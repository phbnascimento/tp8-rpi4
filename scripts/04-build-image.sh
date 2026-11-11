#!/usr/bin/env bash
# 04 — Compila a imagem Linux completa (guia Aula 10, Etapa 10.3/10.4).
# 1º build: de 1 a várias horas (baixa toolchain, kernel, Go, Docker...).
# Se cair no meio (internet, energia), é só rodar de novo: ele continua.
# Log completo em output-rpi4/build.log.
source "$(dirname "$0")/lib.sh"
require_not_root

[ -f "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" ] \
  || die "falta rootfs-overlay/opt/docker/$IMAGE_TAR_NAME — rode ./scripts/03-build-flask-image.sh primeiro"
for s in S55hcsr04 S70tp-ap S99tp-app; do
  [ -x "$OVERLAY_DIR/etc/init.d/$s" ] \
    || die "$s sem permissão de execução — rode ./scripts/02-configure.sh"
done

if [ ! -f "$OUT_DIR/.config" ]; then
  [ -f "$EXT_DIR/configs/$DEFCONFIG_NAME" ] || die "sem .config e sem defconfig — rode ./scripts/02-configure.sh"
  info "Carregando $DEFCONFIG_NAME..."
  br_make "$DEFCONFIG_NAME"
fi

JOBS="$(nproc)"
info "Compilando com -j$JOBS (log: output-rpi4/build.log)."
START=$(date +%s)
if ! br_make -j"$JOBS" 2>&1 | tee "$OUT_DIR/build.log"; then
  echo
  tail -n 40 "$OUT_DIR/build.log"
  die "o build falhou. Leia as últimas linhas acima (o erro real costuma estar ~20 linhas antes do fim)."
fi
MIN=$(( ($(date +%s) - START) / 60 ))

IMG="$OUT_DIR/images/sdcard.img"
[ -f "$IMG" ] || die "build terminou mas não achei $IMG"
ls -lh "$OUT_DIR/images/"

# Confere se o que importa entrou no rootfs final
T="$OUT_DIR/target"
for f in etc/issue etc/network/interfaces etc/init.d/S60dockerd etc/init.d/S99tp-app \
         "opt/docker/$IMAGE_TAR_NAME" usr/bin/docker usr/bin/dockerd usr/bin/curl usr/bin/tp-evidencias; do
  [ -e "$T/$f" ] || die "não encontrei /$f no rootfs final (output-rpi4/target)"
done
# O Buildroot copia o overlay POR CIMA de target/ e nunca remove o que ficou de
# uma build anterior. Depois do rename tp8 -> tp, um S99flask-tp8 sobrevivente
# subiria um segundo container disputando a porta 5000. Falha cedo em vez de
# gerar uma imagem com os dois.
# Só nossos diretórios: em lib/modules existem módulos do kernel cujo nome contém
# a mesma sequência (atp870u, ntp8835), que dariam falso positivo.
STALE="$(find "$T/etc/init.d" "$T/usr/bin" "$T/opt/docker" -name '*tp8*' 2>/dev/null)"
[ -z "$STALE" ] \
  || die "sobraram arquivos da nomenclatura antiga em target/:
$STALE
Apague-os (ou rode 'make -C buildroot O=../output-rpi4 clean') e gere a imagem de novo."
# O overlay guarda o tar da imagem Docker. Renomear o arquivo não muda a RepoTag
# gravada dentro dele: se divergir do IMAGE_REF, o S99 carrega uma tag e tenta
# rodar outra, e o container não sobe no boot.
if command -v tar >/dev/null 2>&1; then
  tar -xOf "$T/opt/docker/$IMAGE_TAR_NAME" manifest.json 2>/dev/null \
    | grep -q "\"$IMAGE_REF\"" \
    || die "$IMAGE_TAR_NAME não contém a imagem $IMAGE_REF — rode ./scripts/03-build-flask-image.sh"
fi

# O Buildroot copia o overlay por cima de target/ e nunca apaga nada de uma
# build anterior. Depois do rename flask-tp -> tp-distance, um flask-tp.tar
# esquecido continuaria na imagem ocupando 48 MB, e o "docker load" do boot
# carregaria as duas. Exigir o conteúdo exato é mais seguro do que procurar o
# nome antigo, que daqui a duas entregas ninguém lembra.
ESPERADO="LEIA-ME.txt $IMAGE_TAR_NAME"
ENCONTRADO="$(cd "$T/opt/docker" && ls | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$ENCONTRADO" = "$ESPERADO" ] \
  || die "/opt/docker na imagem tem \"$ENCONTRADO\", esperado \"$ESPERADO\".
  Sobrou tar de uma nomenclatura anterior? Apague-o do rootfs-overlay e de
  output-rpi4/target/opt/docker/ e gere a imagem de novo."

