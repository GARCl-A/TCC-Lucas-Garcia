using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf, Random

# --- Configuração ---

struct DEQConfig
    data_dir::String
    alpha::Float64
    lambda::Float64
    num_meses::Int
    num_ramos::Int
    seed::Int
    caixa_inicial::Float64
    limite_credito::Float64
    escala::Float64
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    contratos_existentes::DataFrame
    trades::DataFrame
end

function load_deq_config()
    data_dir = joinpath(@__DIR__, "..", "..", "..", "data", "processed")
    
    # 1. Dá uma "espiada" rápida no arquivo gerado pelo Python
    # (Lemos apenas as colunas necessárias para ficar super rápido)
    arquivo_cenarios = joinpath(data_dir, "cenarios_final.csv")
    df_temp = CSV.read(arquivo_cenarios, DataFrame, select=["data", "cenario"])
    
    # 2. Descobre Y (meses) e X (cenários) automaticamente
    y_meses = length(unique(df_temp.data))
    x_cenarios = length(unique(df_temp.cenario))
    
    println("⚙️ Autoconfiguração: Encontrados $x_cenarios cenários ($y_meses meses) no CSV.")

    return DEQConfig(
        data_dir,
        0.95,             # alpha CVaR
        0.05,              # lambda (peso do risco)
        y_meses,          # meses: Y (Automático!)
        x_cenarios,       # ramos: (Automático para a árvore do DEQ)
        42,               # seed
        0.0,              # caixa inicial
        -100.0,           # limite de crédito (R$ Mi)
        1e9               # escala: R$ milhões
    )
end

function load_market_data(config::DEQConfig)::MarketData
    println("Carregando dados...")
    d = config.data_dir
    cenarios             = CSV.read(joinpath(d, "cenarios_final.csv"),     DataFrame)
    geracao              = CSV.read(joinpath(d, "geracao_estocastica.csv"), DataFrame)
    contratos_existentes = CSV.read(joinpath(d, "contratos_legacy.csv"),   DataFrame)
    trades               = CSV.read(joinpath(d, "trades.csv"),             DataFrame)
    for df in (cenarios, geracao, contratos_existentes, trades)
        df.data = Date.(df.data)
    end
    return MarketData(cenarios, geracao, contratos_existentes, trades)
end

horas_mes(d::Date) = Float64(daysinmonth(d) * 24)

# --- Árvore de Cenários ---

struct ArvoreCenarios
    nos::Vector{Int}
    folhas::Vector{Int}
    no_pai::Dict{Int,Int}
    mes_do_no::Dict{Int,Date}
    prob_no::Dict{Int,Float64}
    pld_no::Dict{Tuple{Int,String},Float64}
    producao_no::Dict{Tuple{Int,String},Float64}
end

