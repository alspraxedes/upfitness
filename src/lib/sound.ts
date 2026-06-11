// src/lib/sound.ts
// Beep de confirmação gerado via WebAudio — sem dependência de
// arquivos externos (antes: mp3 do soundjay.com, que quebrava
// offline e dependia de um site de terceiros continuar no ar).

let audioCtx: AudioContext | null = null;

function getCtx(): AudioContext | null {
  try {
    if (!audioCtx) {
      const Ctx =
        window.AudioContext || (window as any).webkitAudioContext;
      if (!Ctx) return null;
      audioCtx = new Ctx();
    }
    // iOS suspende o contexto até a primeira interação do usuário
    if (audioCtx.state === 'suspended') {
      audioCtx.resume().catch(() => {});
    }
    return audioCtx;
  } catch {
    return null;
  }
}

export function playBeep() {
  try {
    const ctx = getCtx();
    if (ctx) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);

      osc.type = 'square';
      osc.frequency.value = 1175; // ~D6, timbre de "leitor de mercado"

      const t = ctx.currentTime;
      gain.gain.setValueAtTime(0.15, t);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.12);

      osc.start(t);
      osc.stop(t + 0.13);
    }
  } catch {
    // som é cosmético — nunca deve quebrar o fluxo
  }

  try {
    if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
      (navigator as Navigator & { vibrate: (p: number) => boolean }).vibrate(50);
    }
  } catch {}
}