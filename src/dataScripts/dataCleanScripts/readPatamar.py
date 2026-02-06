import pandas as pd
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_FILE = os.path.join(BASE_DIR, "../..", "data", "cmarg", "patamar.dat")
OUTPUT_FILE = os.path.join(BASE_DIR, "../..", "data", "processed", "patamar.csv")


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