function build_scenario_tree(data::MarketData, config::DEQConfig)::ArvoreCenarios
    Random.seed!(config.seed)

    T = min(config.num_meses, length(sort(unique(data.cenarios.data))))
    R = min(config.num_ramos, maximum(data.cenarios.cenario))

    todos_meses  = sort(unique(data.cenarios.data))[1:T]
    submercados  = String.(unique(data.cenarios.submercado))
    num_cenarios = maximum(data.cenarios.cenario)

    idx_pld = Dict((r.data, r.cenario, r.submercado) => r.valor for r in eachrow(data.cenarios))

    sub_por_usina = Dict(r.usina_cod => r.submercado for r in eachrow(data.geracao))
    geracao_agregada = combine(
        groupby(
            transform(data.geracao, :usina_cod => ByRow(u -> get(sub_por_usina, u, "")) => :submercado),
            [:data, :cenario, :submercado]
        ),
        :geracao_mwm => sum => :geracao_total
    )
    idx_geracao = Dict((r.data, r.cenario, r.submercado) => r.geracao_total for r in eachrow(geracao_agregada))

    nos_por_estagio = [R^t for t in 1:T]
    total_nos_estimado = 1 + sum(nos_por_estagio)
    println("  Arvore: $total_nos_estimado nos estimados, $(nos_por_estagio[end]) folhas")

    cenarios_por_estagio = [sort(randperm(num_cenarios)[1:R]) for _ in 1:T]

    nos       = Int[]
    folhas    = Int[]
    no_pai    = Dict{Int,Int}()
    mes_do_no = Dict{Int,Date}()
    prob_no   = Dict{Int,Float64}()
    pld_no    = Dict{Tuple{Int,String},Float64}()
    producao_no = Dict{Tuple{Int,String},Float64}()

    id = 1
    push!(nos, id)
    no_pai[id]    = 0
    mes_do_no[id] = todos_meses[1]
    prob_no[id]   = 1.0
    c1 = cenarios_por_estagio[1][1]
    for sub in submercados
        pld_no[(id, sub)]    = get(idx_pld,    (todos_meses[1], c1, sub), 0.0)
        producao_no[(id, sub)] = get(idx_geracao, (todos_meses[1], c1, sub), 0.0)
    end

    nos_estagio_anterior = [id]
    id += 1
    t0 = time()

    for t in 2:T
        mes = todos_meses[t]
        nos_estagio_atual = Int[]
        cenarios_t = cenarios_por_estagio[t]

        for pai in nos_estagio_anterior
            for r in 1:R
                c = cenarios_t[r]
                push!(nos, id)
                push!(nos_estagio_atual, id)
                no_pai[id]      = pai
                mes_do_no[id]   = mes
                prob_no[id]     = prob_no[pai] / R
                for sub in submercados
                    pld_no[(id, sub)]    = get(idx_pld,    (mes, c, sub), 0.0)
                    producao_no[(id, sub)] = get(idx_geracao, (mes, c, sub), 0.0)
                end
                t == T && push!(folhas, id)
                id += 1
            end
        end
        nos_estagio_anterior = nos_estagio_atual
        print("\r  Estagio $t/$T ($(Dates.format(mes, "yyyy-mm"))): $(length(nos)) nos | $(round(time()-t0, digits=1))s")
        flush(stdout)
    end
    println()

    return ArvoreCenarios(nos, folhas, no_pai, mes_do_no, prob_no, pld_no, producao_no)
end

# --- Pré-processamento de Contratos ---

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

# --- Modelo DEQ Multiestágio ---

