'use client';

import { useState, useEffect, useMemo, useCallback, useRef, Suspense } from 'react';
import Link from 'next/link';
import { supabase } from '../../lib/supabase';
import { Html5Qrcode } from 'html5-qrcode';
import Cropper from 'react-easy-crop';
import { useSearchParams } from 'next/navigation';

import ReciboModal from '../components/ReciboModal';

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
  estoque: EstoqueItem[];
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

type DraftResumo = {
  id: string;
  titulo: string | null;
  updated_at: string;
  created_at: string;
};

type DraftItemDB = {
  produto_id: string;
  estoque_id: string;
  descricao: string;
  cor: string | null;
  tamanho: string | null;
  preco: number;
  custo: number;
  qtd: number;
  foto_url: string | null;
  ean: string | null;
};

// --- UTILITÁRIOS ---
const formatBRL = (val: number) => val.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

const playBeep = () => {
  const audio = new Audio('https://www.soundjay.com/buttons/beep-01a.mp3');
  audio.volume = 0.5;
  audio.play().catch(() => {});
  if (typeof window !== 'undefined' && window.navigator && (window.navigator as any).vibrate) {
    (window.navigator as any).vibrate(50);
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
  await new Promise((resolve) => {
    image.onload = resolve;
  });

  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('No 2d context');

  canvas.width = pixelCrop.width;
  canvas.height = pixelCrop.height;

  ctx.drawImage(
    image,
    pixelCrop.x,
    pixelCrop.y,
    pixelCrop.width,
    pixelCrop.height,
    0,
    0,
    pixelCrop.width,
    pixelCrop.height
  );

  return new Promise((resolve) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
    }, 'image/jpeg', 1);
  });
}

function getDashboardQS(searchParams: ReturnType<typeof useSearchParams>) {
  const qs = searchParams?.toString() ?? '';
  return qs ? `?${qs}` : '';
}

/**
 * IMPORTANTE (Next.js / Vercel):
 * useSearchParams() precisa estar dentro de um Suspense boundary.
 */
export default function VendaPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-slate-950" />}>
      <VendaPageInner />
    </Suspense>
  );
}

