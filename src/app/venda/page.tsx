'use client';

import { useState, useEffect, useMemo, useRef, useCallback } from 'react';
import Link from 'next/link';
import { supabase } from '../../lib/supabase';
import { Html5QrcodeScanner, Html5Qrcode, Html5QrcodeSupportedFormats } from 'html5-qrcode';
import Cropper from 'react-easy-crop';

// --- TIPOS ---
type EstoqueItem = {
  id: string;
  quantidade: number;
  codigo_barras: string | null;
  tamanho: { nome: string; ordem: number }; // Adicionado 'ordem'
};

type ProdutoCor = {
  id: string;
  foto_url: string | null;
  cor: { nome: string };
  estoque: EstoqueItem[];
};

type Produto = {
  id: string;
  codigo_peca: string;
  descricao: string;
  preco_venda: number;
  // Custos para cálculo de margem (opcional se não for usar no front)
  preco_compra?: number;
  custo_frete?: number;
  custo_embalagem?: number;
  produto_cores: ProdutoCor[];
};

type ItemCarrinho = {
  tempId: string;
  produto_id: string;
  produto_cor_id: string;
  estoque_id: string;
  descricao: string;
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
};

// Função para ordenar estoque baseada na ordem do tamanho (Banco de Dados)
const ordenarEstoque = (estoque: EstoqueItem[]) => {
    return [...estoque].sort((a, b) => {
        const ordemA = a.tamanho.ordem ?? 999;
        const ordemB = b.tamanho.ordem ?? 999;
        return ordemA - ordemB;
    });
};

