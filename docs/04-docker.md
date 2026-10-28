# 04 — Docker na imagem

## Os dois pacotes

```
Configuração: Target packages → System tools → docker-engine
Símbolo:      BR2_PACKAGE_DOCKER_ENGINE=y
Motivo:       instalar o daemon que realmente cria e executa containers.
Dependências: seleciona containerd, runc e iptables; exige do kernel os
              recursos descritos em 03-linux.md.
Impacto:      acrescenta dezenas de MB ao rootfs e instala o script de
              inicialização /etc/init.d/S60dockerd.
```

```
Configuração: Target packages → System tools → docker-cli
Símbolo:      BR2_PACKAGE_DOCKER_CLI=y
Motivo:       fornecer o comando "docker", usado pelo script de boot e pelas
              evidências (docker ps, docker images, docker inspect).
Dependências: conversa com o daemon pelo socket /var/run/docker.sock.
Impacto:      sem ele haveria daemon, mas nenhuma forma local de operá-lo.
```

São pacotes separados porque são programas separados: o **engine** é o daemon (`dockerd`, com
`containerd` e `runc` abaixo dele); o **cli** é apenas o cliente. Um sistema embarcado poderia ter
só o daemon e ser controlado remotamente.

## Quem pode usar o Docker

O `dockerd` cria o socket `/var/run/docker.sock` pertencente ao grupo `docker` — esse é o padrão do
próprio daemon, não precisa de `-G`. O pacote `docker-engine` cria o grupo, e o `users_table.txt`
põe o `aluno` dentro dele. A imagem gerada confirma:

```
docker:x:101:aluno
```

Por isso o `aluno` roda `docker ps` sem `sudo` — o que importa para as evidências, que são
coletadas logado como `aluno`.

## Onde as imagens ficam

O `docker load` extrai as camadas em `/var/lib/docker`. Verificamos que `/var/lib` é um diretório
real no rootfs ext4, e não um link para `tmpfs` como vários outros subdiretórios de `/var`
(`cache`, `log`, `run`, `spool`, `tmp` são links). Consequência prática: **a imagem carregada
sobrevive ao desligamento**, e o `docker load` só precisa acontecer uma vez, no primeiro boot.

## Inicialização automática

O `S60dockerd`, instalado pelo pacote, sobe o daemon. O `S99flask-tp8`, nosso, roda depois:

1. espera `docker info` responder (até 60 tentativas, 1 s cada) — evita a corrida entre o
   script e o daemon ainda subindo;
2. `docker load -i /opt/docker/flask-tp8.tar`, **apenas se** `docker image inspect` não encontrar a
   imagem — por isso só acontece no primeiro boot;
3. `docker start` se o container já existe; senão
   `docker run -d --name flask-tp8 --restart unless-stopped -p 5000:5000 flask-tp8:1.0`.

O ramo do `docker start` não é redundante. No desligamento o `rcK` chama a ação `stop` do script, e
um `docker stop` marca o container como parado pelo usuário — estado em que a política
`unless-stopped` deliberadamente **não** o reinicia. É o `docker start` explícito que faz o
container voltar nos boots seguintes.

## A imagem do container

Construída com `docker buildx --platform linux/arm64` a partir de `flask-app/Dockerfile`, que fixa
`python:3.12.15-slim-bookworm` e `Flask==3.1.3`. Uma imagem amd64 daria `exec format error` na Pi,
porque os binários rodam direto na CPU Cortex-A72.

Dois detalhes que o `scripts/03-build-flask-image.sh` verifica, por serem causas silenciosas de
falha só perceptíveis na placa:

- **arquitetura**: `docker image inspect` tem que responder `arm64/linux`;
- **formato do tar**: o `docker load` da Pi precisa de `docker-archive`, com `manifest.json` na
  raiz do tar. Por isso o build usa `--provenance=false --sbom=false`: sem isso o buildx acrescenta
  manifests de atestação e, dependendo da versão do Docker do host, o tar sai em formato OCI puro,
  que a Pi recusa.

O tar fica fora do Git (48 MB, artefato de build) com o SHA-256 registrado em
[../evidence/hashes.txt](../evidence/hashes.txt). O PDF do TP prevê esse caminho: artefatos
compilados podem ser publicados como Release acompanhados do hash.
