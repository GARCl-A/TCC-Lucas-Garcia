import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location(
    "config", os.path.join(os.path.dirname(__file__), "..", "config.py")
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

PROCESSED_DIR = config.PROCESSED_DIR
LIMITE_LOTE = config.LIMITE_LOTE_TRADES
DURACOES_MESES = config.DURACOES_TRADES
SPREADS_POR_DURACAO = config.SPREADS_POR_DURACAO
MESES_NOME = {
    1: "JAN",
    2: "FEV",
    3: "MAR",
    4: "ABR",
    5: "MAI",
    6: "JUN",
    7: "JUL",
    8: "AGO",
    9: "SET",
    10: "OUT",
    11: "NOV",
    12: "DEZ",
}


def gerar_ticker(submercado, data, duracao):
    """
    Gera o código do contrato. Ex: SE24FEV3
    SE = Sudeste | 24 = Ano 2024 | FEV = Mês | 3 = Trimestral
    """
    ano_str = str(data.year)[-2:]
    mes_str = MESES_NOME[data.month]
    return f"{submercado}{ano_str}{mes_str}{duracao}"


def gerar_trades():
    print(
        f"Iniciando a Mesa de Operações (Geração de Produtos: {DURACOES_MESES} meses)..."
    )
    path_cenarios = os.path.join(PROCESSED_DIR, "cenarios_final.csv")
    if not os.path.exists(path_cenarios):
        print("❌ Erro: 'cenarios_final.csv' não encontrado.")
        return
    df = pd.read_csv(path_cenarios)
    df["data"] = pd.to_datetime(df["data"])
    curva_forward = df.groupby(["submercado", "data"])["valor"].mean().reset_index()
    curva_forward = curva_forward.sort_values(["submercado", "data"]).reset_index(
        drop=True
    )
    print(
        "   Curva Forward calculada. Criando portfólio de produtos e a aplicar spreads..."
    )
    trades = []
    submercados = curva_forward["submercado"].unique()
    for sub in submercados:
        df_sub = curva_forward[curva_forward["submercado"] == sub].reset_index(
            drop=True
        )
        for duracao in DURACOES_MESES:
            spread_atual = SPREADS_POR_DURACAO[duracao]
            for i in range(len(df_sub)):
                slice_periodo = df_sub.iloc[i : i + duracao]
                if len(slice_periodo) < duracao:
                    break
                preco_medio_periodo = slice_periodo["valor"].mean()
                data_inicio = df_sub.iloc[i]["data"]
                ticker = gerar_ticker(sub, data_inicio, duracao)
                if preco_medio_periodo > 0:
                    trades.append(
                        {
                            "ticker": ticker,
                            "data": data_inicio,
                            "submercado": sub,
                            "duracao_meses": duracao,
                            "preco_compra": round(
                                preco_medio_periodo * (1 + spread_atual), 2
                            ),
                            "preco_venda": round(
                                preco_medio_periodo * (1 - spread_atual), 2
                            ),
                            "limite_compra": LIMITE_LOTE,
                            "limite_venda": LIMITE_LOTE,
                        }
                    )
    df_trades = pd.DataFrame(trades)
    path_saida = os.path.join(PROCESSED_DIR, "trades.csv")
    df_trades.to_csv(path_saida, index=False)
    print(f"\n✅ Arquivo gerado: {path_saida}")
    print(f"Total de produtos disponíveis para otimização: {len(df_trades)}")
    print("\n--- Amostra do Portfólio Gerado ---")
    amostras = df_trades.drop_duplicates(subset=["duracao_meses"]).head(3)
    for _, row in amostras.iterrows():
        print(
            f"Ticker: {row['ticker']:<10} | Início: {row['data'].date()} | Dur: {row['duracao_meses']}M | Ask: R$ {row['preco_compra']:.2f} | Bid: R$ {row['preco_venda']:.2f}"
        )


if __name__ == "__main__":
    gerar_trades()
