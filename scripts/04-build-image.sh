#!/usr/bin/env bash
# 04 — Compila a imagem Linux completa (guia Aula 10, Etapa 10.3/10.4).
# 1º build: de 1 a várias horas (baixa toolchain, kernel, Go, Docker...).
# Se cair no meio (internet, energia), é só rodar de novo: ele continua.
# Log completo em output-rpi4/build.log.
source "$(dirname "$0")/lib.sh"
require_not_root

[ -f "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" ] \
  || die "falta rootfs-overlay/opt/docker/$IMAGE_TAR_NAME — rode ./scripts/03-build-flask-image.sh primeiro"
[ -x "$OVERLAY_DIR/etc/init.d/S99flask-tp" ] \
  || die "S99flask-tp sem permissão de execução — rode ./scripts/02-configure.sh"

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
for f in etc/issue etc/network/interfaces etc/init.d/S60dockerd etc/init.d/S99flask-tp \
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

# --- HC-SR04: driver, overlay e partição de boot -------------------------
# Nada disto dá para testar sem a placa, então cada peça é conferida aqui.

# 1. O .dtbo versionado tem de corresponder ao .dts. Sem esta conferência, um
#    .dts editado e um .dtbo esquecido passam despercebidos até o boot.
DTC="$OUT_DIR/host/bin/dtc"
if [ -x "$DTC" ]; then
  DTBO_TMP="$(mktemp)"
  "$DTC" -@ -I dts -O dtb -o "$DTBO_TMP" "$BOARD_DIR/hcsr04-overlay.dts" 2>/dev/null \
    || die "hcsr04-overlay.dts não compila"
  cmp -s "$DTBO_TMP" "$BOARD_DIR/hcsr04.dtbo" \
    || { rm -f "$DTBO_TMP"; die "hcsr04.dtbo está desatualizado em relação ao .dts.
  Regere com: $DTC -@ -I dts -O dtb -o $BOARD_DIR/hcsr04.dtbo $BOARD_DIR/hcsr04-overlay.dts"; }
  rm -f "$DTBO_TMP"
fi

# 2. O módulo precisa estar no rootfs e o vermagic bater com o kernel desta
#    imagem. Módulo compilado contra outro kernel é o erro clássico, e só
#    apareceria como modprobe falhando no boot.
KVER="$(ls "$T/lib/modules" 2>/dev/null | head -1)"
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
for linha in 'kernel=Image' 'arm_64bit=1' 'dtoverlay=hcsr04'; do
  grep -qxF "$linha" "$FW/config.txt" \
    || die "o config.txt da imagem está sem \"$linha\".
  Se você mudou config_tp.txt, o pacote precisa ser reinstalado:
    make -C buildroot O=../output-rpi4 BR2_EXTERNAL=../br2-external rpi-firmware-reinstall all"
done

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
  Rootfs conferido: banner, rede, S60dockerd, S99flask-tp, flask-tp.tar, docker, curl, usuário $USUARIO.
  Próximo: ./scripts/05-flash-sd.sh"
