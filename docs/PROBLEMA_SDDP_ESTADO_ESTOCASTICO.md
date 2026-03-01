# Problema: Transição de Estado Estocástica em SDDP.jl

## Resumo do Problema

**Objetivo**: Modelar fluxo de caixa acumulado em otimização estocástica multi-estágio com limite de crédito (ruína).

**Limitação Encontrada**: SDDP.jl não suporta variáveis de estado com transições estocásticas usando restrições de igualdade.

---

## Formulação Matemática Desejada

### Variáveis de Estado
- `caixa_t`: saldo de caixa acumulado no estágio t (milhões R$)

### Dinâmica de Estado (ESTOCÁSTICA)
```
caixa_{t+1} = caixa_t + lucro_t(ω_t)
```

Onde:
- `lucro_t(ω_t)` depende do cenário estocástico ω_t (PLD e geração)
- `ω_t` tem múltiplas realizações (ex: 10-2000 cenários por estágio)

### Restrições
```
caixa_t ≥ -100  (limite de crédito / ruína)
caixa_0 = 0     (condição inicial)
```

### Objetivo
```
max E[Σ_{t=1}^{60} lucro_t(ω_t)]  sujeito a CVaR
```

---

## Loop de Erros no SDDP.jl

### Tentativa 1: Restrição de Igualdade Dentro do `parameterize`
```julia
@variable(sp, caixa, SDDP.State, initial_value=0.0)

SDDP.parameterize(sp, cenarios) do ω
    lucro = calcular_lucro(ω)  # Expressão estocástica
    @constraint(sp, caixa.out == caixa.in + lucro)
    @stageobjective(sp, lucro)
end
```

**Erro**: `INFEASIBLE`

**Causa**: Para N cenários, cria N restrições de igualdade:
```
caixa.out == caixa.in + lucro(ω_1)
caixa.out == caixa.in + lucro(ω_2)
...
caixa.out == caixa.in + lucro(ω_N)
```
Sistema sobredeterminado → impossível satisfazer simultaneamente.

---

### Tentativa 2: Variável Auxiliar Fora do `parameterize`
```julia
@variable(sp, caixa, SDDP.State, initial_value=0.0)
@variable(sp, lucro_aux)

@constraint(sp, caixa.out == caixa.in + lucro_aux)

SDDP.parameterize(sp, cenarios) do ω
    lucro = calcular_lucro(ω)
    @constraint(sp, lucro_aux == lucro)
    @stageobjective(sp, lucro)
end
```

**Erro**: `INFEASIBLE`

**Causa**: Mesmo problema - N restrições conflitantes para `lucro_aux`.

---

### Tentativa 3: Usar `JuMP.fix()`
```julia
SDDP.parameterize(sp, cenarios) do ω
    lucro = calcular_lucro(ω)
    JuMP.fix(caixa.out, caixa.in + JuMP.value(lucro); force=true)
end
```

**Erro**: `OptimizeNotCalled()` - não pode chamar `value()` antes de otimizar.

**Causa**: `lucro` é uma expressão não resolvida, não tem valor numérico.

---

### Tentativa 4: Restrição Fora do `parameterize`
```julia
@variable(sp, caixa, SDDP.State, initial_value=0.0)
@constraint(sp, caixa.out == caixa.in + lucro_trades)  # Fora do parameterize

SDDP.parameterize(sp, cenarios) do ω
    lucro_pld = lucro_trades + exposicao * ω.pld
    @stageobjective(sp, lucro_pld)
end
```

**Problema**: `lucro_pld` depende de `ω` (estocástico), mas `caixa.out` é fixado antes de conhecer `ω`.

**Resultado**: Modelo roda mas **não conecta estágios corretamente** - decisões são míopes.

---

## Por Que SDDP.jl Não Suporta Isso?

### Arquitetura do SDDP
1. **Decomposição de Benders**: Separa problema em subproblemas por estágio
2. **Variáveis de Estado**: Devem ter transições **determinísticas** ou **afins**
3. **Estocasticidade**: Entra via `parameterize` que cria **múltiplas instâncias** do subproblema

### Conflito Fundamental
- Variável de estado `x_{t+1}` deve ser **única** (conecta estágios)
- Transição estocástica `x_{t+1} = f(x_t, ω)` requer **múltiplos valores** (um por cenário)
- Impossível ter uma variável com múltiplos valores simultâneos

