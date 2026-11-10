#!/usr/bin/env bash
# 03 — Constrói a imagem Docker do Flask para ARM64 e coloca o .tar no overlay
# (guia Aula 10, Etapas 8 e 9.1). Independe do Buildroot: pode rodar antes ou
# depois do 02, mas TEM que rodar antes do 04.
source "$(dirname "$0")/lib.sh"
require_not_root

docker info >/dev/null 2>&1 || die "Docker do host não responde (rode 00-setup-host.sh / verifique o grupo docker)"
docker buildx use tpbuilder 2>/dev/null || docker buildx create --name tpbuilder --use >/dev/null

info "Arquitetura do host: $(uname -m) → construindo para linux/arm64"
cd "$FLASK_DIR"
# As opções abaixo mantêm a imagem no formato que a Raspberry consegue carregar.
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  -t "$IMAGE_REF" --load .

ARCH="$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}/{{.Os}}')"
[ "$ARCH" = "arm64/linux" ] || die "imagem saiu como $ARCH (esperado arm64/linux) — na Pi isso dá 'exec format error'"
info "Arquitetura da imagem: $ARCH ✔"

# --- Teste do container emulado, incluindo a API da distância -------------
# É o mais perto da Raspberry que dá para chegar no PC: o binário é arm64, o
# Python é o 3.12 da imagem (o do host é outro) e a leitura da distância passa
# pelo mesmo caminho de arquivo que o driver vai criar na placa.
TMP_TESTE="$(mktemp -d)"
FAKE_DEV="$TMP_TESTE/hcsr04"
RESP_JSON="$TMP_TESTE/resp.json"
printf '1234\n' > "$FAKE_DEV"
trap 'docker rm -f tp-teste >/dev/null 2>&1 || true; rm -rf "$TMP_TESTE"' EXIT

subir_teste() {
  docker rm -f tp-teste >/dev/null 2>&1 || true
  docker run -d --name tp-teste --platform linux/arm64 -p 15000:5000 "$@" \
    "$IMAGE_REF" >/dev/null
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null http://127.0.0.1:15000/ && return 0
    sleep 1
  done
  # O 2>&1 é o que importa: o Werkzeug escreve banner, log de requisição e
  # traceback no stderr, então mandar o stderr do docker para /dev/null
  # apagaria justamente o diagnóstico que esta mensagem promete.
  docker logs tp-teste 2>&1 | tail -40 >&2 || true
  die "o container não respondeu na porta 5000 (log acima)"
}

info "Teste 1/2: container emulado SEM /dev/hcsr04..."
subir_teste
RESP="$(curl -s http://127.0.0.1:15000/ || true)"
[ "$RESP" = "Helooowww world eng. Computacional!!!!!!!" ] \
  || die "container não respondeu a frase esperada em / (resposta: '$RESP')"
# Sem o device, a API tem de recusar com 503 e dizer o motivo. Esse é o estado
# em que a aplicação fica se o módulo não carregar ou se o container subir sem
# --device, e é o que o dashboard mostra em vez de um número inventado.
CODE="$(curl -s -o "$RESP_JSON" -w '%{http_code}' http://127.0.0.1:15000/api/distance || true)"
[ "$CODE" = "503" ] || die "sem o device, /api/distance devolveu HTTP $CODE (esperado 503)"
python3 - "$RESP_JSON" <<'PY' || die "resposta inesperada de /api/distance sem o device: $(cat "$RESP_JSON")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False, d
assert "não existe" in d["error"], d
PY
info "sem o device: / responde e /api/distance devolve 503 com ok=false ✔"

info "Teste 2/2: container emulado COM um /dev/hcsr04 falso (1234 mm)..."
subir_teste -v "$FAKE_DEV:/dev/hcsr04:ro"
CODE="$(curl -s -o "$RESP_JSON" -w '%{http_code}' http://127.0.0.1:15000/api/distance || true)"
[ "$CODE" = "200" ] || die "com o device, /api/distance devolveu HTTP $CODE (esperado 200)"
python3 - "$RESP_JSON" <<'PY' || die "a API converteu o valor errado: $(cat "$RESP_JSON")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True, d
assert d["distance_mm"] == 1234, d
assert d["distance_cm"] == 123.4, d
assert d["in_range"] is True, d
PY
info "com o device: 1234 mm viram 123.4 cm, in_range verdadeiro ✔"
docker rm -f tp-teste >/dev/null 2>&1 || true

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
