// src/lib/thumbUtils.ts
// Utilitários para geração e gerenciamento de thumbnails.
//
// A thumb é o que aparece em cards de 48-64px na listagem, então não
// precisa ser grande. Alvo: 240x240 em WebP qualidade 70, que sai em
// 5-15 KB por foto (vs. 50-200 KB da versão anterior 480x480 JPEG q75).
//
// O path continua com extensão .jpg mesmo quando o arquivo é WebP — o
// browser renderiza pelo Content-Type, não pela extensão. Assim
// getThumbUrl() e thumbs antigas seguem funcionando sem mudança.

/**
 * Gera uma thumb quadrada (cover) a partir de um File/Blob.
 * Padrão: 240x240px, WebP qualidade 70 (fallback JPEG q70 em browsers
 * que não suportam WebP encoding em canvas — Safari antigo).
 */
export async function gerarThumb(
  file: File | Blob,
  maxSize = 240,
  quality = 0.7,
): Promise<File> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(file);

    img.onload = () => {
      URL.revokeObjectURL(url);

      const { naturalWidth: w, naturalHeight: h } = img;
      const scale = Math.max(maxSize / w, maxSize / h);
      const sw = Math.round(w * scale);
      const sh = Math.round(h * scale);
      const sx = Math.round((sw - maxSize) / 2);
      const sy = Math.round((sh - maxSize) / 2);

      const canvas = document.createElement('canvas');
      canvas.width = maxSize;
      canvas.height = maxSize;
      const ctx = canvas.getContext('2d')!;
      ctx.drawImage(img, -sx, -sy, sw, sh);

      // Tenta WebP primeiro (Safari 14+, Chrome, Firefox — todos os
      // browsers modernos suportam encoding). Se retornar null (browser
      // muito antigo), cai pra JPEG.
      canvas.toBlob(
        (webpBlob) => {
          if (webpBlob && webpBlob.size > 0) {
            resolve(new File([webpBlob], 'thumb.webp', { type: 'image/webp' }));
            return;
          }
          canvas.toBlob(
            (jpegBlob) => {
              if (!jpegBlob) return reject(new Error('Falha ao gerar thumb'));
              resolve(new File([jpegBlob], 'thumb.jpg', { type: 'image/jpeg' }));
            },
            'image/jpeg',
            quality,
          );
        },
        'image/webp',
        quality,
      );
    };

    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('Falha ao carregar imagem para thumb'));
    };

    img.src = url;
  });
}

/**
 * Dado o path da foto original dentro do bucket, retorna o path onde
 * a thumb deve ser salva.
 * Ex: "migracao/UP001_123.jpg" -> "migracao/thumbs/UP001_123.jpg"
 *
 * Mantemos a extensão original mesmo quando a thumb é WebP — o browser
 * usa o Content-Type do storage, não a extensão da URL, e assim o
 * getThumbUrl() no frontend não precisa saber diferenciar.
 */
export function thumbPathFromOriginal(originalPath: string): string {
  const parts = originalPath.split('/');
  const filename = parts[parts.length - 1];
  const prefix = parts.slice(0, -1).join('/');
  return prefix ? `${prefix}/thumbs/${filename}` : `thumbs/${filename}`;
}

/**
 * Extrai o path relativo do storage a partir de uma URL pública do Supabase.
 * Ex: "https://xxx.supabase.co/storage/v1/object/public/produtos/migracao/foto.jpg"
 *     -> "migracao/foto.jpg"
 */
export function extractStoragePath(url: string | null): string | null {
  if (!url) return null;
  if (!url.startsWith('http')) return url;
  const parts = url.split('/produtos/');
  if (parts.length > 1) return decodeURIComponent(parts[1].split('?')[0]);
  return null;
}

/**
 * Dado a foto_url original (URL pública), retorna a URL pública da thumb.
 * Assume que a thumb está em thumbs/ dentro da mesma pasta.
 */
export function thumbUrlFromFotoUrl(fotoUrl: string | null): string | null {
  if (!fotoUrl) return null;
  const lastSlash = fotoUrl.lastIndexOf('/');
  if (lastSlash === -1) return null;
  const dir = fotoUrl.substring(0, lastSlash);
  const file = fotoUrl.substring(lastSlash + 1).split('?')[0];
  return `${dir}/thumbs/${file}`;
}