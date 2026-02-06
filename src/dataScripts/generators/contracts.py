import pandas as pd
import os
import glob

# --- CONFIGURAÇÃO ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(BASE_DIR, "../..", "data", "ccee", "contratos")
PROCESSED_DIR = os.path.join(BASE_DIR, "../..", "data", "processed")

# PARAMETROS DA CARTEIRA INICIAL
VOLUME_CONTRATADO = 40.0  # MWm (Venda Flat)
SUBMERCADO_CONTRATO = "SE"  # Onde a usina entrega
ANO_INICIO = 2021
ANO_FIM = 2025


def processar_contratos_legados():
    print("💼 Iniciando processamento da Carteira Legada...")

    # 1. Tentar calcular o Preço Médio Real (K0) dos arquivos
    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))

    preco_medio = 230.00  # Valor Default (Fallback)
    precos_encontrados = []

    if arquivos:
        print(
            f"   Lendo {len(arquivos)} arquivos de contratos para referência de preço..."
        )
        for arq in arquivos:
            try:
                # Tenta ler com ; ou ,
                df = pd.read_csv(arq, sep=";", encoding="latin1", on_bad_lines="skip")

                # Procura coluna de Preço (nomes variam: PRECO_LIQUIDACAO, PRECO_MEDIO, etc)
                coluna_preco = None
                for col in df.columns:
                    if "PRECO_LIQUIDACAO" in col:
                        coluna_preco = col
                        break

                if coluna_preco:
                    # Pega média do arquivo
                    media_arq = df[coluna_preco].mean()
                    if pd.notna(media_arq):
                        precos_encontrados.append(media_arq)
            except (
                pd.errors.EmptyDataError,
                pd.errors.ParserError,
                FileNotFoundError,
                UnicodeDecodeError,
            ):
                pass

    if precos_encontrados:
        preco_calculado = sum(precos_encontrados) / len(precos_encontrados)
        print(f"   Preço Médio Histórico encontrado: R$ {preco_calculado:.2f}")
        preco_medio = round(preco_calculado, 2)
    else:
        print(
            f"   ⚠️ Arquivos não lidos ou sem coluna de preço. Usando Default: R$ {preco_medio:.2f}"
        )

    # 2. Gerar a Carteira (2017-2021)
    print(
        f"⏳ Gerando contratos de VENDA de {VOLUME_CONTRATADO} MWm a R$ {preco_medio}..."
    )

    carteira = []
    datas = pd.date_range(
        start=f"{ANO_INICIO}-01-01", end=f"{ANO_FIM}-12-01", freq="MS"
    )

    for d in datas:
        carteira.append(
            {
                "data": d,
                "submercado": SUBMERCADO_CONTRATO,
                "tipo": "VENDA",  # VENDA = Obrigação (Short)
                "volume_mwm": VOLUME_CONTRATADO,
                "preco_r_mwh": preco_medio,
            }
        )

    # 3. Salvar
    df_final = pd.DataFrame(carteira)
    path_saida = os.path.join(PROCESSED_DIR, "contratos_legacy.csv")
    df_final.to_csv(path_saida, index=False)

    print(f"\n✅ Arquivo gerado: {path_saida}")
    print(df_final.head())
    print(f"Total de meses contratados: {len(df_final)}")


if __name__ == "__main__":
    processar_contratos_legados()
