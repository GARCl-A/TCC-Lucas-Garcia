import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path

# Configuração
sns.set_style("whitegrid")
plt.rcParams['figure.figsize'] = (12, 8)
plt.rcParams['font.size'] = 11

# Carrega resultados
data_dir = Path(__file__).parent.parent.parent / "data" / "processed"
df = pd.read_csv(data_dir / "resultados_fronteira.csv")

# Remove benchmark (NaN) e λ ineficazes
df_opt = df[df['Lambda'].notna() & (df['Lambda'] >= 0.01)].copy()
benchmark = df[df['Lambda'].isna()].iloc[0]

# ========================================
# GRÁFICO 1: Fronteira Eficiente (CVaR vs Retorno)
# ========================================
fig, ax = plt.subplots(figsize=(10, 6))

# Pontos otimizados
ax.scatter(df_opt['CVaR_Lucro_Milhoes'], df_opt['Retorno_Milhoes'], 
           s=100, c=df_opt['Lambda'], cmap='viridis', 
           edgecolors='black', linewidth=1.5, zorder=3)

# Benchmark
ax.scatter(benchmark['CVaR_Lucro_Milhoes'], benchmark['Retorno_Milhoes'],
           s=200, c='red', marker='*', edgecolors='black', 
           linewidth=2, label='Benchmark (sem hedge)', zorder=4)

# Destaque λ=0.01
lambda_01 = df_opt[df_opt['Lambda'] == 0.01].iloc[0]
ax.scatter(lambda_01['CVaR_Lucro_Milhoes'], lambda_01['Retorno_Milhoes'],
           s=200, c='lime', marker='D', edgecolors='black',
           linewidth=2, label='λ=0.01 (recomendado)', zorder=5)

# Colorbar
cbar = plt.colorbar(ax.collections[0], ax=ax)
cbar.set_label('λ (peso do risco)', rotation=270, labelpad=20)

ax.set_xlabel('CVaR - Lucro nos 5% Piores Cenários (R$ Milhões)', fontsize=12, fontweight='bold')
ax.set_ylabel('Retorno Esperado (R$ Milhões)', fontsize=12, fontweight='bold')
ax.set_title('Fronteira Eficiente: Trade-off Risco-Retorno', fontsize=14, fontweight='bold')
ax.legend(loc='lower left', fontsize=10)
ax.grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig(data_dir / "grafico_fronteira_eficiente.png", dpi=300, bbox_inches='tight')
print("✅ Gráfico 1 salvo: grafico_fronteira_eficiente.png")

# ========================================
# GRÁFICO 2: Impacto do λ (3 subplots)
# ========================================
fig, axes = plt.subplots(3, 1, figsize=(10, 10))

# 2.1: λ vs Retorno
axes[0].plot(df_opt['Lambda'], df_opt['Retorno_Milhoes'], 
             marker='o', linewidth=2, markersize=8, color='steelblue')
axes[0].axhline(benchmark['Retorno_Milhoes'], color='red', 
                linestyle='--', linewidth=2, label='Benchmark')
axes[0].set_ylabel('Retorno Esperado\n(R$ Milhões)', fontsize=11, fontweight='bold')
axes[0].set_title('Impacto do Parâmetro λ nas Métricas', fontsize=13, fontweight='bold')
axes[0].legend()
axes[0].grid(True, alpha=0.3)

# 2.2: λ vs CVaR
axes[1].plot(df_opt['Lambda'], df_opt['CVaR_Lucro_Milhoes'], 
             marker='s', linewidth=2, markersize=8, color='green')
axes[1].axhline(benchmark['CVaR_Lucro_Milhoes'], color='red', 
                linestyle='--', linewidth=2, label='Benchmark')
axes[1].set_ylabel('CVaR - Lucro 5% Piores\n(R$ Milhões)', fontsize=11, fontweight='bold')
axes[1].legend()
axes[1].grid(True, alpha=0.3)

# 2.3: λ vs Volume Hedge
axes[2].plot(df_opt['Lambda'], df_opt['Volume_Hedge_MW'], 
             marker='^', linewidth=2, markersize=8, color='orange')
axes[2].set_xlabel('λ (peso do risco)', fontsize=12, fontweight='bold')
axes[2].set_ylabel('Volume Total de Hedge\n(MW)', fontsize=11, fontweight='bold')
axes[2].grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig(data_dir / "grafico_impacto_lambda.png", dpi=300, bbox_inches='tight')
print("✅ Gráfico 2 salvo: grafico_impacto_lambda.png")

# ========================================
# GRÁFICO 3: Tabela Resumo
# ========================================
fig, ax = plt.subplots(figsize=(12, 6))
ax.axis('tight')
ax.axis('off')

# Seleciona pontos chave
pontos_chave = df[df['Lambda'].isna() | df['Lambda'].isin([0.01, 0.02, 0.05, 0.1, 1.0])].copy()
pontos_chave['Lambda'] = pontos_chave['Lambda'].fillna('Benchmark')
pontos_chave['Retorno_Milhoes'] = pontos_chave['Retorno_Milhoes'].round(1)
pontos_chave['CVaR_Lucro_Milhoes'] = pontos_chave['CVaR_Lucro_Milhoes'].round(1)
pontos_chave['Volume_Hedge_MW'] = pontos_chave['Volume_Hedge_MW'].round(0)
pontos_chave['Tempo_Segundos'] = pontos_chave['Tempo_Segundos'].round(2)

# Calcula ganhos vs benchmark
pontos_chave['Δ Retorno'] = (pontos_chave['Retorno_Milhoes'] - benchmark['Retorno_Milhoes']).round(1)
pontos_chave['Δ CVaR'] = (pontos_chave['CVaR_Lucro_Milhoes'] - benchmark['CVaR_Lucro_Milhoes']).round(1)

table_data = pontos_chave[['Lambda', 'Retorno_Milhoes', 'Δ Retorno', 
                            'CVaR_Lucro_Milhoes', 'Δ CVaR', 
                            'Volume_Hedge_MW', 'Tempo_Segundos']].values

table = ax.table(cellText=table_data,
                colLabels=['λ', 'Retorno\n(R$ Mi)', 'Δ Retorno\n(R$ Mi)', 
                          'CVaR\n(R$ Mi)', 'Δ CVaR\n(R$ Mi)', 
                          'Hedge\n(MW)', 'Tempo\n(s)'],
                cellLoc='center',
                loc='center',
                bbox=[0, 0, 1, 1])

table.auto_set_font_size(False)
table.set_fontsize(10)
table.scale(1, 2)

# Destaca header
for i in range(7):
    table[(0, i)].set_facecolor('#4472C4')
    table[(0, i)].set_text_props(weight='bold', color='white')

# Destaca benchmark e λ=0.01
table[(1, 0)].set_facecolor('#FFE699')  # Benchmark
table[(2, 0)].set_facecolor('#C6E0B4')  # λ=0.01

plt.title('Resumo dos Resultados da Fronteira Eficiente', 
          fontsize=14, fontweight='bold', pad=20)
plt.savefig(data_dir / "tabela_resumo.png", dpi=300, bbox_inches='tight')
print("✅ Gráfico 3 salvo: tabela_resumo.png")

print("\n📊 Visualizações geradas com sucesso!")
print(f"   Arquivos salvos em: {data_dir}")
