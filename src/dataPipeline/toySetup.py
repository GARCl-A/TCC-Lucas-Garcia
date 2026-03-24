import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location("config", os.path.join(os.path.dirname(__file__), "config.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

PROCESSED_DIR = config.PROCESSED_DIR

def gerar_toy_problem_4m():
    print("Iniciando a criação do Toy Problem (4 Meses, Trade de 3 Meses)...")
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    
    # 1. Cenários (4 meses, 2 cenários de PLD para forçar incerteza)
    meses = ["2026-01-01", "2026-02-01", "2026-03-01", "2026-04-01"]
    cenarios_list = []
    for m in meses:
        cenarios_list.append({"data": m, "submercado": "SE", "cenario": 1, "valor": 50.0})
        cenarios_list.append({"data": m, "submercado": "SE", "cenario": 2, "valor": 250.0})
    cenarios = pd.DataFrame(cenarios_list)
    
    # 2. Geração - Tudo zero para isolar o efeito financeiro
    geracao_list = []
    for m in meses:
        geracao_list.append({"data": m, "usina_cod": 1, "submercado": "SE", "cenario": 1, "geracao_mwm": 0.0})
        geracao_list.append({"data": m, "usina_cod": 1, "submercado": "SE", "cenario": 2, "geracao_mwm": 0.0})
    geracao = pd.DataFrame(geracao_list)
    
    # 3. Contratos Legacy - Vazio
    legacy = pd.DataFrame(columns=["data", "submercado", "tipo", "volume_mwm", "preco_r_mwh"])
    
    # 4. Trades - Duração de 3 meses, arbitragem de R$ 80 limpos.
    trades = pd.DataFrame([
        {
            "ticker": "SE26TOY3M",
            "data": "2026-01-01",
            "submercado": "SE",
            "duracao_meses": 3,
            "preco_compra": 120.0,
            "preco_venda": 200.0,
            "limite_compra": 10.0,
            "limite_venda": 10.0
        }
    ])
    
    cenarios.to_csv(os.path.join(PROCESSED_DIR, "cenarios_final.csv"), index=False)
    geracao.to_csv(os.path.join(PROCESSED_DIR, "geracao_estocastica.csv"), index=False)
    legacy.to_csv(os.path.join(PROCESSED_DIR, "contratos_legacy.csv"), index=False)
    trades.to_csv(os.path.join(PROCESSED_DIR, "trades.csv"), index=False)
    
    print("✅ Toy Problem 4 Meses gerado com sucesso!")

if __name__ == "__main__":
    gerar_toy_problem_4m()