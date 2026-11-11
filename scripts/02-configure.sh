#!/usr/bin/env bash
# 02 — Gera a configuração do TP de forma reproduzível.
#   1. Aplica o tp.env: /etc/issue, users_table.txt, hostname e senha do root
#   2. Carrega a raspberrypi4_64_defconfig oficial            (Aula 10, 3.2)
#   3. Mescla buildroot.fragment + identidade.fragment        (= o que se faria no menuconfig, Etapas 5 e 6)
#   4. Confere se as opções essenciais ficaram ativas
#   5. Salva br2-external/configs/tp_rpi4_defconfig        (Aula 10, 10.1)
#   6. Teste de reprodutibilidade: apaga o .config e recarrega da defconfig salva (Aula 10, 10.2)
# Rode de novo sempre que mudar o tp.env ou algum fragment.
source "$(dirname "$0")/lib.sh"
require_not_root
load_env

# --- 0. Normaliza finais de linha e permissões de execução ----------------
info "Normalizando finais de linha e permissões do overlay e scripts..."
while IFS= read -r -d '' f; do
  if grep -Iq . "$f" 2>/dev/null && grep -q $'\r' "$f"; then
    sed -i 's/\r$//' "$f"; warn "CRLF removido de ${f#"$TP_ROOT"/}"
  fi
