#!/usr/bin/env bash
#
# Coloca o overlay do HC-SR04 na partição de boot.
#
# Por que um script, e não BR2_PACKAGE_RPI_FIRMWARE_EXTRA_FILES: aquela opção
# instala os arquivos na RAIZ de images/rpi-firmware/, enquanto o firmware da
# Raspberry procura os overlays em overlays/<nome>.dtbo. Dava para mudar isso
# com "overlay_prefix=" no config.txt, mas aí o dtoverlay=miniuart-bt, que a
# configuração oficial da placa já usa, deixaria de ser encontrado.
#
# Ordem importa: este script precisa rodar ANTES do post-image.sh da Raspberry,
# que é quem chama o genimage e monta a boot.vfat varrendo images/rpi-firmware/.
# Quem garante a ordem é BR2_ROOTFS_POST_IMAGE_SCRIPT, no buildroot.fragment.

set -euo pipefail

BINARIES_DIR="${1:-${BINARIES_DIR:-}}"
[ -n "$BINARIES_DIR" ] || { echo "post-image: BINARIES_DIR não informado" >&2; exit 1; }

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTBO="$BOARD_DIR/hcsr04.dtbo"
DEST="$BINARIES_DIR/rpi-firmware/overlays"

[ -f "$DTBO" ] || { echo "post-image: não encontrei $DTBO" >&2; exit 1; }
[ -d "$DEST" ] || { echo "post-image: não encontrei $DEST (rpi-firmware não instalou os overlays?)" >&2; exit 1; }

install -m 0644 "$DTBO" "$DEST/hcsr04.dtbo"
echo "post-image: hcsr04.dtbo copiado para overlays/ da partição de boot"
