'use client';

import { use, useEffect, useState, useRef } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { supabase } from '../../../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode'; // Motor Direto

// --- UTILITÁRIOS ---
const formatBRL = (val: number | string) => {
  const n = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(n)) return 'R$ 0,00';
  return n.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
};

function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
}

const ordenarEstoquePorTamanho = (estoque: any[]) => {
  return [...estoque].sort((a, b) => (a.tamanho?.ordem ?? 999) - (b.tamanho?.ordem ?? 999));
};

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

const playBeep = () => {
    const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3'); 
    audio.volume = 0.5;
    audio.play().catch(() => {});
    if (typeof window !== 'undefined' && window.navigator && window.navigator.vibrate) {
        window.navigator.vibrate(50); 
    }
};

type Props = {
  params: Promise<{ id: string }>;
};

export default function DetalheItem({ params }: Props) {
  const { id } = use(params);
  const router = useRouter();
  
  // Refs de Mídia (Persistentes)
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const scannerRef = useRef<Html5Qrcode | null>(null);

  // --- ESTADOS ---
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState<string | null>(null); 
  const [editando, setEditando] = useState(false);
  const [produto, setProduto] = useState<any>(null);
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const [erroCarregamento, setErroCarregamento] = useState(false);

  const [listaCores, setListaCores] = useState<any[]>([]);
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);

  // Preview de Foto (Temporário antes de subir)
  const [fotoTemp, setFotoTemp] = useState<{ url: string, blob: Blob } | null>(null);

  // MODAIS
  const [modalFoto, setModalFoto] = useState<{
    aberto: boolean;
    pcId: string;
    corId: string;
    corNome: string;
    urlAtual: string | null;
  }>({ aberto: false, pcId: '', corId: '', corNome: '', urlAtual: null });

  const [camera, setCamera] = useState<{ aberto: boolean; pcId: string; corId: string } | null>(null);

  const [modalEstoque, setModalEstoque] = useState<{
    aberto: boolean;
    tipo: 'entrada' | 'saida' | 'edicao'; 
    itemEstoqueId: string;
    tamanhoNome: string;
    corNome: string;
    qtdAtual: number;
    qtdOperacao: number | string;
    eanAtual: string; 
    scanning: boolean;
  }>({ 
      aberto: false, tipo: 'entrada', itemEstoqueId: '', 
      tamanhoNome: '', corNome: '', qtdAtual: 0, 
      qtdOperacao: '', eanAtual: '', scanning: false 
  });

  const [modalAdicao, setModalAdicao] = useState<{
    aberto: boolean;
    tipo: 'cor' | 'tamanho';
    paiId: string;
    selecionadoId: string;
  }>({ aberto: false, tipo: 'cor', paiId: '', selecionadoId: '' });

  const [formData, setFormData] = useState({
    descricao: '',
    fornecedor: '',
    preco_compra: 0,
    custo_frete: 0,
    custo_embalagem: 0,
    preco_venda: 0,
    margem_ganho: 0,
    descontinuado: false,
  });

  // --- EFEITOS ---
  useEffect(() => {
    if (!produto?.produto_cores) return;
    const gerarLinksSeguros = async () => {
        const pathsToSign = new Set<string>();
        produto.produto_cores.forEach((pc: any) => {
            if (pc.foto_url && !signedMap[pc.foto_url]) pathsToSign.add(pc.foto_url);
        });
        if (modalFoto.urlAtual && !signedMap[modalFoto.urlAtual] && !modalFoto.urlAtual.startsWith('blob:')) {
             pathsToSign.add(modalFoto.urlAtual);
        }
        if (pathsToSign.size === 0) return;
        const newSigned: Record<string, string> = {};
        for (const originalUrl of Array.from(pathsToSign)) {
            const path = extractPath(originalUrl);
            if (path) {
                const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 3600);
                if (data?.signedUrl) newSigned[originalUrl] = data.signedUrl;
            }
        }
        if (Object.keys(newSigned).length > 0) setSignedMap(prev => ({ ...prev, ...newSigned }));
    };
    gerarLinksSeguros();
  }, [produto, modalFoto.urlAtual, signedMap]);

  // --- SCANNER TURBO (EAN) ---
  useEffect(() => {
    if (modalEstoque.aberto && modalEstoque.scanning) {
        const scannerId = "reader-ean-direct";
        const timeout = setTimeout(() => {
            if (!document.getElementById(scannerId)) return;

            const html5QrCode = new Html5Qrcode(scannerId);
            scannerRef.current = html5QrCode;

            html5QrCode.start(
                { facingMode: "environment" },
                { fps: 30, qrbox: { width: 250, height: 100 }, aspectRatio: 1.0 },
                (decodedText) => {
                    playBeep();
                    setModalEstoque(prev => ({ ...prev, eanAtual: decodedText, scanning: false }));
                    fecharScanner();
                },
                (error) => {}
            ).catch(err => {
                console.error(err);
                alert("Erro ao iniciar câmera.");
                setModalEstoque(prev => ({...prev, scanning: false}));
            });
        }, 200);
        return () => clearTimeout(timeout);
    }
  }, [modalEstoque.aberto, modalEstoque.scanning]);

  // --- RECONEXÃO DE VÍDEO (FOTO) ---
  useEffect(() => {
      if (camera?.aberto && !fotoTemp && videoRef.current && streamRef.current) {
          videoRef.current.srcObject = streamRef.current;
          videoRef.current.play().catch(() => {});
      }
  }, [camera, fotoTemp]);

  useEffect(() => { setErroCarregamento(false); }, [modalFoto.urlAtual]);
  useEffect(() => { if (id) carregarDadosIniciais(); }, [id]);

  async function carregarDadosIniciais() {
    setLoading(true);
    await Promise.all([fetchProduto(), fetchAuxiliares()]);
    setLoading(false);
  }

  async function fetchAuxiliares() {
    const { data: cores } = await supabase.from('cores').select('*').order('ordem', { ascending: true });
    const { data: tamanhos } = await supabase.from('tamanhos').select('*').order('ordem', { ascending: true });
    if (cores) setListaCores(cores);
    if (tamanhos) setListaTamanhos(tamanhos);
  }

  async function fetchProduto() {
    const { data, error } = await supabase
      .from('produtos')
      .select(`*, produto_cores (id, foto_url, cor:cores (id, nome, ordem), estoque (id, quantidade, codigo_barras, tamanho:tamanhos (id, nome, ordem)))`)
      .eq('id', id)
      .single();

    if (error) { console.error(error); return; }
    if (data.produto_cores) data.produto_cores.sort((a: any, b: any) => (a.cor?.ordem ?? 999) - (b.cor?.ordem ?? 999));
    setProduto(data);
    
    const custoTotal = (data.preco_compra || 0) + (data.custo_frete || 0) + (data.custo_embalagem || 0);
    const margemInicial = custoTotal > 0 ? ((data.preco_venda - custoTotal) / custoTotal) * 100 : 100;

    setFormData({
      descricao: data.descricao, fornecedor: data.fornecedor || '', preco_compra: data.preco_compra || 0,
      custo_frete: data.custo_frete || 0, custo_embalagem: data.custo_embalagem || 0, preco_venda: data.preco_venda || 0,
      margem_ganho: parseFloat(margemInicial.toFixed(1)), descontinuado: data.descontinuado || false,
    });
  }

  async function processarEnvioFoto(file: File, produtoCorId: string, corId: string) {
    if (!file) return;
    const previewTemporario = URL.createObjectURL(file);
    setModalFoto(prev => ({ ...prev, urlAtual: previewTemporario })); 
    setUploading(produtoCorId);
    setErroCarregamento(false);

    try {
      const fileExt = file.name.split('.').pop();
      const cleanFileName = `${id}_${corId}_${Date.now()}.${fileExt}`;
      const arrayBuffer = await file.arrayBuffer();
      
      const { error: uploadError } = await supabase.storage.from('produtos').upload(cleanFileName, new Uint8Array(arrayBuffer), { contentType: file.type, upsert: true });
      if (uploadError) throw new Error(uploadError.message);

      const { data: publicUrlData } = supabase.storage.from('produtos').getPublicUrl(cleanFileName);
      const finalUrl = `${publicUrlData.publicUrl}`; 

      const { error: dbError } = await supabase.from('produto_cores').update({ foto_url: finalUrl }).eq('id', produtoCorId);
      if (dbError) throw new Error(dbError.message);

      setSignedMap(prev => ({ ...prev, [finalUrl]: previewTemporario })); 
      await fetchProduto(); 
    } catch (error: any) {
      alert(`Erro: ${error.message}.`);
      setModalFoto(prev => ({ ...prev, urlAtual: null })); 
      setErroCarregamento(true);
    } finally {
      setUploading(null);
    }
  }

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files?.[0]) processarEnvioFoto(e.target.files[0], modalFoto.pcId, modalFoto.corId);
  };

  // --- CONTROLES DE CÂMERA ---

  const abrirCamera = async () => {
    setCamera({ aberto: true, pcId: modalFoto.pcId, corId: modalFoto.corId });
    setFotoTemp(null);
    
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ 
          video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } } 
      });
      streamRef.current = stream; // Persiste stream
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch (err) { 
        alert('Câmera indisponível.'); 
        setCamera(null); 
    }
  };

  const capturarFoto = () => {
    if (!videoRef.current) return;
    const v = videoRef.current;
    const canvas = document.createElement('canvas');
    canvas.width = v.videoWidth;
    canvas.height = v.videoHeight;
    canvas.getContext('2d')?.drawImage(v, 0, 0);
    canvas.toBlob((blob) => {
      if (!blob) return;
      const url = URL.createObjectURL(blob);
      setFotoTemp({ url, blob }); // MOSTRA PREVIEW
    }, 'image/jpeg', 0.85);
  };

  const recapturarFoto = () => {
      setFotoTemp(null); // Tira o preview e o useEffect religa o video
  };

  const confirmarFoto = () => {
      if (!fotoTemp || !camera) return;
      const file = blobToFile(fotoTemp.blob, `cam_${Date.now()}.jpg`);
      processarEnvioFoto(file, camera.pcId, camera.corId);
      fecharCamera();
  };

  const fecharCamera = async () => {
    setFotoTemp(null);
    if (streamRef.current) {
        streamRef.current.getTracks().forEach(t => t.stop());
        streamRef.current = null;
    }
    if (videoRef.current) videoRef.current.srcObject = null;
    setCamera(null);
  };

  const fecharScanner = async () => {
      if (scannerRef.current) {
          try {
            if (scannerRef.current.isScanning) await scannerRef.current.stop();
            scannerRef.current.clear();
          } catch(e) { console.log(e); }
      }
      setModalEstoque(prev => ({ ...prev, scanning: false }));
  };

  const handleBankInput = (valorInput: string, campo: keyof typeof formData) => {
    const apenasDigitos = valorInput.replace(/\D/g, '');
    const floatValue = apenasDigitos ? parseFloat(apenasDigitos) / 100 : 0;
    calcularFinanceiro(campo, floatValue);
  };

  const calcularFinanceiro = (campoAlterado: string, novoValor: number) => {
    const dadosFuturos = { ...formData, [campoAlterado]: novoValor };
    const pCompra = Number(dadosFuturos.preco_compra) || 0;
    const pFrete = Number(dadosFuturos.custo_frete) || 0;
    const pEmb = Number(dadosFuturos.custo_embalagem) || 0;
    const custoTotal = pCompra + pFrete + pEmb;
    const margemAtual = Number(dadosFuturos.margem_ganho) || 0;

    if (campoAlterado === 'preco_venda') {
        if (custoTotal > 0) {
            const novaMargem = ((novoValor - custoTotal) / custoTotal) * 100;
            dadosFuturos.margem_ganho = parseFloat(novaMargem.toFixed(1));
        } else {
            dadosFuturos.margem_ganho = 100;
        }
    } else {
        const novoPrecoVenda = custoTotal * (1 + (margemAtual / 100));
        dadosFuturos.preco_venda = novoPrecoVenda;
    }
    setFormData(dadosFuturos);
  };

  const getOpcoesDisponiveis = () => {
    if (modalAdicao.tipo === 'cor') return listaCores.filter(c => !produto.produto_cores.some((pc: any) => pc.cor.id === c.id));
    const pcAtual = produto.produto_cores.find((pc: any) => pc.id === modalAdicao.paiId);
    if (!pcAtual) return [];
    return listaTamanhos.filter(t => !pcAtual.estoque.some((e: any) => e.tamanho.id === t.id));
  };

  async function salvarEdicao() {
    const { error } = await supabase.from('produtos').update({
        descricao: formData.descricao, fornecedor: formData.fornecedor, preco_compra: formData.preco_compra,
        custo_frete: formData.custo_frete, custo_embalagem: formData.custo_embalagem, preco_venda: formData.preco_venda,
        descontinuado: formData.descontinuado,
      }).eq('id', id);
    if (error) return alert('Erro ao salvar');
    setEditando(false);
    fetchProduto();
  }

  async function toggleDescontinuado() {
    const novoStatus = !formData.descontinuado;
    const { error } = await supabase.from('produtos').update({ descontinuado: novoStatus }).eq('id', id);
    if (!error) {
      setFormData(prev => ({ ...prev, descontinuado: novoStatus }));
      setProduto((prev: any) => ({ ...prev, descontinuado: novoStatus }));
    }
  }

  async function confirmarAdicao() {
    if (!modalAdicao.selecionadoId) return alert('Selecione uma opção.');
    setLoading(true);
    let error = null;
    if (modalAdicao.tipo === 'cor') {
      const { error: err } = await supabase.from('produto_cores').insert({ produto_id: id, cor_id: modalAdicao.selecionadoId });
      error = err;
    } else {
      const { error: err } = await supabase.from('estoque').insert({ produto_cor_id: modalAdicao.paiId, tamanho_id: modalAdicao.selecionadoId, quantidade: 0 });
      error = err;
    }
    if (error) alert('Erro ao adicionar');
    else {
      setModalAdicao({ ...modalAdicao, aberto: false, selecionadoId: '' });
      await fetchProduto();
    }
    setLoading(false);
  }

  const abrirModalEstoque = (tipo: 'entrada' | 'saida' | 'edicao', estoqueItem: any, corNome: string) => {
    setModalEstoque({
        aberto: true,
        tipo,
        itemEstoqueId: estoqueItem.id,
        tamanhoNome: estoqueItem.tamanho?.nome,
        corNome,
        qtdAtual: estoqueItem.quantidade,
        qtdOperacao: '',
        eanAtual: estoqueItem.codigo_barras || '',
        scanning: false
    });
  };

  async function confirmarOperacaoEstoque() {
    if (modalEstoque.tipo === 'edicao') {
        setLoading(true);
        const { error } = await supabase.from('estoque').update({ codigo_barras: modalEstoque.eanAtual.trim() || null }).eq('id', modalEstoque.itemEstoqueId);
        if (!error) {
            setModalEstoque({ ...modalEstoque, aberto: false });
            await fetchProduto();
        } else {
            alert('Erro ao salvar EAN (pode estar duplicado).');
        }
        setLoading(false);
        return;
    }

    const qtd = parseInt(String(modalEstoque.qtdOperacao));
    if (isNaN(qtd) || qtd <= 0) return alert('Informe uma quantidade válida.');
    
    let novaQtd = modalEstoque.qtdAtual;
    if (modalEstoque.tipo === 'entrada') novaQtd += qtd;
    else novaQtd -= qtd;

    if (novaQtd < 0) return alert('Estoque negativo não permitido.');

    setLoading(true);
    const { error } = await supabase.from('estoque').update({ quantidade: novaQtd }).eq('id', modalEstoque.itemEstoqueId);
    if (!error) {
      setModalEstoque({ ...modalEstoque, aberto: false });
      await fetchProduto();
    } else {
      alert('Erro: ' + error.message);
    }
    setLoading(false);
  }

  if (loading && !produto) return <div className="min-h-screen bg-slate-950 flex items-center justify-center text-pink-500 font-black animate-pulse">CARREGANDO...</div>;

  const custoTotal = (formData.preco_compra + formData.custo_frete + formData.custo_embalagem);
  const lucro = formData.preco_venda - custoTotal;
  const opcoesFiltradas = modalAdicao.aberto ? getOpcoesDisponiveis() : [];

  return (
    <div className={`min-h-screen bg-slate-950 text-slate-100 font-sans pb-32 ${formData.descontinuado ? 'grayscale-[0.8]' : ''}`}>
      
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
        {/* STATUS BAR */}
        <div className="bg-slate-900 rounded-2xl p-4 flex justify-between items-center border border-slate-800 shadow-md">
            <div>
                <h1 className="font-black italic text-lg tracking-tighter leading-none text-white">
                    {produto?.codigo_peca}
                </h1>
                <span className="text-[9px] text-slate-500 uppercase font-bold tracking-widest">Código</span>
            </div>
            <button onClick={toggleDescontinuado} className={`px-4 py-2 rounded-xl text-[9px] font-black uppercase tracking-widest transition-all ${formData.descontinuado ? 'bg-red-900/30 text-red-500 border border-red-900' : 'bg-green-900/30 text-green-400 border border-green-900'}`}>
                {formData.descontinuado ? '🚫 Descontinuado' : '✅ Ativo'}
            </button>
        </div>

        {/* INFO GERAL */}
        <section className={`bg-slate-900 p-6 rounded-[2rem] border transition-colors shadow-xl space-y-6 relative overflow-hidden ${editando ? 'border-pink-500/30' : 'border-slate-800'}`}>
            {editando && <div className="absolute top-0 right-0 bg-pink-600 text-white text-[9px] font-bold px-3 py-1 rounded-bl-xl shadow-md z-10">MODO EDIÇÃO</div>}
            
            <div className="space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Descrição</label>
                {editando ? (
                    <input value={formData.descricao} onChange={e => setFormData({...formData, descricao: e.target.value})} className="w-full bg-slate-950 border border-pink-500/50 p-4 rounded-xl text-base font-bold outline-none text-white" />
                ) : <h2 className="text-xl font-black text-white px-2 leading-tight">{formData.descricao}</h2>}
            </div>

            {/* FINANCEIRO (RESUMIDO) */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4 pt-4 border-t border-slate-800/50">
                <div className="col-span-2 md:col-span-1">
                    <span className="block text-[9px] text-slate-500 font-black uppercase mb-1">Custos Totais</span>
                    <div className="text-sm font-bold text-slate-300">
                        {editando ? (
                            <div className="space-y-2">
                                <input type="tel" inputMode="decimal" className="w-full bg-slate-950 text-sm p-2 rounded-lg border border-slate-700 focus:border-pink-500 text-white" value={formatBRL(formData.preco_compra)} onChange={e => handleBankInput(e.target.value, 'preco_compra')} placeholder="Peça" />
                                <div className="flex gap-2">
                                    <input type="tel" inputMode="decimal" className="w-full bg-slate-950 text-xs p-2 rounded-lg border border-slate-700 focus:border-pink-500 text-white" value={formatBRL(formData.custo_frete)} onChange={e => handleBankInput(e.target.value, 'custo_frete')} placeholder="Frete" />
                                    <input type="tel" inputMode="decimal" className="w-full bg-slate-950 text-xs p-2 rounded-lg border border-slate-700 focus:border-pink-500 text-white" value={formatBRL(formData.custo_embalagem)} onChange={e => handleBankInput(e.target.value, 'custo_embalagem')} placeholder="Emb" />
                                </div>
                            </div>
                        ) : <span className="text-xl font-bold">{formatBRL(custoTotal)}</span>}
                    </div>
                </div>
                <div className="bg-blue-900/10 p-3 rounded-xl border border-blue-900/20">
                    <span className="block text-[9px] text-blue-400 font-black uppercase mb-1">Venda</span>
                    {editando ? (
                         <input type="tel" inputMode="decimal" className="w-full bg-slate-900 text-blue-400 font-black p-3 rounded-lg border border-blue-500/30 outline-none text-xl text-center" value={formatBRL(formData.preco_venda)} onChange={e => handleBankInput(e.target.value, 'preco_venda')} />
                    ) : <span className="text-2xl font-black text-blue-400">{formatBRL(formData.preco_venda)}</span>}
                </div>
                <div className="bg-slate-950 p-3 rounded-xl border border-slate-800">
                    <span className="block text-[9px] text-slate-500 font-black uppercase mb-1">Margem</span>
                    {editando ? (
                        <div className="flex items-center gap-1 justify-center h-full">
                            <input type="number" inputMode="decimal" step="0.1" value={formData.margem_ganho} onChange={e => calcularFinanceiro('margem_ganho', parseFloat(e.target.value))} className="w-full bg-transparent text-white font-black text-xl outline-none text-center" />
                            <span className="text-sm font-bold text-slate-500">%</span>
                        </div>
                    ) : <span className="text-2xl font-black text-white">{formData.margem_ganho.toFixed(1)}%</span>}
                </div>
                <div className="bg-green-900/10 p-3 rounded-xl border border-green-900/20 flex flex-col justify-center">
                    <span className="block text-[9px] text-green-500 font-black uppercase mb-1">Lucro</span>
                    <span className="text-xl font-black text-green-400">{formatBRL(lucro)}</span>
                </div>
            </div>
        </section>

        {/* --- ESTOQUE / CORES --- */}
        <div className="flex justify-between items-end pt-4">
            <h3 className="text-sm font-black text-slate-500 uppercase tracking-widest pl-2">Estoque / Cores</h3>
            <button onClick={() => setModalAdicao({ aberto: true, tipo: 'cor', paiId: id, selecionadoId: '' })} className="bg-pink-600 hover:bg-pink-500 text-white text-[10px] font-black uppercase px-4 py-3 rounded-xl shadow-lg active:scale-95 transition-transform">
                + Nova Cor
            </button>
        </div>
        
        <div className="space-y-6">
            {produto?.produto_cores?.map((pc: any) => (
                <div key={pc.id} className="bg-slate-900 rounded-[2rem] p-4 md:p-6 border border-slate-800 shadow-xl relative animate-in fade-in slide-in-from-bottom-4">
                    <div className="flex justify-between items-start mb-6 border-b border-slate-800/50 pb-4">
                         <div className="flex items-center gap-4">
                            <button 
                                onClick={() => setModalFoto({ aberto: true, pcId: pc.id, corId: pc.cor.id, corNome: pc.cor?.nome, urlAtual: pc.foto_url })}
                                className="relative group w-20 h-20 active:scale-95 transition-transform"
                            >
                                <div className={`w-full h-full rounded-2xl overflow-hidden border-2 border-slate-700 hover:border-pink-500 transition-colors bg-slate-950 flex items-center justify-center relative shadow-lg`}>
                                    {pc.foto_url && signedMap[pc.foto_url] ? (
                                        // eslint-disable-next-line @next/next/no-img-element
                                        <img src={signedMap[pc.foto_url]} alt={pc.cor?.nome} className="w-full h-full object-cover" />
                                    ) : <span className="text-2xl opacity-30">📷</span>}
                                    <div className="absolute bottom-1 right-1 bg-black/60 rounded-full p-1.5 backdrop-blur-sm">
                                        <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse"></div>
                                    </div>
                                </div>
                            </button>
                            <div>
                                <div className="flex items-center gap-2 mb-1">
                                    <h4 className="text-lg font-black text-white uppercase">{pc.cor?.nome}</h4>
                                </div>
                                <p className="text-[10px] text-slate-500 font-bold bg-slate-950 px-2 py-1 rounded-lg inline-block">Toque na foto p/ editar</p>
                            </div>
                        </div>
                        <button onClick={() => setModalAdicao({ aberto: true, tipo: 'tamanho', paiId: pc.id, selecionadoId: '' })} className="bg-slate-800 hover:bg-slate-700 text-slate-300 text-[10px] font-bold uppercase px-4 py-2 rounded-xl border border-slate-700 transition-colors active:scale-95">
                            + Add Tam
                        </button>
                    </div>

                    <div className="grid grid-cols-2 min-[400px]:grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-3">
                        {pc.estoque.length === 0 ? (
                            <p className="col-span-full text-center text-slate-600 text-[10px] py-4 bg-slate-950/50 rounded-xl border border-dashed border-slate-800">Sem tamanhos cadastrados.</p>
                        ) : ordenarEstoquePorTamanho(pc.estoque).map((est: any) => (
                            <div key={est.id} className="bg-slate-950 p-3 rounded-2xl border border-slate-800 flex flex-col justify-between gap-3 shadow-sm relative group">
                                <div className="flex justify-between items-center px-1">
                                    <span className="text-xs font-black text-slate-400">{est.tamanho?.nome}</span>
                                    <span className={`text-base font-black ${est.quantidade > 0 ? 'text-white' : 'text-red-500'}`}>{est.quantidade}</span>
                                </div>
                                
                                {/* BOTÃO EAN NO CARTÃO */}
                                <button 
                                    onClick={() => abrirModalEstoque('edicao', est, pc.cor?.nome)} 
                                    className="w-full flex items-center justify-center gap-1 py-2 bg-slate-900 rounded-lg border border-slate-700/50 hover:border-blue-500/50 transition-colors"
                                >
                                    <span className="text-[10px] text-slate-500">|||</span>
                                    <span className="text-[9px] font-mono text-slate-400 truncate max-w-[80px]">
                                        {est.codigo_barras || 'Sem EAN'}
                                    </span>
                                </button>

                                <div className="flex w-full gap-2">
                                    <button onClick={() => abrirModalEstoque('saida', est, pc.cor?.nome)} className="flex-1 h-10 rounded-xl bg-red-950/20 text-red-500 hover:bg-red-600 hover:text-white transition-colors font-black text-lg flex items-center justify-center active:scale-95 border border-red-900/20">-</button>
                                    <button onClick={() => abrirModalEstoque('entrada', est, pc.cor?.nome)} className="flex-1 h-10 rounded-xl bg-green-950/20 text-green-500 hover:bg-green-600 hover:text-white transition-colors font-black text-lg flex items-center justify-center active:scale-95 border border-green-900/20">+</button>
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            ))}
        </div>
      </main>

      {/* --- MODAIS --- */}

      {/* MODAL ADIÇÃO */}
      {modalAdicao.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-sm flex items-center justify-center p-6 animate-in fade-in zoom-in-95 duration-200">
            <div className="bg-slate-900 w-full max-w-sm rounded-[2rem] p-6 border border-slate-800 shadow-2xl">
                <h3 className="text-lg font-black text-white uppercase mb-4 text-center">Adicionar {modalAdicao.tipo === 'cor' ? 'Nova Cor' : 'Novo Tamanho'}</h3>
                <div className="space-y-4">
                    {opcoesFiltradas.length === 0 ? (
                         <div className="bg-amber-900/20 text-amber-500 p-4 rounded-xl text-center text-xs font-bold border border-amber-900/50">Todas as opções já foram adicionadas.</div>
                    ) : (
                        <select className="w-full bg-slate-950 border border-slate-700 text-white p-4 rounded-xl outline-none focus:border-pink-500 h-14 text-base" value={modalAdicao.selecionadoId} onChange={(e) => setModalAdicao({ ...modalAdicao, selecionadoId: e.target.value })}>
                            <option value="">-- Selecione --</option>
                            {opcoesFiltradas.map(opt => <option key={opt.id} value={opt.id}>{opt.nome}</option>)}
                        </select>
                    )}
                    <div className="flex gap-3 pt-4">
                        <button onClick={() => setModalAdicao({ ...modalAdicao, aberto: false })} className="flex-1 bg-slate-800 text-slate-300 font-bold py-4 rounded-xl uppercase text-xs active:scale-95">Cancelar</button>
                        {opcoesFiltradas.length > 0 && <button onClick={confirmarAdicao} className="flex-1 bg-pink-600 text-white font-black py-4 rounded-xl uppercase text-xs shadow-lg active:scale-95">Salvar</button>}
                    </div>
                </div>
            </div>
        </div>
      )}

      {/* MODAL ESTOQUE & EAN (SCANNER TURBO) */}
      {modalEstoque.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-sm flex items-center justify-center p-6 animate-in fade-in zoom-in-95 duration-200">
            <div className="bg-slate-900 w-full max-w-sm rounded-[2.5rem] p-8 border border-slate-800 shadow-2xl space-y-6">
                
                <div className="text-center space-y-2">
                    <h3 className={`text-xl font-black uppercase tracking-tight ${modalEstoque.tipo === 'entrada' ? 'text-green-500' : modalEstoque.tipo === 'saida' ? 'text-red-500' : 'text-blue-400'}`}>
                        {modalEstoque.tipo === 'entrada' ? '📦 Carga' : modalEstoque.tipo === 'saida' ? '📉 Baixa' : '✏️ Editar EAN'}
                    </h3>
                    <p className="text-slate-400 text-sm font-bold">{modalEstoque.corNome} - Tam. {modalEstoque.tamanhoNome}</p>
                </div>
                
                {modalEstoque.scanning ? (
                    <div className="space-y-4">
                        <div id="reader-ean-direct" className="w-full rounded-2xl overflow-hidden border-2 border-blue-500 h-64 bg-black"></div>
                        <button onClick={fecharScanner} className="w-full bg-slate-800 text-white py-3 rounded-xl font-bold uppercase text-xs">Cancelar Scanner</button>
                    </div>
                ) : (
                    <>
                        {/* MODO CARGA/BAIXA */}
                        {modalEstoque.tipo !== 'edicao' && (
                            <div className="space-y-4">
                                <div className="flex items-center justify-center gap-4">
                                    <div className="bg-slate-950 p-4 px-6 rounded-2xl border border-slate-800 text-center">
                                        <span className="text-2xl font-black text-white">{modalEstoque.qtdAtual}</span>
                                        <span className="block text-[8px] text-slate-500 font-bold uppercase">Atual</span>
                                    </div>
                                    <span className="text-slate-600">➜</span>
                                    <div className={`p-4 px-6 rounded-2xl border text-center ${modalEstoque.tipo === 'entrada' ? 'bg-green-900/20 border-green-900/50' : 'bg-red-900/20 border-red-900/50'}`}>
                                        <span className={`text-2xl font-black ${modalEstoque.tipo === 'entrada' ? 'text-green-400' : 'text-red-400'}`}>
                                            {modalEstoque.qtdOperacao ? (modalEstoque.tipo === 'entrada' ? modalEstoque.qtdAtual + Number(modalEstoque.qtdOperacao) : modalEstoque.qtdAtual - Number(modalEstoque.qtdOperacao)) : '-'}
                                        </span>
                                        <span className="block text-[8px] text-slate-500 font-bold uppercase">Novo</span>
                                    </div>
                                </div>
                                <input type="number" inputMode="numeric" autoFocus value={modalEstoque.qtdOperacao} onChange={e => { const val = e.target.value; setModalEstoque({...modalEstoque, qtdOperacao: val === '' ? '' : parseInt(val)}) }} className="w-full bg-slate-950 border-2 border-slate-700 focus:border-pink-500 p-4 rounded-2xl text-center text-3xl font-black text-white outline-none" placeholder="Qtd..." />
                            </div>
                        )}

                        {/* MODO EDIÇÃO EAN */}
                        {modalEstoque.tipo === 'edicao' && (
                            <div className="pt-4 border-t border-slate-800">
                                <label className="text-[10px] text-slate-500 font-black uppercase mb-2 block">Código de Barras (EAN)</label>
                                <div className="flex gap-2">
                                    <input type="text" value={modalEstoque.eanAtual} onChange={e => setModalEstoque({...modalEstoque, eanAtual: e.target.value})} className="flex-1 bg-slate-950 border border-slate-800 focus:border-blue-500 text-white p-4 rounded-xl outline-none font-mono text-base font-bold tracking-widest placeholder:text-slate-700" placeholder="Sem Código" />
                                    <button onClick={() => setModalEstoque({...modalEstoque, scanning: true})} className="bg-blue-600 hover:bg-blue-500 text-white w-14 rounded-xl flex items-center justify-center text-2xl shadow-lg active:scale-95">📷</button>
                                </div>
                                <p className="text-[9px] text-amber-500 mt-4 font-bold flex items-center gap-1 bg-amber-900/20 p-2 rounded-lg border border-amber-900/50 justify-center">⚠️ Cuidado: Alterar o EAN pode duplicar.</p>
                            </div>
                        )}
                        
                        <div className="grid grid-cols-2 gap-4">
                            <button onClick={() => setModalEstoque({...modalEstoque, aberto: false})} className="bg-slate-800 text-white font-bold py-4 rounded-xl text-xs uppercase active:scale-95">Cancelar</button>
                            <button onClick={confirmarOperacaoEstoque} className={`font-black py-4 rounded-xl text-xs uppercase text-white shadow-lg active:scale-95 ${modalEstoque.tipo === 'entrada' ? 'bg-green-600 hover:bg-green-500' : modalEstoque.tipo === 'saida' ? 'bg-red-600 hover:bg-red-500' : 'bg-blue-600 hover:bg-blue-500'}`}>Confirmar</button>
                        </div>
                    </>
                )}
            </div>
        </div>
      )}

      {/* MODAL GESTÃO DE FOTO */}
      {modalFoto.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-md flex items-center justify-center p-6 animate-in fade-in duration-200">
            <div className="w-full max-w-sm flex flex-col gap-6 relative">
                <div className="flex justify-between items-center text-white">
                    <h3 className="font-black uppercase tracking-widest text-sm">Foto: {modalFoto.corNome}</h3>
                    <button onClick={() => setModalFoto({ ...modalFoto, aberto: false })} className="w-10 h-10 rounded-full bg-slate-800 text-slate-400 font-bold flex items-center justify-center active:scale-95">✕</button>
                </div>
                <div className="aspect-[3/4] bg-slate-900 rounded-3xl border-2 border-slate-800 overflow-hidden flex items-center justify-center relative shadow-2xl">
                    {uploading === modalFoto.pcId ? (
                        <div className="flex flex-col items-center gap-2">
                            <div className="w-10 h-10 border-4 border-pink-500 border-t-transparent rounded-full animate-spin"></div>
                            <span className="text-xs font-bold text-pink-500 uppercase tracking-widest">Enviando...</span>
                        </div>
                    ) : erroCarregamento ? (
                        <div className="flex flex-col items-center justify-center h-full text-red-500">
                           <span className="text-3xl mb-2">⚠️</span>
                           <span className="text-xs font-bold uppercase text-center px-4">Erro ao carregar</span>
                           <button onClick={() => setErroCarregamento(false)} className="mt-4 text-[10px] underline text-slate-400 p-2">Tentar novamente</button>
                        </div>
                    ) : modalFoto.urlAtual && signedMap[modalFoto.urlAtual] ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img key={signedMap[modalFoto.urlAtual]} src={signedMap[modalFoto.urlAtual]} className="w-full h-full object-cover" alt="Preview" onError={() => setErroCarregamento(true)} />
                    ) : (
                        <span className="text-4xl opacity-20">📷</span>
                    )}
                </div>
                <div className="grid grid-cols-2 gap-4">
                    <button onClick={abrirCamera} className="bg-slate-800 hover:bg-slate-700 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest flex flex-col items-center gap-2 active:scale-95 transition-all">
                        <span className="text-2xl">📷</span> Câmera
                    </button>
                    <label className="bg-slate-800 hover:bg-slate-700 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest flex flex-col items-center gap-2 cursor-pointer active:scale-95 transition-all">
                        <span className="text-2xl">📂</span> Galeria
                        <input type="file" accept="image/*" className="hidden" onChange={handleFileChange} />
                    </label>
                </div>
            </div>
        </div>
      )}

      {/* MODAL CÂMERA (FOTO COM PREVIEW E CONFIRMAÇÃO) */}
      {camera?.aberto && (
        <div className="fixed inset-0 z-[100] bg-black flex flex-col items-center justify-center p-4">
             <div className="w-full max-w-sm flex flex-col items-center gap-6">
               <h3 className="text-white font-black uppercase tracking-widest text-sm">
                   {fotoTemp ? 'Confirmar Foto' : 'Tirar Foto'}
               </h3>
               
               <div className="w-full aspect-[3/4] rounded-3xl border-2 border-pink-500 overflow-hidden bg-black shadow-2xl relative">
                   {fotoTemp ? (
                       // PREVIEW
                       // eslint-disable-next-line @next/next/no-img-element
                       <img src={fotoTemp.url} className="w-full h-full object-cover" alt="Preview" />
                   ) : (
                       // VÍDEO
                       <video ref={videoRef} autoPlay playsInline className="w-full h-full object-cover" />
                   )}
               </div>

               <div className="flex gap-4 w-full">
                 {fotoTemp ? (
                     <>
                        <button onClick={confirmarFoto} className="flex-1 bg-green-600 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95">Usar Foto</button>
                        <button onClick={recapturarFoto} className="flex-1 bg-slate-800 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95">Tentar De Novo</button>
                     </>
                 ) : (
                     <>
                        <button onClick={capturarFoto} className="flex-1 bg-pink-600 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95">Capturar</button>
                        <button onClick={fecharCamera} className="flex-1 bg-slate-800 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95">Cancelar</button>
                     </>
                 )}
               </div>
             </div>
        </div>
      )}
    </div>
  );
}