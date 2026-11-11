# Configuração do Buildroot e do kernel

A configuração nasce da `raspberrypi4_64_defconfig` oficial e recebe por cima os fragments do
projeto, mesclados por `support/kconfig/merge_config.sh` seguido de `olddefconfig`. O resultado é
salvo com `savedefconfig` em `br2-external/configs/tp_rpi4_defconfig`.

## Árvore BR2_EXTERNAL

```
Configuração: make BR2_EXTERNAL=../br2-external
Símbolo:      arquivo br2-external/external.desc, name: TP
Motivo:       separar o que é do produto (defconfig, overlay, users table,
              fragments) da árvore do Buildroot, que é baixada e descartável.
Dependências: external.desc, Config.in e external.mk devem existir; o caminho
              vira a variável $(BR2_EXTERNAL_TP_PATH), usada nas opções abaixo.
Impacto:      permite atualizar ou trocar o Buildroot sem perder customização,
              e mantém no Git apenas o que o grupo escreveu.
```

## Hostname

```
Configuração: System configuration → System hostname
Símbolo:      BR2_TARGET_GENERIC_HOSTNAME="rpi4-tp-g03"
Motivo:       identificar a placa do grupo na rede e no prompt.
Dependências: nenhuma. O valor é gerado do tp.env pelo scripts/02-configure.sh.
Impacto:      grava /etc/hostname; o init aplica com "hostname -F" no sysinit.
```

## Usuário do projeto

```
Configuração: System configuration → Path to the users tables
Símbolo:      BR2_ROOTFS_USERS_TABLES=
              "$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/users_table.txt"
Motivo:       criar o usuário durante o build, sem nenhum passo manual depois
              do boot — exigência explícita do TP.
Dependências: o utilitário mkusers do Buildroot, executado no target-finalize.
Impacto:      gera as linhas de /etc/passwd, /etc/group e o hash em /etc/shadow.
              O usuário entra no grupo docker, criado pelo pacote docker-engine.
```

A linha usada é:

```
aluno -2 aluno -2 =tpgrupo03 /home/aluno /bin/sh docker Aluno_TP_G03
```

Os dois `-2` pedem UID e GID automáticos na faixa de usuário comum, de 1000 em diante — o valor
que o enunciado espera. A imagem gerada confirma `aluno:x:1000:1000`.

## Root filesystem overlay

```
Configuração: System configuration → Root filesystem overlay directories
Símbolo:      BR2_ROOTFS_OVERLAY=
              "$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/rootfs-overlay"
Motivo:       colocar arquivos no sistema de forma versionada e reproduzível.
Dependências: a árvore é copiada no fim do build, DEPOIS da instalação dos
              pacotes — então o overlay sobrescreve arquivos gerados.
Impacto:      entrega /etc/issue, /etc/network/interfaces, os scripts de init
              do TP (S55hcsr04, S70tp-ap, S99tp-app), /etc/hostapd.conf,
              /etc/dnsmasq.conf, /etc/modules-load.d/tp.conf,
              /usr/bin/tp-evidencias e /opt/docker/tp-distance.tar.
```

A ordem importa: como o overlay é copiado por último, ele tem precedência sobre o
`BR2_TARGET_GENERIC_ISSUE`, sobre o `/etc/network/interfaces` gerado pelo `BR2_SYSTEM_DHCP` e
sobre o `hostapd.conf` de exemplo que o próprio pacote `hostapd` instala. Ver
[docker-web.md](docker-web.md) e [wifi-ap.md](wifi-ap.md).

## Rede por DHCP

```
Configuração: System configuration → Network interface to configure through DHCP
Símbolo:      BR2_SYSTEM_DHCP="eth0"
Motivo:       a Raspberry precisa receber IP do roteador para ser acessada por
              outro equipamento (requisito 12 do TP).
Dependências: pacote ifupdown-scripts; o udhcpc do BusyBox faz o pedido DHCP.
Impacto:      gera /etc/network/interfaces com as diretivas de DHCP, entre elas
              o "wait-delay 15", e instala /etc/network/nfs_check.
```

