using CSV, DataFrames, JuMP, HiGHS, Statistics, Dates

struct ModelConfig
    data_dir::String
    arq_cenarios::String
    arq_geracao::String
    arq_contratos::String
    arq_trades::String
end

struct ModelData
    cenarios::DataFrame
    geracao::DataFrame
    legado::DataFrame
    trades::DataFrame
    pld_det::DataFrame
end

struct OptimizationSets
    T::Vector{Date}
    S::Vector{String}
    A::UnitRange{Int}
end

function load_config()
    return ModelConfig(
        joinpath(@__DIR__, "../..", "data", "processed"),
        "cenarios_final.csv",
        "geracao.csv",
        "contratos_legacy.csv",
        "trades.csv"
    )
end

function load_data(config::ModelConfig)::ModelData
    println("🔥 Carregando dados...")
    
    cenarios = CSV.read(joinpath(config.data_dir, config.arq_cenarios), DataFrame)
    geracao = CSV.read(joinpath(config.data_dir, config.arq_geracao), DataFrame)
    legado = CSV.read(joinpath(config.data_dir, config.arq_contratos), DataFrame)
    trades = CSV.read(joinpath(config.data_dir, config.arq_trades), DataFrame)
    
    return ModelData(cenarios, geracao, legado, trades, DataFrame())
end

function preprocess_data!(data::ModelData)::ModelData
    println("⚙️ Processando dados...")
    
    data.cenarios.data = Date.(data.cenarios.data)
    data.geracao.data = Date.(data.geracao.data)
    data.legado.data = Date.(data.legado.data)
    data.trades.data = Date.(data.trades.data)
    
    pld_det = combine(groupby(data.cenarios, [:data, :submercado]), :valor => mean => :pld)
    
    return ModelData(data.cenarios, data.geracao, data.legado, data.trades, pld_det)
end

function create_optimization_sets(data::ModelData)::OptimizationSets
    T = sort(unique(data.cenarios.data))
    S = unique(data.cenarios.submercado)
    A = 1:nrow(data.trades)
    
    println("   Horizonte: $(length(T)) meses")
    println("   Oportunidades de Trade: $(length(A))")
    
    return OptimizationSets(T, S, A)
end

horas_no_mes(d::Date) = daysinmonth(d) * 24

function build_trades_expression(model, sets::OptimizationSets, data::ModelData, q_compra, q_venda)
    expr = AffExpr(0.0)
    for a in sets.A
        h = horas_no_mes(data.trades.data[a])
        add_to_expression!(expr, 
            (q_venda[a] * data.trades.preco_venda[a] - q_compra[a] * data.trades.preco_compra[a]) * h)
    end
    return expr
end

function build_pld_expression(model, sets::OptimizationSets, data::ModelData, q_compra, q_venda)
    expr = AffExpr(0.0)
    
    dict_pld = Dict((r.data, r.submercado) => r.pld for r in eachrow(data.pld_det))
    dict_ger = Dict((r.data, r.usina_cod) => r.geracao_mwm for r in eachrow(data.geracao))
    
    for t in sets.T, s in sets.S
        h = horas_no_mes(t)
        
        g_val = (s == "SE") ? get(dict_ger, (t, 202), 0.0) : 0.0
        
        leg_mes = filter(row -> row.data == t && row.submercado == s, data.legado)
        q_legado = sum(row.tipo == "VENDA" ? -row.volume_mwm : row.volume_mwm for row in eachrow(leg_mes); init=0.0)
        
        indices_a = findall(row -> row.data == t && row.submercado == s, eachrow(data.trades))
        
        termos_trades = AffExpr(0.0)
        if !isempty(indices_a)
            add_to_expression!(termos_trades, sum(q_compra[a] - q_venda[a] for a in indices_a))
        end
        
        exposicao_mw = g_val + q_legado + termos_trades
        pld_val = get(dict_pld, (t, s), 0.0)
        add_to_expression!(expr, exposicao_mw * h * pld_val)
    end
    
    return expr
end

function build_optimization_model(sets::OptimizationSets, data::ModelData)
    println("🔨 Construindo modelo...")
    
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    @variable(model, 0 <= q_compra[a in sets.A] <= data.trades.limite_compra[a])
    @variable(model, 0 <= q_venda[a in sets.A] <= data.trades.limite_venda[a])
    
    expr_trades = build_trades_expression(model, sets, data, q_compra, q_venda)
    expr_pld = build_pld_expression(model, sets, data, q_compra, q_venda)
    
    @objective(model, Max, expr_trades + expr_pld)
    
    return model, q_compra, q_venda
end

function solve_and_report(model, sets::OptimizationSets, data::ModelData, q_compra, q_venda)
    println("⚡ Otimizando...")
    println("📝 Exportando modelo para 'modelo_deterministico.lp' para validação...")
    write_to_file(model, "modelo_deterministico.lp")
    optimize!(model)
    
    status = termination_status(model)
    println("📊 Status: $status")
    
    if status == MOI.OPTIMAL
        lucro_total = objective_value(model)
        println("💰 Lucro Esperado Total: R\$ $(round(lucro_total/1e6, digits=2)) Milhões")
        
        println("\n--- Principais Decisões (Top 5) ---")
        count = 0
        for a in sets.A
            qc = value(q_compra[a])
            qv = value(q_venda[a])
            if qc > 0.1 || qv > 0.1
                println("   Data: $(data.trades.data[a]) | Compra: $(round(qc,digits=1)) MW | Venda: $(round(qv,digits=1)) MW")
                count += 1
                if count >= 5 break end
            end
        end
    else
        println("❌ O modelo não encontrou solução ótima.")
    end
end

function main()
    println("🔥 Iniciando Modelo DETERMINÍSTICO...")
    config = load_config()
    data = load_data(config)
    data = preprocess_data!(data)
    sets = create_optimization_sets(data)
    
    model, q_compra, q_venda = build_optimization_model(sets, data)
    solve_and_report(model, sets, data, q_compra, q_venda)
end

main()