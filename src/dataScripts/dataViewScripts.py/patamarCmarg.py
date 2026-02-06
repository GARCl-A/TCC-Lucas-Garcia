import pandas as pd
import os

ARQUIVO_CMARG = "cmarg004.csv"
ARQUIVO_PATAMAR = "patamar.csv"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "../..", "data", "processed")


def prova_real_manual():
    print(f"🔍 Buscando arquivos em: {DATA_DIR}")

    path_c = os.path.join(DATA_DIR, ARQUIVO_CMARG)
    path_p = os.path.join(DATA_DIR, ARQUIVO_PATAMAR)

    try:
        df_c = pd.read_csv(path_c)
        df_p = pd.read_csv(path_p)
    except FileNotFoundError:
        print("❌ Erro: Arquivos não encontrados na pasta processed.")
        print("   Verifique se rodou os passos anteriores.")
        return

    ALVO_ANO = 2017
    ALVO_MES = 10
    ALVO_CENARIO = 2

    print(f"\n--- 🕵️‍♂️ AUDITORIA: {ARQUIVO_CMARG} ---")
    print(f"Data: {ALVO_MES}/{ALVO_ANO} | Cenário: {ALVO_CENARIO}")

    filtro_c = (
        (df_c["ano"] == ALVO_ANO)
        & (df_c["mes"] == ALVO_MES)
        & (df_c["cenario"] == ALVO_CENARIO)
    )
    dados_preco = df_c[filtro_c].sort_values("patamar")

    if dados_preco.empty:
        print("❌ Nenhum dado encontrado para essa data/cenário no CMARG.")
        return

    df_p = df_p.drop_duplicates(subset=["ano", "mes", "patamar"])
    filtro_p = (df_p["ano"] == ALVO_ANO) & (df_p["mes"] == ALVO_MES)
    dados_peso = df_p[filtro_p].sort_values("patamar")

    if dados_peso.empty:
        print("❌ Nenhum dado encontrado para essa data no PATAMAR.")
        return

    print("\n📝 Detalhamento da Média Ponderada:")
    print(
        f"{'Patamar':<8} | {'Preço (R$)':<12} | {'Peso (Duração)':<15} | {'Parcela (PxD)':<15}"
    )
    print("-" * 55)

    soma_final = 0.0

    for pat in [1, 2, 3]:
        linha_preco = dados_preco[dados_preco["patamar"] == pat]
        if linha_preco.empty:
            print(f"{pat:<8} | {'MISSING':<12} | ...")
            continue
        preco = float(linha_preco["valor"].iloc[0])

        linha_peso = dados_peso[dados_peso["patamar"] == pat]
        if linha_peso.empty:
            print(f"{pat:<8} | {preco:<12.2f} | {'MISSING':<15}")
            continue
        peso = float(linha_peso["duracao"].iloc[0])

        parcela = preco * peso
        soma_final += parcela

        print(f"{pat:<8} | {preco:<12.2f} | {peso:<15.4f} | {parcela:<15.4f}")

    print("-" * 55)
    print(f"📊 RESULTADO FINAL (Soma): R$ {soma_final:.4f}")

    path_final = os.path.join(DATA_DIR, "cenarios_final.csv")
    if os.path.exists(path_final):
        print("\n--- Comparação com cenarios_final.csv ---")
        df_final = pd.read_csv(path_final)
        sub = dados_preco["submercado"].iloc[0]

        filtro_final = (
            (df_final["submercado"] == sub)
            & (df_final["ano"] == ALVO_ANO)
            & (df_final["mes"] == ALVO_MES)
            & (df_final["cenario"] == ALVO_CENARIO)
        )
        dado_final = df_final[filtro_final]

        if not dado_final.empty:
            valor_csv = dado_final["valor"].iloc[0]
            print(f"Valor no CSV Final:      R$ {valor_csv:.4f}")
            diff = abs(valor_csv - soma_final)
            if diff < 0.001:
                print("✅ BATEU! O cálculo está exato.")
            else:
                print(f"⚠️ Diferença encontrada: {diff:.4f}")
        else:
            print(
                "⚠️ Dado não encontrado no arquivo final (talvez não tenha sido processado ainda)."
            )


if __name__ == "__main__":
    prova_real_manual()
