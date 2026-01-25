import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

// Verificação de segurança para não quebrar o build se faltar env
if (!supabaseUrl || !supabaseAnonKey) {
  console.error('⚠️ ALERTA: Variáveis de ambiente do Supabase não encontradas!');
}

// Configuração otimizada para evitar AbortError no Next.js
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true, // Mantém o login
    autoRefreshToken: true, // Renova token sozinho
    detectSessionInUrl: true,
    storageKey: 'upfitness-auth-token', // Nome único para não conflitar com outros apps
  },
  global: {
    // IMPORTANTE: Isso impede que o React cancele requisições prematuramente
    fetch: (url, options) => {
      return fetch(url, {
        ...options,
        // @ts-ignore
        signal: undefined, // Remove o AbortSignal automático do Next.js
        cache: 'no-store', // Garante dados frescos sempre
      });
    },
  },
});