# O script de boot precisa pedir exatamente a imagem que está no tar. São três
# nomes escritos em arquivos diferentes (lib.sh, o tar e o init), e um rename
# que esqueça um deles só apareceria no boot, com o container não subindo.
# O "|| true" não é enfeite: sem ele, quando não houver S99 nenhum, o ls sai
# com erro, o set -e derruba o script aqui e a mensagem abaixo — que é a útil —
# nunca chega a ser impressa.
S99="$(ls "$T"/etc/init.d/S99* 2>/dev/null | head -1 || true)"
[ -n "$S99" ] || die "não há script S99* em /etc/init.d: nada subiria o container no boot"
grep -qxF "IMAGE=\"$IMAGE_REF\"" "$S99" \
  || die "o $(basename "$S99") não usa IMAGE=\"$IMAGE_REF\" (é o que está no $IMAGE_TAR_NAME)"
grep -qxF "TAR=\"/opt/docker/$IMAGE_TAR_NAME\"" "$S99" \
  || die "o $(basename "$S99") não aponta para /opt/docker/$IMAGE_TAR_NAME"
info "container: $IMAGE_REF no tar, no $(basename "$S99") e em /opt/docker, sem sobras ✔"

# --- Boot: cada serviço com o seu script, e um só -------------------------
# O rename S99flask-tp -> S99tp-app não apaga o arquivo antigo de target/, e
# dois scripts S99 subiriam dois containers disputando a porta 80.
N_S99="$(ls "$T"/etc/init.d/S99* 2>/dev/null | wc -l)"
[ "$N_S99" = "1" ] \
  || die "há $N_S99 scripts S99* em /etc/init.d — sobrou o de um nome anterior?
$(ls "$T"/etc/init.d/S99* 2>/dev/null)
  Apague o antigo de output-rpi4/target/etc/init.d/ e gere a imagem de novo."
[ -x "$T/etc/init.d/S99tp-app" ] || die "/etc/init.d/S99tp-app não está no rootfs"
[ -x "$T/etc/init.d/S55hcsr04" ] || die "/etc/init.d/S55hcsr04 não está no rootfs"

# O container só enxerga o sensor com o --device, e o cliente só abre
# http://192.168.50.1 sem porta se a publicação for na 80. As duas coisas estão
# no checklist de avaliação e são invisíveis até alguém tentar usar.
# Os comentários do próprio script falam de "--device", então procurar a
# palavra solta acharia o comentário e a conferência passaria mesmo com a opção
# removida — foi o que aconteceu no primeiro teste desta checagem. Só valem
# linhas de código.
grep -v '^[[:space:]]*#' "$T/etc/init.d/S99tp-app" | grep -q -- '--device' \
  || die "o S99tp-app não passa --device: o container subiria sem o /dev/hcsr04"
grep -qxF 'PORTA=80' "$T/etc/init.d/S99tp-app" \
  || die "o S99tp-app não publica na porta 80: http://192.168.50.1 não abriria"
grep -qxF 'hcsr04' "$T/etc/modules-load.d/tp.conf" \
  || die "/etc/modules-load.d/tp.conf não lista o hcsr04: o /dev/hcsr04 não existiria no boot"
info "boot: S55hcsr04 prepara o device, S99tp-app sobe o container com --device na porta 80 ✔"

# --- HC-SR04: driver, overlay e partição de boot -------------------------
# Nada disto dá para testar sem a placa, então cada peça é conferida aqui.

# 1. O .dtbo versionado tem de corresponder ao .dts. Sem esta conferência, um
#    .dts editado e um .dtbo esquecido passam despercebidos até o boot.
# O 04 só chega aqui depois de um build completo, então o dtc do host existe.
# Antes isto era um "if": quando o dtc faltava, a conferência era pulada em
# silêncio e a linha de confirmação mais abaixo afirmava algo que não tinha sido
# verificado.
DTC="$OUT_DIR/host/bin/dtc"
[ -x "$DTC" ] || die "não achei o dtc em $DTC — sem ele não dá para conferir se o hcsr04.dtbo corresponde ao .dts"
DTBO_TMP="$(mktemp)"
"$DTC" -@ -I dts -O dtb -o "$DTBO_TMP" "$BOARD_DIR/hcsr04-overlay.dts" 2>/dev/null \
  || die "hcsr04-overlay.dts não compila"
