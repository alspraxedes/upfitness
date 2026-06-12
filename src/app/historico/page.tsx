'use client';

import { useEffect, useState, useRef, useMemo, Suspense } from 'react';
import Link from 'next/link';
import { supabase } from '../../lib/supabase';
import { useSearchParams } from 'next/navigation';

// --- TIPOS ---
type ItemVenda = {
  id: string;
  descricao_completa: string;
  quantidade: number;
  preco_unitario: number;
  subtotal: number;
  estoque_id: string;
  estoque?: {
    produto?: {
      preco_compra: number;
      custo_frete: number;
      custo_embalagem: number;
    };
  };
};

type ParcelaCred = {
  id: string;
  numero: number;
  valor: number;
  data_vencimento: string; // YYYY-MM-DD
  pago: boolean;
  data_pagamento: string | null;
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
  crediario_frequencia: string | null;
  nome_cliente: string | null;
  itens_venda: ItemVenda[];
  crediario_parcelas: ParcelaCred[];
};

// --- CREDIÁRIO (helpers duplicados da tela de venda; unificar na Fase 3) ---
type FrequenciaCrediario = 'semanal' | 'quinzenal' | 'mensal';

type ParcelaConv = {
  numero: number;
  valor: number;
  valorStr: string; // valor como digitado (aceita vírgula)
  data_vencimento: string;
  pago: boolean;
};

// Converte texto digitado (vírgula ou ponto) em número
const parseValorDigitado = (s: string) => {
  const v = parseFloat(s.replace(',', '.'));
  return isNaN(v) ? 0 : v;
};

const valorParaStr = (v: number) => v.toFixed(2).replace('.', ',');

const FREQ_LABEL: Record<FrequenciaCrediario, string> = {
  semanal: 'Semanal',
  quinzenal: 'Quinzenal',
  mensal: 'Mensal',
};

function hojeISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Soma i ciclos da frequência à data base (ISO local). Mensal com clamp
// de fim de mês: 1ª parcela dia 31 → fevereiro cai no 28/29.
function addCiclos(baseISO: string, freq: FrequenciaCrediario, i: number): string {
  const [y, m, d] = baseISO.split('-').map(Number);
  if (freq === 'mensal') {
    const totalM = (m - 1) + i;
    const ano = y + Math.floor(totalM / 12);
    const mes = (totalM % 12) + 1;
    const ultimoDia = new Date(ano, mes, 0).getDate();
    return `${ano}-${String(mes).padStart(2, '0')}-${String(Math.min(d, ultimoDia)).padStart(2, '0')}`;
  }
  const dt = new Date(y, m - 1, d + (freq === 'semanal' ? 7 : 14) * i);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}

// Divide o valor em n parcelas iguais (centavos inteiros);
// a última absorve a diferença de arredondamento.
function gerarParcelasConv(valorFinal: number, n: number, primeiraISO: string, freq: FrequenciaCrediario): ParcelaConv[] {
  const totalCents = Math.round(valorFinal * 100);
  if (n < 1 || totalCents <= 0 || !primeiraISO) return [];
  const base = Math.floor(totalCents / n);
  const out: ParcelaConv[] = [];
  for (let i = 0; i < n; i++) {
    const cents = i === n - 1 ? totalCents - base * (n - 1) : base;
    out.push({ numero: i + 1, valor: cents / 100, valorStr: valorParaStr(cents / 100), data_vencimento: addCiclos(primeiraISO, freq, i), pago: false });
  }
  return out;
}

const formatDataCurta = (iso: string) => {
  const [y, m, d] = iso.split('-');
  return `${d}/${m}/${y.slice(2)}`;
};

// --- UTILITÁRIOS ---
const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

const formatData = (dataIso: string) => {
  const d = new Date(dataIso);
  return d.toLocaleDateString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
};

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

export default function HistoricoPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950 text-slate-100" />}>
      <HistoricoPageInner />
    </Suspense>
  );
}