A `wlan0` **não** entra nesse arquivo: ela só existe depois de o firmware do Wi-Fi carregar, e
quem a configura é o `S70tp-ap`. O motivo está em [wifi-ap.md](wifi-ap.md).

## O pacote do driver

```
Configuração: Target packages → Pacotes do TP → hcsr04-driver
Símbolo:      BR2_PACKAGE_HCSR04_DRIVER=y
Motivo:       compilar o módulo do sensor junto com a imagem, contra o kernel
              exato dela, em vez de levar um .ko pronto.
Dependências: depends on BR2_LINUX_KERNEL; a infraestrutura kernel-module
              acrescenta o kernel às dependências do pacote sozinha.
Impacto:      instala hcsr04.ko.xz em /lib/modules/<versão>/updates/ e o
              registra no modules.dep gerado pelo depmod.
```

A estrutura do pacote — `Config.in`, `.mk`, `src/Makefile` e a ordem obrigatória dos dois `eval` —
está em [driver.md](driver.md).

## Pacotes do Wi-Fi AP

```
Configuração: Target packages → Networking applications → hostapd (+ nl80211),
              dnsmasq, iw
Símbolo:      BR2_PACKAGE_HOSTAPD=y, BR2_PACKAGE_HOSTAPD_DRIVER_NL80211=y,
              BR2_PACKAGE_DNSMASQ=y, BR2_PACKAGE_IW=y
Motivo:       transformar a wlan0 em ponto de acesso e entregar endereços por
              DHCP aos clientes.
Dependências: o nl80211 puxa a libnl; sem essa opção o hostapd não abre
              interface nenhuma.
Impacto:      instala /usr/sbin/hostapd, /usr/bin/hostapd_cli, /usr/sbin/dnsmasq
              e o iw. O pacote dnsmasq também instala um /etc/init.d/S80dnsmasq,
              que o post-build.sh do TP remove.
```

```
Configuração: Target packages → Hardware handling → Firmware → linux-firmware
              → Broadcom BRCM bcm43xxx;  wireless-regdb
Símbolo:      BR2_PACKAGE_LINUX_FIRMWARE_BRCM_BCM43XXX=y,
              BR2_PACKAGE_WIRELESS_REGDB=y
Motivo:       o brcmfmac não funciona sem o firmware do BCM43455; sem ele a
              wlan0 não chega a existir.
Dependências: a opção BCM43XXX seleciona o pacote Cypress, de onde vêm o .bin e
              o .clm_blob que o driver realmente pede.
Impacto:      ~1 MB em /lib/firmware/brcm e /lib/firmware/cypress, mais a
              regulatory.db assinada.
```

## Arquivos de boot e scripts de build

```
Configuração: Bootloaders → rpi-firmware → config.txt file
Símbolo:      BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE=
              "$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/config_tp.txt"
Motivo:       acrescentar "dtoverlay=hcsr04" ao config.txt da partição de boot.
Dependências: o arquivo é a cópia de board/raspberrypi4-64/config_4_64bit.txt.
              ATENÇÃO: o guia manda copiar config_4.txt, que é a variante de
              32 bits — com ela a imagem não dá boot.
Impacto:      mudar esta opção NÃO reinstala o pacote sozinha; é preciso
              "make rpi-firmware-reinstall all". O script 04 confere as três
              linhas obrigatórias dentro da imagem.
```

```
Configuração: System configuration → Custom scripts to run before/after
              creating filesystem images
Símbolo:      BR2_ROOTFS_POST_BUILD_SCRIPT e BR2_ROOTFS_POST_IMAGE_SCRIPT
Motivo:       o post-build remove o S80dnsmasq duplicado; o post-image copia o
              hcsr04.dtbo para overlays/ na partição de boot.
Dependências: a ordem importa. O script do TP é listado ANTES do da Raspberry
              no post-image, porque é o da Raspberry que chama o genimage e
              varre images/rpi-firmware/.
Impacto:      sem o post-image, o .dtbo não chega ao cartão e o dtoverlay do
              config.txt não encontra o arquivo.
```