const scannerConfig = {
    fps: 10,
    qrbox: 250,
    aspectRatio: 1.0,
    formatsToSupport: [
        Html5QrcodeSupportedFormats.EAN_13,
        Html5QrcodeSupportedFormats.EAN_8,
        Html5QrcodeSupportedFormats.CODE_128,
    ]
};

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
  
  // Carrinho
  const [carrinho, setCarrinho] = useState<ItemCarrinho[]>([]);
  
  // Modais e Controles
  const [modalSelecao, setModalSelecao] = useState<Produto | null>(null);
  const [mostrarScanner, setMostrarScanner] = useState(false);
  const [modalPagamento, setModalPagamento] = useState(false);
  
  const [pagamento, setPagamento] = useState({
      metodo: 'pix', 
      parcelas: 1,
      descontoTipo: 'reais' as 'reais' | 'porcentagem', 
      descontoValor: 0, 
      valorFinal: 0
  });

  // Crop
  const [imgSrc, setImgSrc] = useState<string | null>(null);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState<AreaCrop | null>(null);

  useEffect(() => { fetchProdutos(); }, []);

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

  useEffect(() => {
    if (mostrarScanner) {
        const scanner = new Html5QrcodeScanner("reader", scannerConfig, false);
        scanner.render((t) => { handleScanSucesso(t); scanner.clear(); setMostrarScanner(false); }, () => {});
        return () => { scanner.clear().catch(() => {}); };
    }
  }, [mostrarScanner]); // eslint-disable-line

  async function fetchProdutos() {
    // Agora buscamos também a coluna 'ordem' dos tamanhos
    const { data } = await supabase
      .from('produtos')
      .select(`
        id, codigo_peca, descricao, preco_venda, 
        preco_compra, custo_frete, custo_embalagem,
        produto_cores (
          id, foto_url,
          cor:cores(nome),
          estoque(
            id, quantidade, codigo_barras, 
            tamanho:tamanhos(nome, ordem) 
          )
        )
      `)
      .eq('descontinuado', false); 
    if (data) setProdutos(data as any);
  }

  // --- LÓGICA DE BUSCA ---
  function buscarPorEAN(codigo: string) {
      const codigoLimpo = codigo.trim();
      if (!codigoLimpo) return false;
      for (const p of produtos) {
          for (const pc of p.produto_cores) {
              const estoqueEncontrado = pc.estoque.find(e => e.codigo_barras === codigoLimpo);
              if (estoqueEncontrado) {
                  playBeep();
                  adicionarAoCarrinho(p, pc, estoqueEncontrado);
                  return true;
              }
          }
      }
      return false;
  }

  function handleScanSucesso(codigo: string) {
      const achou = buscarPorEAN(codigo);
      if (!achou) alert(`Produto não encontrado: ${codigo}`);
      else setImgSrc(null);
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
        else alert("Código não identificado. Tente ajustar o recorte.");
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
        const matchTexto = (p.descricao||'').toLowerCase().includes(q) || (p.codigo_peca||'').toLowerCase().includes(q);
        const matchEan = p.produto_cores.some(pc => pc.estoque.some(e => e.codigo_barras?.includes(q)));
        if (!matchTexto && !matchEan) return false;
        const estoqueTotal = p.produto_cores.reduce((accCor, pc) => accCor + pc.estoque.reduce((accEst, est) => accEst + est.quantidade, 0), 0);
        return estoqueTotal > 0;
    }).slice(0, 6);
  }, [busca, produtos]);

  // --- CARRINHO ---
  function adicionarAoCarrinho(produto: Produto, pc: ProdutoCor, est: EstoqueItem) {
    const jaNoCarrinho = carrinho.find(item => item.estoque_id === est.id);
    const qtdNoCarrinho = jaNoCarrinho ? jaNoCarrinho.qtd : 0;

    if (qtdNoCarrinho + 1 > est.quantidade) return alert(`Estoque insuficiente!`);

    if (jaNoCarrinho) {
      setCarrinho(prev => prev.map(item => item.estoque_id === est.id ? { ...item, qtd: item.qtd + 1 } : item));
    } else {
      const custoTotalItem = (produto.preco_compra || 0) + (produto.custo_frete || 0) + (produto.custo_embalagem || 0);
      
      const novoItem: ItemCarrinho = {
        tempId: Math.random().toString(36),
        produto_id: produto.id,
        produto_cor_id: pc.id,
        estoque_id: est.id,
        descricao: `${produto.descricao} (${pc.cor.nome} - ${est.tamanho.nome})`,
        preco: produto.preco_venda,
        custo: custoTotalItem,
        qtd: 1,
        maxEstoque: est.quantidade,
        foto: pc.foto_url,
        ean: est.codigo_barras
      };
      setCarrinho(prev => [...prev, novoItem]);
    }
    setModalSelecao(null);
    setBusca('');
  }

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
  const totalCusto = carrinho.reduce((acc, item) => acc + (item.custo * item.qtd), 0);

  // --- FINALIZAR ---
  function abrirModalPagamento() {
      if (carrinho.length === 0) return alert('Carrinho vazio.');
      setPagamento({ metodo: 'pix', parcelas: 1, descontoTipo: 'reais', descontoValor: 0, valorFinal: totalBruto });
      setModalPagamento(true);
  }

  async function confirmarVenda() {
    setLoading(true);
    const itensPayload = carrinho.map(i => ({
      produto_id: i.produto_id,
      produto_cor_id: i.produto_cor_id,
      estoque_id: i.estoque_id,
      descricao_completa: i.descricao,
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
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans pb-32 flex flex-col md:flex-row overflow-hidden">
      <div id="reader-hidden" className="hidden"></div>

      {/* --- SIDEBAR ESQUERDA (BUSCA) --- */}
      <div className="flex-1 p-6 flex flex-col gap-6 h-screen overflow-y-auto">
        <header className="flex items-center gap-4">
          <Link href="/" className="bg-slate-800 p-3 rounded-full hover:bg-slate-700 transition">←</Link>
          <h1 className="font-black italic text-2xl uppercase">UpFitness <span className="font-light text-pink-500">PDV</span></h1>
        </header>

        <div className="relative z-50 flex gap-2">
            <div className="relative flex-1 group">
                <input autoFocus type="text" placeholder="🔎 Buscar produto ou EAN..." className="w-full p-5 rounded-2xl bg-slate-900 border-2 border-slate-800 focus:border-pink-500 outline-none text-lg font-bold shadow-xl text-white" value={busca} onChange={e => setBusca(e.target.value)} onKeyDown={handleKeyDownBusca} />
            </div>
            <button onClick={() => setMostrarScanner(true)} className="bg-slate-800 hover:bg-slate-700 text-white w-16 rounded-2xl flex items-center justify-center text-xl border-2 border-slate-800 hover:border-pink-500 transition-all shadow-xl">📷</button>
            <label className={`bg-slate-800 hover:bg-slate-700 text-white w-16 rounded-2xl flex items-center justify-center text-xl border-2 border-slate-800 hover:border-blue-500 transition-all shadow-xl cursor-pointer ${lendoArquivo ? 'animate-pulse bg-blue-900' : ''}`}>
                {lendoArquivo ? '⏳' : '📂'}
                <input type="file" accept="image/*" className="hidden" onChange={handleFileUpload} />
            </label>
            
            {produtosFiltrados.length > 0 && busca.length > 0 && (
                <div className="absolute top-full left-0 right-32 mt-2 bg-slate-800 rounded-2xl border border-slate-700 shadow-2xl overflow-hidden z-50 max-h-[60vh] overflow-y-auto">
                    {produtosFiltrados.map(p => (
                        <button key={p.id} onClick={() => handleSelecionarProduto(p)} className="w-full text-left p-4 hover:bg-slate-700 border-b border-slate-700/50 last:border-0 flex justify-between items-center transition-colors">
                            <div><p className="font-bold text-white text-sm uppercase">{p.descricao}</p><p className="text-[10px] font-mono text-slate-400">{p.codigo_peca}</p></div>
                            <span className="font-black text-emerald-400 text-sm">{formatBRL(p.preco_venda)}</span>
                        </button>
                    ))}
                </div>
            )}
        </div>

        {/* MODAL SCANNER */}
        {mostrarScanner && (
            <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
                <div className="w-full max-w-sm bg-slate-900 p-6 rounded-3xl border border-slate-800 shadow-2xl relative">
                    <div id="reader" className="w-full rounded-2xl overflow-hidden border-2 border-pink-500 bg-black"></div>
                    <button onClick={() => setMostrarScanner(false)} className="mt-6 w-full bg-slate-800 text-white py-4 rounded-xl font-bold uppercase tracking-widest">Fechar</button>
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

        {/* SELEÇÃO VARIAÇÃO */}
        {modalSelecao && (
            <div className="bg-slate-900 border border-slate-800 rounded-3xl p-6 shadow-2xl animate-in fade-in slide-in-from-top-4 relative">
                <div className="flex justify-between items-start mb-4">
                    <div><span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">Selecionando:</span><h2 className="text-xl font-black uppercase text-white leading-tight">{modalSelecao.descricao}</h2><span className="text-emerald-400 font-bold">{formatBRL(modalSelecao.preco_venda)}</span></div>
                    <button onClick={() => setModalSelecao(null)} className="bg-slate-800 w-8 h-8 rounded-full text-slate-400 hover:text-white">✕</button>
                </div>
                <div className="space-y-4 max-h-[50vh] overflow-y-auto pr-2">
                    {modalSelecao.produto_cores.map(pc => {
                        const total = pc.estoque.reduce((acc, e) => acc + e.quantidade, 0);
                        if (total === 0) return null;
                        
                        // ORDENAÇÃO AQUI (USANDO A FUNÇÃO HELPER)
                        const estoqueOrdenado = ordenarEstoque(pc.estoque);

                        return (
                            <div key={pc.id} className="bg-slate-950 p-4 rounded-xl border border-slate-800">
                                <div className="flex items-center gap-3 mb-3 pb-2 border-b border-slate-800/50">
                                    <div className="w-8 h-8 rounded-lg bg-slate-800 overflow-hidden border border-slate-700">{pc.foto_url ? <img src={pc.foto_url} className="w-full h-full object-cover" alt="" /> : <div className="w-full h-full bg-pink-500"></div>}</div>
                                    <span className="font-bold text-sm uppercase text-slate-300">{pc.cor.nome}</span>
                                </div>
                                <div className="flex flex-wrap gap-2">
                                    {estoqueOrdenado.map(est => {
                                        const semEstoque = est.quantidade <= 0;
                                        return <button key={est.id} disabled={semEstoque} onClick={() => adicionarAoCarrinho(modalSelecao, pc, est)} className={`flex flex-col items-center justify-center w-16 h-14 rounded-lg border text-xs font-black uppercase transition-all ${!semEstoque ? 'bg-slate-800 border-slate-600 text-white hover:bg-pink-600 hover:border-pink-500 hover:scale-105 shadow-lg' : 'bg-red-950/10 border-red-900/20 text-red-800/50 cursor-not-allowed grayscale hidden'}`}><span className="text-sm">{est.tamanho.nome}</span><span className={`text-[9px] ${!semEstoque ? 'text-slate-400' : ''}`}>{est.quantidade} un</span></button>;
                                    })}
                                </div>
                            </div>
                        );
                    })}
                </div>
            </div>
        )}
      </div>

      {/* --- SIDEBAR DIREITA (CARRINHO) --- */}
      <div className="w-full md:w-[420px] bg-slate-900 border-l border-slate-800 flex flex-col h-screen sticky top-0 shadow-2xl z-40">
        <div className="p-6 bg-slate-950/80 backdrop-blur-md border-b border-slate-800">
            <h2 className="font-black text-xl uppercase tracking-widest flex items-center gap-2">🛒 Carrinho <span className="bg-pink-600 text-white text-xs px-2 py-0.5 rounded-full">{carrinho.reduce((a, b) => a + b.qtd, 0)}</span></h2>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-3 bg-slate-950/30">
            {carrinho.length === 0 ? (
                <div className="h-full flex flex-col items-center justify-center text-slate-600 opacity-50"><span className="text-5xl mb-4 grayscale">🛍️</span><p className="text-xs font-bold uppercase tracking-widest">Aguardando itens...</p></div>
            ) : (
                carrinho.map(item => (
                    <div key={item.tempId} className="bg-slate-900 p-3 rounded-xl border border-slate-800 flex gap-3 relative group hover:border-slate-600 transition-colors animate-in fade-in slide-in-from-right-8">
                        {item.foto ? <img src={item.foto} className="w-14 h-14 rounded-lg object-cover bg-slate-800 border border-slate-700" alt="" /> : <div className="w-14 h-14 rounded-lg bg-slate-800 flex items-center justify-center text-xs border border-slate-700">📷</div>}
                        <div className="flex-1 min-w-0 flex flex-col justify-center"><p className="text-xs font-black text-white leading-tight mb-1">{item.descricao}</p>{item.ean && <p className="text-[8px] font-mono text-slate-600 mb-1">EAN: {item.ean}</p>}<p className="text-[10px] text-slate-400 font-mono">{formatBRL(item.preco)} un.</p></div>
                        <div className="flex flex-col items-end justify-between py-1">
                             <div className="flex items-center gap-2 bg-slate-950 rounded-lg p-1 border border-slate-800">
                                <button onClick={() => alterarQtd(item.tempId, -1)} className="w-6 h-6 flex items-center justify-center bg-slate-800 hover:bg-red-500/20 hover:text-red-500 rounded text-xs font-bold transition text-slate-400">-</button>
                                <span className="text-xs font-bold w-4 text-center text-white">{item.qtd}</span>
                                <button onClick={() => alterarQtd(item.tempId, 1)} className="w-6 h-6 flex items-center justify-center bg-slate-800 hover:bg-green-500/20 hover:text-green-500 rounded text-xs font-bold transition text-slate-400">+</button>
                            </div>
                            <span className="font-black text-sm text-emerald-400">{formatBRL(item.preco * item.qtd)}</span>
                        </div>
                        <button onClick={() => removerItem(item.tempId)} className="absolute -top-2 -right-2 bg-red-600 text-white w-6 h-6 rounded-full text-[10px] font-bold shadow-lg opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center z-10 hover:scale-110">✕</button>
                    </div>
                ))
            )}
        </div>

        <div className="p-6 bg-slate-950 border-t border-slate-800 space-y-4 shadow-[0_-10px_40px_rgba(0,0,0,0.5)] z-50">
            <div className="flex justify-between items-end"><span className="text-slate-500 text-xs font-bold uppercase tracking-widest">Total a Pagar</span><span className="text-4xl font-black text-white">{formatBRL(totalBruto)}</span></div>
            <button disabled={loading || carrinho.length === 0} onClick={abrirModalPagamento} className="w-full bg-gradient-to-r from-emerald-600 to-emerald-500 hover:brightness-110 text-white font-black py-5 rounded-xl shadow-lg uppercase tracking-widest text-sm transition-all disabled:opacity-50 disabled:cursor-not-allowed active:scale-95">{loading ? 'PROCESSANDO...' : 'FECHAR VENDA (F2)'}</button>
        </div>
      </div>

      {/* --- MODAL DE PAGAMENTO --- */}
      {modalPagamento && (
        <div className="fixed inset-0 z-[200] bg-black/90 backdrop-blur-md flex items-center justify-center p-4">
            <div className="bg-slate-900 w-full max-w-2xl rounded-[2.5rem] border border-slate-700 shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
                <div className="bg-slate-950 p-6 border-b border-slate-800 flex justify-between items-center"><h2 className="text-xl font-black uppercase text-white tracking-widest">Finalizar Pagamento</h2><button onClick={() => setModalPagamento(false)} className="w-10 h-10 rounded-full bg-slate-800 text-slate-400 hover:text-white font-bold transition">✕</button></div>
                <div className="flex-1 overflow-y-auto p-8 space-y-8">
                    <div className="space-y-4">
                        <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Desconto / Ajuste</label>
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3"><span className="text-pink-500 font-bold">%</span><input type="number" placeholder="0" className="bg-transparent w-full text-lg font-bold text-white outline-none" value={pagamento.descontoTipo === 'porcentagem' ? pagamento.descontoValor : ''} onChange={e => handleDescontoInput(e.target.value, 'porcentagem')} /><span className="text-xs text-slate-600 font-bold uppercase">Desc. %</span></div>
                            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3"><span className="text-blue-500 font-bold">R$</span><input type="number" placeholder="0,00" className="bg-transparent w-full text-lg font-bold text-white outline-none" value={pagamento.descontoTipo === 'reais' ? pagamento.descontoValor : ''} onChange={e => handleDescontoInput(e.target.value, 'reais')} /><span className="text-xs text-slate-600 font-bold uppercase">Desc. R$</span></div>
                        </div>
                        <div className="bg-slate-950 p-6 rounded-3xl border border-slate-800 text-center relative group">
                            <span className="text-xs text-slate-500 font-bold uppercase tracking-widest mb-1 block">Valor Final a Receber</span>
                            <div className="flex items-center justify-center gap-2"><span className="text-2xl text-slate-600 font-bold">R$</span><input type="number" className="bg-transparent text-5xl font-black text-white outline-none text-center w-64" value={pagamento.valorFinal} onChange={e => handleDescontoInput(e.target.value, 'final')} /></div>
                            {pagamento.valorFinal < totalCusto && (<div className="absolute top-4 right-4 text-red-500 text-[10px] font-black uppercase border border-red-900/50 bg-red-950/30 px-3 py-1 rounded-full animate-pulse">⚠️ Abaixo do Custo ({formatBRL(totalCusto)})</div>)}
                        </div>
                    </div>
                    <div className="space-y-4">
                        <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Forma de Pagamento</label>
                        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                            {['pix', 'dinheiro', 'debito', 'credito'].map(m => (<button key={m} onClick={() => setPagamento(prev => ({ ...prev, metodo: m }))} className={`py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition-all border-2 ${pagamento.metodo === m ? 'bg-emerald-600 border-emerald-500 text-white shadow-lg scale-105' : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'}`}>{m === 'credito' ? 'Crédito' : m === 'debito' ? 'Débito' : m}</button>))}
                        </div>
                    </div>
                    {pagamento.metodo === 'credito' && (
                        <div className="space-y-4 animate-in fade-in slide-in-from-top-4">
                            <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Parcelamento</label>
                            <select className="w-full bg-slate-950 border-2 border-slate-800 p-4 rounded-xl text-white font-bold outline-none focus:border-emerald-500" value={pagamento.parcelas} onChange={e => setPagamento(prev => ({ ...prev, parcelas: parseInt(e.target.value) }))}>{[1,2,3,4,5,6,7,8,9,10,11,12].map(p => (<option key={p} value={p}>{p}x de {formatBRL(pagamento.valorFinal / p)} {p === 1 ? '(À Vista)' : '(Sem Juros)'}</option>))}</select>
                        </div>
                    )}
                </div>
                <div className="p-6 bg-slate-950 border-t border-slate-800"><button onClick={confirmarVenda} disabled={loading} className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl uppercase tracking-widest text-sm hover:brightness-110 transition-all disabled:opacity-50">{loading ? 'REGISTRANDO...' : 'CONFIRMAR PAGAMENTO'}</button></div>
            </div>
        </div>
      )}
    </div>
  );
}