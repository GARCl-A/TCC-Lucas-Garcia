import pandas as pd
import numpy as np
import os
import glob

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "..", "data", "ccee", "geracao_usina"))
PROCESSED_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "..", "data", "processed"))
CENARIOS_FILE = os.path.join(PROCESSED_DIR, "cenarios_final.csv")

# Mapeamento de submercados
MAPA_SUBMERCADOS = {
    "SUDESTE": "SE",
    "SUL": "S",
    "NORDESTE": "NE",
    "NORTE": "N"
}


def carregar_dados_historicos():
    """Carrega e processa dados históricos de geração das usinas"""
    print("📂 Carregando dados históricos de geração...")
    
    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))
    dfs = []
    
    for arq in arquivos:
        try:
            df = pd.read_csv(arq, sep=";", encoding="latin1", on_bad_lines="skip")
            if all(col in df.columns for col in ["COD_ATIVO", "SUBMERCADO", "FONTE_ENERGIA_PRIMARIA", "GERACAO_CENTRO_GRAVIDADE", "MES_REFERENCIA"]):
                df = df[["COD_ATIVO", "SUBMERCADO", "FONTE_ENERGIA_PRIMARIA", "GERACAO_CENTRO_GRAVIDADE", "MES_REFERENCIA"]].copy()
                dfs.append(df)
        except Exception as e:
            print(f"⚠️  Erro ao ler {os.path.basename(arq)}: {e}")
    
    if not dfs:
        raise ValueError("❌ Nenhum dado histórico encontrado")
    
    df_completo = pd.concat(dfs, ignore_index=True)
    
    # Padronizar submercados
    df_completo["SUBMERCADO"] = df_completo["SUBMERCADO"].map(MAPA_SUBMERCADOS).fillna(df_completo["SUBMERCADO"])
    
    # Extrair mês (1-12)
    df_completo["mes"] = df_completo["MES_REFERENCIA"].astype(str).str[-2:].astype(int)
    
    print(f"✅ {len(df_completo)} registros carregados")
    return df_completo


def calcular_estatisticas_mensais(df_historico):
    """Calcula média e desvio padrão por usina e mês"""
    print("📊 Calculando estatísticas mensais por usina...")
    
    stats = df_historico.groupby(["COD_ATIVO", "SUBMERCADO", "FONTE_ENERGIA_PRIMARIA", "mes"])["GERACAO_CENTRO_GRAVIDADE"].agg(
        Media_Historica="mean",
        Desvio_Padrao="std"
    ).reset_index()
    
    # Preencher NaN no desvio padrão com 10% da média
    stats["Desvio_Padrao"] = stats["Desvio_Padrao"].fillna(stats["Media_Historica"] * 0.10)
    
    print(f"✅ Estatísticas calculadas para {stats['COD_ATIVO'].nunique()} usinas")
    return stats


def carregar_cenarios_pld():
    """Carrega cenários de PLD e calcula fator PLD"""
    print("📈 Carregando cenários de PLD...")
    
    df_pld = pd.read_csv(CENARIOS_FILE)
    df_pld["data"] = pd.to_datetime(df_pld["data"])
    
    # Calcular PLD médio base por (data, submercado)
    pld_medio = df_pld.groupby(["data", "submercado"])["valor"].mean().reset_index()
    pld_medio.rename(columns={"valor": "PLD_Medio_Base"}, inplace=True)
    
    # Merge para adicionar PLD_Medio_Base
    df_pld = df_pld.merge(pld_medio, on=["data", "submercado"], how="left")
    
    # Calcular Fator_PLD com limite inferior de 0.1
    df_pld["Fator_PLD"] = df_pld["valor"] / df_pld["PLD_Medio_Base"]
    df_pld["Fator_PLD"] = df_pld["Fator_PLD"].clip(lower=0.1)
    
    print(f"✅ {len(df_pld)} cenários de PLD carregados")
    return df_pld


