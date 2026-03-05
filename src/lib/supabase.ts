import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false, // <— recomendado
    storageKey: 'upfitness-auth-token',
  },
  global: {
    fetch: (url, options) =>
      fetch(url, {
        ...options,
        // @ts-ignore
        signal: undefined,
      }),
  },
});