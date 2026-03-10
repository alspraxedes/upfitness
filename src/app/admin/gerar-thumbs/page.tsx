// src/app/admin/gerar-thumbs/page.tsx
// PÁGINA TEMPORÁRIA — delete após usar
//
// Como usar:
// 1. Salve este arquivo em src/app/admin/gerar-thumbs/page.tsx
// 2. Acesse http://localhost:3000/admin/gerar-thumbs (ou no Vercel)
// 3. Clique em "Iniciar" e aguarde
// 4. Após concluir, delete este arquivo

'use client';

import { useState } from 'react';
import { supabase } from '../../../lib/supabase';

function thumbPathFromOriginal(originalPath: string): string {
  const parts = originalPath.split('/');
  const filename = parts[parts.length - 1];
  const prefix = parts.slice(0, -1).join('/');
  return prefix ? `${prefix}/thumbs/${filename}` : `thumbs/${filename}`;
}

function extractStoragePath(url: string | null): string | null {
  if (!url) return null;
  if (!url.startsWith('http')) return url;
  const parts = url.split('/produtos/');
  if (parts.length > 1) return decodeURIComponent(parts[1].split('?')[0]);
  return null;
}

async function gerarThumb(blob: Blob, maxSize = 480, quality = 0.75): Promise<Blob> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(blob);
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
      canvas.getContext('2d')!.drawImage(img, -sx, -sy, sw, sh);
      canvas.toBlob((b) => b ? resolve(b) : reject(new Error('blob nulo')), 'image/jpeg', quality);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('load falhou')); };
    img.src = url;
  });
}

type LogItem = { status: 'ok' | 'skip' | 'err'; msg: string };

export default function GerarThumbsPage() {
  const [rodando, setRodando] = useState(false);
  const [logs, setLogs] = useState<LogItem[]>([]);
  const [resumo, setResumo] = useState<{ ok: number; skip: number; err: number } | null>(null);

  const addLog = (status: LogItem['status'], msg: string) =>
    setLogs((prev) => [...prev, { status, msg }]);

  const iniciar = async () => {
    setRodando(true);
    setLogs([]);
    setResumo(null);

    let ok = 0, skip = 0, err = 0;

    try {
      addLog('ok', 'Buscando produtos com foto...');
      const { data: produtos, error } = await supabase
        .from('produtos')
        .select('id, codigo_peca, foto_url')
        .not('foto_url', 'is', null);

      if (error) throw new Error('Erro ao buscar produtos: ' + error.message);
      addLog('ok', `${produtos!.length} produtos encontrados`);

      const BATCH = 5;
      for (let i = 0; i < produtos!.length; i += BATCH) {
        const lote = produtos!.slice(i, i + BATCH);

        await Promise.all(lote.map(async (p: any) => {
          const originalPath = extractStoragePath(p.foto_url);
          if (!originalPath) { skip++; addLog('skip', `[${p.codigo_peca}] sem path`); return; }

          const thumbPath = thumbPathFromOriginal(originalPath);
          const thumbFolder = thumbPath.substring(0, thumbPath.lastIndexOf('/'));
          const thumbFilename = thumbPath.split('/').pop()!;

          // Verifica se thumb já existe
          const { data: existing } = await supabase.storage
            .from('produtos')
            .list(thumbFolder, { search: thumbFilename });

          if (existing && existing.length > 0) {
            skip++;
            addLog('skip', `[${p.codigo_peca}] já existe`);
            return;
          }

          try {
            const { data: fileData, error: dlErr } = await supabase.storage
              .from('produtos')
              .download(originalPath);
            if (dlErr || !fileData) throw new Error(dlErr?.message || 'download falhou');

            const thumbBlob = await gerarThumb(fileData);
            const { error: upErr } = await supabase.storage
              .from('produtos')
              .upload(thumbPath, thumbBlob, { upsert: true, contentType: 'image/jpeg' });

            if (upErr) throw new Error(upErr.message);
            ok++;
            addLog('ok', `[${p.codigo_peca}] ✅ gerada`);
          } catch (e: any) {
            err++;
            addLog('err', `[${p.codigo_peca}] ❌ ${e.message}`);
          }
        }));

        // Pausa entre lotes
        await new Promise((r) => setTimeout(r, 300));
      }
    } catch (e: any) {
      addLog('err', 'Erro fatal: ' + e.message);
    }

    setResumo({ ok, skip, err });
    setRodando(false);
  };

  return (
    <div className="min-h-screen bg-slate-950 text-white p-8 font-mono">
      <h1 className="text-2xl font-black mb-2">Gerador de Thumbs Retroativo</h1>
      <p className="text-slate-400 text-sm mb-6">
        Processa todas as fotos existentes e gera versões thumb (480×480px) no Storage.<br />
        <span className="text-yellow-400">⚠️ Delete esta página após usar.</span>
      </p>

      <button
        onClick={iniciar}
        disabled={rodando}
        className="bg-pink-600 hover:bg-pink-500 disabled:opacity-50 text-white font-black px-8 py-4 rounded-2xl uppercase tracking-widest mb-6 transition active:scale-95"
      >
        {rodando ? 'Processando...' : 'Iniciar'}
      </button>

      {resumo && (
        <div className="mb-6 bg-slate-900 border border-slate-700 rounded-2xl p-4 text-sm">
          <p className="text-emerald-400 font-black">✅ Geradas: {resumo.ok}</p>
          <p className="text-slate-400 font-black">⏭️ Puladas (já existiam): {resumo.skip}</p>
          <p className="text-red-400 font-black">❌ Erros: {resumo.err}</p>
        </div>
      )}

      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 max-h-[60vh] overflow-y-auto space-y-1">
        {logs.length === 0 && <p className="text-slate-600 text-sm">Aguardando início...</p>}
        {logs.map((l, i) => (
          <p key={i} className={`text-xs ${l.status === 'ok' ? 'text-emerald-400' : l.status === 'skip' ? 'text-slate-500' : 'text-red-400'}`}>
            {l.msg}
          </p>
        ))}
        {rodando && <p className="text-yellow-400 text-xs animate-pulse">processando...</p>}
      </div>
    </div>
  );
}