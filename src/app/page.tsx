'use client';

import { useEffect, useMemo, useState, useRef } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode';
import Image from 'next/image';

// --- UTILITÁRIOS ---
function formatBRL(v: any) {
  const n = typeof v === 'number' ? v : Number(v);
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number.isFinite(n) ? n : 0);
}

function extractPath(url: string | null) {
    if (!url) return null;
    try {
        if (url.startsWith('http')) {
            const urlObj = new URL(url);
            const pathParts = urlObj.pathname.split('/produtos/');
            if (pathParts.length > 1) return decodeURIComponent(pathParts[1]);
        }
        return url;
    } catch { return url; }
}

const playBeep = () => {
    const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3'); 
    audio.volume = 0.5;
    audio.play().catch(() => {});
    if (typeof window !== 'undefined' && window.navigator && window.navigator.vibrate) {
        window.navigator.vibrate(50); 
    }
};

export default function Dashboard() {
  const router = useRouter();
  
  // --- ESTADOS ---
  const [produtos, setProdutos] = useState<any[]>([]);
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const [busca, setBusca] = useState('');
  const [loading, setLoading] = useState(true);
  const [mostrarScanner, setMostrarScanner] = useState(false);
  
  // NOVO: Estado para os filtros de tamanho
  const [tamanhosSelecionados, setTamanhosSelecionados] = useState<string[]>([]);

  // Controle
  const dataFetchedRef = useRef(false);
  const scannerRef = useRef<Html5Qrcode | null>(null);

  // 1. INICIALIZAÇÃO
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
        await fetchProdutos();
      }
    };
    init();
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
        if (event === 'SIGNED_OUT') router.replace('/login');
    });
    return () => { mounted = false; subscription.unsubscribe(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 2. BUSCA
  async function fetchProdutos() {
    setLoading(true);
    try {
        const { data, error } = await supabase
          .from('produtos')
          .select(`
              id, codigo_peca, sku_fornecedor, descricao, cor, foto_url, preco_venda, created_at,
              estoque ( quantidade, codigo_barras, tamanho:tamanhos ( nome, ordem ) )
            `)
          .eq('descontinuado', false)
          .order('created_at', { ascending: false })
          .limit(1000);

        if (error) throw error;
        
        // Ordenar estoque internamente
        const produtosOrdenados = data?.map(p => ({
            ...p,
            estoque: p.estoque?.sort((a: any, b: any) => (a.tamanho?.ordem ?? 99) - (b.tamanho?.ordem ?? 99))
        }));

        setProdutos(produtosOrdenados || []);
    } catch (err) {
        console.error('Erro produtos:', err);
    } finally {
        setLoading(false);
    }
  }

  // 3. IMAGENS
  useEffect(() => {
    if (produtos.length === 0) return;
    const carregarImagens = async () => {
      const paths = new Set<string>();
      produtos.forEach(p => {
          if (p.foto_url && !signedMap[p.foto_url]) paths.add(p.foto_url);
      });
      if (paths.size === 0) return;
      
      const updates: Record<string, string> = {};
      await Promise.allSettled(Array.from(paths).map(async (url) => {
          const path = extractPath(url);
          if (path) {
              const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 3600);
              if (data?.signedUrl) updates[url] = data.signedUrl;
          }
      }));
      setSignedMap(prev => ({ ...prev, ...updates }));
    };
    carregarImagens();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [produtos]); 

  // --- SCANNER ---
  useEffect(() => {
    if (mostrarScanner) {
        const elementId = "reader-dashboard-direct";
        const t = setTimeout(() => {
            if (!document.getElementById(elementId)) return;
            const html5QrCode = new Html5Qrcode(elementId);
            scannerRef.current = html5QrCode;
            html5QrCode.start(
                { facingMode: "environment" },
                { fps: 25, qrbox: { width: 250, height: 150 }, aspectRatio: 1.0 },
                (decodedText) => {
                    playBeep();
                    setBusca(decodedText); 
                    fecharScanner();
                },
                (errorMessage) => {}
            ).catch(err => {
                console.error("Erro câmera:", err);
                setMostrarScanner(false);
            });
        }, 300);
        return () => clearTimeout(t);
    }
  }, [mostrarScanner]);

  const fecharScanner = async () => {
      if (scannerRef.current) {
          try { if (scannerRef.current.isScanning) await scannerRef.current.stop(); scannerRef.current.clear(); } catch (e) {}
      }
      setMostrarScanner(false);
  };

  // --- LOGICA DE FILTROS ---

  // 1. Extrair tamanhos únicos disponíveis nos produtos carregados
  const tamanhosDisponiveis = useMemo(() => {
      const map = new Map<string, number>();
      produtos.forEach(p => {
          p.estoque?.forEach((e: any) => {
              if (e.tamanho?.nome && !map.has(e.tamanho.nome)) {
                  map.set(e.tamanho.nome, e.tamanho.ordem ?? 999);
              }
          });
      });
      // Retorna array ordenado pela ordem do tamanho
      return Array.from(map.entries()).sort((a, b) => a[1] - b[1]).map(x => x[0]);
  }, [produtos]);

  const toggleTamanho = (tam: string) => {
      setTamanhosSelecionados(prev => 
          prev.includes(tam) ? prev.filter(t => t !== tam) : [...prev, tam]
      );
  };

  // 2. Filtro Combinado (Texto + Tamanhos)
  const filtrados = useMemo(() => {
    const q = busca.trim().toLowerCase();
    
    return produtos.filter(p => {
      // 1. Filtro de Texto
      const d = (p.descricao||'').toLowerCase();
      const c = (p.codigo_peca||'').toLowerCase();
      const sku = (p.sku_fornecedor||'').toLowerCase();
      const cor = (p.cor||'').toLowerCase();
      const ean = p.estoque?.some((e: any) => e.codigo_barras?.toLowerCase().includes(q));
      
      const matchTexto = !q || d.includes(q) || c.includes(q) || sku.includes(q) || cor.includes(q) || ean;

      // 2. Filtro de Tamanho (Se houver algum selecionado)
      let matchTamanho = true;
      if (tamanhosSelecionados.length > 0) {
          // O produto deve ter pelo menos um item de estoque cujo tamanho esteja na lista de selecionados
          matchTamanho = p.estoque?.some((e: any) => tamanhosSelecionados.includes(e.tamanho?.nome));
      }

      return matchTexto && matchTamanho;
    });
  }, [busca, produtos, tamanhosSelecionados]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans">
      
      {/* HEADER */}
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-4 md:p-6 shadow-2xl mb-4 flex flex-col md:flex-row justify-between items-center sticky top-0 z-50 gap-4 transition-all">
        <div className="flex flex-col items-center md:items-start w-full md:w-auto">
            <h1 className="font-black italic text-xl tracking-tighter text-center md:text-left">
            UPFITNESS <span className="font-light tracking-normal text-white/80">Estoque</span>
            </h1>
        </div>
        <div className="grid grid-cols-3 gap-2 w-full md:w-auto md:flex">
          <Link href="/cadastro" className="bg-white text-pink-600 py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-black hover:scale-105 active:scale-95 transition-transform shadow-xl uppercase tracking-widest flex items-center justify-center text-center">
            + NOVO
          </Link>
          <Link href="/venda" className="bg-emerald-500 text-white py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-black hover:scale-105 active:scale-95 transition-transform shadow-xl uppercase tracking-widest flex items-center justify-center gap-1 text-center">
             <span className="text-sm">🛒</span> PDV
          </Link>
          <Link href="/historico" className="bg-slate-700 text-white py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-black hover:scale-105 active:scale-95 transition-transform shadow-xl uppercase tracking-widest flex items-center justify-center gap-1 text-center">
            <span className="text-sm">📅</span> HIST
          </Link>
          <button type="button" onClick={async () => { await supabase.auth.signOut(); router.replace('/login'); }} className="bg-black/30 py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-bold tracking-widest border border-white/10 hover:bg-black/40 text-white active:scale-95 transition-transform flex items-center justify-center">
            SAIR
          </button>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 pb-24">
        
        {/* BARRA DE BUSCA */}
        <div className="flex gap-2 mb-4 relative z-40">
            <div className="relative flex-1 group">
                <div className="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none text-slate-400">
                    <span className="text-xl">🔍</span>
                </div>
                <input
                    type="text"
                    placeholder="Buscar nome, código, SKU..."
                    className="w-full pl-12 pr-4 py-4 rounded-2xl bg-slate-900 border border-slate-800 text-white focus:border-pink-500 outline-none shadow-xl transition-all font-bold text-base md:text-sm group-hover:bg-slate-800"
                    value={busca}
                    onChange={(e) => setBusca(e.target.value)}
                />
            </div>
            <button 
                onClick={() => setMostrarScanner(true)}
                className="bg-slate-800 hover:bg-slate-700 text-white w-14 rounded-2xl flex items-center justify-center text-2xl border border-slate-800 hover:border-pink-500 transition-all shadow-xl active:scale-95"
            >
                📷
            </button>
        </div>

        {/* --- FILTRO DE TAMANHOS (SCROLL HORIZONTAL) --- */}
        {!loading && tamanhosDisponiveis.length > 0 && (
            <div className="mb-6 overflow-x-auto pb-2 no-scrollbar -mx-4 px-4 md:mx-0 md:px-0">
                <div className="flex gap-2 w-max">
                    {/* Botão Limpar Filtro */}
                    {tamanhosSelecionados.length > 0 && (
                        <button 
                            onClick={() => setTamanhosSelecionados([])}
                            className="bg-red-900/30 text-red-400 border border-red-500/30 px-4 py-2 rounded-xl text-xs font-black uppercase whitespace-nowrap active:scale-95 transition-all flex items-center gap-1"
                        >
                            ✕ Limpar
                        </button>
                    )}
                    
                    {/* Lista de Tamanhos */}
                    {tamanhosDisponiveis.map(tam => {
                        const ativo = tamanhosSelecionados.includes(tam);
                        return (
                            <button
                                key={tam}
                                onClick={() => toggleTamanho(tam)}
                                className={`
                                    px-5 py-2 rounded-xl text-xs font-black uppercase whitespace-nowrap shadow-md transition-all active:scale-95 border
                                    ${ativo 
                                        ? 'bg-pink-600 border-pink-500 text-white scale-105 shadow-pink-900/50' 
                                        : 'bg-slate-900 border-slate-800 text-slate-400 hover:bg-slate-800 hover:text-white hover:border-slate-600'
                                    }
                                `}
                            >
                                {tam}
                            </button>
                        );
                    })}
                </div>
            </div>
        )}

        {/* LISTAGEM DE PRODUTOS */}
        {loading ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 opacity-50 animate-pulse">
            <div className="w-12 h-12 border-4 border-pink-500 border-t-transparent rounded-full animate-spin"></div>
            <p className="text-xs font-black tracking-widest text-pink-500">CARREGANDO ESTOQUE...</p>
          </div>
        ) : filtrados.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 text-slate-500">
             <span className="text-4xl">📦</span>
             <p className="font-bold text-sm">Nenhum produto encontrado.</p>
             {tamanhosSelecionados.length > 0 && (
                 <button onClick={() => setTamanhosSelecionados([])} className="text-pink-500 text-xs font-bold underline">Limpar filtros de tamanho</button>
             )}
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 md:gap-6">
            {filtrados.map((produto) => {
              const urlAssinada = produto.foto_url ? signedMap[produto.foto_url] : null;
              const totalPeca = produto.estoque?.reduce((acc: number, item: any) => acc + (item.quantidade || 0), 0) || 0;

              return (
                <Link
                  href={`/item/${produto.id}`}
                  key={produto.id}
                  className="bg-slate-900 rounded-2xl overflow-hidden border border-slate-800 shadow-lg hover:shadow-2xl hover:border-pink-500/30 active:scale-[0.98] transition-all flex flex-row h-auto min-h-[120px] group cursor-pointer"
                >
                  {/* FOTO E CÓDIGO */}
                  <div className="w-28 bg-slate-950 relative flex-shrink-0 border-r border-slate-800">
                    {urlAssinada ? (
                      <Image 
                        src={urlAssinada} 
                        alt={produto.descricao || 'Produto'}
                        width={250} 
                        height={250}
                        className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity"
                        unoptimized={false}
                      />
                    ) : (
                      <div className="w-full h-full flex flex-col items-center justify-center text-slate-700 bg-slate-950/50">
                        <span className="text-2xl opacity-30">📷</span>
                      </div>
                    )}
                    <div className="absolute bottom-0 left-0 right-0 bg-black/80 backdrop-blur-sm p-1 text-center">
                        <span className="text-[9px] font-black text-white tracking-widest font-mono block truncate">{produto.codigo_peca}</span>
                        {produto.sku_fornecedor && <span className="text-[8px] font-bold text-slate-400 font-mono block truncate">{produto.sku_fornecedor}</span>}
                    </div>
                  </div>

                  {/* DADOS */}
                  <div className="flex-1 p-3 flex flex-col justify-between min-w-0">
                    <div className="flex justify-between items-start gap-2">
                        <h2 className="font-bold text-slate-200 text-xs leading-tight uppercase line-clamp-2">
                          {produto.descricao}
                        </h2>
                        <span className="text-[10px] font-black text-emerald-400 bg-emerald-950/30 px-1.5 py-0.5 rounded-md whitespace-nowrap">
                            {formatBRL(produto.preco_venda)}
                        </span>
                    </div>

                    <div className="mt-1 mb-2">
                        <span className="text-[10px] font-bold text-slate-400 bg-slate-800 px-2 py-0.5 rounded-full inline-block">
                           Cor: <span className="text-white">{produto.cor || '?'}</span>
                        </span>
                    </div>

                    {/* GRADE DE TAMANHOS (Destaca os selecionados no filtro) */}
                    <div className="flex-1 flex flex-wrap content-start gap-1">
                        {produto.estoque?.map((item: any, i: number) => {
                            const isSelected = tamanhosSelecionados.includes(item.tamanho?.nome);
                            return (
                                <span key={i} className={`text-[8px] font-bold px-1.5 py-0.5 rounded border transition-colors ${
                                    isSelected 
                                    ? 'bg-pink-600 border-pink-500 text-white shadow-sm' // Destaque se filtrado
                                    : (item.quantidade||0) > 0 
                                        ? 'bg-slate-800 border-slate-700 text-slate-300' 
                                        : 'bg-red-950/20 border-red-900/30 text-red-500 opacity-50'
                                }`}>
                                    {item.tamanho?.nome} <span className={isSelected ? 'text-white' : 'text-white/50'}>x{item.quantidade}</span>
                                </span>
                            );
                        })}
                    </div>

                    <div className="mt-2 pt-1 border-t border-slate-800 flex justify-between items-center">
                         <span className="text-[8px] font-bold text-slate-500">
                             {produto.sku_fornecedor ? 'SKU: ' + produto.sku_fornecedor : ''}
                         </span>
                        <span className={`text-[9px] font-black ${totalPeca > 0 ? 'text-slate-400' : 'text-red-500'}`}>
                            Total: <span className="text-white">{totalPeca} un</span>
                        </span>
                    </div>
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </main>

      {/* MODAL SCANNER */}
      {mostrarScanner && (
            <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
                <div className="w-full max-w-sm bg-slate-900 p-6 rounded-3xl border border-slate-800 shadow-2xl relative">
                    <h3 className="text-center font-black uppercase text-white mb-4 text-sm">Aponte para o Código</h3>
                    <div id="reader-dashboard-direct" className="w-full rounded-2xl overflow-hidden border-2 border-pink-500 bg-black h-64"></div>
                    <button onClick={fecharScanner} className="mt-4 w-full bg-slate-800 text-white py-4 rounded-xl font-bold uppercase tracking-widest text-xs active:scale-95">Fechar</button>
                </div>
            </div>
      )}
    </div>
  );
}