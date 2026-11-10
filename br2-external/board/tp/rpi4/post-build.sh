#!/usr/bin/env bash
# post-build.sh — ajustes no rootfs depois de os pacotes e o overlay serem
# copiados, e antes de a imagem ser montada.
#
# Hoje faz uma coisa só: remover o /etc/init.d/S80dnsmasq que o pacote dnsmasq
# instala. Sem isso o dnsmasq subiria duas vezes no boot — uma pelo S70tp-ap,
# junto com o hostapd, e outra pelo S80dnsmasq, que imprimiria FAIL por achar a
# instância anterior. O guia do TP prevê este caso: "se hostapd ou dnsmasq
# iniciarem duas vezes, verifique /etc/init.d no target e desabilite/ajuste os
# scripts duplicados. O objetivo é ter uma única sequência de inicialização
# previsível."
#
# Por que no S70 e não deixar o S80 fazer o trabalho: o AP é uma unidade. O
# "S70tp-ap stop" tem de derrubar o DHCP junto com o rádio, senão fica um
# servidor DHCP respondendo numa rede que não existe mais.
#
# $1 = TARGET_DIR (o Buildroot passa).
set -euo pipefail

TARGET="${1:?uso: post-build.sh TARGET_DIR}"

if [ -e "$TARGET/etc/init.d/S80dnsmasq" ]; then
  rm -f "$TARGET/etc/init.d/S80dnsmasq"
  echo "post-build: S80dnsmasq removido (o dnsmasq é iniciado pelo S70tp-ap)"
fi
