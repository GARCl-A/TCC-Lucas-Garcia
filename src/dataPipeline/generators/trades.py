import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location("config", os.path.join(os.path.dirname(__file__), "..", "config.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

PROCESSED_DIR = config.PROCESSED_DIR
SPREAD = config.SPREAD_TRADES
LIMITE_LOTE = config.LIMITE_LOTE_TRADES


def gerar_trades():
    print("Iniciando a Mesa de Operacoes (Geracao de Trades)...")

    path_cenarios = os.path.join(PROCESSED_DIR, "cenarios_final.csv")

    if not os.path.exists(path_cenarios):
        print("❌ Erro: 'cenarios_final.csv' não encontrado.")
        return

    df = pd.read_csv(path_cenarios)

    df["data"] = pd.to_datetime(df["data"])

    curva_forward = df.groupby(["submercado", "data"])["valor"].mean().reset_index()

    print("   Curva Forward calculada. Criando spreads...")

    print(f"\nGerando trades com SPREAD = {SPREAD*100}%")

    trades = []

    for _, row in curva_forward.iterrows():
        preco_medio = row["valor"]

        if preco_medio > 0:
            trades.append(
                {
                    "data": row["data"],
                    "submercado": row["submercado"],
                    "preco_compra": round(
                        preco_medio * (1 + SPREAD), 2
                    ),  # Ask: você compra mais caro
                    "preco_venda": round(
                        preco_medio * (1 - SPREAD), 2
                    ),  # Bid: você vende mais barato
                    "limite_compra": LIMITE_LOTE,
                    "limite_venda": LIMITE_LOTE,
                }
            )

    df_trades = pd.DataFrame(trades)
    path_saida = os.path.join(PROCESSED_DIR, "trades.csv")
    df_trades.to_csv(path_saida, index=False)

    print(f"\n✅ Arquivo gerado: {path_saida}")
    print(df_trades.head())
    print(f"Total de oportunidades geradas: {len(df_trades)}")

    print("\n--- Exemplo de Trade (Primeira Linha) ---")
    exemplo = df_trades.iloc[0]
    medio = exemplo["preco_compra"] / (1 + SPREAD)
    print(f"Data: {exemplo['data'].date()}")
    print(f"Preço Esperado (NEWAVE): R$ {medio:.2f}")
    print(f"Preço Tela Compra (+{SPREAD*100}%): R$ {exemplo['preco_compra']:.2f}")
    print(f"Preço Tela Venda  (-{SPREAD*100}%): R$ {exemplo['preco_venda']:.2f}")


if __name__ == "__main__":
    gerar_trades()
