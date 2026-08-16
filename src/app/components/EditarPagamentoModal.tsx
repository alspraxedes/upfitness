'use client';

// src/app/components/EditarPagamentoModal.tsx
//
// Modal robusto de edição de pagamento de uma venda. Suporta N formas
// (split), incluindo crediário parcial. Substitui o antigo modal
// "Converter p/ Crediário" no histórico, cobrindo:
//   - Trocar entre formas simples (pix ↔ dinheiro ↔ débito ↔ crédito)
//   - Adicionar linhas para split (100 PIX + 200 dinheiro, etc)
//   - Adicionar crediário parcial a uma venda que não era crediário
//   - Editar as parcelas de crediário existente (mantém IDs para
//     preservar histórico de pagas)
//
// Regras do backend (RPC editar_pagamento_venda) que o modal respeita:
//   - Máx 1 pagamento com forma='crediario' por venda
//   - Soma dos pagamentos == vendas.valor_liquido
//   - Não é permitido remover completamente o crediário de uma venda
//     que já era crediário (bloqueio no botão "remover")
//   - Se linha=crediario, soma das parcelas == valor da linha

import { useState, useEffect, useMemo } from 'react';
import { supabase } from '../../lib/supabase';
import {
  hojeISO,
  gerarParcelas,
  parseValorDigitado,
  valorParaStr,
  sanitizeValor,
  formatBRL,
  formatDataCurta,
  FREQ_LABEL,
  type FrequenciaCrediario,
} from '../../lib/crediario';

// --- Tipos ---
type FormaSimples = 'pix' | 'dinheiro' | 'debito';
type FormaTodas = FormaSimples | 'credito' | 'crediario';

type ParcelaEdit = {
  id: string | null; // uuid existente (mantida) ou null (nova)
  numero: number;
  valorStr: string;
  data_vencimento: string;
  pago: boolean;
  data_pagamento: string | null;
};

type LinhaSimples = { key: string; forma: FormaSimples; valorStr: string };
type LinhaCredito = { key: string; forma: 'credito'; valorStr: string; parcelas: number };
type LinhaCrediario = {
  key: string;
  forma: 'crediario';
  valorStr: string;
  crediario: {
    frequencia: FrequenciaCrediario;
    primeiraData: string;
    numParcelas: number;
    parcelas: ParcelaEdit[];
    tinhaPagaOriginal: boolean; // trava contra redistribuir automaticamente
  };
};
type Linha = LinhaSimples | LinhaCredito | LinhaCrediario;

type VendaMin = {
  id: string;
  codigo_venda: number;
  valor_liquido: number;
  nome_cliente: string | null;
  forma_pagamento: string;
};

const FORMA_LABEL: Record<FormaTodas, string> = {
  pix: 'PIX',
  dinheiro: 'Dinheiro',
  debito: 'Débito',
  credito: 'Crédito',
  crediario: 'Crediário',
};

const FORMA_COR: Record<FormaTodas, string> = {
  pix: 'emerald',
  dinheiro: 'yellow',
  debito: 'sky',
  credito: 'blue',
  crediario: 'violet',
};

let _keyCounter = 0;
const novoKey = () => `l-${Date.now()}-${++_keyCounter}`;

