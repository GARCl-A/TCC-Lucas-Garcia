using CSV, DataFrames, Dates, Statistics
include("sddp.jl") 

function escrever_linha_sddp(f, timestamp, R, T, nos_teoricos, iterecoes, tempo_construcao, tempo_treinamento, status_str)
    linha = "$timestamp,$R,$T,$nos_teoricos,$iterecoes,$tempo_construcao,$tempo_treinamento,$status_str\n"
    write(f, linha)
    flush(f)
end

function run_sddp_benchmarks()
    println("="^60)
    println("🚀 INICIANDO BENCHMARK DO SDDP NAS INSTÂNCIAS CRÍTICAS")
    println("="^60)

    config_base = load_deq_config() 
    data_bruta  = load_market_data(config_base)

    # Os casos limites onde o DEQ sofreu ou parou (do seu log anterior)
    casos_limite = [
        (2, 14), # 32.767 nós
        (3, 9),  # 29.524 nós
        (4, 8),  # 87.381 nós
        (5, 6),  # 19.531 nós
        (6, 6),  # 55.987 nós
        (7, 5),  # 19.608 nós
        (8, 5),  # 37.449 nós
        (9, 5),  # 66.430 nós
        (10, 4)  # 11.111 nós
    ]

    arquivo_csv = joinpath(config_base.data_dir, "..", "results", "benchmark_sddp.csv")
    
    if !isfile(arquivo_csv)
        open(arquivo_csv, "w") do f
            write(f, "timestamp,ramos,meses,nos_teoricos,iteracoes,t_modelo_s,t_otimizacao_s,status\n")
        end
    end

    open(arquivo_csv, "a") do f
        for (R, T) in casos_limite
            total_nos_teoricos = 1 + sum(R^t for t in 1:T)
            println("\n--- Testando SDDP: R=$R, T=$T (Equivale a $total_nos_teoricos nós no DEQ) ---")

            config_teste = DEQConfig(config_base.data_dir, T, R, 42, 0.0, -1e8, 1e6)
            try
                mercado = preprocess_market(data_bruta, config_teste)
                trades = filter(r -> r.data in Set(mercado.meses), data_bruta.trades)
                max_d = maximum(trades.duracao_meses)
                
                # --- FASE 1: CONSTRUÇÃO ---
                t0 = time()
                model_sddp, _, _ = build_sddp_model(config_teste, data_bruta, mercado, max_d)
                t_modelo = round(time() - t0, digits=2)
                println("     Montagem SDDP: $(t_modelo)s")

                # --- FASE 2: RESOLUÇÃO ---
                # Como provamos que a matemática funciona, vamos rodar 50 iterações pra ver
                # o quão rápido ele consegue resolver a árvore completa em comparação ao DEQ.
                MAX_ITERATIONS = 50 
                
                t0_train = time()
                SDDP.train(
                    model_sddp, 
                    iteration_limit=MAX_ITERATIONS, 
                    print_level=0, 
                    risk_measure=SDDP.Expectation()
                )
                t_otimizacao = round(time() - t0_train, digits=2)
                
                println("     Treinamento SDDP ($MAX_ITERATIONS iter): $(t_otimizacao)s")
                
                escrever_linha_sddp(f, now(), R, T, total_nos_teoricos, MAX_ITERATIONS, t_modelo, t_otimizacao, "OPTIMAL_SDDP")

            catch e
                println("     [ERRO SDDP] $e")
                escrever_linha_sddp(f, now(), R, T, total_nos_teoricos, 0, NaN, NaN, "ERRO")
            end
        end
    end
    println("\n✅ Benchmark do SDDP concluído! Salvo em $arquivo_csv")
end

run_sddp_benchmarks()