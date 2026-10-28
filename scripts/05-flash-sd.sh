#!/usr/bin/env bash
# 05 — Grava output-rpi4/images/sdcard.img no microSD (guia Aula 10, Etapa 11).
# PERIGO: dd sobrescreve o disco escolhido sem perguntar. Este script:
#   - lista os discos com lsblk e pede para você DIGITAR o dispositivo
#   - recusa o disco onde está o sistema (/) e discos não-removíveis sem confirmação extra
#   - pede para digitar o nome de novo antes de gravar
# Alternativa gráfica: Raspberry Pi Imager / balenaEtcher → "imagem personalizada" → sdcard.img
source "$(dirname "$0")/lib.sh"
require_not_root

IMG="$OUT_DIR/images/sdcard.img"
[ -f "$IMG" ] || die "não achei $IMG — rode ./scripts/04-build-image.sh"

# Guarda: a imagem PRECISA conter o tar do container. Um sdcard.img gerado antes
# do script 03 boota, faz login e sobe o dockerd, mas fica sem a aplicação Flask —
# e isso só se descobriria com a Pi na mesa.
DEBUGFS="$OUT_DIR/host/sbin/debugfs"
ROOTFS_EXT4="$OUT_DIR/images/rootfs.ext4"
if [ -x "$DEBUGFS" ] && [ -f "$ROOTFS_EXT4" ]; then
  if ! "$DEBUGFS" -R "stat /opt/docker/$IMAGE_TAR_NAME" "$ROOTFS_EXT4" 2>/dev/null | grep -q '^Inode:'; then
    die "a imagem não contém /opt/docker/$IMAGE_TAR_NAME: ela foi gerada sem o container.
  Rode ./scripts/03-build-flask-image.sh e depois ./scripts/04-build-image.sh antes de gravar."
  fi
  info "a imagem contém /opt/docker/$IMAGE_TAR_NAME ✔"
else
  warn "não deu para conferir se o tar do container está na imagem (debugfs/rootfs.ext4 ausentes)."
fi

echo
lsblk -d -o NAME,SIZE,MODEL,TRAN,RM,TYPE | grep -v ' loop\|^loop'
echo
echo "RM=1 indica mídia removível. O microSD costuma ser sdX (leitor USB) ou mmcblkX (leitor interno)."
read -r -p "Digite SÓ o nome do dispositivo do cartão (ex.: sdb ou mmcblk0): " DEV
DEV="${DEV#/dev/}"
[[ "$DEV" =~ ^(sd[a-z]+|mmcblk[0-9]+)$ ]] || die "nome inválido: '$DEV'"
[ -b "/dev/$DEV" ] || die "/dev/$DEV não existe"

ROOT_SRC="$(findmnt -n -o SOURCE /)"
ROOT_DISK="$(lsblk -n -o PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
[ "$DEV" != "$ROOT_DISK" ] || die "/dev/$DEV é o disco do SEU SISTEMA. Abortado."

RM="$(cat "/sys/block/$DEV/removable" 2>/dev/null || echo 0)"
SIZE_GB=$(( $(lsblk -b -d -n -o SIZE "/dev/$DEV") / 1000000000 ))
if [ "$RM" != "1" ] && [[ "$DEV" == sd* ]]; then
  warn "/dev/$DEV não está marcado como removível (alguns leitores USB são assim)."
fi
if [ "$SIZE_GB" -gt 256 ]; then
  die "/dev/$DEV tem ${SIZE_GB} GB — grande demais para ser o microSD. Abortado."
fi

echo
lsblk "/dev/$DEV"
echo
read -r -p "TUDO em /dev/$DEV (${SIZE_GB} GB) será APAGADO. Digite o nome de novo para confirmar: " CONF
[ "$CONF" = "$DEV" ] || die "confirmação não confere. Nada foi gravado."

info "Desmontando partições de /dev/$DEV..."
for p in $(lsblk -n -l -o NAME "/dev/$DEV" | tail -n +2); do
  sudo umount "/dev/$p" 2>/dev/null || true
done

info "Gravando $(du -h "$IMG" | cut -f1) em /dev/$DEV..."
sudo dd if="$IMG" of="/dev/$DEV" bs=4M status=progress conv=fsync
sync
checkpoint "cartão gravado. Ordem para ligar a Pi: microSD → cabo Ethernet → monitor/teclado → fonte por último."
