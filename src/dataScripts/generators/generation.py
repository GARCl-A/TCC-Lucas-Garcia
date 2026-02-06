import pandas as pd
import numpy as np
import os
import glob

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(BASE_DIR, "../..", "data", "ccee", "geracao_usina")
PROCESSED_DIR = os.path.join(BASE_DIR, "../..", "data", "processed")

COD_USINA_ALVO = 202
ANO_INICIO = 2021
ANO_FIM = 2025


def processar_geracao_estocastica():
    print(
        f"🎲 Iniciando Geração Estocástica (Normal Distribution) - Usina {COD_USINA_ALVO}..."
    )

    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))
    dfs = []
    for arq in arquivos:
        try:
            df = pd.read_csv(arq, sep=";", encoding="latin1", on_bad_lines="skip")
            df_usina = df[df["COD_ATIVO"] == COD_USINA_ALVO].copy()
            dfs.append(df_usina)
        except:
            pass

    if not dfs:
        print("❌ Dados base não encontrados.")
        return

    df_base = pd.concat(dfs)
    df_base["mes_idx"] = df_base["MES_REFERENCIA"].astype(str).str[-2:].astype(int)

    stats_mensais = df_base.groupby("mes_idx")["GERACAO_CENTRO_GRAVIDADE"].agg(
        ["mean", "std"]
    )

    stats_mensais["std"] = stats_mensais["std"].fillna(stats_mensais["mean"] * 0.10)

    print("\n📊 Parâmetros da Distribuição Normal (μ e σ):")
    print(stats_mensais)

    dados_finais = []
    datas = pd.date_range(
        start=f"{ANO_INICIO}-01-01", end=f"{ANO_FIM}-12-01", freq="MS"
    )

    np.random.seed(42)

    for d in datas:
        mes = d.month
        params = stats_mensais.loc[mes]

        valor_simulado = np.random.normal(loc=params["mean"], scale=params["std"])

        valor_simulado = max(0.0, valor_simulado)

        dados_finais.append(
            {
                "data": d,
                "submercado": "SE",
                "usina_cod": COD_USINA_ALVO,
                "geracao_mwm": round(valor_simulado, 2),
            }
        )

    df_final = pd.DataFrame(dados_finais)
    path_saida = os.path.join(PROCESSED_DIR, "geracao.csv")
    df_final.to_csv(path_saida, index=False)
    print(f"\n✅ Arquivo gerado com ruído estatístico: {path_saida}")


if __name__ == "__main__":
    processar_geracao_estocastica()
