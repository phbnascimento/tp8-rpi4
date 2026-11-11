# Testes e evidências

## O que está conferido e o que não está

O sistema foi construído sem acesso à Raspberry. Em compensação, **cada camada tem uma conferência
automática no host**, executada a cada build: o `scripts/04-build-image.sh` recusa a imagem se
alguma falhar. Isso prova que os arquivos certos estão na imagem e que os formatos batem — não
prova que o sensor mede, que o rádio associa ou que o container volta depois de reiniciar.

As duas colunas abaixo são a divisão honesta entre as duas coisas.

### Conferido no host

| Verificação | Como |
|---|---|
| conteúdo do rootfs: usuário, grupo `docker`, banner, `wait-delay` da rede, scripts de init | lido de dentro do `rootfs.ext4` com `debugfs`, sem montar a imagem |
| modo `0755` dos quatro executáveis do TP | idem, dentro da imagem |
| kernel com tudo que o Docker exige | `check-config.sh` do próprio Docker contra o `.config` gerado |
| kernel com `MODULES`, `GPIOLIB`, `OF`, `DEVTMPFS_MOUNT`, `CFG80211`, `MAC80211`, `BRCMFMAC` | `grep` no `.config` da imagem |
| `hcsr04.ko` instalado, em `modules.dep`, com `vermagic` igual ao kernel da imagem | `objcopy` na seção `.modinfo` do módulo |
| `hcsr04.dtbo` corresponde ao `.dts` e chegou a `overlays/` na partição de boot | recompila o `.dts` e compara os bytes |
| `config.txt` da imagem com `kernel=Image`, `arm_64bit=1` e `dtoverlay=hcsr04` | lido da partição de boot |
| firmware do BCM43455 presente, com o symlink resolvendo | `test -f`, que segue o link |
| `hostapd.conf` e `dnsmasq.conf` aceitos pelos **binários aarch64 da própria imagem** | executados no PC por binfmt/qemu |
| SSID, faixa DHCP, tamanho da senha WPA2 | `grep` nos arquivos de configuração |
| um único script `S99`, com `--device` e porta 80 | `grep` no rootfs, ignorando comentários |
| `/opt/docker` com exatamente o tar atual e o LEIA-ME | listagem do diretório na imagem |
| o tar contém a imagem `tp-distance:1.0` | `manifest.json` de dentro do tar |
| a API responde certo, com e sem o device | container **emulado** no PC, com um arquivo montado em `/dev/hcsr04` |
| o dashboard atualiza a cada 500 ms | Firefox headless contra o container, requisições contadas no log do Flask |
| a imagem gravada no cartão é idêntica à imagem em disco | `scripts/05-flash-sd.sh` lê o cartão de volta e compara |

As conferências **acrescentadas neste TP** foram testadas falhando: sabotamos o arquivo
correspondente e confirmamos que o script aborta com a mensagem certa — SSID trocado, senha WPA2
curta, módulo fora do `modules-load.d`, firmware ausente, `.conf` inválido, dois scripts `S99`,
container sem `--device`, script de init duplicado, modo errado, opção de kernel ausente, tar
antigo esquecido. As herdadas do TP anterior (usuário, banner, `wait-delay`, `check-config.sh`)
vêm de lá e não foram sabotadas de novo.

Uma verificação que nunca falhou não prova nada — foi exatamente assim que descobrimos uma das
novas que passava mesmo com o defeito presente.

### A validar na placa

Nada abaixo foi executado ainda. É o que a apresentação demonstra.

| Item | Como se demonstra |
|---|---|
| boot e login | ligar a placa e entrar como `aluno` |
| driver carregado | `lsmod`, `/dev/hcsr04` existindo |
| medição real | `cat /dev/hcsr04` com objeto a distâncias diferentes |
| AP no ar | SSID visível, cliente associando, DHCP entregando endereço |
| container ativo | `docker ps` depois do boot, sem comando manual |
| dashboard | `http://192.168.50.1` no cliente, número acompanhando o objeto |
| persistência | tudo igual depois de `reboot`, sem intervenção |

## Procedimento de validação

A sequência é a da seção 15 do enunciado — o professor pode executá-la com a placa partindo do
estado desligado.

1. **Montar o circuito** conforme [hardware.md](hardware.md) e **conferir a ligação antes de
   energizar**. O ECHO tem de passar pelo divisor resistivo.
2. Gravar o cartão com `./scripts/05-flash-sd.sh`, que confere a gravação lendo o cartão de volta.
3. Ligar: microSD → sensor → monitor e teclado → fonte por último.
4. Confirmar o banner do grupo antes do `login:` e entrar como `aluno`.
   **No primeiro boot a tela fica parada por 1 a 2 minutos** na mensagem
   `[TP] carregando imagem Docker`: é o `docker load` dos 48 MB. Não desligar.
5. Confirmar o driver: `lsmod | grep hcsr04` e `ls -l /dev/hcsr04`.
6. Ler o sensor na própria placa: `cat /dev/hcsr04`, com um objeto a uns 20 cm, e de novo a uns
   60 cm. Os números têm de mudar.
7. Confirmar o AP: `ip addr show wlan0` mostrando `192.168.50.1`.
8. No celular ou notebook, procurar o SSID **`TP9-GRUPO03`**, conectar com a senha
   `embarcados2026` e confirmar que recebeu um endereço `192.168.50.x`.
