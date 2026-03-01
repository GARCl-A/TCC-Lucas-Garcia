using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf

struct FrontierConfig
    data_dir::String
    alpha::Float64
    lambdas::Vector{Float64}
    debug::Bool
    caixa_inicial::Float64
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
    saldo_final_esperado_milhoes::Float64
    cvar_saldo_milhoes::Float64
    volume_hedge_mw::Float64
    tempo_segundos::Float64
    status::String
    model::Union{Model, Nothing}
end

function load_frontier_config()
    return FrontierConfig(
        joinpath(@__DIR__, "..", "..", "..", "data", "processed"),
        0.95,
        [0.001, 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 0.99, 1.0],
        false,  # debug mode
        0.0     # ZERO de capital inicial (caixa começa zerado)
    )
end

function load_market_data(config::FrontierConfig)::MarketData
    println("🔥 Carregando dados do mercado...")
    
    cenarios = CSV.read(joinpath(config.data_dir, "cenarios_final.csv"), DataFrame)
    geracao = CSV.read(joinpath(config.data_dir, "geracao_estocastica.csv"), DataFrame)
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
    submercados = unique(data.cenarios.submercado)  # Submercados com usinas reais
    trades_disponiveis = 1:nrow(data.trades)
    num_cenarios = maximum(data.cenarios.cenario)
    cenarios_preco = 1:num_cenarios
    
    # ========================================
    # Parâmetros do Modelo (Seção 4.3)
    # ========================================
    probabilidade_cenario = 1.0 / num_cenarios
    pld_cenario = Dict((r.data, r.submercado, r.cenario) => r.valor for r in eachrow(data.cenarios))
    producao_usina = Dict((r.data, r.usina_cod, r.cenario) => r.geracao_mwm for r in eachrow(data.geracao))
    
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
    # Parâmetros Explícitos
    # ========================================
    preco_compra_trade = data.trades.preco_compra
    preco_venda_trade = data.trades.preco_venda
    limite_compra_trade = data.trades.limite_compra
    limite_venda_trade = data.trades.limite_venda
    alpha = config.alpha
    probabilidade_cenario = cache.probabilidade_cenario
    limite_credito = -100000000  # R$ -100 milhões
    
    # ========================================
    # Variáveis de Decisão
    # ========================================
    @variable(model, 0 <= volume_compra_trade[trade in cache.trades_disponiveis] <= limite_compra_trade[trade])
    @variable(model, 0 <= volume_venda_trade[trade in cache.trades_disponiveis] <= limite_venda_trade[trade])
    
    # Nova variável: Saldo em Caixa por mês e cenário
    @variable(model, caixa[mes in cache.meses_futuros, cenario in cache.cenarios_preco])
    
    # Variáveis CVaR
    @variable(model, VaR)
    @variable(model, desvio_perda_cenario[cenario in cache.cenarios_preco] >= 0)

    # ========================================
    # Dinâmica de Caixa e Fluxo Operacional
    # ========================================
    total_iteracoes = length(cache.meses_futuros) * length(cache.cenarios_preco)
    iteracao_atual = 0
    proximo_marco = 1
    
    for (idx_mes, mes) in enumerate(cache.meses_futuros)
        
        # 1. PRÉ-CÁLCULO DA PARTE DETERMINÍSTICA (Fora do loop de cenários!)
        fluxo_det_mes = AffExpr(0.0)
        agregado_compra_sub = Dict{String, Any}()
        agregado_venda_sub = Dict{String, Any}()
        
        for submercado in cache.submercados
            horas_no_mes = horas_mes(mes)
            
            # Contratos legados (Fixo)
            receita_venda = get(cache.preco_venda_existente, (mes,submercado), 0.0) * get(cache.volume_venda_existente, (mes,submercado), 0.0) * horas_no_mes
            custo_compra = get(cache.preco_compra_existente, (mes,submercado), 0.0) * get(cache.volume_compra_existente, (mes,submercado), 0.0) * horas_no_mes
            add_to_expression!(fluxo_det_mes, receita_venda - custo_compra)
            
            # Novos trades (Decisão Única)
            indices_trades_mes_submercado = cache.indices_trades_por_mes_submercado[(mes,submercado)]
            for t in indices_trades_mes_submercado
                add_to_expression!(fluxo_det_mes, (volume_venda_trade[t] * preco_venda_trade[t] - volume_compra_trade[t] * preco_compra_trade[t]) * horas_no_mes)
            end
            
            # Soma das variáveis para expor ao PLD depois
            agregado_compra_sub[submercado] = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_compra_trade[t] for t in indices_trades_mes_submercado)
            agregado_venda_sub[submercado] = isempty(indices_trades_mes_submercado) ? AffExpr(0.0) : sum(volume_venda_trade[t] for t in indices_trades_mes_submercado)
        end
        
        # 2. LOOP DE CENÁRIOS (Adiciona apenas a Exposição ao PLD)
        for cenario in cache.cenarios_preco
            fluxo_mes_cenario = copy(fluxo_det_mes) # Puxa o bolo que já está pronto
            
            for submercado in cache.submercados
                horas_no_mes = horas_mes(mes)
                
                producao_cenario = sum(get(cache.producao_usina, (mes, u, cenario), 0.0) for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado; init=0.0)
                compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
                venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
                
                # Junta o físico do cenário com o agregado de trades pré-calculado
                exposicao_pld = producao_cenario + compra_existente + agregado_compra_sub[submercado] - venda_existente - agregado_venda_sub[submercado]
                pld = get(cache.pld_cenario, (mes, submercado, cenario), 0.0)
                
                add_to_expression!(fluxo_mes_cenario, exposicao_pld * horas_no_mes * pld)
            end
            
            # Dinâmica de Caixa
            if idx_mes == 1
                @constraint(model, caixa[mes, cenario] == config.caixa_inicial + fluxo_mes_cenario)
            else
                mes_anterior = cache.meses_futuros[idx_mes - 1]
                @constraint(model, caixa[mes, cenario] == caixa[mes_anterior, cenario] + fluxo_mes_cenario)
            end
            
            # Restrição de limite de crédito
            @constraint(model, caixa[mes, cenario] >= limite_credito)
            
            # Tracking
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
    # CVaR sobre Saldo Final
    # ========================================
    ultimo_mes = cache.meses_futuros[end]
    @constraint(model, restricao_cvar[cenario in cache.cenarios_preco], 
        desvio_perda_cenario[cenario] >= VaR - caixa[ultimo_mes, cenario])
    
    # ========================================
    # Função Objetivo
    # ========================================
    @expression(model, SaldoFinalEsperado, 
        sum(caixa[ultimo_mes, cenario] for cenario in cache.cenarios_preco) * probabilidade_cenario)
    
    @expression(model, CVaR_saldo, 
        VaR - (1 / (1-alpha)) * sum(probabilidade_cenario * desvio_perda_cenario[cenario] for cenario in cache.cenarios_preco))
    
    @objective(model, Max, SaldoFinalEsperado + λ * CVaR_saldo)
    print("\r   Otimizando...")
    tempo_inicio = time()
    optimize!(model)
    tempo_otimizacao = time() - tempo_inicio
    print("\r   ")
    
    status = JuMP.termination_status(model)
    if status == MOI.OPTIMAL
        saldo_final_milhoes = value(SaldoFinalEsperado) / 1e6
        cvar_saldo_milhoes = value(CVaR_saldo) / 1e6
        volume_hedge_total = sum(value.(volume_compra_trade)) + sum(value.(volume_venda_trade))
        
        if config.debug
            var_value = value(VaR) / 1e6
            esperanca_desvios = sum(probabilidade_cenario * value(desvio_perda_cenario[c]) for c in cache.cenarios_preco) / 1e6
            println("   [DEBUG OPT λ=$λ] VaR: $(round(var_value, digits=1)) Mi | E[ξ]: $(round(esperanca_desvios, digits=1)) Mi | CVaR: $(round(cvar_saldo_milhoes, digits=1)) Mi")
            trades_executados = sum(value.(volume_compra_trade) .> 0.01) + sum(value.(volume_venda_trade) .> 0.01)
            println("   [DEBUG OPT λ=$λ] Trades executados: $trades_executados de $(length(cache.trades_disponiveis))")
        end
        
        return OptimizationResult(λ, saldo_final_milhoes, cvar_saldo_milhoes, volume_hedge_total, tempo_otimizacao, "OPTIMAL", model)
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
    Calcula o saldo em caixa final SEM fazer nenhum trade novo (benchmark).
    Retorna: (saldo_final_esperado, cvar_saldo, desvio_padrao) em RS milhões
    """
    caixa_final_cenarios = Float64[]
    total_cenarios = length(cache.cenarios_preco)
    proximo_marco = 1
    
    for (idx, cenario) in enumerate(cache.cenarios_preco)
        caixa_acumulado = config.caixa_inicial
        
        progresso = (idx / total_cenarios) * 100
        if progresso >= proximo_marco
            print("\r   Progresso: $idx/$total_cenarios ($(round(Int, progresso))%)")
            proximo_marco += 1
        end
        
        for mes in cache.meses_futuros
            fluxo_mes = 0.0
            
            for submercado in cache.submercados
                horas_no_mes = horas_mes(mes)
                
                receita_venda = get(cache.preco_venda_existente, (mes,submercado), 0.0) * get(cache.volume_venda_existente, (mes,submercado), 0.0) * horas_no_mes
                custo_compra = get(cache.preco_compra_existente, (mes,submercado), 0.0) * get(cache.volume_compra_existente, (mes,submercado), 0.0) * horas_no_mes
                fluxo_mes += receita_venda - custo_compra
                
                producao = sum(
                    get(cache.producao_usina, (mes, u, cenario), 0.0) 
                    for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado;
                    init=0.0
                )
                compra_existente = get(cache.volume_compra_existente, (mes,submercado), 0.0)
                venda_existente = get(cache.volume_venda_existente, (mes,submercado), 0.0)
                exposicao_pld = producao + compra_existente - venda_existente
                pld = get(cache.pld_cenario, (mes, submercado, cenario), 0.0)
                fluxo_mes += exposicao_pld * horas_no_mes * pld
            end
            
            caixa_acumulado += fluxo_mes
        end
        
        push!(caixa_final_cenarios, caixa_acumulado)
    end
    println("\r   Progresso: $total_cenarios/$total_cenarios (100%) ✓")
    
    saldo_final_esperado = mean(caixa_final_cenarios) / 1e6
    desvio_padrao = std(caixa_final_cenarios) / 1e6
    
    caixa_ordenado = sort(caixa_final_cenarios)
    idx_var = Int(ceil((1 - config.alpha) * length(caixa_ordenado)))
    var_value = caixa_ordenado[idx_var]
    desvios = max.(var_value .- caixa_final_cenarios, 0.0)
    cvar_saldo = var_value - (1 / (1 - config.alpha)) * mean(desvios)
    
    if config.debug
        println("   [DEBUG BENCH] VaR: $(round(var_value/1e6, digits=1)) Mi | E[ξ]: $(round(mean(desvios)/1e6, digits=1)) Mi | CVaR: $(round(cvar_saldo/1e6, digits=1)) Mi")
    end
    
    return (saldo_final_esperado, cvar_saldo / 1e6, desvio_padrao)
end

function run_frontier_optimization(config::FrontierConfig, data::MarketData, cache::OptimizationCache)
    println("🔥 Iniciando Loop da Fronteira Eficiente...")
    
    println("\n📊 BENCHMARK (Sem Otimização):")
    bench_saldo, bench_cvar, bench_std = calculate_benchmark(cache, config)
    println("   Saldo Final Esperado:  R\$ $(round(bench_saldo, digits=1)) Mi")
    println("   CVaR (5% piores):      R\$ $(round(bench_cvar, digits=1)) Mi (saldo médio nos piores cenários)")
    println("   Desvio Padrão:         R\$ $(round(bench_std, digits=1)) Mi")
    println("   Volume Hedge:          0.0 MW (nenhum trade)\n")
    
    resultados = DataFrame(Lambda=Float64[], Saldo_Final_Milhoes=Float64[], CVaR_Saldo_Milhoes=Float64[], Volume_Hedge_MW=Float64[], Tempo_Segundos=Float64[])
    push!(resultados, (NaN, bench_saldo, bench_cvar, 0.0, 0.0))
    
    for λ in config.lambdas
        print("⚡ Otimizando λ = $λ ... ")
        result = solve_cvar_model(λ, config, data, cache)
        
        if result.status == "OPTIMAL"
            push!(resultados, (result.lambda, result.saldo_final_esperado_milhoes, result.cvar_saldo_milhoes, result.volume_hedge_mw, result.tempo_segundos))
            delta_saldo = result.saldo_final_esperado_milhoes - bench_saldo
            delta_cvar = result.cvar_saldo_milhoes - bench_cvar
            println("✅ Saldo: R\$ $(round(result.saldo_final_esperado_milhoes, digits=1)) Mi [$(delta_saldo >= 0 ? "+" : "")$(round(delta_saldo, digits=1))] | CVaR: R\$ $(round(result.cvar_saldo_milhoes, digits=1)) Mi [$(delta_cvar >= 0 ? "+" : "")$(round(delta_cvar, digits=1))] | Hedge: $(round(result.volume_hedge_mw, digits=0)) MW | $(round(result.tempo_segundos, digits=1))s")
        else
            println("❌ Falha!")
        end
    end
    
    return resultados
end

function export_hedge_strategy(λ_escolhido::Float64, config::FrontierConfig, data::MarketData, cache::OptimizationCache)
    println("\n📋 Exportando estratégia de hedge para λ=$λ_escolhido...")
    
    result = solve_cvar_model(λ_escolhido, config, data, cache)
    
    if result.status != "OPTIMAL" || isnothing(result.model)
        println("❌ Não foi possível exportar: modelo não resolvido.")
        return
    end
    
    model = result.model
    
    # Relatório de fluxo de caixa mês a mês (cenário médio)
    println("\n💰 FLUXO DE CAIXA MENSAL (Cenário Médio):")
    println("   Capital Inicial: R\$ $(round(config.caixa_inicial/1e6, digits=1)) Mi\n")
    
    caixa_acumulado = config.caixa_inicial
    for (idx_mes, mes) in enumerate(cache.meses_futuros)
        rec_legado_tot = 0.0; cst_legado_tot = 0.0
        rec_trades_tot = 0.0; cst_trades_tot = 0.0
        
        vol_compra_trades = 0.0; vol_venda_trades = 0.0
        exposicao_liquida_tot = 0.0
        liq_pld_tot = 0.0 # Agora será o valor esperado financeiro real
        
        for submercado in cache.submercados
            horas = horas_mes(mes)
            
            # 1. Contratos Existentes
            venda_leg = get(cache.volume_venda_existente, (mes,submercado), 0.0)
            compra_leg = get(cache.volume_compra_existente, (mes,submercado), 0.0)
            rec_legado_tot += get(cache.preco_venda_existente, (mes,submercado), 0.0) * venda_leg * horas
            cst_legado_tot += get(cache.preco_compra_existente, (mes,submercado), 0.0) * compra_leg * horas
            
            # 2. Novos Trades
            indices_trades = cache.indices_trades_por_mes_submercado[(mes,submercado)]
            for t in indices_trades
                v_venda = value(model[:volume_venda_trade][t])
                v_compra = value(model[:volume_compra_trade][t])
                
                vol_venda_trades += v_venda
                vol_compra_trades += v_compra
                rec_trades_tot += v_venda * data.trades.preco_venda[t] * horas
                cst_trades_tot += v_compra * data.trades.preco_compra[t] * horas
            end
            
            # 3. Mercado Spot / PLD (Cálculo Exato Cenário a Cenário)
            compra_total = compra_leg + sum(value(model[:volume_compra_trade][t]) for t in indices_trades; init=0.0)
            venda_total = venda_leg + sum(value(model[:volume_venda_trade][t]) for t in indices_trades; init=0.0)
            
            # Calcula Exposição Média (Apenas para o log visual)
            producao_media = mean([
                sum(get(cache.producao_usina, (mes, u, c), 0.0) for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado; init=0.0)
                for c in cache.cenarios_preco
            ])
            exposicao_liquida_tot += (producao_media + compra_total - venda_total)
            
            # Calcula o Custo Financeiro Real (Cenário a Cenário - Matematicamente Perfeito)
            liq_pld_sub_cenarios = Float64[]
            for c in cache.cenarios_preco
                prod_c = sum(get(cache.producao_usina, (mes, u, c), 0.0) for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado; init=0.0)
                expo_c = prod_c + compra_total - venda_total
                pld_c = get(cache.pld_cenario, (mes, submercado, c), 0.0)
                push!(liq_pld_sub_cenarios, expo_c * horas * pld_c)
            end
            liq_pld_tot += mean(liq_pld_sub_cenarios) # Média real do faturamento
        end
        
        fluxo_mes = (rec_legado_tot - cst_legado_tot) + (rec_trades_tot - cst_trades_tot) + liq_pld_tot
        caixa_acumulado += fluxo_mes
        
        # Coleta estatísticas de PLD do SE para exibir no log (Referência Nacional)
        plds_mes_se = [get(cache.pld_cenario, (mes, "SE", c), 0.0) for c in cache.cenarios_preco]
        pld_min = minimum(plds_mes_se)
        pld_med = mean(plds_mes_se)
        pld_max = maximum(plds_mes_se)
        
        println("   Mês $(idx_mes) ($(Dates.format(mes, "yyyy-mm")))")
        println("      ↳ Contratos Legado: Recebeu R\$ $(round(rec_legado_tot/1e6, digits=2)) Mi | Pagou R\$ $(round(cst_legado_tot/1e6, digits=2)) Mi")
        println("      ↳ Novos Trades:     Vendeu $(round(vol_venda_trades, digits=1)) MWm (R\$ $(round(rec_trades_tot/1e6, digits=2)) Mi) | Comprou $(round(vol_compra_trades, digits=1)) MWm (R\$ $(round(cst_trades_tot/1e6, digits=2)) Mi)")
        println("      ↳ Mercado Spot:     Exposição Média de $(round(exposicao_liquida_tot, digits=1)) MWm | $(liq_pld_tot >= 0 ? "Ganhou" : "Pagou") R\$ $(round(abs(liq_pld_tot)/1e6, digits=2)) Mi no PLD (Valor Esperado)")
        println("                          [PLD de Exemplo SE] Mín: R\$ $(round(pld_min, digits=2)) | Médio: R\$ $(round(pld_med, digits=2)) | Máx: R\$ $(round(pld_max, digits=2)) / MWh")
        println("      ========================================================")
        println("      = Fluxo do Mês:     $(fluxo_mes >= 0 ? "+" : "")R\$ $(round(fluxo_mes/1e6, digits=2)) Mi")
        println("      = Saldo em Caixa:   R\$ $(round(caixa_acumulado/1e6, digits=2)) Mi\n")
    end
    
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
        # Produção média entre todos os cenários
        producao = mean([
            sum(
                get(cache.producao_usina, (mes, u, cenario), 0.0) 
                for u in cache.usinas if get(cache.submercado_usina, u, "") == submercado;
                init=0.0
            )
            for cenario in cache.cenarios_preco
        ])
        
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
    
    melhor_lambda = NaN
    if nrow(resultados) > 1
        bench = resultados[1, :]
        melhor_saldo = resultados[argmax(resultados.Saldo_Final_Milhoes), :]
        melhor_cvar = resultados[argmax(resultados.CVaR_Saldo_Milhoes), :]
        melhor_lambda = melhor_cvar.Lambda
        
        println("\n📈 ANÁLISE DE VALOR AGREGADO:")
        ganho_saldo = melhor_saldo.Saldo_Final_Milhoes - bench.Saldo_Final_Milhoes
        ganho_cvar = melhor_cvar.CVaR_Saldo_Milhoes - bench.CVaR_Saldo_Milhoes
        
        println("   Melhor Saldo Final: λ=$(melhor_saldo.Lambda) → R\$ $(round(melhor_saldo.Saldo_Final_Milhoes, digits=1)) Mi ($(ganho_saldo >= 0 ? "+" : "")$(round(ganho_saldo, digits=1)) vs benchmark)")
        println("   Melhor CVaR:        λ=$(melhor_cvar.Lambda) → R\$ $(round(melhor_cvar.CVaR_Saldo_Milhoes, digits=1)) Mi (+$(round(ganho_cvar, digits=1)) vs benchmark)")
        println("\n   Interpretação: CVaR = saldo em caixa médio nos 5% piores cenários (quanto MAIOR, melhor)")
    end
    
    return melhor_lambda
end

function main()
    config = load_frontier_config()
    data = load_market_data(config)
    cache = build_optimization_cache(data)
    
    resultados = run_frontier_optimization(config, data, cache)
    melhor_lambda = save_results(resultados, config)
    
    # Exporta estratégia do melhor lambda (maior CVaR)
    if !isnan(melhor_lambda)
        export_hedge_strategy(melhor_lambda, config, data, cache)
    end
end

main()