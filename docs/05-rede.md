# 05 — Rede

## O vocabulário, com as nossas palavras

**IP da Raspberry Pi** — o endereço que o roteador da rede local entrega à `eth0` da placa, por
DHCP, quando ela liga. É um endereço da sua rede (algo como `192.168.0.x`) e é por ele que o
notebook enxerga a Raspberry. Descobre-se na própria placa com `ip addr show eth0`.

**docker0** — uma interface de rede virtual que o `dockerd` cria no host, funcionando como um
switch de software. Ela recebe a faixa `172.17.0.0/16` e o endereço `172.17.0.1` fica sendo o
gateway dos containers. Não existe fora da Raspberry: nenhum equipamento da rede local alcança
`172.17.0.1`.

**bridge network** — o modo de rede padrão do Docker, que liga containers à `docker0`. Cada
container recebe um par de interfaces `veth`: uma ponta dentro do container (que lá se chama
`eth0`) e a outra ponta no host, encaixada na bridge. É o cabo virtual entre os dois.

**IP interno do container** — o endereço que o Docker atribui ao container dentro da faixa da
bridge, tipicamente `172.17.0.2`. Ele só tem significado dentro da Raspberry. Aparece em
`docker inspect flask-tp8`.

**Porta do container** — a porta onde o processo escuta **dentro** do container: 5000, onde o
Flask está, por causa de `app.run(host="0.0.0.0", port=5000)`.

**Porta do host** — a porta aberta na própria Raspberry, visível para a rede local. Também é 5000,
porque escolhemos publicar uma na outra, mas poderiam ser diferentes.

**-p 5000:5000** — a instrução de publicação. Lê-se `porta_do_host:porta_do_container`. Ela faz o
Docker inserir regras de `iptables` que reescrevem o destino dos pacotes que chegam à porta 5000 da
Raspberry, mandando-os para `172.17.0.2:5000`. É DNAT: tradução de endereço de destino.

## Por que o acesso é pelo IP da Raspberry, e não pelo do container

Porque o IP do container **não é roteável fora da Raspberry**. A faixa `172.17.0.0/16` existe
apenas dentro da placa, criada pelo `dockerd`; o roteador da rede não sabe que ela existe e nenhum
outro equipamento tem rota para ela. Se do notebook você tentar `http://172.17.0.2:5000`, o pacote
não chega a lugar nenhum.

O caminho real é este:

```
notebook  →  IP_DA_RASPBERRY:5000        (rede local, endereço roteável)
             ↓  iptables do Docker: DNAT
             172.17.0.2:5000              (dentro da Raspberry, via docker0 e veth)
             ↓
             Flask escutando em 0.0.0.0:5000
```

A Raspberry é o único ponto de entrada; o `-p` é a porta que ela abre para o mundo.

## Por que `host="0.0.0.0"` e não `127.0.0.1`

Dentro do container, `127.0.0.1` é o loopback **do próprio container** — um namespace de rede
separado. O tráfego que vem do Docker chega pela interface `veth`, com destino `172.17.0.2`, não
pelo loopback. Com `127.0.0.1`, um `curl` executado dentro do container funcionaria, mas qualquer
acesso de fora seria recusado. `0.0.0.0` significa "todas as interfaces".

## Configuração da rede do sistema

O `BR2_SYSTEM_DHCP="eth0"` faz o Buildroot gerar o `/etc/network/interfaces`. O mesmo arquivo está
no overlay — o checklist do TP exige explicitamente que ele esteja lá — e, como o overlay é copiado
depois dos pacotes, é a cópia do overlay que vale. Por isso ela reproduz as diretivas na íntegra:

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
  pre-up /etc/network/nfs_check
  wait-delay 15
  hostname $(hostname)
```

O `wait-delay 15` é a diretiva que não pode ser perdida: ela faz o `ifup` esperar até 15 segundos o
link físico da `eth0` subir antes de disparar o `udhcpc`. Sem ela, numa placa que acabou de ligar,
o pedido DHCP pode sair antes do link existir — e a interface fica sem IP até alguém intervir. Uma
simplificação do arquivo para as quatro primeiras linhas reintroduz esse defeito, que só aparece em
alguns boots, o que o torna especialmente difícil de diagnosticar.

O `pre-up /etc/network/nfs_check` vem do mesmo gerador e existe para não derrubar a rede quando o
root está montado por NFS. Não é o nosso caso, mas o script está instalado no sistema e remover a
linha sem remover o script não traria benefício.

## Limitação conhecida

A interface `eth0` aparece em dois lugares: no `BR2_SYSTEM_DHCP` do `buildroot.fragment` e escrita
à mão no `interfaces` do overlay. Hoje os dois concordam. Trocar a interface em apenas um deles não
teria efeito, porque o overlay sobrescreve — e o sintoma seria uma configuração que "não pega".