A opção `BR2_PACKAGE_RPI_FIRMWARE_EXTRA_FILES` não serve aqui: ela instala na raiz de
`rpi-firmware/`, e o firmware procura os overlays em `overlays/`. Mudar o `overlay_prefix`
quebraria o `dtoverlay=miniuart-bt` que a placa já usa.

## Kernel

O container compartilha o kernel da Raspberry, e o driver do sensor é compilado contra ele. Se
faltar um recurso aqui, o `dockerd` não sobe, ou sobe e falha ao criar a rede do container. Por
isso o projeto aplica um fragment por cima do `bcm2711_defconfig`.

```
Configuração: Kernel → Additional configuration fragment files
Símbolo:      BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=
              "$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/linux-docker.fragment"
Motivo:       garantir namespaces, cgroups, veth, bridge, netfilter/NAT e
              overlayfs, que o Docker exige do kernel hospedeiro.
Dependências: o fragment é mesclado sobre o defconfig do kernel pelo próprio
              Buildroot, antes de compilar.
Impacto:      kernel um pouco maior e mais tempo de compilação; sem ele o
              Docker não funciona na placa.
```

| Grupo | Símbolos | Para quê |
|---|---|---|
| Namespaces | `NAMESPACES`, `UTS_NS`, `IPC_NS`, `PID_NS`, `NET_NS`, `USER_NS` | isolar processos, rede, hostname e IPC do container |
| Control groups | `CGROUPS`, `CPUSETS`, `MEMCG`, `CGROUP_PIDS`, `CGROUP_DEVICE`, `CGROUP_FREEZER`, `CGROUP_SCHED`, `CGROUP_CPUACCT` | limitar e contabilizar CPU, memória e processos |
| eBPF | `BPF_SYSCALL`, `CGROUP_BPF` | no cgroup v2 o controle de dispositivos do `runc` é feito por eBPF |
| Segurança | `KEYS`, `SECCOMP`, `SECCOMP_FILTER`, `POSIX_MQUEUE` | perfil seccomp padrão do Docker |
| Rede do container | `VETH`, `BRIDGE`, `BRIDGE_NETFILTER` | par veth ligando o container à bridge `docker0` |
| Netfilter / NAT | `NETFILTER`, `NF_CONNTRACK`, `NF_NAT`, `IP_NF_*`, `IP6_NF_*`, `NETFILTER_XT_*` | publicar a porta com `-p 80:5000` (DNAT e masquerade) |
| Armazenamento | `OVERLAY_FS` | driver `overlay2`, usado pelo Docker para as camadas |

As opções `IP_NF_*` são da família *legacy* (xtables) porque o `iptables` que o Buildroot instala
junto com o `docker-engine` é o legacy, não o `nft`.

**O que o TP 9 acrescentou não precisou de fragment.** O driver e o Wi-Fi dependem de
`CONFIG_MODULES`, `GPIOLIB`, `OF`, `DEVTMPFS_MOUNT`, `CFG80211`, `MAC80211` e `BRCMFMAC`, e todos
já vêm do defconfig da Raspberry — os três últimos como módulo. Em vez de repeti-los no fragment, o
que forçaria recompilar o kernel sem necessidade, o `scripts/04-build-image.sh` **confere que eles
continuam lá**: o risco não é configurá-los errado, é alguém desligar um deles sem perceber.

"=y" no fragment é um pedido, não uma garantia: o kconfig rebaixa a opção para "=m" em silêncio
quando uma dependência dela é módulo. É o que acontece com `CONFIG_BRIDGE`, porque o defconfig traz
`CONFIG_IPV6=m`. Aqui isso é seguro — o alvo tem `kmod`, o `depmod` roda no build e a `liblzma`
está no rootfs, então o `dockerd` carrega `bridge.ko.xz` sob demanda, e o `check-config.sh` do
Docker aceita "as module".

