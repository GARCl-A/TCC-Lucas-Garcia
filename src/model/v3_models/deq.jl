using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf, Random

# =============================================================================
# CONFIGURAÇÃO E DADOS
# =============================================================================

struct DEQConfig
    data_dir::String
    alpha::Float64
    lambda::Float64
    num_meses::Int
    num_ramos::Int   # ramificações por nó (controla tamanho da árvore)
    seed::Int
    caixa_inicial::Float64
    limite_credito::Float64
    ESCALA::Float64
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    contratos_existentes::DataFrame
    trades::DataFrame
end

function load_deq_config()
    return DEQConfig(
        joinpath(@__DIR__, "..", "..", "..", "data", "processed"),
        0.95,    # alpha CVaR
        0.01,    # lambda (peso do risco)
        60,       # meses (pequeno para teste — evita maldição da dimensionalidade)
        2000,       # ramos por nó
        42,      # seed
        0.0,     # caixa inicial
        -100.0,  # limite de crédito (em unidades ESCALA = R$ Mi)
        1e6      # escala: trabalha em R$ milhões
    )
end

function load_market_data(config::DEQConfig)::MarketData
    println("🔥 Carregando dados...")
    d = config.data_dir
    cenarios            = CSV.read(joinpath(d, "cenarios_final.csv"),    DataFrame)
    geracao             = CSV.read(joinpath(d, "geracao_estocastica.csv"), DataFrame)
    contratos_existentes = CSV.read(joinpath(d, "contratos_legacy.csv"), DataFrame)
    trades              = CSV.read(joinpath(d, "trades.csv"),             DataFrame)
    for df in (cenarios, geracao, contratos_existentes, trades)
        df.data = Date.(df.data)
    end
    return MarketData(cenarios, geracao, contratos_existentes, trades)
end

horas_mes(d::Date) = Float64(daysinmonth(d) * 24)

# =============================================================================
# ÁRVORE DE CENÁRIOS
# =============================================================================

struct ArvoreCenarios
    nos::Vector{Int}
    folhas::Vector{Int}
    no_pai::Dict{Int,Int}
    mes_do_no::Dict{Int,Date}
    prob_no::Dict{Int,Float64}
    pld_no::Dict{Tuple{Int,String},Float64}
    producao_no::Dict{Tuple{Int,String},Float64}   # (nó, submercado) → MWm agregado
end

"""
Constrói uma árvore de cenários mock a partir dos dados reais.
Estrutura: raiz (nó 1) → T estágios, R ramos por nó.
Total de nós = 1 + R + R² + ... + R^T  (árvore completa)
"""
function build_scenario_tree(data::MarketData, config::DEQConfig)::ArvoreCenarios
    println("🌳 Construindo árvore de cenários ($(config.num_meses) meses, $(config.num_ramos) ramos)...")
    Random.seed!(config.seed)

    T = config.num_meses
    R = config.num_ramos

    # Pré-processa dados de mercado
    todos_meses  = sort(unique(data.cenarios.data))[1:T]
    submercados  = String.(unique(data.cenarios.submercado))
    num_cenarios = maximum(data.cenarios.cenario)

    # Índices rápidos
    idx_pld = Dict((r.data, r.cenario, r.submercado) => r.valor for r in eachrow(data.cenarios))

    # Geração agregada por (data, cenario, submercado)
    sub_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))
    ger_agg   = combine(
        groupby(
            transform(data.geracao, :usina_cod => ByRow(u -> get(sub_usina, u, "")) => :submercado),
            [:data, :cenario, :submercado]
        ),
        :geracao_mwm => sum => :geracao_total
    )
    idx_ger = Dict((r.data, r.cenario, r.submercado) => r.geracao_total for r in eachrow(ger_agg))

    # Estimativa do total de nós para o progresso
    nos_por_estagio = [R^t for t in 1:T]
    total_nos_estimado = 1 + sum(nos_por_estagio)
    println("   📐 Estimativa: $total_nos_estimado nós totais, $(nos_por_estagio[end]) folhas")

    # Amostra R cenários por estágio (com reposição entre ramos)
    cenarios_por_estagio = [sort(randperm(num_cenarios)[1:R]) for _ in 1:T]

    # Constrói a árvore nó a nó (BFS)
    nos       = Int[]
    folhas    = Int[]
    no_pai    = Dict{Int,Int}()
    mes_do_no = Dict{Int,Date}()
    prob_no   = Dict{Int,Float64}()
    pld_no    = Dict{Tuple{Int,String},Float64}()
    prod_no   = Dict{Tuple{Int,String},Float64}()

    # Raiz (estágio 1)
    id = 1
    push!(nos, id)
    no_pai[id]    = 0
    mes_do_no[id] = todos_meses[1]
    prob_no[id]   = 1.0   # prob incondicional do primeiro ramo
    c1 = cenarios_por_estagio[1][1]
    for sub in submercados
        pld_no[(id, sub)]  = get(idx_pld, (todos_meses[1], c1, sub), 0.0)
        prod_no[(id, sub)] = get(idx_ger, (todos_meses[1], c1, sub), 0.0)
    end

    # Expande estágio a estágio
    nos_estagio_anterior = [id]
    id += 1
    t0_arvore = time()

    for t in 1:T
        mes = todos_meses[t]
        nos_estagio_atual = Int[]
        cenarios_t = cenarios_por_estagio[t]
        t_estagio = time()

        for (r_idx, pai) in enumerate(nos_estagio_anterior)
            for r in 1:R
                c = cenarios_t[r]
                push!(nos, id)
                push!(nos_estagio_atual, id)
                no_pai[id]    = pai
                mes_do_no[id] = mes
                prob_no[id]   = prob_no[pai] / R
                for sub in submercados
                    pld_no[(id, sub)]  = get(idx_pld, (mes, c, sub), 0.0)
                    prod_no[(id, sub)] = get(idx_ger, (mes, c, sub), 0.0)
                end
                if t == T
                    push!(folhas, id)
                end
                id += 1
            end
        end
        nos_estagio_anterior = nos_estagio_atual
        elapsed = round(time() - t0_arvore, digits=1)
        println("   Estágio $t/$T ($(Dates.format(mes, "yyyy-mm"))): $(length(nos_estagio_atual)) nós criados | total=$(length(nos)) | $(elapsed)s")
        flush(stdout)
    end

    arvore = ArvoreCenarios(nos, folhas, no_pai, mes_do_no, prob_no, pld_no, prod_no)
    println("   ✓ Árvore: $(length(nos)) nós, $(length(folhas)) folhas")
    return arvore
