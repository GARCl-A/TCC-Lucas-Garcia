import pandas as pd
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROCESSED_DIR = os.path.join(BASE_DIR, "../../..", "data", "processed")

SPREAD = 0.05
LIMITE_LOTE = 20.0


def gerar_trades():
    print("💰 Iniciando a Mesa de Operações (Geração de Trades)...")

    path_cenarios = os.path.join(PROCESSED_DIR, "cenarios_final.csv")

    if not os.path.exists(path_cenarios):
        print("❌ Erro: 'cenarios_final.csv' não encontrado.")
        return

    df = pd.read_csv(path_cenarios)

    df["data"] = pd.to_datetime(df["data"])

    curva_forward = df.groupby(["submercado", "data"])["valor"].mean().reset_index()

    print("   Curva Forward calculada. Criando spreads...")

    trades = []

    for _, row in curva_forward.iterrows():
        preco_medio = row["valor"]

        if preco_medio > 0:
            trades.append(
                {
                    "data": row["data"],
                    "submercado": row["submercado"],
                    "preco_compra": round(preco_medio * (1 + SPREAD), 2),
                    "preco_venda": round(preco_medio * (1 - SPREAD), 2),
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
    print(f"Preço Tela Compra (+5%): R$ {exemplo['preco_compra']:.2f}")
    print(f"Preço Tela Venda  (-5%): R$ {exemplo['preco_venda']:.2f}")


if __name__ == "__main__":
    gerar_trades()
