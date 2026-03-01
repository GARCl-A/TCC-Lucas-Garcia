from dataCleanScripts import readCmarg, readPatamar
from dataProcessScripts import processPatamar
from utils import timeFix
from generators import generation_stochastic, contracts, trades


def main():
    print("Iniciando Pipeline")

    # Fase 1: Preços
    readCmarg.main()
    readPatamar.converter_patamar()
    processPatamar.processar_merge_final()
    timeFix.aplicar_timeshift()

    # Fase 2: Física
    generation_stochastic.main()

    # Fase 3: Portfólio Financeiro
    contracts.processar_contratos_legados()
    trades.gerar_trades()

    print("Pipeline concluído!")


if __name__ == "__main__":
    main()
