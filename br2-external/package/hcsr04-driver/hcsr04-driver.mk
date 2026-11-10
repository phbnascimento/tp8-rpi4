################################################################################
#
# hcsr04-driver
#
# Driver do sensor ultrassônico HC-SR04, compilado como módulo externo contra
# o kernel do próprio projeto.
#
################################################################################

HCSR04_DRIVER_VERSION = 1.0
HCSR04_DRIVER_SITE = $(BR2_EXTERNAL_TP_PATH)/package/hcsr04-driver/src
HCSR04_DRIVER_SITE_METHOD = local
HCSR04_DRIVER_LICENSE = GPL-2.0

# A ordem dos dois eval é exigida pelo Buildroot. O manual (seção "kernel-module
# reference") diz que a infraestrutura kernel-module "is not stand-alone, and
# requires any of the other *-package macros be called after it": ela sozinha só
# registra hooks de post-build e post-install para compilar e instalar o módulo,
# e quem transforma isso nas etapas do pacote é o generic-package, chamado
# depois. Por isso também não é preciso declarar "linux" em DEPENDENCIES — o
# kernel-module acrescenta sozinho.
$(eval $(kernel-module))
$(eval $(generic-package))
