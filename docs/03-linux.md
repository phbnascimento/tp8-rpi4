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

## Um achado que vale conhecer

Pedir `=y` num fragment **não garante** que a opção fique embutida. O kconfig rebaixa em silêncio
para `=m` quando uma dependência é módulo. É o que acontece aqui:

```
CONFIG_BRIDGE tem "depends on IPV6 || IPV6=n"
o bcm2711_defconfig traz CONFIG_IPV6=m
→ CONFIG_BRIDGE e CONFIG_BRIDGE_NETFILTER saem como =m, mesmo pedindo =y
```

Isso é seguro neste projeto: o alvo tem `kmod` (`/sbin/modprobe`), o `depmod` roda durante o build
e o `liblzma` está no rootfs, então o `dockerd` carrega `bridge.ko.xz` e `br_netfilter.ko.xz` sob
demanda. O `check-config.sh` do próprio Docker aceita a resposta *as module*. Forçar built-in
exigiria `CONFIG_IPV6=y`, o que não compensa.

O perigo do rebaixamento silencioso é não perceber que aconteceu. Por isso o
`scripts/04-build-image.sh` roda o `check-config.sh` distribuído com o `docker-engine` contra o
`.config` gerado e falha se faltar algo da seção *Generally Necessary*. A saída fica em
[../evidence/build/kernel-check-config.txt](../evidence/build/kernel-check-config.txt).

Na Raspberry, a verificação equivalente é o `docker info`: recursos ausentes aparecem como linhas
`WARNING: No ... support`.
