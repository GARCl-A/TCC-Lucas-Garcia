using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf

struct FrontierConfig
    data_dir::String
    alpha::Float64
    lambdas::Vector{Float64}
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    contratos_existentes::DataFrame
    trades::DataFrame
end

struct OptimizationCache
    # Conjuntos (Seção 4.2)
    meses_futuros::Vector{Date}              # 𝒯^F: meses do horizonte de estudo
    submercados::Vector{String}              # 𝒮: submercados (SE, S, NE, N)
    trades_disponiveis::UnitRange{Int}       # 𝒜: índices dos trades candidatos
    cenarios_preco::UnitRange{Int}           # Ω: cenários estocásticos (1:2000)
    num_cenarios::Int                        # |Ω|: quantidade de cenários
    
    # Parâmetros (Seção 4.3)
    probabilidade_cenario::Float64           # π_ω: probabilidade de cada cenário (equiprovável)
    pld_cenario::Dict                        # P^ω_{s,t}: PLD por (mês, submercado, cenário)
    producao_usina::Dict                     # G_{u,t}: geração da usina u por (mês, usina)
    usinas::Vector{Int}                      # 𝒰: códigos das usinas
    submercado_usina::Dict{Int, String}      # s(u): mapeamento usina → submercado
    volume_compra_existente::Dict            # Q^{0,B}_{s,t}: volume de compras já existentes por (mês, submercado)
    volume_venda_existente::Dict             # Q^{0,S}_{s,t}: volume de vendas já existentes por (mês, submercado)
    preco_compra_existente::Dict             # K^{0,B}_{s,t}: preço de compras já existentes por (mês, submercado)
    preco_venda_existente::Dict              # K^{0,S}_{s,t}: preço de vendas já existentes por (mês, submercado)
    
    # Caches auxiliares (para performance)
    indices_trades_por_mes_submercado::Dict  # Índices de trades agrupados por (mês, submercado)
end

struct OptimizationResult
    lambda::Float64
    retorno_milhoes::Float64
    cvar_lucro_milhoes::Float64
    volume_hedge_mw::Float64
    tempo_segundos::Float64
    status::String
    model::Union{Model, Nothing}
end

function load_frontier_config()
    return FrontierConfig(
        joinpath(@__DIR__, "../..", "data", "processed"),
        0.95,
        [0.001, 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 0.99,1.0]
    )
end

function load_market_data(config::FrontierConfig)::MarketData
    println("🔥 Carregando dados do mercado...")
    
    cenarios = CSV.read(joinpath(config.data_dir, "cenarios_final.csv"), DataFrame)
    geracao = CSV.read(joinpath(config.data_dir, "geracao.csv"), DataFrame)
    contratos_existentes = CSV.read(joinpath(config.data_dir, "contratos_legacy.csv"), DataFrame)
    trades = CSV.read(joinpath(config.data_dir, "trades.csv"), DataFrame)
    
    cenarios.data = Date.(cenarios.data)
    geracao.data = Date.(geracao.data)
    contratos_existentes.data = Date.(contratos_existentes.data)
    trades.data = Date.(trades.data)
    
    return MarketData(cenarios, geracao, contratos_existentes, trades)
end

