using SDDP, JuMP, Statistics, CSV, DataFrames, Dates
include("deq.jl")

function build_scenario_indexes(data::MarketData, mercado::DadosMercado)
    sub_por_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))

    pld_idx = Dict{Tuple{Date, Int, String}, Float64}()
    for r in eachrow(data.cenarios)
        pld_idx[(r.data, Int(r.cenario), r.submercado)] = r.valor
    end

    ger_idx = Dict{Tuple{Date, Int, String}, Float64}()
    for r in eachrow(data.geracao)
        sub = get(sub_por_usina, r.usina_cod, "")
        key = (r.data, Int(r.cenario), sub)
        ger_idx[key] = get(ger_idx, key, 0.0) + r.geracao_mwm
    end

    scenario_ids = Dict{Int, Vector{Int}}()
    for (m_idx, mes) in enumerate(mercado.meses)
        ids = sort(unique(Int.(filter(r -> r.data == mes, data.cenarios).cenario)))
        isempty(ids) && error("Sem cenarios para o mes $(mes).")
        scenario_ids[m_idx] = ids
    end

    return scenario_ids, pld_idx, ger_idx
end

function build_hazard_graph(num_meses::Int, scenario_ids::Dict{Int, Vector{Int}})
    graph = SDDP.Graph((0, 0))

    for m in 1:num_meses
        SDDP.add_node(graph, (m, 0))
    end
    for m in 1:num_meses
        for c in scenario_ids[m]
            SDDP.add_node(graph, (m, c))
        end
    end

    SDDP.add_edge(graph, (0, 0) => (1, 0), 1.0)

    for m in 1:num_meses
        p = 1.0 / length(scenario_ids[m])
        for c in scenario_ids[m]
            SDDP.add_edge(graph, (m, 0) => (m, c), p)
            if m < num_meses
                SDDP.add_edge(graph, (m, c) => (m + 1, 0), 1.0)
            end
        end
    end

    return graph
end

