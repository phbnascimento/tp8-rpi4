# Docker, rede e aplicação Web

Da bridge do Docker até o número que aparece no navegador.

## Os dois pacotes

```
Configuração: Target packages → System tools → docker-engine
Símbolo:      BR2_PACKAGE_DOCKER_ENGINE=y
Motivo:       instalar o daemon que realmente cria e executa containers.
Dependências: seleciona containerd, runc e iptables; exige do kernel os
              recursos descritos em buildroot.md.
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
`containerd` e `runc` abaixo dele); o **cli** é apenas o cliente.

## Quem pode usar o Docker

O `dockerd` cria o socket `/var/run/docker.sock` pertencente ao grupo `docker` — padrão do próprio
daemon. O pacote cria o grupo, e o `users_table.txt` põe o `aluno` dentro dele. A imagem gerada
confirma:

```
docker:x:101:aluno
```

Por isso o `aluno` roda `docker ps` sem `sudo`, o que importa para as evidências, coletadas logado
como `aluno`.

## A imagem do container

Construída com `docker buildx --platform linux/arm64` a partir de
[`flask-app/Dockerfile`](../flask-app/Dockerfile), que fixa `python:3.12.15-slim-bookworm` e
`Flask==3.1.3`. Uma imagem amd64 daria `exec format error` na Pi, porque os binários rodam direto
na CPU Cortex-A72.

O `scripts/03-build-flask-image.sh` confere, antes de exportar: a arquitetura da imagem, o formato
do arquivo exportado e — rodando o container emulado no PC — que a aplicação responde. O tar fica
fora do Git (48 MB, artefato de build), com o SHA-256 em
[../evidence/hashes.txt](../evidence/hashes.txt).

O `docker load` extrai as camadas em `/var/lib/docker`, que fica no rootfs e é gravável: a imagem
carregada **sobrevive ao desligamento**, e o carregamento só acontece no primeiro boot.

## `--device`: como o sensor entra no container

O container tem um namespace de dispositivos próprio. Mesmo rodando como root, ele **não enxerga**
`/dev/hcsr04` do sistema hospedeiro: para o processo lá dentro, aquele caminho simplesmente não
existe.

```
docker run --device /dev/hcsr04:/dev/hcsr04 ...
```

O `--device` cria o nó dentro do container e concede a permissão correspondente no cgroup de
dispositivos. Lê-se `caminho_no_host:caminho_no_container`; aqui os dois são iguais, para que o
código não precise saber onde está rodando.

A alternativa seria `--privileged`, que dá ao container acesso a **todos** os dispositivos do
sistema. Seria mais fácil e bem pior: o container precisa de um arquivo, não do hardware inteiro.
O enunciado cobra o `--device` explicitamente.

Quando o device não chega, a API devolve `503` com a mensagem
`"/dev/hcsr04 não existe: o módulo hcsr04 não está carregado, ou o container subiu sem --device"`.
De dentro do container não há como distinguir os dois casos, e a mensagem diz isso.

## A rede, com as nossas palavras

**docker0** — interface virtual que o `dockerd` cria no host, funcionando como um switch de
software. Recebe a faixa `172.17.0.0/16`, e `172.17.0.1` é o gateway dos containers. Não existe
fora da Raspberry.

**bridge network** — o modo de rede padrão: cada container ganha um par `veth`, uma ponta dentro
dele (que lá se chama `eth0`) e a outra encaixada na `docker0`. É o cabo virtual entre os dois.

**IP interno do container** — tipicamente `172.17.0.2`. Só tem significado dentro da placa. Aparece
em `docker inspect tp-distance`.

**Porta do container** — onde o processo escuta **dentro** do container: 5000, por causa de
`app.run(host="0.0.0.0", port=5000)`.

**Porta do host** — a porta aberta na própria Raspberry: **80**, para que o cliente abra
`http://192.168.50.1` sem precisar digitar porta.

