// src/app/item/[id]/page.tsx
'use client';

import { use, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { supabase } from '../../../lib/supabase';
import { getSignedUrlCached } from '../../../lib/signedUrlCache';
import { gerarThumb, thumbPathFromOriginal, extractStoragePath } from '../../../lib/thumbUtils';

// --- UTILITÁRIOS ---
const formatBRL = (val: number | string) => {
  const n = typeof val === 'string' ? parseFloat(val) : val;
  if (isNaN(n)) return 'R$ 0,00';
  return n.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
};

function blobToFile(blob: Blob, filename: string) {
  return new File([blob], filename, { type: blob.type || 'image/jpeg' });
}

// ✅ Mesma extração robusta do dashboard
function extractPath(url: string | null) {
  if (!url) return null;
  if (!url.startsWith('http')) return url;

  try {
    const urlObj = new URL(url);
    const pathName = urlObj.pathname;

    const bucketName = 'produtos';
    const markerPublic = `/public/${bucketName}/`;
    const markerSign = `/${bucketName}/`;

    let extractedPath = '';

    if (pathName.includes(markerPublic)) {
      extractedPath = pathName.substring(pathName.indexOf(markerPublic) + markerPublic.length);
    } else if (pathName.includes(markerSign)) {
      extractedPath = pathName.substring(pathName.indexOf(markerSign) + markerSign.length);
    } else {
      const parts = pathName.split('/');
      const bucketIndex = parts.findIndex((p) => p === bucketName);
      if (bucketIndex !== -1 && parts.length > bucketIndex + 1) {
        extractedPath = parts.slice(bucketIndex + 1).join('/');
      }
    }

    return extractedPath ? decodeURIComponent(extractedPath) : null;
  } catch (error) {
    console.error('Erro ao extrair caminho da imagem:', url, error);
    return null;
  }
}

function guessFilenameFromPath(path: string | null | undefined, fallback = 'foto.jpg') {
  if (!path) return fallback;
  const clean = path.split('?')[0];
  const parts = clean.split('/');
  const last = parts[parts.length - 1] || fallback;
  return last.includes('.') ? last : fallback;
}

export default function DetalheItem({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);

  const router = useRouter();
  const searchParams = useSearchParams();
  const qs = searchParams.toString();
  const dashHref = qs ? `/?${qs}` : '/';

  // Refs (foto)
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);

  // Scanner (EAN)
  const scannerRef = useRef<any>(null);
  const zxingRef = useRef<{ reset: () => void } | null>(null);

  // --- ESTADOS ---
  const [loading, setLoading] = useState(true);
  const [editando, setEditando] = useState(false);

  const [produto, setProduto] = useState<any>(null);
  const [listaTamanhos, setListaTamanhos] = useState<any[]>([]);
  const [signedUrl, setSignedUrl] = useState<string | null>(null);

  // Download UI
  const [downloadingFoto, setDownloadingFoto] = useState(false);

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

  // ✅ snapshot para "Cancelar edição"
  const [formSnapshot, setFormSnapshot] = useState<typeof formData | null>(null);

  // MODAIS
  const [modalFoto, setModalFoto] = useState(false);
  const [fotoTemp, setFotoTemp] = useState<{ url: string; blob: Blob } | null>(null);

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
    aberto: false,
    tipo: 'entrada',
    itemEstoqueId: '',
    tamanhoNome: '',
    qtdAtual: 0,
    qtdOperacao: '',
    eanAtual: '',
    scanning: false,
  });

  useEffect(() => {
    if (id) carregarDados();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function carregarDados() {
    setLoading(true);

    const { data: tams } = await supabase.from('tamanhos').select('*').order('ordem');
    setListaTamanhos(tams || []);

    const { data, error } = await supabase
      .from('produtos')
      .select(`*, estoque(*, tamanho:tamanhos(*))`)
      .eq('id', id)
      .single();

    if (error || !data) {
      alert('Produto não encontrado');
      router.push(dashHref);
      return;
    }

    if (data.estoque) data.estoque.sort((a: any, b: any) => (a.tamanho?.ordem ?? 99) - (b.tamanho?.ordem ?? 99));
    setProduto(data);

    setSignedUrl(null);
    if (data.foto_url) {
      const signed = await getSignedUrlCached('produtos', data.foto_url, extractPath, 3600);
      if (signed) setSignedUrl(signed);
    }

    const custo = (data.preco_compra || 0) + (data.custo_frete || 0) + (data.custo_embalagem || 0);
    const margem = custo > 0 ? ((data.preco_venda - custo) / custo) * 100 : 100;

    const nextForm = {
      descricao: data.descricao,
      fornecedor: data.fornecedor,
      sku_fornecedor: data.sku_fornecedor || '',
      cor: data.cor || '',
      preco_compra: data.preco_compra || 0,
      custo_frete: data.custo_frete || 0,
      custo_embalagem: data.custo_embalagem || 0,
      preco_venda: data.preco_venda,
      margem_ganho: parseFloat(margem.toFixed(1)),
      descontinuado: data.descontinuado,
    };

    setFormData(nextForm);

    // se não estiver editando, mantém snapshot em sincronia com o dado real
    setFormSnapshot((prev) => (editando ? prev : nextForm));

    setLoading(false);
  }

  // --- DOWNLOAD FOTO ORIGINAL (via Storage, se possível) ---
  const baixarFotoOriginal = async () => {
    if (!produto?.foto_url) return;

    setDownloadingFoto(true);
    try {
      const maybePath = extractPath(produto.foto_url);

      if (maybePath && (maybePath.includes('/') || maybePath.includes('.'))) {
        const { data, error } = await supabase.storage.from('produtos').download(maybePath);
        if (error || !data) throw new Error('Falha ao baixar do storage');

        const blobUrl = URL.createObjectURL(data);
        const a = document.createElement('a');
        a.href = blobUrl;
        a.download = guessFilenameFromPath(maybePath, `${produto.codigo_peca || 'foto'}.jpg`);
        document.body.appendChild(a);
        a.click();
        a.remove();
        URL.revokeObjectURL(blobUrl);
        return;
      }

      if (signedUrl) {
        const res = await fetch(signedUrl);
        if (!res.ok) throw new Error('Falha ao baixar a partir da URL');
        const blob = await res.blob();

        const blobUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = blobUrl;
        a.download = `${produto.codigo_peca || 'foto'}.jpg`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        URL.revokeObjectURL(blobUrl);
        return;
      }

      alert('Não foi possível baixar a foto.');
    } catch (e) {
      alert('Erro ao baixar a foto.');
    } finally {
      setDownloadingFoto(false);
    }
  };

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
    const timestamp = Date.now();
    const filename = `${id}_${timestamp}.jpg`;
    const path = `migracao/${filename}`;
    const thumbPath = thumbPathFromOriginal(path); // "migracao/thumbs/id_123.jpg"

    // Upload da foto original
    await supabase.storage.from('produtos').upload(path, file);
    const { data } = supabase.storage.from('produtos').getPublicUrl(path);
    await supabase.from('produtos').update({ foto_url: data.publicUrl }).eq('id', id);

    // Gera e faz upload da thumb (não bloqueia se falhar)
    try {
      const thumbFile = await gerarThumb(file);
      await supabase.storage.from('produtos').upload(thumbPath, thumbFile, { upsert: true });
    } catch (thumbErr) {
      console.warn('Thumb não gerada (não crítico):', thumbErr);
    }

    setFotoTemp(null);
    await carregarDados();
  } catch (e) {
    alert('Erro no upload');
  }
  setLoading(false);
};

  const abrirCameraFoto = async () => {
    setFotoTemp(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
      });
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch (e) {
      alert('Erro câmera');
    }
  };

  // --- SALVAR EDIÇÃO ---
  const salvarEdicao = async () => {
    const { error } = await supabase
      .from('produtos')
      .update({
        descricao: formData.descricao,
        fornecedor: formData.fornecedor,
        sku_fornecedor: formData.sku_fornecedor,
        cor: formData.cor,
        preco_compra: formData.preco_compra,
        custo_frete: formData.custo_frete,
        custo_embalagem: formData.custo_embalagem,
        preco_venda: formData.preco_venda,
        descontinuado: formData.descontinuado,
      })
      .eq('id', id);

    if (error) return alert('Erro ao salvar');

    setEditando(false);
    setFormSnapshot(null);
    carregarDados();
  };

  const iniciarEdicao = () => {
    setFormSnapshot(formData); // snapshot do estado atual
    setEditando(true);
  };

  const cancelarEdicao = () => {
    if (formSnapshot) setFormData(formSnapshot);
    setEditando(false);
    setFormSnapshot(null);
  };

  // --- LÓGICA FINANCEIRA ---
  const handleMoneyInput = (val: string, field: string) => {
    const num = parseFloat(val.replace(/\D/g, '')) / 100;
    const newData = { ...formData, [field]: num || 0 };

    const custoTotal = newData.preco_compra + newData.custo_frete + newData.custo_embalagem;
    const margem = custoTotal > 0 ? ((newData.preco_venda - custoTotal) / custoTotal) * 100 : 100;

    setFormData({ ...newData, margem_ganho: parseFloat(margem.toFixed(1)) });
  };

  const handleMarginInput = (val: string) => {
    const margem = parseFloat(val);
    if (isNaN(margem)) return setFormData({ ...formData, margem_ganho: 0 });

    const custoTotal = formData.preco_compra + formData.custo_frete + formData.custo_embalagem;
    const novoPrecoVenda = custoTotal * (1 + margem / 100);

    setFormData({
      ...formData,
      margem_ganho: margem,
      preco_venda: novoPrecoVenda,
    });
  };

  // --- ESTOQUE ---
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

    setModalEstoque((p) => ({ ...p, aberto: false, scanning: false }));
    carregarDados();
  };

  const addTamanho = async () => {
    if (!novoTamanhoId) return;
    await supabase.from('estoque').insert({ produto_id: id, tamanho_id: novoTamanhoId, quantidade: 0 });
    setModalAddTamanho(false);
    carregarDados();
  };

  // ✅ Leitor EAN (mesma lógica/config do dashboard)
  useEffect(() => {
    if (!modalEstoque.aberto || !modalEstoque.scanning) return;

    const elementId = 'reader-ean-edit-direct';
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

      el.innerHTML = '';
      el.classList.remove('hidden');

      const zxingVideo = document.getElementById('zxing-video-ean-edit') as HTMLVideoElement | null;
      if (zxingVideo) zxingVideo.classList.add('hidden');

      await stopAndClear(scannerRef.current);
      if (zxingRef.current) {
        try {
          zxingRef.current.reset();
        } catch {}
        zxingRef.current = null;
      }

      const hasBarcodeDetector = typeof (window as any).BarcodeDetector !== 'undefined';

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
            if (text) {
              const cleaned = String(text).trim();
              setModalEstoque((p) => ({ ...p, eanAtual: cleaned, scanning: false }));
              try {
                zxingRef.current?.reset();
              } catch {}
            }
          });

          return;
        } catch (err) {
          console.error('Falha ao iniciar ZXing fallback:', err);
        }
      }

      let Html5Qrcode: any;
      let Formats: any;

      try {
        const mod = await import('html5-qrcode');
        if (cancelled) return;
        Html5Qrcode = mod.Html5Qrcode;
        Formats = mod.Html5QrcodeSupportedFormats;
      } catch (err) {
        console.error('Falha ao carregar html5-qrcode:', err);
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

      const onDecode = async (decodedText: string) => {
        if (cancelled) return;
        const cleaned = String(decodedText || '').trim();
        if (!cleaned) return;
        setModalEstoque((p) => ({ ...p, eanAtual: cleaned, scanning: false }));
        await stopAndClear(scanner);
      };

      try {
        const cameras = await Html5Qrcode.getCameras();
        const preferred = cameras.find((c: any) => /back|rear|traseira|environment/i.test(c.label)) ?? cameras[0];

        await scanner.start({ deviceId: { exact: preferred.id } }, config, onDecode, () => {});
      } catch (err) {
        console.error('Falha ao iniciar html5-qrcode:', err);
        try {
          await scanner.start({ facingMode: 'environment' }, config, onDecode, () => {});
        } catch (err2) {
          console.error('Fallback html5-qrcode falhou:', err2);
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
  }, [modalEstoque.aberto, modalEstoque.scanning]);

  // --- Cleanup camera/scanner on unmount ---
  useEffect(() => {
    return () => {
      try {
        const s = scannerRef.current;
        if (s) {
          try {
            const maybePromise = s.stop?.();
            if (maybePromise && typeof (maybePromise as any).then === 'function') {
              (maybePromise as Promise<void>).catch(() => {});
            }
          } catch {}
          try {
            s.clear?.();
          } catch {}
        }
      } catch {}

      if (zxingRef.current) {
        try {
          zxingRef.current.reset();
        } catch {}
        zxingRef.current = null;
      }

      try {
        streamRef.current?.getTracks().forEach((t) => t.stop());
      } catch {}
    };
  }, []);

  if (loading)
    return (
      <div className="min-h-screen bg-slate-950 flex items-center justify-center text-slate-800 font-black animate-pulse uppercase text-xs tracking-widest">
        Sincronizando...
      </div>
    );

  return (
    <div className={`min-h-screen bg-slate-950 text-slate-100 font-sans pb-32 ${formData.descontinuado ? 'grayscale-[0.8]' : ''}`}>
      {/* HEADER (voltar à esquerda, como nas outras páginas) */}
      <header className="px-6 pt-10 pb-6 bg-slate-950 border-b border-slate-900 backdrop-blur-md sticky top-0 z-[60]">
        <div className="flex items-end justify-between gap-4">
          <div className="flex items-end gap-3">
            <Link
              href={dashHref}
              className="w-12 h-12 bg-slate-900 border border-slate-800 text-white rounded-2xl flex items-center justify-center text-xl shadow-lg active:scale-90 transition-transform"
              aria-label="Voltar"
              title="Voltar"
            >
              ←
            </Link>

            <div>
              <p className="text-[10px] font-black tracking-[0.3em] text-pink-500 uppercase mb-1">UpFitness App</p>
              <h1 className="text-2xl font-black italic tracking-tighter uppercase">
                ITEM <span className="font-light not-italic text-slate-500 text-lg">DETALHE</span>
              </h1>
            </div>
          </div>

          <div className="flex gap-2">
            {!editando ? (
              <button
                onClick={iniciarEdicao}
                className="h-12 px-5 bg-gradient-to-tr from-pink-600 to-blue-600 text-white rounded-2xl flex items-center justify-center text-[10px] font-black uppercase tracking-widest shadow-lg shadow-pink-500/20 active:scale-90 transition-transform"
                aria-label="Editar"
              >
                Editar
              </button>
            ) : (
              <>
                <button
                  onClick={cancelarEdicao}
                  className="h-12 px-5 bg-slate-900 border border-slate-800 text-slate-200 rounded-2xl flex items-center justify-center text-[10px] font-black uppercase tracking-widest shadow-lg active:scale-90 transition-transform"
                  aria-label="Cancelar edição"
                >
                  Cancelar
                </button>
                <button
                  onClick={salvarEdicao}
                  className="h-12 px-6 bg-emerald-600 text-white rounded-2xl flex items-center justify-center text-[10px] font-black uppercase tracking-widest shadow-lg active:scale-90 transition-transform"
                  aria-label="Salvar"
                >
                  Salvar
                </button>
              </>
            )}
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-4 pt-6 space-y-6">
        {/* STATUS CODE */}
        <div className="flex justify-between items-center bg-slate-900 p-4 rounded-2xl border border-slate-800">
          <div>
            <h1 className="font-black italic text-lg text-white">{produto.codigo_peca}</h1>
            <span className="text-[9px] font-bold text-slate-500 uppercase tracking-widest">Código Interno</span>
          </div>
          {editando && (
            <button
              onClick={() => setFormData({ ...formData, descontinuado: !formData.descontinuado })}
              className={`px-4 py-2 rounded-xl text-[9px] font-black uppercase tracking-widest ${
                formData.descontinuado ? 'bg-red-900/30 text-red-500' : 'bg-emerald-900/30 text-emerald-400'
              }`}
            >
              {formData.descontinuado ? '🚫 Descontinuado' : '✅ Ativo'}
            </button>
          )}
        </div>

        {/* IDENTIFICAÇÃO E FOTO */}
        <section className="bg-slate-900 p-6 rounded-[2rem] border border-slate-800 shadow-xl flex flex-col md:flex-row gap-6">
          <div className="shrink-0 flex justify-center">
            <div className="relative">
              <button
                onClick={() => editando && setModalFoto(true)}
                className={`w-32 h-32 rounded-3xl bg-slate-950 border-2 border-slate-700 overflow-hidden relative group shadow-lg ${
                  editando ? 'cursor-pointer hover:border-pink-500' : 'cursor-default'
                }`}
              >
                {signedUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={signedUrl} className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity" alt="" />
                ) : (
                  <span className="text-4xl opacity-30">📷</span>
                )}

                {editando && (
                  <div className="absolute bottom-0 inset-x-0 bg-black/70 py-1 flex items-center justify-center gap-1 backdrop-blur-sm animate-in fade-in">
                    <span className="text-[10px] text-white font-bold uppercase tracking-wide">📷 Alterar</span>
                  </div>
                )}
              </button>

              {!!produto?.foto_url && (
                <button
                  type="button"
                  onClick={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    baixarFotoOriginal();
                  }}
                  title={downloadingFoto ? 'Baixando...' : 'Baixar foto original'}
                  aria-label="Baixar foto original"
                  className={`absolute -right-2 -top-2 z-10 w-9 h-9 rounded-full border border-slate-700 bg-slate-950/90 backdrop-blur flex items-center justify-center shadow-lg transition
                    ${downloadingFoto ? 'opacity-70 cursor-wait' : 'hover:border-blue-500 hover:scale-105 active:scale-95'}`}
                  disabled={downloadingFoto}
                >
                  <span className="text-sm">{downloadingFoto ? '⏳' : '⬇️'}</span>
                </button>
              )}
            </div>
          </div>

          <div className="flex-1 space-y-4">
            {editando ? (
              <>
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">SKU Fornecedor</label>
                    <input
                      value={formData.sku_fornecedor}
                      onChange={(e) => setFormData({ ...formData, sku_fornecedor: e.target.value })}
                      className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                      placeholder="REF-999"
                    />
                  </div>
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Cor (Texto)</label>
                    <input
                      value={formData.cor}
                      onChange={(e) => setFormData({ ...formData, cor: e.target.value })}
                      className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                    />
                  </div>
                </div>

                <div className="space-y-1">
                  <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Descrição</label>
                  <input
                    value={formData.descricao}
                    onChange={(e) => setFormData({ ...formData, descricao: e.target.value })}
                    className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                  />
                </div>

                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-slate-950/50 p-3 rounded-xl border border-slate-800/50">
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1 truncate">Compra</label>
                    <input
                      type="tel"
                      value={formatBRL(formData.preco_compra)}
                      onChange={(e) => handleMoneyInput(e.target.value, 'preco_compra')}
                      className="w-full bg-slate-900 p-2 rounded-lg border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                    />
                  </div>
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1 truncate">Frete</label>
                    <input
                      type="tel"
                      value={formatBRL(formData.custo_frete)}
                      onChange={(e) => handleMoneyInput(e.target.value, 'custo_frete')}
                      className="w-full bg-slate-900 p-2 rounded-lg border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                    />
                  </div>
                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1 truncate">Emb.</label>
                    <input
                      type="tel"
                      value={formatBRL(formData.custo_embalagem)}
                      onChange={(e) => handleMoneyInput(e.target.value, 'custo_embalagem')}
                      className="w-full bg-slate-900 p-2 rounded-lg border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                    />
                  </div>

                  <div className="space-y-1">
                    <label className="text-[9px] font-black text-emerald-400 uppercase ml-1 truncate">Margem %</label>
                    <div className="relative">
                      <input
                        type="number"
                        value={formData.margem_ganho}
                        onChange={(e) => handleMarginInput(e.target.value)}
                        className="w-full bg-slate-900 p-2 pr-5 rounded-lg border border-slate-700 text-emerald-300 font-bold text-base focus:border-emerald-500 outline-none"
                      />
                      <span className="absolute right-1 top-2.5 text-xs text-emerald-500 font-bold">%</span>
                    </div>
                  </div>
                </div>

                <div className="flex items-center gap-4 pt-2">
                  <div className="flex-1 space-y-1">
                    <label className="text-[9px] font-black text-blue-400 uppercase ml-1">Preço Venda</label>
                    <input
                      type="tel"
                      inputMode="decimal"
                      value={formatBRL(formData.preco_venda)}
                      onChange={(e) => handleMoneyInput(e.target.value, 'preco_venda')}
                      className="w-full bg-slate-950 p-3 rounded-xl border border-blue-900/50 text-blue-400 font-black text-xl focus:border-blue-500 outline-none"
                    />
                  </div>
                  <div className="flex-1 space-y-1">
                    <label className="text-[9px] font-black text-slate-500 uppercase ml-1">Fornecedor</label>
                    <input
                      value={formData.fornecedor}
                      onChange={(e) => setFormData({ ...formData, fornecedor: e.target.value })}
                      className="w-full bg-slate-950 p-3 rounded-xl border border-slate-700 text-white font-bold text-base focus:border-pink-500 outline-none"
                    />
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
            <button
              onClick={() => setModalAddTamanho(true)}
              className="text-[10px] bg-slate-800 text-white px-3 py-2 rounded-lg font-bold uppercase hover:bg-slate-700 active:scale-95 transition"
            >
              + Tamanho
            </button>
          </div>

          <div className="grid grid-cols-2 min-[400px]:grid-cols-3 sm:grid-cols-4 gap-3">
            {produto.estoque.map((est: any) => (
              <div key={est.id} className="bg-slate-900 p-3 rounded-2xl border border-slate-800 shadow-sm flex flex-col gap-3 relative group">
                <div className="flex justify-between items-center">
                  <span className="text-sm font-black text-slate-300">{est.tamanho.nome}</span>
                  <span className={`text-lg font-black ${est.quantidade > 0 ? 'text-white' : 'text-red-500'}`}>{est.quantidade}</span>
                </div>

                <button
                  onClick={() =>
                    setModalEstoque({
                      aberto: true,
                      tipo: 'edicao',
                      itemEstoqueId: est.id,
                      tamanhoNome: est.tamanho.nome,
                      qtdAtual: 0,
                      qtdOperacao: '',
                      eanAtual: est.codigo_barras || '',
                      scanning: false,
                    })
                  }
                  className="bg-slate-950 py-2 rounded-lg text-[9px] font-mono text-slate-500 truncate border border-slate-800 hover:border-blue-500/50 transition-colors"
                >
                  {est.codigo_barras || 'SEM EAN'}
                </button>

                <div className="flex gap-2">
                  <button
                    onClick={() =>
                      setModalEstoque({
                        aberto: true,
                        tipo: 'saida',
                        itemEstoqueId: est.id,
                        tamanhoNome: est.tamanho.nome,
                        qtdAtual: est.quantidade,
                        qtdOperacao: '',
                        eanAtual: '',
                        scanning: false,
                      })
                    }
                    className="flex-1 bg-red-900/20 text-red-500 rounded-lg font-bold hover:bg-red-600 hover:text-white transition h-8 flex items-center justify-center active:scale-90"
                  >
                    -
                  </button>
                  <button
                    onClick={() =>
                      setModalEstoque({
                        aberto: true,
                        tipo: 'entrada',
                        itemEstoqueId: est.id,
                        tamanhoNome: est.tamanho.nome,
                        qtdAtual: est.quantidade,
                        qtdOperacao: '',
                        eanAtual: '',
                        scanning: false,
                      })
                    }
                    className="flex-1 bg-green-900/20 text-green-500 rounded-lg font-bold hover:bg-green-600 hover:text-white transition h-8 flex items-center justify-center active:scale-90"
                  >
                    +
                  </button>
                </div>
              </div>
            ))}
          </div>
        </section>
      </main>

      {/* MODAL ADICIONAR TAMANHO */}
      {modalAddTamanho && (
        <div className="fixed inset-0 z-[110] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4">
          <div className="bg-slate-900 w-full max-w-xs rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10">
            <div className="flex justify-between items-center mb-6">
              <h3 className="text-sm font-black italic text-pink-500 uppercase tracking-tighter">Novo Tamanho</h3>
              <button onClick={() => setModalAddTamanho(false)} className="text-slate-500 font-black text-[10px] uppercase">
                Fechar
              </button>
            </div>

            <select
              className="w-full bg-slate-950 border border-slate-800 rounded-2xl py-4 px-4 text-white font-bold outline-none text-base mb-4"
              onChange={(e) => setNovoTamanhoId(e.target.value)}
              value={novoTamanhoId}
            >
              <option value="">Selecione...</option>
              {listaTamanhos
                .filter((t) => !produto.estoque.find((e: any) => e.tamanho_id === t.id))
                .map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.nome}
                  </option>
                ))}
            </select>

            <div className="flex flex-col gap-3">
              <button
                onClick={addTamanho}
                className="w-full bg-gradient-to-r from-pink-600 to-blue-600 text-white py-5 rounded-[2rem] font-black uppercase text-xs tracking-widest shadow-xl shadow-pink-500/20 active:scale-95"
              >
                Adicionar
              </button>
              <button
                onClick={() => setModalAddTamanho(false)}
                className="w-full py-4 rounded-[2rem] border border-slate-800 text-slate-500 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
              >
                Cancelar
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL FOTO */}
      {modalFoto && (
        <div className="fixed inset-0 z-[120] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4">
          {fotoTemp ? (
            <div className="bg-slate-900 w-full max-w-sm rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={fotoTemp.url} className="rounded-2xl border-2 border-pink-500 shadow-2xl" alt="" />
              <div className="flex flex-col gap-3 mt-4">
                <button
                  onClick={() => uploadFoto(blobToFile(fotoTemp.blob, 'cam.jpg'))}
                  className="w-full bg-emerald-600 text-white py-5 rounded-[2rem] font-black uppercase text-xs tracking-widest shadow-xl active:scale-95"
                >
                  Confirmar
                </button>
                <button
                  onClick={() => setFotoTemp(null)}
                  className="w-full py-4 rounded-[2rem] border border-slate-800 text-slate-400 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
                >
                  Tentar de Novo
                </button>
              </div>
            </div>
          ) : (
            <div className="bg-slate-900 w-full max-w-sm rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10">
              <div className="aspect-[3/4] bg-black rounded-3xl overflow-hidden relative border-2 border-slate-800 shadow-2xl">
                <video ref={videoRef} autoPlay playsInline className="w-full h-full object-cover" />
              </div>

              <div className="flex gap-3 mt-4">
                <button
                  onClick={abrirCameraFoto}
                  className="flex-1 bg-gradient-to-r from-pink-600 to-blue-600 text-white py-4 rounded-2xl font-black uppercase text-xs shadow-lg active:scale-95"
                  onMouseDown={() => {
                    const canvas = document.createElement('canvas');
                    if (videoRef.current) {
                      canvas.width = videoRef.current.videoWidth;
                      canvas.height = videoRef.current.videoHeight;
                      canvas.getContext('2d')?.drawImage(videoRef.current, 0, 0);
                      canvas.toBlob((b) => b && setFotoTemp({ url: URL.createObjectURL(b), blob: b }), 'image/jpeg');
                    }
                  }}
                >
                  Capturar
                </button>
                <label className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-black uppercase text-xs flex items-center justify-center cursor-pointer shadow-lg active:scale-95">
                  Galeria <input type="file" className="hidden" accept="image/*" onChange={handleFileChange} />
                </label>
              </div>

              <button
                onClick={() => {
                  setModalFoto(false);
                  try {
                    streamRef.current?.getTracks().forEach((t) => t.stop());
                  } catch {}
                }}
                className="w-full py-4 mt-3 rounded-[2rem] border border-slate-800 text-slate-400 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
              >
                Cancelar
              </button>
            </div>
          )}
        </div>
      )}

      {/* MODAL ESTOQUE & EAN (com leitor igual ao dashboard) */}
      {modalEstoque.aberto && (
        <div className="fixed inset-0 z-[130] bg-slate-950/95 backdrop-blur-xl flex items-end justify-center p-4">
          <div className="bg-slate-900 w-full max-w-xs rounded-[3rem] border border-slate-800 p-6 shadow-2xl animate-in slide-in-from-bottom-10 space-y-4">
            <div className="flex justify-between items-center">
              <h3 className="font-black italic text-pink-500 uppercase tracking-tighter">
                {modalEstoque.tipo === 'edicao' ? 'EAN' : modalEstoque.tipo === 'entrada' ? 'Entrada' : 'Saída'}
              </h3>
              <button onClick={() => setModalEstoque((p) => ({ ...p, aberto: false, scanning: false }))} className="text-slate-500 font-black text-[10px] uppercase">
                Fechar
              </button>
            </div>

            <p className="text-xs font-bold text-slate-500">{modalEstoque.tamanhoNome}</p>

            {modalEstoque.tipo === 'edicao' ? (
              <>
                <input
                  value={modalEstoque.eanAtual}
                  onChange={(e) => setModalEstoque((p) => ({ ...p, eanAtual: e.target.value }))}
                  className="w-full bg-slate-950 p-4 rounded-2xl text-white font-mono text-center border border-slate-800 outline-none focus:border-blue-500 text-base"
                  placeholder="Sem EAN"
                />

                <button
                  onClick={() => setModalEstoque((p) => ({ ...p, scanning: true }))}
                  className="w-full bg-gradient-to-r from-pink-600 to-blue-600 text-white py-4 rounded-2xl font-black uppercase text-xs tracking-widest shadow-xl shadow-pink-500/20 active:scale-95"
                >
                  📷 Ler Cód. Barras
                </button>

                {modalEstoque.scanning && (
                  <div className="rounded-[2rem] overflow-hidden bg-black border-2 border-pink-500/30 shadow-2xl shadow-pink-500/10 relative mt-2">
                    <video id="zxing-video-ean-edit" className="h-56 w-full object-cover hidden" muted playsInline />
                    <div id="reader-ean-edit-direct" className="h-56 w-full" />
                  </div>
                )}
              </>
            ) : (
              <input
                type="number"
                autoFocus
                className="w-full bg-slate-950 p-4 rounded-2xl text-white text-3xl font-black text-center border border-slate-800 outline-none focus:border-pink-500"
                placeholder="Qtd"
                onChange={(e) => setModalEstoque((p) => ({ ...p, qtdOperacao: e.target.value }))}
              />
            )}

            <div className="flex gap-3 pt-2">
              <button
                onClick={() => setModalEstoque((p) => ({ ...p, aberto: false, scanning: false }))}
                className="flex-1 py-4 rounded-[2rem] border border-slate-800 text-slate-400 font-black text-[10px] uppercase tracking-widest hover:bg-slate-800/30 transition-colors active:scale-95"
              >
                Cancelar
              </button>
              <button
                onClick={confirmarEstoque}
                className="flex-1 bg-emerald-600 text-white py-4 rounded-[2rem] font-black uppercase text-xs tracking-widest shadow-xl active:scale-95"
              >
                Confirmar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}