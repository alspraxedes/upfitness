// src/app/relatorios/page.tsx
'use client';

import { Suspense, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabase } from '../../lib/supabase';
import { getSignedUrlCached } from '../../lib/signedUrlCache';

// --- UTIL ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

function toISODateLocal(d: Date) {
  const yy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${yy}-${mm}-${dd}`;
}
function startOfDay(d: Date) {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}
function endOfDay(d: Date) {
  const x = new Date(d);
  x.setHours(23, 59, 59, 999);
  return x;
}
function addDays(d: Date, days: number) {
  const x = new Date(d);
  x.setDate(x.getDate() + days);
  return x;
}

// Extração robusta do path da imagem do Supabase
function extractPath(url: string | null) {
  if (!url) return null;
  if (!url.startsWith('http')) return url;

  try {
    const urlObj = new URL(url);
    const pathName = urlObj.pathname;

    const bucketName = 'produtos';
    const markerPublic = `/public/${bucketName}/`;
    const markerSign = `/${bucketName}/`;

    let extractedPath = '';

    if (pathName.includes(markerPublic)) {
      extractedPath = pathName.substring(pathName.indexOf(markerPublic) + markerPublic.length);
    } else if (pathName.includes(markerSign)) {
      extractedPath = pathName.substring(pathName.indexOf(markerSign) + markerSign.length);
    } else {
      const parts = pathName.split('/');
      const bucketIndex = parts.findIndex((p) => p === bucketName);
      if (bucketIndex !== -1 && parts.length > bucketIndex + 1) {
        extractedPath = parts.slice(bucketIndex + 1).join('/');
      }
    }

    return extractedPath ? decodeURIComponent(extractedPath) : null;
  } catch {
    return null;
  }
}

// --- TIPOS (Supabase) ---
type VendaRow = {
  id: string;
  created_at: string;
  valor_liquido: number | null;
  valor_total: number | null;
};

type ItemVendaRow = {
  venda_id: string;
  produto_id: string | null;
  descricao_completa: string | null;
  quantidade: number | null;
  subtotal: number | null;
  produto?: {
    id?: string | null;
    descricao?: string | null;
    fornecedor?: string | null;
    preco_compra?: number | null;
    preco_venda?: number | null;
    custo_frete?: number | null;
    custo_embalagem?: number | null;
    foto_url?: string | null;
  } | null;
};

type DailyPoint = { day: string; total: number };

type ProductAgg = {
  key: string;
  label: string;
  fornecedor: string;
  foto_url: string | null;
  qtd: number;
  receita: number;
  custo_unit: number; // compra+frete+emb
  margem_unit: number; // venda - custo_unit
  margem_total: number; // margem_unit*qtd
  margem_pct: number; // margem_unit/venda
};

type SupplierItemAgg = {
  key: string;
  label: string;
  foto_url: string | null;
  fornecedor: string;
  qtd: number;
  receita: number;
  margem_total: number;
  margem_pct: number;
};

type SupplierAgg = {
  key: string;
  label: string;
  qtd: number;
  receita: number;
  margem_total: number;
  itemsTop: SupplierItemAgg[]; // top itens do fornecedor (com detalhes)
};

// ---- PAGE WRAPPER ----
export default function RelatoriosPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950 text-slate-100" />}>
      <RelatoriosInner />
    </Suspense>
  );
}

function RelatoriosInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getQS(searchParams), [searchParams]);

  const today = useMemo(() => startOfDay(new Date()), []);
  const defaultEnd = useMemo(() => today, [today]);
  const defaultStart = useMemo(() => addDays(today, -13), [today]); // 14 dias

  const [dataInicio, setDataInicio] = useState(toISODateLocal(defaultStart));
  const [dataFim, setDataFim] = useState(toISODateLocal(defaultEnd));

  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState('');

  // Dados
  const [series, setSeries] = useState<DailyPoint[]>([]);
  const [prodAgg, setProdAgg] = useState<ProductAgg[]>([]);
  const [suppAgg, setSuppAgg] = useState<SupplierAgg[]>([]);

  // KPIs
  const [kpis, setKpis] = useState({
    receita: 0,
    pedidos: 0,
    itensVendidos: 0,
    ticketMedio: 0,
  });

  // UI: ranking produtos
  const [modoProdutos, setModoProdutos] = useState<'qtd' | 'margem'>('qtd');
  const [limiteProdutos, setLimiteProdutos] = useState(5);

  // UI: expansão fornecedores
  const [fornecedorExpandido, setFornecedorExpandido] = useState<string | null>(null);

  // Tooltip gráfico diário
  const chartWrapRef = useRef<HTMLDivElement>(null);
  const [tip, setTip] = useState<null | { day: string; total: number; x: number; y: number; place: 'top' | 'inside' }>(null);

  // Fotos assinadas (thumbnails do ranking + itens por fornecedor)
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const signedMapRef = useRef<Record<string, string>>({});
  useEffect(() => {
    signedMapRef.current = signedMap;
  }, [signedMap]);

  // Persistência
  const STORAGE_KEY = 'upfitness_relatorios_filtros_v4';

  useEffect(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (typeof parsed?.dataInicio === 'string') setDataInicio(parsed.dataInicio);
        if (typeof parsed?.dataFim === 'string') setDataFim(parsed.dataFim);
        if (typeof parsed?.modoProdutos === 'string' && (parsed.modoProdutos === 'qtd' || parsed.modoProdutos === 'margem'))
          setModoProdutos(parsed.modoProdutos);
        if (typeof parsed?.limiteProdutos === 'number') setLimiteProdutos(Math.min(30, Math.max(3, parsed.limiteProdutos)));
      }
    } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ dataInicio, dataFim, modoProdutos, limiteProdutos }));
    } catch {}
  }, [dataInicio, dataFim, modoProdutos, limiteProdutos]);

  useEffect(() => {
    let mounted = true;
    const init = async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) {
        if (mounted) router.replace('/login');
        return;
      }
      await carregar();
    };
    init();
    return () => {
      mounted = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // debounce ao mudar datas
  useEffect(() => {
    const t = setTimeout(() => {
      carregar();
    }, 150);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dataInicio, dataFim]);

  const limparFiltros = () => {
    setDataInicio(toISODateLocal(defaultStart));
    setDataFim(toISODateLocal(defaultEnd));
    setModoProdutos('qtd');
    setLimiteProdutos(5);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {}
  };

  async function carregar() {
    setLoading(true);
    setErrorMsg('');

    try {
      const s = startOfDay(new Date(`${dataInicio}T00:00:00`));
      const e = endOfDay(new Date(`${dataFim}T00:00:00`));
      if (s.getTime() > e.getTime()) {
        setErrorMsg('Período inválido: a data inicial é maior que a final.');
        setLoading(false);
        return;
      }

      // 1) Vendas
      const { data: vendasData, error: errVendas } = await supabase
        .from('vendas')
        .select('id, created_at, valor_liquido, valor_total')
        .gte('created_at', `${toISODateLocal(s)}T00:00:00`)
        .lte('created_at', `${toISODateLocal(e)}T23:59:59`)
        .order('created_at', { ascending: true });

      if (errVendas) throw errVendas;

      const vendas = ((vendasData as any) || []) as VendaRow[];
      const vendaIds = vendas.map((x) => x.id);

      // 2) Itens + produtos
      const { data: itensData, error: errItens } = vendaIds.length
        ? await supabase
            .from('itens_venda')
            .select(
              `
              venda_id,
              produto_id,
              descricao_completa,
              quantidade,
              subtotal,
              produto:produtos (
                id, descricao, fornecedor, preco_compra, preco_venda, custo_frete, custo_embalagem, foto_url
              )
            `
            )
            .in('venda_id', vendaIds)
        : { data: [], error: null };

      if (errItens) throw errItens;

      const itens = ((itensData as any) || []) as ItemVendaRow[];

      // 3) KPIs
      const receita = vendas.reduce((a, x) => a + (Number(x.valor_liquido) || 0), 0);
      const pedidos = vendas.length;
      const itensVendidos = itens.reduce((a, x) => a + (Number(x.quantidade) || 0), 0);
      const ticketMedio = pedidos > 0 ? receita / pedidos : 0;
      setKpis({ receita, pedidos, itensVendidos, ticketMedio });

      // 4) Série diária
      const map = new Map<string, number>();
      for (const row of vendas) {
        const day = toISODateLocal(new Date(row.created_at));
        map.set(day, (map.get(day) || 0) + (Number(row.valor_liquido) || 0));
      }
      const days: DailyPoint[] = [];
      const cur = new Date(s);
      while (cur.getTime() <= e.getTime()) {
        const d = toISODateLocal(cur);
        days.push({ day: d, total: map.get(d) || 0 });
        cur.setDate(cur.getDate() + 1);
      }
      setSeries(days);

      // 5) Agregação por produto
      const prodMap = new Map<string, ProductAgg>();
      for (const row of itens) {
        const key = (row.produto_id || row.descricao_completa || 'produto').toString();
        const label = (row.produto?.descricao || row.descricao_completa || 'Produto').toString();
        const fornecedor = (row.produto?.fornecedor || 'Sem fornecedor').toString().trim() || 'Sem fornecedor';
        const foto_url = row.produto?.foto_url || null;

        const qtd = Number(row.quantidade) || 0;
        const receitaItem = Number(row.subtotal) || 0;

        const precoCompra = Number(row.produto?.preco_compra) || 0;
        const custoFrete = Number(row.produto?.custo_frete) || 0;
        const custoEmb = Number(row.produto?.custo_embalagem) || 0;
        const precoVenda = Number(row.produto?.preco_venda) || 0;

        const custoUnit = precoCompra + custoFrete + custoEmb;
        const margemUnit = precoVenda > 0 ? precoVenda - custoUnit : 0;
        const margemPct = precoVenda > 0 ? (margemUnit / precoVenda) * 100 : 0;
        const margemTotal = margemUnit * qtd;

        const curRow =
          prodMap.get(key) ||
          ({
            key,
            label,
            fornecedor,
            foto_url,
            qtd: 0,
            receita: 0,
            custo_unit: custoUnit,
            margem_unit: margemUnit,
            margem_total: 0,
            margem_pct: margemPct,
          } as ProductAgg);

        if (custoUnit > 0) curRow.custo_unit = custoUnit;
        if (precoVenda > 0) {
          curRow.margem_unit = margemUnit;
          curRow.margem_pct = margemPct;
        }
        if (foto_url) curRow.foto_url = foto_url;
        if (fornecedor) curRow.fornecedor = fornecedor;

        curRow.qtd += qtd;
        curRow.receita += receitaItem;
        curRow.margem_total += margemTotal;

        prodMap.set(key, curRow);
      }

      const prodArr = Array.from(prodMap.values());
      setProdAgg(prodArr);

      // 6) Agregação por fornecedor + top itens detalhados
      const suppMap = new Map<
        string,
        { qtd: number; receita: number; margem_total: number; items: Map<string, SupplierItemAgg> }
      >();

      for (const p of prodArr) {
        const key = (p.fornecedor || 'Sem fornecedor').toString().trim() || 'Sem fornecedor';
        const curSupp = suppMap.get(key) || { qtd: 0, receita: 0, margem_total: 0, items: new Map() };

        curSupp.qtd += p.qtd;
        curSupp.receita += p.receita;
        curSupp.margem_total += p.margem_total;

        const itemKey = p.key;
        const itemAgg =
          curSupp.items.get(itemKey) ||
          ({
            key: p.key,
            label: p.label,
            foto_url: p.foto_url,
            fornecedor: p.fornecedor,
            qtd: 0,
            receita: 0,
            margem_total: 0,
            margem_pct: p.margem_pct,
          } as SupplierItemAgg);

        itemAgg.qtd += p.qtd;
        itemAgg.receita += p.receita;
        itemAgg.margem_total += p.margem_total;
        // margem_pct já vem do cadastro (aprox.)

        curSupp.items.set(itemKey, itemAgg);
        suppMap.set(key, curSupp);
      }

      const suppArr: SupplierAgg[] = Array.from(suppMap.entries()).map(([key, v]) => {
        const itemsTop = Array.from(v.items.values())
          .sort((a, b) => b.qtd - a.qtd)
          .slice(0, 5); // agora top 5 com detalhes

        return {
          key,
          label: key,
          qtd: v.qtd,
          receita: v.receita,
          margem_total: v.margem_total,
          itemsTop,
        };
      });

      suppArr.sort((a, b) => b.qtd - a.qtd);
      setSuppAgg(suppArr);
    } catch (e: any) {
      console.error(e);
      setErrorMsg(e?.message || 'Erro ao carregar relatórios.');
      setSeries([]);
      setProdAgg([]);
      setSuppAgg([]);
      setKpis({ receita: 0, pedidos: 0, itensVendidos: 0, ticketMedio: 0 });
    } finally {
      setLoading(false);
    }
  }

  // --- Assinar thumbnails (produtos.foto_url) ---
  const fotosFingerprint = useMemo(() => {
    const urls: string[] = [];

    prodAgg.forEach((p) => {
      if (p.foto_url) urls.push(p.foto_url);
    });
    suppAgg.forEach((s) => {
      s.itemsTop?.forEach((it) => {
        if (it.foto_url) urls.push(it.foto_url);
      });
    });

    return urls.join('|');
  }, [prodAgg, suppAgg]);

  useEffect(() => {
    if (!fotosFingerprint) return;

    let cancelled = false;

    const uniqueUrls = Array.from(
      new Set(
        fotosFingerprint
          .split('|')
          .map((x) => x.trim())
          .filter(Boolean)
      )
    );

    const run = async () => {
      const updates: Record<string, string> = {};

      await Promise.all(
        uniqueUrls.map(async (url) => {
          if (!url) return;
          if (signedMapRef.current[url]) return;

          const signed = await getSignedUrlCached('produtos', url, extractPath, 3600);
          if (!cancelled && signed) updates[url] = signed;
        })
      );

      if (!cancelled && Object.keys(updates).length > 0) {
        setSignedMap((prev) => ({ ...prev, ...updates }));
      }
    };

    run();

    return () => {
      cancelled = true;
    };
  }, [fotosFingerprint]);

  // --- Ordenação e limite do ranking de produtos ---
  const produtosOrdenados = useMemo(() => {
    const arr = [...prodAgg];
    if (modoProdutos === 'margem') arr.sort((a, b) => b.margem_total - a.margem_total);
    else arr.sort((a, b) => b.qtd - a.qtd);
    return arr.slice(0, Math.min(30, Math.max(3, limiteProdutos)));
  }, [prodAgg, modoProdutos, limiteProdutos]);

  // --- “Item mais vendido” e “Fornecedor mais vendido” (por qtd) ---
  const itemMaisVendido = useMemo(() => {
    if (!prodAgg.length) return null;
    return [...prodAgg].sort((a, b) => b.qtd - a.qtd)[0] || null;
  }, [prodAgg]);

  const fornecedorMaisVendido = useMemo(() => {
    if (!suppAgg.length) return null;
    return suppAgg[0] || null;
  }, [suppAgg]);

  // --- Chart tooltip (fix: nunca sair do container) ---
  const maxBar = useMemo(() => {
    let m = 0;
    for (const p of series) m = Math.max(m, p.total);
    return m || 1;
  }, [series]);

  const hideTip = () => setTip(null);

  const showTipFor = (day: string, total: number, targetEl: HTMLElement) => {
    const wrap = chartWrapRef.current;
    if (!wrap) return;

    const wrapRect = wrap.getBoundingClientRect();
    const tRect = targetEl.getBoundingClientRect();

    const x = tRect.left - wrapRect.left + tRect.width / 2;

    // tenta "top"; se estiver perto do topo, coloca "dentro" do gráfico
    const topY = tRect.top - wrapRect.top - 10;
    const insideY = tRect.top - wrapRect.top + 18;

    const place: 'top' | 'inside' = topY < 28 ? 'inside' : 'top';
    const y = place === 'top' ? topY : insideY;

    setTip({ day, total, x, y, place });
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-24">
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
              Relatórios <span className="text-pink-600">Compras</span>
            </h1>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">
              Itens e fornecedores mais vendidos + evolução diária
            </p>
          </div>
        </div>

        <div className="flex flex-col md:flex-row gap-3">
          <div className="flex gap-2 flex-1">
            <input
              type="date"
              value={dataInicio}
              onChange={(e) => setDataInicio(e.target.value)}
              className="bg-slate-950 border border-slate-700 text-white rounded-xl px-3 py-2 w-full text-xs font-bold uppercase"
            />
            <input
              type="date"
              value={dataFim}
              onChange={(e) => setDataFim(e.target.value)}
              className="bg-slate-950 border border-slate-700 text-white rounded-xl px-3 py-2 w-full text-xs font-bold uppercase"
            />
          </div>

          <div className="flex gap-2">
            <button
              onClick={carregar}
              className="flex-1 bg-pink-600 text-white px-6 py-2 rounded-xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95 hover:bg-pink-500 transition"
            >
              Atualizar
            </button>
            <button
              onClick={limparFiltros}
              className="bg-slate-800 text-slate-200 px-4 py-2 rounded-xl font-black uppercase text-xs tracking-widest border border-slate-700 hover:bg-slate-700 active:scale-95 transition"
              title="Resetar período e controles"
            >
              Reset
            </button>
          </div>
        </div>

        {errorMsg && <div className="text-xs font-bold text-red-400">{errorMsg}</div>}
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">
        {/* KPIs úteis */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Faturamento</span>
            <p className="text-lg md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(kpis.receita)}</p>
          </div>
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Pedidos</span>
            <p className="text-lg md:text-xl font-black text-white truncate">{loading ? '—' : kpis.pedidos}</p>
          </div>
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Itens vendidos</span>
            <p className="text-lg md:text-xl font-black text-white truncate">{loading ? '—' : kpis.itensVendidos}</p>
          </div>
          <div className="bg-slate-900 p-4 rounded-2xl border border-slate-800 shadow-lg flex flex-col justify-between">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Ticket médio</span>
            <p className="text-lg md:text-xl font-black text-white truncate">{loading ? '—' : formatBRL(kpis.ticketMedio)}</p>
          </div>
        </div>

        {/* Cards */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div className="bg-slate-900 p-5 rounded-2xl border border-slate-800 shadow-lg">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Item mais vendido</span>
            {loading ? (
              <div className="py-6 opacity-50 animate-pulse text-xs font-bold uppercase">Carregando...</div>
            ) : !itemMaisVendido ? (
              <div className="py-6 opacity-30 font-bold">Sem dados no período.</div>
            ) : (
              <div className="mt-2">
                <p className="font-black text-white uppercase text-sm">{itemMaisVendido.label}</p>
                <div className="mt-1 text-[10px] font-black uppercase tracking-widest text-slate-600">
                  {itemMaisVendido.fornecedor}
                </div>
                <div className="mt-2 flex items-center justify-between text-xs font-bold uppercase text-slate-400">
                  <span>Qtd: {itemMaisVendido.qtd}</span>
                  <span>Receita: {formatBRL(itemMaisVendido.receita)}</span>
                </div>
              </div>
            )}
          </div>

          <div className="bg-slate-900 p-5 rounded-2xl border border-slate-800 shadow-lg">
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Fornecedor mais vendido</span>
            {loading ? (
              <div className="py-6 opacity-50 animate-pulse text-xs font-bold uppercase">Carregando...</div>
            ) : !fornecedorMaisVendido ? (
              <div className="py-6 opacity-30 font-bold">Sem dados no período.</div>
            ) : (
              <div className="mt-2">
                <p className="font-black text-white uppercase text-sm">{fornecedorMaisVendido.label}</p>
                <div className="mt-2 flex items-center justify-between text-xs font-bold uppercase text-slate-400">
                  <span>Qtd: {fornecedorMaisVendido.qtd}</span>
                  <span>Receita: {formatBRL(fornecedorMaisVendido.receita)}</span>
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Gráfico diário (tooltip fixado dentro) */}
        <div className="bg-slate-900 p-4 md:p-6 rounded-2xl border border-slate-800 shadow-lg overflow-hidden">
          <div className="flex items-end justify-between gap-4">
            <div>
              <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Vendas por dia</span>
              <p className="font-black italic text-lg uppercase tracking-tighter">
                Evolução <span className="text-pink-600">diária</span>
              </p>
            </div>
            <div className="text-[10px] font-black tracking-widest uppercase text-slate-500">
              Toque/hover para ver valor
            </div>
          </div>

          {loading ? (
            <div className="text-center py-10 opacity-50 animate-pulse">
              <p className="text-xs font-bold uppercase">Carregando gráfico...</p>
            </div>
          ) : series.length === 0 ? (
            <div className="text-center py-12 opacity-30">
              <span className="text-4xl grayscale">📈</span>
              <p className="mt-2 font-bold">Sem dados no período.</p>
            </div>
          ) : (
            <div className="mt-5 overflow-x-auto">
              <div ref={chartWrapRef} className="relative min-w-[720px]">
                {/* tooltip (nunca sai do container; se barra muito alta, mostra "inside") */}
                {tip && (
                  <div
                    className={`absolute z-10 -translate-x-1/2 pointer-events-none ${
                      tip.place === 'top' ? '-translate-y-full' : ''
                    }`}
                    style={{ left: tip.x, top: tip.y }}
                  >
                    <div className="bg-slate-950 border border-slate-700 rounded-xl px-3 py-2 shadow-2xl max-w-[220px]">
                      <div className="text-[10px] font-black uppercase tracking-widest text-slate-500">{tip.day}</div>
                      <div className="text-sm font-black text-white">{formatBRL(tip.total)}</div>
                    </div>
                  </div>
                )}

                <div className="h-44 flex items-end gap-2">
                  {series.map((p) => {
                    const h = Math.max(2, Math.round((p.total / maxBar) * 160));
                    return (
                      <div key={p.day} className="flex-1 min-w-[24px] flex flex-col items-center gap-2">
                        <button
                          type="button"
                          className="w-full flex items-end justify-center focus:outline-none"
                          onMouseEnter={(e) => showTipFor(p.day, p.total, e.currentTarget)}
                          onMouseMove={(e) => showTipFor(p.day, p.total, e.currentTarget)}
                          onMouseLeave={hideTip}
                          onClick={(e) => {
                            if (tip?.day === p.day) hideTip();
                            else showTipFor(p.day, p.total, e.currentTarget);
                          }}
                          aria-label={`${p.day}: ${formatBRL(p.total)}`}
                        >
                          <div className="w-4 rounded-md bg-pink-500/90" style={{ height: h }} />
                        </button>
                        <div className="text-[9px] text-slate-500 font-black tracking-widest uppercase">
                          {p.day.slice(5).replace('-', '/')}
                        </div>
                      </div>
                    );
                  })}
                </div>

                {tip && (
                  <button type="button" onClick={hideTip} className="absolute inset-0 -z-[1]" aria-label="Fechar tooltip" tabIndex={-1} />
                )}
              </div>
            </div>
          )}
        </div>

        {/* Rank: Produtos */}
        <div className="bg-slate-900 p-4 md:p-6 rounded-2xl border border-slate-800 shadow-lg">
          <div className="flex flex-col md:flex-row md:items-end md:justify-between gap-3">
            <div>
              <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Planejamento</span>
              <p className="font-black italic text-lg uppercase tracking-tighter">
                Top produtos <span className="text-pink-600">(ranking)</span>
              </p>
            </div>

            <div className="flex flex-wrap gap-2 items-center">
              <div className="flex bg-slate-950 border border-slate-800 rounded-xl overflow-hidden">
                <button
                  onClick={() => setModoProdutos('qtd')}
                  className={`px-3 py-2 text-[10px] font-black uppercase tracking-widest ${
                    modoProdutos === 'qtd' ? 'bg-pink-600 text-white' : 'text-slate-400 hover:text-white'
                  }`}
                >
                  Quantidade
                </button>
                <button
                  onClick={() => setModoProdutos('margem')}
                  className={`px-3 py-2 text-[10px] font-black uppercase tracking-widest ${
                    modoProdutos === 'margem' ? 'bg-pink-600 text-white' : 'text-slate-400 hover:text-white'
                  }`}
                >
                  Margem
                </button>
              </div>

              <div className="flex items-center gap-2">
                <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">Itens:</span>
                <input
                  type="number"
                  min={3}
                  max={30}
                  value={limiteProdutos}
                  onChange={(e) => setLimiteProdutos(Math.min(30, Math.max(3, Number(e.target.value) || 5)))}
                  className="w-20 bg-slate-950 border border-slate-800 text-white rounded-xl px-3 py-2 text-xs font-black"
                />
              </div>
            </div>
          </div>

          {loading ? (
            <div className="text-center py-10 opacity-50 animate-pulse">
              <p className="text-xs font-bold uppercase">Carregando...</p>
            </div>
          ) : produtosOrdenados.length === 0 ? (
            <div className="text-center py-12 opacity-30">
              <span className="text-4xl grayscale">🏷️</span>
              <p className="mt-2 font-bold">Sem itens no período.</p>
            </div>
          ) : (
            <div className="mt-4 space-y-2">
              {produtosOrdenados.map((p, i) => {
                const thumb = p.foto_url ? signedMap[p.foto_url] : null;
                const margemBadge =
                  p.margem_total >= 0 ? 'bg-emerald-500/15 text-emerald-400 border-emerald-900/40' : 'bg-red-500/15 text-red-400 border-red-900/40';

                return (
                  <div key={`${p.key}-${i}`} className="bg-slate-950 border border-slate-800 rounded-2xl p-4 flex gap-3">
                    <div className="w-14 h-14 rounded-2xl overflow-hidden bg-slate-900 border border-slate-800 flex-shrink-0 relative">
                      {thumb ? (
                        <Image src={thumb} alt={p.label} fill className="object-cover" unoptimized />
                      ) : (
                        <div className="w-full h-full flex items-center justify-center text-[10px] font-black uppercase text-slate-600">
                          {p.foto_url ? '...' : 'Sem'}
                        </div>
                      )}
                    </div>

                    <div className="min-w-0 flex-1">
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <div className="text-[11px] font-black uppercase text-slate-200 truncate">
                            {i + 1}. {p.label}
                          </div>
                          <div className="mt-1 text-[10px] font-black uppercase tracking-widest text-slate-600 truncate">
                            {p.fornecedor}
                          </div>
                        </div>

                        <div className="text-right flex-shrink-0">
                          <div className="text-xs font-black text-white whitespace-nowrap">{formatBRL(p.receita)}</div>
                          <div className="text-[10px] font-black uppercase tracking-widest text-slate-600">receita</div>
                        </div>
                      </div>

                      <div className="mt-3 flex flex-wrap gap-2 items-center">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                          Qtd: {p.qtd}
                        </span>

                        <span className={`text-[10px] font-black uppercase tracking-widest border px-2 py-1 rounded-xl ${margemBadge}`}>
                          Margem: {formatBRL(p.margem_total)}
                        </span>

                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                          Mk: {p.margem_pct.toFixed(1)}%
                        </span>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Rank: Fornecedores (expande e mostra itens com MESMO CARD do ranking de produtos) */}
        <div className="bg-slate-900 p-4 md:p-6 rounded-2xl border border-slate-800 shadow-lg">
          <div>
            <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Planejamento</span>
            <p className="font-black italic text-lg uppercase tracking-tighter">
              Top fornecedores <span className="text-pink-600">(expanda p/ itens)</span>
            </p>
          </div>

          {loading ? (
            <div className="text-center py-10 opacity-50 animate-pulse">
              <p className="text-xs font-bold uppercase">Carregando...</p>
            </div>
          ) : suppAgg.length === 0 ? (
            <div className="text-center py-12 opacity-30">
              <span className="text-4xl grayscale">🏭</span>
              <p className="mt-2 font-bold">Sem dados no período.</p>
            </div>
          ) : (
            <div className="mt-4 space-y-2">
              {suppAgg.map((s, i) => {
                const open = fornecedorExpandido === s.key;
                const margemBadge =
                  s.margem_total >= 0 ? 'bg-emerald-500/15 text-emerald-400 border-emerald-900/40' : 'bg-red-500/15 text-red-400 border-red-900/40';

                return (
                  <div
                    key={s.key}
                    className={`rounded-2xl border overflow-hidden transition-all ${
                      open ? 'border-pink-500/50 shadow-pink-900/10 shadow-lg' : 'border-slate-800 hover:border-slate-700'
                    }`}
                  >
                    <button
                      className="w-full bg-slate-950 p-4 flex items-center justify-between text-left"
                      onClick={() => setFornecedorExpandido(open ? null : s.key)}
                    >
                      <div className="min-w-0 pr-3">
                        <div className="text-[11px] font-black uppercase text-slate-200 truncate">
                          {i + 1}. {s.label}
                        </div>
                        <div className="mt-2 flex flex-wrap gap-2">
                          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                            Qtd: {s.qtd}
                          </span>
                          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                            Receita: {formatBRL(s.receita)}
                          </span>
                          <span className={`text-[10px] font-black uppercase tracking-widest border px-2 py-1 rounded-xl ${margemBadge}`}>
                            Margem: {formatBRL(s.margem_total)}
                          </span>
                        </div>
                      </div>

                      <div className="text-[10px] font-black uppercase tracking-widest text-slate-500">{open ? '▲ Recolher' : '▼ Itens'}</div>
                    </button>

                    {open && (
                      <div className="bg-slate-950/50 border-t border-slate-800 p-4 animate-in slide-in-from-top-2 duration-200">
                        <p className="text-[10px] text-slate-500 font-black uppercase tracking-widest mb-3">Top itens do fornecedor (até 5)</p>

                        {s.itemsTop.length === 0 ? (
                          <div className="text-xs text-slate-500 font-bold uppercase">Sem itens.</div>
                        ) : (
                          <div className="space-y-2">
                            {s.itemsTop.map((p, idx) => {
                              const thumb = p.foto_url ? signedMap[p.foto_url] : null;
                              const margemBadgeItem =
                                p.margem_total >= 0
                                  ? 'bg-emerald-500/15 text-emerald-400 border-emerald-900/40'
                                  : 'bg-red-500/15 text-red-400 border-red-900/40';

                              return (
                                <div key={`${p.key}-${idx}`} className="bg-slate-950 border border-slate-800 rounded-2xl p-4 flex gap-3">
                                  <div className="w-14 h-14 rounded-2xl overflow-hidden bg-slate-900 border border-slate-800 flex-shrink-0 relative">
                                    {thumb ? (
                                      <Image src={thumb} alt={p.label} fill className="object-cover" unoptimized />
                                    ) : (
                                      <div className="w-full h-full flex items-center justify-center text-[10px] font-black uppercase text-slate-600">
                                        {p.foto_url ? '...' : 'Sem'}
                                      </div>
                                    )}
                                  </div>

                                  <div className="min-w-0 flex-1">
                                    <div className="flex items-start justify-between gap-3">
                                      <div className="min-w-0">
                                        <div className="text-[11px] font-black uppercase text-slate-200 truncate">
                                          {idx + 1}. {p.label}
                                        </div>
                                        <div className="mt-1 text-[10px] font-black uppercase tracking-widest text-slate-600 truncate">
                                          {s.label}
                                        </div>
                                      </div>

                                      <div className="text-right flex-shrink-0">
                                        <div className="text-xs font-black text-white whitespace-nowrap">{formatBRL(p.receita)}</div>
                                        <div className="text-[10px] font-black uppercase tracking-widest text-slate-600">receita</div>
                                      </div>
                                    </div>

                                    <div className="mt-3 flex flex-wrap gap-2 items-center">
                                      <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                                        Qtd: {p.qtd}
                                      </span>

                                      <span className={`text-[10px] font-black uppercase tracking-widest border px-2 py-1 rounded-xl ${margemBadgeItem}`}>
                                        Margem: {formatBRL(p.margem_total)}
                                      </span>

                                      <span className="text-[10px] font-black uppercase tracking-widest text-slate-400 bg-slate-900 border border-slate-800 px-2 py-1 rounded-xl">
                                        Mk: {p.margem_pct.toFixed(1)}%
                                      </span>
                                    </div>
                                  </div>
                                </div>
                              );
                            })}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </main>

      {/* NAV (Relatórios ativo) */}
      <div className="fixed left-6 right-6 z-[60]" style={{ bottom: `calc(env(safe-area-inset-bottom, 0px) + 10px)` }}>
        <nav className="bg-slate-900/95 backdrop-blur-2xl border border-white/5 rounded-[2.5rem] h-20 px-6 flex items-center justify-around shadow-2xl">
          <Link href={`/${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2">
              <span className="text-xl">📦</span>
            </div>
            <span className="text-[9px] font-black text-white uppercase tracking-widest">ESTOQUE</span>
          </Link>

          <Link href={`/venda${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2">
              <span className="text-xl">🛒</span>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest">VENDA</span>
          </Link>

          <Link href={`/historico${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2">
              <span className="text-xl">🧾</span>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Histórico</span>
          </Link>

          <Link href={`/relatorios${dashQS}`} className="flex flex-col items-center gap-1">
            <div className="p-2 rounded-2xl bg-pink-500/20 text-pink-500">
              <span className="text-xl">📈</span>
            </div>
            <span className="text-[9px] font-black text-pink-500 tracking-widest uppercase">Relatórios</span>
          </Link>
        </nav>
      </div>
    </div>
  );
}