# 📋 Checklist de Dados: TCC Otimização de Portfólio

## 1. Dados de Mercado (Externos)
Estes são os dados que vêm do "mundo real" ou de simulações de setor.

- [X] **PLD Histórico (Passado)**
    - **Descrição:** Planilha com valores passados do PLD por submercado (Sudeste, Sul, Nordeste, Norte).
    - **Formato:** Data (mensal) x Submercado x Preço (R$/MWh).
    - **Status:** Disponível publicamente (CCEE).

- [X] **Projeções de PLD/CMO (Futuro)**
    - **Descrição:** Séries sintéticas de CMO (Custo Marginal de Operação) do modelo NEWAVE para usar como proxy de preço futuro.
    - **Quantidade:** 2000 cenários.
    - **Variável no Modelo:** $P_{s,t}^{\omega}$ (PLD no cenário $\omega$ para submercado $s$ e mês $t$.
    - **Status:** Crítico (precisa dos decks do NEWAVE ou dados simulados).

- [X] **Probabilidade dos Cenários**
    - **Descrição:** Definir a probabilidade ($\pi_{\omega}$) de cada um dos cenários ocorrer.
    - **Nota:** Geralmente assume-se equiprovável ($1/2000$) se vier de simulação de Monte Carlo.

---

## 2. Dados da Empresa (Internos/Fictícios)
Estes dados definem a "situação inicial" da sua carteira.

- [X] **Carteira de Contratos Existente (Legado)**
    - **Descrição:** Contratos de compra ($Q^{0,B}$) e venda ($Q^{0,S}$) que a empresa já possui.
    - **Necessário para cada contrato:**
        - [X] Quantidade (MWh).
        - [X] Preço fixo (R$/MWh).
        - [X] Período de vigência.
        - [X] Submercado.

- [X] **Previsão de Produção (Geração)**
    - **Descrição:** Quanto a usina vai gerar em cada mês ($G_{s,t}$).
    - **Tipo:** Decidir se será determinística (um valor fixo por mês) ou estocástica (um valor diferente por cenário).

---

## 3. Dados de Oportunidade (O "Mercado de Trades")
Estes dados definem as "opções" de novos contratos que o modelo vai escolher.

- [X] **Lista de Trades Disponíveis**
    - **Descrição:** As oportunidades de mercado.
    - **Necessário definir para cada trade candidato ($a$):**
        - [X] Submercado ($s$) e Mês ($t$).
        - [X] Preço fixo de compra ($K_{a}^{B}$).
        - [X] Preço fixo de venda ($K_{a}^{S}$).
        - [X] Limite máximo de volume de compra ($\overline{q}_{a}^{B}$).
        - [X] Limite máximo de volume de venda ($\overline{q}_{a}^{S}$).

---

## 4. Parâmetros de Risco (Configuração)
Ajustes finos da função objetivo.

- [X] **Nível do CVaR ($\alpha$)**
    - **Descrição:** O percentual de corte para o cálculo de risco (ex: 0.95).

- [X] **Aversão ao Risco ($\lambda$)**
    - **Descrição:** O peso dado ao risco na função objetivo. Quanto maior, mais conservador o modelo será.


--------------------------
- [X] Olhar os outros TCC/Mestrado/Doutorado na parte dos experiemtnos/geração de dados
- [X] Implementar o modelo determinisco equivalente

-----

- [X] exportar .lp e validar na mao (pra ver se ta rolando)

-----

- [X] refatorar o código melhorando a legibilidade & tentando igualar com o projeto
- [X] ampliar para várias usinas
- [X] ampliar para vários submercados
- [N/A] modelar trade entre submercados diferentes ****
    - "Contratos são liquidados localmente por submercado, não havendo arbitragem física entre eles"
- [ ] adicionar métricas de tempo de execução da otimização

- [ ] comparar com os outros trabalhos

-----

- [ ] Fazer policy graph
- [ ] Rodar sddp

----

- FUTURO:
    - [ ] Amplicar o escopo pra POV da comercializadora
    - [ ] Checar como os preços de contrato (futuro) são feitos

-----------------
- [X] Implementar modelo determinístico equivalente
- [X] Refatorar código
- [X] Ampliar para várias usinas
- [X] Ampliar para vários submercados
- [N/A] Trade entre submercados
- [X] ⏱️ Métricas de tempo ← **PRÓXIMO**
- [X] 📊 Gerar gráficos/visualizações
- [X] 📚 Comparar com literatura
- [X] 🎯 SDDP
- [X] Adicionar saldo no SDDP e no JuMP
- [] Revisar a modelagem matemática (.tex), separando SDDP de JuMP

- [] Reescrever a modelagem usada no SDDP e as gerações de dados. (I/O, Considerações).
- [] Avaliar cenários práticos que façam sentido pra fazer um paper de discussão dos cenários com SDDP.
--------------------
- [X] Faz um toy 
- [X] Se certificar de que o sddp_multiestagio e o det_eq estão corretos. !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
- [X] Escrever modelagem do SDDP (policy graph)
- [X] Escrever modelagem do policy_graph
- [X] Gerador de PLD
- [] Testar os limites do DEQ
- [] Comparar o desempenho do DEQ com SDDP pro que o DEQ consegue resolver