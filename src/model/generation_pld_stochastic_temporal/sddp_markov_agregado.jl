include("sddp_common.jl")

# =============================================================================
# DIFERENÇA vs sddp_markoviano.jl
#
# sddp_markoviano.jl:
#   - 1 estado Markov = 1 cenário completo  →  informação perfeita (onisciente)
#   - matriz de transição = identidade       →  cada cenário segue a si mesmo
#   - sem parameterize                       →  ω fixo por nó
#
# sddp_markov_agregado.jl:
#   - 1 estado Markov = 1 nível de PLD (baixo/médio/alto)
#   - matriz de transição P[3×3] estimada das trajetórias históricas
#   - SDDP.parameterize por estado           →  incerteza residual dentro do estado
#   - resultado: dependência temporal SEM revelar o futuro completo
# =============================================================================

const N_ESTADOS = 3   # 1=baixo, 2=médio, 3=alto

function load_sddp_config()
    return SDDPConfig(
        joinpath(@__DIR__, "..", "..", "..", "data", "processed"),
        60,      # Meses do horizonte
        2000,    # Cenários usados para estimar P e ruídos
        42,      # Seed para reprodutibilidade
        0.95,    # Alpha do CVaR
        0.01,    # Lambda (peso do risco)
        200,     # Iterações do SDDP (mais iterações pois o grafo é menor)
        2000     # Simulações
    )
end

# -----------------------------------------------------------------------------
# Discretiza um valor de PLD em estado {1, 2, 3} usando quantis globais.
# q33 e q66 são os quantis de 33% e 66% calculados sobre todos os PLDs.
# -----------------------------------------------------------------------------
function estado_pld(pld::Float64, q33::Float64, q66::Float64)::Int
    pld <= q33 && return 1
    pld <= q66 && return 2
    return 3
end

# -----------------------------------------------------------------------------
# Constrói a sequência de estados por cenário×mês usando o PLD médio entre
# submercados como proxy escalar para discretização.
#
# Retorna:
#   estados_por_cenario[cenario][t] ::Int  (1, 2 ou 3)
#   q33, q66                        ::Float64
# -----------------------------------------------------------------------------
function build_estados(
    meses::Vector{Date},
    submercados::Vector{String},
    cenarios_selecionados::Vector{Int},
    idx_pld::Dict
)
    # Quantis POR MÊS: garante ~33% dos cenários em cada estado em todo mês
    # Evita fallbacks causados por sazonalidade do PLD
    q33_por_mes = Vector{Float64}(undef, length(meses))
    q66_por_mes = Vector{Float64}(undef, length(meses))
    degenerado   = Vector{Bool}(undef, length(meses))   # true = mês sem variabilidade

    for (t, mes) in enumerate(meses)
        plds_mes = [mean(get(idx_pld, (mes, c, sub), 0.0) for sub in submercados)
                    for c in cenarios_selecionados]
        q33_por_mes[t] = quantile(plds_mes, 1/3)
        q66_por_mes[t] = quantile(plds_mes, 2/3)
        degenerado[t]  = abs(q66_por_mes[t] - q33_por_mes[t]) < 1e-6
    end

    n_deg = sum(degenerado)
    if n_deg > 0
        println("   ⚠️  $n_deg mês(es) degenerado(s) detectado(s) — PLD sem variabilidade, todos os cenários → estado 1")
    end
    println("   📊 Quantis PLD por mês — q33 médio: $(round(mean(q33_por_mes), digits=1)) | q66 médio: $(round(mean(q66_por_mes), digits=1))")

    estados_por_cenario = Dict{Int, Vector{Int}}()
    for c in cenarios_selecionados
        estados_por_cenario[c] = [
            # Mês degenerado: colapsa para estado 1 (sem incerteza naquele estágio)
            degenerado[t] ? 1 :
            estado_pld(
                mean(get(idx_pld, (mes, c, sub), 0.0) for sub in submercados),
                q33_por_mes[t], q66_por_mes[t]
            )
            for (t, mes) in enumerate(meses)
        ]
    end

    return estados_por_cenario, q33_por_mes, q66_por_mes
