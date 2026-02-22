// src/lib/signedUrlCache.ts
import { supabase } from './supabase';

const CACHE_KEY = 'img:signed-cache:v1';
const DEFAULT_TTL_MS = 1000 * 60 * 50; // 50 min (um pouco menor que 1h)

type CacheEntry = { url: string; exp: number };
type CacheMap = Record<string, CacheEntry>;

function loadCache(): CacheMap {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY);
    return raw ? (JSON.parse(raw) as CacheMap) : {};
  } catch {
    return {};
  }
}

function saveCache(map: CacheMap) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify(map));
  } catch {}
}

export async function getSignedUrlCached(
  bucket: string,
  pathOrOriginalUrl: string,
  extractPath: (u: string) => string | null,
  ttlSeconds = 3600
) {
  const now = Date.now();
  const cache = loadCache();

  // chave pelo URL original (foto_url) para você não mudar seu estado atual
  const key = pathOrOriginalUrl;

  const hit = cache[key];
  if (hit && hit.exp > now) return hit.url;

  const path = extractPath(pathOrOriginalUrl);
  if (!path) return null;

  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, ttlSeconds);
  if (error || !data?.signedUrl) return null;

  cache[key] = { url: data.signedUrl, exp: now + DEFAULT_TTL_MS };
  saveCache(cache);

  return data.signedUrl;
}