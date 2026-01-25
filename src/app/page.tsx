'use client';

import { useEffect, useMemo, useState, useRef } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode'; // Mudamos para o Motor Puro (Igual ao Cadastro)

// --- UTILITÁRIOS ---
function formatBRL(v: any) {
  const n = typeof v === 'number' ? v : Number(v);
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number.isFinite(n) ? n : 0);
}

function getTamanhoNome(item: any) {
    const t = item.tamanho;
    if (!t) return '?';
    if (Array.isArray(t)) return t[0]?.nome ?? '?';
    return t.nome ?? '?';
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

  // Controle
  const dataFetchedRef = useRef(false);
  const scannerRef = useRef<Html5Qrcode | null>(null); // Referência para controle da câmera

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
              id, codigo_peca, descricao, preco_venda, created_at,
              produto_cores (
                id, foto_url,
                cor:cores ( nome ),
                estoque ( quantidade, codigo_barras, tamanho:tamanhos ( nome ) )
              )
            `)
          .order('created_at', { ascending: false })
          .limit(100);

        if (error) throw error;
        setProdutos(data || []);
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
      produtos.forEach(p => p.produto_cores?.forEach((pc: any) => {
          if (pc.foto_url && !signedMap[pc.foto_url]) paths.add(pc.foto_url);
      }));
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

  // --- 4. SCANNER TURBO (Igual ao Cadastro) ---
  useEffect(() => {
    if (mostrarScanner) {
        const elementId = "reader-dashboard-direct";
        const t = setTimeout(() => {
            if (!document.getElementById(elementId)) return;

            // Instancia Motor Puro
            const html5QrCode = new Html5Qrcode(elementId);
            scannerRef.current = html5QrCode;

            html5QrCode.start(
                { facingMode: "environment" }, // Câmera Traseira Direta
                { 
                    fps: 30, 
                    qrbox: { width: 250, height: 100 }, // Área Retangular
                    aspectRatio: 1.0 
                },
                (decodedText) => {
                    playBeep();
                    console.log("Lido:", decodedText);
                    setBusca(decodedText); 
                    fecharScanner();
                },
                (errorMessage) => { 
                    // Ignora erros de frame vazio para não sujar o console
                }
            ).catch(err => {
                console.error("Erro ao iniciar câmera:", err);
                setMostrarScanner(false);
            });
        }, 300);
        return () => clearTimeout(t);
    }
  }, [mostrarScanner]);

  // Função para fechar corretamente
  const fecharScanner = async () => {
      if (scannerRef.current) {
          try {
            if (scannerRef.current.isScanning) {
                await scannerRef.current.stop();
            }
            scannerRef.current.clear();
          } catch (e) { console.log(e); }
      }
      setMostrarScanner(false);
  };

  const filtrados = useMemo(() => {
    const q = busca.trim().toLowerCase();
    if (!q) return produtos;
    return produtos.filter(p => {
      const d = (p.descricao||'').toLowerCase();
      const c = (p.codigo_peca||'').toLowerCase();
      const ean = p.produto_cores?.some((pc: any) => pc.estoque?.some((e: any) => e.codigo_barras?.toLowerCase().includes(q)));
      return d.includes(q) || c.includes(q) || ean;
    });
  }, [busca, produtos]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans">
      
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-4 md:p-6 shadow-2xl mb-6 flex flex-col md:flex-row justify-between items-center sticky top-0 z-50 gap-4 transition-all">
        <div className="flex flex-col items-center md:items-start w-full md:w-auto">
            <h1 className="font-black italic text-xl tracking-tighter text-center md:text-left">
            UPFITNESS <span className="font-light tracking-normal text-white/80">DASHBOARD</span>
            </h1>
        </div>

        <div className="grid grid-cols-3 gap-2 w-full md:w-auto md:flex">
          <Link href="/cadastro" className="bg-white text-pink-600 py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-black hover:scale-105 active:scale-95 transition-transform shadow-xl uppercase tracking-widest flex items-center justify-center text-center">
            + NOVO
          </Link>
          <Link href="/venda" className="bg-emerald-500 text-white py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-black hover:scale-105 active:scale-95 transition-transform shadow-xl uppercase tracking-widest flex items-center justify-center gap-1 text-center">
             <span className="text-sm">🛒</span> PDV
          </Link>
          <button type="button" onClick={async () => { await supabase.auth.signOut(); router.replace('/login'); }} className="bg-black/30 py-3 md:py-2 px-3 md:px-5 rounded-xl md:rounded-full text-[10px] font-bold tracking-widest border border-white/10 hover:bg-black/40 text-white active:scale-95 transition-transform flex items-center justify-center">
            SAIR
          </button>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 pb-24">
        
        <div className="flex gap-2 mb-8 relative z-40">
            <div className="relative flex-1 group">
                <div className="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none text-slate-400">
                    <span className="text-xl">🔍</span>
                </div>
                <input
                    type="text"
                    placeholder="Buscar nome, código ou EAN..."
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

        {loading ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 opacity-50 animate-pulse">
            <div className="w-12 h-12 border-4 border-pink-500 border-t-transparent rounded-full animate-spin"></div>
            <p className="text-xs font-black tracking-widest text-pink-500">CARREGANDO ESTOQUE...</p>
          </div>
        ) : filtrados.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 text-slate-500">
             <span className="text-4xl">📦</span>
             <p className="font-bold text-sm">Nenhum produto encontrado.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 md:gap-6">
            {filtrados.map((produto) => {
              const cores = produto.produto_cores ?? [];
              const pathFotoPrincipal = cores.find((c: any) => c.foto_url)?.foto_url;
              const urlAssinada = pathFotoPrincipal ? signedMap[pathFotoPrincipal] : null;
              const totalPeca = cores.reduce((acc: number, curr: any) => acc + (curr.estoque?.reduce((a: number, b: any) => a + (b.quantidade||0), 0) || 0), 0);

              return (
                <Link
                  href={`/item/${produto.id}`}
                  key={produto.id}
                  className="bg-slate-900 rounded-2xl overflow-hidden border border-slate-800 shadow-lg hover:shadow-2xl hover:border-pink-500/30 active:scale-[0.98] transition-all flex flex-row h-auto min-h-[120px] group cursor-pointer"
                >
                  <div className="w-24 bg-slate-950 relative flex-shrink-0 border-r border-slate-800">
                    {urlAssinada ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={urlAssinada} className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity" alt="Foto" loading="lazy" />
                    ) : (
                      <div className="w-full h-full flex flex-col items-center justify-center text-slate-700 bg-slate-950/50">
                        {pathFotoPrincipal ? <div className="w-5 h-5 border-2 border-slate-600 border-t-transparent rounded-full animate-spin"></div> : <span className="text-2xl opacity-30">📷</span>}
                      </div>
                    )}
                    <div className="absolute bottom-0 left-0 right-0 bg-black/80 backdrop-blur-sm p-1 text-center">
                        <span className="text-[9px] font-black text-white tracking-widest font-mono block truncate">{produto.codigo_peca}</span>
                    </div>
                  </div>

                  <div className="flex-1 p-3 flex flex-col justify-between min-w-0">
                    <div className="flex justify-between items-start gap-2">
                        <h2 className="font-bold text-slate-200 text-xs leading-tight uppercase line-clamp-2">
                          {produto.descricao}
                        </h2>
                        <span className="text-[10px] font-black text-emerald-400 bg-emerald-950/30 px-1.5 py-0.5 rounded-md whitespace-nowrap">
                            {formatBRL(produto.preco_venda)}
                        </span>
                    </div>

                    <div className="space-y-1.5 mt-2 flex-1">
                        {cores.slice(0, 2).map((pc: any) => {
                            const estoque = pc.estoque || [];
                            if (estoque.length === 0) return null;
                            const urlCor = pc.foto_url ? signedMap[pc.foto_url] : null;

                            return (
                                <div key={pc.id} className="flex items-center gap-2">
                                    <div className="w-2 h-2 rounded-full bg-pink-500 overflow-hidden border border-white/20 shrink-0">
                                        {urlCor && (
                                            // eslint-disable-next-line @next/next/no-img-element
                                            <img src={urlCor} className="w-full h-full object-cover" alt="" />
                                        )}
                                    </div>
                                    <div className="flex flex-wrap gap-1">
                                        {estoque.map((item: any, i: number) => (
                                            <span key={i} className={`text-[8px] font-bold px-1.5 py-0.5 rounded border ${
                                                (item.quantidade||0) > 0 
                                                ? 'bg-slate-800 border-slate-700 text-slate-300' 
                                                : 'bg-red-950/20 border-red-900/30 text-red-500 opacity-50'
                                            }`}>
                                                {getTamanhoNome(item)} <span className="text-white/50">x{item.quantidade}</span>
                                            </span>
                                        ))}
                                    </div>
                                </div>
                            );
                        })}
                    </div>

                    <div className="mt-1 pt-1 border-t border-slate-800 flex justify-end">
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

      {mostrarScanner && (
            <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
                <div className="w-full max-w-sm bg-slate-900 p-6 rounded-3xl border border-slate-800 shadow-2xl relative">
                    <h3 className="text-center font-black uppercase text-white mb-4 text-sm">BUSCAR PRODUTO</h3>
                    <div id="reader-dashboard-direct" className="w-full rounded-2xl overflow-hidden border-2 border-pink-500 bg-black h-64"></div>
                    <p className="text-center text-[10px] text-slate-500 mt-2">Aponte para o código de barras.</p>
                    <button onClick={fecharScanner} className="mt-4 w-full bg-slate-800 text-white py-4 rounded-xl font-bold uppercase tracking-widest text-xs active:scale-95">Fechar</button>
                </div>
            </div>
      )}
    </div>
  );
}