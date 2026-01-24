'use client';

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '../lib/supabase';

// --- TIPAGENS ---
type CorEmbed = { nome: string | null };
type TamanhoEmbed = { nome: string | null };

type EstoqueItem = {
  quantidade: number | null;
  tamanho: TamanhoEmbed | null;
};

type ProdutoCor = {
  id: string;
  foto_url: string | null;
  cor: CorEmbed | null;
  estoque: EstoqueItem[] | null;
};

type Produto = {
  id: string;
  codigo_peca: string | null;
  descricao: string | null;
  preco_venda: string | number | null;
  produto_cores?: ProdutoCor[] | null;
  created_at?: string;
};

// --- UTILITÁRIOS ---
function toNumber(v: string | number | null | undefined) {
  if (v == null) return 0;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function formatBRL(v: string | number | null | undefined) {
  const n = toNumber(v);
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(n);
}

function getCorNome(pc: ProdutoCor) {
  // @ts-ignore
  const c = pc.cor; 
  if (!c) return 'Única';
  if (Array.isArray(c)) return c[0]?.nome ?? 'Única';
  return (c as any).nome ?? 'Única';
}

function getTamanhoNome(item: EstoqueItem) {
    // @ts-ignore
    const t = item.tamanho;
    if (!t) return '?';
    if (Array.isArray(t)) return t[0]?.nome ?? '?';
    return (t as any).nome ?? '?';
}

// Extrai o caminho relativo (path) caso a URL salva seja absoluta
function extractPath(url: string | null) {
    if (!url) return null;
    // Se for URL completa do Supabase, pega só o final depois de /produtos/
    if (url.startsWith('http')) {
        const parts = url.split('/produtos/');
        if (parts.length > 1) return parts[1]; // Retorna "id/cor/arquivo.jpg"
    }
    return url; // Retorna como está se já for relativo
}

export default function Dashboard() {
  const router = useRouter();
  const [produtos, setProdutos] = useState<Produto[]>([]);
  const [busca, setBusca] = useState('');
  const [loading, setLoading] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  
  // Mapa de URLs Assinadas: Chave = URL Original (do banco), Valor = URL Assinada (do Storage)
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});

  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u?.user) {
        router.replace('/login');
        return;
      }
      await fetchProdutos();
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function fetchProdutos() {
    setLoading(true);
    setErro(null);

    const { data, error } = await supabase
      .from('produtos')
      .select(`
          id,
          codigo_peca,
          descricao,
          preco_venda,
          created_at,
          produto_cores (
            id,
            foto_url,
            cor:cores ( nome ),
            estoque ( 
                quantidade,
                tamanho:tamanhos ( nome ) 
            )
          )
        `)
      .order('created_at', { ascending: false });

    if (error) {
      setErro(error.message);
      setProdutos([]);
    } else {
      setProdutos(((data ?? []) as unknown) as Produto[]);
    }
    setLoading(false);
  }

  // --- GERAÇÃO DE URLs ASSINADAS (SECURE) ---
  useEffect(() => {
    if (produtos.length === 0) return;

    (async () => {
      const pathsParaAssinar = new Set<string>();
      
      // 1. Coleta todas as URLs originais que precisam de assinatura
      produtos.forEach(p => {
        p.produto_cores?.forEach(pc => {
            if (pc.foto_url && !signedMap[pc.foto_url]) {
                pathsParaAssinar.add(pc.foto_url);
            }
        });
      });

      if (pathsParaAssinar.size === 0) return;

      const newSignedUrls: Record<string, string> = {};

      // 2. Gera assinatura para cada uma
      for (const originalUrl of Array.from(pathsParaAssinar)) {
          const pathReal = extractPath(originalUrl); // Limpa a URL para pegar só o path
          
          if (pathReal) {
              // Cria URL válida por 1 hora (3600 segundos)
              const { data, error } = await supabase.storage
                  .from('produtos')
                  .createSignedUrl(pathReal, 3600);
              
              if (!error && data?.signedUrl) {
                  // Mapeia: URL do Banco -> URL Temporária Segura
                  newSignedUrls[originalUrl] = data.signedUrl;
              }
          }
      }

      // 3. Atualiza o estado apenas se houver novas URLs
      if (Object.keys(newSignedUrls).length > 0) {
          setSignedMap(prev => ({ ...prev, ...newSignedUrls }));
      }
    })();
  }, [produtos, signedMap]); // Roda sempre que produtos mudar ou signedMap mudar

  const produtosFiltrados = useMemo(() => {
    const q = busca.trim().toLowerCase();
    if (!q) return produtos;

    return produtos.filter((p) => {
      const desc = (p.descricao ?? '').toLowerCase();
      const cod = (p.codigo_peca ?? '').toLowerCase();
      return desc.includes(q) || cod.includes(q);
    });
  }, [busca, produtos]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans">
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-6 shadow-2xl mb-8 flex justify-between items-center sticky top-0 z-50">
        <h1 className="font-black italic text-xl tracking-tighter">
          UPFITNESS <span className="font-light tracking-normal text-white/80">DASHBOARD</span>
        </h1>

        <div className="flex items-center gap-3">
          <Link
            href="/cadastro"
            className="bg-white text-pink-600 px-5 py-2 rounded-full text-[10px] font-black hover:scale-105 transition-transform shadow-xl uppercase tracking-widest"
          >
            + Novo Item
          </Link>

          <Link
            href="/venda"
            className="bg-emerald-500 text-white px-5 py-2 rounded-full text-[10px] font-black hover:scale-105 transition-transform shadow-xl uppercase tracking-widest flex items-center gap-2"
          >
  <span>🛒</span> Nova Venda
</Link>

          <button
            type="button"
            onClick={async () => {
              await supabase.auth.signOut();
              router.replace('/login');
            }}
            className="bg-black/30 px-5 py-2 rounded-full text-[10px] font-bold tracking-widest border border-white/10 hover:bg-black/40 text-white"
          >
            SAIR
          </button>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 pb-20">
        {/* BARRA DE BUSCA */}
        <div className="relative mb-10 group">
            <div className="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none">
                <span className="text-xl">🔍</span>
            </div>
            <input
            type="text"
            placeholder="Buscar por nome, código..."
            className="w-full pl-12 pr-5 py-4 rounded-2xl bg-slate-900 border border-slate-800 text-white focus:border-pink-500 outline-none shadow-xl transition-all font-bold text-sm group-hover:bg-slate-800"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            />
        </div>

        {erro && (
          <div className="mb-8 rounded-2xl bg-red-950/30 border border-red-900/50 p-6 text-sm text-red-200 font-bold">
            ⚠️ Ocorreu um erro ao carregar: {erro}
          </div>
        )}

        {loading ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 opacity-50 animate-pulse">
            <div className="w-12 h-12 border-4 border-pink-500 border-t-transparent rounded-full animate-spin"></div>
            <p className="text-xs font-black tracking-widest text-pink-500">CARREGANDO ESTOQUE...</p>
          </div>
        ) : produtosFiltrados.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 gap-4 text-slate-500">
             <span className="text-4xl">📦</span>
             <p className="font-bold text-sm">Nenhum produto encontrado.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
            {produtosFiltrados.map((produto) => {
              const cores = produto.produto_cores ?? [];
              // Pega a primeira foto disponível
              const pathFotoPrincipal = cores.find((c) => c.foto_url)?.foto_url;
              
              // Tenta pegar a URL assinada do mapa. Se não tiver ainda, usa null.
              const urlAssinada = pathFotoPrincipal ? signedMap[pathFotoPrincipal] : null;

              const totalPeca = cores.reduce((acc, curr) => 
                acc + (curr.estoque?.reduce((a, b) => a + (b.quantidade||0), 0) || 0), 0
              );

              return (
                <Link
                  href={`/item/${produto.id}`}
                  key={produto.id}
                  className="bg-slate-900 rounded-[2rem] overflow-hidden border border-slate-800 shadow-lg hover:shadow-2xl hover:border-pink-500/30 transition-all flex flex-col group cursor-pointer"
                >
                  {/* FOTO */}
                  <div className="h-48 bg-slate-950 relative overflow-hidden">
                    {urlAssinada ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img
                        src={urlAssinada}
                        className="w-full h-full object-cover opacity-80 group-hover:opacity-100 group-hover:scale-105 transition-all duration-500"
                        alt="Foto"
                        loading="lazy"
                      />
                    ) : (
                      <div className="w-full h-full flex flex-col items-center justify-center text-slate-700 bg-slate-950/50">
                        {/* Se tem path mas não tem URL assinada ainda, mostra carregando ou ícone */}
                        {pathFotoPrincipal ? (
                             <div className="w-6 h-6 border-2 border-slate-600 border-t-transparent rounded-full animate-spin"></div>
                        ) : (
                             <>
                                <span className="text-2xl mb-1">📷</span>
                                <span className="text-[9px] font-bold tracking-widest">SEM FOTO</span>
                             </>
                        )}
                      </div>
                    )}
                    
                    <div className="absolute top-3 left-3 bg-black/70 backdrop-blur-md px-3 py-1 rounded-full border border-white/10">
                        <span className="text-[9px] font-black text-white tracking-widest font-mono">{produto.codigo_peca}</span>
                    </div>

                    <div className="absolute bottom-3 right-3 bg-gradient-to-r from-blue-600 to-blue-500 px-3 py-1.5 rounded-lg shadow-lg">
                        <span className="text-xs font-black text-white">{formatBRL(produto.preco_venda)}</span>
                    </div>
                  </div>

                  {/* INFO */}
                  <div className="p-5 flex-1 flex flex-col gap-4">
                    <h2 className="font-bold text-slate-200 text-sm leading-tight uppercase line-clamp-2 min-h-[2.5em]">
                      {produto.descricao}
                    </h2>

                    <div className="space-y-3">
                        {cores.map((pc) => {
                            const estoque = pc.estoque || [];
                            if (estoque.length === 0) return null;
                            
                            // Tenta pegar a URL assinada desta cor específica para a bolinha
                            const urlCor = pc.foto_url ? signedMap[pc.foto_url] : null;

                            return (
                                <div key={pc.id} className="bg-slate-950/50 rounded-xl p-3 border border-slate-800/50">
                                    <div className="flex items-center gap-2 mb-2">
                                        {/* Bolinha da cor */}
                                        <div className="w-3 h-3 rounded-full bg-pink-500 overflow-hidden border border-white/20">
                                            {urlCor && (
                                                // eslint-disable-next-line @next/next/no-img-element
                                                <img src={urlCor} className="w-full h-full object-cover" alt="" />
                                            )}
                                        </div>
                                        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
                                            {getCorNome(pc)}
                                        </span>
                                    </div>
                                    
                                    <div className="flex flex-wrap gap-1.5">
                                        {estoque.map((item, i) => (
                                            <div key={i} className={`
                                                flex items-center gap-1.5 px-2 py-1 rounded-md border text-[10px] font-bold
                                                ${(item.quantidade||0) > 0 
                                                    ? 'bg-slate-800 border-slate-700 text-slate-200' 
                                                    : 'bg-red-950/20 border-red-900/30 text-red-500 opacity-60'}
                                            `}>
                                                <span className="text-blue-400">{getTamanhoNome(item)}</span>
                                                <div className="w-px h-2 bg-slate-600"></div>
                                                <span>{item.quantidade}</span>
                                            </div>
                                        ))}
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                  </div>

                  <div className="bg-slate-950 p-3 border-t border-slate-800 flex justify-between items-center">
                    <span className="text-[9px] font-bold text-slate-500 uppercase">Estoque Total</span>
                    <span className={`text-xs font-black ${totalPeca > 0 ? 'text-green-400' : 'text-red-500'}`}>
                        {totalPeca} Peças
                    </span>
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </main>
    </div>
  );
}