done < <(find "$EXT_DIR" "$FLASK_DIR" "$TP_ROOT/scripts" -type f ! -name '*.tar' -print0)
chmod +x "$OVERLAY_DIR"/etc/init.d/S* \
  "$OVERLAY_DIR/usr/bin/tp-evidencias" "$BOARD_DIR/post-image.sh" "$BOARD_DIR/post-build.sh" \
  "$TP_ROOT"/scripts/*.sh

# --- 1. Identidade do sistema a partir do tp.env -------------------------
info "Gerando /etc/issue (banner antes do login)..."
{
  echo "================================================"
  echo " TP Aula 8 - Sistemas Embarcados - UNISANTA"
  echo " Raspberry Pi 4 + Buildroot + Docker + Flask"
  echo " Grupo: $GRUPO"
  for membro in "${INTEGRANTES[@]}"; do echo "  - $membro"; done
  echo "================================================"
  echo
} > "$OVERLAY_DIR/etc/issue"

info "Gerando users_table.txt (usuário '$USUARIO' no grupo docker)..."
# formato: usuario uid grupo gid senha home shell grupos-extras comentario
#  -2 = UID/GID automático na faixa de usuário comum (1000+); '=' = senha em texto claro
echo "$USUARIO -2 $USUARIO -2 =$SENHA /home/$USUARIO /bin/sh docker Aluno_TP_$GRUPO" \
  > "$BOARD_DIR/users_table.txt"

info "Gerando identidade.fragment (hostname e senha do root)..."
{
  echo "# Gerado por scripts/02-configure.sh a partir do tp.env"
  echo "BR2_TARGET_GENERIC_HOSTNAME=\"$HOSTNAME_RPI\""
  echo "BR2_TARGET_GENERIC_ISSUE=\"TP Aula 8 - Sistemas Embarcados - UNISANTA - Grupo $GRUPO\""
  if [ -n "$ROOT_SENHA" ]; then
    echo "BR2_TARGET_GENERIC_ROOT_PASSWD=\"$ROOT_SENHA\""
  fi
} > "$BOARD_DIR/identidade.fragment"

# --- 2. Base oficial da Raspberry Pi 4 ------------------------------------
info "Carregando raspberrypi4_64_defconfig..."
br_make raspberrypi4_64_defconfig

# --- 3. Mescla as opções do TP --------------------------------------------
info "Mesclando fragments do TP..."
if ! LOG="$(KCONFIG_CONFIG="$OUT_DIR/.config" "$BR_DIR/support/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
      "$OUT_DIR/.config" "$BOARD_DIR/buildroot.fragment" "$BOARD_DIR/identidade.fragment" 2>&1)"; then
  echo "$LOG"; die "merge_config.sh falhou"
fi
# Os avisos "override: reassigning to symbol" são esperados: é o fragment
# sobrescrevendo a defconfig da Pi, então são filtrados da saída.
if ! LOG="$(br_make olddefconfig 2>&1)"; then
  echo "$LOG"; die "make olddefconfig falhou"
fi
echo "$LOG" | grep -v 'warning: override: reassigning to symbol' || true

# --- 4. Conferência -------------------------------------------------------
check() {
  grep -qxF "$1" "$OUT_DIR/.config" || die "opção não ficou ativa no .config: $1
  (provavelmente dependência não satisfeita — abra 'make menuconfig' e procure com '/')"
}
check 'BR2_aarch64=y'
check 'BR2_PACKAGE_DOCKER_ENGINE=y'
check 'BR2_PACKAGE_DOCKER_CLI=y'
check 'BR2_PACKAGE_CONTAINERD=y'
check 'BR2_PACKAGE_IPTABLES=y'
check 'BR2_PACKAGE_CGROUPFS_V2_MOUNT=y'
check 'BR2_PACKAGE_LIBCURL_CURL=y'
check 'BR2_TARGET_ROOTFS_EXT2_SIZE="1024M"'
check "BR2_TARGET_GENERIC_HOSTNAME=\"$HOSTNAME_RPI\""
# shellcheck disable=SC2016  # $(BR2_EXTERNAL_TP_PATH) é literal do Buildroot, não do shell
check 'BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/rootfs-overlay"'
# shellcheck disable=SC2016
check 'BR2_ROOTFS_USERS_TABLES="$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/users_table.txt"'
# shellcheck disable=SC2016
check 'BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/linux-docker.fragment"'
check 'BR2_PACKAGE_HCSR04_DRIVER=y'
# O pacote do driver depende do kernel (depends on BR2_LINUX_KERNEL no
# Config.in). Se o kernel saísse da configuração, o símbolo acima some sem
# avisar, então conferir os dois deixa o erro claro.
check 'BR2_LINUX_KERNEL=y'
# shellcheck disable=SC2016
check 'BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE="$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/config_tp.txt"'
# shellcheck disable=SC2016
check 'BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/post-image.sh board/raspberrypi4-64/post-image.sh"'

# --- Wi-Fi AP (TP 9) ------------------------------------------------------
check 'BR2_PACKAGE_HOSTAPD=y'
# O hostapd sem driver não serve para nada: o nl80211 é a interface de kernel
# que o brcmfmac expõe. Sem esta opção o pacote compila e não abre a wlan0.
check 'BR2_PACKAGE_HOSTAPD_DRIVER_NL80211=y'
check 'BR2_PACKAGE_DNSMASQ=y'
check 'BR2_PACKAGE_IW=y'
check 'BR2_PACKAGE_LINUX_FIRMWARE_BRCM_BCM43XXX=y'
# Esta é selecionada pela de cima e traz os binários que o driver realmente
# pede (cyfmac43455-sdio.bin e .clm_blob). Conferir as duas deixa claro que o
# select funcionou, em vez de descobrir no boot que falta firmware.
check 'BR2_PACKAGE_LINUX_FIRMWARE_CYPRESS_CYW43XXX=y'
check 'BR2_PACKAGE_WIRELESS_REGDB=y'
# shellcheck disable=SC2016
check 'BR2_ROOTFS_POST_BUILD_SCRIPT="board/raspberrypi4-64/post-build.sh $(BR2_EXTERNAL_TP_PATH)/board/tp/rpi4/post-build.sh"'

# O SSID e a faixa DHCP são cobrados pelo enunciado; o canal e o modo definem a
# banda. Conferir aqui evita descobrir na apresentação que um sed de rename
# passou por cima do SSID.
for linha in 'interface=wlan0' 'driver=nl80211' 'ssid=TP9-GRUPO03' 'hw_mode=g' 'channel=6' 'wpa=2'; do
  grep -qxF "$linha" "$OVERLAY_DIR/etc/hostapd.conf" \
    || die "hostapd.conf está sem a linha \"$linha\""
done
for linha in 'interface=wlan0' 'dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h'; do
  grep -qxF "$linha" "$OVERLAY_DIR/etc/dnsmasq.conf" \
    || die "dnsmasq.conf está sem a linha \"$linha\""
done
# WPA2 exige de 8 a 63 caracteres. Fora disso o hostapd recusa o arquivo e o AP
# não sobe — erro fácil de cometer ao trocar a senha do laboratório.
SENHA_WIFI="$(sed -n 's/^wpa_passphrase=//p' "$OVERLAY_DIR/etc/hostapd.conf")"
[ "${#SENHA_WIFI}" -ge 8 ] && [ "${#SENHA_WIFI}" -le 63 ] \
  || die "wpa_passphrase tem ${#SENHA_WIFI} caracteres; o WPA2 aceita de 8 a 63"
# Sem esta linha a wlan0 não existe: brcmfmac é módulo e nada o carrega sozinho.
grep -qxF 'brcmfmac' "$OVERLAY_DIR/etc/modules-load.d/tp.conf" \
  || die "etc/modules-load.d/tp.conf não lista o brcmfmac"

# O config.txt que vai para a placa tem de ser o de 64 bits. O guia do TP manda
# copiar config_4.txt, que é a variante de 32 bits: com ela a imagem não dá
# boot. Esta conferência existe para impedir que alguém "siga o guia" e quebre.
for linha in 'kernel=Image' 'arm_64bit=1' 'dtoverlay=hcsr04'; do
  grep -qxF "$linha" "$BOARD_DIR/config_tp.txt" \
    || die "config_tp.txt está sem a linha \"$linha\""
done

# --- 5. Salva a defconfig do TP -------------------------------------------
br_make BR2_DEFCONFIG="$EXT_DIR/configs/$DEFCONFIG_NAME" savedefconfig
[ -s "$EXT_DIR/configs/$DEFCONFIG_NAME" ] || die "savedefconfig não gerou $DEFCONFIG_NAME"

# --- 5b. Cópia da defconfig em buildroot-config/ e arquivo VERSION --------
# A estrutura pedida no TP tem um buildroot-config/ separado. Para que as duas
# cópias não divirjam, esta aqui é GERADA a cada execução a partir da que o
# savedefconfig acabou de escrever; a canônica é a de br2-external/configs/.
mkdir -p "$BRCFG_DIR"
cp "$EXT_DIR/configs/$DEFCONFIG_NAME" "$BRCFG_DIR/$DEFCONFIG_NAME"

{
  echo "projeto: TP Aula 8 - Buildroot + Docker + Flask - Raspberry Pi 4"
  echo "versao: $VERSAO_PROJETO"
  echo "grupo: $GRUPO"
  echo "buildroot: $BUILDROOT_VERSION"
  echo "placa: Raspberry Pi 4 Model B (aarch64)"
  echo "defconfig: br2-external/configs/$DEFCONFIG_NAME"
  echo "hostname: $HOSTNAME_RPI"
  echo "usuario: $USUARIO"
  echo "container: $IMAGE_REF"
  echo "porta: 5000"
} > "$TP_ROOT/VERSION"
info "buildroot-config/$DEFCONFIG_NAME e VERSION atualizados"

# --- 6. Teste de reprodutibilidade (Aula 10, 10.2) ------------------------
cp "$OUT_DIR/.config" "$OUT_DIR/.config.antes"
rm -f "$OUT_DIR/.config"
br_make "$DEFCONFIG_NAME"
# BR2_DEFCONFIG só registra de onde o .config foi carregado; muda por definição.
if diff -q <(grep -v '^BR2_DEFCONFIG=' "$OUT_DIR/.config.antes") \
           <(grep -v '^BR2_DEFCONFIG=' "$OUT_DIR/.config") >/dev/null; then
  rm -f "$OUT_DIR/.config.antes"
else
  die "recarregar $DEFCONFIG_NAME não reproduziu o mesmo .config (diff $OUT_DIR/.config.antes $OUT_DIR/.config)"
fi

if [ ! -f "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" ]; then
  warn "ainda falta o $IMAGE_TAR_NAME no overlay — rode ./scripts/03-build-flask-image.sh antes do 04."
fi

checkpoint "configuração OK e reproduzível.
  defconfig salva: br2-external/configs/$DEFCONFIG_NAME
  hostname: $HOSTNAME_RPI | usuário: $USUARIO (grupo docker) | rootfs: 1024M
  Para inspecionar no menu:
    make -C buildroot O=../output-rpi4 BR2_EXTERNAL=../br2-external menuconfig"