---

## Solução Atual (Workaround)

### Remover Variável de Estado de Caixa
```julia
# SEM variável de estado caixa
@variable(sp, volume_compra[...])
@variable(sp, volume_venda[...])

SDDP.parameterize(sp, cenarios) do ω
    lucro = calcular_lucro(ω, volume_compra, volume_venda)
    @stageobjective(sp, lucro)
end
```

### O Que Funciona
✅ Maximiza `E[Σ lucro_t]` = maximiza `E[caixa_final]` (equivalente matemático)
✅ Benders cuts conectam estágios via função de valor futuro
✅ CVaR aplicado corretamente

### O Que NÃO Funciona
❌ Não rastreia `caixa_t` explicitamente em cada estágio
❌ Não pode impor `caixa_t ≥ -100` (limite de crédito)
❌ Decisões não consideram risco de ruína intermediária

---

## Alternativas a Pesquisar

### 1. Scenario Tree Approach (Árvore de Cenários)
- Modelar explicitamente árvore de cenários completa
- Cada nó = (estágio, cenário)
- Variáveis de caixa por nó
- **Problema**: Explosão combinatória (2000^60 cenários)

**Bibliotecas**:
- `JuMP.jl` com formulação manual
- `StochOptFormat.jl`

---

### 2. Chance Constraints (Restrições Probabilísticas)
- Substituir `caixa_t ≥ -100` por `P(caixa_t ≥ -100) ≥ 0.95`
- Aproximações via CVaR ou SAA (Sample Average Approximation)

**Bibliotecas**:
- `InfiniteOpt.jl`
- `JuMP.jl` com reformulações manuais

---

### 3. Markov Decision Process (MDP) com Discretização
- Discretizar espaço de estados de caixa (ex: bins de 10M)
- Usar programação dinâmica estocástica
- **Problema**: Maldição da dimensionalidade

**Bibliotecas**:
- `POMDPs.jl`
- `DiscreteValueIteration.jl`

---

### 4. Stochastic Dual Dynamic Programming Modificado
- Implementar SDDP customizado com estados estocásticos
- Usar técnicas de "post-decision state" ou "pre-decision state"

**Referências**:
- Powell, W. B. (2011). "Approximate Dynamic Programming"
- Shapiro et al. (2014). "Lectures on Stochastic Programming"

---

### 5. Robust Optimization (Otimização Robusta)
- Modelar incerteza via conjuntos de incerteza
- Garantir viabilidade para pior caso

**Bibliotecas**:
- `JuMPeR.jl` (descontinuado)
- `JuMP.jl` com reformulações manuais

---

### 6. Multi-Stage Stochastic Programming (Formulação Completa)
- Resolver problema completo sem decomposição
- Usar solvers especializados

**Solvers**:
- `FortSP`
- `DECIS`
- `MSLiP`

**Problema**: Escalabilidade limitada (60 estágios × 2000 cenários é grande)

---

## Termos-Chave para Pesquisa

1. **"Stochastic state transition SDDP"**
2. **"Post-decision state variable"**
3. **"Markovian state space approximation"**
4. **"Multi-stage stochastic programming with state-dependent uncertainty"**
5. **"Risk-averse dynamic programming"**
6. **"Credit constraint in stochastic optimization"**
7. **"Relatively complete recourse violation"**

---

## Questão Fundamental

**O problema é NP-hard?**

Sim, quando:
- Estados dependem de realizações estocásticas passadas (não-Markoviano)
- Espaço de estados é contínuo e multidimensional
- Número de cenários cresce exponencialmente

**Abordagens práticas**:
- Aproximações (discretização, agregação)
- Heurísticas (rolling horizon, scenario reduction)
- Relaxações (remover restrições de estado, penalizar violações)

---

## Recomendação

Para TCC, considere:

1. **Curto prazo**: Aceitar limitação atual, documentar como limitação conhecida
2. **Médio prazo**: Implementar post-processing para filtrar trajetórias que violam crédito
3. **Longo prazo**: Explorar MDP discretizado ou scenario tree com redução de cenários

**Trade-off**: Realismo vs. Tratabilidade Computacional