end

# -----------------------------------------------------------------------------
# Estima a matriz de transição P[N_ESTADOS × N_ESTADOS] contando transições
# estado_t → estado_{t+1} em todas as trajetórias e normalizando por linha.
#
# Fallback: linha sem observações recebe distribuição uniforme.
# -----------------------------------------------------------------------------
function build_transition_matrix(
    estados_por_cenario::Dict{Int, Vector{Int}},
    cenarios_selecionados::Vector{Int},
    num_meses::Int
)::Matrix{Float64}
    contagens = zeros(Int, N_ESTADOS, N_ESTADOS)

    for c in cenarios_selecionados
        seq = estados_por_cenario[c]
        for t in 1:(num_meses - 1)
            contagens[seq[t], seq[t+1]] += 1
        end
    end

    P = zeros(Float64, N_ESTADOS, N_ESTADOS)
    for i in 1:N_ESTADOS
        total = sum(contagens[i, :])
        if total == 0
            P[i, :] .= 1.0 / N_ESTADOS   # fallback uniforme
        else
            P[i, :] = contagens[i, :] / total
        end
    end

    println("   🔀 Matriz de transição estimada:")
    for i in 1:N_ESTADOS
        label = ["baixo", "médio", "alto"][i]
        println("      $label → $(round.(P[i,:], digits=3))")
    end

    return P
end

# -----------------------------------------------------------------------------
# Constrói ruidos_por_estado[t][estado] = vetor de NamedTuples (pld, geracao).
#
# Cada ω representa um cenário histórico que pertence àquele estado naquele mês.
# O SDDP.parameterize sorteia um ω desse vetor a cada iteração, introduzindo
# incerteza residual dentro do estado — sem revelar o cenário completo.
#
# Fallback: se nenhum cenário cai num estado num dado mês, usa os cenários
# do estado mais próximo para evitar vetor vazio.
# -----------------------------------------------------------------------------
function build_ruidos_por_estado(
    meses::Vector{Date},
    submercados::Vector{String},
    cenarios_selecionados::Vector{Int},
    estados_por_cenario::Dict{Int, Vector{Int}},
    idx_pld::Dict,
    idx_geracao::Dict
)::Vector{Vector{Vector{NamedTuple}}}

    T = length(meses)

    # ruidos[t][estado] = vetor de ω
    ruidos = [[NamedTuple[] for _ in 1:N_ESTADOS] for _ in 1:T]

    for (t, mes) in enumerate(meses)
        for c in cenarios_selecionados
            estado = estados_por_cenario[c][t]
            ω = (
                pld     = Dict{String,Float64}(sub => get(idx_pld,    (mes, c, sub), 0.0) for sub in submercados),
                geracao = Dict{String,Float64}(sub => get(idx_geracao, (mes, c, sub), 0.0) for sub in submercados)
            )
            push!(ruidos[t][estado], ω)
        end

        # Mês degenerado: só estado 1 tem cenários — correto por construção
        # Mês normal: todos os 3 estados devem ter cenários (quantis por mês garantem isso)
        estados_presentes = [e for e in 1:N_ESTADOS if !isempty(ruidos[t][e])]
        @assert !isempty(estados_presentes) "Bug: nenhum estado tem cenários no mês $t"
        if length(estados_presentes) < N_ESTADOS
            ausentes = [e for e in 1:N_ESTADOS if isempty(ruidos[t][e])]
            # Estados ausentes só são aceitáveis em mês degenerado (todos no estado 1)
            @assert all(==(1), estados_presentes) || length(estados_presentes) == N_ESTADOS \
                "Bug inesperado: estados $ausentes vazios no mês $t (não é mês degenerado)"
        end
    end

    # Log de distribuição
    println("   🎲 Ruídos por estado (média de cenários/mês):")
    for estado in 1:N_ESTADOS
        media = mean(length(ruidos[t][estado]) for t in 1:T)
        println("      estado $estado: $(round(media, digits=1)) cenários/mês")
    end

    return ruidos