end

# =============================================================================
# PRÉ-PROCESSAMENTO DE CONTRATOS E TRADES
# =============================================================================

struct DadosMercado
    submercados::Vector{String}
    meses::Vector{Date}
    vol_compra_exist::Dict{Tuple{Date,String},Float64}
    vol_venda_exist::Dict{Tuple{Date,String},Float64}
    preco_compra_exist::Dict{Tuple{Date,String},Float64}
    preco_venda_exist::Dict{Tuple{Date,String},Float64}
    trades_por_mes_sub::Dict{Tuple{Date,String},Vector{Int}}
    num_trades::Int
end

function preprocess_market(data::MarketData, config::DEQConfig)::DadosMercado
    todos_meses = sort(unique(data.cenarios.data))[1:config.num_meses]
    submercados = String.(unique(data.cenarios.submercado))

    vol_compra_exist   = Dict{Tuple{Date,String},Float64}()
    vol_venda_exist    = Dict{Tuple{Date,String},Float64}()
    preco_compra_exist = Dict{Tuple{Date,String},Float64}()
    preco_venda_exist  = Dict{Tuple{Date,String},Float64}()

    for mes in todos_meses, sub in submercados
        contratos_ms = filter(r -> r.data == mes && r.submercado == sub, data.contratos_existentes)
        compras = filter(r -> r.tipo == "COMPRA", contratos_ms)
        vendas  = filter(r -> r.tipo == "VENDA",  contratos_ms)

        if nrow(compras) > 0
            vol_compra_exist[(mes,sub)]   = sum(compras.volume_mwm)
            preco_compra_exist[(mes,sub)] = sum(compras.volume_mwm .* compras.preco_r_mwh) / sum(compras.volume_mwm)
        else
            vol_compra_exist[(mes,sub)]   = 0.0
            preco_compra_exist[(mes,sub)] = 0.0
        end

        if nrow(vendas) > 0
            vol_venda_exist[(mes,sub)]   = sum(vendas.volume_mwm)
            preco_venda_exist[(mes,sub)] = sum(vendas.volume_mwm .* vendas.preco_r_mwh) / sum(vendas.volume_mwm)
        else
            vol_venda_exist[(mes,sub)]   = 0.0
            preco_venda_exist[(mes,sub)] = 0.0
        end
    end

    trades_filtrados = filter(r -> r.data in Set(todos_meses), data.trades)
    trades_por_mes_sub = Dict{Tuple{Date,String},Vector{Int}}()
    for mes in todos_meses, sub in submercados
        trades_por_mes_sub[(mes,sub)] = findall(
            i -> trades_filtrados.data[i] == mes && trades_filtrados.submercado[i] == sub,
            1:nrow(trades_filtrados)
        )
    end

    return DadosMercado(
        submercados, todos_meses,
        vol_compra_exist, vol_venda_exist,
        preco_compra_exist, preco_venda_exist,
        trades_por_mes_sub, nrow(trades_filtrados)
    )
