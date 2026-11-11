# Driver do HC-SR04

Módulo de kernel próprio, escrito para este TP, que encapsula toda a conversa com o sensor
ultrassônico e entrega ao user space uma interface de uma linha.

Fonte: [`br2-external/package/hcsr04-driver/src/hcsr04.c`](../br2-external/package/hcsr04-driver/src/hcsr04.c).

## A interface que ele expõe

```
$ cat /dev/hcsr04
374
```

Um `read()` dispara uma medição e devolve a distância em **milímetros**, como texto terminado em
`\n`. É o que o enunciado exige na seção 5.1.

O device é criado por `misc_register()` com minor dinâmico, o que faz o próprio kernel escolher o
número e criar o nó em `/dev` pelo devtmpfs. Não há ioctl, não há escrita, não há parâmetros: tudo
o que a aplicação precisa saber é o caminho do arquivo. É exatamente essa redução que justifica
escrever um driver em vez de manipular GPIO de dentro do Python.

Depois do primeiro `read()` de cada `open()`, o arquivo devolve EOF. Quem quiser uma nova medição
abre de novo — é por isso que o backend em [docker-web.md](docker-web.md) abre o arquivo a cada
leitura em vez de guardar o descritor.

## O algoritmo da medição

```
read()
  ├─ pega o mutex                     (uma medição por vez)
  ├─ limpa o estado da medição anterior
  ├─ TRIG: 0 ─ 2 us ─ 1 ─ 10 us ─ 0   (o datasheet exige >= 10 us em alto)
  ├─ dorme em wait_for_completion_timeout(100 ms)
  │     ↑ enquanto isso, o tratador de interrupção:
  │        borda de SUBIDA  → guarda o instante de partida (ktime_get)
  │        borda de DESCIDA → calcula a distância e acorda o read()
  ├─ se o prazo estourou devolve -ETIMEDOUT
  └─ formata "%llu\n" e copia para o user space
```

**Por que interrupção e não sondagem.** A primeira versão do driver lia o pino ECHO em laço, com
prazo limite. É o caminho mais direto de escrever a medição, ao custo de ocupar a CPU enquanto ela
acontece — o que pode chegar a 38 ms. Com interrupção nas duas bordas, o processo que chamou `read()` dorme e a CPU
fica livre. As duas versões estão no histórico do Git, em commits separados, porque a troca é
justamente o ponto que vale discutir.

**A guarda contra borda solta.** O tratador descarta uma borda de descida que não tenha sido
precedida por uma de subida. Sem isso, uma transição espúria faria o cálculo usar um instante
velho e devolver uma distância sem sentido.

**O prazo de 100 ms.** Não é um número arbitrário. O datasheet cobre até cerca de 4 m, o que dá uns
23 ms de ida e volta; mas **quando não há obstáculo o sensor mantém o ECHO alto por cerca de 38 ms**
antes de desistir. Um prazo menor que isso transformaria "não há obstáculo" em erro de leitura. Os
100 ms deixam margem e ainda devolvem erro depressa quando o sensor não responde — o que é o
sintoma de ECHO desligado ou divisor mal montado.

## A conta, em inteiros

O kernel não usa ponto flutuante. A conversão é feita em inteiros de 64 bits:

```
velocidade do som ≈ 343 m/s = 0,343 mm/us

mm = (ns / 1000) × 0,343 / 2   =   ns × 343 / 2000000
```

A divisão por 2 é porque o tempo medido é o de **ida e volta**. No código isso aparece como
`div_u64((u64)delta_ns * 343, 2000000)`, com `div_u64` porque dividir um `u64` diretamente não é
portável em 32 bits.

A velocidade do som varia com a temperatura (~0,17 % por °C). O driver usa o valor de 20 °C e não
compensa: para a precisão que este TP demonstra, o erro é menor que a dispersão do próprio sensor.

## Device Tree

Os números dos pinos **não aparecem no código**. O driver é um `platform_driver` que casa com um nó
do Device Tree:

```dts
hcsr04 {
    compatible = "unisanta,hcsr04";
    trig-gpios = <&gpio 23 0>;   /* GPIO23, ativo em alto */
    echo-gpios = <&gpio 24 0>;   /* GPIO24, ativo em alto */
    status = "okay";
};
```

O campo `compatible` é a chave de casamento: o kernel compara a string do nó com a tabela
`of_device_id` do módulo e, quando bate, chama o `probe()`. O prefixo antes da vírgula é o
fabricante — aqui `unisanta`, porque o dispositivo é nosso e não existe um `vendor` registrado.

No `probe()`, `devm_gpiod_get(dev, "trig", ...)` procura a propriedade **`trig-gpios`** no nó: o
sufixo `-gpios` é convenção da API de GPIO descriptors. Trocar de pino é editar o overlay e
recompilá-lo, sem tocar no `.c`.

O arquivo é um **overlay** ([`hcsr04-overlay.dts`](../br2-external/board/tp/rpi4/hcsr04-overlay.dts)),
compilado para `hcsr04.dtbo` e carregado pela linha `dtoverlay=hcsr04` do
[`config_tp.txt`](../br2-external/board/tp/rpi4/config_tp.txt). O `.dtbo` é versionado junto com o
`.dts`, e o `scripts/04-build-image.sh` recompila o `.dts` e compara os bytes: assim um `.dts`
editado sem regerar o binário não passa despercebido.