cmp -s "$DTBO_TMP" "$BOARD_DIR/hcsr04.dtbo" \
  || { rm -f "$DTBO_TMP"; die "hcsr04.dtbo está desatualizado em relação ao .dts.
  Regere com: $DTC -@ -I dts -O dtb -o $BOARD_DIR/hcsr04.dtbo $BOARD_DIR/hcsr04-overlay.dts"; }
rm -f "$DTBO_TMP"

# 2. O módulo precisa estar no rootfs e o vermagic bater com o kernel desta
#    imagem. Módulo compilado contra outro kernel é o erro clássico, e só
#    apareceria como modprobe falhando no boot.
# O "|| true" é o mesmo caso do S99= mais abaixo: sem ele, um rootfs sem
# /lib/modules faria o set -e matar o script antes da mensagem explicativa.
KVER="$(ls "$T/lib/modules" 2>/dev/null | head -1 || true)"
[ -n "$KVER" ] || die "não há /lib/modules no rootfs"
KO="$(find "$T/lib/modules/$KVER" -name 'hcsr04.ko*' | head -1)"
[ -n "$KO" ] || die "hcsr04.ko não foi instalado em /lib/modules/$KVER
  (o pacote está selecionado? confira BR2_PACKAGE_HCSR04_DRIVER no .config)"
grep -q "hcsr04" "$T/lib/modules/$KVER/modules.dep" \
  || die "hcsr04 não aparece em modules.dep — o modprobe não vai encontrá-lo"

KO_PLAIN="$KO"
case "$KO" in
  *.xz) KO_PLAIN="$(mktemp)"; xz -dc "$KO" > "$KO_PLAIN" ;;
esac
VERMAGIC="$("$OUT_DIR/host/bin/aarch64-linux-objcopy" -O binary -j .modinfo "$KO_PLAIN" /dev/stdout 2>/dev/null \
  | tr '\0' '\n' | sed -n 's/^vermagic=//p' | cut -d' ' -f1)"
[ "$KO_PLAIN" = "$KO" ] || rm -f "$KO_PLAIN"
[ "$VERMAGIC" = "$KVER" ] \
  || die "vermagic do hcsr04.ko ($VERMAGIC) não bate com o kernel da imagem ($KVER).
  O módulo foi compilado contra outro kernel: rode 'make -C buildroot O=../output-rpi4 hcsr04-driver-dirclean' e gere de novo."

# 3. Módulos comprimidos só carregam se o modprobe souber descomprimir. O kmod
#    do Buildroot faz isso por dlopen, então a biblioteca tem de estar no alvo.
case "$KO" in
  *.xz) [ -e "$T/usr/lib/liblzma.so.5" ] \
    || die "os módulos estão comprimidos em xz mas liblzma.so.5 não está no alvo: o modprobe falharia no boot" ;;
esac

# 4. O overlay precisa chegar à partição de boot, e o config.txt precisa mandar
#    carregá-lo. Mudar BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE não reinstala o
#    pacote sozinho, então este é um erro fácil de cometer e invisível.
FW="$OUT_DIR/images/rpi-firmware"
[ -f "$FW/overlays/hcsr04.dtbo" ] \
  || die "hcsr04.dtbo não está em images/rpi-firmware/overlays — o post-image.sh do TP rodou?"
# E a cópia instalada tem de ser a versionada: é dela que o genimage monta a
# boot.vfat, e uma cópia velha ali sobrevive a mudanças no .dts.
cmp -s "$FW/overlays/hcsr04.dtbo" "$BOARD_DIR/hcsr04.dtbo" \
  || die "o hcsr04.dtbo instalado em images/rpi-firmware/overlays difere do versionado"
# O cmdline.txt é instalado pelo mesmo pacote e sofre do mesmo problema de
# reinstalação: trocar a opção não reinstala sozinha.
for linha in 'quiet' 'loglevel=3' 'console=tty1'; do
  grep -qF "$linha" "$FW/cmdline.txt" \
    || die "o cmdline.txt da imagem está sem \"$linha\".
  Se você mudou cmdline_tp.txt, o pacote precisa ser reinstalado:
    make -C buildroot O=../output-rpi4 BR2_EXTERNAL=../br2-external rpi-firmware-reinstall all"
