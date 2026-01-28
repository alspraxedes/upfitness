'use client';

import { useState, useEffect, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Html5Qrcode } from 'html5-qrcode';

// --- UTILITÁRIOS ---
function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
}

const formatCurrencyInput = (val: string | number) => {
  if (val === '' || val === undefined || val === null) return '';
  const num = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(num)) return '';
  return num.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
};

const playBeep = () => {
    const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3'); 
    audio.volume = 0.5;
    audio.play().catch(() => {});
    if (typeof window !== 'undefined' && window.navigator && window.navigator.vibrate) {
        window.navigator.vibrate(50); 
    }
};

export default function CadastroPage() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  
  // Listas Auxiliares
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);
  
  // Autocomplete Fornecedor
  const [fornecedoresCadastrados, setFornecedoresCadastrados] = useState<string[]>([]);
  const [sugestoesFornecedor, setSugestoesFornecedor] = useState<string[]>([]);
  const [mostrarSugestoes, setMostrarSugestoes] = useState(false);

  // FORMULÁRIO PRINCIPAL
  const [formData, setFormData] = useState({
    codigo_peca: '',
    sku_fornecedor: '', 
    descricao: '',
    fornecedor: '',
    cor: '',            
    preco_compra: '', 
    custo_frete: '',
    custo_embalagem: '',
    preco_venda: '',
    margem_ganho: '', 
  });

  // FOTO E ESTOQUE
  const [foto, setFoto] = useState<{ file: File | null; preview: string }>({ file: null, preview: '' });
  
  const [tamanhos, setTamanhos] = useState<{ tamanho_id: string; qtd: number; ean: string }[]>([
      { tamanho_id: '', qtd: 0, ean: '' }
  ]);
  
  // CÂMERA E SCANNER
  const [modalFotoAberto, setModalFotoAberto] = useState(false);
  const [cameraAtiva, setCameraAtiva] = useState<{ tipo: 'foto' | 'ean'; idxTam?: number } | null>(null);
  const [fotoTemp, setFotoTemp] = useState<{ url: string, blob: Blob } | null>(null);
  
  const videoRef = useRef<HTMLVideoElement>(null);
  const scannerRef = useRef<Html5Qrcode | null>(null);
  const streamRef = useRef<MediaStream | null>(null);

  // --- CARREGAMENTO INICIAL ---
  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u?.user) { router.replace('/login'); return; }

      // Gerar Código Interno
      const novoCodigo = `UPF${new Date().getFullYear()}${Math.floor(1000 + Math.random() * 9000)}`;
      setFormData((prev) => ({ ...prev, codigo_peca: novoCodigo }));

      // Buscar Tamanhos
      const { data: t } = await supabase.from('tamanhos').select('*').order('ordem', { ascending: true });
      if (t) setListaTamanhos(t);
      
      // Buscar Fornecedores para sugestão
      const { data: f } = await supabase.from('produtos').select('fornecedor');
      if (f) {
        const unicos = Array.from(new Set(f.map(item => item.fornecedor).filter(Boolean)));
        setFornecedoresCadastrados(unicos);
      }
    })();
  }, [router]);

  // Filtro Fornecedor
  useEffect(() => {
    if (!formData.fornecedor) { setSugestoesFornecedor([]); return; }
    const termo = formData.fornecedor.toLowerCase();
    const filtrados = fornecedoresCadastrados.filter(f => f.toLowerCase().includes(termo));
    setSugestoesFornecedor(filtrados);
  }, [formData.fornecedor, fornecedoresCadastrados]);

  // --- LÓGICA FINANCEIRA ---
  const handleMoneyInput = (campo: string, valorInput: string) => {
    const apenasDigitos = valorInput.replace(/\D/g, '');
    const floatValue = parseFloat(apenasDigitos) / 100;
    const valorFinal = isNaN(floatValue) ? '0' : floatValue.toString();
    calcularFinanceiro(campo, valorFinal);
  };

  const calcularFinanceiro = (campoAlterado: string, novoValor: string) => {
    const dadosAtuais = { ...formData, [campoAlterado]: novoValor };
    const pCompra = parseFloat(dadosAtuais.preco_compra) || 0;
    const pFrete = parseFloat(dadosAtuais.custo_frete) || 0;
    const pEmb = parseFloat(dadosAtuais.custo_embalagem) || 0;
    const custoTotal = pCompra + pFrete + pEmb;
    
    const margemAtual = parseFloat(dadosAtuais.margem_ganho) || 0;
    
    if (campoAlterado === 'preco_venda') {
        const pVendaAtual = parseFloat(dadosAtuais.preco_venda) || 0;
        if (custoTotal > 0) {
            const novaMargem = ((pVendaAtual - custoTotal) / custoTotal) * 100;
            dadosAtuais.margem_ganho = novaMargem.toFixed(1);
        } else {
            dadosAtuais.margem_ganho = '100'; 
        }
    } else {
        const novoPrecoVenda = custoTotal * (1 + (margemAtual / 100));
        dadosAtuais.preco_venda = novoPrecoVenda.toFixed(2);
    }
    setFormData(dadosAtuais);
  };

  // --- CÂMERA (FOTO) ---
  const ligarCameraFoto = async () => {
    setModalFotoAberto(false);
    setCameraAtiva({ tipo: 'foto' });
    setFotoTemp(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ 
          video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } } 
      });
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch (err) { 
        alert('Câmera indisponível.'); 
        setCameraAtiva(null); 
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
      setFotoTemp({ url: URL.createObjectURL(blob), blob }); 
    }, 'image/jpeg', 0.85);
  };

  const confirmarFoto = () => {
      if (!fotoTemp) return;
      const file = blobToFile(fotoTemp.blob, `foto_${Date.now()}.jpg`);
      setFoto({ file, preview: fotoTemp.url });
      fecharCamera();
  };

  // --- SCANNER (EAN) ---
  useEffect(() => {
    if (cameraAtiva?.tipo === 'ean') {
        const elementId = "reader-cadastro-direct";
        const t = setTimeout(() => {
            if (!document.getElementById(elementId)) return;
            const html5QrCode = new Html5Qrcode(elementId);
            scannerRef.current = html5QrCode;
            html5QrCode.start(
                { facingMode: "environment" },
                { fps: 30, qrbox: { width: 250, height: 100 }, aspectRatio: 1.0 },
                (text) => {
                    playBeep();
                    if (cameraAtiva.idxTam !== undefined) {
                        const n = [...tamanhos];
                        n[cameraAtiva.idxTam].ean = text;
                        setTamanhos(n);
                    }
                    fecharCamera();
                },
                (error) => { }
            ).catch(err => {
                console.error(err);
                alert("Erro ao iniciar câmera.");
                setCameraAtiva(null);
            });
        }, 200);
        return () => clearTimeout(t);
    }
  }, [cameraAtiva, tamanhos]);

  const fecharCamera = async () => {
      setFotoTemp(null);
      if (streamRef.current) {
          streamRef.current.getTracks().forEach(t => t.stop());
          streamRef.current = null;
      }
      if (videoRef.current) videoRef.current.srcObject = null;
      if (scannerRef.current) {
          try {
            if (scannerRef.current.isScanning) await scannerRef.current.stop();
            scannerRef.current.clear();
          } catch(e) { console.log(e); }
      }
      setCameraAtiva(null);
  };

  const handleGaleria = (e: any) => {
    const file = e.target.files?.[0];
    if (file) {
        setFoto({ file, preview: URL.createObjectURL(file) });
        setModalFotoAberto(false);
    }
  };

  // --- SALVAR NOVO MODELO ---
  const salvar = async (e: any) => {
    e.preventDefault();
    if (!formData.descricao.trim()) return alert('Informe a descrição.');
    if (!formData.fornecedor.trim()) return alert('Informe o fornecedor.');
    if (!formData.cor.trim()) return alert('Informe a cor.');
    if (tamanhos.length === 0) return alert('Adicione pelo menos um tamanho.');

    setLoading(true);

    try {
      // 1. Upload da Foto (Se houver)
      let fotoPath = null;
      if (foto.file) {
          const path = `produtos/${formData.codigo_peca}_${Date.now()}.jpg`;
          await supabase.storage.from('produtos').upload(path, foto.file, { upsert: true });
          const { data: pubUrl } = supabase.storage.from('produtos').getPublicUrl(path);
          fotoPath = pubUrl.publicUrl;
      }

      // 2. Criar Produto (Tabela Única)
      const { data: p, error: pe } = await supabase.from('produtos').insert([{
          codigo_peca: formData.codigo_peca,
          sku_fornecedor: formData.sku_fornecedor, 
          descricao: formData.descricao,
          fornecedor: formData.fornecedor,
          cor: formData.cor, 
          foto_url: fotoPath, 
          preco_compra: parseFloat(formData.preco_compra) || 0,
          custo_frete: parseFloat(formData.custo_frete) || 0,
          custo_embalagem: parseFloat(formData.custo_embalagem) || 0,
          preco_venda: parseFloat(formData.preco_venda) || 0,
        }]).select('id').single();

      if (pe) throw pe;

      // 3. Criar Estoque (Lista de Tamanhos)
      const dadosEstoque = tamanhos.map(t => ({
          produto_id: p.id,
          tamanho_id: t.tamanho_id,
          quantidade: Math.max(0, parseInt(String(t.qtd)) || 0),
          codigo_barras: t.ean?.trim() ? t.ean.trim() : null,
      })).filter(t => t.tamanho_id); // Remove vazios

      if (dadosEstoque.length > 0) {
          const { error: estErr } = await supabase.from('estoque').insert(dadosEstoque);
          if (estErr) throw estErr;
      }

      alert('Produto cadastrado com sucesso!');
      window.location.href = '/';
    } catch (err: any) {
      console.error(err);
      alert('Erro: ' + err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 pb-32 font-sans">
      <header className="bg-gradient-to-r from-pink-600 to-blue-600 p-6 shadow-2xl mb-8 flex justify-between items-center sticky top-0 z-50">
        <h1 className="font-black italic text-xl tracking-tighter leading-none">
          UPFITNESS <span className="font-light tracking-normal text-white/80">Cadastro</span>
        </h1>
        <Link href="/" className="bg-black/20 hover:bg-black/40 px-4 py-2 rounded-full text-white text-[10px] font-bold tracking-widest transition-colors border border-white/10 active:scale-95">
          VOLTAR
        </Link>
      </header>

      <main className="max-w-4xl mx-auto px-4 space-y-6">
        <form onSubmit={salvar} className="space-y-8">
          
          {/* SEÇÃO 1: IDENTIFICAÇÃO E FOTO */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl">
             <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Identificação do Item</h2>
             
             <div className="flex flex-col md:flex-row gap-6">
                {/* FOTO - CLICÁVEL */}
                <div className="shrink-0 flex justify-center md:justify-start">
                    <button type="button" onClick={() => setModalFotoAberto(true)} className="w-32 h-32 rounded-3xl bg-slate-950 border-2 border-dashed border-slate-700 hover:border-pink-500 hover:text-pink-500 flex flex-col items-center justify-center relative overflow-hidden group transition-all">
                        {foto.preview ? (
                            // eslint-disable-next-line @next/next/no-img-element
                            <img src={foto.preview} className="w-full h-full object-cover" alt="Preview" />
                        ) : (
                            <>
                                <span className="text-3xl mb-1 opacity-50">📷</span>
                                <span className="text-[9px] font-black uppercase tracking-widest">Add Foto</span>
                            </>
                        )}
                        {foto.preview && <div className="absolute inset-x-0 bottom-0 bg-black/60 text-[8px] font-bold text-white py-1 text-center">ALTERAR</div>}
                    </button>
                </div>

                {/* DADOS */}
                <div className="flex-1 space-y-4">
                     <div className="grid grid-cols-2 gap-4">
                        <div className="space-y-1">
                            <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Cód. Interno</label>
                            {/* AQUI ESTAVA text-sm -> AJUSTADO PARA text-base md:text-sm */}
                            <input readOnly value={formData.codigo_peca} className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl text-slate-400 font-mono text-base md:text-sm font-bold text-center tracking-widest" />
                        </div>
                        <div className="space-y-1">
                            <label className="text-[9px] font-black text-slate-500 uppercase ml-1">SKU Fornecedor</label>
                            {/* AQUI ESTAVA text-xs -> AJUSTADO PARA text-base md:text-xs */}
                            <input 
                                value={formData.sku_fornecedor} 
                                onChange={e => setFormData({...formData, sku_fornecedor: e.target.value})} 
                                placeholder="Ex: REF-998"
                                className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl text-white font-bold text-base md:text-xs focus:border-pink-500 outline-none" 
                            />
                        </div>
                     </div>

                     <div className="space-y-1">
                        <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Descrição do Produto *</label>
                        <input value={formData.descricao} onChange={e => setFormData({...formData, descricao: e.target.value})} placeholder="Ex: Legging Alta Compressão" className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-pink-500 outline-none transition-colors text-base md:text-sm font-bold text-white" />
                     </div>

                     <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                        <div className="space-y-1 relative">
                            <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Fornecedor *</label>
                            <input 
                                value={formData.fornecedor} 
                                onChange={e => { setFormData({...formData, fornecedor: e.target.value}); setMostrarSugestoes(true); }}
                                onFocus={() => setMostrarSugestoes(true)}
                                onBlur={() => setTimeout(() => setMostrarSugestoes(false), 200)}
                                className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-blue-500 outline-none transition-colors text-base md:text-sm font-bold text-white"
                                placeholder="Digite..."
                            />
                            {mostrarSugestoes && sugestoesFornecedor.length > 0 && (
                                <div className="absolute top-full left-0 right-0 z-50 mt-1 bg-slate-800 border border-slate-700 rounded-xl shadow-2xl overflow-hidden max-h-48 overflow-y-auto">
                                    {sugestoesFornecedor.map((s, idx) => (
                                        <button key={idx} type="button" onClick={() => { setFormData({...formData, fornecedor: s}); setMostrarSugestoes(false); }} className="w-full text-left px-4 py-3 text-xs font-bold text-slate-300 hover:bg-pink-600 hover:text-white border-b border-slate-700/50">
                                            {s}
                                        </button>
                                    ))}
                                </div>
                            )}
                        </div>
                        <div className="space-y-1">
                            <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Cor do Item *</label>
                            <input 
                                value={formData.cor} 
                                onChange={e => setFormData({...formData, cor: e.target.value})} 
                                placeholder="Ex: Preto, Storm..."
                                className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-pink-500 outline-none transition-colors text-base md:text-sm font-bold text-white" 
                            />
                        </div>
                     </div>
                </div>
             </div>
          </section>

          {/* SEÇÃO 2: FINANCEIRO (SUBIU DE POSIÇÃO) */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-6">
             <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Precificação</h2>
             <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                <div className="relative group"><span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span><input type="tel" inputMode="decimal" value={formatCurrencyInput(formData.preco_compra)} onChange={e => handleMoneyInput('preco_compra', e.target.value)} className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-white h-12" placeholder="0,00" /><span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Custo</span></div>
                <div className="relative group"><span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span><input type="tel" inputMode="decimal" value={formatCurrencyInput(formData.custo_frete)} onChange={e => handleMoneyInput('custo_frete', e.target.value)} className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-slate-300 h-12" placeholder="0,00" /><span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Frete</span></div>
                <div className="relative group col-span-2 md:col-span-1"><span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span><input type="tel" inputMode="decimal" value={formatCurrencyInput(formData.custo_embalagem)} onChange={e => handleMoneyInput('custo_embalagem', e.target.value)} className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-slate-300 h-12" placeholder="0,00" /><span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Emb.</span></div>
             </div>
             <div className="grid grid-cols-2 gap-4 pt-2">
                <div className="bg-slate-950/50 p-3 rounded-2xl border border-pink-900/30 text-center"><label className="block text-[9px] font-black text-pink-500 mb-1 uppercase tracking-wider">Margem</label><div className="flex items-center justify-center gap-1"><input type="number" inputMode="decimal" step="0.1" value={formData.margem_ganho} onChange={e => calcularFinanceiro('margem_ganho', e.target.value)} className="w-full bg-transparent text-center font-black text-xl text-pink-500 outline-none h-10" placeholder="0" /><span className="text-pink-500 font-bold text-lg">%</span></div></div>
                <div className="bg-blue-900/10 p-3 rounded-2xl border border-blue-900/20 text-center"><label className="block text-[9px] font-black text-blue-400 mb-1 uppercase tracking-wider">Venda Final</label><div className="relative inline-block w-full"><span className="absolute left-2 top-2 text-sm text-blue-500/50 font-bold">R$</span><input type="tel" inputMode="decimal" value={formatCurrencyInput(formData.preco_venda)} onChange={e => handleMoneyInput('preco_venda', e.target.value)} className="w-full bg-transparent text-center font-black text-xl text-blue-400 outline-none h-10" /></div></div>
             </div>
          </section>

          {/* SEÇÃO 3: GRADE DE TAMANHOS (DESCEU) */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl">
             <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Grade de Tamanhos</h2>
             <div className="space-y-3">
                {tamanhos.map((t, idx) => (
                    <div key={idx} className="bg-slate-950 p-2 rounded-xl border border-slate-800 shadow-sm flex gap-2 items-center animate-in slide-in-from-bottom-2">
                        <select 
                            value={t.tamanho_id} 
                            onChange={(e) => { const n = [...tamanhos]; n[idx].tamanho_id = e.target.value; setTamanhos(n); }} 
                            className="bg-slate-900 border border-slate-700 rounded-lg text-base md:text-xs font-black text-blue-400 h-12 w-20 outline-none px-2"
                        >
                            <option value="">Tam</option>
                            {listaTamanhos.map(tm => <option key={tm.id} value={tm.id}>{tm.nome}</option>)}
                        </select>

                        <input 
                            type="tel" inputMode="numeric" placeholder="Qtd" 
                            value={t.qtd} 
                            onChange={(e) => { const n = [...tamanhos]; n[idx].qtd = parseInt(e.target.value)||0; setTamanhos(n); }} 
                            className="bg-slate-900 border border-slate-700 rounded-lg h-12 w-16 text-center text-base md:text-xs font-bold outline-none text-white" 
                        />

                        <div className="flex-1 relative flex items-center">
                            <input 
                                type="text" placeholder="EAN / Cód. Barras" 
                                value={t.ean} 
                                onChange={(e) => { const n = [...tamanhos]; n[idx].ean = e.target.value; setTamanhos(n); }} 
                                className="w-full bg-slate-950 border border-slate-700 rounded-lg h-12 px-3 pr-10 text-base md:text-xs font-mono outline-none text-slate-300 placeholder:text-slate-600" 
                            />
                            <button type="button" onClick={() => setCameraAtiva({tipo: 'ean', idxTam: idx})} className="absolute right-2 w-8 h-8 flex items-center justify-center text-blue-500 hover:text-white">📷</button>
                        </div>
                        
                        <button type="button" onClick={() => { const n = [...tamanhos]; n.splice(idx, 1); setTamanhos(n); }} className="w-10 h-10 flex items-center justify-center text-slate-600 hover:text-red-500 font-bold bg-slate-900 rounded-lg border border-slate-800">✕</button>
                    </div>
                ))}
                <button type="button" onClick={() => setTamanhos([...tamanhos, {tamanho_id: '', qtd: 0, ean: ''}])} className="w-full py-4 border border-dashed border-slate-700 rounded-xl text-slate-500 font-black text-xs uppercase hover:bg-slate-800 hover:text-blue-400 transition-colors tracking-widest">+ Adicionar Tamanho</button>
             </div>
          </section>

          <button disabled={loading} className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl hover:shadow-2xl hover:brightness-110 active:scale-95 transition-all uppercase tracking-widest text-sm disabled:opacity-50 disabled:cursor-not-allowed mb-10">{loading ? 'SALVANDO...' : 'FINALIZAR CADASTRO'}</button>
        </form>
      </main>

      {/* MODAL FOTO (Simplificado) */}
      {modalFotoAberto && (
          <div className="fixed inset-0 z-[120] bg-black/90 backdrop-blur-sm flex items-end md:items-center justify-center pb-8 md:pb-0 px-4" onClick={() => setModalFotoAberto(false)}>
              <div className="bg-slate-900 w-full max-w-sm rounded-3xl p-6 border border-slate-800 shadow-2xl flex flex-col gap-4 animate-in slide-in-from-bottom-10" onClick={e => e.stopPropagation()}>
                  <h3 className="text-center font-black uppercase text-slate-500 text-xs tracking-widest">Adicionar Foto</h3>
                  <button onClick={ligarCameraFoto} className="bg-pink-600 text-white py-4 rounded-2xl font-black text-sm uppercase tracking-widest shadow-lg flex items-center justify-center gap-3 active:scale-95 transition-transform">📷 Câmera</button>
                  <label className="bg-slate-800 text-white py-4 rounded-2xl font-black text-sm uppercase tracking-widest shadow-lg flex items-center justify-center gap-3 cursor-pointer active:scale-95 transition-transform">🖼️ Galeria <input type="file" accept="image/*" onChange={handleGaleria} className="hidden" /></label>
              </div>
          </div>
      )}

      {/* MODAL CÂMERA (UNIFICADO) */}
      {cameraAtiva && (
        <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
             {cameraAtiva.tipo === 'foto' ? (
                <div className="w-full max-w-sm flex flex-col items-center gap-6">
                    <div className="w-full aspect-[3/4] rounded-3xl border-2 border-pink-500 overflow-hidden bg-black relative shadow-2xl">
                        {fotoTemp ? (
                             // eslint-disable-next-line @next/next/no-img-element
                            <img src={fotoTemp.url} className="w-full h-full object-cover" alt="Preview" />
                        ) : <video ref={videoRef} autoPlay playsInline className="w-full h-full object-cover" />}
                    </div>
                    <div className="flex gap-4 w-full">
                        {fotoTemp ? (
                            <>
                                <button onClick={confirmarFoto} className="flex-1 bg-green-600 text-white py-4 rounded-2xl font-black uppercase tracking-widest text-xs shadow-lg active:scale-95">Confirmar</button>
                                <button onClick={() => { setFotoTemp(null); if(videoRef.current && streamRef.current) videoRef.current.srcObject = streamRef.current; }} className="flex-1 bg-slate-700 text-white py-4 rounded-2xl font-black uppercase tracking-widest text-xs active:scale-95">Repetir</button>
                            </>
                        ) : (
                            <button onClick={capturarFoto} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black uppercase tracking-widest text-xs shadow-lg active:scale-95">Capturar</button>
                        )}
                        <button onClick={fecharCamera} className="bg-slate-800 text-white px-6 rounded-2xl font-black uppercase tracking-widest text-xs active:scale-95">X</button>
                    </div>
                </div>
             ) : (
                <div className="w-full max-w-sm flex flex-col gap-4">
                    <h3 className="text-white text-center font-black uppercase tracking-widest text-sm">Ler Código de Barras</h3>
                    <div id="reader-cadastro-direct" className="w-full h-64 bg-black rounded-3xl overflow-hidden border-2 border-blue-500 shadow-2xl"></div>
                    <button onClick={fecharCamera} className="bg-slate-800 text-white py-4 rounded-2xl font-black uppercase tracking-widest text-xs active:scale-95">Cancelar</button>
                </div>
             )}
        </div>
      )}
    </div>
  );
}