function HistoricoPageInner() {
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getQS(searchParams), [searchParams]);

  const [vendas, setVendas] = useState<Venda[]>([]);
  const [loading, setLoading] = useState(true);

  // Filtros
  const [dataInicio, setDataInicio] = useState('');
  const [dataFim, setDataFim] = useState('');
  const STORAGE_KEY = 'upfitness_historico_filtros_v1';

  // Visualização
  const [expandidoId, setExpandidoId] = useState<string | null>(null);
  const [vendaRecibo, setVendaRecibo] = useState<Venda | null>(null);

  // Exclusão/Cancelamento
  const [modalConfirmacao, setModalConfirmacao] = useState<{ tipo: 'apagar' | 'cancelar'; venda: Venda } | null>(null);
  const [processandoAcao, setProcessandoAcao] = useState(false);

  // Conversão para crediário
  const [modalConversao, setModalConversao] = useState<Venda | null>(null);
  const [conv, setConv] = useState({
    frequencia: 'quinzenal' as FrequenciaCrediario,
    numParcelas: 4,
    primeiraData: hojeISO(),
    parcelas: [] as ParcelaConv[],
  });
  const [convertendo, setConvertendo] = useState(false);

  function abrirConversao(venda: Venda) {
    if (!venda.nome_cliente?.trim()) {
      alert('Adicione o nome da cliente antes de converter para crediário (use o ✏️ Editar no bloco Cliente). Sem cliente não há como cobrar os recebíveis.');
      return;
    }
    setConv({
      frequencia: 'quinzenal',
      numParcelas: 4,
      primeiraData: hojeISO(),
      parcelas: gerarParcelasConv(venda.valor_liquido || 0, 4, hojeISO(), 'quinzenal'),
    });
    setModalConversao(venda);
  }

  // Regera as parcelas da conversão quando os parâmetros mudam.
  // Edições manuais (valor/paga) persistem até o próximo ajuste de parâmetro.
  useEffect(() => {
    if (!modalConversao) return;
    setConv((prev) => ({
      ...prev,
      parcelas: gerarParcelasConv(modalConversao.valor_liquido || 0, prev.numParcelas, prev.primeiraData, prev.frequencia),
    }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [modalConversao, conv.numParcelas, conv.primeiraData, conv.frequencia]);

  // Validação em centavos inteiros
  const convTotalCents = modalConversao ? Math.round((modalConversao.valor_liquido || 0) * 100) : 0;
  const convSomaCents = conv.parcelas.reduce((a, p) => a + Math.round(p.valor * 100), 0);
  const convSomaOk = conv.parcelas.length > 0 && convSomaCents === convTotalCents;
  const convValoresOk = conv.parcelas.length > 0 && conv.parcelas.every((p) => Math.round(p.valor * 100) > 0);

  // Joga o que falta (total − soma das demais) na última parcela
  function restoNaUltimaConv() {
    setConv((prev) => {
      if (prev.parcelas.length === 0) return prev;
      const somaOutras = prev.parcelas.slice(0, -1).reduce((a, p) => a + Math.round(p.valor * 100), 0);
      const resto = Math.max(0, convTotalCents - somaOutras);
      return {
        ...prev,
        parcelas: prev.parcelas.map((p, i) =>
          i === prev.parcelas.length - 1 ? { ...p, valor: resto / 100, valorStr: valorParaStr(resto / 100) } : p
        ),
      };
    });
  }

  async function confirmarConversao() {
    if (!modalConversao) return;
    if (!convValoresOk) { alert('Todas as parcelas precisam ter valor maior que zero.'); return; }
    if (!convSomaOk) { alert(`A soma das parcelas (${formatBRL(convSomaCents / 100)}) precisa ser igual ao valor da venda (${formatBRL(convTotalCents / 100)}).`); return; }
    setConvertendo(true);
    try {
      const payload = conv.parcelas.map((p) => ({
        numero: p.numero,
        valor: Math.round(p.valor * 100) / 100,
        data_vencimento: p.data_vencimento,
        pago: p.pago,
      }));
      const { error } = await supabase.rpc('converter_venda_crediario', {
        p_venda_id: modalConversao.id,
        p_frequencia: conv.frequencia,
        p_parcelas: payload,
      });
      if (error) throw new Error(error.message);
      setModalConversao(null);
      await fetchVendas();
    } catch (err: any) {
      alert('Erro ao converter: ' + (err?.message || String(err)));
    } finally {
      setConvertendo(false);
    }
  }

  // Pré-filtra a tela de Recebíveis pelo cliente (mesma chave de localStorage)
  function preFiltrarRecebiveis(nomeCliente: string | null) {
    try {
      localStorage.setItem('upfitness_recebiveis_filtros_v1', JSON.stringify({
        filtroStatus: 'pendentes',
        agrupamento: 'data',
        filtroCliente: nomeCliente?.trim() ?? '',
      }));
    } catch { /* ignore */ }
  }

  // Edição inline de cliente
  const [editandoClienteId, setEditandoClienteId] = useState<string | null>(null);
  const [editandoClienteValor, setEditandoClienteValor] = useState('');
  const [salvandoCliente, setSalvandoCliente] = useState(false);

  // Autocomplete
  const [clientesExistentes, setClientesExistentes] = useState<string[]>([]);
  const [mostrarSugestoes, setMostrarSugestoes] = useState(false);

  const printRef = useRef<HTMLDivElement>(null);

  // Carrega filtros do localStorage + busca clientes ao montar
  useEffect(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (typeof parsed?.dataInicio === 'string') setDataInicio(parsed.dataInicio);
        if (typeof parsed?.dataFim === 'string') setDataFim(parsed.dataFim);
      }
    } catch { /* ignore */ }
    fetchClientes();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Salva filtros sempre que mudarem
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ dataInicio, dataFim }));
    } catch { /* ignore */ }
  }, [dataInicio, dataFim]);

  // Busca vendas com debounce leve sempre que filtros mudarem
  useEffect(() => {
    const t = setTimeout(() => { fetchVendas(); }, 150);
    return () => clearTimeout(t);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dataInicio, dataFim]);

  // --- FETCH VENDAS ---
  async function fetchVendas() {
    setLoading(true);
    let query = supabase
      .from('vendas')
      .select(`
        *,
        itens_venda (
          *,
          estoque (
            produto:produtos ( preco_compra, custo_frete, custo_embalagem )
          )
        ),
        crediario_parcelas ( id, numero, valor, data_vencimento, pago, data_pagamento )
      `)
      .order('created_at', { ascending: false });

    if (dataInicio) query = query.gte('created_at', `${dataInicio}T00:00:00`);
    if (dataFim) query = query.lte('created_at', `${dataFim}T23:59:59`);
    else if (!dataInicio) query = query.limit(50);

    const { data, error } = await query;
    if (error) {
      console.error(error);
      alert('Erro ao buscar vendas: ' + error.message);
      setVendas([]);
    } else {
      setVendas((data as any) || []);
    }
    setLoading(false);
  }

  // --- FETCH CLIENTES (para autocomplete) ---
  async function fetchClientes() {
    const { data } = await supabase
      .from('vendas')
      .select('nome_cliente')
      .not('nome_cliente', 'is', null)
      .neq('nome_cliente', '');

    const nomesUnicos = Array.from(
      new Set(
        (data ?? [])
          .map((v: any) => v.nome_cliente as string)
          .filter(Boolean)
          .map((n) => n.trim())
      )
    ).sort((a, b) => a.localeCompare(b, 'pt-BR'));

    setClientesExistentes(nomesUnicos);
  }

  // --- AUTOCOMPLETE FILTRADO ---
  const sugestoesFiltradas = useMemo(() => {
    const q = editandoClienteValor.trim().toLowerCase();
    if (!q) return clientesExistentes;
    return clientesExistentes.filter((n) => n.toLowerCase().includes(q));
  }, [editandoClienteValor, clientesExistentes]);

  // --- EDIÇÃO INLINE DE CLIENTE ---
  function iniciarEdicaoCliente(venda: Venda) {
    setEditandoClienteId(venda.id);
    setEditandoClienteValor(venda.nome_cliente ?? '');
    setMostrarSugestoes(false);
  }

  function cancelarEdicaoCliente() {
    setEditandoClienteId(null);
    setEditandoClienteValor('');
    setMostrarSugestoes(false);
  }

  async function salvarNomeCliente(vendaId: string) {
    setSalvandoCliente(true);
    const novoNome = editandoClienteValor.trim() || null;
    try {
      const { error } = await supabase
        .from('vendas')
        .update({ nome_cliente: novoNome })
        .eq('id', vendaId);

      if (error) throw error;

      // Atualiza localmente sem refetch completo
      setVendas((prev) =>
        prev.map((v) => v.id === vendaId ? { ...v, nome_cliente: novoNome } : v)
      );

      // Se for um nome novo, adiciona à lista de autocomplete
      if (novoNome && !clientesExistentes.some((n) => n.toLowerCase() === novoNome.toLowerCase())) {
        setClientesExistentes((prev) =>
          [...prev, novoNome].sort((a, b) => a.localeCompare(b, 'pt-BR'))
        );
      }

      setEditandoClienteId(null);
      setEditandoClienteValor('');
      setMostrarSugestoes(false);
    } catch (err: any) {
      alert('Erro ao salvar: ' + (err?.message || String(err)));
    } finally {
      setSalvandoCliente(false);
    }
  }

  // --- MÉTRICAS ---
  const metricas = useMemo(() => {
    let faturamento = 0;
    let custoTotal = 0;
    vendas.forEach((venda) => {
      faturamento += venda.valor_liquido || 0;
      venda.itens_venda.forEach((item) => {
        const prod = item.estoque?.produto;
        if (prod) {
          const custoUnitario = (prod.preco_compra || 0) + (prod.custo_frete || 0) + (prod.custo_embalagem || 0);
          custoTotal += custoUnitario * item.quantidade;
        }
      });
    });
    const lucro = faturamento - custoTotal;
    const margem = custoTotal > 0 ? (lucro / custoTotal) * 100 : 0;
    return { faturamento, custoTotal, lucro, margem };
  }, [vendas]);

  // --- CANCELAMENTO / EXCLUSÃO ---
  // Usa o RPC cancelar_venda (transacional no banco): estorna o estoque
  // e apaga a venda numa única transação — ou tudo acontece, ou nada.
  // Antes: loop de SELECT+UPDATE por item no client, sem atomicidade.
  const executarAcao = async () => {
    if (!modalConfirmacao) return;
    setProcessandoAcao(true);
    const { tipo, venda } = modalConfirmacao;
    try {
      const { error } = await supabase.rpc('cancelar_venda', {
        p_venda_id: venda.id,
        p_estornar_estoque: tipo === 'cancelar',
      });
      if (error) throw error;
      setModalConfirmacao(null);
      await fetchVendas();
    } catch (err: any) {
      alert('Erro: ' + (err?.message || String(err)));
    } finally {
      setProcessandoAcao(false);
    }
  };

  // --- IMPRESSÃO ---
  const handlePrint = () => {
    const conteudo = printRef.current?.innerHTML;
    const janela = window.open('', '', 'height=600,width=400');
    if (janela && conteudo) {
      janela.document.write(
        '<html><head><title>Recibo UPFITNESS</title><style>body{font-family:monospace;padding:20px}.row{display:flex;justify-content:space-between}</style></head><body>'
      );
      janela.document.write(conteudo);
      janela.document.close();
      janela.print();
    }
  };

  // --- WHATSAPP CORRIGIDO ---
  const handleWhatsApp = (v: Venda) => {
    const f = (n: number) =>
      new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(n);

    const linhas: string[] = [];
    linhas.push(`*COMPROVANTE UPFITNESS — PEDIDO #${v.codigo_venda}*`);
    linhas.push('--------------------------------');

    v.itens_venda.forEach((item) => {
      linhas.push(`${item.quantidade}x ${item.descricao_completa} | ${f(item.subtotal)}`);
    });

    linhas.push('--------------------------------');
    if (v.desconto > 0) {
      linhas.push(`Subtotal: ${f(v.valor_total)}`);
      linhas.push(`Desconto: - ${f(v.desconto)}`);
    }
    linhas.push(`*TOTAL: ${f(v.valor_liquido)}*`);
    linhas.push(`Pagamento: ${v.forma_pagamento}${v.parcelas > 1 ? ` (${v.parcelas}x)` : ''}`);
    if (v.forma_pagamento === 'crediario' && (v.crediario_parcelas?.length ?? 0) > 0) {
      if (v.crediario_frequencia) linhas.push(`Frequência: ${v.crediario_frequencia}`);
      [...v.crediario_parcelas].sort((a, b) => a.numero - b.numero).forEach((p) => {
        linhas.push(`${p.numero}ª — ${formatDataCurta(p.data_vencimento)}: ${f(Number(p.valor) || 0)}${p.pago ? ' (paga)' : ''}`);
      });
    }
    linhas.push(`Data: ${formatData(v.created_at)}`);

    const texto = linhas.join('\n');
    window.open(`https://wa.me/?text=${encodeURIComponent(texto)}`, '_blank', 'noopener,noreferrer');
  };

  const limparFiltros = () => {
    setDataInicio('');
    setDataFim('');
    try { localStorage.removeItem(STORAGE_KEY); } catch { /* ignore */ }
  };

  // --- RENDER ---
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-24">

      {/* HEADER */}
      <header className="bg-slate-900 p-6 border-b border-slate-800 sticky top-0 z-20 shadow-xl space-y-4">
        <div className="flex items-center gap-4">
          <Link
            href={`/${dashQS}`}
            className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95 transition"
          >
            ←
          </Link>
          <h1 className="font-black italic text-xl uppercase tracking-tighter">
            Histórico <span className="text-pink-600">Vendas</span>
          </h1>
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
              onClick={fetchVendas}
              className="flex-1 bg-pink-600 text-white px-6 py-2 rounded-xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95 hover:bg-pink-500 transition"
            >
              Filtrar
            </button>
            <button
              onClick={limparFiltros}
              className="bg-slate-800 text-slate-200 px-4 py-2 rounded-xl font-black uppercase text-xs tracking-widest border border-slate-700 hover:bg-slate-700 active:scale-95 transition"
            >
              Limpar
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">

        {/* MÉTRICAS */}
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

        {/* LISTA DE VENDAS */}
        {loading ? (
          <div className="text-center py-10 opacity-50 animate-pulse">
            <p className="text-xs font-bold uppercase">Buscando vendas...</p>
          </div>
        ) : vendas.length === 0 ? (
          <div className="text-center py-20 opacity-30">
            <span className="text-4xl grayscale">🧾</span>
            <p className="mt-2 font-bold">Nenhuma venda encontrada.</p>
          </div>
        ) : (
          <div className="space-y-3">
            {vendas.map((venda) => {
              const isExpanded = expandidoId === venda.id;
              const isEditandoCliente = editandoClienteId === venda.id;

              const custoVenda = venda.itens_venda.reduce((acc, item) => {
                const p = item.estoque?.produto;
                return acc + item.quantidade * ((p?.preco_compra || 0) + (p?.custo_frete || 0) + (p?.custo_embalagem || 0));
              }, 0);
              const lucroVenda = (venda.valor_liquido || 0) - custoVenda;

              return (
                <div
                  key={venda.id}
                  className={`bg-slate-900 rounded-2xl border transition-all overflow-hidden ${
                    isExpanded ? 'border-pink-500/50 shadow-pink-900/10 shadow-lg' : 'border-slate-800 hover:border-slate-700'
                  }`}
                >
                  {/* CABEÇALHO DO CARD */}
                  <button
                    onClick={() => setExpandidoId(isExpanded ? null : venda.id)}
                    className="w-full p-4 flex justify-between items-center text-left"
                  >
                    <div>
                      <div className="flex items-center gap-2 mb-1">
                        <span className="text-xs font-bold text-slate-300 bg-slate-800 px-2 py-0.5 rounded-md border border-slate-700 font-mono">
                          #{venda.codigo_venda}
                        </span>
                        <span className="text-[10px] text-slate-400 font-bold uppercase">
                          {formatData(venda.created_at)}
                        </span>
                      </div>
                      <div className="flex items-center gap-2 flex-wrap">
                        <span
                          className={`text-[9px] font-black uppercase px-1.5 py-0.5 rounded text-slate-950 ${
                            venda.forma_pagamento === 'pix'
                              ? 'bg-emerald-400'
                              : venda.forma_pagamento === 'credito'
                              ? 'bg-blue-400'
                              : venda.forma_pagamento === 'crediario'
                              ? 'bg-violet-400'
                              : 'bg-yellow-400'
                          }`}
                        >
                          {venda.forma_pagamento}
                        </span>
                        {venda.forma_pagamento === 'crediario' && (venda.crediario_parcelas?.length ?? 0) > 0 && (
                          <span className={`text-[9px] font-black uppercase px-1.5 py-0.5 rounded border ${venda.crediario_parcelas.every((p) => p.pago) ? 'text-emerald-400 border-emerald-900/50 bg-emerald-950/30' : 'text-violet-300 border-violet-900/50 bg-violet-950/30'}`}>
                            {venda.crediario_parcelas.filter((p) => p.pago).length}/{venda.crediario_parcelas.length} pagas
                          </span>
                        )}
                        {!isExpanded && (
                          <span className="text-[10px] text-slate-500 font-bold uppercase">
                            {venda.itens_venda.length} itens
                          </span>
                        )}
                        {!isExpanded && venda.nome_cliente?.trim() && (
                          <span className="text-[10px] text-pink-400 font-bold truncate max-w-[140px]">
                            👤 {venda.nome_cliente.trim()}
                          </span>
                        )}
                      </div>
                    </div>

                    <div className="text-right">
                      <span className="block text-lg font-black text-white">
                        {formatBRL(venda.valor_liquido)}
                      </span>
                      {isExpanded && (
                        <span className="block text-[10px] font-bold text-emerald-500">
                          Lucro: {formatBRL(lucroVenda)}
                        </span>
                      )}
                      <span className="text-[10px] text-slate-500 uppercase font-bold">
                        {isExpanded ? '▲ Recolher' : '▼ Detalhes'}
                      </span>
                    </div>
                  </button>

                  {/* DETALHES EXPANDIDOS */}
                  {isExpanded && (
                    <div className="bg-slate-950/50 border-t border-slate-800 p-4 animate-in slide-in-from-top-2 duration-200 space-y-4">

                      {/* BLOCO DE CLIENTE */}
                      <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-3">
                        <p className="text-[10px] text-slate-500 font-black uppercase tracking-widest mb-2">
                          Cliente
                        </p>

                        {isEditandoCliente ? (
                          /* MODO EDIÇÃO COM AUTOCOMPLETE */
                          <div className="flex flex-col gap-2">
                            <div className="relative">
                              <div className="flex gap-2 items-center">
                                <input
                                  type="text"
                                  autoFocus
                                  autoComplete="off"
                                  placeholder="Nome da cliente..."
                                  value={editandoClienteValor}
                                  onChange={(e) => {
                                    setEditandoClienteValor(e.target.value);
                                    setMostrarSugestoes(true);
                                  }}
                                  onFocus={() => setMostrarSugestoes(true)}
                                  onBlur={() => setTimeout(() => setMostrarSugestoes(false), 150)}
                                  onKeyDown={(e) => {
                                    if (e.key === 'Enter') salvarNomeCliente(venda.id);
                                    if (e.key === 'Escape') cancelarEdicaoCliente();
                                  }}
                                  className="flex-1 bg-slate-950 border-2 border-pink-500 outline-none rounded-xl px-3 py-2 text-sm font-bold text-white placeholder:text-slate-600"
                                />
                                <button
                                  onClick={() => salvarNomeCliente(venda.id)}
                                  disabled={salvandoCliente}
                                  className="bg-pink-600 hover:bg-pink-500 text-white px-3 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest active:scale-95 disabled:opacity-50 whitespace-nowrap"
                                >
                                  {salvandoCliente ? '...' : 'Salvar'}
                                </button>
                                <button
                                  onClick={cancelarEdicaoCliente}
                                  disabled={salvandoCliente}
                                  className="bg-slate-800 hover:bg-slate-700 text-slate-400 px-3 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest active:scale-95"
                                >
                                  ✕
                                </button>
                              </div>

                              {/* Dropdown de sugestões */}
                              {mostrarSugestoes && sugestoesFiltradas.length > 0 && (
                                <div className="absolute left-0 right-0 z-50 bg-slate-900 border border-slate-700 rounded-2xl overflow-hidden shadow-2xl max-h-40 overflow-y-auto mt-1">
                                  {sugestoesFiltradas.map((nome) => (
                                    <button
                                      key={nome}
                                      type="button"
                                      onMouseDown={() => {
                                        setEditandoClienteValor(nome);
                                        setMostrarSugestoes(false);
                                      }}
                                      className="w-full text-left px-4 py-2.5 text-sm font-bold text-white hover:bg-pink-600 transition-colors border-b border-slate-800 last:border-0"
                                    >
                                      {nome}
                                    </button>
                                  ))}
                                </div>
                              )}
                            </div>

                            {/* Badge novo cliente */}
                            {editandoClienteValor.trim() &&
                              !clientesExistentes.some(
                                (n) => n.toLowerCase() === editandoClienteValor.trim().toLowerCase()
                              ) && (
                                <p className="text-[10px] font-bold text-emerald-400 uppercase tracking-widest px-1">
                                  ✦ Novo cliente
                                </p>
                              )}
                          </div>
                        ) : (
                          /* MODO LEITURA */
                          <div className="flex items-center justify-between gap-3">
                            {venda.nome_cliente?.trim() ? (
                              <p className="text-sm font-black text-white truncate">
                                👤 {venda.nome_cliente.trim()}
                              </p>
                            ) : (
                              <p className="text-sm font-bold text-slate-600 italic">
                                Sem cliente registrado
                              </p>
                            )}
                            <button
                              onClick={() => iniciarEdicaoCliente(venda)}
                              className="shrink-0 text-[10px] font-black uppercase tracking-widest text-slate-400 hover:text-pink-400 bg-slate-800 hover:bg-slate-700 border border-slate-700 px-3 py-1.5 rounded-xl active:scale-95 transition-colors"
                            >
                              ✏️ {venda.nome_cliente?.trim() ? 'Editar' : 'Adicionar'}
                            </button>
                          </div>
                        )}
                      </div>

                      {/* ITENS */}
                      <div className="space-y-2">
                        <p className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">
                          Itens do Pedido
                        </p>
                        {venda.itens_venda.map((item) => (
                          <div
                            key={item.id}
                            className="flex justify-between items-center text-sm border-b border-slate-800/50 pb-2 last:border-0 last:pb-0"
                          >
                            <div className="text-slate-300">
                              <span className="font-bold text-slate-500 mr-2">{item.quantidade}x</span>
                              {item.descricao_completa}
                            </div>
                            <div className="font-mono text-slate-400 text-xs">{formatBRL(item.subtotal)}</div>
                          </div>
                        ))}
                      </div>

                      {/* PARCELAS DO CREDIÁRIO */}
                      {venda.forma_pagamento === 'crediario' && (venda.crediario_parcelas?.length ?? 0) > 0 && (
                        <div className="bg-slate-900/60 border border-violet-900/40 rounded-2xl p-3 space-y-2">
                          <div className="flex items-center justify-between gap-2">
                            <p className="text-[10px] text-violet-400 font-black uppercase tracking-widest">
                              Crediário — {venda.crediario_parcelas.filter((p) => p.pago).length}/{venda.crediario_parcelas.length} pagas
                              {venda.crediario_frequencia ? ` • ${venda.crediario_frequencia}` : ''}
                            </p>
                            <Link
                              href={`/recebiveis${dashQS}`}
                              onClick={() => preFiltrarRecebiveis(venda.nome_cliente)}
                              className="shrink-0 text-[10px] font-black uppercase tracking-widest text-slate-300 hover:text-white bg-slate-800 hover:bg-slate-700 border border-slate-700 px-3 py-1.5 rounded-xl active:scale-95 transition-colors"
                            >
                              Recebíveis →
                            </Link>
                          </div>
                          <div className="space-y-1">
                            {[...venda.crediario_parcelas].sort((a, b) => a.numero - b.numero).map((p) => (
                              <div key={p.id} className="flex justify-between items-center text-xs border-b border-slate-800/50 pb-1 last:border-0 last:pb-0">
                                <span className="text-slate-400 font-mono">
                                  {p.numero}ª — venc. {formatDataCurta(p.data_vencimento)}
                                  {p.pago && p.data_pagamento ? ` • paga em ${formatDataCurta(p.data_pagamento)}` : ''}
                                </span>
                                <span className={`font-bold ${p.pago ? 'text-emerald-400' : 'text-slate-300'}`}>
                                  {formatBRL(Number(p.valor) || 0)}{p.pago ? ' ✓' : ''}
                                </span>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}

                      {/* AÇÕES */}
                      <div className="flex flex-col gap-2 pt-2 border-t border-slate-800/50">
                        <button
                          onClick={() => setVendaRecibo(venda)}
                          className="w-full bg-slate-800 hover:bg-slate-700 text-white py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest flex items-center justify-center gap-2 transition"
                        >
                          📄 Ver Recibo / Imprimir
                        </button>
                        {venda.forma_pagamento !== 'crediario' && (
                          <button
                            onClick={() => abrirConversao(venda)}
                            className="w-full bg-violet-950/30 hover:bg-violet-900/40 text-violet-300 border border-violet-900/50 py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest flex items-center justify-center gap-2 transition"
                          >
                            💳 Converter p/ Crediário
                          </button>
                        )}
                        <div className="flex gap-2">
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
                  <div key={idx} className="text-xs">
                    <div className="flex justify-between items-start">
                      <div className="pr-2">
                        <span className="font-bold">{item.quantidade}x</span> {item.descricao_completa}
                      </div>
                      <div className="font-bold whitespace-nowrap">{formatBRL(item.subtotal)}</div>
                    </div>
                    <div className="text-[10px] text-slate-500 text-right">
                      {formatBRL(item.preco_unitario)} un.
                    </div>
                  </div>
                ))}
              </div>

              <div className="border-t-2 border-dashed border-slate-300 pt-4 space-y-1 text-right">
                <div className="flex justify-between text-slate-500 text-xs">
                  <span>Subtotal</span>
                  <span>{formatBRL(vendaRecibo.valor_total)}</span>
                </div>
                {vendaRecibo.desconto > 0 && (
                  <div className="flex justify-between text-red-600 text-xs font-bold">
                    <span>Desconto</span>
                    <span>-{formatBRL(vendaRecibo.desconto)}</span>
                  </div>
                )}
                <div className="flex justify-between text-lg font-black mt-2">
                  <span>TOTAL PAGO</span>
                  <span>{formatBRL(vendaRecibo.valor_liquido)}</span>
                </div>
                <div className="text-[10px] uppercase text-slate-500 mt-2">
                  Pagamento via {vendaRecibo.forma_pagamento}
                  {vendaRecibo.parcelas > 1 ? ` (${vendaRecibo.parcelas}x)` : ''}
                  {vendaRecibo.forma_pagamento === 'crediario' && vendaRecibo.crediario_frequencia ? ` • ${vendaRecibo.crediario_frequencia}` : ''}
                </div>
              </div>

              {vendaRecibo.forma_pagamento === 'crediario' && (vendaRecibo.crediario_parcelas?.length ?? 0) > 0 && (
                <div className="mt-4 text-left text-[11px]">
                  <div className="border-b-2 border-dashed border-slate-300 mb-3"></div>
                  <div className="font-bold uppercase text-xs mb-2">Parcelas do crediário</div>
                  <div className="space-y-1">
                    {[...vendaRecibo.crediario_parcelas].sort((a, b) => a.numero - b.numero).map((p) => (
                      <div key={p.id} className="flex justify-between">
                        <span>{p.numero}ª — {formatDataCurta(p.data_vencimento)}</span>
                        <span className="font-bold">{formatBRL(Number(p.valor) || 0)}{p.pago ? ' ✓ paga' : ''}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>

            <div className="p-4 bg-slate-100 border-t border-slate-200 flex flex-col gap-2">
              <div className="flex gap-2">
                <button
                  onClick={handlePrint}
                  className="flex-1 bg-slate-800 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-slate-700 transition-colors text-xs uppercase"
                >
                  🖨️ Imprimir
                </button>
                <button
                  onClick={() => handleWhatsApp(vendaRecibo)}
                  className="flex-1 bg-emerald-600 text-white py-3 rounded-lg font-bold flex items-center justify-center gap-2 hover:bg-emerald-500 transition-colors text-xs uppercase"
                >
                  💬 WhatsApp
                </button>
              </div>
              <button
                onClick={() => setVendaRecibo(null)}
                className="w-full text-slate-500 py-2 font-bold uppercase tracking-widest text-[10px] hover:text-red-500 transition"
              >
                Fechar
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL CONVERSÃO PARA CREDIÁRIO */}
      {modalConversao && (
        <div className="fixed inset-0 z-[60] bg-black/95 backdrop-blur-md flex items-center justify-center p-4 animate-in zoom-in-95 duration-200">
          <div className="bg-slate-900 w-full max-w-md rounded-3xl border border-slate-700 shadow-2xl flex flex-col max-h-[92vh]">
            <div className="p-5 border-b border-slate-800 shrink-0">
              <h3 className="text-lg font-black uppercase text-white tracking-tighter">
                Converter p/ <span className="text-violet-400">Crediário</span>
              </h3>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">
                Venda #{modalConversao.codigo_venda} • {modalConversao.nome_cliente?.trim()} • {formatBRL(modalConversao.valor_liquido || 0)}
              </p>
            </div>

            <div className="p-5 space-y-4 overflow-y-auto">
              {/* Frequência */}
              <div className="grid grid-cols-3 gap-2">
                {(['semanal', 'quinzenal', 'mensal'] as FrequenciaCrediario[]).map((fq) => (
                  <button key={fq} onClick={() => setConv((prev) => ({ ...prev, frequencia: fq }))} className={`py-3 rounded-xl font-bold uppercase text-[10px] tracking-widest transition-all border-2 ${conv.frequencia === fq ? 'bg-violet-600 border-violet-500 text-white shadow' : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'}`}>
                    {FREQ_LABEL[fq]}
                  </button>
                ))}
              </div>

              {/* Nº de parcelas + 1ª parcela */}
              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <label className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">Parcelas</label>
                  <select className="w-full bg-slate-950 border-2 border-slate-800 p-3 rounded-xl text-white font-bold outline-none focus:border-violet-500" value={conv.numParcelas} onChange={(e) => setConv((prev) => ({ ...prev, numParcelas: parseInt(e.target.value) }))}>
                    {Array.from({ length: 24 }, (_, i) => i + 1).map((p) => <option key={p} value={p}>{p}x</option>)}
                  </select>
                </div>
                <div className="space-y-1">
                  <label className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">1ª parcela</label>
                  <input type="date" className="w-full bg-slate-950 border-2 border-slate-800 p-3 rounded-xl text-white font-bold outline-none focus:border-violet-500" value={conv.primeiraData} onChange={(e) => { if (e.target.value) setConv((prev) => ({ ...prev, primeiraData: e.target.value })); }} />
                </div>
              </div>

              <p className="text-[10px] font-bold text-slate-500 uppercase tracking-widest leading-relaxed">
                Venda antiga controlada por fora? Marque as parcelas <span className="text-emerald-400">já pagas</span> — elas entram quitadas, sem passar pelos recebíveis.
              </p>

              {/* Parcelas: paga? + data + valor editável */}
              <div className="bg-slate-950 border-2 border-slate-800 rounded-xl overflow-hidden">
                <div className="px-4 py-3 border-b border-slate-800 flex items-center justify-between">
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Parcelas</span>
                  <button onClick={() => setConv((prev) => ({ ...prev, parcelas: gerarParcelasConv(modalConversao.valor_liquido || 0, prev.numParcelas, prev.primeiraData, prev.frequencia) }))} className="text-[10px] font-black uppercase tracking-widest text-violet-400 hover:text-violet-300 active:scale-95">↺ Redistribuir</button>
                </div>
                <div className="max-h-52 overflow-y-auto divide-y divide-slate-800/60">
                  {conv.parcelas.map((p, idx) => (
                    <div key={p.numero} className="flex items-center gap-2 px-3 py-2">
                      <label className="flex items-center gap-1.5 shrink-0 cursor-pointer" title="Parcela já paga">
                        <input
                          type="checkbox"
                          checked={p.pago}
                          onChange={(e) => setConv((prev) => ({ ...prev, parcelas: prev.parcelas.map((pp) => pp.numero === p.numero ? { ...pp, pago: e.target.checked } : pp) }))}
                          className="w-4 h-4 accent-emerald-500"
                        />
                        <span className={`text-[9px] font-black uppercase ${p.pago ? 'text-emerald-400' : 'text-slate-600'}`}>paga</span>
                      </label>
                      <span className="w-7 text-[11px] font-black text-slate-400 shrink-0">{p.numero}ª</span>
                      <span className="flex-1 text-[11px] font-mono text-slate-300 truncate">{formatDataCurta(p.data_vencimento)}</span>
                      <div className="flex items-center gap-1 bg-slate-900 border border-slate-700 rounded-lg px-2 shrink-0">
                        <span className="text-[10px] text-slate-500 font-bold">R$</span>
                        <input
                          type="text" inputMode="decimal" autoComplete="off"
                          className="bg-transparent w-[4.5rem] py-2 text-sm font-bold text-white outline-none text-right"
                          value={p.valorStr}
                          onChange={(e) => {
                            const raw = e.target.value.replace(/[^0-9.,]/g, '');
                            setConv((prev) => ({
                              ...prev,
                              parcelas: prev.parcelas.map((pp) => pp.numero === p.numero ? { ...pp, valorStr: raw, valor: parseValorDigitado(raw) } : pp),
                            }));
                          }}
                        />
                      </div>
                      {idx === conv.parcelas.length - 1 && conv.parcelas.length > 1 && (
                        <button onClick={restoNaUltimaConv} title="Colocar o valor restante nesta parcela" className="shrink-0 text-[9px] font-black uppercase tracking-widest text-violet-300 bg-violet-950/40 border border-violet-900/50 hover:bg-violet-900/40 px-2 py-1.5 rounded-lg active:scale-95">
                          resto
                        </button>
                      )}
                    </div>
                  ))}
                </div>
                <div className={`px-4 py-3 border-t flex items-center justify-between ${convSomaOk ? 'border-emerald-900/40 bg-emerald-950/20' : 'border-red-900/40 bg-red-950/20'}`}>
                  <span className={`text-[10px] font-black uppercase tracking-widest ${convSomaOk ? 'text-emerald-400' : 'text-red-400'}`}>
                    {convSomaOk ? '✓ Soma confere' : `Diferença: ${formatBRL((convSomaCents - convTotalCents) / 100)}`}
                  </span>
                  <span className="text-xs font-black text-white">{formatBRL(convSomaCents / 100)} / {formatBRL(convTotalCents / 100)}</span>
                </div>
              </div>
            </div>

            <div className="p-4 border-t border-slate-800 grid grid-cols-2 gap-3 shrink-0">
              <button onClick={() => setModalConversao(null)} disabled={convertendo} className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition">
                Voltar
              </button>
              <button onClick={confirmarConversao} disabled={convertendo || !convSomaOk || !convValoresOk} className="bg-violet-600 hover:bg-violet-500 text-white py-4 rounded-xl font-black uppercase text-xs tracking-widest transition shadow-lg disabled:opacity-50">
                {convertendo ? 'Convertendo...' : 'Converter'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL CONFIRMAÇÃO */}
      {modalConfirmacao && (
        <div className="fixed inset-0 z-[60] bg-black/95 backdrop-blur-md flex items-center justify-center p-6 animate-in zoom-in-95 duration-200">
          <div className="bg-slate-900 w-full max-w-sm rounded-3xl border border-slate-700 p-6 shadow-2xl">
            <div className="text-center space-y-4">
              <div
                className={`w-16 h-16 rounded-full flex items-center justify-center mx-auto text-3xl ${
                  modalConfirmacao.tipo === 'cancelar'
                    ? 'bg-orange-500/20 text-orange-500'
                    : 'bg-red-500/20 text-red-500'
                }`}
              >
                {modalConfirmacao.tipo === 'cancelar' ? '🚫' : '🗑️'}
              </div>
              <h3 className="text-xl font-black uppercase text-white">
                {modalConfirmacao.tipo === 'cancelar' ? 'Cancelar Venda?' : 'Apagar Registro?'}
              </h3>
              <p className="text-sm text-slate-400 leading-relaxed">
                {modalConfirmacao.tipo === 'cancelar' ? (
                  <span>
                    Você está prestes a cancelar a venda{' '}
                    <b>#{modalConfirmacao.venda.codigo_venda}</b>.<br /><br />
                    <span className="text-orange-400 font-bold">
                      ⚠️ O estoque dos itens será devolvido automaticamente.
                    </span>
                  </span>
                ) : (
                  <span>
                    Você vai remover o registro da venda{' '}
                    <b>#{modalConfirmacao.venda.codigo_venda}</b> do histórico.<br /><br />
                    <span className="text-red-400 font-bold">
                      ⚠️ O estoque NÃO será alterado.
                    </span>
                  </span>
                )}
                {modalConfirmacao.venda.forma_pagamento === 'crediario' && (modalConfirmacao.venda.crediario_parcelas?.length ?? 0) > 0 && (
                  <span>
                    <br /><br />
                    <span className="text-violet-400 font-bold">
                      💳 Venda em crediário: as {modalConfirmacao.venda.crediario_parcelas.length} parcela(s)
                      {modalConfirmacao.venda.crediario_parcelas.filter((p) => p.pago).length > 0
                        ? ` (${modalConfirmacao.venda.crediario_parcelas.filter((p) => p.pago).length} já paga(s))`
                        : ''} serão removidas dos recebíveis junto com a venda.
                    </span>
                  </span>
                )}
              </p>
            </div>
            <div className="grid grid-cols-2 gap-3 mt-8">
              <button
                onClick={() => setModalConfirmacao(null)}
                className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition"
              >
                Voltar
              </button>
              <button
                onClick={executarAcao}
                disabled={processandoAcao}
                className={`py-4 rounded-xl font-black uppercase text-xs tracking-widest transition text-white shadow-lg ${
                  modalConfirmacao.tipo === 'cancelar'
                    ? 'bg-orange-600 hover:bg-orange-500'
                    : 'bg-red-600 hover:bg-red-500'
                }`}
              >
                {processandoAcao ? 'Processando...' : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}