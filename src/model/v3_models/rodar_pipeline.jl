# rodar_pipeline.jl
# Abra este arquivo no VSCode e aperte o botão play (▶).
# Ajuste NUM_MESES e NUM_RAMOS abaixo antes de rodar.
#
# Gera em data/results/:
#   deq_decisoes.csv          (completo)
#   deq_decisoes_raiz.csv     (só estágio 1)
#   sddp_decisoes.csv         (completo)
#   sddp_decisoes_raiz.csv    (só estágio 1)
#
# Depois rode: python pipeline_validacao.py

include(joinpath(@__DIR__, "config_instancia.jl"))
include("deq.jl")
include("sddp.jl")

using CSV, DataFrames, Statistics

println("\n" * "="^60)
println("PIPELINE DE VALIDAÇÃO — instância: $(INSTANCIA_NUM_MESES) meses × $(INSTANCIA_NUM_RAMOS) ramos")
println("="^60)

config  = load_deq_config()
out_dir = joinpath(config.data_dir, "..", "results")
mkpath(out_dir)

# ── Função auxiliar: exporta apenas o nó raiz ───────────────────────────────
function exportar_raiz(rows_raiz, caminho)
    CSV.write(caminho, DataFrame(rows_raiz))
    println("   Nó raiz exportado: $caminho")
end

# ════════════════════════════════════════════════════════════════════════════
# 1. DEQ
# ════════════════════════════════════════════════════════════════════════════
println("\n[1/2] DEQ")
println("-"^40)

data_mkt  = load_market_data(config)
cenarios  = build_scenario_tree(data_mkt, config)
mercado   = preprocess_market(data_mkt, config)

model_deq, filhos_de, trades_deq, NT_deq = build_deq_model(config, data_mkt, cenarios, mercado)
optimize!(model_deq)

status_deq = JuMP.termination_status(model_deq)
println("   Status DEQ: $(status_deq == MOI.OPTIMAL ? "ÓTIMO" : string(status_deq))")

# Exporta CSV completo (comportamento original)
extract_deq_results(config, model_deq, cenarios, filhos_de, trades_deq, NT_deq)

# Exporta CSV reduzido: apenas o nó raiz do estágio 1
no_raiz = filhos_de[1][1]
vol_compra = model_deq[:volume_compra_trade]
vol_venda  = model_deq[:volume_venda_trade]

rows_deq_raiz = NamedTuple{(:ticker, :compra_mwm, :venda_mwm),
                             Tuple{String, Float64, Float64}}[]
for t in 1:NT_deq
    trades_deq.data[t] == mercado.meses[1] || continue
    push!(rows_deq_raiz, (
        ticker     = trades_deq.ticker[t],
        compra_mwm = round(value(vol_compra[t, no_raiz]), digits=4),
        venda_mwm  = round(value(vol_venda[t,  no_raiz]), digits=4),
    ))
end
exportar_raiz(rows_deq_raiz, joinpath(out_dir, "deq_decisoes_raiz.csv"))

# ════════════════════════════════════════════════════════════════════════════
# 2. SDDP
# ════════════════════════════════════════════════════════════════════════════
println("\n[2/2] SDDP")
println("-"^40)

trades_sddp = filter(r -> r.data in Set(mercado.meses), data_mkt.trades)
NT_sddp     = nrow(trades_sddp)
max_d       = maximum(trades_sddp.duracao_meses)

model_sddp, _, ESCALA_sddp = build_sddp_model(config, data_mkt, mercado, max_d)

println("   Treinando SDDP...")
SDDP.train(
    model_sddp,
    iteration_limit  = 50,
    stopping_rules   = [SDDP.BoundStalling(100, 1e-6)],
    print_level      = 1,
    risk_measure     = SDDP.Expectation(),
)

bound = SDDP.calculate_bound(model_sddp)
println("   Upper Bound: R\$ $(round(bound / 1e6, digits=3)) Mi")

# Simula usando exatamente a mesma lógica do main_sddp() em sddp.jl
trade_ids = 1:NT_sddp
sim_syms  = vcat([:caixa],
                 [Symbol("qB_", i) for i in trade_ids],
                 [Symbol("qS_", i) for i in trade_ids])

sims = SDDP.simulate(model_sddp, 1000, sim_syms; skip_undefined_variables = true)

_, pld_idx, ger_idx = build_scenario_indexes(data_mkt, mercado, config)

rows_sddp_full = NamedTuple{(:simulacao, :estagio, :mes, :cenario, :pld_sub, :geracao_sub,
                              :ticker, :compra_mwm, :venda_mwm, :saldo_mi),
                             Tuple{Int,Int,Date,Int,Float64,Float64,String,Float64,Float64,Float64}}[]
for (s_idx, sim) in enumerate(sims)
    for m_idx in 1:config.num_meses
        mes          = mercado.meses[m_idx]
        stage_dec    = sim[2 * m_idx - 1]   # nó de decisão (c_id == 0)
        stage_settle = sim[2 * m_idx]        # nó de liquidação (c_id > 0)
        saldo  = stage_settle[:caixa].out / 1e6
        c_id   = stage_settle[:node_index][2]
        for i in trade_ids
            trades_sddp.data[i] == mes || continue
            qb = get(stage_dec, Symbol("qB_", i), nothing)
            qs = get(stage_dec, Symbol("qS_", i), nothing)
            qb === nothing && continue
            sub     = trades_sddp.submercado[i]
            pld     = round(get(pld_idx, (mes, c_id, sub), 0.0), digits=2)
            geracao = round(get(ger_idx, (mes, c_id, sub), 0.0), digits=2)
            push!(rows_sddp_full, (s_idx, m_idx, mes, c_id, pld, geracao,
                                   String(trades_sddp.ticker[i]),
                                   round(qb, digits=4), round(qs, digits=4),
                                   round(saldo, digits=3)))
        end
    end
end
CSV.write(joinpath(out_dir, "sddp_decisoes.csv"), DataFrame(rows_sddp_full))
println("   Decisões completas exportadas: $(joinpath(out_dir, "sddp_decisoes.csv"))")

# Exporta CSV reduzido: nó raiz do estágio 1
# A decisão do estágio 1 é pré-cenário — todas as simulações têm o mesmo valor.
# Usa sims[1][1] que é o stage_dec do mês 1 da simulação 1.
trades_mes1 = [i for i in trade_ids if trades_sddp.data[i] == mercado.meses[1]]
rows_sddp_raiz = NamedTuple{(:ticker, :compra_mwm, :venda_mwm),
                              Tuple{String, Float64, Float64}}[]
for i in trades_mes1
    qb = get(sims[1][1], Symbol("qB_", i), 0.0)
    qs = get(sims[1][1], Symbol("qS_", i), 0.0)
    push!(rows_sddp_raiz, (
        ticker     = String(trades_sddp.ticker[i]),
        compra_mwm = round(qb, digits=4),
        venda_mwm  = round(qs, digits=4),
    ))
end
exportar_raiz(rows_sddp_raiz, joinpath(out_dir, "sddp_decisoes_raiz.csv"))

println("\n" * "="^60)
println("Pipeline Julia concluído. Rode agora o script Python:")
println("  python pipeline_validacao.py")
println("="^60)