9. Abrir **`http://192.168.50.1`** no cliente. O número aparece e acompanha o objeto.
10. Na placa: `docker ps` e `docker inspect tp-distance`.
11. `reboot` e repetir os passos 4 a 10 **sem rodar nenhum comando Docker à mão**. É isso que
    demonstra que o sistema é autônomo; qualquer `docker run` manual invalida o teste.

O comando `tp-evidencias`, já instalado, roda de uma vez quase toda a coleta: hostname, usuário,
`ip addr` das duas interfaces, `lsmod`, `ls -l /dev/hcsr04`, `cat /dev/hcsr04`, estado do Docker e
a resposta de `/api/distance`. A saída vai para a tela e é acrescentada a `~/evidencias-tp.txt`, de
modo que os boots sucessivos ficam no mesmo arquivo, cada um com o seu `boot_id`.

Para tirar o arquivo da placa: desligar, pôr o microSD no PC e copiar
`/home/aluno/evidencias-tp.txt` da segunda partição.

## Evidências a coletar

As doze da seção 14 do enunciado, e onde cada uma vai. Mantenha o nome; ajuste só a extensão se a
câmera gerar outro formato.

| # | Evidência | Arquivo |
|---|---|---|
| 1 | foto da montagem elétrica, com o divisor visível | `evidence/hardware/01-montagem.jpg` |
| 2 | banner e prompt de login | `evidence/login/02-banner-login.jpg` |
| 3 | `lsmod` ou `modinfo` com o driver carregado | `evidence/driver/03-lsmod.jpg` |
| 4 | `ls -l /dev/hcsr04` | `evidence/driver/04-ls-dev.jpg` |
| 5 | `cat /dev/hcsr04` | `evidence/driver/05-cat-dev.jpg` |
| 6 | `ip addr show wlan0` com `192.168.50.1` | `evidence/network/06-wlan0.jpg` |
| 7 | cliente conectado ao SSID `TP9-GRUPO03` | `evidence/network/07-cliente-ssid.png` |
| 8 | `docker ps` com o container ativo | `evidence/docker/08-docker-ps.jpg` |
| 9 | resposta de `/api/distance` | `evidence/web/09-api-distance.png` |
| 10 | dashboard exibindo a distância | `evidence/web/10-dashboard.png` |
| 11 | duas distâncias físicas diferentes | `evidence/web/11a-distancia-perto.png` e `11b-distancia-longe.png` |
| 12 | validação repetida após `reboot` | `evidence/reboot/12-apos-reboot.jpg` |

Mais o que não é foto:

| Arquivo | Conteúdo |
|---|---|
| `evidence/evidencias-tp.txt` | saída do `tp-evidencias` em cada boot |
| `evidence/hashes.txt` | SHA-256 do `tp-distance.tar` e do `sdcard.img` do build final |
| `evidence/build/` | conferências automáticas: usuários, kernel, sequência de boot |

**Sobre o hash:** o `evidence/hashes.txt` descreve sempre o último build feito no repositório. Para
que ele corresponda ao cartão apresentado, o `scripts/04-build-image.sh` tem de ser **o último
script executado antes do commit final** — gravar o cartão e depois recompilar troca a imagem e
invalida o registro. O `scripts/05-flash-sd.sh` recusa a gravação se o hash registrado não for o da
imagem em disco, e grava em `evidence/build/cartao-gravado.txt` a comparação com o que leu de volta
do cartão.

## Diagnóstico por sintoma

| Sintoma | Causa provável | Onde olhar |
|---|---|---|
| Banner não aparece | `/etc/issue` não entrou no overlay | `BR2_ROOTFS_OVERLAY`, caminho do arquivo |
| Não consigo logar | `users_table.txt` ou shell errado | `/etc/passwd`, `/etc/shadow` |
| `/dev/hcsr04` não existe | módulo não carregou, ou overlay não carregou | `lsmod \| grep hcsr04`, `dmesg \| grep -i hcsr04`, `ls /proc/device-tree/hcsr04` |
| `cat /dev/hcsr04` trava ou dá erro | ECHO sem retorno: ligação ou divisor | conferir o divisor; o driver devolve erro após 100 ms |
| Distância sempre ~6500 | sem obstáculo no alcance, ou ECHO não chega ao GPIO | apontar para uma parede; conferir o pino 18 |
| `wlan0` não existe | `brcmfmac` não carregou, ou firmware ausente | `lsmod \| grep brcmfmac`, `dmesg \| grep -i brcmf`, `ls /lib/firmware/brcm/` |
| SSID não aparece | `hostapd` não subiu | `hostapd -dd /etc/hostapd.conf` na mão, mensagem do `S70tp-ap` |
| Cliente conecta mas não recebe IP | `dnsmasq` não subiu | `ps \| grep dnsmasq`, `/var/log/messages` |
| Celular diz "sem internet" e sai da rede | esperado: o AP não tem NAT | usar notebook, ou desligar dados móveis |
| `dockerd` não inicia | recurso de kernel faltando | `docker info`, `evidence/build/kernel-check-config.txt` |
| `exec format error` | imagem do container em amd64 | `docker image inspect`; reconstruir com `--platform linux/arm64` |
| Dashboard mostra "Falha: /dev/hcsr04 não existe" | container sem `--device`, ou módulo não carregado | `docker inspect tp-distance`, `ls -l /dev/hcsr04` |
| Container não volta após reboot | `S99tp-app` sem `+x`, ou container antigo sem device | `ls -l /etc/init.d/`, `docker ps -a` |
| Primeiro boot parece travado | `docker load` em andamento | esperar 1 a 2 minutos |
