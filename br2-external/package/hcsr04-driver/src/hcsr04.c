// SPDX-License-Identifier: GPL-2.0
/*
 * hcsr04 — driver do sensor ultrassônico HC-SR04.
 *
 * Expõe /dev/hcsr04. Cada read() dispara uma medição e devolve a distância
 * em milímetros, como texto terminado em '\n'.
 *
 * Os GPIOs não estão gravados aqui: vêm do Device Tree, pelas propriedades
 * trig-gpios e echo-gpios do nó compatível com "unisanta,hcsr04". Trocar de
 * pino é editar o overlay, não recompilar o módulo.
 *
 * Esta primeira versão mede por sondagem (polling) do pino ECHO: o caminho
 * mais direto de escrever a medição, ao custo de ocupar a CPU enquanto ela
 * acontece. A versão por interrupção vem em seguida.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/ktime.h>
#include <linux/delay.h>
#include <linux/math64.h>

/*
 * Velocidade do som ~343 m/s a 20 °C, que é 0,343 mm/us. O tempo medido é o
 * de ida e volta, daí a divisão por 2:
 *
 *   mm = (ns / 1000) * 0,343 / 2  =  ns * 343 / 2000000
 *
 * A conta é feita em inteiros de 64 bits porque o kernel não usa ponto
 * flutuante.
 */
#define HCSR04_SPEED_NUM	343ULL
#define HCSR04_SPEED_DEN	2000000ULL

/*
 * O datasheet do sensor cobre até ~4 m, o que dá cerca de 23 ms de ida e
 * volta. 60 ms deixa folga suficiente e ainda garante que um sensor ausente
 * ou mal ligado devolva erro rápido em vez de travar a leitura.
 */
#define HCSR04_ECHO_TIMEOUT_MS	60

struct hcsr04_dev {
	struct gpio_desc *trig;
	struct gpio_desc *echo;
	struct mutex lock;		/* serializa as medições */
	struct miscdevice miscdev;
};

/* Pulso de disparo: o HC-SR04 exige TRIG em nível alto por >= 10 us. */
static void hcsr04_trigger(struct hcsr04_dev *hdev)
{
	gpiod_set_value_cansleep(hdev->trig, 0);
	udelay(2);
	gpiod_set_value_cansleep(hdev->trig, 1);
	udelay(10);
	gpiod_set_value_cansleep(hdev->trig, 0);
}

/*
 * Espera o ECHO atingir o nível desejado, devolvendo o instante em que isso
 * aconteceu. Erro -ETIMEDOUT se o prazo estourar.
 */
static int hcsr04_wait_level(struct hcsr04_dev *hdev, int want, ktime_t *when)
{
	ktime_t deadline = ktime_add_ms(ktime_get(), HCSR04_ECHO_TIMEOUT_MS);

	while (gpiod_get_value(hdev->echo) != want) {
		if (ktime_after(ktime_get(), deadline))
			return -ETIMEDOUT;
		cpu_relax();
	}

	*when = ktime_get();
	return 0;
}

static int hcsr04_measure(struct hcsr04_dev *hdev, u64 *distance_mm)
{
	ktime_t rise, fall;
	s64 delta_ns;
	int ret;

	hcsr04_trigger(hdev);

	ret = hcsr04_wait_level(hdev, 1, &rise);
	if (ret)
		return ret;

	ret = hcsr04_wait_level(hdev, 0, &fall);
	if (ret)
		return ret;

	delta_ns = ktime_to_ns(ktime_sub(fall, rise));
	if (delta_ns <= 0)
		return -EIO;

	*distance_mm = div_u64((u64)delta_ns * HCSR04_SPEED_NUM,
			       HCSR04_SPEED_DEN);
	return 0;
}

static ssize_t hcsr04_read(struct file *file, char __user *buf,
			   size_t count, loff_t *ppos)
{
	struct miscdevice *misc = file->private_data;
	struct hcsr04_dev *hdev = container_of(misc, struct hcsr04_dev, miscdev);
	char out[32];
	u64 distance_mm;
	int len, ret;

	/* Leitura curta: depois do primeiro read() o arquivo "acaba". */
	if (*ppos != 0)
		return 0;

	if (mutex_lock_interruptible(&hdev->lock))
		return -ERESTARTSYS;

	ret = hcsr04_measure(hdev, &distance_mm);

	mutex_unlock(&hdev->lock);

	if (ret)
		return ret;

	len = scnprintf(out, sizeof(out), "%llu\n", distance_mm);

	return simple_read_from_buffer(buf, count, ppos, out, len);
}

static const struct file_operations hcsr04_fops = {
	.owner	= THIS_MODULE,
	.read	= hcsr04_read,
	.llseek	= default_llseek,
};

static int hcsr04_probe(struct platform_device *pdev)
{
	struct hcsr04_dev *hdev;
	int ret;

	hdev = devm_kzalloc(&pdev->dev, sizeof(*hdev), GFP_KERNEL);
	if (!hdev)
		return -ENOMEM;

	/*
	 * devm_gpiod_get procura a propriedade "<nome>-gpios" no nó do Device
	 * Tree. O prefixo devm_ faz o kernel liberar o recurso sozinho quando
	 * o dispositivo sai, então remove() não precisa desfazer isso.
	 */
	hdev->trig = devm_gpiod_get(&pdev->dev, "trig", GPIOD_OUT_LOW);
	if (IS_ERR(hdev->trig))
		return dev_err_probe(&pdev->dev, PTR_ERR(hdev->trig),
				     "erro ao obter o GPIO do TRIG\n");

	hdev->echo = devm_gpiod_get(&pdev->dev, "echo", GPIOD_IN);
	if (IS_ERR(hdev->echo))
		return dev_err_probe(&pdev->dev, PTR_ERR(hdev->echo),
				     "erro ao obter o GPIO do ECHO\n");

	mutex_init(&hdev->lock);

	hdev->miscdev.minor  = MISC_DYNAMIC_MINOR;
	hdev->miscdev.name   = "hcsr04";
	hdev->miscdev.fops   = &hcsr04_fops;
	hdev->miscdev.parent = &pdev->dev;

	ret = misc_register(&hdev->miscdev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "erro ao registrar /dev/hcsr04\n");

	platform_set_drvdata(pdev, hdev);
	dev_info(&pdev->dev, "HC-SR04 registrado em /dev/hcsr04\n");

	return 0;
}

static void hcsr04_remove(struct platform_device *pdev)
{
	struct hcsr04_dev *hdev = platform_get_drvdata(pdev);

	misc_deregister(&hdev->miscdev);
}

static const struct of_device_id hcsr04_of_match[] = {
	{ .compatible = "unisanta,hcsr04" },
	{ }
};
MODULE_DEVICE_TABLE(of, hcsr04_of_match);

static struct platform_driver hcsr04_driver = {
	.probe	= hcsr04_probe,
	.remove	= hcsr04_remove,
	.driver	= {
		.name		= "hcsr04",
		.of_match_table	= hcsr04_of_match,
	},
};
module_platform_driver(hcsr04_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Grupo 3 - Sistemas Embarcados - UNISANTA");
MODULE_DESCRIPTION("Driver Linux para o sensor ultrassonico HC-SR04");
