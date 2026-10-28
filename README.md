# TP Aula 8 — Buildroot + Docker + Flask na Raspberry Pi 4

Sistemas Embarcados · Engenharia de Computação · UNISANTA · Prof. Sergio Schina
Grupo: **G03**

| Integrante | RA |
|---|---|
| Pedro Cretella | 226013 |
| Pedro Brito | 226146 |
| Vinícius Regis | 230610 |
| Rafael Lima | 226326 |

## Objetivo

Gerar, com o Buildroot, uma imagem Linux para a Raspberry Pi 4 que ao ligar inicie o sistema,
permita login com o usuário do projeto, suba o Docker automaticamente, carregue um container Flask
embarcado na própria imagem e publique a aplicação em `http://IP_DA_RASPBERRY:5000` — sem nenhum
comando manual e sem acesso à internet.

## Alvo

| Item | Valor |
|---|---|
| Buildroot | 2026.08.1 |
| Placa / defconfig base | Raspberry Pi 4 Model B · `raspberrypi4_64_defconfig` |
| Arquitetura | AArch64 (Cortex-A72) |
| Init | BusyBox init (SysV) |
| Hostname | `rpi4-tp8-g03` |
| Usuário de login | `aluno` (UID 1000, membro do grupo `docker`) |

## Estrutura

```
tp8.env                       parâmetros do grupo: grupo, integrantes, hostname, usuário, senhas
scripts/                      automação do build (dependências do host, Buildroot, configuração)
br2-external/                 árvore BR2_EXTERNAL (name: TP8) com tudo que é do nosso produto
└── board/tp8/rpi4/
    ├── identidade.fragment   hostname e senha de root     (gerado a partir do tp8.env)
    └── users_table.txt       usuário do projeto           (gerado a partir do tp8.env)
```

A customização fica toda fora da árvore do Buildroot, via `BR2_EXTERNAL`, overlay e defconfig.
Nada é editado dentro de `buildroot/` ou em `output/target`: assim o Buildroot pode ser atualizado
ou baixado de novo sem perder o trabalho do grupo, e o build é reproduzível a partir do repositório.

O `tp8.env` é o único arquivo com parâmetros do grupo. Os demais arquivos marcados como "gerado"
são produzidos a partir dele, para que grupo, hostname, usuário e banner nunca fiquem divergentes
entre si.

## O que não é versionado, e por quê

| Fora do Git | Motivo |
|---|---|
| `buildroot/`, `output-rpi4/`, `*.img` | artefatos de build, reconstruídos pelos scripts |
| `flask-tp8.tar` (48 MB) | artefato de build, não código-fonte (ver abaixo) |

A imagem do container é gerada pelo build, não escrita por nós: o que define o container é o
`Dockerfile` com as versões fixas da imagem base e do Flask, mais o `app.py` e o
`requirements.txt` — e esses três **estão** versionados. Guardar também o `.tar` acrescentaria
48 MB binários ao histórico do Git a cada vez que a imagem fosse reconstruída, sem acrescentar
informação: qualquer pessoa com o repositório gera a imagem de novo.

O que o Git não consegue garantir é que o arquivo regerado seja idêntico ao entregue — build de
Docker não é reprodutível byte a byte (timestamps e metadados de instalação variam). Por isso o
SHA-256 do artefato efetivamente entregue é registrado em `evidence/hashes.txt`: ele
identifica qual tar gerou a imagem apresentada.

## Em desenvolvimento

Este repositório está sendo construído por etapas. O histórico de commits acompanha a ordem do
guia: configuração inicial, estrutura `BR2_EXTERNAL`, usuário e identidade, overlay, Docker,
aplicação Flask, container, inicialização automática, rede e versão final.
