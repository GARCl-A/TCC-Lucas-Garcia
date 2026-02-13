import pandas as pd
import numpy as np
import os
import glob

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "..", "data", "ccee", "geracao_usina"))
PROCESSED_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "..", "data", "processed"))

ANO_INICIO = 2021
ANO_FIM = 2025


def extrair_usinas_disponiveis():
    """Extrai usinas e padroniza submercados para siglas (SE, S, NE, N)"""
    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))
    dfs = []
    
    # Mapeamento de nomes completos para siglas
    mapa_submercados = {
        "SUDESTE": "SE",
        "SUL": "S",
        "NORDESTE": "NE",
        "NORTE": "N"
    }
    
    for arq in arquivos:
        try:
            df = pd.read_csv(arq, sep=";", encoding="latin1", on_bad_lines="skip")
            if "COD_ATIVO" in df.columns and "SUBMERCADO" in df.columns:
                df_temp = df[["COD_ATIVO", "SUBMERCADO"]].drop_duplicates()
                # Padroniza submercados para siglas
                df_temp["SUBMERCADO"] = df_temp["SUBMERCADO"].map(mapa_submercados).fillna(df_temp["SUBMERCADO"])
                dfs.append(df_temp)
        except Exception as e:
            print(f"⚠️  Erro ao ler {os.path.basename(arq)}: {e}")
    
    if not dfs:
        return []
    
    df_usinas = pd.concat(dfs).drop_duplicates()
    return [{"cod": int(row["COD_ATIVO"]), "submercado": row["SUBMERCADO"]} for _, row in df_usinas.iterrows()]


def processar_geracao_estocastica():
    print("🎲 Iniciando Geração Estocástica...")
    
    # Mapeamento de nomes completos para siglas
    mapa_submercados = {
        "SUDESTE": "SE",
        "SUL": "S",
        "NORDESTE": "NE",
        "NORTE": "N"
    }
    
    usinas = extrair_usinas_disponiveis()
    print(f"📊 Encontradas {len(usinas)} usinas nos arquivos fonte")
    
    arquivos = glob.glob(os.path.join(RAW_DIR, "*.csv"))
    dfs = []
    for arq in arquivos:
        try:
            df = pd.read_csv(arq, sep=";", encoding="latin1", on_bad_lines="skip")
            dfs.append(df)
        except:
            pass

    if not dfs:
        print("❌ Dados base não encontrados.")
        return

    df_completo = pd.concat(dfs)
    dados_finais = []
    datas = pd.date_range(start=f"{ANO_INICIO}-01-01", end=f"{ANO_FIM}-12-01", freq="MS")
    np.random.seed(42)

    for usina in usinas:
        cod = usina["cod"]
        submercado = usina["submercado"]
        
        df_usina = df_completo[df_completo["COD_ATIVO"] == cod].copy()
        
        if df_usina.empty:
            continue
        
        df_usina["mes_idx"] = df_usina["MES_REFERENCIA"].astype(str).str[-2:].astype(int)
        stats_mensais = df_usina.groupby("mes_idx")["GERACAO_CENTRO_GRAVIDADE"].agg(["mean", "std"])
        stats_mensais["std"] = stats_mensais["std"].fillna(stats_mensais["mean"] * 0.10)
        
        for d in datas:
            mes = d.month
            if mes not in stats_mensais.index:
                continue
            params = stats_mensais.loc[mes]
            valor_simulado = max(0.0, np.random.normal(loc=params["mean"], scale=params["std"]))
            
            dados_finais.append({
                "data": d,
                "submercado": submercado,
                "usina_cod": cod,
                "geracao_mwm": round(valor_simulado, 2),
            })

    df_final = pd.DataFrame(dados_finais).sort_values(["data", "usina_cod"])
    path_saida = os.path.join(PROCESSED_DIR, "geracao.csv")
    df_final.to_csv(path_saida, index=False)
    print(f"\n✅ Arquivo gerado: {path_saida} ({len(df_final)} linhas, {len(usinas)} usinas)")


if __name__ == "__main__":
    processar_geracao_estocastica()