function solve_deq(config::DEQConfig, data::MarketData, cenarios::ArvoreCenarios, mercado::DadosMercado)
    println("Construindo modelo DEQ...")
    trades = filter(r -> r.data in Set(mercado.meses), data.trades)
    NT     = nrow(trades)
    nos    = cenarios.nos
    folhas = cenarios.folhas
    subs   = mercado.submercados
    ESCALA = config.escala

    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, volume_compra_trade[t=1:NT, n=nos] >= 0)
    @variable(model, volume_venda_trade[t=1:NT,  n=nos] >= 0)

    for t in 1:NT, n in nos
        set_upper_bound(volume_compra_trade[t,n], trades.limite_compra[t])
        set_upper_bound(volume_venda_trade[t,n],  trades.limite_venda[t])
        if trades.data[t] != cenarios.mes_do_no[n]
            fix(volume_compra_trade[t,n], 0.0; force=true)
            fix(volume_venda_trade[t,n],  0.0; force=true)
        end
    end

    max_d = maximum(trades.duracao_meses)
    # x_n
    @variable(model, saldo_no[n=nos])
    # v_{s,k,n}
    @variable(model, posicao_futura_volume[sub=subs, k=1:max_d, n=nos])
    # c_{s,k,n}
    @variable(model, receita_futura[sub=subs, k=1:max_d, n=nos])
    # VaR, η_n
    @variable(model, VaR)
    @variable(model, desvio_cvar[n=folhas] >= 0)

    total_nos = length(nos)
    t0_constraints = time()

    for (idx_n, n) in enumerate(nos)
        pai = cenarios.no_pai[n]
        mes = cenarios.mes_do_no[n]
        h   = horas_mes(mes)

        trades_no = [t for t in 1:NT if trades.data[t] == mes]

        if pai != 0 && !isempty(trades_no)
            # Busca todos os nós que vieram deste mesmo pai
            irmaos = [m for m in nos if cenarios.no_pai[m] == pai]
            primeiro_irmao = irmaos[1]
            
            # Se o nó atual não for o primeiro irmão, trava as variáveis dele nas do primeiro
            if n != primeiro_irmao
                for t in trades_no
                    @constraint(model, volume_compra_trade[t, n] == volume_compra_trade[t, primeiro_irmao])
                    @constraint(model, volume_venda_trade[t, n] == volume_venda_trade[t, primeiro_irmao])
                end
            end
        end

        for sub in subs
            trades_sub = filter(t -> trades.submercado[t] == sub, trades_no)

            # Transição do volume para k = 1 até max_d - 1
            for k in 1:(max_d - 1)
                delta_volume_k = isempty(trades_sub) ? AffExpr(0.0) : sum(
                    (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                    for t in trades_sub if trades.duracao_meses[t] > k;
                    init=AffExpr(0.0)
                )
                if pai == 0
                    @constraint(model, posicao_futura_volume[sub,k,n] == delta_volume_k)
                else
                    @constraint(model, posicao_futura_volume[sub,k,n] == posicao_futura_volume[sub,k+1,pai] + delta_volume_k)
                end
            end

            # Fronteira final do volume (k = max_d)
            delta_volume_max = isempty(trades_sub) ? AffExpr(0.0) : sum(
                (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                for t in trades_sub if trades.duracao_meses[t] > max_d;
                init=AffExpr(0.0)
            )
            @constraint(model, posicao_futura_volume[sub,max_d,n] == delta_volume_max)
        end

        # c_{s,k,n} = c_{s,k+1,a(n)} + sum_{d_i > k, s_i = s}( q^S*K^S - q^B*K^B )
        for sub in subs
            trades_sub = filter(t -> trades.submercado[t] == sub, trades_no)

            # Transição da receita para k = 1 até max_d - 1
            for k in 1:(max_d - 1)
                delta_receita_k = isempty(trades_sub) ? AffExpr(0.0) : sum(
                    (volume_venda_trade[t,n] * trades.preco_venda[t] -
                     volume_compra_trade[t,n] * trades.preco_compra[t])
                    for t in trades_sub if trades.duracao_meses[t] > k;
                    init=AffExpr(0.0)
                )
                if pai == 0
                    @constraint(model, receita_futura[sub,k,n] == delta_receita_k)
                else
                    @constraint(model, receita_futura[sub,k,n] == receita_futura[sub,k+1,pai] + delta_receita_k)
                end
            end

            # Fronteira final da receita (k = max_d)
            delta_receita_max = isempty(trades_sub) ? AffExpr(0.0) : sum(
                (volume_venda_trade[t,n] * trades.preco_venda[t] -
                 volume_compra_trade[t,n] * trades.preco_compra[t])
                for t in trades_sub if trades.duracao_meses[t] > max_d;
                init=AffExpr(0.0)
            )
            @constraint(model, receita_futura[sub,max_d,n] == delta_receita_max)
        end

        # R_n^{leg}
        lucro_contratos_existentes = sum(
            (get(mercado.preco_venda_exist,  (mes,sub), 0.0) * get(mercado.vol_venda_exist,  (mes,sub), 0.0) -
             get(mercado.preco_compra_exist, (mes,sub), 0.0) * get(mercado.vol_compra_exist, (mes,sub), 0.0)) * h / ESCALA
            for sub in subs; init=0.0
        )

        # sum_{i in I_n}( q^S*K^S - q^B*K^B )  — parcela corrente do pipeline financeiro
        receita_novos_trades = isempty(trades_no) ? AffExpr(0.0) : sum(
            (volume_venda_trade[t,n] * trades.preco_venda[t] -
             volume_compra_trade[t,n] * trades.preco_compra[t])
            for t in trades_no;
            init=AffExpr(0.0)
        )

        # sum_s c_{s,1,a(n)}
        receita_herdada_pai = (pai == 0) ? AffExpr(0.0) : sum(receita_futura[sub,1,pai] for sub in subs)

        # E_{s,n} = G_{s,n} + V^{0B} - V^{0S} + sum(q^B) - sum(q^S) + v_{s,1,a(n)}
        exposicao_spot = AffExpr(0.0)
        for sub in subs
            pld          = get(cenarios.pld_no,          (n, sub), 0.0)  # P_{s,n}
            producao     = get(cenarios.producao_no,      (n, sub), 0.0)  # G_{s,n}
            compra_exist = get(mercado.vol_compra_exist,  (mes,sub), 0.0) # V^{0B}
            venda_exist  = get(mercado.vol_venda_exist,   (mes,sub), 0.0) # V^{0S}

            trades_sub  = filter(t -> trades.submercado[t] == sub, trades_no)
            compra_nova = isempty(trades_sub) ? AffExpr(0.0) : sum(volume_compra_trade[t,n] for t in trades_sub; init=AffExpr(0.0))
            venda_nova  = isempty(trades_sub) ? AffExpr(0.0) : sum(volume_venda_trade[t,n]  for t in trades_sub; init=AffExpr(0.0))

            volume_herdado_pai = (pai == 0) ? 0.0 : posicao_futura_volume[sub,1,pai] # v_{s,1,a(n)}
            exposicao_sub = producao + compra_exist + compra_nova - venda_exist - venda_nova + volume_herdado_pai

            add_to_expression!(exposicao_spot, exposicao_sub * pld * h / ESCALA)
        end

        # x_n = x_{a(n)} + R^{leg} + [ sum(q^S*K^S - q^B*K^B) + c_{1,a(n)} ]*h/E_scale + sum_s E_{s,n}*P_{s,n}*h/E_scale
        saldo_pai = (pai == 0) ? AffExpr(config.caixa_inicial / ESCALA) : 1.0 * saldo_no[pai]
        @constraint(model,
            saldo_no[n] == saldo_pai + lucro_contratos_existentes +
                           (receita_novos_trades + receita_herdada_pai) * (h / ESCALA) + exposicao_spot
        )

        @constraint(model, saldo_no[n] >= config.limite_credito)

        if idx_n % max(1, div(total_nos, 20)) == 0 || idx_n == total_nos
            pct = round(Int, 100 * idx_n / total_nos)
            print("\r  Constraints: $idx_n/$total_nos ($pct%) | $(round(time()-t0_constraints, digits=1))s")
            flush(stdout)
        end
    end
    println()

    # E[x] = sum_{n in L} π_n * x_n
    @expression(model, saldo_esperado,
        sum(cenarios.prob_no[n] * saldo_no[n] for n in folhas)
    )

    # η_n >= VaR - x_n
    @constraint(model, restricao_cvar[n=folhas],
        desvio_cvar[n] >= VaR - saldo_no[n]
    )

    # CVaR = VaR - 1/(1-α) * sum π_n * η_n
    @expression(model, cvar_saldo,
        VaR - (1 / (1 - config.alpha)) * sum(cenarios.prob_no[n] * desvio_cvar[n] for n in folhas)
    )

    # max E[x] + λ * CVaR
    @objective(model, Max, saldo_esperado + config.lambda * cvar_saldo)

    println("Otimizando...")
    t0_solver = time()
    optimize!(model)
    tempo_solver = time() - t0_solver

    status = JuMP.termination_status(model)
    if status == MOI.OPTIMAL
        println("  Status: OTIMO ($(round(tempo_solver, digits=1))s)")
        println("  Saldo Esperado : R\$ $(round(value(saldo_esperado), digits=3)) Mi")
        println("  CVaR ($(round((1-config.alpha)*100, digits=0))%) : R\$ $(round(value(cvar_saldo), digits=3)) Mi")
        println("  VaR            : R\$ $(round(value(VaR), digits=3)) Mi")

        println("\nTrades executados na raiz (mes 1):")
        for t in 1:NT
            v_compra = value(volume_compra_trade[t, 1])
            v_venda  = value(volume_venda_trade[t, 1])
            if v_compra > 0.01 || v_venda > 0.01
                println("  $(trades.ticker[t]): compra=$(round(v_compra, digits=2)) MWm  venda=$(round(v_venda, digits=2)) MWm")
            end
        end
    else
        println("  Status: $status")
    end

    return model, status
end

# --- Main ---

function main()
    println("\nDEQ Multiestagio — Arvore de Cenarios")
    println("-"^40)

    config   = load_deq_config()
    println("  alpha=$(config.alpha)  lambda=$(config.lambda)  meses=$(config.num_meses)  ramos=$(config.num_ramos)  seed=$(config.seed)")

    data     = load_market_data(config)
    cenarios = build_scenario_tree(data, config)
    mercado  = preprocess_market(data, config)

    model, status = solve_deq(config, data, cenarios, mercado)

    println("-"^40)
    return model, status
end

main()
