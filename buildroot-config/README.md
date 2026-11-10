# buildroot-config

Cópia da configuração Buildroot do projeto, no formato `defconfig`, para quem quiser
inspecionar a configuração sem navegar pela árvore `BR2_EXTERNAL`.

## Atenção: esta cópia é gerada

O arquivo canônico é:

```
br2-external/configs/tp_rpi4_defconfig
```

É ele que o Buildroot carrega (`make tp_rpi4_defconfig` com `BR2_EXTERNAL` apontando para
`br2-external/`), e é ele que o `make savedefconfig` reescreve. O arquivo deste diretório é uma
cópia que o `scripts/02-configure.sh` regrava a cada execução.

**Não edite nenhum dos dois à mão.** A configuração nasce de:

| Fonte | O que define |
|---|---|
| `tp.env` | grupo, hostname, usuário, senhas, versão do Buildroot |
| `br2-external/board/tp/rpi4/buildroot.fragment` | opções do Buildroot do projeto |
| `br2-external/board/tp/rpi4/identidade.fragment` | hostname e senha de root (gerado do `tp.env`) |
| `br2-external/board/tp/rpi4/linux-docker.fragment` | opções de kernel para containers |

O `scripts/02-configure.sh` carrega a `raspberrypi4_64_defconfig` oficial da Raspberry Pi 4,
mescla os fragments por cima, confere se as opções essenciais sobreviveram às dependências do
kconfig e só então salva a defconfig — testando, ao final, se recarregá-la reproduz o mesmo
`.config`.