function build_optimization_cache(data::MarketData)::OptimizationCache
    println("⚙️ Construindo cache de otimização...")
    
    # ========================================
    # Conjuntos do Modelo (Seção 4.2)
    # ========================================
    meses_futuros = sort(unique(data.cenarios.data))
    submercados = unique(data.geracao.submercado)  # Submercados com usinas reais
    trades_disponiveis = 1:nrow(data.trades)
    num_cenarios = maximum(data.cenarios.cenario)
    cenarios_preco = 1:num_cenarios
    
    # ========================================
    # Parâmetros do Modelo (Seção 4.3)
    # ========================================
    probabilidade_cenario = 1.0 / num_cenarios
    pld_cenario = Dict((r.data, r.submercado, r.cenario) => r.valor for r in eachrow(data.cenarios))
    producao_usina = Dict((r.data, r.usina_cod) => r.geracao_mwm for r in eachrow(data.geracao))
    
    # Extrai usinas e seus submercados
    usinas = unique(data.geracao.usina_cod)
    submercado_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))
    
    # Q^{0,B}_{s,t}, Q^{0,S}_{s,t}, K^{0,B}_{s,t}, K^{0,S}_{s,t}: volumes e preços dos contratos já existentes
    volume_compra_existente = Dict()
    volume_venda_existente = Dict()
    preco_compra_existente = Dict()
    preco_venda_existente = Dict()
    
    for mes in meses_futuros, submercado in submercados
        contratos_mes = filter(row -> row.data == mes && row.submercado == submercado, data.contratos_existentes)
        
        # Contratos de COMPRA
        compras = filter(row -> row.tipo == "COMPRA", contratos_mes)
        if nrow(compras) > 0
            volume_compra_existente[(mes,submercado)] = sum(compras.volume_mwm)
            # Preço médio ponderado pelo volume
            preco_compra_existente[(mes,submercado)] = sum(compras.volume_mwm .* compras.preco_r_mwh) / sum(compras.volume_mwm)
        else
            volume_compra_existente[(mes,submercado)] = 0.0
            preco_compra_existente[(mes,submercado)] = 0.0
        end
        
        # Contratos de VENDA
        vendas = filter(row -> row.tipo == "VENDA", contratos_mes)
        if nrow(vendas) > 0
            volume_venda_existente[(mes,submercado)] = sum(vendas.volume_mwm)
            # Preço médio ponderado pelo volume
            preco_venda_existente[(mes,submercado)] = sum(vendas.volume_mwm .* vendas.preco_r_mwh) / sum(vendas.volume_mwm)
        else
            volume_venda_existente[(mes,submercado)] = 0.0
            preco_venda_existente[(mes,submercado)] = 0.0
        end
    end
    
    # ========================================
    # Caches Auxiliares (para performance)
    # ========================================
    # Pré-calcula quais trades pertencem a cada (mês, submercado) para evitar filtros repetidos
    indices_trades_por_mes_submercado = Dict()
    for mes in meses_futuros, submercado in submercados
        indices_trades_por_mes_submercado[(mes,submercado)] = findall(row -> row.data == mes && row.submercado == submercado, eachrow(data.trades))
    end
    
    return OptimizationCache(
        meses_futuros, submercados, trades_disponiveis, cenarios_preco, num_cenarios,
        probabilidade_cenario, pld_cenario, producao_usina, usinas, submercado_usina,
        volume_compra_existente, volume_venda_existente,
        preco_compra_existente, preco_venda_existente,
        indices_trades_por_mes_submercado
    )
end

horas_mes(d::Date) = daysinmonth(d) * 24

