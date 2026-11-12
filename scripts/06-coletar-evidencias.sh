#!/usr/bin/env bash
# 06 — Tira as evidências de dentro do microSD, sem montar o cartão.
#
# Uso:
#   ./scripts/06-coletar-evidencias.sh /dev/sdX     (o cartão; usa a 2ª partição)
#   ./scripts/06-coletar-evidencias.sh arquivo.ext4 (uma imagem de rootfs, para testar)
#
# Lê com debugfs em modo somente leitura: o cartão não é montado e não corre
# risco de alteração. Montar a partição de boot como gravável, para a placa
# escrever ali, seria o caminho mais óbvio — e o mais perigoso: um
# desligamento abrupto no meio corromperia justamente a partição que dá boot.
source "$(dirname "$0")/lib.sh"
require_not_root

ALVO="${1:-}"
[ -n "$ALVO" ] || die "uso: $0 /dev/sdX   (ou um arquivo de imagem rootfs)"

DEBUGFS="$OUT_DIR/host/sbin/debugfs"
[ -x "$DEBUGFS" ] || die "não achei o debugfs em $DEBUGFS — rode ./scripts/04-build-image.sh antes"

# Num cartão, o rootfs é a 2ª partição; num arquivo, é o próprio arquivo.
if [ -b "$ALVO" ]; then
  case "$ALVO" in
    *mmcblk*|*nvme*) ROOTFS="${ALVO}p2" ;;
    *)               ROOTFS="${ALVO}2" ;;
  esac
  [ -b "$ROOTFS" ] || die "não achei a 2ª partição ($ROOTFS). O cartão está inteiro?"
  SUDO="sudo"
elif [ -f "$ALVO" ]; then
  ROOTFS="$ALVO"
  SUDO=""
else
  die "$ALVO não é dispositivo de bloco nem arquivo"
fi

ler() { $SUDO "$DEBUGFS" -R "$1" "$ROOTFS" 2>/dev/null; }

# Antes de concluir qualquer coisa sobre o conteúdo, confirmar que deu para LER.
# Sem isto, falta de permissão vira "não é o cartão do TP", que manda procurar
# o problema no lugar errado — foi o que aconteceu na primeira vez que rodei.
PROVA="$($SUDO "$DEBUGFS" -R 'stat /etc/issue' "$ROOTFS" 2>&1 || true)"
case "$PROVA" in
  *"Permission denied"*|*"Operation not permitted"*)
    die "sem permissão para ler $ROOTFS.
  Rode no seu terminal, onde o sudo consegue pedir a senha:
    ./scripts/06-coletar-evidencias.sh $ALVO" ;;
  *"Inode:"*) ;;
  *)
    die "não consegui ler $ROOTFS como sistema de arquivos ext4.
  O cartão está inteiro? É mesmo a 2ª partição?
  Saída do debugfs: $(echo "$PROVA" | tail -2)" ;;
esac

# Agora sim: é um ext4 legível. É o do TP?
ler 'cat /etc/issue' | grep -q 'TP Aula 9' \
  || die "$ROOTFS é legível, mas o /etc/issue não é o deste TP.
  Confira o dispositivo: um erro aqui lê o disco errado."
info "rootfs do TP reconhecido em $ROOTFS ✔"

load_env
HOME_ALUNO="/home/$USUARIO"
mkdir -p "$EVID_DIR"

info "O que está em $HOME_ALUNO:"
ler "ls -l $HOME_ALUNO" | awk '{print "  " $NF}' | grep -vE '^\s+\.{1,2}$|^\s+$' || true

ACHOU=0
for arq in evidencias-tp.txt; do
  if ler "stat $HOME_ALUNO/$arq" | grep -q '^Inode:'; then
    ler "cat $HOME_ALUNO/$arq" > "$EVID_DIR/$arq"
    LINHAS="$(grep -c '' "$EVID_DIR/$arq")"
    info "evidence/$arq copiado ($LINHAS linhas)"
    ACHOU=1
  fi
done

# Capturas que tenham sido salvas na placa (raro, mas barato de cobrir).
for ext in png jpg txt log; do
  for nome in $(ler "ls $HOME_ALUNO" | tr ' ' '\n' | grep -i "\.$ext\$" || true); do
    [ "$nome" = "evidencias-tp.txt" ] && continue
    ler "cat $HOME_ALUNO/$nome" > "$EVID_DIR/$nome" && info "evidence/$nome copiado" && ACHOU=1
  done
done

[ "$ACHOU" = "1" ] || warn "nada encontrado em $HOME_ALUNO — o tp-evidencias chegou a rodar na placa?"

checkpoint "coleta terminada. Confira com 'git status' e commite o que fizer sentido."
