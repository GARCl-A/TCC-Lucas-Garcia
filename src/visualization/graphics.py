import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
from matplotlib.patches import Rectangle
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(BASE_DIR, "../..", "data", "processed", "resultados_fronteira.csv")
GRAPHICS_DIR = os.path.join(BASE_DIR, "../..", "data", "graphics")

def configure_plot_style():
    plt.style.use('seaborn-v0_8-whitegrid')
    plt.rcParams.update({
        'font.family': 'serif',
        'font.serif': ['Times New Roman'],
        'font.size': 11,
        'axes.labelsize': 12,
        'axes.titlesize': 14,
        'xtick.labelsize': 10,
        'ytick.labelsize': 10,
        'legend.fontsize': 10,
        'figure.titlesize': 16,
        'axes.linewidth': 0.8,
        'grid.alpha': 0.3
    })

def load_and_validate_data():
    if not os.path.exists(DATA_FILE):
        raise FileNotFoundError("Arquivo de resultados não encontrado. Execute o modelo Julia primeiro.")
    
    df = pd.read_csv(DATA_FILE)
    required_cols = ['Lambda', 'CVaR_Lucro_Milhoes', 'Retorno_Milhoes', 'Volume_Hedge_MW']
    
    if not all(col in df.columns for col in required_cols):
        raise ValueError(f"Colunas obrigatórias ausentes. Esperado: {required_cols}, Encontrado: {list(df.columns)}")
    
    # Remove linha do benchmark (Lambda = NaN)
    df = df.dropna(subset=['Lambda'])
    
    return df.sort_values('Lambda')

def create_efficient_frontier_plot(df):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 6))
    
    colors = plt.cm.viridis(np.linspace(0, 1, len(df)))
    
    scatter = ax1.scatter(df['CVaR_Lucro_Milhoes'], df['Retorno_Milhoes'], 
                         c=df['Lambda'], cmap='viridis', 
                         s=80, alpha=0.8, edgecolors='black', linewidth=0.5)
    
    ax1.plot(df['CVaR_Lucro_Milhoes'], df['Retorno_Milhoes'], 
             color='#2c3e50', linewidth=2, alpha=0.7, zorder=1)
    
    for i, (idx, row) in enumerate(df.iterrows()):
        if i % 2 == 0 or i == len(df) - 1:
            ax1.annotate(f'λ={row["Lambda"]:.1f}',
                        (row['CVaR_Lucro_Milhoes'], row['Retorno_Milhoes']),
                        xytext=(8, 8), textcoords='offset points',
                        fontsize=9, ha='left',
                        bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
    
    ax1.set_xlabel('CVaR 95% - Lucro Médio nos Piores Cenários (Milhões R$)', fontweight='bold')
    ax1.set_ylabel('Retorno Esperado (Milhões R$)', fontweight='bold')
    ax1.set_title('Fronteira Eficiente: Retorno vs. CVaR', fontweight='bold', pad=20)
    ax1.grid(True, alpha=0.3)
    
    cbar = plt.colorbar(scatter, ax=ax1, shrink=0.8)
    cbar.set_label('Parâmetro de Aversão ao Risco (λ)', fontweight='bold')
    
    bars = ax2.bar(range(len(df)), df['Volume_Hedge_MW'], 
                   color=colors, alpha=0.8, edgecolor='black', linewidth=0.5)
    
    ax2.set_xlabel('Configuração de Portfólio', fontweight='bold')
    ax2.set_ylabel('Volume de Hedge (MW)', fontweight='bold')
    ax2.set_title('Volume de Hedge por Nível de Aversão ao Risco', fontweight='bold', pad=20)
    ax2.set_xticks(range(len(df)))
    ax2.set_xticklabels([f'λ={x:.1f}' for x in df['Lambda']], rotation=45)
    ax2.grid(True, alpha=0.3, axis='y')
    
    for i, (bar, vol) in enumerate(zip(bars, df['Volume_Hedge_MW'])):
        if vol > 0:
            ax2.text(bar.get_x() + bar.get_width()/2, bar.get_height() + max(df['Volume_Hedge_MW'])*0.01,
                    f'{vol:.0f}', ha='center', va='bottom', fontsize=8, fontweight='bold')
    
    plt.tight_layout()
    return fig

def add_statistical_annotations(df, ax):
    risk_range = df['CVaR_Lucro_Milhoes'].max() - df['CVaR_Lucro_Milhoes'].min()
    return_range = df['Retorno_Milhoes'].max() - df['Retorno_Milhoes'].min()
    
    stats_text = f"""Estatísticas da Fronteira:
• Amplitude CVaR: R$ {risk_range:.1f} Mi
• Amplitude Retorno: R$ {return_range:.1f} Mi
• Pontos analisados: {len(df)}"""
    
    ax.text(0.02, 0.98, stats_text, transform=ax.transAxes, 
            verticalalignment='top', fontsize=9,
            bbox=dict(boxstyle='round,pad=0.5', facecolor='lightgray', alpha=0.8))

def save_publication_quality_plot(fig, filename="fronteira_eficiente_cientifica"):
    os.makedirs(GRAPHICS_DIR, exist_ok=True)
    
    formats = ['png', 'pdf', 'svg']
    
    for fmt in formats:
        filepath = os.path.join(GRAPHICS_DIR, f"{filename}.{fmt}")
        dpi = 300 if fmt == 'png' else None
        fig.savefig(filepath, format=fmt, dpi=dpi, bbox_inches='tight', 
                   facecolor='white', edgecolor='none')
        print(f"✅ Gráfico salvo: {filepath}")

def generate_scientific_plot():
    try:
        configure_plot_style()
        df = load_and_validate_data()
        
        fig = create_efficient_frontier_plot(df)
        add_statistical_annotations(df, fig.axes[0])
        
        save_publication_quality_plot(fig)
        
        plt.show()
        
    except Exception as e:
        print(f"❌ Erro: {e}")
        return False
    
    return True

if __name__ == "__main__":
    generate_scientific_plot()