function solve_cvar_model(λ::Float64, config::FrontierConfig, data::MarketData, cache::OptimizationCache)::OptimizationResult
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    # ========================================
    # Parâmetros Explícitos (Seção 4.3)
    # ========================================
    # Parâmetros dos trades disponíveis
    preco_compra_trade = data.trades.preco_compra      # K^B_a: preço de compra do trade a
    preco_venda_trade = data.trades.preco_venda        # K^S_a: preço de venda do trade a
    limite_compra_trade = data.trades.limite_compra    # q̄^B_a: limite máximo de compra do trade a
    limite_venda_trade = data.trades.limite_venda      # q̄^S_a: limite máximo de venda do trade a
    
    # Parâmetros de risco
    alpha = config.alpha                               # α: nível de confiança do CVaR
    # λ: peso do risco (parâmetro de entrada da função)
    probabilidade_cenario = cache.probabilidade_cenario # π_ω: probabilidade do cenário
    
    # ========================================
    # Seção 4.4: Variáveis de Decisão
    # Seção 4.10: Restrições de Volume
    # Decisão única (here-and-now) avaliada em múltiplos cenários
    # ========================================
    # q^B_a: volume de compra do trade a (MWm) - restrição: 0 ≤ q^B_a ≤ q̄^B_a
    @variable(model, 0 <= volume_compra_trade[trade in cache.trades_disponiveis] <= limite_compra_trade[trade])
    # q^S_a: volume de venda do trade a (MWm) - restrição: 0 ≤ q^S_a ≤ q̄^S_a
    @variable(model, 0 <= volume_venda_trade[trade in cache.trades_disponiveis] <= limite_venda_trade[trade])
    
    # ========================================
    # Seção 4.8: Variáveis Auxiliares do CVaR
    # ========================================
    # η: Value-at-Risk (quantil (1-α) dos lucros)
    # ξ_ω: desvios acima do VaR para cada cenário
    @variable(model, VaR)
    @variable(model, desvio_perda_cenario[cenario in cache.cenarios_preco] >= 0)

    # ========================================
    # Cálculo do Lucro por Cenário (Seção 4.7)
    # ========================================
    
    # Parte 1: Lucro dos Contratos Já Existentes (constante)
    lucro_contratos_existentes = 0.0
    for mes in cache.meses_futuros, submercado in cache.submercados
        horas_no_mes = horas_mes(mes)
        # K^{0,S}_{s,t} * Q^{0,S}_{s,t}: receita das vendas existentes
        receita_venda = get(cache.preco_venda_existente, (mes,submercado), 0.0) * get(cache.volume_venda_existente, (mes,submercado), 0.0) * horas_no_mes
        # K^{0,B}_{s,t} * Q^{0,B}_{s,t}: custo das compras existentes
        custo_compra = get(cache.preco_compra_existente, (mes,submercado), 0.0) * get(cache.volume_compra_existente, (mes,submercado), 0.0) * horas_no_mes
        lucro_contratos_existentes += receita_venda - custo_compra
    end
    
    # Parte 2: Lucro dos Novos Trades (variável de decisão)
    # AffExpr(0.0): Expressão afim vazia do JuMP (será preenchida com combinação linear de variáveis)
    # Tipo usado pelo JuMP para representar somas de variáveis de decisão multiplicadas por constantes
    lucro_novos_trades = AffExpr(0.0)
    for trade in cache.trades_disponiveis
        horas_no_mes = horas_mes(data.trades.data[trade])
        add_to_expression!(lucro_novos_trades, (volume_venda_trade[trade] * preco_venda_trade[trade] - volume_compra_trade[trade] * preco_compra_trade[trade]) * horas_no_mes)
    end
    
    # Inicializa lucro_cenario com as partes 1 e 2
    @expression(model, lucro_cenario[cenario in cache.cenarios_preco], lucro_contratos_existentes + lucro_novos_trades)
    
    # Parte 3: Lucro da Exposição ao PLD (estocástico)
    total_iteracoes = length(cache.meses_futuros) * length(cache.submercados) * length(cache.cenarios_preco)
    iteracao_atual = 0
    proximo_marco = 1
    
    for mes in cache.meses_futuros, submercado in cache.submercados
        horas_no_mes = horas_mes(mes)
        # G_{s,t}: produção agregada de todas as usinas do submercado
        producao = sum(
            get(cache.producao_usina, (mes, u), 0.0) 
            for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado;
            init=0.0
        )
        # Q^{0,B}_{s,t}: compras já existentes
        compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
        # Q^{0,S}_{s,t}: vendas já existentes
        venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
        
        # Índices dos trades disponíveis para este (mês, submercado)
        # Pré-computado no cache para evitar filtrar a cada iteração
        indices_trades_mes_submercado = cache.indices_trades_por_mes_submercado[(mes,submercado)]
        
        # Seção 4.5: Agregação dos volumes dos novos trades por (mês, submercado)
        # Q^{B}_{s,t} = Σ q^B_a  (para todos os trades a do mês t e submercado s)
        # AffExpr(0.0): Expressão afim vazia (caso não haja trades neste mês/submercado)
        volume_compra_agregado = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_compra_trade[trade] for trade in indices_trades_mes_submercado)
        volume_venda_agregado = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_venda_trade[trade] for trade in indices_trades_mes_submercado)
        
        # E^{ω}_{s,t}: Exposição ao PLD (Seção 4.6)
        # E = G + Q^{0,B} + Q^{B} - Q^{0,S} - Q^{S}
        exposicao_pld = producao + compra_existente + volume_compra_agregado - venda_existente - volume_venda_agregado
        
        # Adiciona lucro da exposição ao PLD para cada cenário
        for cenario in cache.cenarios_preco
            pld = get(cache.pld_cenario, (mes, submercado, cenario), 0.0)
            add_to_expression!(lucro_cenario[cenario], exposicao_pld * horas_no_mes * pld)
            
            # Progress tracking
            iteracao_atual += 1
            progresso = (iteracao_atual / total_iteracoes) * 100
            if progresso >= proximo_marco
                print("\r   Construindo modelo: $iteracao_atual/$total_iteracoes ($(round(Int, progresso))%)")
                proximo_marco += 1
            end
        end
    end
    println("\r   Construindo modelo: $total_iteracoes/$total_iteracoes (100%) ✓")
    
    # ========================================
    # Restrições CVaR (Seção 4.8)
    # ========================================
    # Trabalhamos diretamente com LUCROS (não invertemos sinal)
    # Restrição: ξ_ω ≥ η - R^ω
    # Onde η = VaR (quantil dos piores lucros) e ξ_ω = desvio do cenário ω
    @constraint(model, restricao_cvar[cenario in cache.cenarios_preco], 
        desvio_perda_cenario[cenario] >= VaR - lucro_cenario[cenario])
    
    # ========================================
    # Função Objetivo (Seção 4.9)
    # ========================================
    # Retorno Esperado: E[R] = Σ π_ω R^ω
    @expression(model, RetornoEsperado, 
        sum(lucro_cenario[cenario] for cenario in cache.cenarios_preco) * probabilidade_cenario)
    
    # CVaR: η - (1/(1-α)) Σ π_ω ξ_ω
    # Representa o lucro médio nos (1-α)% piores cenários
    # Quanto MAIOR o CVaR, MELHOR (mais lucro nos cenários ruins)
    @expression(model, CVaR_lucro, 
        VaR - (1 / (1-alpha)) * sum(probabilidade_cenario * desvio_perda_cenario[cenario] for cenario in cache.cenarios_preco))
    
    # Objetivo: max E[R] + λ * CVaR
    # λ > 0: premia lucro nos piores cenários (aversão ao risco)
    # λ = 0: maximiza apenas retorno esperado (neutro ao risco)
    @objective(model, Max, RetornoEsperado + λ * CVaR_lucro)
    print("\r   Otimizando...")
    tempo_inicio = time()
    optimize!(model)
    tempo_otimizacao = time() - tempo_inicio
    print("\r   ")
    
    status = termination_status(model)
    if status == MOI.OPTIMAL
        retorno_milhoes = value(RetornoEsperado) / 1e6
        cvar_lucro_milhoes = value(CVaR_lucro) / 1e6
        volume_hedge_total = sum(value.(volume_compra_trade)) + sum(value.(volume_venda_trade))
        
        # Debug CVaR
        var_value = value(VaR) / 1e6
        esperanca_desvios = sum(probabilidade_cenario * value(desvio_perda_cenario[c]) for c in cache.cenarios_preco) / 1e6
        println("   [DEBUG OPT λ=$λ] VaR: $(round(var_value, digits=1)) Mi | E[ξ]: $(round(esperanca_desvios, digits=1)) Mi | CVaR: $(round(cvar_lucro_milhoes, digits=1)) Mi")
        
        # Debug: mostrar trades executados
        trades_executados = sum(value.(volume_compra_trade) .> 0.01) + sum(value.(volume_venda_trade) .> 0.01)
        println("   [DEBUG OPT λ=$λ] Trades executados: $trades_executados de $(length(cache.trades_disponiveis))")
        
        return OptimizationResult(λ, retorno_milhoes, cvar_lucro_milhoes, volume_hedge_total, tempo_otimizacao, "OPTIMAL", model)
    else
        # Diagnóstico da falha
        println("\n   🔍 DIAGNÓSTICO DA FALHA (λ=$λ):")
        println("   Status: $status")
        
        if status == MOI.DUAL_INFEASIBLE
            println("   Tipo: DUAL_INFEASIBLE (modelo ilimitado)")
            println("   Causa: Função objetivo pode crescer infinitamente")
            println("   Razão: VaR sem limite inferior + penalização de risco (λ > 0)")
            println("   Interpretação: Não há trades que reduzam risco de forma vantajosa")
            println("   Solução: Modelo funciona apenas com λ=0 (neutro ao risco)")
        elseif status == MOI.INFEASIBLE
            println("   Tipo: INFEASIBLE (sem solução factível)")
            println("   Causa: Restrições conflitantes")
            println("   Razão: Possível erro nos dados ou formulação")
        else
            println("   Tipo: $(status)")
            println("   Detalhes: $(raw_status(model))")
        end
        
        return OptimizationResult(λ, 0.0, 0.0, 0.0, 0.0, "FAILED", nothing)
    end
