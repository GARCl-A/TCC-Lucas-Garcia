using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf, Random

# --- Configuração ---

struct DEQConfig
    data_dir::String
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

    arquivo_cenarios = joinpath(data_dir, "cenarios_final.csv")
    df_temp = CSV.read(arquivo_cenarios, DataFrame, select=["data", "cenario"])

    y_meses    = length(unique(df_temp.data))
    x_cenarios = length(unique(df_temp.cenario))

    println("⚙️ Autoconfiguração: Encontrados $x_cenarios cenários ($y_meses meses) no CSV.")

    return DEQConfig(
        data_dir,
        y_meses,
        x_cenarios,
        42,      # seed
        0.0,     # caixa inicial (R$)
        -1e8,    # limite de crédito (-100 Mi em R$)
        1.0      # escala: sem conversão, valores em R$
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
    mes_do_no::Dict{Int,Union{Date,Nothing}}
    prob_no::Dict{Int,Float64}
    pld_no::Dict{Tuple{Int,String},Float64}
    producao_no::Dict{Tuple{Int,String},Float64}
end

const MAX_NOS = 150_000

function build_scenario_tree(data::MarketData, config::DEQConfig)::ArvoreCenarios
    Random.seed!(config.seed)

    T = min(config.num_meses, length(sort(unique(data.cenarios.data))))
    R = min(config.num_ramos, maximum(data.cenarios.cenario))

    total_nos_previsto = 1 + sum(R^t for t in 1:T)
    if total_nos_previsto > MAX_NOS
        error("MAX_NODES_EXCEEDED: T=$T, R=$R → $total_nos_previsto nós (limite: $MAX_NOS)")
    end

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
    println("  Arvore: $(1 + sum(nos_por_estagio)) nos, $(nos_por_estagio[end]) folhas")

    # Cada estágio usa todos os R cenários disponíveis (mesma distribuição do SDDP)
    cenarios_por_estagio = [collect(1:R) for _ in 1:T]

    nos         = Int[]
    folhas      = Int[]
    no_pai      = Dict{Int,Int}()
    mes_do_no   = Dict{Int,Union{Date,Nothing}}()
    prob_no     = Dict{Int,Float64}()
    pld_no      = Dict{Tuple{Int,String},Float64}()
    producao_no = Dict{Tuple{Int,String},Float64}()

    # Nó raiz virtual: sem mês, sem cenário, só inicializa o estado
    id = 1
    push!(nos, id)
    no_pai[id]  = 0
    mes_do_no[id] = nothing
    prob_no[id] = 1.0
    for sub in submercados
        pld_no[(id, sub)]      = 0.0
        producao_no[(id, sub)] = 0.0
    end

    nos_estagio_anterior = [id]
    id += 1
    t0 = time()

    for t in 1:T
        mes = todos_meses[t]
        nos_estagio_atual = Int[]
        cenarios_t = cenarios_por_estagio[t]

        for pai in nos_estagio_anterior
            for r in 1:R
                c = cenarios_t[r]
                push!(nos, id)
                push!(nos_estagio_atual, id)
                no_pai[id]    = pai
                mes_do_no[id] = mes
                prob_no[id]   = prob_no[pai] / R
                for sub in submercados
                    pld_no[(id, sub)]      = get(idx_pld,    (mes, c, sub), 0.0)
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

        vol_compra_exist[(mes,sub)]   = nrow(compras) > 0 ? sum(compras.volume_mwm) : 0.0
        preco_compra_exist[(mes,sub)] = nrow(compras) > 0 ? sum(compras.volume_mwm .* compras.preco_r_mwh) / sum(compras.volume_mwm) : 0.0
        vol_venda_exist[(mes,sub)]    = nrow(vendas)  > 0 ? sum(vendas.volume_mwm)  : 0.0
        preco_venda_exist[(mes,sub)]  = nrow(vendas)  > 0 ? sum(vendas.volume_mwm  .* vendas.preco_r_mwh)  / sum(vendas.volume_mwm)  : 0.0
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

function build_deq_model(config::DEQConfig, data::MarketData, cenarios::ArvoreCenarios, mercado::DadosMercado)
    trades = filter(r -> r.data in Set(mercado.meses), data.trades)
    NT     = nrow(trades)
    nos    = cenarios.nos
    folhas = cenarios.folhas
    subs   = mercado.submercados
    ESCALA = config.escala
    L_cred = config.limite_credito

    model = Model(HiGHS.Optimizer)
    set_attribute(model, "time_limit", 300.0)
    set_silent(model)

    @variable(model, volume_compra_trade[t=1:NT, n=nos] >= 0)
    @variable(model, volume_venda_trade[t=1:NT,  n=nos] >= 0)

    for t in 1:NT, n in nos
        set_upper_bound(volume_compra_trade[t,n], trades.limite_compra[t])
        set_upper_bound(volume_venda_trade[t,n],  trades.limite_venda[t])
        mes_n = cenarios.mes_do_no[n]
        if isnothing(mes_n) || trades.data[t] != mes_n
            fix(volume_compra_trade[t,n], 0.0; force=true)
            fix(volume_venda_trade[t,n],  0.0; force=true)
        end
    end

    max_d = maximum(trades.duracao_meses)
    @variable(model, saldo_no[n=nos])
    @variable(model, deficit_credito_no[n=nos] >= 0)
    @variable(model, posicao_futura_volume[sub=subs, k=1:max_d, n=nos])
    @variable(model, receita_futura[sub=subs, k=1:max_d, n=nos])
    total_nos = length(nos)
    t0_constraints = time()

    filhos_de = Dict{Int, Vector{Int}}()
    for n in nos
        push!(get!(filhos_de, cenarios.no_pai[n], Int[]), n)
    end

    for (idx_n, n) in enumerate(nos)
        pai    = cenarios.no_pai[n]
        mes_n  = cenarios.mes_do_no[n]

        if isnothing(mes_n)
            @constraint(model, saldo_no[n] == config.caixa_inicial / ESCALA)
            for sub in subs, k in 1:max_d
                fix(posicao_futura_volume[sub, k, n], 0.0; force=true)
                fix(receita_futura[sub, k, n],        0.0; force=true)
            end
            if idx_n % max(1, div(total_nos, 20)) == 0 || idx_n == total_nos
                print("\r  Constraints: $idx_n/$total_nos ($(round(Int, 100*idx_n/total_nos))%) | $(round(time()-t0_constraints, digits=1))s")
                flush(stdout)
            end
            continue
        end

        mes = mes_n
        h   = horas_mes(mes)
        trades_no = [t for t in 1:NT if trades.data[t] == mes]

        # Não-antecipatividade: irmãos com mesmo pai tomam a mesma decisão
        if !isempty(trades_no)
            primeiro_irmao = filhos_de[pai][1]
            if n != primeiro_irmao
                for t in trades_no
                    @constraint(model, volume_compra_trade[t, n] == volume_compra_trade[t, primeiro_irmao])
                    @constraint(model, volume_venda_trade[t, n]  == volume_venda_trade[t, primeiro_irmao])
                end
            end
        end

        # Transição do pipeline de volumes
        for sub in subs
            trades_sub = filter(t -> trades.submercado[t] == sub, trades_no)
            for k in 1:(max_d - 1)
                delta = isempty(trades_sub) ? AffExpr(0.0) : sum(
                    (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                    for t in trades_sub if trades.duracao_meses[t] > k; init=AffExpr(0.0))
                if pai == 0 || isnothing(cenarios.mes_do_no[pai])
                    @constraint(model, posicao_futura_volume[sub,k,n] == delta)
                else
                    @constraint(model, posicao_futura_volume[sub,k,n] == posicao_futura_volume[sub,k+1,pai] + delta)
                end
            end
            delta_max = isempty(trades_sub) ? AffExpr(0.0) : sum(
                (volume_compra_trade[t,n] - volume_venda_trade[t,n])
                for t in trades_sub if trades.duracao_meses[t] > max_d; init=AffExpr(0.0))
            @constraint(model, posicao_futura_volume[sub,max_d,n] == delta_max)
        end

        # Transição do pipeline financeiro
        for sub in subs
            trades_sub = filter(t -> trades.submercado[t] == sub, trades_no)
            for k in 1:(max_d - 1)
                delta = isempty(trades_sub) ? AffExpr(0.0) : sum(
                    (volume_venda_trade[t,n] * trades.preco_venda[t] - volume_compra_trade[t,n] * trades.preco_compra[t])
                    for t in trades_sub if trades.duracao_meses[t] > k; init=AffExpr(0.0))
                if pai == 0 || isnothing(cenarios.mes_do_no[pai])
                    @constraint(model, receita_futura[sub,k,n] == delta)
                else
                    @constraint(model, receita_futura[sub,k,n] == receita_futura[sub,k+1,pai] + delta)
                end
            end
            delta_max = isempty(trades_sub) ? AffExpr(0.0) : sum(
                (volume_venda_trade[t,n] * trades.preco_venda[t] - volume_compra_trade[t,n] * trades.preco_compra[t])
                for t in trades_sub if trades.duracao_meses[t] > max_d; init=AffExpr(0.0))
            @constraint(model, receita_futura[sub,max_d,n] == delta_max)
        end

        # Resultado legado
        R_leg = sum(
            (get(mercado.preco_venda_exist,  (mes,sub), 0.0) * get(mercado.vol_venda_exist,  (mes,sub), 0.0) -
             get(mercado.preco_compra_exist, (mes,sub), 0.0) * get(mercado.vol_compra_exist, (mes,sub), 0.0)) * h / ESCALA
            for sub in subs; init=0.0)

        receita_novos = isempty(trades_no) ? AffExpr(0.0) : sum(
            (volume_venda_trade[t,n] * trades.preco_venda[t] - volume_compra_trade[t,n] * trades.preco_compra[t])
            for t in trades_no; init=AffExpr(0.0))

        receita_herdada = isnothing(cenarios.mes_do_no[pai]) ? AffExpr(0.0) :
            sum(receita_futura[sub,1,pai] for sub in subs; init=AffExpr(0.0))

        # Exposição spot
        exposicao_spot = AffExpr(0.0)
        for sub in subs
            pld          = get(cenarios.pld_no,         (n, sub), 0.0)
            producao     = get(cenarios.producao_no,     (n, sub), 0.0)
            compra_exist = get(mercado.vol_compra_exist, (mes,sub), 0.0)
            venda_exist  = get(mercado.vol_venda_exist,  (mes,sub), 0.0)
            trades_sub   = filter(t -> trades.submercado[t] == sub, trades_no)
            compra_nova  = isempty(trades_sub) ? AffExpr(0.0) : sum(volume_compra_trade[t,n] for t in trades_sub; init=AffExpr(0.0))
            venda_nova   = isempty(trades_sub) ? AffExpr(0.0) : sum(volume_venda_trade[t,n]  for t in trades_sub; init=AffExpr(0.0))
            vol_herdado  = isnothing(cenarios.mes_do_no[pai]) ? 0.0 : posicao_futura_volume[sub,1,pai]
            E_sub = producao + compra_exist + compra_nova - venda_exist - venda_nova + vol_herdado
            add_to_expression!(exposicao_spot, E_sub * pld * h / ESCALA)
        end

        # Equação de transição de caixa
        saldo_pai = isnothing(cenarios.mes_do_no[pai]) ? AffExpr(config.caixa_inicial / ESCALA) : 1.0 * saldo_no[pai]
        @constraint(model,
            saldo_no[n] == saldo_pai + R_leg +
                (receita_novos + receita_herdada) * (h / ESCALA) + exposicao_spot)

        # Restrição de crédito soft (mesma penalidade do SDDP)
        @constraint(model, saldo_no[n] + deficit_credito_no[n] >= L_cred)

        if idx_n % max(1, div(total_nos, 20)) == 0 || idx_n == total_nos
            print("\r  Constraints: $idx_n/$total_nos ($(round(Int, 100*idx_n/total_nos))%) | $(round(time()-t0_constraints, digits=1))s")
            flush(stdout)
        end
    end
    println()

    nos_nao_raiz = filter(n -> !isnothing(cenarios.mes_do_no[n]), nos)
    @expression(model, saldo_esperado, sum(cenarios.prob_no[n] * saldo_no[n] for n in folhas))
    @expression(model, penalidade_total, sum(cenarios.prob_no[n] * deficit_credito_no[n] for n in nos_nao_raiz))
    @objective(model, Max, saldo_esperado - (1e9 / ESCALA) * penalidade_total)

    return model, filhos_de, trades, NT
end

function extract_deq_results(config::DEQConfig, model, cenarios::ArvoreCenarios, filhos_de, trades, NT)
    nos    = cenarios.nos
    saldo_no            = model[:saldo_no]
    volume_compra_trade = model[:volume_compra_trade]
    volume_venda_trade  = model[:volume_venda_trade]
    saldo_esperado      = model[:saldo_esperado]

    status = JuMP.termination_status(model)
    if status == MOI.OPTIMAL
        println("  Saldo Esperado : R\$ $(round(value(saldo_esperado) / 1e6, digits=3)) Mi")

        no_mes1 = filhos_de[1][1]
        println("\nTrades executados no mês 1 (decisão única, pré-cenário):")
        for t in 1:NT
            v_c = value(volume_compra_trade[t, no_mes1])
            v_v = value(volume_venda_trade[t, no_mes1])
            if v_c > 0.01 || v_v > 0.01
                println("  $(trades.ticker[t]): compra=$(round(v_c, digits=2)) MWm  venda=$(round(v_v, digits=2)) MWm")
            end
        end

        rows = NamedTuple{(:mes, :no, :ticker, :compra_mwm, :venda_mwm, :saldo_mi),
                          Tuple{Date,Int,String,Float64,Float64,Float64}}[]
        for n in nos
            isnothing(cenarios.mes_do_no[n]) && continue
            mes = cenarios.mes_do_no[n]
            trades_no = [t for t in 1:NT if trades.data[t] == mes]
            saldo_mi  = value(saldo_no[n]) / 1e6
            for t in trades_no
                push!(rows, (
                    mes        = mes,
                    no         = n,
                    ticker     = trades.ticker[t],
                    compra_mwm = round(value(volume_compra_trade[t, n]), digits=4),
                    venda_mwm  = round(value(volume_venda_trade[t, n]),  digits=4),
                    saldo_mi   = round(saldo_mi, digits=3)
                ))
            end
        end
        out_path = joinpath(config.data_dir, "..", "results", "deq_decisoes.csv")
        mkpath(dirname(out_path))
        CSV.write(out_path, DataFrame(rows))
        println("  Decisões exportadas: $out_path")
    else
        println("  Status: $status")
    end
    return status
end

function solve_deq(config::DEQConfig, data::MarketData, cenarios::ArvoreCenarios, mercado::DadosMercado)
    println("Construindo modelo DEQ...")
    model, filhos_de, trades, NT = build_deq_model(config, data, cenarios, mercado)

    println("Otimizando...")
    t0_solver = time()
    optimize!(model)
    tempo_solver = time() - t0_solver

    status = JuMP.termination_status(model)
    println("  Status: $(status == MOI.OPTIMAL ? "OTIMO" : string(status)) ($(round(tempo_solver, digits=1))s)")
    extract_deq_results(config, model, cenarios, filhos_de, trades, NT)

    return model, status
end

# --- Main ---

function main()
    println("\nDEQ Multiestagio — Arvore de Cenarios")
    println("-"^40)

    config   = load_deq_config()
    println("  meses=$(config.num_meses)  ramos=$(config.num_ramos)  seed=$(config.seed)")

    data     = load_market_data(config)
    cenarios = build_scenario_tree(data, config)
    mercado  = preprocess_market(data, config)

    model, status = solve_deq(config, data, cenarios, mercado)

    println("-"^40)
    return model, status
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end