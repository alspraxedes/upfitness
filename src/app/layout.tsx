import './globals.css';
import { Saira } from 'next/font/google';

// Saira: família esportiva variável — os pesos black/italic dos títulos
// (font-black italic) passam a usar a versão de verdade da fonte,
// em vez do itálico sintético da fonte do sistema.
const saira = Saira({
  subsets: ['latin'],
  style: ['normal', 'italic'],
  weight: ['400', '500', '600', '700', '800', '900'],
  variable: '--font-saira',
  display: 'swap',
});

export const metadata = {
  title: 'UpFitness - Controle de Estoque',
  manifest: '/manifest.json',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="pt-br" className={`bg-slate-950 ${saira.variable}`}>
      <body className="antialiased">{children}</body>
    </html>
  );
}