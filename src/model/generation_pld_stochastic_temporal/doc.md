Os dois usam os dados com PLD e Geração de energia estocásticos.
A entrada são as X usinas que a "Comercializadora" tem e seus contratos legado.
Ela quer decidir quais trades vai fazer com base no que ele tem de previsão do PLD e da Geração de energia.

A diferença entre os dois modelos é:
- **Determinístico Equivalente**: Decisão "here-and-now" no t0 para todos os períodos futuros. Resolve todos os cenários simultaneamente, mas não permite ajustes ao longo do tempo.
- **SDDP Multi-estágio**: Decisões sequenciais "wait-and-see" mês a mês. Permite ajustar a estratégia conforme a incerteza é revelada, capturando o valor da flexibilidade.

Academicamente, o SDDP é superior por encontrar a política ótima adaptativa. Porém, computacionalmente, o determinístico equivalente é mais rápido (resolve em minutos vs horas), sendo uma aproximação prática quando o tempo de processamento é crítico ou quando a flexibilidade de ajuste tem valor limitado.