**Como sabemos que o kernel ficou correto.** O `scripts/04-build-image.sh` roda a verificação que o
próprio Docker distribui contra o `.config` gerado e falha se faltar recurso obrigatório; a saída
fica em [../evidence/build/kernel-check-config.txt](../evidence/build/kernel-check-config.txt). Na
Raspberry, a verificação equivalente é o `docker info`.

## Tamanho do root filesystem

```
Configuração: Filesystem images → ext2/3/4 root filesystem → exact size
Símbolo:      BR2_TARGET_ROOTFS_EXT2_SIZE="1024M"
Motivo:       a defconfig da Pi gera 120 MB. Só os binários do Docker já ocupam
              boa parte; ainda entram o tar de 48 MB e as camadas que o
              docker load extrai em /var/lib/docker no 1º boot.
Dependências: BR2_TARGET_ROOTFS_EXT2_4 (ext4).
Impacto:      a imagem do cartão passa a ~1,1 GB. A medição real da imagem
              construída é 258 MB ocupados de 1024 MB.
```

## curl no alvo

```
Configuração: Target packages → Libraries → Networking → libcurl → curl binary
Símbolo:      BR2_PACKAGE_LIBCURL=y, BR2_PACKAGE_LIBCURL_CURL=y
Motivo:       o procedimento de teste do TP usa "curl http://127.0.0.1:5000"
              rodando na própria Raspberry.
Dependências: libcurl.
Impacto:      acrescenta poucos MB ao rootfs; sem ele o teste local exigiria
              outro cliente HTTP.
```

As opções de Docker estão em [docker-web.md](docker-web.md).

## Decisão descartada: compilador Go no alvo

Foi cogitado incluir o compilador Go na imagem, pensando em futuras expansões do projeto. A ideia
foi descartada por custo de espaço.

O Buildroot não oferece o Go como pacote de alvo — o diretório `package/go/` só tem
`Config.in.host`, com `BR2_PACKAGE_HOST_GO`. O Go 1.27.2 que este projeto já compila é ferramenta
**de build**, usada para construir o `docker-engine` e o `containerd` no PC; ele não vai para a
Raspberry. Pôr o compilador no alvo exigiria escrever um pacote próprio no `br2-external`,
instalando o toolchain oficial `linux-arm64`.

Medindo a instalação que o Buildroot já produz:

| Componente | Tamanho |
|---|---|
| `src` (fontes da biblioteca padrão) | 157 MB |
| `pkg` | 135 MB |
| `bin` (compilador e ferramentas) | 20 MB |
| `lib` | 1,8 MB |
| **Total** | **313 MB** |

Uma instalação mínima, sem as fontes, ficaria em torno de 156 MB.

Hoje o rootfs usa 258 MB dos 1024 MB, e o `docker load` do primeiro boot ainda consome cerca de
150 MB ao extrair as camadas do container em `/var/lib/docker`. Acrescentar 313 MB levaria o
sistema a usar aproximadamente 720 MB dos 1024 MB — caberia, mas com folga pequena demais para
qualquer crescimento, e o prudente seria dobrar o rootfs para 2048 MB, o que dobraria também o
tamanho do `sdcard.img`.

**Decisão:** o compilador não entra na imagem. Programas em Go para este sistema serão
compilados de forma cruzada no PC, com alvo AArch64 / Cortex-A72, e apenas o binário pronto será
colocado no overlay numa expansão futura:

```sh
GOOS=linux GOARCH=arm64 go build -o meu-programa
```

Essa também é a prática comum em sistemas embarcados: o alvo executa, o PC compila. Um compilador
no dispositivo só se justifica quando é preciso compilar na própria placa.

## Reprodutibilidade da configuração

O `scripts/02-configure.sh` termina apagando o `.config` e recarregando a defconfig salva, e falha
se o resultado não for idêntico ao anterior. É a garantia de que o arquivo versionado realmente
reconstrói a configuração usada — e não uma aproximação dela.