end

function calculate_benchmark(cache::OptimizationCache, config::FrontierConfig)::Tuple{Float64, Float64, Float64}
    """
    Calcula o resultado financeiro SEM fazer nenhum trade novo (benchmark).
    Retorna: (retorno_esperado, cvar_perda, desvio_padrao) em RS milhões
    """
    lucros_cenarios = Float64[]
    total_cenarios = length(cache.cenarios_preco)
    proximo_marco = 1
    
    for (idx, cenario) in enumerate(cache.cenarios_preco)
        lucro_cenario = 0.0
        
        # Progress tracking
        progresso = (idx / total_cenarios) * 100
        if progresso >= proximo_marco
            print("\r   Progresso: $idx/$total_cenarios ($(round(Int, progresso))%)")
            proximo_marco += 1
        end
        
        for mes in cache.meses_futuros, submercado in cache.submercados
            horas_no_mes = horas_mes(mes)
            
            # Parte 1: Contratos existentes
            receita_venda = get(cache.preco_venda_existente, (mes,submercado), 0.0) * get(cache.volume_venda_existente, (mes,submercado), 0.0) * horas_no_mes
            custo_compra = get(cache.preco_compra_existente, (mes,submercado), 0.0) * get(cache.volume_compra_existente, (mes,submercado), 0.0) * horas_no_mes
            lucro_cenario += receita_venda - custo_compra
            
            # Parte 2: Exposição ao PLD (sem novos trades)
            producao = sum(
                get(cache.producao_usina, (mes, u), 0.0) 
                for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado;
                init=0.0
            )
            compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
            venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
            exposicao_pld = producao + compra_existente - venda_existente
            
            pld = get(cache.pld_cenario, (mes, submercado, cenario), 0.0)
            lucro_cenario += exposicao_pld * horas_no_mes * pld
        end
        
        push!(lucros_cenarios, lucro_cenario)
    end
    println("\r   Progresso: $total_cenarios/$total_cenarios (100%) ✓")
    
    # Métricas
    retorno_esperado = mean(lucros_cenarios) / 1e6
    desvio_padrao = std(lucros_cenarios) / 1e6
    
    # CVaR usando a mesma formulação do modelo: CVaR = η - (1/(1-α)) * E[ξ]
    # O modelo trabalha com: ξ >= VaR - lucro (não inverte sinal!)
    # Então VaR é o quantil dos LUCROS (não das perdas)
    
    # VaR: quantil (1-α) dos LUCROS (piores lucros)
    lucros_ordenados = sort(lucros_cenarios)  # Ordena crescente (menor lucro = pior)
    idx_var = Int(ceil((1 - config.alpha) * length(lucros_ordenados)))
    var_value = lucros_ordenados[idx_var]  # Quantil dos piores lucros
    
    # Desvios: ξ = max(VaR - lucro, 0)
    desvios = max.(var_value .- lucros_cenarios, 0.0)
    
    # CVaR = η - (1/(1-α)) * E[ξ]
    # Interpretação: lucro médio nos (1-α)% piores cenários
    # Quanto MAIOR, melhor (mais lucro nos cenários ruins)
    cvar_lucro = var_value - (1 / (1 - config.alpha)) * mean(desvios)
    
    # Debug CVaR
    println("   [DEBUG BENCH] VaR: $(round(var_value/1e6, digits=1)) Mi | E[ξ]: $(round(mean(desvios)/1e6, digits=1)) Mi | CVaR: $(round(cvar_lucro/1e6, digits=1)) Mi")
    
    return (retorno_esperado, cvar_lucro / 1e6, desvio_padrao)
