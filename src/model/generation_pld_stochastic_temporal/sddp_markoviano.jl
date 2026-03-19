using CSV, DataFrames, Dates, SDDP, HiGHS, Statistics, Printf, Random, LinearAlgebra

println("Rodando com ", Threads.nthreads(), " threads ativas!")

struct SDDPConfig
    data_dir::String
    num_meses::Int
    num_cenarios::Int
    seed::Int
    alpha::Float64
    lambda::Float64
    iteration_limit::Int
    num_simulations::Int
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    contratos_existentes::DataFrame
    trades::DataFrame
end

function load_sddp_config()
    return SDDPConfig(
        joinpath(@__DIR__, "..", "..", "..", "data", "processed"),
        60,      # Primeiros 60 meses
        2000,       # Cenários (limitado para grafo markoviano)
        42,      # Seed para reprodutibilidade
        0.95,    # Alpha do CVaR
        0.01,    # Lambda (peso do risco)
        20,      # Iterações do SDDP
        2000      # Simulações
    )
end

function load_market_data(config::SDDPConfig)::MarketData
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

horas_mes(d::Date) = daysinmonth(d) * 24

function build_sddp_model(config::SDDPConfig, data::MarketData)
    println("⚙️ Construindo modelo SDDP...")
    
    # Extrai conjuntos - PARAMETRIZADO
    todos_meses = sort(unique(data.cenarios.data))
    meses = todos_meses[1:min(config.num_meses, length(todos_meses))]
    submercados = unique(data.cenarios.submercado)
    usinas = unique(data.geracao.usina_cod)
    num_cenarios_total = maximum(data.cenarios.cenario)
    
    # Seleciona cenários aleatórios com seed
    Random.seed!(config.seed)
    cenarios_selecionados = sort(randperm(num_cenarios_total)[1:min(config.num_cenarios, num_cenarios_total)])
    
    println("   📅 Meses: $(length(meses)) | 🏭 Usinas: $(length(usinas))")
    println("   🎲 Cenários: $(length(cenarios_selecionados)) de $num_cenarios_total (seed=$(config.seed))")
    
    submercado_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))
    
    println("   Criando dicionários de acesso rápido...")
    dict_pld = Dict((r.data, r.submercado, r.cenario) => r.valor for r in eachrow(data.cenarios))
    dict_geracao = Dict((r.data, r.usina_cod, r.cenario) => r.geracao_mwm for r in eachrow(data.geracao))

    println("   🔄 Pré-processando dados por mês...")
    dados_por_mes = Dict()
    for (t, mes) in enumerate(meses)
        print("\r   Mês $t/$(length(meses)): $mes")
        flush(stdout)
        
        contratos_mes = filter(row -> row.data == mes, data.contratos_existentes)
        vol_compra_exist = Dict()
        vol_venda_exist = Dict()
        preco_compra_exist = Dict()
        preco_venda_exist = Dict()
        
        for sub in submercados
            compras = filter(row -> row.submercado == sub && row.tipo == "COMPRA", contratos_mes)
            vendas = filter(row -> row.submercado == sub && row.tipo == "VENDA", contratos_mes)
            
            vol_compra_exist[sub] = nrow(compras) > 0 ? sum(compras.volume_mwm) : 0.0
            vol_venda_exist[sub] = nrow(vendas) > 0 ? sum(vendas.volume_mwm) : 0.0
            preco_compra_exist[sub] = nrow(compras) > 0 ? sum(compras.volume_mwm .* compras.preco_r_mwh) / sum(compras.volume_mwm) : 0.0
            preco_venda_exist[sub] = nrow(vendas) > 0 ? sum(vendas.volume_mwm .* vendas.preco_r_mwh) / sum(vendas.volume_mwm) : 0.0
        end
        
        trades_mes = filter(row -> row.data == mes, data.trades)
        
        dados_por_mes[t] = (
            mes=mes,
            submercados=submercados,
            vol_compra_exist=vol_compra_exist,
            vol_venda_exist=vol_venda_exist,
            preco_compra_exist=preco_compra_exist,
            preco_venda_exist=preco_venda_exist,
            trades=trades_mes,
            horas=horas_mes(mes)
        )
    end
    println("\n   ✓ Pré-processamento concluído")
    
    println("   🔄 Construindo dicionário de trajetórias...")
    trajetorias = Dict{Int, Dict{Int, NamedTuple}}()
    for c in cenarios_selecionados
        trajetorias[c] = Dict{Int, NamedTuple}()
    end
    for (t, mes) in enumerate(meses)
        for cenario in cenarios_selecionados
            pld = Dict(sub => get(dict_pld, (mes, sub, cenario), 0.0) for sub in submercados)
            geracao = Dict(sub => sum(get(dict_geracao, (mes, u, cenario), 0.0) for u in usinas if get(submercado_usina, u, "") == sub; init=0.0) for sub in submercados)
            trajetorias[cenario][t] = (pld=pld, geracao=geracao)
        end
    end
    println("   ✓ Trajetórias construídas")
    
    println("   🔨 Construindo grafo (pode demorar)...")
    flush(stdout)
    
    ESCALA = 1e6
    limite_credito_escala = -100.0  # -100 milhões de reais
    
    ncen = length(cenarios_selecionados)
    graph = SDDP.MarkovianGraph(
        stages = length(meses),
        transition_matrix = Matrix{Float64}(I, ncen, ncen),
        root_node_transition = fill(1.0 / ncen, ncen)
    )
    model = SDDP.PolicyGraph(
        graph;
        sense = :Max,
        upper_bound = 1e6,
        optimizer = HiGHS.Optimizer
    ) do sp, node
        t, markov_state = node
        cenario = cenarios_selecionados[markov_state]
        dados = dados_por_mes[t]
        ω = trajetorias[cenario][t]
        
        total_nos = length(meses) * ncen
        no_atual = (t - 1) * ncen + markov_state
        print("\r   Construindo nós: $no_atual/$total_nos")
        flush(stdout)
        
        # 1. Variáveis de estado: caixa + pipeline temporal de contratos forward
        @variable(sp, caixa, SDDP.State, initial_value=0.0)
        @variable(sp, vol_futuro[dados.submercados, 1:5], SDDP.State, initial_value=0.0)
        @variable(sp, custo_futuro[1:5], SDDP.State, initial_value=0.0)
        
        # 2. Variáveis de decisão (trades)
        num_trades = nrow(dados.trades)
        if num_trades > 0
            @variable(sp, 0 <= volume_compra[i=1:num_trades] <= dados.trades.limite_compra[i])
            @variable(sp, 0 <= volume_venda[i=1:num_trades] <= dados.trades.limite_venda[i])
        else
            @variable(sp, volume_compra[1:0])
            @variable(sp, volume_venda[1:0])
        end
        
        # 3. Agregação dos novos trades por duração
        # vol_add_futuro[sub, k]: volume líquido (compra - venda) que afeta o nível futuro k
        # custo_add_futuro[k]: fluxo financeiro (receita - custo) que afeta o nível futuro k
        # Um trade com duracao_meses D afeta o mês atual E os níveis k=1..(D-1)
        vol_add_futuro = Dict(
            (sub, k) => @expression(sp,
                sum(
                    (volume_compra[i] - volume_venda[i])
                    for i in 1:num_trades
                    if dados.trades.submercado[i] == sub && dados.trades.duracao_meses[i] > k;
                    init=0.0
                )
            )
            for sub in dados.submercados, k in 1:5
        )
        custo_add_futuro = Dict(
            k => @expression(sp,
                sum(
                    (volume_venda[i] * dados.trades.preco_venda[i] - volume_compra[i] * dados.trades.preco_compra[i]) * dados.horas / ESCALA
                    for i in 1:num_trades
                    if dados.trades.duracao_meses[i] > k;
                    init=0.0
                )
            )
            for k in 1:5
        )
        
        # 4. Equações de transição do pipeline temporal
        for sub in dados.submercados
            for k in 1:4
                @constraint(sp, vol_futuro[sub, k].out == vol_futuro[sub, k+1].in + vol_add_futuro[sub, k])
            end
            @constraint(sp, vol_futuro[sub, 5].out == vol_add_futuro[sub, 5])
        end
        for k in 1:4
            @constraint(sp, custo_futuro[k].out == custo_futuro[k+1].in + custo_add_futuro[k])
        end
        @constraint(sp, custo_futuro[5].out == custo_add_futuro[5])
        
        # 5. Lucro determinístico do mês atual
        lucro_legado = 0.0
        for sub in dados.submercados
            receita_venda_exist = dados.preco_venda_exist[sub] * dados.vol_venda_exist[sub] * dados.horas
            custo_compra_exist = dados.preco_compra_exist[sub] * dados.vol_compra_exist[sub] * dados.horas
            lucro_legado += (receita_venda_exist - custo_compra_exist) / ESCALA
        end
        
        custo_novos_trades_mes_atual = @expression(sp,
            sum(
                (volume_venda[i] * dados.trades.preco_venda[i] - volume_compra[i] * dados.trades.preco_compra[i]) * dados.horas / ESCALA
                for i in 1:num_trades;
                init=0.0
            )
        )
        
        # fluxo_contratos: legado + novos trades mês atual + liquidação de contratos herdados
        fluxo_contratos = @expression(sp, lucro_legado + custo_novos_trades_mes_atual + custo_futuro[1].in)
        
        # 6. Variáveis auxiliares para lucro spot (estocástico)
        @variable(sp, spot_profit[dados.submercados])
        
        # 7. Restrição de transição de estado (estrutural)
        @constraint(sp, transicao_caixa, caixa.out == caixa.in + fluxo_contratos + sum(spot_profit[sub] for sub in dados.submercados))
        
        # 8. Restrição de limite de crédito (ruína) COM SLACK
        @variable(sp, 0 <= emprestimo_emergencia)
        @constraint(sp, limite_ruina, caixa.out + emprestimo_emergencia >= limite_credito_escala)
        
        # 9. Restrições de spot_profit com coeficientes da trajetória fixa do nó
        @constraint(sp, spot_profit_eq[sub in dados.submercados], spot_profit[sub] == 0.0)
        
        for sub in dados.submercados
            pld_horas = (ω.pld[sub] * dados.horas) / ESCALA
            
            exposicao_base = ω.geracao[sub] + dados.vol_compra_exist[sub] - dados.vol_venda_exist[sub]
            JuMP.set_normalized_rhs(spot_profit_eq[sub], exposicao_base * pld_horas)
            
            trades_sub = findall(row -> row.submercado == sub, eachrow(dados.trades))
            if !isempty(trades_sub)
                for i in trades_sub
                    JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_compra[i], -pld_horas)
                    JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_venda[i], pld_horas)
                end
            end
            
            JuMP.set_normalized_coefficient(spot_profit_eq[sub], vol_futuro[sub, 1].in, -pld_horas)
        end
        
        # Objetivo: lucro total (trades + spot) - Multa por falência
        @stageobjective(sp, fluxo_contratos + sum(spot_profit[sub] for sub in dados.submercados) - (10000.0 * emprestimo_emergencia))
    end
    
    println("\n   ✓ Grafo construído")
    risk_measure = (1 - config.lambda) * SDDP.Expectation() + config.lambda * SDDP.AVaR(config.alpha)
    
    println("✅ Modelo SDDP construído")
    return model, meses, dados_por_mes, risk_measure
