'use client';

import { useState, useEffect, useRef, useMemo, Suspense } from 'react';
import { supabase } from '../../lib/supabase';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { gerarThumb, thumbPathFromOriginal } from '../../lib/thumbUtils';

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
  try {
    const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3');
    audio.volume = 0.5;
    audio.play().catch(() => {});
  } catch {}

  if (typeof window !== 'undefined' && window.navigator && (window.navigator as any).vibrate) {
    (window.navigator as any).vibrate(50);
  }
};

function getDashboardQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

/**
 * IMPORTANTE (Next.js / Vercel):
 * useSearchParams() precisa estar dentro de um Suspense boundary.
 */
export default function CadastroPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950" />}>
      <CadastroPageInner />
    </Suspense>
  );
}

function CadastroPageInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getDashboardQS(searchParams), [searchParams]);

  const [loading, setLoading] = useState(false);

  // Listas Auxiliares
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);

  // Autocomplete Fornecedor
  const [fornecedoresCadastrados, setFornecedoresCadastrados] = useState<string[]>([]);
  const [sugestoesFornecedor, setSugestoesFornecedor] = useState<string[]>([]);
  const [mostrarSugestoes, setMostrarSugestoes] = useState(false);

  // ✅ manter padrão do app: esconder nav inferior quando teclado abre (iOS)
  const [inputFocado, setInputFocado] = useState(false);

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
    { tamanho_id: '', qtd: 0, ean: '' },
  ]);

  // CÂMERA E SCANNER
  const [modalFotoAberto, setModalFotoAberto] = useState(false);
  const [cameraAtiva, setCameraAtiva] = useState<{ tipo: 'foto' | 'ean'; idxTam?: number } | null>(null);
  const [fotoTemp, setFotoTemp] = useState<{ url: string; blob: Blob } | null>(null);

  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);

  // ✅ scanner robusto (igual dashboard)
  const scannerRef = useRef<any>(null);
  const zxingRef = useRef<{ reset: () => void } | null>(null);

  // --- CARREGAMENTO INICIAL ---
  useEffect(() => {
    (async () => {
      const { data: u } = await supabase.auth.getUser();
      if (!u?.user) {
        router.replace('/login');
        return;
      }

      // Gerar Código Interno
      const novoCodigo = `UPF${new Date().getFullYear()}${Math.floor(1000 + Math.random() * 9000)}`;
      setFormData((prev) => ({ ...prev, codigo_peca: novoCodigo }));

      // Buscar Tamanhos
      const { data: t } = await supabase.from('tamanhos').select('*').order('ordem', { ascending: true });
      if (t) setListaTamanhos(t);

      // Buscar Fornecedores para sugestão
      const { data: f } = await supabase.from('produtos').select('fornecedor');
      if (f) {
        const unicos = Array.from(new Set(f.map((item: any) => item.fornecedor).filter(Boolean)));
        setFornecedoresCadastrados(unicos);
      }
    })();
  }, [router]);

  // Filtro Fornecedor
  useEffect(() => {
    if (!formData.fornecedor) {
      setSugestoesFornecedor([]);
      return;
    }
    const termo = formData.fornecedor.toLowerCase();
    const filtrados = fornecedoresCadastrados.filter((f) => f.toLowerCase().includes(termo));
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
      const novoPrecoVenda = custoTotal * (1 + margemAtual / 100);
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
        video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
      });
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch {
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

    canvas.toBlob(
      (blob) => {
        if (!blob) return;
        setFotoTemp({ url: URL.createObjectURL(blob), blob });
      },
      'image/jpeg',
      0.85
    );
  };

  const confirmarFoto = () => {
    if (!fotoTemp) return;
    const file = blobToFile(fotoTemp.blob, `foto_${Date.now()}.jpg`);
    setFoto({ file, preview: fotoTemp.url });
    fecharCamera();
  };

  const handleGaleria = (e: any) => {
    const file = e.target.files?.[0];
    if (file) {
      setFoto({ file, preview: URL.createObjectURL(file) });
      setModalFotoAberto(false);
    }
  };

  // --- FECHAR CÂMERA/SCANNER ---
  const fecharCamera = async () => {
    setFotoTemp(null);

    // fecha stream (foto)
    if (streamRef.current) {
      try {
        streamRef.current.getTracks().forEach((t) => t.stop());
      } catch {}
      streamRef.current = null;
    }
    if (videoRef.current) (videoRef.current as any).srcObject = null;

    // fecha scanner html5-qrcode
    try {
      const s = scannerRef.current;
      if (s) {
        try {
          const maybe = s.stop?.();
          if (maybe && typeof maybe.then === 'function') await maybe.catch(() => {});
        } catch {}
        try {
          s.clear?.();
        } catch {}
      }
    } catch {}

    // fecha fallback ZXing
    if (zxingRef.current) {
      try {
        zxingRef.current.reset();
      } catch {}
      zxingRef.current = null;
    }

    setCameraAtiva(null);
  };

  // --- SCANNER (EAN) ROBUSTO (igual dashboard) ---
  useEffect(() => {
    if (cameraAtiva?.tipo !== 'ean') return;

    const elementId = 'reader-cadastro-direct';
    let cancelled = false;

    const stopAndClear = async (s: any) => {
      if (!s) return;
      try {
        const maybe = s.stop?.();
        if (maybe && typeof maybe.then === 'function') {
          await maybe.catch(() => {});
        }
      } catch {}
      try {
        s.clear?.();
      } catch {}
    };

    const start = async () => {
      await new Promise((r) => setTimeout(r, 150));
      if (cancelled) return;

      const el = document.getElementById(elementId);
      if (!el) return;

      // limpa e mostra html5-qrcode container
      el.innerHTML = '';
      el.classList.remove('hidden');

      // prepara video do zxing
      const zxingVideo = document.getElementById('zxing-video-cadastro') as HTMLVideoElement | null;
      if (zxingVideo) zxingVideo.classList.add('hidden');

      await stopAndClear(scannerRef.current);
      if (zxingRef.current) {
        try {
          zxingRef.current.reset();
        } catch {}
        zxingRef.current = null;
      }

      const onFound = (text: string) => {
        const cleaned = String(text || '').trim();
        if (!cleaned) return;
        playBeep();

        if (cameraAtiva?.idxTam !== undefined) {
          setTamanhos((prev) => {
            const n = [...prev];
            if (n[cameraAtiva.idxTam!]) n[cameraAtiva.idxTam!].ean = cleaned;
            return n;
          });
        }

        fecharCamera();
      };

      // Detecta suporte a BarcodeDetector (fundamental para 1D no desktop)
      const hasBarcodeDetector = typeof (window as any).BarcodeDetector !== 'undefined';

      // ZXing fallback (desktop sem BarcodeDetector)
      if (!hasBarcodeDetector) {
        try {
          const [{ BrowserMultiFormatReader }, { BarcodeFormat, DecodeHintType }] = await Promise.all([
            import('@zxing/browser'),
            import('@zxing/library'),
          ]);

          if (cancelled) return;

          if (!zxingVideo) {
            console.error('ZXing video element não encontrado.');
            return;
          }

          // esconde html5-qrcode e mostra o video
          el.classList.add('hidden');
          zxingVideo.classList.remove('hidden');

          const hints = new Map();
          hints.set(DecodeHintType.POSSIBLE_FORMATS, [BarcodeFormat.EAN_13, BarcodeFormat.EAN_8]);

          const reader = new BrowserMultiFormatReader(hints, { delayBetweenScanAttempts: 200 });

          zxingRef.current = {
            reset: () => {
              try {
                (reader as any).stopContinuousDecode?.();
              } catch {}
              try {
                (reader as any).stopAsyncDecode?.();
              } catch {}
              try {
                const stream = (zxingVideo as any)?.srcObject as MediaStream | null;
                stream?.getTracks?.().forEach((t) => t.stop());
                (zxingVideo as any).srcObject = null;
              } catch {}
            },
          };

          const devices = await BrowserMultiFormatReader.listVideoInputDevices();
          const preferred = devices.find((d: any) => /back|rear|traseira|environment/i.test(d.label)) ?? devices[0];

          reader.decodeFromVideoDevice(preferred?.deviceId, zxingVideo, (result) => {
            if (cancelled) return;
            const text = result?.getText?.() ? result.getText() : '';
            if (text) onFound(text);
          });

          return;
        } catch (err) {
          console.error('Falha ao iniciar ZXing fallback:', err);
        }
      }

      // html5-qrcode (iPhone / browsers com BarcodeDetector)
      let Html5Qrcode: any;
      let Formats: any;

      try {
        const mod = await import('html5-qrcode');
        if (cancelled) return;
        Html5Qrcode = mod.Html5Qrcode;
        Formats = mod.Html5QrcodeSupportedFormats;
      } catch (err) {
        console.error('Falha ao carregar html5-qrcode:', err);
        alert('Erro ao iniciar câmera.');
        return;
      }

      const scanner = new Html5Qrcode(elementId);
      scannerRef.current = scanner;

      const config: any = {
        fps: 9,
        qrbox: { width: 280, height: 120 },
        aspectRatio: 1.777,
        disableFlip: true,
        formatsToSupport: [Formats.EAN_13, Formats.EAN_8],
        experimentalFeatures: { useBarCodeDetectorIfSupported: true },
        videoConstraints: { width: { ideal: 1280 }, height: { ideal: 720 } },
      };

      try {
        const cameras = await Html5Qrcode.getCameras();
        const preferred = cameras.find((c: any) => /back|rear|traseira|environment/i.test(c.label)) ?? cameras[0];

        await scanner.start({ deviceId: { exact: preferred.id } }, config, onFound, () => {});
      } catch (err) {
        console.error('Falha ao iniciar html5-qrcode:', err);
        try {
          await scanner.start({ facingMode: 'environment' }, config, onFound, () => {});
        } catch (err2) {
          console.error('Fallback html5-qrcode falhou:', err2);
          alert('Erro ao iniciar câmera.');
        }
      }
    };

    start();

    return () => {
      cancelled = true;
      stopAndClear(scannerRef.current);
      if (zxingRef.current) {
        try {
          zxingRef.current.reset();
        } catch {}
        zxingRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cameraAtiva?.tipo, cameraAtiva?.idxTam]);

  // --- SALVAR NOVO MODELO ---
  const salvar = async (e: any) => {
    e.preventDefault();
    if (!formData.descricao.trim()) return alert('Informe a descrição.');
    if (!formData.fornecedor.trim()) return alert('Informe o fornecedor.');
    if (!formData.cor.trim()) return alert('Informe a cor.');
    if (tamanhos.length === 0) return alert('Adicione pelo menos um tamanho.');

    setLoading(true);

    try {
      // 1. Upload da Foto + Thumb
      let fotoPath: string | null = null;
      if (foto.file) {
        const timestamp = Date.now();
        const filename = `${formData.codigo_peca}_${timestamp}.jpg`;
        const path = `migracao/${filename}`;
        const thumbPath = thumbPathFromOriginal(path); // "migracao/thumbs/UP001_123.jpg"

        // Upload da foto original
        await supabase.storage.from('produtos').upload(path, foto.file, { upsert: true });
        const { data: pubUrl } = supabase.storage.from('produtos').getPublicUrl(path);
        fotoPath = pubUrl.publicUrl;

        // Gera e faz upload da thumb (não bloqueia o cadastro se falhar)
        try {
          const thumbFile = await gerarThumb(foto.file);
          await supabase.storage.from('produtos').upload(thumbPath, thumbFile, { upsert: true });
        } catch (thumbErr) {
          console.warn('Thumb não gerada (não crítico):', thumbErr);
        }
      }

      // 2. Criar Produto
      const { data: p, error: pe } = await supabase
        .from('produtos')
        .insert([
          {
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
          },
        ])
        .select('id')
        .single();

      if (pe) throw pe;

      // 3. Criar Estoque
      const dadosEstoque = tamanhos
        .map((t) => ({
          produto_id: (p as any).id,
          tamanho_id: t.tamanho_id,
          quantidade: Math.max(0, parseInt(String(t.qtd)) || 0),
          codigo_barras: t.ean?.trim() ? t.ean.trim() : null,
        }))
        .filter((t) => t.tamanho_id);

      if (dadosEstoque.length > 0) {
        const { error: estErr } = await supabase.from('estoque').insert(dadosEstoque);
        if (estErr) throw estErr;
      }

      alert('Produto cadastrado com sucesso!');
      router.push(`/${dashQS}`);
    } catch (err: any) {
      console.error(err);
      alert('Erro: ' + err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 pb-44 font-sans">
      {/* HEADER (padrão do app) */}
      <header className="px-6 pt-10 pb-6 bg-slate-950 border-b border-slate-900 backdrop-blur-md sticky top-0 z-[60]">
        <div className="flex items-end justify-between gap-4">
          <div className="flex items-end gap-3">
            <Link
              href={`/${dashQS}`}
              className="w-12 h-12 bg-slate-900 border border-slate-800 text-white rounded-2xl flex items-center justify-center text-xl shadow-lg active:scale-90 transition-transform"
              aria-label="Voltar"
              title="Voltar"
            >
              ←
            </Link>

            <div>
              <p className="text-[10px] font-black tracking-[0.3em] text-pink-500 uppercase mb-1">UpFitness App</p>
              <h1 className="text-2xl font-black italic tracking-tighter uppercase">
                CADASTRO <span className="font-light not-italic text-slate-500 text-lg">ITEM</span>
              </h1>
            </div>
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 pt-6 space-y-6">
        <form onSubmit={salvar} className="space-y-8">
          {/* SEÇÃO 1: IDENTIFICAÇÃO E FOTO */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">
              Identificação do Item
            </h2>

            <div className="flex flex-col md:flex-row gap-6">
              {/* FOTO */}
              <div className="shrink-0 flex justify-center md:justify-start">
                <button
                  type="button"
                  onClick={() => setModalFotoAberto(true)}
                  className="w-32 h-32 rounded-3xl bg-slate-950 border-2 border-dashed border-slate-700 hover:border-pink-500 hover:text-pink-500 flex flex-col items-center justify-center relative overflow-hidden group transition-all"
                >
                  {foto.preview ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={foto.preview} className="w-full h-full object-cover" alt="Preview" />
                  ) : (
                    <>
                      <span className="text-3xl mb-1 opacity-50">📷</span>
                      <span className="text-[9px] font-black uppercase tracking-widest">Add Foto</span>
                    </>
                  )}
                  {foto.preview && (
                    <div className="absolute inset-x-0 bottom-0 bg-black/60 text-[8px] font-bold text-white py-1 text-center">
                      ALTERAR
                    </div>
                  )}
                </button>
              </div>

              {/* DADOS */}
              <div className="flex-1 space-y-4">
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Cód. Interno</label>
                    <input
                      readOnly
                      value={formData.codigo_peca}
                      className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl text-slate-400 font-mono text-base md:text-sm font-bold text-center tracking-widest"
                    />
                  </div>
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">SKU Fornecedor</label>
                    <input
                      value={formData.sku_fornecedor}
                      onChange={(e) => setFormData({ ...formData, sku_fornecedor: e.target.value })}
                      placeholder="Ex: REF-998"
                      onFocus={() => setInputFocado(true)}
                      onBlur={() => setInputFocado(false)}
                      className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl text-white font-bold text-base md:text-xs focus:border-pink-500 outline-none"
                    />
                  </div>
                </div>

                <div className="space-y-1">
                  <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Descrição do Produto *</label>
                  <input
                    value={formData.descricao}
                    onChange={(e) => setFormData({ ...formData, descricao: e.target.value })}
                    placeholder="Ex: Legging Alta Compressão"
                    onFocus={() => setInputFocado(true)}
                    onBlur={() => setInputFocado(false)}
                    className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-pink-500 outline-none transition-colors text-base md:text-sm font-bold text-white"
                  />
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-1 relative">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Fornecedor *</label>
                    <input
                      value={formData.fornecedor}
                      onChange={(e) => {
                        setFormData({ ...formData, fornecedor: e.target.value });
                        setMostrarSugestoes(true);
                      }}
                      onFocus={() => {
                        setMostrarSugestoes(true);
                        setInputFocado(true);
                      }}
                      onBlur={() => {
                        setTimeout(() => setMostrarSugestoes(false), 200);
                        setInputFocado(false);
                      }}
                      className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-blue-500 outline-none transition-colors text-base md:text-sm font-bold text-white"
                      placeholder="Digite..."
                    />
                    {mostrarSugestoes && sugestoesFornecedor.length > 0 && (
                      <div className="absolute top-full left-0 right-0 z-[80] mt-1 bg-slate-900 border border-slate-800 rounded-2xl shadow-2xl overflow-hidden max-h-56 overflow-y-auto">
                        {sugestoesFornecedor.map((s, idx) => (
                          <button
                            key={idx}
                            type="button"
                            onMouseDown={(e) => e.preventDefault()}
                            onClick={() => {
                              setFormData({ ...formData, fornecedor: s });
                              setMostrarSugestoes(false);
                            }}
                            className="w-full text-left px-4 py-3 text-xs font-bold text-slate-300 hover:bg-pink-600 hover:text-white border-b border-slate-800/70"
                          >
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
                      onChange={(e) => setFormData({ ...formData, cor: e.target.value })}
                      placeholder="Ex: Preto, Storm..."
                      onFocus={() => setInputFocado(true)}
                      onBlur={() => setInputFocado(false)}
                      className="w-full bg-slate-950 border border-slate-800 p-3 rounded-xl focus:border-pink-500 outline-none transition-colors text-base md:text-sm font-bold text-white"
                    />
                  </div>
                </div>
              </div>
            </div>
          </section>

          {/* SEÇÃO 2: FINANCEIRO */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl space-y-6">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Precificação</h2>

            <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
              <div className="relative">
                <span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span>
                <input
                  type="tel"
                  inputMode="decimal"
                  value={formatCurrencyInput(formData.preco_compra)}
                  onChange={(e) => handleMoneyInput('preco_compra', e.target.value)}
                  onFocus={() => setInputFocado(true)}
                  onBlur={() => setInputFocado(false)}
                  className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-white h-12"
                  placeholder="0,00"
                />
                <span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Custo</span>
              </div>

              <div className="relative">
                <span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span>
                <input
                  type="tel"
                  inputMode="decimal"
                  value={formatCurrencyInput(formData.custo_frete)}
                  onChange={(e) => handleMoneyInput('custo_frete', e.target.value)}
                  onFocus={() => setInputFocado(true)}
                  onBlur={() => setInputFocado(false)}
                  className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-slate-200 h-12"
                  placeholder="0,00"
                />
                <span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Frete</span>
              </div>

              <div className="relative col-span-2 md:col-span-1">
                <span className="absolute left-3 top-3 text-xs text-slate-500 font-bold">R$</span>
                <input
                  type="tel"
                  inputMode="decimal"
                  value={formatCurrencyInput(formData.custo_embalagem)}
                  onChange={(e) => handleMoneyInput('custo_embalagem', e.target.value)}
                  onFocus={() => setInputFocado(true)}
                  onBlur={() => setInputFocado(false)}
                  className="w-full bg-slate-950 text-base md:text-sm font-bold py-3 pl-8 pr-2 rounded-xl border border-slate-800 focus:border-pink-500 outline-none text-slate-200 h-12"
                  placeholder="0,00"
                />
                <span className="absolute right-2 top-1 text-[8px] text-slate-600 uppercase font-black pointer-events-none bg-slate-950 px-1">Emb.</span>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4 pt-2">
              <div className="bg-slate-950/50 p-3 rounded-2xl border border-pink-900/30 text-center">
                <label className="block text-[9px] font-black text-pink-500 mb-1 uppercase tracking-wider">Margem</label>
                <div className="flex items-center justify-center gap-1">
                  <input
                    type="number"
                    inputMode="decimal"
                    step="0.1"
                    value={formData.margem_ganho}
                    onChange={(e) => calcularFinanceiro('margem_ganho', e.target.value)}
                    onFocus={() => setInputFocado(true)}
                    onBlur={() => setInputFocado(false)}
                    className="w-full bg-transparent text-center font-black text-xl text-pink-500 outline-none h-10"
                    placeholder="0"
                  />
                  <span className="text-pink-500 font-bold text-lg">%</span>
                </div>
              </div>

              <div className="bg-blue-900/10 p-3 rounded-2xl border border-blue-900/20 text-center">
                <label className="block text-[9px] font-black text-blue-400 mb-1 uppercase tracking-wider">Venda Final</label>
                <div className="relative inline-block w-full">
                  <span className="absolute left-2 top-2 text-sm text-blue-500/50 font-bold">R$</span>
                  <input
                    type="tel"
                    inputMode="decimal"
                    value={formatCurrencyInput(formData.preco_venda)}
                    onChange={(e) => handleMoneyInput('preco_venda', e.target.value)}
                    onFocus={() => setInputFocado(true)}
                    onBlur={() => setInputFocado(false)}
                    className="w-full bg-transparent text-center font-black text-xl text-blue-400 outline-none h-10"
                  />
                </div>
              </div>
            </div>
          </section>

          {/* SEÇÃO 3: GRADE DE TAMANHOS */}
          <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl">
            <h2 className="text-sm font-black text-slate-500 uppercase tracking-widest mb-4 border-b border-slate-800 pb-2">Grade de Tamanhos</h2>

            <div className="space-y-3">
              {tamanhos.map((t, idx) => (
                <div
                  key={idx}
                  className="bg-slate-950 p-2 rounded-xl border border-slate-800 shadow-sm flex gap-2 items-center animate-in slide-in-from-bottom-2"
                >
                  <select
                    value={t.tamanho_id}
                    onChange={(e) => {
                      const n = [...tamanhos];
                      n[idx].tamanho_id = e.target.value;
                      setTamanhos(n);
                    }}
                    className="bg-slate-900 border border-slate-800 rounded-lg text-base md:text-xs font-black text-blue-400 h-12 w-20 outline-none px-2"
                  >
                    <option value="">Tam</option>
                    {listaTamanhos.map((tm) => (
                      <option key={tm.id} value={tm.id}>
                        {tm.nome}
                      </option>
                    ))}
                  </select>

                  <input
                    type="tel"
                    inputMode="numeric"
                    placeholder="Qtd"
                    value={t.qtd}
                    onChange={(e) => {
                      const n = [...tamanhos];
                      n[idx].qtd = parseInt(e.target.value) || 0;
                      setTamanhos(n);
                    }}
                    onFocus={() => setInputFocado(true)}
                    onBlur={() => setInputFocado(false)}
                    className="bg-slate-900 border border-slate-800 rounded-lg h-12 w-16 text-center text-base md:text-xs font-bold outline-none text-white"
                  />

                  <div className="flex-1 relative flex items-center">
                    <input
                      type="text"
                      placeholder="EAN / Cód. Barras"
                      value={t.ean}
                      onChange={(e) => {
                        const n = [...tamanhos];
                        n[idx].ean = e.target.value;
                        setTamanhos(n);
                      }}
                      onFocus={() => setInputFocado(true)}
                      onBlur={() => setInputFocado(false)}
                      className="w-full bg-slate-950 border border-slate-800 rounded-lg h-12 px-3 pr-10 text-base md:text-xs font-mono outline-none text-slate-200 placeholder:text-slate-600"
                    />
                    <button
                      type="button"
                      onClick={() => setCameraAtiva({ tipo: 'ean', idxTam: idx })}
                      className="absolute right-2 w-9 h-9 rounded-xl bg-slate-800/30 border border-slate-800 text-slate-200 flex items-center justify-center active:scale-90 transition-transform"
                      aria-label="Scanner"
                      title="Scanner"
                    >
                      📷
                    </button>
                  </div>

                  <button
                    type="button"
                    onClick={() => {
                      const n = [...tamanhos];
                      n.splice(idx, 1);
                      setTamanhos(n);
                    }}
                    className="w-10 h-10 flex items-center justify-center text-slate-600 hover:text-red-500 font-bold bg-slate-900 rounded-lg border border-slate-800"
                    aria-label="Remover"
                    title="Remover"
                  >
                    ✕
                  </button>
                </div>
              ))}

              <button
                type="button"
                onClick={() => setTamanhos([...tamanhos, { tamanho_id: '', qtd: 0, ean: '' }])}
                className="w-full py-4 border border-dashed border-slate-700 rounded-xl text-slate-500 font-black text-xs uppercase hover:bg-slate-800 hover:text-blue-400 transition-colors tracking-widest"
              >
                + Adicionar Tamanho
              </button>
            </div>
          </section>

          <button
            disabled={loading}
            className="w-full bg-gradient-to-r from-pink-600 to-blue-600 text-white font-black py-5 rounded-[2rem] shadow-xl shadow-pink-500/20 active:scale-95 transition-all uppercase tracking-widest text-sm disabled:opacity-50 disabled:cursor-not-allowed mb-10"
          >
            {loading ? 'SALVANDO...' : 'FINALIZAR CADASTRO'}
          </button>
        </form>
      </main>

      {/* MODAL FOTO */}
      {modalFotoAberto && (
        <div className="fixed inset-0 z-[120] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4" onClick={() => setModalFotoAberto(false)}>
          <div
            className="bg-slate-900 w-full max-w-sm rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex justify-between items-center mb-6">
              <h3 className="text-sm font-black italic text-pink-500 uppercase tracking-tighter">Foto</h3>
              <button onClick={() => setModalFotoAberto(false)} className="text-slate-500 font-black text-[10px] uppercase">
                Fechar
              </button>
            </div>

            <button
              onClick={ligarCameraFoto}
              className="w-full bg-gradient-to-r from-pink-600 to-blue-600 text-white py-5 rounded-[2rem] font-black uppercase text-xs tracking-widest shadow-xl shadow-pink-500/20 active:scale-95"
            >
              📷 Câmera
            </button>

            <label className="w-full mt-3 py-4 rounded-[2rem] border border-slate-800 text-slate-200 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors flex items-center justify-center cursor-pointer active:scale-95">
              🖼️ Galeria <input type="file" accept="image/*" onChange={handleGaleria} className="hidden" />
            </label>
          </div>
        </div>
      )}

      {/* MODAL CÂMERA (UNIFICADO) */}
      {cameraAtiva && (
        <div className="fixed inset-0 z-[130] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4">
          {cameraAtiva.tipo === 'foto' ? (
            <div className="bg-slate-900 w-full max-w-sm rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10">
              <div className="flex justify-between items-center mb-6">
                <h3 className="text-sm font-black italic text-pink-500 uppercase tracking-tighter">Câmera</h3>
                <button onClick={fecharCamera} className="text-slate-500 font-black text-[10px] uppercase">
                  Fechar
                </button>
              </div>

              <div className="aspect-[3/4] bg-black rounded-3xl overflow-hidden relative border-2 border-pink-500/30 shadow-2xl shadow-pink-500/10">
                {fotoTemp ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={fotoTemp.url} className="w-full h-full object-cover" alt="Preview" />
                ) : (
                  <video ref={videoRef} autoPlay playsInline className="w-full h-full object-cover" />
                )}
              </div>

              <div className="flex gap-3 mt-4">
                {fotoTemp ? (
                  <>
                    <button
                      onClick={confirmarFoto}
                      className="flex-1 bg-emerald-600 text-white py-4 rounded-2xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95"
                    >
                      Confirmar
                    </button>
                    <button
                      onClick={() => {
                        setFotoTemp(null);
                        if (videoRef.current && streamRef.current) (videoRef.current as any).srcObject = streamRef.current;
                      }}
                      className="flex-1 py-4 rounded-2xl border border-slate-800 text-slate-300 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
                    >
                      Repetir
                    </button>
                  </>
                ) : (
                  <button
                    onClick={capturarFoto}
                    className="flex-1 bg-gradient-to-r from-pink-600 to-blue-600 text-white py-4 rounded-2xl font-black uppercase text-xs tracking-widest shadow-lg active:scale-95"
                  >
                    Capturar
                  </button>
                )}
              </div>
            </div>
          ) : (
            <div className="bg-slate-900 w-full max-w-sm rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10">
              <div className="flex justify-between items-center mb-6">
                <h3 className="text-sm font-black italic text-pink-500 uppercase tracking-tighter">Leitor de Código</h3>
                <button onClick={fecharCamera} className="text-slate-500 font-black text-[10px] uppercase">
                  Fechar
                </button>
              </div>

              <div className="rounded-[2rem] overflow-hidden bg-black border-2 border-pink-500/30 shadow-2xl shadow-pink-500/10 relative">
                {/* ZXing fallback */}
                <video id="zxing-video-cadastro" className="h-64 w-full object-cover hidden" muted playsInline />
                {/* html5-qrcode */}
                <div id="reader-cadastro-direct" className="h-64 w-full" />
              </div>

              <div className="mt-3">
                <button
                  onClick={fecharCamera}
                  className="w-full py-4 rounded-[2rem] border border-slate-800 text-slate-300 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
                >
                  Cancelar
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}