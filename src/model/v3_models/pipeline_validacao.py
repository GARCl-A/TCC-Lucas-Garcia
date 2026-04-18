"""
Pipeline de Validação da Política Ótima — DEQ vs SDDP
======================================================
Uso:
    python pipeline_validacao.py

Etapas:
    1. (Opcional) Chama os scripts Julia via subprocess
    2. Lê as decisões do nó raiz de cada algoritmo
    3. Testa convergência (diferença absoluta < 1e-3)
    4. Gera gráfico de barras lado a lado com qualidade de publicação
"""

import subprocess
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from pathlib import Path

# ============================================================
# AJUSTE: caminhos dos arquivos de entrada e saída
# ============================================================
# Raiz do projeto (dois níveis acima deste script)
ROOT = Path(__file__).resolve().parents[3]

# CSVs com as decisões do nó raiz (gerados pelos scripts Julia)
# Se você usar os arquivos completos já existentes, ajuste para:
#   DEQ_CSV  = ROOT / "data" / "results" / "deq_decisoes.csv"
#   SDDP_CSV = ROOT / "data" / "results" / "sddp_decisoes.csv"
DEQ_CSV  = ROOT / "data" / "results" / "deq_decisoes_raiz.csv"
SDDP_CSV = ROOT / "data" / "results" / "sddp_decisoes_raiz.csv"

# Figura de saída
FIG_OUT = ROOT / "data" / "results" / "05_politica_otima_raiz.png"

# ============================================================
# AJUSTE: parâmetros da instância para chamar os scripts Julia
# ============================================================
NUM_MESES  = 6    # X meses
NUM_RAMOS  = 10   # Y ramos por estágio

# AJUSTE: caminhos dos scripts Julia
JULIA_DEQ  = ROOT / "src" / "model" / "v3_models" / "deq.jl"
JULIA_SDDP = ROOT / "src" / "model" / "v3_models" / "sddp.jl"


# ============================================================
# 1. (OPCIONAL) Execução dos scripts Julia
# ============================================================
def rodar_julia(script: Path, num_meses: int, num_ramos: int) -> None:
    """Chama `julia <script> <num_meses> <num_ramos>` no terminal."""
    cmd = ["julia", str(script), str(num_meses), str(num_ramos)]
    print(f"Executando: {' '.join(cmd)}")
    resultado = subprocess.run(cmd, capture_output=False, text=True)
    if resultado.returncode != 0:
        raise RuntimeError(f"Julia falhou com código {resultado.returncode}")
    print("Julia concluído.\n")


# ============================================================
# 2. Leitura dos CSVs do nó raiz
# ============================================================
def carregar_decisoes_raiz(csv_path: Path, label: str) -> pd.DataFrame:
    """
    Lê o CSV e extrai as decisões do nó raiz (estágio 1).

    Para o formato completo (todos os nós/simulações), filtra
    automaticamente o estágio 1. Para o formato reduzido
    (apenas nó raiz), usa diretamente.
    """
    df = pd.read_csv(csv_path)

    # Formato completo do DEQ: filtra pelo menor nó do estágio 1
    if "no" in df.columns and "no_pai" in df.columns:
        no_raiz = df.loc[df["no_pai"] == 1, "no"].min()
        df = df[df["no"] == no_raiz][["ticker", "compra_mwm", "venda_mwm"]].copy()

    # Formato completo do SDDP: filtra estagio == 1, simulacao == 1
    elif "estagio" in df.columns and "simulacao" in df.columns:
        df = df[(df["estagio"] == 1) & (df["simulacao"] == 1)][
            ["ticker", "compra_mwm", "venda_mwm"]
        ].copy()

    # Formato reduzido (já contém apenas nó raiz): usa direto
    # colunas esperadas: ticker, compra_mwm, venda_mwm

    df = df.groupby("ticker", as_index=False)[["compra_mwm", "venda_mwm"]].first()
    df.columns = ["ticker", f"compra_{label}", f"venda_{label}"]
    return df


