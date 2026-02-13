# teste_cvar_formulacoes.jl
using JuMP, HiGHS

println("🧪 TESTE: Comparação de Formulações CVaR\n")
println("="^60)

# Dados toy: 3 cenários simples
lucros_base = [100.0, 50.0, -20.0]  # Lucro sem fazer nada
prob = 1/3
α = 0.95
λ = 0.5

# Oportunidade de trade: comprar a 30 (custo) para reduzir exposição
custo_trade = 30.0
limite_trade = 10.0  # Limite de volume

println("📊 Dados do teste:")
println("   Lucros base: $lucros_base")
println("   Retorno esperado base: $(sum(lucros_base) * prob)")
println("   Trade disponível: custo=$custo_trade, limite=$limite_trade")
println("   α = $α, λ = $λ\n")

# ============================================
# FORMULAÇÃO 1: ATUAL (VaR - lucro)
# ============================================
println("🔴 FORMULAÇÃO 1 (ATUAL): ξ >= VaR - R")
println("-"^60)

m1 = Model(HiGHS.Optimizer)
set_silent(m1)

@variable(m1, VaR1)
@variable(m1, ξ1[1:3] >= 0)
@variable(m1, 0 <= q1 <= limite_trade)  # Volume do trade (LIMITADO)

# Lucro = lucro_base - custo_trade * volume
@expression(m1, R1[i=1:3], lucros_base[i] - custo_trade * q1)

# Restrição CVaR: ξ >= VaR - R (ATUAL)
@constraint(m1, [i=1:3], ξ1[i] >= VaR1 - R1[i])

@expression(m1, Retorno1, sum(R1[i] for i=1:3) * prob)
@expression(m1, CVaR1, VaR1 + (1/(1-α)) * sum(prob * ξ1[i] for i=1:3))
@objective(m1, Max, Retorno1 - λ * CVaR1)

optimize!(m1)

if termination_status(m1) == MOI.OPTIMAL
    println("✅ Status: OPTIMAL")
    println("   VaR = $(round(value(VaR1), digits=2))")
    println("   CVaR = $(round(value(CVaR1), digits=2))")
    println("   Retorno = $(round(value(Retorno1), digits=2))")
    println("   Objetivo = $(round(objective_value(m1), digits=2))")
    println("   Volume trade = $(round(value(q1), digits=2))")
    println("   ξ = [$(round(value(ξ1[1]), digits=2)), $(round(value(ξ1[2]), digits=2)), $(round(value(ξ1[3]), digits=2))]")
else
    println("❌ Status: $(termination_status(m1))")
end

# ============================================
# FORMULAÇÃO 2: CORRIGIDA (-lucro - VaR)
# ============================================
println("\n🟢 FORMULAÇÃO 2 (CORRIGIDA): ξ >= -R - VaR")
println("-"^60)

m2 = Model(HiGHS.Optimizer)
set_silent(m2)

@variable(m2, VaR2)
@variable(m2, ξ2[1:3] >= 0)
@variable(m2, 0 <= q2 <= limite_trade)  # Volume do trade (LIMITADO)

# Lucro = lucro_base - custo_trade * volume
@expression(m2, R2[i=1:3], lucros_base[i] - custo_trade * q2)

# Restrição CVaR: ξ >= -R - VaR (CORRIGIDA)
@constraint(m2, [i=1:3], ξ2[i] >= -R2[i] - VaR2)

@expression(m2, Retorno2, sum(R2[i] for i=1:3) * prob)
@expression(m2, CVaR2, VaR2 + (1/(1-α)) * sum(prob * ξ2[i] for i=1:3))
@objective(m2, Max, Retorno2 - λ * CVaR2)

optimize!(m2)

if termination_status(m2) == MOI.OPTIMAL
    println("✅ Status: OPTIMAL")
    println("   VaR = $(round(value(VaR2), digits=2))")
    println("   CVaR = $(round(value(CVaR2), digits=2))")
    println("   Retorno = $(round(value(Retorno2), digits=2))")
    println("   Objetivo = $(round(objective_value(m2), digits=2))")
    println("   Volume trade = $(round(value(q2), digits=2))")
    println("   ξ = [$(round(value(ξ2[1]), digits=2)), $(round(value(ξ2[2]), digits=2)), $(round(value(ξ2[3]), digits=2))]")
else
    println("❌ Status: $(termination_status(m2))")
end

# ============================================
# ANÁLISE
# ============================================
println("\n" * "="^60)
println("📊 ANÁLISE:")
println("="^60)

if termination_status(m1) == MOI.OPTIMAL && termination_status(m2) == MOI.OPTIMAL
    println("⚠️  Ambas convergiram - mas qual está correta?")
    println("\n   Interpretação esperada:")
    println("   - CVaR deve AUMENTAR quando lucro DIMINUI")
    println("   - ξ deve ser MAIOR nos cenários RUINS (lucro baixo/negativo)")
    
    println("\n   Formulação 1:")
    println("   - Cenário 1 (lucro=100): ξ=$(round(value(ξ1[1]), digits=2))")
    println("   - Cenário 2 (lucro=50):  ξ=$(round(value(ξ1[2]), digits=2))")
    println("   - Cenário 3 (lucro=-20): ξ=$(round(value(ξ1[3]), digits=2))")
    
    println("\n   Formulação 2:")
    println("   - Cenário 1 (lucro=100): ξ=$(round(value(ξ2[1]), digits=2))")
    println("   - Cenário 2 (lucro=50):  ξ=$(round(value(ξ2[2]), digits=2))")
    println("   - Cenário 3 (lucro=-20): ξ=$(round(value(ξ2[3]), digits=2))")
    
    # Verifica qual penaliza corretamente
    if value(ξ2[3]) > value(ξ2[1])
        println("\n✅ FORMULAÇÃO 2 está CORRETA!")
        println("   Penaliza mais o cenário ruim (lucro=-20)")
    else
        println("\n❌ FORMULAÇÃO 2 pode estar ERRADA!")
    end
    
    if value(ξ1[3]) > value(ξ1[1])
        println("✅ FORMULAÇÃO 1 também parece correta?")
    else
        println("❌ FORMULAÇÃO 1 está ERRADA!")
        println("   Penaliza mais o cenário bom (lucro=100)")
    end
    
elseif termination_status(m1) != MOI.OPTIMAL && termination_status(m2) == MOI.OPTIMAL
    println("✅ FORMULAÇÃO 2 está CORRETA!")
    println("   Formulação 1 falhou (ilimitada)")
    println("   Formulação 2 convergiu normalmente")
elseif termination_status(m1) == MOI.OPTIMAL && termination_status(m2) != MOI.OPTIMAL
    println("⚠️  FORMULAÇÃO 1 pode estar INCORRETA!")
    println("   Formulação 1 convergiu mas pode estar penalizando errado")
    println("   Formulação 2 falhou inesperadamente")
else
    println("❌ Ambas falharam - problema nos dados de teste")
end
