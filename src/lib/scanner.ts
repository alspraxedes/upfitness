// src/lib/scanner.ts
// Setup compartilhado do scanner de código de barras com melhorias focadas
// no iPhone:
//  - Prefere a câmera ultra-wide (0.5x) quando existir — o foco mínimo dela é
//    muito mais curto que o da wide (1x), permitindo ler o código bem perto
//    sem borrar. O Safari NÃO troca pra ela sozinho em WebRTC.
//  - Resolução de vídeo em 1920×1080 ideal (mais pixels por módulo = decode de
//    uma distância maior, menos tentação de aproximar demais).
//  - Expõe `MediaStreamTrack` com torch, tap-to-focus e label da lente para
//    a UI mostrar/controlar.

type Html5QrcodeType = typeof import('html5-qrcode').Html5Qrcode;
type Html5QrcodeFormatsType = typeof import('html5-qrcode').Html5QrcodeSupportedFormats;

// Capabilities estendidas que o lib.dom.d.ts ainda não cobre bem.
type ExtTrackCapabilities = MediaTrackCapabilities & {
  torch?: boolean;
  focusMode?: string[];
  zoom?: { min: number; max: number; step: number };
};

type ExtAdvancedConstraint = MediaTrackConstraintSet & {
  torch?: boolean;
  focusMode?: string;
  pointsOfInterest?: Array<{ x: number; y: number }>;
};

export type ScannerSession = {
  /** Track ativa do vídeo (nulo se não conseguiu capturar). */
  track: MediaStreamTrack | null;
  /** O device suporta ligar o flash via API. */
  hasTorch: boolean;
  /** O device aceita algum modo de foco programável. */
  hasFocusControl: boolean;
  /** Rótulo descritivo da lente escolhida (ex: "Back Ultra Wide Camera"). */
  lensLabel: string;
  setTorch: (on: boolean) => Promise<boolean>;
  /** xNorm, yNorm em [0..1]. Tenta reiniciar o AF no ponto. */
  focusAt: (xNorm: number, yNorm: number) => Promise<boolean>;
  /** Para o scanner e libera a câmera. */
  stop: () => Promise<void>;
};

type ScannerOpts = {
  /** Id do <div> onde o html5-qrcode monta o vídeo (iPhone/Android com BarcodeDetector). */
  containerId: string;
  /** Id do <video> usado pelo fallback ZXing (desktop sem BarcodeDetector). */
  videoFallbackId: string;
  onDetect: (text: string) => void;
  /** Chamado se tudo falhar; já logado no console também. */
  onError?: (err: unknown) => void;
};

// --- Seleção da lente ---------------------------------------------------

// A ordem importa: tentamos achar a ULTRA-WIDE primeiro, depois a wide
// comum. Qualquer coisa que não bata com "back" é tratada como última opção.
const RE_ULTRA = /ultra[- ]?wide|0\.5|ultragrande|ultra grande|grande angular/i;
const RE_BACK = /back|rear|traseira|environment/i;

type CameraEntry = { id: string; label: string };

export function pickPreferredCamera<T extends CameraEntry>(cameras: T[]): T | undefined {
  if (cameras.length === 0) return undefined;
  const back = cameras.filter((c) => RE_BACK.test(c.label));
  const pool = back.length > 0 ? back : cameras;
  return pool.find((c) => RE_ULTRA.test(c.label)) ?? pool[0];
}

// --- Capacidades/controles ---------------------------------------------

function getTrack(container: HTMLElement | null): MediaStreamTrack | null {
  if (!container) return null;
  const video = container.querySelector('video') as HTMLVideoElement | null;
  const stream = video?.srcObject as MediaStream | null;
  const track = stream?.getVideoTracks?.()[0] ?? null;
  return track;
}

function detectTorch(track: MediaStreamTrack | null): boolean {
  if (!track) return false;
  try {
    const caps = track.getCapabilities() as ExtTrackCapabilities;
    return !!caps.torch;
  } catch {
    return false;
  }
}

function detectFocusControl(track: MediaStreamTrack | null): boolean {
  if (!track) return false;
  try {
    const caps = track.getCapabilities() as ExtTrackCapabilities;
    const modes = caps.focusMode;
    return Array.isArray(modes) && modes.length > 0;
  } catch {
    return false;
  }
}