# ============================================================
# 3. Teste de convergência
# ============================================================
def testar_convergencia(df: pd.DataFrame, tol: float = 1e-3) -> None:
    """
    Verifica se |compra_DEQ - compra_SDDP| < tol e
                |venda_DEQ  - venda_SDDP|  < tol para cada ticker.
    Lança AssertionError se algum contrato divergir.
    """
    diff_compra = np.abs(df["compra_DEQ"] - df["compra_SDDP"])
    diff_venda  = np.abs(df["venda_DEQ"]  - df["venda_SDDP"])

    divergentes = df[~(np.isclose(diff_compra, 0, atol=tol) &
                       np.isclose(diff_venda,  0, atol=tol))]

    if not divergentes.empty:
        print("\n⚠️  Contratos com divergência acima da tolerância:")
        print(divergentes[["ticker", "compra_DEQ", "compra_SDDP",
                            "venda_DEQ", "venda_SDDP"]].to_string(index=False))
        raise AssertionError(
            f"{len(divergentes)} contrato(s) divergem além de tol={tol} MWm."
        )

    max_diff = max(diff_compra.max(), diff_venda.max())
    print(f"✅  Convergência validada! Diferença máxima: {max_diff:.2e} MWm "
          f"(tolerância: {tol:.0e})\n")


# ============================================================
# 4. Cálculo da posição líquida e geração do gráfico
# ============================================================
def gerar_grafico(df: pd.DataFrame, fig_path: Path) -> None:
    """
    Gráfico de barras lado a lado: Posição Líquida DEQ vs SDDP.
    Posição Líquida = compra_mwm - venda_mwm (positivo = comprado líquido).
    """
    df = df.copy()
    df["pos_DEQ"]  = df["compra_DEQ"]  - df["venda_DEQ"]
    df["pos_SDDP"] = df["compra_SDDP"] - df["venda_SDDP"]
    df = df.sort_values("ticker")

    tickers = df["ticker"].tolist()
    n = len(tickers)
    x = np.arange(n)
    largura = 0.35

    # --- Estilo de publicação ---
    plt.rcParams.update({
        "font.family":  "serif",
        "font.size":    10,
        "axes.spines.top":   False,
        "axes.spines.right": False,
    })

    fig, ax = plt.subplots(figsize=(max(8, n * 0.55), 5))
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")

    barras_deq  = ax.bar(x - largura / 2, df["pos_DEQ"],  largura,
                         label="DEQ",  color="#2166ac", alpha=0.85, zorder=3)
    barras_sddp = ax.bar(x + largura / 2, df["pos_SDDP"], largura,
                         label="SDDP", color="#d6604d", alpha=0.85, zorder=3)

    ax.axhline(0, color="black", linewidth=0.8, zorder=2)
    ax.yaxis.grid(True, linestyle="--", linewidth=0.5, alpha=0.6, zorder=1)
    ax.set_axisbelow(True)

    ax.set_xticks(x)
    ax.set_xticklabels(tickers, rotation=45, ha="right", fontsize=8)
    ax.set_xlabel("Contrato (Ticker)", fontsize=11, labelpad=8)
    ax.set_ylabel("Posição Líquida (MWm)", fontsize=11, labelpad=8)
    ax.set_title("Política Ótima no Nó Raiz — DEQ vs SDDP",
                 fontsize=13, fontweight="bold", pad=12)
    ax.legend(frameon=False, fontsize=10)
    ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%.1f"))

    fig.tight_layout()
    fig_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(fig_path, dpi=300, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"📊 Figura salva em: {fig_path}")


# ============================================================
# Main
# ============================================================
def main(executar_julia: bool = False) -> None:
    # --- (Opcional) Rodar os modelos Julia ---
    if executar_julia:
        rodar_julia(JULIA_DEQ,  NUM_MESES, NUM_RAMOS)
        rodar_julia(JULIA_SDDP, NUM_MESES, NUM_RAMOS)

    # --- Carregar decisões do nó raiz ---
    print(f"Lendo DEQ:  {DEQ_CSV}")
    print(f"Lendo SDDP: {SDDP_CSV}\n")
    df_deq  = carregar_decisoes_raiz(DEQ_CSV,  "DEQ")
    df_sddp = carregar_decisoes_raiz(SDDP_CSV, "SDDP")

    # Merge por ticker
    df = pd.merge(df_deq, df_sddp, on="ticker", how="inner")
    if df.empty:
        raise ValueError("Nenhum ticker em comum entre DEQ e SDDP no estágio 1.")
    print(f"Contratos no estágio 1: {len(df)}\n")

    # --- Teste de convergência ---
    testar_convergencia(df, tol=1e-3)

    # --- Gráfico ---
    gerar_grafico(df, FIG_OUT)


if __name__ == "__main__":
    # Mude para True se quiser disparar os scripts Julia automaticamente
    main(executar_julia=False)
