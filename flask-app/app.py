from flask import Flask

app = Flask(__name__)


@app.get("/")
def index():
    return "Helooowww world eng. Computacional!!!!!!!"


if __name__ == "__main__":
    # 0.0.0.0 é obrigatório: o tráfego chega pela interface virtual (veth)
    # do container, não pelo loopback. Com 127.0.0.1 o navegador não acessa.
    app.run(host="0.0.0.0", port=5000)
