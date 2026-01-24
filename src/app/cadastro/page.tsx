'use client';

import { useState, useEffect, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Html5QrcodeScanner } from 'html5-qrcode';

// --- UTILITÁRIOS ---
function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
}

// Formatação visual para o input (ex: 30.00 vira "30,00")
const formatCurrencyInput = (val: string | number) => {
  if (val === '' || val === undefined || val === null) return '';
  const num = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(num)) return '';
  return num.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
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
  
  // Listas de apoio
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
    margem_ganho: '', // Inicia vazio, mas será tratado como 0 no cálculo
  });

  const [variacoes, setVariacoes] = useState<Variacao[]>([]);
  const [cameraAtiva, setCameraAtiva] = useState<{ tipo: 'foto' | 'ean'; idxCor?: number; idxTam?: number } | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);

  // Busca inicial de dados
  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u?.user) {
        router.replace('/login');
        return;
      }

      const novoCodigo = `UPF${new Date().getFullYear()}${Math.floor(1000 + Math.random() * 9000)}`;
      setFormData((prev) => ({ ...prev, codigo_peca: novoCodigo }));

      const { data: t } = await supabase.from('tamanhos').select('*').order('ordem');
      const { data: c } = await supabase.from('cores').select('*').order('ordem');
      
      const { data: f } = await supabase.from('produtos').select('fornecedor');
      if (f) {
        const unicos = Array.from(new Set(f.map(item => item.fornecedor).filter(Boolean)));
        setFornecedoresCadastrados(unicos);
      }

      setListas({ tamanhos: t || [], cores: c || [] });
    })();
  }, [router]);

  // Filtro de Fornecedor
  useEffect(() => {
    if (!formData.fornecedor) {
        setSugestoesFornecedor([]);
        return;
    }
    const termo = formData.fornecedor.toLowerCase();
    const filtrados = fornecedoresCadastrados.filter(f => f.toLowerCase().includes(termo));
    setSugestoesFornecedor(filtrados);
  }, [formData.fornecedor, fornecedoresCadastrados]);

  const getCoresDisponiveis = (idxAtual: number) => {
    const selecionadas = variacoes.map((v, i) => (i !== idxAtual ? v.cor_id : null)).filter(Boolean);
    return listas.cores.filter((c) => !selecionadas.includes(c.id));
  };

  // --- LÓGICA FINANCEIRA CORRIGIDA ---

  // Input "ATM" (divide por 100)
  const handleMoneyInput = (campo: string, valorInput: string) => {
    const apenasDigitos = valorInput.replace(/\D/g, '');
    const floatValue = parseFloat(apenasDigitos) / 100;
    const valorFinal = isNaN(floatValue) ? '0' : floatValue.toString();
    calcularFinanceiro(campo, valorFinal);
  };

  const calcularFinanceiro = (campoAlterado: string, novoValor: string) => {
    // 1. Cria um objeto temporário com o valor que acabou de mudar
    const dadosAtuais = { ...formData, [campoAlterado]: novoValor };

    // 2. Converte tudo para número para poder calcular
    const pCompra = parseFloat(dadosAtuais.preco_compra) || 0;
    const pFrete = parseFloat(dadosAtuais.custo_frete) || 0;
    const pEmb = parseFloat(dadosAtuais.custo_embalagem) || 0;
    const custoTotal = pCompra + pFrete + pEmb;
    
    const margemAtual = parseFloat(dadosAtuais.margem_ganho) || 0;
    const pVendaAtual = parseFloat(dadosAtuais.preco_venda) || 0;

    // 3. Aplica a lógica de quem atualiza quem
    if (campoAlterado === 'preco_venda') {
        // Se mexeu no PREÇO FINAL -> Recalcula a Margem
        // Evita divisão por zero
        if (custoTotal > 0) {
            const novaMargem = ((pVendaAtual - custoTotal) / custoTotal) * 100;
            dadosAtuais.margem_ganho = novaMargem.toFixed(1);
        } else {
            dadosAtuais.margem_ganho = '100'; // Margem padrão se custo for 0
        }
    } else {
        // Se mexeu em CUSTOS (compra, frete, emb) OU na MARGEM -> Recalcula o Preço Final
        const novoPrecoVenda = custoTotal * (1 + (margemAtual / 100));
        dadosAtuais.preco_venda = novoPrecoVenda.toFixed(2);
    }

    // 4. Salva o estado atualizado
    setFormData(dadosAtuais);
  };

  // --- Câmera e Uploads ---
  const ligarCamera = async (idxCor: number) => {
    setCameraAtiva({ tipo: 'foto', idxCor });
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
      setTimeout(() => { if (videoRef.current) videoRef.current.srcObject = stream; }, 100);
    } catch (err) { alert('Câmera indisponível.'); setCameraAtiva(null); }
  };

  const pararCamera = () => {
    const stream = videoRef.current?.srcObject as MediaStream | null;
    stream?.getTracks().forEach((t) => t.stop());
    if (videoRef.current) videoRef.current.srcObject = null;
    setCameraAtiva(null);
  };

  const capturarFoto = () => {
    const canvas = document.createElement('canvas');
    if (!videoRef.current || cameraAtiva?.idxCor === undefined) return;
    const v = videoRef.current;
    canvas.width = v.videoWidth;
    canvas.height = v.videoHeight;
    canvas.getContext('2d')?.drawImage(v, 0, 0);
    canvas.toBlob((blob) => {
      if (!blob) return;
      const file = blobToFile(blob, `foto_${Date.now()}.jpg`);
      const n = [...variacoes];
      n[cameraAtiva.idxCor!].foto = file;
      n[cameraAtiva.idxCor!].preview = URL.createObjectURL(file);
      setVariacoes(n);
      pararCamera();
    }, 'image/jpeg');
  };

  const handleGaleria = (e: any, idxCor: number) => {
    const file: File | undefined = e.target.files?.[0];
    if (!file) return;
    const n = [...variacoes];
    n[idxCor].foto = file;
    n[idxCor].preview = URL.createObjectURL(file);
    setVariacoes(n);
  };

  useEffect(() => {
    if (cameraAtiva?.tipo !== 'ean') return;
    const sc = new Html5QrcodeScanner('reader', { fps: 10, qrbox: 250 }, false);
    sc.render((text) => {
        const n = [...variacoes];
        n[cameraAtiva.idxCor!].tamanhos[cameraAtiva.idxTam!].ean = text;
        setVariacoes(n);
        setCameraAtiva(null);
        sc.clear();
      }, () => {});
    return () => { sc.clear().catch(() => {}); };
  }, [cameraAtiva, variacoes]);

  // --- Validação e Salvamento ---
  function validarAntesDeSalvar() {
    if (!formData.descricao.trim()) return 'Informe a descrição.';
    if (!formData.fornecedor.trim()) return 'Informe o fornecedor.';
    if (variacoes.length === 0) return 'Adicione ao menos uma cor.';
    
    const eans = new Set<string>();
    for (const [i, v] of variacoes.entries()) {
        if (!v.cor_id) return `Selecione a cor na variação #${i + 1}.`;
        if (!v.tamanhos.length) return `Adicione tamanhos na variação #${i + 1}.`;
        
        for (const [j, t] of v.tamanhos.entries()) {
            if (!t.tamanho_id) return `Selecione o tamanho (Variação ${i+1}).`;
            const ean = (t.ean || '').trim();
            if (ean && eans.has(ean)) return `EAN duplicado: ${ean}`;
            if (ean) eans.add(ean);
        }
    }
    return null;
  }

  const salvar = async (e: any) => {
    e.preventDefault();
    const { data: u } = await supabase.auth.getUser();
    if (!u?.user) return alert('Faça login.');

    const erro = validarAntesDeSalvar();
    if (erro) return alert(erro);

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
          fotoPath = path;
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
          UPFITNESS <span className="font-light tracking-normal text-white/80">NOVO ITEM</span>
        </h1>
        <Link href="/" className="bg-black/20 hover:bg-black/40 p-2 px-4 rounded-full text-white text-[10px] font-bold tracking-widest transition-colors border border-white/10">
          CANCELAR
        </Link>
      </header>

      <main className="max-w-4xl mx-auto px-4 space-y-6">
        <form onSubmit={salvar} className="space-y-8">
          
          {/* SEÇÃO 1: DADOS GERAIS */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-5">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Dados do Produto</h2>
            
            <div className="grid grid-cols-1 md:grid-cols-12 gap-5">
              <div className="md:col-span-3 space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Código</label>
                <input readOnly value={formData.codigo_peca} className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl text-slate-400 font-mono text-xs font-bold text-center tracking-widest" />
              </div>
              
              <div className="md:col-span-9 space-y-2">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Descrição *</label>
                <input 
                  value={formData.descricao} 
                  onChange={e => setFormData({...formData, descricao: e.target.value})}
                  placeholder="Ex: Legging Alta Compressão"
                  className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl focus:border-pink-500 outline-none transition-colors text-sm font-bold placeholder:text-slate-700"
                />
              </div>

              {/* CAMPO FORNECEDOR COM AUTOCOMPLETE */}
              <div className="md:col-span-12 space-y-2 relative">
                <label className="text-[10px] font-black text-slate-500 uppercase ml-2">Fornecedor *</label>
                <input 
                  value={formData.fornecedor} 
                  onChange={e => {
                    setFormData({...formData, fornecedor: e.target.value});
                    setMostrarSugestoes(true);
                  }}
                  onFocus={() => setMostrarSugestoes(true)}
                  onBlur={() => setTimeout(() => setMostrarSugestoes(false), 200)}
                  placeholder="Ex: Confecções Silva LTDA"
                  className="w-full bg-slate-950 border border-slate-800 p-4 rounded-xl focus:border-blue-500 outline-none transition-colors text-sm font-bold placeholder:text-slate-700"
                  autoComplete="off"
                />
                
                {mostrarSugestoes && sugestoesFornecedor.length > 0 && (
                    <div className="absolute top-full left-0 right-0 z-50 mt-1 bg-slate-800 border border-slate-700 rounded-xl shadow-2xl overflow-hidden max-h-48 overflow-y-auto">
                        {sugestoesFornecedor.map((sugestao, idx) => (
                            <button
                                key={idx}
                                type="button"
                                onClick={() => {
                                    setFormData({...formData, fornecedor: sugestao});
                                    setMostrarSugestoes(false);
                                }}
                                className="w-full text-left px-4 py-3 text-xs font-bold text-slate-300 hover:bg-pink-600 hover:text-white transition-colors border-b border-slate-700/50 last:border-0"
                            >
                                {sugestao}
                            </button>
                        ))}
                    </div>
                )}
              </div>
            </div>
          </section>

          {/* SEÇÃO 2: FINANCEIRO (PADRONIZADO) */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-6">
             <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Precificação</h2>
             
             <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                
                {/* PREÇO COMPRA */}
                <div className="relative group">
                    <span className="absolute left-2 top-1.5 text-[10px] text-slate-500 font-bold">R$</span>
                    <input 
                        placeholder="0,00"
                        type="tel"
                        value={formatCurrencyInput(formData.preco_compra)} 
                        onChange={e => handleMoneyInput('preco_compra', e.target.value)} 
                        className="w-full bg-slate-950 text-sm font-bold py-3 pl-7 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none transition-colors text-white" 
                    />
                    <span className="absolute right-2 top-2 text-[8px] text-slate-600 uppercase font-black pointer-events-none">Peça</span>
                </div>

                {/* FRETE */}
                <div className="relative group">
                    <span className="absolute left-2 top-1.5 text-[10px] text-slate-500 font-bold">R$</span>
                    <input 
                        placeholder="0,00"
                        type="tel"
                        value={formatCurrencyInput(formData.custo_frete)} 
                        onChange={e => handleMoneyInput('custo_frete', e.target.value)} 
                        className="w-full bg-slate-950 text-sm font-bold py-3 pl-7 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none transition-colors text-slate-300" 
                    />
                    <span className="absolute right-2 top-2 text-[8px] text-slate-600 uppercase font-black pointer-events-none">Frete</span>
                </div>

                {/* EMBALAGEM */}
                <div className="relative group col-span-2 md:col-span-1">
                    <span className="absolute left-2 top-1.5 text-[10px] text-slate-500 font-bold">R$</span>
                    <input 
                        placeholder="0,00"
                        type="tel"
                        value={formatCurrencyInput(formData.custo_embalagem)} 
                        onChange={e => handleMoneyInput('custo_embalagem', e.target.value)} 
                        className="w-full bg-slate-950 text-sm font-bold py-3 pl-7 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none transition-colors text-slate-300" 
                    />
                    <span className="absolute right-2 top-2 text-[8px] text-slate-600 uppercase font-black pointer-events-none">Emb.</span>
                </div>
             </div>

             <div className="grid grid-cols-2 gap-4 pt-2">
                <div className="bg-slate-950/50 p-4 rounded-2xl border border-pink-900/30 text-center relative">
                    <label className="block text-[10px] font-black text-pink-500 mb-1 uppercase tracking-wider">Margem Desejada</label>
                    <div className="flex items-center justify-center gap-1">
                        <input 
                            type="number" 
                            step="0.1" 
                            value={formData.margem_ganho} 
                            onChange={e => calcularFinanceiro('margem_ganho', e.target.value)} 
                            className="w-20 bg-transparent text-center font-black text-2xl text-pink-500 outline-none appearance-none [&::-webkit-inner-spin-button]:appearance-none" 
                            placeholder="0"
                        />
                        <span className="text-pink-500 font-bold text-lg">%</span>
                    </div>
                </div>

                <div className="bg-blue-900/10 p-4 rounded-2xl border border-blue-900/20 text-center relative group">
                    <label className="block text-[10px] font-black text-blue-400 mb-1 uppercase tracking-wider">Preço Venda Final</label>
                    <div className="relative inline-block w-full">
                         <span className="absolute left-2 top-2 text-sm text-blue-500/50 font-bold">R$</span>
                        <input 
                            type="tel"
                            value={formatCurrencyInput(formData.preco_venda)} 
                            onChange={e => handleMoneyInput('preco_venda', e.target.value)} 
                            className="w-full bg-transparent text-center font-black text-2xl text-blue-400 outline-none" 
                        />
                    </div>
                </div>
             </div>
             
             {/* CUSTO TOTAL (Texto informativo) */}
             <div className="text-center">
                <p className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">
                    Custo Real Total: <b className="text-slate-300 text-sm ml-1">{formatCurrencyInput((parseFloat(formData.preco_compra)||0) + (parseFloat(formData.custo_frete)||0) + (parseFloat(formData.custo_embalagem)||0))}</b>
                </p>
             </div>
          </section>

          {/* SEÇÃO 3: CORES E GRADE */}
          <div className="space-y-6">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest border-b border-slate-800 pb-2">Estoque & Variações</h2>

            {variacoes.map((v, cIdx) => (
              <div key={cIdx} className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl relative animate-in fade-in slide-in-from-bottom-4 duration-500">
                
                <div className="mb-6">
                    <label className="text-[10px] font-black text-slate-500 uppercase ml-2 block mb-2">Cor</label>
                    <select 
                        required 
                        value={v.cor_id} 
                        onChange={(e) => { const n = [...variacoes]; n[cIdx].cor_id = e.target.value; setVariacoes(n); }} 
                        className="w-full bg-slate-950 text-white font-bold p-4 rounded-xl border border-slate-800 outline-none focus:border-pink-500 text-sm appearance-none"
                    >
                        <option value="">Selecione a Cor...</option>
                        {getCoresDisponiveis(cIdx).map((c) => (<option key={c.id} value={c.id}>{c.nome}</option>))}
                    </select>
                </div>

                <div className="flex flex-col md:flex-row gap-6">
                  {/* PREVIEW DA FOTO */}
                  <div className="w-full md:w-32 flex-shrink-0 flex flex-col gap-3">
                    <div className="aspect-[3/4] bg-slate-950 rounded-2xl border border-slate-800 flex items-center justify-center overflow-hidden relative group shadow-inner">
                      {v.preview ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={v.preview} className="w-full h-full object-cover" alt="preview" />
                      ) : (
                        <div className="text-center p-2 opacity-30">
                            <span className="text-2xl">📷</span>
                        </div>
                      )}
                      <div className="absolute inset-0 bg-black/80 opacity-0 group-hover:opacity-100 transition-opacity flex flex-col items-center justify-center gap-2 p-2">
                          <button type="button" onClick={() => ligarCamera(cIdx)} className="w-full bg-blue-600 hover:bg-blue-500 text-[9px] py-2 rounded-lg font-black tracking-widest text-white">FOTO</button>
                          <label className="w-full bg-slate-700 hover:bg-slate-600 text-[9px] py-2 rounded-lg font-black tracking-widest text-center cursor-pointer text-white">
                             UPLOAD <input type="file" accept="image/*" onChange={(e) => handleGaleria(e, cIdx)} className="hidden" />
                          </label>
                      </div>
                    </div>
                  </div>

                  {/* LISTA DE TAMANHOS */}
                  <div className="flex-1 space-y-3">
                    {v.tamanhos.map((t, tIdx) => (
                        <div key={tIdx} className="flex gap-2 items-center bg-slate-950 p-2 pl-3 rounded-xl border border-slate-800 shadow-sm hover:border-slate-700 transition-colors">
                            {/* Select Tamanho */}
                            <select required value={t.tamanho_id} onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].tamanho_id = e.target.value; setVariacoes(n);}} className="bg-transparent text-sm font-black text-blue-400 w-16 outline-none appearance-none">
                                <option value="">Tam</option>
                                {listas.tamanhos.map((tam) => (<option key={tam.id} value={tam.id}>{tam.nome}</option>))}
                            </select>
                            
                            <div className="w-px h-6 bg-slate-800"></div>
                            
                            {/* Input Qtd */}
                            <input 
                                type="number" 
                                placeholder="Qtd" 
                                min="0" 
                                value={t.qtd} 
                                onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].qtd = parseInt(e.target.value)||0; setVariacoes(n);}} 
                                className="w-12 bg-transparent text-center text-sm font-bold outline-none text-white appearance-none [&::-webkit-inner-spin-button]:appearance-none" 
                            />
                            
                            <div className="w-px h-6 bg-slate-800"></div>
                            
                            {/* Input EAN */}
                            <input type="text" placeholder="Código Barras" value={t.ean} onChange={(e) => {const n = [...variacoes]; n[cIdx].tamanhos[tIdx].ean = e.target.value; setVariacoes(n);}} className="flex-1 bg-transparent text-xs font-bold outline-none text-slate-400 placeholder:text-slate-800" />
                            
                            <button type="button" onClick={() => setCameraAtiva({tipo: 'ean', idxCor: cIdx, idxTam: tIdx})} className="text-slate-600 hover:text-blue-500 p-2 transition-colors" title="Ler Código de Barras">📷</button>
                            
                            <button type="button" onClick={() => {const n = [...variacoes]; n[cIdx].tamanhos.splice(tIdx, 1); setVariacoes(n);}} className="bg-red-950/30 hover:bg-red-600 text-red-500 hover:text-white w-8 h-8 rounded-lg transition-all flex items-center justify-center font-bold">
                                ✕
                            </button>
                        </div>
                    ))}
                    <button type="button" onClick={() => {const n = [...variacoes]; n[cIdx].tamanhos.push({tamanho_id: '', qtd: 0, ean: ''}); setVariacoes(n);}} className="w-full py-3 text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-blue-400 border border-dashed border-slate-800 hover:border-blue-500/30 rounded-xl transition-all">
                        + Adicionar Tamanho
                    </button>
                  </div>
                </div>
                
                <button type="button" onClick={() => setVariacoes(variacoes.filter((_, i) => i !== cIdx))} className="absolute top-4 right-4 text-[9px] text-red-900/60 hover:text-red-500 font-bold uppercase tracking-widest transition-colors">
                    Excluir Variação
                </button>
              </div>
            ))}

            <button type="button" onClick={() => setVariacoes([...variacoes, { cor_id: '', foto: null, preview: '', tamanhos: [{ tamanho_id: '', qtd: 0, ean: '' }] }])} className="w-full py-6 border-2 border-dashed border-slate-800 rounded-[2rem] text-slate-500 font-black text-xs tracking-[0.2em] hover:border-pink-500 hover:text-pink-500 transition-all uppercase mb-8 hover:bg-pink-500/5">
                + Adicionar Nova Cor
            </button>
          </div>

          <button disabled={loading} className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl hover:shadow-2xl hover:brightness-110 active:scale-95 transition-all uppercase tracking-widest text-xs disabled:opacity-50 disabled:cursor-not-allowed">
            {loading ? 'SALVANDO...' : 'CADASTRAR ITEM'}
          </button>
        </form>
      </main>

      {/* MODAL CÂMERA */}
      {cameraAtiva && (
        <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md animate-in fade-in duration-200">
           {cameraAtiva.tipo === 'foto' ? (
             <div className="w-full max-w-sm flex flex-col items-center gap-6">
               <h3 className="text-white font-black uppercase tracking-widest text-sm">Capturar Foto</h3>
               <video ref={videoRef} autoPlay playsInline className="w-full aspect-[3/4] rounded-3xl border-2 border-pink-500 object-cover bg-slate-900 shadow-2xl" />
               <div className="flex gap-4 w-full">
                 <button onClick={capturarFoto} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest shadow-lg active:scale-95 transition-transform">Capturar</button>
                 <button onClick={pararCamera} className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95 transition-transform">Voltar</button>
               </div>
             </div>
           ) : (
             <div className="w-full max-w-sm flex flex-col items-center gap-6">
                <h3 className="text-white font-black uppercase tracking-widest text-sm">Ler Código de Barras</h3>
                <div id="reader" className="w-full rounded-3xl overflow-hidden border-2 border-blue-500 shadow-2xl bg-black"></div>
                <button onClick={() => setCameraAtiva(null)} className="w-full bg-slate-800 text-white py-4 rounded-2xl font-black text-xs uppercase tracking-widest active:scale-95 transition-transform">Cancelar</button>
             </div>
           )}
        </div>
      )}
    </div>
  );
}