export default function EditarPagamentoModal({
  venda,
  onClose,
  onSaved,
}: {
  venda: VendaMin;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [carregando, setCarregando] = useState(true);
  const [salvando, setSalvando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [linhas, setLinhas] = useState<Linha[]>([]);
  const [tinhaCrediarioOriginal, setTinhaCrediarioOriginal] = useState(false);

  // ---- Fetch inicial ----
  useEffect(() => {
    let cancelado = false;
    (async () => {
      setCarregando(true);
      setErro(null);
      const [pgtoRes, parcRes] = await Promise.all([
        supabase
          .from('venda_pagamentos')
          .select('id, forma, valor, parcelas, crediario_frequencia, ordem')
          .eq('venda_id', venda.id)
          .order('ordem'),
        supabase
          .from('crediario_parcelas')
          .select('id, numero, valor, data_vencimento, pago, data_pagamento, pagamento_id')
          .eq('venda_id', venda.id)
          .order('numero'),
      ]);

      if (cancelado) return;

      if (pgtoRes.error) {
        setErro('Erro ao carregar pagamentos: ' + pgtoRes.error.message);
        setCarregando(false);
        return;
      }

      const pgts = pgtoRes.data ?? [];
      const parcs = parcRes.data ?? [];

      const linhasIni: Linha[] = pgts.map((p: any) => {
        if (p.forma === 'crediario') {
          const minhasParcs = parcs
            .filter((par: any) => par.pagamento_id === p.id)
            .sort((a: any, b: any) => a.numero - b.numero);
          const tinhaPaga = minhasParcs.some((par: any) => par.pago);
          return {
            key: novoKey(),
            forma: 'crediario',
            valorStr: valorParaStr(Number(p.valor)),
            crediario: {
              frequencia: (p.crediario_frequencia ?? 'quinzenal') as FrequenciaCrediario,
              primeiraData: minhasParcs[0]?.data_vencimento ?? hojeISO(),
              numParcelas: minhasParcs.length || 1,
              parcelas: minhasParcs.map((par: any) => ({
                id: par.id,
                numero: par.numero,
                valorStr: valorParaStr(Number(par.valor)),
                data_vencimento: par.data_vencimento,
                pago: par.pago,
                data_pagamento: par.data_pagamento,
              })),
              tinhaPagaOriginal: tinhaPaga,
            },
          } as LinhaCrediario;
        }
        if (p.forma === 'credito') {
          return {
            key: novoKey(),
            forma: 'credito',
            valorStr: valorParaStr(Number(p.valor)),
            parcelas: p.parcelas || 1,
          } as LinhaCredito;
        }
        return {
          key: novoKey(),
          forma: p.forma as FormaSimples,
          valorStr: valorParaStr(Number(p.valor)),
        } as LinhaSimples;
      });

      // Fallback defensivo: se por algum motivo não veio pagamento,
      // começa com 1 linha em dinheiro pelo total.
      if (linhasIni.length === 0) {
        linhasIni.push({
          key: novoKey(),
          forma: 'dinheiro',
          valorStr: valorParaStr(venda.valor_liquido || 0),
        } as LinhaSimples);
      }

      setLinhas(linhasIni);
      setTinhaCrediarioOriginal(linhasIni.some((l) => l.forma === 'crediario'));
      setCarregando(false);
    })();
    return () => {
      cancelado = true;
    };
  }, [venda.id, venda.valor_liquido]);

  // ---- Cálculos ----
  const valorTotalCents = Math.round((venda.valor_liquido || 0) * 100);
  const somaCents = linhas.reduce(
    (s, l) => s + Math.round(parseValorDigitado(l.valorStr) * 100),
    0
  );
  const diffCents = somaCents - valorTotalCents;
  const somaBate = diffCents === 0 && linhas.length > 0;
  const temCrediarioAgora = linhas.some((l) => l.forma === 'crediario');
  const naoPodeAdicionarCrediario = temCrediarioAgora;

  // Se venda ORIGINAL era crediário, o botão "remover" da linha crediário fica bloqueado.
  const linhaCrediario = linhas.find((l) => l.forma === 'crediario') as LinhaCrediario | undefined;

  // Validações
  const validacao = useMemo(() => {
    if (linhas.length === 0) return { ok: false, msg: 'Adicione ao menos uma forma de pagamento.' };

    for (const l of linhas) {
      const v = parseValorDigitado(l.valorStr);
      if (v <= 0) return { ok: false, msg: `Valor de ${FORMA_LABEL[l.forma]} deve ser maior que zero.` };
    }

    if (!somaBate) {
      return {
        ok: false,
        msg:
          diffCents > 0
            ? `Soma passou ${formatBRL(diffCents / 100)} do total.`
            : `Faltam ${formatBRL(-diffCents / 100)} para bater o total.`,
      };
    }

    if (linhas.filter((l) => l.forma === 'crediario').length > 1) {
      return { ok: false, msg: 'Só é permitido 1 pagamento em crediário por venda.' };
    }

    if (linhaCrediario) {
      const somaParcCents = linhaCrediario.crediario.parcelas.reduce(
        (s, p) => s + Math.round(parseValorDigitado(p.valorStr) * 100),
        0
      );
      const valLinhaCents = Math.round(parseValorDigitado(linhaCrediario.valorStr) * 100);
      if (linhaCrediario.crediario.parcelas.length === 0) {
        return { ok: false, msg: 'Crediário precisa de ao menos 1 parcela.' };
      }
      if (somaParcCents !== valLinhaCents) {
        return {
          ok: false,
          msg: `Parcelas do crediário somam ${formatBRL(somaParcCents / 100)}, precisam somar ${formatBRL(valLinhaCents / 100)}.`,
        };
      }
      if (linhaCrediario.crediario.parcelas.some((p) => parseValorDigitado(p.valorStr) <= 0)) {
        return { ok: false, msg: 'Todas as parcelas do crediário precisam ter valor > 0.' };
      }
    }

    if (tinhaCrediarioOriginal && !temCrediarioAgora) {
      return {
        ok: false,
        msg: 'Não é permitido remover o crediário desta venda (regra atual).',
      };
    }

    return { ok: true, msg: '' };
  }, [linhas, somaBate, diffCents, linhaCrediario, tinhaCrediarioOriginal, temCrediarioAgora]);

  // ---- Handlers ----
  function adicionarLinha(forma: FormaTodas) {
    if (forma === 'crediario' && naoPodeAdicionarCrediario) return;
    setLinhas((prev) => {
      // Sugestão de valor: sobra que falta bater o total
      const faltaCents = Math.max(0, valorTotalCents - somaCents);
      const valorSug = faltaCents > 0 ? valorParaStr(faltaCents / 100) : '0,00';
      if (forma === 'crediario') {
        return [
          ...prev,
          {
            key: novoKey(),
            forma: 'crediario',
            valorStr: valorSug,
            crediario: {
              frequencia: 'quinzenal',
              primeiraData: hojeISO(),
              numParcelas: 4,
              parcelas: gerarParcelas(faltaCents / 100, 4, hojeISO(), 'quinzenal').map((g) => ({
                id: null,
                numero: g.numero,
                valorStr: g.valorStr,
                data_vencimento: g.data_vencimento,
                pago: false,
                data_pagamento: null,
              })),
              tinhaPagaOriginal: false,
            },
          } as LinhaCrediario,
        ];
      }
      if (forma === 'credito') {
        return [...prev, { key: novoKey(), forma: 'credito', valorStr: valorSug, parcelas: 1 } as LinhaCredito];
      }
      return [...prev, { key: novoKey(), forma, valorStr: valorSug } as LinhaSimples];
    });
  }

  function removerLinha(key: string) {
    setLinhas((prev) => prev.filter((l) => l.key !== key));
  }

  function atualizarValorLinha(key: string, novoValorStr: string) {
    const raw = sanitizeValor(novoValorStr);
    setLinhas((prev) =>
      prev.map((l) => (l.key === key ? ({ ...l, valorStr: raw } as Linha) : l))
    );
  }

  function atualizarParcelasCredito(key: string, parcelas: number) {
    setLinhas((prev) =>
      prev.map((l) =>
        l.key === key && l.forma === 'credito' ? ({ ...l, parcelas } as LinhaCredito) : l
      )
    );
  }

  function atualizarCrediarioParam(
    key: string,
    patch: Partial<LinhaCrediario['crediario']>
  ) {
    setLinhas((prev) =>
      prev.map((l) => {
        if (l.key !== key || l.forma !== 'crediario') return l;
        return { ...l, crediario: { ...l.crediario, ...patch } } as LinhaCrediario;
      })
    );
  }

  // Regera as parcelas do crediário a partir dos parâmetros atuais.
  // Preserva IDs de parcelas de mesmo número quando possível — assim
  // o RPC (que faz upsert por id) mantém o histórico de pagas.
  function redistribuirParcelasCred(key: string) {
    const linha = linhas.find((l) => l.key === key);
    if (!linha || linha.forma !== 'crediario') return;

    const cred = linha.crediario;
    if (cred.tinhaPagaOriginal) {
      const ok = confirm(
        'Esta venda tem parcelas de crediário já pagas. Redistribuir vai reescrever as parcelas e pode desmarcar os pagamentos. Continuar?'
      );
      if (!ok) return;
    }

    const valorLinha = parseValorDigitado(linha.valorStr);
    const geradas = gerarParcelas(valorLinha, cred.numParcelas, cred.primeiraData, cred.frequencia);
    const antigasPorNumero = new Map(cred.parcelas.map((p) => [p.numero, p]));

    const parcelasNovas: ParcelaEdit[] = geradas.map((g) => {
      const antiga = antigasPorNumero.get(g.numero);
      return {
        id: antiga?.id ?? null,
        numero: g.numero,
        valorStr: g.valorStr,
        data_vencimento: g.data_vencimento,
        pago: antiga?.pago ?? false,
        data_pagamento: antiga?.data_pagamento ?? null,
      };
    });

    atualizarCrediarioParam(key, { parcelas: parcelasNovas });
  }

  function atualizarParcelaCred(
    linhaKey: string,
    numero: number,
    patch: Partial<ParcelaEdit>
  ) {
    setLinhas((prev) =>
      prev.map((l) => {
        if (l.key !== linhaKey || l.forma !== 'crediario') return l;
        return {
          ...l,
          crediario: {
            ...l.crediario,
            parcelas: l.crediario.parcelas.map((p) =>
              p.numero === numero ? { ...p, ...patch } : p
            ),
          },
        } as LinhaCrediario;
      })
    );
  }

  // Joga a diferença faltante na última parcela do crediário.
  function restoNaUltimaParcela(linhaKey: string) {
    const l = linhas.find((x) => x.key === linhaKey);
    if (!l || l.forma !== 'crediario') return;
    const valLinhaCents = Math.round(parseValorDigitado(l.valorStr) * 100);
    const parc = l.crediario.parcelas;
    if (parc.length === 0) return;
    const somaOutrasCents = parc
      .slice(0, -1)
      .reduce((s, p) => s + Math.round(parseValorDigitado(p.valorStr) * 100), 0);
    const restoCents = Math.max(0, valLinhaCents - somaOutrasCents);
    atualizarCrediarioParam(linhaKey, {
      parcelas: parc.map((p, i) =>
        i === parc.length - 1 ? { ...p, valorStr: valorParaStr(restoCents / 100) } : p
      ),
    });
  }

  // ---- Salvar ----
  async function salvar() {
    if (!validacao.ok) return;
    setSalvando(true);
    setErro(null);
    try {
      const payload = linhas.map((l) => {
        const base: any = {
          forma: l.forma,
          valor: Math.round(parseValorDigitado(l.valorStr) * 100) / 100,
        };
        if (l.forma === 'credito') base.parcelas = l.parcelas;
        if (l.forma === 'crediario') {
          base.crediario_frequencia = l.crediario.frequencia;
          base.crediario_parcelas = l.crediario.parcelas.map((p) => ({
            id: p.id,
            numero: p.numero,
            valor: Math.round(parseValorDigitado(p.valorStr) * 100) / 100,
            data_vencimento: p.data_vencimento,
            pago: p.pago,
            data_pagamento: p.pago ? p.data_pagamento ?? hojeISO() : null,
          }));
        }
        return base;
      });

      const { error } = await supabase.rpc('editar_pagamento_venda', {
        p_venda_id: venda.id,
        p_pagamentos: payload,
      });
      if (error) throw new Error(error.message);
      onSaved();
      onClose();
    } catch (err: any) {
      setErro(err?.message || String(err));
    } finally {
      setSalvando(false);
    }
  }

  // ---- Render ----
  const formasParaAdicionar: FormaTodas[] = ['pix', 'dinheiro', 'debito', 'credito', 'crediario'];

  return (
    <div className="fixed inset-0 z-[60] bg-black/95 backdrop-blur-md flex items-center justify-center p-4 animate-in zoom-in-95 duration-200">
      <div className="bg-slate-900 w-full max-w-lg rounded-3xl border border-slate-700 shadow-2xl flex flex-col max-h-[92vh]">
        {/* CABEÇALHO */}
        <div className="p-5 border-b border-slate-800 shrink-0">
          <h3 className="text-lg font-black uppercase text-white tracking-tighter">
            Editar <span className="text-violet-400">Pagamento</span>
          </h3>
          <p className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mt-1">
            Venda #{venda.codigo_venda}
            {venda.nome_cliente?.trim() && <> • {venda.nome_cliente.trim()}</>}
            {' • '}
            {formatBRL(venda.valor_liquido || 0)}
          </p>
        </div>

        {/* CORPO */}
        <div className="p-5 space-y-4 overflow-y-auto flex-1">
          {carregando ? (
            <div className="text-center text-slate-500 py-8 font-bold uppercase text-xs tracking-widest">
              Carregando…
            </div>
          ) : (
            <>
              {/* Linhas de pagamento */}
              <div className="space-y-3">
                {linhas.map((l) => (
                  <LinhaPagamentoCard
                    key={l.key}
                    linha={l}
                    podeRemover={
                      // trava contra remover a linha crediário se venda original era crediário
                      !(l.forma === 'crediario' && tinhaCrediarioOriginal)
                    }
                    onValorChange={(v) => atualizarValorLinha(l.key, v)}
                    onParcelasCreditoChange={(n) => atualizarParcelasCredito(l.key, n)}
                    onCredParamChange={(patch) => atualizarCrediarioParam(l.key, patch)}
                    onCredParcelaChange={(num, patch) => atualizarParcelaCred(l.key, num, patch)}
                    onCredRedistribuir={() => redistribuirParcelasCred(l.key)}
                    onCredRestoUltima={() => restoNaUltimaParcela(l.key)}
                    onRemover={() => removerLinha(l.key)}
                  />
                ))}
              </div>

              {/* Botões para adicionar formas */}
              <div className="border border-dashed border-slate-800 rounded-xl p-3 space-y-2">
                <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">
                  + Adicionar forma
                </p>
                <div className="grid grid-cols-3 gap-2">
                  {formasParaAdicionar.map((f) => {
                    const bloqueado = f === 'crediario' && naoPodeAdicionarCrediario;
                    return (
                      <button
                        key={f}
                        onClick={() => adicionarLinha(f)}
                        disabled={bloqueado}
                        className={`py-2 rounded-lg text-[10px] font-black uppercase tracking-widest border transition ${
                          bloqueado
                            ? 'bg-slate-950 border-slate-900 text-slate-700 cursor-not-allowed'
                            : `bg-slate-950 border-slate-800 text-${FORMA_COR[f]}-400 hover:border-${FORMA_COR[f]}-700 active:scale-95`
                        }`}
                        title={bloqueado ? 'Já existe uma linha de crediário' : undefined}
                      >
                        + {FORMA_LABEL[f]}
                      </button>
                    );
                  })}
                </div>
              </div>

              {/* Barra de soma / total */}
              <div
                className={`rounded-xl border px-4 py-3 flex items-center justify-between ${
                  somaBate
                    ? 'border-emerald-900/40 bg-emerald-950/20'
                    : 'border-red-900/40 bg-red-950/20'
                }`}
              >
                <span
                  className={`text-[10px] font-black uppercase tracking-widest ${
                    somaBate ? 'text-emerald-400' : 'text-red-400'
                  }`}
                >
                  {somaBate ? '✓ Soma confere' : `Diferença: ${formatBRL(diffCents / 100)}`}
                </span>
                <span className="text-xs font-black text-white">
                  {formatBRL(somaCents / 100)} / {formatBRL(valorTotalCents / 100)}
                </span>
              </div>

              {/* Aviso de validação */}
              {!validacao.ok && !carregando && linhas.length > 0 && (
                <p className="text-[11px] text-amber-400 font-bold">{validacao.msg}</p>
              )}

              {/* Erro do servidor */}
              {erro && (
                <div className="rounded-xl border border-red-900/50 bg-red-950/30 px-4 py-3">
                  <p className="text-[11px] text-red-300 font-bold whitespace-pre-wrap">{erro}</p>
                </div>
              )}
            </>
          )}
        </div>

        {/* RODAPÉ */}
        <div className="p-4 border-t border-slate-800 grid grid-cols-2 gap-3 shrink-0">
          <button
            onClick={onClose}
            disabled={salvando}
            className="bg-slate-800 hover:bg-slate-700 text-white py-4 rounded-xl font-bold uppercase text-xs tracking-widest transition disabled:opacity-50"
          >
            Voltar
          </button>
          <button
            onClick={salvar}
            disabled={salvando || carregando || !validacao.ok}
            className="bg-violet-600 hover:bg-violet-500 text-white py-4 rounded-xl font-black uppercase text-xs tracking-widest transition shadow-lg disabled:opacity-50"
          >
            {salvando ? 'Salvando…' : 'Salvar'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ============================================================================
// Subcomponente: card de uma linha de pagamento
// ============================================================================

function LinhaPagamentoCard({
  linha,
  podeRemover,
  onValorChange,
  onParcelasCreditoChange,
  onCredParamChange,
  onCredParcelaChange,
  onCredRedistribuir,
  onCredRestoUltima,
  onRemover,
}: {
  linha: Linha;
  podeRemover: boolean;
  onValorChange: (v: string) => void;
  onParcelasCreditoChange: (n: number) => void;
  onCredParamChange: (patch: Partial<LinhaCrediario['crediario']>) => void;
  onCredParcelaChange: (numero: number, patch: Partial<ParcelaEdit>) => void;
  onCredRedistribuir: () => void;
  onCredRestoUltima: () => void;
  onRemover: () => void;
}) {
  const cor = FORMA_COR[linha.forma];

  return (
    <div
      className={`rounded-xl border-2 border-${cor}-900/40 bg-${cor}-950/10 overflow-hidden`}
    >
      {/* Header da linha */}
      <div className="px-3 py-2 flex items-center gap-2 border-b border-slate-800/50">
        <span
          className={`text-[10px] font-black uppercase tracking-widest px-2 py-1 rounded bg-${cor}-500/20 text-${cor}-300`}
        >
          {FORMA_LABEL[linha.forma]}
        </span>
        <div className="flex items-center gap-1 flex-1 justify-end bg-slate-950/60 border border-slate-800 rounded-lg px-2">
          <span className="text-[10px] text-slate-500 font-bold">R$</span>
          <input
            type="text"
            inputMode="decimal"
            autoComplete="off"
            className="bg-transparent w-24 py-2 text-sm font-bold text-white outline-none text-right"
            value={linha.valorStr}
            onChange={(e) => onValorChange(e.target.value)}
          />
        </div>
        <button
          onClick={onRemover}
          disabled={!podeRemover}
          title={podeRemover ? 'Remover forma' : 'Não é permitido remover o crediário desta venda'}
          className={`shrink-0 w-8 h-8 rounded-lg text-sm font-black transition ${
            podeRemover
              ? 'bg-red-950/40 text-red-400 hover:bg-red-900/40 active:scale-95'
              : 'bg-slate-900 text-slate-700 cursor-not-allowed'
          }`}
        >
          ×
        </button>
      </div>

      {/* Corpo condicional */}
      {linha.forma === 'credito' && (
        <div className="p-3 flex items-center gap-3">
          <label className="text-[10px] font-black uppercase tracking-widest text-slate-500">
            Parcelas do cartão
          </label>
          <select
            value={linha.parcelas}
            onChange={(e) => onParcelasCreditoChange(parseInt(e.target.value))}
            className="bg-slate-950 border-2 border-slate-800 px-3 py-2 rounded-lg text-white font-bold outline-none focus:border-blue-500 text-sm"
          >
            {Array.from({ length: 12 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {n}x
              </option>
            ))}
          </select>
        </div>
      )}

      {linha.forma === 'crediario' && (
        <CrediarioSection
          linha={linha}
          onParamChange={onCredParamChange}
          onParcelaChange={onCredParcelaChange}
          onRedistribuir={onCredRedistribuir}
          onRestoUltima={onCredRestoUltima}
        />
      )}
    </div>
  );
}

// ============================================================================
// Subcomponente: seção completa do crediário dentro de uma linha
// ============================================================================

function CrediarioSection({
  linha,
  onParamChange,
  onParcelaChange,
  onRedistribuir,
  onRestoUltima,
}: {
  linha: LinhaCrediario;
  onParamChange: (patch: Partial<LinhaCrediario['crediario']>) => void;
  onParcelaChange: (numero: number, patch: Partial<ParcelaEdit>) => void;
  onRedistribuir: () => void;
  onRestoUltima: () => void;
}) {
  const cred = linha.crediario;
  const valLinhaCents = Math.round(parseValorDigitado(linha.valorStr) * 100);
  const somaParcCents = cred.parcelas.reduce(
    (s, p) => s + Math.round(parseValorDigitado(p.valorStr) * 100),
    0
  );
  const somaOk = valLinhaCents > 0 && somaParcCents === valLinhaCents;

  return (
    <div className="p-3 space-y-3 bg-slate-950/40">
      {/* Frequência */}
      <div className="grid grid-cols-3 gap-2">
        {(['semanal', 'quinzenal', 'mensal'] as FrequenciaCrediario[]).map((fq) => (
          <button
            key={fq}
            onClick={() => onParamChange({ frequencia: fq })}
            className={`py-2 rounded-lg text-[10px] font-black uppercase tracking-widest border transition ${
              cred.frequencia === fq
                ? 'bg-violet-600 border-violet-500 text-white'
                : 'bg-slate-950 border-slate-800 text-slate-400 hover:border-slate-600'
            }`}
          >
            {FREQ_LABEL[fq]}
          </button>
        ))}
      </div>

      {/* Parcelas + primeira data + redistribuir */}
      <div className="grid grid-cols-[1fr_1fr_auto] gap-2 items-end">
        <div className="space-y-1">
          <label className="text-[9px] font-black text-slate-500 uppercase tracking-widest">
            Nº parcelas
          </label>
          <select
            value={cred.numParcelas}
            onChange={(e) => onParamChange({ numParcelas: parseInt(e.target.value) })}
            className="w-full bg-slate-950 border-2 border-slate-800 px-2 py-2 rounded-lg text-white font-bold outline-none focus:border-violet-500 text-sm"
          >
            {Array.from({ length: 24 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {n}x
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <label className="text-[9px] font-black text-slate-500 uppercase tracking-widest">
            1ª parcela
          </label>
          <input
            type="date"
            value={cred.primeiraData}
            onChange={(e) => e.target.value && onParamChange({ primeiraData: e.target.value })}
            className="w-full bg-slate-950 border-2 border-slate-800 px-2 py-2 rounded-lg text-white font-bold outline-none focus:border-violet-500 text-sm"
          />
        </div>
        <button
          onClick={onRedistribuir}
          className="h-[38px] px-3 rounded-lg text-[10px] font-black uppercase tracking-widest text-violet-400 bg-violet-950/30 border border-violet-900/50 hover:bg-violet-900/40 active:scale-95"
          title="Gera N parcelas iguais a partir dos parâmetros acima"
        >
          ↺ Gerar
        </button>
      </div>

      {cred.tinhaPagaOriginal && (
        <p className="text-[10px] text-amber-400 font-bold leading-relaxed">
          ⚠ Esta venda tem parcelas já pagas. Ao redistribuir você pode perdê-las.
        </p>
      )}

      {/* Lista de parcelas */}
      {cred.parcelas.length > 0 && (
        <div className="bg-slate-950 border border-slate-800 rounded-lg overflow-hidden">
          <div className="max-h-60 overflow-y-auto divide-y divide-slate-800/60">
            {cred.parcelas.map((p, idx) => (
              <div key={p.numero} className="flex items-center gap-2 px-2 py-2">
                <label className="flex items-center gap-1 shrink-0 cursor-pointer" title="Parcela paga">
                  <input
                    type="checkbox"
                    checked={p.pago}
                    onChange={(e) => onParcelaChange(p.numero, { pago: e.target.checked })}
                    className="w-3.5 h-3.5 accent-emerald-500"
                  />
                  <span
                    className={`text-[8px] font-black uppercase ${
                      p.pago ? 'text-emerald-400' : 'text-slate-600'
                    }`}
                  >
                    paga
                  </span>
                </label>
                <span className="w-6 text-[10px] font-black text-slate-400 shrink-0">
                  {p.numero}ª
                </span>
                <input
                  type="date"
                  value={p.data_vencimento}
                  onChange={(e) =>
                    e.target.value && onParcelaChange(p.numero, { data_vencimento: e.target.value })
                  }
                  className="flex-1 min-w-0 bg-slate-900 border border-slate-700 rounded px-1 py-1 text-[10px] font-mono text-slate-300 outline-none focus:border-violet-500"
                />
                <div className="flex items-center gap-1 bg-slate-900 border border-slate-700 rounded px-2 shrink-0">
                  <span className="text-[9px] text-slate-500 font-bold">R$</span>
                  <input
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    className="bg-transparent w-16 py-1 text-xs font-bold text-white outline-none text-right"
                    value={p.valorStr}
                    onChange={(e) =>
                      onParcelaChange(p.numero, { valorStr: sanitizeValor(e.target.value) })
                    }
                  />
                </div>
                {idx === cred.parcelas.length - 1 && cred.parcelas.length > 1 && (
                  <button
                    onClick={onRestoUltima}
                    title="Colocar o restante nesta parcela"
                    className="shrink-0 text-[8px] font-black uppercase tracking-widest text-violet-300 bg-violet-950/40 border border-violet-900/50 hover:bg-violet-900/40 px-1.5 py-1 rounded active:scale-95"
                  >
                    resto
                  </button>
                )}
              </div>
            ))}
          </div>
          <div
            className={`px-3 py-1.5 border-t text-[9px] font-black uppercase tracking-widest flex items-center justify-between ${
              somaOk
                ? 'border-emerald-900/40 bg-emerald-950/30 text-emerald-400'
                : 'border-red-900/40 bg-red-950/30 text-red-400'
            }`}
          >
            <span>{somaOk ? '✓ Parcelas OK' : 'Parcelas ≠ valor'}</span>
            <span className="text-white">
              {formatBRL(somaParcCents / 100)} / {formatBRL(valLinhaCents / 100)}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}