import pandas as pd
import os
import glob
import importlib.util

spec = importlib.util.spec_from_file_location(
    "config", os.path.join(os.path.dirname(__file__), "..", "config.py")
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

RAW_DIR = config.RAW_CCEE_CONTRATOS_DIR
PROCESSED_DIR = config.PROCESSED_DIR
GERACAO_FILE = os.path.normpath(os.path.join(PROCESSED_DIR, "geracao_estocastica.csv"))

# PARAMETROS DA CARTEIRA INICIAL
PERCENTUAL_CONTRATADO = config.PERCENTUAL_CONTRATO_LEGADO
ANO_INICIO = config.ANO_INICIO
ANO_FIM = config.ANO_FIM
PRECO_DEFAULT = config.PRECO_CONTRATO_DEFAULT


def processar_contratos_legados():
    print("💼 Iniciando processamento da Carteira Legada...")

    # 1. Ler arquivo de geração para calcular produção média por submercado
    if not os.path.exists(GERACAO_FILE):
        print(
            f"❌ Arquivo {GERACAO_FILE} não encontrado. Execute geracao_estocastica.py primeiro."
        )
        return

    df_geracao = pd.read_csv(GERACAO_FILE)
    producao_por_submercado = (
        df_geracao.groupby("submercado")["geracao_mwm"].mean().to_dict()
    )

    print("\n📊 Produção Média por Submercado:")
    for sub, prod in producao_por_submercado.items():
        print(f"   {sub}: {prod:.2f} MWm")

    # 2. Calcular preço médio dos contratos
    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))

    preco_medio = PRECO_DEFAULT  # Valor Default (Fallback)
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
            f"   ⚠️ Arquivos não lidos ou sem coluna de preço. Usando Default: R$ {PRECO_DEFAULT:.2f}"
        )

    # 3. Gerar contratos proporcionais à produção de cada submercado
    print(
        f"\n⏳ Gerando contratos de VENDA ({PERCENTUAL_CONTRATADO*100:.0f}% da produção) a R$ {preco_medio}..."
    )

    carteira = []
    datas = pd.date_range(
        start=f"{ANO_INICIO}-01-01", end=f"{ANO_FIM}-12-01", freq="MS"
    )

    for submercado, producao_media in producao_por_submercado.items():
        volume_contratado = round(producao_media * PERCENTUAL_CONTRATADO, 2)

        for d in datas:
            carteira.append(
                {
                    "data": d,
                    "submercado": submercado,
                    "tipo": "VENDA",  # VENDA = Obrigação (Short)
                    "volume_mwm": volume_contratado,
                    "preco_r_mwh": preco_medio,
                }
            )

    # 4. Salvar
    df_final = pd.DataFrame(carteira).sort_values(["data", "submercado"])
    path_saida = os.path.join(PROCESSED_DIR, "contratos_legacy.csv")
    df_final.to_csv(path_saida, index=False)

    print(f"\n✅ Arquivo gerado: {path_saida}")
    print("\n📋 Resumo por Submercado:")
    print(df_final.groupby("submercado")["volume_mwm"].agg(["count", "mean"]).round(2))
    print(f"\nTotal de contratos: {len(df_final)}")


if __name__ == "__main__":
    processar_contratos_legados()
