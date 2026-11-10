"""Backend do TP 9 — expõe a medição do HC-SR04 como JSON.

A aplicação não sabe nada de GPIO, interrupção ou velocidade do som: ela abre
/dev/hcsr04 e lê um número em milímetros. Toda a conversa com o hardware está
no driver, e é essa separação que o TP quer demonstrar.
"""

import os
import threading
import time

from flask import Flask, jsonify, render_template

app = Flask(__name__)

# O caminho é fixo na imagem; a variável de ambiente existe para poder testar a
# API no PC, apontando para um arquivo comum com um número dentro.
DEVICE = os.environ.get("HCSR04_DEVICE", "/dev/hcsr04")

# Faixa útil do HC-SR04, segundo o fabricante: de 2 cm a 4 m. Fora disso a
# leitura é devolvida do mesmo jeito, mas marcada como fora de faixa — sem
# obstáculo, o sensor mantém o ECHO alto por ~38 ms, o que o driver converte
# em algo perto de 6,5 m.
MIN_MM = 20
MAX_MM = 4000

# O HC-SR04 precisa de uma folga entre disparos; medições encavaladas podem
# captar o eco da anterior. Com o dashboard pedindo a cada 500 ms isso não
# acontece, mas dois navegadores abertos ao mesmo tempo já bastariam. O cache
# curto faz a segunda leitura simultânea reaproveitar a primeira em vez de
# disparar o sensor de novo.
CACHE_MS = 100

_lock = threading.Lock()
_ultima = {"instante": 0.0, "mm": None}


def ler_distancia_mm():
    """Dispara uma medição e devolve a distância em milímetros."""
    # Abrir a cada leitura é obrigatório: o driver devolve EOF depois do
    # primeiro read() de cada open, então reaproveitar o descritor leria "".
    with open(DEVICE, "r", encoding="utf-8") as dispositivo:
        texto = dispositivo.read().strip()
    return int(texto)


def medir():
    """Leitura com cache curto, serializada entre requisições simultâneas."""
    with _lock:
        agora = time.monotonic()
        recente = _ultima["mm"] is not None and \
            (agora - _ultima["instante"]) * 1000 < CACHE_MS
        if recente:
            return _ultima["mm"]
        mm = ler_distancia_mm()
        _ultima["mm"] = mm
        _ultima["instante"] = time.monotonic()
        return mm


@app.get("/api/distance")
def api_distance():
    """Medição atual em JSON. 503 quando o sensor não pode ser lido.

    As mensagens de erro dizem o que olhar: no dia da apresentação, a diferença
    entre "o módulo não carregou" e "o sensor não respondeu" decide se o
    problema está no software ou na ligação do protoboard.
    """
    try:
        mm = medir()
    except FileNotFoundError:
        return jsonify({
            "ok": False,
            "error": f"{DEVICE} não existe: o módulo hcsr04 não está "
                     "carregado, ou o container subiu sem --device",
        }), 503
    except PermissionError:
        return jsonify({
            "ok": False,
            "error": f"sem permissão para ler {DEVICE} "
                     "(o S55hcsr04 faz o chmod 666)",
        }), 503
    except TimeoutError:
        return jsonify({
            "ok": False,
            "error": "o sensor não devolveu eco dentro do prazo do driver: "
                     "confira a ligação do ECHO e o divisor de tensão",
        }), 503
    except ValueError:
        return jsonify({
            "ok": False,
            "error": f"conteúdo inesperado em {DEVICE} "
                     "(o driver devolve só o número em milímetros)",
        }), 503
    except OSError as exc:
        return jsonify({"ok": False, "error": f"erro ao ler {DEVICE}: {exc}"}), 503

    return jsonify({
        "ok": True,
        "distance_mm": mm,
        "distance_cm": round(mm / 10.0, 1),
        "in_range": MIN_MM <= mm <= MAX_MM,
    })


@app.get("/")
def index():
    """Dashboard. O HTML é estático; quem busca os números é o JavaScript."""
    return render_template("index.html")


if __name__ == "__main__":
    # 0.0.0.0 é obrigatório: o tráfego chega pela interface virtual (veth)
    # do container, não pelo loopback. Com 127.0.0.1 o navegador não acessa.
    app.run(host="0.0.0.0", port=5000)