end

# =============================================================================
# MODELO DEQ MULTIESTÁGIO
# =============================================================================

function solve_deq(config::DEQConfig, data::MarketData, arvore::ArvoreCenarios, dm::DadosMercado)
    println("⚙️  Construindo modelo DEQ...")
    trades = filter(r -> r.data in Set(dm.meses), data.trades)
    NT = nrow(trades)
    nos    = arvore.nos
    folhas = arvore.folhas
    subs   = dm.submercados
    ESCALA = config.ESCALA

    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # =========================================================================
    # VARIÁVEIS
    # =========================================================================
    # Trades: só ativos no nó cujo mês coincide com o mês do trade
    @variable(model, volume_compra_trade[t=1:NT, n=nos] >= 0)
    @variable(model, volume_venda_trade[t=1:NT,  n=nos] >= 0)

    # Bounds e restrição de ativação por mês
    for t in 1:NT, n in nos
        set_upper_bound(volume_compra_trade[t,n], trades.limite_compra[t])
        set_upper_bound(volume_venda_trade[t,n],  trades.limite_venda[t])
        # Trade só pode ser executado no nó cujo mês coincide
        if trades.data[t] != arvore.mes_do_no[n]
            fix(volume_compra_trade[t,n], 0.0; force=true)
            fix(volume_venda_trade[t,n],  0.0; force=true)
        end
    end

    @variable(model, caixa[n=nos])
    @variable(model, vol_futuro[sub=subs, k=1:5, n=nos])
    @variable(model, custo_futuro[k=1:5, n=nos])

    # CVaR
    @variable(model, VaR)
    @variable(model, desvio_perda[n=folhas] >= 0)

    # =========================================================================
    # EQUAÇÕES DE TRANSIÇÃO (por nó)
    # =========================================================================
    total_nos = length(nos)
    t0_model  = time()
    for (idx_n, n) in enumerate(nos)
        pai  = arvore.no_pai[n]
        mes  = arvore.mes_do_no[n]
        h    = horas_mes(mes)

        # Trades ativos neste nó
        trades_n = Int[]
        for t in 1:NT
            if trades.data[t] == mes
                push!(trades_n, t)
            end
        end

        # --- Pipeline de Volumes (espelha vol_futuro[sub,k].out do SDDP) ---
        for sub in subs
            # vol_add: compras - vendas dos novos trades deste nó neste submercado
            trades_sub_n = filter(t -> trades.submercado[t] == sub, trades_n)

            for k in 1:4
                vol_add_k = isempty(trades_sub_n) ? AffExpr(0.0) :
                    sum(
                        (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                        for t in trades_sub_n
                        if trades.duracao_meses[t] > k;
                        init = AffExpr(0.0)
                    )
                if pai == 0
                    @constraint(model, vol_futuro[sub,k,n] == vol_add_k)
                else
                    @constraint(model, vol_futuro[sub,k,n] == vol_futuro[sub,k+1,pai] + vol_add_k)
                end
            end

            vol_add_5 = isempty(trades_sub_n) ? AffExpr(0.0) :
                sum(
                    (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                    for t in trades_sub_n
                    if trades.duracao_meses[t] > 5;
                    init = AffExpr(0.0)
                )
            @constraint(model, vol_futuro[sub,5,n] == vol_add_5)
        end

        # --- Pipeline Financeiro (espelha custo_futuro[k].out do SDDP) ---
        for k in 1:4
            custo_add_k = isempty(trades_n) ? AffExpr(0.0) :
                sum(
                    (volume_venda_trade[t,n] * trades.preco_venda[t] -
                     volume_compra_trade[t,n] * trades.preco_compra[t]) * h / ESCALA
                    for t in trades_n
                    if trades.duracao_meses[t] > k;
                    init = AffExpr(0.0)
                )
            if pai == 0
                @constraint(model, custo_futuro[k,n] == custo_add_k)
            else
                @constraint(model, custo_futuro[k,n] == custo_futuro[k+1,pai] + custo_add_k)
            end
        end

        custo_add_5 = isempty(trades_n) ? AffExpr(0.0) :
            sum(
                (volume_venda_trade[t,n] * trades.preco_venda[t] -
                 volume_compra_trade[t,n] * trades.preco_compra[t]) * h / ESCALA
                for t in trades_n
                if trades.duracao_meses[t] > 5;
                init = AffExpr(0.0)
            )
        @constraint(model, custo_futuro[5,n] == custo_add_5)

        # --- Lucro Legado (determinístico) ---
        lucro_legado = sum(
            (get(dm.preco_venda_exist, (mes,sub), 0.0) * get(dm.vol_venda_exist, (mes,sub), 0.0) -
             get(dm.preco_compra_exist,(mes,sub), 0.0) * get(dm.vol_compra_exist,(mes,sub), 0.0)) * h / ESCALA
            for sub in subs
        )

        # --- Receita líquida dos novos trades do nó atual (k=1, duração >= 1) ---
        custo_novos_trades = isempty(trades_n) ? AffExpr(0.0) :
            sum(
                (volume_venda_trade[t,n] * trades.preco_venda[t] -
                 volume_compra_trade[t,n] * trades.preco_compra[t]) * h / ESCALA
                for t in trades_n;
                init = AffExpr(0.0)
            )

        custo_futuro_1_pai = (pai == 0) ? 0.0 : custo_futuro[1,pai]

        # --- Exposição ao Spot por submercado ---
        spot_total = AffExpr(0.0)
        for sub in subs
            pld   = get(arvore.pld_no,    (n, sub), 0.0)
            prod  = get(arvore.producao_no,(n, sub), 0.0)
            compra_exist = get(dm.vol_compra_exist, (mes,sub), 0.0)
            venda_exist  = get(dm.vol_venda_exist,  (mes,sub), 0.0)

            trades_sub_n = filter(t -> trades.submercado[t] == sub, trades_n)
            compra_nova = isempty(trades_sub_n) ? AffExpr(0.0) :
                sum(volume_compra_trade[t,n] for t in trades_sub_n)
            venda_nova  = isempty(trades_sub_n) ? AffExpr(0.0) :
                sum(volume_venda_trade[t,n]  for t in trades_sub_n)

            vol_futuro_1_pai = (pai == 0) ? 0.0 : vol_futuro[sub,1,pai]

            # Exposição = Produção + Compras - Vendas - vol_futuro_1_pai
            exposicao = prod + compra_exist + compra_nova - venda_exist - venda_nova - vol_futuro_1_pai

            add_to_expression!(spot_total, exposicao * pld * h / ESCALA)
        end

        # --- Transição de Caixa ---
        caixa_pai = (pai == 0) ? config.caixa_inicial / ESCALA : caixa[pai]
        @constraint(model,
            caixa[n] == caixa_pai + lucro_legado + custo_novos_trades + custo_futuro_1_pai + spot_total
        )

        # Limite de crédito
        @constraint(model, caixa[n] >= config.limite_credito)

        if idx_n % max(1, div(total_nos, 20)) == 0 || idx_n == total_nos
            pct = round(Int, 100 * idx_n / total_nos)
            print("\r   Constraints: $idx_n/$total_nos ($pct%) | $(round(time()-t0_model, digits=1))s")
            flush(stdout)
        end
    end
    println()

    # =========================================================================
    # FUNÇÃO OBJETIVO E CVaR (apenas sobre folhas)
    # =========================================================================
    @expression(model, SaldoFinalEsperado,
        sum(arvore.prob_no[n] * caixa[n] for n in folhas)
    )

    @constraint(model, restricao_cvar[n=folhas],
        desvio_perda[n] >= VaR - caixa[n]
    )

    @expression(model, CVaR_saldo,
        VaR - (1 / (1 - config.alpha)) * sum(arvore.prob_no[n] * desvio_perda[n] for n in folhas)
    )

    @objective(model, Max, SaldoFinalEsperado + config.lambda * CVaR_saldo)

    # =========================================================================
    # RESOLVE
    # =========================================================================
    println("🚀 Otimizando...")
    t0 = time()
    optimize!(model)
    tempo = time() - t0

    status = termination_status(model)
    if status == MOI.OPTIMAL
        saldo_esp = value(SaldoFinalEsperado)
        cvar_val  = value(CVaR_saldo)
        var_val   = value(VaR)
        println("\n✅ ÓTIMO encontrado em $(round(tempo, digits=1))s")
        println("   Saldo Final Esperado: R\$ $(round(saldo_esp, digits=3)) Mi")
        println("   CVaR ($(round((1-config.alpha)*100, digits=0))%): R\$ $(round(cvar_val, digits=3)) Mi")
        println("   VaR:                  R\$ $(round(var_val, digits=3)) Mi")
        return model, status
    else
        println("\n❌ Status: $status")
        return model, status
    end
end

# =============================================================================
# MAIN
# =============================================================================

function main()
    println("\n" * "="^60)
    println("🎯 DEQ MULTIESTÁGIO — ÁRVORE DE CENÁRIOS")
    println("="^60)

    config = load_deq_config()
    data   = load_market_data(config)
    arvore = build_scenario_tree(data, config)
    dm     = preprocess_market(data, config)

    model, status = solve_deq(config, data, arvore, dm)

    println("\n" * "="^60)
    println("✅ DEQ concluído!")
    println("="^60)
    return model, status
end

main()