done
for linha in 'kernel=Image' 'arm_64bit=1' 'dtoverlay=hcsr04' 'disable_splash=1' 'boot_delay=0' 'initial_turbo=30'; do
  grep -qxF "$linha" "$FW/config.txt" \
    || die "o config.txt da imagem está sem \"$linha\".
  Se você mudou config_tp.txt, o pacote precisa ser reinstalado:
    make -C buildroot O=../output-rpi4 BR2_EXTERNAL=../br2-external rpi-firmware-reinstall all"
done

info "HC-SR04: .dtbo igual ao .dts, módulo no rootfs com vermagic $KVER, overlay e config.txt na partição de boot ✔"

# --- Wi-Fi AP: pacotes, firmware, módulo e scripts de boot ---------------
# Mesma lógica do bloco do HC-SR04: nada disto dá para testar sem a placa, e
# cada peça que falta produz um sintoma indireto (wlan0 inexistente, hostapd
# abortando) que só apareceria na apresentação.

# 1) Os programas entraram na imagem.
for f in usr/sbin/hostapd usr/bin/hostapd_cli usr/sbin/dnsmasq; do
  [ -x "$T/$f" ] || die "/$f não está no rootfs (confira BR2_PACKAGE_HOSTAPD / BR2_PACKAGE_DNSMASQ)"
done
[ -x "$T/usr/sbin/iw" ] || [ -x "$T/usr/bin/iw" ] \
  || die "o iw não está no rootfs (BR2_PACKAGE_IW)"

# 2) O hostapd.conf da imagem tem de ser o NOSSO. O pacote hostapd instala um
#    hostapd.conf de exemplo em /etc; se a cópia do overlay não acontecer, a
#    imagem fica com o exemplo e o AP sobe com outro SSID — ou não sobe.
for linha in 'ssid=TP9-GRUPO03' 'driver=nl80211' 'wpa=2'; do
  grep -qxF "$linha" "$T/etc/hostapd.conf" \
    || die "o /etc/hostapd.conf da imagem está sem \"$linha\" — o overlay sobrescreveu o exemplo do pacote?"
done
grep -qxF 'dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h' "$T/etc/dnsmasq.conf" \
  || die "o /etc/dnsmasq.conf da imagem está sem a faixa DHCP exigida pelo enunciado"

# 3) Um único script inicia o AP. O pacote dnsmasq instala um S80dnsmasq que,
#    com o nosso /etc/dnsmasq.conf presente, subiria uma segunda instância; o
#    post-build.sh do TP o remove.
[ -x "$T/etc/init.d/S70tp-ap" ] || die "/etc/init.d/S70tp-ap não está no rootfs ou não é executável"
[ ! -e "$T/etc/init.d/S80dnsmasq" ] \
  || die "o S80dnsmasq do pacote dnsmasq continua no rootfs: o dnsmasq subiria duas vezes.
  O post-build.sh do TP rodou? Confira BR2_ROOTFS_POST_BUILD_SCRIPT no .config."

# 4) O brcmfmac é módulo e nada o carrega sozinho (devtmpfs puro, sem mdev nem
#    eudev). Quem o carrega é o S11modules, lendo /etc/modules-load.d.
grep -qxF 'brcmfmac' "$T/etc/modules-load.d/tp.conf" \
  || die "/etc/modules-load.d/tp.conf não lista o brcmfmac — a wlan0 não vai existir no boot"
for m in cfg80211 mac80211 brcmutil brcmfmac; do
  find "$T/lib/modules/$KVER" -name "$m.ko*" | grep -q . \
    || die "o módulo $m não está em /lib/modules/$KVER"
done
grep -q 'brcmfmac' "$T/lib/modules/$KVER/modules.dep" \
  || die "brcmfmac não aparece em modules.dep — o modprobe do S11modules não vai encontrá-lo"
# O brcmfmac 6.12 separa o código por fabricante e carrega o submódulo certo em
# tempo de execução, por request_module("brcmfmac-%s"). Qual deles é o do 43455
# está na tabela SDIO do driver, em bcmsdh.c:
#   BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43455, WCC)
# ou seja, WCC — apesar de o FIRMWARE vir do diretório cypress/ do
# linux-firmware. São coisas diferentes e é fácil trocar uma pela outra.
find "$T/lib/modules/$KVER" -name 'brcmfmac-wcc.ko*' | grep -q . \
  || die "falta o submódulo brcmfmac-wcc, que é o que a tabela SDIO associa ao 43455"