end

function run_frontier_optimization(config::FrontierConfig, data::MarketData, cache::OptimizationCache)
    println("🔥 Iniciando Loop da Fronteira Eficiente...")
    
    # Calcula benchmark (sem otimização)
    println("\n📊 BENCHMARK (Sem Otimização):")
    bench_retorno, bench_cvar, bench_std = calculate_benchmark(cache, config)
    println("   Retorno Esperado:  R\$ $(round(bench_retorno, digits=1)) Mi")
    println("   CVaR (5% piores):  R\$ $(round(bench_cvar, digits=1)) Mi (lucro médio nos piores cenários - quanto MAIOR, melhor)")
    println("   Desvio Padrão:     R\$ $(round(bench_std, digits=1)) Mi")
    println("   Volume Hedge:      0.0 MW (nenhum trade)\n")
    
    resultados = DataFrame(Lambda=Float64[], Retorno_Milhoes=Float64[], CVaR_Lucro_Milhoes=Float64[], Volume_Hedge_MW=Float64[], Tempo_Segundos=Float64[])
    
    # Adiciona benchmark como primeira linha (λ = N/A)
    push!(resultados, (NaN, bench_retorno, bench_cvar, 0.0, 0.0))
    
    for λ in config.lambdas
        print("⚡ Otimizando λ = $λ ... ")
        
        result = solve_cvar_model(λ, config, data, cache)
        
        if result.status == "OPTIMAL"
            push!(resultados, (result.lambda, result.retorno_milhoes, result.cvar_lucro_milhoes, result.volume_hedge_mw, result.tempo_segundos))
            
            delta_retorno = result.retorno_milhoes - bench_retorno
            delta_cvar = result.cvar_lucro_milhoes - bench_cvar  # Quanto aumentou o CVaR
            
            sinal_retorno = delta_retorno >= 0 ? "+" : ""
            sinal_cvar = delta_cvar >= 0 ? "+" : ""
            
            println("✅ OK! Retorno: R\$ $(round(result.retorno_milhoes, digits=1)) Mi [$(sinal_retorno)$(round(delta_retorno, digits=1))] | CVaR: R\$ $(round(result.cvar_lucro_milhoes, digits=1)) Mi [$(sinal_cvar)$(round(delta_cvar, digits=1))] | Hedge: $(round(result.volume_hedge_mw, digits=0)) MW | Tempo: $(round(result.tempo_segundos, digits=2))s")
        else
            println("❌ Falha!")
        end
    end
    
    return resultados
