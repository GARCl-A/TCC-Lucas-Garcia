import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
from pathlib import Path

OUTPUT_DIR = Path(__file__).parent / "output"
OUTPUT_DIR.mkdir(exist_ok=True)

sns.set_theme(style="whitegrid")
plt.rcParams.update({"font.size": 12})


def carregar_dados(caminho: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    df = pd.read_csv(caminho, comment="#")
    df_limpo = df[df["status"] != "EM_ANDAMENTO"].copy()

    colunas_tempo = ["t_arvore_s", "t_mercado_s", "t_modelo_s", "t_otimizacao_s", "t_extracao_s", "tempo_total_s"]
    for col in colunas_tempo:
        df_limpo[col] = pd.to_numeric(df_limpo[col], errors="coerce")

    df_limpo["timestamp"] = pd.to_datetime(df_limpo["timestamp"], format="%d/%m/%Y %H:%M:%S")

    print(f"Dados limpos! Reduzido de {len(df)} para {len(df_limpo)} linhas.")

    df_sucesso = df_limpo[df_limpo["status"] == "OPTIMAL"].copy()
    return df_limpo, df_sucesso


def grafico_crescimento_arvore(df_limpo: pd.DataFrame):
    fig, ax = plt.subplots(figsize=(10, 6))
    sns.lineplot(
        data=df_limpo, x="meses", y="nos", hue="ramos",
        marker="o", linewidth=2.5, palette="viridis", ax=ax,
    )
    ax.set_yscale("log")
    ax.set_title("Crescimento da Árvore de Cenários (Escala Log)", fontsize=14, fontweight="bold")
    ax.set_xlabel("Horizonte de Planejamento (Meses)")
    ax.set_ylabel("Total de Nós na Árvore")
    ax.legend(title="Cenários/Mês (R)")
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "01_crescimento_arvore.png", dpi=150)
    plt.close()
    print("Salvo: 01_crescimento_arvore.png")


def grafico_otimizacao_vs_nos_loglog(df_sucesso: pd.DataFrame):
    fig, ax = plt.subplots(figsize=(10, 6))
    sns.scatterplot(
        data=df_sucesso, x="nos", y="t_otimizacao_s", hue="ramos",
        s=120, palette="magma", ax=ax,
    )
    for ramo, grupo in df_sucesso.groupby("ramos"):
        grupo_ord = grupo.sort_values("nos")
        ax.plot(grupo_ord["nos"], grupo_ord["t_otimizacao_s"], alpha=0.4, linewidth=1)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_title("Tempo de Otimização vs Nós (escala log-log)", fontsize=14, fontweight="bold")
    ax.set_xlabel("Total de Nós (log)")
    ax.set_ylabel("Tempo do Solver em segundos (log)")
    ax.legend(title="Ramos")
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "02_otimizacao_vs_nos_loglog.png", dpi=150)
    plt.close()
    print("Salvo: 02_otimizacao_vs_nos_loglog.png")


def grafico_otimizacao_vs_nos_linear(df_sucesso: pd.DataFrame):
    fig, ax = plt.subplots(figsize=(10, 6))
    df_ord = df_sucesso.sort_values(["ramos", "nos"])
    sns.scatterplot(
        data=df_ord, x="nos", y="t_otimizacao_s", hue="ramos",
        s=120, palette="magma", ax=ax,
    )
    for ramo, grupo in df_ord.groupby("ramos"):
        grupo_ord = grupo.sort_values("nos")
        ax.plot(grupo_ord["nos"], grupo_ord["t_otimizacao_s"], alpha=0.4, linewidth=1)

    ax.set_title("Tempo de Otimização vs Nós (escala linear)", fontsize=14, fontweight="bold")
    ax.set_xlabel("Total de Nós")
    ax.set_ylabel("Tempo do Solver (Segundos)")
    ax.legend(title="Ramos")
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "02b_otimizacao_vs_nos_linear.png", dpi=150)
    plt.close()
    print("Salvo: 02b_otimizacao_vs_nos_linear.png")


def grafico_otimizacao_linear_log_duplo(df_sucesso: pd.DataFrame):
    df_ord = df_sucesso.sort_values(["ramos", "nos"])
    fig, axes = plt.subplots(1, 2, figsize=(16, 6))

    for ax, log, titulo, ylabel, marker in [
        (axes[0], False, "Tempo de Otimização vs Nós (Escala Linear)", "Tempo do Solver (Segundos)", "o"),
        (axes[1], True,  "Tempo de Otimização vs Nós (Escala Logarítmica)", "Tempo do Solver (Segundos - Escala LOG)", "s"),
    ]:
        sns.lineplot(
            data=df_ord, x="nos", y="t_otimizacao_s", hue="ramos",
            palette="magma", marker=marker, markersize=8, linewidth=2.5, ax=ax,
        )
        if log:
            ax.set_yscale("log")
        ax.set_title(titulo, fontsize=14, fontweight="bold")
        ax.set_xlabel("Total de Nós na Árvore")
        ax.set_ylabel(ylabel)
        ax.grid(True, linestyle="--", alpha=0.7)
        ax.legend(title="Ramos")

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "02c_otimizacao_linear_log_duplo.png", dpi=150)
    plt.close()
    print("Salvo: 02c_otimizacao_linear_log_duplo.png")


def grafico_perfil_tempo(df_sucesso: pd.DataFrame):
    idx_maiores = df_sucesso.groupby("ramos")["nos"].idxmax()
    df_maiores = df_sucesso.loc[idx_maiores].sort_values("nos")

    fig, ax = plt.subplots(figsize=(10, 6))
    indices = np.arange(len(df_maiores))
    largura = 0.5

    ax.bar(indices, df_maiores["t_modelo_s"], largura, label="Montagem do modelo", color="#3498db")
    ax.bar(indices, df_maiores["t_otimizacao_s"], largura, bottom=df_maiores["t_modelo_s"], label="Otimização (HiGHS)", color="#e74c3c")

    ax.set_title("Divisão do Tempo Computacional (Casos Críticos por R)", fontsize=14, fontweight="bold")
    ax.set_xticks(indices)
    ax.set_xticklabels([f"R={r}\n({n} nós)" for r, n in zip(df_maiores["ramos"], df_maiores["nos"])])
    ax.set_ylabel("Tempo Total (Segundos)")
    ax.legend()
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "03_perfil_tempo.png", dpi=150)
    plt.close()
    print("Salvo: 03_perfil_tempo.png")


def exportar_dados(df_limpo: pd.DataFrame):
    caminho = OUTPUT_DIR / "stress_test_deq_LIMPO.csv"
    df_limpo.to_csv(caminho, index=False)
    print(f"Exportado: {caminho}")


if __name__ == "__main__":
    df_limpo, df_sucesso = carregar_dados("data\\results\\stress_test_deq_keep.csv")
    grafico_crescimento_arvore(df_limpo)
    grafico_otimizacao_vs_nos_loglog(df_sucesso)
    grafico_otimizacao_vs_nos_linear(df_sucesso)
    grafico_otimizacao_linear_log_duplo(df_sucesso)
    grafico_perfil_tempo(df_sucesso)
    exportar_dados(df_limpo)
