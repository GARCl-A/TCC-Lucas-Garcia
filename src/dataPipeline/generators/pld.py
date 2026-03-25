import pandas as pd
import numpy as np
from datetime import datetime
from dateutil.relativedelta import relativedelta


# ==========================================
# 1. CARREGAR E PREPARAR DADOS
# ==========================================
def pld_gen():
    df = pd.read_csv("data\\ccee\\PLD_Mensal_2001_2025.csv")
    submercados = ["SUDESTE", "SUL", "NORDESTE", "NORTE"]

    # Limpar formatação
    for sub in submercados:
        df[sub] = df[sub].astype(str).str.replace(",", ".").astype(float)

    meses_map = {
        "jan.": 1,
        "fev.": 2,
        "mar.": 3,
        "abr.": 4,
        "mai.": 5,
        "jun.": 6,
        "jul.": 7,
        "ago.": 8,
        "set.": 9,
        "out.": 10,
        "nov.": 11,
        "dez.": 12,
    }
    df["mes"] = df["MES"].apply(lambda x: meses_map[x.split("-")[0]])

    # Transformação Log-Normal (Garante que PLD > 0 e trata os picos)
    for sub in submercados:
        df[f"log_{sub}"] = np.log(df[sub])

    # ==========================================
    # 2. CALIBRAR O MODELO PAR(1) LOG-NORMAL
    # ==========================================
    estatisticas = {}
    for sub in submercados:
        estatisticas[sub] = {}
        for m in range(1, 13):
            # Mês atual e Mês anterior (lida com a virada do ano Jan -> Dez)
            m_ant = 12 if m == 1 else m - 1

            dados_m = df[df["mes"] == m][f"log_{sub}"].values
            dados_m_ant = df[df["mes"] == m_ant][f"log_{sub}"].values

            # Garante que os vetores tenham o mesmo tamanho para a correlação
            min_len = min(len(dados_m), len(dados_m_ant))

            mu_m = np.mean(dados_m)
            std_m = np.std(dados_m)
            mu_ant = np.mean(dados_m_ant)
            std_ant = np.std(dados_m_ant)

            # Correlação de Pearson entre o mês atual e o mês passado
            corr = np.corrcoef(dados_m[:min_len], dados_m_ant[:min_len])[0, 1]

            estatisticas[sub][m] = {
                "mu": mu_m,
                "std": std_m,
                "corr": corr,
                "mu_ant": mu_ant,
                "std_ant": std_ant,
            }

    # ==========================================
    # 3. GERAR CENÁRIOS SINTÉTICOS E ÚNICOS
    # ==========================================
    num_cenarios = 5
    meses_simulacao = 6
    data_inicio = "2026-01-01"
    data_base = datetime.strptime(data_inicio, "%Y-%m-%d")

    linhas_finais = []
    map_subs_modelo = {"SUDESTE": "SE", "SUL": "S", "NORDESTE": "NE", "NORTE": "N"}

    for cenario in range(1, num_cenarios + 1):
        # Condição Inicial: Pega o último PLD conhecido (ex: Dezembro 2025)
        # Como não temos, vamos iniciar a cadeia sorteando um valor realista para o mês 0
        mes_0 = (data_base - relativedelta(months=1)).month
        ultimo_log_pld = {
            sub: np.random.normal(
                estatisticas[sub][mes_0]["mu"], estatisticas[sub][mes_0]["std"]
            )
            for sub in submercados
        }

        for i in range(meses_simulacao):
            data_atual = data_base + relativedelta(months=i)
            m_atual = data_atual.month

            # Sorteia um "Choque" aleatório (Ruído Branco Normal Padrão)
            # Usamos o mesmo ruído para os 4 submercados para manter a correlação espacial (se chove no SE, afeta o S)
            choque_sistema = np.random.normal(0, 1)

            for sub in submercados:
                st = estatisticas[sub][m_atual]

                # A Magia do PAR(1): Valor = Média + Inércia do Passado + Choque Aleatório
                z_ant = (ultimo_log_pld[sub] - st["mu_ant"]) / st["std_ant"]
                z_atual = (
                    st["corr"] * z_ant + np.sqrt(1 - st["corr"] ** 2) * choque_sistema
                )

                log_pld_simulado = st["mu"] + st["std"] * z_atual
                ultimo_log_pld[sub] = log_pld_simulado

                # Reverte o Logaritmo (Exponencial) e garante limites regulatórios (ex: teto de R$ 700, piso de R$ 69)
                pld_real = np.exp(log_pld_simulado)
                pld_real = np.clip(
                    pld_real, 69.04, 700.00
                )  # Limites fictícios aproximados da CCEE

                linhas_finais.append(
                    {
                        "data": data_atual.strftime("%Y-%m-%d"),
                        "cenario": cenario,
                        "submercado": map_subs_modelo[sub],
                        "valor": round(pld_real, 2),
                    }
                )

    # Salvar
    df_final = pd.DataFrame(linhas_finais)
    df_final.to_csv("data\\processed\\cenarios_final.csv", index=False)
    print(f"Gerados {num_cenarios} cenários estocásticos PAR(1) com sucesso!")
