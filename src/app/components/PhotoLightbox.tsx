'use client';

/**
 * PhotoLightbox — visualização em tela cheia da(s) foto(s) do produto,
 * com pinch-to-zoom, pan quando ampliada, swipe-para-fechar, carrossel
 * de múltiplas fotos e faixa inferior com legenda pronta pra WhatsApp,
 * botão de compartilhar (Web Share API com arquivo) e cópia da legenda.
 *
 * Usado na home (page.tsx) e na tela do item ([id]/page.tsx). O
 * componente é auto-contido: recebe apenas os paths/URLs das fotos e
 * assina cada uma internamente via getSignedUrlCached (que tem cache
 * global, então fotos já assinadas em outros lugares são reusadas).
 *
 * O download tenta baixar direto do Supabase Storage (evita CORS e
 * traz o arquivo original); se não, faz fetch da URL assinada.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { getSignedUrlCached } from '../../lib/signedUrlCache';

type EstoqueItem = {
  quantidade: number;
  tamanho?: { nome?: string | null } | null;
};

export type PhotoLightboxProduto = {
  descricao: string;
  cor?: string | null;
  preco_venda?: number | null;
  estoque?: EstoqueItem[] | null;
};

type Props = {
  aberto: boolean;
  onClose: () => void;
  /** URLs completas ou paths do bucket 'produtos'. A primeira é
   *  tratada como "principal" para nome de arquivo. */
  fotos: string[];
  produto: PhotoLightboxProduto | null;
  /** Índice da foto a começar (default 0). Útil quando o usuário
   *  tocou numa miniatura específica na tela do item. */
  fotoInicial?: number;
};

const ZOOM_MIN = 1;
const ZOOM_MAX = 4;
const DOUBLE_TAP_ZOOM = 2.5;
const DOUBLE_TAP_MS = 300;
const SWIPE_TO_CLOSE_PX = 110;
const SWIPE_TO_NAV_PX = 60;

function formatBRL(v: number | null | undefined) {
  const n = typeof v === 'number' ? v : Number(v ?? 0);
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(
    Number.isFinite(n) ? n : 0,
  );
}

function slugify(s: string) {
  return s
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase()
    .slice(0, 60) || 'foto';
}

function montarLegenda(p: PhotoLightboxProduto): string {
  const linhas: string[] = [`*${p.descricao}*`];
  if (p.cor) linhas.push(`Cor: ${p.cor}`);
  const disponiveis = (p.estoque || [])
    .filter((e) => (Number(e.quantidade) || 0) > 0)
    .map((e) => e.tamanho?.nome)
    .filter((n): n is string => !!n);
  if (disponiveis.length > 0) linhas.push(`Tamanhos disponíveis: ${disponiveis.join(', ')}`);
  if (typeof p.preco_venda === 'number' && p.preco_venda > 0) linhas.push(formatBRL(p.preco_venda));
  return linhas.join('\n');
}

/** Extrai o path dentro do bucket 'produtos' a partir de URL completa
 *  ou path direto. Duplicado dos consumidores para o componente ser
 *  auto-contido. */
function extractPath(url: string | null): string | null {
  if (!url) return null;
  if (!url.startsWith('http')) return url;
  try {
    const urlObj = new URL(url);
    const pathName = urlObj.pathname;
    const bucketName = 'produtos';
    const markerPublic = `/public/${bucketName}/`;
    const markerSign = `/${bucketName}/`;
    let extracted = '';
    if (pathName.includes(markerPublic)) {
      extracted = pathName.substring(pathName.indexOf(markerPublic) + markerPublic.length);
    } else if (pathName.includes(markerSign)) {
      extracted = pathName.substring(pathName.indexOf(markerSign) + markerSign.length);
    } else {
      const parts = pathName.split('/');
      const bucketIndex = parts.findIndex((p) => p === bucketName);
      if (bucketIndex !== -1 && parts.length > bucketIndex + 1) {
        extracted = parts.slice(bucketIndex + 1).join('/');
      }
    }
    return extracted ? decodeURIComponent(extracted) : null;
  } catch {
    return null;
  }
}