# 5) O firmware. O driver pede brcm/brcmfmac43455-sdio.{bin,clm_blob}, que no
#    linux-firmware são symlinks para ../cypress/cyfmac43455-sdio.*; o pacote só
#    cria o link se o alvo existir, e em silêncio se não. O -f segue o link, ou
#    seja, confere que o arquivo apontado está lá de verdade.
FW_BRCM="$T/lib/firmware/brcm"
for f in brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob 'brcmfmac43455-sdio.raspberrypi,4-model-b.txt'; do
  [ -f "$FW_BRCM/$f" ] \
    || die "falta o firmware /lib/firmware/brcm/$f (sem ele a wlan0 não existe).
  Confira BR2_PACKAGE_LINUX_FIRMWARE_BRCM_BCM43XXX e o symlink para ../cypress/."
done
for f in regulatory.db regulatory.db.p7s; do
  [ -f "$T/lib/firmware/$f" ] || die "falta /lib/firmware/$f (BR2_PACKAGE_WIRELESS_REGDB)"
done

# 6) O kernel tem a pilha sem fio. Estes vêm do defconfig da Pi, não de um
#    fragment nosso: se um dia saírem, o sintoma seria a wlan0 não aparecer.
for o in CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_BRCMFMAC; do
  grep -qE "^$o=[ym]$" "$OUT_DIR/build/linux-custom/.config" \
    || die "o kernel da imagem está sem $o"
done
# A base de que tudo neste TP depende: sem MODULES não há como carregar o
# driver; sem GPIOLIB e OF o probe do hcsr04 nunca é chamado; sem DEVTMPFS_MOUNT
# o /dev fica vazio e nem o console se comporta. Vêm do defconfig da Pi, então o
# risco não é configurá-los errado: é alguém desligar um deles sem perceber.
for o in CONFIG_MODULES CONFIG_GPIOLIB CONFIG_OF CONFIG_DEVTMPFS_MOUNT; do
  grep -qE "^$o=y$" "$OUT_DIR/build/linux-custom/.config" \
    || die "o kernel da imagem está sem $o=y"
done

# Um serviço, um script. O pacote dnsmasq já teve o seu removido pelo
# post-build; se um dia o hostapd ganhar um script no Buildroot, ele subiria
# junto com o S70tp-ap e os dois disputariam a wlan0.
DUPLICADOS="$(ls "$T"/etc/init.d/*hostapd* "$T"/etc/init.d/*dnsmasq* 2>/dev/null || true)"
[ -z "$DUPLICADOS" ] \
  || die "há scripts de init próprios de hostapd/dnsmasq no rootfs:
$DUPLICADOS
  Quem sobe os dois é o S70tp-ap; remova o duplicado no post-build.sh."

# 7) Os dois arquivos de configuração passam pelo parser dos programas que vão
#    lê-los — com os binários aarch64 da própria imagem, via binfmt/qemu. É o
#    mais perto de testar o AP que dá para chegar sem a placa.
# O timeout existe porque estes binários rodam traduzidos: se algum ficar
# esperando um recurso que o host não tem, o build não pode travar por isso.
if [ -x "$T/usr/sbin/dnsmasq" ] && QEMU_LD_PREFIX="$T" timeout 20 "$T/usr/sbin/dnsmasq" --version >/dev/null 2>&1; then
  DNSMASQ_TESTE="$(QEMU_LD_PREFIX="$T" timeout 20 "$T/usr/sbin/dnsmasq" --test -C "$T/etc/dnsmasq.conf" 2>&1)" \
    || die "o dnsmasq do alvo recusou o /etc/dnsmasq.conf:
$DNSMASQ_TESTE"
  HOSTAPD_TESTE="$(QEMU_LD_PREFIX="$T" timeout 20 "$T/usr/sbin/hostapd" "$T/etc/hostapd.conf" 2>&1 || true)"
  # O hostapd não tem modo "só testar": ele lê o arquivo, depois tenta abrir a
  # interface (que não existe no host). Erro de sintaxe aparece como "Line N:"
  # antes disso.
  if echo "$HOSTAPD_TESTE" | grep -qE '^Line [0-9]+:|Invalid configuration'; then
    die "o hostapd do alvo recusou o /etc/hostapd.conf:
