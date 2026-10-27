#!/usr/bin/env bash
# 01 — Baixa e extrai o Buildroot na versão do tp8.env para ./buildroot
# (guia Aula 10, Etapa 3.1). A pasta buildroot/ NÃO vai pro Git: ela é
# reconstruída por este script; a versão fica registrada no README.
source "$(dirname "$0")/lib.sh"
require_not_root
load_env

V="$BUILDROOT_VERSION"

if [ -f "$BR_DIR/Makefile" ]; then
  HAVE="$(make -s -C "$BR_DIR" --no-print-directory print-version 2>/dev/null || true)"
  if [ "$HAVE" = "$V" ]; then
    checkpoint "Buildroot $V já está em $BR_DIR — nada a fazer."
    exit 0
  fi
  die "já existe buildroot/ na versão '$HAVE' (tp8.env pede $V). Apague a pasta buildroot/ e output-rpi4/ e rode de novo."
fi

cd "$TP8_ROOT"
TARBALL="buildroot-$V.tar.xz"
info "Baixando $TARBALL de buildroot.org..."
if wget -c "https://buildroot.org/downloads/$TARBALL"; then
  tar -xf "$TARBALL"
  mv "buildroot-$V" buildroot
  rm -f "$TARBALL"
else
  warn "buildroot.org falhou — tentando o espelho oficial no GitHub (tag $V)"
  git clone --depth 1 --branch "$V" https://github.com/buildroot/buildroot.git buildroot
fi

HAVE="$(make -s -C "$BR_DIR" --no-print-directory print-version)"
[ "$HAVE" = "$V" ] || die "versão extraída ($HAVE) diferente da pedida ($V)"
checkpoint "Buildroot $HAVE em $BR_DIR"
