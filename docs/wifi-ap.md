# Wi-Fi em modo Access Point

A Raspberry não se conecta a uma rede: **ela é a rede**. O Wi-Fi onboard sobe como ponto de acesso,
distribui endereços e serve o dashboard, sem depender de nenhuma infraestrutura do laboratório.

| Item | Valor | Onde está definido |
|---|---|---|
| SSID | `TP9-GRUPO03` | `rootfs-overlay/etc/hostapd.conf` |
| Senha | `embarcados2026` (WPA2-PSK) | idem |
| Banda / canal | 2,4 GHz, canal 6 | idem |
| IP da Raspberry | `192.168.50.1/24` | `rootfs-overlay/etc/init.d/S70tp-ap` |
| Faixa DHCP | `192.168.50.10` a `192.168.50.100`, 12 h | `rootfs-overlay/etc/dnsmasq.conf` |
| URL do dashboard | `http://192.168.50.1` | porta 80, publicada pelo `S99tp-app` |

O SSID, o IP e a faixa são exigidos pelo enunciado e, por isso, são os únicos nomes do projeto que
mantêm o número do TP.

## As três peças

**`hostapd`** transforma a interface `wlan0` em ponto de acesso: anuncia o SSID, faz a autenticação
WPA2 e gerencia as associações. Fala com o kernel pelo driver **`nl80211`**, que é a interface
moderna de configuração sem fio — por isso o pacote precisa de
`BR2_PACKAGE_HOSTAPD_DRIVER_NL80211`. Sem essa opção o programa compila e instala, mas não sabe
abrir interface nenhuma.

**`dnsmasq`** entrega endereços por DHCP a quem se associar. Só DHCP: o serviço de DNS fica
irrelevante numa rede sem saída para a internet.

**`iw`** não participa do funcionamento; está na imagem para diagnóstico na apresentação
(`iw dev`, `iw reg get`).

## O firmware, que é onde isto costuma falhar

O Wi-Fi da Pi 4 é um **BCM43455** ligado por SDIO. O driver `brcmfmac` não funciona sem dois
arquivos binários que ele carrega em tempo de execução, e a armadilha é como eles chegam à imagem:

```
BR2_PACKAGE_LINUX_FIRMWARE_BRCM_BCM43XXX
   ├── traz  brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt   (NVRAM da placa)
   └── seleciona BR2_PACKAGE_LINUX_FIRMWARE_CYPRESS_CYW43XXX
          └── traz  cypress/cyfmac43455-sdio.bin  e  .clm_blob
```

O driver pede `brcm/brcmfmac43455-sdio.bin`, que **não existe como arquivo**: é um symlink para
`../cypress/cyfmac43455-sdio.bin`, criado a partir das linhas `Link:` do arquivo `WHENCE` do
`linux-firmware`. O pacote do Buildroot só cria esse link **se o alvo existir — e em silêncio se
não existir**. Por isso o `scripts/04-build-image.sh` testa os três arquivos com `test -f`, que
segue o symlink: um link pendurado reprovaria.

Vale separar dois nomes parecidos que não são a mesma coisa:

- o **firmware** vem do diretório `cypress/` do `linux-firmware`;
- o **submódulo de fabricante do kernel** que o 43455 usa é o **`brcmfmac-wcc`**, não o `cyw`. Está
  na tabela SDIO do driver: `BRCMF_SDIO_DEVICE(SDIO_DEVICE_ID_BROADCOM_43455, WCC)`, e o
  `brcmfmac` o carrega em tempo de execução por `request_module("brcmfmac-%s")`.

Confundir os dois leva a uma conferência que nunca pega o erro real — foi o que aconteceu na
primeira versão da verificação, corrigida depois de conferir a tabela no fonte do kernel.

## O módulo não carrega sozinho

`CONFIG_BRCMFMAC` é módulo, e esta imagem cria dispositivos com `devtmpfs` puro, sem `mdev` nem
`eudev`. Não há quem trate o uevent do barramento SDIO, então **nada carrega o `brcmfmac`
espontaneamente** e a `wlan0` nunca apareceria.

A solução é a mesma do driver do sensor: `/etc/modules-load.d/tp.conf` lista o módulo, e o
`S11modules` — que o próprio Buildroot instala — faz o `modprobe` no início do boot. As
dependências (`cfg80211`, `mac80211`, `brcmutil`) vêm junto pelo `modprobe`; o submódulo de
fabricante é carregado pelo próprio `brcmfmac`.

O resto da cadeia de hardware (controlador SDIO, sequência de energia, expansor de GPIO que
controla o reset do rádio) já vem embutida no kernel da Raspberry, o que foi conferido no `.config`
da imagem.

## O script que sobe tudo

[`S70tp-ap`](../br2-external/board/tp/rpi4/rootfs-overlay/etc/init.d/S70tp-ap), nesta ordem:

1. **espera a `wlan0` aparecer**, até 30 s — o `brcmfmac` carrega o firmware de forma assíncrona, e
   sem a espera o comando seguinte correria antes de a interface existir;
2. desbloqueia o rádio pelo `sysfs`, se houver bloqueio por software;
3. `ip link set wlan0 up`, `ip addr flush`, `ip addr add 192.168.50.1/24` — o `flush` antes do
   `add` é o que faz o `restart` funcionar, em vez de falhar com "File exists";
4. `hostapd -B`;
5. `dnsmasq`.

Quando a `wlan0` não aparece, o script imprime o que olhar: `lsmod | grep brcmfmac`,
`dmesg | grep -i brcmf` e a listagem de `/lib/firmware/brcm/`. Num sistema sem tela de diagnóstico,
essa mensagem é a diferença entre resolver em um minuto e não resolver.

## Decisões que divergem do guia

O guia da disciplina descreve este passo de uma forma que, nesta configuração, não funcionaria.
Cada divergência está comentada no arquivo correspondente:

| O guia indica | O que aconteceria aqui | O que foi adotado |
|---|---|---|
| escrever `auto wlan0 / iface wlan0 inet static` no `/etc/network/interfaces` | o arquivo do guia **apaga a `eth0`**, que é o acesso por cabo e item do checklist do TP anterior; e `auto wlan0` faz o `ifup` do `S40network` falhar, porque a interface só existe depois de o firmware carregar | o endereço é posto pelo `S70tp-ap` com `ip addr add`, exatamente como o próprio script do guia faz |
| nada sobre carregar o `brcmfmac` | sem `mdev`/`eudev`, a `wlan0` nunca apareceria | `brcmfmac` em `/etc/modules-load.d/tp.conf` |
| iniciar o `dnsmasq` dentro do `S70` | o pacote `dnsmasq` instala um `S80dnsmasq` próprio, que subiria uma segunda instância | o `S80dnsmasq` é removido por um `post-build.sh`, e o `S70tp-ap` inicia os dois serviços — o guia prevê este caso e manda desabilitar duplicados |
| `bind-interfaces` no `dnsmasq.conf` | exige que a interface já exista e tenha endereço no instante em que o serviço sobe, e falha de forma definitiva se não | `bind-dynamic`, que acompanha a interface aparecendo |

## Duas escolhas que merecem explicação

**Sem `country_code`.** O `brcmfmac` gerencia o domínio regulatório pelo próprio firmware (CLM), e
um `country_code` que o driver recuse faz o `hostapd` abortar na inicialização. O canal 6 em
2,4 GHz é válido em qualquer domínio. A base regulatória assinada (`wireless-regdb`) **está na
imagem**, em `/lib/firmware/regulatory.db`: se no dia a potência ou o canal precisarem de ajuste,
basta acrescentar `country_code=BR` e `ieee80211d=1` ao `hostapd.conf`, sem recompilar.

**A rede não tem internet.** Não há NAT entre a `wlan0` e a `eth0`, e isso é deliberado: o produto
é autônomo. A consequência prática aparece no dia — um celular com dados móveis ligados detecta
"rede sem internet" e pode preferir a rede celular. Para a demonstração, usar o notebook, ou
desligar os dados móveis antes de conectar, e digitar `http://192.168.50.1` diretamente.

## O que foi conferido sem a placa

| Conferência | Onde |
|---|---|
| `hostapd.conf` e `dnsmasq.conf` aceitos pelos **binários aarch64 da própria imagem**, rodados no host por binfmt/qemu | `scripts/04-build-image.sh` |
| SSID, faixa DHCP e as linhas obrigatórias presentes nos dois arquivos | `scripts/02-configure.sh` e `04` |
| senha WPA2 com tamanho válido (8 a 63 caracteres) | `scripts/02-configure.sh` |
| `hostapd`, `dnsmasq` e `iw` presentes no rootfs | `scripts/04-build-image.sh` |
| os três arquivos de firmware do 43455 resolvem (symlink incluído) e `regulatory.db` está lá | idem |
| `brcmfmac` e `brcmfmac-wcc` instalados, e `brcmfmac` em `modules.dep` e no `modules-load.d` | idem |
| `S70tp-ap` executável, `S80dnsmasq` ausente, nenhum outro script de init de `hostapd`/`dnsmasq` | idem |
| pilha sem fio presente no `.config` do kernel | idem |

O `S70tp-ap` também passou no `sh -n` do BusyBox da própria imagem.

**O que só o hardware demonstra:** que o rádio associa, que o SSID aparece na varredura, que o DHCP
entrega endereço a um cliente real e que o dashboard abre em `http://192.168.50.1`. Está em
[testes.md](testes.md).