def gerar_cenarios_estocasticos(stats, df_pld):
    """Gera cenários estocásticos de geração correlacionados ao PLD"""
    print("🎲 Gerando cenários estocásticos de geração...")
    
    # Preparar dados para merge
    df_pld["mes"] = df_pld["data"].dt.month
    df_pld["ano"] = df_pld["data"].dt.year
    
    # Processar em chunks por (data, submercado) para economizar memória
    grupos = df_pld.groupby(["data", "submercado"])
    total_grupos = len(grupos)
    
    resultados = []
    np.random.seed(42)
    
    print(f"📦 Processando {total_grupos} grupos (data x submercado)...")
    
    for i, ((data, submercado), grupo_pld) in enumerate(grupos, 1):
        if i % 50 == 0:
            print(f"   Processando grupo {i}/{total_grupos}...")
        
        mes = grupo_pld["mes"].iloc[0]
        
        # Filtrar usinas do submercado e mês
        stats_filtrado = stats[(stats["SUBMERCADO"] == submercado) & (stats["mes"] == mes)].copy()
        
        if stats_filtrado.empty:
            continue
        
        # Criar combinações: cada usina x cada cenário do grupo
        n_cenarios = len(grupo_pld)
        n_usinas = len(stats_filtrado)
        
        # Replicar usinas para cada cenário
        stats_rep = pd.concat([stats_filtrado] * n_cenarios, ignore_index=True)
        
        # Replicar cenários para cada usina
        pld_rep = grupo_pld.loc[grupo_pld.index.repeat(n_usinas)].reset_index(drop=True)
        
        # Combinar
        df_chunk = pd.concat([pld_rep.reset_index(drop=True), stats_rep.reset_index(drop=True)], axis=1)
        
        # Ajustar média por fonte primária (vetorizado)
        mask_hidro = df_chunk["FONTE_ENERGIA_PRIMARIA"].str.contains("Hidráulica|Hidraulica", case=False, na=False)
        mask_eolica = df_chunk["FONTE_ENERGIA_PRIMARIA"].str.contains("Eólica|Eolica", case=False, na=False)
        
        df_chunk["Media_Ajustada"] = df_chunk["Media_Historica"]
        df_chunk.loc[mask_hidro, "Media_Ajustada"] = df_chunk.loc[mask_hidro, "Media_Historica"] * (1.0 / df_chunk.loc[mask_hidro, "Fator_PLD"])
        df_chunk.loc[mask_eolica, "Media_Ajustada"] = df_chunk.loc[mask_eolica, "Media_Historica"] * (df_chunk.loc[mask_eolica, "Fator_PLD"] ** 0.5)
        
        # Sorteio de Monte Carlo
        df_chunk["geracao_mwm"] = np.maximum(
            0.0,
            np.random.normal(
                loc=df_chunk["Media_Ajustada"],
                scale=df_chunk["Desvio_Padrao"]
            )
        ).round(2)
        
        # Selecionar colunas
        resultado_chunk = df_chunk[["data", "submercado", "COD_ATIVO", "cenario", "geracao_mwm"]].copy()
        resultados.append(resultado_chunk)
    
    # Concatenar todos os resultados
    print("🔗 Concatenando resultados...")
    resultado = pd.concat(resultados, ignore_index=True)
    resultado.rename(columns={"COD_ATIVO": "usina_cod"}, inplace=True)
    
    print(f"✅ {len(resultado)} registros gerados")
    return resultado


def main():
    print("🚀 Iniciando geração estocástica de energia...\n")
    
    # Passo 1: Carregar dados históricos e calcular estatísticas
    df_historico = carregar_dados_historicos()
    stats = calcular_estatisticas_mensais(df_historico)
    
    # Passo 2: Carregar cenários de PLD
    df_pld = carregar_cenarios_pld()
    
    # Passo 3 e 4: Gerar cenários estocásticos
    df_resultado = gerar_cenarios_estocasticos(stats, df_pld)
    
    # Exportar resultado
    output_path = os.path.join(PROCESSED_DIR, "geracao_estocastica.csv")
    df_resultado.to_csv(output_path, index=False)
    
    print(f"\n✅ Arquivo gerado: {output_path}")
    print(f"📊 Total de registros: {len(df_resultado):,}")
    print(f"🏭 Usinas únicas: {df_resultado['usina_cod'].nunique()}")
    print(f"🎯 Cenários: {df_resultado['cenario'].nunique()}")
    print(f"📅 Período: {df_resultado['data'].min()} a {df_resultado['data'].max()}")


if __name__ == "__main__":
    main()
