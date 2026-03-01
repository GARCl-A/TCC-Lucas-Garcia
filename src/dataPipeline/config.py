# config.py

# ============================================
# PARÂMETROS TEMPORAIS
# ============================================
ANO_INICIO = 2021
ANO_FIM = 2025
OFFSET_ANOS = 4  # Offset para ajustar dados históricos ao período desejado

# ============================================
# PATHS DE DADOS
# ============================================
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_ROOT = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "data"))

# Dados Brutos
RAW_CMARG_DIR = os.path.join(DATA_ROOT, "cmarg")
RAW_CCEE_GERACAO_DIR = os.path.join(DATA_ROOT, "ccee", "geracao_usina")
RAW_CCEE_CONTRATOS_DIR = os.path.join(DATA_ROOT, "ccee", "contratos")

# Dados Processados
PROCESSED_DIR = os.path.join(DATA_ROOT, "processed")

# ============================================
# SELEÇÃO DE USINAS
# ============================================
USINAS_SELECIONADAS = [8578, 110222, 81285]  # Se vazio ou None, pega todas

# ============================================
# PARÂMETROS DE MERCADO
# ============================================
PERCENTUAL_CONTRATO_LEGADO = 0.80  # 80% da produção vendida em contratos
SPREAD_TRADES = 0.01  # 1% de spread bid-ask
LIMITE_LOTE_TRADES = 100  # MWm por lote
PRECO_CONTRATO_DEFAULT = 230.00  # R$/MWh - Fallback se não houver dados

# ============================================
# PARÂMETROS TÉCNICOS
# ============================================
DURACAO_PATAMAR_DEFAULT = 0.333333  # Fallback quando não há dados de patamar

# ============================================
# LIMITES PLD (ANEEL)
# ============================================
LIMITES_PLD = {
    2017: (33.68, 533.82),
    2018: (40.16, 505.18),
    2019: (42.35, 513.89),
    2020: (39.68, 559.75),
    2021: (49.77, 583.88),
    2022: (55.70, 646.58),
    2023: (69.04, 684.73),
    2024: (61.07, 716.80),
    2025: (58.60, 751.73),
    2026: (57.31, 785.27),
}
