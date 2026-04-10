import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path

# Configuração de caminhos
BASE_DIR = Path(__file__).parent.parent.parent.parent / "data" / "results"
ARQUIVO_DEQ = BASE_DIR / "stress_test_deq_keep.csv"
ARQUIVO_SDDP = BASE_DIR / "benchmark_sddp.csv"

# Carregando os dados e IGNORANDO as linhas de comentário (#)
df_deq = pd.read_csv(ARQUIVO_DEQ, comment="#")
df_sddp = pd.read_csv(ARQUIVO_SDDP, comment="#")

# Remove espaços em branco dos nomes das colunas por precaução
df_deq.columns = df_deq.columns.str.strip()
df_sddp.columns = df_sddp.columns.str.strip()

# --- BLOCO DO DEQ ---
# Se a coluna status existir, nós filtramos
if "status" in df_deq.columns:
    df_deq = df_deq[df_deq["status"] == "OPTIMAL"]

# Seleciona as colunas e renomeia
df_deq = df_deq[["ramos", "meses", "nos", "t_otimizacao_s"]]
df_deq.rename(columns={"t_otimizacao_s": "tempo_deq"}, inplace=True)

# --- BLOCO DO SDDP ---
# Seleciona as colunas do SDDP e renomeia
if "status" in df_sddp.columns:
    df_sddp = df_sddp[df_sddp["status"] == "OPTIMAL_SDDP"]

df_sddp = df_sddp[["ramos", "meses", "t_otimizacao_s"]]
df_sddp.rename(columns={"t_otimizacao_s": "tempo_sddp"}, inplace=True)

# --- MERGE E PLOTAGEM ---
# Juntando os dois DataFrames baseados no cenário (ramos e meses)
df_comp = pd.merge(df_deq, df_sddp, on=["ramos", "meses"])
df_comp = df_comp.sort_values(by="nos")  # Ordena do menor pro maior (Nós)

# Criando um rótulo bonito pro eixo X (Ex: "R=4, T=8\n(87k nós)")
df_comp["label"] = df_comp.apply(
    lambda x: f"R={int(x['ramos'])}, T={int(x['meses'])}\n({int(x['nos']/1000)}k nós)",
    axis=1,
)

# ==========================================
# PLOTANDO O GRÁFICO MATADOR
# ==========================================
sns.set_theme(style="whitegrid")
plt.rcParams.update({"font.size": 12})

fig, ax = plt.subplots(figsize=(12, 6))

# Plotando as duas linhas
ax.plot(
    df_comp["label"],
    df_comp["tempo_deq"],
    marker="o",
    linewidth=3,
    markersize=8,
    color="#e74c3c",
    label="DEQ (Matriz Completa)",
)
ax.plot(
    df_comp["label"],
    df_comp["tempo_sddp"],
    marker="s",
    linewidth=3,
    markersize=8,
    color="#3498db",
    label="SDDP (Decomposição)",
)

# Preenchendo a área entre as linhas para destacar o "Tempo Salvo"
ax.fill_between(
    df_comp["label"],
    df_comp["tempo_sddp"],
    df_comp["tempo_deq"],
    color="#e74c3c",
    alpha=0.1,
)

ax.set_title(
    "Comparação de Esforço Computacional: DEQ vs SDDP", fontsize=16, fontweight="bold"
)
ax.set_xlabel("Instância do Problema (Tamanho do Horizonte e Ramificações)")
ax.set_ylabel("Tempo de Otimização do Solver (Segundos)")
ax.legend(fontsize=12)

# Ajuste visual do Eixo X
plt.xticks(rotation=45)
plt.tight_layout()

# Salvando a imagem
CAMINHO_SAIDA = Path(__file__).parent / "output" / "04_comparacao_deq_sddp.png"
CAMINHO_SAIDA.parent.mkdir(
    parents=True, exist_ok=True
)  # Garante que a pasta output existe
plt.savefig(CAMINHO_SAIDA, dpi=300)
print(f"Gráfico salvo com sucesso em: {CAMINHO_SAIDA}")
plt.show()