function dist(a: { x: number; y: number }, b: { x: number; y: number }): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

export default function PhotoLightbox({ aberto, onClose, fotos, produto, fotoInicial = 0 }: Props) {
  const [scale, setScale] = useState(1);
  const [tx, setTx] = useState(0);
  const [ty, setTy] = useState(0);

  const [closingDy, setClosingDy] = useState(0);
  const [navDx, setNavDx] = useState(0);

  const [indice, setIndice] = useState(0);
  const [urlsAssinadas, setUrlsAssinadas] = useState<Record<string, string>>({});

  const [toast, setToast] = useState<string | null>(null);
  const toastTimeoutRef = useRef<number | null>(null);

  const [ocupado, setOcupado] = useState<false | 'baixando' | 'compartilhando'>(false);

  const pointersRef = useRef<Map<number, { x: number; y: number }>>(new Map());
  const gestoRef = useRef<{
    tipo: 'pinch' | 'pan-zoom' | 'pan-fechar' | 'pan-nav' | 'indefinido' | null;
    scaleInicial: number;
    txInicial: number;
    tyInicial: number;
    distInicial: number;
    startX: number;
    startY: number;
  }>({ tipo: null, scaleInicial: 1, txInicial: 0, tyInicial: 0, distInicial: 0, startX: 0, startY: 0 });

  const containerRef = useRef<HTMLDivElement | null>(null);
  const lastTapRef = useRef<{ t: number; x: number; y: number }>({ t: 0, x: 0, y: 0 });

  const legenda = useMemo(() => (produto ? montarLegenda(produto) : ''), [produto]);
  const totalFotos = fotos.length;
  const fotoAtualBruta = fotos[indice] ?? null;
  const fotoAtualUrl = fotoAtualBruta ? urlsAssinadas[fotoAtualBruta] ?? null : null;
  const fotoAtualPath = useMemo(() => extractPath(fotoAtualBruta), [fotoAtualBruta]);

  const nomeArquivo = useMemo(() => {
    const base = produto ? slugify(produto.descricao) : 'foto';
    const sufixo = totalFotos > 1 ? `-${indice + 1}` : '';
    return `${base}${sufixo}.jpg`;
  }, [produto, indice, totalFotos]);

  useEffect(() => {
    if (aberto) {
      setScale(1);
      setTx(0);
      setTy(0);
      setClosingDy(0);
      setNavDx(0);
      setIndice(Math.max(0, Math.min(fotoInicial, totalFotos - 1)));
      setOcupado(false);
    }
  }, [aberto, fotoInicial, totalFotos]);

  // Assina a foto atual e as vizinhas (pré-fetch pra navegação fluida)
  useEffect(() => {
    if (!aberto) return;
    const paraAssinar = new Set<string>();
    for (const off of [-1, 0, 1]) {
      const i = indice + off;
      if (i >= 0 && i < totalFotos) paraAssinar.add(fotos[i]);
    }
    let cancelado = false;
    (async () => {
      const novas: Record<string, string> = {};
      for (const bruta of paraAssinar) {
        if (urlsAssinadas[bruta]) continue;
        try {
          const url = await getSignedUrlCached('produtos', bruta, extractPath, 3600);
          if (url) novas[bruta] = url;
        } catch {}
      }
      if (!cancelado && Object.keys(novas).length > 0) {
        setUrlsAssinadas((prev) => ({ ...prev, ...novas }));
      }
    })();
    return () => {
      cancelado = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [aberto, indice, totalFotos, fotos]);

  const mostrarToast = useCallback((msg: string) => {
    setToast(msg);
    if (toastTimeoutRef.current) window.clearTimeout(toastTimeoutRef.current);
    toastTimeoutRef.current = window.setTimeout(() => setToast(null), 2400);
  }, []);

  const irPara = useCallback(
    (novo: number) => {
      if (novo < 0 || novo >= totalFotos) return;
      setIndice(novo);
      setScale(1);
      setTx(0);
      setTy(0);
      setNavDx(0);
    },
    [totalFotos],
  );

  useEffect(() => {
    if (!aberto) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      else if (e.key === 'ArrowLeft') irPara(indice - 1);
      else if (e.key === 'ArrowRight') irPara(indice + 1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [aberto, indice, onClose, irPara]);

  const clampPan = useCallback((novoTx: number, novoTy: number, s: number) => {
    const el = containerRef.current;
    if (!el) return { tx: novoTx, ty: novoTy };
    if (s <= 1) return { tx: 0, ty: 0 };
    const rect = el.getBoundingClientRect();
    const maxX = ((s - 1) * rect.width) / 2;
    const maxY = ((s - 1) * rect.height) / 2;
    return {
      tx: Math.max(-maxX, Math.min(maxX, novoTx)),
      ty: Math.max(-maxY, Math.min(maxY, novoTy)),
    };
  }, []);

  const handlePointerDown = (e: React.PointerEvent) => {
    if (!aberto) return;
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (pointersRef.current.size === 2) {
      const pts = Array.from(pointersRef.current.values()) as Array<{ x: number; y: number }>;
      gestoRef.current = {
        tipo: 'pinch',
        scaleInicial: scale,
        txInicial: tx,
        tyInicial: ty,
        distInicial: dist(pts[0], pts[1]),
        startX: 0,
        startY: 0,
      };
    } else if (pointersRef.current.size === 1) {
      gestoRef.current = {
        tipo: scale > 1 ? 'pan-zoom' : 'indefinido',
        scaleInicial: scale,
        txInicial: tx,
        tyInicial: ty,
        distInicial: 0,
        startX: e.clientX,
        startY: e.clientY,
      };
    }
  };

  const handlePointerMove = (e: React.PointerEvent) => {
    if (!aberto) return;
    if (!pointersRef.current.has(e.pointerId)) return;
    pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const g = gestoRef.current;

    if (g.tipo === 'pinch' && pointersRef.current.size >= 2) {
      const pts = Array.from(pointersRef.current.values()) as Array<{ x: number; y: number }>;
      const d = dist(pts[0], pts[1]);
      if (g.distInicial > 0) {
        const bruto = g.scaleInicial * (d / g.distInicial);
        const novo = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, bruto));
        setScale(novo);
        if (novo <= 1.001) {
          setTx(0);
          setTy(0);
        }
      }
      return;
    }

    if (pointersRef.current.size !== 1) return;
    const dx = e.clientX - g.startX;
    const dy = e.clientY - g.startY;

    if (g.tipo === 'indefinido') {
      if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
      if (Math.abs(dx) > Math.abs(dy) && totalFotos > 1) g.tipo = 'pan-nav';
      else if (dy > 0) g.tipo = 'pan-fechar';
      else return;
    }

    if (g.tipo === 'pan-zoom') {
      const { tx: novoTx, ty: novoTy } = clampPan(g.txInicial + dx, g.tyInicial + dy, scale);
      setTx(novoTx);
      setTy(novoTy);
    } else if (g.tipo === 'pan-fechar') {
      if (dy > 0) setClosingDy(dy);
    } else if (g.tipo === 'pan-nav') {
      setNavDx(dx);
    }
  };

  const handlePointerUp = (e: React.PointerEvent) => {
    if (!aberto) return;
    const foiUltimoPointer = pointersRef.current.size === 1;
    pointersRef.current.delete(e.pointerId);
    const g = gestoRef.current;

    if (g.tipo === 'pinch') {
      if (scale <= 1.001) {
        setScale(1);
        setTx(0);
        setTy(0);
      } else {
        const { tx: t1, ty: t2 } = clampPan(tx, ty, scale);
        setTx(t1);
        setTy(t2);
      }
    }

    if (foiUltimoPointer && (g.tipo === 'pan-fechar' || g.tipo === 'pan-nav' || g.tipo === 'indefinido')) {
      if (g.tipo === 'pan-fechar') {
        if (closingDy > SWIPE_TO_CLOSE_PX) {
          onClose();
          return;
        }
        setClosingDy(0);
      }

      if (g.tipo === 'pan-nav') {
        if (navDx <= -SWIPE_TO_NAV_PX && indice < totalFotos - 1) {
          irPara(indice + 1);
        } else if (navDx >= SWIPE_TO_NAV_PX && indice > 0) {
          irPara(indice - 1);
        }
        setNavDx(0);
      }

      if (g.tipo === 'indefinido') {
        const dx = e.clientX - g.startX;
        const dy = e.clientY - g.startY;
        const foiTap = Math.hypot(dx, dy) < 8;
        if (foiTap) {
          const agora = Date.now();
          const dt = agora - lastTapRef.current.t;
          const dd = Math.hypot(e.clientX - lastTapRef.current.x, e.clientY - lastTapRef.current.y);
          if (dt < DOUBLE_TAP_MS && dd < 40) {
            if (scale > 1) {
              setScale(1);
              setTx(0);
              setTy(0);
            } else {
              setScale(DOUBLE_TAP_ZOOM);
            }
            lastTapRef.current = { t: 0, x: 0, y: 0 };
          } else {
            lastTapRef.current = { t: agora, x: e.clientX, y: e.clientY };
          }
        }
      }
    }

    if (pointersRef.current.size === 0) {
      gestoRef.current.tipo = null;
    }
  };

  const handleWheel = (e: React.WheelEvent) => {
    if (!aberto) return;
    e.preventDefault();
    const delta = -e.deltaY * 0.002;
    const novo = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, scale + delta));
    setScale(novo);
    if (novo <= 1) {
      setTx(0);
      setTy(0);
    }
  };

  const pegarBlob = async (): Promise<Blob> => {
    if (fotoAtualPath) {
      const { data, error } = await supabase.storage.from('produtos').download(fotoAtualPath);
      if (!error && data) return data;
    }
    if (!fotoAtualUrl) throw new Error('Sem URL de foto');
    const resp = await fetch(fotoAtualUrl);
    if (!resp.ok) throw new Error('Falha ao baixar foto');
    return await resp.blob();
  };

  const baixar = async () => {
    if (ocupado) return;
    setOcupado('baixando');
    try {
      const blob = await pegarBlob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = nomeArquivo;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      mostrarToast('Foto baixada.');
    } catch {
      mostrarToast('Não consegui baixar a foto.');
    } finally {
      setOcupado(false);
    }
  };

  const compartilhar = async () => {
    if (ocupado || !produto) return;
    setOcupado('compartilhando');
    try {
      const blob = await pegarBlob();
      const file = new File([blob], nomeArquivo, { type: blob.type || 'image/jpeg' });
      const podeCompartilharArquivo =
        typeof navigator !== 'undefined' &&
        typeof navigator.canShare === 'function' &&
        navigator.canShare({ files: [file] });

      if (podeCompartilharArquivo && typeof navigator.share === 'function') {
        try {
          await navigator.share({ files: [file], text: legenda, title: produto.descricao });
          return;
        } catch (err: unknown) {
          if (err instanceof Error && err.name === 'AbortError') return;
          throw err;
        }
      }

      try {
        await navigator.clipboard.writeText(legenda);
      } catch {}
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = nomeArquivo;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      mostrarToast('Legenda copiada. Foto baixada — anexe no WhatsApp.');
    } catch {
      mostrarToast('Não consegui compartilhar. Tenta baixar a foto.');
    } finally {
      setOcupado(false);
    }
  };

  const copiarLegenda = async () => {
    try {
      await navigator.clipboard.writeText(legenda);
      mostrarToast('Legenda copiada!');
    } catch {
      mostrarToast('Não consegui copiar. Selecione e copie manualmente.');
    }
  };

  if (!aberto || totalFotos === 0 || !produto) return null;

  const closingProgress = Math.min(closingDy / (SWIPE_TO_CLOSE_PX * 2), 1);
  const backdropOpacity = 1 - closingProgress * 0.6;
  const semGesto = pointersRef.current.size === 0 && closingDy === 0 && navDx === 0;
  const podeVoltar = indice > 0;
  const podePassar = indice < totalFotos - 1;

  return (
    <div
      className="fixed inset-0 z-[200] flex flex-col select-none"
      style={{ background: `rgba(0,0,0,${backdropOpacity})` }}
      onWheel={handleWheel}
    >
      <div
        ref={containerRef}
        className="relative flex-1 overflow-hidden touch-none"
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        <button
          onClick={onClose}
          aria-label="Fechar"
          className="absolute top-4 right-4 z-10 w-11 h-11 rounded-full bg-slate-900/80 backdrop-blur border border-slate-700 text-white flex items-center justify-center hover:bg-slate-800 active:scale-95 shadow-lg"
          style={{ top: `calc(env(safe-area-inset-top, 0px) + 12px)` }}
        >
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor" className="w-5 h-5">
            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>

        {totalFotos > 1 && (
          <div
            className="absolute top-4 left-4 z-10 px-3 py-1.5 rounded-full bg-slate-900/80 backdrop-blur border border-slate-800 text-white text-[11px] font-black uppercase tracking-widest pointer-events-none"
            style={{ top: `calc(env(safe-area-inset-top, 0px) + 12px)` }}
          >
            {indice + 1} / {totalFotos}
          </div>
        )}
        {totalFotos === 1 && scale === 1 && closingDy === 0 && (
          <div
            className="absolute top-4 left-4 z-10 px-3 py-1.5 rounded-full bg-slate-900/70 backdrop-blur border border-slate-800 text-slate-400 text-[10px] font-bold uppercase tracking-widest pointer-events-none"
            style={{ top: `calc(env(safe-area-inset-top, 0px) + 12px)` }}
          >
            Pinça para zoom
          </div>
        )}

        {totalFotos > 1 && (
          <>
            <button
              onClick={() => irPara(indice - 1)}
              disabled={!podeVoltar}
              aria-label="Foto anterior"
              className="hidden md:flex absolute left-4 top-1/2 -translate-y-1/2 z-10 w-12 h-12 rounded-full bg-slate-900/80 backdrop-blur border border-slate-700 text-white items-center justify-center hover:bg-slate-800 active:scale-95 disabled:opacity-30 disabled:cursor-not-allowed shadow-lg"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
              </svg>
            </button>
            <button
              onClick={() => irPara(indice + 1)}
              disabled={!podePassar}
              aria-label="Próxima foto"
              className="hidden md:flex absolute right-4 top-1/2 -translate-y-1/2 z-10 w-12 h-12 rounded-full bg-slate-900/80 backdrop-blur border border-slate-700 text-white items-center justify-center hover:bg-slate-800 active:scale-95 disabled:opacity-30 disabled:cursor-not-allowed shadow-lg"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor" className="w-6 h-6">
                <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
              </svg>
            </button>
          </>
        )}

        {fotoAtualUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={fotoAtualUrl}
            alt={produto.descricao}
            draggable={false}
            className="absolute inset-0 w-full h-full object-contain will-change-transform"
            style={{
              transform: `translate3d(${tx + navDx}px, ${ty + closingDy}px, 0) scale(${scale})`,
              transition: semGesto ? 'transform 180ms ease-out' : 'none',
              touchAction: 'none',
            }}
          />
        ) : (
          <div className="absolute inset-0 flex items-center justify-center text-slate-600 font-bold text-xs uppercase tracking-widest">
            Carregando...
          </div>
        )}
      </div>

      <div
        className="relative bg-slate-950/95 backdrop-blur border-t border-slate-800 text-slate-100"
        style={{ paddingBottom: `calc(env(safe-area-inset-bottom, 0px) + 16px)` }}
      >
        <div className="max-w-2xl mx-auto p-4 flex flex-col gap-3">
          {totalFotos > 1 && (
            <div className="flex items-center justify-center gap-1.5">
              {fotos.map((_, i) => (
                <button
                  key={i}
                  onClick={() => irPara(i)}
                  aria-label={`Foto ${i + 1}`}
                  className={`h-1.5 rounded-full transition-all ${
                    i === indice ? 'w-6 bg-white' : 'w-1.5 bg-slate-600 hover:bg-slate-500'
                  }`}
                />
              ))}
            </div>
          )}

          <div className="min-w-0">
            <h2 className="font-black text-white uppercase text-sm leading-tight truncate">{produto.descricao}</h2>
            <p className="text-[11px] text-slate-400 font-bold uppercase mt-0.5 truncate">
              {produto.cor ? `${produto.cor} • ` : ''}
              {(() => {
                const disp = (produto.estoque || [])
                  .filter((e) => (Number(e.quantidade) || 0) > 0)
                  .map((e) => e.tamanho?.nome)
                  .filter((n): n is string => !!n);
                return disp.length > 0 ? disp.join(', ') : 'Sem estoque';
              })()}
            </p>
            {typeof produto.preco_venda === 'number' && produto.preco_venda > 0 && (
              <p className="text-white font-black text-base mt-1">{formatBRL(produto.preco_venda)}</p>
            )}
          </div>

          <div className="grid grid-cols-3 gap-2">
            <button
              onClick={compartilhar}
              disabled={!!ocupado}
              className="flex flex-col items-center justify-center gap-1 py-3 rounded-2xl bg-emerald-600 hover:bg-emerald-500 disabled:opacity-50 disabled:cursor-wait active:scale-95 text-white font-black uppercase text-[10px] tracking-widest shadow-lg"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" d="M7.217 10.907a2.25 2.25 0 100 2.186m0-2.186c.18.324.283.696.283 1.093s-.103.77-.283 1.093m0-2.186l9.566-5.314m-9.566 7.5l9.566 5.314m0 0a2.25 2.25 0 103.935 2.186 2.25 2.25 0 00-3.935-2.186zm0-12.814a2.25 2.25 0 103.933-2.185 2.25 2.25 0 00-3.933 2.185z" />
              </svg>
              {ocupado === 'compartilhando' ? 'Aguarde...' : 'Compartilhar'}
            </button>

            <button
              onClick={copiarLegenda}
              disabled={!!ocupado}
              className="flex flex-col items-center justify-center gap-1 py-3 rounded-2xl bg-slate-800 hover:bg-slate-700 disabled:opacity-50 active:scale-95 text-white font-black uppercase text-[10px] tracking-widest border border-slate-700"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 01-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 011.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 00-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 01-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5a3.375 3.375 0 00-3.375-3.375H9.75" />
              </svg>
              Copiar
            </button>

            <button
              onClick={baixar}
              disabled={!!ocupado}
              className="flex flex-col items-center justify-center gap-1 py-3 rounded-2xl bg-slate-800 hover:bg-slate-700 disabled:opacity-50 disabled:cursor-wait active:scale-95 text-white font-black uppercase text-[10px] tracking-widest border border-slate-700"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" />
              </svg>
              {ocupado === 'baixando' ? 'Aguarde...' : 'Baixar'}
            </button>
          </div>
        </div>
      </div>

      {toast && (
        <div
          className="fixed left-4 right-4 z-[210] flex justify-center pointer-events-none animate-in fade-in slide-in-from-bottom-4 duration-200"
          style={{ bottom: `calc(env(safe-area-inset-bottom, 0px) + 180px)` }}
        >
          <div className="pointer-events-auto max-w-md w-full rounded-2xl px-4 py-3 shadow-2xl border font-bold text-sm bg-slate-900 border-slate-700 text-white text-center">
            {toast}
          </div>
        </div>
      )}
    </div>
  );
}