function build_sddp_model(config::DEQConfig, data::MarketData, mercado::DadosMercado, max_d::Int)
    println("Construindo o Policy Graph do SDDP...")

    # Reescala interna igual ao DEQ: sem conversão, valores em R$ crus
    ESCALA = config.escala  # 1.0
    L_cred = config.limite_credito  # -1e8 R$
    M_penalty = 1e9  # penalidade alta = crédito quasi-hard (teste risk-neutral)

    trades = filter(r -> r.data in Set(mercado.meses), data.trades)
    NT = nrow(trades)
    subs = mercado.submercados

    scenario_ids, pld_idx, ger_idx = build_scenario_indexes(data, mercado)
    graph = build_hazard_graph(config.num_meses, scenario_ids)

    model = SDDP.PolicyGraph(
        graph,
        sense = :Max,
        lower_bound = -1.0e8,
        optimizer = HiGHS.Optimizer,
        upper_bound = 1.0e8,
    ) do sp, node
        m_idx, c_id = node
        mes = mercado.meses[m_idx]
        h = horas_mes(mes)
        scale_det = h / ESCALA
        trades_no = [i for i in 1:NT if trades.data[i] == mes]

        @variable(sp, caixa, SDDP.State, initial_value = config.caixa_inicial / ESCALA)
        @variable(sp, v[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)
        @variable(sp, c[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)
        @variable(sp, 0 <= qb_state[i in 1:NT] <= trades.limite_compra[i], SDDP.State, initial_value = 0.0)
        @variable(sp, 0 <= qs_state[i in 1:NT] <= trades.limite_venda[i], SDDP.State, initial_value = 0.0)

        if c_id == 0
            @variable(sp, 0 <= q_B[i in trades_no] <= trades.limite_compra[i])
            @variable(sp, 0 <= q_S[i in trades_no] <= trades.limite_venda[i])

            for i in 1:NT
                if trades.data[i] == mes
                    @constraint(sp, qb_state[i].out == q_B[i])
                    @constraint(sp, qs_state[i].out == q_S[i])
                    sp[Symbol("qB_", i)] = q_B[i]
                    sp[Symbol("qS_", i)] = q_S[i]
                else
                    @constraint(sp, qb_state[i].out == 0.0)
                    @constraint(sp, qs_state[i].out == 0.0)
                end
            end

            @constraint(sp, caixa.out == caixa.in)
            for sub in subs, k in 1:max_d
                @constraint(sp, v[sub, k].out == v[sub, k].in)
                @constraint(sp, c[sub, k].out == c[sub, k].in)
            end

            SDDP.@stageobjective(sp, 0.0)
            return
        end

        @variable(sp, slack_credito >= 0)

        for i in 1:NT
            @constraint(sp, qb_state[i].out == 0.0)
            @constraint(sp, qs_state[i].out == 0.0)
        end

        for sub in subs
            trades_sub = filter(i -> trades.submercado[i] == sub, trades_no)
            for k in 1:(max_d - 1)
                delta = isempty(trades_sub) ? 0.0 :
                    sum(qb_state[i].in - qs_state[i].in
                        for i in trades_sub if trades.duracao_meses[i] > k; init = 0.0)
                @constraint(sp, v[sub, k].out == v[sub, k + 1].in + delta)

                delta_fin = isempty(trades_sub) ? 0.0 :
                    sum(qs_state[i].in * trades.preco_venda[i] - qb_state[i].in * trades.preco_compra[i]
                        for i in trades_sub if trades.duracao_meses[i] > k; init = 0.0)
                @constraint(sp, c[sub, k].out == c[sub, k + 1].in + delta_fin)
            end

            delta_max = isempty(trades_sub) ? 0.0 :
                sum(qb_state[i].in - qs_state[i].in
                    for i in trades_sub if trades.duracao_meses[i] > max_d; init = 0.0)
            @constraint(sp, v[sub, max_d].out == delta_max)

            delta_fin_max = isempty(trades_sub) ? 0.0 :
                sum(qs_state[i].in * trades.preco_venda[i] - qb_state[i].in * trades.preco_compra[i]
                    for i in trades_sub if trades.duracao_meses[i] > max_d; init = 0.0)
            @constraint(sp, c[sub, max_d].out == delta_fin_max)
        end

        R_leg = sum(
            (get(mercado.preco_venda_exist, (mes, sub), 0.0) * get(mercado.vol_venda_exist, (mes, sub), 0.0) -
             get(mercado.preco_compra_exist, (mes, sub), 0.0) * get(mercado.vol_compra_exist, (mes, sub), 0.0)) * scale_det
            for sub in subs; init = 0.0)

        cash_expr = AffExpr(R_leg)
        for sub in subs
            pld = get(pld_idx, (mes, c_id, sub), 0.0)
            ger = get(ger_idx, (mes, c_id, sub), 0.0)
            compra_exist = get(mercado.vol_compra_exist, (mes, sub), 0.0)
            venda_exist = get(mercado.vol_venda_exist, (mes, sub), 0.0)
            scale_pld = pld * h / ESCALA

            add_to_expression!(cash_expr, (ger + compra_exist - venda_exist) * scale_pld)
            add_to_expression!(cash_expr, scale_pld, v[sub, 1].in)
            add_to_expression!(cash_expr, scale_det, c[sub, 1].in)
        end

        for i in trades_no
            pld_trade = get(pld_idx, (mes, c_id, trades.submercado[i]), 0.0)
            scale_pld_trade = pld_trade * h / ESCALA
            coeff_b = -trades.preco_compra[i] * scale_det + scale_pld_trade
            coeff_s = trades.preco_venda[i] * scale_det - scale_pld_trade
            add_to_expression!(cash_expr, coeff_b, qb_state[i].in)
            add_to_expression!(cash_expr, coeff_s, qs_state[i].in)
        end

        @constraint(sp, caixa.out - caixa.in == cash_expr)
        @constraint(sp, caixa.out + slack_credito >= L_cred)

        # Soma dos ganhos mensais de caixa (telescopa para saldo final, pois odd stages têm objetivo zero).
        SDDP.@stageobjective(sp, (caixa.out - caixa.in) - M_penalty * slack_credito)
    end

    return model, trades, ESCALA
end

function main_sddp()
    println("\n" * "="^60)
    println("SDDP MULTIESTAGIO - TREINAMENTO")
    println("="^60)

    config = load_deq_config()
    data = load_market_data(config)
    mercado = preprocess_market(data, config)
    trades = filter(r -> r.data in Set(mercado.meses), data.trades)
    max_d = maximum(trades.duracao_meses)

    model, trades, ESCALA = build_sddp_model(config, data, mercado, max_d)

    println("\nIniciando treinamento SDDP (CVaR terminal)...")
    # CVaR terminal: Expectation em todos os nos exceto o ultimo estagio de liquidacao,
    # onde aplica EAVaR(lambda, alpha) — equivalente ao CVaR terminal do DEQ.
    # Os nos do grafo sao (m, 0) para decisao e (m, c) para liquidacao.
    # O ultimo estagio de liquidacao e (num_meses, c) para cada cenario c.
    scenario_ids_last = sort(unique(Int.(filter(r -> r.data == mercado.meses[end], data.cenarios).cenario)))
    last_nodes = Set([(config.num_meses, c) for c in scenario_ids_last])
    risk_dict = Dict{Tuple{Int,Int}, SDDP.AbstractRiskMeasure}()
    for m in 1:config.num_meses
        risk_dict[(m, 0)] = SDDP.Expectation()
        for c in sort(unique(Int.(filter(r -> r.data == mercado.meses[m], data.cenarios).cenario)))
            if (m, c) in last_nodes
                # Ultimo estagio: aplica CVaR terminal, equivalente ao DEQ
                risk_dict[(m, c)] = SDDP.EAVaR(
                    lambda = config.lambda / (1.0 + config.lambda),
                    beta   = config.alpha,
                )
            else
                risk_dict[(m, c)] = SDDP.Expectation()
            end
        end
    end
    SDDP.train(
        model,
        iteration_limit = 2000,
        stopping_rules = [SDDP.BoundStalling(100, 1e-6)],
        print_level = 1,
        risk_measure = risk_dict,
    )

    bound = SDDP.calculate_bound(model)
    println("\nTreinamento concluido!")
    println("   Upper Bound (Z) : R\$ $(round(bound / 1e6, digits = 3)) Mi")

    trade_ids = 1:nrow(trades)
    sim_syms = vcat([:caixa],
                    [Symbol("qB_", i) for i in trade_ids],
                    [Symbol("qS_", i) for i in trade_ids])

    sims = SDDP.simulate(model, 1000, sim_syms; skip_undefined_variables = true)

    saldos_finais = [sim[end][:caixa].out for sim in sims]
    println("   E[Saldo Final] (1000 simulacoes) : R\$ $(round(mean(saldos_finais) / 1e6, digits = 3)) Mi")

    println("\nTrades executados no mes 1 (decisao unica, pre-cenario):")
    trades_mes1 = [i for i in trade_ids if trades.data[i] == mercado.meses[1]]
    for i in trades_mes1
        qb = get(sims[1][1], Symbol("qB_", i), 0.0)
        qs = get(sims[1][1], Symbol("qS_", i), 0.0)
        if qb > 0.01 || qs > 0.01
            println("  $(trades.ticker[i]): compra=$(round(qb, digits = 2)) MWm  venda=$(round(qs, digits = 2)) MWm")
        end
    end

    rows = NamedTuple{(:simulacao, :estagio, :mes, :ticker, :compra_mwm, :venda_mwm, :saldo_mi),
                      Tuple{Int, Int, Date, String, Float64, Float64, Float64}}[]
    for (s_idx, sim) in enumerate(sims)
        for m_idx in 1:config.num_meses
            mes = mercado.meses[m_idx]
            stage_dec = sim[2 * m_idx - 1]
            stage_settle = sim[2 * m_idx]
            saldo = stage_settle[:caixa].out / 1e6
            for i in trade_ids
                trades.data[i] == mes || continue
                qb = get(stage_dec, Symbol("qB_", i), nothing)
                qs = get(stage_dec, Symbol("qS_", i), nothing)
                qb === nothing && continue
                push!(rows, (s_idx, m_idx, mes, trades.ticker[i],
                             round(qb, digits = 4), round(qs, digits = 4), round(saldo, digits = 3)))
            end
        end
    end

    out_path = joinpath(config.data_dir, "..", "results", "sddp_decisoes.csv")
    mkpath(dirname(out_path))
    CSV.write(out_path, DataFrame(rows))
    println("   Decisoes exportadas: $out_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main_sddp()
end

main_sddp()