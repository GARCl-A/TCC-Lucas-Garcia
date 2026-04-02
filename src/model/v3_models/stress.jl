using CSV, DataFrames, Dates, JuMP, HiGHS
include("deq.jl") 

function run_stress_test()
    println("="^50)
    println("🚀 INICIANDO TESTE DE ESTRESSE DO DEQ (LIMITE DE 5 MINUTOS)")
    println("="^50)

    config_base = load_deq_config() 
    data_bruta  = load_market_data(config_base)

    TIME_LIMIT_SEC = 300.0 # 5 minutos

    testes_ramos = [2, 3, 4, 5]
    meses_limite = 36
    resultados = []

    for R in testes_ramos
        println("\n--- Testando Incerteza: $R Ramos por Nó ---")
        for T in 2:meses_limite
            total_nos = 1 + sum(R^t for t in 1:T)
            println("  -> Rodando T=$T meses | Nós: $total_nos")
            
            config_teste = DEQConfig(
                config_base.data_dir, T, R, 42, 0.0, -100.0, 1.0
            )

try
                t0 = time()
                cenarios = build_scenario_tree(data_bruta, config_teste)
                mercado  = preprocess_market(data_bruta, config_teste)
                
                # --- EXECUÇÃO COM TIMEOUT FORÇADO (NÍVEL JULIA) ---
                task = @async solve_deq(config_teste, data_bruta, cenarios, mercado)
                
                t_total = 0.0
                while !istaskdone(task)
                    sleep(1.0) # Espera 1 segundo
                    t_total = time() - t0
                    
                    if t_total > TIME_LIMIT_SEC
                        println("\n     [TIMEOUT] Limite de 5 minutos excedido! Abortando a força.")
                        # Tenta matar a tarefa (nem sempre funciona perfeitamente se o HiGHS travar no C++, mas é o mais seguro)
                        schedule(task, ErrorException("Timeout"), error=true) 
                        break
                    end
                end
                # --------------------------------------------------

                if t_total > TIME_LIMIT_SEC
                    push!(resultados, (ramos=R, meses=T, nos=total_nos, tempo_segundos=round(t_total, digits=1), status="TIMEOUT_FORCADO"))
                    break # Passa do limite, vai pro próximo "R"
                end

                # Se a tarefa terminou dentro do tempo, pegamos os resultados
                model, status = fetch(task)
                t_total = time() - t0
                status_str = string(status)
                
                println("     OK! Tempo Total: $(round(t_total, digits=1))s | Status: $status_str")
                push!(resultados, (ramos=R, meses=T, nos=total_nos, tempo_segundos=round(t_total, digits=1), status=status_str))
                
            catch e
                if isa(e, OutOfMemoryError)
                    println("     [FALHA] Memória RAM esgotada (OutOfMemory).")
                    push!(resultados, (ramos=R, meses=T, nos=total_nos, tempo_segundos=NaN, status="OUT_OF_MEMORY"))
                else
                    println("     [ERRO] $e")
                    push!(resultados, (ramos=R, meses=T, nos=total_nos, tempo_segundos=NaN, status="ERRO"))
                end
                break
            end
        end
    end

    df_resultados = DataFrame(resultados)
    CSV.write(joinpath(config_base.data_dir, "..", "results", "stress_test_deq.csv"), df_resultados)
    println("\n✅ Teste concluído!")
end

run_stress_test()