$(echo "$HOSTAPD_TESTE" | grep -E '^Line [0-9]+:|Invalid configuration')"
  fi
  # Mostra onde o hostapd parou. Tem de ser DEPOIS de ler o arquivo — numa
  # falha de interface ou de driver, não numa linha do .conf. Sem imprimir
  # isto, um hostapd que abortasse antes de ler o arquivo deixaria a
  # conferência passar sem conferir nada.
  echo "$HOSTAPD_TESTE" | sed 's/^/  hostapd: /' | tail -3
  info "hostapd.conf e dnsmasq.conf aceitos pelos binários aarch64 da imagem (binfmt) ✔"
else
  warn "não deu para rodar os binários do alvo no host (binfmt/qemu-aarch64 ausente): os arquivos de configuração do AP não foram testados."
fi

info "Wi-Fi AP: hostapd, dnsmasq e iw na imagem, firmware do BCM43455 presente, brcmfmac no modules-load.d, S80dnsmasq removido ✔"

load_env
# A espera pelo link da eth0 precisa sobreviver à cópia do overlay: sem ela a
# interface pode ficar sem IP no boot.
grep -q 'wait-delay' "$T/etc/network/interfaces" \
  || die "/etc/network/interfaces está sem a espera pelo link da eth0 (wait-delay)"
# O usuário é criado ao gerar a imagem, então a conferência é feita dentro dela.
DEBUGFS="$OUT_DIR/host/sbin/debugfs"
ROOTFS_EXT4="$OUT_DIR/images/rootfs.ext4"
if [ -x "$DEBUGFS" ] && [ -f "$ROOTFS_EXT4" ]; then
  IMG_PASSWD="$("$DEBUGFS" -R 'cat /etc/passwd' "$ROOTFS_EXT4" 2>/dev/null)"
  IMG_GROUP="$("$DEBUGFS" -R 'cat /etc/group' "$ROOTFS_EXT4" 2>/dev/null)"
  echo "$IMG_PASSWD" | grep -q "^$USUARIO:" \
    || die "usuário $USUARIO não está em /etc/passwd dentro de images/rootfs.ext4
  (confira board/tp/rpi4/users_table.txt e rode ./scripts/02-configure.sh)"
  echo "$IMG_GROUP" | grep -q "^docker:.*$USUARIO" \
    || die "usuário $USUARIO não está no grupo docker dentro de images/rootfs.ext4"
  info "usuário $USUARIO e grupo docker conferidos DENTRO do rootfs.ext4 ✔"

  # Modo errado = script que não roda no boot, e o rootfs-overlay não carrega
  # permissão de quem o copiou. Conferir dentro da imagem, e não em target/,
  # porque é a imagem que vai para o cartão.
  for arq in etc/init.d/S55hcsr04 etc/init.d/S70tp-ap etc/init.d/S99tp-app usr/bin/tp-evidencias; do
    MODO="$("$DEBUGFS" -R "stat /$arq" "$ROOTFS_EXT4" 2>/dev/null \
      | sed -n 's/.*Mode: *0*\([0-7]\{3,4\}\).*/\1/p' | head -1)"
    [ "$MODO" = "755" ] \
      || die "/$arq está com modo ${MODO:-?} dentro da imagem, esperado 755 — rode ./scripts/02-configure.sh"
  done
  info "os quatro executáveis do TP estão 0755 DENTRO da imagem ✔"

  # Evidência do boot, lida da imagem: é o que permite mostrar a sequência sem
  # ter a placa ligada.
  { echo "# Lido de images/rootfs.ext4 com debugfs, sem montar a imagem."
    echo
    echo "--- /etc/init.d (ordem em que o rcS executa) ---"
    "$DEBUGFS" -R 'ls -l /etc/init.d' "$ROOTFS_EXT4" 2>/dev/null \
      | awk '{print $NF}' | grep -E '^(S|rc)' | sort
    echo
    echo "--- /etc/modules-load.d/tp.conf (módulos carregados pelo S11modules) ---"
    "$DEBUGFS" -R 'cat /etc/modules-load.d/tp.conf' "$ROOTFS_EXT4" 2>/dev/null \
      | grep -v '^#' | grep -v '^$'
    echo
    echo "--- docker run do S99tp-app ---"
    "$DEBUGFS" -R 'cat /etc/init.d/S99tp-app' "$ROOTFS_EXT4" 2>/dev/null \
      | sed -n '/docker run/,/IMAGE/p'
  } > "$EVID_BUILD_DIR/boot-na-imagem.txt"
  info "sequência de boot registrada em evidence/build/boot-na-imagem.txt"
  mkdir -p "$EVID_BUILD_DIR"
  { echo "# /etc/passwd e /etc/group lidos de images/rootfs.ext4 com debugfs"; echo
    echo "--- /etc/passwd ---"; echo "$IMG_PASSWD"
    echo; echo "--- /etc/group ---"; echo "$IMG_GROUP"
  } > "$EVID_BUILD_DIR/usuarios-na-imagem.txt"
