// src/lib/crediario.ts
// Helpers de crediário compartilhados (antes duplicados em venda, histórico
// e recebíveis). Sem dependências de React — funções puras.

export type FrequenciaCrediario = 'semanal' | 'quinzenal' | 'mensal';

export const FREQ_LABEL: Record<FrequenciaCrediario, string> = {
  semanal: 'Semanal',
  quinzenal: 'Quinzenal',
  mensal: 'Mensal',
};

export const FREQ_CURTA: Record<string, string> = {
  semanal: 'semanal',
  quinzenal: 'quinzenal',
  mensal: 'mensal',
};

// --- DATAS (ISO local YYYY-MM-DD, sem timezone) ---
export function hojeISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function addDiasISO(baseISO: string, dias: number): string {
  const [y, m, d] = baseISO.split('-').map(Number);
  const dt = new Date(y, m - 1, d + dias);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}

// Soma i ciclos da frequência à data base. Mensal com clamp de fim de mês:
// 1ª parcela dia 31 -> fevereiro cai no 28/29.
export function addCiclos(baseISO: string, freq: FrequenciaCrediario, i: number): string {
  const [y, m, d] = baseISO.split('-').map(Number);
  if (freq === 'mensal') {
    const totalM = (m - 1) + i;
    const ano = y + Math.floor(totalM / 12);
    const mes = (totalM % 12) + 1;
    const ultimoDia = new Date(ano, mes, 0).getDate();
    return `${ano}-${String(mes).padStart(2, '0')}-${String(Math.min(d, ultimoDia)).padStart(2, '0')}`;
  }
  const dt = new Date(y, m - 1, d + (freq === 'semanal' ? 7 : 14) * i);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}

export const formatDataCurta = (iso: string) => {
  const [y, m, d] = iso.split('-');
  return `${d}/${m}/${y.slice(2)}`;
};

// --- VALORES (digitação com vírgula + moeda) ---
export const parseValorDigitado = (s: string) => {
  const v = parseFloat(String(s).replace(',', '.'));
  return isNaN(v) ? 0 : v;
};

export const valorParaStr = (v: number) => v.toFixed(2).replace('.', ',');

export const formatBRL = (val: number) =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val);

// Sanitiza entrada de valor (só dígitos, vírgula e ponto)
export const sanitizeValor = (s: string) => s.replace(/[^0-9.,]/g, '');

// --- GERAÇÃO DE PARCELAS ---
export type ParcelaGerada = {
  numero: number;
  valor: number;
  valorStr: string;
  data_vencimento: string;
};

// Divide valorFinal em n parcelas iguais (centavos inteiros);
// a última absorve a diferença de arredondamento.
export function gerarParcelas(
  valorFinal: number,
  n: number,
  primeiraISO: string,
  freq: FrequenciaCrediario
): ParcelaGerada[] {
  const totalCents = Math.round(valorFinal * 100);
  if (n < 1 || totalCents <= 0 || !primeiraISO) return [];
  const base = Math.floor(totalCents / n);
  const out: ParcelaGerada[] = [];
  for (let i = 0; i < n; i++) {
    const cents = i === n - 1 ? totalCents - base * (n - 1) : base;
    out.push({
      numero: i + 1,
      valor: cents / 100,
      valorStr: valorParaStr(cents / 100),
      data_vencimento: addCiclos(primeiraISO, freq, i),
    });
  }
  return out;
}

// Divide um total (em centavos) igualmente entre n itens, último absorve resto.
export function dividirCents(totalCents: number, n: number): number[] {
  if (n < 1) return [];
  const safe = Math.max(0, totalCents);
  const base = Math.floor(safe / n);
  return Array.from({ length: n }, (_, i) => (i === n - 1 ? safe - base * (n - 1) : base));
}