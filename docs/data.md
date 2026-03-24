# 📂 Controle de Dados do TCC

## 1. Dados de Mercado (Externos)

| Arquivo / Dado | 1. O que é o dado? | 2. Fonte (Referência) | 3. Como/Por que estou usando? |
| :--- | :--- | :--- | :--- |
| **cmarg001** a **cmarg004** | **Cenários Estocásticos (CMO):** Arquivos contendo 2000 trajetórias de Custo Marginal de Operação (CMO) para cada um dos 4 submercados (SE, S, NE, N). Cada arquivo cobre o horizonte de estudo com valores mensais. | *Dados provenientes de simulação interna utilizando o modelo NEWAVE (Base acadêmica).* | **Proxy de Preço Futuro ($P_{s,t}^{\omega}$):** É a principal entrada de incerteza do modelo. Como o PLD tende a seguir o CMO, utilizamos essas 2000 séries para simular os possíveis futuros de preço e calcular o risco (CVaR) e o retorno esperado das estratégias de *trading*. |
| **PLD_min_max_2017_2026** | **Limites Regulatórios Anuais:** Tabela contendo os valores de Piso (Mínimo) e Teto (Máximo Estrutural) do PLD definidos pela ANEEL para cada ano do horizonte de estudo. | [CCEE - Conceitos de Preços](https://www.ccee.org.br/precos/conceitos-precos) | **Restrição de Preço (Clipping):** O modelo matemático usa esses limites para ajustar os dados do NEWAVE. Se um cenário de CMO ultrapassar o teto ou cair abaixo do piso, ele é "cortado" para respeitar as regras reais de mercado antes do cálculo financeiro. |
| **patamar.dat** | **Fatores de Duração de Patamar:** Matriz de coeficientes que indica a fração do mês correspondente a cada patamar de carga (Leve, Médio, Pesado). A soma dos coeficientes de um mês é sempre igual a 1.0. | *Dados provenientes de simulação interna (Base acadêmica).* | **Conversão Física $\to$ Financeira (MWm $\to$ MWh):** O modelo decide a contratação em Potência (MW médio), mas a liquidação financeira ocorre em Energia (MWh). Utilizamos estes fatores, multiplicados pelas horas totais do mês, para converter o volume contratado na quantidade exata de energia para o cálculo da receita/custo. |
PLD HISTÓRICO obtido aqui:  https://www.ccee.org.br/en/precos/painel-precos
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
| $\lambda$ | **Aversão ao Risco** | 💻 **No Código** | **Variável $[0, \infty)$:** Peso dado ao risco na função objetivo.<br>$\lambda=0$: Neutro ao risco (Maximiza Lucro Médio).<br>$\lambda>0$: Conservador (Premia lucro nos piores cenários). |

---

# 💻 Documentação do Código de Otimização

## Arquivo: `deterministico_equivalente.jl`

Este arquivo implementa o modelo de otimização estocástica com CVaR descrito na Seção 4 do documento `Projeto.tex`.

---

## 1️⃣ Conjuntos do Modelo (Seção 4.2)

Os conjuntos matemáticos são implementados como estruturas de dados Julia:

| Símbolo Matemático | Nome no Código | Tipo | Descrição | Onde é Construído |
|:---:|:---|:---|:---|:---|
| $\mathcal{S}$ | `submercados` | `Vector{String}` | Lista de submercados (ex: "SE", "S", "NE", "N") | `build_optimization_cache()` |
| $\mathcal{T}^F$ | `meses_futuros` | `Vector{Date}` | Datas mensais do horizonte de estudo (ordenadas) | `build_optimization_cache()` |
| $\mathcal{A}$ | `trades_disponiveis` | `UnitRange{Int}` | Índices dos trades candidatos (1:N, onde N = número de linhas em `trades.csv`) | `build_optimization_cache()` |
| $\Omega$ | `cenarios_preco` | `UnitRange{Int}` | Índices dos cenários estocásticos (1:2000) | `build_optimization_cache()` |

### Código de Construção:

```julia
function build_optimization_cache(data::MarketData)::OptimizationCache
    # Extração dos conjuntos a partir dos dados carregados
    meses_futuros = sort(unique(data.cenarios.data))           # 𝒯^F
    submercados = unique(data.cenarios.submercado)             # 𝒮
    trades_disponiveis = 1:nrow(data.trades)                   # 𝒜
    num_cenarios = maximum(data.cenarios.cenario)              # |Ω|
    cenarios_preco = 1:num_cenarios                            # Ω
    
    # ... resto da função
end
```



---

## 2️⃣ Parâmetros do Modelo (Seção 4.3)

Os parâmetros matemáticos são extraídos dos dados e armazenados no `OptimizationCache`:

| Símbolo Matemático | Nome no Código | Tipo | Descrição | Onde é Construído |
|:---:|:---|:---|:---|:---|
| $\pi_\omega$ | `probabilidade_cenario` | `Float64` | Probabilidade de cada cenário (1/2000) | `build_optimization_cache()` |
| $P^\omega_{s,t}$ | `pld_cenario` | `Dict{(Date,String,Int), Float64}` | PLD por (mês, submercado, cenário) | `build_optimization_cache()` |
| $G_{s,t}$ | `producao_usina` | `Dict{(Date,Int), Float64}` | Geração da usina por (mês, código_usina) | `build_optimization_cache()` |
| $Q^{0,B}_{s,t}$ | `volume_compra_existente` | `Dict{(Date,String), Float64}` | Volume de compras já existentes por (mês, submercado) | `build_optimization_cache()` |
| $Q^{0,S}_{s,t}$ | `volume_venda_existente` | `Dict{(Date,String), Float64}` | Volume de vendas já existentes por (mês, submercado) | `build_optimization_cache()` |
| $K^{0,B}_{s,t}$ | `preco_compra_existente` | `Dict{(Date,String), Float64}` | Preço médio ponderado das compras existentes | `build_optimization_cache()` |
| $K^{0,S}_{s,t}$ | `preco_venda_existente` | `Dict{(Date,String), Float64}` | Preço médio ponderado das vendas existentes | `build_optimization_cache()` |
| $K^B_a$ | `preco_compra_trade` | `Vector{Float64}` | Preço de compra do trade `a` | `solve_cvar_model()` |
| $K^S_a$ | `preco_venda_trade` | `Vector{Float64}` | Preço de venda do trade `a` | `solve_cvar_model()` |
| $\overline{q}^B_a$ | `limite_compra_trade` | `Vector{Float64}` | Limite máximo de compra do trade `a` | `solve_cvar_model()` |
| $\overline{q}^S_a$ | `limite_venda_trade` | `Vector{Float64}` | Limite máximo de venda do trade `a` | `solve_cvar_model()` |
| $\alpha$ | `alpha` | `Float64` | Nível de confiança do CVaR (0.95) | `FrontierConfig` |
| $\lambda$ | `λ` | `Float64` | Peso do risco (parâmetro variável) | Argumento de `solve_cvar_model()` |

### Código de Extração dos Contratos Existentes:

```julia
# Extração de volumes e preços dos contratos já existentes
for t in meses_futuros, s in submercados
    contratos_mes = filter(row -> row.data == t && row.submercado == s, data.contratos_existentes)
    
    # Contratos de COMPRA
    compras = filter(row -> row.tipo == "COMPRA", contratos_mes)
    if nrow(compras) > 0
        volume_compra_existente[(t,s)] = sum(compras.volume_mwm)
        # Preço médio ponderado pelo volume
        preco_compra_existente[(t,s)] = sum(compras.volume_mwm .* compras.preco_r_mwh) / sum(compras.volume_mwm)
    else
        volume_compra_existente[(t,s)] = 0.0
        preco_compra_existente[(t,s)] = 0.0
    end
    
    # Contratos de VENDA (análogo)
    # ...
end
```

### Observações:
- **Preço Médio Ponderado:** Quando há múltiplos contratos no mesmo (mês, submercado), calcula-se a média ponderada pelo volume
- **Valores Padrão:** Se não há contratos de um tipo, volume e preço são definidos como 0.0
- **Fonte dos Dados:** Arquivo `contratos_legacy.csv` contém as colunas `volume_mwm` e `preco_r_mwh`

---

## 3️⃣ Cálculo do Lucro por Cenário (Seção 4.7)

O lucro é calculado em **3 partes**, conforme a formulação matemática:

### Parte 1: Lucro dos Contratos Já Existentes (Constante)

```julia
lucro_contratos_existentes = 0.0
for mes in cache.meses_futuros, submercado in cache.submercados
    horas_no_mes = horas_mes(mes)
    # K^{0,S}_{s,t} * Q^{0,S}_{s,t}: receita das vendas existentes
    receita_venda = get(cache.preco_venda_existente, (mes,submercado), 0.0) * get(cache.volume_venda_existente, (mes,submercado), 0.0) * horas_no_mes
    # K^{0,B}_{s,t} * Q^{0,B}_{s,t}: custo das compras existentes
    custo_compra = get(cache.preco_compra_existente, (mes,submercado), 0.0) * get(cache.volume_compra_existente, (mes,submercado), 0.0) * horas_no_mes
    lucro_contratos_existentes += receita_venda - custo_compra
end
```

**Características:**
- ✅ Valor **constante** (não depende das variáveis de decisão)
- ✅ Representa obrigações contratuais pré-existentes
- ✅ Não afeta a solução ótima, mas é importante para o lucro total real

### Parte 2: Lucro dos Novos Trades (Variável de Decisão)

```julia
lucro_novos_trades = AffExpr(0.0)
for trade in cache.trades_disponiveis
    horas_no_mes = horas_mes(data.trades.data[trade])
    # K^S_a * q^S_a - K^B_a * q^B_a
    add_to_expression!(lucro_novos_trades, 
        (volume_venda_trade[trade] * preco_venda_trade[trade] - volume_compra_trade[trade] * preco_compra_trade[trade]) * horas_no_mes)
end
```

**Características:**
- ✅ Depende das **variáveis de decisão** `volume_compra_trade[a]` e `volume_venda_trade[a]`
- ✅ Representa as decisões de hedge que o modelo otimiza

### Parte 3: Lucro da Exposição ao PLD (Estocástico)

```julia
# Inicializa lucro_cenario com as partes 1 e 2
@expression(model, lucro_cenario[cenario in cache.cenarios_preco], lucro_contratos_existentes + lucro_novos_trades)

# Adiciona a parte estocástica (exposição ao PLD)
for mes in cache.meses_futuros, submercado in cache.submercados
    horas_no_mes = horas_mes(mes)
    # G_{s,t}: produção da usina
    producao = (submercado == "SE" ? get(cache.producao_usina, (mes, 202), 0.0) : 0.0)
    # Q^{0,B}_{s,t}: compras já existentes
    compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
    # Q^{0,S}_{s,t}: vendas já existentes
    venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
    
    # Agregação dos volumes dos novos trades (Seção 4.5)
    indices_trades_mes_submercado = cache.indices_trades_por_mes_submercado[(mes,submercado)]
    volume_compra_agregado = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_compra_trade[trade] for trade in indices_trades_mes_submercado)
    volume_venda_agregado = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_venda_trade[trade] for trade in indices_trades_mes_submercado)
    
    # E^{ω}_{s,t}: Exposição ao PLD (Seção 4.6)
    # E = G + Q^{0,B} + Q^{B} - Q^{0,S} - Q^{S}
    exposicao_pld = producao + compra_existente + volume_compra_agregado - venda_existente - volume_venda_agregado
    
    # Para cada cenário, adiciona: E * P^ω_{s,t}
    for cenario in cache.cenarios_preco
        pld = get(cache.pld_cenario, (mes, submercado, cenario), 0.0)
        add_to_expression!(lucro_cenario[cenario], exposicao_pld * horas_no_mes * pld)
    end
end
```

**Características:**
- ✅ Valor **estocástico** (varia por cenário)
- ✅ Representa o risco de mercado (incerteza do PLD)
- ✅ É a razão pela qual o CVaR é necessário

### Lucro Total por Cenário:

```julia
lucro_cenario[ω] = Parte1 + Parte2 + Parte3
                 = lucro_contratos_existentes + lucro_novos_trades + exposicao_pld * PLD^ω
```

---

## 4️⃣ Restrições CVaR (Seção 4.8)

O CVaR (Conditional Value-at-Risk) é implementado através de variáveis auxiliares e restrições lineares:

### Variáveis Auxiliares:

```julia
# η: Value-at-Risk (quantil (1-α) dos lucros)
@variable(model, VaR)
# ξ_ω: desvio acima do VaR para cada cenário
@variable(model, desvio_perda_cenario[cenario in cache.cenarios_preco] >= 0)
```

### Restrições:

```julia
# Para cada cenário: ξ_ω >= η - R^ω
@constraint(model, restricao_cvar[cenario in cache.cenarios_preco], 
    desvio_perda_cenario[cenario] >= VaR - lucro_cenario[cenario])
```

**Nota Importante:**
- O modelo trabalha diretamente com **LUCROS** (não inverte sinal)
- η = VaR dos lucros (quantil dos piores lucros)
- ξ_ω = quanto o cenário fica abaixo do VaR
- CVaR = lucro médio nos piores cenários (quanto MAIOR, melhor)

---

## 5️⃣ Função Objetivo (Seção 4.9)

A função objetivo combina retorno esperado e premia lucro nos piores cenários:

```julia
# E[R^ω]: retorno esperado (média dos lucros em todos os cenários)
@expression(model, RetornoEsperado, 
    sum(lucro_cenario[cenario] for cenario in cache.cenarios_preco) * probabilidade_cenario)

# CVaR_lucro: η - (1/(1-α)) * Σ π_ω * ξ_ω
# Representa o lucro médio nos (1-α)% piores cenários
# Quanto MAIOR o CVaR, MELHOR (mais lucro nos cenários ruins)
@expression(model, CVaR_lucro, 
    VaR - (1 / (1-alpha)) * sum(probabilidade_cenario * desvio_perda_cenario[cenario] for cenario in cache.cenarios_preco))

# Objetivo: max E[R] + λ * CVaR
@objective(model, Max, RetornoEsperado + λ * CVaR_lucro)
```

**Interpretação dos Parâmetros:**
- **λ = 0**: Neutro ao risco (maximiza retorno esperado)
- **λ > 0**: Avesso ao risco (premia lucro nos piores cenários)
- **λ → ∞**: Extremamente conservador (maximiza lucro nos piores cenários)

**Fronteira Eficiente:**
Variando λ de 0 a valores altos, obtemos diferentes pontos da fronteira risco-retorno.

---

## 6️⃣ Estrutura de Cache para Otimização

Para evitar reprocessamento a cada iteração de λ, pré-computamos estruturas auxiliares:

```julia
struct OptimizationCache
    meses_futuros::Vector{Date}
    submercados::Vector{String}
    trades_disponiveis::UnitRange{Int}
    cenarios_preco::UnitRange{Int}
    num_cenarios::Int
    probabilidade_cenario::Float64
    pld_cenario::Dict{Tuple{Date,String,Int}, Float64}
    producao_usina::Dict{Tuple{Date,Int}, Float64}
    volume_compra_existente::Dict{Tuple{Date,String}, Float64}
    volume_venda_existente::Dict{Tuple{Date,String}, Float64}
    preco_compra_existente::Dict{Tuple{Date,String}, Float64}
    preco_venda_existente::Dict{Tuple{Date,String}, Float64}
    indices_trades_por_mes_submercado::Dict{Tuple{Date,String}, Vector{Int}}
end
```

**Benefícios:**
- ✅ Evita filtrar DataFrames repetidamente
- ✅ Acesso O(1) aos dados via dicionários
- ✅ Pré-computa índices de trades por (mês, submercado)
- ✅ Reduz tempo de execução da fronteira eficiente

---

## 7️⃣ Validações e Tratamento de Dados

### Limites Regulatórios do PLD

O arquivo `PLD_min_max_2017_2026.csv` contém os limites anuais definidos pela ANEEL:

```julia
# Durante o processamento dos cenários (em outro arquivo)
for row in eachrow(cenarios)
    ano = year(row.data)
    limite = filter(r -> r.ano == ano, limites_pld)
    
    # Clipping: força PLD a respeitar [piso, teto]
    pld_ajustado = clamp(row.valor, limite.piso, limite.teto)
end
```

**Fonte:** [CCEE - Conceitos de Preços](https://www.ccee.org.br/precos/conceitos-precos)

### Preço Médio Ponderado de Contratos

Quando há múltiplos contratos no mesmo (mês, submercado):

```julia
if nrow(compras) > 0
    volume_total = sum(compras.volume_mwm)
    preco_medio = sum(compras.volume_mwm .* compras.preco_r_mwh) / volume_total
else
    volume_total = 0.0
    preco_medio = 0.0
end
```

---

## 8️⃣ Fluxo de Execução

```julia
function main()
    # 1. Carrega configuração (α, λs, diretórios)
    config = load_frontier_config()
    
    # 2. Carrega dados de mercado (cenários, trades, contratos, geração)
    data = load_market_data(config)
    
    # 3. Pré-processa e constrói cache de otimização
    cache = build_optimization_cache(data)
    
    # 4. Loop da fronteira eficiente (varia λ)
    resultados = run_frontier_optimization(config, data, cache)
    
    # 5. Salva resultados em CSV
    save_results(resultados, config)
end
```

**Saída:**
- Arquivo `resultados_fronteira.csv` com colunas:
  - `Lambda`: Peso do risco
  - `Retorno_Milhoes`: Retorno esperado (R$ milhões)
  - `CVaR_Lucro_Milhoes`: CVaR do lucro (R$ milhões) - lucro médio nos 5% piores cenários
  - `Volume_Hedge_MW`: Volume total de hedge (MW médio)