end

function train_sddp_model(model, risk_measure, config::SDDPConfig)
    println("\n🚀 Treinando modelo SDDP ($(config.iteration_limit) iterações)...\n")
    
    SDDP.train(model, 
        iteration_limit=config.iteration_limit,
        risk_measure=risk_measure,
        print_level=1,
        log_frequency=1,
    )
    
    println("\n✅ Treinamento concluído")
end

function simulate_policy(model, config::SDDPConfig, meses, dados_por_mes)
    println("\n📊 Simulando política ótima ($(config.num_simulations) trajetórias)...")
    
    simulations = SDDP.simulate(model, config.num_simulations, [:caixa])
    
    lucros_totais = [sim[end][:caixa].out * 1e6 for sim in simulations]
    retorno_esperado = mean(lucros_totais) / 1e6
    desvio_padrao = std(lucros_totais) / 1e6
    
    lucros_ordenados = sort(lucros_totais)
    idx_var = Int(ceil((1 - config.alpha) * length(lucros_ordenados)))
    var_value = lucros_ordenados[idx_var]
    cvar_lucro = mean(lucros_ordenados[1:idx_var]) / 1e6
    
    # Agora podemos rastrear caixa!
    caixa_final_medio = mean([sim[end][:caixa].out for sim in simulations]) * 1e6
    caixa_minimo = minimum([minimum([stage[:caixa].out for stage in sim]) for sim in simulations]) * 1e6
    
    println("\n📈 RESULTADOS DA SIMULAÇÃO:")
    println("   Retorno Esperado:  R\$ $(round(retorno_esperado, digits=1)) Mi")
    println("   CVaR (5% piores):  R\$ $(round(cvar_lucro, digits=1)) Mi")
    println("   Desvio Padrão:     R\$ $(round(desvio_padrao, digits=1)) Mi")
    println("   VaR (95%):         R\$ $(round(var_value/1e6, digits=1)) Mi")
    println("   Caixa Final Médio: R\$ $(round(caixa_final_medio / 1e6, digits=1)) Mi")
    println("   Caixa Mínimo:      R\$ $(round(caixa_minimo / 1e6, digits=1)) Mi")
    
    return simulations, retorno_esperado, cvar_lucro, desvio_padrao
end

function main()
    println("\n" * "="^60)
    println("🎯 OTIMIZAÇÃO MULTI-ESTÁGIO COM SDDP.jl")
    println("="^60)
    
    tempo_inicio = time()
    
    config = load_sddp_config()
    data = load_market_data(config)
    
    model, meses, dados_por_mes, risk_measure = build_sddp_model(config, data)
    train_sddp_model(model, risk_measure, config)
    simulations, retorno, cvar, std_dev = simulate_policy(model, config, meses, dados_por_mes)
    
    tempo_total = time() - tempo_inicio
    println("\n" * "="^60)
    println("✅ Otimização SDDP concluída!")
    println("⏱️  Tempo total: $(round(tempo_total, digits=1)) segundos")
    println("="^60)
end

main()
