using SDDP, JuMP
include("deq.jl")

# ==========================================================
# ESTRUTURA PARA A INCERTEZA DO MÊS
# ==========================================================
struct SDDPNoise
    pld::Dict{String, Float64}
    geracao::Dict{String, Float64}
end

function build_sddp_model(config::DEQConfig, data::MarketData, mercado::DadosMercado, max_d::Int)

    println("Construindo o Policy Graph do SDDP...")

    # Penalidade para violação do limite de crédito.
    # Deve dominar a escala do objetivo (caixa em R$ Mi) para que o slack
    # nunca seja ativado na solução ótima quando o DEQ é viável.
    M_penalty = 1e6

    model = SDDP.PolicyGraph(
        SDDP.LinearGraph(config.num_meses),
        sense = :Max,
        lower_bound = -1e12,
        optimizer = HiGHS.Optimizer,
        upper_bound = 1e6
    ) do sp, t

        mes  = mercado.meses[t]
        h    = horas_mes(mes)
        subs = mercado.submercados

        trades_no = [i for i in 1:mercado.num_trades if data.trades.data[i] == mes]

        # ----------------------------------------------------------
        # 1. VARIÁVEIS DE ESTADO
        # caixa NÃO possui lower bound aqui. O limite de crédito é
        # imposto via penalidade (slack_credito), garantindo recurso
        # completo relativo para toda realização de incerteza.
        # ----------------------------------------------------------
        @variable(sp, caixa, SDDP.State, initial_value = config.caixa_inicial / config.escala)
        @variable(sp, v[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)
        @variable(sp, c[sub in subs, k in 1:max_d], SDDP.State, initial_value = 0.0)

        # Slack para violação do limite de crédito (linha de crédito emergencial).
        # slack_credito >= 0 torna o subproblema sempre viável.
        @variable(sp, slack_credito >= 0)

        # ----------------------------------------------------------
        # 2. VARIÁVEIS DE DECISÃO
        # ----------------------------------------------------------
        @variable(sp, 0 <= q_B[i in trades_no] <= data.trades.limite_compra[i])
        @variable(sp, 0 <= q_S[i in trades_no] <= data.trades.limite_venda[i])

        # ----------------------------------------------------------
        # 3. TRANSIÇÃO DA ESTEIRA
        # ----------------------------------------------------------
        for sub in subs
            trades_sub = filter(i -> data.trades.submercado[i] == sub, trades_no)

            for k in 1:(max_d - 1)
                delta_vol = isempty(trades_sub) ? 0.0 : sum(q_B[i] - q_S[i] for i in trades_sub if data.trades.duracao_meses[i] > k; init=0.0)
                @constraint(sp, v[sub, k].out == v[sub, k+1].in + delta_vol)

                delta_fin = isempty(trades_sub) ? 0.0 : sum(q_S[i]*data.trades.preco_venda[i] - q_B[i]*data.trades.preco_compra[i] for i in trades_sub if data.trades.duracao_meses[i] > k; init=0.0)
                @constraint(sp, c[sub, k].out == c[sub, k+1].in + delta_fin)
            end

            delta_vol_max = isempty(trades_sub) ? 0.0 : sum(q_B[i] - q_S[i] for i in trades_sub if data.trades.duracao_meses[i] > max_d; init=0.0)
            @constraint(sp, v[sub, max_d].out == delta_vol_max)

            delta_fin_max = isempty(trades_sub) ? 0.0 : sum(q_S[i]*data.trades.preco_venda[i] - q_B[i]*data.trades.preco_compra[i] for i in trades_sub if data.trades.duracao_meses[i] > max_d; init=0.0)
            @constraint(sp, c[sub, max_d].out == delta_fin_max)
        end

        # ----------------------------------------------------------
        # 4. INCERTEZA E TRANSIÇÃO DE CAIXA
        # ----------------------------------------------------------
        lucro_legado = sum(
            (get(mercado.preco_venda_exist, (mes,sub), 0.0) * get(mercado.vol_venda_exist, (mes,sub), 0.0) -
             get(mercado.preco_compra_exist, (mes,sub), 0.0) * get(mercado.vol_compra_exist, (mes,sub), 0.0)) * (h / config.escala)
            for sub in subs; init=0.0
        )
        receita_novos   = isempty(trades_no) ? 0.0 : sum(q_S[i]*data.trades.preco_venda[i] - q_B[i]*data.trades.preco_compra[i] for i in trades_no; init=0.0)
        receita_herdada = sum(c[sub, 1].in for sub in subs; init=0.0)

        cenarios_df  = filter(r -> r.data == mes, data.cenarios)
        geracao_df   = filter(r -> r.data == mes, data.geracao)
        cenarios_ids = unique(cenarios_df.cenario)

        noises = SDDPNoise[]
        for c_id in cenarios_ids
            pld_c = Dict{String, Float64}()
            ger_c = Dict{String, Float64}()
            for sub in subs
                row_pld = filter(r -> r.cenario == c_id && r.submercado == sub, cenarios_df)
                pld_c[sub] = isempty(row_pld) ? 0.0 : row_pld.valor[1]

                rows_ger      = filter(r -> r.cenario == c_id, geracao_df)
                sub_por_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))
                ger_c[sub]    = sum(r.geracao_mwm for r in eachrow(rows_ger) if get(sub_por_usina, r.usina_cod, "") == sub; init=0.0)
            end
            push!(noises, SDDPNoise(pld_c, ger_c))
        end

        SDDP.parameterize(sp, noises) do omega
            exposicao_spot = AffExpr(0.0)

            for sub in subs
                compra_exist = get(mercado.vol_compra_exist, (mes,sub), 0.0)
                venda_exist  = get(mercado.vol_venda_exist,  (mes,sub), 0.0)

                trades_sub  = filter(i -> data.trades.submercado[i] == sub, trades_no)
                compra_nova = isempty(trades_sub) ? 0.0 : sum(q_B[i] for i in trades_sub; init=0.0)
                venda_nova  = isempty(trades_sub) ? 0.0 : sum(q_S[i] for i in trades_sub; init=0.0)

                exposicao_sub = omega.geracao[sub] + compra_exist + compra_nova - venda_exist - venda_nova + v[sub, 1].in
                add_to_expression!(exposicao_spot, exposicao_sub * omega.pld[sub] * (h / config.escala))
            end

            # Transição de caixa: slack absorve qualquer violação do limite de crédito.
            # caixa.out = caixa.in + fluxos + slack_credito
            # O limite x >= L^cred é imposto pela penalidade, não por um bound rígido no estado.
            @constraint(sp,
                caixa.out == caixa.in + lucro_legado +
                             (receita_novos + receita_herdada) * (h / config.escala) +
                             exposicao_spot + slack_credito
            )

            # Objetivo do estágio: penaliza uso do slack em todos os estágios.
            # Quando slack_credito = 0 (política viável), o objetivo coincide com o DEQ.
            if t == config.num_meses
                SDDP.@stageobjective(sp, caixa.out - M_penalty * slack_credito)
            else
                SDDP.@stageobjective(sp, -M_penalty * slack_credito)
            end
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

    model = build_sddp_model(config, data, mercado, max_d)

    println("\n🚀 Iniciando o Forward/Backward Pass (Benders Decomposition)...")
    SDDP.train(model, iteration_limit = 10, print_level = 1, risk_measure = SDDP.EAVaR(lambda = config.lambda, beta = config.alpha))

    bound_otimo = SDDP.calculate_bound(model)
    println("\n✅ Treinamento Concluído!")
    println("   Valor Ótimo (Z) Convergido : R\$ $(round(bound_otimo, digits=3)) Mi")
end

main_sddp()
