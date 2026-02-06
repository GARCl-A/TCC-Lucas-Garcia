using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics, Printf

struct FrontierConfig
    data_dir::String
    alpha::Float64
    lambdas::Vector{Float64}
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    legado::DataFrame
    trades::DataFrame
end

struct OptimizationCache
    T::Vector{Date}
    S::Vector{String}
    A::UnitRange{Int}
    num_cenarios::Int
    Ω::UnitRange{Int}
    prob::Float64
    dict_pld::Dict
    dict_ger::Dict
    cache_legado::Dict
    cache_trades_idx::Dict
end

struct OptimizationResult
    lambda::Float64
    retorno_mi::Float64
    cvar_mi::Float64
    vol_hedge_mw::Float64
    status::String
end

function load_frontier_config()
    return FrontierConfig(
        joinpath(@__DIR__, "../..", "data", "processed"),
        0.95,
        [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 0.99]
    )
end

function load_market_data(config::FrontierConfig)::MarketData
    println("🔥 Carregando dados do mercado...")
    
    cenarios = CSV.read(joinpath(config.data_dir, "cenarios_final.csv"), DataFrame)
    geracao = CSV.read(joinpath(config.data_dir, "geracao.csv"), DataFrame)
    legado = CSV.read(joinpath(config.data_dir, "contratos_legacy.csv"), DataFrame)
    trades = CSV.read(joinpath(config.data_dir, "trades.csv"), DataFrame)
    
    cenarios.data = Date.(cenarios.data)
    geracao.data = Date.(geracao.data)
    legado.data = Date.(legado.data)
    trades.data = Date.(trades.data)
    
    return MarketData(cenarios, geracao, legado, trades)
end

function build_optimization_cache(data::MarketData)::OptimizationCache
    println("⚙️ Construindo cache de otimização...")
    
    T = sort(unique(data.cenarios.data))
    S = unique(data.cenarios.submercado)
    A = 1:nrow(data.trades)
    num_cenarios = maximum(data.cenarios.cenario)
    Ω = 1:num_cenarios
    prob = 1.0 / num_cenarios
    
    dict_pld = Dict((r.data, r.submercado, r.cenario) => r.valor for r in eachrow(data.cenarios))
    dict_ger = Dict((r.data, r.usina_cod) => r.geracao_mwm for r in eachrow(data.geracao))
    
    cache_legado = Dict()
    for t in T, s in S
        leg_mes = filter(row -> row.data == t && row.submercado == s, data.legado)
        val = sum(row.tipo == "VENDA" ? -row.volume_mwm : row.volume_mwm for row in eachrow(leg_mes); init=0.0)
        cache_legado[(t,s)] = val
    end
    
    cache_trades_idx = Dict()
    for t in T, s in S
        cache_trades_idx[(t,s)] = findall(row -> row.data == t && row.submercado == s, eachrow(data.trades))
    end
    
    return OptimizationCache(T, S, A, num_cenarios, Ω, prob, dict_pld, dict_ger, cache_legado, cache_trades_idx)
end

horas_mes(d::Date) = daysinmonth(d) * 24

function solve_cvar_model(λ::Float64, config::FrontierConfig, data::MarketData, cache::OptimizationCache)::OptimizationResult
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    @variable(model, 0 <= q_compra[a in cache.A] <= data.trades.limite_compra[a])
    @variable(model, 0 <= q_venda[a in cache.A] <= data.trades.limite_venda[a])
    @variable(model, VaR)
    @variable(model, dev[ω in cache.Ω] >= 0)
    
    expr_res_trades = AffExpr(0.0)
    for a in cache.A
        h = horas_mes(data.trades.data[a])
        add_to_expression!(expr_res_trades, (q_venda[a] * data.trades.preco_venda[a] - q_compra[a] * data.trades.preco_compra[a]) * h)
    end
    
    @expression(model, lucro_cenario[ω in cache.Ω], expr_res_trades)
    
    for t in cache.T, s in cache.S
        h = horas_mes(t)
        base_mw = (s == "SE" ? get(cache.dict_ger, (t, 202), 0.0) : 0.0) + cache.cache_legado[(t,s)]
        idx_trades = cache.cache_trades_idx[(t,s)]
        
        vol_trades = isempty(idx_trades) ? AffExpr(0.0) : sum(q_compra[a] - q_venda[a] for a in idx_trades)
        vol_total = base_mw + vol_trades
        
        for ω in cache.Ω
            pld = get(cache.dict_pld, (t, s, ω), 0.0)
            add_to_expression!(lucro_cenario[ω], vol_total * h * pld)
        end
    end
    
    @constraint(model, cvar_restricao[ω in cache.Ω], dev[ω] >= VaR - lucro_cenario[ω])
    @expression(model, RetornoEsperado, sum(lucro_cenario[ω] for ω in cache.Ω) * cache.prob)
    @expression(model, CVaR, VaR - (1 / ((1-config.alpha) * cache.num_cenarios)) * sum(dev[ω] for ω in cache.Ω))
    
    @objective(model, Max, (1 - λ) * RetornoEsperado + λ * CVaR)
    
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL
        ret = value(RetornoEsperado) / 1e6
        cvar = value(CVaR) / 1e6
        vol_hedge = sum(value.(q_compra)) + sum(value.(q_venda))
        return OptimizationResult(λ, ret, cvar, vol_hedge, "OPTIMAL")
    else
        return OptimizationResult(λ, 0.0, 0.0, 0.0, "FAILED")
    end
end

function run_frontier_optimization(config::FrontierConfig, data::MarketData, cache::OptimizationCache)
    println("🔥 Iniciando Loop da Fronteira Eficiente...")
    
    resultados = DataFrame(Lambda=Float64[], Retorno_Mi=Float64[], CVaR_Mi=Float64[], Vol_Hedge_MW=Float64[])
    
    for λ in config.lambdas
        print("⚡ Otimizando λ = $λ ... ")
        
        result = solve_cvar_model(λ, config, data, cache)
        
        if result.status == "OPTIMAL"
            push!(resultados, (result.lambda, result.retorno_mi, result.cvar_mi, result.vol_hedge_mw))
            println("✅ OK! (CVaR: R\$ $(round(result.cvar_mi, digits=1)) Mi | Hedge: $(round(result.vol_hedge_mw, digits=0)) MW)")
        else
            println("❌ Falha!")
        end
    end
    
    return resultados
end

function save_results(resultados::DataFrame, config::FrontierConfig)
    println("\n📊 TABELA FRONTEIRA EFICIENTE:")
    println(resultados)
    CSV.write(joinpath(config.data_dir, "resultados_fronteira.csv"), resultados)
    println("✅ Resultados salvos em resultados_fronteira.csv")
end

function main()
    config = load_frontier_config()
    data = load_market_data(config)
    cache = build_optimization_cache(data)
    
    resultados = run_frontier_optimization(config, data, cache)
    save_results(resultados, config)
end

main()