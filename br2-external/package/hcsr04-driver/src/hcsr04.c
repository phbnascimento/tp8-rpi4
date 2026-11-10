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
 * A medição é feita por interrupção nas duas bordas do pino ECHO: a borda de
 * subida marca o instante em que o pulso ultrassônico partiu, a de descida o
 * instante em que o eco voltou. Entre as duas, o processo que chamou read()
 * dorme — nenhuma CPU fica ocupada esperando.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/completion.h>
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
 * O datasheet cobre até ~4 m, cerca de 23 ms de ida e volta. Quando não há
 * obstáculo, porém, o sensor mantém o ECHO alto por cerca de 38 ms antes de
 * desistir — por isso o prazo tem de ser maior que isso, senão a ausência de
 * obstáculo apareceria como erro de timeout em vez de leitura. 100 ms deixa
 * margem confortável e ainda devolve erro rápido se o sensor não responder.
 */
#define HCSR04_ECHO_TIMEOUT_MS	100

struct hcsr04_dev {
	struct gpio_desc *trig;
	struct gpio_desc *echo;
	int irq;

	/*
	 * Escritos pelo tratador de interrupção, lidos por read(). A ordenação
	 * entre os dois é dada pelo par complete()/wait_for_completion(), que
	 * estabelece a barreira de memória necessária.
	 */
	ktime_t rise;			/* instante da borda de subida */
	bool have_rise;			/* já vimos a subida desta medição */
	u64 distance_mm;

	struct completion done;
	struct mutex lock;		/* serializa as medições */
	struct miscdevice miscdev;
};

/*
 * Tratador das duas bordas do ECHO.
 *
 * Roda em contexto de interrupção, por isso usa gpiod_get_value() e não a
 * variante _cansleep: o GPIO do BCM2711 é mapeado em memória e a leitura não
 * dorme.
 */
static irqreturn_t hcsr04_irq(int irq, void *data)
{
	struct hcsr04_dev *hdev = data;
	ktime_t now = ktime_get();
	s64 delta_ns;

	if (gpiod_get_value(hdev->echo) > 0) {
		hdev->rise = now;
		hdev->have_rise = true;
		return IRQ_HANDLED;
	}

	/*
	 * Borda de descida. Se não vimos a subida correspondente, esta é uma
	 * borda espúria ou resto de uma medição anterior: descartar, senão o
	 * cálculo usaria um instante de subida velho e devolveria distância
	 * sem sentido.
	 */
	if (!hdev->have_rise)
		return IRQ_HANDLED;

	hdev->have_rise = false;

	delta_ns = ktime_to_ns(ktime_sub(now, hdev->rise));
	if (delta_ns <= 0)
		return IRQ_HANDLED;

	hdev->distance_mm = div_u64((u64)delta_ns * HCSR04_SPEED_NUM,
				    HCSR04_SPEED_DEN);
	complete(&hdev->done);

	return IRQ_HANDLED;
}

/* Pulso de disparo: o HC-SR04 exige TRIG em nível alto por >= 10 us. */
static void hcsr04_trigger(struct hcsr04_dev *hdev)
{
	gpiod_set_value_cansleep(hdev->trig, 0);
	udelay(2);
	gpiod_set_value_cansleep(hdev->trig, 1);
	udelay(10);
	gpiod_set_value_cansleep(hdev->trig, 0);
}

static ssize_t hcsr04_read(struct file *file, char __user *buf,
			   size_t count, loff_t *ppos)
{
	struct miscdevice *misc = file->private_data;
	struct hcsr04_dev *hdev = container_of(misc, struct hcsr04_dev, miscdev);
	char out[32];
	u64 distance_mm;
	unsigned long left;
	int len;

	/* Leitura curta: depois do primeiro read() o arquivo "acaba". */
	if (*ppos != 0)
		return 0;

	if (mutex_lock_interruptible(&hdev->lock))
		return -ERESTARTSYS;

	/*
	 * Zerar antes de disparar: se sobrou sinalização de uma medição
	 * anterior, wait_for_completion_timeout() voltaria na hora com um
	 * valor velho.
	 */
	hdev->have_rise = false;
	reinit_completion(&hdev->done);

	hcsr04_trigger(hdev);

	left = wait_for_completion_timeout(&hdev->done,
					   msecs_to_jiffies(HCSR04_ECHO_TIMEOUT_MS));
	if (!left) {
		mutex_unlock(&hdev->lock);
		return -ETIMEDOUT;
	}

	distance_mm = hdev->distance_mm;

	mutex_unlock(&hdev->lock);

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

	hdev->irq = gpiod_to_irq(hdev->echo);
	if (hdev->irq < 0)
		return dev_err_probe(&pdev->dev, hdev->irq,
				     "o GPIO do ECHO não suporta interrupção\n");

	init_completion(&hdev->done);
	mutex_init(&hdev->lock);

	/*
	 * As duas bordas são necessárias: a de subida dá o início da contagem,
	 * a de descida o fim. Registrado com devm_, portanto liberado junto com
	 * o dispositivo.
	 *
	 * A IRQ é pedida depois de init_completion e mutex_init porque o
	 * tratador pode disparar assim que ela é registrada.
	 */
	ret = devm_request_irq(&pdev->dev, hdev->irq, hcsr04_irq,
			       IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING,
			       dev_name(&pdev->dev), hdev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "erro ao registrar a interrupção do ECHO\n");

	hdev->miscdev.minor  = MISC_DYNAMIC_MINOR;
	hdev->miscdev.name   = "hcsr04";
	hdev->miscdev.fops   = &hcsr04_fops;
	hdev->miscdev.parent = &pdev->dev;

	ret = misc_register(&hdev->miscdev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "erro ao registrar /dev/hcsr04\n");

	platform_set_drvdata(pdev, hdev);
	dev_info(&pdev->dev, "HC-SR04 registrado em /dev/hcsr04 (IRQ %d)\n",
		 hdev->irq);

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
