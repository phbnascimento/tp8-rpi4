#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis usadas pelos scripts que fazem source desta lib
# Funções e caminhos comuns a todos os scripts do TP8.
# Uso: source "$(dirname "$0")/lib.sh"

set -euo pipefail

TP8_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR_DIR="$TP8_ROOT/buildroot"
OUT_DIR="$TP8_ROOT/output-rpi4"
EXT_DIR="$TP8_ROOT/br2-external"
BOARD_DIR="$EXT_DIR/board/tp8/rpi4"
OVERLAY_DIR="$BOARD_DIR/rootfs-overlay"
FLASK_DIR="$TP8_ROOT/flask-app"
EVID_DIR="$TP8_ROOT/docs/evidence"
DEFCONFIG_NAME="tp8_rpi4_defconfig"

IMAGE_REF="flask-tp8:1.0"
IMAGE_TAR_NAME="flask-tp8.tar"

if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_WARN=$'\e[33m'; C_END=$'\e[0m'
else
  C_OK=""; C_ERR=""; C_INFO=""; C_WARN=""; C_END=""
fi

info()  { echo "${C_INFO}[TP8]${C_END} $*"; }
warn()  { echo "${C_WARN}[TP8] ATENÇÃO:${C_END} $*" >&2; }
die()   { echo "${C_ERR}[TP8] ERRO:${C_END} $*" >&2; exit 1; }
checkpoint() { echo; echo "${C_OK}[TP8] ✔ CHECKPOINT:${C_END} $*"; echo; }

# Carrega tp8.env removendo CRLF.
load_env() {
  local env_file="$TP8_ROOT/tp8.env"
  [ -f "$env_file" ] || die "tp8.env não encontrado em $TP8_ROOT"
  local tmp
  tmp="$(mktemp)"
  tr -d '\r' < "$env_file" > "$tmp"
  # shellcheck source=/dev/null
  source "$tmp"
  rm -f "$tmp"

  : "${GRUPO:?defina GRUPO no tp8.env}"
  : "${HOSTNAME_RPI:?defina HOSTNAME_RPI no tp8.env}"
  : "${USUARIO:?defina USUARIO no tp8.env}"
  : "${SENHA:?defina SENHA no tp8.env}"
  : "${BUILDROOT_VERSION:?defina BUILDROOT_VERSION no tp8.env}"
  ROOT_SENHA="${ROOT_SENHA:-}"

  [[ "$HOSTNAME_RPI" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "HOSTNAME_RPI inválido: use só minúsculas, números e hífen"
  [[ "$USUARIO" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "USUARIO inválido: use minúsculas, números, _ ou -"
  [ "$USUARIO" != "root" ] || die "USUARIO não pode ser root"
  [[ "$SENHA" =~ ^[^[:space:]:]+$ ]] \
    || die "SENHA não pode ter espaços nem ':'"
  if [ -n "$ROOT_SENHA" ]; then
    [[ "$ROOT_SENHA" =~ ^[^[:space:]\"]+$ ]] \
      || die "ROOT_SENHA não pode ter espaços nem aspas"
  fi
}

# make do Buildroot sempre com O= e BR2_EXTERNAL= (padrão do guia da Aula 10).
br_make() {
  [ -d "$BR_DIR" ] || die "Buildroot não encontrado. Rode ./scripts/01-fetch-buildroot.sh"
  make -C "$BR_DIR" O="$OUT_DIR" BR2_EXTERNAL="$EXT_DIR" "$@"
}

require_not_root() {
  [ "$(id -u)" -ne 0 ] || die "não rode este script como root/sudo (o Buildroot não deve rodar como root)"
}

# Registra um hash em docs/evidence/hashes.txt (substitui linha antiga do mesmo arquivo).
record_hash() {
  local file="$1" label="$2" hash
  hash="$(sha256sum "$file" | awk '{print $1}')"
  mkdir -p "$EVID_DIR"
  touch "$EVID_DIR/hashes.txt"
  grep -v "  $label\$" "$EVID_DIR/hashes.txt" > "$EVID_DIR/hashes.txt.tmp" || true
  echo "$hash  $label" >> "$EVID_DIR/hashes.txt.tmp"
  mv "$EVID_DIR/hashes.txt.tmp" "$EVID_DIR/hashes.txt"
  info "SHA-256 $label = $hash  (salvo em docs/evidence/hashes.txt)"
}
