// src/app/relatorios/page.tsx
'use client';

import { Suspense, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabase } from '../../lib/supabase';
import { thumbUrlFromFotoUrl } from '../../lib/thumbUtils';

// --- UTIL ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

// Formato compacto para rótulos de barra (ex: 450 → "450", 1234 → "1,2k",
// 12345 → "12k", 1200000 → "1,2M"). Vazia para zero para não poluir o gráfico.
function formatCompactBR(v: number): string {
  if (!v || v <= 0) return '';
  if (v < 1000) return v.toFixed(0);
  if (v < 10000) return `${(v / 1000).toFixed(1).replace('.', ',')}k`;
  if (v < 1000000) return `${Math.round(v / 1000)}k`;
  return `${(v / 1000000).toFixed(1).replace('.', ',')}M`;
}

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

// Monta o href de /item/[id] com from=relatorios para que o botão de voltar
// da tela do item retorne para esta página em vez do dashboard.
function itemHrefFromRelatorios(id: string, dashQS: string): string {
  const sp = new URLSearchParams(dashQS.startsWith('?') ? dashQS.slice(1) : dashQS);
  sp.set('from', 'relatorios');
  return `/item/${id}?${sp.toString()}`;
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

// Inventário (snapshot atual — independente do filtro de datas)
type ProdutoInventario = {
  id: string;
  descricao: string;
  cor: string | null;
  fornecedor: string;
  foto_url: string | null;
  created_at: string;
  descontinuado: boolean;
  custo_unit: number;
  preco_venda: number;
  qtd: number;
};

type FornecedorInventario = {
  fornecedor: string;
  qtd: number;
  valorCusto: number;
  valorVenda: number;
  lucro: number;
  skus: number;
};

type InventarioKpis = {
  pecas: number;
  skusComEstoque: number;
  valorCusto: number;
  valorVenda: number;
  lucroPotencial: number;
  skusIncompletos: number;
  descontinuadosComEstoque: number;
  pecasDescontinuadas: number;
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

  // Inventário (snapshot, não depende do período)
  const [invKpis, setInvKpis] = useState<InventarioKpis>({
    pecas: 0, skusComEstoque: 0, valorCusto: 0, valorVenda: 0, lucroPotencial: 0,
    skusIncompletos: 0, descontinuadosComEstoque: 0, pecasDescontinuadas: 0,
  });
  const [invPorFornecedor, setInvPorFornecedor] = useState<FornecedorInventario[]>([]);
  const [invMaisAntigos, setInvMaisAntigos] = useState<ProdutoInventario[]>([]);
  const [invDescontinuados, setInvDescontinuados] = useState<ProdutoInventario[]>([]);
  const [loadingInv, setLoadingInv] = useState(true);

  // ABAS (Vendas | Inventário)
  const [aba, setAba] = useState<'vendas' | 'inventario'>('vendas');
  const [descontinuadosAberto, setDescontinuadosAberto] = useState(false);

  // Granularidade do gráfico de evolução (persistida junto dos outros filtros)
  const [granularidade, setGranularidade] = useState<'dia' | 'semana' | 'mes'>('dia');

  // Quantidade de itens no ranking "Mais antigos ainda em estoque" (até 100)
  const [limiteAntigos, setLimiteAntigos] = useState(10);

  // KPIs
  const [kpis, setKpis] = useState({
    receita: 0,
    pedidos: 0,
    itensVendidos: 0,
    ticketMedio: 0,
  });

  // KPIs de crediário (recebíveis): aberto/vencido são o saldo TOTAL atual;
  // recebido acompanha o período filtrado (pela data de pagamento).
  const [crediarioKpis, setCrediarioKpis] = useState({
    aberto: 0,
    qtdAberto: 0,
    vencido: 0,
    qtdVencido: 0,
    recebidoPeriodo: 0,
    qtdRecebidoPeriodo: 0,
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
  // (bucket 'produtos' agora é público — as thumbs são derivadas
  // síncronamente via thumbUrlFromFotoUrl no lugar de onde antes lia signedMap)

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
        if (parsed?.aba === 'vendas' || parsed?.aba === 'inventario') setAba(parsed.aba);
        if (parsed?.granularidade === 'dia' || parsed?.granularidade === 'semana' || parsed?.granularidade === 'mes') setGranularidade(parsed.granularidade);
        if (typeof parsed?.limiteAntigos === 'number') setLimiteAntigos(Math.min(100, Math.max(5, parsed.limiteAntigos)));
      }
    } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ dataInicio, dataFim, modoProdutos, limiteProdutos, aba, granularidade, limiteAntigos }));
    } catch {}
  }, [dataInicio, dataFim, modoProdutos, limiteProdutos, aba, granularidade, limiteAntigos]);

  useEffect(() => {
    let mounted = true;
    const init = async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) {
        if (mounted) router.replace('/login');
        return;
      }
      await Promise.all([carregar(), carregarInventario()]);
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

      // 3b) Crediário (recebíveis)
      const hojeStr = toISODateLocal(new Date());
      const [{ data: abertasData, error: errAbertas }, { data: recebidasData, error: errRecebidas }] = await Promise.all([
        supabase.from('crediario_parcelas').select('valor, data_vencimento').eq('pago', false),
        supabase
          .from('crediario_parcelas')
          .select('valor')
          .eq('pago', true)
          .gte('data_pagamento', toISODateLocal(s))
          .lte('data_pagamento', toISODateLocal(e)),
      ]);
      if (errAbertas) throw errAbertas;
      if (errRecebidas) throw errRecebidas;
      const abertas = ((abertasData as any) || []) as { valor: number; data_vencimento: string }[];
      const vencidas = abertas.filter((p) => p.data_vencimento < hojeStr);
      const recebidas = ((recebidasData as any) || []) as { valor: number }[];
      setCrediarioKpis({
        aberto: abertas.reduce((a, p) => a + (Number(p.valor) || 0), 0),
        qtdAberto: abertas.length,
        vencido: vencidas.reduce((a, p) => a + (Number(p.valor) || 0), 0),
        qtdVencido: vencidas.length,
        recebidoPeriodo: recebidas.reduce((a, p) => a + (Number(p.valor) || 0), 0),
        qtdRecebidoPeriodo: recebidas.length,
      });

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

  // ------------- INVENTÁRIO (snapshot atual) -------------
  // Carrega produtos + estoque aninhado em lotes de 1000, agrega KPIs,
  // breakdown por fornecedor e lista dos mais antigos ainda em estoque.
  async function carregarInventario() {
    setLoadingInv(true);
    try {
      type EstoqueLinha = { quantidade: number | null };
      type ProdLinha = {
        id: string;
        descricao: string;
        cor: string | null;
        fornecedor: string | null;
        foto_url: string | null;
        created_at: string;
        descontinuado: boolean | null;
        preco_compra: number | null;
        preco_venda: number | null;
        custo_frete: number | null;
        custo_embalagem: number | null;
        estoque: EstoqueLinha[] | null;
      };

      const PAGE = 1000;
      let todos: ProdLinha[] = [];
      for (let from = 0; ; from += PAGE) {
        const { data, error } = await supabase
          .from('produtos')
          .select('id, descricao, cor, fornecedor, foto_url, created_at, descontinuado, preco_compra, preco_venda, custo_frete, custo_embalagem, estoque(quantidade)')
          .order('created_at', { ascending: true })
          .range(from, from + PAGE - 1);
        if (error) throw error;
        const lote = ((data as unknown) as ProdLinha[] | null) ?? [];
        todos = todos.concat(lote);
        if (lote.length < PAGE) break;
      }

      const produtos: ProdutoInventario[] = todos.map((p) => {
        const qtd = (p.estoque ?? []).reduce((a, e) => a + (Number(e.quantidade) || 0), 0);
        const custo_unit = (Number(p.preco_compra) || 0) + (Number(p.custo_frete) || 0) + (Number(p.custo_embalagem) || 0);
        const preco_venda = Number(p.preco_venda) || 0;
        return {
          id: p.id,
          descricao: p.descricao || '(sem descrição)',
          cor: p.cor,
          fornecedor: (p.fornecedor || '').trim() || 'Sem fornecedor',
          foto_url: p.foto_url,
          created_at: p.created_at,
          descontinuado: !!p.descontinuado,
          custo_unit,
          preco_venda,
          qtd,
        };
      });

      // KPIs globais — considera apenas produtos NÃO descontinuados com estoque > 0
      let pecas = 0, skusComEstoque = 0;
      let valorCusto = 0, valorVenda = 0;
      let skusIncompletos = 0;
      let descontinuadosComEstoque = 0, pecasDescontinuadas = 0;
      const porForn = new Map<string, FornecedorInventario>();
      const descontinuadosLista: ProdutoInventario[] = [];

      for (const p of produtos) {
        if (p.qtd <= 0) continue;
        if (p.descontinuado) {
          descontinuadosComEstoque += 1;
          pecasDescontinuadas += p.qtd;
          descontinuadosLista.push(p);
          continue;
        }
        pecas += p.qtd;
        skusComEstoque += 1;
        const vCusto = p.custo_unit * p.qtd;
        const vVenda = p.preco_venda * p.qtd;
        valorCusto += vCusto;
        valorVenda += vVenda;
        if (p.custo_unit <= 0 || p.preco_venda <= 0) skusIncompletos += 1;

        const f = porForn.get(p.fornecedor) ?? { fornecedor: p.fornecedor, qtd: 0, valorCusto: 0, valorVenda: 0, lucro: 0, skus: 0 };
        f.qtd += p.qtd;
        f.valorCusto += vCusto;
        f.valorVenda += vVenda;
        f.lucro += Math.max(0, vVenda - vCusto);
        f.skus += 1;
        porForn.set(p.fornecedor, f);
      }

      const lucroPotencial = Math.max(0, valorVenda - valorCusto);
      setInvKpis({
        pecas, skusComEstoque, valorCusto, valorVenda, lucroPotencial,
        skusIncompletos, descontinuadosComEstoque, pecasDescontinuadas,
      });

      const porFornArr = Array.from(porForn.values()).sort((a, b) => b.valorCusto - a.valorCusto);
      setInvPorFornecedor(porFornArr);

      // Mais antigos ainda em estoque (top 10 — já vem ordenado ASC por created_at)
      // Guarda a lista completa (já ordenada por created_at ASC); o slider
      // na UI decide quantos exibir, até o teto de 100.
      const antigos = produtos
        .filter((p) => p.qtd > 0 && !p.descontinuado)
        .slice(0, 100);
      setInvMaisAntigos(antigos);
      // Descontinuados ordenados por maior valor preso (custo total) primeiro
      descontinuadosLista.sort((a, b) => (b.custo_unit * b.qtd) - (a.custo_unit * a.qtd));
      setInvDescontinuados(descontinuadosLista);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('inventário:', msg);
      setInvKpis({ pecas: 0, skusComEstoque: 0, valorCusto: 0, valorVenda: 0, lucroPotencial: 0, skusIncompletos: 0, descontinuadosComEstoque: 0, pecasDescontinuadas: 0 });
      setInvPorFornecedor([]);
      setInvMaisAntigos([]);
      setInvDescontinuados([]);
    } finally {
      setLoadingInv(false);
    }
  }

  // Nota: com bucket 'produtos' público, não precisamos assinar URLs.
  // As thumbs são derivadas síncronamente de foto_url via thumbUrlFromFotoUrl().

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

  // --- Granularidade: agrega a série diária em semanal (segunda a domingo) ou mensal ---
  const seriesAgrupada = useMemo<Array<{ day: string; total: number; label: string }>>(() => {
    if (series.length === 0) return [];
    const MESES_ABR = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez'];
    const fmtDiaMes = (iso: string) => {
      const [, m, d] = iso.split('-');
      return `${d}/${m}`;
    };
    if (granularidade === 'dia') {
      return series.map((p) => ({ day: p.day, total: p.total, label: fmtDiaMes(p.day) }));
    }
    // Para semanal: chave = segunda-feira da semana (ISO-like, dow 1=seg)
    const mondayOf = (iso: string): string => {
      const [y, m, d] = iso.split('-').map(Number);
      const dt = new Date(y, m - 1, d);
      const dow = dt.getDay(); // 0=dom, 1=seg, ..., 6=sáb
      const diff = dow === 0 ? -6 : 1 - dow;
      dt.setDate(dt.getDate() + diff);
      return toISODateLocal(dt);
    };
    const mapTot = new Map<string, number>();
    for (const p of series) {
      const key = granularidade === 'semana' ? mondayOf(p.day) : p.day.slice(0, 7); // YYYY-MM
      mapTot.set(key, (mapTot.get(key) ?? 0) + p.total);
    }
    const sorted = Array.from(mapTot.entries()).sort((a, b) => a[0].localeCompare(b[0]));
    return sorted.map(([k, total]) => {
      let label: string;
      if (granularidade === 'semana') {
        label = fmtDiaMes(k);
      } else {
        const [y, m] = k.split('-');
        label = `${MESES_ABR[parseInt(m, 10) - 1]}/${y.slice(2)}`;
      }
      return { day: k, total, label };
    });
  }, [series, granularidade]);

  // --- Chart tooltip (fix: nunca sair do container) ---
  const maxBar = useMemo(() => {
    let m = 0;
    for (const p of seriesAgrupada) m = Math.max(m, p.total);
    return m || 1;
  }, [seriesAgrupada]);

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
              {aba === 'vendas' ? 'Vendas, lucros e crediário' : 'Estoque parado, idade e descontinuados'}
            </p>
          </div>
        </div>

        {/* ABAS */}
        <div className="flex gap-2 bg-slate-950 border border-slate-800 rounded-xl p-1">
          <button
            onClick={() => setAba('vendas')}
            className={`flex-1 py-2.5 rounded-lg text-[11px] font-black uppercase tracking-widest transition active:scale-95 ${aba === 'vendas' ? 'bg-pink-600 text-white shadow-lg' : 'text-slate-400 hover:text-white'}`}
          >
            📈 Vendas
          </button>
          <button
            onClick={() => setAba('inventario')}
            className={`flex-1 py-2.5 rounded-lg text-[11px] font-black uppercase tracking-widest transition active:scale-95 flex items-center justify-center gap-1 ${aba === 'inventario' ? 'bg-amber-500 text-slate-950 shadow-lg' : 'text-slate-400 hover:text-white'}`}
          >
            📦 Inventário
            {invKpis.descontinuadosComEstoque > 0 && (
              <span className={`${aba === 'inventario' ? 'bg-slate-950 text-red-400' : 'bg-red-950/60 text-red-300 border border-red-900/50'} rounded-full px-1.5 text-[9px] font-black`}>
                {invKpis.descontinuadosComEstoque}
              </span>
            )}
          </button>
        </div>

        {aba === 'vendas' && (
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
              onClick={() => { carregar(); carregarInventario(); }}
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
        )}

        {errorMsg && <div className="text-xs font-bold text-red-400">{errorMsg}</div>}
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">
        {aba === 'vendas' && (
        <>
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

        {/* Crediário (recebíveis) */}
        <div className="bg-slate-900 p-5 rounded-2xl border border-slate-800 shadow-lg space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-[10px] font-black text-violet-400 uppercase tracking-widest">Crediário</span>
            <Link
              href={`/recebiveis${dashQS}`}
              className="text-[10px] font-black uppercase tracking-widest text-slate-300 hover:text-white bg-slate-950 border border-slate-800 hover:border-violet-500 px-3 py-1.5 rounded-xl active:scale-95 transition-colors"
            >
              Gerir recebíveis →
            </Link>
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex flex-col justify-between">
              <span className="text-[9px] font-black text-slate-500 uppercase tracking-widest">Em aberto</span>
              <p className="text-sm md:text-lg font-black text-white truncate">{loading ? '—' : formatBRL(crediarioKpis.aberto)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">{loading ? '' : `${crediarioKpis.qtdAberto} parcela(s)`}</span>
            </div>
            <div className={`bg-slate-950 p-3 rounded-xl border flex flex-col justify-between ${crediarioKpis.qtdVencido > 0 ? 'border-red-900/60' : 'border-slate-800'}`}>
              <span className="text-[9px] font-black text-red-400 uppercase tracking-widest">Vencido</span>
              <p className="text-sm md:text-lg font-black text-white truncate">{loading ? '—' : formatBRL(crediarioKpis.vencido)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">{loading ? '' : `${crediarioKpis.qtdVencido} parcela(s)`}</span>
            </div>
            <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex flex-col justify-between">
              <span className="text-[9px] font-black text-emerald-400 uppercase tracking-widest">Recebido no período</span>
              <p className="text-sm md:text-lg font-black text-white truncate">{loading ? '—' : formatBRL(crediarioKpis.recebidoPeriodo)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">{loading ? '' : `${crediarioKpis.qtdRecebidoPeriodo} parcela(s)`}</span>
            </div>
          </div>
          <p className="text-[9px] font-bold text-slate-600 uppercase tracking-widest">
            Em aberto e vencido: saldo total atual • Recebido: pela data de pagamento dentro do período filtrado
          </p>
        </div>
        </>
        )}

        {aba === 'inventario' && (
        <>
        {/* INVENTÁRIO — snapshot atual (não depende do período) */}
        <section className="bg-slate-900 rounded-2xl border border-slate-800 shadow-lg overflow-hidden">
          <div className="p-5 border-b border-slate-800 flex items-end justify-between gap-3">
            <div>
              <span className="text-[10px] font-black text-amber-400 uppercase tracking-widest">Inventário</span>
              <p className="font-black italic text-lg uppercase tracking-tighter">
                O que está <span className="text-amber-400">parado</span>
              </p>
            </div>
            <span className="text-[9px] font-bold text-slate-600 uppercase tracking-widest text-right leading-tight">Snapshot atual<br/>independe do período</span>
          </div>

          {/* 4 KPIs */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 p-5">
            <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex flex-col justify-between gap-1">
              <span className="text-[9px] font-black text-slate-500 uppercase tracking-widest">Peças em estoque</span>
              <p className="text-base md:text-xl font-black text-white truncate">{loadingInv ? '—' : invKpis.pecas.toLocaleString('pt-BR')}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">{loadingInv ? '' : `${invKpis.skusComEstoque} SKUs`}</span>
            </div>
            <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex flex-col justify-between gap-1">
              <span className="text-[9px] font-black text-slate-500 uppercase tracking-widest">Investido (custo)</span>
              <p className="text-sm md:text-lg font-black text-white truncate">{loadingInv ? '—' : formatBRL(invKpis.valorCusto)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">dinheiro preso</span>
            </div>
            <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex flex-col justify-between gap-1">
              <span className="text-[9px] font-black text-slate-500 uppercase tracking-widest">A faturar</span>
              <p className="text-sm md:text-lg font-black text-white truncate">{loadingInv ? '—' : formatBRL(invKpis.valorVenda)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">se vender tudo</span>
            </div>
            <div className="bg-slate-950 p-3 rounded-xl border border-emerald-900/50 flex flex-col justify-between gap-1">
              <span className="text-[9px] font-black text-emerald-400 uppercase tracking-widest">Lucro potencial</span>
              <p className="text-sm md:text-lg font-black text-emerald-400 truncate">{loadingInv ? '—' : formatBRL(invKpis.lucroPotencial)}</p>
              <span className="text-[9px] font-bold text-slate-600 uppercase">a realizar</span>
            </div>
          </div>

          {/* Alerta de cadastro incompleto (badge inline) */}
          {!loadingInv && invKpis.skusIncompletos > 0 && (
            <div className="px-5 pb-3">
              <span className="text-[9px] font-black uppercase tracking-widest px-2 py-1 rounded-lg bg-amber-950/40 text-amber-300 border border-amber-900/50">
                ⚠ {invKpis.skusIncompletos} SKU(s) sem preço/custo cadastrado — não entram no cálculo
              </span>
            </div>
          )}

          {/* CARTÃO COLAPSÁVEL: Descontinuados com estoque */}
          {!loadingInv && (() => {
            const temProblema = invKpis.descontinuadosComEstoque > 0;
            const borda = temProblema ? 'border-red-900/60' : 'border-emerald-900/50';
            const bgHeader = temProblema ? 'bg-red-950/30 hover:bg-red-950/50' : 'bg-emerald-950/20 hover:bg-emerald-950/30';
            const corTexto = temProblema ? 'text-red-300' : 'text-emerald-300';
            const corNum = temProblema ? 'text-red-400' : 'text-emerald-400';
            const icone = temProblema ? '⚠' : '✓';
            return (
              <div className="px-5 pb-5">
                <div className={`border ${borda} rounded-xl overflow-hidden`}>
                  <button
                    type="button"
                    onClick={() => temProblema && setDescontinuadosAberto((v) => !v)}
                    disabled={!temProblema}
                    className={`w-full ${bgHeader} px-4 py-3 flex items-center gap-3 text-left transition active:scale-[0.995] ${!temProblema ? 'cursor-default' : ''}`}
                  >
                    <span className={`text-base ${corNum}`}>{icone}</span>
                    <div className="flex-1 min-w-0">
                      <p className={`text-[11px] font-black uppercase tracking-widest ${corTexto}`}>
                        Descontinuados com estoque
                      </p>
                      <p className="text-[10px] font-bold text-slate-400 mt-0.5">
                        {temProblema
                          ? `${invKpis.descontinuadosComEstoque} SKU(s) · ${invKpis.pecasDescontinuadas} peça(s) ainda em estoque`
                          : 'Tudo em ordem — nenhum item descontinuado com estoque'}
                      </p>
                    </div>
                    {temProblema && (
                      <span className={`text-xs font-black ${corTexto}`}>{descontinuadosAberto ? '▲' : '▼'}</span>
                    )}
                  </button>
                  {temProblema && descontinuadosAberto && (
                    <div className="divide-y divide-slate-800/60 bg-slate-950/40">
                      {invDescontinuados.map((p) => {
                        const thumbUrl = thumbUrlFromFotoUrl(p.foto_url || '');
                        const thumbPath = extractPath(thumbUrl);
                        const custoTotal = p.custo_unit * p.qtd;
                        return (
                          <Link
                            key={p.id}
                            href={itemHrefFromRelatorios(p.id, dashQS)}
                            className="flex items-center gap-3 px-4 py-2.5 hover:bg-red-950/20 active:scale-[0.995] transition"
                          >
                            <div className="shrink-0 w-10 h-10 rounded-lg overflow-hidden bg-slate-900 border border-slate-800 relative">
                              {thumbPath ? (
                                <Image src={supabase.storage.from('produtos').getPublicUrl(thumbPath).data.publicUrl} alt="" fill sizes="40px" className="object-cover" unoptimized />
                              ) : (
                                <div className="w-full h-full flex items-center justify-center text-slate-700 text-xs">📦</div>
                              )}
                            </div>
                            <div className="flex-1 min-w-0">
                              <p className="text-xs font-black text-white truncate">{p.descricao}</p>
                              <p className="text-[10px] font-bold text-slate-500 uppercase truncate mt-0.5">
                                {p.cor ? `${p.cor} · ` : ''}{p.fornecedor}
                              </p>
                            </div>
                            <div className="text-right shrink-0">
                              <p className="text-xs font-black text-white leading-tight">{p.qtd} un</p>
                              {custoTotal > 0 && <p className="text-[9px] font-bold text-slate-500 uppercase leading-tight mt-0.5">preso {formatBRL(custoTotal)}</p>}
                            </div>
                            <span className="text-slate-600 text-sm shrink-0">›</span>
                          </Link>
                        );
                      })}
                      <div className="px-4 py-2 bg-slate-950/60 text-[9px] font-bold uppercase tracking-widest text-slate-500 leading-relaxed">
                        Toque num item para abrir e revisar: reativar o cadastro, zerar o estoque ou colocar em promoção.
                      </div>
                    </div>
                  )}
                </div>
              </div>
            );
          })()}

          {/* POR FORNECEDOR */}
          <div className="px-5 pb-5">
            <h3 className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-2">Dinheiro preso por fornecedor</h3>
            {loadingInv ? (
              <div className="py-6 opacity-50 animate-pulse text-xs font-bold uppercase">Carregando...</div>
            ) : invPorFornecedor.length === 0 ? (
              <div className="py-6 text-slate-500 text-xs font-bold uppercase text-center">Sem estoque cadastrado</div>
            ) : (
              <div className="bg-slate-950 border border-slate-800 rounded-xl divide-y divide-slate-800/60">
                {invPorFornecedor.slice(0, 5).map((f) => {
                  const pct = invKpis.valorCusto > 0 ? (f.valorCusto / invKpis.valorCusto) * 100 : 0;
                  return (
                    <div key={f.fornecedor} className="px-3 py-2.5">
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-xs font-black text-white truncate flex-1 min-w-0">{f.fornecedor}</span>
                        <span className="text-xs font-black text-white shrink-0">{formatBRL(f.valorCusto)}</span>
                      </div>
                      <div className="flex items-center justify-between gap-2 text-[10px] font-bold text-slate-500 uppercase mt-0.5">
                        <span>{f.skus} SKUs · {f.qtd} peças</span>
                        <span className="text-amber-400">lucro {formatBRL(f.lucro)}</span>
                      </div>
                      <div className="mt-1.5 h-1 bg-slate-800 rounded-full overflow-hidden">
                        <div className="h-full bg-gradient-to-r from-amber-500 to-pink-500" style={{ width: `${Math.min(100, pct)}%` }} />
                      </div>
                    </div>
                  );
                })}
                {invPorFornecedor.length > 5 && (
                  <div className="px-3 py-2 text-[9px] font-bold text-slate-600 uppercase tracking-widest">
                    + {invPorFornecedor.length - 5} fornecedor(es) com estoque menor
                  </div>
                )}
              </div>
            )}
          </div>

          {/* MAIS ANTIGOS AINDA EM ESTOQUE */}
          <div className="px-5 pb-5">
            <div className="flex items-end justify-between gap-3 mb-2 flex-wrap">
              <h3 className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Candidatos a promoção · mais antigos em estoque</h3>
              {!loadingInv && invMaisAntigos.length > 0 && (
                <span className="text-[10px] font-black text-amber-400 uppercase tracking-widest shrink-0">
                  mostrando {Math.min(limiteAntigos, invMaisAntigos.length)} de {invMaisAntigos.length}
                </span>
              )}
            </div>
            {!loadingInv && invMaisAntigos.length > 5 && (
              <div className="bg-slate-950/60 border border-slate-800 rounded-xl px-4 py-3 mb-2 flex items-center gap-3">
                <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest shrink-0">Quantidade</span>
                <input
                  type="range"
                  min={5}
                  max={Math.min(100, Math.max(5, invMaisAntigos.length))}
                  step={5}
                  value={Math.min(limiteAntigos, Math.max(5, invMaisAntigos.length))}
                  onChange={(e) => setLimiteAntigos(parseInt(e.target.value, 10))}
                  className="flex-1 accent-amber-500 cursor-pointer"
                  aria-label="Quantidade de itens no ranking"
                />
                <span className="text-sm font-black text-amber-400 w-10 text-right shrink-0">{Math.min(limiteAntigos, invMaisAntigos.length)}</span>
              </div>
            )}
            {loadingInv ? (
              <div className="py-6 opacity-50 animate-pulse text-xs font-bold uppercase">Carregando...</div>
            ) : invMaisAntigos.length === 0 ? (
              <div className="py-6 text-slate-500 text-xs font-bold uppercase text-center">Sem itens</div>
            ) : (
              <div className="bg-slate-950 border border-slate-800 rounded-xl divide-y divide-slate-800/60">
                {invMaisAntigos.slice(0, limiteAntigos).map((p) => {
                  const dias = Math.floor((Date.now() - new Date(p.created_at).getTime()) / (1000 * 60 * 60 * 24));
                  const thumbUrl = thumbUrlFromFotoUrl(p.foto_url || '');
                  const thumbPath = extractPath(thumbUrl);
                  const custoTotal = p.custo_unit * p.qtd;
                  // Badge de idade sempre visível, com faixa colorida por tempo
                  const idadeTom =
                    dias >= 180 ? 'bg-red-950/50 text-red-300 border-red-900/60' :
                    dias >= 90  ? 'bg-amber-950/50 text-amber-300 border-amber-900/60' :
                                  'bg-slate-800 text-slate-300 border-slate-700';
                  return (
                    <Link
                      key={p.id}
                      href={itemHrefFromRelatorios(p.id, dashQS)}
                      className="flex items-center gap-3 px-3 py-2.5 hover:bg-slate-900/60 active:scale-[0.995] transition"
                    >
                      <div className="shrink-0 w-10 h-10 rounded-lg overflow-hidden bg-slate-900 border border-slate-800 relative">
                        {thumbPath ? (
                          <Image src={supabase.storage.from('produtos').getPublicUrl(thumbPath).data.publicUrl} alt="" fill sizes="40px" className="object-cover" unoptimized />
                        ) : (
                          <div className="w-full h-full flex items-center justify-center text-slate-700 text-xs">📦</div>
                        )}
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-1.5 min-w-0">
                          <span className="text-xs font-black text-white truncate flex-1 min-w-0">{p.descricao}</span>
                          <span className={`text-[9px] font-black uppercase px-1.5 py-0.5 rounded border shrink-0 ${idadeTom}`} title={`há ${dias} dias no sistema`}>
                            {dias}d
                          </span>
                        </div>
                        <p className="text-[10px] font-bold text-slate-500 uppercase truncate mt-0.5">
                          {p.cor ? `${p.cor} · ` : ''}{p.fornecedor}
                        </p>
                      </div>
                      <div className="text-right shrink-0">
                        <p className="text-xs font-black text-white leading-tight">{p.qtd} un</p>
                        <p className="text-[9px] font-bold text-slate-500 uppercase leading-tight mt-0.5">preso {formatBRL(custoTotal)}</p>
                        {p.preco_venda > 0 && <p className="text-[9px] font-bold text-amber-400 uppercase leading-tight">venda {formatBRL(p.preco_venda)}</p>}
                      </div>
                    </Link>
                  );
                })}
              </div>
            )}
            <p className="text-[9px] font-bold text-slate-600 uppercase tracking-widest mt-2">
              Toque num item para abrir e editar. Idade = tempo desde o cadastro do SKU, não desde a última reposição.
            </p>
          </div>
        </section>
        </>
        )}

        {aba === 'vendas' && (
        <>
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

        {/* Gráfico de evolução — toggle dia/semana/mês */}
        <div className="bg-slate-900 p-4 md:p-6 rounded-2xl border border-slate-800 shadow-lg overflow-hidden">
          <div className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-3">
            <div>
              <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">
                {granularidade === 'dia' ? 'Vendas por dia' : granularidade === 'semana' ? 'Vendas por semana' : 'Vendas por mês'}
              </span>
              <p className="font-black italic text-lg uppercase tracking-tighter">
                <span className="text-pink-600">Evolução</span>
              </p>
            </div>
            <div className="flex items-center gap-2">
              <div className="flex gap-1 bg-slate-950 border border-slate-800 rounded-lg p-1">
                {(['dia', 'semana', 'mes'] as const).map((g) => (
                  <button
                    key={g}
                    onClick={() => { hideTip(); setGranularidade(g); }}
                    className={`px-3 py-1.5 rounded-md text-[10px] font-black uppercase tracking-widest transition active:scale-95 ${
                      granularidade === g ? 'bg-pink-600 text-white shadow' : 'text-slate-400 hover:text-white'
                    }`}
                  >
                    {g === 'dia' ? 'Dia' : g === 'semana' ? 'Semana' : 'Mês'}
                  </button>
                ))}
              </div>
            </div>
          </div>

          {loading ? (
            <div className="text-center py-10 opacity-50 animate-pulse">
              <p className="text-xs font-bold uppercase">Carregando gráfico...</p>
            </div>
          ) : seriesAgrupada.length === 0 ? (
            <div className="text-center py-12 opacity-30">
              <span className="text-4xl grayscale">📈</span>
              <p className="mt-2 font-bold">Sem dados no período.</p>
            </div>
          ) : (
            <div className="mt-5 overflow-x-auto">
              <div ref={chartWrapRef} className={`relative ${seriesAgrupada.length > 20 ? 'min-w-[720px]' : ''}`}>
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

                <div className="h-56 flex items-end gap-2">
                  {seriesAgrupada.map((p) => {
                    const h = Math.max(2, Math.round((p.total / maxBar) * 150));
                    const tipLabel =
                      granularidade === 'semana' ? `Semana de ${p.label}` :
                      granularidade === 'mes' ? p.label :
                      p.label;
                    const valorCompacto = formatCompactBR(p.total);
                    return (
                      <div key={p.day} className="flex-1 min-w-[24px] flex flex-col items-center gap-1">
                        <button
                          type="button"
                          className="w-full flex flex-col items-center justify-end focus:outline-none"
                          onMouseEnter={(e) => showTipFor(tipLabel, p.total, e.currentTarget)}
                          onMouseMove={(e) => showTipFor(tipLabel, p.total, e.currentTarget)}
                          onMouseLeave={hideTip}
                          onClick={(e) => {
                            if (tip?.day === tipLabel) hideTip();
                            else showTipFor(tipLabel, p.total, e.currentTarget);
                          }}
                          aria-label={`${tipLabel}: ${formatBRL(p.total)}`}
                        >
                          {/* Rótulo com valor compacto acima da barra (sumido para dia zerado) */}
                          <div className="text-[9px] font-black tracking-widest text-slate-300 h-3.5 leading-none mb-1">
                            {valorCompacto}
                          </div>
                          <div className="w-4 rounded-md bg-pink-500/90" style={{ height: h }} />
                        </button>
                        <div className="text-[9px] text-slate-500 font-black tracking-widest uppercase">
                          {p.label}
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
                const thumb = thumbUrlFromFotoUrl(p.foto_url);
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
                              const thumb = thumbUrlFromFotoUrl(p.foto_url);
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
        </>
        )}
      </main>

      {/* NAV (Relatórios ativo) */}
      <div className="fixed left-6 right-6 z-[60]" style={{ bottom: `calc(env(safe-area-inset-bottom, 0px) + 10px)` }}>
        <nav className="bg-slate-900/95 backdrop-blur-2xl border border-white/5 rounded-[2.5rem] h-20 px-4 flex items-center justify-around shadow-2xl">
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

          <Link href={`/recebiveis${dashQS}`} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2">
              <span className="text-xl">💰</span>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Recebíveis</span>
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