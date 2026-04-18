# config_instancia.jl
# ============================================================
# ÚNICA fonte da verdade para o tamanho da instância.
# Todos os scripts (deq.jl, sddp.jl, rodar_pipeline.jl)
# incluem este arquivo antes de chamar load_deq_config().
#
# AJUSTE AQUI antes de rodar qualquer script.
# ============================================================
const INSTANCIA_NUM_MESES = 6
const INSTANCIA_NUM_RAMOS = 7
