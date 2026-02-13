using CSV, DataFrames, Dates, JuMP, HiGHS, Statistics

include("deterministico_equivalente.jl")

"""
TESTE DE VALIDAÇÃO: Cria trades artificialmente vantajosos para verificar se o modelo funciona.

Cenário de teste:
1. Reduz preço de COMPRA em 50% (trades de compra ficam muito baratos)
2. Aumenta preço de VENDA em 50% (trades de venda ficam muito caros)
3. O modelo DEVE fazer trades para aproveitar essas oportunidades
"""

function teste_validacao()
    println("🧪 TESTE DE VALIDAÇÃO DO MODELO")
    println("=" ^ 60)
    
    # Carrega dados normais
    config = load_frontier_config()
    data_original = load_market_data(config)
    
    # Cria cópia dos dados com trades vantajosos
    data_teste = MarketData(
        data_original.cenarios,
        data_original.geracao,
        data_original.contratos_existentes,
        copy(data_original.trades)
    )
    
    # MODIFICA OS PREÇOS DOS TRADES PARA TORNÁ-LOS VANTAJOSOS
    println("\n📝 Modificando preços dos trades:")
    println("   Preço de COMPRA: -50% (trades de compra ficam baratos)")
    println("   Preço de VENDA:  +50% (trades de venda ficam caros)\n")
    
    data_teste.trades.preco_compra = data_original.trades.preco_compra .* 0.5  # 50% mais barato
    data_teste.trades.preco_venda = data_original.trades.preco_venda .* 1.5    # 50% mais caro
    
    # Mostra exemplo de preços
    println("📊 Exemplo de preços (primeiro trade):")
    println("   ORIGINAL: Compra = R\$ $(round(data_original.trades.preco_compra[1], digits=2)) | Venda = R\$ $(round(data_original.trades.preco_venda[1], digits=2))")
    println("   TESTE:    Compra = R\$ $(round(data_teste.trades.preco_compra[1], digits=2)) | Venda = R\$ $(round(data_teste.trades.preco_venda[1], digits=2))")
    
    # Constrói cache
    cache = build_optimization_cache(data_teste)
    
    # Calcula benchmark
    println("\n📊 BENCHMARK (Sem Otimização):")
    bench_retorno, bench_cvar, bench_std = calculate_benchmark(cache, config)
    println("   Retorno Esperado: R\$ $(round(bench_retorno, digits=1)) Mi")
    
    # Roda otimização com λ=0 (neutro ao risco)
    println("\n⚡ Otimizando com λ = 0.0 (neutro ao risco)...")
    result = solve_cvar_model(0.0, config, data_teste, cache)
    
    # Verifica resultado
    println("\n" * "=" ^ 60)
    println("🎯 RESULTADO DO TESTE:")
    println("=" ^ 60)
    
    if result.status == "OPTIMAL"
        ganho = result.retorno_milhoes - bench_retorno
        println("✅ Status: OPTIMAL")
        println("   Retorno Otimizado: R\$ $(round(result.retorno_milhoes, digits=1)) Mi")
        println("   Ganho vs Benchmark: R\$ $(round(ganho, digits=1)) Mi")
        println("   Volume de Hedge: $(round(result.volume_hedge_mw, digits=1)) MW")
        
        if result.volume_hedge_mw > 0.1
            println("\n✅ TESTE PASSOU! O modelo está fazendo trades.")
            println("   Interpretação: Com preços vantajosos, o modelo aproveita as oportunidades.")
            return true
        else
            println("\n❌ TESTE FALHOU! O modelo NÃO está fazendo trades mesmo com preços vantajosos.")
            println("   Possível problema: Erro na formulação ou nos dados.")
            return false
        end
    else
        println("❌ TESTE FALHOU! Modelo não convergiu.")
        println("   Status: $(result.status)")
        return false
    end
end

# Roda o teste
teste_validacao()
