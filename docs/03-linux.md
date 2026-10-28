# 03 — Kernel Linux

O container compartilha o kernel da Raspberry. Se faltar um recurso aqui, o `dockerd` não sobe, ou
sobe e falha ao criar a rede do container. Por isso o projeto aplica um fragment de kernel por cima
do `bcm2711_defconfig`.

```
Configuração: Kernel → Additional configuration fragment files
Símbolo:      BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=
              "$(BR2_EXTERNAL_TP8_PATH)/board/tp8/rpi4/linux-docker.fragment"
Motivo:       garantir namespaces, cgroups, veth, bridge, netfilter/NAT e
              overlayfs, que o Docker exige do kernel hospedeiro.
Dependências: o fragment é mesclado sobre o defconfig do kernel pelo próprio
              Buildroot, antes de compilar.
Impacto:      kernel um pouco maior e mais tempo de compilação; sem ele o
              Docker não funciona na placa.
```

## O que cada grupo de opções faz

| Grupo | Símbolos | Para quê |
|---|---|---|
| Namespaces | `NAMESPACES`, `UTS_NS`, `IPC_NS`, `PID_NS`, `NET_NS`, `USER_NS` | isolar processos, rede, hostname e IPC do container |
| Control groups | `CGROUPS`, `CPUSETS`, `MEMCG`, `CGROUP_PIDS`, `CGROUP_DEVICE`, `CGROUP_FREEZER`, `CGROUP_SCHED`, `CGROUP_CPUACCT` | limitar e contabilizar CPU, memória e processos |
| eBPF | `BPF_SYSCALL`, `CGROUP_BPF` | no cgroup v2 o controle de dispositivos do `runc` é feito por eBPF |
| Segurança | `KEYS`, `SECCOMP`, `SECCOMP_FILTER`, `POSIX_MQUEUE` | perfil seccomp padrão do Docker |
| Rede do container | `VETH`, `BRIDGE`, `BRIDGE_NETFILTER` | par veth ligando o container à bridge `docker0` |
| Netfilter / NAT | `NETFILTER`, `NF_CONNTRACK`, `NF_NAT`, `IP_NF_*`, `IP6_NF_*`, `NETFILTER_XT_*` | publicar a porta com `-p 5000:5000` (DNAT e masquerade) |
| Armazenamento | `OVERLAY_FS` | driver `overlay2`, usado pelo Docker para as camadas |

As opções `IP_NF_*` são da família *legacy* (xtables) porque o `iptables` que o Buildroot instala
junto com o `docker-engine` é o legacy, não o `nft`.

## Como sabemos que o kernel ficou correto

Parte desses recursos pode ficar como módulo em vez de embutida no kernel, o que é suportado: o
sistema carrega o módulo quando o Docker precisa dele.

Para não depender de inspeção manual, o `scripts/04-build-image.sh` roda a verificação que o
próprio Docker distribui contra o kernel gerado, e falha se faltar algum recurso obrigatório. A
saída fica em [../evidence/build/kernel-check-config.txt](../evidence/build/kernel-check-config.txt).

Na Raspberry, a verificação equivalente é o `docker info`: recursos ausentes apareceriam como
avisos.
