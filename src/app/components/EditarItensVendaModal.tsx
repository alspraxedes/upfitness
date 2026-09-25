'use client';

// ============================================================================
// EditarItensVendaModal — modal de-para para editar itens de uma venda
// já concluída. Deixa marcar itens para excluir, trocar por outro produto
// e adicionar novos, tudo em estado local; só ao clicar em "Continuar" é
// que o RPC editar_itens_venda roda transacional no banco.
//
// UX pensada para tela pequena:
//   * Um cartão empilhado por item, com border-l-4 colorida indicando estado
//     (neutro / amarelo trocado / vermelho excluído / verde adicionado).
//   * Botões grandes (mínimo 44px), com ícone + texto curto.
//   * Rodapé sticky com botão "Adicionar item" + totais antes/agora + ações.
//   * Ao clicar "Trocar" ou "Adicionar", abre o BuscaProduto em tela cheia.
//
// Depois de salvar, o pai recebe { precisaReconciliar } para decidir se
// abre o EditarPagamentoModal em seguida (quando valor_liquido mudou).
// ============================================================================

import { useMemo, useState } from 'react';
import { supabase } from '../../lib/supabase';
import BuscaProduto, { type ProdutoEscolhido } from './BuscaProduto';

// --- TIPOS ---
type ItemVendaOriginal = {
  id: string;
  produto_id?: string | null;
  estoque_id: string | null;
  descricao_completa: string;
  quantidade: number;
  preco_unitario: number;
  subtotal: number;
};

type VendaEditavel = {
  id: string;
  codigo_venda: number;
  nome_cliente: string | null;
  valor_total: number;
  valor_liquido: number;
  desconto: number;
  itens_venda: ItemVendaOriginal[];
};

type ResultadoSave = {
  venda: any;
  itens: any[];
  precisa_reconciliar: boolean;
};

type Props = {
  venda: VendaEditavel;
  onSaved: (resultado: ResultadoSave) => void;
  onClose: () => void;
};

// Estado de cada cartão exibido no modal.
type CartaoState =
  | { kind: 'unchanged'; original: ItemVendaOriginal }
  | { kind: 'removed'; original: ItemVendaOriginal }
  | { kind: 'swapped'; original: ItemVendaOriginal; novo: ProdutoEscolhido }
  | { kind: 'added'; tempId: string; novo: ProdutoEscolhido };

// --- UTILITÁRIOS ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

function subtotalCartao(c: CartaoState): number {
  switch (c.kind) {
    case 'unchanged':
      return c.original.quantidade * c.original.preco_unitario;
    case 'removed':
      return 0;
    case 'swapped':
    case 'added':
      return c.novo.quantidade * c.novo.preco_unitario;
  }
}

