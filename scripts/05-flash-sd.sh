#!/usr/bin/env bash
# 05 — Grava output-rpi4/images/sdcard.img no microSD (guia Aula 10, Etapa 11).
# PERIGO: dd sobrescreve o disco escolhido sem perguntar. Este script:
#   - lista os discos com lsblk e pede para você DIGITAR o dispositivo
#   - recusa o disco onde está o sistema (/) e discos não-removíveis sem confirmação extra
#   - pede para digitar o nome de novo antes de gravar
#   - confere, depois de gravar, se o cartão bate byte a byte com a imagem
# Alternativa gráfica: Raspberry Pi Imager / balenaEtcher → "imagem personalizada" → sdcard.img
source "$(dirname "$0")/lib.sh"
require_not_root

# --rapido pula a leitura de volta. A conferência lê 1,1 GB do cartão, o que
# custa quase o mesmo que a gravação: é metade do tempo total. Para iterar
# durante o desenvolvimento, vale pular; para o cartão que vai ser apresentado,
# não — é a única prova de que o cartão tem a imagem que o hash registra.
CONFERIR=sim
case "${1:-}" in
  -r|--rapido) CONFERIR=nao ;;
  "")          ;;
  *)           die "opção desconhecida: $1 (use --rapido para pular a conferência)" ;;
esac

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

# O hash que vai para o commit final tem de ser o do artefato que foi para o
# cartão. Se o registrado pelo 04 não é o desta imagem, o sdcard.img foi regerado
# depois — e basta regerar, porque os timestamps do ext4 e da vfat entram na
# imagem e mudam o hash sem nenhuma mudança de código.
info "Calculando o SHA-256 da imagem..."
IMG_HASH="$(sha256sum "$IMG" | awk '{print $1}')"
REC_HASH="$(awk '$2 == "sdcard.img" { print $1 }' "$EVID_DIR/hashes.txt" 2>/dev/null | tail -1)"
if [ -n "$REC_HASH" ] && [ "$REC_HASH" != "$IMG_HASH" ]; then
  die "o SHA-256 registrado em evidence/hashes.txt não é o desta imagem:
  registrado: $REC_HASH
  imagem:     $IMG_HASH
  Rode ./scripts/04-build-image.sh antes de gravar, para que o hash do commit
  descreva o cartão que você vai apresentar."
fi
[ -n "$REC_HASH" ] || warn "evidence/hashes.txt não tem linha de sdcard.img — o 04 não rodou?"

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

# bs=16M em vez de 4M: menos chamadas e menos idas e voltas ao controlador do
# cartão. Em leitores USB comuns a diferença é de alguns por cento — o grosso do
# tempo é o cartão, não o programa.
info "Gravando $(du -h "$IMG" | cut -f1) em /dev/$DEV..."
T_GRAVACAO=$(date +%s)
sudo dd if="$IMG" of="/dev/$DEV" bs=16M status=progress conv=fsync
sync
T_GRAVACAO=$(( $(date +%s) - T_GRAVACAO ))
IMG_SIZE="$(stat -c %s "$IMG")"
info "gravação: ${T_GRAVACAO}s ($(( IMG_SIZE / 1048576 / (T_GRAVACAO > 0 ? T_GRAVACAO : 1) )) MB/s)"

# Conferência de verdade: lê de volta do cartão exatamente o número de bytes da
# imagem e compara os hashes. Dois detalhes são essenciais:
#   iflag=count_bytes — o cartão é maior que a imagem; sem isto a leitura pega
#     bytes a mais e o hash nunca bateria;
#   blockdev --flushbufs — descarta o cache de bloco, senão a leitura vem da
#     memória e a conferência não prova nada sobre o cartão.
if [ "$CONFERIR" = "nao" ]; then
  warn "conferência pulada (--rapido): não há prova de que o cartão recebeu a imagem.
  Para o cartão da apresentação, rode sem --rapido."
  checkpoint "cartão gravado em ${T_GRAVACAO}s, SEM conferência.
  Ordem para ligar a Pi: microSD → sensor → monitor/teclado → fonte por último."
  exit 0
fi

info "Lendo $IMG_SIZE bytes de volta do cartão para conferir (demora)..."
T_CONFERENCIA=$(date +%s)
# O set -e abortaria aqui se o flushbufs falhasse, já com o cartão gravado, e sem
# explicar nada — então a falha vira aviso: a comparação ainda roda, mas pode
# estar lendo da memória em vez do cartão.
sudo blockdev --flushbufs "/dev/$DEV" \
  || warn "não deu para descartar o cache de bloco de /dev/$DEV: a leitura abaixo
  pode vir da memória, e então ela não prova que o cartão está íntegro."
# Sem iflag=direct de propósito: ele exige leitura alinhada ao setor lógico, e o
# último bloco desta imagem tem 512 bytes — num leitor com setor de 4096 a
# leitura falharia e acusaria erro numa gravação correta. Quem garante que a
# leitura vem do cartão, e não da memória, é o flushbufs acima.
CARD_HASH="$(sudo dd if="/dev/$DEV" bs=16M iflag=count_bytes count="$IMG_SIZE" status=none \
  | sha256sum | awk '{print $1}')"
T_CONFERENCIA=$(( $(date +%s) - T_CONFERENCIA ))
[ "$CARD_HASH" = "$IMG_HASH" ] \
  || die "o conteúdo do cartão não bate com a imagem:
  imagem: $IMG_HASH
  cartão: $CARD_HASH
  A gravação falhou ou o cartão tem defeito. Não apresente este cartão."
info "cartão confere byte a byte com a imagem ✔ (conferência: ${T_CONFERENCIA}s)"

mkdir -p "$EVID_BUILD_DIR"
{
  echo "--- gravação do microSD ---"
  echo "data: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "dispositivo: /dev/$DEV (${SIZE_GB} GB)"
  echo "imagem: ${IMG#"$TP_ROOT"/} ($IMG_SIZE bytes)"
  echo "SHA-256 da imagem:      $IMG_HASH"
  echo "SHA-256 lido do cartão: $CARD_HASH"
  echo "resultado: iguais"
  echo "tempos: gravação ${T_GRAVACAO}s, conferência ${T_CONFERENCIA}s"
} > "$EVID_BUILD_DIR/cartao-gravado.txt"
info "registrado em evidence/build/cartao-gravado.txt"

checkpoint "cartão gravado e conferido em $(( T_GRAVACAO + T_CONFERENCIA ))s ($IMG_HASH).
  Ordem para ligar a Pi: microSD → cabo Ethernet → monitor/teclado → fonte por último."
