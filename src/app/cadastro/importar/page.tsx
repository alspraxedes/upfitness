// src/app/cadastro/importar/page.tsx
// Importação em massa de produtos a partir de uma planilha .xlsx no formato
// usado pelas lojistas. Parse 100% client-side (SheetJS). Agrupamento:
// (sku_fornecedor + cor) = 1 produto; linhas repetidas por tamanho somam
// quantidade. Produto já existente no banco (mesmo sku_fornecedor + cor) tem
// o estoque somado em vez de recriado.
'use client';

import { Suspense, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import * as XLSX from 'xlsx';
import { supabase } from '../../../lib/supabase';

type RawRow = {
  linha: number;
  codigo: string;
  fornecedor: string;
  descricao: string;
  cor: string;
  preco_compra: number;
  qtd: number;
  tamanho: string;
  frete: number;
  embalagem: number;
  preco_venda: number;
  ean: string;
};

type GrupoItem = {
  key: string; // sku_fornecedor + '|' + cor_normalizada
  sku_fornecedor: string;
  cor: string;
  cor_origem: 'planilha' | 'sufixo-codigo' | 'ausente';
  fornecedor: string;
  descricao: string;
  preco_compra: number;
  custo_frete: number;
  custo_embalagem: number;
  preco_venda: number;
  // Por nome de tamanho da planilha: quantidade e EAN (primeiro não-vazio).
  tamanhos: Map<string, { qtd: number; ean: string | null }>;
  linhas: number[]; // nº da planilha, para preview
  // Resolvido depois contra o banco:
  existente_produto_id?: string | null;
};

type Tamanho = { id: string; nome: string; ordem: number };

type Validacao =
  | { tipo: 'erro'; msg: string; linha: number }
  | { tipo: 'aviso'; msg: string; linha: number };

function getQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

// Normaliza string (minúscula, sem acento, trim) para comparar cor/tamanho
function norm(s: string | null | undefined): string {
  if (!s) return '';
  return s.toString().normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}

// Capitaliza cada palavra ("storm" → "Storm", "AZUL BIC" → "Azul Bic")
function capitalizar(s: string): string {
  return s
    .toLowerCase()
    .trim()
    .split(/\s+/)
    .map((w) => (w.length > 0 ? w[0].toUpperCase() + w.slice(1) : w))
    .join(' ');
}

// Extrai cor do sufixo de códigos tipo "TP10502/storm" ou "FS1528.V26_C0173"
function extrairCorDoCodigo(codigo: string): string | null {
  const slash = codigo.indexOf('/');
  if (slash >= 0 && slash < codigo.length - 1) {
    const sufixo = codigo.substring(slash + 1).trim();
    if (sufixo && !/^\d+$/.test(sufixo)) return capitalizar(sufixo);
  }
  return null;
}

function parseNum(v: unknown): number {
  if (v === null || v === undefined || v === '') return 0;
  if (typeof v === 'number') return isFinite(v) ? v : 0;
  const n = parseFloat(String(v).replace(',', '.').replace(/[^0-9.-]/g, ''));
  return isNaN(n) ? 0 : n;
}

// Cabeçalhos esperados (match case-insensitive, acento-insensitive)
const COLS = {
  codigo: ['codigo do produto', 'codigo', 'código do produto', 'código'],
  fornecedor: ['fornecedor'],
  descricao: ['descricao', 'descrição'],
  cor: ['cor'],
  preco_unitario: ['preco unitario', 'preço unitário', 'preco unit', 'preço unit'],
  qtd: ['quantidade em estoque', 'quantidade', 'qtd', 'qtd em estoque'],
  tamanho: ['tamanho'],
  frete: ['frete diluido', 'frete diluído', 'frete'],
  embalagem: ['embalagem'],
  preco_venda: ['valor de revenda', 'preco de venda', 'preço de venda', 'preco venda', 'preço venda'],
};

// Colunas opcionais: se o cabeçalho tiver, usa; se não tiver, ignora.
const COLS_OPCIONAIS = {
  ean: ['ean', 'codigo de barras', 'código de barras', 'cod barras', 'cód barras', 'cod. barras', 'cód. barras'],
};

function identificarColunas(header: unknown[]): Record<string, number> {
  const idx: Record<string, number> = {};
  header.forEach((h, i) => {
    const n = norm(String(h ?? ''));
    for (const [chave, alts] of Object.entries(COLS)) {
      if (alts.some((a) => norm(a) === n)) idx[chave] = i;
    }
    for (const [chave, alts] of Object.entries(COLS_OPCIONAIS)) {
      if (alts.some((a) => norm(a) === n)) idx[chave] = i;
    }
  });
  return idx;
}

// EAN pode vir como número (Excel converte sozinho) ou string. Trim e tira
// o ".0" que o Excel às vezes insere ao formatar número grande como texto.
function parseEan(v: unknown): string {
  if (v === null || v === undefined || v === '') return '';
  const s = String(v).trim();
  if (/^\d+\.0+$/.test(s)) return s.replace(/\.0+$/, '');
  return s;
}

type EtapaProgresso = {
  total: number;
  feitos: number;
  atual: string;
};

export default function ImportarPlanilhaPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950 text-slate-100" />}>
      <ImportarPlanilhaInner />
    </Suspense>
  );
}

function ImportarPlanilhaInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getQS(searchParams), [searchParams]);
  const voltarQS = useMemo(() => (dashQS ? dashQS : ''), [dashQS]);

  const [loadingPage, setLoadingPage] = useState(true);
  const [fileName, setFileName] = useState<string>('');
  const [parsing, setParsing] = useState(false);
  const [grupos, setGrupos] = useState<GrupoItem[]>([]);
  const [validacoes, setValidacoes] = useState<Validacao[]>([]);
  const [tamanhosDB, setTamanhosDB] = useState<Tamanho[]>([]);
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set());
  const [importando, setImportando] = useState(false);
  const [progresso, setProgresso] = useState<EtapaProgresso | null>(null);
  const [resultado, setResultado] = useState<{ novos: number; reposicoes: number; erros: Array<{ grupo: string; msg: string }> } | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) { router.replace('/login'); return; }
      const { data: t } = await supabase.from('tamanhos').select('id, nome, ordem').order('ordem', { ascending: true });
      setTamanhosDB((t as Tamanho[] | null) ?? []);
      setLoadingPage(false);
    })();
  }, [router]);

  // Resolve o id do tamanho (do banco) a partir do nome na planilha
  function tamanhoIdPorNome(nome: string): string | null {
    const n = norm(nome);
    const found = tamanhosDB.find((t) => norm(t.nome) === n);
    return found ? found.id : null;
  }

  async function onFile(ev: React.ChangeEvent<HTMLInputElement>) {
    const f = ev.target.files?.[0];
    if (!f) return;
    setFileName(f.name);
    setParsing(true);
    setGrupos([]);
    setValidacoes([]);
    setResultado(null);
    try {
      const buf = await f.arrayBuffer();
      const wb = XLSX.read(buf, { type: 'array' });
      const ws = wb.Sheets[wb.SheetNames[0]];
      if (!ws) throw new Error('Planilha vazia');
      const linhas = XLSX.utils.sheet_to_json<unknown[]>(ws, { header: 1, defval: null }) as unknown[][];
      if (linhas.length < 2) throw new Error('Planilha sem dados');

      const header = linhas[0];
      const idx = identificarColunas(header);
      const faltando = Object.keys(COLS).filter((k) => idx[k] === undefined);
      if (faltando.length > 0) {
        throw new Error(`Colunas obrigatórias faltando no cabeçalho: ${faltando.join(', ')}`);
      }

      const avisos: Validacao[] = [];
      const brutas: RawRow[] = [];
      for (let r = 1; r < linhas.length; r++) {
        const row = linhas[r] ?? [];
        const codigoRaw = row[idx.codigo];
        if (codigoRaw === null || codigoRaw === undefined || String(codigoRaw).trim() === '') continue;
        const linhaN = r + 1; // nº como aparece no Excel
        brutas.push({
          linha: linhaN,
          codigo: String(codigoRaw).trim(),
          fornecedor: String(row[idx.fornecedor] ?? '').trim(),
          descricao: String(row[idx.descricao] ?? '').trim(),
          cor: String(row[idx.cor] ?? '').trim(),
          preco_compra: parseNum(row[idx.preco_unitario]),
          qtd: Math.max(0, Math.round(parseNum(row[idx.qtd]))),
          tamanho: String(row[idx.tamanho] ?? '').trim(),
          frete: parseNum(row[idx.frete]),
          embalagem: parseNum(row[idx.embalagem]),
          preco_venda: parseNum(row[idx.preco_venda]),
          ean: idx.ean !== undefined ? parseEan(row[idx.ean]) : '',
        });
      }

      // Resolve cor: planilha → sufixo do código → ausente
      type RowResolvido = RawRow & { corFinal: string; corOrigem: GrupoItem['cor_origem'] };
      const resolvidas: RowResolvido[] = [];
      for (const r of brutas) {
        let corFinal = r.cor;
        let corOrigem: GrupoItem['cor_origem'] = 'planilha';
        if (!corFinal) {
          const extraida = extrairCorDoCodigo(r.codigo);
          if (extraida) {
            corFinal = extraida;
            corOrigem = 'sufixo-codigo';
          } else {
            corOrigem = 'ausente';
          }
        }
        if (!corFinal) {
          avisos.push({ tipo: 'erro', linha: r.linha, msg: `Linha ${r.linha}: sem cor (coluna vazia e código "${r.codigo}" sem sufixo) — pulada.` });
          continue;
        }
        if (!r.fornecedor) {
          avisos.push({ tipo: 'erro', linha: r.linha, msg: `Linha ${r.linha}: sem fornecedor — pulada.` });
          continue;
        }
        if (!r.tamanho) {
          avisos.push({ tipo: 'erro', linha: r.linha, msg: `Linha ${r.linha}: sem tamanho — pulada.` });
          continue;
        }
        if (!tamanhoIdPorNome(r.tamanho)) {
          avisos.push({ tipo: 'erro', linha: r.linha, msg: `Linha ${r.linha}: tamanho "${r.tamanho}" não cadastrado no app — pulada.` });
          continue;
        }
        resolvidas.push({ ...r, corFinal, corOrigem });
      }

      // Agrupa por (codigo + cor normalizada)
      const porGrupo = new Map<string, GrupoItem>();
      for (const r of resolvidas) {
        const key = `${r.codigo}|${norm(r.corFinal)}`;
        let g = porGrupo.get(key);
        if (!g) {
          g = {
            key,
            sku_fornecedor: r.codigo,
            cor: r.corFinal,
            cor_origem: r.corOrigem,
            fornecedor: r.fornecedor,
            descricao: r.descricao,
            preco_compra: r.preco_compra,
            custo_frete: r.frete,
            custo_embalagem: r.embalagem,
            preco_venda: r.preco_venda,
            tamanhos: new Map(),
            linhas: [],
          };
          porGrupo.set(key, g);
        } else {
          // Avisa se valores divergem (mantemos os da primeira linha)
          const campos: Array<[keyof GrupoItem, number]> = [
            ['preco_compra', r.preco_compra],
            ['custo_frete', r.frete],
            ['custo_embalagem', r.embalagem],
            ['preco_venda', r.preco_venda],
          ];
          for (const [campo, val] of campos) {
            if (Math.round((g[campo] as number) * 100) !== Math.round(val * 100)) {
              avisos.push({
                tipo: 'aviso',
                linha: r.linha,
                msg: `Linha ${r.linha}: ${String(campo)} (${formatBRL(val)}) difere do grupo (${formatBRL(g[campo] as number)}) — mantido o primeiro.`,
              });
            }
          }
        }
        g.linhas.push(r.linha);
        // Soma quantidades por tamanho e consolida EAN (primeiro não-vazio).
        // Se chegar EAN diferente para o mesmo tamanho, avisa.
        const atual = g.tamanhos.get(r.tamanho) ?? { qtd: 0, ean: null };
        const novoEan = r.ean || null;
        let eanFinal = atual.ean;
        if (novoEan && !eanFinal) {
          eanFinal = novoEan;
        } else if (novoEan && eanFinal && novoEan !== eanFinal) {
          avisos.push({
            tipo: 'aviso',
            linha: r.linha,
            msg: `Linha ${r.linha}: EAN "${novoEan}" difere do já visto no mesmo tamanho ("${eanFinal}") — mantido o primeiro.`,
          });
        }
        g.tamanhos.set(r.tamanho, {
          qtd: atual.qtd + (r.qtd > 0 ? r.qtd : 1),
          ean: eanFinal,
        });
      }

      // Consulta banco: produtos já existentes (sku_fornecedor+cor)
      const gruposArr = Array.from(porGrupo.values());
      const skus = Array.from(new Set(gruposArr.map((g) => g.sku_fornecedor)));
      if (skus.length > 0) {
        // Chunk de 200 pra não estourar query string
        const CHUNK = 200;
        for (let i = 0; i < skus.length; i += CHUNK) {
          const slice = skus.slice(i, i + CHUNK);
          const { data: exist } = await supabase
            .from('produtos')
            .select('id, sku_fornecedor, cor')
            .in('sku_fornecedor', slice);
          (exist ?? []).forEach((p) => {
            const nkey = `${p.sku_fornecedor}|${norm(p.cor ?? '')}`;
            const g = porGrupo.get(nkey);
            if (g) g.existente_produto_id = p.id as string;
          });
        }
      }

      setGrupos(gruposArr);
      setSelecionados(new Set(gruposArr.map((g) => g.key)));
      setValidacoes(avisos);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      alert(`Erro ao ler planilha: ${msg}`);
      setFileName('');
    } finally {
      setParsing(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  }

  // Gera códigos UPF em lote, verificando colisão em uma única query
  async function gerarCodigosUPF(quantidade: number): Promise<string[]> {
    const ano = new Date().getFullYear();
    const prefixo = `UPF${ano}`;
    // Pega o maior sufixo existente este ano
    const { data } = await supabase
      .from('produtos')
      .select('codigo_peca')
      .ilike('codigo_peca', `${prefixo}%`);
    let maior = 999;
    (data ?? []).forEach((p) => {
      const m = String(p.codigo_peca ?? '').match(/^UPF\d{4}(\d{4,})$/);
      if (m) {
        const n = parseInt(m[1], 10);
        if (!isNaN(n) && n > maior) maior = n;
      }
    });
    const out: string[] = [];
    for (let i = 1; i <= quantidade; i++) {
      out.push(`${prefixo}${String(maior + i).padStart(4, '0')}`);
    }
    return out;
  }

  async function importar() {
    const alvo = grupos.filter((g) => selecionados.has(g.key));
    if (alvo.length === 0) { alert('Nenhum item selecionado.'); return; }

    setImportando(true);
    setProgresso({ total: alvo.length, feitos: 0, atual: 'Preparando...' });
    const erros: Array<{ grupo: string; msg: string }> = [];
    let novos = 0;
    let reposicoes = 0;

    try {
      const novosGrupos = alvo.filter((g) => !g.existente_produto_id);
      const codigos = await gerarCodigosUPF(novosGrupos.length);
      const codigosMap = new Map<string, string>();
      novosGrupos.forEach((g, i) => codigosMap.set(g.key, codigos[i]));

      for (let i = 0; i < alvo.length; i++) {
        const g = alvo[i];
        setProgresso({ total: alvo.length, feitos: i, atual: `${g.sku_fornecedor} — ${g.cor}` });
        try {
          let produto_id = g.existente_produto_id ?? null;

          if (!produto_id) {
            const codigo_peca = codigosMap.get(g.key)!;
            const { data: p, error: pe } = await supabase
              .from('produtos')
              .insert([{
                codigo_peca,
                sku_fornecedor: g.sku_fornecedor,
                descricao: g.descricao,
                fornecedor: g.fornecedor,
                cor: g.cor,
                foto_url: null,
                preco_compra: g.preco_compra,
                custo_frete: g.custo_frete,
                custo_embalagem: g.custo_embalagem,
                preco_venda: g.preco_venda,
              }])
              .select('id')
              .single();
            if (pe) throw new Error(pe.message);
            produto_id = (p as { id: string }).id;
            novos++;
          } else {
            reposicoes++;
          }

          // Para cada tamanho do grupo: se já existe linha de estoque, soma e
          // preenche EAN caso esteja em branco no banco; senão, insere com EAN.
          const tamanhosDoGrupo = Array.from(g.tamanhos.entries());
          const tamanhoIds = tamanhosDoGrupo
            .map(([nome]) => tamanhoIdPorNome(nome))
            .filter((v): v is string => !!v);
          const { data: existEst } = await supabase
            .from('estoque')
            .select('id, tamanho_id, quantidade, codigo_barras')
            .eq('produto_id', produto_id)
            .in('tamanho_id', tamanhoIds);
          const existMap = new Map<string, { id: string; quantidade: number; codigo_barras: string | null }>();
          (existEst ?? []).forEach((e) => existMap.set(
            e.tamanho_id as string,
            { id: e.id as string, quantidade: Number(e.quantidade) || 0, codigo_barras: (e.codigo_barras as string | null) ?? null },
          ));

          const paraInserir: Array<{ produto_id: string; tamanho_id: string; quantidade: number; codigo_barras: string | null }> = [];
          for (const [nomeTam, info] of tamanhosDoGrupo) {
            const tid = tamanhoIdPorNome(nomeTam);
            if (!tid) continue;
            const atual = existMap.get(tid);
            if (atual) {
              const nova = atual.quantidade + info.qtd;
              const patch: { quantidade: number; codigo_barras?: string } = { quantidade: nova };
              if (info.ean && !atual.codigo_barras) patch.codigo_barras = info.ean;
              const { error: ue } = await supabase
                .from('estoque')
                .update(patch)
                .eq('id', atual.id);
              if (ue) throw new Error(`estoque ${nomeTam}: ${ue.message}`);
            } else {
              paraInserir.push({ produto_id, tamanho_id: tid, quantidade: info.qtd, codigo_barras: info.ean || null });
            }
          }
          if (paraInserir.length > 0) {
            const { error: ie } = await supabase.from('estoque').insert(paraInserir);
            if (ie) throw new Error(`estoque insert: ${ie.message}`);
          }
        } catch (e: unknown) {
          const msg = e instanceof Error ? e.message : String(e);
          erros.push({ grupo: `${g.sku_fornecedor} — ${g.cor}`, msg });
        }
      }
      setProgresso({ total: alvo.length, feitos: alvo.length, atual: 'Concluído' });
      setResultado({ novos, reposicoes, erros });
    } finally {
      setImportando(false);
    }
  }

  const resumoPreview = useMemo(() => {
    const novos = grupos.filter((g) => !g.existente_produto_id).length;
    const reposicoes = grupos.filter((g) => g.existente_produto_id).length;
    const totalPecas = grupos.reduce((a, g) => a + Array.from(g.tamanhos.values()).reduce((s, info) => s + info.qtd, 0), 0);
    const erros = validacoes.filter((v) => v.tipo === 'erro').length;
    const avisos = validacoes.filter((v) => v.tipo === 'aviso').length;
    return { novos, reposicoes, totalPecas, erros, avisos };
  }, [grupos, validacoes]);

  function toggleGrupo(key: string) {
    setSelecionados((prev) => {
      const n = new Set(prev);
      if (n.has(key)) n.delete(key); else n.add(key);
      return n;
    });
  }
  function selecionarTodos(filtro: 'todos' | 'novos' | 'reposicoes') {
    setSelecionados(new Set(
      grupos
        .filter((g) => filtro === 'todos' || (filtro === 'novos' ? !g.existente_produto_id : !!g.existente_produto_id))
        .map((g) => g.key)
    ));
  }

  if (loadingPage) {
    return <div className="min-h-screen bg-slate-950 text-slate-100 flex items-center justify-center text-xs font-black uppercase tracking-widest text-slate-500 animate-pulse">Carregando...</div>;
  }

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-32">
      <div className="h-[3px] w-full bg-gradient-to-r from-pink-600 to-blue-600" />

      <header className="bg-slate-900 p-6 border-b border-slate-800 sticky top-0 z-20 shadow-xl">
        <div className="flex items-center gap-4">
          <Link href={`/cadastro${voltarQS}`} className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white border border-slate-700 active:scale-95 transition" aria-label="Voltar">←</Link>
          <div>
            <h1 className="font-black italic text-xl uppercase tracking-tighter">Importar <span className="text-violet-500">planilha</span></h1>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">Cadastro em massa de produtos</p>
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto p-4 space-y-6">
        {/* UPLOAD */}
        {grupos.length === 0 && !resultado && (
          <section className="bg-slate-900 rounded-2xl border border-slate-800 shadow-xl p-6 space-y-4">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest">1. Escolha o arquivo</h2>
            <label className="block border-2 border-dashed border-slate-700 hover:border-violet-500 rounded-2xl p-8 text-center cursor-pointer transition">
              <input ref={fileInputRef} type="file" accept=".xlsx,.xls" onChange={onFile} disabled={parsing} className="hidden" />
              <div className="text-4xl mb-2 opacity-70">📊</div>
              <p className="text-sm font-black text-white uppercase tracking-widest">{parsing ? 'Processando...' : 'Clique para selecionar .xlsx'}</p>
              {fileName && <p className="text-[10px] font-mono text-slate-500 mt-2">{fileName}</p>}
            </label>
            <div className="bg-slate-950/60 border border-slate-800 rounded-xl p-4 text-[11px] text-slate-400 leading-relaxed">
              <p className="font-black uppercase tracking-widest text-slate-500 mb-2 text-[10px]">Colunas esperadas</p>
              <code className="font-mono text-[10px] text-violet-300">
                Código do Produto · Fornecedor · Descrição · Cor · Preço unitário · Quantidade em estoque · Tamanho · Frete Diluido · Embalagem · Valor de Revenda
              </code>
              <p className="mt-2 text-[10px] text-slate-500">
                Opcional: coluna <span className="text-sky-300 font-mono">EAN</span> (ou <span className="text-sky-300 font-mono">Código de Barras</span>) — se vier, cada linha carrega o EAN do seu tamanho.
              </p>
              <p className="mt-3 text-[10px] font-bold text-slate-500 uppercase tracking-widest">O que a importação faz</p>
              <ul className="list-disc list-inside mt-1 space-y-1 text-[11px]">
                <li>Agrupa linhas por <span className="text-white font-black">código + cor</span> → 1 produto; tamanhos viram grade de estoque.</li>
                <li>Se cor estiver vazia, extrai do sufixo do código (ex: <code className="text-violet-300">TP10502/storm</code>).</li>
                <li>Produto já cadastrado com mesmo SKU+cor: a quantidade é <span className="text-white font-black">somada</span> no estoque.</li>
                <li>Linhas sem fornecedor, tamanho ou com tamanho não cadastrado são puladas e listadas.</li>
              </ul>
            </div>
          </section>
        )}

        {/* PREVIEW */}
        {grupos.length > 0 && !resultado && (
          <>
            <section className="bg-slate-900 rounded-2xl border border-slate-800 shadow-xl p-5 space-y-3">
              <div className="flex items-center justify-between gap-3">
                <h2 className="text-sm font-black text-slate-400 uppercase tracking-widest">2. Confira e selecione</h2>
                <button onClick={() => { setGrupos([]); setValidacoes([]); setSelecionados(new Set()); setFileName(''); }} className="text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-white border border-slate-700 rounded-lg px-3 py-1.5 active:scale-95">Trocar arquivo</button>
              </div>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-2">
                <Tile label="Novos" value={resumoPreview.novos} tone="emerald" />
                <Tile label="Reposições" value={resumoPreview.reposicoes} tone="violet" />
                <Tile label="Peças (soma)" value={resumoPreview.totalPecas} tone="slate" />
                <Tile label="Linhas puladas" value={resumoPreview.erros} tone={resumoPreview.erros > 0 ? 'red' : 'slate'} />
              </div>
              <div className="flex items-center gap-2 flex-wrap pt-2">
                <button onClick={() => selecionarTodos('todos')} className="text-[10px] font-black uppercase tracking-widest text-slate-300 bg-slate-800 border border-slate-700 rounded-lg px-3 py-1.5 active:scale-95">✓ Todos ({grupos.length})</button>
                <button onClick={() => selecionarTodos('novos')} className="text-[10px] font-black uppercase tracking-widest text-emerald-300 bg-emerald-950/40 border border-emerald-900/50 rounded-lg px-3 py-1.5 active:scale-95">Só novos ({resumoPreview.novos})</button>
                <button onClick={() => selecionarTodos('reposicoes')} className="text-[10px] font-black uppercase tracking-widest text-violet-300 bg-violet-950/40 border border-violet-900/50 rounded-lg px-3 py-1.5 active:scale-95">Só reposições ({resumoPreview.reposicoes})</button>
                <button onClick={() => setSelecionados(new Set())} className="text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-white border border-slate-700 rounded-lg px-3 py-1.5 active:scale-95">Limpar</button>
                <span className="ml-auto text-[10px] font-black uppercase tracking-widest text-white">{selecionados.size} selecionado(s)</span>
              </div>
            </section>

            {validacoes.length > 0 && (
              <details className="bg-slate-900 rounded-2xl border border-slate-800 shadow-xl p-4" open={resumoPreview.erros > 0}>
                <summary className="cursor-pointer text-[10px] font-black uppercase tracking-widest text-amber-300">
                  Avisos e linhas puladas ({validacoes.length})
                </summary>
                <ul className="mt-3 space-y-1 max-h-60 overflow-y-auto text-[11px] font-mono">
                  {validacoes.map((v, i) => (
                    <li key={i} className={v.tipo === 'erro' ? 'text-red-300' : 'text-amber-300'}>
                      <span className="font-black">{v.tipo === 'erro' ? '✕' : '!'}</span> {v.msg}
                    </li>
                  ))}
                </ul>
              </details>
            )}

            <section className="bg-slate-900 rounded-2xl border border-slate-800 shadow-xl overflow-hidden">
              <div className="divide-y divide-slate-800/60">
                {grupos.map((g) => {
                  const checked = selecionados.has(g.key);
                  const total = Array.from(g.tamanhos.values()).reduce((a, info) => a + info.qtd, 0);
                  const temEan = Array.from(g.tamanhos.values()).some((info) => !!info.ean);
                  return (
                    <label key={g.key} className={`flex items-start gap-3 px-4 py-3 cursor-pointer transition ${checked ? 'bg-slate-900' : 'bg-slate-950/40'}`}>
                      <input type="checkbox" checked={checked} onChange={() => toggleGrupo(g.key)} className="mt-1.5 w-5 h-5 accent-violet-500 shrink-0" />
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 flex-wrap mb-0.5">
                          <span className="text-xs font-black text-white truncate">{g.descricao || '(sem descrição)'}</span>
                          {g.existente_produto_id
                            ? <span className="text-[8px] font-black uppercase px-1.5 py-0.5 rounded bg-violet-950/40 text-violet-300 border border-violet-900/50">reposição</span>
                            : <span className="text-[8px] font-black uppercase px-1.5 py-0.5 rounded bg-emerald-950/40 text-emerald-300 border border-emerald-900/50">novo</span>}
                          {g.cor_origem === 'sufixo-codigo' && <span className="text-[8px] font-black uppercase px-1.5 py-0.5 rounded bg-amber-950/40 text-amber-300 border border-amber-900/50" title="Cor extraída do sufixo do código">cor do código</span>}
                          {temEan && <span className="text-[8px] font-black uppercase px-1.5 py-0.5 rounded bg-sky-950/40 text-sky-300 border border-sky-900/50" title="Pelo menos um tamanho traz EAN">ean</span>}
                        </div>
                        <p className="text-[10px] font-mono text-slate-500 truncate">
                          {g.sku_fornecedor} • {g.cor} • {g.fornecedor} • {formatBRL(g.preco_venda)}
                        </p>
                        <p className="text-[10px] font-mono text-slate-400 mt-0.5">
                          {Array.from(g.tamanhos.entries()).map(([t, info]) => `${t}:${info.qtd}${info.ean ? '🏷' : ''}`).join(' · ')} <span className="text-slate-600">(total {total})</span>
                        </p>
                      </div>
                    </label>
                  );
                })}
              </div>
            </section>
          </>
        )}

        {/* RESULTADO */}
        {resultado && (
          <section className="bg-slate-900 rounded-2xl border border-emerald-900/40 shadow-xl p-6 space-y-4">
            <h2 className="text-sm font-black text-emerald-400 uppercase tracking-widest">Importação concluída</h2>
            <div className="grid grid-cols-3 gap-2">
              <Tile label="Novos" value={resultado.novos} tone="emerald" />
              <Tile label="Reposições" value={resultado.reposicoes} tone="violet" />
              <Tile label="Erros" value={resultado.erros.length} tone={resultado.erros.length > 0 ? 'red' : 'slate'} />
            </div>
            {resultado.erros.length > 0 && (
              <details className="bg-slate-950/60 border border-red-900/40 rounded-xl p-4" open>
                <summary className="cursor-pointer text-[10px] font-black uppercase tracking-widest text-red-300">Erros por item</summary>
                <ul className="mt-2 space-y-1 text-[11px] font-mono text-red-300">
                  {resultado.erros.map((e, i) => <li key={i}>✕ {e.grupo}: {e.msg}</li>)}
                </ul>
              </details>
            )}
            <div className="flex gap-3">
              <Link href={`/cadastro${voltarQS}`} className="flex-1 text-center bg-slate-800 hover:bg-slate-700 text-white py-3 rounded-xl font-black uppercase text-xs tracking-widest">Voltar ao cadastro</Link>
              <button onClick={() => { setGrupos([]); setValidacoes([]); setSelecionados(new Set()); setResultado(null); setFileName(''); }} className="flex-1 bg-violet-600 hover:bg-violet-500 text-white py-3 rounded-xl font-black uppercase text-xs tracking-widest">Importar outra</button>
            </div>
          </section>
        )}
      </main>

      {/* RODAPÉ FIXO: botão importar */}
      {grupos.length > 0 && !resultado && (
        <div className="fixed left-0 right-0 bottom-0 z-30 bg-slate-900/95 backdrop-blur-xl border-t border-slate-800 p-4">
          <div className="max-w-4xl mx-auto flex items-center gap-3">
            {progresso && importando && (
              <div className="flex-1 min-w-0">
                <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
                  <div className="h-full bg-gradient-to-r from-emerald-500 to-violet-500 transition-all" style={{ width: `${(progresso.feitos / Math.max(1, progresso.total)) * 100}%` }} />
                </div>
                <p className="text-[10px] font-mono text-slate-400 mt-1 truncate">{progresso.feitos}/{progresso.total} • {progresso.atual}</p>
              </div>
            )}
            <button
              onClick={importar}
              disabled={importando || selecionados.size === 0}
              className="shrink-0 bg-violet-600 hover:bg-violet-500 disabled:opacity-40 disabled:cursor-not-allowed text-white px-6 py-3 rounded-xl font-black uppercase text-xs tracking-widest shadow-lg transition active:scale-95"
            >
              {importando ? 'Importando...' : `Importar ${selecionados.size}`}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function Tile({ label, value, tone }: { label: string; value: number; tone: 'emerald' | 'violet' | 'slate' | 'red' }) {
  const map = {
    emerald: { bd: 'border-emerald-900/50', fg: 'text-emerald-300', num: 'text-emerald-400' },
    violet: { bd: 'border-violet-900/50', fg: 'text-violet-300', num: 'text-violet-400' },
    slate: { bd: 'border-slate-800', fg: 'text-slate-500', num: 'text-white' },
    red: { bd: 'border-red-900/50', fg: 'text-red-300', num: 'text-red-400' },
  }[tone];
  return (
    <div className={`bg-slate-950 rounded-xl border ${map.bd} px-3 py-2`}>
      <p className={`text-[9px] font-black uppercase tracking-widest ${map.fg}`}>{label}</p>
      <p className={`text-xl font-black ${map.num}`}>{value}</p>
    </div>
  );
}