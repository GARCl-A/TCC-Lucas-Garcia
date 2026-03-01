import pandas as pd
import os
import glob
import importlib.util

# Importa o config dinamicamente
spec = importlib.util.spec_from_file_location(
    "config", os.path.join(os.path.dirname(__file__), "..", "config.py")
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

PROCESSED_DIR = config.PROCESSED_DIR


def aplicar_limites_aneel(row):
    """
    Transforma o Custo Marginal de Operação (CMO) do simulador em PLD regulatório
    respeitando o Teto e o Piso do ano de operação.
    """
    ano_base = row["ano"]
    valor_cmo = row["valor"]

    # Se existe um OFFSET_ANOS no config (ex: 2017 virando 2021),
    # queremos aplicar a regra da ANEEL do ano alvo (2021) e não do ano antigo.
    ano_alvo = ano_base + getattr(config, "OFFSET_ANOS", 0)

    if ano_alvo in config.LIMITES_PLD:
        piso, teto = config.LIMITES_PLD[ano_alvo]
        return max(piso, min(valor_cmo, teto))

    return valor_cmo


def processar_merge_final():
    print("🔥 Iniciando o Processamento Final (Agregação de Patamares)...")

    path_patamar = os.path.join(PROCESSED_DIR, "patamar.csv")
    try:
        df_patamar = pd.read_csv(path_patamar)
        df_patamar = df_patamar.drop_duplicates(subset=["ano", "mes", "patamar"])

        print(f"✅ Tabela de Patamares carregada! ({len(df_patamar)} linhas únicas)")

        check = df_patamar.groupby(["ano", "mes"])["duracao"].sum().mean()
        print(f"   (Check de Qualidade: Média da soma das durações = {check:.4f})")

    except FileNotFoundError:
        print(
            "❌ Erro: 'patamar.csv' não encontrado. Rode o step2_convert_patamar.py antes."
        )
        return

    arquivos_cmarg = glob.glob(os.path.join(PROCESSED_DIR, "cmarg*.csv"))
    dfs_finais = []

    for arquivo in arquivos_cmarg:
        if "cenarios_final.csv" in arquivo:
            continue

        nome_arq = os.path.basename(arquivo)
        print(f"\n⚡ Processando {nome_arq}...")

        df = pd.read_csv(arquivo)

        # ==============================================================
        # NOVO: Aplica o Teto e Piso ANTES de fazer a média mensal!
        # Transforma os valores absurdos de CMO em valores reais de PLD
        # ==============================================================
        df["valor"] = df.apply(aplicar_limites_aneel, axis=1)

        # Agora junta com os patamares
        df_merged = pd.merge(df, df_patamar, on=["ano", "mes", "patamar"], how="left")

        nulos = df_merged["duracao"].isnull().sum()
        if nulos > 0:
            print(
                f"   ⚠️ Aviso: {nulos} linhas sem duração definida (Anos futuros?). Usando média simples."
            )
            df_merged["duracao"] = df_merged["duracao"].fillna(
                config.DURACAO_PATAMAR_DEFAULT
            )

        # Média ponderada pela duração das horas do patamar
        df_merged["valor_ponderado"] = df_merged["valor"] * df_merged["duracao"]

        df_mensal = (
            df_merged.groupby(["submercado", "ano", "mes", "cenario"])[
                "valor_ponderado"
            ]
            .sum()
            .reset_index()
        )

        df_mensal.rename(columns={"valor_ponderado": "valor"}, inplace=True)
        dfs_finais.append(df_mensal)

    if dfs_finais:
        df_master = pd.concat(dfs_finais, ignore_index=True)

        df_master["data"] = pd.to_datetime(
            dict(year=df_master.ano, month=df_master.mes, day=1)
        )

        df_master = df_master.sort_values(["submercado", "data", "cenario"])

        path_saida = os.path.join(PROCESSED_DIR, "cenarios_final.csv")
        df_master.to_csv(path_saida, index=False)

        print(f"\n🚀 SUCESSO TOTAL! Arquivo Mestre gerado: {path_saida}")
        print(f"📊 Dimensões Finais: {df_master.shape} (Linhas x Colunas)")
        print(
            "   A coluna 'patamar' foi removida e os limites da ANEEL foram aplicados."
        )
    else:
        print("\n❌ Nenhum arquivo CMARG processado.")


if __name__ == "__main__":
    processar_merge_final()
