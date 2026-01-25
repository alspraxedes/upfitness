'use client';

import { useState, useEffect, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Html5Qrcode, Html5QrcodeSupportedFormats } from 'html5-qrcode';

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

type Variacao = {
  cor_id: string;
  foto: File | null;
  preview: string;
  tamanhos: { tamanho_id: string; qtd: number; ean: string }[];
};

export default function CadastroPage() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  
  // Listas
  const [listas, setListas] = useState({ tamanhos: [] as any[], cores: [] as any[] });
  const [fornecedoresCadastrados, setFornecedoresCadastrados] = useState<string[]>([]);
  const [sugestoesFornecedor, setSugestoesFornecedor] = useState<string[]>([]);
  const [mostrarSugestoes, setMostrarSugestoes] = useState(false);

  const [formData, setFormData] = useState({
    codigo_peca: '',
    descricao: '',
    fornecedor: '',
    preco_compra: '', 
    custo_frete: '',
    custo_embalagem: '',
    preco_venda: '',
    margem_ganho: '', 
  });

  const [variacoes, setVariacoes] = useState<Variacao[]>([]);
  
  // Controle de Modais e Câmera
  const [menuFotoIdx, setMenuFotoIdx] = useState<number | null>(null);
  const [cameraAtiva, setCameraAtiva] = useState<{ 
      tipo: 'foto' | 'ean'; 
      idxCor?: number; 
      idxTam?: number 
  } | null>(null);
  
  const [fotoTemp, setFotoTemp] = useState<{ url: string, blob: Blob } | null>(null);
  
  // REFS IMPORTANTES
  const videoRef = useRef<HTMLVideoElement>(null);
  const scannerRef = useRef<Html5Qrcode | null>(null);
  const streamRef = useRef<MediaStream | null>(null); // <-- CORREÇÃO: Guarda o stream na memória

  // Busca inicial
  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u?.user) { router.replace('/login'); return; }

      const novoCodigo = `UPF${new Date().getFullYear()}${Math.floor(1000 + Math.random() * 9000)}`;
      setFormData((prev) => ({ ...prev, codigo_peca: novoCodigo }));

      const { data: t } = await supabase.from('tamanhos').select('*').order('ordem', { ascending: true });
      const { data: c } = await supabase.from('cores').select('*').order('nome');
      
      const { data: f } = await supabase.from('produtos').select('fornecedor');
      if (f) {
        const unicos = Array.from(new Set(f.map(item => item.fornecedor).filter(Boolean)));
        setFornecedoresCadastrados(unicos);
      }

      setListas({ tamanhos: t || [], cores: c || [] });
    })();
  }, [router]);

  // Filtro Fornecedor
  useEffect(() => {
    if (!formData.fornecedor) { setSugestoesFornecedor([]); return; }
    const termo = formData.fornecedor.toLowerCase();
    const filtrados = fornecedoresCadastrados.filter(f => f.toLowerCase().includes(termo));
    setSugestoesFornecedor(filtrados);
  }, [formData.fornecedor, fornecedoresCadastrados]);

  const getCoresDisponiveis = (idxAtual: number) => {
    const selecionadas = variacoes.map((v, i) => (i !== idxAtual ? v.cor_id : null)).filter(Boolean);
    return listas.cores.filter((c) => !selecionadas.includes(c.id));
  };

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
    if (menuFotoIdx === null) return;
    setCameraAtiva({ tipo: 'foto', idxCor: menuFotoIdx });
    setMenuFotoIdx(null);
    setFotoTemp(null);
    
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ 
          video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } } 
      });
      streamRef.current = stream; // Salva na memória
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch (err) { 
        alert('Câmera indisponível.'); 
        setCameraAtiva(null); 
    }
  };

  // 1. Captura (Congela)
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
      setFotoTemp({ url, blob }); 
      // Não fecha o stream aqui, apenas mostra o preview por cima
    }, 'image/jpeg', 0.85);
  };

  // 2. Tentar de Novo (CORRIGIDO)
  const recapturarFoto = () => {
      setFotoTemp(null); // Remove o preview
      // O useEffect abaixo vai religar o vídeo automaticamente
  };

  // 3. Confirmar
  const confirmarFoto = () => {
      if (!fotoTemp || cameraAtiva?.idxCor === undefined) return;
      const file = blobToFile(fotoTemp.blob, `foto_${Date.now()}.jpg`);
      const n = [...variacoes];
      n[cameraAtiva.idxCor].foto = file;
      n[cameraAtiva.idxCor].preview = fotoTemp.url;
      setVariacoes(n);
      fecharCamera();
  };

  // --- EFEITO DE RECONEXÃO DE VÍDEO ---
  // Esse efeito garante que se a tag <video> for remontada, ela recebe o stream de volta
  useEffect(() => {
      if (cameraAtiva?.tipo === 'foto' && !fotoTemp && videoRef.current && streamRef.current) {
          videoRef.current.srcObject = streamRef.current;
          videoRef.current.play().catch(() => {});
      }
  }, [cameraAtiva, fotoTemp]);

  // --- ARQUIVO (GALERIA) ---
  const handleGaleria = (e: any) => {
    if (menuFotoIdx === null) return;
    const file: File | undefined = e.target.files?.[0];
    if (!file) return;
    const n = [...variacoes];
    n[menuFotoIdx].foto = file;
    n[menuFotoIdx].preview = URL.createObjectURL(file);
    setVariacoes(n);
    setMenuFotoIdx(null);
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
                    const n = [...variacoes];
                    if (cameraAtiva.idxCor !== undefined && cameraAtiva.idxTam !== undefined) {
                        n[cameraAtiva.idxCor].tamanhos[cameraAtiva.idxTam].ean = text;
                        setVariacoes(n);
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
  }, [cameraAtiva, variacoes]);

  // Fechar Geral e Limpar Memória
  const fecharCamera = async () => {
      setFotoTemp(null);
      
      // Para Foto
      if (streamRef.current) {
          streamRef.current.getTracks().forEach(t => t.stop());
          streamRef.current = null;
      }
      if (videoRef.current) {
          videoRef.current.srcObject = null;
      }

      // Para Scanner
      if (scannerRef.current) {
          try {
            if (scannerRef.current.isScanning) await scannerRef.current.stop();
            scannerRef.current.clear();
          } catch(e) { console.log(e); }
      }
      setCameraAtiva(null);
  };

  // --- SALVAR ---
  const salvar = async (e: any) => {
    e.preventDefault();
    if (!formData.descricao.trim()) return alert('Informe a descrição.');
    if (!formData.fornecedor.trim()) return alert('Informe o fornecedor.');
    if (variacoes.length === 0) return alert('Adicione ao menos uma cor.');

    setLoading(true);

    try {
      const { data: p, error: pe } = await supabase.from('produtos').insert([{
          codigo_peca: formData.codigo_peca,
          descricao: formData.descricao,
          fornecedor: formData.fornecedor,
          preco_compra: parseFloat(formData.preco_compra) || 0,
          custo_frete: parseFloat(formData.custo_frete) || 0,
          custo_embalagem: parseFloat(formData.custo_embalagem) || 0,
          preco_venda: parseFloat(formData.preco_venda) || 0,
        }]).select('id').single();

      if (pe) throw pe;

      for (const v of variacoes) {
        let fotoPath = '';
        if (v.foto) {
          const path = `${p.id}/${v.cor_id}/${Date.now()}_${v.foto.name}`;
          await supabase.storage.from('produtos').upload(path, v.foto, { upsert: true });
          const { data: pubUrl } = supabase.storage.from('produtos').getPublicUrl(path);
          fotoPath = pubUrl.publicUrl;
        }

        const { data: pc, error: pcErr } = await supabase.from('produto_cores').insert([{ 
            produto_id: p.id, cor_id: v.cor_id, foto_url: fotoPath 
        }]).select('id').single();

        if (pcErr) throw pcErr;

        const est = v.tamanhos.map((t) => ({
          produto_id: p.id,
          produto_cor_id: pc.id,
          tamanho_id: t.tamanho_id,
          quantidade: Math.max(0, parseInt(String(t.qtd)) || 0),
          codigo_barras: t.ean?.trim() ? t.ean.trim() : null,
        }));

        const { error: estErr } = await supabase.from('estoque').insert(est);
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
          UPFITNESS <span className="font-light tracking-normal text-white/80">V11.0</span>
        </h1>
        <Link href="/" className="bg-black/20 hover:bg-black/40 px-4 py-2 rounded-full text-white text-[10px] font-bold tracking-widest transition-colors border border-white/10 active:scale-95">
          VOLTAR
        </Link>
      </header>

      <main className="max-w-4xl mx-auto px-4 space-y-6">
        <form onSubmit={salvar} className="space-y-8">
          
          {/* SEÇÃO 1: DADOS */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-5">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Dados do Produto</h2>
            <div className="grid grid-cols-1 md:grid-cols-12 gap-5">
              <div className="md:col-span-3 space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Código (Auto)</label>
                <input readOnly value={formData.codigo_peca} className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl text-slate-400 font-mono text-sm font-bold text-center tracking-widest" />
              </div>
              <div className="md:col-span-9 space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Descrição *</label>
                <input value={formData.descricao} onChange={e => setFormData({...formData, descricao: e.target.value})} placeholder="Ex: Legging Alta Compressão" className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl focus:border-pink-500 outline-none transition-colors text-base md:text-sm font-bold text-white" />
              </div>
              <div className="md:col-span-12 space-y-2 relative">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Fornecedor *</label>
                <input 
                  value={formData.fornecedor} 
                  onChange={e => { setFormData({...formData, fornecedor: e.target.value}); setMostrarSugestoes(true); }}
                  onFocus={() => setMostrarSugestoes(true)}
                  onBlur={() => setTimeout(() => setMostrarSugestoes(false), 200)}
                  placeholder="Ex: Confecções Silva LTDA"
                  className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl focus:border-blue-500 outline-none transition-colors text-base md:text-sm font-bold text-white"
                  autoComplete="off"
                />
                {mostrarSugestoes && sugestoesFornecedor.length > 0 && (
                    <div className="absolute top-full left-0 right-0 z-50 mt-1 bg-slate-800 border border-slate-700 rounded-xl shadow-2xl overflow-hidden max-h-48 overflow-y-auto">
                        {sugestoesFornecedor.map((sugestao, idx) => (
                            <button key={idx} type="button" onClick={() => { setFormData({...formData, fornecedor: sugestao}); setMostrarSugestoes(false); }} className="w-full text-left px-4 py-3 text-sm font-bold text-slate-300 hover:bg-pink-600 hover:text-white transition-colors border-b border-slate-700/50">
                                {sugestao}
                            </button>
                        ))}
                    </div>
                )}
              </div>
            </div>
          </section>

          {/* SEÇÃO 2: FINANCEIRO */}
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

          {/* SEÇÃO 3: VARIAÇÕES */}
          <div className="space-y-6">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest border-b border-slate-800 pb-2">Estoque & Variações</h2>

            {variacoes.map((v, cIdx) => (
              <div key={cIdx} className="bg-slate-900 p-4 rounded-[2rem] border border-slate-800 shadow-xl relative animate-in fade-in slide-in-from-bottom-4">
                
                <div className="flex items-center gap-4 mb-4 pb-4 border-b border-slate-800">
                    
                    {/* FOTO - BOLINHA COM AÇÃO */}
                    <div className="relative shrink-0">
                        <button 
                            type="button"
                            onClick={() => setMenuFotoIdx(cIdx)} 
                            className="w-16 h-16 rounded-full bg-slate-950 border-2 border-slate-700 flex items-center justify-center overflow-hidden shadow-lg relative group hover:border-pink-500 transition-colors"
                        >
                            {v.preview ? (
                                // eslint-disable-next-line @next/next/no-img-element
                                <img src={v.preview} className="w-full h-full object-cover" alt="Preview" />
                            ) : (
                                <span className="text-xl opacity-30">📷</span>
                            )}
                            <div className="absolute bottom-0 inset-x-0 bg-black/60 text-[8px] font-bold text-white text-center py-0.5">EDITAR</div>
                        </button>
                    </div>

                    <div className="flex-1">
                        <label className="text-[10px] font-black text-slate-500 uppercase ml-1 block mb-1">Selecione a Cor</label>
                        <select required value={v.cor_id} onChange={(e) => { const n = [...variacoes]; n[cIdx].cor_id = e.target.value; setVariacoes(n); }} className="w-full bg-slate-950 text-white font-bold p-3 rounded-xl border border-slate-800 outline-none focus:border-pink-500 text-sm">
                            <option value="">Selecione...</option>
                            {getCoresDisponiveis(cIdx).map((c) => (<option key={c.id} value={c.id}>{c.nome}</option>))}
                        </select>
                    </div>

                    <button type="button" onClick={() => setVariacoes(variacoes.filter((_, i) => i !== cIdx))} className="text-red-500 hover:bg-red-950/30 p-2 rounded-lg transition self-end mb-1">🗑️</button>
                </div>

                <div className="space-y-3">
                    {v.tamanhos.map((t, tIdx) => (
                        <div key={tIdx} className="bg-slate-950 p-2 rounded-xl border border-slate-800 shadow-sm flex gap-2 items-center">
                            <select required value={t.tamanho_id} onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].tamanho_id = e.target.value; setVariacoes(n);}} className="bg-slate-900 border border-slate-700 rounded-lg text-xs font-black text-blue-400 h-10 w-16 outline-none px-1">
                                <option value="">Tam</option>
                                {listas.tamanhos.map((tam) => (<option key={tam.id} value={tam.id}>{tam.nome}</option>))}
                            </select>
                            <input type="tel" inputMode="numeric" placeholder="Qtd" min="0" value={t.qtd} onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].qtd = parseInt(e.target.value)||0; setVariacoes(n);}} className="bg-slate-900 border border-slate-700 rounded-lg h-10 w-14 text-center text-xs font-bold outline-none text-white" />
                            <div className="flex-1 relative flex items-center">
                                <input type="text" placeholder="EAN" value={t.ean} onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].ean = e.target.value; setVariacoes(n);}} className="w-full bg-slate-950 border border-slate-700 rounded-lg h-10 px-2 pr-10 text-xs font-mono outline-none text-slate-300 placeholder:text-slate-600" />
                                <button type="button" onClick={() => setCameraAtiva({tipo: 'ean', idxCor: cIdx, idxTam: tIdx})} className="absolute right-1 w-8 h-8 flex items-center justify-center text-blue-500 hover:text-white">📷</button>
                            </div>
                            <button type="button" onClick={() => {const n = [...variacoes]; n[cIdx].tamanhos.splice(tIdx, 1); setVariacoes(n);}} className="text-slate-600 hover:text-red-500 px-2 font-bold">✕</button>
                        </div>
                    ))}
                    <button type="button" onClick={() => {const n = [...variacoes]; n[cIdx].tamanhos.push({tamanho_id: '', qtd: 0, ean: ''}); setVariacoes(n);}} className="w-full py-3 text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-blue-400 border border-dashed border-slate-800 hover:border-blue-500/30 rounded-xl transition-all">+ Adicionar Tamanho</button>
                </div>
              </div>
            ))}

            <button type="button" onClick={() => setVariacoes([...variacoes, { cor_id: '', foto: null, preview: '', tamanhos: [{ tamanho_id: '', qtd: 0, ean: '' }] }])} className="w-full py-5 border-2 border-dashed border-slate-800 rounded-[2rem] text-slate-500 font-black text-xs tracking-[0.2em] hover:border-pink-500 hover:text-pink-500 transition-all uppercase mb-8 hover:bg-pink-500/5 active:scale-98">+ Adicionar Nova Cor</button>
          </div>

          <button disabled={loading} className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl hover:shadow-2xl hover:brightness-110 active:scale-95 transition-all uppercase tracking-widest text-sm disabled:opacity-50 disabled:cursor-not-allowed mb-10">{loading ? 'SALVANDO...' : 'FINALIZAR CADASTRO'}</button>
        </form>
      </main>

      {/* MODAL ESCOLHA DE FOTO */}
      {menuFotoIdx !== null && (
          <div className="fixed inset-0 z-[120] bg-black/90 flex flex-col justify-end pb-10 px-4 backdrop-blur-sm animate-in slide-in-from-bottom duration-200" onClick={() => setMenuFotoIdx(null)}>
              <div className="bg-slate-900 rounded-3xl p-6 border border-slate-800 shadow-2xl flex flex-col gap-4" onClick={e => e.stopPropagation()}>
                  <h3 className="text-center font-black uppercase text-slate-500 text-sm tracking-widest mb-2">Adicionar Foto</h3>
                  <button onClick={ligarCameraFoto} className="w-full bg-pink-600 text-white py-4 rounded-2xl font-black text-sm uppercase tracking-widest shadow-lg flex items-center justify-center gap-3 active:scale-95 transition-transform"><span>📷</span> Tirar Foto Agora</button>
                  <label className="w-full bg-slate-800 text-white py-4 rounded-2xl font-black text-sm uppercase tracking-widest shadow-lg flex items-center justify-center gap-3 active:scale-95 transition-transform cursor-pointer"><span>🖼️</span> Escolher da Galeria <input type="file" accept="image/*" onChange={handleGaleria} className="hidden" /></label>
                  <button onClick={() => setMenuFotoIdx(null)} className="w-full py-3 text-slate-500 text-xs font-bold uppercase mt-2">Cancelar</button>
              </div>
          </div>
      )}

      {/* MODAL CÂMERA UNIFICADO */}
      {cameraAtiva && (
        <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md animate-in fade-in duration-200">
           {cameraAtiva.tipo === 'foto' ? (
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
                        <button onClick={confirmarFoto} className="flex-1 bg-green-600 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95">Usar Foto</button>
                        <button onClick={recapturarFoto} className="flex-1 bg-slate-700 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95">Tentar De Novo</button>
                     </>
                 ) : (
                     <>
                        <button onClick={capturarFoto} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95">Capturar</button>
                        <button onClick={fecharCamera} className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95">Cancelar</button>
                     </>
                 )}
               </div>
             </div>
           ) : (
             <div className="w-full max-w-sm flex flex-col items-center gap-6">
                <h3 className="text-white font-black uppercase tracking-widest text-sm">Ler Código de Barras</h3>
                <div id="reader-cadastro-direct" className="w-full rounded-3xl overflow-hidden border-2 border-blue-500 shadow-2xl bg-black h-64"></div>
                <button onClick={fecharCamera} className="w-full bg-slate-800 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95 transition-transform">Cancelar</button>
             </div>
           )}
        </div>
      )}
    </div>
  );
}