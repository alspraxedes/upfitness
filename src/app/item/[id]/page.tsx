'use client';

import { use, useEffect, useState, useRef } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { supabase } from '../../../lib/supabase';

// --- UTILITÁRIOS ---
const formatBRL = (val: number | string) => {
  const n = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(n)) return 'R$ 0,00';
  return n.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
};

function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
}

const ordenarPorBanco = (lista: any[]) => {
  return [...lista].sort((a, b) => (a.ordem ?? 999) - (b.ordem ?? 999));
};

const ordenarEstoquePorTamanho = (estoque: any[]) => {
  return [...estoque].sort((a, b) => (a.tamanho?.ordem ?? 999) - (b.tamanho?.ordem ?? 999));
};

type Props = {
  params: Promise<{ id: string }>;
};

export default function DetalheItem({ params }: Props) {
  const { id } = use(params);
  const router = useRouter();
  const videoRef = useRef<HTMLVideoElement>(null);

  // --- ESTADOS ---
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState<string | null>(null); 
  const [editando, setEditando] = useState(false);
  const [produto, setProduto] = useState<any>(null);
  
  // Estado para controlar erro de carregamento da imagem no modal (NOVO)
  const [erroCarregamento, setErroCarregamento] = useState(false);

  const [listaCores, setListaCores] = useState<any[]>([]);
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);

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
    tipo: 'entrada' | 'saida';
    itemEstoqueId: string;
    tamanhoNome: string;
    corNome: string;
    qtdAtual: number;
    qtdOperacao: number | string;
  }>({ aberto: false, tipo: 'entrada', itemEstoqueId: '', tamanhoNome: '', corNome: '', qtdAtual: 0, qtdOperacao: '' });

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
  
  // Resetar erro de imagem sempre que a URL do modal mudar
  useEffect(() => {
    setErroCarregamento(false);
  }, [modalFoto.urlAtual]);

  useEffect(() => {
    if (id) carregarDadosIniciais();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

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
      .select(`
        *,
        produto_cores (
          id,
          foto_url,
          cor:cores ( id, nome, ordem ),
          estoque (
            id,
            quantidade,
            codigo_barras,
            tamanho:tamanhos ( id, nome, ordem )
          )
        )
      `)
      .eq('id', id)
      .single();

    if (error) {
      console.error(error);
      return;
    }

    if (data.produto_cores) {
      data.produto_cores.sort((a: any, b: any) => (a.cor?.ordem ?? 999) - (b.cor?.ordem ?? 999));
    }

    setProduto(data);

    const custoTotal = (data.preco_compra || 0) + (data.custo_frete || 0) + (data.custo_embalagem || 0);
    const margemInicial = custoTotal > 0 
      ? ((data.preco_venda - custoTotal) / custoTotal) * 100 
      : 100;

    setFormData({
      descricao: data.descricao,
      fornecedor: data.fornecedor || '',
      preco_compra: data.preco_compra || 0,
      custo_frete: data.custo_frete || 0,
      custo_embalagem: data.custo_embalagem || 0,
      preco_venda: data.preco_venda || 0,
      margem_ganho: parseFloat(margemInicial.toFixed(1)),
      descontinuado: data.descontinuado || false,
    });
  }

  // --- LÓGICA DE UPLOAD ---
  async function processarEnvioFoto(file: File, produtoCorId: string, corId: string) {
    if (!file) return;

    const previewTemporario = URL.createObjectURL(file);
    setModalFoto(prev => ({ ...prev, urlAtual: previewTemporario })); 
    setUploading(produtoCorId);
    setErroCarregamento(false); // Reseta erro ao começar upload

    try {
      const fileExt = file.name.split('.').pop();
      // Nome sem caracteres especiais para evitar problemas de URL
      const cleanFileName = `${id}_${corId}_${Date.now()}.${fileExt}`;

      const arrayBuffer = await file.arrayBuffer();
      const fileBuffer = new Uint8Array(arrayBuffer);

      // Upload
      const { error: uploadError } = await supabase.storage
        .from('produtos')
        .upload(cleanFileName, fileBuffer, {
          contentType: file.type,
          upsert: true,
        });

      if (uploadError) throw new Error(uploadError.message);

      // URL Pública
      const { data: publicUrlData } = supabase.storage
        .from('produtos')
        .getPublicUrl(cleanFileName);
        
      if (!publicUrlData.publicUrl) throw new Error('Erro URL pública');

      // Cache Busting
      const finalUrl = `${publicUrlData.publicUrl}?v=${Date.now()}`;

      // Update Banco
      const { error: dbError } = await supabase
        .from('produto_cores')
        .update({ foto_url: finalUrl })
        .eq('id', produtoCorId);

      if (dbError) throw new Error(dbError.message);

      // Sucesso
      setModalFoto(prev => ({ ...prev, urlAtual: finalUrl })); 
      await fetchProduto(); 

    } catch (error: any) {
      console.error('Falha:', error);
      alert(`Erro: ${error.message}.`);
      setModalFoto(prev => ({ ...prev, urlAtual: null })); 
      setErroCarregamento(true);
    } finally {
      setUploading(null);
    }
  }

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files?.[0]) {
      processarEnvioFoto(e.target.files[0], modalFoto.pcId, modalFoto.corId);
    }
  };

  // --- CÂMERA ---
  const abrirCamera = async () => {
    setCamera({ aberto: true, pcId: modalFoto.pcId, corId: modalFoto.corId });
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
      setTimeout(() => { if (videoRef.current) videoRef.current.srcObject = stream; }, 100);
    } catch (err) {
      alert('Câmera indisponível.');
      setCamera(null);
    }
  };

  const fecharCamera = () => {
    const stream = videoRef.current?.srcObject as MediaStream | null;
    stream?.getTracks().forEach((t) => t.stop());
    if (videoRef.current) videoRef.current.srcObject = null;
    setCamera(null);
  };

  const tirarFoto = () => {
    if (!videoRef.current || !camera) return;
    const canvas = document.createElement('canvas');
    canvas.width = videoRef.current.videoWidth;
    canvas.height = videoRef.current.videoHeight;
    canvas.getContext('2d')?.drawImage(videoRef.current, 0, 0);
    
    canvas.toBlob((blob) => {
      if (!blob) return;
      const file = blobToFile(blob, `cam_${Date.now()}.jpg`);
      processarEnvioFoto(file, camera.pcId, camera.corId);
      fecharCamera();
    }, 'image/jpeg');
  };

  // --- FINANCEIRO ---
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

  // --- ACTIONS ---
  const getOpcoesDisponiveis = () => {
    if (modalAdicao.tipo === 'cor') {
      return listaCores.filter(c => !produto.produto_cores.some((pc: any) => pc.cor.id === c.id));
    } else {
      const pcAtual = produto.produto_cores.find((pc: any) => pc.id === modalAdicao.paiId);
      if (!pcAtual) return [];
      return listaTamanhos.filter(t => !pcAtual.estoque.some((e: any) => e.tamanho.id === t.id));
    }
  };

  async function salvarEdicao() {
    const { error } = await supabase.from('produtos').update({
        descricao: formData.descricao,
        fornecedor: formData.fornecedor,
        preco_compra: formData.preco_compra,
        custo_frete: formData.custo_frete,
        custo_embalagem: formData.custo_embalagem,
        preco_venda: formData.preco_venda,
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

  const abrirModalEstoque = (tipo: 'entrada' | 'saida', estoqueItem: any, corNome: string) => {
    setModalEstoque({ aberto: true, tipo, itemEstoqueId: estoqueItem.id, tamanhoNome: estoqueItem.tamanho?.nome, corNome, qtdAtual: estoqueItem.quantidade, qtdOperacao: '' });
  };

  async function confirmarOperacaoEstoque() {
    const qtd = parseInt(String(modalEstoque.qtdOperacao));
    if (!qtd || qtd <= 0) return alert('Qtd inválida.');
    const novaQtd = modalEstoque.tipo === 'entrada' ? modalEstoque.qtdAtual + qtd : modalEstoque.qtdAtual - qtd;
    if (novaQtd < 0) return alert('Estoque negativo não permitido.');

    setLoading(true);
    const { error } = await supabase.from('estoque').update({ quantidade: novaQtd }).eq('id', modalEstoque.itemEstoqueId);
    if (!error) {
      setModalEstoque({ ...modalEstoque, aberto: false });
      await fetchProduto();
    }
    setLoading(false);
  }

  if (loading && !produto) return <div className="min-h-screen bg-slate-950 flex items-center justify-center text-pink-500 font-black animate-pulse">CARREGANDO...</div>;

  const custoTotal = (formData.preco_compra + formData.custo_frete + formData.custo_embalagem);
  const lucro = formData.preco_venda - custoTotal;
  const opcoesFiltradas = modalAdicao.aberto ? getOpcoesDisponiveis() : [];

  return (
    <div className={`min-h-screen bg-slate-950 text-slate-100 font-sans pb-32 ${formData.descontinuado ? 'grayscale-[0.8]' : ''}`}>
      
      {/* HEADER */}
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-6 shadow-2xl mb-8 flex justify-between items-center sticky top-0 z-40">
        <div className="flex items-center gap-4">
            <Link href="/" className="bg-black/20 hover:bg-black/40 p-2 rounded-full text-white transition-colors">←</Link>
            <div>
                <h1 className="font-black italic text-xl tracking-tighter leading-none">DETALHES <span className="font-light tracking-normal text-white/80">DA PEÇA</span></h1>
                <p className="text-[10px] font-mono text-white/60">{produto?.codigo_peca}</p>
            </div>
        </div>
        <div className="flex gap-2">
            {!editando ? (
                <button onClick={() => setEditando(true)} className="bg-white text-pink-600 px-4 py-2 rounded-full text-[10px] font-black uppercase tracking-widest shadow-lg hover:scale-105 transition-transform">Editar</button>
            ) : (
                <button onClick={salvarEdicao} className="bg-green-500 text-white px-6 py-2 rounded-full text-[10px] font-black uppercase tracking-widest shadow-lg hover:scale-105 transition-transform">Salvar</button>
            )}
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 space-y-6">

        {/* STATUS */}
        <div className="bg-slate-900 rounded-2xl p-4 flex justify-between items-center border border-slate-800">
            <span className="text-xs font-bold text-slate-400 uppercase tracking-widest">Situação</span>
            <button onClick={toggleDescontinuado} className={`px-4 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest transition-all ${formData.descontinuado ? 'bg-red-900/30 text-red-500 border border-red-900' : 'bg-green-900/30 text-green-400 border border-green-900'}`}>
                {formData.descontinuado ? '🚫 Descontinuado' : '✅ Ativo'}
            </button>
        </div>

        {/* INFO GERAL */}
        <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-6 relative overflow-hidden">
            {editando && <div className="absolute top-0 right-0 bg-pink-600 text-white text-[9px] font-bold px-3 py-1 rounded-bl-xl">MODO EDIÇÃO</div>}
            
            <div className="space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Descrição</label>
                {editando ? (
                    <input value={formData.descricao} onChange={e => setFormData({...formData, descricao: e.target.value})} className="w-full bg-slate-950 border border-pink-500/50 p-4 rounded-xl text-lg font-bold outline-none" />
                ) : <h2 className="text-xl font-black text-white px-2">{formData.descricao}</h2>}
            </div>

            <div className="space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Fornecedor</label>
                {editando ? (
                    <input value={formData.fornecedor} onChange={e => setFormData({...formData, fornecedor: e.target.value})} className="w-full bg-slate-950 border border-pink-500/50 p-3 rounded-xl text-sm outline-none" />
                ) : <p className="text-sm text-slate-300 font-bold px-2 flex items-center gap-2">🏭 {formData.fornecedor}</p>}
            </div>

            {/* FINANCEIRO */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4 pt-4 border-t border-slate-800/50">
                <div>
                    <span className="block text-[9px] text-slate-500 font-black uppercase mb-1">Custo Total</span>
                    <div className="text-sm font-bold text-slate-300">
                        {editando ? (
                            <div className="space-y-2">
                                <div className="relative">
                                    <span className="text-[9px] absolute left-2 top-2 text-slate-500">PEÇA</span>
                                    <input type="tel" className="w-full bg-slate-950 text-xs p-2 pt-5 rounded border border-slate-700 outline-none focus:border-pink-500" value={formatBRL(formData.preco_compra)} onChange={e => handleBankInput(e.target.value, 'preco_compra')} />
                                </div>
                                <div className="grid grid-cols-2 gap-2">
                                    <div className="relative">
                                        <span className="text-[8px] absolute left-1 top-1 text-slate-500">FRETE</span>
                                        <input type="tel" className="w-full bg-slate-950 text-[10px] p-1 pt-4 rounded border border-slate-700 outline-none focus:border-pink-500" value={formatBRL(formData.custo_frete)} onChange={e => handleBankInput(e.target.value, 'custo_frete')} />
                                    </div>
                                    <div className="relative">
                                        <span className="text-[8px] absolute left-1 top-1 text-slate-500">EMB.</span>
                                        <input type="tel" className="w-full bg-slate-950 text-[10px] p-1 pt-4 rounded border border-slate-700 outline-none focus:border-pink-500" value={formatBRL(formData.custo_embalagem)} onChange={e => handleBankInput(e.target.value, 'custo_embalagem')} />
                                    </div>
                                </div>
                            </div>
                        ) : formatBRL(custoTotal)}
                    </div>
                </div>
                <div>
                    <span className="block text-[9px] text-pink-500 font-black uppercase mb-1">Venda</span>
                    {editando ? (
                         <input type="tel" className="w-full bg-slate-950 text-blue-400 font-bold p-2 rounded border border-pink-500/50 outline-none text-lg" value={formatBRL(formData.preco_venda)} onChange={e => handleBankInput(e.target.value, 'preco_venda')} />
                    ) : <span className="text-lg font-black text-blue-400">{formatBRL(formData.preco_venda)}</span>}
                </div>
                <div>
                    <span className="block text-[9px] text-slate-500 font-black uppercase mb-1">Lucro R$</span>
                    <span className="text-sm font-bold text-green-400">{formatBRL(lucro)}</span>
                </div>
                <div>
                    <span className="block text-[9px] text-slate-500 font-black uppercase mb-1">Margem %</span>
                    {editando ? (
                        <div className="flex items-center gap-1">
                            <input type="number" step="0.1" value={formData.margem_ganho} onChange={e => calcularFinanceiro('margem_ganho', parseFloat(e.target.value))} className="w-full bg-slate-950 text-white font-bold p-2 rounded border border-pink-500/50 outline-none text-sm text-center" />
                            <span className="text-xs font-bold text-slate-500">%</span>
                        </div>
                    ) : <span className="text-sm font-bold text-white">{formData.margem_ganho.toFixed(1)}%</span>}
                </div>
            </div>
        </section>

        {/* --- AREA DE ESTOQUE --- */}
        <div className="flex justify-between items-end">
            <h3 className="text-sm font-black text-slate-500 uppercase tracking-widest pl-2">Estoque / Cores</h3>
            <button onClick={() => setModalAdicao({ aberto: true, tipo: 'cor', paiId: id, selecionadoId: '' })} className="bg-pink-600 hover:bg-pink-500 text-white text-[10px] font-black uppercase px-4 py-2 rounded-lg shadow-lg">
                + Nova Cor
            </button>
        </div>
        
        <div className="space-y-6">
            {produto?.produto_cores?.map((pc: any) => (
                <div key={pc.id} className="bg-slate-900 rounded-[2rem] p-5 border border-slate-800 shadow-xl relative">
                    <div className="flex justify-between items-start mb-6 border-b border-slate-800/50 pb-4">
                         <div className="flex items-center gap-4">
                            
                            {/* AREA DA FOTO */}
                            <button 
                                onClick={() => setModalFoto({ aberto: true, pcId: pc.id, corId: pc.cor.id, corNome: pc.cor?.nome, urlAtual: pc.foto_url })}
                                className="relative group w-16 h-16 active:scale-95 transition-transform"
                            >
                                <div className={`w-full h-full rounded-2xl overflow-hidden border-2 border-slate-700 hover:border-pink-500 transition-colors bg-slate-950 flex items-center justify-center relative`}>
                                    {pc.foto_url ? (
                                        // eslint-disable-next-line @next/next/no-img-element
                                        <img src={pc.foto_url} alt={pc.cor?.nome} className="w-full h-full object-cover" />
                                    ) : <span className="text-2xl opacity-30">📷</span>}
                                    
                                    <div className="absolute bottom-1 right-1 bg-black/60 rounded-full p-1">
                                        <div className="w-2 h-2 bg-white rounded-full"></div>
                                    </div>
                                </div>
                            </button>

                            <div>
                                <div className="flex items-center gap-2 mb-1">
                                    <div className="w-2 h-2 rounded-full bg-pink-500 shadow-[0_0_8px_rgba(236,72,153,0.8)]"></div>
                                    <h4 className="text-lg font-black text-white uppercase">{pc.cor?.nome}</h4>
                                </div>
                                <p className="text-[10px] text-slate-500 font-bold">Toque na foto para editar</p>
                            </div>
                        </div>

                        <button onClick={() => setModalAdicao({ aberto: true, tipo: 'tamanho', paiId: pc.id, selecionadoId: '' })} className="bg-slate-800 hover:bg-slate-700 text-slate-300 text-[9px] font-bold uppercase px-3 py-1.5 rounded-lg border border-slate-700 transition-colors">
                            + Add Tam
                        </button>
                    </div>

                    <div className="grid grid-cols-2 min-[400px]:grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-2">
                        {pc.estoque.length === 0 ? (
                            <p className="col-span-full text-center text-slate-600 text-[10px] py-2">Sem estoque.</p>
                        ) : ordenarEstoquePorTamanho(pc.estoque).map((est: any) => (
                            <div key={est.id} className="bg-slate-950 p-2 rounded-xl border border-slate-800/50 flex flex-col justify-between items-center gap-2 hover:border-slate-700 transition-colors">
                                <div className="w-full flex justify-between items-center px-1">
                                    <span className="text-[10px] font-black text-slate-500">{est.tamanho?.nome}</span>
                                    <span className={`text-sm font-bold ${est.quantidade > 0 ? 'text-white' : 'text-red-500'}`}>{est.quantidade}</span>
                                </div>
                                <div className="flex w-full gap-1">
                                    <button onClick={() => abrirModalEstoque('saida', est, pc.cor?.nome)} className="flex-1 h-6 rounded bg-red-950/20 text-red-500 hover:bg-red-600 hover:text-white transition-colors font-bold text-xs flex items-center justify-center">-</button>
                                    <button onClick={() => abrirModalEstoque('entrada', est, pc.cor?.nome)} className="flex-1 h-6 rounded bg-green-950/20 text-green-500 hover:bg-green-600 hover:text-white transition-colors font-bold text-xs flex items-center justify-center">+</button>
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            ))}
        </div>
      </main>

      {/* MODAL ADIÇÃO */}
      {modalAdicao.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-sm flex items-center justify-center p-4">
            <div className="bg-slate-900 w-full max-w-sm rounded-[2rem] p-6 border border-slate-800 shadow-2xl">
                <h3 className="text-lg font-black text-white uppercase mb-4 text-center">Adicionar {modalAdicao.tipo === 'cor' ? 'Nova Cor' : 'Novo Tamanho'}</h3>
                <div className="space-y-4">
                    {opcoesFiltradas.length === 0 ? (
                         <div className="bg-amber-900/20 text-amber-500 p-4 rounded-xl text-center text-xs font-bold border border-amber-900/50">Todas as opções já foram adicionadas.</div>
                    ) : (
                        <>
                            <label className="text-xs font-bold text-slate-500 uppercase">Selecione:</label>
                            <select className="w-full bg-slate-950 border border-slate-700 text-white p-4 rounded-xl outline-none focus:border-pink-500" value={modalAdicao.selecionadoId} onChange={(e) => setModalAdicao({ ...modalAdicao, selecionadoId: e.target.value })}>
                                <option value="">-- Selecione --</option>
                                {opcoesFiltradas.map(opt => <option key={opt.id} value={opt.id}>{opt.nome}</option>)}
                            </select>
                        </>
                    )}
                    <div className="flex gap-3 pt-2">
                        <button onClick={() => setModalAdicao({ ...modalAdicao, aberto: false })} className="flex-1 bg-slate-800 text-slate-300 font-bold py-3 rounded-xl uppercase text-xs">Cancelar</button>
                        {opcoesFiltradas.length > 0 && <button onClick={confirmarAdicao} className="flex-1 bg-pink-600 text-white font-black py-3 rounded-xl uppercase text-xs shadow-lg hover:bg-pink-500">Salvar</button>}
                    </div>
                </div>
            </div>
        </div>
      )}

      {/* MODAL ESTOQUE */}
      {modalEstoque.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-sm flex items-center justify-center p-4">
            <div className="bg-slate-900 w-full max-w-sm rounded-[2.5rem] p-8 border border-slate-800 shadow-2xl space-y-6">
                <div className="text-center space-y-2">
                    <h3 className={`text-xl font-black uppercase tracking-tight ${modalEstoque.tipo === 'entrada' ? 'text-green-500' : 'text-red-500'}`}>{modalEstoque.tipo === 'entrada' ? '📦 Carga' : '📉 Baixa'}</h3>
                    <p className="text-slate-400 text-sm font-bold">{modalEstoque.corNome} - Tam. {modalEstoque.tamanhoNome}</p>
                </div>
                <div className="bg-slate-950 p-6 rounded-3xl border border-slate-800 text-center">
                    <span className="text-3xl font-black text-white">{modalEstoque.qtdAtual}</span>
                    <span className="block text-[10px] text-slate-500 font-bold uppercase mt-1">Atual</span>
                </div>
                <input type="number" autoFocus value={modalEstoque.qtdOperacao} onChange={e => setModalEstoque({...modalEstoque, qtdOperacao: parseInt(e.target.value)})} className="w-full bg-slate-950 border-2 border-slate-700 focus:border-pink-500 p-4 rounded-2xl text-center text-xl font-black text-white outline-none" placeholder="Qtd" />
                <div className="grid grid-cols-2 gap-4">
                    <button onClick={() => setModalEstoque({...modalEstoque, aberto: false})} className="bg-slate-800 text-white font-bold py-4 rounded-xl text-xs uppercase">Cancelar</button>
                    <button onClick={confirmarOperacaoEstoque} className={`font-black py-4 rounded-xl text-xs uppercase text-white shadow-lg ${modalEstoque.tipo === 'entrada' ? 'bg-green-600 hover:bg-green-500' : 'bg-red-600 hover:bg-red-500'}`}>Confirmar</button>
                </div>
            </div>
        </div>
      )}

      {/* MODAL GESTÃO DE FOTO */}
      {modalFoto.aberto && (
        <div className="fixed inset-0 z-50 bg-black/95 backdrop-blur-md flex items-center justify-center p-6 animate-in fade-in duration-200">
            <div className="w-full max-w-sm flex flex-col gap-6 relative">
                
                <div className="flex justify-between items-center text-white">
                    <h3 className="font-black uppercase tracking-widest text-sm">Foto: {modalFoto.corNome}</h3>
                    <button onClick={() => setModalFoto({ ...modalFoto, aberto: false })} className="w-8 h-8 rounded-full bg-slate-800 text-slate-400 font-bold flex items-center justify-center">✕</button>
                </div>

                <div className="aspect-[3/4] bg-slate-900 rounded-3xl border-2 border-slate-800 overflow-hidden flex items-center justify-center relative shadow-2xl">
                    {uploading === modalFoto.pcId ? (
                        <div className="flex flex-col items-center gap-2">
                            <div className="w-8 h-8 border-4 border-pink-500 border-t-transparent rounded-full animate-spin"></div>
                            <span className="text-xs font-bold text-pink-500 uppercase tracking-widest">Enviando...</span>
                        </div>
                    ) : erroCarregamento ? (
                        <div className="flex flex-col items-center justify-center h-full text-red-500">
                           <span className="text-3xl mb-2">⚠️</span>
                           <span className="text-xs font-bold uppercase text-center px-4">Erro ao carregar</span>
                           <button 
                                onClick={() => setErroCarregamento(false)}
                                className="mt-4 text-[10px] underline text-slate-400"
                           >
                               Tentar novamente
                           </button>
                        </div>
                    ) : modalFoto.urlAtual ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img 
                            key={modalFoto.urlAtual} // Força remontagem ao mudar URL
                            src={modalFoto.urlAtual} 
                            className="w-full h-full object-cover" 
                            alt="Preview" 
                            onError={() => setErroCarregamento(true)}
                        />
                    ) : (
                        <span className="text-4xl opacity-20">📷</span>
                    )}
                </div>

                <div className="grid grid-cols-2 gap-4">
                    <button 
                        onClick={abrirCamera} 
                        className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest flex flex-col items-center gap-1 active:scale-95 transition-all"
                    >
                        <span className="text-xl">📷</span> Câmera
                    </button>
                    
                    <label className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest flex flex-col items-center gap-1 cursor-pointer active:scale-95 transition-all">
                        <span className="text-xl">📂</span> Galeria
                        <input type="file" accept="image/*" className="hidden" onChange={handleFileChange} />
                    </label>
                </div>

            </div>
        </div>
      )}

      {/* MODAL CÂMERA */}
      {camera?.aberto && (
        <div className="fixed inset-0 z-[100] bg-black flex flex-col items-center justify-center p-6">
             <div className="w-full max-w-sm flex flex-col items-center gap-6">
               <h3 className="text-white font-black uppercase tracking-widest text-sm">Tirar Foto</h3>
               <video ref={videoRef} autoPlay playsInline className="w-full aspect-[3/4] rounded-3xl border-2 border-pink-500 object-cover bg-slate-900 shadow-2xl" />
               <div className="flex gap-4 w-full">
                 <button onClick={tirarFoto} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95 transition-transform">Capturar</button>
                 <button onClick={fecharCamera} className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95 transition-transform">Cancelar</button>
               </div>
             </div>
        </div>
      )}
    </div>
  );
}