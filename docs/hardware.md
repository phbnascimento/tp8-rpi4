# Hardware — HC-SR04 na Raspberry Pi 4

Documento das ligações elétricas do sensor ultrassônico e da adequação de nível obrigatória no
pino ECHO.

## Ligações

| HC-SR04 | Função | Raspberry Pi 4 | Pino físico |
|---|---|---|---|
| VCC | Alimentação | 5 V | 2 |
| TRIG | Entrada de disparo | GPIO23 (BCM) | 16 |
| ECHO | Saída do eco | GPIO24 (BCM), **via divisor** | 18 |
| GND | Terra | GND | 6 |

O sensor precisa de 5 V para funcionar: o transdutor ultrassônico não opera de forma confiável em
3,3 V. Por isso o VCC vai no pino 2, e não num pino de 3,3 V.

## Adequação de nível no ECHO — obrigatória

O HC-SR04 devolve o pulso de eco em **5 V**. As entradas GPIO da Raspberry Pi 4 toleram no máximo
**3,3 V**: elas não são tolerantes a 5 V, e aplicar essa tensão pode danificar permanentemente o
pino ou o SoC. Ligar ECHO diretamente ao GPIO24 é considerado montagem tecnicamente incorreta.

A adequação é feita com um divisor resistivo:

```
HC-SR04 ECHO ──────┐
                   │
                  ┌┴┐
                  │ │ R1 = 1 kΩ
                  └┬┘
                   ├──────────► GPIO24 (pino 18)
                  ┌┴┐
                  │ │ R2 = 2 kΩ
                  └┬┘
                   │
                  GND (pino 6)
```

A tensão no ponto central é:

```
V_GPIO = V_ECHO × R2 / (R1 + R2)
V_GPIO = 5 V × 2 kΩ / (1 kΩ + 2 kΩ)
V_GPIO ≈ 3,33 V
```

Fica dentro da faixa aceita pelo GPIO e acima do limiar de nível alto, então o pino continua
lendo o pulso corretamente.

O TRIG **não** precisa de divisor: ali a Raspberry é quem envia o sinal, em 3,3 V, e o HC-SR04
reconhece esse nível como alto na sua entrada.

## Por que GPIO23 e GPIO24

São pinos de uso geral, sem função alternativa ocupada por outro periférico: não conflitam com
I²C (GPIO2/3), SPI (GPIO7-11) nem UART (GPIO14/15). Ficam fisicamente adjacentes, nos pinos 16 e
18, o que simplifica a ligação na protoboard e reduz risco de engano. São também os pinos
definidos pelo enunciado do TP.

Os números não aparecem fixos no código do driver: eles são descritos no Device Tree e obtidos
pelo driver através da API de GPIO descriptors.

## Princípio de funcionamento

1. A Raspberry gera um pulso de disparo no TRIG.
2. O HC-SR04 emite um trem de pulsos ultrassônicos em 40 kHz.
3. Quando o eco retorna, o sensor coloca o ECHO em nível alto por um tempo proporcional ao tempo
   de voo da onda.
4. O driver mede a duração desse pulso e converte em distância.

A conversão usa a velocidade do som no ar, cerca de 343 m/s, e divide por dois, porque o som
percorre o caminho de ida e volta:

```
distância_mm ≈ Δt_µs × 343 / 2000
```

## Cuidados de montagem

- Conferir a ligação **antes** de energizar: 5 V no pino errado danifica a placa.
- O divisor precisa estar montado antes do primeiro teste, não depois.
- Alimentação da Raspberry por fonte adequada: o sensor consome pouco, mas uma fonte fraca causa
  reinícios que parecem falha de software.
- Manter o sensor apontado para uma superfície livre durante os testes; obstáculos muito próximos
  (abaixo de ~2 cm) ficam fora da faixa útil do módulo.
