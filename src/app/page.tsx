// src/app/page.tsx
'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabase } from '../lib/supabase';
import { Html5Qrcode, Html5QrcodeSupportedFormats } from 'html5-qrcode';
import Image from 'next/image';
import { getSignedUrlCached } from '../lib/signedUrlCache';

// --- UTILITÁRIOS ---
function formatBRL(v: any) {
  const n = typeof v === 'number' ? v : Number(v);
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number.isFinite(n) ? n : 0);
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
  } catch (error) {
    console.error('Erro ao extrair caminho da imagem:', url, error);
    return null;
  }
}

type Anchor = { id: string; top: number };

export default function Dashboard() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const [produtos, setProdutos] = useState<any[]>([]);
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const [busca, setBusca] = useState('');
  const [loading, setLoading] = useState(true);

  const [mostrarScanner, setMostrarScanner] = useState(false);
  const [mostrarFiltros, setMostrarFiltros] = useState(false);

  // FILTROS
  const [tamanhosSelecionados, setTamanhosSelecionados] = useState<string[]>([]);
  const [esconderZerados, setEsconderZerados] = useState(false);
  const [fornecedorSelecionado, setFornecedorSelecionado] = useState('');

  const dataFetchedRef = useRef(false);
  const restoredScrollRef = useRef(false);
  const scannerRef = useRef<Html5Qrcode | null>(null);

  // HEADER height (para sticky search não ficar escondida)
  const headerRef = useRef<HTMLElement | null>(null);
  const [headerH, setHeaderH] = useState<number>(104); // fallback

  // Keys (sessionStorage)
  const scrollKey = 'dashboard:scrollY';
  const anchorKey = 'dashboard:anchor';
  const shouldRestoreKey = 'dashboard:shouldRestore';
  const lastQueryKey = 'dashboard:lastQuery';

  // Para evitar re-render/loop e para o cache de assinatura
  const signedMapRef = useRef<Record<string, string>>({});
  useEffect(() => {
    signedMapRef.current = signedMap;
  }, [signedMap]);

  // --- mede altura real do header (robusto em qualquer device / zoom) ---
  useEffect(() => {
    const el = headerRef.current;
    if (!el) return;

    const measure = () => {
      const h = Math.round(el.getBoundingClientRect().height || 104);
      if (h > 0) setHeaderH(h);
    };

    measure();

    const ro = new ResizeObserver(() => measure());
    ro.observe(el);

    window.addEventListener('resize', measure);
    window.addEventListener('orientationchange', measure);

    return () => {
      ro.disconnect();
      window.removeEventListener('resize', measure);
      window.removeEventListener('orientationchange', measure);
    };
  }, []);

  // --- 1) Inicializa filtros a partir da URL (querystring) ---
  useEffect(() => {
    const q = searchParams.get('q') ?? '';
    const sizesRaw = searchParams.get('sizes') ?? '';
    const brand = searchParams.get('brand') ?? '';
    const hideZero = searchParams.get('hideZero') === '1';

    const sizes = sizesRaw
      ? sizesRaw
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean)
      : [];

    setBusca(q);
    setFornecedorSelecionado(brand);
    setEsconderZerados(hideZero);
    setTamanhosSelecionados(sizes);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- 2) Mantém URL sincronizada com filtros/busca ---
  useEffect(() => {
    const params = new URLSearchParams();

    const q = busca.trim();
    if (q) params.set('q', q);

    if (tamanhosSelecionados.length > 0) params.set('sizes', tamanhosSelecionados.join(','));
    if (fornecedorSelecionado) params.set('brand', fornecedorSelecionado);
    if (esconderZerados) params.set('hideZero', '1');

    const qs = params.toString();

    try {
      sessionStorage.setItem(lastQueryKey, qs);
    } catch {}

    const href = qs ? `/?${qs}` : '/';
    router.replace(href);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [busca, tamanhosSelecionados, fornecedorSelecionado, esconderZerados]);

  // --- Auth + fetch ---
  useEffect(() => {
    let mounted = true;
    const init = async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) {
        if (mounted) router.replace('/login');
        return;
      }
      if (!dataFetchedRef.current) {
        dataFetchedRef.current = true;
        fetchProdutos();
      }
    };
    init();
    return () => {
      mounted = false;
    };
  }, [router]);

  async function fetchProdutos() {
    setLoading(true);

    const { data } = await supabase
      .from('produtos')
      .select(
        `
        id, codigo_peca, sku_fornecedor, fornecedor, descricao, cor, foto_url, preco_venda, created_at,
        estoque ( quantidade, codigo_barras, tamanho:tamanhos ( nome, ordem ) )
      `
      )
      .eq('descontinuado', false)
      .order('created_at', { ascending: false });

    if (data) {
      const ordenados = data.map((p: any) => ({
        ...p,
        estoque: p.estoque?.sort((a: any, b: any) => (a.tamanho?.ordem ?? 99) - (b.tamanho?.ordem ?? 99)),
      }));
      setProdutos(ordenados);
    }

    setLoading(false);
  }

  // fingerprint estável para evitar qualquer risco de "deps dinâmico"
  const fotosFingerprint = useMemo(() => produtos.map((p) => p.foto_url || '').join('|'), [produtos]);

  // --- Assinar imagens (private bucket) ---
  useEffect(() => {
    if (produtos.length === 0) return;

    let cancelled = false;

    const carregarImagens = async () => {
      const updates: Record<string, string> = {};

      await Promise.all(
        produtos.map(async (p) => {
          if (!p.foto_url) return;

          // lê do ref (evita precisar colocar signedMap no deps e evita loop)
          if (signedMapRef.current[p.foto_url]) return;

          const signed = await getSignedUrlCached('produtos', p.foto_url, extractPath, 3600);
          if (!cancelled && signed) updates[p.foto_url] = signed;
        })
      );

      if (!cancelled && Object.keys(updates).length > 0) {
        setSignedMap((prev) => ({ ...prev, ...updates }));
      }
    };

    carregarImagens();

    return () => {
      cancelled = true;
    };
  }, [produtos.length, fotosFingerprint]);

  const listaFornecedores = useMemo(() => {
    const set = new Set<string>();
    produtos.forEach((p) => {
      if (p.fornecedor) set.add(p.fornecedor);
    });
    return Array.from(set).sort();
  }, [produtos]);

  // Busca + filtros
  const filtrados = useMemo(() => {
    const q = busca.toLowerCase().trim();
    return produtos.filter((p) => {
      const total = p.estoque?.reduce((acc: number, item: any) => acc + (item.quantidade || 0), 0) || 0;

      const matchTexto =
        !q ||
        p.descricao?.toLowerCase().includes(q) ||
        p.codigo_peca?.toLowerCase().includes(q) ||
        p.cor?.toLowerCase().includes(q) ||
        p.sku_fornecedor?.toLowerCase().includes(q) ||
        p.fornecedor?.toLowerCase().includes(q);

      const matchTamanho =
        tamanhosSelecionados.length === 0 || p.estoque?.some((e: any) => tamanhosSelecionados.includes(e.tamanho?.nome));
      const matchFornecedor = !fornecedorSelecionado || p.fornecedor === fornecedorSelecionado;
      const matchEstoque = esconderZerados ? total > 0 : true;

      return matchTexto && matchTamanho && matchFornecedor && matchEstoque;
    });
  }, [busca, produtos, tamanhosSelecionados, esconderZerados, fornecedorSelecionado]);

  const resetarFiltros = () => {
    setTamanhosSelecionados([]);
    setFornecedorSelecionado('');
    setEsconderZerados(false);
    setBusca('');
  };

  // --- 3) Salvar posição ao sair do dashboard ---
  const saveReturnState = (produtoId?: string) => {
    try {
      sessionStorage.setItem(shouldRestoreKey, '1');
      sessionStorage.setItem(scrollKey, String(window.scrollY));

      if (produtoId) {
        const el = document.getElementById(`produto-${produtoId}`);
        if (el) {
          const top = el.getBoundingClientRect().top;
          const anchor: Anchor = { id: produtoId, top };
          sessionStorage.setItem(anchorKey, JSON.stringify(anchor));
        } else {
          sessionStorage.removeItem(anchorKey);
        }
      } else {
        sessionStorage.removeItem(anchorKey);
      }
    } catch {}
  };

  // --- 4) Restaurar posição ao retornar (uma vez) ---
  useEffect(() => {
    if (restoredScrollRef.current) return;
    if (loading) return;

    const should = (() => {
      try {
        return sessionStorage.getItem(shouldRestoreKey) === '1';
      } catch {
        return false;
      }
    })();

    if (!should) return;

    try {
      const rawAnchor = sessionStorage.getItem(anchorKey);
      if (rawAnchor) {
        const anchor = JSON.parse(rawAnchor) as Partial<Anchor>;
        if (anchor?.id && typeof anchor.top === 'number') {
          const el = document.getElementById(`produto-${anchor.id}`);
          const top = anchor.top;
          if (el) {
            requestAnimationFrame(() => {
              const elTop = el.getBoundingClientRect().top + window.scrollY;
              window.scrollTo(0, Math.max(0, elTop - top));
            });

            restoredScrollRef.current = true;
            sessionStorage.removeItem(shouldRestoreKey);
            return;
          }
        }
      }
    } catch {}

    try {
      const y = Number(sessionStorage.getItem(scrollKey) || '0');
      if (Number.isFinite(y) && y > 0) {
        requestAnimationFrame(() => window.scrollTo(0, y));
      }
    } catch {}

    restoredScrollRef.current = true;
    try {
      sessionStorage.removeItem(shouldRestoreKey);
    } catch {}
  }, [loading]);

  // Query atual (para passar para o item)
  const currentQS = useMemo(() => {
    const params = new URLSearchParams();
    const q = busca.trim();
    if (q) params.set('q', q);
    if (tamanhosSelecionados.length > 0) params.set('sizes', tamanhosSelecionados.join(','));
    if (fornecedorSelecionado) params.set('brand', fornecedorSelecionado);
    if (esconderZerados) params.set('hideZero', '1');
    return params.toString();
  }, [busca, tamanhosSelecionados, fornecedorSelecionado, esconderZerados]);

  // --- SCANNER: start/stop + suporte real a CÓDIGO DE BARRAS (EAN/UPC/Code128) ---
  useEffect(() => {
    if (!mostrarScanner) return;

    const elementId = 'reader-dashboard-direct';
    let cancelled = false;

    const stopAndClear = async (s: Html5Qrcode | null) => {
      if (!s) return;
      try {
        const maybe = s.stop();
        if (maybe && typeof (maybe as any).then === 'function') {
          await (maybe as Promise<void>).catch(() => {});
        }
      } catch {}
      try {
        s.clear(); // clear() é void
      } catch {}
    };

    const start = async () => {
      await new Promise((r) => setTimeout(r, 150));
      if (cancelled) return;

      const el = document.getElementById(elementId);
      if (!el) return;

      // limpa container (evita “já existe um scanner”)
      el.innerHTML = '';

      // encerra scanner anterior, se existir
      await stopAndClear(scannerRef.current);

      const scanner = new Html5Qrcode(elementId);
      scannerRef.current = scanner;

      // Configs otimizadas p/ código de barras
      const config: any = {
        fps: 12,
        qrbox: { width: 320, height: 140 }, // retângulo mais "largo" p/ EAN/Code128
        aspectRatio: 1.777,
        disableFlip: true,
        formatsToSupport: [
          Html5QrcodeSupportedFormats.EAN_13,
          Html5QrcodeSupportedFormats.EAN_8,
          Html5QrcodeSupportedFormats.UPC_A,
          Html5QrcodeSupportedFormats.UPC_E,
          Html5QrcodeSupportedFormats.CODE_128,
          Html5QrcodeSupportedFormats.CODE_39,
          Html5QrcodeSupportedFormats.ITF,
        ],
        // quando disponível, usa BarcodeDetector nativo (melhor e mais rápido em mobile)
        experimentalFeatures: { useBarCodeDetectorIfSupported: true },
      };

      try {
        await scanner.start(
          { facingMode: 'environment' },
          config,
          async (decodedText) => {
            if (cancelled) return;

            const cleaned = String(decodedText || '').trim();
            if (!cleaned) return;

            // seta busca com o código lido
            setBusca(cleaned);

            // fecha e limpa
            setMostrarScanner(false);
            await stopAndClear(scanner);
          },
          () => {}
        );
      } catch (err) {
        console.error('Falha ao iniciar scanner:', err);
      }
    };

    start();

    return () => {
      cancelled = true;
      const s = scannerRef.current;
      stopAndClear(s);
    };
  }, [mostrarScanner]);

  const scannerTips = (
    <div className="mt-4 bg-slate-900/70 border border-slate-800 rounded-2xl p-4">
      <p className="text-[10px] font-black tracking-widest uppercase text-slate-400 mb-2">Dicas p/ leitura</p>
      <ul className="text-xs text-slate-300 space-y-1">
        <li>• Aproxime o código até ocupar boa parte do retângulo.</li>
        <li>• Evite reflexo (incline levemente o celular).</li>
        <li>• Se estiver escuro, acenda a luz do ambiente.</li>
        <li>• Se a câmera demorar a focar, segure 1–2s parado no código.</li>
      </ul>
    </div>
  );

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-44">
      {/* HEADER */}
      <header
        ref={(n) => {
          headerRef.current = n;
        }}
        className="px-6 pt-10 pb-6 bg-slate-950 border-b border-slate-900 flex justify-between items-end sticky top-0 z-50 backdrop-blur-md"
      >
        <div>
          <p className="text-[10px] font-black tracking-[0.3em] text-pink-500 uppercase mb-1">UpFitness App</p>
          <h1 className="text-2xl font-black italic tracking-tighter uppercase">
            ESTOQUE <span className="font-light not-italic text-slate-500 text-lg">HUB</span>
          </h1>
        </div>
        <div className="flex gap-2">
          <button
            onClick={async () => {
              await supabase.auth.signOut();
              router.replace('/login');
            }}
            className="w-12 h-12 bg-slate-900 border border-slate-800 text-white rounded-2xl flex items-center justify-center text-xl shadow-lg active:scale-90 transition-transform"
            aria-label="Sair"
          >
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15m3 0l3-3m0 0l-3-3m3 3H9"
              />
            </svg>
          </button>

          <Link
            href={currentQS ? `/cadastro?${currentQS}` : '/cadastro'}
            onClick={() => saveReturnState()}
            className="w-12 h-12 bg-gradient-to-tr from-pink-600 to-blue-600 text-white rounded-2xl flex items-center justify-center text-2xl shadow-lg shadow-pink-500/20 active:scale-90 transition-transform"
            aria-label="Cadastrar"
          >
            ＋
          </Link>
        </div>
      </header>

      <main className="px-4 pt-0">
        {/* BARRA DE BUSCA FIXA (sticky, sem ficar escondida) */}
        <div
          className="sticky z-[60] -mx-4 px-4 pt-4 pb-4 bg-slate-950/90 backdrop-blur-md border-b border-slate-900"
          style={{
            top: `calc(env(safe-area-inset-top, 0px) + ${headerH}px)`,
          }}
        >
          <div className="relative">
            <input
              type="text"
              placeholder="Buscar por nome, cor, código ou marca..."
              className="w-full pl-5 pr-12 py-4 rounded-2xl bg-slate-900 border border-slate-800 text-white focus:outline-none focus:border-pink-500 transition-all shadow-lg placeholder:text-slate-600 text-sm font-bold"
              value={busca}
              onChange={(e) => setBusca(e.target.value)}
            />
            <button
              onClick={() => setMostrarScanner(true)}
              className="absolute right-4 top-4 text-slate-500 text-xl"
              aria-label="Scanner"
            >
              📷
            </button>
          </div>
        </div>

        {/* LISTA */}
        <div className="space-y-4 pt-4">
          {loading ? (
            <div className="text-center py-20 text-slate-800 font-black animate-pulse uppercase text-xs tracking-widest">Sincronizando...</div>
          ) : filtrados.length === 0 ? (
            <div className="text-center py-20 text-slate-600 font-bold uppercase text-xs tracking-widest flex flex-col items-center gap-2">
              <span className="text-2xl">🤔</span>
              Nenhum item encontrado
              {(busca || tamanhosSelecionados.length > 0 || fornecedorSelecionado || esconderZerados) && (
                <button onClick={resetarFiltros} className="text-pink-500 underline mt-2">
                  Limpar filtros
                </button>
              )}
            </div>
          ) : (
            filtrados.map((produto, idx) => {
              const urlAssinada = produto.foto_url ? signedMap[produto.foto_url] : null;
              const total = produto.estoque?.reduce((acc: number, item: any) => acc + (item.quantidade || 0), 0) || 0;
              const itemHref = currentQS ? `/item/${produto.id}?${currentQS}` : `/item/${produto.id}`;

              return (
                <Link
                  href={itemHref}
                  key={produto.id}
                  id={`produto-${produto.id}`}
                  onClick={() => saveReturnState(produto.id)}
                  onMouseDown={() => saveReturnState(produto.id)}
                  className="bg-slate-900 rounded-[2.5rem] flex overflow-hidden border border-slate-800/50 min-h-[160px] shadow-xl group active:scale-[0.98] transition-all"
                >
                  <div className="w-36 bg-slate-950 relative border-r border-slate-800 flex-shrink-0">
                    {urlAssinada ? (
                      <Image
                        src={urlAssinada}
                        alt={produto.descricao}
                        fill
                        className="object-cover opacity-90 group-hover:opacity-100 transition-opacity"
                        unoptimized
                        // melhora sensação de velocidade p/ primeiros itens
                        priority={idx < 6}
                        onError={(e) => {
                          const target = e.target as HTMLImageElement;
                          target.style.display = 'none';
                          target.parentElement!.innerHTML =
                            '<div class="w-full h-full flex items-center justify-center text-slate-800 text-[10px] font-black uppercase">Erro Foto</div>';
                        }}
                      />
                    ) : (
                      <div className="w-full h-full flex items-center justify-center text-slate-800 text-[10px] font-black uppercase">
                        {produto.foto_url ? 'Carregando...' : 'Sem Foto'}
                      </div>
                    )}
                    <div
                      className={`absolute bottom-4 left-4 px-2.5 py-1 rounded-lg font-black text-[10px] shadow-2xl ${
                        total > 0 ? 'bg-emerald-500 text-white' : 'bg-red-600 text-white'
                      }`}
                    >
                      {total} UN
                    </div>
                  </div>

                  <div className="flex-1 p-6 flex flex-col justify-between min-w-0">
                    <div>
                      <h2 className="font-bold text-slate-100 text-[13px] uppercase line-clamp-2 leading-tight">{produto.descricao}</h2>
                      <p className="text-[10px] text-slate-600 font-bold mt-1 uppercase tracking-wide">
                        {produto.fornecedor || 'Geral'} • {produto.cor}
                      </p>
                    </div>

                    <div className="flex flex-wrap gap-1.5 mt-3">
                      {produto.estoque?.map((item: any, i: number) => (
                        <span
                          key={i}
                          className={`text-[9px] px-2 py-1 rounded-lg font-black border ${
                            item.quantidade > 0
                              ? 'bg-slate-800 border-slate-700 text-slate-300'
                              : 'bg-transparent border-slate-800 text-slate-700 border-dashed'
                          }`}
                        >
                          {item.tamanho?.nome} {item.quantidade > 0 && `· ${item.quantidade}`}
                        </span>
                      ))}
                    </div>

                    <div className="mt-3 flex justify-end items-end">
                      <span className="text-base font-black text-white">{formatBRL(produto.preco_venda)}</span>
                    </div>
                  </div>
                </Link>
              );
            })
          )}
        </div>
      </main>

      {/* FAB FILTRO */}
      <button
        onClick={() => setMostrarFiltros(true)}
        className={`fixed bottom-32 right-6 w-14 h-14 rounded-2xl flex items-center justify-center z-[70] shadow-2xl transition-all active:scale-90 border-2 ${
          tamanhosSelecionados.length > 0 || fornecedorSelecionado || esconderZerados
            ? 'bg-pink-600 border-pink-400 text-white animate-pulse'
            : 'bg-slate-900 border-slate-800 text-slate-400'
        }`}
        aria-label="Filtros"
      >
        <div className="relative">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-6 h-6">
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M12 3c2.755 0 5.455.232 8.083.678.533.09.917.556.917 1.096v1.044a2.25 2.25 0 01-.659 1.591l-5.432 5.432a2.25 2.25 0 00-.659 1.591v2.927a2.25 2.25 0 01-1.244 2.013L9.75 21v-6.568a2.25 2.25 0 00-.659-1.591L3.659 7.409A2.25 2.25 0 013 5.818V4.774c0-.54.384-1.006.917-1.096A48.32 48.32 0 0112 3z"
            />
          </svg>
          {(tamanhosSelecionados.length > 0 || fornecedorSelecionado || esconderZerados) && (
            <div className="absolute -top-2 -right-2 w-4 h-4 bg-blue-500 rounded-full border-2 border-slate-950 text-[8px] flex items-center justify-center font-black">
              !
            </div>
          )}
        </div>
      </button>

      {/* MODAL FILTROS */}
      {mostrarFiltros && (
        <div className="fixed inset-0 z-[110] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4">
          <div className="bg-slate-900 w-full max-w-md rounded-[3rem] border border-slate-800 p-8 shadow-2xl animate-in slide-in-from-bottom-10">
            <div className="flex justify-between items-center mb-10">
              <h3 className="text-xl font-black italic text-pink-500 uppercase tracking-tighter">Filtros</h3>
              <button onClick={() => setMostrarFiltros(false)} className="text-slate-500 font-black text-[10px] uppercase">
                Fechar
              </button>
            </div>

            <div className="space-y-8 mb-10">
              <div>
                <label className="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-4">Marca</label>
                <select
                  className="w-full bg-slate-950 border border-slate-800 rounded-2xl py-4 px-4 text-white font-bold outline-none"
                  value={fornecedorSelecionado}
                  onChange={(e) => setFornecedorSelecionado(e.target.value)}
                >
                  <option value="">Todas</option>
                  {listaFornecedores.map((f) => (
                    <option key={f} value={f}>
                      {f}
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label className="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-4">Grade</label>
                <div className="flex flex-wrap gap-2">
                  {['P', 'M', 'G', 'GG'].map((tam) => {
                    const ativo = tamanhosSelecionados.includes(tam);
                    return (
                      <button
                        key={tam}
                        onClick={() => setTamanhosSelecionados((prev) => (ativo ? prev.filter((t) => t !== tam) : [...prev, tam]))}
                        className={`px-6 py-3 rounded-xl text-xs font-black border-2 transition-all ${
                          ativo ? 'bg-blue-600 border-blue-500 text-white' : 'bg-slate-950 border-slate-800 text-slate-500'
                        }`}
                      >
                        {tam}
                      </button>
                    );
                  })}
                </div>
              </div>

              <button
                onClick={() => setEsconderZerados(!esconderZerados)}
                className={`w-full py-4 rounded-2xl font-black text-[10px] border-2 uppercase tracking-widest ${
                  esconderZerados ? 'bg-pink-600/20 border-pink-500 text-pink-500' : 'bg-slate-950 border-slate-800 text-slate-500'
                }`}
              >
                {esconderZerados ? '🚫 Ocultando Zerados' : '👁️ Mostrar Tudo'}
              </button>
            </div>

            <div className="flex flex-col gap-3">
              <button
                onClick={() => setMostrarFiltros(false)}
                className="w-full bg-gradient-to-r from-pink-600 to-blue-600 text-white py-5 rounded-[2rem] font-black uppercase text-xs tracking-widest shadow-xl shadow-pink-500/20"
              >
                Confirmar Filtros
              </button>
              <button
                onClick={resetarFiltros}
                className="w-full py-4 rounded-[2rem] border border-slate-800 text-slate-500 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors"
              >
                Limpar Tudo
              </button>
            </div>
          </div>
        </div>
      )}

      {/* NAV FLUTUANTE */}
      <div className="fixed bottom-10 left-6 right-6 z-[60]">
        <nav className="bg-slate-900/95 backdrop-blur-2xl border border-white/5 rounded-[2.5rem] h-20 px-6 flex items-center justify-around shadow-2xl">
          <Link href="/" className="flex flex-col items-center gap-1">
            <div className="p-2 rounded-2xl bg-pink-500/20 text-pink-500">
              <span className="text-xl">📦</span>
            </div>
            <span className="text-[9px] font-black text-pink-500 uppercase tracking-widest">ESTOQUE</span>
          </Link>

          <Link href={currentQS ? `/venda?${currentQS}` : '/venda'} onClick={() => saveReturnState()} className="flex flex-col items-center gap-1 opacity-40">
            <div className="p-2">
              <span className="text-xl">🛒</span>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest">VENDA</span>
          </Link>

          <Link
            href={currentQS ? `/historico?${currentQS}` : '/historico'}
            onClick={() => saveReturnState()}
            className="flex flex-col items-center gap-1 opacity-40"
          >
            <div className="p-2">
              <span className="text-xl">📊</span>
            </div>
            <span className="text-[9px] font-black text-white tracking-widest uppercase">Histórico</span>
          </Link>
        </nav>
      </div>

      {/* SCANNER */}
      {mostrarScanner && (
        <div className="fixed inset-0 z-[120] bg-slate-950 flex flex-col p-6 animate-in slide-in-from-bottom">
          <div className="flex justify-between items-center mb-6 pt-6 px-4">
            <h3 className="font-black text-[10px] uppercase text-pink-500 italic tracking-widest">Leitor de Código</h3>
            <button
              onClick={() => setMostrarScanner(false)}
              className="text-white bg-slate-800 px-6 py-2 rounded-full text-[10px] font-black uppercase"
            >
              Voltar
            </button>
          </div>

          <div className="rounded-[2rem] overflow-hidden bg-black border-2 border-pink-500/30 shadow-2xl shadow-pink-500/10">
            <div id="reader-dashboard-direct" className="h-[65vh] w-full" />
          </div>

          {scannerTips}

          {/* fallback manual */}
          <div className="mt-4">
            <label className="text-[10px] font-black tracking-widest uppercase text-slate-500 block mb-2">Digitar / Colar código</label>
            <input
              value={busca}
              onChange={(e) => setBusca(e.target.value)}
              className="w-full bg-slate-900 border border-slate-800 rounded-2xl py-4 px-4 text-white font-bold outline-none"
              placeholder="Ex: 789..."
            />
          </div>
        </div>
      )}
    </div>
  );
}