end

function export_hedge_strategy(λ_escolhido::Float64, config::FrontierConfig, data::MarketData, cache::OptimizationCache)
    println("\n📋 Exportando estratégia de hedge para λ=$λ_escolhido...")
    
    # Resolve o modelo para o λ escolhido
    result = solve_cvar_model(λ_escolhido, config, data, cache)
    
    if result.status != "OPTIMAL" || isnothing(result.model)
        println("❌ Não foi possível exportar: modelo não resolvido.")
        return
    end
    
    model = result.model
    estrategia = []
    
    # Extrai decisões de trades
    for trade_idx in cache.trades_disponiveis
        vol_compra = value(model[:volume_compra_trade][trade_idx])
        vol_venda = value(model[:volume_venda_trade][trade_idx])
        
        if vol_compra > 0.01 || vol_venda > 0.01
            trade_info = data.trades[trade_idx, :]
            push!(estrategia, (
                mes = trade_info.data,
                submercado = trade_info.submercado,
                compra_mwm = round(vol_compra, digits=2),
                preco_compra = trade_info.preco_compra,
                venda_mwm = round(vol_venda, digits=2),
                preco_venda = trade_info.preco_venda
            ))
        end
    end
    
    df_estrategia = DataFrame(estrategia)
    
    # Calcula exposição final por (mês, submercado)
    exposicao = []
    for mes in cache.meses_futuros, submercado in cache.submercados
        # Produção
        producao = sum(
            get(cache.producao_usina, (mes, u), 0.0) 
            for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado;
            init=0.0
        )
        
        # Contratos existentes
        compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
        venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
        
        # Novos trades
        trades_mes = filter(row -> row.mes == mes && row.submercado == submercado, df_estrategia)
        compra_nova = nrow(trades_mes) > 0 ? sum(trades_mes.compra_mwm) : 0.0
        venda_nova = nrow(trades_mes) > 0 ? sum(trades_mes.venda_mwm) : 0.0
        
        exposicao_final = producao + compra_existente + compra_nova - venda_existente - venda_nova
        
        push!(exposicao, (
            mes = mes,
            submercado = submercado,
            producao_mwm = round(producao, digits=2),
            compra_existente_mwm = round(compra_existente, digits=2),
            venda_existente_mwm = round(venda_existente, digits=2),
            compra_nova_mwm = round(compra_nova, digits=2),
            venda_nova_mwm = round(venda_nova, digits=2),
            exposicao_final_mwm = round(exposicao_final, digits=2)
        ))
    end
    
    df_exposicao = DataFrame(exposicao)
    
    # Salva arquivos
    CSV.write(joinpath(config.data_dir, "estrategia_trades_lambda_$(λ_escolhido).csv"), df_estrategia)
    CSV.write(joinpath(config.data_dir, "exposicao_pld_lambda_$(λ_escolhido).csv"), df_exposicao)
    
    println("✅ Estratégia exportada:")
    println("   - estrategia_trades_lambda_$(λ_escolhido).csv ($(nrow(df_estrategia)) trades)")
    println("   - exposicao_pld_lambda_$(λ_escolhido).csv ($(nrow(df_exposicao)) linhas)")
