"""
Pipeline de Validação da Política Ótima — DEQ vs SDDP
======================================================
Pré-requisito: rodar primeiro o script Julia:
    julia rodar_pipeline.jl <num_meses> <num_ramos>

Este script:
    1. Lê deq_decisoes_raiz.csv e sddp_decisoes_raiz.csv
    2. Testa convergência (diferença absoluta < 1e-3 MWm)
    3. Gera gráfico de barras lado a lado com qualidade de publicação
       → salvo em data/results/05_politica_otima_raiz.png
"""

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from pathlib import Path

# ── Caminhos ────────────────────────────────────────────────────────────────
ROOT     = Path(__file__).resolve().parents[3]
RESULTS  = ROOT / "data" / "results"
DEQ_CSV  = RESULTS / "deq_decisoes_raiz.csv"
SDDP_CSV = RESULTS / "sddp_decisoes_raiz.csv"
FIG_OUT  = RESULTS / "05_politica_otima_raiz.png"


# ── 1. Leitura ───────────────────────────────────────────────────────────────
def carregar(csv_path: Path, sufixo: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    # Colunas esperadas: ticker, compra_mwm, venda_mwm
    df = df.rename(columns={"compra_mwm": f"compra_{sufixo}",
                             "venda_mwm":  f"venda_{sufixo}"})
    return df[["ticker", f"compra_{sufixo}", f"venda_{sufixo}"]]


# ── 2. Teste de convergência ─────────────────────────────────────────────────
def testar_convergencia(df: pd.DataFrame, tol: float = 1e-3) -> None:
    diff_c = np.abs(df["compra_DEQ"] - df["compra_SDDP"])
    diff_v = np.abs(df["venda_DEQ"]  - df["venda_SDDP"])
    divergentes = df[~(np.isclose(diff_c, 0, atol=tol) &
                       np.isclose(diff_v, 0, atol=tol))]

    if not divergentes.empty:
        print("\n⚠️  Contratos divergentes:")
        print(divergentes.to_string(index=False))
        raise AssertionError(
            f"{len(divergentes)} contrato(s) divergem além de tol={tol} MWm."
        )

    print(f"✅  Convergência validada! "
          f"Diferença máxima: {max(diff_c.max(), diff_v.max()):.2e} MWm\n")


# ── 3. Gráfico ───────────────────────────────────────────────────────────────
def gerar_grafico(df: pd.DataFrame) -> None:
    df = df.copy().sort_values("ticker")
    df["pos_DEQ"]  = df["compra_DEQ"]  - df["venda_DEQ"]
    df["pos_SDDP"] = df["compra_SDDP"] - df["venda_SDDP"]

    tickers = df["ticker"].tolist()
    x       = np.arange(len(tickers))
    w       = 0.35

    plt.rcParams.update({
        "font.family":       "serif",
        "font.size":         10,
        "axes.spines.top":   False,
        "axes.spines.right": False,
    })

    fig, ax = plt.subplots(figsize=(max(8, len(tickers) * 0.55), 5))
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")

    ax.bar(x - w / 2, df["pos_DEQ"],  w, label="DEQ",  color="#2166ac", alpha=0.85, zorder=3)
    ax.bar(x + w / 2, df["pos_SDDP"], w, label="SDDP", color="#d6604d", alpha=0.85, zorder=3)

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
    FIG_OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG_OUT, dpi=300, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"📊 Figura salva em: {FIG_OUT}")


# ── Main ─────────────────────────────────────────────────────────────────────
def main() -> None:
    print(f"Lendo DEQ:  {DEQ_CSV}")
    print(f"Lendo SDDP: {SDDP_CSV}\n")

    df = pd.merge(carregar(DEQ_CSV, "DEQ"), carregar(SDDP_CSV, "SDDP"), on="ticker")
    if df.empty:
        raise ValueError("Nenhum ticker em comum entre DEQ e SDDP.")
    print(f"Contratos no estágio 1: {len(df)}\n")

    testar_convergencia(df, tol=1e-3)
    gerar_grafico(df)


if __name__ == "__main__":
    main()