end

# =============================================================================
# preprocess_data — monta dados_por_mes com ruidos_por_estado embutidos,
# além de retornar P e a distribuição inicial dos estados.
# =============================================================================
function preprocess_data(config::SDDPConfig, data::MarketData)
    meses, submercados, cenarios_selecionados, contratos_filtrado, trades_filtrado, idx_pld, idx_geracao =
        _preprocess_base(config, data)

    println("   🔄 Construindo estados Markovianos agregados...")

    # 1. Discretiza trajetórias em sequências de estados
    estados_por_cenario, q33_por_mes, q66_por_mes = build_estados(meses, submercados, cenarios_selecionados, idx_pld)

    # 2. Estima matriz de transição P[3×3]
    P = build_transition_matrix(estados_por_cenario, cenarios_selecionados, length(meses))

    # 3. Distribuição inicial: frequência dos estados no primeiro mês
    contagem_inicial = zeros(Int, N_ESTADOS)
    for c in cenarios_selecionados
        contagem_inicial[estados_por_cenario[c][1]] += 1
    end
    root_probs = contagem_inicial / sum(contagem_inicial)
    println("   🌱 Distribuição inicial: $(round.(root_probs, digits=3))")

    # 4. Ruídos por estado por mês
    println("   🔄 Montando ruidos_por_estado...")
    ruidos = build_ruidos_por_estado(
        meses, submercados, cenarios_selecionados,
        estados_por_cenario, idx_pld, idx_geracao
    )

    # 5. dados_por_mes — idêntico ao markoviano, mas com ruidos_por_estado
    println("   🔄 Montando dados_por_mes...")
    dados_por_mes = Dict{Int, NamedTuple}()

    for (t, mes) in enumerate(meses)
        print("\r   Mês $t/$(length(meses)): $mes")
        flush(stdout)

        contratos_mes = filter(r -> r.data == mes, contratos_filtrado)
        vol_compra_exist, vol_venda_exist, preco_compra_exist, preco_venda_exist =
            _contratos_por_submercado(submercados, contratos_mes)

        trades_mes = filter(r -> r.data == mes, trades_filtrado)
        dados_por_mes[t] = (
            mes                = mes,
            submercados        = submercados,
            vol_compra_exist   = vol_compra_exist,
            vol_venda_exist    = vol_venda_exist,
            preco_compra_exist = preco_compra_exist,
            preco_venda_exist  = preco_venda_exist,
            trades             = trades_mes,
            trades_por_sub     = _trades_por_sub(submercados, trades_mes),
            ruidos_por_estado  = ruidos[t],
            horas              = horas_mes(mes)
        )
    end

    println("\n   ✓ Pré-processamento concluído")
    return meses, submercados, dados_por_mes, P, root_probs
end

