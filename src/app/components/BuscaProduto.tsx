'use client';

// ============================================================================
// BuscaProduto — overlay tela cheia que reproduz o fluxo de busca da tela
// /venda de forma reutilizável: input de busca -> lista -> seleção de tamanho
// -> definição de quantidade/preço -> callback onEscolher.
//
// Sem scanner de código de barras (a versão inline em /venda continua sendo
// a única com câmera/upload de foto). Se um dia isso for necessário aqui,
// dá para adicionar como próxima iteração — o RPC não muda.
//
// Ordem de z-index para conviver com outros modais:
//   overlay principal:  z-[70]
//   size picker:        z-[75]
//   qty/preço picker:   z-[80]
// (o EditarItensVendaModal usa z-[60], histórico usa z-[50] e menores.)
// ============================================================================

import { useEffect, useMemo, useState, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import { thumbUrlFromFotoUrl } from '../../lib/thumbUtils';

// --- TIPOS ---
type EstoqueItem = {
  id: string;
  quantidade: number;
  codigo_barras: string | null;
  tamanho: { nome: string; ordem: number } | null;
};

type Produto = {
  id: string;
  codigo_peca: string;
  sku_fornecedor: string | null;
  descricao: string;
  cor: string | null;
  foto_url: string | null;
  preco_venda: number;
  estoque: EstoqueItem[];
};

export type ProdutoEscolhido = {
  produto_id: string;
  estoque_id: string;
  descricao_completa: string; // "Descricao - Cor (Tamanho)"
  quantidade: number;
  preco_unitario: number;
  // metadados úteis pro pai renderizar cartões
  descricao: string;
  cor: string;
  tamanho: string;
  foto_url: string | null;
  estoque_disponivel: number;
};

type Props = {
  onEscolher: (payload: ProdutoEscolhido) => void;
  onFechar: () => void;
  /** Se true (default), esconde produtos sem nenhum estoque. */
  filtroSomenteComEstoque?: boolean;
  /** Título mostrado no header do overlay. */
  titulo?: string;
};

// --- UTILITÁRIOS (locais para não acoplar a página /venda) ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

const ordenarEstoque = (estoque: EstoqueItem[]) =>
  [...estoque].sort((a, b) => (a.tamanho?.ordem ?? 999) - (b.tamanho?.ordem ?? 999));

const parseValorDigitado = (s: string) => {
  const v = parseFloat(String(s).replace(',', '.'));
  return isNaN(v) ? 0 : v;
};

const valorParaStr = (v: number) => v.toFixed(2).replace('.', ',');
const sanitizeValor = (s: string) => s.replace(/[^0-9.,]/g, '');

// ============================================================================
export default function BuscaProduto({
  onEscolher,
  onFechar,
  filtroSomenteComEstoque = true,
  titulo = 'Buscar produto',
}: Props) {
  const [produtos, setProdutos] = useState<Produto[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erroFetch, setErroFetch] = useState<string | null>(null);
  const [busca, setBusca] = useState('');
  const [selecionado, setSelecionado] = useState<Produto | null>(null);
  const [itemPendente, setItemPendente] = useState<{
    produto: Produto;
    est: EstoqueItem;
    qtdStr: string;
    precoStr: string;
  } | null>(null);
  // (bucket 'produtos' agora é público — thumbs derivadas via thumbUrlFromFotoUrl)

  // --- FETCH inicial ---
  useEffect(() => {
    let cancelado = false;
    (async () => {
      setCarregando(true);
      setErroFetch(null);
      const PAGE = 1000;
      const todos: Produto[] = [];
      try {
        for (let from = 0; ; from += PAGE) {
          const { data, error } = await supabase
            .from('produtos')
            .select(
              `id, codigo_peca, sku_fornecedor, descricao, cor, foto_url, preco_venda,
               estoque ( id, quantidade, codigo_barras, tamanho:tamanhos(nome, ordem) )`,
            )
            .eq('descontinuado', false)
            .order('descricao', { ascending: true })
            .range(from, from + PAGE - 1);
          if (error) throw new Error(error.message);
          const lote = (data ?? []) as unknown as Produto[];
          todos.push(...lote);
          if (lote.length < PAGE) break;
        }
        if (!cancelado) setProdutos(todos);
      } catch (e: any) {
        if (!cancelado) setErroFetch(e?.message || String(e));
      } finally {
        if (!cancelado) setCarregando(false);
      }
    })();
    return () => {
      cancelado = true;
    };
  }, []);

  // --- FILTRO (mesma lógica multi-termo da tela de venda) ---
  const disponiveis = useMemo(() => {
    if (!filtroSomenteComEstoque) return produtos;
    return produtos.filter(
      (p) => p.estoque.reduce((acc, est) => acc + (Number(est.quantidade) || 0), 0) > 0,
    );
  }, [produtos, filtroSomenteComEstoque]);

  const visiveis = useMemo(() => {
    const q = busca.toLowerCase().trim();
    if (!q) return disponiveis;
    const termos = q.split(/\s+/).filter(Boolean);
    return disponiveis.filter((p) => {
      const descricao = (p.descricao || '').toLowerCase();
      const codigo = (p.codigo_peca || '').toLowerCase();
      const sku = (p.sku_fornecedor || '').toLowerCase();
      const cor = (p.cor || '').toLowerCase();
      return termos.every((t) => {
        if (descricao.includes(t)) return true;
        if (codigo.includes(t)) return true;
        if (sku.includes(t)) return true;
        if (cor.includes(t)) return true;
        if (p.estoque.some((e) => (e.codigo_barras || '').includes(t))) return true;
        return false;
      });
    });
  }, [busca, disponiveis]);

  // (não precisa mais assinar URLs — bucket público. Thumbs derivadas
  // via thumbUrlFromFotoUrl no lugar de renderização.)

  // --- HANDLERS ---
  const abrirTamanhos = useCallback((p: Produto) => {
    setSelecionado(p);
    setBusca('');
  }, []);

  const escolherTamanho = useCallback((produto: Produto, est: EstoqueItem) => {
    setItemPendente({
      produto,
      est,
      qtdStr: '1',
      precoStr: valorParaStr(produto.preco_venda),
    });
    setSelecionado(null);
  }, []);

  const confirmarItem = useCallback(() => {
    if (!itemPendente) return;
    const { produto, est, qtdStr, precoStr } = itemPendente;
    const qtd = Math.max(0, Math.floor(Number(qtdStr) || 0));
    const preco = Math.max(0, parseValorDigitado(precoStr));
    if (qtd <= 0) {
      alert('Quantidade precisa ser maior que zero.');
      return;
    }
    if (qtd > est.quantidade) {
      alert(`Estoque insuficiente. Disponível: ${est.quantidade}.`);
      return;
    }
    if (preco <= 0) {
      alert('Preço precisa ser maior que zero.');
      return;
    }
    const tamNome = est.tamanho?.nome ?? '';
    const cor = produto.cor ?? '';
    const descCompleta = `${produto.descricao} - ${cor} (${tamNome})`;
    onEscolher({
      produto_id: produto.id,
      estoque_id: est.id,
      descricao_completa: descCompleta,
      quantidade: qtd,
      preco_unitario: preco,
      descricao: produto.descricao,
      cor,
      tamanho: tamNome,
      foto_url: produto.foto_url,
      estoque_disponivel: est.quantidade,
    });
    setItemPendente(null);
  }, [itemPendente, onEscolher]);

  // --- RENDER ---
  return (
    <div className="fixed inset-0 z-[70] bg-slate-950 flex flex-col animate-in fade-in duration-150">
      {/* HEADER */}
      <div className="shrink-0 px-4 pt-[calc(env(safe-area-inset-top,0px)+1rem)] pb-3 border-b border-slate-800 bg-slate-950">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-lg font-black uppercase text-white tracking-tighter truncate">
            {titulo}
          </h3>
          <button
            onClick={onFechar}
            className="shrink-0 w-10 h-10 rounded-full bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white font-bold text-xl active:scale-90 transition"
            aria-label="Fechar busca"
          >
            ✕
          </button>
        </div>
        <input
          autoFocus
          type="text"
          placeholder="🔎 Nome, cor, SKU ou EAN..."
          className="mt-3 w-full p-4 rounded-2xl bg-slate-900 border-2 border-slate-800 focus:border-pink-500 outline-none text-base font-bold shadow-xl text-white h-14"
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
        />
      </div>

      {/* LISTA */}
      <div className="flex-1 overflow-y-auto pb-[calc(env(safe-area-inset-bottom,0px)+1rem)]">
        {carregando ? (
          <div className="p-8 text-center text-slate-500 text-xs font-bold uppercase tracking-widest">
            Carregando produtos…
          </div>
        ) : erroFetch ? (
          <div className="p-6 mx-4 mt-4 rounded-xl border border-red-900/50 bg-red-950/30">
            <p className="text-[11px] text-red-300 font-bold whitespace-pre-wrap">{erroFetch}</p>
          </div>
        ) : (
          <div className="bg-slate-900 border-y border-slate-800">
            <div className="px-4 py-3 border-b border-slate-800 flex items-center justify-between">
              <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">
                Itens disponíveis
              </span>
              <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">
                {visiveis.length} itens
              </span>
            </div>
            {visiveis.length === 0 ? (
              <div className="p-6 text-center text-slate-500 text-xs font-bold uppercase tracking-widest">
                Nenhum item encontrado
              </div>
            ) : (
              visiveis.map((p, idx) => {
                const thumbUrl = thumbUrlFromFotoUrl(p.foto_url);
                return (
                  <button
                    key={p.id}
                    onClick={() => abrirTamanhos(p)}
                    className="w-full text-left p-4 hover:bg-slate-800 border-b border-slate-800/60 last:border-0 flex justify-between items-center transition-colors active:bg-slate-700 gap-4"
                  >
                    <div className="flex items-center gap-4 min-w-0">
                      <div className="w-12 h-12 rounded-xl bg-slate-950 border border-slate-800 overflow-hidden flex items-center justify-center flex-shrink-0">
                        {thumbUrl ? (
                          <img
                            src={thumbUrl}
                            className="w-full h-full object-cover"
                            alt=""
                            loading={idx < 6 ? 'eager' : 'lazy'}
                            decoding="async"
                          />
                        ) : (
                          <span className="text-lg opacity-60">📷</span>
                        )}
                      </div>
                      <div className="min-w-0">
                        <p className="font-bold text-white text-sm uppercase truncate">
                          {p.descricao}
                        </p>
                        <p className="text-[10px] font-mono text-slate-400 truncate">
                          {p.codigo_peca} | {p.cor}
                        </p>
                      </div>
                    </div>
                    <span className="font-black text-emerald-400 text-sm whitespace-nowrap">
                      {formatBRL(p.preco_venda)}
                    </span>
                  </button>
                );
              })
            )}
          </div>
        )}
      </div>

      {/* MODAL SELEÇÃO DE TAMANHO */}
      {selecionado && (
        <div
          className="fixed inset-0 z-[75] bg-black/90 backdrop-blur-sm flex items-end md:items-center justify-center p-0 md:p-6 animate-in fade-in duration-200"
          onClick={() => setSelecionado(null)}
        >
          <div
            className="bg-slate-900 w-full max-w-lg rounded-t-[2rem] md:rounded-[2rem] p-6 border-t md:border border-slate-800 shadow-2xl relative max-h-[90vh] overflow-hidden flex flex-col"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex justify-between items-start mb-6 shrink-0 gap-4">
              <div className="flex items-start gap-4 min-w-0">
                <div className="w-16 h-16 rounded-2xl bg-slate-950 border border-slate-800 overflow-hidden flex items-center justify-center shrink-0">
                  {selecionado.foto_url && thumbUrlFromFotoUrl(selecionado.foto_url) ? (
                    <img
                      src={thumbUrlFromFotoUrl(selecionado.foto_url)!}
                      className="w-full h-full object-cover"
                      alt=""
                      loading="eager"
                      decoding="async"
                    />
                  ) : (
                    <span className="text-2xl opacity-50">📷</span>
                  )}
                </div>
                <div className="min-w-0">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">
                    Selecionando:
                  </span>
                  <h2 className="text-xl font-black uppercase text-white leading-tight truncate">
                    {selecionado.descricao}
                  </h2>
                  <p className="text-xs text-slate-400 font-bold mt-1 uppercase truncate">
                    {selecionado.cor}
                  </p>
                </div>
              </div>
              <button
                onClick={() => setSelecionado(null)}
                className="bg-slate-800 w-10 h-10 rounded-full text-slate-400 hover:text-white font-bold text-xl active:scale-90 shrink-0"
              >
                ✕
              </button>
            </div>
            <div className="space-y-4 overflow-y-auto pr-1 pb-4">
              <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800">
                <div className="flex flex-wrap gap-2 justify-center">
                  {ordenarEstoque(selecionado.estoque).map((est) => {
                    const semEstoque = est.quantidade <= 0;
                    return (
                      <button
                        key={est.id}
                        disabled={semEstoque}
                        onClick={() => escolherTamanho(selecionado, est)}
                        className={`flex flex-col items-center justify-center w-16 h-16 rounded-xl border text-xs font-black uppercase transition-all active:scale-95 ${
                          !semEstoque
                            ? 'bg-slate-800 border-slate-600 text-white hover:bg-pink-600 hover:border-pink-500 shadow-lg'
                            : 'bg-red-950/10 border-red-900/20 text-red-800/50 cursor-not-allowed'
                        }`}
                      >
                        <span className="text-sm">{est.tamanho?.nome ?? '?'}</span>
                        <span
                          className={`text-[9px] ${
                            !semEstoque ? 'text-slate-400' : ''
                          }`}
                        >
                          {est.quantidade}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </div>
              <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center justify-between">
                <span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">
                  Preço
                </span>
                <span className="text-lg font-black text-emerald-400">
                  {formatBRL(selecionado.preco_venda)}
                </span>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* MODAL QUANTIDADE + PREÇO */}
      {itemPendente && (
        <div
          className="fixed inset-0 z-[80] bg-black/95 backdrop-blur-md flex items-end md:items-center justify-center p-0 md:p-4 animate-in fade-in duration-200"
          onClick={() => setItemPendente(null)}
        >
          <div
            className="bg-slate-900 w-full max-w-md rounded-t-[2.5rem] md:rounded-[2.5rem] border-t md:border border-slate-700 shadow-2xl overflow-hidden flex flex-col"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="bg-slate-950 p-5 border-b border-slate-800 flex justify-between items-start gap-3 shrink-0">
              <div className="min-w-0">
                <span className="text-[9px] font-black uppercase tracking-widest text-slate-500">
                  Confirmando
                </span>
                <h3 className="text-base font-black uppercase text-white leading-tight truncate">
                  {itemPendente.produto.descricao}
                </h3>
                <div className="flex items-center gap-2 mt-1">
                  <span className="text-[10px] font-bold text-slate-400 uppercase truncate">
                    {itemPendente.produto.cor}
                  </span>
                  <span className="text-[10px] font-black text-white bg-pink-600 px-2 py-0.5 rounded-md uppercase">
                    {itemPendente.est.tamanho?.nome ?? '?'}
                  </span>
                  <span className="text-[10px] font-bold text-slate-500 uppercase">
                    · {itemPendente.est.quantidade} disp.
                  </span>
                </div>
              </div>
              <button
                onClick={() => setItemPendente(null)}
                className="shrink-0 w-9 h-9 rounded-full bg-slate-800 text-slate-400 hover:text-white font-bold active:scale-90"
              >
                ✕
              </button>
            </div>

            <div className="p-5 space-y-4">
              <div>
                <label className="text-[10px] font-black uppercase tracking-widest text-slate-500 block mb-2">
                  Quantidade
                </label>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() =>
                      setItemPendente((prev) =>
                        prev
                          ? {
                              ...prev,
                              qtdStr: String(Math.max(1, (Number(prev.qtdStr) || 1) - 1)),
                            }
                          : prev,
                      )
                    }
                    className="w-12 h-14 rounded-xl bg-slate-800 hover:bg-slate-700 text-white text-2xl font-black active:scale-90"
                  >
                    −
                  </button>
                  <input
                    type="number"
                    inputMode="numeric"
                    min={1}
                    max={itemPendente.est.quantidade}
                    value={itemPendente.qtdStr}
                    onChange={(e) =>
                      setItemPendente((prev) =>
                        prev ? { ...prev, qtdStr: e.target.value } : prev,
                      )
                    }
                    className="flex-1 h-14 rounded-xl bg-slate-950 border-2 border-slate-800 focus:border-pink-500 outline-none text-center text-xl font-black text-white"
                  />
                  <button
                    type="button"
                    onClick={() =>
                      setItemPendente((prev) =>
                        prev
                          ? {
                              ...prev,
                              qtdStr: String(
                                Math.min(
                                  prev.est.quantidade,
                                  (Number(prev.qtdStr) || 0) + 1,
                                ),
                              ),
                            }
                          : prev,
                      )
                    }
                    className="w-12 h-14 rounded-xl bg-slate-800 hover:bg-slate-700 text-white text-2xl font-black active:scale-90"
                  >
                    +
                  </button>
                </div>
              </div>

              <div>
                <label className="text-[10px] font-black uppercase tracking-widest text-slate-500 block mb-2">
                  Preço unitário
                </label>
                <div className="relative">
                  <span className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-500 text-sm font-bold">
                    R$
                  </span>
                  <input
                    type="text"
                    inputMode="decimal"
                    value={itemPendente.precoStr}
                    onChange={(e) =>
                      setItemPendente((prev) =>
                        prev
                          ? { ...prev, precoStr: sanitizeValor(e.target.value) }
                          : prev,
                      )
                    }
                    className="w-full h-14 pl-12 pr-4 rounded-xl bg-slate-950 border-2 border-slate-800 focus:border-pink-500 outline-none text-xl font-black text-white"
                  />
                </div>
                <p className="text-[9px] text-slate-500 mt-1 font-bold uppercase">
                  Sugerido: {formatBRL(itemPendente.produto.preco_venda)}
                </p>
              </div>

              <div className="bg-slate-950 p-4 rounded-xl border border-slate-800 flex items-center justify-between">
                <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">
                  Subtotal
                </span>
                <span className="text-xl font-black text-emerald-400">
                  {formatBRL(
                    (Number(itemPendente.qtdStr) || 0) *
                      parseValorDigitado(itemPendente.precoStr),
                  )}
                </span>
              </div>
            </div>

            <div className="p-4 border-t border-slate-800 grid grid-cols-2 gap-3 shrink-0">
              <button
                onClick={() => setItemPendente(null)}
                className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition"
              >
                Cancelar
              </button>
              <button
                onClick={confirmarItem}
                className="bg-pink-600 hover:bg-pink-500 text-white py-4 rounded-xl font-black uppercase text-xs tracking-widest transition shadow-lg"
              >
                Confirmar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}