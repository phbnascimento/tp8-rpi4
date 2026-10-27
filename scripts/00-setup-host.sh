#!/usr/bin/env bash
# 00 — Prepara o PC Linux de build.
#   - dependências do Buildroot (guia Aula 10, Etapa 2.1)
#   - Docker + buildx no host (para construir a imagem ARM64 do Flask)
#   - emulação ARM64 via binfmt/QEMU (host x86_64)
# Suporta famílias Debian/Ubuntu (apt-get) e Arch/CachyOS (pacman).
# Pode rodar quantas vezes quiser. Usa sudo só onde precisa.
source "$(dirname "$0")/lib.sh"
require_not_root

# --- 0. Qual gerenciador de pacotes? --------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v pacman >/dev/null 2>&1; then
  PKG=pacman
else
  die "não achei apt-get nem pacman. Instale à mão: build-essential/base-devel, git wget cpio
  unzip rsync file bc bison flex openssl ncurses python3, docker e docker-buildx."
fi
info "Gerenciador de pacotes detectado: $PKG"

# --- 1. Dependências do Buildroot -----------------------------------------
info "Instalando dependências do Buildroot..."
case "$PKG" in
  apt)
    sudo apt-get update
    sudo apt-get install -y \
      build-essential git wget cpio unzip rsync file \
      bc bison flex libssl-dev libncurses-dev python3 \
      ca-certificates curl xz-utils
    ;;
  pacman)
    # base-devel já traz gcc, make, patch, bison, flex, which, pkgconf, texinfo...
    sudo pacman -S --needed --noconfirm \
      base-devel git wget cpio unzip rsync file \
      bc openssl ncurses python \
      ca-certificates curl xz
    ;;
esac

# --- 2. Docker + buildx ---------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  info "Docker não encontrado — instalando..."
  case "$PKG" in
    apt)
      sudo apt-get install -y docker.io
      sudo apt-get install -y docker-buildx || sudo apt-get install -y docker-buildx-plugin || \
        warn "não achei pacote do buildx; se o 'docker buildx' falhar, instale o Docker CE (docs.docker.com/engine/install/ubuntu)"
      ;;
    pacman)
      sudo pacman -S --needed --noconfirm docker docker-buildx
      ;;
  esac
else
  info "Docker já instalado: $(docker --version)"
  # O plugin buildx é pacote separado nas duas famílias.
  if ! docker buildx version >/dev/null 2>&1; then
    info "Plugin docker buildx ausente — instalando..."
    case "$PKG" in
      apt)    sudo apt-get install -y docker-buildx || sudo apt-get install -y docker-buildx-plugin ;;
      pacman) sudo pacman -S --needed --noconfirm docker-buildx ;;
    esac
  fi
fi

# --- 3. Daemon do Docker ativo --------------------------------------------
# No Debian/Ubuntu o pacote já habilita o serviço; no Arch/CachyOS não.
if ! docker info >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1; then
    info "Daemon do Docker não responde — habilitando docker.service no boot e iniciando..."
    sudo systemctl enable --now docker
  else
    die "o daemon do Docker não responde e este host não usa systemd. Inicie o dockerd à mão."
  fi
fi

# --- 4. Usuário no grupo docker (para não precisar de sudo no 03) ---------
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  warn "seu usuário entrou no grupo docker. FAÇA LOGOUT/LOGIN (ou rode 'newgrp docker') e rode este script de novo."
  exit 0
fi

docker info >/dev/null 2>&1 \
  || die "o daemon do Docker ainda não responde (veja 'systemctl status docker' e 'journalctl -u docker')."
docker buildx version >/dev/null 2>&1 || die "docker buildx não está disponível. Instale o plugin buildx e rode de novo."

# --- 5. Emulação ARM64 (binfmt/QEMU) --------------------------------------
# Host x86_64 precisa emular AArch64 para o 'docker buildx build --platform linux/arm64'.
if [ "$(uname -m)" != "aarch64" ]; then
  BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64
  if [ -r "$BINFMT" ] && grep -q '^enabled' "$BINFMT"; then
    info "Emulação ARM64 já registrada no host ($(awk '/^interpreter/{print $2}' "$BINFMT")) ✔"
  else
    info "Host $(uname -m): habilitando emulação ARM64 (binfmt/QEMU)..."
    docker run --privileged --rm tonistiigi/binfmt --install arm64
  fi
fi

# --- 6. Builder do buildx com linux/arm64 ---------------------------------
docker buildx create --name tp8builder --use >/dev/null 2>&1 || docker buildx use tp8builder
docker buildx inspect --bootstrap | grep -i 'platforms' || true
docker buildx inspect --bootstrap | grep -q 'linux/arm64' \
  || die "o builder não lista linux/arm64. Veja a seção 'exec format error' no ROTEIRO."

FREE_GB=$(df -BG --output=avail "$TP8_ROOT" | tail -1 | tr -dc '0-9')
if [ "${FREE_GB:-0}" -lt 30 ]; then
  warn "só ${FREE_GB}G livres em $TP8_ROOT. O build completo usa ~20-30 GB (toolchain, kernel, Go, Docker)."
fi

checkpoint "host pronto: dependências OK, docker $(docker --version | awk '{print $3}' | tr -d ,), buildx com linux/arm64, ${FREE_GB}G livres."
