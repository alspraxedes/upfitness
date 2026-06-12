// src/app/recebiveis/page.tsx
'use client';

import { Suspense, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabase } from '../../lib/supabase';

// --- TIPOS ---
type VendaInfo = {
  codigo_venda: number;
  nome_cliente: string | null;
  parcelas: number;
  crediario_frequencia: string | null;
};

type Parcela = {
  id: string;
  venda_id: string;
  numero: number;
  valor: number;
  data_vencimento: string; // YYYY-MM-DD
  pago: boolean;
  data_pagamento: string | null;
  venda: VendaInfo | null;
};

type FiltroStatus = 'pendentes' | 'pagas' | 'todas';
type Agrupamento = 'data' | 'cliente';

// --- UTILITÁRIOS ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

function hojeISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function addDiasISO(baseISO: string, dias: number): string {
  const [y, m, d] = baseISO.split('-').map(Number);
  const dt = new Date(y, m - 1, d + dias);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}

const formatDataCurta = (iso: string) => {
  const [y, m, d] = iso.split('-');
  return `${d}/${m}/${y.slice(2)}`;
};

// Rótulo amigável da data de vencimento ("Hoje", "Amanhã", "Seg 15/06/26"...)
function rotuloData(iso: string, hoje: string): string {
  if (iso === hoje) return 'Hoje';
  if (iso === addDiasISO(hoje, 1)) return 'Amanhã';
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(y, m - 1, d);
  const dia = dt.toLocaleDateString('pt-BR', { weekday: 'short' }).replace('.', '');
  return `${dia.charAt(0).toUpperCase()}${dia.slice(1)} ${formatDataCurta(iso)}`;
}

