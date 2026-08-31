/**
 * Carrinho persistente local (localStorage).
 *
 * A tela /venda mantém um "rascunho local" do carrinho em montagem para
 * que a usuária não perca o trabalho ao sair/voltar da página, fechar o
 * PWA, ou dar refresh. A tela inicial também escreve nesse mesmo
 * rascunho via swipe (adicionar direto do card do estoque).
 *
 * Esta lib é o único ponto que conhece o formato armazenado —
 * qualquer mudança de shape passa a ser feita bumping a versão da chave.
 */

export const RASCUNHO_LOCAL_KEY = 'upfitness:venda:rascunho-local:v1';

export type ItemCarrinho = {
  tempId: string;
  produto_id: string;
  estoque_id: string;
  descricao: string;
  cor: string;
  tamanho: string;
  preco: number;
  custo: number;
  qtd: number;
  maxEstoque: number;
  foto: string | null;
  ean: string | null;
};

export type RascunhoLocal = {
  carrinho?: ItemCarrinho[];
  draftAtualId?: string | null;
  draftAtualTitulo?: string;
  savedAt?: number;
};

/** Lê o rascunho salvo. Retorna null se não existe, está corrompido, ou
 *  se localStorage está indisponível (modo privado, SSR). */
export function lerRascunhoLocal(): RascunhoLocal | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(RASCUNHO_LOCAL_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as RascunhoLocal;
  } catch {
    return null;
  }
}

/** Salva o rascunho. Se estiver vazio (carrinho vazio e sem draft
 *  vinculado), remove a chave em vez de gravar. Retorna true em
 *  sucesso, false em falha silenciosa (quota, modo privado). */
export function salvarRascunhoLocal(dados: RascunhoLocal): boolean {
  if (typeof window === 'undefined') return false;
  try {
    const carrinhoVazio = !dados.carrinho || dados.carrinho.length === 0;
    const semDraft = !dados.draftAtualId;
    if (carrinhoVazio && semDraft) {
      window.localStorage.removeItem(RASCUNHO_LOCAL_KEY);
      return true;
    }
    const payload: RascunhoLocal = { ...dados, savedAt: Date.now() };
    window.localStorage.setItem(RASCUNHO_LOCAL_KEY, JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}

export type ResultadoAdicionar =
  | { ok: true; novaQtd: number; totalItens: number; jaExistia: boolean }
  | { ok: false; motivo: 'sem-estoque' | 'estoque-esgotado' | 'erro'; mensagem: string };

/**
 * Adiciona (ou incrementa em 1) um item ao rascunho local.
 * Se já existe uma linha com o mesmo estoque_id, incrementa qtd.
 * Respeita maxEstoque. Não abre modal nem toca em UI — a UI decide o
 * que mostrar a partir do ResultadoAdicionar.
 */
export function adicionarAoRascunhoLocal(
  novoItem: Omit<ItemCarrinho, 'tempId' | 'qtd'>,
): ResultadoAdicionar {
  if (novoItem.maxEstoque <= 0) {
    return { ok: false, motivo: 'sem-estoque', mensagem: 'Sem estoque para este item.' };
  }
  try {
    const atual = lerRascunhoLocal();
    const carrinho = atual?.carrinho ?? [];
    const existente = carrinho.find((it) => it.estoque_id === novoItem.estoque_id);

    let carrinhoNovo: ItemCarrinho[];
    let novaQtd: number;
    let jaExistia: boolean;

    if (existente) {
      novaQtd = existente.qtd + 1;
      if (novaQtd > novoItem.maxEstoque) {
        return {
          ok: false,
          motivo: 'estoque-esgotado',
          mensagem: `Você já tem ${existente.qtd} no carrinho e só há ${novoItem.maxEstoque} em estoque.`,
        };
      }
      jaExistia = true;
      carrinhoNovo = carrinho.map((it) =>
        it.estoque_id === novoItem.estoque_id
          ? { ...it, qtd: novaQtd, maxEstoque: novoItem.maxEstoque }
          : it,
      );
    } else {
      novaQtd = 1;
      jaExistia = false;
      carrinhoNovo = [
        ...carrinho,
        { ...novoItem, tempId: Math.random().toString(36).slice(2), qtd: 1 },
      ];
    }

    const totalItens = carrinhoNovo.reduce((acc, it) => acc + it.qtd, 0);
    const gravou = salvarRascunhoLocal({ ...atual, carrinho: carrinhoNovo });
    if (!gravou) {
      return {
        ok: false,
        motivo: 'erro',
        mensagem: 'Não foi possível salvar o carrinho local (armazenamento cheio ou modo privado).',
      };
    }
    return { ok: true, novaQtd, totalItens, jaExistia };
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Erro desconhecido';
    return { ok: false, motivo: 'erro', mensagem: msg };
  }
}