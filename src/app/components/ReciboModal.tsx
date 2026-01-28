'use client';

import { useRef } from 'react';

interface ItemVenda {
  descricao: string;
  quantidade: number;
  preco_venda: number;
  tamanho: string;
}

interface ReciboProps {
  visivel: boolean;
  onClose: () => void;
  dados: {
    itens: ItemVenda[];
    subtotal: number;
    desconto: number;
    totalFinal: number;
    metodoPagamento: string;
    data: Date;
    cliente?: string; // Opcional
  } | null;
}

export default function ReciboModal({ visivel, onClose, dados }: ReciboProps) {
  const printRef = useRef<HTMLDivElement>(null);

  if (!visivel || !dados) return null;

  // Formata moeda
  const f = (n: number) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(n);

  // Função para imprimir (Gera PDF nativo)
  const handlePrint = () => {
    const conteudo = printRef.current?.innerHTML;
    const janela = window.open('', '', 'height=600,width=400');
    
    if (janela && conteudo) {
      janela.document.write('<html><head><title>Recibo UPFITNESS</title>');
      janela.document.write('<style>');
      janela.document.write(`
        body { font-family: 'Courier New', monospace; font-size: 12px; padding: 20px; }
        .center { text-align: center; }
        .line { border-bottom: 1px dashed #000; margin: 10px 0; }
        .row { display: flex; justify-content: space-between; margin-bottom: 5px; }
        .bold { font-weight: bold; }
        .title { font-size: 16px; font-weight: bold; margin-bottom: 5px; }
        .btn-hide { display: none; } 
      `);
      janela.document.write('</style></head><body>');
      janela.document.write(conteudo);
      janela.document.write('</body></html>');
      janela.document.close();
      janela.print();
    }
  };

  // Função para gerar link do WhatsApp
  const handleWhatsApp = () => {
    let texto = `*COMPROVANTE UPFITNESS*%0A`;
    texto += `--------------------------------%0A`;
    dados.itens.forEach(item => {
      texto += `${item.quantidade}x ${item.descricao} (${item.tamanho})%0A`;
    });
    texto += `--------------------------------%0A`;
    texto += `*TOTAL: ${f(dados.totalFinal)}*%0A`;
    
    window.open(`https://wa.me/?text=${texto}`, '_blank');
  };

  return (
    <div className="fixed inset-0 bg-black/80 z-[60] flex items-center justify-center p-4 backdrop-blur-sm">
      <div className="bg-white text-black w-full max-w-sm rounded-lg shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        
        {/* ÁREA DO RECIBO (VISUAL NA TELA) */}
        <div className="p-6 overflow-y-auto bg-yellow-50 font-mono text-sm leading-relaxed" ref={printRef}>
          <div className="text-center mb-4">
            <h2 className="text-xl font-black uppercase tracking-tighter">UPFITNESS</h2>
            <p className="text-xs text-gray-600">Moda Fitness & Casual</p>
            <p className="text-[10px] text-gray-500 mt-1">{dados.data.toLocaleString()}</p>
          </div>

          <div className="border-b-2 border-dashed border-gray-300 my-4"></div>

          <div className="space-y-2">
            {dados.itens.map((item, i) => (
              <div key={i} className="flex justify-between items-start">
                <div className="flex-1 pr-2">
                  <span className="font-bold">{item.quantidade}x</span> {item.descricao} <span className="text-xs text-gray-500">({item.tamanho})</span>
                </div>
                <div className="whitespace-nowrap font-medium">
                  {f(item.preco_venda * item.quantidade)}
                </div>
              </div>
            ))}
          </div>

          <div className="border-b-2 border-dashed border-gray-300 my-4"></div>

          <div className="space-y-1 text-right">
            <div className="flex justify-between text-gray-600">
              <span>Subtotal</span>
              <span>{f(dados.subtotal)}</span>
            </div>
            {dados.desconto > 0 && (
              <div className="flex justify-between text-red-600">
                <span>Desconto</span>
                <span>- {f(dados.desconto)}</span>
              </div>
            )}
            <div className="flex justify-between text-lg font-black mt-2">
              <span>TOTAL</span>
              <span>{f(dados.totalFinal)}</span>
            </div>
            <div className="text-xs text-gray-500 mt-1 uppercase">
              Pagamento: {dados.metodoPagamento}
            </div>
          </div>
          
          <div className="mt-8 text-center text-[10px] text-gray-400">
            <p>Obrigado pela preferência!</p>
            <p>Volte sempre :)</p>
          </div>
        </div>

        {/* BOTÕES DE AÇÃO */}
        <div className="p-4 bg-gray-100 flex flex-col gap-2 border-t">
          <button 
            onClick={handlePrint}
            className="w-full bg-slate-800 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-slate-700 transition-colors"
          >
            🖨️ Imprimir / PDF
          </button>
          
          <button 
            onClick={handleWhatsApp}
            className="w-full bg-emerald-600 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-emerald-500 transition-colors"
          >
            💬 Enviar no WhatsApp
          </button>

          <button 
            onClick={onClose}
            className="w-full text-gray-500 py-2 text-sm hover:text-red-500 transition-colors"
          >
            Fechar / Nova Venda
          </button>
        </div>
      </div>
    </div>
  );
}