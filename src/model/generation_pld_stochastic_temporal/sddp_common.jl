using CSV, DataFrames, Dates, SDDP, HiGHS, Statistics, Printf, Random, LinearAlgebra

struct SDDPConfig
    data_dir::String
    num_meses::Int
    num_cenarios::Int
    seed::Int
    alpha::Float64
    lambda::Float64
    iteration_limit::Int
    num_simulations::Int
end

struct MarketData
    cenarios::DataFrame
    geracao::DataFrame
    contratos_existentes::DataFrame
    trades::DataFrame
end

function load_market_data(config::SDDPConfig)::MarketData
    println("🔥 Carregando dados do mercado...")
    cenarios = CSV.read(joinpath(config.data_dir, "cenarios_final.csv"), DataFrame)
    geracao = CSV.read(joinpath(config.data_dir, "geracao_estocastica.csv"), DataFrame)
    contratos_existentes = CSV.read(joinpath(config.data_dir, "contratos_legacy.csv"), DataFrame)
    trades = CSV.read(joinpath(config.data_dir, "trades.csv"), DataFrame)
    cenarios.data = Date.(cenarios.data)
    geracao.data = Date.(geracao.data)
    contratos_existentes.data = Date.(contratos_existentes.data)
    trades.data = Date.(trades.data)
    return MarketData(cenarios, geracao, contratos_existentes, trades)
end

horas_mes(d::Date) = daysinmonth(d) * 24

function train_sddp_model(model, risk_measure, config::SDDPConfig)
    println("\n🚀 Treinando modelo SDDP ($(config.iteration_limit) iterações)...\n")
    SDDP.train(model,
        iteration_limit = config.iteration_limit,
        risk_measure    = risk_measure,
        print_level     = 1,
        log_frequency   = 1,
    )
    println("\n✅ Treinamento concluído")
end

function simulate_policy(model, config::SDDPConfig)
    println("\n📊 Simulando política ótima ($(config.num_simulations) trajetórias)...")
    simulations = SDDP.simulate(model, config.num_simulations, [:caixa])
    lucros_totais    = [sim[end][:caixa].out * 1e6 for sim in simulations]
    retorno_esperado = mean(lucros_totais) / 1e6
    desvio_padrao    = std(lucros_totais)  / 1e6
    lucros_ordenados = sort(lucros_totais)
    idx_var          = Int(ceil((1 - config.alpha) * length(lucros_ordenados)))
    var_value        = lucros_ordenados[idx_var]
    cvar_lucro       = mean(lucros_ordenados[1:idx_var]) / 1e6
    caixa_final_medio = mean([sim[end][:caixa].out for sim in simulations]) * 1e6
    caixa_minimo      = minimum([minimum([stage[:caixa].out for stage in sim]) for sim in simulations]) * 1e6
    println("\n📈 RESULTADOS DA SIMULAÇÃO:")
    println("   Retorno Esperado:  R\$ $(round(retorno_esperado, digits=1)) Mi")
    println("   CVaR (5% piores):  R\$ $(round(cvar_lucro, digits=1)) Mi")
    println("   Desvio Padrão:     R\$ $(round(desvio_padrao, digits=1)) Mi")
    println("   VaR (95%):         R\$ $(round(var_value/1e6, digits=1)) Mi")
    println("   Caixa Final Médio: R\$ $(round(caixa_final_medio / 1e6, digits=1)) Mi")
    println("   Caixa Mínimo:      R\$ $(round(caixa_minimo / 1e6, digits=1)) Mi")
    return simulations, retorno_esperado, cvar_lucro, desvio_padrao
end

# =============================================================================
# Pré-processamento compartilhado — retorna estruturas base sem ruídos/trajetórias
# =============================================================================
function _preprocess_base(config::SDDPConfig, data::MarketData)
    println("⚙️  Pré-processando dados...")
    todos_meses = sort(unique(data.cenarios.data))
    meses       = todos_meses[1:min(config.num_meses, length(todos_meses))]
    submercados = unique(data.cenarios.submercado)
    usinas      = unique(data.geracao.usina_cod)
    num_cenarios_total = maximum(data.cenarios.cenario)
    Random.seed!(config.seed)
    cenarios_selecionados = sort(randperm(num_cenarios_total)[1:min(config.num_cenarios, num_cenarios_total)])
    println("   📅 Meses: $(length(meses)) | 🏭 Usinas: $(length(usinas))")
    println("   🎲 Cenários: $(length(cenarios_selecionados)) de $num_cenarios_total (seed=$(config.seed))")
    submercado_usina_df = unique(select(data.geracao, [:usina_cod, :submercado]))
    geracao_com_sub = leftjoin(data.geracao, submercado_usina_df, on=:usina_cod, makeunique=true)
    geracao_agrupada = combine(
        groupby(geracao_com_sub, [:data, :cenario, :submercado]),
        :geracao_mwm => sum => :geracao_total
    )
    set_meses    = Set(meses)
    set_cenarios = Set(cenarios_selecionados)
    cenarios_filtrado  = filter(r -> r.data in set_meses && r.cenario in set_cenarios, data.cenarios)
    geracao_filtrada   = filter(r -> r.data in set_meses && r.cenario in set_cenarios, geracao_agrupada)
    contratos_filtrado = filter(r -> r.data in set_meses, data.contratos_existentes)
    trades_filtrado    = filter(r -> r.data in set_meses, data.trades)
    idx_pld     = Dict((r.data, r.cenario, r.submercado) => r.valor         for r in eachrow(cenarios_filtrado))
    idx_geracao = Dict((r.data, r.cenario, r.submercado) => r.geracao_total  for r in eachrow(geracao_filtrada))
    return meses, submercados, cenarios_selecionados, contratos_filtrado, trades_filtrado, idx_pld, idx_geracao
end

function _contratos_por_submercado(submercados, contratos_mes)
    vol_compra_exist   = Dict{String, Float64}()
    vol_venda_exist    = Dict{String, Float64}()
    preco_compra_exist = Dict{String, Float64}()
    preco_venda_exist  = Dict{String, Float64}()
    for sub in submercados
        vol_compra_exist[sub]   = 0.0
        vol_venda_exist[sub]    = 0.0
        preco_compra_exist[sub] = 0.0
        preco_venda_exist[sub]  = 0.0
    end
    if nrow(contratos_mes) > 0
        grupos = groupby(contratos_mes, [:submercado, :tipo])
        for key in keys(grupos)
            sub = key.submercado
            tipo = key.tipo
            df_grupo = grupos[key]
            vol_total = sum(df_grupo.volume_mwm)
            preco_medio = sum(df_grupo.volume_mwm .* df_grupo.preco_r_mwh) / vol_total
            if tipo == "COMPRA"
                vol_compra_exist[sub] = vol_total
                preco_compra_exist[sub] = preco_medio
            elseif tipo == "VENDA"
                vol_venda_exist[sub] = vol_total
                preco_venda_exist[sub] = preco_medio
            end
        end
    end
    return vol_compra_exist, vol_venda_exist, preco_compra_exist, preco_venda_exist
end
