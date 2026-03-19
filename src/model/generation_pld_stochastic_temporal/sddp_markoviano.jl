include("sddp_common.jl")

function load_sddp_config()
    return SDDPConfig(
        joinpath(@__DIR__, "..", "..", "..", "data", "processed"),
        60,      # Meses do horizonte
        100,     # Cenários (limitado para grafo markoviano)
        42,      # Seed para reprodutibilidade
        0.95,    # Alpha do CVaR
        0.01,    # Lambda (peso do risco)
        20,      # Iterações do SDDP
        2000     # Simulações
    )
end

function preprocess_data(config::SDDPConfig, data::MarketData)
    meses, submercados, cenarios_selecionados, contratos_filtrado, trades_filtrado, idx_pld, idx_geracao =
        _preprocess_base(config, data)

    println("   🔄 Montando dados_por_mes e trajetorias...")
    dados_por_mes = Dict{Int, NamedTuple}()
    trajetorias   = Dict{Int, Dict{Int, NamedTuple}}(c => Dict{Int, NamedTuple}() for c in cenarios_selecionados)
    for (t, mes) in enumerate(meses)
        print("\r   Mês $t/$(length(meses)): $mes")
        flush(stdout)
        contratos_mes = filter(r -> r.data == mes, contratos_filtrado)
        vol_compra_exist, vol_venda_exist, preco_compra_exist, preco_venda_exist =
            _contratos_por_submercado(submercados, contratos_mes)
        dados_por_mes[t] = (
            mes                = mes,
            submercados        = submercados,
            vol_compra_exist   = vol_compra_exist,
            vol_venda_exist    = vol_venda_exist,
            preco_compra_exist = preco_compra_exist,
            preco_venda_exist  = preco_venda_exist,
            trades             = filter(r -> r.data == mes, trades_filtrado),
            horas              = horas_mes(mes)
        )
        for cenario in cenarios_selecionados
            pld     = Dict(sub => get(idx_pld,    (mes, cenario, sub), 0.0) for sub in submercados)
            geracao = Dict(sub => get(idx_geracao, (mes, cenario, sub), 0.0) for sub in submercados)
            trajetorias[cenario][t] = (pld=pld, geracao=geracao)
        end
    end

    println("\n   ✓ Pré-processamento concluído")
    return meses, submercados, cenarios_selecionados, dados_por_mes, trajetorias
end

function build_sddp_model(meses, cenarios_selecionados, dados_por_mes, trajetorias)
    println("   🔨 Construindo grafo markoviano...")
    flush(stdout)
    ESCALA = 1e6
    limite_credito_escala = -100.0
    ncen = length(cenarios_selecionados)
    total_nos = length(meses) * ncen
    graph = SDDP.MarkovianGraph(
        stages               = length(meses),
        transition_matrix    = Matrix{Float64}(I, ncen, ncen),
        root_node_transition = fill(1.0 / ncen, ncen)
    )
    model = SDDP.PolicyGraph(
        graph;
        sense       = :Max,
        upper_bound = 1e6,
        optimizer   = HiGHS.Optimizer
    ) do sp, node
        t, markov_state = node
        cenario = cenarios_selecionados[markov_state]
        dados   = dados_por_mes[t]
        ω       = trajetorias[cenario][t]

        no_atual = (t - 1) * ncen + markov_state
        if no_atual % 500 == 0 || no_atual == total_nos
            print("\r   Construindo nós: $no_atual/$total_nos")
            flush(stdout)
        end
        @variable(sp, caixa, SDDP.State, initial_value=0.0)
        @variable(sp, vol_futuro[dados.submercados, 1:5], SDDP.State, initial_value=0.0)
        @variable(sp, custo_futuro[1:5], SDDP.State, initial_value=0.0)
        num_trades = nrow(dados.trades)
        if num_trades > 0
            @variable(sp, 0 <= volume_compra[i=1:num_trades] <= dados.trades.limite_compra[i])
            @variable(sp, 0 <= volume_venda[i=1:num_trades]  <= dados.trades.limite_venda[i])
        else
            @variable(sp, volume_compra[1:0])
            @variable(sp, volume_venda[1:0])
        end
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
        lucro_legado = 0.0
        for sub in dados.submercados
            lucro_legado += (dados.preco_venda_exist[sub] * dados.vol_venda_exist[sub] -
                             dados.preco_compra_exist[sub] * dados.vol_compra_exist[sub]) * dados.horas / ESCALA
        end
        custo_novos_trades_mes_atual = @expression(sp,
            sum(
                (volume_venda[i] * dados.trades.preco_venda[i] - volume_compra[i] * dados.trades.preco_compra[i]) * dados.horas / ESCALA
                for i in 1:num_trades;
                init=0.0
            )
        )
        fluxo_contratos = @expression(sp, lucro_legado + custo_novos_trades_mes_atual + custo_futuro[1].in)
        @variable(sp, spot_profit[dados.submercados])
        @constraint(sp, transicao_caixa,
            caixa.out == caixa.in + fluxo_contratos + sum(spot_profit[sub] for sub in dados.submercados))
        @variable(sp, 0 <= emprestimo_emergencia)
        @constraint(sp, limite_ruina, caixa.out + emprestimo_emergencia >= limite_credito_escala)
        @constraint(sp, spot_profit_eq[sub in dados.submercados], spot_profit[sub] == 0.0)
        for sub in dados.submercados
            pld_horas = (ω.pld[sub] * dados.horas) / ESCALA
            exposicao_base = ω.geracao[sub] + dados.vol_compra_exist[sub] - dados.vol_venda_exist[sub]
            JuMP.set_normalized_rhs(spot_profit_eq[sub], exposicao_base * pld_horas)
            trades_sub = findall(r -> r.submercado == sub, eachrow(dados.trades))
            for i in trades_sub
                JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_compra[i], -pld_horas)
                JuMP.set_normalized_coefficient(spot_profit_eq[sub], volume_venda[i],   pld_horas)
            end
            JuMP.set_normalized_coefficient(spot_profit_eq[sub], vol_futuro[sub, 1].in, -pld_horas)
        end
        @stageobjective(sp,
            fluxo_contratos +
            sum(spot_profit[sub] for sub in dados.submercados) -
            10000.0 * emprestimo_emergencia
        )
    end
    println("\n   ✓ Grafo construído")
    return model
end

function main()
    println("\n" * "="^60)
    println("🎯 OTIMIZAÇÃO MULTI-ESTÁGIO COM SDDP.jl — GRAFO MARKOVIANO")
    println("="^60)
    tempo_inicio = time()
    config = load_sddp_config()
    data   = load_market_data(config)
    meses, submercados, cenarios_selecionados, dados_por_mes, trajetorias = preprocess_data(config, data)
    risk_measure = (1 - config.lambda) * SDDP.Expectation() + config.lambda * SDDP.AVaR(config.alpha)
    model = build_sddp_model(meses, cenarios_selecionados, dados_por_mes, trajetorias)
    println("✅ Modelo SDDP construído")
    train_sddp_model(model, risk_measure, config)
    simulate_policy(model, config)
    tempo_total = time() - tempo_inicio
    println("\n" * "="^60)
    println("✅ Otimização SDDP concluída!")
    println("⏱️  Tempo total: $(round(tempo_total, digits=1)) segundos")
    println("="^60)
end

main()