**`-p 80:5000`** — a publicação. Lê-se `porta_do_host:porta_do_container`. Faz o Docker inserir
regras de `iptables` que reescrevem o destino dos pacotes que chegam à porta 80 da Raspberry,
mandando-os para `172.17.0.2:5000`. É DNAT.

### Por que o acesso é pelo IP da Raspberry

Porque o IP do container **não é roteável fora dela**. A faixa `172.17.0.0/16` existe apenas dentro
da placa; nenhum outro equipamento tem rota para ela. O caminho real é:

```
celular/notebook  →  192.168.50.1:80        (rede do AP, endereço roteável)
                     ↓  iptables do Docker: DNAT
                     172.17.0.2:5000         (dentro da Raspberry, via docker0 e veth)
                     ↓
                     Flask escutando em 0.0.0.0:5000
```

A publicação de porta vale para qualquer interface, inclusive uma que **apareça depois** — é o que
permite o `dockerd` (S60) subir antes do Wi-Fi (S70).

### Por que `host="0.0.0.0"` e não `127.0.0.1`

Dentro do container, `127.0.0.1` é o loopback **do próprio container**, num namespace de rede
separado. O tráfego publicado chega pela `veth`, com destino `172.17.0.2`. Com `127.0.0.1`, um
`curl` de dentro do container funcionaria e qualquer acesso de fora seria recusado. `0.0.0.0`
significa "todas as interfaces".

### A rede do sistema

`BR2_SYSTEM_DHCP="eth0"` gera o `/etc/network/interfaces`; a cópia que vale é a do overlay, porque
ele é aplicado depois dos pacotes. A diretiva que não pode ser perdida é o **`wait-delay 15`**: ela
faz o `ifup` esperar até 15 s o link físico subir antes de disparar o `udhcpc`. Sem ela, numa placa
que acabou de ligar, o pedido DHCP pode sair antes de o link existir, e a interface fica sem IP até
alguém intervir — defeito que aparece só em alguns boots, o que o torna difícil de diagnosticar. O
`scripts/04-build-image.sh` confere essa diretiva dentro da imagem.

A `eth0` continua por DHCP e serve para administrar a placa, mas sobe **em segundo plano**, pelo
`S41eth0`: o `ifup` é síncrono e, sem cabo, seguraria o boot pelos 15 s do `wait-delay`. O
dashboard é servido pela `wlan0`, descrita em [wifi-ap.md](wifi-ap.md).

## Inicialização automática

`S60dockerd` (do pacote) sobe o daemon. [`S99tp-app`](../br2-external/board/tp/rpi4/rootfs-overlay/etc/init.d/S99tp-app),
nosso, roda depois:

1. confere que `/dev/hcsr04` existe — o container subiria sem sensor, e é melhor falhar dizendo
   por quê;
2. espera `docker info` responder (até 60 tentativas, 1 s cada), evitando a corrida com o daemon
   ainda subindo;
3. `docker load -i /opt/docker/tp-distance.tar`, **apenas se** `docker image inspect` não encontrar
   a imagem — por isso só no primeiro boot;
4. se o container já existe, **confere se ele tem o device**; se não tiver, remove e recria. Um
   container criado por uma imagem anterior sobrevive em `/var/lib/docker` e seria reaproveitado
   com as opções antigas — sem o device, ou na porta errada;
5. `docker start` se existe e está correto; senão `docker run -d --restart unless-stopped
   --device /dev/hcsr04:/dev/hcsr04 -p 80:5000 tp-distance:1.0`.

O ramo do `docker start` não é redundante: no desligamento o `rcK` chama a ação `stop`, e um
`docker stop` marca o container como parado pelo usuário — estado em que a política
`unless-stopped` deliberadamente **não** o reinicia. É o `docker start` explícito que o faz voltar
nos boots seguintes.

## A API

[`flask-app/app.py`](../flask-app/app.py). Um endpoint de dados e uma página.

```
GET /api/distance
```

```json
{"ok": true, "distance_mm": 374, "distance_cm": 37.4, "in_range": true}
```