Por que GPIO23 e GPIO24, e por que o ECHO precisa de divisor resistivo, está em
[hardware.md](hardware.md).

## Integração ao Buildroot

O driver é um pacote da árvore `BR2_EXTERNAL`, em `br2-external/package/hcsr04-driver/`:

| Arquivo | Papel |
|---|---|
| `Config.in` | declara `BR2_PACKAGE_HCSR04_DRIVER`, com `depends on BR2_LINUX_KERNEL` — sem kernel não há contra o que compilar |
| `hcsr04-driver.mk` | diz onde está o fonte e invoca a infraestrutura de compilação |
| `src/Makefile` | uma linha, `obj-m += hcsr04.o`: é o Makefile que o build de módulos externos do kernel espera |
| `src/hcsr04.c` | o driver |

O `.mk` termina com dois `eval`, **nesta ordem**:

```make
$(eval $(kernel-module))
$(eval $(generic-package))
```

A ordem é exigida pelo Buildroot. O manual diz que a infraestrutura `kernel-module` "is not
stand-alone, and requires any of the other `*-package` macros be called after it": sozinha, ela só
registra os hooks de post-build e post-install que compilam e instalam o módulo; quem transforma
isso nas etapas do pacote é o `generic-package`, chamado depois. É também por isso que não é
preciso declarar `linux` em `DEPENDENCIES` — o `kernel-module` acrescenta sozinho.

`HCSR04_DRIVER_SITE_METHOD = local` faz o Buildroot sincronizar o diretório `src/` inteiro para a
área de build. A consequência prática: compilar o módulo à mão dentro de `src/` deixa `.o`, `.ko` e
arquivos de dependência que iriam junto. Eles estão no `.gitignore`.

O módulo sai instalado em `/lib/modules/<versão>/updates/`, comprimido em `.ko.xz`.

## Como ele chega a carregar no boot

A criação de dispositivos desta imagem é `devtmpfs` puro — **sem mdev e sem eudev**. Não há,
portanto, quem trate o uevent e carregue um módulo por alias. Ou seja: o alias de Device Tree que o
módulo declara não basta, e sem um `modprobe` explícito o `/dev/hcsr04` simplesmente não existiria.

A cadeia é esta:

```
/etc/modules-load.d/tp.conf   lista "hcsr04"
        ↓
S11modules                    (do Buildroot) faz o modprobe
        ↓
probe() do driver             casa com o nó do Device Tree e cria /dev/hcsr04
        ↓
S55hcsr04                     espera o device aparecer e faz chmod 666
        ↓
S99tp-app                     sobe o container com --device /dev/hcsr04
```

O `chmod 666` existe porque o devtmpfs cria o nó como `0600` do `root`. O container roda como root
e enxergaria o device de qualquer forma, mas sem a permissão aberta o usuário `aluno` não
conseguiria fazer o `cat /dev/hcsr04` que o enunciado pede como evidência.

## O que foi conferido sem a placa

Nada disto substitui o sensor na mesa, mas cada peça tem uma verificação automática no
`scripts/04-build-image.sh`:

| Conferência | O que ela pega |
|---|---|
| recompila o `.dts` e compara com o `.dtbo` versionado | binário esquecido depois de editar o `.dts` |
| `hcsr04.ko*` presente em `/lib/modules/<versão>` e em `modules.dep` | pacote fora da defconfig; `modprobe` que não acharia o módulo |
| `vermagic` do módulo igual à versão do kernel da imagem | módulo compilado contra outro kernel — o erro clássico |
| `liblzma.so.5` no alvo | módulo `.xz` que o `modprobe` não conseguiria descomprimir |
| `hcsr04.dtbo` em `rpi-firmware/overlays/` e igual ao versionado | overlay que não chegaria à partição de boot |
| `config.txt` da imagem com `dtoverlay=hcsr04` | overlay presente mas nunca carregado |
| `hcsr04` em `/etc/modules-load.d/tp.conf` | device que nunca existiria no boot |

O módulo também foi compilado contra o kernel 6.12.61 do projeto com `W=1`, sem avisos. Durante o
desenvolvimento, o overlay foi mesclado no `bcm2711-rpi-4-b.dtb` real com `fdtoverlay` e a saída
confirmou que o nó aparece sob `/` e que os dois GPIOs resolvem para o controlador
`brcm,bcm2711-gpio`.

**O que só o hardware demonstra:** que o pulso de disparo sai, que a interrupção chega nas duas
bordas, que o tempo medido corresponde à distância real e que o valor acompanha um objeto se
aproximando. Está na lista de [testes.md](testes.md).

## Limites conhecidos

- Faixa útil do sensor: de 2 cm a 4 m. Fora disso a leitura é devolvida do mesmo jeito; quem marca
  "fora de faixa" é a API, não o driver — ele devolve o que mediu.
- Sem obstáculo, a leitura resultante fica perto de 6,5 m, que é o pulso de ~38 ms convertido.
- Uma medição por vez: o `mutex` serializa leituras simultâneas, que no sensor se atrapalhariam.
- Sem compensação de temperatura.
- O driver não limita a frequência de disparos. Quem garante folga entre medições é a aplicação,
  com um cache curto.
