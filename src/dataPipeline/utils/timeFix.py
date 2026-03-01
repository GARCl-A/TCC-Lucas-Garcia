import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location("config", os.path.join(os.path.dirname(__file__), "..", "config.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

DATA_DIR = config.PROCESSED_DIR
ARQUIVO_ALVO = "cenarios_final.csv"
OFFSET_ANOS = config.OFFSET_ANOS


def aplicar_timeshift():
    print(
        f"⏳ Iniciando Time Shift de +{OFFSET_ANOS} anos no arquivo {ARQUIVO_ALVO}..."
    )

    path_arq = os.path.join(DATA_DIR, ARQUIVO_ALVO)

    if not os.path.exists(path_arq):
        print("❌ Arquivo não encontrado.")
        return

    # 1. Ler
    df = pd.read_csv(path_arq)

    # Guardar estatística antes
    min_ano_antes = df["ano"].min()
    max_ano_antes = df["ano"].max()

    # 2. Aplicar Shift
    df["ano"] = df["ano"] + OFFSET_ANOS

    # Recalcular a coluna 'data' para bater com o novo ano
    df["data"] = pd.to_datetime(dict(year=df["ano"], month=df["mes"], day=1))

    # 3. Salvar por cima (ou novo arquivo se preferir)
    df.to_csv(path_arq, index=False)

    print("✅ Datas atualizadas com sucesso!")
    print(f"   Antes: {min_ano_antes} a {max_ano_antes}")
    print(f"   Agora: {df['ano'].min()} a {df['ano'].max()}")
    print("   (Não esqueça de rodar o gerador de Trades novamente depois disso!)")


if __name__ == "__main__":
    aplicar_timeshift()
