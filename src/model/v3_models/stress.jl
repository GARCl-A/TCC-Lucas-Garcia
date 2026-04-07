using CSV, DataFrames, Dates, JuMP, HiGHS
include("deq.jl") 

# Se PULAR_JA_RODADOS=true, lê o CSV existente e pula combinações (R,T) que já têm linha
const PULAR_JA_RODADOS = true

function carregar_ja_rodados(path)
    !isfile(path) && return Set{Tuple{Int,Int}}(), Dict{Int,Int}()
    linhas = filter(l -> !startswith(l, "#") && !startswith(l, "timestamp"), readlines(path))
    rodados   = Set{Tuple{Int,Int}}()
    stops     = Dict{Int,Int}()  # R => T_minimo do STOP_MANUAL
    for l in linhas[2:end]  # pula header
        partes = split(l, ",")
        length(partes) < 3 && continue
        try
            R, T = parse(Int, partes[2]), parse(Int, partes[3])
            status = strip(partes[end])
            if status == "STOP_MANUAL"
                stops[R] = min(get(stops, R, typemax(Int)), T)
            else
                push!(rodados, (R, T))
            end
        catch end
    end
    return rodados, stops
end

function escrever_linha(f, timestamp, R, T, nos, t_arvore, t_mercado, t_modelo, t_otimizacao, t_extracao, t_total, status)
    ts = Dates.format(timestamp, "dd/mm/yyyy HH:MM:SS")
    println(f, "$ts,$R,$T,$nos,$t_arvore,$t_mercado,$t_modelo,$t_otimizacao,$t_extracao,$t_total,$status")
    flush(f)
end

function run_stress_test()
    inicio_teste = now()
    println("="^50)
    println("🚀 INICIANDO TESTE DE ESTRESSE DO DEQ")
    println("   Início: $(Dates.format(inicio_teste, "dd/mm/yyyy HH:MM:SS"))")
    println("   Pular já rodados: $PULAR_JA_RODADOS")
    println("="^50)

    config_base = load_deq_config()
    data_bruta  = load_market_data(config_base)

    testes_ramos = [2, 3, 4, 5, 6, 7, 8, 9, 10]
    meses_limite = 36

    output_path = joinpath(config_base.data_dir, "..", "results", "stress_test_deq.csv")
    ja_rodados, stops = PULAR_JA_RODADOS ? carregar_ja_rodados(output_path) : (Set{Tuple{Int,Int}}(), Dict{Int,Int}())

    # Cria arquivo com header apenas se não existir
    if !isfile(output_path)
        open(output_path, "w") do f
            println(f, "# Criado em: $(Dates.format(inicio_teste, "dd/mm/yyyy HH:MM:SS"))")
            println(f, "timestamp,ramos,meses,nos,t_arvore_s,t_mercado_s,t_modelo_s,t_otimizacao_s,t_extracao_s,tempo_total_s,status")
        end
    end

    for R in testes_ramos
        println("\n--- Testando Incerteza: $R Ramos por Nó ---")
        for T in 2:meses_limite
            if (R, T) in ja_rodados
                println("  -> R=$R T=$T já rodado, pulando.")
                continue
            end
            if haskey(stops, R) && T >= stops[R]
                println("  -> R=$R T=$T bloqueado por STOP_MANUAL em T=$(stops[R]), pulando restante.")
                break
            end

            total_nos_estimado = 1 + sum(R^t for t in 1:T)
            println("  -> Rodando T=$T meses | Nós estimados: $total_nos_estimado")

            config_teste = DEQConfig(config_base.data_dir, T, R, 42, 0.0, -1e8, 1.0)

            t_arvore = NaN; t_mercado = NaN; t_modelo = NaN; t_otimizacao = NaN; t_extracao = NaN; t_total = NaN
            status_str = "ERRO"
            deve_parar = false

            open(output_path, "a") do f
                try
                    t_inicio_iter = now()

                    t0 = time()
                    cenarios  = build_scenario_tree(data_bruta, config_teste)
                    t_arvore  = round(time() - t0, digits=2)
                    println("     árvore OK ($(t_arvore)s)")
                    escrever_linha(f, t_inicio_iter, R, T, total_nos_estimado, t_arvore, NaN, NaN, NaN, NaN, NaN, "EM_ANDAMENTO")

                    t1 = time()
                    mercado   = preprocess_market(data_bruta, config_teste)
                    t_mercado = round(time() - t1, digits=2)
                    println("     mercado OK ($(t_mercado)s)")
                    escrever_linha(f, t_inicio_iter, R, T, total_nos_estimado, t_arvore, t_mercado, NaN, NaN, NaN, NaN, "EM_ANDAMENTO")

                    println("     Construindo modelo DEQ...")
                    t2 = time()
                    model, filhos_de, trades, NT = build_deq_model(config_teste, data_bruta, cenarios, mercado)
                    t_modelo = round(time() - t2, digits=2)
                    println("\n     modelo OK ($(t_modelo)s)")
                    escrever_linha(f, t_inicio_iter, R, T, total_nos_estimado, t_arvore, t_mercado, t_modelo, NaN, NaN, NaN, "EM_ANDAMENTO")

                    println("     Otimizando...")
                    t3 = time()
                    optimize!(model)
                    t_otimizacao = round(time() - t3, digits=2)
                    status_str   = string(JuMP.termination_status(model))
                    println("     otimização OK ($(t_otimizacao)s) | $status_str")
                    escrever_linha(f, t_inicio_iter, R, T, total_nos_estimado, t_arvore, t_mercado, t_modelo, t_otimizacao, NaN, NaN, "EM_ANDAMENTO")

                    t4 = time()
                    extract_deq_results(config_teste, model, cenarios, filhos_de, trades, NT)
                    t_extracao = round(time() - t4, digits=2)
                    t_total    = round(t_arvore + t_mercado + t_modelo + t_otimizacao + t_extracao, digits=2)
                    println("     OK! árvore=$(t_arvore)s | mercado=$(t_mercado)s | modelo=$(t_modelo)s | otim=$(t_otimizacao)s | extr=$(t_extracao)s | total=$(t_total)s")
                    escrever_linha(f, t_inicio_iter, R, T, total_nos_estimado, t_arvore, t_mercado, t_modelo, t_otimizacao, t_extracao, t_total, status_str)

                catch e
                    if occursin("MAX_NODES_EXCEEDED", string(e))
                        println("     [LIMITE] Árvore muito grande ($total_nos_estimado nós).")
                        status_str = "LIMITE_NOS_EXCEDIDO"
                    elseif isa(e, OutOfMemoryError)
                        println("     [FALHA] Memória RAM esgotada.")
                        status_str = "OUT_OF_MEMORY"
                    else
                        println("     [ERRO] $e")
                    end
                    escrever_linha(f, now(), R, T, total_nos_estimado, t_arvore, t_mercado, t_modelo, t_otimizacao, t_extracao, t_total, status_str)
                    deve_parar = true
                end
            end

            deve_parar && break
        end
    end

    println("\n✅ Teste concluído! Resultados em: $output_path")
end

run_stress_test()