function tempIdNovo() {
  return `add-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

// ============================================================================
export default function EditarItensVendaModal({ venda, onSaved, onClose }: Props) {
  // Estado local de cada cartão. Ordem inicial preserva a ordem dos itens
  // originais; adicionados vão para o final.
  const [cartoes, setCartoes] = useState<CartaoState[]>(() =>
    venda.itens_venda.map((it) => ({ kind: 'unchanged', original: it } as CartaoState)),
  );

  // Controla o BuscaProduto: null = fechado; caso contrário informa a operação
  // e, se for troca, qual cartão está sendo trocado.
  const [buscaAberta, setBuscaAberta] = useState<
    | null
    | { modo: 'adicionar' }
    | { modo: 'trocar'; cartaoIdx: number }
  >(null);

  const [salvando, setSalvando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [confirmarSemMudanca, setConfirmarSemMudanca] = useState(false);

  // --- CÁLCULOS ---
  const totalAntes = venda.valor_total;
  const totalAgora = useMemo(
    () => cartoes.reduce((acc, c) => acc + subtotalCartao(c), 0),
    [cartoes],
  );
  const totalAntesLiquido = venda.valor_liquido;
  // Preserva desconto absoluto — igual à regra do RPC.
  const descontoNovo = venda.desconto > totalAgora ? 0 : venda.desconto;
  const totalAgoraLiquido = Math.max(0, totalAgora - descontoNovo);
  const diffLiquido = totalAgoraLiquido - totalAntesLiquido;

  const temMudanca = useMemo(
    () => cartoes.some((c) => c.kind !== 'unchanged'),
    [cartoes],
  );

  const ficariaVazia = useMemo(
    () => cartoes.every((c) => c.kind === 'removed'),
    [cartoes],
  );

  // --- HANDLERS DE CARTÃO ---
  function marcarRemover(idx: number) {
    setCartoes((prev) =>
      prev.map((c, i) => {
        if (i !== idx) return c;
        if (c.kind === 'added') {
          // Adicionado ainda não foi salvo — some da lista de vez.
          return null as any;
        }
        if (c.kind === 'unchanged' || c.kind === 'swapped') {
          const orig = c.kind === 'unchanged' ? c.original : c.original;
          return { kind: 'removed', original: orig };
        }
        return c;
      }).filter(Boolean) as CartaoState[],
    );
  }

  function desfazerRemover(idx: number) {
    setCartoes((prev) =>
      prev.map((c, i) => {
        if (i !== idx) return c;
        if (c.kind === 'removed') return { kind: 'unchanged', original: c.original };
        return c;
      }),
    );
  }

  function desfazerTroca(idx: number) {
    setCartoes((prev) =>
      prev.map((c, i) => {
        if (i !== idx) return c;
        if (c.kind === 'swapped') return { kind: 'unchanged', original: c.original };
        return c;
      }),
    );
  }

  function abrirTrocar(idx: number) {
    setBuscaAberta({ modo: 'trocar', cartaoIdx: idx });
  }

  function abrirAdicionar() {
    setBuscaAberta({ modo: 'adicionar' });
  }

  function handleEscolhaBusca(escolha: ProdutoEscolhido) {
    if (!buscaAberta) return;

    if (buscaAberta.modo === 'adicionar') {
      setCartoes((prev) => [
        ...prev,
        { kind: 'added', tempId: tempIdNovo(), novo: escolha },
      ]);
    } else {
      const idx = buscaAberta.cartaoIdx;
      setCartoes((prev) =>
        prev.map((c, i) => {
          if (i !== idx) return c;
          if (c.kind === 'added') {
            // Trocar um item recém-adicionado só substitui o "novo".
            return { ...c, novo: escolha };
          }
          if (c.kind === 'unchanged') {
            return { kind: 'swapped', original: c.original, novo: escolha };
          }
          if (c.kind === 'swapped') {
            return { kind: 'swapped', original: c.original, novo: escolha };
          }
          return c;
        }),
      );
    }
    setBuscaAberta(null);
  }

  // --- SALVAR ---
  async function salvar(forcar: boolean = false) {
    setErro(null);
    if (ficariaVazia) {
      setErro('A venda ficaria sem itens. Use "Cancelar Venda" no histórico.');
      return;
    }
    if (!temMudanca) {
      if (!forcar) {
        setConfirmarSemMudanca(true);
        return;
      }
      onClose();
      return;
    }

    // Monta payload de operações na ordem que apareceram na tela.
    const operacoes: any[] = [];
    for (const c of cartoes) {
      if (c.kind === 'unchanged') continue;
      if (c.kind === 'removed') {
        operacoes.push({ op: 'remover', item_id: c.original.id });
      } else if (c.kind === 'swapped') {
        operacoes.push({
          op: 'trocar',
          item_id: c.original.id,
          novo_produto_id: c.novo.produto_id,
          novo_estoque_id: c.novo.estoque_id,
          nova_quantidade: c.novo.quantidade,
          novo_preco_unitario: c.novo.preco_unitario,
          nova_descricao_completa: c.novo.descricao_completa,
        });
      } else if (c.kind === 'added') {
        operacoes.push({
          op: 'adicionar',
          produto_id: c.novo.produto_id,
          estoque_id: c.novo.estoque_id,
          quantidade: c.novo.quantidade,
          preco_unitario: c.novo.preco_unitario,
          descricao_completa: c.novo.descricao_completa,
        });
      }
    }

    setSalvando(true);
    try {
      const { data, error } = await supabase.rpc('editar_itens_venda', {
        p_venda_id: venda.id,
        p_operacoes: operacoes,
      });
      if (error) throw new Error(error.message);
      onSaved(data as ResultadoSave);
      onClose();
    } catch (err: any) {
      setErro(err?.message || String(err));
    } finally {
      setSalvando(false);
    }
  }

  // --- RENDER ---
  return (
    <>
      <div className="fixed inset-0 z-[60] bg-black/95 backdrop-blur-md flex items-end md:items-center justify-center p-0 md:p-4">
        <div className="bg-slate-900 w-full max-w-lg rounded-t-[2rem] md:rounded-[2rem] border-t md:border border-slate-700 shadow-2xl flex flex-col max-h-[95vh]">
          {/* CABEÇALHO */}
          <div className="p-5 border-b border-slate-800 shrink-0 flex justify-between items-start gap-3">
            <div className="min-w-0">
              <h3 className="text-lg font-black uppercase text-white tracking-tighter">
                Editar <span className="text-pink-500">Itens</span>
              </h3>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1 truncate">
                Venda #{venda.codigo_venda}
                {venda.nome_cliente?.trim() && <> • {venda.nome_cliente.trim()}</>}
              </p>
            </div>
            <button
              onClick={onClose}
              disabled={salvando}
              className="shrink-0 w-10 h-10 rounded-full bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-white font-bold text-xl active:scale-90 disabled:opacity-50"
            >
              ✕
            </button>
          </div>

          {/* CORPO */}
          <div className="flex-1 overflow-y-auto p-4 space-y-3">
            {cartoes.length === 0 && (
              <div className="text-center py-8 text-slate-500 text-xs font-bold uppercase tracking-widest">
                Nenhum item na venda
              </div>
            )}
            {cartoes.map((c, idx) => (
              <CartaoItem
                key={
                  c.kind === 'added'
                    ? c.tempId
                    : c.kind === 'unchanged'
                    ? c.original.id
                    : c.kind === 'removed'
                    ? `rm-${c.original.id}`
                    : `sw-${c.original.id}`
                }
                cartao={c}
                onRemover={() => marcarRemover(idx)}
                onDesfazerRemover={() => desfazerRemover(idx)}
                onDesfazerTroca={() => desfazerTroca(idx)}
                onTrocar={() => abrirTrocar(idx)}
              />
            ))}

            {/* + Adicionar item */}
            <button
              onClick={abrirAdicionar}
              disabled={salvando}
              className="w-full py-4 rounded-2xl border-2 border-dashed border-slate-700 hover:border-emerald-500 text-slate-400 hover:text-emerald-300 font-black uppercase text-xs tracking-widest transition active:scale-[.99] disabled:opacity-50"
            >
              + Adicionar item
            </button>

            {ficariaVazia && (
              <div className="rounded-xl border border-red-900/50 bg-red-950/30 px-4 py-3">
                <p className="text-[11px] text-red-300 font-bold">
                  Todos os itens estão marcados para excluir. A venda não pode ficar
                  vazia — use &quot;Cancelar Venda&quot; no histórico se for essa a
                  intenção.
                </p>
              </div>
            )}

            {erro && (
              <div className="rounded-xl border border-red-900/50 bg-red-950/30 px-4 py-3">
                <p className="text-[11px] text-red-300 font-bold whitespace-pre-wrap">
                  {erro}
                </p>
              </div>
            )}
          </div>

          {/* RODAPÉ STICKY: totais + ações */}
          <div className="shrink-0 border-t border-slate-800 bg-slate-950/80 backdrop-blur">
            <div className="px-5 py-3 border-b border-slate-800/70 grid grid-cols-3 gap-2 text-center">
              <div>
                <p className="text-[9px] font-black uppercase tracking-widest text-slate-500">
                  Antes
                </p>
                <p className="text-sm font-black text-slate-300">
                  {formatBRL(totalAntesLiquido)}
                </p>
              </div>
              <div>
                <p className="text-[9px] font-black uppercase tracking-widest text-slate-500">
                  Agora
                </p>
                <p className="text-sm font-black text-white">
                  {formatBRL(totalAgoraLiquido)}
                </p>
              </div>
              <div>
                <p className="text-[9px] font-black uppercase tracking-widest text-slate-500">
                  Diferença
                </p>
                <p
                  className={`text-sm font-black ${
                    diffLiquido === 0
                      ? 'text-slate-500'
                      : diffLiquido > 0
                      ? 'text-emerald-400'
                      : 'text-red-400'
                  }`}
                >
                  {diffLiquido === 0
                    ? '—'
                    : `${diffLiquido > 0 ? '↑' : '↓'} ${formatBRL(Math.abs(diffLiquido))}`}
                </p>
              </div>
            </div>
            {venda.desconto > 0 && descontoNovo !== venda.desconto && (
              <div className="px-5 py-2 border-b border-slate-800/70 bg-amber-950/20">
                <p className="text-[10px] font-bold text-amber-300">
                  ⚠ Desconto atual ({formatBRL(venda.desconto)}) maior que o novo total.
                  Será zerado ao salvar — ajuste na tela seguinte se precisar.
                </p>
              </div>
            )}
            <div className="p-4 grid grid-cols-2 gap-3">
              <button
                onClick={onClose}
                disabled={salvando}
                className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition disabled:opacity-50"
              >
                Cancelar
              </button>
              <button
                onClick={() => salvar(false)}
                disabled={salvando || ficariaVazia}
                className="bg-pink-600 hover:bg-pink-500 text-white py-4 rounded-xl font-black uppercase text-xs tracking-widest transition shadow-lg disabled:opacity-50"
              >
                {salvando ? 'Salvando…' : 'Continuar →'}
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Overlay de busca (novo item ou troca) */}
      {buscaAberta && (
        <BuscaProduto
          onEscolher={handleEscolhaBusca}
          onFechar={() => setBuscaAberta(null)}
          titulo={buscaAberta.modo === 'adicionar' ? 'Adicionar item' : 'Trocar por…'}
        />
      )}

      {/* Confirmação quando não há mudança */}
      {confirmarSemMudanca && (
        <div className="fixed inset-0 z-[85] bg-black/80 flex items-center justify-center p-4">
          <div className="bg-slate-900 rounded-2xl border border-slate-700 p-6 max-w-sm w-full">
            <p className="text-sm text-white font-bold mb-4">
              Nenhuma alteração foi feita. Deseja fechar?
            </p>
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => setConfirmarSemMudanca(false)}
                className="bg-slate-800 hover:bg-slate-700 text-white py-3 rounded-xl font-bold uppercase text-xs tracking-widest"
              >
                Voltar
              </button>
              <button
                onClick={() => {
                  setConfirmarSemMudanca(false);
                  onClose();
                }}
                className="bg-pink-600 hover:bg-pink-500 text-white py-3 rounded-xl font-black uppercase text-xs tracking-widest"
              >
                Fechar
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

// ============================================================================
// Subcomponente: cartão de um item na lista (visual muda por estado)
// ============================================================================
function CartaoItem({
  cartao,
  onRemover,
  onDesfazerRemover,
  onDesfazerTroca,
  onTrocar,
}: {
  cartao: CartaoState;
  onRemover: () => void;
  onDesfazerRemover: () => void;
  onDesfazerTroca: () => void;
  onTrocar: () => void;
}) {
  if (cartao.kind === 'unchanged') {
    const it = cartao.original;
    return (
      <div className="rounded-2xl bg-slate-950/60 border border-slate-800 border-l-4 border-l-slate-700 p-3">
        <p className="text-sm font-bold text-white uppercase leading-tight">
          {it.descricao_completa}
        </p>
        <div className="flex items-center justify-between mt-1 mb-3">
          <p className="text-[11px] font-mono text-slate-400">
            {it.quantidade} × {formatBRL(it.preco_unitario)}
          </p>
          <p className="text-sm font-black text-emerald-400">
            {formatBRL(it.quantidade * it.preco_unitario)}
          </p>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <button
            onClick={onTrocar}
            className="bg-slate-800 hover:bg-slate-700 text-white py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
          >
            🔄 Trocar
          </button>
          <button
            onClick={onRemover}
            className="bg-red-950/40 hover:bg-red-900/50 text-red-300 py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
          >
            🗑 Excluir
          </button>
        </div>
      </div>
    );
  }

  if (cartao.kind === 'removed') {
    const it = cartao.original;
    return (
      <div className="rounded-2xl bg-red-950/20 border border-red-900/40 border-l-4 border-l-red-500 p-3">
        <p className="text-sm font-bold text-red-200 uppercase leading-tight line-through opacity-70">
          {it.descricao_completa}
        </p>
        <p className="text-[11px] font-mono text-red-300/70 line-through mb-3">
          {it.quantidade} × {formatBRL(it.preco_unitario)} = {formatBRL(it.quantidade * it.preco_unitario)}
        </p>
        <button
          onClick={onDesfazerRemover}
          className="w-full bg-red-950/60 hover:bg-red-900/60 text-red-200 py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
        >
          ↩ Desfazer exclusão
        </button>
      </div>
    );
  }

  if (cartao.kind === 'swapped') {
    const it = cartao.original;
    const n = cartao.novo;
    return (
      <div className="rounded-2xl bg-amber-950/20 border border-amber-900/40 border-l-4 border-l-amber-400 p-3">
        <p className="text-[11px] font-bold text-amber-300/80 uppercase leading-tight line-through opacity-70">
          {it.descricao_completa}
        </p>
        <p className="text-sm font-black text-amber-100 uppercase leading-tight mt-1">
          → {n.descricao_completa}
        </p>
        <div className="flex items-center justify-between mt-1 mb-3">
          <p className="text-[11px] font-mono text-amber-200/80">
            {n.quantidade} × {formatBRL(n.preco_unitario)}
          </p>
          <p className="text-sm font-black text-emerald-400">
            {formatBRL(n.quantidade * n.preco_unitario)}
          </p>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <button
            onClick={onTrocar}
            className="bg-amber-900/40 hover:bg-amber-800/50 text-amber-100 py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
          >
            🔄 Trocar de novo
          </button>
          <button
            onClick={onDesfazerTroca}
            className="bg-slate-800 hover:bg-slate-700 text-white py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
          >
            ↩ Desfazer
          </button>
        </div>
      </div>
    );
  }

  // added
  const n = cartao.novo;
  return (
    <div className="rounded-2xl bg-emerald-950/20 border border-emerald-900/40 border-l-4 border-l-emerald-400 p-3">
      <div className="flex items-center gap-2 mb-1">
        <span className="text-[9px] font-black text-white bg-emerald-600 px-2 py-0.5 rounded-md uppercase tracking-widest">
          Novo
        </span>
        <p className="text-sm font-bold text-emerald-100 uppercase leading-tight truncate">
          {n.descricao_completa}
        </p>
      </div>
      <div className="flex items-center justify-between mt-1 mb-3">
        <p className="text-[11px] font-mono text-emerald-200/80">
          {n.quantidade} × {formatBRL(n.preco_unitario)}
        </p>
        <p className="text-sm font-black text-emerald-400">
          {formatBRL(n.quantidade * n.preco_unitario)}
        </p>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <button
          onClick={onTrocar}
          className="bg-emerald-900/40 hover:bg-emerald-800/50 text-emerald-100 py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
        >
          🔄 Trocar
        </button>
        <button
          onClick={onRemover}
          className="bg-red-950/40 hover:bg-red-900/50 text-red-300 py-2.5 rounded-lg font-bold uppercase text-[10px] tracking-widest active:scale-95 min-h-[44px]"
        >
          🗑 Excluir
        </button>
      </div>
    </div>
  );
}