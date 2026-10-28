# 02 — Decisões de configuração do Buildroot

A configuração nasce da `raspberrypi4_64_defconfig` oficial e recebe por cima os fragments do
projeto, mesclados por `support/kconfig/merge_config.sh` seguido de `olddefconfig`. O resultado é
salvo com `savedefconfig` em `br2-external/configs/tp8_rpi4_defconfig`.

## Árvore BR2_EXTERNAL

```
Configuração: make BR2_EXTERNAL=../br2-external
Símbolo:      arquivo br2-external/external.desc, name: TP8
Motivo:       separar o que é do produto (defconfig, overlay, users table,
              fragments) da árvore do Buildroot, que é baixada e descartável.
Dependências: external.desc, Config.in e external.mk devem existir; o caminho
              vira a variável $(BR2_EXTERNAL_TP8_PATH), usada nas opções abaixo.
Impacto:      permite atualizar ou trocar o Buildroot sem perder customização,
              e mantém no Git apenas o que o grupo escreveu.
```

## Hostname

```
Configuração: System configuration → System hostname
Símbolo:      BR2_TARGET_GENERIC_HOSTNAME="rpi4-tp8-g03"
Motivo:       identificar a placa do grupo na rede e no prompt.
Dependências: nenhuma. O valor é gerado do tp8.env pelo scripts/02-configure.sh.
Impacto:      grava /etc/hostname; o init aplica com "hostname -F" no sysinit.
```

## Usuário do projeto

```
Configuração: System configuration → Path to the users tables
Símbolo:      BR2_ROOTFS_USERS_TABLES=
              "$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/users_table.txt"
Motivo:       criar o usuário durante o build, sem nenhum passo manual depois
              do boot — exigência explícita do TP.
Dependências: o utilitário mkusers do Buildroot, executado no target-finalize.
Impacto:      gera as linhas de /etc/passwd, /etc/group e o hash em /etc/shadow.
              O usuário entra no grupo docker, criado pelo pacote docker-engine.
```

A linha usada é:

```
aluno -2 aluno -2 =tp8grupo03 /home/aluno /bin/sh docker Aluno_TP8_G03
```

O guia da disciplina mostra `-1` para "UID automático", mas no `support/scripts/mkusers` do
Buildroot `-1` é `AUTO_SYSTEM_ID` (faixa abaixo de 1000) e `-2` é `AUTO_USER_ID` (1000 em diante).
Com `-1` o `aluno` sairia como usuário de sistema. Usamos `-2`, e a imagem gerada confirma
`aluno:x:1000:1000`.

## Root filesystem overlay

```
Configuração: System configuration → Root filesystem overlay directories
Símbolo:      BR2_ROOTFS_OVERLAY=
              "$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/rootfs-overlay"
Motivo:       colocar arquivos no sistema de forma versionada e reproduzível.
Dependências: a árvore é copiada no fim do build, DEPOIS da instalação dos
              pacotes — então o overlay sobrescreve arquivos gerados.
Impacto:      entrega /etc/issue, /etc/init.d/S99flask-tp8, /etc/network/interfaces,
              /usr/bin/tp8-evidencias e /opt/docker/flask-tp8.tar.
```

A ordem importa: como o overlay é copiado por último, ele tem precedência sobre o
`BR2_TARGET_GENERIC_ISSUE` e sobre o `/etc/network/interfaces` gerado pelo `BR2_SYSTEM_DHCP`. Ver
[05-rede.md](05-rede.md).

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

As opções de Docker estão em [04-docker.md](04-docker.md) e as de kernel em
[03-linux.md](03-linux.md).

## Reprodutibilidade da configuração

O `scripts/02-configure.sh` termina apagando o `.config` e recarregando a defconfig salva, e falha
se o resultado não for idêntico ao anterior. É a garantia de que o arquivo versionado realmente
reconstrói a configuração usada — e não uma aproximação dela.
