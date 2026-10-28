# 07 — Testes e evidências

## Estado da validação

| Verificação | Situação |
|---|---|
| Conteúdo da imagem conferido com `debugfs` | **feito** — usuário, grupo, banner, rede, scripts de init, tar do container |
| Kernel aprovado no `check-config.sh` do Docker | **feito** — nenhuma opção obrigatória ausente |
| Container responde a frase exigida (emulado no host) | **feito** — testado pelo `scripts/03` |
| Arquitetura `arm64/linux` da imagem do container | **feito** |
| Boot na Raspberry Pi 4 física | **pendente** |
| Três ciclos de reboot | **pendente** |
| Capturas de tela e do navegador | **pendente** |

As quatro primeiras linhas são inspeção estática do artefato: provam que os arquivos corretos estão
na imagem. Não provam que o `dockerd` sobe, que o `docker load` conclui no primeiro boot nem que o
container volta depois de reiniciar — isso só o hardware demonstra.

## Procedimento de teste na placa

1. Gravar o cartão com `./scripts/05-flash-sd.sh`.
2. Montar: microSD → cabo Ethernet no mesmo roteador do notebook → monitor e teclado → fonte por
   último.
3. Aguardar o boot. **No primeiro boot a tela fica parada por 1 a 2 minutos** na mensagem
   `[TP8] carregando imagem Docker`: é o `docker load` dos 48 MB. Não desligar a placa nesse
   momento.
4. Conferir o banner do grupo antes do `login:`.
5. Entrar com o usuário do `tp8.env` (`aluno`).
6. Rodar `tp8-evidencias`, que grava em `~/evidencias-tp8.txt` e mostra na tela.
7. Anotar o IP da placa e abrir `http://IP_DA_RASPBERRY:5000` no navegador do notebook.
8. `reboot`. Repetir os passos 5 a 7 mais duas vezes, **sem rodar nenhum comando Docker à mão**.
   O arquivo de evidências acumula as execuções.

O objetivo dos três ciclos é demonstrar que o serviço e o container voltam sozinhos. Qualquer
`docker run` manual invalida o teste.

## Comandos de verificação

| Comando | O que prova |
|---|---|
| `hostname` / `whoami` | hostname e usuário configurados no build |
| `ip addr show eth0` | a placa recebeu IP do DHCP |
| `docker version` | cliente e daemon respondendo |
| `docker info` | daemon saudável; avisos de kernel apareceriam aqui |
| `docker images` | a imagem foi carregada do tar |
| `docker ps` | o container está em execução |
| `docker network ls` | a rede `bridge` (docker0) existe |
| `docker inspect flask-tp8` | IP interno do container e a publicação da porta |
| `curl http://127.0.0.1:5000` | a aplicação responde na própria placa |
| `sha256sum /opt/docker/flask-tp8.tar` | o tar embarcado é o mesmo que foi entregue |

O `/usr/bin/tp8-evidencias` automatiza a lista inteira: basta logar e digitar o nome dele. A saída
vai para a tela e é acrescentada a `~/evidencias-tp8.txt`, de modo que os três boots ficam no mesmo
arquivo, cada um com o seu `boot_id` e o seu uptime no cabeçalho.

## Evidências a coletar

As dez evidências exigidas, e onde cada uma vai:

| Arquivo | Conteúdo |
|---|---|
| `evidence/login/01-login.png` | foto da tela com o banner e o prompt de login |
| `evidence/login/02-ip-raspberry.png` | saída de `hostname`, `whoami` e `ip addr show eth0` |
| `evidence/docker/03-docker-running.png` | `docker version` e `docker info` |
| `evidence/docker/04-container-running.png` | `docker images` e `docker ps` |
| `evidence/network/05-docker-network.png` | `docker network ls` e `docker inspect flask-tp8` |
| `evidence/network/05-curl-local.png` | `curl http://127.0.0.1:5000` |
| `evidence/web/06-acesso-notebook.png` | navegador do notebook exibindo a frase |
| `evidence/evidencias-tp8.txt` | saída do `tp8-evidencias` nos três boots |
| `evidence/hashes.txt` | SHA-256 do `flask-tp8.tar` e do `sdcard.img` |

Para tirar o `evidencias-tp8.txt` da placa: desligar, pôr o microSD no PC e copiar
`/home/aluno/evidencias-tp8.txt` da segunda partição.

## Diagnóstico por sintoma

| Sintoma | Causa provável | Onde olhar |
|---|---|---|
| Banner não aparece | `/etc/issue` não entrou no overlay | `BR2_ROOTFS_OVERLAY`, caminho do arquivo |
| Não consigo logar | `users_table.txt` ou shell errado | `/etc/passwd`, `/etc/shadow` |
| `eth0` sem IP | DHCP ou cabo; `wait-delay` removido | `/etc/network/interfaces`, `ip link` |
| `dockerd` não inicia | recurso de kernel faltando | `docker info`, `evidence/build/kernel-check-config.txt` |
| `exec format error` | imagem do container em amd64 | `docker image inspect`; reconstruir com `--platform linux/arm64` |
| `curl` funciona na placa, mas não de fora | Flask em `127.0.0.1` ou porta não publicada | `app.py`, `docker ps` |
| Container não volta após reboot | `S99flask-tp8` sem `+x` ou sem `docker start` | `ls -l /etc/init.d/`, `docker ps -a` |
| Primeiro boot parece travado | `docker load` em andamento | esperar 1 a 2 minutos |