| Campo | Significado |
|---|---|
| `ok` | a leitura funcionou |
| `distance_mm` | o que o driver devolveu, em milímetros |
| `distance_cm` | o mesmo valor em centímetros, uma casa decimal |
| `in_range` | se está entre 2 cm e 4 m, a faixa útil do sensor |

Em caso de falha, **HTTP 503** e `{"ok": false, "error": "..."}`, com mensagens que distinguem os
casos: device ausente, sem permissão, sem eco dentro do prazo do driver, ou conteúdo inesperado no
device. Na apresentação, essa diferença é o que separa um problema de software de um fio solto.

Dois detalhes de implementação que não são enfeite:

- **o device é aberto a cada leitura.** O driver devolve EOF depois do primeiro `read()` de cada
  `open()`; reaproveitar o descritor leria vazio;
- **um cache de 100 ms**, protegido por `lock`. O HC-SR04 precisa de folga entre disparos, e dois
  navegadores abertos ao mesmo tempo já bastariam para encavalar medições. Dentro da janela, a
  segunda requisição reaproveita a leitura em vez de disparar o sensor de novo.

O caminho do device é `/dev/hcsr04`, com a variável de ambiente `HCSR04_DEVICE` como exceção usada
só para testar a API no PC.

## O dashboard

[`flask-app/templates/index.html`](../flask-app/templates/index.html). O HTML é estático; quem
busca os números é o JavaScript:

```
setInterval(atualizar, 500)
   └─ fetch("/api/distance", {cache: "no-store"})
        ├─ ok    → escreve distance_cm com uma casa, mostra os mm e "Sensor OK"
        ├─ fora  → mesmo número, apagado, com aviso de fora da faixa útil
        └─ erro  → volta para "--.-" e mostra a mensagem do backend
```

A atualização é a cada **500 ms**, sem recarregar a página — é o que o enunciado pede.

Três cuidados que o guia não menciona:

- **guarda contra acúmulo**: se a requisição anterior ainda não voltou, o tique seguinte é
  descartado, em vez de abrir uma fila de pedidos ao sensor;
- **corte em 2 s** (`AbortController`): um pedido pendurado não trava o laço;
- **o número some quando a leitura falha**. Deixar o último valor em destaque faria dado velho
  parecer medição atual — o erro mais fácil de cometer num painel em tempo real, e o mais
  enganoso.

**Tudo é embutido**: nenhuma fonte, folha de estilo ou biblioteca externa. A rede do AP não tem
saída para a internet, e uma referência a CDN deixaria a página quebrada exatamente na
apresentação, depois de o navegador esperar o tempo limite. O `scripts/03-build-flask-image.sh`
recusa o arquivo se encontrar nele endereço de outro servidor.

## O que foi conferido sem a placa

| Conferência | Como |
|---|---|
| a imagem do container é `arm64/linux` | `docker image inspect` no `scripts/03` |
| sem `/dev/hcsr04`, a API devolve 503 com `ok:false` | container **emulado** no PC, sem o device |
| com um arquivo contendo `1234` montado em `/dev/hcsr04`, devolve 200, `123.4` cm e `in_range` | container emulado com `-v` |
| o `/` serve o dashboard, com o `setInterval` de 500 ms | idem — prova também que o `templates/` entrou na imagem |
| o dashboard atualiza de verdade | Firefox headless contra o container: **duas requisições por segundo durante 8 s**, contadas no log do Flask |
| os quatro estados da tela (normal, fora de faixa, driver ausente, servidor mudo) | lógica do dashboard executada em motor de JavaScript, com DOM e `fetch` simulados |
| o `S99tp-app` pede a mesma imagem que está dentro do tar, com `--device` e porta 80 | `scripts/04-build-image.sh` |
| `/opt/docker` contém exatamente o tar atual e o LEIA-ME | idem — pega tar de nomenclatura antiga esquecido |

**O que só o hardware demonstra:** que o `dockerd` sobe na placa, que o `docker load` conclui no
primeiro boot, que o container volta depois de reiniciar e que o número do dashboard acompanha um
objeto se aproximando. Está em [testes.md](testes.md).
