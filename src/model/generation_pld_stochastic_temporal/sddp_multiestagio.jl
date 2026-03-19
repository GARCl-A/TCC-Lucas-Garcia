using CSV, DataFrames, Dates, SDDP, HiGHS, Statistics, Printf, Random

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
        60,      # Primeiros 12 meses
        2000,      # 10 cenários aleatórios
        42,      # Seed para reprodutibilidade
        0.95,    # Alpha do CVaR
        0.01,    # Lambda (peso do risco)
        3,      # Iterações do SDDP
        100      # Simulações
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
        
        # Ruídos com cenários selecionados
        ruidos = []
        prob = 1.0 / length(cenarios_selecionados)
        for cenario in cenarios_selecionados
            pld = Dict(sub => get(dict_pld, (mes, sub, cenario), 0.0) for sub in submercados)
            geracao = Dict(sub => sum(get(dict_geracao, (mes, u, cenario), 0.0) for u in usinas if get(submercado_usina, u, "") == sub; init=0.0) for sub in submercados)
            push!(ruidos, (pld=pld, geracao=geracao, probabilidade=prob))
        end
        
        dados_por_mes[t] = (
            mes=mes,
            submercados=submercados,
            vol_compra_exist=vol_compra_exist,
            vol_venda_exist=vol_venda_exist,
            preco_compra_exist=preco_compra_exist,
            preco_venda_exist=preco_venda_exist,
            trades=trades_mes,
            ruidos=ruidos,
            horas=horas_mes(mes)
        )
    end
    println("\n   ✓ Pré-processamento concluído")
    
    println("   🔨 Construindo grafo (pode demorar)...")
    flush(stdout)
    
    ESCALA = 1e6
    limite_credito_escala = -100.0  # -100 milhões de reais
    
    # Upper bound: 1 trilhão de reais (em escala de milhões = 1e6)
    model = SDDP.LinearPolicyGraph(
        stages=length(meses),
        sense=:Max,
        upper_bound=1e6,
        optimizer=HiGHS.Optimizer
    ) do sp, t
        print("\r   Estágio $t/$(length(meses))")
        flush(stdout)
        
        dados = dados_por_mes[t]
        
        # 1. Variável de estado caixa
        @variable(sp, caixa, SDDP.State, initial_value=0.0)
        
        # 2. Variáveis de decisão (trades)
        num_trades = nrow(dados.trades)
        if num_trades > 0
            @variable(sp, 0 <= volume_compra[i=1:num_trades] <= dados.trades.limite_compra[i])
            @variable(sp, 0 <= volume_venda[i=1:num_trades] <= dados.trades.limite_venda[i])
        else
            @variable(sp, volume_compra[1:0])
            @variable(sp, volume_venda[1:0])
        end
        
        # 3. Lucro determinístico (contratos legados + novos trades)
        lucro_fixo = 0.0
        for sub in dados.submercados
            receita_venda_exist = dados.preco_venda_exist[sub] * dados.vol_venda_exist[sub] * dados.horas
            custo_compra_exist = dados.preco_compra_exist[sub] * dados.vol_compra_exist[sub] * dados.horas
            lucro_fixo += (receita_venda_exist - custo_compra_exist) / ESCALA
        end
        
        lucro_trades = @expression(sp, lucro_fixo)
        for sub in dados.submercados
            trades_sub = findall(row -> row.submercado == sub, eachrow(dados.trades))
            if !isempty(trades_sub)
                for i in trades_sub
                    lucro_trades += (volume_venda[i] * dados.trades.preco_venda[i] - volume_compra[i] * dados.trades.preco_compra[i]) * dados.horas / ESCALA
                end
            end
        end
        
        # 4. Variáveis auxiliares para lucro spot (estocástico)
        @variable(sp, spot_profit[dados.submercados])
        
        # 5. Restrição de transição de estado (estrutural)
        @constraint(sp, transicao_caixa, caixa.out == caixa.in + lucro_trades + sum(spot_profit[sub] for sub in dados.submercados))
        
        # 6. Restrição de limite de crédito (ruína)
        @constraint(sp, limite_ruina, caixa.out >= limite_credito_escala)
        
        # 7. Restrições "molde" para spot_profit (serão modificadas no parameterize)
        @constraint(sp, spot_profit_eq[sub in dados.submercados], spot_profit[sub] == 0.0)
        
        # 8. Parameterização estocástica (modifica coeficientes)
        SDDP.parameterize(sp, dados.ruidos) do ω
            for sub in dados.submercados
                pld_horas = (ω.pld[sub] * dados.horas) / ESCALA
                
                # RHS: exposição base (geração + contratos legados) * PLD
                exposicao_base = ω.geracao[sub] + dados.vol_compra_exist[sub] - dados.vol_venda_exist[sub]
                rhs_val = exposicao_base * pld_horas
                JuMP.set_normalized_rhs(spot_profit_eq[sub], rhs_val)
                
                # Coeficientes: novos trades afetam exposição ao spot
                trades_sub = findall(row -> row.submercado == sub, eachrow(dados.trades))
                if !isempty(trades_sub)
                    for i in trades_sub
                        # Compra reduz exposição (coef positivo), venda aumenta (coef negativo)
                        JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_compra[i], -pld_horas)
                        JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_venda[i], pld_horas)
                    end
                end
            end
            
            # Objetivo: lucro total (trades + spot)
            @stageobjective(sp, lucro_trades + sum(spot_profit[sub] for sub in dados.submercados))
        end
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
    
    lucros_totais = [sum(stage[:stage_objective] for stage in sim) * 1e6 for sim in simulations]
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
