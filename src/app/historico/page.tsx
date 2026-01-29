'use client';

import { useEffect, useState, useRef, useMemo } from 'react';
import Link from 'next/link';
import { supabase } from '../../lib/supabase';

// --- TIPOS ATUALIZADOS ---
type ItemVenda = {
  id: string;
  descricao_completa: string;
  quantidade: number;
  preco_unitario: number;
  subtotal: number;
  estoque_id: string;
  // Estrutura aninhada para pegar os custos do produto via estoque
  estoque?: {
    produto?: {
      preco_compra: number;
      custo_frete: number;
      custo_embalagem: number;
    }
  }
};

type Venda = {
  id: string;
  codigo_venda: number;
  created_at: string;
  valor_total: number;
  valor_liquido: number;
  forma_pagamento: string;
  desconto: number;
  parcelas: number;
  itens_venda: ItemVenda[];
};

// --- UTILITÁRIOS ---
const formatBRL = (val: number) => 
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

const formatData = (dataIso: string) => {
  const d = new Date(dataIso);
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' });
};

export default function HistoricoPage() {
  const [vendas, setVendas] = useState<Venda[]>([]);
  const [loading, setLoading] = useState(true);
  
  // Filtros
  const [dataInicio, setDataInicio] = useState('');
  const [dataFim, setDataFim] = useState('');

  // Controles de Visualização
  const [expandidoId, setExpandidoId] = useState<string | null>(null);
  const [vendaRecibo, setVendaRecibo] = useState<Venda | null>(null);
  
  // Controles de Exclusão/Cancelamento
  const [modalConfirmacao, setModalConfirmacao] = useState<{ tipo: 'apagar' | 'cancelar', venda: Venda } | null>(null);
  const [processandoAcao, setProcessandoAcao] = useState(false);

  const printRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    fetchVendas();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function fetchVendas() {
    setLoading(true);
    
    // QUERY ATUALIZADA: Busca custos dentro de estoque -> produto
    let query = supabase
      .from('vendas')
      .select(`
        *,
        itens_venda (
          *,
          estoque (
            produto:produtos ( preco_compra, custo_frete, custo_embalagem )
          )
        )
      `)
      .order('created_at', { ascending: false });

    if (dataInicio) query = query.gte('created_at', `${dataInicio}T00:00:00`);
    if (dataFim) query = query.lte('created_at', `${dataFim}T23:59:59`);
    else if (!dataInicio) query = query.limit(50);

    const { data, error } = await query;
    if (!error) setVendas(data as any);
    setLoading(false);
  }

  // --- CÁLCULOS FINANCEIROS (Memoizado para performance) ---
  const metricas = useMemo(() => {
      let faturamento = 0;
      let custoTotal = 0;

      vendas.forEach(venda => {
          faturamento += (venda.valor_liquido || 0);
          
          venda.itens_venda.forEach(item => {
              const prod = item.estoque?.produto;
              if (prod) {
                  const custoUnitario = (prod.preco_compra || 0) + (prod.custo_frete || 0) + (prod.custo_embalagem || 0);
                  custoTotal += custoUnitario * item.quantidade;
              }
          });
      });

      const lucro = faturamento - custoTotal;
      // Margem baseada no Markup (Lucro sobre Custo) conforme lógica anterior, ou Margem Bruta (Lucro sobre Venda)
      // Vou usar Markup ((Venda - Custo) / Custo) para manter consistência com o cadastro de produtos
      const margem = custoTotal > 0 ? (lucro / custoTotal) * 100 : 0;

      return { faturamento, custoTotal, lucro, margem };
  }, [vendas]);

  // Lógica de Cancelamento/Exclusão
  const executarAcao = async () => {
    if (!modalConfirmacao) return;
    setProcessandoAcao(true);
    const { tipo, venda } = modalConfirmacao;

    try {
      if (tipo === 'cancelar') {
        for (const item of venda.itens_venda) {
          const { data: estAtual } = await supabase.from('estoque').select('quantidade').eq('id', item.estoque_id).single();
          if (estAtual) {
            await supabase.from('estoque').update({ quantidade: estAtual.quantidade + item.quantidade }).eq('id', item.estoque_id);
          }
        }
      }
      const { error } = await supabase.from('vendas').delete().eq('id', venda.id);
      if (error) throw error;
      setModalConfirmacao(null);
      fetchVendas(); 
    } catch (err: any) {
      alert('Erro: ' + err.message);
    } finally {
      setProcessandoAcao(false);
    }
  };

  const handlePrint = () => {
    const conteudo = printRef.current?.innerHTML;
    const janela = window.open('', '', 'height=600,width=400');
    if (janela && conteudo) {
      janela.document.write('<html><head><title>Recibo UPFITNESS</title><style>body { font-family: monospace; padding: 20px; } .row { display: flex; justify-content: space-between; }</style></head><body>');
      janela.document.write(conteudo);
      janela.document.close();
      janela.print();
    }
  };

  const handleWhatsApp = (v: Venda) => {
    let texto = `*COMPROVANTE UPFITNESS - PEDIDO #${v.codigo_venda}*%0A--------------------------------%0A`;
    v.itens_venda.forEach(item => texto += `${item.quantidade}x ${item.descricao_completa}%0A`);
    texto += `--------------------------------%0A*TOTAL: ${formatBRL(v.valor_liquido)}*`;
    window.open(`https://wa.me/?text=${texto}`, '_blank');
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-24">
      
      {/* HEADER */}
      <header className="bg-slate-900 p-6 border-b border-slate-800 sticky top-0 z-20 shadow-xl space-y-4">
        <div className="flex items-center gap-4">
            <Link href="/" className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95 transition">←</Link>
            <div><h1 className="font-black italic text-xl uppercase tracking-tighter">Histórico <span className="text-pink-600">Vendas</span></h1></div>
        </div>
        <div className="flex flex-col md:flex-row gap-3">
            <div className="flex gap-2 flex-1">
                <input type="date" value={dataInicio} onChange={e => setDataInicio(e.target.value)} className="bg-slate-950 border border-slate-700 text-white rounded-xl px-3 py-2 w-full text-xs font-bold uppercase" />
                <input type="date" value={dataFim} onChange={e => setDataFim(e.target.value)} className="bg-slate-950 border border-slate-700 text-white rounded-xl px-3 py-2 w-full text-xs font-bold uppercase" />
            </div>
            <button onClick={fetchVendas} className="bg-pink-600 text-white px-6 py-2 rounded-xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95 hover:bg-pink-500 transition">Filtrar</button>
        </div>
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">
        
        {/* DASHBOARD DE MÉTRICAS */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
             <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
                <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Faturamento</span>
                <p className="text-lg md:text-xl font-black text-white truncate">{formatBRL(metricas.faturamento)}</p>
             </div>
             <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
                <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Custo Peças</span>
                <p className="text-lg md:text-xl font-black text-red-400 truncate">{formatBRL(metricas.custoTotal)}</p>
             </div>
             <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
                <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Lucro Líquido</span>
                <p className="text-lg md:text-xl font-black text-emerald-400 truncate">{formatBRL(metricas.lucro)}</p>
             </div>
             <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
                <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Margem (Mk)</span>
                <p className="text-lg md:text-xl font-black text-pink-500 truncate">{metricas.margem.toFixed(1)}%</p>
             </div>
        </div>

        {loading ? (
          <div className="text-center py-10 opacity-50 animate-pulse"><p className="text-xs font-bold uppercase">Buscando vendas...</p></div>
        ) : vendas.length === 0 ? (
          <div className="text-center py-20 opacity-30"><span className="text-4xl grayscale">🧾</span><p className="mt-2 font-bold">Nenhuma venda encontrada.</p></div>
        ) : (
          <div className="space-y-3">
            {vendas.map((venda) => {
              const isExpanded = expandidoId === venda.id;
              // Cálculo individual de custo para exibir lucro por venda (opcional, mas útil)
              const custoVenda = venda.itens_venda.reduce((acc, item) => {
                  const p = item.estoque?.produto;
                  return acc + (item.quantidade * ((p?.preco_compra||0) + (p?.custo_frete||0) + (p?.custo_embalagem||0)));
              }, 0);
              const lucroVenda = venda.valor_liquido - custoVenda;

              return (
                <div key={venda.id} className={`bg-slate-900 rounded-2xl border transition-all overflow-hidden ${isExpanded ? 'border-pink-500/50 shadow-pink-900/10 shadow-lg' : 'border-slate-800 hover:border-slate-700'}`}>
                  <button onClick={() => setExpandidoId(isExpanded ? null : venda.id)} className="w-full p-4 flex justify-between items-center text-left">
                    <div>
                      <div className="flex items-center gap-2 mb-1">
                        <span className="text-xs font-bold text-slate-300 bg-slate-800 px-2 py-0.5 rounded-md border border-slate-700 font-mono">#{venda.codigo_venda}</span>
                        <span className="text-[10px] text-slate-400 font-bold uppercase">{formatData(venda.created_at)}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <span className={`text-[9px] font-black uppercase px-1.5 py-0.5 rounded text-slate-950 ${venda.forma_pagamento === 'pix' ? 'bg-emerald-400' : venda.forma_pagamento === 'credito' ? 'bg-blue-400' : 'bg-yellow-400'}`}>{venda.forma_pagamento}</span>
                        {!isExpanded && <span className="text-[10px] text-slate-500 font-bold uppercase">{venda.itens_venda.length} itens</span>}
                      </div>
                    </div>
                    <div className="text-right">
                      <span className="block text-lg font-black text-white">{formatBRL(venda.valor_liquido)}</span>
                      {isExpanded && <span className="block text-[10px] font-bold text-emerald-500">Lucro: {formatBRL(lucroVenda)}</span>}
                      <span className="text-[10px] text-slate-500 uppercase font-bold">{isExpanded ? '▲ Recolher' : '▼ Detalhes'}</span>
                    </div>
                  </button>

                  {isExpanded && (
                    <div className="bg-slate-950/50 border-t border-slate-800 p-4 animate-in slide-in-from-top-2 duration-200">
                        <div className="space-y-2 mb-4">
                            <p className="text-[10px] text-slate-500 font-bold uppercase tracking-widest mb-2">Itens do Pedido</p>
                            {venda.itens_venda.map(item => (
                                <div key={item.id} className="flex justify-between items-center text-sm border-b border-slate-800/50 pb-2 last:border-0 last:pb-0">
                                    <div className="text-slate-300"><span className="font-bold text-slate-500 mr-2">{item.quantidade}x</span>{item.descricao_completa}</div>
                                    <div className="font-mono text-slate-400 text-xs">{formatBRL(item.subtotal)}</div>
                                </div>
                            ))}
                        </div>
                        
                        <div className="flex flex-col gap-2 pt-2 border-t border-slate-800/50 mt-2">
                            <button onClick={() => setVendaRecibo(venda)} className="w-full bg-slate-800 hover:bg-slate-700 text-white py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest flex items-center justify-center gap-2 transition">📄 Ver Recibo / Imprimir</button>
                            
                            <div className="flex gap-2 mt-1">
                                <button 
                                    onClick={() => setModalConfirmacao({ tipo: 'apagar', venda })}
                                    className="flex-1 bg-red-950/30 hover:bg-red-900/50 text-red-500 border border-red-900/50 py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest flex items-center justify-center gap-2 transition"
                                >
                                    🗑️ Só Apagar
                                </button>
                                <button 
                                    onClick={() => setModalConfirmacao({ tipo: 'cancelar', venda })}
                                    className="flex-1 bg-orange-950/30 hover:bg-orange-900/50 text-orange-500 border border-orange-900/50 py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest flex items-center justify-center gap-2 transition"
                                >
                                    🚫 Cancelar (Estorno)
                                </button>
                            </div>
                        </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </main>

      {/* MODAL RECIBO */}
      {vendaRecibo && (
        <div className="fixed inset-0 z-50 bg-black/90 backdrop-blur-sm flex items-center justify-center p-4 animate-in fade-in duration-200">
          <div className="bg-white w-full max-w-sm rounded-lg shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
            <div className="p-6 bg-yellow-50 text-slate-900 font-mono text-sm overflow-y-auto" ref={printRef}>
              <div className="text-center mb-6 border-b-2 border-dashed border-slate-300 pb-4">
                <h3 className="font-black text-xl uppercase tracking-tighter">UPFITNESS</h3>
                <p className="text-xs text-slate-500">Recibo #{vendaRecibo.codigo_venda}</p>
                <p className="text-[10px] mt-1">{formatData(vendaRecibo.created_at)}</p>
              </div>
              <div className="space-y-3 mb-6">
                {vendaRecibo.itens_venda.map((item, idx) => (
                  <div key={idx} className="flex justify-between items-start text-xs">
                    <div className="pr-2"><span className="font-bold">{item.quantidade}x</span> {item.descricao_completa}</div>
                    <div className="font-bold whitespace-nowrap">{formatBRL(item.subtotal)}</div>
                  </div>
                ))}
              </div>
              <div className="border-t-2 border-dashed border-slate-300 pt-4 space-y-1 text-right">
                <div className="flex justify-between text-slate-500 text-xs"><span>Subtotal</span><span>{formatBRL(vendaRecibo.valor_total)}</span></div>
                {vendaRecibo.desconto > 0 && (<div className="flex justify-between text-red-600 text-xs font-bold"><span>Desconto</span><span>-{formatBRL(vendaRecibo.desconto)}</span></div>)}
                <div className="flex justify-between text-lg font-black mt-2"><span>TOTAL PAGO</span><span>{formatBRL(vendaRecibo.valor_liquido)}</span></div>
                <div className="text-[10px] uppercase text-slate-500 mt-2">Pagamento via {vendaRecibo.forma_pagamento} {vendaRecibo.parcelas > 1 ? ` (${vendaRecibo.parcelas}x)` : ''}</div>
              </div>
            </div>
            <div className="p-4 bg-slate-100 border-t border-slate-200 flex flex-col gap-2">
              <div className="flex gap-2">
                  <button onClick={handlePrint} className="flex-1 bg-slate-800 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-slate-700 transition-colors text-xs uppercase">🖨️ Imprimir</button>
                  <button onClick={() => handleWhatsApp(vendaRecibo)} className="flex-1 bg-emerald-600 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-emerald-500 transition-colors text-xs uppercase">💬 WhatsApp</button>
              </div>
              <button onClick={() => setVendaRecibo(null)} className="w-full text-slate-500 py-2 font-bold uppercase tracking-widest text-[10px] hover:text-red-500 transition">Fechar</button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL CONFIRMAÇÃO */}
      {modalConfirmacao && (
        <div className="fixed inset-0 z-[60] bg-black/95 backdrop-blur-md flex items-center justify-center p-6 animate-in zoom-in-95 duration-200">
            <div className="bg-slate-900 w-full max-w-sm rounded-3xl border border-slate-700 p-6 shadow-2xl relative">
                <div className="text-center space-y-4">
                    <div className={`w-16 h-16 rounded-full flex items-center justify-center mx-auto text-3xl ${modalConfirmacao.tipo === 'cancelar' ? 'bg-orange-500/20 text-orange-500' : 'bg-red-500/20 text-red-500'}`}>
                        {modalConfirmacao.tipo === 'cancelar' ? '🚫' : '🗑️'}
                    </div>
                    <h3 className="text-xl font-black uppercase text-white">
                        {modalConfirmacao.tipo === 'cancelar' ? 'Cancelar Venda?' : 'Apagar Registro?'}
                    </h3>
                    <p className="text-sm text-slate-400 leading-relaxed">
                        {modalConfirmacao.tipo === 'cancelar' 
                            ? <span>Você está prestes a cancelar a venda <b>#{modalConfirmacao.venda.codigo_venda}</b>. <br/><br/><span className="text-orange-400 font-bold">⚠️ O estoque dos itens será devolvido automaticamente.</span></span>
                            : <span>Você vai remover o registro da venda <b>#{modalConfirmacao.venda.codigo_venda}</b> do histórico. <br/><br/><span className="text-red-400 font-bold">⚠️ O estoque NÃO será alterado.</span></span>
                        }
                    </p>
                </div>
                <div className="grid grid-cols-2 gap-3 mt-8">
                    <button onClick={() => setModalConfirmacao(null)} className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition">Voltar</button>
                    <button onClick={executarAcao} disabled={processandoAcao} className={`py-4 rounded-xl font-black uppercase text-xs tracking-widest transition text-white shadow-lg ${modalConfirmacao.tipo === 'cancelar' ? 'bg-orange-600 hover:bg-orange-500' : 'bg-red-600 hover:bg-red-500'}`}>{processandoAcao ? 'Processando...' : 'Confirmar'}</button>
                </div>
            </div>
        </div>
      )}
    </div>
  );
}