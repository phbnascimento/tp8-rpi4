# Inclui a receita de cada pacote deste BR2_EXTERNAL.
#
# O wildcard evita ter que listar pacote a pacote; o sort deixa a ordem
# determinística, que é o que o Buildroot espera e o que mantém o build
# reproduzível independentemente da ordem em que o sistema de arquivos
# devolve os nomes.
include $(sort $(wildcard $(BR2_EXTERNAL_TP_PATH)/package/*/*.mk))
