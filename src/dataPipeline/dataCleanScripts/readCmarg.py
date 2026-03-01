import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location("config", os.path.join(os.path.dirname(__file__), "..", "config.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

RAW_DIR = config.RAW_CMARG_DIR
PROCESSED_DIR = config.PROCESSED_DIR

os.makedirs(PROCESSED_DIR, exist_ok=True)

mapa_arquivos = {
    "cmarg001.out": "SE",
    "cmarg002.out": "S",
    "cmarg003.out": "NE",
    "cmarg004.out": "N",
}


def converter_cmarg_bruto(filepath, submercado):
    print(f"🔄 Processando {os.path.basename(filepath)}...")

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"❌ Arquivo não encontrado: {filepath}")
        return

    dados = []
    ano_atual = None
    serie_atual = None

    for line in lines:
        parts = line.split()
        if not parts:
            continue

        if parts[0] == "ANO:":
            ano_atual = int(parts[1])
            continue

        if not parts[0].isdigit():
            continue

        num_floats = 13

        if len(parts) == 2 + num_floats:
            serie_atual = int(parts[0])
            patamar = int(parts[1])
            valores = parts[2:-1]

        elif len(parts) == 1 + num_floats:
            if serie_atual is None:
                continue
            patamar = int(parts[0])
            valores = parts[1:-1]

        else:
            continue

        for i, val_str in enumerate(valores):
            try:
                valor = float(val_str.replace(",", "."))
                dados.append(
                    {
                        "submercado": submercado,
                        "ano": ano_atual,
                        "cenario": serie_atual,
                        "patamar": patamar,
                        "mes": i + 1,
                        "valor": valor,
                    }
                )
            except ValueError:
                continue

    df = pd.DataFrame(dados)

    nome_saida = os.path.basename(filepath).replace(".out", ".csv")
    caminho_saida = os.path.join(PROCESSED_DIR, nome_saida)

    df.to_csv(caminho_saida, index=False)
    print(f"✅ Salvo: {caminho_saida} | Linhas: {len(df)}")


def main():
    print("--- INÍCIO DA CONVERSÃO (PASSO 1) ---")
    for arq, sub in mapa_arquivos.items():
        caminho_full = os.path.join(RAW_DIR, arq)
        converter_cmarg_bruto(caminho_full, sub)
    print("--- FIM ---")


if __name__ == "__main__":
    main()
