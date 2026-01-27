'use client';

import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import Link from 'next/link';
import { supabase } from '../../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode';
import Cropper from 'react-easy-crop';

// --- TIPOS ---
type EstoqueItem = {
  id: string;
  quantidade: number;
  codigo_barras: string | null;
  tamanho: { nome: string; ordem: number }; 
};

type Produto = {
  id: string;
  codigo_peca: string;
  sku_fornecedor: string | null;
  descricao: string;
  cor: string | null;
  foto_url: string | null;
  preco_venda: number;
  preco_compra?: number;
  custo_frete?: number;
  custo_embalagem?: number;
  estoque: EstoqueItem[]; // Agora direto no produto
};

type ItemCarrinho = {
  tempId: string;
  produto_id: string;
  estoque_id: string;
  descricao: string;
  cor: string;
  tamanho: string;
  preco: number;
  custo: number;
  qtd: number;
  maxEstoque: number;
  foto: string | null;
  ean: string | null;
};

type AreaCrop = { x: number; y: number; width: number; height: number };

// --- UTILITÁRIOS ---
const formatBRL = (val: number) => 
  val.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

const playBeep = () => {
    const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3'); 
    audio.volume = 0.5;
    audio.play().catch(() => {});
    if (typeof window !== 'undefined' && window.navigator && window.navigator.vibrate) {
        window.navigator.vibrate(50); 
    }
};

const ordenarEstoque = (estoque: EstoqueItem[]) => {
    return [...estoque].sort((a, b) => (a.tamanho?.ordem ?? 999) - (b.tamanho?.ordem ?? 999));
};

function extractPath(url: string | null) {
    if (!url) return null;
    if (url.startsWith('http')) {
        const parts = url.split('/produtos/');
        if (parts.length > 1) return parts[1].split('?')[0]; 
    }
    return url; 
}

async function getCroppedImg(imageSrc: string, pixelCrop: AreaCrop): Promise<Blob> {
  const image = new Image();
  image.src = imageSrc;
  await new Promise((resolve) => { image.onload = resolve; });
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('No 2d context');
  canvas.width = pixelCrop.width;
  canvas.height = pixelCrop.height;
  ctx.drawImage(image, pixelCrop.x, pixelCrop.y, pixelCrop.width, pixelCrop.height, 0, 0, pixelCrop.width, pixelCrop.height);
  return new Promise((resolve) => { canvas.toBlob((blob) => { if (blob) resolve(blob); }, 'image/jpeg', 1); });
}

