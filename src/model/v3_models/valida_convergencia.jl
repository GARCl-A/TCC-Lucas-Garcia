using CSV, DataFrames, Dates, JuMP, HiGHS, SDDP, Statistics
include("deq.jl")
include("sddp.jl")

function rodar_comparacao()
    println("="^60)
    println("VERIFICAÇÃO DE CONVERGÊNCIA MATEMÁTICA (DEQ vs SDDP)")
    println("="^60)

    # 1. Configurando um problema pequeno e idêntico para ambos
    # Vamos usar apenas 3 meses (T=3) e 2 cenários por nó (R=2) -> 15 Nós.
    config_base = load_deq_config()
    config_toy = DEQConfig(
        config_base.data_dir, 
        3,  # T = 3 meses
        2,  # R = 2 cenários
        42, # seed idêntica
        0.0, -1e8, 1.0 # Parâmetros base (R$)
    )

    data = load_market_data(config_toy)
    mercado = preprocess_market(data, config_toy)

    # =========================================================
    # RODANDO O DEQ
    # =========================================================
    println("\n[1] RESOLVENDO VIA DEQ...")
    cenarios_deq = build_scenario_tree(data, config_toy)
    
    # Chama as funções originais do seu deq.jl
    model_deq, filhos_de, trades_deq, NT = build_deq_model(config_toy, data, cenarios_deq, mercado)
    set_silent(model_deq)
    optimize!(model_deq)
    
    status_deq = JuMP.termination_status(model_deq)
    obj_deq = NaN
    decisoes_deq = Dict{String, Tuple{Float64, Float64}}()
    
    if status_deq == MOI.OPTIMAL
        obj_deq = objective_value(model_deq)
        println("    - Saldo Esperado (Objetivo) : R\$ $(round(obj_deq / 1e6, digits = 3)) Mi")
        
        # Pega as decisões do Mês 1 (primeiro filho do nó virtual)
        no_mes1 = filhos_de[1][1]
        for t in 1:NT
            v_c = value(model_deq[:volume_compra_trade][t, no_mes1])
            v_v = value(model_deq[:volume_venda_trade][t, no_mes1])
            if v_c > 0.01 || v_v > 0.01
                decisoes_deq[trades_deq.ticker[t]] = (v_c, v_v)
            end
        end
    end

    # =========================================================
    # RODANDO O SDDP
    # =========================================================
    println("\n[2] RESOLVENDO VIA SDDP...")
    trades_sddp = filter(r -> r.data in Set(mercado.meses), data.trades)
    max_d = maximum(trades_sddp.duracao_meses)
    
    model_sddp, _, _ = build_sddp_model(config_toy, data, mercado, max_d)
    
    SDDP.train(
        model_sddp,
        iteration_limit = 100, # Para 15 nós, convergir é garantido aqui
        stopping_rules = [SDDP.BoundStalling(20, 1e-4)],
        print_level = 0, # Silencioso
        risk_measure = SDDP.Expectation()
    )

    # O Upper Bound é o equivalente a Função Objetivo no modelo de Maximização
    obj_sddp = SDDP.calculate_bound(model_sddp)
    println("    - Upper Bound (Objetivo)    : R\$ $(round(obj_sddp / 1e6, digits = 3)) Mi")

    # Simulando para pegar as decisões do primeiro estágio (In-sample)
    # No SDDP determinístico no 1o estágio, 1 simulação basta para a decisão inicial
    trade_ids = 1:nrow(trades_sddp)
    sim_syms = vcat([Symbol("qB_", i) for i in trade_ids], [Symbol("qS_", i) for i in trade_ids])
    sims = SDDP.simulate(model_sddp, 1, sim_syms; skip_undefined_variables = true)

    decisoes_sddp = Dict{String, Tuple{Float64, Float64}}()
    trades_mes1 = [i for i in trade_ids if trades_sddp.data[i] == mercado.meses[1]]
    for i in trades_mes1
        qb = get(sims[1][1], Symbol("qB_", i), 0.0)
        qs = get(sims[1][1], Symbol("qS_", i), 0.0)
        if qb > 0.01 || qs > 0.01
            decisoes_sddp[trades_sddp.ticker[i]] = (qb, qs)
        end
    end

    # =========================================================
    # RELATÓRIO DE COMPARAÇÃO
    # =========================================================
    println("\n" * "="^60)
    println("RESULTADO DA COMPARAÇÃO (T=$(config_toy.num_meses), R=$(config_toy.num_ramos))")
    println("="^60)
    
    diff_obj = abs(obj_deq - obj_sddp)
    status_matematica = diff_obj < 1.0 ? "IGUAL ✅" : "DIFERENTE ❌"
    
    println("Função Objetivo DEQ  : R\$ $(round(obj_deq / 1e6, digits=4)) Mi")
    println("Função Objetivo SDDP : R\$ $(round(obj_sddp / 1e6, digits=4)) Mi")
    println("Status Matemático    : $status_matematica (Diff: $(round(diff_obj, digits=2)))")
    
    println("\nDecisões no Estágio 1 (Compra, Venda):")
    todas_chaves = unique(vcat(collect(keys(decisoes_deq)), collect(keys(decisoes_sddp))))
    for tk in todas_chaves
        c_deq, v_deq = get(decisoes_deq, tk, (0.0, 0.0))
        c_sddp, v_sddp = get(decisoes_sddp, tk, (0.0, 0.0))
        
        diff_c = abs(c_deq - c_sddp)
        diff_v = abs(v_deq - v_sddp)
        status_dec = (diff_c < 0.1 && diff_v < 0.1) ? "✅" : "❌"
        
        println("  [$tk] $status_dec")
        println("      DEQ : $(round(c_deq, digits=1)) / $(round(v_deq, digits=1))")
        println("      SDDP: $(round(c_sddp, digits=1)) / $(round(v_sddp, digits=1))")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    rodar_comparacao()
end

rodar_comparacao()