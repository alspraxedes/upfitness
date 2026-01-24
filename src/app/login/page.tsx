'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '../../lib/supabase';

export default function LoginPage() {
  const router = useRouter();
  const [modo, setModo] = useState<'login' | 'signup'>('login');
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [loading, setLoading] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [sucessoMsg, setSucessoMsg] = useState<string | null>(null); // Novo estado para feedback

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
    setSucessoMsg(null);
    setLoading(true);

    try {
      if (!email.trim() || !senha.trim()) throw new Error('Informe e-mail e senha.');

      if (modo === 'login') {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password: senha,
        });
        if (error) throw error;
        router.replace('/');
      } else {
        // --- AJUSTE AQUI ---
        const origin = window.location.origin;
        
        const { error, data } = await supabase.auth.signUp({
          email: email.trim(),
          password: senha,
          options: {
            emailRedirectTo: origin, // Força o link para a URL atual
          },
        });
        
        if (error) throw error;

        // Verifica se o usuário foi criado mas precisa confirmar (session é null)
        if (data?.user && !data.session) {
            setSucessoMsg('Conta criada! Verifique seu e-mail (inclusive SPAM) para confirmar o cadastro.');
            setModo('login'); // Volta para tela de login
        } else if (data?.session) {
            // Se o "Confirm Email" estiver desligado no Supabase, ele entra direto
            router.replace('/');
        }
      }
    } catch (err: any) {
      setErro(err?.message ?? 'Erro ao autenticar.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-sans flex items-center justify-center px-4">
      <div className="w-full max-w-md">
        <div className="rounded-2xl bg-gradient-to-r from-pink-600 to-blue-600 p-[1px]">
          <div className="rounded-2xl bg-slate-900 border border-slate-800 p-8">
            <h1 className="font-black italic text-2xl tracking-tighter">
              UPFITNESS <span className="font-light tracking-normal text-white/80">ACESSO</span>
            </h1>

            <p className="text-slate-300 text-sm mt-2">
              {modo === 'login' ? 'Entre para acessar o estoque.' : 'Crie um usuário para acessar o sistema.'}
            </p>

            {erro && (
              <div className="mt-6 rounded-xl bg-red-950/40 border border-red-900/40 p-4 text-sm text-red-200 font-bold">
                ⚠️ {erro}
              </div>
            )}

            {sucessoMsg && (
              <div className="mt-6 rounded-xl bg-green-950/40 border border-green-900/40 p-4 text-sm text-green-200 font-bold animate-pulse">
                ✅ {sucessoMsg}
              </div>
            )}

            <form onSubmit={handleSubmit} className="mt-6 space-y-4">
              <div>
                <label className="text-[10px] font-bold text-slate-500 uppercase ml-2">E-mail</label>
                <input
                  className="mt-1 w-full bg-slate-950 border border-slate-800 p-4 rounded-2xl outline-none focus:border-pink-500 text-sm transition-all"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  type="email"
                  placeholder="seu@email.com"
                  autoComplete="email"
                />
              </div>

              <div>
                <label className="text-[10px] font-bold text-slate-500 uppercase ml-2">Senha</label>
                <input
                  className="mt-1 w-full bg-slate-950 border border-slate-800 p-4 rounded-2xl outline-none focus:border-pink-500 text-sm transition-all"
                  value={senha}
                  onChange={(e) => setSenha(e.target.value)}
                  type="password"
                  placeholder="••••••••"
                  autoComplete={modo === 'login' ? 'current-password' : 'new-password'}
                />
              </div>

              <button
                disabled={loading}
                className="w-full bg-gradient-to-r from-pink-600 to-pink-500 text-white font-black py-4 rounded-2xl shadow-2xl hover:brightness-110 active:scale-[0.99] transition-all uppercase tracking-[0.2em] text-[11px] disabled:opacity-60"
              >
                {loading ? 'Processando...' : modo === 'login' ? 'Entrar' : 'Criar conta'}
              </button>
            </form>

            <div className="mt-6 flex items-center justify-between text-xs">
              <button
                type="button"
                onClick={() => {
                    setModo(modo === 'login' ? 'signup' : 'login');
                    setErro(null);
                    setSucessoMsg(null);
                }}
                className="text-slate-300 hover:text-white underline decoration-slate-700"
              >
                {modo === 'login' ? 'Não tenho conta → criar' : 'Já tenho conta → entrar'}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}