# =============================================================================
# build_sddp_model
#
# DIFERENÇAS vs sddp_markoviano.jl:
#   1. MarkovianGraph usa P estimada (não identidade)
#   2. root_node_transition vem da distribuição empírica dos estados no mês 1
#   3. Dentro do nó: estado = markov_state (1/2/3), sem lookup de cenário
#   4. SDDP.parameterize sorteia ω de ruidos_por_estado[t][estado]
#   5. Toda a lógica econômica (variáveis, restrições, objetivo) é idêntica
# =============================================================================
function build_sddp_model(meses, dados_por_mes, P::Matrix{Float64}, root_probs::Vector{Float64})
    println("   🔨 Construindo grafo Markov agregado ($(N_ESTADOS) estados)...")
    flush(stdout)

    ESCALA                = 1e6
    limite_credito_escala = -100.0
    total_nos             = length(meses) * N_ESTADOS

    # DIFERENÇA 1: P[3×3] estimada das trajetórias — não é mais identidade
    graph = SDDP.MarkovianGraph(
        stages               = length(meses),
        transition_matrix    = P,
        root_node_transition = root_probs
    )

    model = SDDP.PolicyGraph(
        graph;
        sense       = :Max,
        upper_bound = 1e6,
        optimizer   = HiGHS.Optimizer
    ) do sp, node
        t, estado = node   # DIFERENÇA 2: estado ∈ {1,2,3}, não é índice de cenário

        dados = dados_por_mes[t]

        no_atual = (t - 1) * N_ESTADOS + estado
        if no_atual % 50 == 0 || no_atual == total_nos
            print("\r   Construindo nós: $no_atual/$total_nos")
            flush(stdout)
        end

        # ── Variáveis de estado ────────────────────────────────────────────
        @variable(sp, caixa, SDDP.State, initial_value=0.0)
        @variable(sp, vol_futuro[dados.submercados, 1:5], SDDP.State, initial_value=0.0)
        @variable(sp, custo_futuro[1:5], SDDP.State, initial_value=0.0)

        # ── Variáveis de decisão ───────────────────────────────────────────
        num_trades = nrow(dados.trades)
        if num_trades > 0
            @variable(sp, 0 <= volume_compra[i=1:num_trades] <= dados.trades.limite_compra[i])
            @variable(sp, 0 <= volume_venda[i=1:num_trades]  <= dados.trades.limite_venda[i])
        else
            @variable(sp, volume_compra[1:0])
            @variable(sp, volume_venda[1:0])
        end

        # ── Pipeline temporal de contratos forward ─────────────────────────
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

        # ── Lucro determinístico dos contratos legados ─────────────────────
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

        # ── Lucro spot (coeficientes injetados no parameterize) ────────────
        @variable(sp, spot_profit[dados.submercados])

        @constraint(sp, transicao_caixa,
            caixa.out == caixa.in + fluxo_contratos + sum(spot_profit[sub] for sub in dados.submercados))

        @variable(sp, 0 <= emprestimo_emergencia)
        @constraint(sp, limite_ruina, caixa.out + emprestimo_emergencia >= limite_credito_escala)

        # Restrições molde — RHS e coeficientes injetados pelo parameterize
        @constraint(sp, spot_profit_eq[sub in dados.submercados], spot_profit[sub] == 0.0)

        # DIFERENÇA 3: parameterize sorteia ω de ruidos_por_estado[estado]
        # O SDDP.jl usa as probabilidades implícitas (uniforme dentro do estado)
        # A dependência temporal vem da matriz P, não da trajetória fixa
        SDDP.parameterize(sp, dados.ruidos_por_estado[estado]) do ω
            for sub in dados.submercados
                pld_horas = (ω.pld[sub] * dados.horas) / ESCALA

                exposicao_base = ω.geracao[sub] + dados.vol_compra_exist[sub] - dados.vol_venda_exist[sub]
                JuMP.set_normalized_rhs(spot_profit_eq[sub], exposicao_base * pld_horas)

                trades_sub = dados.trades_por_sub[sub]
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
    end

    println("\n   ✓ Grafo construído")
    return model
end

function main()
    println("\n" * "="^60)
    println("🎯 OTIMIZAÇÃO MULTI-ESTÁGIO COM SDDP.jl — MARKOV AGREGADO")
    println("   (estados: baixo / médio / alto PLD)")
    println("="^60)

    tempo_inicio = time()

    config = load_sddp_config()
    data   = load_market_data(config)

    meses, submercados, dados_por_mes, P, root_probs = preprocess_data(config, data)

    risk_measure = (1 - config.lambda) * SDDP.Expectation() + config.lambda * SDDP.AVaR(config.alpha)

    model = build_sddp_model(meses, dados_por_mes, P, root_probs)
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
