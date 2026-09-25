#!/usr/bin/env node
// scripts/backfill-thumbs.mjs
//
// Gera thumbs faltantes (ou regenera todas com --force) para produtos
// que já têm foto_url. Roda local, usa a SERVICE_ROLE_KEY do Supabase
// para bypassar RLS e conseguir upload no bucket.
//
// Padrão da thumb: 240px, WebP qualidade 70 (~5-15 KB por foto).
//
// USO:
//   node scripts/backfill-thumbs.mjs             # só as faltantes
//   node scripts/backfill-thumbs.mjs --force     # regenera todas
//   node scripts/backfill-thumbs.mjs --dry-run   # só relata, não sobe
//   node scripts/backfill-thumbs.mjs --limit 50  # processa só as primeiras 50
//
// PRÉ-REQUISITOS:
//   1. Instalar: npm install --no-save @supabase/supabase-js sharp
//   2. Definir env vars antes de rodar:
//        export NEXT_PUBLIC_SUPABASE_URL='https://<projeto>.supabase.co'
//        export SUPABASE_SERVICE_ROLE_KEY='<a chave service_role, NÃO a anon>'
//      Você pega a service_role em: Supabase → Project Settings → API Keys.
//      NUNCA commite essa chave no repo — ela dá acesso total ao banco.

import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';

// ============================================================================
// CONFIG
// ============================================================================
const BUCKET = 'produtos';
const THUMB_MAX_SIZE = 240;      // pixels
const THUMB_QUALITY = 70;        // WebP q0-100
const CONCURRENCY = 6;           // uploads simultâneos (não abusar do Supabase)

// ============================================================================
// FLAGS
// ============================================================================
const args = process.argv.slice(2);
const FORCE = args.includes('--force');
const DRY_RUN = args.includes('--dry-run');
const LIMIT_IDX = args.indexOf('--limit');
const LIMIT = LIMIT_IDX >= 0 ? parseInt(args[LIMIT_IDX + 1], 10) : null;

