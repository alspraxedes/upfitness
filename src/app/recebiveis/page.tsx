// src/app/recebiveis/page.tsx
'use client';

import { Suspense, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabase } from '../../lib/supabase';
import {
  FrequenciaCrediario, FREQ_LABEL, FREQ_CURTA,
  hojeISO, addDiasISO, addCiclos, formatDataCurta,
  parseValorDigitado, valorParaStr, formatBRL, sanitizeValor, dividirCents,
} from '../../lib/crediario';

type VendaInfo = {
  codigo_venda: number;
  nome_cliente: string | null;
  parcelas: number;
  crediario_frequencia: string | null;
  valor_liquido: number;
};

type Parcela = {
  id: string;
  venda_id: string;
  numero: number;
  valor: number;
  data_vencimento: string;
  pago: boolean;
  data_pagamento: string | null;
  venda: VendaInfo | null;
};

type LinhaEdit = {
  id: string | null;
  numero: number;
  valor: number;
  valorStr: string;
  data_vencimento: string;
  pago: boolean;
  data_pagamento: string | null;
};

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

// Linha de parcela no modal — componente de módulo (não recriado a cada render
// do pai), com swipe-to-delete e campos inline.
function LinhaParcela({
  l, idx, bloqueada, destravada, hoje,
  onValor, onVenc, onPgto, onTogglePago, onDestravar, onCancelar, onDescartar, onExcluir, onResto,
  mostrarResto,
}: {
  l: LinhaEdit; idx: number; bloqueada: boolean; destravada: boolean; hoje: string;
  onValor: (idx: number, raw: string) => void;
  onVenc: (idx: number, v: string) => void;
  onPgto: (idx: number, v: string) => void;
  onTogglePago: (idx: number) => void;
  onDestravar: (idx: number) => void;
  onCancelar: (idx: number) => void;
  onDescartar: (idx: number) => void;
  onExcluir: (idx: number) => void;
  onResto: () => void;
  mostrarResto: boolean;
}) {
  const atrasada = !l.pago && l.data_vencimento < hoje;
  const swipeAtivo = l.id !== null;
  const [dx, setDx] = useState(0);
  const startX = useRef<number | null>(null);
  const LIMIAR = 72;

  function onDown(e: React.PointerEvent) { if (swipeAtivo) startX.current = e.clientX; }
  function onMove(e: React.PointerEvent) {
    if (!swipeAtivo || startX.current === null) return;
    const delta = e.clientX - startX.current;
    if (delta < 0) setDx(Math.max(delta, -96));
  }
  function onUp() {
    if (!swipeAtivo || startX.current === null) return;
    const acionou = dx <= -LIMIAR;
    startX.current = null;
    setDx(0);
    if (acionou) onExcluir(idx);
  }

  return (
    <div className="relative overflow-hidden">
      {swipeAtivo && (
        <div className="absolute inset-0 flex items-center justify-end pr-4 bg-red-950/40 pointer-events-none">
          <span className="text-[10px] font-black uppercase tracking-widest text-red-300">arraste p/ excluir ✕</span>
        </div>
      )}
      <div
        className="relative bg-slate-950 py-3.5 px-1 touch-pan-y"
        style={{ transform: `translateX(${dx}px)`, transition: startX.current === null ? 'transform 0.18s ease' : 'none' }}
        onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onPointerCancel={onUp}
      >
        <div className="flex items-center gap-2">
          <span className="text-[11px] font-black text-slate-300 shrink-0 w-7">{l.numero}ª</span>
          {l.id === null && <span className="text-[8px] font-black uppercase text-emerald-400 shrink-0">nova</span>}
          {atrasada && <span className="text-[8px] font-black uppercase text-red-300 shrink-0">atrasada</span>}

          <div className="flex items-baseline gap-1 ml-auto shrink-0">
            <span className="text-[10px] text-slate-500 font-bold">R$</span>
            <input
              type="text" inputMode="decimal" autoComplete="off" disabled={bloqueada}
              className={`bg-transparent w-[5.5rem] text-base font-black outline-none text-right border-b ${bloqueada ? 'text-slate-300 border-transparent' : 'text-white border-slate-700 focus:border-violet-500'}`}
              value={l.valorStr}
              onChange={(e) => onValor(idx, sanitizeValor(e.target.value))}
            />
          </div>

          {bloqueada ? (
            <button onClick={() => onDestravar(idx)} title="Editar parcela paga" className="shrink-0 text-slate-500 hover:text-white text-base px-1.5 py-1" aria-label="Editar">✎</button>
          ) : destravada ? (
            <button onClick={() => onCancelar(idx)} title="Cancelar edição" className="shrink-0 text-[8px] font-black uppercase tracking-widest text-slate-400 hover:text-white border border-slate-700 rounded px-2 py-1.5 active:scale-95">cancelar</button>
          ) : l.id === null ? (
            <button onClick={() => onDescartar(idx)} title="Descartar parcela nova" className="shrink-0 text-slate-600 hover:text-red-400 text-sm font-bold px-1.5 py-1" aria-label="Descartar">✕</button>
          ) : (
            <span className="shrink-0 w-6" aria-hidden />
          )}
        </div>

        <div className="flex items-center gap-x-5 gap-y-1.5 flex-wrap mt-2 pl-9">
          <div className="flex items-center gap-2">
            <span className="text-[9px] font-bold uppercase tracking-widest text-slate-600 shrink-0">venc.</span>
            {bloqueada ? (
              <span className="text-[11px] font-mono text-slate-300">{formatDataCurta(l.data_vencimento)}</span>
            ) : (
              <input type="date" className="bg-transparent border-b border-slate-700 focus:border-violet-500 px-0.5 py-0.5 text-[11px] font-mono text-slate-300 outline-none"
                value={l.data_vencimento} onChange={(e) => { if (e.target.value) onVenc(idx, e.target.value); }} />
            )}
          </div>
          {l.pago && (
            <div className="flex items-center gap-2">
              <span className="text-[9px] font-bold uppercase tracking-widest text-emerald-600 shrink-0">pago</span>
              {bloqueada ? (
                <span className="text-[11px] font-mono text-emerald-300">{formatDataCurta(l.data_pagamento ?? hoje)}</span>
              ) : (
                <input type="date" className="bg-transparent border-b border-emerald-800 focus:border-emerald-500 px-0.5 py-0.5 text-[11px] font-mono text-emerald-300 outline-none"
                  value={l.data_pagamento ?? hoje} onChange={(e) => { if (e.target.value) onPgto(idx, e.target.value); }} />
              )}
            </div>
          )}
        </div>

        {!bloqueada && (
          <div className="flex items-center gap-2 flex-wrap mt-2.5 pl-9">
            <button
              onClick={() => onTogglePago(idx)}
              className={`text-[9px] font-black uppercase tracking-widest px-2.5 py-1.5 rounded-lg border active:scale-95 ${l.pago ? 'bg-emerald-950/40 text-emerald-300 border-emerald-900/50 hover:bg-emerald-900/40' : 'bg-slate-900 text-slate-300 border-slate-700 hover:border-slate-500'}`}
            >
              {l.pago ? '✓ marcar pendente' : 'marcar paga'}
            </button>
            {mostrarResto && (
              <button onClick={onResto} title="Colocar o valor restante nesta parcela" className="text-[9px] font-black uppercase tracking-widest px-2.5 py-1.5 rounded-lg border bg-violet-950/40 text-violet-300 border-violet-900/50 hover:bg-violet-900/40 active:scale-95">↧ restante aqui</button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

export default function RecebiveisPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950 text-slate-100" />}>
      <RecebiveisPageInner />
    </Suspense>
  );
}

function RecebiveisPageInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getQS(searchParams), [searchParams]);

  const [parcelas, setParcelas] = useState<Parcela[]>([]);
  const [loading, setLoading] = useState(true);
  const [clienteAberto, setClienteAberto] = useState<string | null>(null);

  const STORAGE_KEY = 'upfitness_recebiveis_filtros_v1';
  const [busca, setBusca] = useState('');
  const [ordenarPor, setOrdenarPor] = useState<'nome' | 'aberto'>('aberto');

  const [modalVenda, setModalVenda] = useState<string | null>(null);
  const [linhas, setLinhas] = useState<LinhaEdit[]>([]);
  const [modalFreq, setModalFreq] = useState<FrequenciaCrediario>('mensal');
  const [salvandoModal, setSalvandoModal] = useState(false);
  // Ids de parcelas pagas que o usuário destravou para edição (via lápis).
  // Linhas novas (id null) e pendentes são sempre editáveis.
  const [destravadas, setDestravadas] = useState<Set<string>>(new Set());
  // Snapshot da linha no momento em que foi destravada, para cancelar a edição.
  const [snapshots, setSnapshots] = useState<Record<string, LinhaEdit>>({});

  const hoje = hojeISO();

  useEffect(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const p = JSON.parse(raw);
        if (typeof p?.filtroCliente === 'string' && p.filtroCliente) setBusca(p.filtroCliente);
      }
    } catch { /* ignore */ }
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) { router.replace('/login'); return; }
      await fetchParcelas();
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const onVisible = () => { if (document.visibilityState === 'visible') fetchParcelas(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function fetchParcelas() {
    setLoading(true);
    const PAGE = 1000;
    let todas: Parcela[] = [];
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from('crediario_parcelas')
        .select('id, venda_id, numero, valor, data_vencimento, pago, data_pagamento, venda:vendas(codigo_venda, nome_cliente, parcelas, crediario_frequencia, valor_liquido)')
        .order('data_vencimento', { ascending: true })
        .order('numero', { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) { alert('Erro ao buscar recebíveis: ' + error.message); setLoading(false); return; }
      const lote = (data ?? []) as any as Parcela[];
      todas = todas.concat(lote);
      if (lote.length < PAGE) break;
    }
    setParcelas(todas);
    setLoading(false);
  }

  const resumo = useMemo(() => {
    const pend = parcelas.filter((p) => !p.pago);
    const soma = (arr: Parcela[]) => arr.reduce((a, p) => a + (Number(p.valor) || 0), 0);
    const venc = pend.filter((p) => p.data_vencimento < hoje);
    const sete = addDiasISO(hoje, 7);
    const prox = pend.filter((p) => p.data_vencimento >= hoje && p.data_vencimento <= sete);
    return { aberto: soma(pend), vencido: soma(venc), qtdVencido: venc.length, proximos7: soma(prox) };
  }, [parcelas, hoje]);

  type ClienteResumo = { nome: string; aberto: number; pago: number; qtdPend: number; temAtrasada: boolean; proxVenc: string | null; };

  const clientes = useMemo<ClienteResumo[]>(() => {
    const mapa = new Map<string, Parcela[]>();
    parcelas.forEach((p) => {
      const nome = p.venda?.nome_cliente?.trim() || 'Sem cliente';
      const arr = mapa.get(nome) ?? [];
      arr.push(p);
      mapa.set(nome, arr);
    });
    const out: ClienteResumo[] = [];
    mapa.forEach((arr, nome) => {
      const pend = arr.filter((p) => !p.pago);
      const aberto = pend.reduce((a, p) => a + (Number(p.valor) || 0), 0);
      const pago = arr.filter((p) => p.pago).reduce((a, p) => a + (Number(p.valor) || 0), 0);
      const temAtrasada = pend.some((p) => p.data_vencimento < hoje);
      const proxVenc = pend.length > 0 ? pend.map((p) => p.data_vencimento).sort()[0] : null;
      out.push({ nome, aberto, pago, qtdPend: pend.length, temAtrasada, proxVenc });
    });
    return out;
  }, [parcelas, hoje]);

  const clientesFiltrados = useMemo(() => {
    const q = busca.trim().toLowerCase();
    let arr = q ? clientes.filter((c) => c.nome.toLowerCase().includes(q)) : clientes;
    arr = [...arr].sort((a, b) => {
      if (ordenarPor === 'nome') return a.nome.localeCompare(b.nome, 'pt-BR');
      return b.aberto - a.aberto || a.nome.localeCompare(b.nome, 'pt-BR');
    });
    return arr;
  }, [clientes, busca, ordenarPor]);

  type VendaGrupo = { venda_id: string; codigo: number; valorLiquido: number; frequencia: string | null; itens: Parcela[]; pagas: number; total: number; abertoVenda: number; };

  const vendasDoCliente = useMemo<VendaGrupo[]>(() => {
    if (!clienteAberto) return [];
    const doCliente = parcelas.filter((p) => (p.venda?.nome_cliente?.trim() || 'Sem cliente') === clienteAberto);
    const mapa = new Map<string, Parcela[]>();
    doCliente.forEach((p) => {
      const arr = mapa.get(p.venda_id) ?? [];
      arr.push(p);
      mapa.set(p.venda_id, arr);
    });
    const out: VendaGrupo[] = [];
    mapa.forEach((itens, venda_id) => {
      const ordenadas = [...itens].sort((a, b) => a.numero - b.numero);
      const v = ordenadas[0]?.venda;
      out.push({
        venda_id, codigo: v?.codigo_venda ?? 0, valorLiquido: Number(v?.valor_liquido) || 0,
        frequencia: v?.crediario_frequencia ?? null, itens: ordenadas,
        pagas: ordenadas.filter((p) => p.pago).length, total: ordenadas.length,
        abertoVenda: ordenadas.filter((p) => !p.pago).reduce((a, p) => a + (Number(p.valor) || 0), 0),
      });
    });
    return out.sort((a, b) => b.abertoVenda - a.abertoVenda || a.codigo - b.codigo);
  }, [clienteAberto, parcelas]);

  const vendaDoModal = useMemo(() => vendasDoCliente.find((v) => v.venda_id === modalVenda) || null, [vendasDoCliente, modalVenda]);

  function abrirEdicao(v: VendaGrupo) {
    setModalFreq(((v.frequencia as FrequenciaCrediario) || 'mensal'));
    setDestravadas(new Set());
    setSnapshots({});
    setLinhas(v.itens.map((p) => ({
      id: p.id, numero: p.numero, valor: Number(p.valor) || 0, valorStr: valorParaStr(Number(p.valor) || 0),
      data_vencimento: p.data_vencimento, pago: p.pago, data_pagamento: p.data_pagamento,
    })));
    setModalVenda(v.venda_id);
  }

  const totalVendaCents = vendaDoModal ? Math.round(vendaDoModal.valorLiquido * 100) : 0;
  const somaLinhasCents = linhas.reduce((a, l) => a + Math.round(l.valor * 100), 0);
  const somaOk = linhas.length > 0 && somaLinhasCents === totalVendaCents;
  const valoresOk = linhas.length > 0 && linhas.every((l) => Math.round(l.valor * 100) >= 0);
  const numerosUnicos = new Set(linhas.map((l) => l.numero)).size === linhas.length;
  const edicaoPronta = somaOk && valoresOk && numerosUnicos;

  // Uma linha está bloqueada se é paga e ainda não foi destravada pelo lápis
  function linhaBloqueada(l: LinhaEdit): boolean {
    return l.pago && l.id !== null && !destravadas.has(l.id);
  }

  function setLinha(idx: number, patch: Partial<LinhaEdit>) {
    setLinhas((prev) => prev.map((l, i) => (i === idx ? { ...l, ...patch } : l)));
  }

  // Divide entre as linhas EDITÁVEIS (pendentes + pagas destravadas) o saldo
  // que sobra depois das parcelas pagas/bloqueadas — assim a soma total fecha.
  function dividirIgual() {
    setLinhas((prev) => {
      const editaveis = prev.filter((l) => !linhaBloqueada(l));
      if (editaveis.length === 0) return prev;
      const travadasCents = prev.filter((l) => linhaBloqueada(l)).reduce((a, l) => a + Math.round(l.valor * 100), 0);
      const saldo = Math.max(0, totalVendaCents - travadasCents);
      const cents = dividirCents(saldo, editaveis.length);
      let k = 0;
      return prev.map((l) => {
        if (linhaBloqueada(l)) return l;
        const c = cents[k++];
        return { ...l, valor: c / 100, valorStr: valorParaStr(c / 100) };
      });
    });
  }

  // Joga o restante (saldo − soma das outras editáveis) na última linha editável
  function restoNaUltima() {
    setLinhas((prev) => {
      const idxsEditaveis = prev.map((l, i) => (linhaBloqueada(l) ? -1 : i)).filter((i) => i >= 0);
      if (idxsEditaveis.length === 0) return prev;
      const ultimaIdx = idxsEditaveis[idxsEditaveis.length - 1];
      const outras = prev.reduce((a, l, i) => (i === ultimaIdx ? a : a + Math.round(l.valor * 100)), 0);
      const resto = Math.max(0, totalVendaCents - outras);
      return prev.map((l, i) => i === ultimaIdx ? { ...l, valor: resto / 100, valorStr: valorParaStr(resto / 100) } : l);
    });
  }
  function adicionarLinha() {
    setLinhas((prev) => {
      const maxNum = Math.max(0, ...prev.map((l) => l.numero));
      const datas = prev.map((l) => l.data_vencimento).sort();
      const ultima = datas[datas.length - 1] || hojeISO();
      return [...prev, { id: null, numero: maxNum + 1, valor: 0, valorStr: '0,00', data_vencimento: addCiclos(ultima, modalFreq, 1), pago: false, data_pagamento: null }];
    });
  }
  function removerLinha(idx: number) {
    setLinhas((prev) => prev.filter((_, i) => i !== idx));
  }

  // Lápis: destrava uma parcela paga para edição, guardando snapshot
  function destravar(idx: number) {
    const l = linhas[idx];
    if (!l.id) return;
    setSnapshots((prev) => ({ ...prev, [l.id as string]: { ...l } }));
    setDestravadas((prev) => { const n = new Set(prev); n.add(l.id as string); return n; });
  }

  // ✕ numa linha destravada: cancela a edição, restaura o snapshot e trava de novo
  function cancelarEdicao(idx: number) {
    const l = linhas[idx];
    if (!l.id) return;
    const snap = snapshots[l.id];
    if (snap) setLinhas((prev) => prev.map((x, i) => (i === idx ? { ...snap } : x)));
    setDestravadas((prev) => { const n = new Set(prev); n.delete(l.id as string); return n; });
    setSnapshots((prev) => { const c = { ...prev }; delete c[l.id as string]; return c; });
  }

  // Excluir (via swipe): confirma e remove a linha
  function excluirLinha(idx: number) {
    const l = linhas[idx];
    const ok = confirm(`Excluir a ${l.numero}ª parcela${l.pago ? ' (paga)' : ''}? O valor dela precisará ser realocado para a soma fechar.`);
    if (!ok) return;
    if (l.id) {
      setDestravadas((prev) => { const n = new Set(prev); n.delete(l.id as string); return n; });
      setSnapshots((prev) => { const c = { ...prev }; delete c[l.id as string]; return c; });
    }
    setLinhas((prev) => prev.filter((_, i) => i !== idx));
  }

  // Índice da última linha editável (para o botão "jogar restante aqui")
  const ultimaEditavelIdx = useMemo(() => {
    const idxs = linhas.map((l, i) => (linhaBloqueada(l) ? -1 : i)).filter((i) => i >= 0);
    return idxs.length > 0 ? idxs[idxs.length - 1] : -1;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [linhas, destravadas]);

  const qtdEditaveis = linhas.filter((l) => !linhaBloqueada(l)).length;

  // Monta as props de uma LinhaParcela a partir do índice real
  function propsLinha(l: LinhaEdit, idx: number) {
    return {
      l, idx, hoje,
      bloqueada: linhaBloqueada(l),
      destravada: !!l.id && destravadas.has(l.id),
      onValor: (i: number, raw: string) => setLinha(i, { valorStr: raw, valor: parseValorDigitado(raw) }),
      onVenc: (i: number, v: string) => setLinha(i, { data_vencimento: v }),
      onPgto: (i: number, v: string) => setLinha(i, { data_pagamento: v }),
      onTogglePago: (i: number) => setLinha(i, { pago: !linhas[i].pago, data_pagamento: !linhas[i].pago ? hojeISO() : null }),
      onDestravar: destravar,
      onCancelar: cancelarEdicao,
      onDescartar: removerLinha,
      onExcluir: excluirLinha,
      onResto: restoNaUltima,
      mostrarResto: idx === ultimaEditavelIdx && qtdEditaveis > 1,
    };
  }



  async function salvarParcelamento(venda: VendaGrupo, freq: FrequenciaCrediario, payloadLinhas: LinhaEdit[]) {
    const payload = payloadLinhas.map((l) => ({
      id: l.id, numero: l.numero, valor: Math.round(l.valor * 100) / 100,
      data_vencimento: l.data_vencimento, pago: l.pago, data_pagamento: l.pago ? (l.data_pagamento || hojeISO()) : null,
    }));
    const { error } = await supabase.rpc('editar_parcelamento_venda', {
      p_venda_id: venda.venda_id, p_frequencia: freq, p_parcelas: payload,
    });
    if (error) throw new Error(error.message);
  }

  async function salvarEdicao() {
    if (!vendaDoModal) return;
    if (!numerosUnicos) { alert('Há números de parcela repetidos.'); return; }
    if (!valoresOk) { alert('Há parcela com valor inválido.'); return; }
    if (!somaOk) { alert(`A soma das parcelas (${formatBRL(somaLinhasCents / 100)}) precisa ser igual ao valor da venda (${formatBRL(totalVendaCents / 100)}).`); return; }
    setSalvandoModal(true);
    try {
      await salvarParcelamento(vendaDoModal, modalFreq, linhas);
      setModalVenda(null);
      await fetchParcelas();
    } catch (e: any) {
      alert(`Erro ao salvar: ${e?.message ?? e}`);
    } finally { setSalvandoModal(false); }
  }

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-32">
      <div className="h-[3px] w-full bg-gradient-to-r from-pink-600 to-blue-600" />

      <header className="bg-slate-900 p-6 border-b border-slate-800 sticky top-0 z-20 shadow-xl space-y-4">
        <div className="flex items-center gap-4">
          <Link href={`/${dashQS}`} className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95 transition" aria-label="Voltar">←</Link>
          <div>
            <h1 className="font-black italic text-xl uppercase tracking-tighter">Recebíveis <span className="text-violet-500">Crediário</span></h1>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">Situação por cliente</p>
          </div>
        </div>
        <div className="flex gap-2">
          <div className="relative flex-1">
            <input type="text" placeholder="Buscar cliente..." autoComplete="off"
              className="w-full bg-slate-950 border border-slate-700 focus:border-violet-500 outline-none px-4 py-3 rounded-xl text-white font-bold text-sm placeholder:text-slate-600"
              value={busca} onChange={(e) => setBusca(e.target.value)} />
            {busca && <button onClick={() => setBusca('')} className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-500 hover:text-white text-sm font-bold">✕</button>}
          </div>
          <button onClick={() => setOrdenarPor((p) => (p === 'aberto' ? 'nome' : 'aberto'))} className="px-4 py-3 rounded-xl text-[10px] font-black uppercase tracking-widest border bg-slate-800 border-slate-700 text-slate-200 hover:border-slate-500 active:scale-95 shrink-0">
            {ordenarPor === 'aberto' ? '⇅ Valor' : '⇅ Nome'}
          </button>
        </div>
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">
        <div className="grid grid-cols-3 gap-3">
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-violet-400 uppercase tracking-widest">Em aberto</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.aberto)}</p>
          </div>
          <div className={`bg-slate-900 p-4 rounded-2xl border shadow-lg flex flex-col justify-between ${resumo.qtdVencido > 0 ? 'border-red-900/60' : 'border-slate-800'}`}>
            <span className="text-[10px] font-black text-red-400 uppercase tracking-widest">Vencido</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.vencido)}</p>
          </div>
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-emerald-400 uppercase tracking-widest">Próx. 7 dias</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.proximos7)}</p>
          </div>
        </div>

        {loading ? (
          <div className="text-slate-400 text-xs font-bold uppercase tracking-widest text-center py-16 animate-pulse">Carregando...</div>
        ) : clientesFiltrados.length === 0 ? (
          <div className="text-slate-500 text-sm font-bold uppercase tracking-widest text-center py-16">
            {clientes.length === 0 ? 'Nenhuma venda em crediário ainda' : 'Nenhum cliente encontrado'}
          </div>
        ) : (
          <div className="space-y-2">
            {clientesFiltrados.map((c) => (
              <button key={c.nome} onClick={() => setClienteAberto(c.nome)} className="w-full text-left bg-slate-900 rounded-2xl border border-slate-800 hover:border-violet-700 p-4 flex items-center gap-3 transition-colors active:scale-[0.99]">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap mb-1">
                    <span className="text-sm font-black text-white truncate">{c.nome}</span>
                    {c.temAtrasada && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-red-950/40 text-red-300 border border-red-900/50">atrasada</span>}
                    {c.qtdPend === 0 && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-emerald-950/40 text-emerald-300 border border-emerald-900/50">quitado</span>}
                  </div>
                  <p className="text-[10px] font-bold text-slate-500 uppercase">
                    {c.qtdPend > 0 ? `${c.qtdPend} parcela(s) pendente(s)` : 'sem pendências'}{c.proxVenc ? ` • próx. ${formatDataCurta(c.proxVenc)}` : ''}
                  </p>
                </div>
                <div className="shrink-0 text-right">
                  <p className="text-[9px] font-bold text-slate-500 uppercase">Em aberto</p>
                  <p className={`text-base font-black ${c.aberto > 0 ? 'text-white' : 'text-emerald-400'}`}>{formatBRL(c.aberto)}</p>
                </div>
                <span className="text-slate-600 text-lg shrink-0">›</span>
              </button>
            ))}
          </div>
        )}
      </main>

      {clienteAberto && (
        <div className="fixed inset-0 z-50 bg-slate-950 flex flex-col animate-in slide-in-from-bottom-4 duration-200">
          <div className="h-[3px] w-full bg-gradient-to-r from-pink-600 to-blue-600 shrink-0" />
          <header className="bg-slate-900 p-5 border-b border-slate-800 shrink-0 flex items-center gap-3">
            <button onClick={() => setClienteAberto(null)} className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95" aria-label="Voltar">←</button>
            <div className="flex-1 min-w-0">
              <h2 className="font-black italic text-lg uppercase tracking-tighter truncate">{clienteAberto}</h2>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500">
                {vendasDoCliente.length} venda(s) • em aberto {formatBRL(vendasDoCliente.reduce((a, v) => a + v.abertoVenda, 0))}
              </p>
            </div>
          </header>
          <div className="flex-1 min-h-0 overflow-y-auto p-4 space-y-4 max-w-3xl w-full mx-auto">
            {vendasDoCliente.map((v) => (
              <section key={v.venda_id} className="bg-slate-900 rounded-2xl border border-slate-800 overflow-hidden">
                <div className="px-4 py-3 border-b border-slate-800 flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-sm font-black text-white">#{v.codigo} <span className="text-slate-500 font-bold">• {formatBRL(v.valorLiquido)}</span></p>
                    <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500">
                      {v.pagas}/{v.total} pagas{v.frequencia ? ` • ${FREQ_CURTA[v.frequencia] ?? v.frequencia}` : ''} • aberto {formatBRL(v.abertoVenda)}
                    </p>
                  </div>
                  <button onClick={() => abrirEdicao(v)} className="shrink-0 text-[10px] font-black uppercase tracking-widest text-violet-300 bg-violet-950/40 border border-violet-900/50 hover:bg-violet-900/40 px-3 py-2 rounded-xl active:scale-95">Gerir parcelas</button>
                </div>
                <div className="divide-y divide-slate-800/60">
                  {v.itens.map((p) => {
                    const atrasada = !p.pago && p.data_vencimento < hoje;
                    return (
                      <div key={p.id} className="flex items-center gap-3 px-4 py-3">
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center gap-2 mb-0.5">
                            <span className="text-xs font-black text-slate-300">{p.numero}ª</span>
                            {atrasada && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-red-950/40 text-red-300 border border-red-900/50">atrasada</span>}
                            {p.pago && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-emerald-950/40 text-emerald-300 border border-emerald-900/50">paga</span>}
                          </div>
                          <p className="text-[10px] font-mono text-slate-500">venc. {formatDataCurta(p.data_vencimento)}{p.pago && p.data_pagamento ? ` • pg ${formatDataCurta(p.data_pagamento)}` : ''}</p>
                        </div>
                        <span className={`text-sm font-black shrink-0 ${p.pago ? 'text-emerald-400' : 'text-white'}`}>{formatBRL(Number(p.valor) || 0)}</span>
                      </div>
                    );
                  })}
                </div>
                <div className="px-4 py-2 bg-slate-950/40 text-[9px] font-bold uppercase tracking-widest text-slate-600">Use Gerir parcelas para registrar pagamentos, ajustar valores, datas ou excluir parcelas</div>
              </section>
            ))}
          </div>
        </div>
      )}

      {vendaDoModal && (
        <div className="fixed inset-0 z-[70] bg-black/95 backdrop-blur-md overflow-y-auto overscroll-contain animate-in fade-in duration-200">
          <div className="min-h-full flex items-center justify-center p-4">
          <div className="bg-slate-900 w-full max-w-md rounded-3xl border border-slate-700 shadow-2xl relative">
            <div className="p-5 border-b border-slate-800 sticky top-0 bg-slate-900 rounded-t-3xl z-10">
              <h3 className="text-lg font-black uppercase text-white tracking-tighter">Editar <span className="text-violet-400">parcelamento</span></h3>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">#{vendaDoModal.codigo} • {clienteAberto} • valor {formatBRL(vendaDoModal.valorLiquido)}</p>
            </div>
            <div className="p-5 space-y-4">
              {/* Frequência compacta (usada só para sugerir data ao adicionar) */}
              <div className="flex items-center justify-between gap-2">
                <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Frequência (sugestão de datas)</span>
                <select
                  value={modalFreq}
                  onChange={(e) => setModalFreq(e.target.value as FrequenciaCrediario)}
                  className="bg-slate-950 border border-slate-700 rounded-lg px-3 py-1.5 text-[11px] font-black uppercase tracking-widest text-white outline-none focus:border-violet-500"
                >
                  {(['semanal', 'quinzenal', 'mensal'] as FrequenciaCrediario[]).map((fq) => (
                    <option key={fq} value={fq}>{FREQ_LABEL[fq]}</option>
                  ))}
                </select>
              </div>

              <div className="bg-slate-950 border border-slate-800 rounded-xl overflow-hidden">
                <div className="px-4 py-3 border-b border-slate-800 flex items-center justify-between gap-2">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Parcelas ({linhas.length})</span>
                  <div className="flex items-center gap-4 shrink-0">
                    <button onClick={dividirIgual} className="text-[10px] font-black uppercase tracking-widest text-violet-400 hover:text-violet-300 active:scale-95">↺ Dividir</button>
                    <button onClick={adicionarLinha} className="text-[10px] font-black uppercase tracking-widest text-emerald-400 hover:text-emerald-300 active:scale-95">+ Parcela</button>
                  </div>
                </div>

                {/* PENDENTES */}
                {linhas.some((l) => !l.pago) && (
                  <>
                    <div className="px-4 pt-3 pb-1">
                      <span className="text-[9px] font-black uppercase tracking-widest text-slate-500">Pendentes</span>
                    </div>
                    <div className="px-3 divide-y divide-slate-800/50">
                      {linhas.map((l, idx) => (!l.pago ? <LinhaParcela key={l.id ?? `n-${idx}`} {...propsLinha(l, idx)} /> : null))}
                    </div>
                  </>
                )}

                {/* PAGAS */}
                {linhas.some((l) => l.pago) && (
                  <>
                    <div className="px-4 pt-3 pb-1 border-t border-slate-800/60 bg-emerald-950/10">
                      <span className="text-[9px] font-black uppercase tracking-widest text-emerald-500">Pagas</span>
                    </div>
                    <div className="px-3 divide-y divide-slate-800/50 bg-emerald-950/5">
                      {linhas.map((l, idx) => (l.pago ? <LinhaParcela key={l.id ?? `p-${idx}`} {...propsLinha(l, idx)} /> : null))}
                    </div>
                  </>
                )}

                <div className={`px-4 py-3 border-t flex items-center justify-between ${somaOk ? 'border-emerald-900/40 bg-emerald-950/20' : 'border-red-900/40 bg-red-950/20'}`}>
                  <span className={`text-[10px] font-black uppercase tracking-widest ${somaOk ? 'text-emerald-400' : 'text-red-400'}`}>{somaOk ? '✓ Soma confere' : `Diferença: ${formatBRL((somaLinhasCents - totalVendaCents) / 100)}`}</span>
                  <span className="text-xs font-black text-white">{formatBRL(somaLinhasCents / 100)} / {formatBRL(totalVendaCents / 100)}</span>
                </div>
              </div>
              {!numerosUnicos && <p className="text-[10px] font-black uppercase tracking-widest text-red-400">⚠ Há números de parcela repetidos</p>}
              <p className="text-[9px] font-bold text-slate-600 uppercase tracking-widest leading-relaxed">Parcelas pagas ficam bloqueadas — toque em ✎ para editá-las. ↺ Dividir reparte só entre as pendentes; a soma total precisa bater com o valor da venda.</p>
            </div>
            <div className="p-4 border-t border-slate-800 grid grid-cols-2 gap-3 sticky bottom-0 bg-slate-900 rounded-b-3xl z-10">
              <button onClick={() => setModalVenda(null)} disabled={salvandoModal} className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition">Cancelar</button>
              <button onClick={salvarEdicao} disabled={salvandoModal || !edicaoPronta} className="bg-violet-600 hover:bg-violet-500 text-white py-4 rounded-xl font-black uppercase text-xs tracking-widest transition shadow-lg disabled:opacity-50">{salvandoModal ? 'Salvando...' : 'Salvar'}</button>
            </div>
          </div>
          </div>
        </div>
      )}


      <div className="fixed left-6 right-6 z-[60]" style={{ bottom: `calc(env(safe-area-inset-bottom, 0px) + 10px)` }}>
        <nav className="bg-slate-900/95 backdrop-blur-2xl border border-white/5 rounded-[2.5rem] h-20 px-4 flex items-center justify-around shadow-2xl">
          <Link href={`/${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6"><path strokeLinecap="round" strokeLinejoin="round" d="M21 7.5l-9-5.25L3 7.5m18 0l-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9" /></svg></div>
            <span className="text-[9px] font-black text-white uppercase tracking-widest">ESTOQUE</span>
          </Link>
          <Link href={`/venda${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6"><path strokeLinecap="round" strokeLinejoin="round" d="M2.25 3h1.386c.51 0 .955.343 1.087.835l.383 1.437M7.5 14.25a3 3 0 00-3 3h15.75m-12.75-3h11.218c1.121-2.3 2.1-4.684 2.924-7.138a60.114 60.114 0 00-16.536-1.84M7.5 14.25L5.106 5.272M6 20.25a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm12.75 0a.75.75 0 11-1.5 0 .75.75 0 011.5 0z" /></svg></div>
            <span className="text-[9px] font-black text-white tracking-widest">VENDA</span>
          </Link>
          <Link href={`/historico${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6"><path strokeLinecap="round" strokeLinejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z" /></svg></div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Histórico</span>
          </Link>
          <Link href={`/recebiveis${dashQS}`} className="flex flex-col items-center gap-1">
            <div className="p-2 rounded-2xl bg-pink-500/20 text-pink-500"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6"><path strokeLinecap="round" strokeLinejoin="round" d="M2.25 18.75a60.07 60.07 0 0115.797 2.101c.727.198 1.453-.342 1.453-1.096V18.75M3.75 4.5v.75A.75.75 0 013 6h-.75m0 0v-.375c0-.621.504-1.125 1.125-1.125H20.25M2.25 6v9m18-10.5v.75c0 .414.336.75.75.75h.75m-1.5-1.5h.375c.621 0 1.125.504 1.125 1.125v9.75c0 .621-.504 1.125-1.125 1.125h-.375m1.5-1.5H21a.75.75 0 00-.75.75v.75m0 0H3.75m0 0h-.375a1.125 1.125 0 01-1.125-1.125V15m1.5 1.5v-.75A.75.75 0 003 15h-.75M15 10.5a3 3 0 11-6 0 3 3 0 016 0zm3 0h.008v.008H18V10.5zm-12 0h.008v.008H6V10.5z" /></svg></div>
            <span className="text-[9px] font-black text-pink-500 tracking-widest uppercase">Recebíveis</span>
          </Link>
          <Link href={`/relatorios${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6"><path strokeLinecap="round" strokeLinejoin="round" d="M2.25 18L9 11.25l4.306 4.307a11.95 11.95 0 015.814-5.519l2.74-1.22m0 0l-5.94-2.28m5.94 2.28l-2.28 5.941" /></svg></div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Relatórios</span>
          </Link>
        </nav>
      </div>
    </div>
  );
}