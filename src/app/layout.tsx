import './globals.css';

export const metadata = {
  title: 'UpFitness - Controle de Estoque',
  manifest: "/manifest.json",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="pt-br" className="bg-slate-950">
      <body className="antialiased">{children}</body>
    </html>
  );
}