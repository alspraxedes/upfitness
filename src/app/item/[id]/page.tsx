'use client';

import { use, useEffect, useState, useRef } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { supabase } from '../../../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode';

// --- UTILITÁRIOS ---
const formatBRL = (val: number | string) => {
  const n = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(n)) return 'R$ 0,00';
  return n.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
};

function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
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
    } catch (e) { return url; }
}

export default function DetalheItem({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const router = useRouter();
  
  // Refs
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const scannerRef = useRef<Html5Qrcode | null>(null);

  // --- ESTADOS ---
  const [loading, setLoading] = useState(true);
  const [editando, setEditando] = useState(false);
  
  // Dados Principais
  const [produto, setProduto] = useState<any>(null);
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);
  const [signedUrl, setSignedUrl] = useState<string | null>(null);

  // Formulário de Edição
  const [formData, setFormData] = useState({
    descricao: '',
    fornecedor: '',
    sku_fornecedor: '', 
    cor: '',            
    preco_compra: 0,
    custo_frete: 0,
    custo_embalagem: 0,
    preco_venda: 0,
    margem_ganho: 0,
    descontinuado: false,
  });

  // MODAIS
  const [modalFoto, setModalFoto] = useState(false);
  const [fotoTemp, setFotoTemp] = useState<{ url: string, blob: Blob } | null>(null);
  
  const [modalAddTamanho, setModalAddTamanho] = useState(false);
  const [novoTamanhoId, setNovoTamanhoId] = useState('');

  const [modalEstoque, setModalEstoque] = useState<{
    aberto: boolean;
    tipo: 'entrada' | 'saida' | 'edicao'; 
    itemEstoqueId: string;
    tamanhoNome: string;
    qtdAtual: number;
    qtdOperacao: number | string;
    eanAtual: string; 
    scanning: boolean;
  }>({ 
      aberto: false, tipo: 'entrada', itemEstoqueId: '', 
      tamanhoNome: '', qtdAtual: 0, qtdOperacao: '', eanAtual: '', scanning: false 
  });

  // --- CARREGAMENTO ---
  useEffect(() => { if (id) carregarDados(); }, [id]);

  async function carregarDados() {
    setLoading(true);
    
    // 1. Carregar Tamanhos para o Select
    const { data: tams } = await supabase.from('tamanhos').select('*').order('ordem');
    setListaTamanhos(tams || []);

    // 2. Carregar Produto + Estoque
    const { data, error } = await supabase
      .from('produtos')
      .select(`*, estoque(*, tamanho:tamanhos(*))`)
      .eq('id', id)
      .single();

    if (error || !data) { 
        alert('Produto não encontrado'); 
        return router.push('/'); 
    }
    
    // Ordenar estoque (P, M, G...)
    if (data.estoque) data.estoque.sort((a:any, b:any) => (a.tamanho?.ordem ?? 99) - (b.tamanho?.ordem ?? 99));

    setProduto(data);
    
    // Gerar URL Assinada da Foto
    if (data.foto_url) {
        const path = extractPath(data.foto_url);
        if (path) {
            const { data: signed } = await supabase.storage.from('produtos').createSignedUrl(path, 3600);
            if (signed?.signedUrl) setSignedUrl(signed.signedUrl);
        }
    }

    // Preencher Form
    const custo = (data.preco_compra||0) + (data.custo_frete||0) + (data.custo_embalagem||0);
    const margem = custo > 0 ? ((data.preco_venda - custo)/custo)*100 : 100;

    setFormData({
        descricao: data.descricao, fornecedor: data.fornecedor, 
        sku_fornecedor: data.sku_fornecedor || '', cor: data.cor || '',
        preco_compra: data.preco_compra, custo_frete: data.custo_frete, custo_embalagem: data.custo_embalagem,
        preco_venda: data.preco_venda, margem_ganho: parseFloat(margem.toFixed(1)),
        descontinuado: data.descontinuado
    });
    setLoading(false);
  }

  // --- UPLOAD FOTO ---
  const handleFileChange = async (e: any) => {
      const file = e.target.files?.[0];
      if (!file) return;
      await uploadFoto(file);
  };

  const uploadFoto = async (file: File) => {
      setModalFoto(false);
      setLoading(true);
      try {
          const path = `produtos/${id}_${Date.now()}.jpg`;
          await supabase.storage.from('produtos').upload(path, file);
          const { data } = supabase.storage.from('produtos').getPublicUrl(path);
          await supabase.from('produtos').update({ foto_url: data.publicUrl }).eq('id', id);
          setFotoTemp(null);
          await carregarDados();
      } catch (e) { alert('Erro no upload'); }
      setLoading(false);
  };

  // Câmera Foto
  const abrirCameraFoto = async () => {
    setFotoTemp(null);
    try {
        const stream = await navigator.mediaDevices.getUserMedia({ 
            video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } } 
        });
        streamRef.current = stream;
        if (videoRef.current) videoRef.current.srcObject = stream;
    } catch (e) { alert('Erro câmera'); }
  };

  // --- SALVAR EDIÇÃO ---
  const salvarEdicao = async () => {
      const { error } = await supabase.from('produtos').update({
          descricao: formData.descricao, 
          fornecedor: formData.fornecedor, 
          sku_fornecedor: formData.sku_fornecedor, 
          cor: formData.cor, 
          preco_compra: formData.preco_compra, 
          custo_frete: formData.custo_frete, 
          custo_embalagem: formData.custo_embalagem,
          preco_venda: formData.preco_venda, 
          descontinuado: formData.descontinuado
      }).eq('id', id);

      if (error) return alert('Erro ao salvar');
      setEditando(false);
      carregarDados();
  };

  const handleMoneyInput = (val: string, field: string) => {
     const num = parseFloat(val.replace(/\D/g, '')) / 100;
     setFormData({...formData, [field]: num || 0});
  };

  // --- ESTOQUE E SCANNER ---
  useEffect(() => {
    if (modalEstoque.aberto && modalEstoque.scanning) {
        const elementId = "reader-ean-edit";
        const timeout = setTimeout(() => {
            if (!document.getElementById(elementId)) return;
            const scanner = new Html5Qrcode(elementId);
            scannerRef.current = scanner;
            scanner.start({ facingMode: "environment" }, { fps: 30, qrbox: { width: 250, height: 100 }, aspectRatio: 1.0 }, (text) => {
                setModalEstoque(p => ({ ...p, eanAtual: text, scanning: false }));
                scanner.stop().then(() => scanner.clear());
            }, () => {}).catch(console.error);
        }, 200);
        return () => clearTimeout(timeout);
    }
  }, [modalEstoque.aberto, modalEstoque.scanning]);

  const confirmarEstoque = async () => {
      if (modalEstoque.tipo === 'edicao') {
          const { error } = await supabase.from('estoque').update({ codigo_barras: modalEstoque.eanAtual }).eq('id', modalEstoque.itemEstoqueId);
          if (error) alert('Erro (EAN duplicado?)');
      } else {
          const qtd = parseInt(String(modalEstoque.qtdOperacao));
          if (!qtd) return;
          const nova = modalEstoque.tipo === 'entrada' ? modalEstoque.qtdAtual + qtd : modalEstoque.qtdAtual - qtd;
          if (nova < 0) return alert('Estoque não pode ser negativo');
          await supabase.from('estoque').update({ quantidade: nova }).eq('id', modalEstoque.itemEstoqueId);
      }
      setModalEstoque(p => ({ ...p, aberto: false }));
      carregarDados();
  };

  const addTamanho = async () => {
      if(!novoTamanhoId) return;
      await supabase.from('estoque').insert({ produto_id: id, tamanho_id: novoTamanhoId, quantidade: 0 });
      setModalAddTamanho(false);
      carregarDados();
  };

  if (loading) return <div className="min-h-screen bg-slate-950 flex items-center justify-center text-pink-500 font-black animate-pulse">CARREGANDO...</div>;

  return (
    <div className={`min-h-screen bg-slate-950 text-slate-100 font-sans pb-32 ${formData.descontinuado ? 'grayscale-[0.8]' : ''}`}>
      
      {/* HEADER */}
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-6 shadow-2xl mb-8 flex justify-between items-center sticky top-0 z-40">
        <div className="flex items-center gap-4">
            <Link href="/" className="bg-black/20 hover:bg-black/40 px-3 py-2 rounded-full text-white transition-colors text-xs font-bold">← VOLTAR</Link>
        </div>
        <div className="flex gap-2">
            {!editando ? (
                <button onClick={() => setEditando(true)} className="bg-white text-pink-600 px-5 py-2 rounded-full text-[10px] font-black uppercase tracking-widest shadow-lg active:scale-95 transition-transform">Editar</button>
            ) : (
                <button onClick={salvarEdicao} className="bg-green-500 text-white px-6 py-2 rounded-full text-[10px] font-black uppercase tracking-widest shadow-lg active:scale-95 transition-transform">Salvar</button>
            )}
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 space-y-6">
        
        {/* STATUS CODE */}
        <div className="flex justify-between items-center bg-slate-900 p-4 rounded-2xl border border-slate-800">
             <div>
                 <h1 className="font-black italic text-lg text-white">{produto.codigo_peca}</h1>
                 <span className="text-[9px] font-bold text-slate-500 uppercase tracking-widest">Código Interno</span>
             </div>
             {editando && (
                <button onClick={() => setFormData({...formData, descontinuado: !formData.descontinuado})} className={`px-4 py-2 rounded-xl text-[9px] font-black uppercase tracking-widest ${formData.descontinuado ? 'bg-red-900/30 text-red-500' : 'bg-green-900/30 text-green-500'}`}>
                    {formData.descontinuado ? '🚫 Descontinuado' : '✅ Ativo'}
                </button>
             )}
        </div>

        {/* IDENTIFICAÇÃO E FOTO */}
        <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl flex flex-col md:flex-row gap-6">
            <div className="shrink-0 flex justify-center">
                 <button onClick={() => setModalFoto(true)} className="w-32 h-32 rounded-3xl bg-slate-950 border-2 border-slate-700 overflow-hidden relative group shadow-lg">
                    {signedUrl ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={signedUrl} className="w-full h-full object-cover" alt="" /> 
                    ) : <span className="text-4xl opacity-30">📷</span>}
                    <div className="absolute inset-0 bg-black/50 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity font-bold text-[10px] text-white">ALTERAR</div>
                 </button>
            </div>
            
            <div className="flex-1 space-y-4">
                {editando ? (
                    <>
                        <div className="grid grid-cols-2 gap-4">
                            <div className="space-y-1">
                                <label className="text-[9px] font-black text-slate-500 uppercase ml-1">SKU Fornecedor</label>
                                <input value={formData.sku_fornecedor} onChange={e => setFormData({...formData, sku_fornecedor: e.target.value})} className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-xs focus:border-pink-500 outline-none" placeholder="REF-999" />
                            </div>
                            <div className="space-y-1">
                                <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Cor (Texto)</label>
                                <input value={formData.cor} onChange={e => setFormData({...formData, cor: e.target.value})} className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-xs focus:border-pink-500 outline-none" />
                            </div>
                        </div>

                        <div className="space-y-1">
                             <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Descrição</label>
                             <input value={formData.descricao} onChange={e => setFormData({...formData, descricao: e.target.value})} className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-sm focus:border-pink-500 outline-none" />
                        </div>

                        <div className="flex items-center gap-4 pt-2">
                             <div className="flex-1 space-y-1">
                                <label className="text-[9px] font-black text-blue-400 uppercase ml-1">Preço Venda</label>
                                <input type="tel" inputMode="decimal" value={formatBRL(formData.preco_venda)} onChange={e => handleMoneyInput(e.target.value, 'preco_venda')} className="w-full bg-slate-950 p-3 rounded-xl border border-blue-900/50 text-blue-400 font-black text-lg focus:border-blue-500 outline-none" />
                             </div>
                             <div className="flex-1 space-y-1">
                                <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Fornecedor</label>
                                <input value={formData.fornecedor} onChange={e => setFormData({...formData, fornecedor: e.target.value})} className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-xs focus:border-pink-500 outline-none" />
                             </div>
                        </div>
                    </>
                ) : (
                    <>
                        <h2 className="text-xl font-black leading-tight text-white mb-2">{formData.descricao}</h2>
                        <div className="flex flex-wrap gap-2">
                             <span className="bg-slate-800 px-3 py-1 rounded-lg text-xs font-bold text-slate-300">Cor: {formData.cor}</span>
                             <span className="bg-slate-800 px-3 py-1 rounded-lg text-xs font-bold text-slate-300">SKU: {formData.sku_fornecedor || '-'}</span>
                             <span className="bg-blue-900/30 px-3 py-1 rounded-lg text-xs font-black text-blue-400">{formatBRL(formData.preco_venda)}</span>
                        </div>
                        <p className="text-xs text-slate-500 font-bold mt-2">Forn: {formData.fornecedor}</p>
                    </>
                )}
            </div>
        </section>

        {/* GRADE DE ESTOQUE */}
        <section className="space-y-4">
            <div className="flex justify-between items-center px-2">
                <h3 className="text-xs font-black text-slate-500 uppercase tracking-widest">Estoque por Tamanho</h3>
                <button onClick={() => setModalAddTamanho(true)} className="text-[10px] bg-slate-800 text-white px-3 py-2 rounded-lg font-bold uppercase hover:bg-slate-700 active:scale-95 transition">+ Tamanho</button>
            </div>

            <div className="grid grid-cols-2 min-[400px]:grid-cols-3 sm:grid-cols-4 gap-3">
                {produto.estoque.map((est: any) => (
                    <div key={est.id} className="bg-slate-900 p-3 rounded-2xl border border-slate-800 shadow-sm flex flex-col gap-3 relative group">
                        <div className="flex justify-between items-center">
                            <span className="text-sm font-black text-slate-300">{est.tamanho.nome}</span>
                            <span className={`text-lg font-black ${est.quantidade > 0 ? 'text-white' : 'text-red-500'}`}>{est.quantidade}</span>
                        </div>
                        
                        {/* AQUI ESTAVA O ERRO: Removi corNome: '' */}
                        <button onClick={() => setModalEstoque({ aberto: true, tipo: 'edicao', itemEstoqueId: est.id, tamanhoNome: est.tamanho.nome, qtdAtual: 0, qtdOperacao: '', eanAtual: est.codigo_barras || '', scanning: false })} className="bg-slate-950 py-2 rounded-lg text-[9px] font-mono text-slate-500 truncate border border-slate-800 hover:border-blue-500/50 transition-colors">
                            {est.codigo_barras || 'SEM EAN'}
                        </button>
                        
                        <div className="flex gap-2">
                             {/* AQUI TAMBÉM: Removi corNome: '' */}
                             <button onClick={() => setModalEstoque({ aberto: true, tipo: 'saida', itemEstoqueId: est.id, tamanhoNome: est.tamanho.nome, qtdAtual: est.quantidade, qtdOperacao: '', eanAtual: '', scanning: false })} className="flex-1 bg-red-900/20 text-red-500 rounded-lg font-bold hover:bg-red-600 hover:text-white transition h-8 flex items-center justify-center active:scale-90">-</button>
                             <button onClick={() => setModalEstoque({ aberto: true, tipo: 'entrada', itemEstoqueId: est.id, tamanhoNome: est.tamanho.nome, qtdAtual: est.quantidade, qtdOperacao: '', eanAtual: '', scanning: false })} className="flex-1 bg-green-900/20 text-green-500 rounded-lg font-bold hover:bg-green-600 hover:text-white transition h-8 flex items-center justify-center active:scale-90">+</button>
                        </div>
                    </div>
                ))}
            </div>
        </section>
      </main>

      {/* MODAL ADICIONAR TAMANHO */}
      {modalAddTamanho && (
          <div className="fixed inset-0 z-50 bg-black/90 flex items-center justify-center p-4 backdrop-blur-sm animate-in fade-in">
              <div className="bg-slate-900 p-6 rounded-3xl w-full max-w-xs border border-slate-800 shadow-2xl">
                  <h3 className="text-center font-black text-white mb-4 uppercase text-sm tracking-widest">Novo Tamanho</h3>
                  <select className="w-full bg-slate-950 p-4 rounded-xl border border-slate-700 text-white mb-4 outline-none text-base md:text-sm" onChange={e => setNovoTamanhoId(e.target.value)} value={novoTamanhoId}>
                      <option value="">Selecione...</option>
                      {listaTamanhos.filter(t => !produto.estoque.find((e:any) => e.tamanho_id === t.id)).map(t => (
                          <option key={t.id} value={t.id}>{t.nome}</option>
                      ))}
                  </select>
                  <button onClick={addTamanho} className="w-full bg-pink-600 text-white py-4 rounded-xl font-black uppercase text-xs mb-2 shadow-lg active:scale-95">Adicionar</button>
                  <button onClick={() => setModalAddTamanho(false)} className="w-full bg-slate-800 text-slate-400 py-4 rounded-xl font-black uppercase text-xs active:scale-95">Cancelar</button>
              </div>
          </div>
      )}

      {/* MODAL FOTO */}
      {modalFoto && (
          <div className="fixed inset-0 z-50 bg-black/95 flex flex-col items-center justify-center p-4 backdrop-blur-md">
              {fotoTemp ? (
                  <div className="w-full max-w-sm flex flex-col gap-4">
                      <img src={fotoTemp.url} className="rounded-2xl border-2 border-pink-500 shadow-2xl" alt="" />
                      <button onClick={() => uploadFoto(blobToFile(fotoTemp.blob, 'cam.jpg'))} className="bg-green-600 text-white py-4 rounded-xl font-black uppercase text-xs shadow-lg active:scale-95">Confirmar</button>
                      <button onClick={() => setFotoTemp(null)} className="bg-slate-800 text-white py-4 rounded-xl font-black uppercase text-xs active:scale-95">Tentar de Novo</button>
                  </div>
              ) : (
                  <div className="w-full max-w-sm flex flex-col gap-4">
                      <div className="aspect-[3/4] bg-black rounded-3xl overflow-hidden relative border-2 border-slate-700 shadow-2xl">
                           <video ref={videoRef} autoPlay playsInline className="w-full h-full object-cover" />
                      </div>
                      <div className="flex gap-3">
                           <button onClick={abrirCameraFoto} className="flex-1 bg-pink-600 text-white py-4 rounded-xl font-black uppercase text-xs shadow-lg active:scale-95" onMouseDown={() => {
                               const canvas = document.createElement('canvas');
                               if(videoRef.current){
                                   canvas.width = videoRef.current.videoWidth; canvas.height = videoRef.current.videoHeight;
                                   canvas.getContext('2d')?.drawImage(videoRef.current, 0, 0);
                                   canvas.toBlob(b => b && setFotoTemp({url: URL.createObjectURL(b), blob: b}), 'image/jpeg');
                               }
                           }}>Capturar</button>
                           <label className="flex-1 bg-blue-600 text-white py-4 rounded-xl font-black uppercase text-xs flex items-center justify-center cursor-pointer shadow-lg active:scale-95">
                               Galeria <input type="file" className="hidden" accept="image/*" onChange={handleFileChange} />
                           </label>
                      </div>
                      <button onClick={() => { setModalFoto(false); if(streamRef.current) streamRef.current.getTracks().forEach(t=>t.stop()); }} className="w-full bg-slate-800 text-white py-4 rounded-xl font-black uppercase text-xs active:scale-95">Cancelar</button>
                  </div>
              )}
          </div>
      )}

      {/* MODAL ESTOQUE & EAN (Reutilizado Lógica Simples) */}
      {modalEstoque.aberto && (
          <div className="fixed inset-0 z-[60] bg-black/90 flex items-center justify-center p-4 backdrop-blur-sm animate-in fade-in">
              <div className="bg-slate-900 p-6 rounded-3xl w-full max-w-xs border border-slate-800 shadow-2xl space-y-4">
                  <h3 className="text-center font-black uppercase text-white tracking-widest text-sm">{modalEstoque.tipo === 'edicao' ? 'Editar EAN' : modalEstoque.tipo === 'entrada' ? 'Carga Estoque' : 'Baixa Estoque'}</h3>
                  <p className="text-center text-xs font-bold text-slate-500">{modalEstoque.tamanhoNome}</p>
                  
                  {modalEstoque.tipo === 'edicao' ? (
                      <>
                        <input value={modalEstoque.eanAtual} onChange={e => setModalEstoque({...modalEstoque, eanAtual: e.target.value})} className="w-full bg-slate-950 p-4 rounded-xl text-white font-mono text-center border border-slate-700 outline-none focus:border-blue-500 text-base md:text-sm" placeholder="Sem EAN" />
                        <button onClick={() => setModalEstoque({...modalEstoque, scanning: true})} className="w-full bg-blue-600 text-white py-4 rounded-xl font-bold uppercase text-xs shadow-lg active:scale-95">📷 Ler Cód. Barras</button>
                        {modalEstoque.scanning && <div id="reader-ean-edit" className="h-48 bg-black rounded-xl overflow-hidden border-2 border-blue-500 mt-2"></div>}
                      </>
                  ) : (
                      <input type="number" autoFocus className="w-full bg-slate-950 p-4 rounded-xl text-white text-3xl font-black text-center border border-slate-700 outline-none focus:border-pink-500" placeholder="Qtd" onChange={e => setModalEstoque({...modalEstoque, qtdOperacao: e.target.value})} />
                  )}
                  
                  <div className="flex gap-3 pt-2">
                      <button onClick={() => setModalEstoque({...modalEstoque, aberto: false})} className="flex-1 bg-slate-800 text-white py-4 rounded-xl font-black uppercase text-xs active:scale-95">Cancelar</button>
                      <button onClick={confirmarEstoque} className="flex-1 bg-green-600 text-white py-4 rounded-xl font-black uppercase text-xs shadow-lg active:scale-95">Confirmar</button>
                  </div>
              </div>
          </div>
      )}
    </div>
  );
}