else
  warn "não achei $DEBUGFS ou $ROOTFS_EXT4 — não deu para conferir o usuário dentro da imagem."
fi

# --- Checagens que evitam descobrir o problema só na Pi -------------------
# 1) O kernel ficou com tudo que o Docker precisa? Um recurso pode acabar de
#    fora sem aviso, e isso só apareceria na Raspberry.
KCONF="$OUT_DIR/build/linux-custom/.config"
CHECKCFG="$(ls -d "$OUT_DIR"/build/docker-engine-*/contrib/check-config.sh 2>/dev/null | head -1 || true)"
if [ -r "$KCONF" ] && [ -r "${CHECKCFG:-/nonexistent}" ]; then
  info "Conferindo o kernel com o check-config.sh do próprio Docker..."
  mkdir -p "$EVID_BUILD_DIR"
  CONFIG="$KCONF" bash "$CHECKCFG" "$KCONF" > "$EVID_BUILD_DIR/kernel-check-config.txt" 2>&1 || true
  # Só a seção "Generally Necessary" importa: em "Optional Features" é normal
  # faltar btrfs, zfs, apparmor, IPVS etc., que este TP não usa.
  NECESSARIO="$(sed 's/\x1b\[[0-9;]*m//g' "$EVID_BUILD_DIR/kernel-check-config.txt" \
    | sed -n '/^Generally Necessary/,/^Optional Features/p' | grep -i 'missing' || true)"
  if [ -n "$NECESSARIO" ]; then
    warn "o check-config.sh apontou recursos OBRIGATÓRIOS ausentes no kernel:"
    echo "$NECESSARIO" >&2
    warn "se algum for obrigatório, acrescente em linux-docker.fragment e rode:
  make -C buildroot O=../output-rpi4 BR2_EXTERNAL=../br2-external linux-reconfigure && ./scripts/04-build-image.sh"
  else
    info "kernel com todos os recursos obrigatórios do Docker ✔"
  fi
  info "Saída completa em evidence/build/kernel-check-config.txt"
else
  warn "não achei o check-config.sh do docker-engine ou o .config do kernel — pulando essa checagem."
fi

# 2) Sobra espaço no rootfs para o "docker load" do 1º boot?
#    O load extrai as camadas em /var/lib/docker, no MESMO ext4 de 1024M.
ROOTFS_MB="$(sed -n 's/^BR2_TARGET_ROOTFS_EXT2_SIZE="\([0-9]*\)M"$/\1/p' "$OUT_DIR/.config")"
USED_MB="$(du -sm "$T" | cut -f1)"
TAR_MB="$(du -m "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" | cut -f1)"
if [ -n "$ROOTFS_MB" ]; then
  FREE_MB=$(( ROOTFS_MB - USED_MB ))
  info "rootfs: ${ROOTFS_MB}M total, ${USED_MB}M ocupados, ${FREE_MB}M livres (o docker load vai querer ~${TAR_MB}M)"
  if [ "$FREE_MB" -lt "$TAR_MB" ]; then
    warn "pouco espaço livre no rootfs para o 'docker load' do 1º boot.
  Aumente BR2_TARGET_ROOTFS_EXT2_SIZE em br2-external/board/tp/rpi4/buildroot.fragment
  (ex.: 2048M), rode ./scripts/02-configure.sh e este script de novo."
  fi
fi

record_hash "$IMG" "sdcard.img"
checkpoint "imagem pronta em ${MIN} min: output-rpi4/images/sdcard.img
  Rootfs conferido: banner, rede, S60dockerd, o S99 do container, $IMAGE_TAR_NAME, docker, curl, usuário $USUARIO.
  HC-SR04 e Wi-Fi AP conferidos (driver, overlay, firmware, hostapd/dnsmasq).
  Próximo: ./scripts/05-flash-sd.sh"