const FREQ_CURTA: Record<string, string> = {
  semanal: 'semanal',
  quinzenal: 'quinzenal',
  mensal: 'mensal',
};

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
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
  const [processandoId, setProcessandoId] = useState<string | null>(null);

  // Filtros (persistidos)
  const STORAGE_KEY = 'upfitness_recebiveis_filtros_v1';
  const [filtroStatus, setFiltroStatus] = useState<FiltroStatus>('pendentes');
  const [agrupamento, setAgrupamento] = useState<Agrupamento>('data');
  const [filtroCliente, setFiltroCliente] = useState('');
  const [mostrarSugestoes, setMostrarSugestoes] = useState(false);

  const hoje = hojeISO();

  // Carrega filtros + dados ao montar (com checagem de sessão)
  useEffect(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed?.filtroStatus === 'pendentes' || parsed?.filtroStatus === 'pagas' || parsed?.filtroStatus === 'todas') setFiltroStatus(parsed.filtroStatus);
        if (parsed?.agrupamento === 'data' || parsed?.agrupamento === 'cliente') setAgrupamento(parsed.agrupamento);
        if (typeof parsed?.filtroCliente === 'string') setFiltroCliente(parsed.filtroCliente);
      }
    } catch { /* ignore */ }

    let mounted = true;
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) {
        if (mounted) router.replace('/login');
        return;
      }
      await fetchParcelas();
    })();
    return () => { mounted = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Persiste filtros
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ filtroStatus, agrupamento, filtroCliente }));
    } catch { /* ignore */ }
  }, [filtroStatus, agrupamento, filtroCliente]);

  // PWA aberto o dia inteiro: ao voltar para a aba, atualiza a lista
  // (baixas feitas pela outra vendedora aparecem sem recarregar a página).
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === 'visible') fetchParcelas();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- FETCH ---
  // Busca TODAS as parcelas (filtros de status/cliente são aplicados no
  // client): os cards de resumo precisam do total em aberto independente
  // do filtro ativo. Paginação em lotes de 1000 (teto do Supabase).
  async function fetchParcelas() {
    setLoading(true);
    const PAGE = 1000;
    let todas: Parcela[] = [];
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from('crediario_parcelas')
        .select('id, venda_id, numero, valor, data_vencimento, pago, data_pagamento, venda:vendas(codigo_venda, nome_cliente, parcelas, crediario_frequencia)')
        .order('data_vencimento', { ascending: true })
        .order('numero', { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) {
        alert('Erro ao buscar recebíveis: ' + error.message);
        setLoading(false);
        return;
      }
      const lote = (data ?? []) as any as Parcela[];
      todas = todas.concat(lote);
      if (lote.length < PAGE) break;
    }
    setParcelas(todas);
    setLoading(false);
  }

  // --- RESUMO (sempre sobre o conjunto completo de pendentes) ---
  const resumo = useMemo(() => {
    const pendentes = parcelas.filter((p) => !p.pago);
    const soma = (arr: Parcela[]) => arr.reduce((a, p) => a + (Number(p.valor) || 0), 0);
    const vencidas = pendentes.filter((p) => p.data_vencimento < hoje);
    const seteDias = addDiasISO(hoje, 7);
    const proximos7 = pendentes.filter((p) => p.data_vencimento >= hoje && p.data_vencimento <= seteDias);
    return {
      aberto: soma(pendentes),
      qtdAberto: pendentes.length,
      vencido: soma(vencidas),
      qtdVencido: vencidas.length,
      proximos7: soma(proximos7),
      qtdProximos7: proximos7.length,
    };
  }, [parcelas, hoje]);

  // --- CLIENTES (autocomplete a partir das parcelas carregadas) ---
  const clientes = useMemo(() => {
    const set = new Set<string>();
    parcelas.forEach((p) => {
      const n = p.venda?.nome_cliente?.trim();
      if (n) set.add(n);
    });
    return Array.from(set).sort((a, b) => a.localeCompare(b, 'pt-BR'));
  }, [parcelas]);

  const sugestoesFiltradas = useMemo(() => {
    const q = filtroCliente.trim().toLowerCase();
    if (!q) return clientes;
    return clientes.filter((n) => n.toLowerCase().includes(q));
  }, [filtroCliente, clientes]);

  // --- FILTRO APLICADO ---
  const parcelasVisiveis = useMemo(() => {
    let arr = parcelas;
    if (filtroStatus === 'pendentes') arr = arr.filter((p) => !p.pago);
    else if (filtroStatus === 'pagas') arr = arr.filter((p) => p.pago);
    const q = filtroCliente.trim().toLowerCase();
    if (q) arr = arr.filter((p) => (p.venda?.nome_cliente ?? '').toLowerCase().includes(q));
    return arr;
  }, [parcelas, filtroStatus, filtroCliente]);

  // --- AGRUPAMENTOS ---
  // Por data: "Atrasadas" (pendentes vencidas) primeiro, depois cada data.
  const gruposPorData = useMemo(() => {
    if (agrupamento !== 'data') return [];
    const atrasadas = parcelasVisiveis.filter((p) => !p.pago && p.data_vencimento < hoje);
    const demais = parcelasVisiveis.filter((p) => p.pago || p.data_vencimento >= hoje);
    const mapa = new Map<string, Parcela[]>();
    demais.forEach((p) => {
      const arr = mapa.get(p.data_vencimento) ?? [];
      arr.push(p);
      mapa.set(p.data_vencimento, arr);
    });
    const grupos: { chave: string; titulo: string; alerta: boolean; itens: Parcela[] }[] = [];
    if (atrasadas.length > 0) grupos.push({ chave: '__atrasadas', titulo: 'Atrasadas', alerta: true, itens: atrasadas });
    Array.from(mapa.keys()).sort().forEach((dia) => {
      grupos.push({ chave: dia, titulo: rotuloData(dia, hoje), alerta: false, itens: mapa.get(dia)! });
    });
    return grupos;
  }, [agrupamento, parcelasVisiveis, hoje]);

  // Por cliente: ordem alfabética, parcelas por vencimento, subtotal em aberto.
  const gruposPorCliente = useMemo(() => {
    if (agrupamento !== 'cliente') return [];
    const mapa = new Map<string, Parcela[]>();
    parcelasVisiveis.forEach((p) => {
      const nome = p.venda?.nome_cliente?.trim() || 'Sem cliente';
      const arr = mapa.get(nome) ?? [];
      arr.push(p);
      mapa.set(nome, arr);
    });
    return Array.from(mapa.keys())
      .sort((a, b) => a.localeCompare(b, 'pt-BR'))
      .map((nome) => {
        const itens = mapa.get(nome)!;
        const emAberto = itens.filter((p) => !p.pago).reduce((a, p) => a + (Number(p.valor) || 0), 0);
        return { chave: nome, titulo: nome, emAberto, itens };
      });
  }, [agrupamento, parcelasVisiveis]);

  // --- BAIXA / DESFAZER ---
  async function darBaixa(p: Parcela) {
    const cliente = p.venda?.nome_cliente?.trim() || 'Sem cliente';
    if (!confirm(`Dar baixa na ${p.numero}ª parcela de ${cliente} — ${formatBRL(Number(p.valor) || 0)}?`)) return;
    setProcessandoId(p.id);
    try {
      const { error } = await supabase
        .from('crediario_parcelas')
        .update({ pago: true, data_pagamento: hojeISO() })
        .eq('id', p.id);
      if (error) throw new Error(error.message);
      setParcelas((prev) => prev.map((pp) => (pp.id === p.id ? { ...pp, pago: true, data_pagamento: hojeISO() } : pp)));
    } catch (e: any) {
      alert(`Erro ao dar baixa: ${e?.message ?? e}`);
    } finally {
      setProcessandoId(null);
    }
  }

  async function desfazerBaixa(p: Parcela) {
    const cliente = p.venda?.nome_cliente?.trim() || 'Sem cliente';
    if (!confirm(`Desfazer a baixa da ${p.numero}ª parcela de ${cliente}? Ela volta para a lista de pendentes.`)) return;
    setProcessandoId(p.id);
    try {
      const { error } = await supabase
        .from('crediario_parcelas')
        .update({ pago: false, data_pagamento: null })
        .eq('id', p.id);
      if (error) throw new Error(error.message);
      setParcelas((prev) => prev.map((pp) => (pp.id === p.id ? { ...pp, pago: false, data_pagamento: null } : pp)));
    } catch (e: any) {
      alert(`Erro ao desfazer: ${e?.message ?? e}`);
    } finally {
      setProcessandoId(null);
    }
  }

  // --- CARD DE PARCELA ---
  function CardParcela({ p }: { p: Parcela }) {
    const atrasada = !p.pago && p.data_vencimento < hoje;
    const ehHoje = !p.pago && p.data_vencimento === hoje;
    const cliente = p.venda?.nome_cliente?.trim() || 'Sem cliente';
    const freq = p.venda?.crediario_frequencia ? FREQ_CURTA[p.venda.crediario_frequencia] ?? p.venda.crediario_frequencia : null;
    const processando = processandoId === p.id;
    return (
      <div className={`bg-slate-900 rounded-2xl border p-4 flex items-center gap-3 ${atrasada ? 'border-red-900/60' : p.pago ? 'border-emerald-900/40' : 'border-slate-800'}`}>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap mb-1">
            <span className="text-sm font-black text-white truncate">{cliente}</span>
            {atrasada && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-red-500 text-slate-950">atrasada</span>}
            {ehHoje && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-amber-400 text-slate-950">hoje</span>}
            {p.pago && <span className="text-[9px] font-black uppercase px-1.5 py-0.5 rounded bg-emerald-400 text-slate-950">paga</span>}
          </div>
          <p className="text-[10px] font-bold text-slate-400 uppercase">
            #{p.venda?.codigo_venda ?? '—'} • {p.numero}/{p.venda?.parcelas ?? '?'}{freq ? ` • ${freq}` : ''}
          </p>
          <p className="text-[10px] font-mono text-slate-500 mt-0.5">
            Venc. {formatDataCurta(p.data_vencimento)}
            {p.pago && p.data_pagamento ? ` • paga em ${formatDataCurta(p.data_pagamento)}` : ''}
          </p>
        </div>
        <div className="shrink-0 text-right space-y-2">
          <p className={`text-base font-black ${p.pago ? 'text-emerald-400' : 'text-white'}`}>{formatBRL(Number(p.valor) || 0)}</p>
          {p.pago ? (
            <button disabled={processando} onClick={() => desfazerBaixa(p)} className="bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-white border border-slate-700 px-3 py-2 rounded-xl text-[9px] font-black uppercase tracking-widest active:scale-95 disabled:opacity-50">
              {processando ? '...' : 'Desfazer'}
            </button>
          ) : (
            <button disabled={processando} onClick={() => darBaixa(p)} className="bg-emerald-600 hover:bg-emerald-500 text-white px-4 py-2 rounded-xl text-[9px] font-black uppercase tracking-widest shadow active:scale-95 disabled:opacity-50">
              {processando ? '...' : '✓ Baixar'}
            </button>
          )}
        </div>
      </div>
    );
  }

  // --- RENDER ---
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-32">

      {/* FRISO v2 */}
      <div className="h-[3px] w-full bg-gradient-to-r from-pink-600 to-blue-600" />

      {/* HEADER (padrão do Histórico) */}
      <header className="bg-slate-900 p-6 border-b border-slate-800 sticky top-0 z-20 shadow-xl space-y-4">
        <div className="flex items-center gap-4">
          <Link
            href={`/${dashQS}`}
            className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95 transition"
            aria-label="Voltar"
          >
            ←
          </Link>
          <div>
            <h1 className="font-black italic text-xl uppercase tracking-tighter">
              Recebíveis <span className="text-violet-500">Crediário</span>
            </h1>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">
              Projeção de pagamentos e baixa de parcelas
            </p>
          </div>
        </div>

        {/* FILTROS */}
        <div className="space-y-3">
          <div className="flex gap-2">
            {([['pendentes', 'Pendentes'], ['pagas', 'Pagas'], ['todas', 'Todas']] as [FiltroStatus, string][]).map(([k, label]) => (
              <button key={k} onClick={() => setFiltroStatus(k)} className={`flex-1 py-2.5 rounded-xl text-[10px] font-black uppercase tracking-widest border transition-colors active:scale-95 ${filtroStatus === k ? 'bg-violet-600 border-violet-500 text-white' : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'}`}>
                {label}
              </button>
            ))}
            <button onClick={() => setAgrupamento((prev) => (prev === 'data' ? 'cliente' : 'data'))} className="flex-1 py-2.5 rounded-xl text-[10px] font-black uppercase tracking-widest border bg-slate-800 border-slate-700 text-slate-200 hover:border-slate-500 active:scale-95">
              {agrupamento === 'data' ? '⇅ Por data' : '⇅ Por cliente'}
            </button>
          </div>

          <div className="relative">
            <input
              type="text"
              placeholder="Filtrar por cliente..."
              autoComplete="off"
              className="w-full bg-slate-950 border border-slate-700 focus:border-violet-500 outline-none px-4 py-3 rounded-xl text-white font-bold text-sm placeholder:text-slate-600"
              value={filtroCliente}
              onChange={(e) => { setFiltroCliente(e.target.value); setMostrarSugestoes(true); }}
              onFocus={() => setMostrarSugestoes(true)}
              onBlur={() => setTimeout(() => setMostrarSugestoes(false), 150)}
            />
            {filtroCliente && (
              <button onClick={() => setFiltroCliente('')} className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-500 hover:text-white text-sm font-bold">✕</button>
            )}
            {mostrarSugestoes && sugestoesFiltradas.length > 0 && (
              <div className="absolute left-0 right-0 z-50 mt-1 bg-slate-900 border border-slate-700 rounded-2xl overflow-hidden shadow-2xl max-h-48 overflow-y-auto">
                {sugestoesFiltradas.map((nome) => (
                  <button
                    key={nome}
                    type="button"
                    onMouseDown={() => { setFiltroCliente(nome); setMostrarSugestoes(false); }}
                    className="w-full text-left px-4 py-3 text-sm font-bold text-white hover:bg-violet-600 transition-colors border-b border-slate-800 last:border-0"
                  >
                    {nome}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">

        {/* CARDS DE RESUMO (sempre sobre o total, independente do filtro) */}
        <div className="grid grid-cols-3 gap-3">
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-violet-400 uppercase tracking-widest">Em aberto</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.aberto)}</p>
            <span className="text-[9px] font-bold text-slate-500 uppercase">{loading ? '' : `${resumo.qtdAberto} parcela(s)`}</span>
          </div>
          <div className={`bg-slate-900 p-4 rounded-2xl border shadow-lg flex flex-col justify-between ${resumo.qtdVencido > 0 ? 'border-red-900/60' : 'border-slate-800'}`}>
            <span className="text-[10px] font-black text-red-400 uppercase tracking-widest">Vencido</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.vencido)}</p>
            <span className="text-[9px] font-bold text-slate-500 uppercase">{loading ? '' : `${resumo.qtdVencido} parcela(s)`}</span>
          </div>
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-emerald-400 uppercase tracking-widest">Próx. 7 dias</span>
            <p className="text-base md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(resumo.proximos7)}</p>
            <span className="text-[9px] font-bold text-slate-500 uppercase">{loading ? '' : `${resumo.qtdProximos7} parcela(s)`}</span>
          </div>
        </div>

        {/* LISTA */}
        {loading ? (
          <div className="text-slate-400 text-xs font-bold uppercase tracking-widest text-center py-16 animate-pulse">Carregando recebíveis...</div>
        ) : parcelasVisiveis.length === 0 ? (
          <div className="text-slate-500 text-sm font-bold uppercase tracking-widest text-center py-16">
            {parcelas.length === 0 ? 'Nenhuma venda em crediário ainda' : 'Nada encontrado com os filtros atuais'}
          </div>
        ) : agrupamento === 'data' ? (
          <div className="space-y-6">
            {gruposPorData.map((g) => (
              <section key={g.chave} className="space-y-2">
                <div className="flex items-center justify-between px-1">
                  <h2 className={`text-[11px] font-black uppercase tracking-widest ${g.alerta ? 'text-red-400' : 'text-slate-400'}`}>
                    {g.alerta ? '⚠ ' : ''}{g.titulo}
                  </h2>
                  <span className="text-[10px] font-black text-slate-500">
                    {formatBRL(g.itens.reduce((a, p) => a + (Number(p.valor) || 0), 0))} • {g.itens.length}
                  </span>
                </div>
                <div className="space-y-2">
                  {g.itens.map((p) => <CardParcela key={p.id} p={p} />)}
                </div>
              </section>
            ))}
          </div>
        ) : (
          <div className="space-y-6">
            {gruposPorCliente.map((g) => (
              <section key={g.chave} className="space-y-2">
                <div className="flex items-center justify-between px-1">
                  <h2 className="text-[11px] font-black uppercase tracking-widest text-slate-300 truncate">{g.titulo}</h2>
                  <span className="text-[10px] font-black text-violet-400 shrink-0">
                    {g.emAberto > 0 ? `em aberto: ${formatBRL(g.emAberto)}` : 'quitado'}
                  </span>
                </div>
                <div className="space-y-2">
                  {g.itens.map((p) => <CardParcela key={p.id} p={p} />)}
                </div>
              </section>
            ))}
          </div>
        )}
      </main>

      {/* NAV (Recebíveis ativo) */}
      <div className="fixed left-6 right-6 z-[60]" style={{ bottom: `calc(env(safe-area-inset-bottom, 0px) + 10px)` }}>
        <nav className="bg-slate-900/95 backdrop-blur-2xl border border-white/5 rounded-[2.5rem] h-20 px-4 flex items-center justify-around shadow-2xl">
          <Link href={`/${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M21 7.5l-9-5.25L3 7.5m18 0l-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9" />
              </svg>
            </div>
            <span className="text-[9px] font-black text-white uppercase tracking-widest">ESTOQUE</span>
          </Link>

          <Link href={`/venda${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 3h1.386c.51 0 .955.343 1.087.835l.383 1.437M7.5 14.25a3 3 0 00-3 3h15.75m-12.75-3h11.218c1.121-2.3 2.1-4.684 2.924-7.138a60.114 60.114 0 00-16.536-1.84M7.5 14.25L5.106 5.272M6 20.25a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm12.75 0a.75.75 0 11-1.5 0 .75.75 0 011.5 0z" />
              </svg>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest">VENDA</span>
          </Link>

          <Link href={`/historico${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z" />
              </svg>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Histórico</span>
          </Link>

          <Link href={`/recebiveis${dashQS}`} className="flex flex-col items-center gap-1">
            <div className="p-2 rounded-2xl bg-pink-500/20 text-pink-500">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 18.75a60.07 60.07 0 0115.797 2.101c.727.198 1.453-.342 1.453-1.096V18.75M3.75 4.5v.75A.75.75 0 013 6h-.75m0 0v-.375c0-.621.504-1.125 1.125-1.125H20.25M2.25 6v9m18-10.5v.75c0 .414.336.75.75.75h.75m-1.5-1.5h.375c.621 0 1.125.504 1.125 1.125v9.75c0 .621-.504 1.125-1.125 1.125h-.375m1.5-1.5H21a.75.75 0 00-.75.75v.75m0 0H3.75m0 0h-.375a1.125 1.125 0 01-1.125-1.125V15m1.5 1.5v-.75A.75.75 0 003 15h-.75M15 10.5a3 3 0 11-6 0 3 3 0 016 0zm3 0h.008v.008H18V10.5zm-12 0h.008v.008H6V10.5z" />
              </svg>
            </div>
            <span className="text-[9px] font-black text-pink-500 tracking-widest uppercase">Recebíveis</span>
          </Link>

          <Link href={`/relatorios${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2 text-white">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 18L9 11.25l4.306 4.307a11.95 11.95 0 015.814-5.519l2.74-1.22m0 0l-5.94-2.28m5.94 2.28l-2.28 5.941" />
              </svg>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Relatórios</span>
          </Link>
        </nav>
      </div>
    </div>
  );
}