function VendaPageInner() {
  const searchParams = useSearchParams();
  const dashQS = useMemo(() => getDashboardQS(searchParams), [searchParams]);

  const [loading, setLoading] = useState(false);
  const [lendoArquivo, setLendoArquivo] = useState(false);
  const [produtos, setProdutos] = useState<Produto[]>([]);
  const [busca, setBusca] = useState('');

  // URLs assinadas (normal) e thumbnails (transformadas)
  const [signedMap, setSignedMap] = useState<Record<string, string>>({});
  const [thumbMap, setThumbMap] = useState<Record<string, string>>({});

  const [abaMobile, setAbaMobile] = useState<'busca' | 'carrinho'>('busca');
  const [carrinho, setCarrinho] = useState<ItemCarrinho[]>([]);

  // Drafts
  const [draftAtualId, setDraftAtualId] = useState<string | null>(null);
  const [draftAtualTitulo, setDraftAtualTitulo] = useState<string>('');
  const [drafts, setDrafts] = useState<DraftResumo[]>([]);
  const [mostrarDrafts, setMostrarDrafts] = useState(false);

  // Expand no modal de drafts (pré-visualizar itens)
  const [draftExpanded, setDraftExpanded] = useState<Record<string, boolean>>({});
  const [draftItemsCache, setDraftItemsCache] = useState<Record<string, DraftItemDB[]>>({});
  const [draftItemsLoading, setDraftItemsLoading] = useState<Record<string, boolean>>({});

  // Modais e Recibo
  const [modalSelecao, setModalSelecao] = useState<Produto | null>(null);
  const [mostrarScanner, setMostrarScanner] = useState(false);
  const [modalPagamento, setModalPagamento] = useState(false);
  const [itemPendente, setItemPendente] = useState<{ produto: Produto; est: EstoqueItem } | null>(null);

  // RECIBO
  const [mostrarRecibo, setMostrarRecibo] = useState(false);
  const [dadosRecibo, setDadosRecibo] = useState<any>(null);

  const [pagamento, setPagamento] = useState({
    metodo: 'pix',
    parcelas: 1,
    descontoTipo: 'reais' as 'reais' | 'porcentagem',
    descontoValor: 0,
    valorFinal: 0,
  });

  // Upload e Crop
  const [imgSrc, setImgSrc] = useState<string | null>(null);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState<AreaCrop | null>(null);

  const scannerRef = useRef<Html5Qrcode | null>(null);

  // ====== Cache local de thumbs (reduz muito o "tempo percebido" depois da 1ª vez)
  const LS_THUMB_KEY = 'upfitness_thumbMap_v1';
  const persistTimerRef = useRef<any>(null);

  useEffect(() => {
    try {
      const raw = localStorage.getItem(LS_THUMB_KEY);
      if (raw) setThumbMap(JSON.parse(raw));
    } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (persistTimerRef.current) clearTimeout(persistTimerRef.current);
    persistTimerRef.current = setTimeout(() => {
      try {
        localStorage.setItem(LS_THUMB_KEY, JSON.stringify(thumbMap));
      } catch {}
    }, 400);
  }, [thumbMap]);

  useEffect(() => {
    (async () => {
      await fetchProdutos();
      await fetchDrafts();
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const produtosDisponiveis = useMemo(() => {
    return produtos.filter((p) => {
      const total = p.estoque.reduce((acc, est) => acc + (Number(est.quantidade) || 0), 0);
      return total > 0;
    });
  }, [produtos]);

  const produtosVisiveis = useMemo(() => {
    const q = busca.toLowerCase().trim();
    if (!q) return produtosDisponiveis;

    return produtosDisponiveis.filter((p) => {
      const matchTexto =
        (p.descricao || '').toLowerCase().includes(q) ||
        (p.codigo_peca || '').toLowerCase().includes(q) ||
        (p.sku_fornecedor || '').toLowerCase().includes(q);

      const matchEan = p.estoque.some((e) => (e.codigo_barras || '').includes(q));
      return matchTexto || matchEan;
    });
  }, [busca, produtosDisponiveis]);

  // ===== Thumbs (Supabase Image Transformations) =====
  // Mais agressivo para carregar mais rápido.
  const THUMB_TRANSFORM_BUSCA = useMemo(
    () => ({
      width: 48,
      height: 48,
      resize: 'cover' as const,
      quality: 20,
      // NÃO forçamos format aqui. Supabase costuma otimizar automaticamente (WebP) quando usa transform.
    }),
    []
  );

  const THUMB_TRANSFORM_MODAL = useMemo(
    () => ({
      width: 180,
      height: 180,
      resize: 'cover' as const,
      quality: 45,
    }),
    []
  );

  // ===== Assinatura de fotos (normal + thumbs) =====
  // - Normal: carrinho / modais
  // - Thumbs: assinatura progressiva (primeiros N imediatos + resto em lotes no idle)
  const thumbJobVersionRef = useRef(0);

  useEffect(() => {
    const version = ++thumbJobVersionRef.current;
    let cancelled = false;

    const SIGN_THUMBS_IMMEDIATE = 40; // assina imediatamente (p/ evitar tela “sem foto”)
    const SIGN_THUMBS_CHUNK = 40; // lotes em idle

    const run = async () => {
      // NORMAL (qualidade original): carrinho + modais maiores (recibo/confirm)
      const normalToSign = new Set<string>();
      carrinho.forEach((item) => {
        if (item.foto && !signedMap[item.foto]) normalToSign.add(item.foto);
      });
      if (modalSelecao?.foto_url && !signedMap[modalSelecao.foto_url]) normalToSign.add(modalSelecao.foto_url);
      if (itemPendente?.produto.foto_url && !signedMap[itemPendente.produto.foto_url]) normalToSign.add(itemPendente.produto.foto_url);

      // THUMBS (lista): só do que está visível (mas assinando progressivamente)
      const allThumbCandidates: string[] = [];
      for (const p of produtosVisiveis) {
        if (!p.foto_url) continue;
        if (thumbMap[p.foto_url]) continue;
        allThumbCandidates.push(p.foto_url);
      }

      const firstBatch = allThumbCandidates.slice(0, SIGN_THUMBS_IMMEDIATE);
      const rest = allThumbCandidates.slice(SIGN_THUMBS_IMMEDIATE);

      // THUMB do modal de seleção (também leve, mas maior)
      const thumbsModalToSign = new Set<string>();
      if (modalSelecao?.foto_url && !thumbMap[modalSelecao.foto_url]) thumbsModalToSign.add(modalSelecao.foto_url);

      // Nada para fazer
      if (normalToSign.size === 0 && firstBatch.length === 0 && rest.length === 0 && thumbsModalToSign.size === 0) return;

      // Assina NORMAL
      if (normalToSign.size > 0 && !cancelled && version === thumbJobVersionRef.current) {
        const newSigned: Record<string, string> = {};
        for (const original of Array.from(normalToSign)) {
          const path = extractPath(original);
          if (!path) continue;
          const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 3600);
          if (data?.signedUrl) newSigned[original] = data.signedUrl;
        }
        if (!cancelled && version === thumbJobVersionRef.current && Object.keys(newSigned).length > 0) {
          setSignedMap((prev) => ({ ...prev, ...newSigned }));
        }
      }

      // Assina THUMBS imediatos (24h)
      if (firstBatch.length > 0 && !cancelled && version === thumbJobVersionRef.current) {
        const newThumbs: Record<string, string> = {};
        for (const original of firstBatch) {
          const path = extractPath(original);
          if (!path) continue;

          const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 86400, {
            transform: THUMB_TRANSFORM_BUSCA,
          });

          if (data?.signedUrl) newThumbs[original] = data.signedUrl;
        }
        if (!cancelled && version === thumbJobVersionRef.current && Object.keys(newThumbs).length > 0) {
          setThumbMap((prev) => ({ ...prev, ...newThumbs }));
        }
      }

      // Assina THUMB do modal (se necessário, sobrescreve)
      if (thumbsModalToSign.size > 0 && !cancelled && version === thumbJobVersionRef.current) {
        const newThumbs: Record<string, string> = {};
        for (const original of Array.from(thumbsModalToSign)) {
          const path = extractPath(original);
          if (!path) continue;

          const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 3600, {
            transform: THUMB_TRANSFORM_MODAL,
          });

          if (data?.signedUrl) newThumbs[original] = data.signedUrl;
        }
        if (!cancelled && version === thumbJobVersionRef.current && Object.keys(newThumbs).length > 0) {
          setThumbMap((prev) => ({ ...prev, ...newThumbs }));
        }
      }

      // Assina restante em lotes no idle
      const signChunk = async (chunk: string[]) => {
        const newThumbs: Record<string, string> = {};
        for (const original of chunk) {
          if (cancelled || version !== thumbJobVersionRef.current) return;
          if (thumbMap[original]) continue;

          const path = extractPath(original);
          if (!path) continue;

          const { data } = await supabase.storage.from('produtos').createSignedUrl(path, 86400, {
            transform: THUMB_TRANSFORM_BUSCA,
          });

          if (data?.signedUrl) newThumbs[original] = data.signedUrl;
        }
        if (!cancelled && version === thumbJobVersionRef.current && Object.keys(newThumbs).length > 0) {
          setThumbMap((prev) => ({ ...prev, ...newThumbs }));
        }
      };

      const schedule = (fn: () => void) => {
        const w = window as any;
        if (typeof w.requestIdleCallback === 'function') w.requestIdleCallback(fn, { timeout: 800 });
        else setTimeout(fn, 50);
      };

      // quebrar rest em lotes
      for (let i = 0; i < rest.length; i += SIGN_THUMBS_CHUNK) {
        const chunk = rest.slice(i, i + SIGN_THUMBS_CHUNK);
        schedule(() => {
          // dispara mas não bloqueia a UI
          signChunk(chunk).catch(() => {});
        });
      }
    };

    run().catch(() => {});

    return () => {
      cancelled = true;
    };
  }, [carrinho, modalSelecao, itemPendente, produtosVisiveis, signedMap, thumbMap, THUMB_TRANSFORM_BUSCA, THUMB_TRANSFORM_MODAL]);

  // Recalcula valor final conforme desconto
  useEffect(() => {
    const totalBrutoCalc = carrinho.reduce((acc, item) => acc + item.preco * item.qtd, 0);
    let final = totalBrutoCalc;

    if (pagamento.descontoTipo === 'reais') final = totalBrutoCalc - pagamento.descontoValor;
    else final = totalBrutoCalc - totalBrutoCalc * (pagamento.descontoValor / 100);

    setPagamento((prev) => ({ ...prev, valorFinal: Math.max(0, final) }));
  }, [carrinho, pagamento.descontoTipo, pagamento.descontoValor]);

  // --- SCANNER TURBO ---
  useEffect(() => {
    if (mostrarScanner) {
      const elementId = 'reader-venda-direct';
      const t = setTimeout(() => {
        if (!document.getElementById(elementId)) return;

        const html5QrCode = new Html5Qrcode(elementId);
        scannerRef.current = html5QrCode;

        html5QrCode
          .start(
            { facingMode: 'environment' },
            { fps: 30, qrbox: { width: 250, height: 100 }, aspectRatio: 1.0 },
            (decodedText) => {
              handleScanSucesso(decodedText);
              fecharScanner();
            },
            () => {}
          )
          .catch((err) => {
            console.error('Erro Câmera:', err);
            setMostrarScanner(false);
          });
      }, 300);

      return () => clearTimeout(t);
    }
  }, [mostrarScanner]);

  const fecharScanner = async () => {
    if (scannerRef.current) {
      try {
        if ((scannerRef.current as any).isScanning) await scannerRef.current.stop();
        scannerRef.current.clear();
      } catch (e) {
        console.log(e);
      }
    }
    setMostrarScanner(false);
  };

  async function fetchProdutos(): Promise<Produto[]> {
    const { data, error } = await supabase
      .from('produtos')
      .select(
        `
        id, codigo_peca, sku_fornecedor, descricao, cor, foto_url, preco_venda,
        preco_compra, custo_frete, custo_embalagem,
        estoque ( id, quantidade, codigo_barras, tamanho:tamanhos(nome, ordem) )
      `
      )
      .eq('descontinuado', false);

    if (error) {
      console.log('Erro ao buscar produtos:', error.message);
      return produtos;
    }

    const list = (data ?? []) as any as Produto[];
    setProdutos(list);
    return list;
  }

  async function fetchDrafts() {
    const { data, error } = await supabase
      .from('venda_drafts')
      .select('id, titulo, updated_at, created_at')
      .order('updated_at', { ascending: false })
      .limit(30);

    if (error) {
      console.log('Erro ao listar drafts:', error.message);
      return;
    }
    setDrafts((data ?? []) as any);
  }

  async function fetchDraftItemsPreview(draftId: string) {
    if (draftItemsCache[draftId]) return;

    setDraftItemsLoading((prev) => ({ ...prev, [draftId]: true }));
    try {
      const { data, error } = await supabase
        .from('venda_draft_itens')
        .select('produto_id, estoque_id, descricao, cor, tamanho, preco, custo, qtd, foto_url, ean')
        .eq('draft_id', draftId);

      if (error) throw new Error(error.message);

      setDraftItemsCache((prev) => ({ ...prev, [draftId]: (data ?? []) as DraftItemDB[] }));
    } catch (e: any) {
      alert(`Erro ao carregar itens do rascunho: ${e?.message ?? e}`);
    } finally {
      setDraftItemsLoading((prev) => ({ ...prev, [draftId]: false }));
    }
  }

  function buscarPorEAN(codigo: string) {
    const codigoLimpo = codigo.trim();
    if (!codigoLimpo) return false;

    for (const p of produtos) {
      const estoqueEncontrado = p.estoque.find((e) => e.codigo_barras === codigoLimpo);
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

  function prepararAdicao(produto: Produto, est: EstoqueItem) {
    playBeep();
    setItemPendente({ produto, est });
    setModalSelecao(null);
    setBusca('');
  }

  function confirmarAdicao() {
    if (!itemPendente) return;
    const { produto, est } = itemPendente;

    const jaNoCarrinho = carrinho.find((item) => item.estoque_id === est.id);
    const qtdNoCarrinho = jaNoCarrinho ? jaNoCarrinho.qtd : 0;

    if (qtdNoCarrinho + 1 > est.quantidade) {
      alert(`Estoque insuficiente! Restam apenas ${est.quantidade}.`);
      return;
    }

    if (jaNoCarrinho) {
      setCarrinho((prev) =>
        prev.map((item) => (item.estoque_id === est.id ? { ...item, qtd: item.qtd + 1 } : item))
      );
    } else {
      const custoTotalItem =
        (produto.preco_compra || 0) + (produto.custo_frete || 0) + (produto.custo_embalagem || 0);

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
        ean: est.codigo_barras,
      };

      setCarrinho((prev) => [...prev, novoItem]);
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

  const onCropComplete = useCallback((_: any, croppedAreaPixels_: AreaCrop) => {
    setCroppedAreaPixels(croppedAreaPixels_);
  }, []);

  const processarRecorte = async () => {
    if (!imgSrc || !croppedAreaPixels) return;
    setLendoArquivo(true);

    try {
      const croppedBlob = await getCroppedImg(imgSrc, croppedAreaPixels);
      const croppedFile = new File([croppedBlob], 'temp.jpg', { type: 'image/jpeg' });

      const html5QrCode = new Html5Qrcode('reader-hidden');
      const decodedText = await html5QrCode.scanFileV2(croppedFile, true);

      if (decodedText) handleScanSucesso(decodedText.decodedText);
      else alert('Código não identificado.');
    } catch {
      alert('Erro ao ler código.');
    } finally {
      setLendoArquivo(false);
    }
  };

  const handleKeyDownBusca = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && busca.length > 0) {
      if (buscarPorEAN(busca)) setBusca('');
    }
  };

  function removerItem(tempId: string) {
    setCarrinho((prev) => prev.filter((i) => i.tempId !== tempId));
  }

  function alterarQtd(tempId: string, delta: number) {
    setCarrinho((prev) =>
      prev.map((item) => {
        if (item.tempId === tempId) {
          const novaQtd = item.qtd + delta;
          if (novaQtd < 1) return item;
          if (delta > 0 && novaQtd > item.maxEstoque) return item;
          return { ...item, qtd: novaQtd };
        }
        return item;
      })
    );
  }

  const totalBruto = carrinho.reduce((acc, item) => acc + item.preco * item.qtd, 0);
  const qtdItensCarrinho = carrinho.reduce((acc, item) => acc + item.qtd, 0);

  const itensZerados = useMemo(() => carrinho.filter((i) => (i.maxEstoque ?? 0) <= 0), [carrinho]);
  const temZerados = itensZerados.length > 0;

  function bloquearFechamentoSeZerados() {
    if (!temZerados) return false;
    const lista = itensZerados
      .slice(0, 6)
      .map((i) => `• ${i.descricao} (${i.cor} • ${i.tamanho})`)
      .join('\n');
    alert(
      `Existem itens no carrinho com ESTOQUE ZERADO.\n\nRemova os itens zerados antes de fechar a venda.\n\nItens:\n${lista}${
        itensZerados.length > 6 ? `\n• ... (+${itensZerados.length - 6})` : ''
      }`
    );
    return true;
  }

  function abrirModalPagamento() {
    if (carrinho.length === 0) return alert('Carrinho vazio.');
    if (bloquearFechamentoSeZerados()) return;

    setPagamento({ metodo: 'pix', parcelas: 1, descontoTipo: 'reais', descontoValor: 0, valorFinal: totalBruto });
    setModalPagamento(true);
  }

  // -------- DRAFTS: salvar / carregar / excluir --------
  function tituloPadraoDraft() {
    const d = new Date();
    const dd = String(d.getDate()).padStart(2, '0');
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const hh = String(d.getHours()).padStart(2, '0');
    const mi = String(d.getMinutes()).padStart(2, '0');
    return `Carrinho ${dd}/${mm} ${hh}:${mi}`;
  }

  async function salvarDraft() {
    if (carrinho.length === 0) return alert('Carrinho vazio.');

    const isEditando = !!draftAtualId;
    let tituloFinal = draftAtualTitulo?.trim();

    if (!isEditando) {
      const titulo = window.prompt('Nome do carrinho salvo:', '') ?? '';
      tituloFinal = titulo.trim() || tituloPadraoDraft();
    } else {
      if (!tituloFinal) tituloFinal = tituloPadraoDraft();
    }

    setLoading(true);
    try {
      let draftId = draftAtualId;

      if (!draftId) {
        const { data: created, error: errCreate } = await supabase
          .from('venda_drafts')
          .insert([{ titulo: tituloFinal }])
          .select('id')
          .single();

        if (errCreate) throw new Error(errCreate.message);
        draftId = created?.id as string;
        setDraftAtualId(draftId);
        setDraftAtualTitulo(tituloFinal);
      } else {
        const { error: errUpd } = await supabase.from('venda_drafts').update({ titulo: tituloFinal }).eq('id', draftId);
        if (errUpd) throw new Error(errUpd.message);
        setDraftAtualTitulo(tituloFinal);
      }

      const { error: errDel } = await supabase.from('venda_draft_itens').delete().eq('draft_id', draftId);
      if (errDel) throw new Error(errDel.message);

      const itens = carrinho.map((i) => ({
        draft_id: draftId,
        produto_id: i.produto_id,
        estoque_id: i.estoque_id,
        descricao: i.descricao,
        cor: i.cor,
        tamanho: i.tamanho,
        preco: i.preco,
        custo: i.custo,
        qtd: i.qtd,
        foto_url: i.foto,
        ean: i.ean,
      }));

      const { error: errIns } = await supabase.from('venda_draft_itens').insert(itens);
      if (errIns) throw new Error(errIns.message);

      await fetchDrafts();
      alert(isEditando ? 'Carrinho atualizado.' : 'Carrinho salvo.');

      if (draftId) {
        setDraftItemsCache((prev) => {
          const cp = { ...prev };
          delete cp[draftId];
          return cp;
        });
      }
    } catch (e: any) {
      alert(`Erro ao salvar carrinho: ${e?.message ?? e}`);
    } finally {
      setLoading(false);
    }
  }

  async function carregarDraft(draftId: string, draftTitulo?: string | null) {
    setLoading(true);
    try {
      const { data, error } = await supabase
        .from('venda_draft_itens')
        .select('produto_id, estoque_id, descricao, cor, tamanho, preco, custo, qtd, foto_url, ean')
        .eq('draft_id', draftId);

      if (error) throw new Error(error.message);

      const items = (data ?? []) as DraftItemDB[];
      const produtosAtualizados = await fetchProdutos();

      const novoCarrinho: ItemCarrinho[] = items.map((it) => {
        const p = produtosAtualizados.find((pp) => pp.id === it.produto_id);
        const est = p?.estoque?.find((ee) => ee.id === it.estoque_id);
        const maxEstoque = est?.quantidade ?? 0;

        return {
          tempId: Math.random().toString(36),
          produto_id: it.produto_id,
          estoque_id: it.estoque_id,
          descricao: it.descricao,
          cor: it.cor ?? '',
          tamanho: it.tamanho ?? '',
          preco: Number(it.preco) || 0,
          custo: Number(it.custo) || 0,
          qtd: Math.max(1, Number(it.qtd) || 1),
          maxEstoque,
          foto: it.foto_url,
          ean: it.ean,
        };
      });

      setCarrinho(novoCarrinho);
      setDraftAtualId(draftId);
      setDraftAtualTitulo((draftTitulo ?? drafts.find((d) => d.id === draftId)?.titulo ?? 'Carrinho salvo').trim());

      setMostrarDrafts(false);
      setAbaMobile('carrinho');

      const zerados = novoCarrinho.filter((i) => (i.maxEstoque ?? 0) <= 0);
      if (zerados.length > 0) {
        const lista = zerados
          .slice(0, 6)
          .map((i) => `• ${i.descricao} (${i.cor} • ${i.tamanho})`)
          .join('\n');

        alert(
          `Carrinho carregado, mas existem itens com ESTOQUE ZERADO.\n\nEles foram mantidos no carrinho para você visualizar, porém você precisa removê-los antes de fechar a venda.\n\nItens:\n${lista}${
            zerados.length > 6 ? `\n• ... (+${zerados.length - 6})` : ''
          }`
        );
      }
    } catch (e: any) {
      alert(`Erro ao carregar carrinho: ${e?.message ?? e}`);
    } finally {
      setLoading(false);
    }
  }

  async function excluirDraft(draftId: string) {
    if (!confirm('Excluir este carrinho salvo?')) return;

    setLoading(true);
    try {
      const { error } = await supabase.from('venda_drafts').delete().eq('id', draftId);
      if (error) throw new Error(error.message);

      if (draftAtualId === draftId) {
        setDraftAtualId(null);
        setDraftAtualTitulo('');
      }
      await fetchDrafts();

      setDraftItemsCache((prev) => {
        const cp = { ...prev };
        delete cp[draftId];
        return cp;
      });
      setDraftExpanded((prev) => {
        const cp = { ...prev };
        delete cp[draftId];
        return cp;
      });
    } catch (e: any) {
      alert(`Erro ao excluir: ${e?.message ?? e}`);
    } finally {
      setLoading(false);
    }
  }

  function limparCarrinho() {
    if (carrinho.length === 0 && !draftAtualId) return;

    const msg =
      carrinho.length === 0 && draftAtualId
        ? 'Limpar o rascunho atual (desvincular do carrinho) ?'
        : 'Limpar carrinho atual?';

    if (!confirm(msg)) return;

    setCarrinho([]);
    setDraftAtualId(null);
    setDraftAtualTitulo('');
    setAbaMobile('busca');
  }

  // --- CONFIRMAR VENDA ---
  async function confirmarVenda() {
    if (bloquearFechamentoSeZerados()) return;

    setLoading(true);

    const itensPayload = carrinho.map((i) => ({
      produto_id: i.produto_id,
      estoque_id: i.estoque_id,
      descricao_completa: `${i.descricao} - ${i.cor} (${i.tamanho})`,
      quantidade: i.qtd,
      preco_unitario: i.preco,
      subtotal: i.preco * i.qtd,
    }));

    const { error } = await supabase.rpc('realizar_venda', {
      p_valor_bruto: totalBruto,
      p_valor_liquido: pagamento.valorFinal,
      p_desconto: totalBruto - pagamento.valorFinal,
      p_forma_pagamento: pagamento.metodo,
      p_parcelas: pagamento.metodo === 'credito' ? pagamento.parcelas : 1,
      p_itens: itensPayload,
    });

    setLoading(false);

    if (error) {
      alert('Erro: ' + error.message);
      return;
    }

    if (draftAtualId) {
      await supabase.from('venda_drafts').delete().eq('id', draftAtualId);
      setDraftAtualId(null);
      setDraftAtualTitulo('');
      await fetchDrafts();
    }

    const dadosParaRecibo = {
      itens: carrinho.map((i) => ({
        descricao: i.descricao,
        quantidade: i.qtd,
        preco_venda: i.preco,
        tamanho: i.tamanho,
      })),
      subtotal: totalBruto,
      desconto: totalBruto - pagamento.valorFinal,
      totalFinal: pagamento.valorFinal,
      metodoPagamento: pagamento.metodo,
      data: new Date(),
    };

    setDadosRecibo(dadosParaRecibo);
    setMostrarRecibo(true);
    setModalPagamento(false);
    setCarrinho([]);
    setAbaMobile('busca');
    await fetchProdutos();
  }

  const handleDescontoInput = (valor: string, tipo: 'reais' | 'porcentagem' | 'final') => {
    const num = parseFloat(valor) || 0;
    if (tipo === 'final') {
      const descontoEmReais = totalBruto - num;
      setPagamento((prev) => ({
        ...prev,
        descontoTipo: 'reais',
        descontoValor: parseFloat(descontoEmReais.toFixed(2)),
      }));
    } else {
      setPagamento((prev) => ({ ...prev, descontoTipo: tipo, descontoValor: num }));
    }
  };

  const handleSelecionarProduto = (p: Produto) => {
    setModalSelecao(p);
    setBusca('');
  };

  const isEditandoDraft = !!draftAtualId;

  const bgClass = isEditandoDraft
    ? 'bg-gradient-to-br from-orange-950 via-amber-950 to-slate-950'
    : 'bg-slate-950';

  return (
    <div className={`min-h-screen ${bgClass} text-slate-100 font-sans flex flex-col md:flex-row overflow-hidden relative`}>
      {/* FUNDO / MARCA D’ÁGUA PARA EDIÇÃO DE CARRINHO SALVO */}
      {isEditandoDraft && (
        <div className="pointer-events-none absolute inset-0 z-0">
          <div className="absolute inset-0 opacity-[0.10]"></div>
        </div>
      )}

      <div id="reader-hidden" className="hidden"></div>

      {/* ÁREA ESQUERDA: BUSCA */}
      <div
        className={`relative z-10 flex-1 p-4 md:p-6 flex flex-col gap-4 h-[calc(100vh-80px)] md:h-screen overflow-y-auto ${
          abaMobile === 'carrinho' ? 'hidden md:flex' : 'flex'
        }`}
      >
        <header className="flex items-center gap-4">
          <Link href={`/${dashQS}`} className="bg-slate-800 p-3 rounded-full hover:bg-slate-700 transition active:scale-95">
            ←
          </Link>
          <h1 className="font-black italic text-xl uppercase">
            UpFitness <span className="font-light text-pink-500">Checkout</span>
          </h1>

          {isEditandoDraft && (
            <span className="ml-auto bg-orange-600 text-white text-[10px] px-3 py-1 rounded-full font-black uppercase tracking-widest border border-orange-300/30 shadow">
              MODO EDIÇÃO
            </span>
          )}
        </header>

        {isEditandoDraft && (
          <div className="bg-orange-900/35 border border-orange-500/40 rounded-2xl p-4 shadow-[0_0_0_1px_rgba(0,0,0,0.2)]">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-[10px] font-black uppercase tracking-widest text-orange-200">
                  Você está editando um carrinho salvo
                </p>
                <p className="text-white font-black truncate">{draftAtualTitulo || 'Carrinho salvo'}</p>
                {temZerados && (
                  <p className="mt-2 text-[11px] font-bold text-red-200">
                    Atenção: existem itens com <span className="font-black">ESTOQUE ZERADO</span>. Remova-os para fechar a venda.
                  </p>
                )}
              </div>
              <button
                onClick={limparCarrinho}
                className="shrink-0 text-[10px] font-black uppercase text-red-200 hover:text-white bg-red-950/30 border border-red-900/30 px-3 py-2 rounded-xl active:scale-95"
              >
                Sair da edição
              </button>
            </div>
          </div>
        )}

        <div className="relative z-30 flex flex-col gap-3">
          <input
            autoFocus
            type="text"
            placeholder="🔎 Buscar, SKU ou EAN..."
            className="w-full p-4 rounded-2xl bg-slate-900 border-2 border-slate-800 focus:border-pink-500 outline-none text-base font-bold shadow-xl text-white h-16"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            onKeyDown={handleKeyDownBusca}
          />

          <div className="flex gap-3">
            <button
              onClick={() => setMostrarScanner(true)}
              className="flex-1 bg-slate-800 hover:bg-slate-700 text-white h-14 rounded-2xl flex items-center justify-center text-sm font-bold uppercase tracking-widest border-2 border-slate-800 hover:border-pink-500 transition-all shadow-xl active:scale-95 gap-2"
            >
              📷 <span className="hidden min-[350px]:inline">Câmera</span>
            </button>

            <label
              className={`flex-1 bg-slate-800 hover:bg-slate-700 text-white h-14 rounded-2xl flex items-center justify-center text-sm font-bold uppercase tracking-widest border-2 border-slate-800 hover:border-blue-500 transition-all shadow-xl cursor-pointer active:scale-95 gap-2 ${
                lendoArquivo ? 'animate-pulse bg-blue-900' : ''
              }`}
            >
              {lendoArquivo ? '⏳' : '📂'} <span className="hidden min-[350px]:inline">Foto</span>
              <input type="file" accept="image/*" className="hidden" onChange={handleFileUpload} />
            </label>
          </div>

          {/* LISTA SEMPRE VISÍVEL (filtra quando digita) */}
          <div className="bg-slate-900 border border-slate-800 rounded-2xl overflow-hidden shadow-xl">
            <div className="px-4 py-3 border-b border-slate-800 flex items-center justify-between">
              <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">
                Itens disponíveis
              </span>
              <span className="text-[10px] font-black uppercase tracking-widest text-slate-500">
                {produtosVisiveis.length} itens
              </span>
            </div>

            <div className="max-h-[55vh] overflow-y-auto">
              {produtosVisiveis.length === 0 ? (
                <div className="p-6 text-center text-slate-500 text-xs font-bold uppercase tracking-widest">
                  Nenhum item encontrado
                </div>
              ) : (
                produtosVisiveis.map((p, idx) => {
                  const thumbUrl = p.foto_url ? thumbMap[p.foto_url] : null;
                  const eager = idx < 6; // só o topo da lista com prioridade

                  return (
                    <button
                      key={p.id}
                      onClick={() => handleSelecionarProduto(p)}
                      className="w-full text-left p-4 hover:bg-slate-800 border-b border-slate-800/60 last:border-0 flex justify-between items-center transition-colors active:bg-slate-700 gap-4"
                    >
                      <div className="flex items-center gap-4 min-w-0">
                        <div className="w-12 h-12 rounded-xl bg-slate-950 border border-slate-800 overflow-hidden flex items-center justify-center flex-shrink-0">
                          {thumbUrl ? (
                            // eslint-disable-next-line @next/next/no-img-element
                            <img
                              src={thumbUrl}
                              className="w-full h-full object-cover"
                              alt=""
                              loading={eager ? 'eager' : 'lazy'}
                              decoding="async"
                            />
                          ) : (
                            <span className="text-lg opacity-60">📷</span>
                          )}
                        </div>

                        <div className="min-w-0">
                          <p className="font-bold text-white text-sm uppercase truncate">{p.descricao}</p>
                          <p className="text-[10px] font-mono text-slate-400 truncate">
                            {p.codigo_peca} | {p.cor}
                          </p>
                        </div>
                      </div>

                      <span className="font-black text-emerald-400 text-sm whitespace-nowrap">
                        {formatBRL(p.preco_venda)}
                      </span>
                    </button>
                  );
                })
              )}
            </div>
          </div>
        </div>

        {/* BARRA INFERIOR MOBILE */}
        <div
          className="md:hidden fixed bottom-0 left-0 right-0 bg-slate-900 border-t border-slate-800 p-4 pb-8 flex items-center justify-between shadow-[0_-10px_40px_rgba(0,0,0,0.5)] z-20"
          onClick={() => setAbaMobile('carrinho')}
        >
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
      <div
        className={`relative z-10 w-full md:w-[420px] md:border-l flex flex-col h-screen md:sticky md:top-0 shadow-2xl ${
          abaMobile === 'busca' ? 'hidden md:flex' : 'flex fixed inset-0'
        } ${isEditandoDraft ? 'border-orange-800/50' : 'border-slate-800'}`}
      >
        {isEditandoDraft ? (
          <>
            <div className="absolute inset-0 z-0 bg-gradient-to-br from-orange-950 via-amber-950 to-slate-950" />
            <div className="pointer-events-none absolute inset-0 z-0">
              <div className="absolute inset-0 opacity-[0.10]"></div>
            </div>
          </>
        ) : (
          <div className="absolute inset-0 z-0 bg-slate-900" />
        )}

        {/* CONTEÚDO DO CARRINHO */}
        <div className="relative z-10 flex flex-col h-full">
          <div className="p-6 bg-slate-950/95 backdrop-blur-md border-b border-slate-800 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <button onClick={() => setAbaMobile('busca')} className="md:hidden bg-slate-800 p-2 rounded-full text-slate-300">
                ←
              </button>
              <h2 className="font-black text-xl uppercase tracking-widest flex items-center gap-2">
                Carrinho <span className="bg-pink-600 text-white text-xs px-2 py-0.5 rounded-full">{qtdItensCarrinho}</span>
              </h2>

              {isEditandoDraft && (
                <span className="ml-2 bg-orange-600 text-white text-[10px] px-3 py-1 rounded-full font-black uppercase tracking-widest border border-orange-300/30 shadow">
                  MODO EDIÇÃO
                </span>
              )}
            </div>

            <div className="flex items-center gap-2">
              <button
                disabled={loading}
                onClick={() => {
                  setMostrarDrafts(true);
                  fetchDrafts();
                }}
                className="bg-slate-800 hover:bg-slate-700 text-white px-3 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest border border-slate-700 active:scale-95"
                title="Carrinhos salvos"
              >
                📂
              </button>
              <button
                disabled={loading || carrinho.length === 0}
                onClick={salvarDraft}
                className="bg-blue-600 hover:bg-blue-500 text-white px-3 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest border border-blue-400/30 active:scale-95 disabled:opacity-50"
                title={isEditandoDraft ? 'Atualizar carrinho salvo' : 'Salvar carrinho'}
              >
                💾
              </button>
            </div>
          </div>

          {/* Banner (mesmo estilo do checkout em modo edição) */}
          {isEditandoDraft && (
            <div className="px-4 pt-3">
              <div className="bg-orange-900/35 border border-orange-500/40 rounded-2xl p-4 shadow-[0_0_0_1px_rgba(0,0,0,0.2)]">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-[10px] font-black uppercase tracking-widest text-orange-200">
                      Você está editando um carrinho salvo
                    </p>
                    <p className="text-white font-black truncate">{draftAtualTitulo || 'Carrinho salvo'}</p>
                    {temZerados && (
                      <p className="mt-2 text-[11px] font-bold text-red-200">
                        Atenção: existem itens com <span className="font-black">ESTOQUE ZERADO</span>. Remova-os para fechar a venda.
                      </p>
                    )}
                  </div>

                  <button
                    onClick={limparCarrinho}
                    className="shrink-0 text-[10px] font-black uppercase text-red-200 hover:text-white bg-red-950/30 border border-red-900/30 px-3 py-2 rounded-xl active:scale-95"
                  >
                    Sair da edição
                  </button>
                </div>
              </div>
            </div>
          )}

          {temZerados && (
            <div className="px-4 pt-3">
              <div className="bg-red-950/25 border border-red-900/30 rounded-2xl p-3">
                <p className="text-[11px] font-bold text-red-200">
                  Existem <span className="font-black">{itensZerados.length}</span> item(ns) com <span className="font-black">ESTOQUE ZERADO</span>. Remova-os antes de fechar a venda.
                </p>
              </div>
            </div>
          )}

          <div className="flex-1 overflow-y-auto p-4 space-y-3 bg-slate-950/25">
            {carrinho.map((item) => {
              const zerado = (item.maxEstoque ?? 0) <= 0;
              const disablePlus = zerado || item.qtd >= item.maxEstoque;

              return (
                <div
                  key={item.tempId}
                  className={`bg-slate-900/90 p-3 rounded-2xl border flex gap-3 relative group transition-colors shadow-sm ${
                    zerado ? 'border-red-900/60 hover:border-red-700' : 'border-slate-800 hover:border-slate-600'
                  }`}
                >
                  <div className="w-16 h-16 rounded-xl bg-slate-800 overflow-hidden border border-slate-700 flex-shrink-0 relative">
                    {item.foto && signedMap[item.foto] ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={signedMap[item.foto]} className="w-full h-full object-cover" alt="" loading="lazy" decoding="async" />
                    ) : (
                      <div className="w-full h-full flex items-center justify-center text-xs">📷</div>
                    )}

                    {zerado && (
                      <div className="absolute bottom-0 left-0 right-0 bg-red-600/90 text-white text-[9px] font-black uppercase text-center py-0.5">
                        zerado
                      </div>
                    )}
                  </div>

                  <div className="flex-1 min-w-0 flex flex-col justify-center">
                    <p className="text-xs font-black text-white leading-tight mb-1 line-clamp-2">{item.descricao}</p>
                    <p className="text-[9px] font-bold text-slate-500 mb-1 uppercase">
                      {item.cor} • {item.tamanho}
                    </p>

                    <div className="flex items-center gap-2">
                      <p className="text-[10px] text-slate-400 font-mono">{formatBRL(item.preco)} un.</p>
                      {zerado ? (
                        <span className="text-[9px] font-black uppercase text-red-200 bg-red-950/30 border border-red-900/30 px-2 py-0.5 rounded-lg">
                          estoque 0
                        </span>
                      ) : (
                        <span className="text-[9px] font-bold uppercase text-slate-400 bg-slate-950/40 border border-slate-800 px-2 py-0.5 rounded-lg">
                          disp. {item.maxEstoque}
                        </span>
                      )}
                    </div>
                  </div>

                  <div className="flex flex-col items-end justify-between py-1">
                    <div className="flex items-center gap-1 bg-slate-950 rounded-lg p-1 border border-slate-800">
                      <button
                        onClick={() => alterarQtd(item.tempId, -1)}
                        className="w-8 h-8 flex items-center justify-center bg-slate-800 hover:bg-red-500/20 hover:text-red-500 rounded-lg text-lg font-bold transition text-slate-400 active:scale-90"
                      >
                        -
                      </button>
                      <span className="text-sm font-bold w-6 text-center text-white">{item.qtd}</span>
                      <button
                        onClick={() => alterarQtd(item.tempId, 1)}
                        disabled={disablePlus}
                        className={`w-8 h-8 flex items-center justify-center rounded-lg text-lg font-bold transition active:scale-90 ${
                          disablePlus
                            ? 'bg-slate-800/60 text-slate-600 cursor-not-allowed'
                            : 'bg-slate-800 hover:bg-green-500/20 hover:text-green-500 text-slate-400'
                        }`}
                        title={zerado ? 'Estoque zerado' : item.qtd >= item.maxEstoque ? 'Limite do estoque' : 'Aumentar'}
                      >
                        +
                      </button>
                    </div>
                    <span className="font-black text-sm text-emerald-400">{formatBRL(item.preco * item.qtd)}</span>
                  </div>

                  <button
                    onClick={() => removerItem(item.tempId)}
                    className="absolute -top-2 -right-2 bg-red-600 text-white w-7 h-7 rounded-full text-[10px] font-bold shadow-lg flex items-center justify-center z-10 active:scale-90"
                  >
                    ✕
                  </button>
                </div>
              );
            })}
            <div className="h-20"></div>
          </div>

          <div className="p-6 bg-slate-950/95 backdrop-blur-md border-t border-slate-800 space-y-4 shadow-[0_-10px_40px_rgba(0,0,0,0.5)]">
            <div className="flex justify-between items-end">
              <span className="text-slate-500 text-xs font-bold uppercase tracking-widest">Total a Pagar</span>
              <span className="text-4xl font-black text-white">{formatBRL(totalBruto)}</span>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <button
                disabled={loading || carrinho.length === 0}
                onClick={salvarDraft}
                className="w-full bg-slate-800 hover:bg-slate-700 text-white font-black py-5 rounded-xl shadow-lg uppercase tracking-widest text-[10px] transition-all disabled:opacity-50 disabled:cursor-not-allowed active:scale-95 h-16"
              >
                {isEditandoDraft ? 'ATUALIZAR' : 'SALVAR'}
              </button>

              <button
                disabled={loading || carrinho.length === 0}
                onClick={abrirModalPagamento}
                className={`w-full text-white font-black py-5 rounded-xl shadow-lg uppercase tracking-widest text-[10px] transition-all disabled:opacity-50 disabled:cursor-not-allowed active:scale-95 h-16 ${
                  temZerados ? 'bg-red-700 hover:bg-red-600' : 'bg-gradient-to-r from-emerald-600 to-emerald-500 hover:brightness-110'
                }`}
                title={temZerados ? 'Remova itens com estoque zerado para fechar' : 'Fechar venda'}
              >
                {loading ? 'PROCESSANDO...' : temZerados ? 'REMOVA ITENS ZERADOS' : 'FECHAR VENDA (F2)'}
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* MODAL: LISTA DE DRAFTS (COM EXPAND PARA VER ITENS) */}
      {mostrarDrafts && (
        <div className="fixed inset-0 z-[500] bg-black/95 backdrop-blur-md flex items-end md:items-center justify-center p-0 md:p-4">
          <div className="bg-slate-900 w-full max-w-2xl rounded-t-[2.5rem] md:rounded-[2.5rem] border-t md:border border-slate-700 shadow-2xl overflow-hidden flex flex-col max-h-[95vh]">
            <div className="bg-slate-950 p-6 border-b border-slate-800 flex justify-between items-center shrink-0">
              <h2 className="text-xl font-black uppercase text-white tracking-widest">Carrinhos salvos</h2>
              <button
                onClick={() => setMostrarDrafts(false)}
                className="w-10 h-10 rounded-full bg-slate-800 text-slate-400 hover:text-white font-bold transition active:scale-90"
              >
                ✕
              </button>
            </div>

            <div className="flex-1 overflow-y-auto p-6 space-y-3">
              {drafts.length === 0 ? (
                <div className="text-slate-500 text-sm font-bold uppercase tracking-widest text-center py-10">
                  Nenhum carrinho salvo
                </div>
              ) : (
                drafts.map((d) => {
                  const isOpen = !!draftExpanded[d.id];
                  const isLoadingItems = !!draftItemsLoading[d.id];
                  const items = draftItemsCache[d.id] ?? [];
                  const itensResumo = items.reduce((acc, it) => acc + (Number(it.qtd) || 0), 0);

                  return (
                    <div key={d.id} className="bg-slate-950 border border-slate-800 rounded-2xl overflow-hidden">
                      <div className="p-4 flex items-center justify-between gap-4">
                        <button
                          className="min-w-0 text-left flex-1"
                          onClick={async () => {
                            const next = !isOpen;
                            setDraftExpanded((prev) => ({ ...prev, [d.id]: next }));
                            if (next) await fetchDraftItemsPreview(d.id);
                          }}
                          title="Expandir para ver itens"
                        >
                          <p className="text-sm font-black text-white truncate">{d.titulo || 'Carrinho salvo'}</p>
                          <p className="text-[10px] font-mono text-slate-500">
                            {new Date(d.updated_at || d.created_at).toLocaleString('pt-BR')}
                          </p>

                          <div className="mt-2 flex items-center gap-2">
                            {draftAtualId === d.id && (
                              <span className="text-[10px] font-black uppercase text-emerald-400 bg-emerald-900/20 border border-emerald-900/30 px-2 py-1 rounded-lg">
                                Ativo
                              </span>
                            )}
                            <span className="text-[10px] font-black uppercase text-slate-300 bg-slate-900/40 border border-slate-800 px-2 py-1 rounded-lg">
                              {isOpen ? 'Ocultar itens' : 'Ver itens'}
                            </span>
                            {items.length > 0 && (
                              <span className="text-[10px] font-black uppercase text-slate-300 bg-slate-900/40 border border-slate-800 px-2 py-1 rounded-lg">
                                {itensResumo} itens
                              </span>
                            )}
                          </div>
                        </button>

                        <div className="flex items-center gap-2 shrink-0 pr-1">
                          <button
                            disabled={loading}
                            onClick={() => carregarDraft(d.id, d.titulo)}
                            className="bg-blue-600 hover:bg-blue-500 text-white px-4 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest active:scale-95"
                          >
                            Carregar
                          </button>
                          <button
                            disabled={loading}
                            onClick={() => excluirDraft(d.id)}
                            className="bg-red-600 hover:bg-red-500 text-white px-4 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest active:scale-95"
                          >
                            Excluir
                          </button>
                        </div>
                      </div>

                      {isOpen && (
                        <div className="border-t border-slate-800 bg-slate-950/60 p-4">
                          {isLoadingItems ? (
                            <div className="text-slate-400 text-xs font-bold uppercase tracking-widest py-3">
                              Carregando itens...
                            </div>
                          ) : items.length === 0 ? (
                            <div className="text-slate-500 text-xs font-bold uppercase tracking-widest py-3">
                              Nenhum item neste carrinho
                            </div>
                          ) : (
                            <div className="space-y-2">
                              {items.slice(0, 10).map((it, idx) => (
                                <div
                                  key={`${it.estoque_id}-${idx}`}
                                  className="flex items-center justify-between gap-3 bg-slate-900/40 border border-slate-800 rounded-xl px-3 py-2"
                                >
                                  <div className="min-w-0">
                                    <p className="text-[11px] font-black text-white truncate">{it.descricao}</p>
                                    <p className="text-[9px] font-bold text-slate-400 uppercase truncate">
                                      {(it.cor ?? '').trim()} • {(it.tamanho ?? '').trim()}
                                    </p>
                                  </div>
                                  <div className="shrink-0 text-right">
                                    <p className="text-[10px] font-black text-white">x{Number(it.qtd) || 0}</p>
                                    <p className="text-[10px] font-mono text-slate-400">{formatBRL(Number(it.preco) || 0)}</p>
                                  </div>
                                </div>
                              ))}

                              {items.length > 10 && (
                                <div className="text-slate-400 text-[10px] font-bold uppercase tracking-widest pt-2">
                                  +{items.length - 10} item(ns)...
                                </div>
                              )}
                            </div>
                          )}
                        </div>
                      )}
                    </div>
                  );
                })
              )}
            </div>

            <div className="p-6 bg-slate-950 border-t border-slate-800 shrink-0 flex gap-3">
              <button
                onClick={fetchDrafts}
                className="flex-1 bg-slate-800 text-white font-black py-4 rounded-2xl shadow-xl uppercase tracking-widest text-[10px] hover:bg-slate-700 active:scale-95"
              >
                Atualizar
              </button>
              <button
                onClick={() => setMostrarDrafts(false)}
                className="flex-1 bg-pink-600 text-white font-black py-4 rounded-2xl shadow-xl uppercase tracking-widest text-[10px] hover:bg-pink-500 active:scale-95"
              >
                Fechar
              </button>
            </div>
          </div>
        </div>
      )}

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
                <img src={signedMap[itemPendente.produto.foto_url]} className="w-full h-full object-cover" alt="" loading="lazy" decoding="async" />
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
              <button
                onClick={() => setItemPendente(null)}
                className="bg-slate-800 text-slate-400 font-bold py-3 rounded-xl text-[10px] uppercase active:scale-95 transition-transform hover:bg-slate-700 hover:text-white"
              >
                Cancelar
              </button>
              <button
                onClick={confirmarAdicao}
                className="bg-blue-600 text-white font-black py-3 rounded-xl text-[10px] uppercase shadow-lg shadow-blue-900/20 active:scale-95 transition-transform hover:bg-blue-500"
              >
                ADICIONAR
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL SELEÇÃO MANUAL (AGORA COM THUMBNAIL) */}
      {modalSelecao && (
        <div className="fixed inset-0 z-[50] bg-black/90 backdrop-blur-sm flex items-end md:items-center justify-center p-0 md:p-6 animate-in fade-in duration-200">
          <div className="bg-slate-900 w-full max-w-lg rounded-t-[2rem] md:rounded-[2rem] p-6 border-t md:border border-slate-800 shadow-2xl relative max-h-[90vh] overflow-hidden flex flex-col">
            <div className="flex justify-between items-start mb-6 shrink-0 gap-4">
              <div className="flex items-start gap-4 min-w-0">
                <div className="w-16 h-16 rounded-2xl bg-slate-950 border border-slate-800 overflow-hidden flex items-center justify-center shrink-0">
                  {modalSelecao.foto_url && thumbMap[modalSelecao.foto_url] ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={thumbMap[modalSelecao.foto_url]} className="w-full h-full object-cover" alt="" loading="eager" decoding="async" />
                  ) : (
                    <span className="text-2xl opacity-50">📷</span>
                  )}
                </div>

                <div className="min-w-0">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">Selecionando:</span>
                  <h2 className="text-xl font-black uppercase text-white leading-tight truncate">{modalSelecao.descricao}</h2>
                  <p className="text-xs text-slate-400 font-bold mt-1 uppercase truncate">{modalSelecao.cor}</p>
                </div>
              </div>

              <button
                onClick={() => setModalSelecao(null)}
                className="bg-slate-800 w-10 h-10 rounded-full text-slate-400 hover:text-white font-bold text-xl active:scale-90 shrink-0"
              >
                ✕
              </button>
            </div>

            <div className="space-y-4 overflow-y-auto pr-1 pb-10">
              <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800">
                <div className="flex flex-wrap gap-2 justify-center">
                  {ordenarEstoque(modalSelecao.estoque).map((est) => {
                    const semEstoque = est.quantidade <= 0;
                    return (
                      <button
                        key={est.id}
                        disabled={semEstoque}
                        onClick={() => prepararAdicao(modalSelecao, est)}
                        className={`flex flex-col items-center justify-center w-16 h-16 rounded-xl border text-xs font-black uppercase transition-all active:scale-95 ${
                          !semEstoque
                            ? 'bg-slate-800 border-slate-600 text-white hover:bg-pink-600 hover:border-pink-500 shadow-lg'
                            : 'bg-red-950/10 border-red-900/20 text-red-800/50 cursor-not-allowed'
                        }`}
                      >
                        <span className="text-sm">{est.tamanho.nome}</span>
                        <span className={`text-[9px] ${!semEstoque ? 'text-slate-400' : ''}`}>{est.quantidade}</span>
                      </button>
                    );
                  })}
                </div>
              </div>

              <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center justify-between">
                <span className="text-[10px] text-slate-500 font-bold uppercase tracking-widest">Preço</span>
                <span className="text-lg font-black text-emerald-400">{formatBRL(modalSelecao.preco_venda)}</span>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* MODAL PAGAMENTO */}
      {modalPagamento && (
        <div className="fixed inset-0 z-[200] bg-black/95 backdrop-blur-md flex items-end md:items-center justify-center p-0 md:p-4">
          <div className="bg-slate-900 w-full max-w-2xl rounded-t-[2.5rem] md:rounded-[2.5rem] border-t md:border border-slate-700 shadow-2xl overflow-hidden flex flex-col max-h-[95vh]">
            <div className="bg-slate-950 p-6 border-b border-slate-800 flex justify-between items-center shrink-0">
              <h2 className="text-xl font-black uppercase text-white tracking-widest">Pagamento</h2>
              <button onClick={() => setModalPagamento(false)} className="w-10 h-10 rounded-full bg-slate-800 text-slate-400 hover:text-white font-bold transition active:scale-90">
                ✕
              </button>
            </div>

            <div className="flex-1 overflow-y-auto p-6 space-y-8">
              <div className="space-y-4">
                <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Desconto / Ajuste</label>

                <div className="grid grid-cols-1 min-[400px]:grid-cols-2 gap-4">
                  <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3">
                    <span className="text-pink-500 font-bold">%</span>
                    <input
                      type="number"
                      inputMode="decimal"
                      placeholder="0"
                      className="bg-transparent w-full text-lg font-bold text-white outline-none"
                      value={pagamento.descontoTipo === 'porcentagem' ? pagamento.descontoValor : ''}
                      onChange={(e) => handleDescontoInput(e.target.value, 'porcentagem')}
                    />
                    <span className="text-xs text-slate-600 font-bold uppercase">Desc. %</span>
                  </div>

                  <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex items-center gap-3">
                    <span className="text-blue-500 font-bold">R$</span>
                    <input
                      type="number"
                      inputMode="decimal"
                      placeholder="0,00"
                      className="bg-transparent w-full text-lg font-bold text-white outline-none"
                      value={pagamento.descontoTipo === 'reais' ? pagamento.descontoValor : ''}
                      onChange={(e) => handleDescontoInput(e.target.value, 'reais')}
                    />
                    <span className="text-xs text-slate-600 font-bold uppercase">Desc. R$</span>
                  </div>
                </div>

                <div className="bg-slate-950 p-6 rounded-3xl border border-slate-800 text-center relative group">
                  <span className="text-xs text-slate-500 font-bold uppercase tracking-widest mb-1 block">Valor Final a Receber</span>
                  <div className="flex items-center justify-center gap-2">
                    <span className="text-2xl text-slate-600 font-bold">R$</span>
                    <input
                      type="number"
                      inputMode="decimal"
                      className="bg-transparent text-5xl font-black text-white outline-none text-center w-64"
                      value={pagamento.valorFinal}
                      onChange={(e) => handleDescontoInput(e.target.value, 'final')}
                    />
                  </div>
                </div>
              </div>

              <div className="space-y-4">
                <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Forma de Pagamento</label>
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                  {['pix', 'dinheiro', 'debito', 'credito'].map((m) => (
                    <button
                      key={m}
                      onClick={() => setPagamento((prev) => ({ ...prev, metodo: m }))}
                      className={`py-5 rounded-xl font-bold uppercase text-xs tracking-widest transition-all border-2 ${
                        pagamento.metodo === m
                          ? 'bg-emerald-600 border-emerald-500 text-white shadow-lg scale-105'
                          : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'
                      }`}
                    >
                      {m === 'credito' ? 'Crédito' : m === 'debito' ? 'Débito' : m}
                    </button>
                  ))}
                </div>
              </div>

              {pagamento.metodo === 'credito' && (
                <div className="space-y-4 animate-in fade-in slide-in-from-top-4">
                  <label className="text-xs font-bold text-slate-500 uppercase tracking-widest">Parcelamento</label>
                  <select
                    className="w-full bg-slate-950 border-2 border-slate-800 p-4 rounded-xl text-white font-bold outline-none focus:border-emerald-500 h-16 text-lg"
                    value={pagamento.parcelas}
                    onChange={(e) => setPagamento((prev) => ({ ...prev, parcelas: parseInt(e.target.value) }))}
                  >
                    {[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map((p) => (
                      <option key={p} value={p}>
                        {p}x de {formatBRL(pagamento.valorFinal / p)} {p === 1 ? '(À Vista)' : '(Sem Juros)'}
                      </option>
                    ))}
                  </select>
                </div>
              )}
            </div>

            <div className="p-6 bg-slate-950 border-t border-slate-800 shrink-0">
              <button
                onClick={confirmarVenda}
                disabled={loading}
                className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-5 rounded-2xl shadow-xl uppercase tracking-widest text-sm hover:brightness-110 transition-all disabled:opacity-50 h-16 active:scale-95"
              >
                {loading ? 'REGISTRANDO...' : 'CONFIRMAR PAGAMENTO'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL SCANNER TURBO */}
      {mostrarScanner && (
        <div className="fixed inset-0 z-[100] bg-black/95 flex flex-col items-center justify-center p-6 backdrop-blur-md">
          <div className="w-full max-w-sm bg-slate-900 p-6 rounded-3xl border border-slate-800 shadow-2xl relative">
            <h3 className="text-center font-black uppercase text-white mb-4 text-sm">Aponte para o Código</h3>
            <div id="reader-venda-direct" className="w-full rounded-2xl overflow-hidden border-2 border-pink-500 bg-black h-64"></div>
            <button onClick={fecharScanner} className="mt-6 w-full bg-slate-800 text-white py-4 rounded-xl font-bold uppercase tracking-widest">
              Fechar
            </button>
          </div>
        </div>
      )}

      {/* MODAL CROP */}
      {imgSrc && (
        <div className="fixed inset-0 z-[100] bg-black flex flex-col items-center justify-center">
          <div className="relative w-full h-full bg-black">
            <Cropper
              image={imgSrc}
              crop={crop}
              zoom={zoom}
              aspect={3 / 2}
              onCropChange={setCrop}
              onCropComplete={onCropComplete}
              onZoomChange={setZoom}
            />
          </div>

          <div className="absolute bottom-0 left-0 right-0 p-6 z-50 flex flex-col gap-4 bg-black/80 backdrop-blur-md pb-10">
            <p className="text-center text-xs text-slate-300">Ajuste o código de barras</p>
            <input
              type="range"
              value={zoom}
              min={1}
              max={3}
              step={0.1}
              onChange={(e) => setZoom(Number(e.target.value))}
              className="w-full accent-pink-500 h-10"
            />
            <div className="flex gap-2">
              <button onClick={() => setImgSrc(null)} className="flex-1 bg-slate-800 text-white py-4 rounded-2xl font-bold uppercase">
                Cancelar
              </button>
              <button onClick={processarRecorte} disabled={lendoArquivo} className="flex-1 bg-pink-600 text-white py-4 rounded-2xl font-black uppercase shadow-xl">
                {lendoArquivo ? 'Lendo...' : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL DE RECIBO */}
      <ReciboModal visivel={mostrarRecibo} dados={dadosRecibo} onClose={() => setMostrarRecibo(false)} />
    </div>
  );
}