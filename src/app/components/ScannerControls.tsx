// src/app/components/ScannerControls.tsx
// UI dos controles do scanner: botão de lanterna, label da lente ativa,
// dica de distância ideal e overlay invisível que captura toques pra
// tap-to-focus. Fica sobreposto ao vídeo (position: absolute inset-0).
'use client';

import { useState } from 'react';
import type { ScannerSession } from '../../lib/scanner';

type Props = {
  session: ScannerSession | null;
};

export function ScannerControls({ session }: Props) {
  const [torchOn, setTorchOn] = useState(false);
  const [focusPing, setFocusPing] = useState<{ x: number; y: number; key: number } | null>(null);

  async function toggleTorch() {
    if (!session?.hasTorch) return;
    const next = !torchOn;
    const ok = await session.setTorch(next);
    if (ok) setTorchOn(next);
  }

  async function handleTap(e: React.PointerEvent<HTMLDivElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;
    setFocusPing({ x: e.clientX - rect.left, y: e.clientY - rect.top, key: Date.now() });
    if (session?.hasFocusControl) {
      await session.focusAt(x, y);
    }
  }

  // Rótulo curto da lente (ex: "Back Ultra Wide Camera" → "0.5x ultra-wide")
  const lensShort = (() => {
    const l = session?.lensLabel ?? '';
    if (!l) return '';
    if (/ultra[- ]?wide|0\.5|ultragrande|ultra grande|grande angular/i.test(l)) return '0.5× ultra-wide';
    if (/tele|3x|zoom/i.test(l)) return '3× tele';
    if (/back|rear|traseira/i.test(l)) return '1× wide';
    return l;
  })();

  return (
    <>
      {/* Camada invisível para tap-to-focus (sobre o vídeo, abaixo dos botões) */}
      <div
        className="absolute inset-0 z-10"
        onPointerDown={handleTap}
        aria-label="Toque para focar"
      />

      {/* "Ping" visual onde o usuário tocou pra focar */}
      {focusPing && (
        <div
          key={focusPing.key}
          className="absolute z-20 pointer-events-none"
          style={{ left: focusPing.x - 22, top: focusPing.y - 22 }}
          onAnimationEnd={() => setFocusPing(null)}
        >
          <div className="w-11 h-11 rounded-full border-2 border-amber-300 animate-ping" />
        </div>
      )}

      {/* Mira pulsante guiando o enquadramento */}
      <div className="absolute inset-0 z-10 flex items-center justify-center pointer-events-none">
        <div className="relative w-[72%] max-w-[320px] aspect-[16/7]">
          <div className="absolute inset-0 border-2 border-pink-500/40 rounded-xl animate-pulse" />
          <div className="absolute top-0 left-0 w-6 h-6 border-t-4 border-l-4 border-pink-500 rounded-tl-xl" />
          <div className="absolute top-0 right-0 w-6 h-6 border-t-4 border-r-4 border-pink-500 rounded-tr-xl" />
          <div className="absolute bottom-0 left-0 w-6 h-6 border-b-4 border-l-4 border-pink-500 rounded-bl-xl" />
          <div className="absolute bottom-0 right-0 w-6 h-6 border-b-4 border-r-4 border-pink-500 rounded-br-xl" />
        </div>
      </div>

      {/* Label da lente ativa — ajuda a entender se está na ultra-wide */}
      {lensShort && (
        <div className="absolute top-3 left-3 z-30 bg-slate-950/80 border border-slate-700/60 rounded-full px-3 py-1 text-[10px] font-black uppercase tracking-widest text-slate-300">
          {lensShort}
        </div>
      )}

      {/* Botão de lanterna — só aparece quando o device suporta */}
      {session?.hasTorch && (
        <button
          type="button"
          onClick={toggleTorch}
          className={`absolute top-3 right-3 z-30 w-11 h-11 rounded-full border backdrop-blur-md flex items-center justify-center transition active:scale-95 ${
            torchOn
              ? 'bg-amber-500 border-amber-300 text-slate-950 shadow-lg shadow-amber-500/50'
              : 'bg-slate-950/80 border-slate-700/60 text-slate-200'
          }`}
          aria-label={torchOn ? 'Apagar lanterna' : 'Acender lanterna'}
          title={torchOn ? 'Apagar lanterna' : 'Acender lanterna'}
        >
          <span className="text-xl leading-none">{torchOn ? '💡' : '🔦'}</span>
        </button>
      )}

      {/* Dica de distância fixada no rodapé do vídeo */}
      <div className="absolute left-0 right-0 bottom-3 z-30 flex justify-center pointer-events-none">
        <div className="bg-slate-950/80 border border-slate-700/60 rounded-full px-3 py-1 text-[10px] font-black uppercase tracking-widest text-slate-300">
          Mantenha ~15–20 cm · toque p/ focar
        </div>
      </div>
    </>
  );
}
