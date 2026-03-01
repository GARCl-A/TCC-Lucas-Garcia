import pandas as pd
import os
import importlib.util

spec = importlib.util.spec_from_file_location("config", os.path.join(os.path.dirname(__file__), "..", "config.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

RAW_FILE = os.path.join(config.RAW_CMARG_DIR, "patamar.dat")
OUTPUT_FILE = os.path.join(config.PROCESSED_DIR, "patamar.csv")


def converter_patamar():
    print(f"📖 Lendo arquivo: {RAW_FILE}")

    try:
        with open(RAW_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print("❌ Arquivo patamar.dat não encontrado.")
        return

    dados = []
    ano_atual = None

    for line in lines:
        parts = line.strip().split()
        if not parts:
            continue

        if len(parts) > 12 and parts[0].isdigit() and len(parts[0]) == 4:
            ano_atual = int(parts[0])
            duracoes = parts[1:]
            patamar = 1

        elif len(parts) == 12:
            if ano_atual is None:
                continue

            try:
                float(parts[0])
                patamar += 1
                duracoes = parts
            except ValueError:
                continue
        else:
            continue

        if ano_atual and len(duracoes) == 12:
            for i, valor_str in enumerate(duracoes):
                try:
                    valor = float(valor_str)
                    dados.append(
                        {
                            "ano": ano_atual,
                            "mes": i + 1,
                            "patamar": patamar,
                            "duracao": valor,
                        }
                    )
                except ValueError:
                    continue

    if dados:
        df = pd.DataFrame(dados)
        df.to_csv(OUTPUT_FILE, index=False)
        print(f"✅ Arquivo gerado: {OUTPUT_FILE}")
        print(f"📊 Total de registros: {len(df)}")
        print(df.head())
    else:
        print("⚠️ Nenhum dado foi extraído. Verifique o formato do arquivo.")


if __name__ == "__main__":
    converter_patamar()
