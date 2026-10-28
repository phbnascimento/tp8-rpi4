#!/usr/bin/env bash
# 02 — Gera a configuração do TP8 de forma reproduzível.
#   1. Aplica o tp8.env: /etc/issue, users_table.txt, hostname e senha do root
#   2. Carrega a raspberrypi4_64_defconfig oficial            (Aula 10, 3.2)
#   3. Mescla buildroot.fragment + identidade.fragment        (= o que se faria no menuconfig, Etapas 5 e 6)
#   4. Confere se as opções essenciais ficaram ativas
#   5. Salva br2-external/configs/tp8_rpi4_defconfig        (Aula 10, 10.1)
#   6. Teste de reprodutibilidade: apaga o .config e recarrega da defconfig salva (Aula 10, 10.2)
# Rode de novo sempre que mudar o tp8.env ou algum fragment.
source "$(dirname "$0")/lib.sh"
require_not_root
load_env

# --- 0. Normaliza finais de linha e permissões de execução ----------------
info "Normalizando finais de linha e permissões do overlay e scripts..."
while IFS= read -r -d '' f; do
  if grep -Iq . "$f" 2>/dev/null && grep -q $'\r' "$f"; then
    sed -i 's/\r$//' "$f"; warn "CRLF removido de ${f#"$TP8_ROOT"/}"
  fi
done < <(find "$EXT_DIR" "$FLASK_DIR" "$TP8_ROOT/scripts" -type f ! -name '*.tar' -print0)
chmod +x "$OVERLAY_DIR/etc/init.d/S99flask-tp8" "$OVERLAY_DIR/usr/bin/tp8-evidencias" "$TP8_ROOT"/scripts/*.sh

# --- 1. Identidade do sistema a partir do tp8.env -------------------------
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
echo "$USUARIO -2 $USUARIO -2 =$SENHA /home/$USUARIO /bin/sh docker Aluno_TP8_$GRUPO" \
  > "$BOARD_DIR/users_table.txt"

info "Gerando identidade.fragment (hostname e senha do root)..."
{
  echo "# Gerado por scripts/02-configure.sh a partir do tp8.env"
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
info "Mesclando fragments do TP8..."
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
# shellcheck disable=SC2016  # $(BR2_EXTERNAL_TP8_PATH) é literal do Buildroot, não do shell
check 'BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/rootfs-overlay"'
# shellcheck disable=SC2016
check 'BR2_ROOTFS_USERS_TABLES="$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/users_table.txt"'
# shellcheck disable=SC2016
check 'BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/linux-docker.fragment"'

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
} > "$TP8_ROOT/VERSION"
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
