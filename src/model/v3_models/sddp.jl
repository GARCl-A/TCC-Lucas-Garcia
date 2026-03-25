using SDDP, JuMP, Statistics, CSV, DataFrames
include("deq.jl")

struct SDDPNoise
    pld::Dict{String, Float64}
    geracao::Dict{String, Float64}
end

function build_sddp_model(config::DEQConfig, data::MarketData, mercado::DadosMercado, max_d::Int)
    println("Construindo o Policy Graph do SDDP...")

    ESCALA = config.escala
    L_cred = config.limite_credito / ESCALA  # -0.1 em unidades internas

    # M deve ser >> escala do objetivo real.
    # Objetivo esperado ~ 0.02 unidades internas.
    # M = 1.0 garante que qualquer violação de crédito é penalizada mais do que o ganho máximo.
    M_penalty = 1.0

    model = SDDP.PolicyGraph(
        SDDP.LinearGraph(config.num_meses),
        sense      = :Max,
        lower_bound = -M_penalty,          # pior caso: slack máximo por T estágios
        optimizer  = HiGHS.Optimizer,
        upper_bound = 0.5                  # acima do ótimo esperado (~0.02), abaixo de M
    ) do sp, t

        mes  = mercado.meses[t]
        h    = horas_mes(mes)
        subs = mercado.submercados

        trades_no = [i for i in 1:mercado.num_trades if data.trades.data[i] == mes]

        # Estados
        @variable(sp, caixa, SDDP.State, initial_value = config.caixa_inicial / ESCALA)
        @variable(sp, v[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)
        @variable(sp, c[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)

        # Folga para recurso completo relativo (conforme .tex)
        @variable(sp, slack_credito >= 0)

        # Decisões
        @variable(sp, 0 <= q_B[i in trades_no] <= data.trades.limite_compra[i])
        @variable(sp, 0 <= q_S[i in trades_no] <= data.trades.limite_venda[i])

        # Registra para captura no simulate
        for i in trades_no
            sp[Symbol("qB_", i)] = q_B[i]
            sp[Symbol("qS_", i)] = q_S[i]
        end

        # Transição do pipeline de volumes
        for sub in subs
            trades_sub = filter(i -> data.trades.submercado[i] == sub, trades_no)
            for k in 1:(max_d - 1)
                delta = isempty(trades_sub) ? 0.0 :
                    sum(q_B[i] - q_S[i] for i in trades_sub if data.trades.duracao_meses[i] > k; init=0.0)
                @constraint(sp, v[sub, k].out == v[sub, k+1].in + delta)
                delta_fin = isempty(trades_sub) ? 0.0 :
                    sum(q_S[i]*data.trades.preco_venda[i] - q_B[i]*data.trades.preco_compra[i]
                        for i in trades_sub if data.trades.duracao_meses[i] > k; init=0.0)
                @constraint(sp, c[sub, k].out == c[sub, k+1].in + delta_fin)
            end
            delta_max = isempty(trades_sub) ? 0.0 :
                sum(q_B[i] - q_S[i] for i in trades_sub if data.trades.duracao_meses[i] > max_d; init=0.0)
            @constraint(sp, v[sub, max_d].out == delta_max)
            delta_fin_max = isempty(trades_sub) ? 0.0 :
                sum(q_S[i]*data.trades.preco_venda[i] - q_B[i]*data.trades.preco_compra[i]
                    for i in trades_sub if data.trades.duracao_meses[i] > max_d; init=0.0)
            @constraint(sp, c[sub, max_d].out == delta_fin_max)
        end

        # Resultado legado (determinístico)
        R_leg = sum(
            (get(mercado.preco_venda_exist, (mes,sub), 0.0) * get(mercado.vol_venda_exist, (mes,sub), 0.0) -
             get(mercado.preco_compra_exist,(mes,sub), 0.0) * get(mercado.vol_compra_exist,(mes,sub), 0.0)) * (h / ESCALA)
            for sub in subs; init=0.0)

        # Equação de caixa: coeficientes estocásticos zerados aqui, atualizados no parameterize
        # x_{t+1} = x_t + R_leg + receita_contratos*h/E + exposição_spot*h/E + slack
        # (slack garante recurso completo relativo conforme .tex)
        cash_con = @constraint(sp,
            caixa.out - caixa.in - slack_credito == R_leg)

        for sub in subs
            JuMP.set_normalized_coefficient(cash_con, v[sub, 1].in, 0.0)
            JuMP.set_normalized_coefficient(cash_con, c[sub, 1].in, 0.0)
            for i in filter(i -> data.trades.submercado[i] == sub, trades_no)
                JuMP.set_normalized_coefficient(cash_con, q_B[i], 0.0)
                JuMP.set_normalized_coefficient(cash_con, q_S[i], 0.0)
            end
        end

        # Objetivo do estágio: caixa no último estágio, penalidade pelo slack em todos
        if t == config.num_meses
            SDDP.@stageobjective(sp, caixa.out - M_penalty * slack_credito)
        else
            SDDP.@stageobjective(sp, -M_penalty * slack_credito)
        end

        # Cenários
        cenarios_df  = filter(r -> r.data == mes, data.cenarios)
        geracao_df   = filter(r -> r.data == mes, data.geracao)
        sub_por_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))

        noises = SDDPNoise[]
        for c_id in unique(cenarios_df.cenario)
            pld_c = Dict{String,Float64}()
            ger_c = Dict{String,Float64}()
            for sub in subs
                row_pld = filter(r -> r.cenario == c_id && r.submercado == sub, cenarios_df)
                pld_c[sub] = isempty(row_pld) ? 0.0 : row_pld.valor[1]
                rows_ger   = filter(r -> r.cenario == c_id, geracao_df)
                ger_c[sub] = sum(r.geracao_mwm for r in eachrow(rows_ger)
                                 if get(sub_por_usina, r.usina_cod, "") == sub; init=0.0)
            end
            push!(noises, SDDPNoise(pld_c, ger_c))
        end

        SDDP.parameterize(sp, noises) do omega
            new_rhs = R_leg
            for sub in subs
                pld          = omega.pld[sub]
                ger          = omega.geracao[sub]
                compra_exist = get(mercado.vol_compra_exist, (mes,sub), 0.0)
                venda_exist  = get(mercado.vol_venda_exist,  (mes,sub), 0.0)
                scale_pld    = pld * h / ESCALA
                scale_det    = h / ESCALA

                JuMP.set_normalized_coefficient(cash_con, v[sub, 1].in, scale_pld)
                JuMP.set_normalized_coefficient(cash_con, c[sub, 1].in, scale_det)

                trades_sub = filter(i -> data.trades.submercado[i] == sub, trades_no)
                for i in trades_sub
                    JuMP.set_normalized_coefficient(cash_con, q_B[i], -data.trades.preco_compra[i] * scale_det + scale_pld)
                    JuMP.set_normalized_coefficient(cash_con, q_S[i],  data.trades.preco_venda[i]  * scale_det - scale_pld)
                end

                new_rhs += (ger + compra_exist - venda_exist) * scale_pld
            end
            JuMP.set_normalized_rhs(cash_con, new_rhs)
        end
    end

    return model
