# 06 — Procedimento de compilação

O critério do TP é: *outro aluno conseguiria reconstruir a imagem usando apenas este repositório e
esta documentação?* O que segue é o caminho completo, do clone ao cartão gravado.

## Pré-requisitos do host

PC com Linux x86_64, cerca de 30 GB livres e Docker funcionando. O projeto foi construído em
CachyOS (Arch); o `scripts/00-setup-host.sh` também suporta Debian/Ubuntu.

Como o host é x86_64 e a imagem do container é ARM64, é preciso emulação: o script registra o
`binfmt`/QEMU (`qemu-aarch64`) e cria um builder `buildx` que ofereça `linux/arm64`.

## Passo a passo

```bash
git clone <URL do repositório> tp8-rpi4
cd tp8-rpi4

# 1. dependências do host, Docker, buildx e emulação ARM64 (usa sudo)
./scripts/00-setup-host.sh

# 2. baixa o Buildroot na versão do tp8.env
./scripts/01-fetch-buildroot.sh

# 3. edite o tp8.env: grupo, integrantes, hostname, usuário e senhas

# 4. aplica o tp8.env e os fragments, salva e testa a defconfig
./scripts/02-configure.sh

# 5. constrói a imagem ARM64 do container e coloca o tar no overlay
./scripts/03-build-flask-image.sh

# 6. compila a imagem do sistema
./scripts/04-build-image.sh

# 7. grava o microSD
./scripts/05-flash-sd.sh
```

A ordem entre `02` e `03` é indiferente, mas **os dois têm que rodar antes do `04`**: é o `03` que
deposita o `flask-tp8.tar` no overlay, e é o `04` que o assa dentro da imagem.

## O que cada script faz

| Script | Função | Precisa de sudo |
|---|---|---|
| `00-setup-host.sh` | pacotes de build, Docker, `buildx`, binfmt ARM64 | sim |
| `01-fetch-buildroot.sh` | baixa e extrai o Buildroot em `buildroot/` | não |
| `02-configure.sh` | gera identidade, mescla fragments, salva e testa a defconfig, grava `VERSION` e `buildroot-config/` | não |
| `03-build-flask-image.sh` | `docker buildx` ARM64, testa o container, exporta o tar, registra o hash | não (precisa do grupo `docker`) |
| `04-build-image.sh` | `make` do Buildroot, confere o rootfs gerado, registra o hash | não |
| `05-flash-sd.sh` | grava `sdcard.img` no cartão com dupla confirmação | sim (apenas o `dd`) |

Nenhuma etapa do build roda como root. O `lib.sh` recusa execução com `sudo`.

## Tempos observados

| Operação | Tempo |
|---|---|
| Build completo (20 núcleos) | cerca de 30 minutos |
| Rebuild incremental após mudar o overlay | 14 a 60 segundos |
| `03` com cache do Docker quente | poucos segundos |

O primeiro build baixa toolchain, kernel, Go e Docker — em máquina mais modesta ou rede lenta pode
passar de uma hora. Se for interrompido, basta rodar de novo: ele continua de onde parou.

## Conferências automáticas

O `04` não termina sem verificar o artefato real, lendo o `images/rootfs.ext4` com `debugfs`:

- `aluno` e grupo `docker` presentes em `/etc/passwd` e `/etc/group`
  (prova em [../evidence/build/usuarios-na-imagem.txt](../evidence/build/usuarios-na-imagem.txt));
- `wait-delay` presente no `/etc/network/interfaces`;
- `S60dockerd`, `S99flask-tp8`, `flask-tp8.tar`, `docker` e `curl` no lugar;
- kernel aprovado no `check-config.sh` do Docker
  (saída em [../evidence/build/kernel-check-config.txt](../evidence/build/kernel-check-config.txt));
- espaço livre suficiente no rootfs para o `docker load` do primeiro boot.

A verificação é feita na imagem gerada, e não no diretório intermediário de build: só a imagem é o
artefato real, e é nela que o usuário existe.

## Artefatos e hashes

| Artefato | Caminho | Tamanho |
|---|---|---|
| Imagem do container | `br2-external/board/tp8/rpi4/rootfs-overlay/opt/docker/flask-tp8.tar` | 48 MB |
| Imagem do cartão | `output-rpi4/images/sdcard.img` | 1,1 GB |

Os SHA-256 de ambos ficam em [../evidence/hashes.txt](../evidence/hashes.txt), reescritos a cada
geração. Nenhum dos dois vai para o Git: são artefatos de build.

Vale registrar o limite disso: build de Docker **não** é reprodutível byte a byte — timestamps e
metadados de instalação variam entre execuções. Reconstruir o projeto gera uma imagem equivalente e
funcional, mas com hash diferente. Por isso o hash serve para identificar o artefato **entregue**,
não para validar uma reconstrução.
