# 📂 Controle de Dados do TCC

## 1. Dados de Mercado (Externos)

| Arquivo / Dado | 1. O que é o dado? | 2. Fonte (Referência) | 3. Como/Por que estou usando? |
| :--- | :--- | :--- | :--- |
| **cmarg001** a **cmarg004** | **Cenários Estocásticos (CMO):** Arquivos contendo 2000 trajetórias de Custo Marginal de Operação (CMO) para cada um dos 4 submercados (SE, S, NE, N). Cada arquivo cobre o horizonte de estudo com valores mensais. | *Dados provenientes de simulação interna utilizando o modelo NEWAVE (Base acadêmica).* | **Proxy de Preço Futuro ($P_{s,t}^{\omega}$):** É a principal entrada de incerteza do modelo. Como o PLD tende a seguir o CMO, utilizamos essas 2000 séries para simular os possíveis futuros de preço e calcular o risco (CVaR) e o retorno esperado das estratégias de *trading*. |
| **PLD_min_max_2017_2026** | **Limites Regulatórios Anuais:** Tabela contendo os valores de Piso (Mínimo) e Teto (Máximo Estrutural) do PLD definidos pela ANEEL para cada ano do horizonte de estudo. | [CCEE - Conceitos de Preços](https://www.ccee.org.br/precos/conceitos-precos) | **Restrição de Preço (Clipping):** O modelo matemático usa esses limites para ajustar os dados do NEWAVE. Se um cenário de CMO ultrapassar o teto ou cair abaixo do piso, ele é "cortado" para respeitar as regras reais de mercado antes do cálculo financeiro. |
| **patamar.dat** | **Fatores de Duração de Patamar:** Matriz de coeficientes que indica a fração do mês correspondente a cada patamar de carga (Leve, Médio, Pesado). A soma dos coeficientes de um mês é sempre igual a 1.0. | *Dados provenientes de simulação interna (Base acadêmica).* | **Conversão Física $\to$ Financeira (MWm $\to$ MWh):** O modelo decide a contratação em Potência (MW médio), mas a liquidação financeira ocorre em Energia (MWh). Utilizamos estes fatores, multiplicados pelas horas totais do mês, para converter o volume contratado na quantidade exata de energia para o cálculo da receita/custo. |

# 2. Dados da Empresa (Usina Hidrelétrica Real)

| Arquivo / Dado | 1. O que é o dado? | 2. Fonte (Referência) | 3. Como/Por que estou usando? |
| :--- | :--- | :--- | :--- |
| **Parcela usina montante mensal** | **Histórico de Geração Real:** Base de dados contendo a geração verificada (`GERACAO_CENTRO_GRAVIDADE`) e a garantia física de usinas do sistema. | [CCEE - Dados Públicos de Medição/Contabilização.](https://dadosabertos.ccee.org.br/dataset/parcela_usina_montante_mensal) | **Modelagem do Ativo ($G_{s,t}$):** Utilizaremos o histórico real da usina (ex: UHE Mascarenhas) para extrair o perfil de sazonalidade típico. A média histórica mensal será projetada para o futuro como a previsão de geração da usina no modelo de otimização. |
| **mscd_energia_nova_preco** | **Preços de Leilão (ACR):** Histórico de preços de fechamento de contratos regulados (CCEAR) por fonte e leilão. |[CCEE - Resultados de Leilões.](https://dadosabertos.ccee.org.br/dataset/mcsd_energia_nova_preco) | **Definição do Contrato Legado ($K^0$):** Para definir o preço da venda já existente na carteira da usina (obrigação inicial), utilizaremos a média real dos preços deste arquivo, simulando que a usina vendeu energia em um leilão passado que precisa ser honrado. |

# 🧪 Dados Derivados / Sintéticos (Construídos)

| Dado Construído | 1. O que é? | 2. Metodologia de Cálculo (Fonte) | 3. Como/Por que estou usando? |
| :--- | :--- | :--- | :--- |
| **Lista de Trades Disponíveis**<br>*(Opportunity Set)* | **Curva de Preços de Mercado ($K^B, K^S$):** Conjunto de preços fixos para contratos de compra e venda disponíveis para cada mês futuro do horizonte de estudo. | **Spread sobre o Valor Esperado:** Calculado a partir da média aritmética dos 2000 cenários de CMO (`cmarg`) acrescida de um *spread* bid/ask (ex: $\pm 5\%$).<br>*Fórmula:* $K_{t} = \text{Média}(P_{t}^{\omega}) \times (1 \pm \text{Spread})$. | **Definição de Mercado:** Como não temos acesso a curvas *forward* proprietárias (ex: DCIDE/BBCE), construímos uma curva de mercado internamente coerente com nossos próprios cenários. O uso do *spread* garante que o modelo só execute trades para **mitigação de risco** (hedge), evitando que ele faça arbitragem puramente especulativa (lucro livre de risco) que ocorreria se usássemos preços desconectados do NEWAVE. |
| **cenarios_final.csv** | **Matriz de Preços Mensais ($P_{s,t}^{\omega}$):** O PLD consolidado por mês, cenário e submercado. | **Média Ponderada:** Agregação dos arquivos `cmarg` e `patamar`.<br>Formula: $P_{mensal} = \sum (P_{pat} \times Dur_{pat})$. | **Input de Preço:** É a variável estocástica central. O modelo lê este arquivo para saber o preço de liquidação no mercado de curto prazo em cada cenário futuro. |
| geracao.csv | Série de Geração do Ativo ($G_{s,t}$): Volume de energia produzido pela usina em cada mês do horizonte futuro. | Simulação Estocástica: Extração da Média ($\mu$) e Desvio Padrão ($\sigma$) dos dados reais de 2024/2025. O modelo sorteia valores de uma Distribuição Normal $N(\mu, \sigma)$ para cada mês do horizonte de estudo (2021-2025), incorporando a variabilidade hidrológica. | Balanço Energético: Define a disponibilidade física incerta. É usado para calcular a exposição ao PLD ($E_{s,t} = G_{s,t} - Contratos$). |
| **contratos_legacy.csv** | **Carteira Inicial ($Q^0, K^0$):** Obrigações contratuais pré-existentes da empresa. | **Preço Médio Histórico:** Calculado a partir da média dos preços de leilão (`mscd`) encontrados (R$ 229,98). Assumimos um volume *flat* de 40 MWm. | **Redutor de Exposição:** Representa o *hedge* natural que a empresa já possui. O modelo busca otimizar apenas o *net* (excedente ou déficit) além deste contrato. |
| **trades.csv** | **Cardápio de Oportunidades ($K^B, K^S$):** Lista de contratos disponíveis para negociação (Swap/Futuros) mês a mês. | **Spread sobre Cenários:** Construído sinteticamente. Calculamos a média dos cenários ($E[P]$) e aplicamos um ágio de 5% para compra e deságio de 5% para venda. Limite de liquidez fixado em 20 MWm. | **Variáveis de Decisão:** O modelo de otimização escolherá quanto comprar ou vender desses contratos para maximizar a utilidade (Retorno - Risco). |

# 🎛️ Tabela Mestra de Parâmetros do Modelo

Esta tabela mapeia cada símbolo matemático da formulação do problema para sua origem prática nos dados processados.

## 1. Conjuntos e Índices (Dimensões do Problema)

| Símbolo | Descrição | Onde está o dado? | Como é definido? |
| :---: | :--- | :--- | :--- |
| $\mathcal{S}$ | **Conjunto de Submercados** | `cenarios_final.csv` (Coluna `submercado`) | Extraído dos arquivos originais do NEWAVE (SE, S, NE, N). |
| $\mathcal{T}$ | **Horizonte de Tempo** | `cenarios_final.csv` (Coluna `data`) | Datas mensais cobrindo o período do estudo (ex: 2017-2021). |
| $\Omega$ | **Conjunto de Cenários** | `cenarios_final.csv` (Coluna `cenario`) | Índices de 1 a 2000, representando as trajetórias simuladas. |
| $\mathcal{A}$ | **Conjunto de Trades Candidatos** | `trades.csv` (Cada linha é um trade $a$) | Cada linha do arquivo representa uma oportunidade de negócio em um mês/submercado específico. |

---

## 2. Parâmetros Estocásticos (Incertezas de Mercado)

| Símbolo | Descrição | Onde está o dado? | Metodologia de Obtenção |
| :---: | :--- | :--- | :--- |
| $P_{s,t}^{\omega}$ | **Preço de Liquidação (PLD)** | 📂 `cenarios_final.csv`<br>*(Coluna `valor`)* | **Média Ponderada:** Processamento dos arquivos brutos `cmarg` (custo marginal) cruzados com `patamar.dat` (duração).<br>Fórmula: $\sum (CMO_{pat} \times Duração_{pat})$. |
| $\pi_{\omega}$ | **Probabilidade do Cenário** | 💻 **No Código** | **Equiprovável:** Como os cenários vêm de uma simulação de Monte Carlo padrão, assume-se probabilidade igual para todos.<br>Valor: $\pi_{\omega} = 1 / 2000$. |

---

## 3. Parâmetros Determinísticos (Ativo, Passivo e Mercado)

| Símbolo | Descrição | Onde está o dado? | Metodologia de Obtenção |
| :---: | :--- | :--- | :--- |
| $G_{s,t}$ | **Geração da Usina (Ativo)** | 📂 `geracao.csv`<br>*(Coluna `geracao_mwm`)* | **Backcasting Sazonal:** Extração do perfil médio mensal (sazonalidade) da usina Mascarenhas (dados reais 2024/25) aplicado ao horizonte passado. |
| $Q_{s,t}^{0}$ | **Quantidade Contratada (Legado)** | 📂 `contratos_legacy.csv`<br>*(Coluna `volume_mwm`)* | **Definição de Cenário:** Volume fixo (ex: 40 MWm) que representa a obrigação contratual pré-existente da empresa. |
| $K^{0}$ | **Preço do Contrato Legado** | 📂 `contratos_legacy.csv`<br>*(Coluna `preco_r_mwh`)* | **Média Histórica:** Média aritmética dos preços de liquidação encontrados nos arquivos de leilão (`mscd`) da CCEE (aprox. R$ 229,98). |
| $K_{a}^{B}$ | **Preço de Compra do Trade** | 📂 `trades.csv`<br>*(Coluna `preco_compra`)* | **Spread de Mercado:** Média dos cenários NEWAVE + Spread (ex: +5%). Representa o preço "Ask" (Venda) do mercado. |
| $K_{a}^{S}$ | **Preço de Venda do Trade** | 📂 `trades.csv`<br>*(Coluna `preco_venda`)* | **Spread de Mercado:** Média dos cenários NEWAVE - Spread (ex: -5%). Representa o preço "Bid" (Compra) do mercado. |
| $\overline{q}_{a}^{B}$ | **Limite Máx. de Compra** | 📂 `trades.csv`<br>*(Coluna `limite_compra`)* | **Parâmetro de Liquidez:** Definido sinteticamente (ex: 20 MWm) para evitar que o modelo compre volumes infinitos. |
| $\overline{q}_{a}^{S}$ | **Limite Máx. de Venda** | 📂 `trades.csv`<br>*(Coluna `limite_venda`)* | **Parâmetro de Liquidez:** Idem acima. |

---

## 4. Parâmetros de Risco e Preferências (Inputs do Usuário)

Estes valores não vêm de arquivos, são "botões" que ajustamos no código para ver como a decisão muda.

| Símbolo | Descrição | Onde está o dado? | Valor Típico / Configuração |
| :---: | :--- | :--- | :--- |
| $\alpha$ | **Nível de Confiança do CVaR** | 💻 **No Código** | **0.95 (95%):** Indica que estamos olhando para a média dos 5% piores cenários. |
| $\lambda$ | **Aversão ao Risco** | 💻 **No Código** | **Variável $[0, \infty)$:** Peso dado ao risco na função objetivo.<br>$\lambda=0$: Neutro ao risco (Maximiza Lucro Médio).<br>$\lambda>0$: Conservador (Sacrifica lucro para reduzir risco). |