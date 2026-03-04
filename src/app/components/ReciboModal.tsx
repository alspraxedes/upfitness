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

  // Função para gerar link do WhatsApp (CORRIGIDA)
  const handleWhatsApp = () => {
    // Monte o texto normal e encode no final (não use %0A manual)
    const linhas: string[] = [];

    linhas.push('*COMPROVANTE UPFITNESS*');
    linhas.push('--------------------------------');

    if (dados.cliente?.trim()) {
      linhas.push(`Cliente: ${dados.cliente.trim()}`);
      linhas.push('--------------------------------');
    }

    dados.itens.forEach((item) => {
      const unit = f(item.preco_venda);
      const totalItem = f(item.preco_venda * item.quantidade);
      // Ex: 2x Legging (M) | un: R$ 49,90 | item: R$ 99,80
      linhas.push(
        `${item.quantidade}x ${item.descricao} (${item.tamanho}) | un: ${unit} | item: ${totalItem}`
      );
    });

    linhas.push('--------------------------------');
    linhas.push(`Subtotal: ${f(dados.subtotal)}`);
    if (dados.desconto > 0) linhas.push(`Desconto: - ${f(dados.desconto)}`);
    linhas.push(`*TOTAL: ${f(dados.totalFinal)}*`);
    linhas.push(`Pagamento: ${dados.metodoPagamento}`);
    linhas.push(`Data: ${dados.data.toLocaleString('pt-BR')}`);

    const texto = linhas.join('\n');
    const url = `https://wa.me/?text=${encodeURIComponent(texto)}`;

    window.open(url, '_blank', 'noopener,noreferrer');
  };

  return (
    <div className="fixed inset-0 bg-black/80 z-[60] flex items-center justify-center p-4 backdrop-blur-sm">
      <div className="bg-white text-black w-full max-w-sm rounded-lg shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* ÁREA DO RECIBO (VISUAL NA TELA) */}
        <div className="p-6 overflow-y-auto bg-yellow-50 font-mono text-sm leading-relaxed" ref={printRef}>
          <div className="text-center mb-4">
            <h2 className="text-xl font-black uppercase tracking-tighter">UPFITNESS</h2>
            <p className="text-xs text-gray-600">Moda Fitness & Casual</p>
            <p className="text-[10px] text-gray-500 mt-1">{dados.data.toLocaleString('pt-BR')}</p>
            {dados.cliente?.trim() && (
              <p className="text-[10px] text-gray-700 mt-1">
                Cliente: <span className="font-bold">{dados.cliente.trim()}</span>
              </p>
            )}
          </div>

          <div className="border-b-2 border-dashed border-gray-300 my-4"></div>

          <div className="space-y-2">
            {dados.itens.map((item, i) => (
              <div key={i} className="space-y-1">
                {/* Linha 1: descrição */}
                <div className="flex justify-between items-start">
                  <div className="flex-1 pr-2">
                    <span className="font-bold">{item.quantidade}x</span> {item.descricao}{' '}
                    <span className="text-xs text-gray-500">({item.tamanho})</span>
                  </div>
                  <div className="whitespace-nowrap font-bold">
                    {f(item.preco_venda * item.quantidade)}
                  </div>
                </div>

                {/* Linha 2: preço unitário */}
                <div className="flex justify-between text-[11px] text-gray-600">
                  <span>Unitário</span>
                  <span>{f(item.preco_venda)}</span>
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