export default function VendaPage() {
  const [loading, setLoading] = useState(false);
  const [lendoArquivo, setLendoArquivo] = useState(false);
  const [produtos, setProdutos] = useState<Produto[]>([]);
  const [busca, setBusca] = useState('');
  
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const [abaMobile, setAbaMobile] = useState<'busca' | 'carrinho'>('busca');
  const [carrinho, setCarrinho] = useState<ItemCarrinho[]>([]);
  
  // Modais
  const [modalSelecao, setModalSelecao] = useState<Produto | null>(null);
  const [mostrarScanner, setMostrarScanner] = useState(false);
  const [modalPagamento, setModalPagamento] = useState(false);
  const [itemPendente, setItemPendente] = useState<{ produto: Produto, est: EstoqueItem } | null>(null);

  const [pagamento, setPagamento] = useState({
      metodo: 'pix', 
      parcelas: 1,
      descontoTipo: 'reais' as 'reais' | 'porcentagem', 
      descontoValor: 0, 
      valorFinal: 0
  });

  // Upload e Crop
  const [imgSrc, setImgSrc] = useState<string | null>(null);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState<AreaCrop | null>(null);

  const scannerRef = useRef<Html5Qrcode | null>(null);

  useEffect(() => { fetchProdutos(); }, []);

  // Assinatura de Fotos (Simplificado)
  useEffect(() => {
    (async () => {
        const pathsToSign = new Set<string>();
        carrinho.forEach(item => { if (item.foto && !signedMap[item.foto]) pathsToSign.add(item.foto); });
        
        if (modalSelecao?.foto_url && !signedMap[modalSelecao.foto_url]) pathsToSign.add(modalSelecao.foto_url);
        if (itemPendente?.produto.foto_url && !signedMap[itemPendente.produto.foto_url]) pathsToSign.add(itemPendente.produto.foto_url);

        if (pathsToSign.size === 0) return;

        const newSigned: Record<string, string> = {};
        for (const original of Array.from(pathsToSign)) {
            const path = extractPath(original);
            if (path) {
                const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 3600);
                if (data?.signedUrl) newSigned[original] = data.signedUrl;
            }
        }
        if (Object.keys(newSigned).length > 0) setSignedMap(prev => ({ ...prev, ...newSigned }));
    })();
  }, [carrinho, modalSelecao, itemPendente, signedMap]);

  useEffect(() => {
      const totalBruto = carrinho.reduce((acc, item) => acc + (item.preco * item.qtd), 0);
      let final = totalBruto;
      if (pagamento.descontoTipo === 'reais') {
          final = totalBruto - pagamento.descontoValor;
      } else {
          final = totalBruto - (totalBruto * (pagamento.descontoValor / 100));
      }
      setPagamento(prev => ({ ...prev, valorFinal: Math.max(0, final) }));
  }, [carrinho, pagamento.descontoTipo, pagamento.descontoValor]);

  // --- SCANNER TURBO ---
  useEffect(() => {
    if (mostrarScanner) {
        const elementId = "reader-venda-direct";
        const t = setTimeout(() => {
            if (!document.getElementById(elementId)) return;
            const html5QrCode = new Html5Qrcode(elementId);
            scannerRef.current = html5QrCode;
            html5QrCode.start(
                { facingMode: "environment" },
                { fps: 30, qrbox: { width: 250, height: 100 }, aspectRatio: 1.0 },
                (decodedText) => {
                    handleScanSucesso(decodedText);
                    fecharScanner();
                },
                (error) => { }
            ).catch(err => {
                console.error("Erro Câmera:", err);
                setMostrarScanner(false);
            });
        }, 300);
        return () => clearTimeout(t);
    }
  }, [mostrarScanner]);

  const fecharScanner = async () => {
      if (scannerRef.current) {
          try {
            if (scannerRef.current.isScanning) await scannerRef.current.stop();
            scannerRef.current.clear();
          } catch (e) { console.log(e); }
      }
      setMostrarScanner(false);
  };

  async function fetchProdutos() {
    const { data } = await supabase
      .from('produtos')
      .select(`
        id, codigo_peca, sku_fornecedor, descricao, cor, foto_url, preco_venda, 
        preco_compra, custo_frete, custo_embalagem,
        estoque ( id, quantidade, codigo_barras, tamanho:tamanhos(nome, ordem) )
      `)
      .eq('descontinuado', false); 
    if (data) setProdutos(data as any);
  }

  function buscarPorEAN(codigo: string) {
      const codigoLimpo = codigo.trim();
      if (!codigoLimpo) return false;
      for (const p of produtos) {
          const estoqueEncontrado = p.estoque.find(e => e.codigo_barras === codigoLimpo);
          if (estoqueEncontrado) {
              prepararAdicao(p, estoqueEncontrado); 
              return true;
          }
      }
      return false;
  }

  function handleScanSucesso(codigo: string) {
      const achou = buscarPorEAN(codigo);
      if (!achou) alert(`Produto não encontrado: ${codigo}`);
      else setImgSrc(null);
  }

  // --- NOVA LÓGICA DE ADIÇÃO ---
  function prepararAdicao(produto: Produto, est: EstoqueItem) {
      playBeep();
      setItemPendente({ produto, est });
      setModalSelecao(null);
      setBusca('');
  }

  function confirmarAdicao() {
    if (!itemPendente) return;
    const { produto, est } = itemPendente;

    const jaNoCarrinho = carrinho.find(item => item.estoque_id === est.id);
    const qtdNoCarrinho = jaNoCarrinho ? jaNoCarrinho.qtd : 0;

    if (qtdNoCarrinho + 1 > est.quantidade) {
        alert(`Estoque insuficiente! Restam apenas ${est.quantidade}.`);
        return;
    }

    if (jaNoCarrinho) {
      setCarrinho(prev => prev.map(item => item.estoque_id === est.id ? { ...item, qtd: item.qtd + 1 } : item));
    } else {
      const custoTotalItem = (produto.preco_compra || 0) + (produto.custo_frete || 0) + (produto.custo_embalagem || 0);
      
      const novoItem: ItemCarrinho = {
        tempId: Math.random().toString(36),
        produto_id: produto.id,
        estoque_id: est.id,
        descricao: produto.descricao,
        cor: produto.cor || '',
        tamanho: est.tamanho.nome,
        preco: produto.preco_venda,
        custo: custoTotalItem,
        qtd: 1,
        maxEstoque: est.quantidade,
        foto: produto.foto_url,
        ean: est.codigo_barras
      };
      setCarrinho(prev => [...prev, novoItem]);
    }
    setItemPendente(null);
  }

  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.addEventListener('load', () => setImgSrc(reader.result?.toString() || ''));
      reader.readAsDataURL(file);
      e.target.value = '';
  };

  const onCropComplete = useCallback((_: any, croppedAreaPixels: AreaCrop) => {
    setCroppedAreaPixels(croppedAreaPixels);
  }, []);

  const processarRecorte = async () => {
    if (!imgSrc || !croppedAreaPixels) return;
    setLendoArquivo(true);
    try {
        const croppedBlob = await getCroppedImg(imgSrc, croppedAreaPixels);
        const croppedFile = new File([croppedBlob], "temp.jpg", { type: "image/jpeg" });
        const html5QrCode = new Html5Qrcode("reader-hidden");
        const decodedText = await html5QrCode.scanFileV2(croppedFile, true);
        if (decodedText) handleScanSucesso(decodedText.decodedText);
        else alert("Código não identificado.");
    } catch {
        alert("Erro ao ler código.");
    } finally {
        setLendoArquivo(false);
    }
  };

  const handleKeyDownBusca = (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter' && busca.length > 0) {
          if (buscarPorEAN(busca)) setBusca('');
      }
  };

  const produtosFiltrados = useMemo(() => {
    const q = busca.toLowerCase().trim();
    if (!q) return [];
    return produtos.filter(p => {
        const matchTexto = (p.descricao||'').toLowerCase().includes(q) 
            || (p.codigo_peca||'').toLowerCase().includes(q) 
            || (p.sku_fornecedor||'').toLowerCase().includes(q);
        
        const matchEan = p.estoque.some(e => e.codigo_barras?.includes(q));
        if (!matchTexto && !matchEan) return false;
        
        // Só mostra se tem estoque > 0
        const totalEstoque = p.estoque.reduce((acc, est) => acc + est.quantidade, 0);
        return totalEstoque > 0;
    }).slice(0, 6);
  }, [busca, produtos]);

  function removerItem(tempId: string) { setCarrinho(prev => prev.filter(i => i.tempId !== tempId)); }
  
  function alterarQtd(tempId: string, delta: number) {
    setCarrinho(prev => prev.map(item => {
      if (item.tempId === tempId) {
        const novaQtd = item.qtd + delta;
        if (novaQtd < 1) return item; 
        if (novaQtd > item.maxEstoque) return item;
        return { ...item, qtd: novaQtd };
      }
      return item;
    }));
  }

  const totalBruto = carrinho.reduce((acc, item) => acc + (item.preco * item.qtd), 0);
  const qtdItensCarrinho = carrinho.reduce((acc, item) => acc + item.qtd, 0);

  function abrirModalPagamento() {
      if (carrinho.length === 0) return alert('Carrinho vazio.');
      setPagamento({ metodo: 'pix', parcelas: 1, descontoTipo: 'reais', descontoValor: 0, valorFinal: totalBruto });
      setModalPagamento(true);
  }

  // --- CONFIRMAR VENDA ---
  async function confirmarVenda() {
    setLoading(true);
    
    // Preparar Payload para a RPC (Procedure no Banco)
    const itensPayload = carrinho.map(i => ({
      produto_id: i.produto_id,
      estoque_id: i.estoque_id,
      // Como removemos produto_cor_id, não enviamos ou enviamos null se a procedure esperar
      // Ajuste importante: A descrição completa para histórico agora concatena cor e tamanho
      descricao_completa: `${i.descricao} - ${i.cor} (${i.tamanho})`,
      quantidade: i.qtd,
      preco_unitario: i.preco,
      subtotal: i.preco * i.qtd
    }));

    const { error } = await supabase.rpc('realizar_venda', {
      p_valor_bruto: totalBruto,
      p_valor_liquido: pagamento.valorFinal,
      p_desconto: totalBruto - pagamento.valorFinal,
      p_forma_pagamento: pagamento.metodo,
      p_parcelas: pagamento.metodo === 'credito' ? pagamento.parcelas : 1,
      p_itens: itensPayload
    });

    setLoading(false);
    if (error) {
      alert('Erro: ' + error.message);
    } else {
      alert(`✅ Venda Sucesso!`);
      setModalPagamento(false);
      setCarrinho([]); 
      setAbaMobile('busca');
      await fetchProdutos();
    }
  }

  const handleDescontoInput = (valor: string, tipo: 'reais' | 'porcentagem' | 'final') => {
      const num = parseFloat(valor) || 0;
      if (tipo === 'final') {
          const descontoEmReais = totalBruto - num;
          setPagamento(prev => ({ ...prev, descontoTipo: 'reais', descontoValor: parseFloat(descontoEmReais.toFixed(2)) }));
      } else {
          setPagamento(prev => ({ ...prev, descontoTipo: tipo, descontoValor: num }));
      }
  };

  const handleSelecionarProduto = (p: Produto) => { setModalSelecao(p); setBusca(''); };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans flex flex-col md:flex-row overflow-hidden relative">
      <div id="reader-hidden" className="hidden"></div>

      {/* ÁREA ESQUERDA: BUSCA */}
      <div className={`flex-1 p-4 md:p-6 flex flex-col gap-4 h-[calc(100vh-80px)] md:h-screen overflow-y-auto ${abaMobile === 'carrinho' ? 'hidden md:flex' : 'flex'}`}>
        
        <header className="flex items-center gap-4">
          <Link href="/" className="bg-slate-800 p-3 rounded-full hover:bg-slate-700 transition active:scale-95">←</Link>
          <h1 className="font-black italic text-xl uppercase">UpFitness <span className="font-light text-pink-500">Checkout</span></h1>
        </header>

        <div className="relative z-30 flex flex-col gap-3">
            <input 
                autoFocus 
                type="text" 
                placeholder="🔎 Buscar, SKU ou EAN..." 
                className="w-full p-4 rounded-2xl bg-slate-900 border-2 border-slate-800 focus:border-pink-500 outline-none text-base font-bold shadow-xl text-white h-16" 
                value={busca} 
                onChange={e => setBusca(e.target.value)} 
                onKeyDown={handleKeyDownBusca} 
            />
            
            <div className="flex gap-3">
                <button onClick={() => setMostrarScanner(true)} className="flex-1 bg-slate-800 hover:bg-slate-700 text-white h-14 rounded-2xl flex items-center justify-center text-sm font-bold uppercase tracking-widest border-2 border-slate-800 hover:border-pink-500 transition-all shadow-xl active:scale-95 gap-2">
                    📷 <span className="hidden min-[350px]:inline">Câmera</span>
                </button>
                <label className={`flex-1 bg-slate-800 hover:bg-slate-700 text-white h-14 rounded-2xl flex items-center justify-center text-sm font-bold uppercase tracking-widest border-2 border-slate-800 hover:border-blue-500 transition-all shadow-xl cursor-pointer active:scale-95 gap-2 ${lendoArquivo ? 'animate-pulse bg-blue-900' : ''}`}>
                    {lendoArquivo ? '⏳' : '📂'} <span className="hidden min-[350px]:inline">Foto</span>
                    <input type="file" accept="image/*" className="hidden" onChange={handleFileUpload} />
                </label>
            </div>
            
            {produtosFiltrados.length > 0 && busca.length > 0 && (
                <div className="absolute top-full left-0 right-0 mt-2 bg-slate-800 rounded-2xl border border-slate-700 shadow-2xl overflow-hidden z-50 max-h-[50vh] overflow-y-auto">
                    {produtosFiltrados.map(p => (
                        <button key={p.id} onClick={() => handleSelecionarProduto(p)} className="w-full text-left p-5 hover:bg-slate-700 border-b border-slate-700/50 last:border-0 flex justify-between items-center transition-colors active:bg-slate-600">
                            <div>
                                <p className="font-bold text-white text-sm uppercase">{p.descricao}</p>
                                <p className="text-[10px] font-mono text-slate-400">{p.codigo_peca} | {p.cor}</p>
                            </div>
                            <span className="font-black text-emerald-400 text-sm">{formatBRL(p.preco_venda)}</span>
                        </button>
                    ))}
                </div>
            )}
        </div>

        <div className="flex-1 flex flex-col items-center justify-center text-slate-700 opacity-50 gap-2">
            <span className="text-6xl grayscale">🛒</span>
            <p className="text-sm font-bold uppercase tracking-widest text-center">Use a busca ou câmera<br/>para adicionar itens</p>
        </div>

        {/* BARRA INFERIOR MOBILE */}
        <div className="md:hidden fixed bottom-0 left-0 right-0 bg-slate-900 border-t border-slate-800 p-4 pb-8 flex items-center justify-between shadow-[0_-10px_40px_rgba(0,0,0,0.5)] z-20" onClick={() => setAbaMobile('carrinho')}>
            <div className="flex flex-col">
                <span className="text-[10px] text-slate-500 font-bold uppercase">Total ({qtdItensCarrinho} itens)</span>
                <span className="text-2xl font-black text-white">{formatBRL(totalBruto)}</span>
            </div>
            <button className="bg-emerald-600 text-white px-6 py-3 rounded-xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95">
                Ver Carrinho →
            </button>
        </div>
      </div>

      {/* ÁREA DIREITA: CARRINHO */}
      <div className={`w-full md:w-[420px] bg-slate-900 md:border-l border-slate-800 flex flex-col h-screen md:sticky md:top-0 shadow-2xl z-20 ${abaMobile === 'busca' ? 'hidden md:flex' : 'flex fixed inset-0'}`}>
        <div className="p-6 bg-slate-950/95 backdrop-blur-md border-b border-slate-800 flex items-center justify-between">
            <div className="flex items-center gap-3"><button onClick={() => setAbaMobile('busca')} className="md:hidden bg-slate-800 p-2 rounded-full text-slate-300">←</button><h2 className="font-black text-xl uppercase tracking-widest flex items-center gap-2">Carrinho <span className="bg-pink-600 text-white text-xs px-2 py-0.5 rounded-full">{qtdItensCarrinho}</span></h2></div>
        </div>
        <div className="flex-1 overflow-y-auto p-4 space-y-3 bg-slate-950/30">
            {carrinho.map(item => (
                <div key={item.tempId} className="bg-slate-900 p-3 rounded-2xl border border-slate-800 flex gap-3 relative group hover:border-slate-600 transition-colors shadow-sm">
                    <div className="w-16 h-16 rounded-xl bg-slate-800 overflow-hidden border border-slate-700 flex-shrink-0">
                        {item.foto && signedMap[item.foto] ? <img src={signedMap[item.foto]} className="w-full h-full object-cover" alt="" /> : <div className="w-full h-full flex items-center justify-center text-xs">📷</div>}
                    </div>
                    <div className="flex-1 min-w-0 flex flex-col justify-center">
                        <p className="text-xs font-black text-white leading-tight mb-1 line-clamp-2">{item.descricao}</p>
                        <p className="text-[9px] font-bold text-slate-500 mb-1 uppercase">{item.cor} • {item.tamanho}</p>
                        <p className="text-[10px] text-slate-400 font-mono">{formatBRL(item.preco)} un.</p>
                    </div>
                    <div className="flex flex-col items-end justify-between py-1">
                            <div className="flex items-center gap-1 bg-slate-950 rounded-lg p-1 border border-slate-800">
                            <button onClick={() => alterarQtd(item.tempId, -1)} className="w-8 h-8 flex items-center justify-center bg-slate-800 hover:bg-red-500/20 hover:text-red-500 rounded-lg text-lg font-bold transition text-slate-400 active:scale-90">-</button>
                            <span className="text-sm font-bold w-6 text-center text-white">{item.qtd}</span>
                            <button onClick={() => alterarQtd(item.tempId, 1)} className="w-8 h-8 flex items-center justify-center bg-slate-800 hover:bg-green-500/20 hover:text-green-500 rounded-lg text-lg font-bold transition text-slate-400 active:scale-90">+</button>
                        </div>
                        <span className="font-black text-sm text-emerald-400">{formatBRL(item.preco * item.qtd)}</span>
                    </div>
                    <button onClick={() => removerItem(item.tempId)} className="absolute -top-2 -right-2 bg-red-600 text-white w-7 h-7 rounded-full text-[10px] font-bold shadow-lg flex items-center justify-center z-10 active:scale-90">✕</button>
                </div>
            ))}
            <div className="h-20"></div>
        </div>
        <div className="p-6 bg-slate-950 border-t border-slate-800 space-y-4 shadow-[0_-10px_40px_rgba(0,0,0,0.5)] z-50">
            <div className="flex justify-between items-end"><span className="text-slate-500 text-xs font-bold uppercase tracking-widest">Total a Pagar</span><span className="text-4xl font-black text-white">{formatBRL(totalBruto)}</span></div>
            <button disabled={loading || carrinho.length === 0} onClick={abrirModalPagamento} className="w-full bg-gradient-to-r from-emerald-600 to-emerald-500 hover:brightness-110 text-white font-black py-5 rounded-xl shadow-lg uppercase tracking-widest text-sm transition-all disabled:opacity-50 disabled:cursor-not-allowed active:scale-95 h-16">{loading ? 'PROCESSANDO...' : 'FECHAR VENDA (F2)'}</button>
        </div>
      </div>

      {/* MODAL DE CONFERÊNCIA */}
      {itemPendente && (
        <div className="fixed inset-0 z-[10000] bg-black/95 backdrop-blur-md flex items-center justify-center p-4 animate-in fade-in zoom-in-95 duration-200">
            <div className="bg-slate-900 w-full max-w-xs rounded-3xl p-6 border border-slate-700 shadow-2xl relative flex flex-col gap-5">
                <div className="text-center space-y-1">
                    <span className="text-[10px] font-black text-blue-400 uppercase tracking-widest">Confirmação</span>
                    <h3 className="text-sm font-black uppercase text-white leading-tight line-clamp-2">{itemPendente.produto.descricao}</h3>
                </div>
                <div className="relative aspect-square bg-black rounded-2xl border-2 border-slate-700 overflow-hidden shadow-2xl mx-auto w-32 shrink-0">
                    {itemPendente.produto.foto_url && signedMap[itemPendente.produto.foto_url] ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={signedMap[itemPendente.produto.foto_url]} className="w-full h-full object-cover" alt="" />
                    ) : (
                        <div className="w-full h-full flex items-center justify-center text-4xl opacity-20">📷</div>
                    )}
                    <div className="absolute bottom-0 left-0 right-0 bg-black/80 backdrop-blur-sm p-1 flex justify-between items-center px-2">
                        <span className="text-[9px] font-bold text-white uppercase truncate">{itemPendente.produto.cor}</span>
                        <span className="text-[9px] font-black text-white bg-pink-600 px-1.5 py-0.5 rounded-md">{itemPendente.est.tamanho.nome}</span>
                    </div>
                </div>
                <div className="bg-slate-950 p-3 rounded-xl border border-slate-800 flex justify-between items-center shrink-0">
                    <span className="text-[10px] text-slate-500 font-bold uppercase">Valor</span>
                    <span className="text-xl font-black text-emerald-400">{formatBRL(itemPendente.produto.preco_venda)}</span>
                </div>
                <div className="grid grid-cols-2 gap-3 shrink-0">
                    <button onClick={() => setItemPendente(null)} className="bg-slate-800 text-slate-400 font-bold py-3 rounded-xl text-[10px] uppercase active:scale-95 transition-transform hover:bg-slate-700 hover:text-white">Cancelar</button>
                    <button onClick={confirmarAdicao} className="bg-blue-600 text-white font-black py-3 rounded-xl text-[10px] uppercase shadow-lg shadow-blue-900/20 active:scale-95 transition-transform hover:bg-blue-500">ADICIONAR</button>
                </div>
            </div>
        </div>
      )}

      {/* MODAL SELEÇÃO MANUAL */}
      {modalSelecao && (
            <div className="fixed inset-0 z-[50] bg-black/90 backdrop-blur-sm flex items-end md:items-center justify-center p-0 md:p-6 animate-in fade-in duration-200">
                <div className="bg-slate-900 w-full max-w-lg rounded-t-[2rem] md:rounded-[2rem] p-6 border-t md:border border-slate-800 shadow-2xl relative max-h-[90vh] overflow-hidden flex flex-col">
                    <div className="flex justify-between items-start mb-6 shrink-0">
                        <div>
                            <span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">Selecionando:</span>
                            <h2 className="text-xl font-black uppercase text-white leading-tight">{modalSelecao.descricao}</h2>
                            <p className="text-xs text-slate-400 font-bold mt-1 uppercase">{modalSelecao.cor}</p>
                        </div>
                        <button onClick={() => setModalSelecao(null)} className="bg-slate-800 w-10 h-10 rounded-full text-slate-400 hover:text-white font-bold text-xl active:scale-90">✕</button>
                    </div>
                    <div className="space-y-4 overflow-y-auto pr-1 pb-10">
                        <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800">
                            <div className="flex flex-wrap gap-2 justify-center">
                                {ordenarEstoque(modalSelecao.estoque).map(est => {
                                    const semEstoque = est.quantidade <= 0;
                                    return (
                                        <button key={est.id} disabled={semEstoque} onClick={() => prepararAdicao(modalSelecao, est)} className={`flex flex-col items-center justify-center w-16 h-16 rounded-xl border text-xs font-black uppercase transition-all active:scale-95 ${!semEstoque ? 'bg-slate-800 border-slate-600 text-white hover:bg-pink-600 hover:border-pink-500 shadow-lg' : 'bg-red-950/10 border-red-900/20 text-red-800/50 cursor-not-allowed'}`}>
                                            <span className="text-sm">{est.tamanho.nome}</span><span className={`text-[9px] ${!semEstoque ? 'text-slate-400' : ''}`}>{est.quantidade}</span>
                                        </button>
                                    );
                                })}
                            </div>
                        </div>
                    </div>
                </div>
            </div>
      )}

      {/* MODAL PAGAMENTO */}
      {modalPagamento && (
        <div className="fixed inset-0 z-[200] bg-black/95 backdrop-blur-md flex items-end md:items-center justify-center p-0 md:p-4">
            <div className="bg-slate-900 w-full max-w-2xl rounded-t-[2.5rem] md:rounded-[2.5rem] border-t md:border border-slate-700 shadow-2xl overflow-hidden flex flex-col max-h-[95vh]">
                <div className="bg-slate-950 p-6 border-b border-slate-800 flex justify-between items-center shrink-0"><h2 className="text-xl font-black uppercase text-white tracking-widest">Pagamento</h2><button onClick={() => setModalPagamento(false)} className="w-10 h-10 rounded-full bg-slate-800 text-slate-400 hover:text-white font-bold transition active:scale-90">✕</button></div>
                <div className="flex-1 overflow-y-auto p-6 space-y-8">
                    <div className="space-y-4">
                        <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Desconto / Ajuste</label>
                        <div className="grid grid-cols-1 min-[400px]:grid-cols-2 gap-4">
                            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3"><span className="text-pink-500 font-bold">%</span><input type="number" inputMode="decimal" placeholder="0" className="bg-transparent w-full text-lg font-bold text-white outline-none" value={pagamento.descontoTipo === 'porcentagem' ? pagamento.descontoValor : ''} onChange={e => handleDescontoInput(e.target.value, 'porcentagem')} /><span className="text-xs text-slate-600 font-bold uppercase">Desc. %</span></div>
                            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3"><span className="text-blue-500 font-bold">R$</span><input type="number" inputMode="decimal" placeholder="0,00" className="bg-transparent w-full text-lg font-bold text-white outline-none" value={pagamento.descontoTipo === 'reais' ? pagamento.descontoValor : ''} onChange={e => handleDescontoInput(e.target.value, 'reais')} /><span className="text-xs text-slate-600 font-bold uppercase">Desc. R$</span></div>
                        </div>
                        <div className="bg-slate-950 p-6 rounded-3xl border border-slate-800 text-center relative group">
                            <span className="text-xs text-slate-500 font-bold uppercase tracking-widest mb-1 block">Valor Final a Receber</span>
                            <div className="flex items-center justify-center gap-2"><span className="text-2xl text-slate-600 font-bold">R$</span><input type="number" inputMode="decimal" className="bg-transparent text-5xl font-black text-white outline-none text-center w-64" value={pagamento.valorFinal} onChange={e => handleDescontoInput(e.target.value, 'final')} /></div>
                        </div>
                    </div>
                    <div className="space-y-4">
                        <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Forma de Pagamento</label>
                        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                            {['pix', 'dinheiro', 'debito', 'credito'].map(m => (<button key={m} onClick={() => setPagamento(prev => ({ ...prev, metodo: m }))} className={`py-5 rounded-xl font-bold uppercase text-xs tracking-widest transition-all border-2 ${pagamento.metodo === m ? 'bg-emerald-600 border-emerald-500 text-white shadow-lg scale-105' : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'}`}>{m === 'credito' ? 'Crédito' : m === 'debito' ? 'Débito' : m}</button>))}
                        </div>
                    </div>
                    {pagamento.metodo === 'credito' && (
                        <div className="space-y-4 animate-in fade-in slide-in-from-top-4">
                            <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Parcelamento</label>
                            <select className="w-full bg-slate-950 border-2 border-slate-800 p-4 rounded-xl text-white font-bold outline-none focus:border-emerald-500 h-16 text-lg" value={pagamento.parcelas} onChange={e => setPagamento(prev => ({ ...prev, parcelas: parseInt(e.target.value) }))}>{[1,2,3,4,5,6,7,8,9,10,11,12].map(p => (<option key={p} value={p}>{p}x de {formatBRL(pagamento.valorFinal / p)} {p === 1 ? '(À Vista)' : '(Sem Juros)'}</option>))}</select>
                        </div>
                    )}
                </div>
                <div className="p-6 bg-slate-950 border-t border-slate-800 shrink-0"><button onClick={confirmarVenda} disabled={loading} className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl uppercase tracking-widest text-sm hover:brightness-110 transition-all disabled:opacity-50 h-16 active:scale-95">{loading ? 'REGISTRANDO...' : 'CONFIRMAR PAGAMENTO'}</button></div>
            </div>
        </div>
      )}

      {/* MODAL SCANNER TURBO */}
      {mostrarScanner && (
            <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
                <div className="w-full max-w-sm bg-slate-900 p-6 rounded-3xl border border-slate-800 shadow-2xl relative">
                    <h3 className="text-center font-black uppercase text-white mb-4 text-sm">Aponte para o Código</h3>
                    <div id="reader-venda-direct" className="w-full rounded-2xl overflow-hidden border-2 border-pink-500 bg-black h-64"></div>
                    <button onClick={fecharScanner} className="mt-6 w-full bg-slate-800 text-white py-4 rounded-xl font-bold uppercase tracking-widest">Fechar</button>
                </div>
            </div>
      )}

      {/* MODAL CROP */}
      {imgSrc && (
            <div className="fixed inset-0 z-[100] bg-black flex flex-col items-center justify-center">
                <div className="relative w-full h-full bg-black">
                    <Cropper image={imgSrc} crop={crop} zoom={zoom} aspect={3 / 2} onCropChange={setCrop} onCropComplete={onCropComplete} onZoomChange={setZoom} />
                </div>
                <div className="absolute bottom-0 left-0 right-0 p-6 z-50 flex flex-col gap-4 bg-black/80 backdrop-blur-md pb-10">
                    <p className="text-center text-xs text-slate-300">Ajuste o código de barras</p>
                    <input type="range" value={zoom} min={1} max={3} step={0.1} onChange={(e) => setZoom(Number(e.target.value))} className="w-full accent-pink-500 h-10" />
                    <div className="flex gap-2">
                        <button onClick={() => setImgSrc(null)} className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-bold uppercase">Cancelar</button>
                        <button onClick={processarRecorte} disabled={lendoArquivo} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black uppercase shadow-xl">{lendoArquivo ? 'Lendo...' : 'Confirmar'}</button>
                    </div>
                </div>
            </div>
      )}
    </div>
  );
}