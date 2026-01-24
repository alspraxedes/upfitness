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

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
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
        const { error } = await supabase.auth.signUp({
          email: email.trim(),
          password: senha,
        });
        if (error) throw error;

        // Dependendo da config do Supabase, pode exigir confirmação por e-mail.
        // Se não exigir, já estará logado.
        const { data } = await supabase.auth.getUser();
        if (data?.user) router.replace('/');
        else setErro('Conta criada. Verifique seu e-mail para confirmar e depois faça login.');
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
              <div className="mt-6 rounded-xl bg-slate-950/40 border border-red-900/40 p-4 text-sm text-red-200">
                {erro}
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
                onClick={() => setModo(modo === 'login' ? 'signup' : 'login')}
                className="text-slate-300 hover:text-white"
              >
                {modo === 'login' ? 'Não tenho conta → criar' : 'Já tenho conta → entrar'}
              </button>

              <button
                type="button"
                onClick={async () => {
                  await supabase.auth.signOut();
                  setErro('Sessão encerrada.');
                }}
                className="text-slate-500 hover:text-slate-300"
                title="Útil para limpar sessão"
              >
                Sair
              </button>
            </div>

            <p className="mt-6 text-[11px] text-slate-500">
              Se você habilitou confirmação por e-mail no Supabase Auth, a criação de conta pode exigir confirmação antes do login.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