async function applyTorch(track: MediaStreamTrack | null, on: boolean): Promise<boolean> {
  if (!track) return false;
  try {
    await track.applyConstraints({ advanced: [{ torch: on } as ExtAdvancedConstraint] });
    return true;
  } catch {
    return false;
  }
}

// Tenta reiniciar o auto-foco no ponto apontado. O suporte varia muito
// entre browsers — se não aceitar, pelo menos tenta forçar um ciclo de AF
// alternando continuous → single-shot → continuous.
async function focusAtImpl(track: MediaStreamTrack | null, xNorm: number, yNorm: number): Promise<boolean> {
  if (!track) return false;
  const caps = (() => {
    try { return track.getCapabilities() as ExtTrackCapabilities; } catch { return null; }
  })();
  const modes = caps?.focusMode ?? [];

  // Tentativa 1: single-shot com pointsOfInterest (Chrome Android)
  if (modes.includes('single-shot')) {
    try {
      await track.applyConstraints({
        advanced: [{ focusMode: 'single-shot', pointsOfInterest: [{ x: xNorm, y: yNorm }] } as ExtAdvancedConstraint],
      });
      return true;
    } catch { /* segue tentando */ }
  }
  // Tentativa 2: alternar manual → continuous força um ciclo de AF
  if (modes.includes('manual') && modes.includes('continuous')) {
    try {
      await track.applyConstraints({ advanced: [{ focusMode: 'manual' } as ExtAdvancedConstraint] });
      await track.applyConstraints({ advanced: [{ focusMode: 'continuous' } as ExtAdvancedConstraint] });
      return true;
    } catch { /* ignora */ }
  }
  return false;
}

// --- Entry point --------------------------------------------------------

