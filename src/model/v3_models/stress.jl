using CSV, DataFrames, Dates, JuMP, HiGHS
include("deq.jl") # Puxa as suas funções do DEQ

function run_stress_test()
    println("="^50)
    println("🚀 INICIANDO TESTE DE ESTRESSE DO DEQ")
    println("="^50)

    # Carrega os dados brutos de 36 meses uma única vez
    config_base = load_deq_config() 
    data_bruta  = load_market_data(config_base)

    # Limite de segurança: se a árvore passar de 300.000 nós, nem tenta rodar para não travar o PC
    MAX_NOS_SEGUROS = 300_000 

    testes_ramos = [2, 3, 4, 5, 10]
    meses_limite = 36
    
    resultados = []

    for R in testes_ramos
        println("\n--- Testando Incerteza: $R Ramos por Nó ---")
        for T in 2:meses_limite
            # Pré-calcula o tamanho da árvore (1 raiz + ramos)
            total_nos = 1 + sum(R^t for t in 1:T)

            if total_nos > MAX_NOS_SEGUROS
                println("  [BLOQUEADO] T=$T | Nós: $total_nos (Excedeu o limite seguro de RAM)")
                break # Sai do loop de meses e vai para o próximo "R"
            end

            println("  -> Rodando T=$T meses | Nós estimados: $total_nos")
            
            # Cria a config específica para esse loop
            config_teste = DEQConfig(
                config_base.data_dir,
                T,          # num_meses
                R,          # num_ramos
                42,         # seed
                0.0,        # caixa_inicial
                -100.0,     # limite_credito
                1.0         # escala
            )

            # Bloco try/catch caso o HiGHS estoure a memória mesmo nos nós permitidos
            try
                t0_build = time()
                cenarios = build_scenario_tree(data_bruta, config_teste)
                mercado  = preprocess_market(data_bruta, config_teste)
                
                # Monta e Otimiza
                model, status = solve_deq(config_teste, data_bruta, cenarios, mercado)
                t_total = time() - t0_build
                
                status_str = string(status)
                
                push!(resultados, (ramos=R, meses=T, nos_arvore=total_nos, tempo_segundos=round(t_total, digits=2), status=status_str))
                
                println("     OK! Tempo: $(round(t_total, digits=1))s | Status: $status_str")
                
            catch e
                println("     [FALHA] Ocorreu um erro de memória ou estabilidade.")
                push!(resultados, (ramos=R, meses=T, nos_arvore=total_nos, tempo_segundos=NaN, status="ERRO/OOM"))
                break # Para de tentar meses maiores para esse R
            end
        end
    end

    # Exporta para CSV
    df_resultados = DataFrame(resultados)
    out_path = joinpath(config_base.data_dir, "..", "results", "stress_test_deq.csv")
    mkpath(dirname(out_path))
    CSV.write(out_path, df_resultados)
    
    println("\n✅ Teste de estresse concluído! Resultados salvos em: $out_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_stress_test()
end