end

function main_sddp()
    println("\n" * "="^60)
    println("🎯 SDDP MULTIESTÁGIO — TREINAMENTO")
    println("="^60)

    config  = load_deq_config()
    data    = load_market_data(config)
    mercado = preprocess_market(data, config)
    max_d   = maximum(data.trades.duracao_meses)
    ESCALA  = config.escala

    model = build_sddp_model(config, data, mercado, max_d)

    println("\n🚀 Iniciando treinamento SDDP...")
    # EAVaR(λ_e, α) = λ_e·E[x] + (1-λ_e)·AVaR_α(x)
    # Para maximizar E[x] + λ·CVaR (mesmo que o DEQ), usamos λ_e = 1/(1+λ)
    # pois: λ_e·E + (1-λ_e)·CVaR = [E + λ·CVaR] / (1+λ)  → mesmo ótimo
    lambda_eavar = 1.0 / (1.0 + config.lambda)
    SDDP.train(model,
        iteration_limit = 2000,
        stopping_rules  = [SDDP.BoundStalling(100, 1e-6)],
        print_level     = 1,
        risk_measure    = SDDP.EAVaR(lambda = lambda_eavar, beta = config.alpha)
    )

    bound = SDDP.calculate_bound(model)
    println("\n✅ Treinamento Concluído!")
    println("   Upper Bound (Z) : R\$ $(round(bound * ESCALA / 1e6, digits=3)) Mi")

    # Simulação para estimar o valor real da política
    trade_ids = 1:mercado.num_trades
    sim_syms  = vcat([:caixa],
                     [Symbol("qB_", i) for i in trade_ids],
                     [Symbol("qS_", i) for i in trade_ids])

    sims = SDDP.simulate(model, 1000, sim_syms; skip_undefined_variables = true)

    saldos_finais = [sim[end][:caixa].out for sim in sims]
    println("   E[Saldo Final] (1000 simulações) : R\$ $(round(mean(saldos_finais) * ESCALA / 1e6, digits=3)) Mi")

    # Decisões do mês 1 (consistentes em todas as simulações)
    println("\nTrades executados no mês 1 (decisão única, pré-cenário):")
    trades_mes1 = [i for i in trade_ids if data.trades.data[i] == mercado.meses[1]]
    for i in trades_mes1
        qb = get(sims[1][1], Symbol("qB_", i), 0.0)
        qs = get(sims[1][1], Symbol("qS_", i), 0.0)
        if qb > 0.01 || qs > 0.01
            println("  $(data.trades.ticker[i]): compra=$(round(qb, digits=2)) MWm  venda=$(round(qs, digits=2)) MWm")
        end
    end

    # Exporta decisões
    rows = NamedTuple{(:simulacao, :estagio, :mes, :ticker, :compra_mwm, :venda_mwm, :saldo_mi),
                      Tuple{Int,Int,Date,String,Float64,Float64,Float64}}[]
    for (s_idx, sim) in enumerate(sims)
        for (t_idx, stage) in enumerate(sim)
            mes   = mercado.meses[t_idx]
            saldo = stage[:caixa].out * ESCALA / 1e6
            for i in trade_ids
                data.trades.data[i] == mes || continue
                qb = get(stage, Symbol("qB_", i), nothing)
                qs = get(stage, Symbol("qS_", i), nothing)
                qb === nothing && continue
                push!(rows, (s_idx, t_idx, mes, data.trades.ticker[i],
                             round(qb, digits=4), round(qs, digits=4), round(saldo, digits=3)))
            end
        end
    end
    out_path = joinpath(config.data_dir, "..", "results", "sddp_decisoes.csv")
    mkpath(dirname(out_path))
    CSV.write(out_path, DataFrame(rows))
    println("   Decisões exportadas: $out_path")
end

main_sddp()