end

function save_results(resultados::DataFrame, config::FrontierConfig)
    println("\n📊 TABELA FRONTEIRA EFICIENTE:")
    println("\nLinha 1 = BENCHMARK (sem otimização)")
    println("Demais linhas = Otimização com diferentes valores de λ\n")
    println(resultados)
    
    CSV.write(joinpath(config.data_dir, "resultados_fronteira.csv"), resultados)
    println("\n✅ Resultados salvos em resultados_fronteira.csv")
    
    # Análise de valor agregado
    if nrow(resultados) > 1
        bench = resultados[1, :]
        melhor_retorno = resultados[argmax(resultados.Retorno_Milhoes), :]
        melhor_cvar = resultados[argmax(resultados.CVaR_Lucro_Milhoes), :]  # MAIOR CVaR = melhor
        
        println("\n📈 ANÁLISE DE VALOR AGREGADO:")
        ganho_retorno = melhor_retorno.Retorno_Milhoes - bench.Retorno_Milhoes
        ganho_cvar = melhor_cvar.CVaR_Lucro_Milhoes - bench.CVaR_Lucro_Milhoes  # Positivo = aumentou lucro nos piores cenários
        
        println("   Melhor Retorno: λ=$(melhor_retorno.Lambda) → R\$ $(round(melhor_retorno.Retorno_Milhoes, digits=1)) Mi ($(ganho_retorno >= 0 ? "+" : "")$(round(ganho_retorno, digits=1)) vs benchmark)")
        println("   Melhor CVaR:    λ=$(melhor_cvar.Lambda) → R\$ $(round(melhor_cvar.CVaR_Lucro_Milhoes, digits=1)) Mi (+$(round(ganho_cvar, digits=1)) vs benchmark)")
        println("\n   Interpretação: CVaR = lucro médio nos 5% piores cenários (quanto MAIOR, melhor)")
    end
end

function main()
    config = load_frontier_config()
    data = load_market_data(config)
    cache = build_optimization_cache(data)
    
    resultados = run_frontier_optimization(config, data, cache)
    save_results(resultados, config)
    
    # Exporta estratégia detalhada para λ=0.01 (melhor trade-off)
    export_hedge_strategy(0.01, config, data, cache)
end

main()