// ============================================================================
// CLIENT
// ============================================================================
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('❌ Faltam env vars NEXT_PUBLIC_SUPABASE_URL e/ou SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ============================================================================
// HELPERS
// ============================================================================

/** Extrai path relativo do storage a partir de uma URL pública. */
function extractStoragePath(url) {
  if (!url) return null;
  if (!url.startsWith('http')) return url;
  const parts = url.split(`/${BUCKET}/`);
  if (parts.length > 1) return decodeURIComponent(parts[1].split('?')[0]);
  return null;
}

/** Gera path da thumb correspondente. */
function thumbPathFromOriginal(originalPath) {
  const parts = originalPath.split('/');
  const filename = parts[parts.length - 1];
  const prefix = parts.slice(0, -1).join('/');
  return prefix ? `${prefix}/thumbs/${filename}` : `thumbs/${filename}`;
}

/** Verifica se um path existe no bucket. */
async function existeNoBucket(path) {
  const parts = path.split('/');
  const filename = parts[parts.length - 1];
  const prefix = parts.slice(0, -1).join('/');
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .list(prefix, { search: filename, limit: 1 });
  if (error) return false;
  return (data ?? []).some((f) => f.name === filename);
}

/** Baixa a foto original como Buffer. */
async function baixarOriginal(path) {
  const { data, error } = await supabase.storage.from(BUCKET).download(path);
  if (error) throw error;
  return Buffer.from(await data.arrayBuffer());
}

/** Redimensiona e converte para WebP. */
async function gerarThumbBuffer(inputBuffer) {
  return sharp(inputBuffer)
    .resize(THUMB_MAX_SIZE, THUMB_MAX_SIZE, {
      fit: 'cover',
      position: 'center',
    })
    .webp({ quality: THUMB_QUALITY })
    .toBuffer();
}

/** Sobe a thumb no bucket, sempre com upsert. */
async function subirThumb(thumbPath, buffer) {
  const { error } = await supabase.storage
    .from(BUCKET)
    .upload(thumbPath, buffer, {
      contentType: 'image/webp',
      upsert: true,
    });
  if (error) throw error;
}

// ============================================================================
// FLUXO
// ============================================================================

async function listarProdutos() {
  // Paginação — Supabase corta em 1000.
  const PAGE = 1000;
  const todos = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from('produtos')
      .select('id, codigo_peca, descricao, foto_url')
      .not('foto_url', 'is', null)
      .order('created_at', { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) throw error;
    todos.push(...(data ?? []));
    if ((data ?? []).length < PAGE) break;
  }
  return todos;
}

async function processarUm(produto) {
  const originalPath = extractStoragePath(produto.foto_url);
  if (!originalPath) {
    return { status: 'skip', motivo: 'foto_url inválida' };
  }

  const thumbPath = thumbPathFromOriginal(originalPath);

  if (!FORCE) {
    const jaExiste = await existeNoBucket(thumbPath);
    if (jaExiste) return { status: 'skip', motivo: 'thumb já existe' };
  }

  if (DRY_RUN) {
    return { status: 'would-generate', thumbPath };
  }

  try {
    const original = await baixarOriginal(originalPath);
    const thumb = await gerarThumbBuffer(original);
    await subirThumb(thumbPath, thumb);
    return {
      status: 'ok',
      tamanhoOriginal: original.length,
      tamanhoThumb: thumb.length,
    };
  } catch (e) {
    return { status: 'erro', erro: e?.message || String(e) };
  }
}

/** Processa um array em lotes paralelos de tamanho `size`. */
async function processarEmLotes(items, size, fn) {
  const resultados = [];
  for (let i = 0; i < items.length; i += size) {
    const lote = items.slice(i, i + size);
    const parciais = await Promise.all(lote.map(fn));
    resultados.push(...parciais);
    const total = i + lote.length;
    process.stdout.write(`\r  processado ${total}/${items.length}...`);
  }
  process.stdout.write('\n');
  return resultados;
}

// ============================================================================
// MAIN
// ============================================================================
(async () => {
  console.log('🔍 Buscando produtos com foto_url...');
  let produtos = await listarProdutos();
  console.log(`   ${produtos.length} produtos encontrados`);

  if (LIMIT) {
    produtos = produtos.slice(0, LIMIT);
    console.log(`   Limitado a ${produtos.length} (--limit ${LIMIT})`);
  }

  console.log('');
  console.log(`⚙️  Modo: ${FORCE ? 'REGENERAR TODAS' : 'só as faltantes'}${DRY_RUN ? ' (DRY-RUN)' : ''}`);
  console.log(`⚙️  Thumb: ${THUMB_MAX_SIZE}px WebP q${THUMB_QUALITY}, concorrência ${CONCURRENCY}`);
  console.log('');

  const t0 = Date.now();
  const resultados = await processarEmLotes(produtos, CONCURRENCY, processarUm);
  const tt = ((Date.now() - t0) / 1000).toFixed(1);

  // Sumário
  const stats = {
    ok: 0,
    skip: 0,
    erro: 0,
    'would-generate': 0,
    bytesOriginal: 0,
    bytesThumb: 0,
  };
  const erros = [];
  for (const r of resultados) {
    stats[r.status] = (stats[r.status] ?? 0) + 1;
    if (r.status === 'ok') {
      stats.bytesOriginal += r.tamanhoOriginal;
      stats.bytesThumb += r.tamanhoThumb;
    }
    if (r.status === 'erro') erros.push(r.erro);
  }

  console.log('');
  console.log('═'.repeat(50));
  console.log(`✅ Concluído em ${tt}s`);
  console.log(`   Geradas:            ${stats.ok}`);
  console.log(`   Puladas (já OK):    ${stats.skip}`);
  if (DRY_RUN) console.log(`   Seriam geradas:     ${stats['would-generate']}`);
  console.log(`   Erros:              ${stats.erro}`);
  if (stats.ok > 0) {
    const mbOrig = (stats.bytesOriginal / 1024 / 1024).toFixed(2);
    const mbThumb = (stats.bytesThumb / 1024 / 1024).toFixed(2);
    const razao = (stats.bytesOriginal / stats.bytesThumb).toFixed(1);
    console.log(`   Peso original:      ${mbOrig} MB (total)`);
    console.log(`   Peso das thumbs:    ${mbThumb} MB (total)`);
    console.log(`   Redução:            ${razao}× menor`);
  }
  if (erros.length > 0) {
    console.log('');
    console.log('⚠️  Primeiros erros:');
    erros.slice(0, 5).forEach((e) => console.log(`   • ${e}`));
    if (erros.length > 5) console.log(`   ... e mais ${erros.length - 5}`);
  }
})().catch((e) => {
  console.error('❌ Erro fatal:', e);
  process.exit(1);
});
