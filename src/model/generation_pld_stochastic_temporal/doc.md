Os dois usam os dados com PLD e Geração de energia estocásticos.
A entrada são as X usinas que a "Comercializadora" tem e seus contratos legado.
Ela quer decidir quais trades vai fazer com base no que ele tem de previsão do PLD e da Geração de energia.

A diferença entre os dois modelos é:
- **Determinístico Equivalente**: Decisão "here-and-now" no t0 para todos os períodos futuros. Resolve todos os cenários simultaneamente, mas não permite ajustes ao longo do tempo.
- **SDDP Multi-estágio**: Decisões sequenciais "wait-and-see" mês a mês. Permite ajustar a estratégia conforme a incerteza é revelada, capturando o valor da flexibilidade.

Academicamente, o SDDP é superior por encontrar a política ótima adaptativa. Porém, computacionalmente, o determinístico equivalente é mais rápido (resolve em minutos vs horas), sendo uma aproximação prática quando o tempo de processamento é crítico ou quando a flexibilidade de ajuste tem valor limitado.
---------------------
Deq:

Lambda,Saldo_Final_Milhoes,CVaR_Saldo_Milhoes,Volume_Hedge_MW,Tempo_Segundos
NaN,266.2372722205772,250.5555601898459,0.0,0.0
0.001,266.2372722205771,250.5555601898459,0.0,7.296000003814697
0.005,266.2372722205771,250.55556018984583,0.0,7.244999885559082
0.01,266.2372722205771,250.55556018984583,0.0,6.758000135421753
0.02,266.1892013226583,253.4279154875784,31.26576686275243,7.27400016784668
0.03,266.09744706991086,256.9792047340342,150.1418820460714,7.558000087738037
0.04,266.06097129924467,258.07366911165366,208.10224450327672,7.728999853134155
0.05,266.0557619689176,258.193069368396,213.43301443176392,8.509000062942505
0.1,266.00436402289785,258.823948145725,299.11932945429237,8.467000007629395
0.3,265.87248669115786,259.57384912673143,558.6181409434772,8.724000215530396
0.5,265.8082103243989,259.7362233180112,697.3442430622694,8.871000051498413
0.7,265.77658250883803,259.7891585362188,765.19528443047,9.407000064849854
0.9,265.7609789752537,259.80787861804845,799.6033708945296,10.109999895095825
0.99,265.7543298914229,259.8148806633781,814.9495761317057,11.105999946594238
1.0,265.75366635184395,259.81554743928547,816.5157382827025,11.353000164031982

------------------------------