export async function startBarcodeScanner(opts: ScannerOpts): Promise<ScannerSession> {
  const { containerId, videoFallbackId, onDetect, onError } = opts;

  const container = document.getElementById(containerId);
  const zxingVideo = document.getElementById(videoFallbackId) as HTMLVideoElement | null;

  const hasBarcodeDetector = typeof (window as unknown as { BarcodeDetector?: unknown }).BarcodeDetector !== 'undefined';

  // Sessão base — vai ser preenchida depois do start.
  const session: ScannerSession = {
    track: null,
    hasTorch: false,
    hasFocusControl: false,
    lensLabel: '',
    setTorch: async () => false,
    focusAt: async () => false,
    stop: async () => { /* preenchido abaixo */ },
  };

  // Flag anti-duplicata: o html5-qrcode/ZXing seguem lendo o vídeo e podem
  // chamar o callback várias vezes em sequência com o mesmo (ou novos)
  // códigos. Garantimos que `onDetect` só é chamado UMA VEZ e paramos a
  // sessão em seguida — senão o estado da página fica sendo sobrescrito e
  // o usuário não consegue limpar/editar o campo depois.
  let detected = false;
  const handleDetect = (text: string) => {
    if (detected) return;
    const cleaned = String(text || '').trim();
    if (!cleaned) return;
    detected = true;
    try { onDetect(cleaned); } catch (err) { console.error(err); }
    // Para a câmera fora da pilha de chamadas atual para não entrar em corrida
    // com os callbacks internos dos leitores.
    queueMicrotask(() => { void session.stop(); });
  };

  // --- Caminho ZXing (desktop sem BarcodeDetector) ---------------------
  if (!hasBarcodeDetector) {
    try {
      const [{ BrowserMultiFormatReader }, { BarcodeFormat, DecodeHintType }] = await Promise.all([
        import('@zxing/browser'),
        import('@zxing/library'),
      ]);

      if (!zxingVideo) throw new Error('ZXing video element não encontrado.');

      container?.classList.add('hidden');
      zxingVideo.classList.remove('hidden');

      const hints = new Map<number, unknown>();
      hints.set(DecodeHintType.POSSIBLE_FORMATS, [BarcodeFormat.EAN_13, BarcodeFormat.EAN_8]);

      const reader = new BrowserMultiFormatReader(hints, { delayBetweenScanAttempts: 200 });

      const devices = await BrowserMultiFormatReader.listVideoInputDevices();
      const camList: CameraEntry[] = devices.map((d) => ({ id: d.deviceId, label: d.label }));
      const preferred = pickPreferredCamera(camList);
      session.lensLabel = preferred?.label ?? '';

      await reader.decodeFromVideoDevice(preferred?.id ?? undefined, zxingVideo, (result) => {
        const text = result?.getText?.() ? result.getText() : '';
        if (text) handleDetect(text);
      });

      // ZXing não oferece controle de torch/focus de forma portátil — expomos como no-op.
      const track = (zxingVideo.srcObject as MediaStream | null)?.getVideoTracks?.()[0] ?? null;
      session.track = track;
      session.hasTorch = detectTorch(track);
      session.hasFocusControl = detectFocusControl(track);
      session.setTorch = (on) => applyTorch(session.track, on);
      session.focusAt = (x, y) => focusAtImpl(session.track, x, y);
      session.stop = async () => {
        try {
          const r = reader as unknown as { stopContinuousDecode?: () => void; stopAsyncDecode?: () => void };
          r.stopContinuousDecode?.();
          r.stopAsyncDecode?.();
        } catch { /* ignore */ }
        try {
          const stream = zxingVideo.srcObject as MediaStream | null;
          stream?.getTracks?.().forEach((t) => t.stop());
          zxingVideo.srcObject = null;
        } catch { /* ignore */ }
      };
      return session;
    } catch (err) {
      console.error('Falha ao iniciar ZXing fallback:', err);
      onError?.(err);
    }
  }

  // --- Caminho padrão (iPhone / BarcodeDetector): html5-qrcode ---------
  let Html5Qrcode: Html5QrcodeType;
  let Formats: Html5QrcodeFormatsType;
  try {
    const mod = await import('html5-qrcode');
    Html5Qrcode = mod.Html5Qrcode;
    Formats = mod.Html5QrcodeSupportedFormats;
  } catch (err) {
    console.error('Falha ao carregar html5-qrcode:', err);
    onError?.(err);
    return session;
  }

  if (!container) {
    const e = new Error(`Container "${containerId}" não existe no DOM.`);
    console.error(e.message);
    onError?.(e);
    return session;
  }

  const scanner = new Html5Qrcode(containerId);

  const config = {
    fps: 9,
    qrbox: { width: 280, height: 120 },
    aspectRatio: 1.777,
    disableFlip: true,
    formatsToSupport: [Formats.EAN_13, Formats.EAN_8],
    experimentalFeatures: { useBarCodeDetectorIfSupported: true },
    // Resolução maior: mais pixels por módulo do EAN; o usuário consegue ler
    // de uma distância maior em vez de aproximar demais.
    videoConstraints: { width: { ideal: 1920 }, height: { ideal: 1080 } },
  };

  const decoded = (text: string) => {
    handleDetect(text);
  };

  try {
    const cameras = (await Html5Qrcode.getCameras()) as CameraEntry[];
    const preferred = pickPreferredCamera(cameras);
    session.lensLabel = preferred?.label ?? '';
    if (preferred) {
      await scanner.start({ deviceId: { exact: preferred.id } }, config, decoded, () => { /* onError silenciado */ });
    } else {
      await scanner.start({ facingMode: 'environment' }, config, decoded, () => { /* onError silenciado */ });
    }
  } catch (err) {
    console.error('Falha ao iniciar com câmera preferida:', err);
    // Fallback: facingMode plano.
    try {
      await scanner.start({ facingMode: 'environment' }, config, decoded, () => { /* onError silenciado */ });
    } catch (err2) {
      console.error('Fallback html5-qrcode falhou:', err2);
      onError?.(err2);
      return session;
    }
  }

  // Depois do start, o <video> existe dentro do container.
  const track = getTrack(container);
  session.track = track;
  session.hasTorch = detectTorch(track);
  session.hasFocusControl = detectFocusControl(track);
  session.setTorch = (on) => applyTorch(session.track, on);
  session.focusAt = (x, y) => focusAtImpl(session.track, x, y);
  session.stop = async () => {
    try {
      const maybe = scanner.stop?.();
      if (maybe && typeof (maybe as Promise<unknown>).then === 'function') {
        await (maybe as Promise<unknown>).catch(() => { /* ignore */ });
      }
    } catch { /* ignore */ }
    try { scanner.clear?.(); } catch { /* ignore */ }
  };

  return session;
}