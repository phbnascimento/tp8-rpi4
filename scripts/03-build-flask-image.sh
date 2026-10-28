#!/usr/bin/env bash
# 03 — Constrói a imagem Docker do Flask para ARM64 e coloca o .tar no overlay
# (guia Aula 10, Etapas 8 e 9.1). Independe do Buildroot: pode rodar antes ou
# depois do 02, mas TEM que rodar antes do 04.
source "$(dirname "$0")/lib.sh"
require_not_root

docker info >/dev/null 2>&1 || die "Docker do host não responde (rode 00-setup-host.sh / verifique o grupo docker)"
docker buildx use tp8builder 2>/dev/null || docker buildx create --name tp8builder --use >/dev/null

info "Arquitetura do host: $(uname -m) → construindo para linux/arm64"
cd "$FLASK_DIR"
# As opções abaixo mantêm a imagem no formato que a Raspberry consegue carregar.
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  -t "$IMAGE_REF" --load .

ARCH="$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}/{{.Os}}')"
[ "$ARCH" = "arm64/linux" ] || die "imagem saiu como $ARCH (esperado arm64/linux) — na Pi isso dá 'exec format error'"
info "Arquitetura da imagem: $ARCH ✔"

info "Teste rápido do container (emulado) no host..."
docker rm -f tp8-teste >/dev/null 2>&1 || true
docker run -d --name tp8-teste --platform linux/arm64 -p 15000:5000 "$IMAGE_REF" >/dev/null
RESP=""
for _ in $(seq 1 30); do
  RESP="$(curl -s http://127.0.0.1:15000/ || true)"
  [ -n "$RESP" ] && break
  sleep 1
done
docker rm -f tp8-teste >/dev/null
[ "$RESP" = "Helooowww world eng. Computacional!!!!!!!" ] \
  || die "container não respondeu a frase esperada (resposta: '$RESP')"
info "Container respondeu: $RESP ✔"

info "Exportando com docker save..."
docker save "$IMAGE_REF" -o "$FLASK_DIR/$IMAGE_TAR_NAME"

# Confere que o arquivo exportado está no formato que a Raspberry carrega.
tar -tf "$FLASK_DIR/$IMAGE_TAR_NAME" manifest.json >/dev/null 2>&1 \
  || die "o $IMAGE_TAR_NAME saiu num formato que a Raspberry não carrega.
  Confira a versão do Docker do host e refaça este passo."
info "Formato do arquivo exportado conferido ✔"

cp "$FLASK_DIR/$IMAGE_TAR_NAME" "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME"
record_hash "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" "$IMAGE_TAR_NAME"

SIZE="$(du -h "$OVERLAY_DIR/opt/docker/$IMAGE_TAR_NAME" | cut -f1)"
checkpoint "imagem $IMAGE_REF (arm64) exportada: rootfs-overlay/opt/docker/$IMAGE_TAR_NAME ($SIZE)"
