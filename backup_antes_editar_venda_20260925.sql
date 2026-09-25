--
-- PostgreSQL database dump
--

\restrict 8oSzjiWHr0iueflro1krWzHr6iYroqzPjujDNM5VrctnFjABXpUgXrl9V0gIoa4

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: cancelar_venda(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancelar_venda(p_venda_id uuid, p_estornar_estoque boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- Autorização explícita (DEFINER ignora RLS, então checamos aqui)
  if not is_sales() then
    raise exception 'Acesso negado: requer role de vendas.';
  end if;
 
  if not exists (select 1 from vendas where id = p_venda_id) then
    raise exception 'Venda não encontrada.';
  end if;
 
  -- Estorno (cancelamento devolve ao estoque; exclusão pura não)
  if p_estornar_estoque then
    update estoque e
       set quantidade = e.quantidade + i.quantidade
      from itens_venda i
     where i.venda_id = p_venda_id
       and e.id = i.estoque_id;
  end if;
 
  -- Apaga a venda (itens_venda deve ter FK ON DELETE CASCADE;
  -- se não tiver, descomente a linha abaixo)
  -- delete from itens_venda where venda_id = p_venda_id;
  delete from vendas where id = p_venda_id;
end;
$$;


--
-- Name: confirmar_pagamento_parcela(uuid, numeric, date, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirmar_pagamento_parcela(p_parcela_id uuid, p_valor_pago numeric, p_data_pagamento date, p_redistribuicao jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_venda_id       uuid;
  v_saldo_antes    numeric;
  v_saldo_depois   numeric;
  v_soma_redis     numeric;
  v_total_linhas   int;
  v_max_numero     int;
  v_existentes     uuid[];
  v_enviados       uuid[];
  v_pago_cents     int;
begin
  if not is_sales() then
    raise exception 'Sem permissão para confirmar pagamentos.';
  end if;
 
  if p_valor_pago is null or round(p_valor_pago, 2) < 0 then
    raise exception 'Valor pago inválido.';
  end if;
 
  if p_redistribuicao is null or jsonb_typeof(p_redistribuicao) <> 'array' then
    raise exception 'Redistribuição inválida (esperado array JSON).';
  end if;
 
  -- Trava a parcela alvo e obtém a venda
  select venda_id into v_venda_id
  from crediario_parcelas
  where id = p_parcela_id
  for update;
 
  if not found then
    raise exception 'Parcela não encontrada.';
  end if;
 
  -- Trava todas as parcelas da venda para evitar corrida com outra baixa
  perform 1 from crediario_parcelas where venda_id = v_venda_id for update;
 
  -- A parcela alvo precisa estar pendente
  if exists (select 1 from crediario_parcelas where id = p_parcela_id and pago = true) then
    raise exception 'Esta parcela já está paga.';
  end if;
 
  -- Saldo pendente antes (todas as pendentes, incluindo a que será paga)
  select coalesce(sum(round(valor, 2)), 0) into v_saldo_antes
  from crediario_parcelas
  where venda_id = v_venda_id and pago = false;
 
  v_pago_cents := round(p_valor_pago * 100);
  v_saldo_depois := round(v_saldo_antes, 2) - round(p_valor_pago, 2);
 
  if round(v_saldo_depois, 2) < 0 then
    raise exception 'Valor pago (R$ %) maior que o saldo pendente (R$ %).',
      to_char(p_valor_pago, 'FM999G999D00'), to_char(v_saldo_antes, 'FM999G999D00');
  end if;
 
  -- Soma e validações do array de redistribuição
  select coalesce(sum(round((e->>'valor')::numeric, 2)), 0) into v_soma_redis
  from jsonb_array_elements(p_redistribuicao) e;
 
  if round(v_soma_redis, 2) <> round(v_saldo_depois, 2) then
    raise exception 'Soma das parcelas restantes (R$ %) difere do saldo a distribuir (R$ %).',
      to_char(v_soma_redis, 'FM999G999D00'), to_char(v_saldo_depois, 'FM999G999D00');
  end if;
 
  if exists (
    select 1 from jsonb_array_elements(p_redistribuicao) e
    where (e->>'valor') is null or round((e->>'valor')::numeric, 2) < 0
  ) then
    raise exception 'Há parcela com valor inválido na redistribuição.';
  end if;
 
  -- Conjunto de pendentes existentes da venda, exceto a que será paga
  select array_agg(id) into v_existentes
  from crediario_parcelas
  where venda_id = v_venda_id and pago = false and id <> p_parcela_id;
  v_existentes := coalesce(v_existentes, '{}');
 
  -- Ids não-nulos enviados no array (devem ser subconjunto das pendentes)
  select array_agg((e->>'id')::uuid) into v_enviados
  from jsonb_array_elements(p_redistribuicao) e
  where e->>'id' is not null;
  v_enviados := coalesce(v_enviados, '{}');
 
  -- Todo id enviado precisa ser uma pendente existente desta venda
  if exists (
    select 1 from unnest(v_enviados) x
    where not (x = any (v_existentes))
  ) then
    raise exception 'Redistribuição referencia parcela que não é pendente desta venda.';
  end if;
 
  -- A) Marca a parcela alvo como paga, com o valor efetivamente recebido
  update crediario_parcelas
     set pago = true,
         valor = round(p_valor_pago, 2),
         data_pagamento = coalesce(p_data_pagamento, current_date)
   where id = p_parcela_id;
 
  -- B) Exclui as pendentes que saíram do array (não enviadas)
  delete from crediario_parcelas
   where venda_id = v_venda_id
     and pago = false
     and id <> p_parcela_id
     and not (id = any (v_enviados));
 
  -- C) UPDATE das pendentes mantidas (id não-nulo)
  update crediario_parcelas cp
     set valor = round((e->>'valor')::numeric, 2),
         data_vencimento = (e->>'data_vencimento')::date
  from jsonb_array_elements(p_redistribuicao) e
  where e->>'id' is not null
    and cp.id = (e->>'id')::uuid
    and cp.venda_id = v_venda_id;
 
  -- D) INSERT das novas (id nulo). numero: usa o informado se livre,
  --    senão sequencia a partir do max atual.
  select coalesce(max(numero), 0) into v_max_numero
  from crediario_parcelas where venda_id = v_venda_id;
 
  insert into crediario_parcelas (venda_id, numero, valor, data_vencimento, pago, data_pagamento)
  select
    v_venda_id,
    v_max_numero + row_number() over (order by ord),
    valor_novo,
    venc_novo,
    false,
    null
  from (
    select
      round((elem->>'valor')::numeric, 2) as valor_novo,
      (elem->>'data_vencimento')::date    as venc_novo,
      ord                                  as ord
    from jsonb_array_elements(p_redistribuicao) with ordinality as t(elem, ord)
    where elem->>'id' is null
  ) novas;
 
  -- E) Recalcula vendas.parcelas = total de linhas da venda
  select count(*) into v_total_linhas
  from crediario_parcelas where venda_id = v_venda_id;
 
  update vendas set parcelas = v_total_linhas where id = v_venda_id;
end;
$_$;


--
-- Name: converter_venda_crediario(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.converter_venda_crediario(p_venda_id uuid, p_frequencia text, p_parcelas jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_valor        numeric;
  v_soma         numeric;
  v_qtd          int;
  v_pagamento_id uuid;
  v_qtd_pgtos    int;
BEGIN
  IF NOT is_sales() THEN
    RAISE EXCEPTION 'Sem permissão para converter vendas.';
  END IF;
 
  IF p_frequencia NOT IN ('semanal', 'quinzenal', 'mensal') THEN
    RAISE EXCEPTION 'Frequência inválida: %', p_frequencia;
  END IF;
 
  IF p_parcelas IS NULL OR jsonb_typeof(p_parcelas) <> 'array' THEN
    RAISE EXCEPTION 'Parcelas inválidas (esperado array JSON).';
  END IF;
 
  SELECT valor_liquido INTO v_valor
  FROM vendas WHERE id = p_venda_id
  FOR UPDATE;
 
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venda não encontrada.';
  END IF;
 
  IF EXISTS (SELECT 1 FROM crediario_parcelas WHERE venda_id = p_venda_id) THEN
    RAISE EXCEPTION 'Esta venda já possui parcelas de crediário.';
  END IF;
 
  -- Esta função só suporta converter vendas SIMPLES (1 pagamento) para
  -- crediário. Para vendas com split, use editar_pagamento_venda.
  SELECT count(*) INTO v_qtd_pgtos
  FROM venda_pagamentos WHERE venda_id = p_venda_id;
 
  IF v_qtd_pgtos <> 1 THEN
    RAISE EXCEPTION 'converter_venda_crediario só suporta vendas com 1 pagamento. Use editar_pagamento_venda para split.';
  END IF;
 
  SELECT count(*), coalesce(sum(round((e->>'valor')::numeric, 2)), 0)
    INTO v_qtd, v_soma
  FROM jsonb_array_elements(p_parcelas) e;
 
  IF v_qtd < 1 THEN
    RAISE EXCEPTION 'Nenhuma parcela informada.';
  END IF;
 
  IF round(v_soma, 2) <> round(v_valor, 2) THEN
    RAISE EXCEPTION 'Soma das parcelas (R$ %) difere do valor da venda (R$ %).',
      to_char(v_soma, 'FM999G999D00'), to_char(v_valor, 'FM999G999D00');
  END IF;
 
  -- NOVO: atualiza o venda_pagamento existente (era pix/dinheiro/etc,
  -- vira crediario) em vez de criar outro.
  UPDATE venda_pagamentos
     SET forma = 'crediario',
         parcelas = 1,
         crediario_frequencia = p_frequencia
   WHERE venda_id = p_venda_id
  RETURNING id INTO v_pagamento_id;
 
  INSERT INTO crediario_parcelas
    (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
  SELECT
    p_venda_id,
    v_pagamento_id,
    (e->>'numero')::int,
    round((e->>'valor')::numeric, 2),
    (e->>'data_vencimento')::date,
    coalesce((e->>'pago')::boolean, false),
    CASE WHEN coalesce((e->>'pago')::boolean, false)
         THEN coalesce((e->>'data_pagamento')::date, current_date)
         ELSE NULL END
  FROM jsonb_array_elements(p_parcelas) e;
 
  UPDATE vendas
     SET forma_pagamento      = 'crediario',
         parcelas             = v_qtd,
         crediario_frequencia = p_frequencia
   WHERE id = p_venda_id;
END;
$_$;


--
-- Name: criar_venda_com_pagamentos(numeric, numeric, numeric, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.criar_venda_com_pagamentos(p_valor_bruto numeric, p_valor_liquido numeric, p_desconto numeric, p_itens jsonb, p_nome_cliente text, p_pagamentos jsonb) RETURNS uuid
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_venda_id         uuid;
  v_soma_pagamentos  numeric;
  v_qtd_pagamentos   int;
  v_qtd_crediarios   int;
  v_qtd_parc_cred    int;
  v_soma_parc_cred   numeric;
  v_pgto_cred_id     uuid;
  v_valor_cred       numeric;
  v_freq_cred        text;
  v_parcelas_cred    jsonb;
  v_forma_final      text;
  v_parcelas_final   int;
  v_freq_final       text;
  v_item             jsonb;
  v_produto_item     jsonb;
BEGIN
  -- ---- Validação básica ----
  IF p_pagamentos IS NULL OR jsonb_typeof(p_pagamentos) <> 'array' THEN
    RAISE EXCEPTION 'Pagamentos inválidos (esperado array JSON).';
  END IF;
 
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' THEN
    RAISE EXCEPTION 'Itens inválidos (esperado array JSON).';
  END IF;
 
  IF jsonb_array_length(p_itens) < 1 THEN
    RAISE EXCEPTION 'Venda precisa de ao menos 1 item.';
  END IF;
 
  SELECT
    count(*),
    coalesce(sum(round((e->>'valor')::numeric, 2)), 0),
    count(*) FILTER (WHERE e->>'forma' = 'crediario')
  INTO v_qtd_pagamentos, v_soma_pagamentos, v_qtd_crediarios
  FROM jsonb_array_elements(p_pagamentos) e;
 
  IF v_qtd_pagamentos < 1 THEN
    RAISE EXCEPTION 'Informe ao menos um pagamento.';
  END IF;
 
  IF v_qtd_crediarios > 1 THEN
    RAISE EXCEPTION 'Só é permitido um pagamento por crediário por venda.';
  END IF;
 
  -- Regra do app: crediário exige nome de cliente (para cobrar depois).
  IF v_qtd_crediarios > 0 AND (p_nome_cliente IS NULL OR btrim(p_nome_cliente) = '') THEN
    RAISE EXCEPTION 'Crediário exige o nome do cliente.';
  END IF;
 
  -- Valida cada pagamento (mesma lógica do editar_pagamento_venda).
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_pagamentos)
  LOOP
    IF v_item->>'forma' IS NULL OR
       v_item->>'forma' NOT IN ('pix','dinheiro','debito','credito','crediario') THEN
      RAISE EXCEPTION 'Forma de pagamento inválida: %', v_item->>'forma';
    END IF;
 
    IF (v_item->>'valor') IS NULL OR round((v_item->>'valor')::numeric, 2) <= 0 THEN
      RAISE EXCEPTION 'Valor de pagamento inválido para forma %.', v_item->>'forma';
    END IF;
 
    IF v_item->>'forma' = 'credito' THEN
      IF (v_item->>'parcelas') IS NOT NULL AND (v_item->>'parcelas')::int < 1 THEN
        RAISE EXCEPTION 'Número de parcelas de crédito inválido.';
      END IF;
    ELSIF (v_item->>'parcelas') IS NOT NULL AND (v_item->>'parcelas')::int > 1 THEN
      RAISE EXCEPTION 'parcelas > 1 só é válido para forma=credito.';
    END IF;
 
    IF v_item->>'forma' = 'crediario' THEN
      IF v_item->>'crediario_frequencia' IS NULL OR
         v_item->>'crediario_frequencia' NOT IN ('semanal','quinzenal','mensal') THEN
        RAISE EXCEPTION 'Frequência de crediário inválida.';
      END IF;
 
      IF NOT (v_item ? 'crediario_parcelas') OR
         jsonb_typeof(v_item->'crediario_parcelas') <> 'array' THEN
        RAISE EXCEPTION 'crediario_parcelas obrigatório para forma=crediario (array).';
      END IF;
 
      SELECT count(*), coalesce(sum(round((e->>'valor')::numeric, 2)), 0)
        INTO v_qtd_parc_cred, v_soma_parc_cred
      FROM jsonb_array_elements(v_item->'crediario_parcelas') e;
 
      IF v_qtd_parc_cred < 1 THEN
        RAISE EXCEPTION 'Crediário exige ao menos uma parcela.';
      END IF;
 
      IF round(v_soma_parc_cred, 2) <> round((v_item->>'valor')::numeric, 2) THEN
        RAISE EXCEPTION 'Soma das parcelas do crediário (R$ %) difere do valor do pagamento crediário (R$ %).',
          to_char(v_soma_parc_cred, 'FM999G999D00'),
          to_char((v_item->>'valor')::numeric, 'FM999G999D00');
      END IF;
    END IF;
  END LOOP;
 
  -- Conservação: soma dos pagamentos == valor_liquido
  IF round(v_soma_pagamentos, 2) <> round(p_valor_liquido, 2) THEN
    RAISE EXCEPTION 'Soma dos pagamentos (R$ %) difere do valor final da venda (R$ %).',
      to_char(v_soma_pagamentos, 'FM999G999D00'),
      to_char(p_valor_liquido, 'FM999G999D00');
  END IF;
 
  -- ---- Deriva os campos legados de vendas ----
  IF v_qtd_pagamentos = 1 THEN
    SELECT p->>'forma',
           CASE WHEN p->>'forma' = 'credito'
                THEN coalesce((p->>'parcelas')::int, 1)
                ELSE 1
           END,
           CASE WHEN p->>'forma' = 'crediario'
                THEN p->>'crediario_frequencia'
                ELSE NULL
           END
      INTO v_forma_final, v_parcelas_final, v_freq_final
    FROM jsonb_array_elements(p_pagamentos) p LIMIT 1;
 
    -- Para crediário, vendas.parcelas legado guarda a QTD de parcelas
    -- (comportamento antigo preservado).
    IF v_forma_final = 'crediario' THEN
      SELECT count(*) INTO v_parcelas_final
      FROM jsonb_array_elements(p_pagamentos) p,
           jsonb_array_elements(p->'crediario_parcelas') pc
      WHERE p->>'forma' = 'crediario';
    END IF;
  ELSE
    v_forma_final := 'split';
    v_parcelas_final := 1;
    v_freq_final := NULL;
  END IF;
 
  -- ---- Cria a venda ----
  INSERT INTO vendas (
    valor_total, valor_liquido, desconto, forma_pagamento, parcelas,
    nome_cliente, crediario_frequencia
  )
  VALUES (
    p_valor_bruto,
    p_valor_liquido,
    p_desconto,
    v_forma_final,
    v_parcelas_final,
    CASE WHEN p_nome_cliente IS NULL OR btrim(p_nome_cliente) = ''
         THEN NULL
         ELSE btrim(p_nome_cliente)
    END,
    v_freq_final
  )
  RETURNING id INTO v_venda_id;
 
  -- ---- Itens + baixa estoque ----
  FOR v_produto_item IN SELECT * FROM jsonb_array_elements(p_itens)
  LOOP
    INSERT INTO itens_venda (
      venda_id, produto_id, estoque_id, descricao_completa, cor,
      quantidade, preco_unitario, subtotal
    ) VALUES (
      v_venda_id,
      (v_produto_item->>'produto_id')::uuid,
      (v_produto_item->>'estoque_id')::uuid,
      v_produto_item->>'descricao_completa',
      v_produto_item->>'cor',
      (v_produto_item->>'quantidade')::int,
      (v_produto_item->>'preco_unitario')::numeric,
      (v_produto_item->>'subtotal')::numeric
    );
 
    UPDATE estoque
    SET quantidade = quantidade - (v_produto_item->>'quantidade')::int
    WHERE id = (v_produto_item->>'estoque_id')::uuid;
  END LOOP;
 
  -- ---- venda_pagamentos: crediário primeiro (para pegar id) ----
  IF v_qtd_crediarios > 0 THEN
    SELECT
      p->>'crediario_frequencia',
      round((p->>'valor')::numeric, 2),
      p->'crediario_parcelas'
    INTO v_freq_cred, v_valor_cred, v_parcelas_cred
    FROM jsonb_array_elements(p_pagamentos) p
    WHERE p->>'forma' = 'crediario';
 
    INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, crediario_frequencia, ordem)
    VALUES (v_venda_id, 'crediario', v_valor_cred, 1, v_freq_cred,
      -- ordem: se crediário é o único pgto, ordem=1; senão, ordem baseada na posição no array
      (SELECT coalesce(min(ord)::int, 1)
       FROM jsonb_array_elements(p_pagamentos) WITH ORDINALITY AS t(p, ord)
       WHERE p->>'forma' = 'crediario')
    )
    RETURNING id INTO v_pgto_cred_id;
 
    INSERT INTO crediario_parcelas
      (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
    SELECT
      v_venda_id,
      v_pgto_cred_id,
      (e->>'numero')::int,
      round((e->>'valor')::numeric, 2),
      (e->>'data_vencimento')::date,
      coalesce((e->>'pago')::boolean, false),
      CASE WHEN coalesce((e->>'pago')::boolean, false)
           THEN coalesce((e->>'data_pagamento')::date, current_date)
           ELSE NULL END
    FROM jsonb_array_elements(v_parcelas_cred) e;
  END IF;
 
  -- ---- venda_pagamentos: formas não-crediário ----
  INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, ordem)
  SELECT
    v_venda_id,
    p->>'forma',
    round((p->>'valor')::numeric, 2),
    CASE WHEN p->>'forma' = 'credito'
         THEN coalesce((p->>'parcelas')::int, 1)
         ELSE 1
    END,
    ord::int
  FROM jsonb_array_elements(p_pagamentos) WITH ORDINALITY AS t(p, ord)
  WHERE p->>'forma' <> 'crediario';
 
  RETURN v_venda_id;
END;
$_$;


--
-- Name: editar_pagamento_venda(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.editar_pagamento_venda(p_venda_id uuid, p_pagamentos jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_valor_liquido    numeric;
  v_soma_pagamentos  numeric;
  v_qtd_pagamentos   int;
  v_qtd_crediarios   int;
  v_tinha_crediario  boolean;
  v_novo_tem_cred    boolean;
  v_pgto_cred_id     uuid;
  v_valor_cred       numeric;
  v_freq_cred        text;
  v_parcelas_cred    jsonb;
  v_soma_parc_cred   numeric;
  v_qtd_parc_cred    int;
  v_forma_final      text;
  v_parcelas_final   int;
  v_freq_final       text;
  v_item             jsonb;  -- renomeada (era 'p' e conflitava com alias)
BEGIN
  IF NOT is_sales() THEN
    RAISE EXCEPTION 'Sem permissão para editar pagamento.';
  END IF;
 
  IF p_pagamentos IS NULL OR jsonb_typeof(p_pagamentos) <> 'array' THEN
    RAISE EXCEPTION 'Pagamentos inválidos (esperado array JSON).';
  END IF;
 
  SELECT valor_liquido INTO v_valor_liquido
  FROM vendas WHERE id = p_venda_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venda não encontrada.';
  END IF;
  PERFORM 1 FROM crediario_parcelas WHERE venda_id = p_venda_id FOR UPDATE;
  PERFORM 1 FROM venda_pagamentos WHERE venda_id = p_venda_id FOR UPDATE;
 
  SELECT
    count(*),
    coalesce(sum(round((e->>'valor')::numeric, 2)), 0),
    count(*) FILTER (WHERE e->>'forma' = 'crediario')
  INTO v_qtd_pagamentos, v_soma_pagamentos, v_qtd_crediarios
  FROM jsonb_array_elements(p_pagamentos) e;
 
  IF v_qtd_pagamentos < 1 THEN
    RAISE EXCEPTION 'Informe ao menos um pagamento.';
  END IF;
 
  IF v_qtd_crediarios > 1 THEN
    RAISE EXCEPTION 'Só é permitido um pagamento por crediário por venda.';
  END IF;
 
  -- Valida cada item (usa v_item — não conflita com aliases 'p' abaixo).
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_pagamentos)
  LOOP
    IF v_item->>'forma' IS NULL OR
       v_item->>'forma' NOT IN ('pix','dinheiro','debito','credito','crediario') THEN
      RAISE EXCEPTION 'Forma de pagamento inválida: %', v_item->>'forma';
    END IF;
 
    IF (v_item->>'valor') IS NULL OR round((v_item->>'valor')::numeric, 2) <= 0 THEN
      RAISE EXCEPTION 'Valor de pagamento inválido para forma %.', v_item->>'forma';
    END IF;
 
    IF v_item->>'forma' = 'credito' THEN
      IF (v_item->>'parcelas') IS NOT NULL AND (v_item->>'parcelas')::int < 1 THEN
        RAISE EXCEPTION 'Número de parcelas de crédito inválido.';
      END IF;
    ELSIF (v_item->>'parcelas') IS NOT NULL AND (v_item->>'parcelas')::int > 1 THEN
      RAISE EXCEPTION 'parcelas > 1 só é válido para forma=credito.';
    END IF;
 
    IF v_item->>'forma' = 'crediario' THEN
      IF v_item->>'crediario_frequencia' IS NULL OR
         v_item->>'crediario_frequencia' NOT IN ('semanal','quinzenal','mensal') THEN
        RAISE EXCEPTION 'Frequência de crediário inválida.';
      END IF;
 
      IF NOT (v_item ? 'crediario_parcelas') OR
         jsonb_typeof(v_item->'crediario_parcelas') <> 'array' THEN
        RAISE EXCEPTION 'crediario_parcelas obrigatório para forma=crediario (array).';
      END IF;
 
      SELECT count(*), coalesce(sum(round((e->>'valor')::numeric, 2)), 0)
        INTO v_qtd_parc_cred, v_soma_parc_cred
      FROM jsonb_array_elements(v_item->'crediario_parcelas') e;
 
      IF v_qtd_parc_cred < 1 THEN
        RAISE EXCEPTION 'Crediário exige ao menos uma parcela.';
      END IF;
 
      IF round(v_soma_parc_cred, 2) <> round((v_item->>'valor')::numeric, 2) THEN
        RAISE EXCEPTION 'Soma das parcelas do crediário (R$ %) difere do valor do pagamento crediário (R$ %).',
          to_char(v_soma_parc_cred, 'FM999G999D00'),
          to_char((v_item->>'valor')::numeric, 'FM999G999D00');
      END IF;
    END IF;
  END LOOP;
 
  IF round(v_soma_pagamentos, 2) <> round(v_valor_liquido, 2) THEN
    RAISE EXCEPTION 'Soma dos pagamentos (R$ %) difere do valor da venda (R$ %).',
      to_char(v_soma_pagamentos, 'FM999G999D00'),
      to_char(v_valor_liquido, 'FM999G999D00');
  END IF;
 
  SELECT EXISTS(SELECT 1 FROM venda_pagamentos
                WHERE venda_id = p_venda_id AND forma = 'crediario')
    INTO v_tinha_crediario;
  v_novo_tem_cred := (v_qtd_crediarios > 0);
 
  IF v_tinha_crediario AND NOT v_novo_tem_cred THEN
    RAISE EXCEPTION 'Não é permitido remover totalmente o crediário desta venda. Ajuste as parcelas em vez de trocar de forma.';
  END IF;
 
  -- Passo 1 + 2: cuida do crediário existente ou apaga tudo se não vai ter.
  IF v_tinha_crediario THEN
    -- Extrai o pagamento crediário do novo array.
    SELECT
      p->>'crediario_frequencia',
      round((p->>'valor')::numeric, 2),
      p->'crediario_parcelas'
    INTO v_freq_cred, v_valor_cred, v_parcelas_cred
    FROM jsonb_array_elements(p_pagamentos) p
    WHERE p->>'forma' = 'crediario';
 
    SELECT id INTO v_pgto_cred_id
    FROM venda_pagamentos
    WHERE venda_id = p_venda_id AND forma = 'crediario';
 
    UPDATE venda_pagamentos
       SET valor = v_valor_cred,
           crediario_frequencia = v_freq_cred
     WHERE id = v_pgto_cred_id;
 
    DELETE FROM crediario_parcelas
     WHERE venda_id = p_venda_id
       AND (id NOT IN (
         SELECT (e->>'id')::uuid
         FROM jsonb_array_elements(v_parcelas_cred) e
         WHERE e->>'id' IS NOT NULL
       ) OR NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_parcelas_cred) e
         WHERE e->>'id' IS NOT NULL
       ));
 
    UPDATE crediario_parcelas cp
       SET numero          = (e->>'numero')::int,
           valor           = round((e->>'valor')::numeric, 2),
           data_vencimento = (e->>'data_vencimento')::date,
           pago            = coalesce((e->>'pago')::boolean, false),
           data_pagamento  = CASE
                               WHEN coalesce((e->>'pago')::boolean, false)
                                 THEN coalesce((e->>'data_pagamento')::date, current_date)
                               ELSE NULL
                             END,
           pagamento_id    = v_pgto_cred_id
    FROM jsonb_array_elements(v_parcelas_cred) e
    WHERE e->>'id' IS NOT NULL
      AND cp.id = (e->>'id')::uuid
      AND cp.venda_id = p_venda_id;
 
    INSERT INTO crediario_parcelas
      (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
    SELECT
      p_venda_id,
      v_pgto_cred_id,
      (e->>'numero')::int,
      round((e->>'valor')::numeric, 2),
      (e->>'data_vencimento')::date,
      coalesce((e->>'pago')::boolean, false),
      CASE WHEN coalesce((e->>'pago')::boolean, false)
           THEN coalesce((e->>'data_pagamento')::date, current_date)
           ELSE NULL END
    FROM jsonb_array_elements(v_parcelas_cred) e
    WHERE e->>'id' IS NULL;
 
    DELETE FROM venda_pagamentos
     WHERE venda_id = p_venda_id
       AND id <> v_pgto_cred_id;
  ELSE
    DELETE FROM venda_pagamentos WHERE venda_id = p_venda_id;
  END IF;
 
  -- Passo 3: se o novo array tem crediário mas a venda não tinha, cria.
  IF v_novo_tem_cred AND NOT v_tinha_crediario THEN
    SELECT
      p->>'crediario_frequencia',
      round((p->>'valor')::numeric, 2),
      p->'crediario_parcelas'
    INTO v_freq_cred, v_valor_cred, v_parcelas_cred
    FROM jsonb_array_elements(p_pagamentos) p
    WHERE p->>'forma' = 'crediario';
 
    INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, crediario_frequencia, ordem)
    VALUES (p_venda_id, 'crediario', v_valor_cred, 1, v_freq_cred, 1)
    RETURNING id INTO v_pgto_cred_id;
 
    INSERT INTO crediario_parcelas
      (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
    SELECT
      p_venda_id,
      v_pgto_cred_id,
      (e->>'numero')::int,
      round((e->>'valor')::numeric, 2),
      (e->>'data_vencimento')::date,
      coalesce((e->>'pago')::boolean, false),
      CASE WHEN coalesce((e->>'pago')::boolean, false)
           THEN coalesce((e->>'data_pagamento')::date, current_date)
           ELSE NULL END
    FROM jsonb_array_elements(v_parcelas_cred) e;
  END IF;
 
  -- Passo 4: cria venda_pagamentos das formas não-crediário.
  INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, ordem)
  SELECT
    p_venda_id,
    p->>'forma',
    round((p->>'valor')::numeric, 2),
    CASE WHEN p->>'forma' = 'credito'
         THEN coalesce((p->>'parcelas')::int, 1)
         ELSE 1
    END,
    ord
  FROM jsonb_array_elements(p_pagamentos) WITH ORDINALITY AS t(p, ord)
  WHERE p->>'forma' <> 'crediario';
 
  -- Recalcula vendas.forma_pagamento derivado.
  IF v_qtd_pagamentos = 1 THEN
    SELECT p->>'forma',
           CASE WHEN p->>'forma' = 'credito'
                THEN coalesce((p->>'parcelas')::int, 1)
                ELSE 1
           END,
           CASE WHEN p->>'forma' = 'crediario'
                THEN p->>'crediario_frequencia'
                ELSE NULL
           END
      INTO v_forma_final, v_parcelas_final, v_freq_final
    FROM jsonb_array_elements(p_pagamentos) p LIMIT 1;
 
    IF v_forma_final = 'crediario' THEN
      SELECT count(*) INTO v_parcelas_final
      FROM crediario_parcelas WHERE venda_id = p_venda_id;
    END IF;
  ELSE
    v_forma_final := 'split';
    v_parcelas_final := 1;
    v_freq_final := NULL;
  END IF;
 
  UPDATE vendas
     SET forma_pagamento      = v_forma_final,
         parcelas             = v_parcelas_final,
         crediario_frequencia = v_freq_final
   WHERE id = p_venda_id;
END;
$_$;


--
-- Name: editar_parcelamento_venda(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.editar_parcelamento_venda(p_venda_id uuid, p_frequencia text, p_parcelas jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_valor          numeric;
  v_soma_crediario numeric;
  v_qtd            int;
  v_numeros        int[];
  v_existentes     uuid[];
  v_enviados       uuid[];
  v_pagamento_id   uuid;
  v_valor_cred     numeric;
BEGIN
  IF NOT is_sales() THEN
    RAISE EXCEPTION 'Sem permissão para editar parcelamentos.';
  END IF;
 
  IF p_frequencia IS NULL OR p_frequencia NOT IN ('semanal', 'quinzenal', 'mensal') THEN
    RAISE EXCEPTION 'Frequência inválida: %', p_frequencia;
  END IF;
 
  IF p_parcelas IS NULL OR jsonb_typeof(p_parcelas) <> 'array' THEN
    RAISE EXCEPTION 'Parcelas inválidas (esperado array JSON).';
  END IF;
 
  SELECT valor_liquido INTO v_valor
  FROM vendas WHERE id = p_venda_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venda não encontrada.';
  END IF;
  PERFORM 1 FROM crediario_parcelas WHERE venda_id = p_venda_id FOR UPDATE;
 
  -- Localiza o venda_pagamento crediário desta venda (deve existir 1).
  SELECT id, valor INTO v_pagamento_id, v_valor_cred
  FROM venda_pagamentos
  WHERE venda_id = p_venda_id AND forma = 'crediario';
 
  IF v_pagamento_id IS NULL THEN
    RAISE EXCEPTION 'Esta venda não possui pagamento crediário.';
  END IF;
 
  SELECT
    count(*),
    coalesce(sum(round((e->>'valor')::numeric, 2)), 0),
    array_agg((e->>'numero')::int)
  INTO v_qtd, v_soma_crediario, v_numeros
  FROM jsonb_array_elements(p_parcelas) e;
 
  IF v_qtd < 1 THEN
    RAISE EXCEPTION 'Informe ao menos uma parcela.';
  END IF;
 
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_parcelas) e
    WHERE (e->>'valor') IS NULL OR round((e->>'valor')::numeric, 2) < 0
  ) THEN
    RAISE EXCEPTION 'Há parcela com valor inválido.';
  END IF;
 
  IF (SELECT count(*) FROM unnest(v_numeros)) <> (SELECT count(DISTINCT x) FROM unnest(v_numeros) x) THEN
    RAISE EXCEPTION 'Há números de parcela duplicados.';
  END IF;
 
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_parcelas) e
    WHERE coalesce((e->>'pago')::boolean, false) = true
      AND e->>'data_pagamento' IS NOT NULL
      AND (e->>'data_pagamento') !~ '^\d{4}-\d{2}-\d{2}$'
  ) THEN
    RAISE EXCEPTION 'Data de pagamento em formato inválido.';
  END IF;
 
  -- CONSERVAÇÃO: soma bate com o valor do pagamento crediário
  -- (NÃO mais com o valor_liquido da venda — que pode ter split).
  IF round(v_soma_crediario, 2) <> round(v_valor_cred, 2) THEN
    RAISE EXCEPTION 'Soma das parcelas (R$ %) difere do valor do crediário (R$ %).',
      to_char(v_soma_crediario, 'FM999G999D00'), to_char(v_valor_cred, 'FM999G999D00');
  END IF;
 
  SELECT array_agg(id) INTO v_existentes
  FROM crediario_parcelas WHERE venda_id = p_venda_id;
  v_existentes := coalesce(v_existentes, '{}');
 
  SELECT array_agg((e->>'id')::uuid) INTO v_enviados
  FROM jsonb_array_elements(p_parcelas) e
  WHERE e->>'id' IS NOT NULL;
  v_enviados := coalesce(v_enviados, '{}');
 
  IF EXISTS (
    SELECT 1 FROM unnest(v_enviados) x
    WHERE NOT (x = ANY (v_existentes))
  ) THEN
    RAISE EXCEPTION 'Parcela informada não pertence a esta venda.';
  END IF;
 
  DELETE FROM crediario_parcelas
   WHERE venda_id = p_venda_id
     AND NOT (id = ANY (v_enviados));
 
  UPDATE crediario_parcelas cp
     SET numero          = (e->>'numero')::int,
         valor           = round((e->>'valor')::numeric, 2),
         data_vencimento = (e->>'data_vencimento')::date,
         pago            = coalesce((e->>'pago')::boolean, false),
         data_pagamento  = CASE
                             WHEN coalesce((e->>'pago')::boolean, false)
                               THEN coalesce((e->>'data_pagamento')::date, current_date)
                             ELSE NULL
                           END,
         pagamento_id    = v_pagamento_id  -- garantia extra de consistência
  FROM jsonb_array_elements(p_parcelas) e
  WHERE e->>'id' IS NOT NULL
    AND cp.id = (e->>'id')::uuid
    AND cp.venda_id = p_venda_id;
 
  -- INSERT das novas já vem com pagamento_id linkado.
  INSERT INTO crediario_parcelas
    (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
  SELECT
    p_venda_id,
    v_pagamento_id,
    (elem->>'numero')::int,
    round((elem->>'valor')::numeric, 2),
    (elem->>'data_vencimento')::date,
    coalesce((elem->>'pago')::boolean, false),
    CASE WHEN coalesce((elem->>'pago')::boolean, false)
         THEN coalesce((elem->>'data_pagamento')::date, current_date)
         ELSE NULL END
  FROM jsonb_array_elements(p_parcelas) WITH ORDINALITY AS t(elem, ord)
  WHERE elem->>'id' IS NULL;
 
  -- Atualiza o venda_pagamento crediário com nova frequência.
  UPDATE venda_pagamentos
     SET crediario_frequencia = p_frequencia
   WHERE id = v_pagamento_id;
 
  -- Recalcula vendas.parcelas e grava a frequência (só faz sentido
  -- se essa é a única forma de pagamento; se for split, o
  -- editar_pagamento_venda cuida disso).
  SELECT count(*) INTO v_qtd FROM crediario_parcelas WHERE venda_id = p_venda_id;
 
  UPDATE vendas
     SET parcelas = v_qtd,
         crediario_frequencia = p_frequencia
   WHERE id = p_venda_id
     AND forma_pagamento = 'crediario';  -- só toca se não for split
END;
$_$;


--
-- Name: get_catalog_items_public(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_catalog_items_public() RETURNS TABLE(produto_id uuid, codigo_peca text, descricao text, cor text, foto_url text, preco_venda numeric, quantidade_total integer, tamanhos jsonb)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    p.id as produto_id,
    p.codigo_peca,
    p.descricao,
    p.cor,
    p.foto_url,
    p.preco_venda,
    coalesce(sum(e.quantidade), 0)::int4 as quantidade_total,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'estoque_id', e.id,
          'tamanho_id', t.id,
          'tamanho', t.nome,
          'ordem', t.ordem,
          'quantidade', e.quantidade
        )
        order by t.ordem
      ) filter (where e.id is not null),
      '[]'::jsonb
    ) as tamanhos
  from public.produtos p
  join public.estoque e on e.produto_id = p.id
  join public.tamanhos t on t.id = e.tamanho_id
  where p.descontinuado is distinct from true
    and e.quantidade > 0
  group by p.id, p.codigo_peca, p.descricao, p.cor, p.foto_url, p.preco_venda;
$$;


--
-- Name: get_catalog_public(integer, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_catalog_public(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid) RETURNS TABLE(product_id uuid, codigo_peca text, descricao text, cor text, preco_venda numeric, foto_url text, tamanhos jsonb, total_disponivel integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with base as (
    select
      p.id as product_id,
      p.codigo_peca,
      p.descricao,
      p.cor,
      p.preco_venda,
      p.foto_url
    from public.produtos p
    where coalesce(p.descontinuado, false) = false
      and (p_product_id is null or p.id = p_product_id)
  ),
  stock as (
    select
      e.produto_id,
      t.id as tamanho_id,
      t.nome as tamanho_nome,
      sum(coalesce(e.quantidade, 0))::int as quantidade
    from public.estoque e
    join public.tamanhos t on t.id = e.tamanho_id
    group by e.produto_id, t.id, t.nome
  ),
  aggregated as (
    select
      b.product_id,
      b.codigo_peca,
      b.descricao,
      b.cor,
      b.preco_venda,
      b.foto_url,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tamanho_id', s.tamanho_id,
            'tamanho', s.tamanho_nome,
            'quantidade', s.quantidade
          )
          order by s.tamanho_nome
        ) filter (where s.quantidade > 0),
        '[]'::jsonb
      ) as tamanhos,
      coalesce(sum(s.quantidade) filter (where s.quantidade > 0), 0)::int as total_disponivel
    from base b
    left join stock s on s.produto_id = b.product_id
    group by b.product_id, b.codigo_peca, b.descricao, b.cor, b.preco_venda, b.foto_url
  )
  select *
  from aggregated
  where total_disponivel > 0   -- filtro reforçado: SEMPRE esconde zerados
  order by descricao
  limit p_limit offset p_offset;
$$;


--
-- Name: importar_carrinho_catalogo(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.importar_carrinho_catalogo(p_carrinho_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_draft_id uuid;
  v_carrinho record;
  v_item record;
  v_estoque_id uuid;
  v_custo numeric;
  v_ean text;
BEGIN
  -- Busca o carrinho
  SELECT * INTO v_carrinho FROM public.catalogo_carrinhos WHERE id = p_carrinho_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Carrinho não encontrado'; END IF;
  IF v_carrinho.status != 'pendente' THEN RAISE EXCEPTION 'Carrinho já foi importado ou expirado'; END IF;

  -- Cria o draft
  INSERT INTO public.venda_drafts (titulo)
  VALUES (COALESCE('Catálogo: ' || v_carrinho.nome_cliente, 'Pedido do catálogo'))
  RETURNING id INTO v_draft_id;

  -- Itera sobre os itens
  FOR v_item IN
    SELECT * FROM public.catalogo_carrinho_itens WHERE carrinho_id = p_carrinho_id
  LOOP
    -- Resolve estoque_id via produto_id + tamanho nome
    SELECT e.id, p.preco_compra + p.custo_frete + p.custo_embalagem, e.codigo_barras
    INTO v_estoque_id, v_custo, v_ean
    FROM public.estoque e
    JOIN public.tamanhos t ON t.id = e.tamanho_id
    JOIN public.produtos p ON p.id = e.produto_id
    WHERE e.produto_id = v_item.produto_id
      AND t.nome = v_item.tamanho
    LIMIT 1;

    IF v_estoque_id IS NULL THEN
      RAISE EXCEPTION 'Estoque não encontrado para % tamanho %', v_item.descricao, v_item.tamanho;
    END IF;

    INSERT INTO public.venda_draft_itens
      (draft_id, produto_id, estoque_id, descricao, cor, tamanho, preco, custo, qtd, foto_url, ean)
    VALUES
      (v_draft_id, v_item.produto_id, v_estoque_id, v_item.descricao, v_item.cor,
       v_item.tamanho, v_item.preco, COALESCE(v_custo, 0), v_item.quantidade, v_item.foto_url, v_ean);
  END LOOP;

  -- Marca como importado
  UPDATE public.catalogo_carrinhos
  SET status = 'importado', importado_at = now(), importado_por = auth.uid()
  WHERE id = p_carrinho_id;

  RETURN v_draft_id;
END;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  select exists (
    select 1 from public.app_users u
    where u.user_id = auth.uid() and u.role = 'admin'
  );
$$;


--
-- Name: is_sales(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_sales() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  select exists (
    select 1 from public.app_users u
    where u.user_id = auth.uid() and u.role in ('sales','admin')
  );
$$;


--
-- Name: realizar_venda(numeric, numeric, numeric, text, integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.realizar_venda(p_valor_bruto numeric, p_valor_liquido numeric, p_desconto numeric, p_forma_pagamento text, p_parcelas integer, p_itens jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_venda_id uuid;
  item jsonb;
BEGIN
  INSERT INTO vendas (valor_total, valor_liquido, desconto, forma_pagamento, parcelas)
  VALUES (p_valor_bruto, p_valor_liquido, p_desconto, p_forma_pagamento, p_parcelas)
  RETURNING id INTO v_venda_id;
 
  FOR item IN SELECT * FROM jsonb_array_elements(p_itens)
  LOOP
    INSERT INTO itens_venda (
      venda_id, produto_id, estoque_id, descricao_completa,
      quantidade, preco_unitario, subtotal
    ) VALUES (
      v_venda_id,
      (item->>'produto_id')::uuid,
      (item->>'estoque_id')::uuid,
      item->>'descricao_completa',
      (item->>'quantidade')::int,
      (item->>'preco_unitario')::numeric,
      (item->>'subtotal')::numeric
    );
 
    UPDATE estoque
    SET quantidade = quantidade - (item->>'quantidade')::int
    WHERE id = (item->>'estoque_id')::uuid;
  END LOOP;
 
  -- NOVO: popular venda_pagamentos (1 linha, forma única).
  INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, ordem)
  VALUES (
    v_venda_id,
    p_forma_pagamento,
    p_valor_liquido,
    CASE WHEN p_forma_pagamento = 'credito' THEN COALESCE(p_parcelas, 1) ELSE 1 END,
    1
  );
END;
$$;


--
-- Name: realizar_venda(numeric, numeric, numeric, text, integer, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.realizar_venda(p_valor_bruto numeric, p_valor_liquido numeric, p_desconto numeric, p_forma_pagamento text, p_parcelas integer, p_itens jsonb, p_nome_cliente text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_venda_id uuid;
  item       jsonb;
BEGIN
  INSERT INTO vendas (
    valor_total, valor_liquido, desconto, forma_pagamento, parcelas, nome_cliente
  )
  VALUES (
    p_valor_bruto, p_valor_liquido, p_desconto, p_forma_pagamento, p_parcelas, p_nome_cliente
  )
  RETURNING id INTO v_venda_id;
 
  FOR item IN SELECT * FROM jsonb_array_elements(p_itens)
  LOOP
    INSERT INTO itens_venda (
      venda_id, produto_id, estoque_id, descricao_completa, cor,
      quantidade, preco_unitario, subtotal
    ) VALUES (
      v_venda_id,
      (item->>'produto_id')::uuid,
      (item->>'estoque_id')::uuid,
      item->>'descricao_completa',
      item->>'cor',
      (item->>'quantidade')::int,
      (item->>'preco_unitario')::numeric,
      (item->>'subtotal')::numeric
    );
 
    UPDATE estoque
    SET quantidade = quantidade - (item->>'quantidade')::int
    WHERE id = (item->>'estoque_id')::uuid;
  END LOOP;
 
  -- NOVO: popular venda_pagamentos (1 linha, forma única).
  INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, ordem)
  VALUES (
    v_venda_id,
    p_forma_pagamento,
    p_valor_liquido,
    CASE WHEN p_forma_pagamento = 'credito' THEN COALESCE(p_parcelas, 1) ELSE 1 END,
    1
  );
END;
$$;


--
-- Name: realizar_venda_crediario(numeric, numeric, numeric, jsonb, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.realizar_venda_crediario(p_valor_bruto numeric, p_valor_liquido numeric, p_desconto numeric, p_itens jsonb, p_nome_cliente text, p_frequencia text, p_parcelas_crediario jsonb) RETURNS uuid
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_venda_id     uuid;
  v_pagamento_id uuid;
  v_qtd          int;
  v_soma         numeric;
  item           jsonb;
BEGIN
  IF p_nome_cliente IS NULL OR btrim(p_nome_cliente) = '' THEN
    RAISE EXCEPTION 'Crediário exige o nome do cliente.';
  END IF;
 
  IF p_frequencia NOT IN ('semanal', 'quinzenal', 'mensal') THEN
    RAISE EXCEPTION 'Frequência inválida: %', p_frequencia;
  END IF;
 
  IF p_parcelas_crediario IS NULL OR jsonb_typeof(p_parcelas_crediario) <> 'array' THEN
    RAISE EXCEPTION 'Parcelas inválidas (esperado array JSON).';
  END IF;
 
  SELECT count(*), coalesce(sum(round((e->>'valor')::numeric, 2)), 0)
    INTO v_qtd, v_soma
  FROM jsonb_array_elements(p_parcelas_crediario) e;
 
  IF v_qtd < 1 THEN
    RAISE EXCEPTION 'Nenhuma parcela informada.';
  END IF;
 
  IF round(v_soma, 2) <> round(p_valor_liquido, 2) THEN
    RAISE EXCEPTION 'Soma das parcelas (R$ %) difere do valor da venda (R$ %).',
      to_char(v_soma, 'FM999G999D00'), to_char(p_valor_liquido, 'FM999G999D00');
  END IF;
 
  INSERT INTO vendas (
    valor_total, valor_liquido, desconto, forma_pagamento, parcelas,
    nome_cliente, crediario_frequencia
  )
  VALUES (
    p_valor_bruto, p_valor_liquido, p_desconto, 'crediario', v_qtd,
    btrim(p_nome_cliente), p_frequencia
  )
  RETURNING id INTO v_venda_id;
 
  FOR item IN SELECT * FROM jsonb_array_elements(p_itens)
  LOOP
    INSERT INTO itens_venda (
      venda_id, produto_id, estoque_id, descricao_completa, cor,
      quantidade, preco_unitario, subtotal
    ) VALUES (
      v_venda_id,
      (item->>'produto_id')::uuid,
      (item->>'estoque_id')::uuid,
      item->>'descricao_completa',
      item->>'cor',
      (item->>'quantidade')::int,
      (item->>'preco_unitario')::numeric,
      (item->>'subtotal')::numeric
    );
 
    UPDATE estoque
    SET quantidade = quantidade - (item->>'quantidade')::int
    WHERE id = (item->>'estoque_id')::uuid;
  END LOOP;
 
  -- NOVO: criar venda_pagamento primeiro para ter o id.
  INSERT INTO venda_pagamentos (venda_id, forma, valor, parcelas, crediario_frequencia, ordem)
  VALUES (v_venda_id, 'crediario', p_valor_liquido, 1, p_frequencia, 1)
  RETURNING id INTO v_pagamento_id;
 
  -- Parcelas já entram com pagamento_id linkado.
  INSERT INTO crediario_parcelas
    (venda_id, pagamento_id, numero, valor, data_vencimento, pago, data_pagamento)
  SELECT
    v_venda_id,
    v_pagamento_id,
    (e->>'numero')::int,
    round((e->>'valor')::numeric, 2),
    (e->>'data_vencimento')::date,
    coalesce((e->>'pago')::boolean, false),
    CASE WHEN coalesce((e->>'pago')::boolean, false)
         THEN coalesce((e->>'data_pagamento')::date, current_date)
         ELSE NULL END
  FROM jsonb_array_elements(p_parcelas_crediario) e;
 
  RETURN v_venda_id;
END;
$_$;


--
-- Name: salvar_carrinho_catalogo(text, text, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.salvar_carrinho_catalogo(p_token text, p_nome_cliente text, p_total numeric, p_itens jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_carrinho_id uuid;
BEGIN
  INSERT INTO public.catalogo_carrinhos (token, nome_cliente, total, status)
  VALUES (p_token, p_nome_cliente, p_total, 'pendente')
  RETURNING id INTO v_carrinho_id;

  INSERT INTO public.catalogo_carrinho_itens 
    (carrinho_id, produto_id, descricao, cor, tamanho, preco, quantidade, foto_url)
  SELECT 
    v_carrinho_id,
    (item->>'produto_id')::uuid,
    item->>'descricao',
    item->>'cor',
    item->>'tamanho',
    (item->>'preco')::numeric,
    (item->>'quantidade')::integer,
    item->>'foto_url'
  FROM jsonb_array_elements(p_itens) AS item;

  RETURN v_carrinho_id;
END;
$$;


--
-- Name: set_user_id_on_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_user_id_on_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.user_id is null then
    new.user_id := auth.uid();
  end if;
  return new;
end;
$$;


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_users (
    user_id uuid NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT app_users_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'sales'::text])))
);


--
-- Name: estoque; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.estoque (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tamanho_id uuid,
    codigo_barras text,
    quantidade integer DEFAULT 0,
    produto_id uuid
);


--
-- Name: produtos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.produtos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo_peca text,
    descricao text NOT NULL,
    preco_compra numeric(10,2) DEFAULT 0,
    preco_venda numeric(10,2) DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    fornecedor text,
    custo_frete numeric DEFAULT 0,
    custo_embalagem numeric DEFAULT 0,
    descontinuado boolean DEFAULT false,
    cor text,
    foto_url text,
    sku_fornecedor text,
    fotos text[] DEFAULT '{}'::text[] NOT NULL
);


--
-- Name: tamanhos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tamanhos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nome text NOT NULL,
    ordem integer DEFAULT 0
);


--
-- Name: catalog_items_public; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.catalog_items_public WITH (security_invoker='true') AS
 SELECT p.id AS produto_id,
    p.codigo_peca,
    p.descricao,
    p.cor,
    p.foto_url,
    p.preco_venda,
    p.descontinuado,
    (COALESCE(sum(e.quantidade), (0)::bigint))::integer AS quantidade_total,
    (COALESCE(sum(e.quantidade), (0)::bigint) > 0) AS disponivel,
    COALESCE(jsonb_agg(jsonb_build_object('estoque_id', e.id, 'tamanho_id', t.id, 'tamanho', t.nome, 'ordem', t.ordem, 'codigo_barras', e.codigo_barras, 'quantidade', e.quantidade) ORDER BY t.ordem) FILTER (WHERE (e.id IS NOT NULL)), '[]'::jsonb) AS tamanhos
   FROM ((public.produtos p
     LEFT JOIN public.estoque e ON ((e.produto_id = p.id)))
     LEFT JOIN public.tamanhos t ON ((t.id = e.tamanho_id)))
  WHERE ((p.descontinuado IS DISTINCT FROM true) AND (EXISTS ( SELECT 1
           FROM public.estoque e2
          WHERE ((e2.produto_id = p.id) AND (e2.quantidade > 0)))))
  GROUP BY p.id, p.codigo_peca, p.descricao, p.cor, p.foto_url, p.preco_venda, p.descontinuado;


--
-- Name: catalogo_carrinho_itens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalogo_carrinho_itens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    carrinho_id uuid NOT NULL,
    produto_id uuid,
    descricao text NOT NULL,
    cor text,
    tamanho text NOT NULL,
    preco numeric DEFAULT 0 NOT NULL,
    quantidade integer DEFAULT 1 NOT NULL,
    foto_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: catalogo_carrinhos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalogo_carrinhos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token text NOT NULL,
    status text DEFAULT 'pendente'::text NOT NULL,
    observacao text,
    total numeric DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    importado_at timestamp with time zone,
    importado_por uuid,
    nome_cliente text,
    CONSTRAINT catalogo_carrinhos_status_check CHECK ((status = ANY (ARRAY['pendente'::text, 'importado'::text, 'expirado'::text])))
);


--
-- Name: crediario_parcelas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crediario_parcelas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venda_id uuid NOT NULL,
    numero integer NOT NULL,
    valor numeric(10,2) NOT NULL,
    data_vencimento date NOT NULL,
    pago boolean DEFAULT false NOT NULL,
    data_pagamento date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    pagamento_id uuid,
    CONSTRAINT crediario_parcelas_numero_check CHECK ((numero >= 1)),
    CONSTRAINT crediario_parcelas_valor_check CHECK ((valor >= (0)::numeric))
);


--
-- Name: TABLE crediario_parcelas; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.crediario_parcelas IS 'Parcelas de vendas em crediário. Baixa = pago=true + data_pagamento.';


--
-- Name: itens_venda; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.itens_venda (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venda_id uuid,
    produto_id uuid,
    estoque_id uuid,
    descricao_completa text,
    quantidade integer NOT NULL,
    preco_unitario numeric(10,2) NOT NULL,
    subtotal numeric(10,2) NOT NULL,
    cor text
);


--
-- Name: venda_draft_itens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venda_draft_itens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    draft_id uuid NOT NULL,
    produto_id uuid NOT NULL,
    estoque_id uuid NOT NULL,
    descricao text NOT NULL,
    cor text,
    tamanho text,
    preco numeric DEFAULT 0 NOT NULL,
    custo numeric DEFAULT 0 NOT NULL,
    qtd integer DEFAULT 1 NOT NULL,
    foto_url text,
    ean text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: venda_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venda_drafts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    titulo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid
);


--
-- Name: venda_pagamentos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venda_pagamentos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venda_id uuid NOT NULL,
    forma text NOT NULL,
    valor numeric NOT NULL,
    parcelas smallint DEFAULT 1 NOT NULL,
    crediario_frequencia text,
    ordem smallint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT venda_pagamentos_forma_valida CHECK ((forma = ANY (ARRAY['pix'::text, 'dinheiro'::text, 'debito'::text, 'credito'::text, 'crediario'::text]))),
    CONSTRAINT venda_pagamentos_frequencia_coerente CHECK ((((forma = 'crediario'::text) AND (crediario_frequencia IS NOT NULL)) OR ((forma <> 'crediario'::text) AND (crediario_frequencia IS NULL)))),
    CONSTRAINT venda_pagamentos_frequencia_valida CHECK (((crediario_frequencia IS NULL) OR (crediario_frequencia = ANY (ARRAY['semanal'::text, 'quinzenal'::text, 'mensal'::text])))),
    CONSTRAINT venda_pagamentos_parcelas_coerente CHECK (((parcelas = 1) OR (forma = 'credito'::text))),
    CONSTRAINT venda_pagamentos_parcelas_min CHECK ((parcelas >= 1)),
    CONSTRAINT venda_pagamentos_valor_positivo CHECK ((valor > (0)::numeric))
);


--
-- Name: TABLE venda_pagamentos; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.venda_pagamentos IS 'N formas de pagamento por venda. Substitui gradualmente vendas.forma_pagamento/parcelas/crediario_frequencia (que continuam populadas por compat).';


--
-- Name: vendas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo_venda integer NOT NULL,
    valor_total numeric(10,2) NOT NULL,
    forma_pagamento text DEFAULT 'dinheiro'::text,
    created_at timestamp with time zone DEFAULT now(),
    desconto numeric(10,2) DEFAULT 0,
    valor_liquido numeric(10,2),
    parcelas integer DEFAULT 1,
    nome_cliente text,
    crediario_frequencia text,
    CONSTRAINT vendas_crediario_frequencia_check CHECK (((crediario_frequencia IS NULL) OR (crediario_frequencia = ANY (ARRAY['semanal'::text, 'quinzenal'::text, 'mensal'::text]))))
);


--
-- Name: vendas_codigo_venda_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vendas_codigo_venda_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vendas_codigo_venda_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vendas_codigo_venda_seq OWNED BY public.vendas.codigo_venda;


--
-- Name: vendas codigo_venda; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendas ALTER COLUMN codigo_venda SET DEFAULT nextval('public.vendas_codigo_venda_seq'::regclass);


--
-- Data for Name: app_users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.app_users (user_id, role, created_at) FROM stdin;
a71190dd-e547-4c5f-bb89-545b283ca256	admin	2026-03-04 22:49:50.246869+00
6476021c-3dfa-472a-bab7-de4ae2d07aac	admin	2026-03-04 22:49:50.246869+00
c025785b-a746-4afc-af7e-3737da30d7e0	admin	2026-03-06 17:28:25+00
\.


--
-- Data for Name: catalogo_carrinho_itens; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.catalogo_carrinho_itens (id, carrinho_id, produto_id, descricao, cor, tamanho, preco, quantidade, foto_url, created_at) FROM stdin;
3f144bef-4bc2-4fb0-91f1-707d87146104	18e8b27f-d587-47bc-b21f-ca9b88c2da61	c63e0319-a5ae-463e-9b82-b98bb96a604d	COLETE CRISTALE	UVA ROSE	M	319	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c63e0319-a5ae-463e-9b82-b98bb96a604d_1770145849969.jpg	2026-03-10 00:48:20.487692+00
360c9b54-2693-411f-ad58-4c575cee2385	18e8b27f-d587-47bc-b21f-ca9b88c2da61	19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f	Legging Elastico Degrade	Laranja	M	320	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f_1772465925656.jpg	2026-03-10 00:48:20.487692+00
2092c0c1-d4fd-417f-9212-ce2116d5b6c3	18e8b27f-d587-47bc-b21f-ca9b88c2da61	e90473b4-52a3-476e-b132-2a33caa81ee6	Jaqueta Dry Com Elastico	Verde	M	365	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e90473b4-52a3-476e-b132-2a33caa81ee6_1772471956587.jpg	2026-03-10 00:48:20.487692+00
9e5f2c89-9e55-41ff-852a-8b83ee9a3649	18e8b27f-d587-47bc-b21f-ca9b88c2da61	bbcba1b7-c542-4e19-92c7-df58f537cc63	BERMUDA CANELADA TN AG ROSA DOCE	ROSA DOCE	P	260	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319819_1769559862595.jpg	2026-03-10 00:48:20.487692+00
476aaef1-5b3f-4557-83bc-b8ac0e620d43	3c6f29f7-bfa5-4bc4-9b01-ce3c5e53bc61	498a47fd-de22-4035-ad7a-00e679abeba4	BERMUDA ALTO GIRO SPORT VERDE ESCURO	VERDE ESCURO 	M	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp	2026-03-10 00:55:37.569247+00
7f2887a9-7660-4f0a-8ee5-35aec955bfec	5c953af7-40c9-4246-8948-c17c3a405067	4b80ba74-7234-4662-b19d-5e730e7f9571	BERMUDA 5 PRO PRETO	PRO PRETO	P	340	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319289_1769559858980.jpg	2026-03-10 01:02:29.250377+00
c4e06d53-8b97-4942-a0d9-bb0646407f87	c559b3ac-55e5-4777-9057-ef5dbf32b746	f6c11475-b890-40e4-90d7-bd6a63a7af3b	BERMUDA ALTO GIRO SPORT MARROM NOBRE	 MARROM NOBRE	M	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319126_1769559860545.jpg	2026-03-10 01:10:05.816701+00
3f228ca7-50cd-4a3e-81fb-1b63108d4177	5885056a-ec8b-4f25-bdd0-0b5a6de6fe54	4b80ba74-7234-4662-b19d-5e730e7f9571	BERMUDA 5 PRO PRETO	PRO PRETO	P	340	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319289_1769559858980.jpg	2026-03-10 01:12:36.303509+00
da824598-2f79-4c20-a5bd-3479ce0d0290	58c856ae-610c-495e-ae6c-5ce4330d642d	498a47fd-de22-4035-ad7a-00e679abeba4	BERMUDA ALTO GIRO SPORT VERDE ESCURO	VERDE ESCURO 	P	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp	2026-03-10 01:16:47.569891+00
44355fab-8b02-4d56-8b26-66d38e4323da	58c856ae-610c-495e-ae6c-5ce4330d642d	498a47fd-de22-4035-ad7a-00e679abeba4	BERMUDA ALTO GIRO SPORT VERDE ESCURO	VERDE ESCURO 	M	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp	2026-03-10 01:16:47.569891+00
30036d05-af1c-44da-bd22-f0c3faa9b0c4	667d20cf-c019-4b48-83c9-099a0d2e56cd	bbcba1b7-c542-4e19-92c7-df58f537cc63	BERMUDA CANELADA TN AG ROSA DOCE	ROSA DOCE	P	260	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319819_1769559862595.jpg	2026-03-10 01:21:11.642588+00
a013ddfd-34e1-4b77-9e7f-98c0302130f7	1ba89f20-4a08-41ab-8e21-58fd0720d06a	f6c11475-b890-40e4-90d7-bd6a63a7af3b	BERMUDA ALTO GIRO SPORT MARROM NOBRE	 MARROM NOBRE	M	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319126_1769559860545.jpg	2026-03-18 01:31:56.774848+00
e2139dab-b764-478b-bcc0-bd4c7be95c32	948abcb5-ffde-44f9-a60a-39317e257ae1	35212ea8-1da9-4214-b94d-1b680875b8fb	BERMUDA FITNESS SELENITA	AZUL MARINHO/AZUL GALÁXIA	G	215	1	\N	2026-08-16 16:14:51.706202+00
3bc584bb-9c26-4a30-866d-4e74ff759617	948abcb5-ffde-44f9-a60a-39317e257ae1	df6a97ff-20c2-42af-b5e5-d1d7117a0750	BERMUDA DETALHE BICOLOR	VERMELHO ROSADO	M	249.9	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266639_1779802956929.jpg	2026-08-16 16:14:51.706202+00
f771242b-429e-49cb-889d-4681bafcc5e0	948abcb5-ffde-44f9-a60a-39317e257ae1	498a47fd-de22-4035-ad7a-00e679abeba4	BERMUDA ALTO GIRO SPORT VERDE ESCURO	VERDE ESCURO 	P	240	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp	2026-08-16 16:14:51.706202+00
\.


--
-- Data for Name: catalogo_carrinhos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.catalogo_carrinhos (id, token, status, observacao, total, created_at, importado_at, importado_por, nome_cliente) FROM stdin;
18e8b27f-d587-47bc-b21f-ca9b88c2da61	z--bEHvcVnzuQysoyx6lggMw	pendente	\N	1264	2026-03-10 00:48:20.487692+00	\N	\N	Marcia
58c856ae-610c-495e-ae6c-5ce4330d642d	ZBEwDIjg8CiCyYxGdYtQu5gx	pendente	\N	480	2026-03-10 01:16:47.569891+00	\N	\N	Maravilhosa
667d20cf-c019-4b48-83c9-099a0d2e56cd	l1DCxGfYOpAFZfGqx51Rxe4r	importado	\N	260	2026-03-10 01:21:11.642588+00	2026-03-10 01:55:24.924597+00	a71190dd-e547-4c5f-bb89-545b283ca256	Boazuda de rosa
3c6f29f7-bfa5-4bc4-9b01-ce3c5e53bc61	7QjyICIw1UxBT-oWmwRP8Cqx	expirado	\N	240	2026-03-10 00:55:37.569247+00	\N	\N	Gisele
1ba89f20-4a08-41ab-8e21-58fd0720d06a	YjOxGgKbYUaFErJjhp1BJ5CX	importado	\N	240	2026-03-18 01:31:56.774848+00	2026-03-18 01:34:40.879369+00	a71190dd-e547-4c5f-bb89-545b283ca256	Maria
c559b3ac-55e5-4777-9057-ef5dbf32b746	Pj8lYnyTFPM5Aw_n-4JX4PWz	importado	\N	240	2026-03-10 01:10:05.816701+00	2026-06-11 18:29:08.608032+00	a71190dd-e547-4c5f-bb89-545b283ca256	Cacetilda
5c953af7-40c9-4246-8948-c17c3a405067	kXuxn5PFjFP5Z8b_fh8vWvDt	importado	\N	340	2026-03-10 01:02:29.250377+00	2026-06-11 18:29:39.16429+00	a71190dd-e547-4c5f-bb89-545b283ca256	Cacilda
948abcb5-ffde-44f9-a60a-39317e257ae1	faaYCT09a9BCu8ovhxLSsfIY	pendente	\N	704.9	2026-08-16 16:14:51.706202+00	\N	\N	Mariazinha
5885056a-ec8b-4f25-bdd0-0b5a6de6fe54	jVksF_Fvj733shBhqHPIyfnL	importado	\N	340	2026-03-10 01:12:36.303509+00	2026-08-31 21:57:21.319901+00	a71190dd-e547-4c5f-bb89-545b283ca256	Giselda
\.


--
-- Data for Name: crediario_parcelas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.crediario_parcelas (id, venda_id, numero, valor, data_vencimento, pago, data_pagamento, created_at, pagamento_id) FROM stdin;
5f03e292-99a7-4954-b408-4ac5c58aff8f	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	1	149.95	2026-07-20	t	2026-08-04	2026-07-11 03:36:02.353817+00	50a89e86-bb24-4bad-8311-d915221b35a7
192936d9-f4d2-41ef-ac1f-e184f48cdb7d	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	2	149.95	2026-08-03	t	2026-08-17	2026-07-11 03:36:02.353817+00	50a89e86-bb24-4bad-8311-d915221b35a7
a5d80e50-5c58-465f-b4ad-7605bd0ff20f	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	3	149.95	2026-08-17	t	2026-08-04	2026-07-11 03:36:02.353817+00	50a89e86-bb24-4bad-8311-d915221b35a7
0519f754-fc91-4d4e-aae6-b28c016c3084	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	4	149.95	2026-08-31	t	2026-08-17	2026-07-11 03:36:02.353817+00	50a89e86-bb24-4bad-8311-d915221b35a7
358064be-7175-465d-b519-dd763f82334c	bee19e29-193f-45d2-819d-9760948fd45d	1	249.90	2026-08-01	t	2026-08-10	2026-07-03 18:44:11.817392+00	a1d8517c-6462-4760-ac69-56407848df51
ac6f719f-1a93-4c65-9865-09610c8eb519	be56aead-81ef-4271-be5b-76124e0d348e	1	297.00	2026-09-10	f	\N	2026-09-03 15:45:40.349678+00	36018eb2-47f6-4bae-a762-8c9a4ed5864d
e9a7c48d-b811-4d1b-8b42-ff1c163dc376	bee19e29-193f-45d2-819d-9760948fd45d	2	249.90	2026-08-10	t	2026-08-10	2026-07-03 18:44:11.817392+00	a1d8517c-6462-4760-ac69-56407848df51
f693583f-f43d-443b-8ebd-df9caa285c25	25773b86-715a-4f92-8433-20fb7fabf595	1	30.00	2026-08-01	t	2026-08-01	2026-08-01 08:24:28.01768+00	31fa24c6-3eb3-4b2d-9ba2-2c625f65caa0
441e8391-910a-404f-9c1f-58dd00886e88	25773b86-715a-4f92-8433-20fb7fabf595	2	189.80	2026-08-29	t	2026-08-29	2026-08-01 08:31:06.422261+00	31fa24c6-3eb3-4b2d-9ba2-2c625f65caa0
6ad0dd59-9409-49d8-ae83-737b3f3be431	addc5e67-13d8-4857-940f-6e558a2b229b	1	284.00	2026-08-14	t	2026-08-14	2026-08-14 21:06:02.371536+00	7ac96d37-15ea-461e-bbb4-c041b370aa03
eabc129d-d53b-444f-8c24-329510e0a59a	addc5e67-13d8-4857-940f-6e558a2b229b	2	200.00	2026-09-14	t	2026-08-14	2026-08-14 21:06:02.371536+00	7ac96d37-15ea-461e-bbb4-c041b370aa03
95229986-c84e-416d-9c05-34686616c335	bd33264b-59b5-418c-8869-68201818c57a	1	199.90	2026-07-30	t	2026-07-01	2026-07-01 13:56:57.957035+00	c75358b0-8e43-4fec-b605-e325cec836f3
7cd7b2ad-01c1-43a3-a06c-6d0f803a4634	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	3	375.00	2026-06-11	t	2026-06-16	2026-06-12 21:09:12.707856+00	e19567a5-544f-4d56-91d0-642f07f0c908
4219849b-b1d5-4254-88fb-995a324b4f92	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	6	300.00	2026-06-16	t	2026-06-16	2026-06-16 13:34:09.668094+00	e19567a5-544f-4d56-91d0-642f07f0c908
754a1a9e-e153-40a5-8f91-f5e7dfe1b148	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	7	300.00	2026-07-02	t	2026-07-02	2026-06-16 13:34:09.668094+00	e19567a5-544f-4d56-91d0-642f07f0c908
69e87371-cc8c-456a-bee2-8b26e204027c	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	8	300.00	2026-07-14	t	2026-07-02	2026-06-16 13:34:09.668094+00	e19567a5-544f-4d56-91d0-642f07f0c908
5e1605ca-afe9-4e76-ab66-7e85a4abb149	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	9	200.00	2026-07-09	t	2026-07-09	2026-06-16 13:34:09.668094+00	e19567a5-544f-4d56-91d0-642f07f0c908
1a80356d-abb1-4708-ba3a-2b2c33663915	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	10	300.00	2026-07-20	t	2026-07-23	2026-07-09 16:02:37.05914+00	e19567a5-544f-4d56-91d0-642f07f0c908
1ca54ba6-13d6-4068-a472-8814b243f6f1	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	11	1600.33	2026-08-03	f	\N	2026-07-23 18:18:25.006691+00	e19567a5-544f-4d56-91d0-642f07f0c908
78b0e1aa-25fc-4baa-9abf-b61a43cb496a	49415213-6157-4937-ac75-7f612ded322b	1	130.00	2026-08-21	t	2026-08-21	2026-08-22 00:27:20.830205+00	29104233-d456-4a6f-8648-284bac55914e
912b22a4-c450-4cc9-815e-db2f90542500	49415213-6157-4937-ac75-7f612ded322b	2	130.00	2026-08-28	t	2026-08-31	2026-08-22 00:27:20.830205+00	29104233-d456-4a6f-8648-284bac55914e
94cc1cfc-79fb-4b41-a5c3-8ddc35bfe7fe	30274953-5922-4d2b-9972-e1db42931650	1	139.95	2026-10-05	f	\N	2026-09-14 13:54:35.458312+00	0d60e656-383e-4133-9c38-d7a46d3a2c33
1e4197b1-09d4-4372-a6e5-20ea5a088327	30274953-5922-4d2b-9972-e1db42931650	2	139.95	2026-11-05	f	\N	2026-09-14 13:54:35.458312+00	0d60e656-383e-4133-9c38-d7a46d3a2c33
6b537cc2-c68a-4c72-844c-6d291398ded1	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	1	300.00	2026-09-15	t	2026-09-22	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
1ed92b8b-e7e4-4d04-9efb-5b3e3827eb6f	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	2	645.95	2026-09-29	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
62b535af-edf1-4326-a430-f777ed2f5f23	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	3	645.95	2026-10-13	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
0bc776ab-d22c-471e-8021-92c04ce08c7b	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	1	120.48	2026-09-30	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
c485693d-0625-4dca-81d5-eff012c31128	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	2	120.48	2026-10-30	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
5abb5e23-30a1-4a5d-9af8-cad11d2909a0	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	3	120.48	2026-11-30	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
a87ad226-8ae5-4d8b-a653-5b49a7e35d9d	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	4	120.48	2026-12-30	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
133385c5-7aca-4cbe-8a73-583eb6d9ad00	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	5	120.48	2027-01-30	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
f5a6ebab-ef84-4792-9ed0-d043583bd17e	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	6	120.50	2027-02-28	f	\N	2026-08-31 23:41:34.612344+00	65309eb3-081a-4d56-9418-8038c7d9b1c5
369a3419-8672-4862-9369-2f82dfb2b0b6	8289852a-5b57-43f4-ab76-6a856d472dae	4	119.90	2026-09-01	t	2026-09-01	2026-08-18 17:08:35.202186+00	d34dcffa-3444-41e0-9b69-366c630aacdf
4e41ba89-c362-487c-b4bb-cd4476f60dae	067ac8b8-86a5-4710-9142-2277faccc67f	1	119.90	2026-10-01	f	\N	2026-09-02 01:41:24.131945+00	5c35219b-8a7b-48d8-9766-c9a6c16864d5
cee2bcff-4f65-477f-9b4f-8fd6798ee1cc	e1cb8ba5-583d-4552-ba38-d59bf16a8dbb	1	179.90	2026-07-30	t	2026-08-01	2026-07-01 17:19:20.783155+00	afc75b0a-576d-42ad-87fe-713ba6857655
8c11ed4e-0ad1-4a25-a79a-72757743a6ee	7f7f4cdb-8718-4d55-8dfb-84d032f82b13	1	220.00	2026-09-02	t	2026-09-02	2026-08-27 21:29:49.203418+00	5642f4cb-c990-4b3b-b59d-db1d0ef78e50
2e310f71-8ade-445d-bd26-efb933820c9f	af0ccc75-7300-4f7d-a066-f56be7d19fb5	1	145.50	2026-09-10	t	2026-09-03	2026-09-01 07:12:23.90837+00	5fcebe9f-2f2f-413f-994e-594f0f280597
c41a2888-fa27-49cc-b3f6-20189c0c756c	af0ccc75-7300-4f7d-a066-f56be7d19fb5	2	145.50	2026-10-10	t	2026-09-03	2026-09-01 07:12:23.90837+00	5fcebe9f-2f2f-413f-994e-594f0f280597
24b8cffc-435a-4c8b-83df-ab8f4a0ddc85	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	1	300.00	2026-08-01	t	2026-08-17	2026-08-01 08:36:20.763766+00	1c6fe1fa-03bc-4587-b85a-9b185d84f56f
9372819a-17eb-4676-80df-3d84c5c4aa60	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	2	200.00	2026-08-15	t	2026-09-01	2026-08-01 08:36:20.763766+00	1c6fe1fa-03bc-4587-b85a-9b185d84f56f
8c1300fe-df50-4bee-a2ac-6d514180ee76	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	3	0.00	2026-08-29	t	2026-09-03	2026-08-01 08:36:20.763766+00	1c6fe1fa-03bc-4587-b85a-9b185d84f56f
6a2483cf-2c23-47c7-ab73-e48e3af2af27	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	4	66.60	2026-09-12	t	2026-09-01	2026-08-01 08:36:20.763766+00	1c6fe1fa-03bc-4587-b85a-9b185d84f56f
271d764c-e504-48d7-8402-f300af819df3	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	1	300.00	2026-07-31	t	2026-08-31	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
5017f510-d10a-49e9-bda2-866e7d9d083d	1871e295-fb6f-4022-8cb2-5ce142c003e5	1	129.80	2026-08-01	t	2026-08-01	2026-08-01 08:20:14.71809+00	c82613a8-a515-49a8-8113-f1a37a5cd05a
77e4d720-c71e-4b5f-b143-7ec170d1d6f6	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	2	300.00	2026-09-12	t	2026-09-12	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
c0417ae6-156a-40a3-b089-d06f972511b1	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	3	996.31	2026-08-28	f	\N	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
dbbdb5a1-19bc-4d64-9a62-5970eb0be011	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	4	996.31	2026-09-11	f	\N	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
18ace819-057a-488e-81f2-e422a51a9963	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	5	996.31	2026-09-25	f	\N	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
716e097c-1727-45b6-b370-5467d570ded3	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	6	2388.97	2026-10-09	f	\N	2026-07-23 23:23:56.742045+00	a0cb9aba-78ad-4bed-83b5-48c267dc9553
5b8ab3b7-b5ad-4ab8-b09d-ecd3ae6a8d14	69d88638-e460-442b-9ae8-7fafd2ac5d1b	1	258.95	2026-09-14	t	2026-09-14	2026-09-09 18:10:25.294671+00	83788256-9336-481b-bf0d-6b213ff9e519
d897b705-0e70-4f9c-a143-f5466debce58	69d88638-e460-442b-9ae8-7fafd2ac5d1b	2	258.95	2026-10-30	f	\N	2026-09-09 18:10:25.294671+00	83788256-9336-481b-bf0d-6b213ff9e519
db1017e2-3fc7-4dd2-9698-314e7ec2682f	69d88638-e460-442b-9ae8-7fafd2ac5d1b	3	258.95	2026-11-30	f	\N	2026-09-09 18:10:25.294671+00	83788256-9336-481b-bf0d-6b213ff9e519
7aff6f12-b604-4e8a-aebb-9d81ba832e4f	69d88638-e460-442b-9ae8-7fafd2ac5d1b	4	258.95	2026-12-30	f	\N	2026-09-09 18:10:25.294671+00	83788256-9336-481b-bf0d-6b213ff9e519
be7bc1ba-b0bf-4e89-96c0-32ed62954950	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	4	645.95	2026-10-27	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
2afde435-ad41-4da9-a2d3-a62b07dfccef	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	5	645.95	2026-11-10	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
2ff271c0-26cc-41f6-ad3e-2b44ac6cfdbc	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	6	645.95	2026-11-24	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
f1f74a5f-c114-491f-927e-e89b6be196a7	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	7	645.95	2026-12-08	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
a8049ab5-4691-4f99-9f14-8e1265bd7381	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	8	645.95	2026-12-22	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
81521a60-fd58-49a5-9167-e849e6b0c242	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	9	645.95	2027-01-05	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
5b6409ff-5fc9-45cf-b123-0fd24b085ced	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	10	991.90	2027-01-19	f	\N	2026-09-04 17:25:35.847851+00	94af2576-7982-48f9-a561-5d5e2037db39
4e8ed904-bc25-4303-a5c2-45d367d4e629	6311f079-8c03-46c5-81a1-e1ebc45c06b7	1	114.95	2026-10-01	f	\N	2026-09-23 13:14:37.176689+00	08f5135a-d4a3-4093-8a7c-d02b2727e4df
610b543f-1450-4a93-8806-07e5e52f9907	6311f079-8c03-46c5-81a1-e1ebc45c06b7	2	114.95	2026-11-01	f	\N	2026-09-23 13:14:37.176689+00	08f5135a-d4a3-4093-8a7c-d02b2727e4df
\.


--
-- Data for Name: estoque; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.estoque (id, tamanho_id, codigo_barras, quantidade, produto_id) FROM stdin;
8e5a5918-0ae0-4cde-8e36-9ba55c30857d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	bbcba1b7-c542-4e19-92c7-df58f537cc63
d7e08929-d786-41d6-af6e-4d171d1ef16d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	24d8a866-2155-4fdb-9d96-d46c996b7b33
a004b512-bb25-4e7e-9cc4-6f9e8a5482bc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	24d8a866-2155-4fdb-9d96-d46c996b7b33
e85fd066-61cd-4db4-8bf3-8a139753c41c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1b9c4839-a0e6-4f8b-bdbc-28f0753d4329
1826747e-dd24-46fc-a66e-b8f4c34dad12	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2a2efbb1-4ff4-494c-8249-8509f0d5b2b9
196296d7-383a-43ef-8651-260b8d0e9ced	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d90fc150-1d5a-4f27-988d-009d35eb6208
ba3976d7-6fae-48f7-bf65-e3bd5caf8116	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735
a096aebf-f43b-4262-8c4d-cb324188871b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e37154ed-ab5d-4afb-a128-bf216c3f61e5
ddeb6f86-b9a4-4e52-bd72-6559650d94a8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0dba3d38-30b5-4ae1-ace9-98357a7185de
f1a3d9dc-d777-4bff-9337-45af444ce0a6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	437b0672-0343-4c5b-905e-178b1335b989
34c593ac-6dec-4be6-9ab0-fbdcf7093e45	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	7dff2a36-5d91-4e59-bb59-5992219a424f
a61d99c0-824e-4a9e-965d-004d263989ca	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	263dd6e2-b4e8-403f-a36b-91fe37617d1c
84e1268f-6138-40c2-8625-866abeb4ab07	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	870ee767-6395-4972-a6df-842ec8e56163
157cc385-0bb5-489f-98ee-28d7a4fae250	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8f699409-f2a8-4435-8b0a-7dec0fe9f9ff
8ad0d66a-9b2b-4de4-b9e6-64e766c4e6b4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5b0303c9-e6b0-49ef-b4ed-95f34b8378ee
785d57bd-a74e-4834-aa98-94580a5c692b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	6c4d8e31-0d88-4ce5-b5a6-6cd127c673f0
24c95eb3-1683-4c71-a42b-9ea95a78db1a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1196c057-6651-4221-b508-168b34eae212
563a33d3-e81b-4e20-b6d9-50ba01bcf2f5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	753da075-b425-4017-a158-ffc3439080da
b8766c46-882a-49e2-bc28-db998b83e1f9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	cca084fb-beb8-44ba-aadd-e113cb1b3ea4
db3c10e9-12b7-4bc6-ab17-06192669ae60	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	fb6ada2a-d736-4f84-973a-0e74cd0d511a
ea99c435-d81a-4bb1-b419-b9da61a470ea	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	fb6ada2a-d736-4f84-973a-0e74cd0d511a
4a5cdd1d-9fb6-4e45-8b92-51b1395f063d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	6285de86-72ae-494c-896e-2089dab313a4
fe29494f-ad60-4d19-9f9b-7f67347aed77	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ecfc88c2-959c-42d7-92a1-cb6108b8330c
67406aeb-e793-44b9-8bae-3f6692408215	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5275a586-1b84-462a-b6f0-4eb0684d9cfe
d9cb7c75-5c33-451f-84aa-9f825ba1a7df	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	cd479f88-5df1-4756-8c2d-c1ab84b9fb67
92594743-5f3a-42c4-bf08-0d98d8bf04fd	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	68eee4c1-6ae7-4045-a26d-4ccd7176df43
a93a6ec4-4d0f-497c-b6d2-359e4179b190	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b70e4e91-97dc-47bd-8145-cc47cd6c4d76
b6e04f6d-0600-48f7-88d0-e04cc0b71dcc	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	6f62ece9-e90b-491f-8545-4a95dafd4333
80917f3b-4c81-4d81-83f6-26c9a8c95876	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c8bdd838-eaa4-43de-8086-821d7afa061c
17824613-d7b5-4f02-a599-19d011fdc6bc	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	8a010270-dd77-4bae-b479-312888222b7e
e384ad34-7e87-4cee-acef-9d59bbd00895	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	6b2b4cd3-7722-463a-b9b7-b9ff98a3fd79
bb1f7477-8e9a-49d2-92b3-780f332b3a59	05e02b30-0867-4b3b-8518-0a0805db9706	\N	1	6b2b4cd3-7722-463a-b9b7-b9ff98a3fd79
cf41fecb-bd90-42a7-a662-2906db100b7c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e9cd840d-7841-4501-bef1-d98121c15833
0349af55-a232-4e9c-b61e-7d016e3d6ac0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	f6fb68a7-c01d-4417-94d2-0922286b048d
f5b6ae4e-6d64-49cd-adb3-481e25e11702	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f5cf970b-cd2e-4074-ba56-ff9f6eed6013
077cf614-9734-404b-96bd-ea4bc0f574c2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	166da7ab-bc8a-4ff7-9bbe-1295d3c8d018
608e0d14-b6f1-48ff-b4a5-d53a50f1bde7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1aeaf07c-7ac5-4914-932f-01e637ac21bb
bb8b0c8e-97aa-4042-a7f7-7209a8f902e8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c76c15fa-3429-45fe-986a-d38dd9065e4f
1273290d-dfa4-4f70-8817-e3a3b06d717d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ab5cde9d-8617-4a59-ba71-23823bc4972b
2b562d6a-72fc-4a06-ba69-eb51fbdbf2c0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ab5cde9d-8617-4a59-ba71-23823bc4972b
f82715c8-af50-4a29-b4cf-b879180c0e35	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	7f9e2a22-cbe1-4b3f-979d-1f58e1fbbb97
e45d3cb9-b50f-4e3b-b136-7a111f8b150c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f438b6f9-4793-4180-be63-cc904f0c76b2
fcb4fe42-2c33-4ac6-8407-2be2fd258c91	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	78ab4a79-1959-47b7-b3d3-f3050f815489
6506df1e-2c80-4b16-b589-f331e83d80b3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	78ab4a79-1959-47b7-b3d3-f3050f815489
6d3a8674-10f7-4beb-87ad-2688f7327586	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	78ab4a79-1959-47b7-b3d3-f3050f815489
42e07bfc-b4b1-4adf-8f49-52483666991d	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	06407111-0b94-4b5a-be8c-b03601192c0f
2d883cfb-fd9f-4806-84c1-b81dbf60c146	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e640cbfb-4205-4826-9f51-6c5db0b6f6a3
95eafabe-563c-43e0-b40c-6e6234303922	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	aeb598db-17f0-4e9a-8804-cc5d10b440d4
b4ff50ac-01c6-4637-b57f-89e9cebd339f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	48999143-c489-469b-b0f4-d13827a99571
dfdfead2-4217-414a-905c-d7777d63c7e0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	5222e144-e660-49e4-98a8-45093105323e
aa893995-8384-40cb-b085-95637b820766	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3ac1ddca-642d-4e59-be7f-6db747165549
3beff6a8-8b89-4cbb-a2f5-303df6e31488	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	32abbbfd-598e-4841-acda-3308c99d10a8
9d795b3e-da62-47e3-9705-4e86d71cab3e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	68eee4c1-6ae7-4045-a26d-4ccd7176df43
55c84366-063e-41d5-a7f5-ed0680b92bf4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3ac1ddca-642d-4e59-be7f-6db747165549
56f7787a-a393-44cf-8c7a-72cc4b4e26a1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	d9127c0d-1b71-427e-9991-34814b25e8f2
fdb93948-d13a-4ec6-b620-8ed952063c19	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bab94c54-9ef3-4197-9f5c-a0bbe357d309
a4b10422-eb8a-49ad-b71d-a51eebb297dc	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	d88b3467-2808-4435-8722-330c89f4dc47
603b2c41-5a04-4f95-8720-4e2502e5ad76	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	abf441fa-cbdd-4904-ba8b-65c70f37f53b
5a315735-4c8e-48d0-9e28-795491ffcb1c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d90fc150-1d5a-4f27-988d-009d35eb6208
5a55a8bd-ef0d-413a-af52-13cddcd5fe5c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	87e4682f-f04a-4e7c-88e9-0829fda3d325
1ee2217d-fbed-4368-ba3f-9f863bba7e7e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	02ca7973-0ef3-4180-8774-3fb42e9642cd
f412fc18-975f-4407-a027-5614279dd73f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0ef1c1c9-8c50-44e9-98c1-89a87e856803
f7bb6311-0a98-435c-921f-e00907077b28	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	ea9742b4-b495-4787-a7cd-f53352a29c99
97f6d8a5-1f4a-4845-bce4-47dcc56e4940	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	324a4866-e38e-4841-b189-c834b04f5205
363fd144-651e-4fb6-886c-d66dfcf699ae	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	59aec366-a55e-4aa9-88d8-5659a6ce3af5
94458769-1634-4f21-b50a-462ea40544ae	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735
8377a140-818f-4921-b37b-7a6ac6cd7fc3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	d90fc150-1d5a-4f27-988d-009d35eb6208
cb482c80-134b-4d20-b2c2-d0f158c1f484	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ddfc3385-ddc8-4ade-bac2-7bdc6fbfa9a5
7ba17a00-a4a1-408d-b828-9d4bf89a3d37	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	3ac1ddca-642d-4e59-be7f-6db747165549
1932f258-21bc-468c-81e3-d62ab756eb4b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	aeb598db-17f0-4e9a-8804-cc5d10b440d4
cbcd20e1-a8dc-4301-bf43-ce82920947ac	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	484e09bc-a947-442b-928c-bd89a7e0c5cb
6cee7333-fc39-4a75-81e1-851a51c098e8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	4b80ba74-7234-4662-b19d-5e730e7f9571
38d1e418-8821-41eb-8d73-9ad2b2bab5d3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ca957b05-f901-457a-bb3f-4d2f51560b34
bc83dd95-a582-4bde-a0f3-53e6295bc385	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e7a1f608-edb7-45e8-8a90-424636a6aee7
3a1a092c-a046-4599-90e1-ad6d3ea17727	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	395d35c2-9a98-4deb-a529-575292209199
05633d1a-5089-4f69-a747-c1c7f62e1fe1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c63e0319-a5ae-463e-9b82-b98bb96a604d
7800beee-c9eb-4c0d-b1e3-ff676a126bf4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	ddfc3385-ddc8-4ade-bac2-7bdc6fbfa9a5
6af2802c-98dd-4c71-946b-a577b11f85cc	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	fc092e25-e25b-4cf5-abb7-ce6881fd3a54
c54dd10d-2c90-4b3a-859b-8f867ed33336	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f6c11475-b890-40e4-90d7-bd6a63a7af3b
b1c82ce9-c98b-4ae1-99b3-1d3a9a41833a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4c744423-e7a5-44a9-88d9-9ae2bcee022b
ad8c7e30-f86e-4b38-8c54-0f3e47a32dc0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	498a47fd-de22-4035-ad7a-00e679abeba4
95291201-69dc-4567-9201-3a775af3ce09	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a22bb2c5-11d9-497c-bad0-5be877f784d4
2859c8ae-dbe1-479a-9f06-d0eb0a67744c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	17651cc2-5ea4-4d8b-9a28-d829bcfa1abe
bdc06cd3-84ea-4e18-b4ae-91e4179e0f14	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	7223beff-dc9d-4b53-8c4c-658b3763a6ea
6e20f91b-b422-4709-8061-ddc2e0866a83	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	00a58446-4e64-4cf1-9bf8-caae7a3a1ac1
dce37737-eca0-4dfc-8135-3d4b7cfd5fa5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ea9742b4-b495-4787-a7cd-f53352a29c99
66eb0847-f223-4901-b443-92f0d88a8a81	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	498a47fd-de22-4035-ad7a-00e679abeba4
c937de3b-45fb-4ae8-9222-94de80902db9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	87e4682f-f04a-4e7c-88e9-0829fda3d325
7b12243b-5204-43db-b9cd-50f777b2917a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	7eaeb75b-ea96-45fc-98fd-b6cd7063aee8
fd9638d0-7c8f-49ce-82e1-9f28a8c46172	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4f2c3123-b08d-4515-8cde-dfcff86273bc
68c55fdf-39c0-459e-9719-ed42da2dc2af	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	70604eae-b5d8-4a80-9999-58b39f210865
c3949965-2005-4f23-9189-31068e7da0ec	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735
07df0de9-1e1b-428d-aa16-40b34e9bcf60	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	e640cbfb-4205-4826-9f51-6c5db0b6f6a3
0612f63f-4b7f-49f7-97e2-6db60533712a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4bb37cc9-72b8-40b6-b4e3-d4aa4ebe67f7
ec86116f-57f7-4e01-8193-578bcf8d9f47	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	32a7a79b-c8f5-4e09-8182-1944d1de5871
169dc603-67df-4cbe-8c35-57a65222e96a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f5dd7fd3-05fb-4fd3-be0e-1931e62400ec
3ad2d494-5e4b-454e-b023-8c7267d7a6b9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	629803ab-5af1-4d33-952e-439da2d8c1c1
664a0872-a97f-4fb3-ab98-d2c3b1970b2f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	629803ab-5af1-4d33-952e-439da2d8c1c1
95fef65d-24f3-43c8-aca1-ce3ca1154f77	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a88f20ac-2cdd-448f-8ecc-83301fd91232
2589ae9e-774a-4ae8-8506-a93d161086b4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4edfee0b-4759-4c94-8f6d-0c7faf1d696a
41488c5c-c0f7-4780-8591-28bfdfd61616	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4edfee0b-4759-4c94-8f6d-0c7faf1d696a
ada7a879-7bd4-4bcf-9bf2-026694c2ef1f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7d44dcae-2896-4cc3-a263-0fa96255ee45
a580ad4b-0050-4d9e-ba92-50c64c17ee03	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ee417b1f-2f0c-418b-94ef-4864d15d4658
322803d4-73a3-468e-be18-d14c91318039	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ee417b1f-2f0c-418b-94ef-4864d15d4658
f8cbc10d-20cc-4a4a-b4c4-c28c3411ebda	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c4c02bd8-32b4-4477-944e-359394fe8d3d
dca3e1d1-41a9-4e95-82a7-c504bcc5d90c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	10b05256-8c65-4a61-b046-7f5e5ce22ae9
b1a9caf7-0c35-412e-817f-2436229e0d0f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4659bbd2-b530-4d22-80fb-d3bf752e4169
10660a6b-8781-4eab-a1ed-af9565782e41	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	d1cef6b1-1344-414a-a7dc-f871f502c42a
6bf42af1-38b6-4732-9992-72254888acf1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2eedfd04-a261-4e1f-80e7-569c5c6e05b9
d87e8a5a-61c0-47b6-b39e-408099a31605	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1e7430fa-ca57-41dc-a6ae-e879229da39b
44b361c3-5589-44e7-80e0-65cec451d0b4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	546abfef-6887-47c3-8357-f9f549784f09
fc04642c-92c0-4528-9020-fbfd5ca86d95	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	de16a930-eaac-4821-a2d8-241f58309991
29b6893d-2606-4cde-8d98-9e347cbac991	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	714c73bc-4dcb-4d63-93e3-7871bf8af0bb
1df322a6-d4cc-43dd-a29a-6786b6aab659	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	665b3def-961c-4622-8c39-383a27f90e11
9dd6969c-2525-42fc-8a10-c4ca62fa9082	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	06941075-893f-4448-b265-9ad9c812b79f
f27c1c16-9a5d-403e-b14b-79b321f09d33	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	076a4890-e615-4d78-a90d-0163749b7bcc
9d2401a3-32e0-4862-b71e-ab9ed5db41c6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3fbdb66b-d910-435f-b711-72813863cddb
2b8da178-8803-4397-b0b8-e0891b1d86d5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3fbdb66b-d910-435f-b711-72813863cddb
91c08285-ce06-4854-a825-a03074187b5f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f4d73fad-c742-4a57-bc32-aec016eeee73
356fa11f-3134-478a-934d-236edc754418	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3c7b3a5f-f1aa-4f5a-bba2-c34c2c28fb77
0be14d02-65f5-4287-aef1-438e07d680c5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	98421a47-135d-40a1-91f6-2f93c718f08b
9ab47f0c-38de-4ee1-86ba-7ca9102531d0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2a072449-b424-45a7-8b27-bd3d72d50dfe
dbd5cba0-f5d2-4c4f-8e06-27fcf36524bd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	93151ba2-86b2-4cd9-8f3b-207c55ebae57
e13d559d-03bf-43a8-91ef-29aaee1ce524	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	93151ba2-86b2-4cd9-8f3b-207c55ebae57
9b567957-c201-4bfa-90d9-510530cf7ac1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	48bbde29-773a-414d-93fd-005ae14f6e5a
5f73654b-24fd-443f-b42d-535ba8333181	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	81ddfb56-c909-4b6c-8acd-2bc33e5516d5
833826ed-470c-4863-ab1c-763e84c9911b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	901030fe-f800-403c-863a-3714907a8816
8496660b-cb62-4838-b715-0d2d4fc042bc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	a34ab995-352a-4372-b146-d5cd1824f9ae
a3d74298-9aaf-43ff-bbe9-90b1602849c1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0f66d00d-9186-4d6d-b34e-46f468a0eebf
3aaa0ffc-81d9-4be6-8062-994a3cb910a2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5cf3abf2-83b4-498b-9d73-6def36cdbb73
a4e1d4de-113a-4d0b-970c-eada18174e31	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a9a02cf1-6036-425e-bbe2-1a4966fcecf3
e6f98f63-c7c3-4a63-8e79-01ab555b1ddf	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d60c95e7-2789-4e1a-a865-f58b037f5d1e
ea976828-857b-4cbb-a605-4fe70bb20bc3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	6e056781-f22f-4806-bdde-c66288659526
61afc0f6-b0e0-4db6-be40-ca28aa408703	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	70d64c00-4d7d-4b67-9cee-739ca9d062d0
2361a7b3-0efb-4c26-ad48-82db709dcaf6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	45ab48a9-9bb8-479a-ac06-8493a16f661b
e7c0d408-6370-489c-bce5-f2d0f8acbfcf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	74d58012-c42e-41c9-b4e9-14a3f046e43f
58c0eb7c-a992-4a7e-b5a6-e7b9fd91d58f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	749ede5e-8fd6-4cd9-bb4b-0f52b100de12
d3a0c32a-41d2-4326-9c28-54ae96820938	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bca813d2-0870-4fb4-b690-3b8ce744ca3c
865504d6-468f-4063-b7e7-0f1e3b5c2e4c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	8d43f80f-32fc-4b5f-9ba5-feee72d699b3
ab591b52-7a54-4482-9414-e5e4782ec9b8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	424d591a-67df-4b58-b24c-847287c57fe5
2c796035-dfb8-4973-b996-4120bab89572	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8d43f80f-32fc-4b5f-9ba5-feee72d699b3
e54831a6-130e-414d-8ab9-86d9a60f589f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	982f6554-aea1-48cf-b717-c62f92de6568
d2cb5239-4cac-4846-bb93-407e1c856d46	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8fa37df0-d45e-4e32-a938-707801477ad0
ce9763c4-a3fd-4a78-8d16-82938be0b578	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2
f0f05d59-8219-41bd-aae7-4aa9cd94e525	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	0f66d00d-9186-4d6d-b34e-46f468a0eebf
a36e87f2-a98f-42bd-9263-77bb020a18d1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	dbc5252a-ad89-4603-9fd3-960f017fa9e2
b4be9f34-2a17-429b-a794-db242659b726	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ecfe6c61-24fe-406d-a552-31ef3a28b4e3
6b48fd1c-5cfa-4d8e-8e55-ea3512181c12	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	f6035591-635d-44b0-9217-87e80cb5acab
c9cd8f90-a0ad-459a-a6f4-521719d1ee99	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	6f6a7e5e-8263-429f-b753-e2175699836b
0ed76af2-9d96-4975-8adc-c777d432b552	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	32a6d01e-f913-44e2-9872-c04f433046fb
45274db3-9498-498e-8677-a55eae545d3f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	d6f3a94c-f481-4ce2-a8ac-5bc0cf146b72
46dacd9f-da4c-4698-8a74-0b860f285a83	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6bba510d-f3a4-4806-ab18-5d2095022144
4549bbfc-42a3-4497-92d1-9b59d525e639	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d69c6f1a-ffb2-4faf-aa55-974f59e94bf4
e180cb2a-24e8-4c98-8e40-73fe9c09feb1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	d69c6f1a-ffb2-4faf-aa55-974f59e94bf4
49ef1864-67c4-410f-a6ae-4f6765de1499	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	c4c02bd8-32b4-4477-944e-359394fe8d3d
1af5462d-485b-4b8b-816b-132f413223d1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3aef3c68-a258-4f54-9526-223fda41c8aa
452a8ede-1bed-44df-84c5-f649ba8f2c76	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	10b05256-8c65-4a61-b046-7f5e5ce22ae9
97596847-81d8-457a-9699-c82c7a49241c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	acdbdc4b-b73c-4199-884b-1dd0db809e91
5f7ae9e5-93c2-4413-98b7-0951beb39e1a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f1e2c779-0cb7-4341-a46b-b7aac9105bd2
014de473-3ddb-4e33-ae54-7c6094006f44	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	f4d73fad-c742-4a57-bc32-aec016eeee73
caaf5418-8dc6-4ffe-8d4c-7e9d03b05358	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	fb0297cc-dc85-4d25-8294-28a449672fc9
ed2e601e-dc29-4faa-9e56-ccb6f1d53193	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ce9a4cf1-d4e1-4699-b547-373ab022c6c6
62d1825e-cea5-44d0-8f3f-f519bf7c0d7e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	4f7973c8-04fb-4671-8819-74aa2dee4038
13ca4db3-1d57-4500-8e74-3d49bef1cc4d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b550dd7b-3d20-4049-88ec-0b09875a58b1
b9e11ed1-3aa2-47b1-999e-40f1de8c7681	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	97fba60a-fae3-497d-bd3a-081ba65a7d11
7ce6f7d2-1017-44c1-8193-8adf447cdcb4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	75ed12b3-85f8-4292-8d72-aee071febf28
e3ad9ba7-3a9a-42c8-a871-582c6fcd2249	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ff195db1-072f-4d00-b808-4fceeb13362a
6e9791e5-e873-43d3-95b6-5238dc0950ac	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	665b3def-961c-4622-8c39-383a27f90e11
eca6363c-e468-4972-b7ad-35d6bde76c58	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c74b9db9-716a-46ba-b5a4-11b3983ae74d
1f891cf5-f1a8-43be-8e67-f683a6852e84	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	97fba60a-fae3-497d-bd3a-081ba65a7d11
516a0ba3-6cb1-4fc3-8322-98b07b6819a5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a88f20ac-2cdd-448f-8ecc-83301fd91232
167d3dbb-495f-4b62-a83c-22d1e6ddf5f9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	8d43f80f-32fc-4b5f-9ba5-feee72d699b3
eaa14fa9-058d-4077-892a-f93ad34d19c2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d1cef6b1-1344-414a-a7dc-f871f502c42a
5af797e2-95a7-4d36-a552-9fe7ba6e5d2a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b550dd7b-3d20-4049-88ec-0b09875a58b1
5988b96a-b0c7-4d01-a46b-810d613d3e42	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8fa37df0-d45e-4e32-a938-707801477ad0
301c1a09-1bcc-4eb0-85dd-a58cad70c86c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2
feae30cd-25b5-4a1f-9ed4-61761884a0ee	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4e36014a-55f9-497d-935a-8d1e4694a596
3ae6256b-d402-4e27-bd50-38c153d5d153	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d61bf2c1-9320-4a1b-9b7c-5d51c0ae1a00
ec9efcf6-3129-432b-963c-b448af1a9412	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f9ecc97f-22e3-4b87-abb6-f1ff65cd95be
14847523-18eb-492e-b48c-e1f114d3af9f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	32c571f7-ef80-4948-a2ad-18e0771263a6
cfedb2c2-7b58-479a-9782-c3c4f4418612	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	7f22cf72-8496-41f6-821d-334ffd96a556
1a193382-f6d3-49a0-a4fe-43fcb616bb6f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d495480f-e043-47f9-a70e-7b79eea14777
1290cbd9-00b2-407d-9d07-4dc2b49dcf8e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	2a072449-b424-45a7-8b27-bd3d72d50dfe
1aa7519b-f22c-44d6-9eda-b4cd8f1a0c3f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a1368013-65de-43a2-8f20-e4291147b298
a4f01980-cafa-4b9b-ac67-b174139f3a8a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	d1c4ced5-0e3e-4c44-8f20-9d559bc13a43
4dd9fed3-aded-40f3-aac5-8750a3bdef7a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	133ceda7-5f0f-40c2-a994-cff417dc9e2b
27b21e13-fd06-4044-879d-c8c17978582a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b0b1e84f-3b81-468c-9b4d-4fb6819d9d2d
1d0fe279-7a9f-4cdf-bdf2-80cce377aa6f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	810df6a5-30b2-481d-bb29-e84596b54f6b
9ce07640-309a-4e83-9a80-a42da3d93c89	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	810df6a5-30b2-481d-bb29-e84596b54f6b
ba233488-f895-43e4-988f-0d6e58975dd5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a1512a34-000d-4db6-92d4-30a445282977
3855b472-98f0-45b1-9bb3-5658a3bfd4e4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e6dcde65-5c3d-4edb-98af-3dd0b6bd878c
b8d78dd6-797e-4688-9012-129b91235369	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	93bd5d41-ce0e-481d-86ae-f466a371adf8
4292bfac-2284-44cd-9acf-b9f908ceb891	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	fba58f93-8a7d-48f3-8008-608ba8dcf407
4bb4a46a-5887-47e0-b70b-1d7eae901d9f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b5bbae07-250d-478b-9fe9-b641f8f64561
7664ac59-45f9-429a-bfe3-e990b967e0af	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ed3fed61-279f-42a1-95f8-15b43036464a
cf7e23bf-ccd6-451a-81de-b49a228188c3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c859f056-4e38-4fb1-88ae-0ff574625416
1d6eea7b-6f0f-4fcd-86a4-9adf8c0d75cf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c859f056-4e38-4fb1-88ae-0ff574625416
ef88bdf4-f828-4aac-995b-be0fefb931f7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b08361e8-e792-49e3-bbfc-df7230e45714
14c93d11-b47d-4a8e-8d58-5f7c57ac0465	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b08361e8-e792-49e3-bbfc-df7230e45714
6cb6fa5d-0d94-43fb-a946-b99c04f88658	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	03c428f1-287d-4195-9cb0-44906ca53ce6
45c570dc-d08d-4b77-ab0e-bbf623068895	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8127c5c0-e3b9-445e-8b63-47335531be49
5e02a55b-e788-4990-82e8-79fe0e8e3fa5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0f044716-0ce3-4984-bc8c-4a6f00c8c8c7
420ffab2-6191-48f9-9b68-16c607430b2b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	97fba60a-fae3-497d-bd3a-081ba65a7d11
fec44e40-4b84-48c2-80cb-11f92dd4ee87	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	b49bac40-5aca-44ea-91f9-36b138fae931
a8693c10-6878-4e80-bfc7-d3dc592312d5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b6f403e1-f88c-4232-87db-7ea4b8713d05
cbee71b9-88db-4177-858e-a951226e5003	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6ab17bb2-6aa5-47ab-8d06-9657943a92a0
2c8796bf-aa68-4b96-bb64-f675e8efcfc2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	fac47062-4296-46a9-845f-ae567089a3f9
1d292321-bc10-483f-97f7-e3582a7db7d4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a8f9fedc-57eb-402f-b5a8-65f03b97f1a8
f9fbf375-d64e-48bf-a58d-ad1960422695	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3821f950-75b1-42be-94ce-514ac77674de
aac84a58-110a-4f6a-b90c-7137cad08c72	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	d8c4b2ca-77cb-4f6b-bd05-969eec7fe34d
f713413c-9270-41ab-8586-d0c093578732	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	45ab48a9-9bb8-479a-ac06-8493a16f661b
96c98c01-f7d2-40a4-8b4e-a817f12f2efa	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bef92425-0281-4d62-b06e-607e557d8c9d
f75ad8bb-51cc-4140-bd74-080d0c4ebb70	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3eb37bde-1dcf-4f9a-9e08-8c1d605d5677
52cd8cda-11d0-4b44-8cce-a56e2937a4a6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	2c8461c4-e54d-44cf-b630-aaabb5572c1e
5b22f16f-ad5b-477e-97f8-ac3429e89300	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	efd9997b-9730-4b62-90ac-cf329487482a
9f36b513-d275-42fb-bee5-008f84ae1dd0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0bd12109-1bc9-4aca-bbeb-4a830e1e189b
c41d4020-caed-4a37-b2dd-b6810fe86228	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	628d2222-2c97-4bae-bb3d-8dc41a48f187
a5a4ec83-de5f-4b28-82f4-c03a05e98b43	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b226cbb8-5781-41b3-8647-a2b88fe9cf58
452a30ba-cdb5-441c-a126-20c115923028	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c1de500b-d49f-42e2-ae2b-b67e1d8b495d
d7fa264a-44ff-447b-9d24-6515065737f9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	21f63dde-aa95-4131-ab22-e8726166ce0d
dccd39b5-09b5-4820-89d4-2ee89cf3279f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ace6e53f-58f0-4935-8a7c-78fbd4ffdf46
36a6a4c8-ad01-46d2-b845-c20cfd789ff3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c9052f3f-10d3-4641-b067-808fa8dedd85
7a7dbfa6-ae12-416a-a069-c3ec644eb87d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	b6c34d57-c96f-42c2-8af7-2fa01667273f
ecd65831-2eaa-4eae-94d0-aa97ecd84e83	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	2482e124-00de-4933-94c9-6ef22273f033
5904857d-0456-4f6d-8e7a-2821df3d1e57	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	0fdea5e8-ce59-4581-a6dc-16be6cf0b27f
e5302994-a274-4761-b0b1-dba6d0611960	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	0fdea5e8-ce59-4581-a6dc-16be6cf0b27f
7936372b-14ad-495a-ac9d-2536d61ec7d3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3
e91bad99-7519-4f35-b628-b1de421dc45a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1461ace4-6809-494e-a5a0-17eb0ab766e1
c1589003-52a9-46bd-8f02-9afe067d9cdf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1461ace4-6809-494e-a5a0-17eb0ab766e1
34a15cc5-7553-49c1-a542-a3ccfb32f69b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	1461ace4-6809-494e-a5a0-17eb0ab766e1
92f4392c-60d8-43a7-a8f6-55e9cc9f51af	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	97a1ff92-f4a2-4f35-9d24-231c598fd6b9
29281280-bd58-40b1-b022-df7658ce5455	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	3	94d5e287-ab10-4835-bd37-6b0f58171be2
9e63ace6-1afd-4f0a-aa08-8ef76bd3e62f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	94d5e287-ab10-4835-bd37-6b0f58171be2
4fb833bb-6d33-4b58-bbe0-256430bbdafa	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	68561129-9cd1-4cbc-b434-a2e9da1a8d61
2035ea08-4a9d-4b35-a54b-c6881d273efd	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2b760f88-2bba-42f7-8a5d-4da95c1b864c
c6e5f0af-0f98-4c50-8700-93c9d52d17c7	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	8bfdd37a-d956-4320-975c-b0ac0a319317
7569007b-e10f-4b4e-a00a-8a6390a9bd0e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	fac47062-4296-46a9-845f-ae567089a3f9
ea89669b-68dd-46b0-9d1c-1d72bc562b85	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4f61e39d-59f6-4273-8804-94a48c7e068a
2caca9a6-d4e7-4f76-a609-5977f7eab1ef	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	68561129-9cd1-4cbc-b434-a2e9da1a8d61
eb1f3f57-3db5-44b5-89df-c43d00cb6180	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6e056781-f22f-4806-bdde-c66288659526
838efb1b-c446-4e50-8be7-0cbac9b75f35	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	511252b4-4a5e-433a-ac9d-e31fd182144a
39643bff-b61d-475f-8eba-8049c1b4ad6e	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	628d2222-2c97-4bae-bb3d-8dc41a48f187
9b45278d-6622-4671-96a1-de2e623d9528	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	21f63dde-aa95-4131-ab22-e8726166ce0d
90ae99a0-29cd-4044-9ea1-880fd4adf77f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	cec93d51-6aeb-484f-a139-cac515ba14c9
67155dd7-287a-4613-ac1e-722555f7926a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	a592bf06-b2ab-486c-8373-545c90dc2ff0
072524df-8db6-4b87-a9de-b2b6687eedd7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	36d81da0-e329-4843-8d92-f91d82256467
50fd6f77-8dde-4ce9-af85-bcd6b812c6e5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	23fb179e-1177-4a97-961b-35b11922582f
f59734be-2b4a-48cc-a4d5-bdfa168e64d7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bdb8a6de-0cf6-41d9-8acd-244113c3bf13
3cdc999c-529c-4f05-8364-b6d04ae2246c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3131bb7b-5f21-4483-a4fd-e6a5242faff6
c2a2519c-7e88-45cf-939f-b89d091cf0e4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	cda5a2f7-8a67-4766-bdd6-bbc712cad09b
58678fd8-50a7-4b71-96ee-c7925eecefc2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b6c34d57-c96f-42c2-8af7-2fa01667273f
5597afe8-d4ca-47db-adf7-03cb3166b2a5	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	fac47062-4296-46a9-845f-ae567089a3f9
f443b4bc-1db5-42e3-b8e3-9ea929da2cc6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3
5a349db8-db46-414b-ad07-656de44b89c0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	97e44051-9e10-45e5-a711-72817bb30a3b
f43c1c8b-3be5-427d-b00b-70b0ef124965	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bfba079a-f6ab-4577-8619-53f3ba184a4a
06a88a59-6bbd-4017-b199-627843a0f16d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	063ce64c-6690-475d-96d0-1930e7d65cf2
3ebf2e00-bcbf-49ee-b558-3d13214c38e1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3d294cbf-70af-48ee-a64b-3128fa402808
2fa2d11c-cae3-4f8a-a4b9-28be3cb303c1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	133ceda7-5f0f-40c2-a994-cff417dc9e2b
cb6655af-e2f3-4623-8bf7-581a010a4488	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	94d5e287-ab10-4835-bd37-6b0f58171be2
19a77653-561b-4050-a31e-30ba6e4d8721	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4c514054-93ff-408e-8c50-8420cf8e0e59
172ba8be-3584-46ae-9f08-5a459a30c445	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d9010f7d-2788-41a1-b104-8e82bbdee1f2
b9286f2a-9a47-42ef-936b-09bdfa570f06	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4f61e39d-59f6-4273-8804-94a48c7e068a
8a548f43-0ad2-4df5-bebe-fb2aff03165d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3
d56e4138-6ba4-4d4b-a658-c0e35f28f0ea	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	628d2222-2c97-4bae-bb3d-8dc41a48f187
c749bda2-13a8-481a-b3c7-9fa5bdd10e07	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cda5a2f7-8a67-4766-bdd6-bbc712cad09b
3e1b9c84-c683-422a-9b4f-f024f82a05d2	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	bfba079a-f6ab-4577-8619-53f3ba184a4a
6cdb1b7f-bf3b-4cdc-8191-e8b9bce53c09	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a76afd4d-507a-49bc-816b-4d7d3f5a3a69
d1bf2c62-cad2-4c93-85b8-77bf04e5f850	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	93bd5d41-ce0e-481d-86ae-f466a371adf8
cb16b25d-4e95-488b-b5ab-a7d83264c334	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	cda5a2f7-8a67-4766-bdd6-bbc712cad09b
6b8f8929-d6b9-456e-84fc-5e249eff9a7a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	aae971a1-9054-47ca-99ca-8d2d58524cb4
bec2e856-e6d6-418f-bdd5-87242dcac858	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cec93d51-6aeb-484f-a139-cac515ba14c9
bb07c323-a2e1-4eae-8c6c-bc19cd661351	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	cec93d51-6aeb-484f-a139-cac515ba14c9
73d64d22-dc52-4ea2-8a57-bfd2320393b2	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	ce60564c-7257-4134-ab7c-725150da593e
c96fff3c-af22-4ad4-a1b6-3712c1bb20c8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	2b760f88-2bba-42f7-8a5d-4da95c1b864c
7c8c256c-9869-4095-887a-77910abeea43	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2b760f88-2bba-42f7-8a5d-4da95c1b864c
8e9888cf-5aec-47ee-9fbc-be6a6b89c144	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	cec11c74-39a6-489c-a603-ab4ae4a3b1ff
bdf20933-eea0-46d9-bc5c-96a0e4fe8788	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	bd47c449-4163-4b39-a7a7-14083553b056
4b09b7be-05a2-4940-9587-815f5edf1b18	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	d35665ce-46f4-4b59-a491-eb22731c6422
209d6cce-caf6-4cb7-950b-66daa6c90c3c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	66ff3218-0f96-4717-8e6a-967d40e6b736
45e28788-3f1a-42cc-b84e-94d06278ae96	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	66ff3218-0f96-4717-8e6a-967d40e6b736
d999806c-d117-44ec-8672-6795b81dd6a5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e289df1e-64bb-4091-8c72-0c72aec52501
19a8a498-638a-4783-8382-c43005ad07cd	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	e289df1e-64bb-4091-8c72-0c72aec52501
9cbd7672-c203-457f-84d3-9f023ca52da3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	bfcc1f5d-691a-43e0-80f4-d6d7b87404b9
b5d783a0-203c-4b27-9801-265d71dc7ce3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	bfcc1f5d-691a-43e0-80f4-d6d7b87404b9
483e6a82-493f-442c-9975-e173512b7b2c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3461894e-b04c-4295-8c83-17ee8bcac3f7
68ac1efd-8d5f-4918-a5c2-d9ecc31fb078	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	597f8eee-6577-4da4-9db9-24022243d8ce
12dee05f-fc29-4cff-bea5-b5d1b1776abd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	227b75b5-3579-432d-b6ff-8c115323186d
bd8d0687-378a-42c9-997d-29bfc0995c87	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1fb4200e-1c94-4dd8-8107-cdbe29c66158
a6930f94-2c04-4641-b240-8551e57cc6e2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e90473b4-52a3-476e-b132-2a33caa81ee6
cfdb96dc-8f76-4a76-aae1-193fd68dba4b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5004a2d6-dabd-448a-b318-6c1be0952e81
e8eb3b62-adfd-41f8-9f6e-0293308ab8fa	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8c39e65a-756a-4a23-b4ff-358643ab6fa0
d2299cc3-fa8c-4f35-8be2-d8958a79441f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c5a4b82c-029b-4f7a-96e5-c2298729d874
8e2a3323-125c-4c61-9ee4-c96b347d9bfc	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f
a5c60131-2286-4f86-9507-b894fca49c8b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7513ef03-93f3-43ae-99cf-93749679bb1d
4eef9098-8cb9-4c51-ba93-e722bb71a10e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	83ad5336-0f31-494c-b249-7ff2edfc1814
af95637a-6388-4bb9-8d5a-b2513f9ffdf5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2105858a-d98b-4d00-b607-d618524b7e24
7dd672b3-f2b2-4a49-a6e5-e8af18e51c0f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	313449c2-742e-466c-9229-5a66c4105768
e1390e7b-6e2b-4f41-a060-c6f1feb39610	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	e37154ed-ab5d-4afb-a128-bf216c3f61e5
4f8ffc26-a21c-4222-9cf7-6d9320e67eab	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114
d8e2ca82-7b86-44bc-a648-fb2091189b40	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a26aa634-b21b-4b21-a127-702abfab1f20
0bb72f89-aa0d-4329-af2f-155b1a47b0e3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3461894e-b04c-4295-8c83-17ee8bcac3f7
ecd9950d-5b8f-4926-8c65-5dd764fa46c6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	23f42e5e-8baf-451a-8232-4639513222a4
42e31d20-67bb-4b06-8e5a-6b317426610c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	7b2dd504-50ee-45ab-83c1-8ce5552c3394
3881c3c4-f9e4-4fb7-926b-c0efb155cc01	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	3d294cbf-70af-48ee-a64b-3128fa402808
2364d8f5-08a4-4a24-a6f5-ebdb31939984	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	1af532e8-1f99-47b1-881a-33f63f18287a
ceb4e44e-da7d-4a1c-b426-63bedabb19a3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	80b0e230-bee4-46c0-9ff3-bf55b59955d5
37fef6d8-3d7b-4527-90ef-9cb23cd6ec60	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c215f201-699a-4fe2-a842-7fea0c782a32
0dcaae7f-a89f-47c4-ae18-323ada57ea9e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	7908981963402	1	11efebf1-53fc-48ef-a7f1-3a13af82c1f3
8f03a25d-005c-4973-af01-52ff07e5564b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	27478A87190354D68BEBC514	1	e18c6da6-b141-4d37-af6b-8f4f3a047267
40b161cc-1fd8-41b0-bdec-5447a43b9628	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e404c7b0-4099-43e3-b305-c855fd4b734d
7470f8ba-6912-4230-9898-593b4a44aa73	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e289df1e-64bb-4091-8c72-0c72aec52501
9c35c8c2-54d5-4aeb-a925-ad03dca68d44	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d20563f4-ccda-4cca-842f-ee62eaeb6e1b
420c94ce-d9e6-4560-afaf-9212609cf177	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	bfcc1f5d-691a-43e0-80f4-d6d7b87404b9
e4eb7ebc-885e-43a5-ad90-7e71fe9ba5b7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d35665ce-46f4-4b59-a491-eb22731c6422
f53ad8d6-40a8-4be6-ae8f-40b85b552499	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	4fe6ebd8-4172-4b00-a7fd-b056179e8257
f6437406-e0bb-41ac-896a-b983895a9dd5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	133ceda7-5f0f-40c2-a994-cff417dc9e2b
653cf677-75b2-41ee-b142-8d896534d1c6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e2276700-5553-4a39-bda7-53118e24cade
33563cbe-c1c0-4257-b4b3-100d3fb37833	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3d634e9c-b236-49f3-9d74-19a6a21bc730
62d7c830-c7fd-4507-9b5e-c296945cf2d8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1123a71a-461e-41a2-994b-c4921c097aa4
349402ff-e534-4514-91dd-cf4d7b2555f1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e8f954b3-9c64-4ef2-b505-652fbedecdd1
557dace3-6a9b-4782-ad7b-49f11dc490ea	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	e8f954b3-9c64-4ef2-b505-652fbedecdd1
1560e5b3-a59f-4817-a81a-58d32c897ba6	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	e8f954b3-9c64-4ef2-b505-652fbedecdd1
9d0f212f-ff06-4d5c-96af-b09257df07f0	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114
33292a24-e0c6-4db2-8115-25cfc11e9f74	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	e2276700-5553-4a39-bda7-53118e24cade
756a787a-5351-448d-939a-2a9bfc2c40d7	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb
62a0206a-2831-4b0f-b3db-1ea4ad2dd27f	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	3d634e9c-b236-49f3-9d74-19a6a21bc730
797d56ac-16a4-4bb6-b95a-d7639fe001c7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb
b150bf0b-2919-4c86-8d6f-c505316af8df	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114
b60c491a-d0e5-4e3a-b337-a0799d5fc7bc	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb
22b8f81c-ba7e-4417-926d-21af31020659	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8a12b1fa-aeac-4389-aa75-4258b198ceb6
f359d07d-86f2-4407-97f5-410e97077c63	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	ce60564c-7257-4134-ab7c-725150da593e
6bfa4403-fdd2-4288-a1a4-b37d33818f98	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ca957b05-f901-457a-bb3f-4d2f51560b34
74adb45d-8aab-47aa-9f99-cf8f9f01109e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ec88d356-7f2c-4efd-8caf-5e651313607f
a87125a6-9618-46af-a5bb-5427b9ad6ac0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ec88d356-7f2c-4efd-8caf-5e651313607f
1dd1598c-79bb-49ca-add9-cdcb738210bf	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	ec88d356-7f2c-4efd-8caf-5e651313607f
37e8570e-c858-47f2-8b34-86d9aff6c368	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c3fef1a0-bd1e-48ab-b87e-260e3140dad9
1fc66170-6b7f-4eb2-95f1-701eb0c57668	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	cea3440e-0830-4042-907b-81ea40c691ea
8cc6d0a4-2c9b-481b-a346-7bb59ddc556c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	cea3440e-0830-4042-907b-81ea40c691ea
74cb2d97-31f0-4ffe-b0b7-843e7a1027f2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d35665ce-46f4-4b59-a491-eb22731c6422
53ac7a23-1934-44d6-943f-2109ac0ac42b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cc6ae999-7249-48b5-9450-f13d7ec9f8c1
712f8f32-1cb2-4727-9295-118168ab11bc	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c3fef1a0-bd1e-48ab-b87e-260e3140dad9
6085f571-06c6-44ee-b194-d1748e745dbc	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	e8f954b3-9c64-4ef2-b505-652fbedecdd1
902c7366-0852-4dc7-b4d3-106099549ed8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bf3fe2fa-8837-49de-aadd-27b863410a0c
f86c9dad-6bcd-49cd-a9b5-9f9b7ca92d05	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	7908981916798	0	0d3caf74-bd91-49de-aaf0-35021ed180d3
c317a62e-000d-47e1-b71a-2f448b30eab1	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	1123a71a-461e-41a2-994b-c4921c097aa4
d85a965b-7c31-47fb-8d6d-767108e13ccb	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	0d3caf74-bd91-49de-aaf0-35021ed180d3
e849fac1-9c5c-416e-aed3-763e913250b4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d2736922-2464-450c-9772-f5dfc945b560
626c784b-554f-4355-8a86-48c2f0a3aab9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	bf3fe2fa-8837-49de-aadd-27b863410a0c
65695057-c525-4568-8c4e-fe82ddde32f6	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	1123a71a-461e-41a2-994b-c4921c097aa4
3bbe5fef-4caf-45fc-94b5-3769756ceeae	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b4a8c083-7ce3-463f-bd4d-c8418d6ba579
b86ae314-9302-43fa-ab52-071bb05b6575	394dd3f4-45e4-4eaf-9028-3260e229bb65		1	66ff3218-0f96-4717-8e6a-967d40e6b736
3f939022-d89a-4472-ad52-c69886e6ace5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e5e74ca4-e1d2-4f50-9561-d28d3b586d8a
12ed8c8b-4e30-43c7-9d25-5aa05afacde1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3d634e9c-b236-49f3-9d74-19a6a21bc730
df14407b-0ad0-492e-800c-7a2652f6abc4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1123a71a-461e-41a2-994b-c4921c097aa4
aa290e2d-8848-4d0d-bf4e-3db7a5994bf4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	e2276700-5553-4a39-bda7-53118e24cade
137e48b1-7783-4f68-9942-e5276f20d6a7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	3d634e9c-b236-49f3-9d74-19a6a21bc730
4bd1e60d-e5e7-480c-99a3-6b71b556aecb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e2276700-5553-4a39-bda7-53118e24cade
fd1e2cd5-a13d-4c92-bc6b-b43349c00094	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	fbe4fa70-fb78-492d-9608-27c11090a41a
dbe4c0cf-48a8-4b4b-aaf9-0139801f9d59	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	0d3caf74-bd91-49de-aaf0-35021ed180d3
d06f4fbb-b575-423d-9060-fbbe3a652f3a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ec9ab5f4-7f9e-46f1-ab0d-f8530834b1ac
b6777ac1-a3d7-4eca-910e-0e5df3c9e2d2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cbc0b5ff-58a5-4680-9ae8-706846963470
cd2dc712-8b2e-4c97-81de-1ceb232d08e4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	511252b4-4a5e-433a-ac9d-e31fd182144a
6d616edc-5de4-4020-9894-0a759fb90077	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c65bcd91-670c-46af-9dcb-d462ed643695
cfba89ef-a357-4874-bf2f-709830ef2db2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d62c33d5-ff0e-4a95-be05-d1ed90c8f5cd
a6995d3b-d1b0-4c17-9c45-782fa9440f3c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e78ea427-c4f8-4611-a943-ad1488bf5756
9251bb6f-78b5-4bae-8edd-65b40b52fe7e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8903dc04-754f-4653-8c72-c9fefdf35a8c
09879099-71be-4d0f-b135-40502412bf32	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	afd5f46a-ecd0-46b9-9d4d-85fc13bafb44
b50f9a86-c140-4a51-83b3-d138df624f11	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1726d8a8-7466-49d2-b541-78f16f78d316
7383a649-78d7-4dd6-aa30-b2ee69d81f38	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1726d8a8-7466-49d2-b541-78f16f78d316
f5de1c1b-6eb0-4d8b-8802-29bd0ea81b67	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	e60e28a2-3d2f-4105-8a7c-a0dd5749fc35
c820a7d3-27a6-44ea-b748-72801e1600cb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	e60e28a2-3d2f-4105-8a7c-a0dd5749fc35
e307e674-5dfd-4702-a103-ff80e8644f2d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	71e09487-ea2d-49ee-a27c-2f57bb005e30
bdb1b1e4-1852-43be-a912-274c74f93a17	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	71e09487-ea2d-49ee-a27c-2f57bb005e30
44c523e4-1b9f-4d4d-b910-4d314b79d411	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	71e09487-ea2d-49ee-a27c-2f57bb005e30
66756315-79d3-4f04-9d3d-dd535f3523ea	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	2f01216e-2642-44c7-8bfb-12d31c8372df
bc3ad1a8-079d-4517-b61b-f2a8f9c29f50	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	2f01216e-2642-44c7-8bfb-12d31c8372df
e4051596-66b0-4017-8d73-acdb98bc7fa6	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	2f01216e-2642-44c7-8bfb-12d31c8372df
0e844c98-baf2-4797-9ec5-71f2de33b665	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	75c94f89-3b69-470b-a567-ad924d9604f3
f61ca966-76c8-4287-b4f6-cadbc611e1b4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	75c94f89-3b69-470b-a567-ad924d9604f3
0d9aec8f-926b-4133-be16-586961156b9a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a5bed760-0886-43ce-9884-0b2fa9d7e122
751f77e6-760f-4fd2-ba32-6ca555020722	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a5bed760-0886-43ce-9884-0b2fa9d7e122
f6d415ce-2f27-43d7-8e24-ec5dc55d6bd4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	598d5623-0507-4a89-b3a4-987c1cae56af
2c3d081c-de37-4bde-9f64-c113829b7373	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	598d5623-0507-4a89-b3a4-987c1cae56af
16577738-e5be-472c-bbe8-fd89319c1cff	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	c5b72bbb-6b92-46a3-a543-bde357e9eef8
db53a8a1-a104-4374-893a-69c8e9e0f2da	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	c5b72bbb-6b92-46a3-a543-bde357e9eef8
d5677124-44a2-4dc1-90db-4395ef8d64ba	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	3879d0a9-cb07-47ba-8062-f0405051f2e2
00241d16-74c6-49be-bb0a-3b614cc4bf46	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	3879d0a9-cb07-47ba-8062-f0405051f2e2
7b6765fb-5fed-4983-ab90-9ebd6de0b89f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	a1438632-772e-4035-ac6f-36c7030329d8
850e322d-21e9-4532-9cff-6c72dd772d05	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	a1438632-772e-4035-ac6f-36c7030329d8
a5812a32-fb41-4e6e-ab62-19cedb8033ce	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	253816a0-017a-42b6-aae4-128963fdc544
c6d81e80-1345-43ae-9d55-43f6bb32ec91	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	253816a0-017a-42b6-aae4-128963fdc544
d8df7a29-c491-4a49-a2a7-4f87766623c0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	28287d18-20dd-4210-9450-67c2e91e8345
92ce2c39-cd71-4d96-80be-4f701cd36f07	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	787c677e-8541-4a37-8f76-1b0a338ce9d3
8758928c-0db3-4395-8b1c-5494772d50a5	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	178c1bfb-c016-4a74-9879-bbe421693e9e
1b7e8b50-0622-4127-b9a4-801c4c7aedc2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	756a8f66-8f2d-4fca-9255-2b4c2faa1a96
40023b16-8e96-407c-bd9e-a62f3bc295c4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	756a8f66-8f2d-4fca-9255-2b4c2faa1a96
bededf0e-d60d-4942-80d3-7443cb431c41	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	d5b8a956-5d2c-4b3b-a02d-0fb2243ffa88
b2b1e390-b524-46db-9d69-e27076e49cf1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	bf5059d6-196f-41b7-ba5f-e1f5c29ded46
a234020f-12f5-4578-8a41-28ac32adc431	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	1d1fb844-0f07-4b09-a80c-0b02ba50570d
705cf158-0363-4c5a-be17-f5db3bf04885	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9a55dd2b-b128-425f-9a60-4661635c2a14
d05ae524-aae7-4928-b895-346baa9380ce	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	7c051d7b-cdf7-4a19-aa50-9a0f6e308655
f53d25ca-bd3e-4659-9664-5c7c550688de	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3fd3798e-d793-4754-ab1c-a5566edc77e3
79d886de-3112-4bd7-b1fa-ad5c4364055c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	88964da7-b084-44c7-9231-43645c98ebf2
3781ca49-be72-43b3-94f1-cb34e90aa8c1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	fe2f9328-af80-4d72-aa25-8ed6a2430cb4
356f1c2f-4d66-41af-bef2-75fb9c204e9e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c9bf8fab-7dc3-4f86-8ede-4f0a1d34c466
d16780dd-b03a-4966-bba6-a73e42771b6a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	9fd20c26-5d5b-4b11-80e5-ecf884019976
94106ece-16c4-420a-b4c5-f3ec7a55cf93	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960
fded3b4c-8d0b-4955-8eab-3b45edc2ef4a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	c0ec0db7-f802-4337-a426-5224eefa3342
702cbd3c-f32d-42c4-bcd7-3a55b5dba91c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9437321d-7e2b-41a5-96cd-27b94663bc00
8c73a143-e818-4fba-8542-ea4f43338508	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	9a55dd2b-b128-425f-9a60-4661635c2a14
4cb3b221-37b7-439d-9749-b542bbce418c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	9437321d-7e2b-41a5-96cd-27b94663bc00
b072affd-e2c7-40fb-829a-f1563fed20de	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	963ba04d-3a66-4c13-aab0-640bb69ed947
4e4abd99-d5ee-450f-8b26-aa549e936ee9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	a57e0149-55f4-432d-99d9-251483ecc644
e510b82f-794f-4fc5-8b0d-694eda59843e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ef55c198-d3c5-41ce-afcb-a329e0f8865f
1d3b4649-3798-4fce-b520-11f96bf52a79	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6dc84bb9-65fb-4f58-b048-a5c404b6c3ae
ca1f1ebc-4a34-4707-b624-e8a25b84759a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	a5bed760-0886-43ce-9884-0b2fa9d7e122
e1d9ec05-fea4-404a-8c7d-203d979df50a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	1726d8a8-7466-49d2-b541-78f16f78d316
f83b0cb0-b8b7-4df2-bd5a-2d185d52ba78	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1775cd64-1b1e-455b-9912-e320c910d18a
302a6867-c821-4a97-9c08-97e22ffaca98	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	1775cd64-1b1e-455b-9912-e320c910d18a
b67463be-78cc-4183-9358-14a3d93b2cfe	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	1775cd64-1b1e-455b-9912-e320c910d18a
e5797329-3609-49ea-bdc1-aea4dd02be25	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	41d2c32d-5cb2-49cc-8ba0-e2151436b298
aae3f230-f079-4af4-806c-2585988234c9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	9fd20c26-5d5b-4b11-80e5-ecf884019976
08ae5032-4938-446d-8b6e-52561e3e12e0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ec60a756-d6ac-42ae-a91a-819307d66c1d
99cc0bd2-fd66-4d32-b96f-6680ce0282fc	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	e404c7b0-4099-43e3-b305-c855fd4b734d
3dcf3c81-86fd-4b43-b9ad-2205f3817720	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	e404c7b0-4099-43e3-b305-c855fd4b734d
8c564c47-16be-40d8-8720-5b986f6a5785	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	5	1d1fb844-0f07-4b09-a80c-0b02ba50570d
7202baaa-c299-4a3d-b1eb-46809d27d4ac	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	7c051d7b-cdf7-4a19-aa50-9a0f6e308655
82f451e3-0540-4f29-9d3b-f75ea3e812b7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4bbc099b-fc0c-48a9-a621-8674934824b5
7aa1b0f2-bacc-4e26-ac40-5f8ed00a7337	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	b1a76627-8254-44af-aaf5-99dd25c780d3
07ea9b14-d32b-4289-b23d-56f07814ab06	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	b1a76627-8254-44af-aaf5-99dd25c780d3
63d9061c-7423-4b08-87f6-df2ceeff8bda	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	fe2f9328-af80-4d72-aa25-8ed6a2430cb4
dfbb901d-87ff-4716-9dc4-d7f9bae63692	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	15f7fd5b-846c-498e-8c6d-dbca6ed3f5d7
b668891d-e25c-4973-969c-983a05e82cc7	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	c0ec0db7-f802-4337-a426-5224eefa3342
feff9013-4090-40a0-9c17-c11233b92483	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	6b088322-81c6-4e64-af59-76b9ab62f027
c2d79261-4799-48b5-97e8-ef8ec006f165	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	28be9554-3198-41e3-8d90-8bc13d4df232
380b2f88-2b83-472f-aad5-d4c34079b6ea	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	c3fef1a0-bd1e-48ab-b87e-260e3140dad9
0dc17671-51dc-42d7-b75e-985edd38980b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	89ee27b6-e12c-48ee-bf00-722b97a38220
49526e07-92dd-4fae-a9b1-5c0618831120	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	ec60a756-d6ac-42ae-a91a-819307d66c1d
6091f153-ad27-42f5-a875-711230265eb1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960
d1c8971a-4ae6-4bb7-883c-2716c9d7e189	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6b088322-81c6-4e64-af59-76b9ab62f027
b16e39a3-82a6-45d9-afae-8accc75a3dde	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0f2f9bb8-5eaf-46de-b5e5-b1455ccb8321
5c07ec4d-549a-47cc-883d-27c6bbd0b8f3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960
65b0b5a4-a600-4ac8-8db6-de5ed0698c7b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	6b088322-81c6-4e64-af59-76b9ab62f027
36057585-d399-4c9e-b475-e18d727d3c66	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b1a76627-8254-44af-aaf5-99dd25c780d3
879d026b-88e2-4eab-b854-1f8f30c0d31f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	78fcd02f-ea2b-4665-9eb5-e29d71b525ec
ac0759a6-e48b-42b2-962b-1d2dec93c674	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	9a55dd2b-b128-425f-9a60-4661635c2a14
3503f869-7775-489d-ab0d-e2520bf27695	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	598d5623-0507-4a89-b3a4-987c1cae56af
ba3a1a7c-19a1-4f47-aae2-8e46d8d05fbd	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	28287d18-20dd-4210-9450-67c2e91e8345
d8dc5a0c-b64e-44e0-ad02-657b836d4de5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9437321d-7e2b-41a5-96cd-27b94663bc00
04502a26-7009-4684-a278-517756284c2a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	e60e28a2-3d2f-4105-8a7c-a0dd5749fc35
0d60351b-1d93-4db3-bb5c-2ce653c24be9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	178c1bfb-c016-4a74-9879-bbe421693e9e
ab64c416-9b6f-4240-b5b1-cad033696e37	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f58a6e05-302a-4ae7-9754-7eba7b2ab797
e965c682-05a6-4c7d-8f17-e1d25d5abe56	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	89ee27b6-e12c-48ee-bf00-722b97a38220
2b3e56f0-e679-4790-80c2-2be845e2016f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	7c051d7b-cdf7-4a19-aa50-9a0f6e308655
5fff32d1-7833-4fc0-9e46-ed9fce89b3da	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	75c94f89-3b69-470b-a567-ad924d9604f3
eca61b47-c6b0-442c-8e24-77b868e20051	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	ef55c198-d3c5-41ce-afcb-a329e0f8865f
9a64c940-16b0-42af-8853-7c9177e5219a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	0e389fbc-7e79-482e-accb-4e2e5b92b509
1f74393d-5bc7-4538-838c-3c6b7d61ff51	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	c13c6bb2-b261-4906-aa83-2fc815cbcf33
bbdfd890-7f1f-460b-96a8-e444289e4a1c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0b666f5a-9359-483e-9e74-26b41a5457a6
6243a16d-0527-41b5-b18b-0dc43cf63b25	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1ab6e617-34db-432e-9557-56d84a5d234e
9bcd9e83-9dee-457c-af21-316d6c95bbca	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	03d3e7a0-6398-47a7-aefd-e5811cddb10f
db6278b8-5281-43cd-a2b3-02e9848a207d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	efbdfcbf-4526-466f-a863-115f66bd0714
4fe4979d-a920-4d1d-aa54-db2a968769f0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4912f884-71ef-4b99-ba46-3daae390bc79
b232382c-a74a-409e-8d1e-2bde60d3fe77	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	75fda0ae-993d-4cdb-8647-43b5dacd8e4e
1852f73a-54be-4f2e-a3fe-da0ef3a289f4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	52a04c53-d12e-4d24-adb0-e99f550a3907
d9bda251-e39b-4d5c-a927-a795821797ce	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	32c8d197-fa1e-4cd7-8559-639d7b8a1359
e27489f6-f19e-4cf9-addd-04bdd667a322	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bff71c24-ac1a-4a4c-822c-2c1b299b343d
87f40fe3-89ff-4498-b1af-ed43fa26ef39	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0fdea5e8-ce59-4581-a6dc-16be6cf0b27f
acbca184-d861-479b-ad3f-d55f867e6377	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	21db8fae-3c39-4e2f-ab6d-0013477c0b3b
6a3e7909-1d6f-41d7-858b-0fc5d6a0e938	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	33919956-5f82-408a-bf83-d948ffca4d4b
43d987cc-58b5-45ea-93d8-f19dc5f60996	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	80b0e230-bee4-46c0-9ff3-bf55b59955d5
51df8698-697c-41ed-b286-eeafbd74ec31	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c26f24e0-e9c3-4e19-9e79-6e4ce4ee2189
21193f3a-00b3-420e-8aa5-80b6d1172444	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4dda8aa6-b238-4cf3-88a1-fa327584a3be
fac6d951-f0b7-4006-b335-ba2a7d6063af	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	0e389fbc-7e79-482e-accb-4e2e5b92b509
c5776c55-f683-4c0e-9d5e-451a6307f548	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	fe2f9328-af80-4d72-aa25-8ed6a2430cb4
c372dc80-134b-47e9-bb12-df6ef89f5201	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	41d2c32d-5cb2-49cc-8ba0-e2151436b298
c13a07c6-726c-4a32-8e6c-22e20ae125a3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	41d2c32d-5cb2-49cc-8ba0-e2151436b298
6ac3ef60-89b4-49f7-a4d8-bd67f53cb518	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5
f975d4c6-03ef-456a-8f25-917ec634d2de	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5
7bd96d53-aee5-4587-b5f9-e0ffcb6aa8b6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	03d3e7a0-6398-47a7-aefd-e5811cddb10f
18d4e329-587f-4094-bccc-91ad8eb15df2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	bd450fd1-8aa8-4c61-af95-30307a3f65aa
fb28c18f-2b40-42db-a038-44ee01a23ae4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2dc364cf-d17f-4bb7-9b77-3727c544746c
e848866f-573b-448d-ad75-1a9e0c0e11b2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	59c41dec-c3db-4783-9036-f32b38162602
e369278b-6c64-4fe0-913b-95f303a85811	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	59c41dec-c3db-4783-9036-f32b38162602
98e28b0b-f1cb-4f92-881e-6ec7748a4aeb	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	877e5d32-474a-4f90-a4d4-f780e572d58a
17d887f0-da59-4003-948f-928da99544c3	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	41d2c32d-5cb2-49cc-8ba0-e2151436b298
3910323e-ae4c-4774-b771-84ed7ab05a41	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5
91aaa205-3990-48f8-8828-504146c0f5c6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	877e5d32-474a-4f90-a4d4-f780e572d58a
f8ce2cae-e40b-4b1b-af36-30e4b68b3cb6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	03d3e7a0-6398-47a7-aefd-e5811cddb10f
7b3627cf-c611-4f08-93f4-3fa6d249121e	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5
0860546a-e730-42f0-b1e8-cffba52076e1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	1d1fb844-0f07-4b09-a80c-0b02ba50570d
afd6fb8e-e7a9-4e39-9c38-759c6567cfe4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	de845772-4adf-4165-8eb9-4acb2ef1f46b
770afe0e-b14e-48f9-8703-086578a50cdb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9b724805-0053-422f-ad26-a756d381a78e
01d145fc-8e48-40fa-ac79-03ff0e7b0327	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	443f6902-6e31-4726-b73a-f099e1b067a0
870f1f0d-2640-4516-8bfa-7a4be0f51062	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	12340bde-9009-4c92-904d-b0ca61d085af
d59a305d-e48f-420b-9e0d-82504a4ed3af	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	fc469e48-c097-4005-bbf7-9c8b7e488b82
b538176a-a194-41dd-baf5-268518d87fe0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	64544c42-05d0-4c1a-b988-0d0e07834e15
bc031156-6089-4a8a-abec-6513aef7f39c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	03b2fc1c-cf16-4880-872f-05e52f9f882b
81b105b2-1655-4ecf-8b20-c992db9e98a0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	7bbe0ce4-8a2d-47f3-92d7-e5c73dc392f2
108d36db-d4e7-4ea0-bc3a-98c320b10556	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d9074cc0-4cc0-4951-acc7-7465541abf71
e82ddcec-589e-4576-abec-932edd3b9c59	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	35212ea8-1da9-4214-b94d-1b680875b8fb
583b56f3-3ea4-46fe-b275-eb625290625a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	35212ea8-1da9-4214-b94d-1b680875b8fb
6e0bb264-4b19-4094-8b14-b88dfdd7fc53	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	dc407b2b-d84b-4554-831b-795e0716bdbe
467e1a1c-0098-48ba-94cc-99c9cb5704af	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	b85faab3-1556-45b8-af50-804c9e70bbb2
95494e0b-424f-49c3-9651-62e1ef835d49	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	03984ca4-0f91-49d0-903d-e6bc09e9e9d3
edc7c2fc-9193-4d83-8265-fef75f6a26d6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e4d0e600-15d1-45b5-9391-240739862804
2cef071a-1b64-47a0-bc61-1f6eb74d51f5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9a64e33d-81b5-435d-8649-8e44ae96c86c
0156ee0d-f811-4af0-acce-dcd66368e2fc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	254e1417-650b-4140-bb3e-9bf3ade91b50
26330b5e-bccc-4e9d-9db4-2d4132e7143a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5c6dda5a-1ebd-4489-b45e-99ded1fcbd5b
ad54240f-8621-4110-9b8f-86ab99132b9e	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	5c6dda5a-1ebd-4489-b45e-99ded1fcbd5b
f9618c33-d019-4692-a54c-9fbef5ecbea5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	e6481b12-5b71-48fb-8014-ac527908b6fc
cea66e22-984b-4643-8ed5-8671cf84e5bb	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8cdbc26f-24a3-4d84-9c3c-a4781c65304c
ac945bd0-0fb0-4c76-aa9d-4555709de601	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8cdbc26f-24a3-4d84-9c3c-a4781c65304c
56c04e72-f2af-4681-9aa2-af1010bbfd52	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	461a481e-12a3-4373-8ddd-cb410748e9cd
dcd11936-0f5f-446b-aebb-f883c5cf1926	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	03dcd463-76cf-4c8f-83b6-22a0a3d72268
19d8652a-a738-4a14-9412-8aefebea6715	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	03dcd463-76cf-4c8f-83b6-22a0a3d72268
e4e1f996-b235-4843-95d1-a8a0b1970180	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	43dcec98-8ce6-4b18-bfe5-2d43562e41dc
974d24c8-2328-4c08-ada0-978766cf2069	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	43dcec98-8ce6-4b18-bfe5-2d43562e41dc
af2729aa-d331-4798-94e1-8cedd4e5585f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	fddb8bcb-6e9c-4c9e-bcf7-2341053e40cf
606cb46f-ffe0-4c04-86bf-23850cdc57c6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	7e3d8939-6360-463f-9573-9188011607ed
c3a0e97a-86fd-428a-8ae6-a51d5d1ce50c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cbd9bb0f-ff33-4a7e-9df3-230d91f25ee9
ab360519-cb45-4460-ad65-aaf396e10098	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0b64b183-18e2-4aa8-9152-421260382cb3
628a4602-b0f8-4432-a90f-761e53c4bfc0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	5a486e27-2649-4704-90b2-09769d302dda
19614eee-4362-4474-b022-b15326b9bf95	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	0b79f466-a4c6-4dcb-bad4-1a285ddb4377
96ac036e-8e35-4854-bdc8-8bc7ebea198d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	61f63760-95d2-493a-a81f-fdbdad335355
653ea9bb-38de-4b2e-b874-cf850b6d2775	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	dc407b2b-d84b-4554-831b-795e0716bdbe
aea9f109-7250-40c4-ae15-595bdcfc53c0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e4d0e600-15d1-45b5-9391-240739862804
07fe3d25-330e-478f-acdf-0a61303fe09d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	32c8d197-fa1e-4cd7-8559-639d7b8a1359
b473056d-8290-4412-937f-0f7f0ac94475	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3e7cf9ec-8b8f-4bef-acb3-b2d54e5c2ad1
d5b608ff-d7e5-4aec-adb8-4f0216a55094	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	e4d0e600-15d1-45b5-9391-240739862804
3b1e2a97-36dc-49ac-b342-06a2878f2d11	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a0f12306-5fce-4173-ac98-5b6350de1863
5ca68ed1-f534-479f-8701-198fc28abaae	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	271fec96-9aed-4d36-b71d-87147092ae3e
e4094a4d-252a-44a0-ba14-f3b8e37eefd6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c360ccbe-736e-4357-afc3-62f7cacc33b9
d1ec243b-463f-46c2-870b-60ff4b080d0b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	61a2649e-51cc-4f2f-b143-1113d41bc9fd
81502d34-8d77-41ca-a424-d68904ab43f8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1eb39472-4b0e-4753-b75b-8187024d77d2
9ff493a7-606d-49fb-a621-bb6462d7d8bf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c2ad6656-55cd-4bfb-a495-71b04535a657
60c3c3d7-1e4d-43fc-b992-6244ec274848	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	461a481e-12a3-4373-8ddd-cb410748e9cd
337dae1b-7048-47bb-8a5c-d5b051dee765	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	59c41dec-c3db-4783-9036-f32b38162602
0625571c-d980-48da-a6d5-9bc8543bac94	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	390efbab-b038-4088-9bd3-fdb4889b5ae7
0d66f4a7-5370-471a-818b-b1aba224f865	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	c9f22b86-6bdb-47cd-9832-d47f617bd6bc
9d56baf5-d054-4bd0-8202-24f42974e871	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2ca91c0d-1c44-4b8b-83c7-35a12406f314
fa6957ea-2a79-490d-b48d-e87ffd4ce8e2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8
3a6c1861-c427-4d42-961a-7fa27793ba4c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	03b2fc1c-cf16-4880-872f-05e52f9f882b
52afca54-aac8-4946-a1fa-ac06f3f2ec15	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	5dcffd07-7cfd-4204-9e49-3401773bb7ab
1f1d9e09-43d8-4832-9e28-36896d798c4f	05e02b30-0867-4b3b-8518-0a0805db9706	\N	1	5dcffd07-7cfd-4204-9e49-3401773bb7ab
ff51016e-8dae-4079-894d-9c005ca8219d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2ce7d50a-d254-4860-bf0b-8f18b4c67d85
4b282726-b8aa-4a07-8aaf-83f33cd47ed4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2ce7d50a-d254-4860-bf0b-8f18b4c67d85
3d53bf7e-8051-43cb-a28b-e046f81ebb2d	05e02b30-0867-4b3b-8518-0a0805db9706	\N	1	2ce7d50a-d254-4860-bf0b-8f18b4c67d85
939d6575-3c21-40ec-b848-56a6c7d5af85	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2b0404e5-ce5e-4a3d-8507-66d89e323326
f26f976d-c6e9-4c17-a266-39501f2354e5	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2b0404e5-ce5e-4a3d-8507-66d89e323326
81478d4c-fd3b-471b-a8b6-058f6580f729	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	2	f2ad9e63-2c90-4472-bc1f-ab3936f125cf
255e57da-0b1a-4bbc-947a-30f422bcb2d9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	55e0343b-26ae-4c0f-98bd-a40b6a49418d
a4bf1902-87ae-4ef1-81b3-4b93692f2f29	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1dab11ed-3bae-4f22-b579-31737836d5ee
1d64e322-f13c-44c3-8fb3-4137d4404156	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b69505bd-c95e-4f1d-8cc1-9d87cf033664
c2f7f486-d24a-4bd0-bd1c-621f4930cc80	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b69505bd-c95e-4f1d-8cc1-9d87cf033664
213598fb-323b-4ac9-ac42-7774e81221ab	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e80d740d-58dc-480e-969f-423f63dcc8bc
6700efec-c529-4234-92a2-bb9a28417457	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	ab17bb5d-386a-4800-9597-5686055239d9
c592b94e-c083-4544-8a12-8f757e8c27e1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	ab17bb5d-386a-4800-9597-5686055239d9
8612b6e0-9efb-4c61-9d8f-a65b42135068	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8cdbc26f-24a3-4d84-9c3c-a4781c65304c
baa4ef2b-2fb7-434e-a5b9-ce2f151b1ea4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	fddb8bcb-6e9c-4c9e-bcf7-2341053e40cf
6d93bd14-ad38-4d58-a88d-878c8c105db3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	244b0d4a-aba1-407a-90bf-fe4a6e464be3
bb91d62e-82c9-432b-adc1-882a4cfeb424	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f5c5e94d-bcb9-4f49-96ea-38f80502e452
8829a6bf-f838-40de-996d-e3e0dcd6cca9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e6481b12-5b71-48fb-8014-ac527908b6fc
db125336-6418-4294-8f1e-a87ccfe18c99	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e56cbf93-b2fd-4251-b400-757de41fe7a4
aba46ff4-6f18-43ab-8b1d-31afdf7d7464	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e56cbf93-b2fd-4251-b400-757de41fe7a4
f97a4766-7baa-4122-b1b2-83beb0273468	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	db44cd4c-ca3e-49c9-9fc8-a5c50e8a1f01
3f0e57ca-8488-418b-bd17-c0b05b00c512	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	cb527f95-20c9-4c42-82a0-1236ccab1f86
c9ca73f1-cb08-4fdb-bb37-f5602e37b220	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	bf164b87-cfad-4bb6-9885-0b40b4857ed4
d0ac13a1-676a-4921-a0aa-58e8d2180b8a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	df6a97ff-20c2-42af-b5e5-d1d7117a0750
59d8f7bc-7776-49d5-a9e1-ac4094f98157	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	df6a97ff-20c2-42af-b5e5-d1d7117a0750
ffa32253-ac3c-446c-b07c-6a9f439e10a4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	001a4eee-5381-447d-8b59-5795bded7918
f7b4b061-e808-4fc3-955c-1605615b6add	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8c5c138d-e2b4-4931-bcd2-8329534ce9e1
c6b206a4-faf5-4c68-8949-675fa2b804b8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8c5c138d-e2b4-4931-bcd2-8329534ce9e1
3f73f8e3-d2f4-43b7-a498-d799aea20aa0	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	96270ce4-a952-4a02-bb35-c1cf555e2f8c
d4d1245f-39f5-4fe6-862e-56fb88b5ce4f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	96270ce4-a952-4a02-bb35-c1cf555e2f8c
fa319d5f-81ad-4d19-98db-44d3d1b6750f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c9f22b86-6bdb-47cd-9832-d47f617bd6bc
5303764c-728f-480e-9c1d-fa1c3f8628f7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8
62fbe352-0d47-41c0-9576-9d1d966dfe3f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2ca91c0d-1c44-4b8b-83c7-35a12406f314
7ae340f2-c85f-4ef0-b504-d488d8d5dfc9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a0f12306-5fce-4173-ac98-5b6350de1863
c76efc2c-0f0d-45c2-914a-2d57879786b9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	a0f12306-5fce-4173-ac98-5b6350de1863
28e96364-5d82-47c5-b82a-a4acd5207abc	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	271fec96-9aed-4d36-b71d-87147092ae3e
cb7d56ae-ae4d-4ef3-ad40-dd80e294c798	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	61f63760-95d2-493a-a81f-fdbdad335355
365a0260-e40b-4393-a9c1-0b2b9ac1051a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3a053da8-0523-4cc3-927b-1ebb65aab3a9
efabdef6-5532-40bf-a0dd-45c8ebefab6d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e1eeabac-0b5c-414e-8292-b5487a1bc841
228255a4-6b16-4bfa-91d1-ddb0324914a9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	5a9db7ea-c12c-4eab-ae6e-3b2ade4da98b
035acb22-0ed1-472c-8c4f-a0a38ced0787	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9b18bfa1-5be2-4276-8c1f-0e4d0281231f
8ab43a7b-7e9c-468a-8873-073843ea3602	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	30881abb-d3f6-44c3-8684-d9d34df5545d
73d56300-9e12-47b1-86de-375b47feca37	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	fd8be7ee-558e-4606-a6fb-9bbfce5c5649
f53d4128-31f2-4e90-b92b-fe08b3ec3a3f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	3c34c887-2401-40e3-84b5-0eefedea12df
f5eda00b-341a-43f3-ac70-dc5e38e09dbe	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	9b18bfa1-5be2-4276-8c1f-0e4d0281231f
8a9ffe9b-ef3d-4ffc-b8ec-62b60c504ad3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9bec3a8f-030b-4b74-be80-24e3ced41e0c
436bee94-cb78-4107-bcbd-e686f7b225e1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	dc407b2b-d84b-4554-831b-795e0716bdbe
221f42ab-a784-4e1e-aaa1-93b8b9f71946	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8c16d307-f3a4-4c06-863a-d6ee02ea9869
947b45e9-4f7d-4d1d-a9b1-0c6be2caf8da	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bf4acbba-69dd-4445-8a60-52a91652fb1b
d2d52065-afee-43c9-9b9f-e61f390e285d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1e0a66d1-dbc1-4ef8-8839-aece52724742
aa6310b9-2004-4a56-a9cc-cc5f6ac45286	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	5dcffd07-7cfd-4204-9e49-3401773bb7ab
f8518e3c-b177-4692-8177-b3abbd21bf2d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7
336ee95d-aa7f-4754-b7d9-46324a8dfb10	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8b1f499c-ee20-479e-8588-aa0811712935
4e9fba70-e0fe-44dd-86a7-5183792c85a6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2adfffdd-1e23-4800-a123-f0ddadd83cf9
d4074d0f-63e8-4163-80e6-87585a218fa3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	75e05685-9baf-46cd-82f8-e02a4083bcf9
853142ab-bca3-4328-b2b3-598fd5744cad	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	9bec3a8f-030b-4b74-be80-24e3ced41e0c
c69f50a3-f499-4ad8-a354-2e9cdc5313a7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	5a9db7ea-c12c-4eab-ae6e-3b2ade4da98b
5d842263-970c-476d-9593-c0fc346ea59e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248
5077fa7a-1d9d-4824-9f5b-7441252c0967	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	244b0d4a-aba1-407a-90bf-fe4a6e464be3
ff3aedc4-b220-4070-aacb-c78a46a12be7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f1f37c0b-af2d-4a47-bb00-d8e7f832a4c0
ea9c69df-a02c-4175-9847-63d5341a7123	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	56d8eaf0-17ed-4d25-99f1-74144b557ab9
d5558fc2-4878-4ce1-b858-307965af447c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4005334e-6610-41dc-95b2-6eee8ad8e419
dc661388-75c8-487b-9b6b-48404005a6f0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	4005334e-6610-41dc-95b2-6eee8ad8e419
6d550a25-1166-41aa-8258-00ec1a323e9d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	098e7ef6-19cd-4fb2-bac7-da38efb9ad72
2fd2a9a5-e8f5-4bbf-92bf-f9df339d8fd0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	eafb3b17-fafe-4d6f-863b-b12a2fc6343f
0227c761-c81a-442a-b52f-a41d069af7ff	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3
5d3c3597-9577-4707-aee8-b9f50888205d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	5a1309a8-2b53-440e-9dcd-463538d23141
ce4b1448-40a6-49e0-a8aa-ee90cb7043c5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	30881abb-d3f6-44c3-8684-d9d34df5545d
f269a319-db12-4fd7-9fa3-14660b6edc87	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bf164b87-cfad-4bb6-9885-0b40b4857ed4
b84fb933-537f-479e-94cd-d505268247f6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ecba23cc-511a-45b8-85d9-27dc7cb8f0c4
afc619d5-dda1-4121-aec9-284bf43847c8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8b1f499c-ee20-479e-8588-aa0811712935
88abc986-c7b1-4c79-9596-daa27165d53f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cf50944b-9c24-4253-b741-2e63beb82308
b02ea989-7c63-4187-83b7-b3f048e51c1c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	2adfffdd-1e23-4800-a123-f0ddadd83cf9
f64f3e40-e731-4197-87e3-9968eea5c8e8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c68f212a-8a4b-4d82-b22f-d56006f28c10
b40cb1ca-263c-4a7f-98f9-5e1919ad0fbb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	746529fd-29ba-4712-aa89-b7444bc978e3
dd821152-f254-4045-b363-bbfad44264c0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	230c38d0-2506-44ca-a39a-564d5e06e802
dfa20af5-fb85-4b7a-bb8a-9d0c2c0e73b2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8d6da76c-03ee-4bc0-a8b0-a49424b4dee3
1891fc6b-477f-450e-936b-58bde1c48678	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	eeef784a-f4c3-49a4-b126-a4ff7cced463
57cb77dc-031f-4053-87ed-6f0945fcb9ca	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	75e05685-9baf-46cd-82f8-e02a4083bcf9
25a5d914-3310-420f-b800-a76be89d2ef8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	001a4eee-5381-447d-8b59-5795bded7918
e801fb7d-de70-43a4-a6d2-9ac34a1a46fa	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7
04c4f56e-c091-4ec9-958a-4d0cfa3577e7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248
c79dc660-4f13-4af8-b89a-c03a5e68e9ce	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3
421f6eb3-f13a-4eba-bac7-84790a6d1df1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	eafb3b17-fafe-4d6f-863b-b12a2fc6343f
3287cf1c-1ac3-4a5f-86c8-5fdc9481a56a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248
87d32685-edbe-4161-8cbf-13c3cfddcdb1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	1dab11ed-3bae-4f22-b579-31737836d5ee
c85835e3-084f-494c-85da-f26febe20cdc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	098e7ef6-19cd-4fb2-bac7-da38efb9ad72
4a0f8be7-e0c9-49fa-98e0-2815b14a69ee	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9c643407-daf7-4827-bf3f-19706be83648
d5c991b7-8277-465b-a9f4-d4a762a4262f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	d5723028-0256-43b6-9d2c-dee1033aa63a
45b40c3e-7dcc-4543-849e-3302025d06b3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c507f310-9f7b-401b-84a1-08b2910b50a9
fc0b53f7-2423-4e25-a9a3-784a01df375d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	33ab8e86-97c7-4442-b8ce-27ed8b70ff04
3cb52fda-8f87-42c5-854f-ef11ee805f75	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	c68f212a-8a4b-4d82-b22f-d56006f28c10
cb5a98a4-ad05-4c3d-abba-b91badf0d678	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	cb527f95-20c9-4c42-82a0-1236ccab1f86
23fd1e1f-e6d3-4bc1-9d53-1903b954cecb	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	3a053da8-0523-4cc3-927b-1ebb65aab3a9
a5a8bb92-a8fe-4103-a7a2-815ce78f8ae2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	e1eeabac-0b5c-414e-8292-b5487a1bc841
d90e2b67-acda-46b1-8f72-3ffc2967772c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	eeef784a-f4c3-49a4-b126-a4ff7cced463
1fb7278c-cba4-40bd-85b3-1584de2be55a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	bd62d0cf-146b-4d56-9621-244e4e5352cd
4639058a-276e-42c2-b43f-fa5d0cf9f19b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	db44cd4c-ca3e-49c9-9fc8-a5c50e8a1f01
8f582656-6c8c-493a-a016-9bf80916e8c0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	787c677e-8541-4a37-8f76-1b0a338ce9d3
932378c1-fae0-417a-91ee-c150f2944c34	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	d9158d5b-3529-4301-b4e5-e1bcdc4158c4
6dda2784-aae9-49e8-8402-97b63a91234f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	37f7c903-b6a5-4451-9584-37760953d250
236b2a28-7301-408f-96d3-ce5b46b449e5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	717f76a2-0f95-47ed-992a-808ba48cffa3
bdd3fc05-3dc3-4ebb-ad14-05b032089127	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	717f76a2-0f95-47ed-992a-808ba48cffa3
6ad174e3-af1d-465e-ba20-7efac81e245b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	326add3c-eb17-495c-926f-374e8b982837
0695f7fc-7739-4278-ab75-4cacccaf8f11	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	508022e6-0d24-4d5b-a11c-f8422dbf85b8
69550e09-b387-4315-9ba5-5a0855bca1f5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	508022e6-0d24-4d5b-a11c-f8422dbf85b8
47038d1b-cb1f-47f7-b5da-0243395302ba	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a10ea09b-2ce4-45b7-aea5-0629d630e5f7
86d002a1-acf6-4ce3-80af-777400025060	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a10ea09b-2ce4-45b7-aea5-0629d630e5f7
66195200-26d7-4bce-a2d2-a87d5ed09422	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	39ccf293-fcfe-4409-9588-290e3419c592
ba467cdb-d626-4bff-85ee-0a35e46e4a0b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	cc8c8918-e373-494a-8032-dbad1d9278df
7feaf940-25e1-4621-b79e-f4f7d79f9151	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a1d510e0-4be6-4d40-b8ed-6ecd2a598060
e6d6acd2-ae89-4a80-8dd1-dcf3a93be820	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b3f898c9-4d5f-4155-afbc-33b49b1131f2
48ff9155-197e-4397-8756-8bc8c87057f4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2a66ac9d-0c8e-4c7b-a7b7-d6e615dd8d28
482dc403-1831-4bf4-b9f2-15cf6f946e87	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2a66ac9d-0c8e-4c7b-a7b7-d6e615dd8d28
f08cfe32-9929-41af-baf6-762518a2e7b9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	62bb5e2a-10dc-4edf-8d56-911c2a0fa863
dc0010ed-561c-408e-b9e4-4be2339d4888	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	3a7b5436-a329-48ed-841d-b103d2e3b4c9
b5fe6291-83f2-4472-a320-6d771d48cdc8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	30839a14-f92a-41a3-923f-2340724763b0
a5e542e9-e6a7-493d-b69c-8719af302c8c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	30839a14-f92a-41a3-923f-2340724763b0
46f1dd51-a01d-4cd7-aa42-a04e3a06fb4a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	afc0bdf2-dca6-42b7-abcb-2cb7ff27cff7
294428c8-aa95-46a9-bbb0-0ffddd332692	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	11f5db23-1e55-4980-a635-41fc0cf50d93
939eb8a0-f0d3-47f0-9039-bead596f4a74	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	62bb5e2a-10dc-4edf-8d56-911c2a0fa863
bc2f17cb-c000-4ba9-9ef6-97783cf0ce50	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	717f76a2-0f95-47ed-992a-808ba48cffa3
4e0fbcdc-8c87-4a99-b68d-c0e5f44c0388	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	a27d57a0-bc23-492a-9632-8082d16c7170
642a148a-56a9-4b5e-998b-6978eb35d5d9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	769c8388-bf63-468c-b806-2f326b5af2ee
b8352a38-6158-4fa2-97e3-a490ab1d4b44	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	2357e280-e696-4910-8e91-4393557c8a37
2ef2bad6-d6fe-4430-8515-dc236a07bd8c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	6e18ff3f-06dc-4ad2-a18c-7a9dc33e4f66
f6e4bb72-5d12-4d3a-9d9a-e1264066119e	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	6e18ff3f-06dc-4ad2-a18c-7a9dc33e4f66
d7e05527-d991-4d25-a671-d4543832cd5c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	316e0847-fb38-4f8e-b27d-5674bd1666bf
bea52321-85aa-4686-8ae9-ba3854cb190e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	a2e9454e-e59e-4c92-aa00-0cf93c3ea168
8d57bad3-eef8-479c-be5b-c6218d90eb8d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6060f268-49b8-492f-aee7-d21656de929b
c9e08a4a-fb8e-4787-a496-f9941e3a6d23	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	6e18ff3f-06dc-4ad2-a18c-7a9dc33e4f66
028f3e14-9142-4cf5-9b8d-19461f5a28fe	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	69e1d89e-c197-4a93-997b-14bc02e1a31a
97e4ee71-88d8-45d9-ac63-b05db8b0c8dc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	42d326ad-5ca4-4a70-9827-56795a80e6be
86777dbc-d9a2-446e-9876-e2d5a9a90a73	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	3d4d4732-f830-49fa-a7ea-72b7ba66801e
e822f646-2e45-4440-9134-b00bc8e75aad	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	314cbea3-f0b7-41f4-b609-59e904d83a35
dd96450e-e2e2-4745-889f-1139507dbbbd	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	bfd9dd8a-d38d-4e9e-a50c-55621630213c
c4367a61-1f6d-4043-875c-7401f7a09090	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a3cd85f4-dbc5-4682-8322-3d18814912ff
d41270b2-9899-4603-bd1c-4eba0c9a2b73	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	39ccf293-fcfe-4409-9588-290e3419c592
c9eb34cd-3957-4bf5-960f-8dbe17e5a197	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	cc8c8918-e373-494a-8032-dbad1d9278df
20c7cb58-0ca5-4a73-86c0-29cedb37d818	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3a7b5436-a329-48ed-841d-b103d2e3b4c9
44e669fd-87a8-4e0c-b123-91f35828db95	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	281effef-a0ef-4e40-b504-bb72e4af97cf
ed81d798-e223-432f-b8e0-f4febbbbcadf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	281effef-a0ef-4e40-b504-bb72e4af97cf
33357eef-feb8-48af-b9a0-c4100c3be260	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	281effef-a0ef-4e40-b504-bb72e4af97cf
6fb51a90-40c2-419d-9ab8-63aa6da71c0e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	334f3a3a-1926-4a22-a982-d8f6a40ae667
034fb940-f7eb-4fd2-b690-2edc5b1d1863	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	334f3a3a-1926-4a22-a982-d8f6a40ae667
9b25a609-53ed-497d-91ba-9c6c56072292	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	334f3a3a-1926-4a22-a982-d8f6a40ae667
0f18bec7-93cc-497b-b524-c5c3c6345f1a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	69e1d89e-c197-4a93-997b-14bc02e1a31a
3203eafa-462e-49e7-8868-12bbb5f1f49f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	69e1d89e-c197-4a93-997b-14bc02e1a31a
abf4c8ea-eb5a-4d8e-b64b-2670fe5b4c4f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	67ca82be-45c3-44d6-add9-baa452eb77ff
0fe15f31-5df1-450e-8106-11df2e4d68d4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	67ca82be-45c3-44d6-add9-baa452eb77ff
2f658bf4-0834-4426-9a1c-92e5117af820	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	316e0847-fb38-4f8e-b27d-5674bd1666bf
56401ce3-627c-4c6c-ad58-0f8f1ba70b2d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	aaba247b-5e6f-45d6-8138-7f6c2154f2bd
fb77cdfe-9a04-4646-9a9b-a655d353aefa	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	aaba247b-5e6f-45d6-8138-7f6c2154f2bd
4344ce43-a5fa-432b-9287-6c3d19a1859e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d9158d5b-3529-4301-b4e5-e1bcdc4158c4
089cc615-e37a-4996-946f-7107c4fb4a6b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bd33b8f4-d6d5-409f-830f-47294e5461d1
23a45e41-edc7-4e6f-8b38-1f779b1d59dd	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	bd33b8f4-d6d5-409f-830f-47294e5461d1
948f6425-996e-400b-b9be-071a1d7269fd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a2e9454e-e59e-4c92-aa00-0cf93c3ea168
61f7dbb1-86a0-40c3-927b-1a0a1c4f6ec3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	bd33b8f4-d6d5-409f-830f-47294e5461d1
6247138d-d9c4-4c64-abbf-0d916a02c5f7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	72307b52-03ee-438f-96d1-0d5ea050b9a5
a146a76b-353e-43d3-a206-71a0d5b1baf9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	1ff8c188-c391-4884-82fb-fb90ea649d97
37e5bd95-7a2e-4a97-9029-f40dc1241ed9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	85197957-d929-4d27-b954-d7ace210e9f1
c8555d6b-4279-4d02-925f-fb1f7892d2e8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	11f5db23-1e55-4980-a635-41fc0cf50d93
7f947c21-5111-463e-9ddb-36d3b98ddfc7	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	508022e6-0d24-4d5b-a11c-f8422dbf85b8
e38c28ac-f213-4ca9-a367-ec054f4bf834	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c822c582-3b36-4455-863a-54c47b4611a5
7c0fd194-f06b-4836-b513-d412af906f12	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	d5723028-0256-43b6-9d2c-dee1033aa63a
d59c223a-5e65-4803-8c8e-30372a6ab15c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d389d258-964a-4d0e-b4ef-0387083ed1f5
567242f3-fbf7-4c33-b898-5da299762f14	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	26405f63-d9bc-48a6-b965-c6a5947af58a
17e3fdc4-3d00-48e3-825b-02fe474d9362	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1ff8c188-c391-4884-82fb-fb90ea649d97
f133d26b-b48e-4334-b4fc-a2196a5e3b46	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	85197957-d929-4d27-b954-d7ace210e9f1
27e71a0c-b129-4441-931c-1846146781ac	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	37f7c903-b6a5-4451-9584-37760953d250
c50700e6-efb9-4e92-8731-a9f9c240f23f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	0d252391-9224-48a8-8ec9-dd9cbcb683e4
ddb7fdae-e69d-46b9-9183-cd83ce5f7920	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	0bfa8bd6-dbed-482c-9fb1-8b2475c62d01
85696341-d5ca-4ed1-9f38-0d7f97dfd336	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	aaba247b-5e6f-45d6-8138-7f6c2154f2bd
8a85c55d-22f5-441b-9597-adcf19d80828	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bfd9dd8a-d38d-4e9e-a50c-55621630213c
d1992d20-f5e1-4d6c-8846-214a557e1e77	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3a7b5436-a329-48ed-841d-b103d2e3b4c9
91ebd18e-ec62-487b-99f6-a80d132c5336	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	a27d57a0-bc23-492a-9632-8082d16c7170
9faaaafa-4260-4d42-a8b7-86d495c3b16d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	409af360-66bc-471b-8317-a82430ee6c7d
4caca670-f589-4ac2-80ed-51ffc06964fd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	409af360-66bc-471b-8317-a82430ee6c7d
d4f766ed-e9be-4875-9855-c0563efd8c4f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3b5891a1-fc87-4940-ab0d-0a8433ff333d
ba3fa275-d306-4cda-8ba4-7ef1f2d786a0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	3b5891a1-fc87-4940-ab0d-0a8433ff333d
8b77c017-5b33-4ff4-aba8-b2b756e13224	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	3b5891a1-fc87-4940-ab0d-0a8433ff333d
bd5777aa-dc58-4066-a056-1df5b38a0954	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	fc98af9b-2b1e-4adc-8de7-60508fb088f8
29589642-04a2-47bb-aacd-f8221d1bdcad	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	fc98af9b-2b1e-4adc-8de7-60508fb088f8
dada0052-b6aa-4237-9ec4-00eb1a935269	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	23c409d8-f4d3-4878-8fe3-953870964111
11e48dd1-1657-4492-8031-24866d146134	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	46c40d21-adf4-470a-b558-e79d835ad579
67a6cddf-1d19-4a08-8c5e-d78b06290292	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	dbb7e21c-ac6e-40c0-a691-780ac8dfb450
f8e6eefd-498a-4949-8861-26aff1063219	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	dbb7e21c-ac6e-40c0-a691-780ac8dfb450
0aff0fb4-5352-4f15-9946-d0246f820706	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	6e4f0580-1905-4289-b0e2-9ad9c1db84d1
057da5d8-8fe5-4694-8cd4-c53a15d44605	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	6e4f0580-1905-4289-b0e2-9ad9c1db84d1
39b41747-f213-4589-b204-48c61ba1f396	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9337d5ae-36a0-4a21-afa7-10b2ad8d4e5d
1bb0e59c-5791-4021-9115-c1562a73a77f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	9337d5ae-36a0-4a21-afa7-10b2ad8d4e5d
b32e60ef-10e3-4f23-b206-f078f7604d62	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	46389cbf-b8d5-49de-8278-7f8efe157f36
fd17f8c7-768d-41d6-ae94-18de9c5f5de7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	46389cbf-b8d5-49de-8278-7f8efe157f36
e65417fe-43b3-4287-8db0-ffabb5de6c8a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	316e0847-fb38-4f8e-b27d-5674bd1666bf
b53e71f6-ac57-469d-9cf1-f4dc503b6729	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	4607c983-b3ce-4528-b0df-7be410246578
bc100c29-9ed9-4063-9377-8ba09682099b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4607c983-b3ce-4528-b0df-7be410246578
e36fd937-5a4e-49cf-8e33-78768dcfdea9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	4607c983-b3ce-4528-b0df-7be410246578
95220301-a9b8-4854-bbed-6c1543f1c399	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	76e1779f-f72d-4903-88a4-df32c0ddbf7a
00903c80-3fc5-4368-bc68-09527bf6ac0a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c8d3440d-0a34-4e5a-8154-3a2a2d065f88
6d884773-aa3b-497a-a79a-24d5ff6021e2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c8d3440d-0a34-4e5a-8154-3a2a2d065f88
bf1bcde4-684f-40bb-b967-4e7ee6230515	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	c8d3440d-0a34-4e5a-8154-3a2a2d065f88
362f31d5-2bec-4f40-9916-145e76b4fb22	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ecba77b4-5fbd-4ca9-a21d-8d73c77b5d27
32811b45-a466-420d-aaba-8b2426eb4fb3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	ecba77b4-5fbd-4ca9-a21d-8d73c77b5d27
14bc1731-7bee-42a3-8c10-aa4f30b8b007	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8929682c-550d-4126-87d4-8561dd141c94
23bd2036-417d-44d4-a072-e3b0735f4955	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	8929682c-550d-4126-87d4-8561dd141c94
117e4d16-42a8-4dca-a664-151cb2b152b9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	99bfb9d0-1cfe-45e4-a877-89b22f69ddec
b495af09-2478-4f07-bc14-4bc7b9200048	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	99bfb9d0-1cfe-45e4-a877-89b22f69ddec
5211262d-420c-42ef-b76e-b3420cfab367	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	99bfb9d0-1cfe-45e4-a877-89b22f69ddec
7ebbf5e7-b4b0-43ce-bfcb-2b4458f8237c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4e5f7259-292f-4235-a7f5-33322c291888
46e7e282-4bde-43fc-99db-faacfa8fadb9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4e5f7259-292f-4235-a7f5-33322c291888
f7c65fb6-a75a-4a85-881e-bd0b5877d2b7	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	4e5f7259-292f-4235-a7f5-33322c291888
9c1be72f-6e1f-432b-992e-8fbf4981c4b9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	75289bf7-308c-49ea-9910-14a0f72c86f9
484ac33b-2fbb-4c56-b7dd-71bd4ea28701	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	75289bf7-308c-49ea-9910-14a0f72c86f9
e16c0ddd-2000-4376-9ad7-28389c167c83	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	e40245f6-771f-4c75-8131-58d2766506c8
7863d97a-4c9d-4b27-8790-20ae95c99173	05e02b30-0867-4b3b-8518-0a0805db9706	\N	2	e40245f6-771f-4c75-8131-58d2766506c8
3c3b65f1-f63d-4db6-b38b-8e74dc53efaf	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	99b1f132-5dfd-4cd8-bce2-38f71d12a8af
d87d1154-4ea9-475b-807f-ddc088c2c131	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	99b1f132-5dfd-4cd8-bce2-38f71d12a8af
a620c663-c17e-47cb-9c10-5d333bb3d92f	05e02b30-0867-4b3b-8518-0a0805db9706	\N	1	99b1f132-5dfd-4cd8-bce2-38f71d12a8af
8522bc2c-148a-489c-a864-66bef7bd94c4	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	7dc15126-a8ea-419b-9a69-9965641c91c1
1deecb07-43d0-4768-95fd-f305bf8369a9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	42d326ad-5ca4-4a70-9827-56795a80e6be
4ca420ab-4d92-4ece-9b88-e9bf70a06d0c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b4569222-dc3c-4d38-a01c-51552d0d23d7
5119f512-de2d-490c-a08c-8d7912c80006	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d6fac8fe-af98-491e-97fb-8a6891baab68
cac85243-354d-4de3-9497-964fddbad5e8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4d2893f2-7535-415a-884e-dd060eeb6cbc
85bfec41-0adc-4962-828f-3674a209e2a1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4d2893f2-7535-415a-884e-dd060eeb6cbc
1b230a70-8a5f-4ca8-b93b-66463f67f00a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2e5432cc-ab51-4605-b02c-49c5c00e2605
4faabf0b-c6e2-42da-8850-78fdec5b7e54	05e02b30-0867-4b3b-8518-0a0805db9706	\N	0	8929682c-550d-4126-87d4-8561dd141c94
77cbb2b4-2313-4428-a390-c8833908affe	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	1	0	39ccf293-fcfe-4409-9588-290e3419c592
186ea5ac-64ac-4019-bfd1-9885176f1c70	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4bde4343-0684-40a3-a694-abf824e2fe33
2af0286a-a890-41f4-b2b7-d6937d622be1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	2e5432cc-ab51-4605-b02c-49c5c00e2605
4bedc7b1-5a0d-44f1-8254-43afd796e052	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	51df7326-c23d-4ce8-bb6b-f81662867894
eaa1c14d-e6e5-490a-a202-86d8cb91646e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a27d57a0-bc23-492a-9632-8082d16c7170
e211116e-7522-42cd-9141-4511793558bb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	0d252391-9224-48a8-8ec9-dd9cbcb683e4
ba47390f-f7ac-436b-856d-a1177360e60d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	326add3c-eb17-495c-926f-374e8b982837
9b1c51fc-f0fd-4a31-99b5-2ad9bd9f29ab	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	9c643407-daf7-4827-bf3f-19706be83648
60fe29d6-e98b-4c68-a94f-a375cdae9b09	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1d1a3201-afad-4946-9463-0c5b125e2615
3a009bce-fee3-4576-9344-25d197f786ef	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a6368ef1-e4ce-40d1-b616-fb9693a14a0e
d66c39f5-3b77-480c-8b39-db03d8e24ac7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e40245f6-771f-4c75-8131-58d2766506c8
c3415a6e-37d7-46cc-a3a8-aa195e0f2c45	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a3cd85f4-dbc5-4682-8322-3d18814912ff
fbda60fd-ab93-49cc-aa9d-8056eaa3f4f7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	76e1779f-f72d-4903-88a4-df32c0ddbf7a
729c24fa-6e99-42fc-9b2a-ff0d51100d30	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8929682c-550d-4126-87d4-8561dd141c94
f69fe834-bdda-4573-819c-ad03f33b2849	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8c82a054-9bcc-4286-b55c-aa974443ad8e
06eb8734-b85f-4cdf-8274-f5a7a55b44ce	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	fc98af9b-2b1e-4adc-8de7-60508fb088f8
ea9f5046-8b79-43be-be1e-bab6256a830d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	6e0276fd-af02-48e2-9eb2-2e75f957f888
f64c28f0-ebd7-427f-a034-65043a195401	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4902c1b3-9178-4e16-9be8-4674f57b81dd
3442e5b6-3e30-4d97-ac33-39778f7dcc53	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4902c1b3-9178-4e16-9be8-4674f57b81dd
8486bcac-8c37-4ba9-888c-748eea3b24fa	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8f41c22d-86bc-445b-93ed-a43e0052c10b
e84dc318-684c-408e-bbb0-744f3331c56b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8f41c22d-86bc-445b-93ed-a43e0052c10b
15c3c33e-dfba-453d-a8e8-23d931440f97	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	298bf824-e4f4-49a6-9b8e-e18c15df00c6
cb49d005-6ee9-48cd-bc42-3dbb6afeead0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	298bf824-e4f4-49a6-9b8e-e18c15df00c6
51f6e868-d101-4374-9998-dae99abe98d3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	20cb8218-2234-4f5b-8833-7a0ba8901c84
339dacad-d6ba-4564-96d2-5c0e4fecc684	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	20cb8218-2234-4f5b-8833-7a0ba8901c84
13506b60-f966-4c20-b2f6-e5434dda3adf	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	468a8286-c41a-4042-83b0-95d393857dc1
8f247ea7-9d8a-48aa-9468-35c7c8a55b4b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	468a8286-c41a-4042-83b0-95d393857dc1
2fde8c02-d8f5-4da0-b92d-b04ed0b3ca04	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	9a95b489-962f-4d5b-a175-ab5c3d725cbb
e57d9bf8-af93-44a9-8c79-a21b761180d3	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	9a488d37-920c-4249-815c-4998efd3fcbe
1acf659d-4679-4407-b7c0-d2f56d142df9	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	76e1779f-f72d-4903-88a4-df32c0ddbf7a
a3e970dd-b90c-4ab7-b46a-79c0e54518cc	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	e40245f6-771f-4c75-8131-58d2766506c8
d48d6fae-a2e0-4ac3-8953-e29637d01d66	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	9a488d37-920c-4249-815c-4998efd3fcbe
2ad4b5cd-d1a5-4a7d-aa42-09d035b0ea85	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	d6fac8fe-af98-491e-97fb-8a6891baab68
0f675d5d-ae34-401f-b367-35fc2138d852	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7dc15126-a8ea-419b-9a69-9965641c91c1
1a91386f-598c-4f95-b61b-f07e69aa61ac	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8ae0556d-3282-40e2-91d9-32b84108bb97
47f3362e-12bf-4ff7-8de3-79b83ecd570e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	468a8286-c41a-4042-83b0-95d393857dc1
53cb7068-1bf5-48a1-89d7-f0c80dd4e6fb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	20cb8218-2234-4f5b-8833-7a0ba8901c84
91f23387-601c-49c2-91a7-1bf12a3a91f1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	8c82a054-9bcc-4286-b55c-aa974443ad8e
d202b9d5-d328-4621-8353-50f1aac82609	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	99bfb9d0-1cfe-45e4-a877-89b22f69ddec
38ccdc4d-f590-41d1-89e6-0fb9b543b455	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	99b1f132-5dfd-4cd8-bce2-38f71d12a8af
a3e6134e-9f75-4584-b7bb-279b214b1f9d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	eb554f6d-638d-4599-a492-a67e62b78779
1d25d2cc-763b-4707-b9ff-e78144de18cd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	eb554f6d-638d-4599-a492-a67e62b78779
9fd6134e-4c28-4faf-aeea-2fac8264c027	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	eb554f6d-638d-4599-a492-a67e62b78779
09ee9edf-1c89-40da-94e1-47ce7196c10b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	df47824c-8073-4c51-8386-9a2e0d702e25
07f2d717-0699-4ef8-acae-73e24a02b59f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	df47824c-8073-4c51-8386-9a2e0d702e25
a2a0b1b8-73ae-4ce9-9e98-91b51a9463ef	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	df47824c-8073-4c51-8386-9a2e0d702e25
0f20a69f-a0ab-44f8-9136-134245c91ca7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	ede8cd0a-4aac-4a12-b5f2-24b5c9319f99
4269129f-87a4-4935-a1c8-9f484976f685	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ede8cd0a-4aac-4a12-b5f2-24b5c9319f99
43271d6f-231d-4628-8003-28c40e6e8946	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	ede8cd0a-4aac-4a12-b5f2-24b5c9319f99
33a9c415-7d1f-4617-a0d9-cd8a3f64a543	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a107e628-ba0d-4207-92e8-7bd844beca8c
5dcb0390-67cf-4fc4-be0d-de00c65f14b6	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	a107e628-ba0d-4207-92e8-7bd844beca8c
c7193547-4f29-4113-aa20-c8d055f943f7	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	1dc8aebb-9216-4bf4-934e-526e32fa7d8f
b75fecc5-1f89-45c0-b73c-4c50e6b54b14	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	493d0744-d854-4b40-9a9b-62dcf4538682
8fd02956-43d1-456a-af89-7c637c7ff8d4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	493d0744-d854-4b40-9a9b-62dcf4538682
a2bb6efe-1fca-47d5-a3a8-4f86a7c35025	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f6006a13-c5f1-410f-a5a1-4c6cca27f391
e308930e-ae3b-4c94-8a24-13edf562ac43	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f6006a13-c5f1-410f-a5a1-4c6cca27f391
a91b781c-8e89-4584-9307-5d36b8e0c3cb	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	36acb101-7da7-4eba-add3-1abde739b408
9c8a2150-d338-44ee-b92e-e9ac21163b93	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4802bbea-1e6f-49f2-a250-6c7b50ac723b
05a0a57c-8cd9-49f5-8ef9-a325398c580b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4802bbea-1e6f-49f2-a250-6c7b50ac723b
88d732f7-423f-4604-b4b6-1c7706993911	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	4802bbea-1e6f-49f2-a250-6c7b50ac723b
1a7a4649-d376-44e0-ae41-77114ec06902	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a85b331b-f896-424f-9e68-e89ec02baa9d
8f4eb92b-5c0b-4930-bc29-dc0bee47a21c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a85b331b-f896-424f-9e68-e89ec02baa9d
6f886221-4f47-40f0-9215-3d4fa2037f8b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	8fd67591-1770-4592-ad69-6a114992c9f5
c03ff29d-1f61-4078-a42c-33ef75587b1b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	8fd67591-1770-4592-ad69-6a114992c9f5
23552394-5e44-47d2-93bc-5c34493b2e82	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	8fd67591-1770-4592-ad69-6a114992c9f5
7ecb626e-f171-46b7-b29d-b546716ca530	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	4cfd28a9-7638-44cc-87a6-6c5b8531ec84
3bd15b72-7a23-4f86-a686-7e4f9f568819	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	4cfd28a9-7638-44cc-87a6-6c5b8531ec84
0c4f0754-a069-4775-aa3a-22ffb99a661e	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	0e2ebee8-3f2d-4863-815d-13007b2ffe28
1283c87a-804f-4c95-bec3-f852ef3b6226	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b4569222-dc3c-4d38-a01c-51552d0d23d7
7c06bfa8-aa3c-4ef4-b453-ac03480fcdce	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1a77ad94-37c6-4d5d-9a18-ab679cb39175
085aedb2-45c1-446e-9eac-a14c5c46b69d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	a6368ef1-e4ce-40d1-b616-fb9693a14a0e
2a2e9ab8-8c16-4733-9977-57f892f070e2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	a107e628-ba0d-4207-92e8-7bd844beca8c
fcb0a333-bb18-4bda-a48e-15b587e4146f	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1dc8aebb-9216-4bf4-934e-526e32fa7d8f
476738c4-8e13-4820-878b-cdbf214f62c5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0
4b9e195e-689b-45e0-96ba-2058b0587984	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1dc8aebb-9216-4bf4-934e-526e32fa7d8f
abc231dd-0139-461c-a741-515062cfbbf3	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	0e2ebee8-3f2d-4863-815d-13007b2ffe28
58c86c87-17cd-4205-ab2f-b7e1b2ea27d5	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	4cfd28a9-7638-44cc-87a6-6c5b8531ec84
0679b4ab-e28e-4d01-91ea-653dee1a096a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	75289bf7-308c-49ea-9910-14a0f72c86f9
c11d1034-60bc-4da4-97b5-3fe9b0819315	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ecba77b4-5fbd-4ca9-a21d-8d73c77b5d27
78c56a56-29e7-4cd5-bc99-e76d8f124c61	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f1d8ca78-cc35-4f92-b62e-043175c1094f
879decd2-d2fd-46f9-a15b-e38b92e9e18a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f1d8ca78-cc35-4f92-b62e-043175c1094f
e8f69767-3361-4059-8c5c-9f1ac051730f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f89024c3-9556-4a5d-9afe-c786c90928d2
52d67273-5060-4a69-abe6-d031680277d1	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	0e2ebee8-3f2d-4863-815d-13007b2ffe28
399aafa0-b3fe-42b4-bcb2-570cb6dff3a4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	b67f9c47-62d1-4363-9597-ff40721fa5fb
ba4ab98b-684a-4d4c-ab17-0d6a3ad5a7ed	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b67f9c47-62d1-4363-9597-ff40721fa5fb
2cc2ca9f-2627-4e51-b71e-f9f8e8f7a160	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	f89024c3-9556-4a5d-9afe-c786c90928d2
1bd5cfd0-ce66-482b-8b68-1e2881f8b14e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	bd62d0cf-146b-4d56-9621-244e4e5352cd
e451144a-960c-47d9-9ec5-cb2242c4e3f5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	69f39cbe-2daf-4887-9e45-9a756c8ddc3c
398c7653-1f7f-429f-ba50-00cb701473fe	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	69f39cbe-2daf-4887-9e45-9a756c8ddc3c
30f6ec83-4f3b-4d0d-8c9f-a517efdfe003	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	4dc0559a-ba74-40d1-aa2e-644be03b57ee
b1b84ad4-9b63-4e3a-b4bf-8100e11587ff	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	ba30cb7f-37d2-4b52-b782-484f0582778a
3ea245d6-6831-40c8-a34c-165c953cf199	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	dba825df-6b52-4f67-8ffd-40f0354ae35d
95a59e0e-a30a-4f7c-951c-cca748fa8dae	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	43e8ffde-910a-4f0f-8852-595937f36838
4fab874e-8f69-43be-92d6-a2296a30e240	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	363adf14-a657-476b-83a9-325ebfa6167f
6225fe4b-db0a-4455-88c5-6a4110b09050	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	363adf14-a657-476b-83a9-325ebfa6167f
3fc97d35-2dc3-44e1-a21f-6e4f634ae1a8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	6b8e72cb-598a-4bd0-8dd1-fd6e3ec0c576
22bd885a-9d94-4ff3-8e0d-6ace4112bc4c	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	6b8e72cb-598a-4bd0-8dd1-fd6e3ec0c576
093389d6-6962-4ade-8095-fe755e951e1a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e4230a11-cca2-445f-b228-28d109ac89e5
95a41d8b-ee3f-409a-ba85-e0a2d4b7179f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e4230a11-cca2-445f-b228-28d109ac89e5
c67d3cf9-5cc1-4d1f-ab24-b6ee38bb6700	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	aef9392c-32a9-4613-820e-af62ff4bf67a
735faf59-81ea-48e2-adcc-3f80b18e5d95	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d19a3610-019e-4b86-8d02-3eb852229ac1
08b80804-765e-473e-b486-56f79a97474b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d19a3610-019e-4b86-8d02-3eb852229ac1
35a1b1ea-e2db-4683-b368-900c6946e1c3	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2343ce27-26a5-4dcd-81d9-bae03d99784a
417cc71a-772c-4b05-aed7-0e4fe26ad861	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2343ce27-26a5-4dcd-81d9-bae03d99784a
0d3f28c4-ee86-48fa-a133-e0b74729bb02	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d90522e9-5428-43fc-98c4-a917b3e127a4
a96f7faa-2ac3-4014-932f-2d9cb626a0cf	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f4fbf33a-b258-4b0e-a0da-d62990868a2e
a2898766-a504-4885-b1fc-0d85678f5ec5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	97eee61f-35ac-4a7b-a1ac-4d2d25327ecd
b8e3b4a0-18cc-4855-ac4b-d39dd683fcb0	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	accf8762-30d5-40d7-8a30-e1162f37f44d
26d2b1c5-bf0a-4628-bb38-a425cc21f44b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	44b4578a-2b74-4bf9-885c-c28036067785
88e00f0a-b3bb-4bb3-89f7-a605ddd24f45	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7a369a01-ab99-4d15-a35b-c9dd79978c2c
10416ea0-e6f3-45d4-8356-57add0c7c3e6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	68bab43b-5906-4487-b2b1-27cd035c32c7
8da943e1-e7bf-4124-83de-9b88d87221b7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	68bab43b-5906-4487-b2b1-27cd035c32c7
4afd530f-f961-4a69-84d6-c7fe7a4853ce	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a5d189a1-aeef-4619-846e-37ef41dc8aae
1ad33c8d-7d2f-4935-ad81-eb7de939222b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d90522e9-5428-43fc-98c4-a917b3e127a4
21dc7602-8646-441f-9c73-43c810424a9d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	e0e8cdbf-efac-41fb-9b4d-981f769482e3
7b4c7718-7125-4974-9344-b1b21bb41cce	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	0	12e3378b-1df5-487e-9e56-8e49bfb780df
e6d768ae-7f68-452f-85da-1fc2d0d627d2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	aef9392c-32a9-4613-820e-af62ff4bf67a
c899e4e5-3dff-4cb5-8e97-f55953604a77	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0
1c83eb18-3a55-494a-b790-abce3692ae22	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a5d189a1-aeef-4619-846e-37ef41dc8aae
a0dbb204-8a04-4b4a-ac6b-950b1bc3136d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	b67f9c47-62d1-4363-9597-ff40721fa5fb
4fc6a677-b548-4db6-8e33-90ad6e0078ab	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	12e3378b-1df5-487e-9e56-8e49bfb780df
f1979516-1ae0-46bd-acde-953a5a7da108	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	43e8ffde-910a-4f0f-8852-595937f36838
74180736-bd1b-4dd0-8276-00e85d159590	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1ab57614-5f36-4656-a86d-8dab0ab7f111
5b4473a0-bdae-4aae-bdee-b0a2c940d539	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ad7a7d20-ddb6-464e-9cab-000213aef72c
0a254521-5623-4df4-b4fa-5ab75fbf0a3e	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9e40eb7f-300e-4d29-aaca-7dbfcf5ae35f
bcd4b8b9-be26-44a6-9d67-bd01c2398a1d	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	cb20910e-33f4-4a25-8495-2d2233e0c65a
d279adf7-b13f-4d7a-b892-42024af9f548	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8cb2a4a5-8f52-458a-aff1-b630519a1412
b7269019-3cd3-4af5-ae2f-41dd538f1555	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f7ab7d75-c6a6-42dc-ba7d-11e1ee91d2fb
546cb8de-f6a7-47b1-9edf-1a73dcd5920a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	cce759a5-641c-41dc-bf2d-be4339c668ce
c2fa19ad-3cc4-4f4e-af8d-b26b71bc31d6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	25cdeb8b-57a6-49cc-a961-473a1ce9ba6c
42aac000-d0c3-4bc0-8ebe-ab6ac601017a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	25cdeb8b-57a6-49cc-a961-473a1ce9ba6c
718a833a-da5e-46d8-8f58-d7e45791fde7	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cce759a5-641c-41dc-bf2d-be4339c668ce
2714d8bb-74b0-444f-9d1c-deab9d089cab	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	f4fbf33a-b258-4b0e-a0da-d62990868a2e
38bf25a4-9901-4d6a-8e2d-84b3d7de6b20	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	97eee61f-35ac-4a7b-a1ac-4d2d25327ecd
ff85e743-74ff-4980-a5c3-12e837cf6716	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	44b4578a-2b74-4bf9-885c-c28036067785
a815d039-b643-40b9-891c-9b21a6f56ecf	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	accf8762-30d5-40d7-8a30-e1162f37f44d
0b2055df-43b3-4518-a7eb-50a64ad69b27	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	82bb791e-f319-4a56-854f-0fee7efbdea0
603ab521-2b02-43b2-b32b-f5efee0bec1e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	82bb791e-f319-4a56-854f-0fee7efbdea0
6664f6b6-c04a-4e0d-a861-d02f5608da88	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	dff7d74a-6295-417b-8ef6-c5e21d66f7a0
117f9a31-3396-494f-87dd-099da0dc53b2	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	12444a33-e5d1-4837-bbe5-b0b6bd5102c5
a1c9e69a-040f-4f0d-b3c4-e25d509536ab	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	691998be-432b-47ff-ba8f-7d36e544ccae
a31aaa21-7132-4108-85ca-0944e14b0685	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	737a3ccd-d10f-4dda-8204-a1ad9b500c1e
7d6a368e-e381-4b16-a51f-3bb3742c4573	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	5b37491b-1b89-4fd7-8977-35abe967d14a
64accefa-150a-407f-b09e-efb5803ac0e6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	08cef4f7-a38c-4f00-8708-d10461e8496d
d2ab1da4-e2d7-4e0a-8c63-757fcbbaafcd	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d2a91312-c159-4008-8b7c-4a927a059a72
c1f6f455-538c-40fc-9c0d-ac02850f5b2a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	d2a91312-c159-4008-8b7c-4a927a059a72
648da2f4-4c32-47d6-9f5c-069ea12cecf5	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	7bbe7a32-436b-4731-80f7-135caeb74157
e1aefb83-83eb-4ffc-8f92-74c50cd9f7ea	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7bbe7a32-436b-4731-80f7-135caeb74157
3c6cc9c0-a913-4b97-b9d6-a94fa1f0115c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	7bbe7a32-436b-4731-80f7-135caeb74157
7b440a62-cfc5-4e62-941c-015a45179c99	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	41bf3df1-cfc1-4d54-96d5-185b589c8219
96ece4f3-574d-40c3-821e-a731a9d8ad24	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8883ceb1-8409-4d9a-a7d5-9e0b77aa9d94
a6a4a7c3-8688-494b-898d-eb2d7a00cd0b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	8883ceb1-8409-4d9a-a7d5-9e0b77aa9d94
f025f0f0-2317-4808-a316-8d3337a1c669	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	fa4f77fc-9010-4930-8f97-9ddcf522c252
45a072cb-1b60-4225-a53b-bdfa6d7eb321	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	87a7fcf6-8e18-4e39-8833-c6ec27ef5e0a
38228d5d-fe4b-47f1-90be-128691f9b9c9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cb20910e-33f4-4a25-8495-2d2233e0c65a
9b0faed0-8618-474a-85ad-2edf35ff1e8d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	dff7d74a-6295-417b-8ef6-c5e21d66f7a0
285bccbf-599d-44a7-a2a9-5aa966b02dca	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	3162db89-c536-455c-b655-c709782f43bc
adcc36b0-b687-4eb2-adb2-5b2b47a69a95	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d
b7696686-67cf-4d53-bb54-7bf12aa0ee09	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	ad7a7d20-ddb6-464e-9cab-000213aef72c
04fa7fde-32d8-445c-8e27-2d65ab134da9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	12444a33-e5d1-4837-bbe5-b0b6bd5102c5
d7c53e61-e097-477e-88f1-2caa0e5ae5e8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9a488d37-920c-4249-815c-4998efd3fcbe
2f5b42ae-d1a7-46aa-a12d-0327ab589f64	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	a85fa1e4-9f26-4268-98b7-23ef8bac47a4
636691b5-9d3b-4417-acf5-10ff93e45b14	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f5308cd0-0f94-41a1-af0e-2ea227cf90d3
1c708ad0-8e27-4f98-8046-dd86ff6695d8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	15f80495-da76-4b3f-ae33-ea1ac43890f3
7d6f926f-f9d5-445c-b04d-dcd04e807d58	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	71078803-21e1-480a-a0b3-680bdc73e027
016dc6eb-8503-4713-8ac1-3cc611b87055	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	dbc7eb53-e7db-49a6-9432-998937c2f04f
dea91b53-f126-46b8-9b27-2a56d64ad930	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	847242be-5ae1-4357-b0f9-03a500793cb3
72d70a5a-ff4e-4fea-9c3a-c94a84c4a73d	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	968eed0e-6f20-46e0-b3a7-24be0a7003f4
6c745069-7cf4-404f-a043-e91f10502e6b	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	28f8967b-ef7d-43c1-8aad-ccfe909953e7
5b31ab0e-47e6-4b6b-a1ce-447770c0eaf4	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	12444a33-e5d1-4837-bbe5-b0b6bd5102c5
060f422e-fb42-4d20-b144-5c9cecec8a8f	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	dff7d74a-6295-417b-8ef6-c5e21d66f7a0
e5b33fa6-09ae-46d0-9e0e-501397d22bd2	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	3162db89-c536-455c-b655-c709782f43bc
be55417f-66a7-4edc-bd5d-40713af78353	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d
2eeb224b-0f76-4aec-80d7-b7f5238dadb4	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	1d6c897d-8fd2-46ef-a23e-2a0f90e6f99c
457c41e6-36ab-430e-86ef-411bd071b61b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	8883ceb1-8409-4d9a-a7d5-9e0b77aa9d94
2f240eb0-7554-47c1-bbd1-0edc3f5a4503	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	92eddced-cd4e-4310-b470-09f2a230b729
311a3f2c-ba71-437d-9b78-4da022f90d1b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	bbca77cf-357c-4eac-a5a2-bd7c49055b36
6db3de64-cb58-4da5-838e-2d7614513175	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	bbca77cf-357c-4eac-a5a2-bd7c49055b36
cea28793-b701-4bfa-bf63-ba06662939a1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	9abc134e-a5ba-4ad7-9bc2-5436b8d81fc8
e930c461-4b47-4bb5-8d73-e478a068528b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9abc134e-a5ba-4ad7-9bc2-5436b8d81fc8
e3ad8e2c-694f-4362-a732-a051db582e9a	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	8a189df4-bf12-4c44-8b83-42773cb4082f
fe7425fb-4110-4438-b0c4-748362ba9b02	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	8a189df4-bf12-4c44-8b83-42773cb4082f
9cf15e45-3df1-46fc-b636-314f7e59aa6c	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	44f22275-9ace-4eed-a585-0147c1cb9b9d
55e49748-2180-47c8-ae4f-a0fa5edc7e95	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	44f22275-9ace-4eed-a585-0147c1cb9b9d
7fa40890-658b-41cd-be7d-de2f539f4c75	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	44f22275-9ace-4eed-a585-0147c1cb9b9d
ed89b869-c047-45e3-a0b7-2b7b8ec56be6	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	87a7fcf6-8e18-4e39-8833-c6ec27ef5e0a
7489920f-af04-497d-a767-3ae9da3d38b2	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	043497d1-0d8f-440c-9ae8-24f2cc7adf43
54e77f48-b4eb-4e97-8b4d-94b495820a97	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	043497d1-0d8f-440c-9ae8-24f2cc7adf43
6ffdaf96-b6d3-4841-9881-15e1beba8456	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9ee05df7-4f09-4781-b42d-e4fe77cc1877
5a8347cf-aaf7-4d24-ba81-dcaffa461da0	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9ee05df7-4f09-4781-b42d-e4fe77cc1877
f331cc2a-2917-499b-87d2-dce5d16a26da	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9ee05df7-4f09-4781-b42d-e4fe77cc1877
175b23b9-2f98-48a1-b609-d7322f23c826	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	18fadb91-ef7c-4866-bd25-1d2ef25c1a85
0f887086-f7c9-4154-bf01-9d13b4c4ca6d	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	18fadb91-ef7c-4866-bd25-1d2ef25c1a85
4024f7ec-2cd0-48cd-9d4b-d781ba6b0c58	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1d5bfeeb-928f-4d0f-8e70-b5a7615d3172
cf24af87-33d0-4186-977e-9971e06f5a7e	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	1d5bfeeb-928f-4d0f-8e70-b5a7615d3172
2d3c46b0-f7a0-4e85-98fb-75a0db656347	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	1d5bfeeb-928f-4d0f-8e70-b5a7615d3172
ccc960a5-2179-4f4d-9595-faee01127bb6	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	e2934091-9b05-4c69-b83a-f6b9c253e9b7
bef14943-8e65-4d2b-9484-13a30b611360	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	e2934091-9b05-4c69-b83a-f6b9c253e9b7
5b86a824-f21d-4930-bd55-9f65574f9780	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	e2934091-9b05-4c69-b83a-f6b9c253e9b7
08f6402e-caff-4244-a928-227ba610295b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2330c025-6a8d-4527-a3f6-c06847d63ba2
4ac8604f-68bd-473f-bc2d-4ccf6264088f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	2330c025-6a8d-4527-a3f6-c06847d63ba2
8ba95858-5e4d-4057-ad0e-ca30a1f88f81	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2330c025-6a8d-4527-a3f6-c06847d63ba2
74cd383d-cab1-4603-9e14-75c73f5591f9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	7e4d790e-3d22-4e1c-89d8-6613d04c6955
21a61df9-1d85-460f-9076-37d25088a5a8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	7e4d790e-3d22-4e1c-89d8-6613d04c6955
db7162df-d5f4-4920-b5c7-717e09f4ebd6	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	7e4d790e-3d22-4e1c-89d8-6613d04c6955
4f951faf-5cdb-40fd-8cf8-ef8bfa3c5ec8	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d53f3a9f-4254-492f-a580-66a6d17dc9b4
59a7127d-146f-4c88-a638-ca80ff967e76	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d53f3a9f-4254-492f-a580-66a6d17dc9b4
e812b431-77cc-4bd9-afca-2908c7766776	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	ed862ad2-431e-4dc0-9833-72c64ed5c9f1
784bc8d9-3c5e-4ad3-bd26-cdf9c6f833ca	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	a8233b13-73e4-46f4-ac6a-fbf4e5b24676
fa968412-2233-4dcc-b5b5-8c3dddc47e5a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	a8233b13-73e4-46f4-ac6a-fbf4e5b24676
d4c03cc5-dcb1-4ebf-840d-0635606c9085	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	d7d7b201-9a29-49bf-ae41-2f302f337110
7b2fd66e-47f5-4338-a853-6a9759594e59	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	d7d7b201-9a29-49bf-ae41-2f302f337110
e7aa3036-83c1-4768-8419-8cf442f2fbb9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	2	fa54a66c-e4ab-42e5-9f4c-46b297cd8bca
cc81fc34-c552-436a-8854-9c8378a80cb9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	3	fa54a66c-e4ab-42e5-9f4c-46b297cd8bca
33af098f-8e7f-4168-9570-295c1cacce37	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	9d9b17fc-6f19-459c-afff-e483755963a0
bcb7c95e-df54-471e-ac09-bbba9559e725	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	92eddced-cd4e-4310-b470-09f2a230b729
2ac019a6-b73f-47c1-b1db-7a58fb22521b	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	c0b9a395-5d2d-4349-841e-9b8e4ae1fb16
1f0b3d0a-bfb2-47d5-b25e-2b45b0b944fc	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	c0b9a395-5d2d-4349-841e-9b8e4ae1fb16
00812702-a62a-4c34-9bd9-17ee0075ec66	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	3a6d422a-1801-4714-a965-e81816036b4b
445d30e8-a9cc-41eb-aa5d-f8adcb94ee0a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	3a6d422a-1801-4714-a965-e81816036b4b
c6553c75-3501-49c5-8fc7-410eaf298721	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	b2613d94-7aa4-4753-b13c-297135533962
4cc93922-2c69-49c0-b0d4-2940df71239a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	b2613d94-7aa4-4753-b13c-297135533962
b3e03c0c-022f-4b17-b056-f3d866e94d99	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	b2613d94-7aa4-4753-b13c-297135533962
b259f5a6-cc4b-4d2d-90ab-647edae38b86	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	2dae49a4-9222-4a44-9a7b-408d7d2f90c1
c7f99edd-af28-4f37-9248-78480893cd5f	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	3	2dae49a4-9222-4a44-9a7b-408d7d2f90c1
20a36d67-7ac3-4efc-98d0-3e600330f46a	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2dae49a4-9222-4a44-9a7b-408d7d2f90c1
2240f403-992a-4427-ae32-394fa70a6712	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	46fb1325-8776-4858-99de-ec1423ced26f
af9a5cc7-a588-4910-b54e-af49faa16c54	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	46fb1325-8776-4858-99de-ec1423ced26f
21b1f13d-d573-4394-8067-8e590c9cb582	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	8993da5b-90c2-4af4-801d-b1b08e00be77
058669b0-c48d-41f8-9b72-7aa3170e31d8	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	2	8993da5b-90c2-4af4-801d-b1b08e00be77
096bebdb-033c-4e62-b8b6-2062f94e9471	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f658305e-d395-429c-8c5c-d87c9e0a2c29
e025feae-84a3-4f8e-a7ca-ee0729f932c9	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f658305e-d395-429c-8c5c-d87c9e0a2c29
99f57bbe-ee00-4f3d-89f6-bba7354de6b0	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	f658305e-d395-429c-8c5c-d87c9e0a2c29
c3364cbe-1413-450b-bf90-d93a238ce843	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	35112591-d9b0-46f7-bcc3-56d06538fed0
f5943158-e592-4002-acef-dd83fba518fd	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	35112591-d9b0-46f7-bcc3-56d06538fed0
2bbda661-a941-4b43-8d0b-c5970827aeb1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	35112591-d9b0-46f7-bcc3-56d06538fed0
56cdcec4-90dc-48f7-bff0-9ddbc2130058	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	73caf4fa-855b-4629-b0dd-386d42210374
7f4a7446-8ef6-4460-b7c5-4023780d78e1	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	73caf4fa-855b-4629-b0dd-386d42210374
f02f236d-7690-43d4-ae19-e108727c5a7b	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	73caf4fa-855b-4629-b0dd-386d42210374
0476e5e4-defe-4b97-af31-7f674edd4921	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f2070b32-3f43-4580-a47d-7b1dad432779
6d08e135-6af9-485c-83be-9010840863f7	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	1a77ad94-37c6-4d5d-9a18-ab679cb39175
f1ab0d99-8bfd-49b5-994f-5be08f9d4e4a	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	42d326ad-5ca4-4a70-9827-56795a80e6be
4b68b15e-a462-433e-a819-a02fdd7ea94c	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	0d252391-9224-48a8-8ec9-dd9cbcb683e4
7cc54e35-a66b-4f80-9669-57e21aa51cde	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	f632628f-203a-4e8d-8151-c82c4116adad
f96ae487-ad02-4429-9f5a-2083ddaeac89	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	f632628f-203a-4e8d-8151-c82c4116adad
453d5699-2da7-4bcc-9ce4-1f8bfe0d54b1	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	2a66ac9d-0c8e-4c7b-a7b7-d6e615dd8d28
2520ed7d-1132-4b9b-849c-4f8dc159c2e9	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	9a95b489-962f-4d5b-a175-ab5c3d725cbb
6ad6e8da-6c42-4298-b7c5-3dab9b4d9b07	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ce46e8b8-19e8-48b1-b9cc-030dd7c66660
a07fe940-9aa8-4764-966a-3d45c9606677	394dd3f4-45e4-4eaf-9028-3260e229bb65	\N	1	ebb9249d-6b6e-4440-a613-62700db7d0cf
8d09c654-29eb-4c26-87ab-8880dc460a57	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	1	ebb9249d-6b6e-4440-a613-62700db7d0cf
bce16d71-760f-4cf7-8b6d-5a43d6ff2862	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	1	9d9b17fc-6f19-459c-afff-e483755963a0
23d322a7-904d-4743-aa94-9bff534a3959	d4c5c7d6-cc72-4381-80e6-9b87e99fe772	\N	0	d2a91312-c159-4008-8b7c-4a927a059a72
9c6c9b59-1ab6-4bf8-872d-a278f657e65d	88d8c3ff-c506-43a2-a7ba-2617fd7c679d	\N	0	ed862ad2-431e-4dc0-9833-72c64ed5c9f1
\.


--
-- Data for Name: itens_venda; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.itens_venda (id, venda_id, produto_id, estoque_id, descricao_completa, quantidade, preco_unitario, subtotal, cor) FROM stdin;
ea8687f0-208e-4a25-928d-0c391a08c624	50780636-1df1-4faa-aa12-0592fc1d85f7	97fba60a-fae3-497d-bd3a-081ba65a7d11	420ffab2-6191-48f9-9b68-16c607430b2b	TOP ELASTICO COSTAS NADADOR BRANCO OPTICO - BRANCO OPTICO (G)	1	240.00	240.00	\N
c670e06b-62bf-411e-bb20-409915b6e07f	50780636-1df1-4faa-aa12-0592fc1d85f7	b49bac40-5aca-44ea-91f9-36b138fae931	fec44e40-4b84-48c2-80cb-11f92dd4ee87	TOP ELASTICO COSTAS NADADOR PRETO - NADADOR PRETO (G)	1	240.00	240.00	\N
78e5773c-72cd-4374-807b-9fe44b2b6616	50780636-1df1-4faa-aa12-0592fc1d85f7	aeb598db-17f0-4e9a-8804-cc5d10b440d4	95eafabe-563c-43e0-b40c-6e6234303922	LEGGING ASSIMETRICA LISTRAS E BOLSO VERMELHO VIBRANTE - VERMELHO VIBRANTE (M)	1	320.00	320.00	\N
3d75a47f-0ff9-4b38-849c-6e5820444536	8e8930cf-5748-4db9-841d-f21d3e34bf90	74d58012-c42e-41c9-b4e9-14a3f046e43f	e7c0d408-6370-489c-bce5-f2d0f8acbfcf	SHORT ALECRIM RIPPLE - Verde (M)	1	141.19	141.19	\N
200f7029-ec3f-4ad5-891d-2af9188023d5	8e8930cf-5748-4db9-841d-f21d3e34bf90	749ede5e-8fd6-4cd9-bb4b-0f52b100de12	58c0eb7c-a992-4a7e-b5a6-e7b9fd91d58f	SHORT STORM EVERYLINE - Cinza (M)	1	149.28	149.28	\N
50c59967-b2a7-43b1-97fc-0a3fd60a42ea	8e8930cf-5748-4db9-841d-f21d3e34bf90	b6f403e1-f88c-4232-87db-7ea4b8713d05	a8693c10-6878-4e80-bfc7-d3dc592312d5	TOP CROCO DUPLA FACE RIPPLE - Verde (M)	1	135.14	135.14	\N
64440c0d-2358-4524-b8af-e0daabf9f025	8e8930cf-5748-4db9-841d-f21d3e34bf90	6ab17bb2-6aa5-47ab-8d06-9657943a92a0	cbee71b9-88db-4177-858e-a951226e5003	TOP POP RED EVERYLINE - Vermelho (M)	1	135.27	135.27	\N
2b3912ed-35cc-4e90-9d63-54fa208a0ad3	70b3de88-4be4-4917-9b7f-329d4b43795b	bca813d2-0870-4fb4-b690-3b8ce744ca3c	d3a0c32a-41d2-4326-9c28-54ae96820938	SHORTS BICOLOR VIVID - C0001 - BRANCO (M)	1	189.90	189.90	\N
bdf02368-108e-4ba1-8832-1e57c91fcbc8	70b3de88-4be4-4917-9b7f-329d4b43795b	6e056781-f22f-4806-bdde-c66288659526	eb1f3f57-3db5-44b5-89df-c43d00cb6180	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID - C0001 - BRANCO (M)	1	189.90	189.90	\N
336928ae-da1c-40c7-b2a7-8629cd24216b	70b3de88-4be4-4917-9b7f-329d4b43795b	48999143-c489-469b-b0f4-d13827a99571	b4ff50ac-01c6-4637-b57f-89e9cebd339f	BLUSA MANGA CURTA DRY FIT JANICE - C0007 - LARANJA NEON (M)	1	129.90	129.90	\N
6dfeca71-d38a-409e-8f54-219f123991df	70b3de88-4be4-4917-9b7f-329d4b43795b	a8f9fedc-57eb-402f-b5a8-65f03b97f1a8	1d292321-bc10-483f-97f7-e3582a7db7d4	LEGGING FUSO TRICOLOR FORCE - C0002 - PRETO (M)	1	279.00	279.00	\N
f4a74a3d-4435-4559-ad65-b6ba7c59805d	70b3de88-4be4-4917-9b7f-329d4b43795b	3821f950-75b1-42be-94ce-514ac77674de	f9fbf375-d64e-48bf-a58d-ad1960422695	Top Serenity Everyline - Azul (G)	1	136.64	136.64	\N
efbd2de6-fe92-4544-adab-b8bf1e4b7ef4	70b3de88-4be4-4917-9b7f-329d4b43795b	d8c4b2ca-77cb-4f6b-bd05-969eec7fe34d	aac84a58-110a-4f6a-b90c-7137cad08c72	Calça Legging Cocoa Everytime - Marrom (G)	1	240.50	240.50	\N
cfe2a762-2676-4b33-8733-ca77589d54a3	70b3de88-4be4-4917-9b7f-329d4b43795b	8d43f80f-32fc-4b5f-9ba5-feee72d699b3	865504d6-468f-4063-b7e7-0f1e3b5c2e4c	Top Cocoa Everymove - Marrom (G)	1	153.64	153.64	\N
2029453c-1876-46a9-bcc9-7907dc477bc3	70b3de88-4be4-4917-9b7f-329d4b43795b	45ab48a9-9bb8-479a-ac06-8493a16f661b	f713413c-9270-41ab-8586-d0c093578732	Short Cocoa Everymove - Marrom (G)	1	156.47	156.47	\N
eeeca14f-3b33-4d43-bd9c-8487106c31ba	e95183be-3c02-4a88-a1a6-7449f2175023	45ab48a9-9bb8-479a-ac06-8493a16f661b	2361a7b3-0efb-4c26-ad48-82db709dcaf6	Short Cocoa Everymove - Marrom (M)	1	156.47	156.47	\N
16d21131-bb57-4b53-89eb-6d00dfaab40e	e95183be-3c02-4a88-a1a6-7449f2175023	8d43f80f-32fc-4b5f-9ba5-feee72d699b3	2c796035-dfb8-4973-b996-4120bab89572	Top Cocoa Everymove - Marrom (M)	1	153.64	153.64	\N
b8194fd7-362c-47e3-bb03-656e24f832b4	18cd6848-d998-4fae-9a23-6b0bcb951fd7	70d64c00-4d7d-4b67-9cee-739ca9d062d0	61afc0f6-b0e0-4db6-be40-ca28aa408703	T-SHIRT ETERNA GOLA V ROSA DOCE - ROSA DOCE (M)	1	160.00	160.00	\N
d6df92c3-f122-4546-8296-cef7dbf7e3b6	9bc77b51-8fa3-4403-95be-a2021c885604	59aec366-a55e-4aa9-88d8-5659a6ce3af5	363fd144-651e-4fb6-886c-d66dfcf699ae	JAQUETA CORTA VENTO CRISTALE - BRANCO (M)	1	369.90	369.90	\N
c7f447d4-6610-48c9-9cb7-3830b3e39dd7	e30df005-79ed-4d50-adbd-6b075a3a858c	bef92425-0281-4d62-b06e-607e557d8c9d	96c98c01-f7d2-40a4-8b4e-a817f12f2efa	CONJUNTO SAIA E TOP SABINA - C0002 - PRETO (M)	1	179.90	179.90	\N
abd20dbd-9fa0-4a1b-926e-a7d037944a89	e30df005-79ed-4d50-adbd-6b075a3a858c	dbc5252a-ad89-4603-9fd3-960f017fa9e2	a36e87f2-a98f-42bd-9263-77bb020a18d1	TOP CROPPED SENSE - MANTEIGA (M)	1	179.90	179.90	\N
98cb7dae-8228-41c5-be8a-92cba6834e20	e30df005-79ed-4d50-adbd-6b075a3a858c	ecfe6c61-24fe-406d-a552-31ef3a28b4e3	b4be9f34-2a17-429b-a794-db242659b726	SHORT BOXER SENSE - MANTEIGA (M)	1	199.90	199.90	\N
68bbe524-ddb9-4e78-96e1-d35f6e57e5d6	e30df005-79ed-4d50-adbd-6b075a3a858c	3ac1ddca-642d-4e59-be7f-6db747165549	aa893995-8384-40cb-b085-95637b820766	BLUSA MANGA CURTA DRY FIT ZADAR - C0001 - BRANCO (M)	1	159.90	159.90	\N
8f4b4b3f-dec9-495f-b6a1-6f8893e40eb0	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	8fa37df0-d45e-4e32-a938-707801477ad0	d2cb5239-4cac-4846-bb93-407e1c856d46	TOP CROPPED SENSE - AZUL NEBLINA (P)	1	179.90	179.90	\N
4af4ee7e-4357-4669-a934-b1b284a435b3	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2	ce9763c4-a3fd-4a78-8d16-82938be0b578	SHORT BOXER SENSE - AZUL NEBLINA (P)	1	199.90	199.90	\N
e3a3957e-e97b-41ed-b280-2a6c5a6efd7b	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	ca957b05-f901-457a-bb3f-4d2f51560b34	38d1e418-8821-41eb-8d73-9ad2b2bab5d3	COLETE BRAVO - PRETO (M)	1	199.90	199.90	\N
80a10dff-e1ba-490e-86f5-bab2a0494619	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	68eee4c1-6ae7-4045-a26d-4ccd7176df43	9d795b3e-da62-47e3-9705-4e86d71cab3e	LEGGING FUSÔ AVIATOR - C0173 - MARINHO ESCURIDAO (P)	1	229.90	229.90	\N
e2ba25f3-a437-4977-84bd-fb0fc86a150e	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	0f66d00d-9186-4d6d-b34e-46f468a0eebf	f0f05d59-8219-41bd-aae7-4aa9cd94e525	TOP MÉDIA SUSTENTAÇÃO AVIATOR - C0173 - MARINHO ESCURIDAO (P)	1	129.90	129.90	\N
91043556-531c-4506-b053-1d404b1be3d3	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	3eb37bde-1dcf-4f9a-9e08-8c1d605d5677	f75ad8bb-51cc-4140-bd74-080d0c4ebb70	SHORT MARINHO COM BLACKOUT YOUTH - Azul (M)	1	156.39	156.39	\N
e87cf65c-c364-4403-8659-0cc5967dc896	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	2c8461c4-e54d-44cf-b630-aaabb5572c1e	52cd8cda-11d0-4b44-8cce-a56e2937a4a6	TOP LIMA COM BLACKOUT YOUTH - Verde (P)	1	139.47	139.47	\N
e3578650-d9ff-4afd-8648-e2a50a3f87b1	3a385a02-2b2d-4546-bdbf-4d8b98e5d53f	dbc5252a-ad89-4603-9fd3-960f017fa9e2	a36e87f2-a98f-42bd-9263-77bb020a18d1	TOP CROPPED SENSE - MANTEIGA (M)	1	179.90	179.90	\N
510efde0-29e3-4235-b062-6a517211e1f7	3a385a02-2b2d-4546-bdbf-4d8b98e5d53f	ecfe6c61-24fe-406d-a552-31ef3a28b4e3	b4be9f34-2a17-429b-a794-db242659b726	SHORT BOXER SENSE - MANTEIGA (M)	1	199.90	199.90	\N
c84402c0-881f-48f4-9e96-b8da268c7272	3a385a02-2b2d-4546-bdbf-4d8b98e5d53f	3ac1ddca-642d-4e59-be7f-6db747165549	55c84366-063e-41d5-a7f5-ed0680b92bf4	BLUSA MANGA CURTA DRY FIT ZADAR - C0001 - BRANCO (G)	1	159.90	159.90	\N
a8c893e1-995c-4b99-bf66-f5f7bddc05aa	1fe9b44b-e800-42c2-8860-751501baf75c	424d591a-67df-4b58-b24c-847287c57fe5	ab591b52-7a54-4482-9414-e5e4782ec9b8	Short Cocoa Everyenergy - Marrom (P)	1	141.96	141.96	\N
7a3a9ec5-8552-48dc-ba7b-0df287d67b9f	1fe9b44b-e800-42c2-8860-751501baf75c	982f6554-aea1-48cf-b717-c62f92de6568	e54831a6-130e-414d-8ab9-86d9a60f589f	Top Cocoa Everyenergy - Marrom (P)	1	136.01	136.01	\N
8231fcc3-08a6-42b5-8430-261a5f54463b	22ed3572-8295-462e-8ff2-abf353e5a1ff	d9127c0d-1b71-427e-9991-34814b25e8f2	56f7787a-a393-44cf-8c7a-72cc4b4e26a1	LEGGING FUSO TRICOLOR MOTION - C0550 - EBANO (G)	1	215.00	215.00	\N
5eff106f-bea7-4dbd-8cc1-3bbad83dc63f	22ed3572-8295-462e-8ff2-abf353e5a1ff	f6035591-635d-44b0-9217-87e80cb5acab	6b48fd1c-5cfa-4d8e-8e55-ea3512181c12	TOP ALTA SUSTENTAÇÃO MOTION - C0550 - EBANO (G)	1	133.00	133.00	\N
81289225-162b-470b-a8de-01ebe33b3286	22ed3572-8295-462e-8ff2-abf353e5a1ff	bab94c54-9ef3-4197-9f5c-a0bbe357d309	fdb93948-d13a-4ec6-b620-8ed952063c19	LEGGING ESSENTIALS PRETO - ESSENTIALS PRETO (M)	1	270.00	270.00	\N
7156ffd3-89b4-4cbb-a76e-d07a62e6a14a	c93e7bf8-0fe3-4069-8ba6-fa0bff528634	6f6a7e5e-8263-429f-b753-e2175699836b	c9cd8f90-a0ad-459a-a6f4-521719d1ee99	TOP ALTA SUSTENTAÇÃO ELÁSTICO IMPULSE - C0084 - AZUL SUBMARINE (GG)	1	199.90	199.90	\N
47d195f8-bd0a-4d7c-a181-6f8594f3aade	c93e7bf8-0fe3-4069-8ba6-fa0bff528634	d88b3467-2808-4435-8722-330c89f4dc47	a4b10422-eb8a-49ad-b71d-a51eebb297dc	LEGGING FUSÔ ELÁSTICO IMPULSE - C0084 - AZUL SUBMARINE (GG)	1	299.90	299.90	\N
0b4ae73a-50f0-46f0-8828-880507afaefd	bdd3797f-f159-4360-ba05-59b95ee6da3e	abf441fa-cbdd-4904-ba8b-65c70f37f53b	603b2c41-5a04-4f95-8720-4e2502e5ad76	CALÇA LEGGING STORM EVERYTONE - Cinza (P)	1	198.28	198.28	\N
496d3f03-da88-4809-aa3a-9d5ad7244d3c	bdd3797f-f159-4360-ba05-59b95ee6da3e	efd9997b-9730-4b62-90ac-cf329487482a	5b22f16f-ad5b-477e-97f8-ac3429e89300	TOP SERENITY EVERYTONE - Azul (P)	1	155.27	155.27	\N
0cf562a5-d6c2-4f0d-b47c-197adec4f361	136bae77-5194-4318-9fe2-0d9cbef9a9b4	0bd12109-1bc9-4aca-bbeb-4a830e1e189b	9f36b513-d275-42fb-bee5-008f84ae1dd0	TOP NADADOR ELASTICO PERSONALIZADO AZUL BLUEBERRY - AZUL BLUEBERRY (M)	1	205.00	205.00	\N
74fa5ba4-4fa5-4fd3-9891-e761e8bd0815	136bae77-5194-4318-9fe2-0d9cbef9a9b4	32a6d01e-f913-44e2-9872-c04f433046fb	0ed76af2-9d96-4975-8adc-c777d432b552	SHORTS ELASTICO PERSONALIZADO E TULE AZUL BLUEBERRY - AZUL BLUEBERRY (M)	1	210.00	210.00	\N
37ba5e59-1ee1-44af-9d0b-08a46eaa5124	a545d132-497c-41d0-9052-7b96bb3f9a84	67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2	301c1a09-1bcc-4eb0-85dd-a58cad70c86c	SHORT BOXER SENSE - AZUL NEBLINA (M)	1	199.90	199.90	\N
00366883-5362-419e-9d0e-d5cf1b94f769	a545d132-497c-41d0-9052-7b96bb3f9a84	d69c6f1a-ffb2-4faf-aa55-974f59e94bf4	4549bbfc-42a3-4497-92d1-9b59d525e639	REGATA FITNESS DANIELE - ROXO AMETISTA (M)	1	139.90	139.90	\N
e507f00c-be21-4870-8d97-b35bded34d58	d5f32451-caad-4a78-80db-2f6f370284cd	c4c02bd8-32b4-4477-944e-359394fe8d3d	49ef1864-67c4-410f-a6ae-4f6765de1499	REGATA FITNESS DANIELE - BRANCO (P)	1	139.90	139.90	\N
0397991b-a598-4785-851e-69b6ed378396	d5f32451-caad-4a78-80db-2f6f370284cd	10b05256-8c65-4a61-b046-7f5e5ce22ae9	452a8ede-1bed-44df-84c5-f649ba8f2c76	REGATA FITNESS DANIELE - PRETO (P)	1	139.90	139.90	\N
740ca281-3dcb-4461-b559-fdc24bf1c3d5	d5f32451-caad-4a78-80db-2f6f370284cd	02ca7973-0ef3-4180-8774-3fb42e9642cd	1ee2217d-fbed-4368-ba3f-9f863bba7e7e	COLETE CRISTALE - BRANCO (M)	1	319.00	319.00	\N
618fc8c5-d225-43a9-8dfd-407b8be09351	d5f32451-caad-4a78-80db-2f6f370284cd	ea9742b4-b495-4787-a7cd-f53352a29c99	f7bb6311-0a98-435c-921f-e00907077b28	BLUSA MANGA CURTA DRY FIT JANICE - C0009 - AMARELO NEON (P)	1	129.90	129.90	\N
6c4a4e08-2a2b-48a5-885c-f51586a7e251	657db4fa-adf1-4e2d-9a28-98a0041311b9	d69c6f1a-ffb2-4faf-aa55-974f59e94bf4	e180cb2a-24e8-4c98-8e40-73fe9c09feb1	REGATA FITNESS DANIELE - ROXO AMETISTA (P)	1	139.90	139.90	\N
8fc3a2c0-ca98-4d63-94b1-e16d22ab7883	657db4fa-adf1-4e2d-9a28-98a0041311b9	3aef3c68-a258-4f54-9526-223fda41c8aa	1af5462d-485b-4b8b-816b-132f413223d1	TOP LEVE SUSTENTAÇÃO PARK - C0515 - ROXO AMETISTA (M)	1	139.90	139.90	\N
b8a59dd4-7c46-4d26-9e92-9ac1b2113195	657db4fa-adf1-4e2d-9a28-98a0041311b9	0ef1c1c9-8c50-44e9-98c1-89a87e856803	f412fc18-975f-4407-a027-5614279dd73f	LEGGING FUSO LISBOA - C0515 - ROXO AMETISTA (M)	1	209.00	209.00	\N
a28825de-e3fe-4460-8385-1a5ac91c9b4e	271f0269-611b-47ca-924f-53fb4f9e4a82	324a4866-e38e-4841-b189-c834b04f5205	97f6d8a5-1f4a-4845-bce4-47dcc56e4940	LEGGING ELASTICO VERDE PRIMAVERA - VERDE PRIMAVERA (P)	1	320.00	320.00	\N
f7bd2114-7b60-4f93-837e-33f74364af63	271f0269-611b-47ca-924f-53fb4f9e4a82	97a1ff92-f4a2-4f35-9d24-231c598fd6b9	92f4392c-60d8-43a7-a8f6-55e9cc9f51af	TOP NADADOR ELASTICO PERSONALIZADO VERDE PRIMAVERA - VERDE PRIMAVERA (P)	1	205.00	205.00	\N
fa123201-1676-4974-bbd7-65d8373d88f2	898c5028-dbbb-4708-8a72-ff154f72c37c	59aec366-a55e-4aa9-88d8-5659a6ce3af5	363fd144-651e-4fb6-886c-d66dfcf699ae	JAQUETA CORTA VENTO CRISTALE - BRANCO (M)	1	369.90	369.90	\N
7999b071-2495-455c-a376-cb7a2e0eae02	79ca1441-55e3-47b3-a1fa-90a4fc49d27d	5222e144-e660-49e4-98a8-45093105323e	dfdfead2-4217-414a-905c-d7777d63c7e0	CALÇA LEGGING PISTACHE RISE - Verde (G)	1	218.67	218.67	\N
7318d85d-81cd-4cb1-aea6-b451a10dd273	79ca1441-55e3-47b3-a1fa-90a4fc49d27d	acdbdc4b-b73c-4199-884b-1dd0db809e91	97596847-81d8-457a-9699-c82c7a49241c	TOP BRANCO E-WELLNESS - Branco (G)	1	131.67	131.67	\N
03423975-76ba-4f0c-bd53-d2d2e627c032	79ca1441-55e3-47b3-a1fa-90a4fc49d27d	d90fc150-1d5a-4f27-988d-009d35eb6208	8377a140-818f-4921-b37b-7a6ac6cd7fc3	BLUSA MANGA CURTA DRY FIT ZADAR - C0002 - PRETO (G)	1	159.90	159.90	\N
577c428d-6e73-4c08-8fca-86a17189c484	79ca1441-55e3-47b3-a1fa-90a4fc49d27d	e37154ed-ab5d-4afb-a128-bf216c3f61e5	e1390e7b-6e2b-4f41-a060-c6f1feb39610	BLUSA MANGA CURTA DRY FIT ZADAR - C0346 - ROSA SATIN (G)	1	129.90	129.90	\N
b1e83cfe-8487-45d3-a166-1b17eabbe705	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	a26aa634-b21b-4b21-a127-702abfab1f20	d8e2ca82-7b86-44bc-a648-fb2091189b40	Top Cos De Elastico E Alca Dupla - VERDE (M)	1	220.00	220.00	\N
3f26df7a-b16c-40bb-8673-7e2fe90b5539	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	23f42e5e-8baf-451a-8232-4639513222a4	ecd9950d-5b8f-4926-8c65-5dd764fa46c6	Shorts Sobreposto Com Elastico - Verde (M)	1	268.90	268.90	\N
4cc3b8b1-1877-447e-a606-517b9b2d30c2	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	7b2dd504-50ee-45ab-83c1-8ce5552c3394	42e31d20-67bb-4b06-8e5a-6b317426610c	Top Alcas Finas E Costas De Tule - Azul Claro (M)	1	235.00	235.00	\N
1c5e11ba-fc46-49f5-a456-07db96cdf4f0	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	8bfdd37a-d956-4320-975c-b0ac0a319317	c6e5f0af-0f98-4c50-8700-93c9d52d17c7	SHORT CASUAL RUN - PRETO (G)	1	167.41	167.41	\N
f804514b-ee50-4ecf-a18f-4864083d129a	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	80b0e230-bee4-46c0-9ff3-bf55b59955d5	ceb4e44e-da7d-4a1c-b426-63bedabb19a3	TOP PRETO FRAME - PRETO (G)	1	134.29	134.29	\N
318dd8da-1294-47fc-bef3-00c6a46af155	9e0a854e-eccf-43ae-87d3-18a676af89a2	1af532e8-1f99-47b1-881a-33f63f18287a	2364d8f5-08a4-4a24-a6f5-ebdb31939984	Short Preto Cityflow - Preto (G)	1	168.08	168.08	\N
33dbfd30-57cd-48aa-b1d9-91419d2527f6	9e0a854e-eccf-43ae-87d3-18a676af89a2	80b0e230-bee4-46c0-9ff3-bf55b59955d5	ceb4e44e-da7d-4a1c-b426-63bedabb19a3	TOP PRETO FRAME - PRETO (G)	1	134.29	134.29	\N
80322078-1bcb-4185-b3df-0307fb638498	9e0a854e-eccf-43ae-87d3-18a676af89a2	3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735	94458769-1634-4f21-b50a-462ea40544ae	BLUSA MANGA CURTA DRY FIT ZADAR - C0280 - VERDE MENTA (G)	1	159.90	159.90	\N
14cabf7e-994c-47e1-b152-6e46e11eb9c9	8f7f1d2e-d845-4d95-a2d2-857cf11e5358	ddfc3385-ddc8-4ade-bac2-7bdc6fbfa9a5	cb482c80-134b-4d20-b2c2-d0f158c1f484	COLETE BRAVO - BRANCO (M)	1	199.90	199.90	\N
2a723b07-fd59-4985-af48-651f48943fe3	8f7f1d2e-d845-4d95-a2d2-857cf11e5358	ca957b05-f901-457a-bb3f-4d2f51560b34	38d1e418-8821-41eb-8d73-9ad2b2bab5d3	COLETE BRAVO - PRETO (M)	1	199.90	199.90	\N
863c76bb-670b-4baf-a577-6b2f7e9eab20	07406a7e-bbf2-4886-a4ce-b3e7952a2fb4	32abbbfd-598e-4841-acda-3308c99d10a8	3beff6a8-8b89-4cbb-a2f5-303df6e31488	COLETE JULY - VERDE MINT (M)	1	289.90	289.90	\N
28f75288-68b3-4362-b251-25091d88140d	07406a7e-bbf2-4886-a4ce-b3e7952a2fb4	0d3caf74-bd91-49de-aaf0-35021ed180d3	f86c9dad-6bcd-49cd-a9b5-9f9b7ca92d05	COLETE DRY FIT INTENSE - Preto (M)	1	199.90	199.90	\N
e4733ee5-642a-4dd1-84eb-e9bc1daa1322	07406a7e-bbf2-4886-a4ce-b3e7952a2fb4	f1e2c779-0cb7-4341-a46b-b7aac9105bd2	5f7ae9e5-93c2-4413-98b7-0951beb39e1a	SHORT JULY - VERDE MINT (M)	1	210.00	210.00	\N
55f7575f-50c9-4097-ad58-504d70f61f83	21d0a14e-fe32-4cce-a53f-dd04256d1836	d35665ce-46f4-4b59-a491-eb22731c6422	e4eb7ebc-885e-43a5-ad90-7e71fe9ba5b7	JAQUETA CORTA VENTO MOVEMENT - Branco (M)	1	289.90	289.90	\N
5852795f-c412-462b-ba43-56d366525133	21d0a14e-fe32-4cce-a53f-dd04256d1836	e289df1e-64bb-4091-8c72-0c72aec52501	7470f8ba-6912-4230-9898-593b4a44aa73	JAQUETA CORTA VENTO MOVEMENT - Lavanda (M)	1	289.90	289.90	\N
49f0e941-bdd8-4df2-86d7-1a2bfa2e1c48	c2ddf683-8768-4178-b1fa-6bef806ad340	511252b4-4a5e-433a-ac9d-e31fd182144a	838efb1b-c446-4e50-8be7-0cbac9b75f35	TOP NADADOR ELASTICO PERSONALIZADO BRANCO OPTICO - BRANCO OPTICO (P)	1	205.00	205.00	\N
e645aa85-3bd0-4bfe-9d27-00a3f6db9cbf	c2ddf683-8768-4178-b1fa-6bef806ad340	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	c749bda2-13a8-481a-b3c7-9fa5bdd10e07	Blusa Tule Básica - Branco (M)	1	139.90	139.90	\N
36af6285-20ff-4a92-9735-85336bbc8b0f	12d68805-4d98-41ff-be17-c5dc737b75fd	cec93d51-6aeb-484f-a139-cac515ba14c9	90ae99a0-29cd-4044-9ea1-880fd4adf77f	BOMBER TEBAS - Branco (G)	1	249.90	249.90	\N
77544f7d-be64-4cd8-af5a-d8f51b79f358	12d68805-4d98-41ff-be17-c5dc737b75fd	68561129-9cd1-4cbc-b434-a2e9da1a8d61	2caca9a6-d4e7-4f76-a609-5977f7eab1ef	CALÇA LEGGING MOTIV - Branco (G)	1	259.90	259.90	\N
1782b3e7-b69f-49fd-b484-01fc089f664b	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	f4d73fad-c742-4a57-bc32-aec016eeee73	014de473-3ddb-4e33-ae54-7c6094006f44	TOP ELASTICO PERSONALIZADO ALTO GIRO VERDE CALIDO - VERDE CALIDO (P)	1	200.00	200.00	\N
0243cd28-aa91-4ff9-8386-7b268db76e77	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	87e4682f-f04a-4e7c-88e9-0829fda3d325	5a55a8bd-ef0d-413a-af52-13cddcd5fe5c	LEGGING ETERNA COM BOLSO VERDE CALIDO - VERDE CALIDO (P)	1	270.00	270.00	\N
0196e0e4-827d-41ca-8d41-bf7d7a841047	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	fac47062-4296-46a9-845f-ae567089a3f9	7569007b-e10f-4b4e-a00a-8a6390a9bd0e	Regata Tule Celeste - Branco (P)	1	129.90	129.90	\N
73b24a35-4f86-4475-8411-3a530a00aa69	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	bfcc1f5d-691a-43e0-80f4-d6d7b87404b9	420c94ce-d9e6-4560-afaf-9212609cf177	JAQUETA CORTA VENTO MOVEMENT - Cinza Pedra (M)	1	289.90	289.90	\N
8be731d1-5111-4a68-89be-274629386ae1	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	d35665ce-46f4-4b59-a491-eb22731c6422	e4eb7ebc-885e-43a5-ad90-7e71fe9ba5b7	JAQUETA CORTA VENTO MOVEMENT - Branco (M)	1	289.90	289.90	\N
48d548bd-fb3e-4fb9-89c2-11268b07d312	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3	8a548f43-0ad2-4df5-bebe-fb2aff03165d	Regata Tule Celeste - Preto (P)	1	129.90	129.90	\N
f3c7d35c-8af9-4288-93b8-9c158b083a54	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	aeb598db-17f0-4e9a-8804-cc5d10b440d4	1932f258-21bc-468c-81e3-d62ab756eb4b	LEGGING ASSIMETRICA LISTRAS E BOLSO VERMELHO VIBRANTE - VERMELHO VIBRANTE (P)	1	320.00	320.00	\N
0d228621-cc34-4908-9df1-92623417bc15	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	ce60564c-7257-4134-ab7c-725150da593e	f359d07d-86f2-4407-97f5-410e97077c63	Regata Tule Celeste - Marrom Charuto (P)	1	129.90	129.90	\N
0e08138e-ecff-4997-876f-779648192b2f	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	4fe6ebd8-4172-4b00-a7fd-b056179e8257	f53ad8d6-40a8-4be6-ae8f-40b85b552499	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID - C0515 - ROXO AMETISTA (P)	1	189.90	189.90	\N
d8199717-b53e-46ec-a815-e0f420f39fb4	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	484e09bc-a947-442b-928c-bd89a7e0c5cb	cbcd20e1-a8dc-4301-bf43-ce82920947ac	LEGGING FUSÔ BICOLOR VIVID - C0515 - ROXO AMETISTA (M)	1	299.90	299.90	\N
428062d3-73fa-4d48-acf7-6509a796b893	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	133ceda7-5f0f-40c2-a994-cff417dc9e2b	f6437406-e0bb-41ac-896a-b983895a9dd5	TOP MÉDIA SUSTENTAÇÃO GLOW - C0001 - BRANCO (P)	1	189.90	189.90	\N
118e56d5-22d6-465d-a96b-56c4c8016a65	14feb63e-54b5-41ef-9274-0908b7eb4cab	21f63dde-aa95-4131-ab22-e8726166ce0d	9b45278d-6622-4671-96a1-de2e623d9528	Top Mescla Ground - CINZA  (M)	1	128.92	128.92	\N
b5dee0a1-2366-4bd9-aa4a-262e12d97c56	14feb63e-54b5-41ef-9274-0908b7eb4cab	a592bf06-b2ab-486c-8373-545c90dc2ff0	67155dd7-287a-4613-ac1e-722555f7926a	Short Cinza CasualRun - Cinza (G)	1	167.41	167.41	\N
7a6841d2-22ee-4469-a048-a0692c9b74db	a1f31cad-6062-4ebc-8598-16ae90f366d3	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	c2a2519c-7e88-45cf-939f-b89d091cf0e4	Blusa Tule Básica - Branco (P)	1	139.90	139.90	\N
0d8544ef-00ce-4fa7-94b5-adedd681076a	a1f31cad-6062-4ebc-8598-16ae90f366d3	ca957b05-f901-457a-bb3f-4d2f51560b34	38d1e418-8821-41eb-8d73-9ad2b2bab5d3	COLETE BRAVO - PRETO (M)	1	199.90	199.90	\N
eff3ee15-592f-4598-8a85-a0facf92bbfc	15f3a142-3361-4841-8ed5-9f51f2323815	fb0297cc-dc85-4d25-8294-28a449672fc9	caaf5418-8dc6-4ffe-8d4c-7e9d03b05358	T-SHIRT ETERNA GOLA V AZUL BLUEBERRY - AZUL BLUEBERRY (P)	1	160.00	160.00	\N
294fffd9-dffd-472f-96e4-989b8d44399c	6d07bd7d-573b-443f-8edc-5972e052b948	1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114	9d0f212f-ff06-4d5c-96af-b09257df07f0	Top Fitness Veloz - Roxo Deluxe (GG)	1	179.90	179.90	\N
46b432ed-af54-4483-ad7c-25f292b93f89	6d07bd7d-573b-443f-8edc-5972e052b948	e2276700-5553-4a39-bda7-53118e24cade	33292a24-e0c6-4db2-8115-25cfc11e9f74	Top Fitness Veloz - Azul Bic (GG)	1	179.90	179.90	\N
d3a0e0ea-54f7-4340-a5e6-50a0ea45e694	6d07bd7d-573b-443f-8edc-5972e052b948	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb	756a787a-5351-448d-939a-2a9bfc2c40d7	Bermuda Fitness Veloz - Roxo Deluxe (GG)	1	199.90	199.90	\N
271a5c44-6705-4589-a06a-71e7125f311f	6d07bd7d-573b-443f-8edc-5972e052b948	3d634e9c-b236-49f3-9d74-19a6a21bc730	62a0206a-2831-4b0f-b3db-1ea4ad2dd27f	Bermuda Fitness Veloz - Azul Bic (GG)	1	199.90	199.90	\N
2ef8e454-7097-416e-a2df-4a7206ec63ce	78887ce5-2c9b-4ee5-8945-39805bfa5206	0d3caf74-bd91-49de-aaf0-35021ed180d3	d85a965b-7c31-47fb-8d6d-767108e13ccb	COLETE DRY FIT INTENSE - Preto (P)	1	199.90	199.90	\N
4813b30b-5834-4320-befe-22261fd10b7c	78887ce5-2c9b-4ee5-8945-39805bfa5206	1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114	b150bf0b-2919-4c86-8d6f-c505316af8df	Top Fitness Veloz - Roxo Deluxe (P)	1	179.90	179.90	\N
7128f90b-cc8a-4031-a8c8-ccdc525941e0	78887ce5-2c9b-4ee5-8945-39805bfa5206	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb	b60c491a-d0e5-4e3a-b337-a0799d5fc7bc	Bermuda Fitness Veloz - Roxo Deluxe (P)	1	199.90	199.90	\N
18ea40d4-6fc5-4886-932b-b21b52da7420	78887ce5-2c9b-4ee5-8945-39805bfa5206	ce9a4cf1-d4e1-4699-b547-373ab022c6c6	ed2e601e-dc29-4faa-9e56-ccb6f1d53193	SHORTS SOBREPOSTO COS DE ELASTICO PRETO - ELASTICO PRETO (M)	1	320.00	320.00	\N
fdda479e-94f3-4c47-9bc4-7530fb52c7a3	46bb9fa7-449f-408b-9ea1-d9ba76fd045b	3ac1ddca-642d-4e59-be7f-6db747165549	7ba17a00-a4a1-408d-b828-9d4bf89a3d37	BLUSA MANGA CURTA DRY FIT ZADAR - C0001 - BRANCO (P)	1	159.90	159.90	\N
8834535a-f0bd-43ef-b44b-07bb94e77c48	e0461218-e0fc-420d-96c4-3ba16e63add3	8a12b1fa-aeac-4389-aa75-4258b198ceb6	22b8f81c-ba7e-4417-926d-21af31020659	Macaquinho Anticelulite - Marrom (M)	1	310.00	310.00	\N
671b8b70-8f05-442c-bcc0-0147dfa0f929	e0461218-e0fc-420d-96c4-3ba16e63add3	ce60564c-7257-4134-ab7c-725150da593e	f359d07d-86f2-4407-97f5-410e97077c63	Regata Tule Celeste - Marrom Charuto (P)	1	129.90	129.90	\N
890e815a-5748-46c3-8cd2-3616010b5e4b	15614157-7336-4210-99f9-9cbf371e4a11	cec93d51-6aeb-484f-a139-cac515ba14c9	90ae99a0-29cd-4044-9ea1-880fd4adf77f	BOMBER TEBAS - Branco (G)	1	249.90	249.90	\N
3956ca85-f9e5-44f3-af50-24069df1e624	94e02f85-247a-4dde-8fe5-4e3380b3a1f4	d62c33d5-ff0e-4a95-be05-d1ed90c8f5cd	cfba89ef-a357-4874-bf2f-709830ef2db2	Top Nadador Com Bolso - Marrom (M)	1	280.00	280.00	\N
a903f6b3-7e41-451a-aca7-71a08b944223	94e02f85-247a-4dde-8fe5-4e3380b3a1f4	4f61e39d-59f6-4273-8804-94a48c7e068a	ea89669b-68dd-46b0-9d1c-1d72bc562b85	Blusa Tule Básica - Preto (M)	1	139.90	139.90	\N
e040535d-d212-41ff-874e-b3aeacfecf4f	94e02f85-247a-4dde-8fe5-4e3380b3a1f4	e78ea427-c4f8-4611-a943-ad1488bf5756	a6995d3b-d1b0-4c17-9c45-782fa9440f3c	Legging Com Bolsos Laterais - Marrom (M)	1	380.00	380.00	\N
8f14ba9c-02d9-4cd2-8021-15dcebd897a8	aac20eed-6110-46b6-9a1e-fe4a81cbef07	313449c2-742e-466c-9229-5a66c4105768	7dd672b3-f2b2-4a49-a6e5-e8af18e51c0f	T-shirt Cropped Elastico Personalizado - Vinho (M)	1	218.90	218.90	\N
c0295838-121d-4198-b1c4-24fcbd179462	aac20eed-6110-46b6-9a1e-fe4a81cbef07	c215f201-699a-4fe2-a842-7fea0c782a32	37fef6d8-3d7b-4527-90ef-9cb23cd6ec60	Bermuda Elastico Personalizado - Laranja (M)	1	280.00	280.00	\N
8bf08762-585d-4ed1-97ce-daca50c701e4	aac20eed-6110-46b6-9a1e-fe4a81cbef07	8903dc04-754f-4653-8c72-c9fefdf35a8c	9251bb6f-78b5-4bae-8edd-65b40b52fe7e	Legging Elastico Personalizado - Vinho (M)	1	320.00	320.00	\N
f6f80560-436e-4423-9c25-351e6af69797	aac20eed-6110-46b6-9a1e-fe4a81cbef07	afd5f46a-ecd0-46b9-9d4d-85fc13bafb44	09879099-71be-4d0f-b135-40502412bf32	Top Nadador Elastico Personalizado - Vinho (M)	1	235.00	235.00	\N
c0b89061-1667-46c0-a880-533aefe2dcce	4cb77150-9c30-42bf-962b-657dafcd0c15	d35665ce-46f4-4b59-a491-eb22731c6422	74cb2d97-31f0-4ffe-b0b7-843e7a1027f2	JAQUETA CORTA VENTO MOVEMENT - Branco (P)	1	289.90	289.90	\N
80c82946-503e-4ef4-a7b6-b57688e320bc	a0d80b27-f650-4618-84d9-b06369488431	d6f3a94c-f481-4ce2-a8ac-5bc0cf146b72	45274db3-9498-498e-8677-a55eae545d3f	LEGGING SUSTENTACAO RECORTES TULE PRETO - TULE PRETO (G)	1	380.00	380.00	\N
c91d1d0c-216b-49ac-a0be-d66969cb448e	8534b434-f91e-4942-90c9-30909f036ed3	d90fc150-1d5a-4f27-988d-009d35eb6208	5a315735-4c8e-48d0-9e28-795491ffcb1c	BLUSA MANGA CURTA DRY FIT ZADAR - C0002 - PRETO (M)	1	159.90	159.90	\N
735db4a7-879a-40e1-b4c9-0a9e17c0f2c8	8534b434-f91e-4942-90c9-30909f036ed3	e7a1f608-edb7-45e8-8a90-424636a6aee7	bc83dd95-a582-4bde-a0f3-53e6295bc385	BLUSA MANGA CURTA DRY FIT JANICE - C0279 - LILAS LAVANDA (M)	1	129.90	129.90	\N
a0b48260-c66e-4803-a420-cf38b1a32efc	f1a029fc-60c5-4f80-868c-bc17a62963ba	3461894e-b04c-4295-8c83-17ee8bcac3f7	0bb72f89-aa0d-4329-af2f-155b1a47b0e3	JAQUETA CULTIVO - OFF WHITE (M)	1	249.90	249.90	\N
e57740ab-6741-434f-aee4-73f3a82db2a1	c6db1718-62cf-48ef-a9a5-f5870431d1ee	36d81da0-e329-4843-8d92-f91d82256467	072524df-8db6-4b87-a9de-b2b6687eedd7	TOP MÉDIA SUSTENTAÇÃO BLISS - C0257 - AZUL JEANS (P)	1	189.90	189.90	\N
2fe51b82-7efd-4df7-ad01-4e220ca71f77	c6db1718-62cf-48ef-a9a5-f5870431d1ee	23fb179e-1177-4a97-961b-35b11922582f	50fd6f77-8dde-4ce9-af85-bcd6b812c6e5	TOP MÉDIA SUSTENTAÇÃO FLOW - C0280 - VERDE MENTA (M)	1	108.00	108.00	\N
11484626-e612-4aba-b7e4-ea89a81483b3	c6db1718-62cf-48ef-a9a5-f5870431d1ee	395d35c2-9a98-4deb-a529-575292209199	3a1a092c-a046-4599-90e1-ad6d3ea17727	LEGGING FUSO SEAMLESS ELIS - C0280 - VERDE MENTA (M)	1	209.90	209.90	\N
d496979c-1a32-499a-a546-0d834dbeaceb	45f0a747-a320-4429-b960-709b4666e22c	bdb8a6de-0cf6-41d9-8acd-244113c3bf13	f59734be-2b4a-48cc-a4d5-bdfa168e64d7	Regata Mellow EveryMatch - Amarelo (M)	1	132.33	132.33	\N
7573391f-ed1d-44fa-8e7a-b604a49ec21d	45f0a747-a320-4429-b960-709b4666e22c	3131bb7b-5f21-4483-a4fd-e6a5242faff6	3cdc999c-529c-4f05-8364-b6d04ae2246c	Short Saia Mellow EveryMatch - Amarelo (M)	1	225.99	225.99	\N
ea7ec344-8623-4f54-bdd8-fb21786638e5	45f0a747-a320-4429-b960-709b4666e22c	4f7973c8-04fb-4671-8819-74aa2dee4038	62d1825e-cea5-44d0-8f3f-f519bf7c0d7e	TOP ELASTICO PERSONALIZADO ALTO GIRO PRETO - GIRO PRETO (P)	1	200.00	200.00	\N
7ff8e054-37b9-40ba-8fbd-9f5487029c21	6c1b5939-0e32-4737-89af-6344c1f9b24f	3fd3798e-d793-4754-ab1c-a5566edc77e3	f53d25ca-bd3e-4659-9664-5c7c550688de	Short Isis - Preto (M)	1	199.90	199.90	\N
8016e0c0-7f55-45ee-83b4-5e55e981f688	6c1b5939-0e32-4737-89af-6344c1f9b24f	6b088322-81c6-4e64-af59-76b9ab62f027	d1c8971a-4ae6-4bb7-883c-2716c9d7e189	Top Média Sustentação Isis - Preto (M)	1	179.90	179.90	\N
db938bb0-e857-4568-821b-441252dc147e	41ee7f32-7015-4352-bcb1-a869faf314fd	c3fef1a0-bd1e-48ab-b87e-260e3140dad9	712f8f32-1cb2-4727-9295-118168ab11bc	Colete Bravo  - Azul Bic (M)	1	199.90	199.90	\N
169b8160-a4ef-45d2-8c9e-f65271e9f408	41ee7f32-7015-4352-bcb1-a869faf314fd	bf3fe2fa-8837-49de-aadd-27b863410a0c	902c7366-0852-4dc7-b4d3-106099549ed8	Colete Bravo  - Rosa Frutilly (M)	1	199.90	199.90	\N
80f2b0f9-9fa2-4ff1-8036-887a89c669cc	bf87a8b8-08fc-4399-9c10-93390b92977b	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	c2a2519c-7e88-45cf-939f-b89d091cf0e4	Blusa Tule Básica - Branco (P)	1	139.90	139.90	\N
e43fdd39-d3f6-446e-8199-cbc508c36ad1	bf87a8b8-08fc-4399-9c10-93390b92977b	b6c34d57-c96f-42c2-8af7-2fa01667273f	58678fd8-50a7-4b71-96ee-c7925eecefc2	Blusa Tule Básica - Azul Bic (P)	1	139.90	139.90	\N
6d94936b-8b38-468a-83f4-09d312d26835	fa318a38-f899-4179-9f8e-672fddac185d	c63e0319-a5ae-463e-9b82-b98bb96a604d	05633d1a-5089-4f69-a747-c1c7f62e1fe1	COLETE CRISTALE - UVA ROSE (M)	1	319.00	319.00	\N
30058096-9c45-49a1-8cdd-a998edceeff4	fa318a38-f899-4179-9f8e-672fddac185d	628d2222-2c97-4bae-bb3d-8dc41a48f187	39643bff-b61d-475f-8eba-8049c1b4ad6e	MACAQUINHO COCOA - Marrom (G)	1	259.57	259.57	\N
5416f5e9-6a96-4eeb-ac8e-66beab88d8bd	ac6246c5-9ab3-4e5b-a2c8-1df457a148ed	e60e28a2-3d2f-4105-8a7c-a0dd5749fc35	04502a26-7009-4684-a278-517756284c2a	Short Fitness Street Bolso - Vermelho Classic (G)	1	239.90	239.90	\N
de61243b-a634-41d1-8a80-2d12fc2dc75a	ac6246c5-9ab3-4e5b-a2c8-1df457a148ed	598d5623-0507-4a89-b3a4-987c1cae56af	3503f869-7775-489d-ab0d-e2520bf27695	Top Fitness Summer Liso - Vermelho Classic (G)	1	169.90	169.90	\N
c6636753-8188-4693-a43d-61c97ac618ce	ac6246c5-9ab3-4e5b-a2c8-1df457a148ed	fac47062-4296-46a9-845f-ae567089a3f9	5597afe8-d4ca-47db-adf7-03cb3166b2a5	Regata Tule Celeste - Branco (G)	1	129.90	129.90	\N
df01cedb-c343-40ae-823e-b25e3505536a	b53f59e6-8f32-4554-80db-5b2e7ff60841	c0ec0db7-f802-4337-a426-5224eefa3342	fded3b4c-8d0b-4955-8eab-3b45edc2ef4a	Top Fitness Nanny - Branco (M)	1	209.00	209.00	\N
ab31a4fb-11bf-4d54-8755-add5f949a81a	08cff621-3183-45f3-876c-d3e7f04fff90	e8f954b3-9c64-4ef2-b505-652fbedecdd1	6085f571-06c6-44ee-b194-d1748e745dbc	Bermuda Fitness Veloz - Preto (GG)	1	199.90	199.90	\N
9cd017ae-d5ff-4c81-b570-5a60279be2f6	313756d4-156d-447e-be65-23f74b6034e5	fe2f9328-af80-4d72-aa25-8ed6a2430cb4	3781ca49-be72-43b3-94f1-cb34e90aa8c1	Top Fitness Nanny - Verde Neon (M)	1	209.00	209.00	\N
5fb8e7cd-ddf3-4679-9f05-0737a740300a	7ce6ce23-ca2e-4bc2-9569-6256979be0cb	fe2f9328-af80-4d72-aa25-8ed6a2430cb4	63d9061c-7423-4b08-87f6-df2ceeff8bda	Top Fitness Nanny - Verde Neon (P)	1	209.00	209.00	\N
33a2b9e6-30b3-4db5-b1d2-129cc4e3180d	99252fc8-5b21-4d74-8d42-8ae7ed615c5b	c3fef1a0-bd1e-48ab-b87e-260e3140dad9	712f8f32-1cb2-4727-9295-118168ab11bc	Colete Bravo  - Azul Bic (M)	1	199.90	199.90	\N
6d9d248a-5e0f-439e-b8c7-11d6bdf117ef	bd43127b-736e-4833-808d-fd71ce103c1d	78fcd02f-ea2b-4665-9eb5-e29d71b525ec	879d026b-88e2-4eab-b854-1f8f30c0d31f	Short Running Lyra - Preto (M)	1	319.90	319.90	\N
74af057d-dbda-454b-8795-2c3d3475d80e	bd43127b-736e-4833-808d-fd71ce103c1d	0d3caf74-bd91-49de-aaf0-35021ed180d3	f86c9dad-6bcd-49cd-a9b5-9f9b7ca92d05	COLETE DRY FIT INTENSE - Preto (M)	1	199.90	199.90	\N
3029fe5d-b2d5-47ea-8d3b-424a0cdb1e82	19b419d7-f1f7-4764-b375-b2cbda99704e	ddfc3385-ddc8-4ade-bac2-7bdc6fbfa9a5	7800beee-c9eb-4c0d-b1e3-ff676a126bf4	COLETE BRAVO - BRANCO (G)	1	199.90	199.90	\N
59e73c04-06cf-466e-96a4-0797018b8f89	19b419d7-f1f7-4764-b375-b2cbda99704e	ef55c198-d3c5-41ce-afcb-a329e0f8865f	e510b82f-794f-4fc5-8b0d-694eda59843e	Top Média Sustentação Isis - Branco (M)	1	179.90	179.90	\N
b1d338d1-d108-4fd8-9860-0c1fffdc75f3	19b419d7-f1f7-4764-b375-b2cbda99704e	ec60a756-d6ac-42ae-a91a-819307d66c1d	08ae5032-4938-446d-8b6e-52561e3e12e0	Legging Isis - Branco (M)	1	299.90	299.90	\N
d8423f98-d2e2-42b5-b2c9-469824e1944d	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	1123a71a-461e-41a2-994b-c4921c097aa4	c317a62e-000d-47e1-b71a-2f448b30eab1	Top Fitness Veloz - Preto (GG)	1	179.90	179.90	\N
6efadabd-db68-48dc-8c9a-11af4dd554af	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	b550dd7b-3d20-4049-88ec-0b09875a58b1	13ca4db3-1d57-4500-8e74-3d49bef1cc4d	TOP CROPPED SENSE - CREME (P)	1	179.90	179.90	\N
90f9ebf0-5806-44ab-aab5-7b72376f1b90	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	4b80ba74-7234-4662-b19d-5e730e7f9571	6cee7333-fc39-4a75-81e1-851a51c098e8	BERMUDA 5 PRO PRETO - PRO PRETO (P)	1	340.00	340.00	\N
d9a14e60-41c3-4481-b1c9-09d331bfce87	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	d2736922-2464-450c-9772-f5dfc945b560	e849fac1-9c5c-416e-aed3-763e913250b4	Regata Ampla Sobreposicao - Azul Marinho (M)	1	218.00	218.00	\N
9521f40e-aad4-47c5-ac96-126fc22df3e9	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	e404c7b0-4099-43e3-b305-c855fd4b734d	3dcf3c81-86fd-4b43-b9ad-2205f3817720	Top Elastico Personalizado Alto Giro - Preto (P)	1	205.00	205.00	\N
41560684-9469-45ad-b15b-148e0e33743f	ef139de1-d72f-4316-967d-bf1517e4a06f	c0ec0db7-f802-4337-a426-5224eefa3342	b668891d-e25c-4973-969c-983a05e82cc7	Top Fitness Nanny - Branco (G)	1	209.00	209.00	\N
33fb52ea-9925-47c6-b571-4e98826e4ee5	ef139de1-d72f-4316-967d-bf1517e4a06f	7c051d7b-cdf7-4a19-aa50-9a0f6e308655	7202baaa-c299-4a3d-b1eb-46809d27d4ac	Top Fitness Nanny - Lilás (G)	1	209.00	209.00	\N
755bdf7a-eb8e-4f95-b404-848075e45fd6	023b9f31-a3c3-404f-938e-58215f18b3a4	4bbc099b-fc0c-48a9-a621-8674934824b5	82f451e3-0540-4f29-9d3b-f75ea3e812b7	Short Helena - Marrom Sepia (M)	1	199.90	199.90	\N
9cdcca27-5231-474c-988d-7f0193a10b61	023b9f31-a3c3-404f-938e-58215f18b3a4	f58a6e05-302a-4ae7-9754-7eba7b2ab797	ab64c416-9b6f-4240-b5b1-cad033696e37	Top Alta Sustentação Helena - Marrom Sepia (M)	1	199.90	199.90	\N
5602eeff-e325-4134-b426-878d48035a46	023b9f31-a3c3-404f-938e-58215f18b3a4	0d3caf74-bd91-49de-aaf0-35021ed180d3	d85a965b-7c31-47fb-8d6d-767108e13ccb	COLETE DRY FIT INTENSE - Preto (P)	1	199.90	199.90	\N
38a0ec60-79a7-45d1-8ffc-32cfe5b6726a	023b9f31-a3c3-404f-938e-58215f18b3a4	f9ecc97f-22e3-4b87-abb6-f1ff65cd95be	ec9efcf6-3129-432b-963c-b448af1a9412	Short Areia Everylift - Creme (M)	1	183.52	183.52	\N
ee68b4fc-153d-4cf8-841b-fec88703f4db	023b9f31-a3c3-404f-938e-58215f18b3a4	75ed12b3-85f8-4292-8d72-aee071febf28	7ce6f7d2-1017-44c1-8193-8adf447cdcb4	Top Cocoa Everylift - Marrom (M)	1	157.89	157.89	\N
3c3dcd87-8ccf-4de5-8771-e979ec5594c3	09069f38-1e9a-4440-adf7-516ce9758547	f6c11475-b890-40e4-90d7-bd6a63a7af3b	c54dd10d-2c90-4b3a-859b-8f867ed33336	BERMUDA ALTO GIRO SPORT MARROM NOBRE -  MARROM NOBRE (M)	1	240.00	240.00	\N
dea40489-ad74-4bb0-80a2-91bbb7ede2ff	09069f38-1e9a-4440-adf7-516ce9758547	498a47fd-de22-4035-ad7a-00e679abeba4	ad8c7e30-f86e-4b38-8c54-0f3e47a32dc0	BERMUDA ALTO GIRO SPORT VERDE ESCURO - VERDE ESCURO  (M)	1	240.00	240.00	\N
bbf79513-a460-4ff5-836b-c45e711e1054	09069f38-1e9a-4440-adf7-516ce9758547	bfba079a-f6ab-4577-8619-53f3ba184a4a	f43c1c8b-3be5-427d-b00b-70b0ef124965	Short Mescla Ground - Cinza (M)	1	147.14	147.14	\N
a1221fe8-f971-42a3-a85d-0dbbbc18339d	09069f38-1e9a-4440-adf7-516ce9758547	3d294cbf-70af-48ee-a64b-3128fa402808	3ebf2e00-bcbf-49ee-b558-3d13214c38e1	Top Mescla SoftLine - Cinza (M)	1	155.10	155.10	\N
2b5d2b36-391d-4b71-9c18-5a541e207e07	ed7eeb3c-f871-4c6e-aa43-488a64d93e1a	65a7f4a2-7044-4aa5-a817-81f7cdfe34fb	797d56ac-16a4-4bb6-b95a-d7639fe001c7	Bermuda Fitness Veloz - Roxo Deluxe (M)	1	199.90	199.90	\N
77d3ac63-3c95-411d-bc26-289c013cef6d	390b45e6-b74a-48c2-811c-d582b1907a1c	fe2f9328-af80-4d72-aa25-8ed6a2430cb4	3781ca49-be72-43b3-94f1-cb34e90aa8c1	Top Fitness Nanny - Verde Neon (M)	1	209.00	209.00	\N
c2bc3a64-8218-4eff-bbb5-6a9e630727f7	390b45e6-b74a-48c2-811c-d582b1907a1c	9a55dd2b-b128-425f-9a60-4661635c2a14	8c73a143-e818-4fba-8542-ea4f43338508	Top Fitness Nanny - Rosa Fúcsia (M)	1	209.00	209.00	\N
4e7fd70d-1f8a-4e66-82e5-840bfbd121bd	390b45e6-b74a-48c2-811c-d582b1907a1c	15f7fd5b-846c-498e-8c6d-dbca6ed3f5d7	dfbb901d-87ff-4716-9dc4-d7f9bae63692	Calça Legging Montana - Preto (M)	1	269.90	269.90	\N
8defd3d0-c896-4064-8528-bf570cb32e47	390b45e6-b74a-48c2-811c-d582b1907a1c	41d2c32d-5cb2-49cc-8ba0-e2151436b298	e5797329-3609-49ea-bdc1-aea4dd02be25	Bermuda Fitness Montana - Preto (M)	1	209.00	209.00	\N
bc107bcf-8444-4add-a7fd-46a127bccfc0	83b28183-0eed-4fa9-a132-e5102c239527	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3	f443b4bc-1db5-42e3-b8e3-9ea929da2cc6	Regata Tule Celeste - Preto (M)	1	129.90	129.90	\N
c12e25b3-aaac-4331-a0a5-869784fc91d3	b5890cc9-86c0-40e9-9d56-fc079223159b	bf3fe2fa-8837-49de-aadd-27b863410a0c	626c784b-554f-4355-8a86-48c2f0a3aab9	Colete Bravo  - Rosa Frutilly (P)	1	199.90	199.90	\N
57f13ee7-9504-4d10-8c86-2d43a9de3af0	b5890cc9-86c0-40e9-9d56-fc079223159b	1123a71a-461e-41a2-994b-c4921c097aa4	65695057-c525-4568-8c4e-fe82ddde32f6	Top Fitness Veloz - Preto (G)	1	179.90	179.90	\N
584e3971-1b56-4d67-9a02-53cb35570d32	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	0d3caf74-bd91-49de-aaf0-35021ed180d3	dbe4c0cf-48a8-4b4b-aaf9-0139801f9d59	COLETE DRY FIT INTENSE - Preto (G)	1	199.90	199.90	\N
fd59548e-952a-40f1-8844-49f6eb435694	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960	94106ece-16c4-420a-b4c5-f3ec7a55cf93	Legging Isis - Preto (G)	1	299.90	299.90	\N
2f63e8ba-1d90-4b09-9f2b-28e4f91f5f39	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	6b088322-81c6-4e64-af59-76b9ab62f027	feff9013-4090-40a0-9c17-c11233b92483	Top Média Sustentação Isis - Preto (G)	1	179.90	179.90	\N
c41bae31-f89f-4735-a4cd-9d20ea491df6	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	e2276700-5553-4a39-bda7-53118e24cade	4bd1e60d-e5e7-480c-99a3-6b71b556aecb	Top Fitness Veloz - Azul Bic (M)	1	179.90	179.90	\N
e0d452ae-c98b-4c9f-84b9-aedf2479c240	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	1123a71a-461e-41a2-994b-c4921c097aa4	df14407b-0ad0-492e-800c-7a2652f6abc4	Top Fitness Veloz - Preto (M)	1	179.90	179.90	\N
e207df29-d13c-49ff-bc06-9a6f2320d5ce	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	28be9554-3198-41e3-8d90-8bc13d4df232	c2d79261-4799-48b5-97e8-ef8ec006f165	Legging Elastico Personalizado Alto Giro - Preto (M)	1	320.00	320.00	\N
7b30f50f-c3cb-48e1-8418-eb898ad3b22f	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	c3fef1a0-bd1e-48ab-b87e-260e3140dad9	380b2f88-2b83-472f-aad5-d4c34079b6ea	Colete Bravo  - Azul Bic (G)	1	199.90	199.90	\N
e047a3d2-5abc-453d-bf5a-2cb195179817	3f29919a-5012-4fd9-80f9-89521f5d041d	3d634e9c-b236-49f3-9d74-19a6a21bc730	12ed8c8b-4e30-43c7-9d25-5aa05afacde1	Bermuda Fitness Veloz - Azul Bic (G)	1	199.90	199.90	\N
5d7733c0-57bb-469f-96f0-bdd5ba002896	3f29919a-5012-4fd9-80f9-89521f5d041d	e2276700-5553-4a39-bda7-53118e24cade	aa290e2d-8848-4d0d-bf4e-3db7a5994bf4	Top Fitness Veloz - Azul Bic (G)	1	179.90	179.90	\N
1d9ba7a6-9ce2-41a0-be2d-3217d7ce441a	3b91814b-8a9b-413a-a8ee-66a712f6613d	ec60a756-d6ac-42ae-a91a-819307d66c1d	49526e07-92dd-4fae-a9b1-5c0618831120	Legging Isis - Branco (P)	1	299.90	299.90	\N
4acfc5b6-74e3-4a44-a7f0-881d88de25bc	3b91814b-8a9b-413a-a8ee-66a712f6613d	ef55c198-d3c5-41ce-afcb-a329e0f8865f	eca61b47-c6b0-442c-8e24-77b868e20051	Top Média Sustentação Isis - Branco (P)	1	179.90	179.90	\N
c4af59bd-bae5-4d8b-a641-fd221650188f	b2db3b18-16a8-4696-863b-0c870c31b040	7eaeb75b-ea96-45fc-98fd-b6cd7063aee8	7b12243b-5204-43db-b9cd-50f777b2917a	BLUSA MANGA CURTA DRY FIT JANICE - C0243 - ROSA ROMANCE (M)	1	129.90	129.90	\N
70f13bd7-4adf-4eac-9b5b-9de5b475814a	5aebee91-b1f7-4309-92fe-111743a716c8	ff195db1-072f-4d00-b808-4fceeb13362a	e3ad9ba7-3a9a-42c8-a871-582c6fcd2249	T-SHIRT ETERNA GOLA V VERDE BRISA - VERDE BRISA (M)	1	160.00	160.00	\N
42c178b6-c037-4299-bd1b-9233e9591a6e	5aebee91-b1f7-4309-92fe-111743a716c8	c74b9db9-716a-46ba-b5a4-11b3983ae74d	eca6363c-e468-4972-b7ad-35d6bde76c58	T-SHIRT ETERNA GOLA V VERMELHO VIBRANTE - VERMELHO VIBRANTE (M)	1	160.00	160.00	\N
d62ddc44-a382-41d5-abe4-7e6aee6e9e7f	719e410d-7728-48d8-a3f9-f7473ad72efd	97fba60a-fae3-497d-bd3a-081ba65a7d11	1f891cf5-f1a8-43be-8e67-f683a6852e84	TOP ELASTICO COSTAS NADADOR BRANCO OPTICO - BRANCO OPTICO (M)	1	240.00	240.00	\N
b243411f-a654-419f-b388-86b23ee18f22	3310eb3d-0a5c-4516-a8da-ddb1122c7567	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960	6091f153-ad27-42f5-a875-711230265eb1	Legging Isis - Preto (M)	1	299.90	299.90	\N
fc7c9a0c-5c7b-47bd-86e5-390fdb23ecc6	3310eb3d-0a5c-4516-a8da-ddb1122c7567	6b088322-81c6-4e64-af59-76b9ab62f027	d1c8971a-4ae6-4bb7-883c-2716c9d7e189	Top Média Sustentação Isis - Preto (M)	1	179.90	179.90	\N
ac9f3aa4-3979-40e1-9daa-ccb63540c9b4	3310eb3d-0a5c-4516-a8da-ddb1122c7567	a88f20ac-2cdd-448f-8ecc-83301fd91232	516a0ba3-6cb1-4fc3-8322-98b07b6819a5	MACACAO DUBLIN - C0002 - PRETO (M)	1	419.00	419.00	\N
6bfc6e2c-4b1e-466c-9662-bf3249e16587	7676aaca-25c7-4e74-9051-45e42fedc114	88964da7-b084-44c7-9231-43645c98ebf2	79d886de-3112-4bd7-b1fa-ad5c4364055c	Legging Helena - Preto (M)	1	299.90	299.90	\N
5dc4142e-f20d-4e73-a621-d8e7ba58f22c	7676aaca-25c7-4e74-9051-45e42fedc114	0f2f9bb8-5eaf-46de-b5e5-b1455ccb8321	b16e39a3-82a6-45d9-afae-8accc75a3dde	Top Alta Sustentação Helena - Preto (M)	1	199.90	199.90	\N
4b9234d3-f05c-4501-88cd-dc70064f17eb	1970c736-adbe-45a5-82f9-f744633a36ee	8d43f80f-32fc-4b5f-9ba5-feee72d699b3	167d3dbb-495f-4b62-a83c-22d1e6ddf5f9	Top Cocoa Everymove - Marrom (P)	1	153.64	153.64	\N
8a8f7e34-c4aa-4024-b4d4-4c2de77612d1	1970c736-adbe-45a5-82f9-f744633a36ee	c13c6bb2-b261-4906-aa83-2fc815cbcf33	1f74393d-5bc7-4538-838c-3c6b7d61ff51	Calça Legging Cocoa Everymove - Marrom (P)	1	223.61	223.61	\N
a8d24445-b611-4cb0-98d7-83a84789e285	1970c736-adbe-45a5-82f9-f744633a36ee	133ceda7-5f0f-40c2-a994-cff417dc9e2b	2fa2d11c-cae3-4f8a-a4b9-28be3cb303c1	TOP MÉDIA SUSTENTAÇÃO GLOW - C0001 - BRANCO (M)	1	189.90	189.90	\N
2a2f7e2c-37a0-4397-9bfd-89dbae876ff0	fda15600-10c7-45bc-b08a-df44caab1a97	4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960	5c07ec4d-549a-47cc-883d-27c6bbd0b8f3	Legging Isis - Preto (P)	1	299.90	299.90	\N
3521f962-8038-48ce-ae9d-11d137085057	fda15600-10c7-45bc-b08a-df44caab1a97	6b088322-81c6-4e64-af59-76b9ab62f027	65b0b5a4-a600-4ac8-8db6-de5ed0698c7b	Top Média Sustentação Isis - Preto (P)	1	179.90	179.90	\N
32f471f2-c82e-4816-bb91-b9fa928e9683	228867b0-244e-44d9-a65f-9c0af5bdc2f4	c9bf8fab-7dc3-4f86-8ede-4f0a1d34c466	356f1c2f-4d66-41af-bef2-75fb9c204e9e	Colete Lyra - Preto (M)	1	339.90	339.90	\N
da989814-d382-4f99-963e-ba7574ae9615	228867b0-244e-44d9-a65f-9c0af5bdc2f4	78fcd02f-ea2b-4665-9eb5-e29d71b525ec	879d026b-88e2-4eab-b854-1f8f30c0d31f	Short Running Lyra - Preto (M)	1	319.90	319.90	\N
725ddb33-0a88-4f06-aed6-a48aa98abf5c	c3878d85-0946-43fc-ac2b-b4e596d5b2a6	66ff3218-0f96-4717-8e6a-967d40e6b736	b86ae314-9302-43fa-ab52-071bb05b6575	JAQUETA CORTA VENTO MOVEMENT - Preto (P)	1	289.90	289.90	\N
c58c7019-81fb-4c2a-8789-03a6d5b03bb5	1882538b-8b9b-424e-a1f7-ecb2c099209c	17651cc2-5ea4-4d8b-9a28-d829bcfa1abe	2859c8ae-dbe1-479a-9f06-d0eb0a67744c	LEGGING FUSÔ COM BOLSOS MOVEMENT - C0575 - VERMELHO GRENADINE (G)	1	329.90	329.90	\N
32788688-42af-4abf-8229-6b50fddad650	1882538b-8b9b-424e-a1f7-ecb2c099209c	97e44051-9e10-45e5-a711-72817bb30a3b	5a349db8-db46-414b-ad07-656de44b89c0	TOP MÉDIA SUSTENTAÇÃO MOVEMENT - C0575 - VERMELHO GRENADINE (G)	1	209.00	209.00	\N
26fadd79-2512-4ecc-a299-73a93bcf3fa7	2e744f06-0c9d-452d-8c90-8806905bd4e0	d1cef6b1-1344-414a-a7dc-f871f502c42a	eaa14fa9-058d-4077-892a-f93ad34d19c2	SHORT BOXER SENSE - CREME (M)	1	199.90	199.90	\N
bea7c502-7d06-41e6-90cf-78f8f67ee280	2e744f06-0c9d-452d-8c90-8806905bd4e0	b550dd7b-3d20-4049-88ec-0b09875a58b1	5af797e2-95a7-4d36-a552-9fe7ba6e5d2a	TOP CROPPED SENSE - CREME (M)	1	179.90	179.90	\N
b5795b21-a35c-44e2-a9b9-29482564f398	2e744f06-0c9d-452d-8c90-8806905bd4e0	8fa37df0-d45e-4e32-a938-707801477ad0	5988b96a-b0c7-4d01-a46b-810d613d3e42	TOP CROPPED SENSE - AZUL NEBLINA (M)	1	179.90	179.90	\N
2772c019-7dff-41af-b00a-2c95a5f918f5	2e744f06-0c9d-452d-8c90-8806905bd4e0	67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2	301c1a09-1bcc-4eb0-85dd-a58cad70c86c	SHORT BOXER SENSE - AZUL NEBLINA (M)	1	199.90	199.90	\N
6aab1c17-8c4c-4b3b-ac1f-59d1864e19f3	2e744f06-0c9d-452d-8c90-8806905bd4e0	75fda0ae-993d-4cdb-8647-43b5dacd8e4e	b232382c-a74a-409e-8d1e-2bde60d3fe77	Shorts Degrade - Rosa (M)	1	259.90	259.90	\N
60c14e8e-6892-4b27-b278-4e32e987946f	2e744f06-0c9d-452d-8c90-8806905bd4e0	a0f12306-5fce-4173-ac98-5b6350de1863	3b1e2a97-36dc-49ac-b342-06a2878f2d11	Top Alça Cruzada nas Costas - Cinza (M)	1	219.90	219.90	\N
af99ca82-1ec9-4775-b0e8-57cdfa72d7c3	2e744f06-0c9d-452d-8c90-8806905bd4e0	271fec96-9aed-4d36-b71d-87147092ae3e	5ca68ed1-f534-479f-8701-198fc28abaae	Bermuda Detalhe Bicolor - Cinza (M)	1	279.90	279.90	\N
2ac9846d-5752-4cad-94fd-75e9b3f38cd1	2e744f06-0c9d-452d-8c90-8806905bd4e0	bff71c24-ac1a-4a4c-822c-2c1b299b343d	e27489f6-f19e-4cf9-addd-04bdd667a322	Top Alças Duplas - Azul (M)	1	199.90	199.90	\N
68b51aa7-7c32-4a0b-af1e-cbf5c9f06d75	2e744f06-0c9d-452d-8c90-8806905bd4e0	4c514054-93ff-408e-8c50-8420cf8e0e59	19a77653-561b-4050-a31e-30ba6e4d8721	TOP MÉDIA SUSTENTAÇÃO MYSTICAL - E1341.V26 - VESTEM VERDE HERA (M)	1	189.90	189.90	\N
cfd68e61-e5fc-44f4-9982-c585808ee283	2e744f06-0c9d-452d-8c90-8806905bd4e0	00a58446-4e64-4cf1-9bf8-caae7a3a1ac1	6e20f91b-b422-4709-8061-ddc2e0866a83	LEGGING FUSÔ MYSTICAL - E1341.V26 - VESTEM VERDE HERA (M)	1	249.90	249.90	\N
37bda9a9-e429-4934-8912-1f8273a43a71	2e744f06-0c9d-452d-8c90-8806905bd4e0	c0ec0db7-f802-4337-a426-5224eefa3342	fded3b4c-8d0b-4955-8eab-3b45edc2ef4a	Top Fitness Nanny - Branco (M)	1	209.00	209.00	\N
0025c57c-cc6a-4e16-b75d-234e0b1a1232	2e744f06-0c9d-452d-8c90-8806905bd4e0	d9010f7d-2788-41a1-b104-8e82bbdee1f2	172ba8be-3584-46ae-9f08-5a459a30c445	Regata Tule Celeste - Castanho (M)	1	129.90	129.90	\N
0e5688b2-7440-462d-bf62-0a2d56605506	2e744f06-0c9d-452d-8c90-8806905bd4e0	4f61e39d-59f6-4273-8804-94a48c7e068a	b9286f2a-9a47-42ef-936b-09bdfa570f06	Blusa Tule Básica - Preto (P)	1	139.90	139.90	\N
7174ebc1-9922-4bbb-a972-3b92812ac170	2e744f06-0c9d-452d-8c90-8806905bd4e0	fac47062-4296-46a9-845f-ae567089a3f9	2c8796bf-aa68-4b96-bb64-f675e8efcfc2	Regata Tule Celeste - Branco (M)	1	129.90	129.90	\N
faa63a8a-7b86-4838-8577-ca5965b0148b	2e744f06-0c9d-452d-8c90-8806905bd4e0	0fdea5e8-ce59-4581-a6dc-16be6cf0b27f	87f40fe3-89ff-4498-b1af-ed43fa26ef39	Regata Tule Celeste - Azul Bic (M)	1	129.90	129.90	\N
6716231b-08fc-4624-82b6-f80a70c4bc3b	2e744f06-0c9d-452d-8c90-8806905bd4e0	21db8fae-3c39-4e2f-ab6d-0013477c0b3b	acbca184-d861-479b-ad3f-d55f867e6377	T-Shirt Cropped Com Tule - Azul (M)	1	229.90	229.90	\N
9d9442d1-cbc6-4188-842f-0d3e13a7e79e	2e744f06-0c9d-452d-8c90-8806905bd4e0	e6481b12-5b71-48fb-8014-ac527908b6fc	f9618c33-d019-4692-a54c-9fbef5ecbea5	Regata Cropped Recorte Costas - Rosa/Marrom (M)	1	198.90	198.90	\N
a7af17d8-66ea-46bd-9f7e-99456196a0f0	28cc2232-8cfd-42d1-b38e-4a5668fdad11	0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8	fa6957ea-2a79-490d-b48d-e87ffd4ce8e2	Top Degrade - Rosa (M)	1	229.90	229.90	\N
c0bbd13e-fa76-4895-b80f-d03f48745ae7	28cc2232-8cfd-42d1-b38e-4a5668fdad11	c26f24e0-e9c3-4e19-9e79-6e4ce4ee2189	51df8698-697c-41ed-b286-eeafbd74ec31	T-Shirt Cropped Torção - Rosa (M)	1	199.90	199.90	\N
2a1f1a70-9454-4da0-b911-37be93795d36	28cc2232-8cfd-42d1-b38e-4a5668fdad11	c9f22b86-6bdb-47cd-9832-d47f617bd6bc	0d66f4a7-5370-471a-818b-b1aba224f865	Legging com Bolso e Estampa - Rosa (M)	1	329.90	329.90	\N
4acdc920-f355-4c74-a595-6f652c756e41	5d1f3636-8fef-46ca-9cd8-f60b1ecb28ab	d35665ce-46f4-4b59-a491-eb22731c6422	4b09b7be-05a2-4940-9587-815f5edf1b18	JAQUETA CORTA VENTO MOVEMENT - Branco (G)	1	289.90	289.90	\N
b396e273-ca0e-4de8-8100-0d586b8dcaa8	58049dd1-19ca-4b89-82cb-1e693c542e4c	628d2222-2c97-4bae-bb3d-8dc41a48f187	d56e4138-6ba4-4d4b-a658-c0e35f28f0ea	MACAQUINHO COCOA - Marrom (M)	1	259.57	259.57	\N
77682373-69b3-4b16-ac57-255661f853a3	1f0641b3-2c24-4162-85c8-701513526fb7	41d2c32d-5cb2-49cc-8ba0-e2151436b298	17d887f0-da59-4003-948f-928da99544c3	Bermuda Fitness Montana - Preto (GG)	1	209.00	209.00	\N
00907095-10e4-4e6c-b474-405e061d37a1	1f0641b3-2c24-4162-85c8-701513526fb7	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5	3910323e-ae4c-4774-b771-84ed7ab05a41	Bermuda Fitness Montana - Azul Marinho (GG)	1	209.00	209.00	\N
80f35f9a-a131-46ff-a6fd-4adfb28b41cf	8d1fbc53-56a0-43b3-b898-491312a47646	877e5d32-474a-4f90-a4d4-f780e572d58a	91aaa205-3990-48f8-8828-504146c0f5c6	Bermuda Fitness Montana - Vermelho Batom (M)	1	209.00	209.00	\N
6988ef93-541b-440f-bb92-addbc9f33390	8d1fbc53-56a0-43b3-b898-491312a47646	03d3e7a0-6398-47a7-aefd-e5811cddb10f	f8ce2cae-e40b-4b1b-af36-30e4b68b3cb6	Bermuda Fitness Montana - Cinza Mescla Escuro (M)	1	209.00	209.00	\N
03a1c1a6-248b-40d1-b938-075b6e77a25b	8d1fbc53-56a0-43b3-b898-491312a47646	c0ec0db7-f802-4337-a426-5224eefa3342	b668891d-e25c-4973-969c-983a05e82cc7	Top Fitness Nanny - Branco (G)	1	209.00	209.00	\N
1303a6c7-9362-479b-a5e9-2c57ebbb2107	0455e7f3-b7d4-4fb0-9a70-552f05285c1c	3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5	7b3627cf-c611-4f08-93f4-3fa6d249121e	Bermuda Fitness Montana - Azul Marinho (G)	1	209.00	209.00	\N
aadf53b2-7ec9-429c-829b-aa154513f412	d7b0855c-a27c-45f1-bed3-90c1deaddcea	1d1fb844-0f07-4b09-a80c-0b02ba50570d	0860546a-e730-42f0-b1e8-cffba52076e1	Top Fitness Nanny - Preto (G)	1	209.00	209.00	\N
f58d23f9-199d-4944-af6f-8adeb3d54e49	9358736e-dc18-45f7-8ef5-75bfd27924a4	41d2c32d-5cb2-49cc-8ba0-e2151436b298	e5797329-3609-49ea-bdc1-aea4dd02be25	Bermuda Fitness Montana - Preto (M)	1	209.00	209.00	\N
cb1cd451-c5c0-47c9-8e11-f4b1e9d980dd	8828bc22-2eb9-4f73-99c8-c86fb41d4fb4	3d634e9c-b236-49f3-9d74-19a6a21bc730	137e48b1-7783-4f68-9942-e5276f20d6a7	Bermuda Fitness Veloz - Azul Bic (M)	1	199.90	199.90	\N
09c8a63a-a65e-4aed-a620-f3b8afa319be	0f101e5a-c55c-4747-8ccf-e5ee06fb4cf2	ea9742b4-b495-4787-a7cd-f53352a29c99	dce37737-eca0-4dfc-8135-3d4b7cfd5fa5	BLUSA MANGA CURTA DRY FIT JANICE - C0009 - AMARELO NEON (M)	1	129.90	129.90	C0009 - AMARELO NEON
403f8b9f-968a-4945-bdd6-2a206c2ad8db	10fd7815-9ba0-4c7f-a124-04e275ae2d91	b1a76627-8254-44af-aaf5-99dd25c780d3	07ea9b14-d32b-4289-b23d-56f07814ab06	Short Fitness Street Bolso - Azul Bic (P)	1	239.90	239.90	Azul Bic
0b94e25f-145b-4c40-9b47-48ea07bfd2a4	58468760-bada-4195-b6f5-4dfa8bda8313	12340bde-9009-4c92-904d-b0ca61d085af	870f1f0d-2640-4516-8bfa-7a4be0f51062	Legging Eterna Cos Alto - Preto (M)	1	290.90	290.90	Preto
68258896-7601-4cd2-8aae-6266630e427d	58468760-bada-4195-b6f5-4dfa8bda8313	fc469e48-c097-4005-bbf7-9c8b7e488b82	d59a305d-e48f-420b-9e0d-82504a4ed3af	Bermuda Eterna com Bolsos - Preto (M)	1	220.00	220.00	Preto
c7afbc39-d7df-42ad-b5a9-8537fc70ed44	995e79b0-dfcb-48a7-9cd9-bf89cafe8f33	64544c42-05d0-4c1a-b988-0d0e07834e15	b538176a-a194-41dd-baf5-268518d87fe0	T-shirt Eterna Gola V - Preto (M)	1	129.90	129.90	Preto
b329e2c3-b1dc-42ec-87a9-30ae190348b3	cf7d6e22-eb97-4eaa-9396-ede63576eb4d	28287d18-20dd-4210-9450-67c2e91e8345	ba3a1a7c-19a1-4f47-aae2-8e46d8d05fbd	Regata Fitness Pulsar - Verde Forest (P)	1	139.90	139.90	Verde Forest
53c02745-1b7d-4064-82ec-3dcf18c1bc35	cf7d6e22-eb97-4eaa-9396-ede63576eb4d	9437321d-7e2b-41a5-96cd-27b94663bc00	d8dc5a0c-b64e-44e0-ad02-657b836d4de5	Short Fitness Street Bolso - Amarelo (M)	1	239.90	239.90	Amarelo
2d5d63ff-7494-4703-a666-6b46f97ca4a9	1b0dc0b3-cad0-4bb3-8c98-ebb66aae4ddc	9a55dd2b-b128-425f-9a60-4661635c2a14	8c73a143-e818-4fba-8542-ea4f43338508	Top Fitness Nanny - Rosa Fúcsia (M)	1	209.00	209.00	Rosa Fúcsia
a11412c9-c4c0-419b-9e98-be4e8a04bd1f	9a8b5fc0-6438-4c46-95d4-cf6e4048c49d	87e4682f-f04a-4e7c-88e9-0829fda3d325	c937de3b-45fb-4ae8-9222-94de80902db9	LEGGING ETERNA COM BOLSO VERDE CALIDO - VERDE CALIDO (M)	1	270.00	270.00	VERDE CALIDO
e095611f-dfc5-4a39-814e-4b78da577663	9a8b5fc0-6438-4c46-95d4-cf6e4048c49d	7bbe0ce4-8a2d-47f3-92d7-e5c73dc392f2	81b105b2-1655-4ecf-8b20-c992db9e98a0	Shorts Sobreposto Eterna - Preto (M)	1	220.00	220.00	Preto
17546ab1-daa9-4e8d-b753-9b56fb645916	9a8b5fc0-6438-4c46-95d4-cf6e4048c49d	d9074cc0-4cc0-4951-acc7-7465541abf71	108d36db-d4e7-4ea0-bc3a-98c320b10556	Regata Eterna Cropped - Preto (M)	1	150.00	150.00	Preto
670d93c1-85ce-4c39-8273-b913ff7de0fd	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	7eaeb75b-ea96-45fc-98fd-b6cd7063aee8	7b12243b-5204-43db-b9cd-50f777b2917a	BLUSA MANGA CURTA DRY FIT JANICE - C0243 - ROSA ROMANCE (M)	1	129.90	129.90	C0243 - ROSA ROMANCE
811f9edf-1a10-49b6-86c0-5c98769dbb3f	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	cbd9bb0f-ff33-4a7e-9df3-230d91f25ee9	c3a0e97a-86fd-428a-8ae6-a51d5d1ce50c	SHORT JULY - Verde Escuro (M)	1	210.00	210.00	Verde Escuro
e992a4b7-5946-43ce-b812-22fd62f6d9f9	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	fd8be7ee-558e-4606-a6fb-9bbfce5c5649	73d56300-9e12-47b1-86de-375b47feca37	COLETE JULY - Verde Escuro (M)	1	289.90	289.90	Verde Escuro
6c698c37-2f84-41d7-bce9-e6e478b6716a	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	4f2c3123-b08d-4515-8cde-dfcff86273bc	fd9638d0-7c8f-49ce-82e1-9f28a8c46172	Calça Legging Cocoa Everybeat - Marrom (M)	1	195.45	195.45	Marrom
f7325059-2638-4ade-95b2-c3fd68e3cb58	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	d20563f4-ccda-4cca-842f-ee62eaeb6e1b	9c35c8c2-54d5-4aeb-a925-ad03dca68d44	Bermuda Com Bolsos Laterais - Marrom (M)	1	290.00	290.00	Marrom
fb22913d-dca1-443b-9361-a463c01118fc	f9e83c9e-f4c5-4590-93c9-82e21d71a414	3c34c887-2401-40e3-84b5-0eefedea12df	f53d4128-31f2-4e90-b92b-fe08b3ec3a3f	SHORTS SOBREPOSTO REFLETIVO - VERDE (M)	1	259.90	259.90	VERDE
db118030-40b1-490a-b0d6-aa8012ad2016	f9e83c9e-f4c5-4590-93c9-82e21d71a414	0b64b183-18e2-4aa8-9152-421260382cb3	ab360519-cb45-4460-ad65-aaf396e10098	Shorts Sport Way of Life - Azul (M)	1	265.90	265.90	Azul
ba1c9420-5859-40f4-a124-c9e27b4f1d66	f9e83c9e-f4c5-4590-93c9-82e21d71a414	9b18bfa1-5be2-4276-8c1f-0e4d0281231f	f5eda00b-341a-43f3-ac70-dc5e38e09dbe	TOP ELASTICO PERSONALIZADO ALTO GIRO - AZUL VINIL (M)	1	229.90	229.90	AZUL VINIL
13b3dcdc-2a01-4e8d-ae15-9267ea3986b9	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	21f63dde-aa95-4131-ab22-e8726166ce0d	d7fa264a-44ff-447b-9d24-6515065737f9	Top Mescla Ground - CINZA  (G)	1	128.92	128.92	CINZA 
3b3e3d59-80ab-4723-a741-c6a98785a33c	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	bfba079a-f6ab-4577-8619-53f3ba184a4a	3e1b9c84-c683-422a-9b4f-f024f82a05d2	Short Mescla Ground - Cinza (G)	1	147.14	147.14	Cinza
d48d8ba2-c50e-4ad4-869d-354f0175a402	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	cb16b25d-4e95-488b-b5ab-a7d83264c334	Blusa Tule Básica - Branco (G)	1	139.90	139.90	Branco
262a2151-5d4b-4560-94a5-a51e93b8ed92	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	598d5623-0507-4a89-b3a4-987c1cae56af	3503f869-7775-489d-ab0d-e2520bf27695	Top Fitness Summer Liso - Vermelho Classic (G)	1	169.90	169.90	Vermelho Classic
bfd0c450-c6e6-48c4-bf65-6f712e9eb7ca	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	e60e28a2-3d2f-4105-8a7c-a0dd5749fc35	04502a26-7009-4684-a278-517756284c2a	Short Fitness Street Bolso - Vermelho Classic (G)	1	239.90	239.90	Vermelho Classic
417eea7f-0597-4ab0-9eb9-b4d3544c6292	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	5a486e27-2649-4704-90b2-09769d302dda	628a4602-b0f8-4432-a90f-761e53c4bfc0	Bermuda Gelo Run Drop - Branco (G)	1	181.07	181.07	Branco
bea5b087-0334-44d7-b485-6a21307b0da4	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	0b79f466-a4c6-4dcb-bad4-1a285ddb4377	19614eee-4362-4474-b022-b15326b9bf95	Top Gelo Run Drop - Branco (G)	1	148.98	148.98	Branco
14b0570e-87b3-4a7d-ba9d-7231b6bdb6a2	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	fc092e25-e25b-4cf5-abb7-ce6881fd3a54	6af2802c-98dd-4c71-946b-a577b11f85cc	LEGGING ELASTICO VERMELHO TINTO - VERMELHO TINTO (M)	1	320.00	320.00	VERMELHO TINTO
90a07175-ef04-4587-89ed-995edeec32b1	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	93bd5d41-ce0e-481d-86ae-f466a371adf8	d1bf2c62-cad2-4c93-85b8-77bf04e5f850	TOP MÉDIA SUSTENTAÇÃO TREK - C0557 - AZUL JEANS/MENTA (G)	1	143.93	143.93	C0557 - AZUL JEANS/MENTA
fb153706-730e-4083-953b-0a141ae194d1	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	8cdbc26f-24a3-4d84-9c3c-a4781c65304c	8612b6e0-9efb-4c61-9d8f-a65b42135068	TOP ANATOMICO ALCAS DUPLAS - PRETO (M)	1	199.90	199.90	PRETO
178291cf-b849-4bda-b151-78846603144a	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	fbe4fa70-fb78-492d-9608-27c11090a41a	fd1e2cd5-a13d-4c92-bc6b-b43349c00094	Bermuda Cos Elastico Bicolor - Verde (M)	1	269.90	269.90	Verde
5c10e3d4-81b0-4184-81d2-fc1db5d9eecc	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	a26aa634-b21b-4b21-a127-702abfab1f20	d8e2ca82-7b86-44bc-a648-fb2091189b40	Top Cos De Elastico E Alca Dupla - VERDE (M)	1	220.00	220.00	VERDE
87b87d93-570e-40cc-94a3-8da2a85a4c38	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	61f63760-95d2-493a-a81f-fdbdad335355	96ac036e-8e35-4854-bdc8-8bc7ebea198d	Bermuda Recorte Lateral - Marrom (M)	1	255.00	255.00	Marrom
20c68646-43c4-4a50-a085-bfe2d359060f	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	2ca91c0d-1c44-4b8b-83c7-35a12406f314	9d56baf5-d054-4bd0-8202-24f42974e871	Top Dupla Face - MARROM ANIS (M)	1	229.90	229.90	MARROM ANIS
74739b71-817d-49ba-9eae-e7be7a78c108	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	9bec3a8f-030b-4b74-be80-24e3ced41e0c	8a9ffe9b-ef3d-4ffc-b8ec-62b60c504ad3	REGATA ELASTICO PERSONALIZADO - BRANCO OPTICO (M)	1	179.90	179.90	BRANCO OPTICO
ceaaee04-c2cb-41b6-b6a3-cd9637887ed7	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	6bba510d-f3a4-4806-ab18-5d2095022144	46dacd9f-da4c-4698-8a74-0b860f285a83	SHORTS SHAPE UP LOGOMANIA MYST - E1343.I25 - VESTEM CACTUS (M)	1	139.90	139.90	E1343.I25 - VESTEM CACTUS
36c28507-0bcf-4dfe-a374-0fd23faa09ce	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	b226cbb8-5781-41b3-8647-a2b88fe9cf58	a5a4ec83-de5f-4b28-82f4-c03a05e98b43	TOP MEDIA SUSTENTACAO LOGOMANIA MYST - C0550 - EBANO (M)	1	159.90	159.90	C0550 - EBANO
4522ca3a-a1a0-4282-9ae9-782498bf7c46	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	fe2f9328-af80-4d72-aa25-8ed6a2430cb4	3781ca49-be72-43b3-94f1-cb34e90aa8c1	Top Fitness Nanny - Verde Neon (M)	1	209.00	209.00	Verde Neon
112c4198-1e04-4536-b1ca-3c7cb922f646	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	c9bf8fab-7dc3-4f86-8ede-4f0a1d34c466	356f1c2f-4d66-41af-bef2-75fb9c204e9e	Colete Lyra - Preto (M)	1	339.90	339.90	Preto
d7e717f6-510f-422d-aaf5-cb62b942c786	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	4c744423-e7a5-44a9-88d9-9ae2bcee022b	b1c82ce9-c98b-4ae1-99b3-1d3a9a41833a	LEGGING FUSO LISBOA - C0512 - VERDE EDEN (M)	1	209.00	209.00	C0512 - VERDE EDEN
f2a75fb3-a879-4e95-b985-8692d255ba6c	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	4e36014a-55f9-497d-935a-8d1e4694a596	feae30cd-25b5-4a1f-9ed4-61761884a0ee	TOP LISBOA - C0512 - VERDE EDEN (M)	1	209.00	209.00	C0512 - VERDE EDEN
ac6c2483-c75d-43ed-b889-811a77571289	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	e4d0e600-15d1-45b5-9391-240739862804	aea9f109-7250-40c4-ae15-595bdcfc53c0	TOP FITNESS CELESTIAL - AZUL CARIBE (M)	1	160.00	160.00	AZUL CARIBE
22b0f88f-ba9b-496b-83d9-281676701162	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	dc407b2b-d84b-4554-831b-795e0716bdbe	436bee94-cb78-4107-bcbd-e686f7b225e1	CALÇA LEGGING CELESTIAL - AZUL BIC/AZUL CARIBE (M)	1	235.00	235.00	AZUL BIC/AZUL CARIBE
234830a2-d7e3-4eb4-9c08-92c28447d5a9	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	8c16d307-f3a4-4c06-863a-d6ee02ea9869	221f42ab-a784-4e1e-aaa1-93b8b9f71946	Short Rose WindFit - Rosa (M)	1	181.34	181.34	Rosa
751931fb-24ff-4b72-9e02-1421e43bf751	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	bf4acbba-69dd-4445-8a60-52a91652fb1b	947b45e9-4f7d-4d1d-a9b1-0c6be2caf8da	Regata Rose Daylight - Rosa (M)	1	216.13	216.13	Rosa
9c6c6fd5-5bd8-4832-9be5-d63e55e07081	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	1e0a66d1-dbc1-4ef8-8839-aece52724742	d2d52065-afee-43c9-9b9f-e61f390e285d	Top Rose PureCore - Rosa (M)	1	161.46	161.46	Rosa
d865a8c7-22ae-424e-94d6-6b6252e0bce2	30309d16-15c5-4f4b-866a-e959451719a4	5dcffd07-7cfd-4204-9e49-3401773bb7ab	aa6310b9-2004-4a56-a9cc-cc5f6ac45286	LEGGING ETERNA COM BOLSO - AZUL NOTURNO (M)	1	279.90	279.90	AZUL NOTURNO
b8a8227c-7bf5-4c80-a082-7754828fa548	05e78f2f-b675-4088-9972-ce575938e01c	80b0e230-bee4-46c0-9ff3-bf55b59955d5	43d987cc-58b5-45ea-93d8-f19dc5f60996	TOP PRETO FRAME - PRETO (M)	1	134.29	134.29	PRETO
7df29fed-84e7-46cd-95c3-e29ba6659491	e1cb8ba5-583d-4552-ba38-d59bf16a8dbb	9bec3a8f-030b-4b74-be80-24e3ced41e0c	853142ab-bca3-4328-b2b3-598fd5744cad	REGATA ELASTICO PERSONALIZADO - BRANCO OPTICO (G)	1	179.90	179.90	BRANCO OPTICO
3d6948d5-337a-4575-a49c-5ef671604e47	2193d452-0c1e-4500-a3ff-d95f44e2e811	5a9db7ea-c12c-4eab-ae6e-3b2ade4da98b	c69f50a3-f499-4ad8-a354-2e9cdc5313a7	TOP NADADOR ELASTICO PERSONALIZADO - CINZA HORIZONTE (M)	1	229.90	229.90	CINZA HORIZONTE
3b0383d2-fa21-4414-b2ec-d0f0aa4d1567	2193d452-0c1e-4500-a3ff-d95f44e2e811	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248	5d842263-970c-476d-9593-c0fc346ea59e	LEGGING DETALHE CONTRASTANTE - MARROM NOITE (M)	1	369.90	369.90	MARROM NOITE
ac71d67c-bcb7-4781-88b9-369e8715f839	2193d452-0c1e-4500-a3ff-d95f44e2e811	244b0d4a-aba1-407a-90bf-fe4a6e464be3	5077fa7a-1d9d-4824-9f5b-7441252c0967	REGATA NADADOR COM TULE - CINZA HORIZONTE (M)	1	179.90	179.90	CINZA HORIZONTE
f710f952-d9b1-4e8d-a73f-6ee46393616c	968f323b-e225-4869-984d-bdf058330c8c	c0ec0db7-f802-4337-a426-5224eefa3342	fded3b4c-8d0b-4955-8eab-3b45edc2ef4a	Top Fitness Nanny - Branco (M)	1	209.00	209.00	Branco
60830720-af4c-4bcb-a295-4ce0837c0a9f	968f323b-e225-4869-984d-bdf058330c8c	b1a76627-8254-44af-aaf5-99dd25c780d3	36057585-d399-4c9e-b475-e18d727d3c66	Short Fitness Street Bolso - Azul Bic (M)	1	239.90	239.90	Azul Bic
7100e595-b71f-4a72-916b-c504f6527def	b24f4633-230e-471f-ba24-21c5bebd1113	97fba60a-fae3-497d-bd3a-081ba65a7d11	1f891cf5-f1a8-43be-8e67-f683a6852e84	TOP ELASTICO COSTAS NADADOR BRANCO OPTICO - BRANCO OPTICO (M)	1	240.00	240.00	BRANCO OPTICO
0277f567-5352-45bd-93ac-b2fc761c3c8d	b24f4633-230e-471f-ba24-21c5bebd1113	a26aa634-b21b-4b21-a127-702abfab1f20	d8e2ca82-7b86-44bc-a648-fb2091189b40	Top Cos De Elastico E Alca Dupla - VERDE (M)	1	220.00	220.00	VERDE
3abd2a68-54d9-4c35-8509-ccfa69a499d0	6813c9ec-1007-4a41-bb18-a9956f13db8f	52a04c53-d12e-4d24-adb0-e99f550a3907	1852f73a-54be-4f2e-a3fe-da0ef3a289f4	COLETE JULY - Branco (P)	1	289.90	289.90	Branco
3cdb4ce9-5af1-4b78-8cbe-e1611f9d6801	6813c9ec-1007-4a41-bb18-a9956f13db8f	7e3d8939-6360-463f-9573-9188011607ed	606cb46f-ffe0-4c04-86bf-23850cdc57c6	SHORT JULY - Branco (P)	1	210.00	210.00	Branco
09238518-dc2e-4d10-973e-9e29bf1bd515	9431a927-7040-4ed8-98d5-4630dac31865	7223beff-dc9d-4b53-8c4c-658b3763a6ea	bdc06cd3-84ea-4e18-b4ae-91e4179e0f14	COLETE JULY - MOSTARDA DIJON (M)	1	289.90	289.90	MOSTARDA DIJON
2577a7c9-4ba1-4101-a412-18fd6a2889a0	9431a927-7040-4ed8-98d5-4630dac31865	d61bf2c1-9320-4a1b-9b7c-5d51c0ae1a00	3ae6256b-d402-4e27-bd50-38c153d5d153	SHORT JULY - MOSTARDA DIJON (M)	1	210.00	210.00	MOSTARDA DIJON
190ffe05-524e-488a-9943-3cd84f04d30c	73fac3fc-117b-4739-9e41-0994acab437d	03b2fc1c-cf16-4880-872f-05e52f9f882b	3a6c1861-c427-4d42-961a-7fa27793ba4c	LEGGING SPORT WAY OF LIFE - PRETO (P)	1	329.90	329.90	PRETO
6fadef44-c6d1-4331-8ce8-97cbd7363ae3	73fac3fc-117b-4739-9e41-0994acab437d	e2276700-5553-4a39-bda7-53118e24cade	4bd1e60d-e5e7-480c-99a3-6b71b556aecb	Top Fitness Veloz - Azul Bic (M)	1	179.90	179.90	Azul Bic
aba892eb-3253-4ffd-a05b-560e9badb0ad	6cc62712-62ab-432d-863c-d12a13122ac4	fac47062-4296-46a9-845f-ae567089a3f9	2c8796bf-aa68-4b96-bb64-f675e8efcfc2	Regata Tule Celeste - Branco (M)	1	129.90	129.90	Branco
01845374-e04e-4b83-ba46-c4f863ae2d6f	fa9b359c-6a5f-4edc-800e-1e07336ced79	3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3	8a548f43-0ad2-4df5-bebe-fb2aff03165d	Regata Tule Celeste - Preto (P)	1	129.90	129.90	Preto
58eda1bc-a747-4dc3-99e5-df28a3303a81	a70452b0-1880-47cd-908e-154924638f34	97fba60a-fae3-497d-bd3a-081ba65a7d11	b9e11ed1-3aa2-47b1-999e-40f1de8c7681	TOP ELASTICO COSTAS NADADOR BRANCO OPTICO - BRANCO OPTICO (P)	1	240.00	240.00	BRANCO OPTICO
6132da98-752e-4ead-9475-146089936c65	a70452b0-1880-47cd-908e-154924638f34	511252b4-4a5e-433a-ac9d-e31fd182144a	838efb1b-c446-4e50-8be7-0cbac9b75f35	TOP ELASTICO PERSONALIZADO ALTO GIRO - BRANCO OPTICO (P)	1	229.90	229.90	BRANCO OPTICO
d34043f2-dffc-4ed4-a894-a1cc8f86c9f7	a70452b0-1880-47cd-908e-154924638f34	c68f212a-8a4b-4d82-b22f-d56006f28c10	3cb52fda-8f87-42c5-854f-ef11ee805f75	TOP ELASTICO PERSONALIZADO NADADOR FINO - AZUL PISCINA (P)	1	199.90	199.90	AZUL PISCINA
ddb2c4db-7f29-4b63-972e-7eda84eb7ed2	a70452b0-1880-47cd-908e-154924638f34	cb527f95-20c9-4c42-82a0-1236ccab1f86	cb5a98a4-ad05-4c3d-abba-b91badf0d678	TOP REGATA NADADOR - PRETO (P)	1	399.00	399.00	PRETO
a5a3117d-ebee-4251-aba2-949c1c9b3975	a70452b0-1880-47cd-908e-154924638f34	3a053da8-0523-4cc3-927b-1ebb65aab3a9	23fd1e1f-e6d3-4bc1-9d53-1903b954cecb	BERMUDA COS ELASTICO BICOLOR - ROSA AURORA (P)	1	269.90	269.90	ROSA AURORA
88545c37-e2b7-4e85-9859-ec90ba78664f	a70452b0-1880-47cd-908e-154924638f34	e1eeabac-0b5c-414e-8292-b5487a1bc841	a5a8bb92-a8fe-4103-a7a2-815ce78f8ae2	TOP COS DE ELASTICO E ALCA DUPLA - ROSA AURORA (P)	1	239.90	239.90	ROSA AURORA
2a0c021c-a5ae-4ced-b528-0dc2cd61e6e4	a70452b0-1880-47cd-908e-154924638f34	32c571f7-ef80-4948-a2ad-18e0771263a6	14847523-18eb-492e-b48c-e1f114d3af9f	TOP ELASTICO PERSONALIZADO ALTO GIRO ROSA DOCE - ROSA DOCE (P)	1	200.00	200.00	ROSA DOCE
a938a7b0-7b85-4518-9960-cf0843b72247	a70452b0-1880-47cd-908e-154924638f34	eeef784a-f4c3-49a4-b126-a4ff7cced463	d90e2b67-acda-46b1-8f72-3ffc2967772c	BERMUDA ELASTICO PERSONALIZADO ALTO GIRO - ROSA AURORA (P)	1	219.90	219.90	ROSA AURORA
1b33ef8a-4da0-4606-9947-a6843fc5d4fd	a70452b0-1880-47cd-908e-154924638f34	bd62d0cf-146b-4d56-9621-244e4e5352cd	1fb7278c-cba4-40bd-85b3-1584de2be55a	TOP NADADOR ELASTICO PERSONALIZADO - ROSA AURORA (P)	1	229.90	229.90	ROSA AURORA
3bd1ed8e-c4e3-4651-9984-66c2c666aa03	a70452b0-1880-47cd-908e-154924638f34	db44cd4c-ca3e-49c9-9fc8-a5c50e8a1f01	4639058a-276e-42c2-b43f-fa5d0cf9f19b	LEGGING COM RECORTES E ESTAMPA - PRETO (P)	1	399.90	399.90	PRETO
abf0cb68-5985-43bf-90a0-e578b9cfe1e1	a70452b0-1880-47cd-908e-154924638f34	32c8d197-fa1e-4cd7-8559-639d7b8a1359	07fe3d25-330e-478f-acdf-0a61303fe09d	TOP ALTO GIRO SPORT - PRETO (P)	1	299.90	299.90	PRETO
f34564c2-7c59-4391-b0dc-7ff4d783395a	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	eafb3b17-fafe-4d6f-863b-b12a2fc6343f	2fd2a9a5-e8f5-4bbf-92bf-f9df339d8fd0	TOP ELASTICO PERSONALIZADO ALTO GIRO - BEGE (M)	1	229.90	229.90	BEGE
ec2276d9-f779-4bf6-aa67-9db9097f9098	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3	0227c761-c81a-442a-b52f-a41d069af7ff	LEGGING ELASTICO PERSONALIZADO - BEGE FRIO (M)	1	329.90	329.90	BEGE FRIO
01549f9e-0e79-4e28-a138-e6d934d56857	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	9fd20c26-5d5b-4b11-80e5-ecf884019976	aae3f230-f079-4af4-806c-2585988234c9	Regata Helena - Marinho Escuridão (M)	1	189.90	189.90	Marinho Escuridão
a0c794de-94e4-438a-82ed-3d43acdcff8a	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	178c1bfb-c016-4a74-9879-bbe421693e9e	0d60351b-1d93-4db3-bb5c-2ce653c24be9	Top Alta Sustentação Helena - Marinho Escuridão (M)	1	199.90	199.90	Marinho Escuridão
2ca5b852-103b-4669-950b-0d210337ff48	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	787c677e-8541-4a37-8f76-1b0a338ce9d3	8f582656-6c8c-493a-a016-9bf80916e8c0	Legging Helena - Marinho Escurudão (M)	1	299.90	299.90	Marinho Escurudão
42b478e3-30c1-4abe-9d53-5b5aab5319fd	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8	fa6957ea-2a79-490d-b48d-e87ffd4ce8e2	Top Degrade - Rosa (M)	1	229.90	229.90	Rosa
704324eb-2f40-4351-b07b-a71928d7148e	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	c9f22b86-6bdb-47cd-9832-d47f617bd6bc	0d66f4a7-5370-471a-818b-b1aba224f865	Legging com Bolso e Estampa - Rosa (M)	1	329.90	329.90	Rosa
81476519-1caf-434e-afd1-e82467b9d298	c38b79a8-9005-4b52-b009-cb24693fa29f	33919956-5f82-408a-bf83-d948ffca4d4b	6a3e7909-1d6f-41d7-858b-0fc5d6a0e938	Short Saia Storm EveryMatch - Azul (M)	1	225.99	225.99	Azul
5a3e36e1-bbbe-4f1e-b195-4a5b5bf2e3db	c38b79a8-9005-4b52-b009-cb24693fa29f	4dda8aa6-b238-4cf3-88a1-fa327584a3be	21193f3a-00b3-420e-8aa5-80b6d1172444	Regata Storm EveryMatch - Azul (M)	1	132.33	132.33	Azul
78e06df9-562f-43ab-b5b9-e68ddb3d5b1a	615d7e05-5fc0-48cf-b653-ee6c11d0567a	769c8388-bf63-468c-b806-2f326b5af2ee	642a148a-56a9-4b5e-998b-6978eb35d5d9	LEGGING FRISO CONTRASTANTE - Preto (M)	1	369.90	369.90	Preto
a1925b86-946f-4c97-8813-779ca762e1e8	615d7e05-5fc0-48cf-b653-ee6c11d0567a	2357e280-e696-4910-8e91-4393557c8a37	b8352a38-6158-4fa2-97e3-a490ab1d4b44	TOP NADADOR ELÁSTICO WAY OF LIFE - PRETO (M)	1	259.90	259.90	PRETO
fd7c519d-a157-4c24-808a-bec5045359f9	bd33264b-59b5-418c-8869-68201818c57a	30881abb-d3f6-44c3-8684-d9d34df5545d	ce4b1448-40a6-49e0-a8aa-ee90cb7043c5	T-SHIRT CROPPED - OFF WHITE (M)	1	199.90	199.90	OFF WHITE
c68381d3-9b94-4fa3-b900-6c371099457c	3d728f6c-e38d-4137-b099-545946a2e3cc	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	c749bda2-13a8-481a-b3c7-9fa5bdd10e07	Blusa Tule Básica - Branco (M)	1	139.90	139.90	Branco
0ce3ddb8-4ce4-4cae-a791-1b93ce77fe1f	3d728f6c-e38d-4137-b099-545946a2e3cc	a2e9454e-e59e-4c92-aa00-0cf93c3ea168	bea52321-85aa-4686-8ae9-ba3854cb190e	LEGGING RECORTE ASSIMÉTRICO - Preto (P)	1	429.90	429.90	Preto
c3e29aec-87e3-49a6-8be6-0281d879f5da	3d728f6c-e38d-4137-b099-545946a2e3cc	6060f268-49b8-492f-aee7-d21656de929b	8d57bad3-eef8-479c-be5b-c6218d90eb8d	TOP ALÇA FINA AG WAY OF LIFE - BRANCO ÓPTICO (M)	1	199.90	199.90	BRANCO ÓPTICO
f8880623-f4d4-4355-8566-ccba79800e14	319e1273-25d3-4963-b3ee-414be1bfd801	7f22cf72-8496-41f6-821d-334ffd96a556	cfedb2c2-7b58-479a-9782-c3c4f4418612	MACACAO LONGO FITNESS BRO - PRETO/TEX (P)	1	335.00	335.00	PRETO/TEX
bf0c1957-1999-4ea4-b1fd-003907fed8b9	319e1273-25d3-4963-b3ee-414be1bfd801	fac47062-4296-46a9-845f-ae567089a3f9	7569007b-e10f-4b4e-a00a-8a6390a9bd0e	Regata Tule Celeste - Branco (P)	1	129.90	129.90	Branco
ac440f69-f89b-4205-b224-ed71574ff908	b6d7ce40-b699-4914-9ee1-b3f4b127b285	30881abb-d3f6-44c3-8684-d9d34df5545d	ce4b1448-40a6-49e0-a8aa-ee90cb7043c5	T-SHIRT CROPPED - OFF WHITE (M)	1	199.90	199.90	OFF WHITE
3a35a714-d84a-4cef-ada4-81316322f0ab	bee19e29-193f-45d2-819d-9760948fd45d	a0f12306-5fce-4173-ac98-5b6350de1863	3b1e2a97-36dc-49ac-b342-06a2878f2d11	Top Alça Cruzada nas Costas - Cinza (M)	1	219.90	219.90	Cinza
30e9469c-08ea-4105-a185-9165b7c13e42	bee19e29-193f-45d2-819d-9760948fd45d	271fec96-9aed-4d36-b71d-87147092ae3e	5ca68ed1-f534-479f-8701-198fc28abaae	Bermuda Detalhe Bicolor - Cinza (M)	1	279.90	279.90	Cinza
410438ef-958e-4e7c-b269-4f14d36200f5	b4f7d41c-6d78-4a29-a39f-77b81f1b0434	3d4d4732-f830-49fa-a7ea-72b7ba66801e	86777dbc-d9a2-446e-9876-e2d5a9a90a73	TOP ELÁSTICO PERSONALIZADO - Roxo Malva (GG)	1	229.90	229.90	Roxo Malva
00896c91-d445-4f02-8b95-89b2a85a75bd	b4f7d41c-6d78-4a29-a39f-77b81f1b0434	314cbea3-f0b7-41f4-b609-59e904d83a35	e822f646-2e45-4440-9134-b00bc8e75aad	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO - Roxo Malva (GG)	1	229.90	229.90	Roxo Malva
e55d64bb-bfcb-4747-b898-150b2017efc5	7caedb35-8690-4a93-b3b0-ad139b8e2550	42d326ad-5ca4-4a70-9827-56795a80e6be	97e4ee71-88d8-45d9-ac63-b05db8b0c8dc	TOP ALÇA FINA AG WAY OF LIFE - AZUL CÉU (G)	1	199.90	199.90	AZUL CÉU
ca0eb997-f54a-45cb-b3a2-af5b359b84ba	7caedb35-8690-4a93-b3b0-ad139b8e2550	39ccf293-fcfe-4409-9588-290e3419c592	d41270b2-9899-4603-bd1c-4eba0c9a2b73	LEGGING RECORTES AG WAY OF LIFE - Azul Céu (G)	1	369.90	369.90	Azul Céu
de495296-917b-446a-abf3-b5af2e04e089	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	cc8c8918-e373-494a-8032-dbad1d9278df	c9eb34cd-3957-4bf5-960f-8dbe17e5a197	SAIA RETA DETALHE ESTAMPA - ROSA PASTEL (M)	1	299.90	299.90	ROSA PASTEL
947f951d-38dd-49d4-a12e-161fc5ff6ae8	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	3a7b5436-a329-48ed-841d-b103d2e3b4c9	20c7cb58-0ca5-4a73-86c0-29cedb37d818	TOP SOBREPOSTO BICOLOR - ROXO INTENSO (M)	1	299.90	299.90	ROXO INTENSO
2af90309-3de2-4de7-a9e0-c23aa92536ec	fb3d69f8-e303-43f2-a588-2c63f56d9dd9	6e18ff3f-06dc-4ad2-a18c-7a9dc33e4f66	c9e08a4a-fb8e-4787-a496-f9941e3a6d23	SHORTS SLEEK FIT SHAPE UP - Marrom Castanho (M)	1	209.90	209.90	Marrom Castanho
fe8d982b-1d57-44e2-a866-016d89d4043b	fb3d69f8-e303-43f2-a588-2c63f56d9dd9	69e1d89e-c197-4a93-997b-14bc02e1a31a	028f3e14-9142-4cf5-9b8d-19461f5a28fe	TOP PARK SLEEK FIT MÉDIA SUSTENTAÇÃO - Marrom Castanho (M)	1	159.90	159.90	Marrom Castanho
9e9c2649-c2a1-4f26-b457-bbaa03763306	716d1344-1503-41fc-8eb4-8a7547bde1bd	316e0847-fb38-4f8e-b27d-5674bd1666bf	e65417fe-43b3-4287-8db0-ffabb5de6c8a	BLUSA CROPPED SPOT TREVOS - PRETO (M)	1	119.90	119.90	PRETO
dffc0803-9a28-4ede-8c24-051627be0d4c	d2ac5fb3-efaa-4864-9f12-edddd4118831	8929682c-550d-4126-87d4-8561dd141c94	4faabf0b-c6e2-42da-8850-78fdec5b7e54	SHORTS LINEA SHAPE UP - MARINHO ESCURIDÃO (GG)	1	159.90	159.90	MARINHO ESCURIDÃO
82fdad87-effa-4820-847e-71e97eefd578	d2ac5fb3-efaa-4864-9f12-edddd4118831	03d3e7a0-6398-47a7-aefd-e5811cddb10f	9bcd9e83-9dee-457c-af21-316d6c95bbca	Bermuda Fitness Montana - Cinza Mescla Escuro (GG)	1	209.00	209.00	Cinza Mescla Escuro
4eaf5f84-5424-41c5-9857-bc719905dbda	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	39ccf293-fcfe-4409-9588-290e3419c592	77cbb2b4-2313-4428-a390-c8833908affe	LEGGING RECORTES AG WAY OF LIFE - Azul Céu (M)	1	369.90	369.90	Azul Céu
f9579031-e8fa-480a-bffe-f6a8f50f1032	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	4bde4343-0684-40a3-a694-abf824e2fe33	186ea5ac-64ac-4019-bfd1-9885176f1c70	MACACÃO ELÁSTICO AG WAY OF LIFE - PRETO (M)	1	479.90	479.90	PRETO
4ac32e5d-1467-4a03-853a-a5a5611d7081	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	d9158d5b-3529-4301-b4e5-e1bcdc4158c4	4344ce43-a5fa-432b-9287-6c3d19a1859e	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO - Preto (M)	1	229.90	229.90	Preto
5a8d567c-9bfa-40f6-9d8e-a661347083ae	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	2e5432cc-ab51-4605-b02c-49c5c00e2605	2af0286a-a890-41f4-b2b7-d6937d622be1	TOP DUPLA FACE COSTAS CRUZADA - BEGE CREMOSO (M)	1	199.90	199.90	BEGE CREMOSO
8d7fc6c7-7736-4a32-bde9-345966607356	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	51df7326-c23d-4ce8-bb6b-f81662867894	4bedc7b1-5a0d-44f1-8254-43afd796e052	BERMUDA RECORTES AG WAY OF LIFE - AZUL CÉU (M)	1	349.90	349.90	AZUL CÉU
c11cc3ce-35c5-463e-9e6b-b381fa7cc440	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	a27d57a0-bc23-492a-9632-8082d16c7170	eaa1c14d-e6e5-490a-a202-86d8cb91646e	TOP NADADOR ELÁSTICO WAY OF LIFE - VERMELHO RUBRO (M)	1	259.90	259.90	VERMELHO RUBRO
803604e9-1f22-45c4-bd80-cbf1aee3df83	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	0d252391-9224-48a8-8ec9-dd9cbcb683e4	e211116e-7522-42cd-9141-4511793558bb	LEGGING ELÁSTICO AG WAY OF LIFE - VERMELHO RUBRO (M)	1	369.90	369.90	VERMELHO RUBRO
a42fed47-64ab-40cd-9987-2c75263c95e5	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	326add3c-eb17-495c-926f-374e8b982837	ba47390f-f7ac-436b-856d-a1177360e60d	BERMUDA RECORTES AG WAY OF LIFE - BRANCO ÓPTICO (M)	1	349.90	349.90	BRANCO ÓPTICO
7637288b-16ae-4d55-a545-c088eb30375f	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	32c8d197-fa1e-4cd7-8559-639d7b8a1359	d9bda251-e39b-4d5c-a927-a795821797ce	TOP ALTO GIRO SPORT - PRETO (M)	1	299.90	299.90	PRETO
53750faf-0add-4a6d-8461-196eaefafc0e	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	f58a6e05-302a-4ae7-9754-7eba7b2ab797	ab64c416-9b6f-4240-b5b1-cad033696e37	Top Alta Sustentação Helena - Marrom Sepia (M)	1	199.90	199.90	Marrom Sepia
f3e5ee98-ffb5-416a-9266-5362c1116aa8	0b156dab-8965-4358-a6da-7e598e3ce2d9	cec93d51-6aeb-484f-a139-cac515ba14c9	bec2e856-e6d6-418f-bdd5-87242dcac858	BOMBER TEBAS - Branco (M)	1	249.90	249.90	Branco
6439fac6-4992-4f43-8ac8-699e80733a27	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	5a1309a8-2b53-440e-9dcd-463538d23141	5d3c3597-9577-4707-aee8-b9f50888205d	Legging Bicolor com Bolsos Helena - Marrom Sépia (M)	1	299.90	299.90	Marrom Sépia
39995db5-86ea-4861-9fb0-77760dc45358	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	9c643407-daf7-4827-bf3f-19706be83648	9b1c51fc-f0fd-4a31-99b5-2ad9bd9f29ab	Legging Shape Up Transpassado Bicolor Yara - Marinho Escuridão (M)	1	279.90	279.90	Marinho Escuridão
58306030-28e5-46ad-92d0-0dc2b00b647b	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	b4a8c083-7ce3-463f-bd4d-c8418d6ba579	3bbe5fef-4caf-45fc-94b5-3769756ceeae	Macaquinho Com Ziper E Elastico - Preto (M)	1	310.00	310.00	Preto
e298563a-d345-41ee-b3ff-baeccf152ae7	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	1d1a3201-afad-4946-9463-0c5b125e2615	60fe29d6-e98b-4c68-a94f-a375cdae9b09	LEGGING BOLSOS E ESTAMPA - PRETO (M)	1	359.90	359.90	PRETO
8717cd5e-20af-4441-bb5b-17334f896093	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	c360ccbe-736e-4357-afc3-62f7cacc33b9	e4094a4d-252a-44a0-ba14-f3b8e37eefd6	Shorts 2 em 1 Elastico - Azul (M)	1	329.90	329.90	Azul
a3fa8560-524a-4cc2-b605-8c5a8e7181ed	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	61a2649e-51cc-4f2f-b143-1113d41bc9fd	d1ec243b-463f-46c2-870b-60ff4b080d0b	Top Elastico Personalizado Nadador - Azul (M)	1	219.90	219.90	Azul
b6b32860-c1bd-4872-a68a-594053c4c534	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	a6368ef1-e4ce-40d1-b616-fb9693a14a0e	3a009bce-fee3-4576-9344-25d197f786ef	T-SHIRT TULE LISTRAS - BEGE CREMOSO/VERDE CÍTRICO (M)	1	219.90	219.90	BEGE CREMOSO/VERDE CÍTRICO
e0e43dc6-a06a-4118-83d4-b5547655d65a	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	e40245f6-771f-4c75-8131-58d2766506c8	d66c39f5-3b77-480c-8b39-db03d8e24ac7	TOP LINEA MÉDIA SUSTENTAÇÃO - MARINHO ESCURIDÃO (M)	1	179.90	179.90	MARINHO ESCURIDÃO
377fc45e-7c91-4474-9466-0a4aee945c23	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	fc98af9b-2b1e-4adc-8de7-60508fb088f8	06eb8734-b85f-4cdf-8274-f5a7a55b44ce	BLUSA CROPPED SPOT TREVOS - VERMELHO BATOM (M)	1	119.90	119.90	VERMELHO BATOM
a71fd959-c7a8-4f9b-9bc7-c3301fec24b2	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	a3cd85f4-dbc5-4682-8322-3d18814912ff	c3415a6e-37d7-46cc-a3a8-aa195e0f2c45	BLUSA CROPPED SPOT TREVOS - CAQUI (M)	1	119.90	119.90	CAQUI
272439a2-8b63-454a-91d6-427f87f770d2	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	76e1779f-f72d-4903-88a4-df32c0ddbf7a	fbda60fd-ab93-49cc-aa9d-8056eaa3f4f7	LEGGING LINEA SHAPE UP - MARINHO ESCURIDÃO (M)	1	269.90	269.90	MARINHO ESCURIDÃO
894cad3f-b003-4a98-80c7-3307cd16d5bd	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	8929682c-550d-4126-87d4-8561dd141c94	729c24fa-6e99-42fc-9b2a-ff0d51100d30	SHORTS LINEA SHAPE UP - MARINHO ESCURIDÃO (M)	1	159.90	159.90	MARINHO ESCURIDÃO
0b02c0a0-8d07-464a-9e86-a765c4068358	783960f7-8b70-498d-bf46-31f40ca6b2eb	717f76a2-0f95-47ed-992a-808ba48cffa3	bc2f17cb-c000-4ba9-9ef6-97783cf0ce50	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO - Roxo Encanto (G)	1	229.90	229.90	Roxo Encanto
629bccb2-9a0a-49ac-bb3b-1f97cdce5c7d	1871e295-fb6f-4022-8cb2-5ce142c003e5	bd33b8f4-d6d5-409f-830f-47294e5461d1	089cc615-e37a-4996-946f-7107c4fb4a6b	BLUSA CROPPED SPOT TREVOS - AZUL MARINHO (M)	1	119.90	119.90	AZUL MARINHO
4b9f7d17-6b7b-44ea-b2c0-8fb3cddcbce4	1871e295-fb6f-4022-8cb2-5ce142c003e5	fc98af9b-2b1e-4adc-8de7-60508fb088f8	06eb8734-b85f-4cdf-8274-f5a7a55b44ce	BLUSA CROPPED SPOT TREVOS - VERMELHO BATOM (M)	1	119.90	119.90	VERMELHO BATOM
ff950e5a-21d7-4b6d-88f2-fce610e347f0	25773b86-715a-4f92-8433-20fb7fabf595	70604eae-b5d8-4a80-9999-58b39f210865	68c55fdf-39c0-459e-9719-ed42da2dc2af	BLUSA MANGA CURTA DRY FIT JANICE - C0528 - CORALINA (M)	1	129.90	129.90	C0528 - CORALINA
1d08432c-e215-47f8-b818-fea23df24195	25773b86-715a-4f92-8433-20fb7fabf595	b4569222-dc3c-4d38-a01c-51552d0d23d7	1283c87a-804f-4c95-bec3-f852ef3b6226	BERMUDA COM BOLSOS E ESTAMPA - LARANJA PÊSSEGO (M)	1	349.90	349.90	LARANJA PÊSSEGO
09115aef-6770-45f1-ad4d-625a81a89f2c	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	9a95b489-962f-4d5b-a175-ab5c3d725cbb	2fde8c02-d8f5-4da0-b92d-b04ed0b3ca04	MACACÃO ELÁSTICO AG WAY OF LIFE - AZUL NOTURNO (M)	1	479.90	479.90	AZUL NOTURNO
90ba43c2-72e8-4213-8254-71ecb89dacb5	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	bd33b8f4-d6d5-409f-830f-47294e5461d1	23a45e41-edc7-4e6f-8b38-1f779b1d59dd	BLUSA CROPPED SPOT TREVOS - AZUL MARINHO (P)	1	119.90	119.90	AZUL MARINHO
dd33a0db-00de-434e-a949-9b7bc5638f4a	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	1a77ad94-37c6-4d5d-9a18-ab679cb39175	7c06bfa8-aa3c-4ef4-b453-ac03480fcdce	BERMUDA COM BOLSOS E ESTAMPA - VERDE CÍTRICO (M)	1	349.90	349.90	VERDE CÍTRICO
0d340188-9535-449e-8694-e6fbf139eb78	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	a6368ef1-e4ce-40d1-b616-fb9693a14a0e	085aedb2-45c1-446e-9eac-a14c5c46b69d	T-SHIRT TULE LISTRAS - BEGE CREMOSO/VERDE CÍTRICO (P)	1	219.90	219.90	BEGE CREMOSO/VERDE CÍTRICO
f91548c2-71e7-4b3d-9ab3-2b6b08bb5cf2	40757cf5-57b0-47c1-9b20-84af21d31c08	a2e9454e-e59e-4c92-aa00-0cf93c3ea168	948f6425-996e-400b-b9be-071a1d7269fd	LEGGING RECORTE ASSIMÉTRICO - Preto (M)	1	429.90	429.90	Preto
68cfdf8e-cfaa-480f-b3dc-76bbe8387071	40757cf5-57b0-47c1-9b20-84af21d31c08	6e056781-f22f-4806-bdde-c66288659526	eb1f3f57-3db5-44b5-89df-c43d00cb6180	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID - C0001 - BRANCO (M)	1	189.90	189.90	C0001 - BRANCO
817ddbe8-5bef-47bb-9219-2ddfc964fa56	44ce3879-2819-478a-9084-f15785c0e5fe	a107e628-ba0d-4207-92e8-7bd844beca8c	2a2e9ab8-8c16-4733-9977-57f892f070e2	SHORTS SHAPE UP MATCHPOINT - VERDE HÓRUS (P)	1	217.00	217.00	VERDE HÓRUS
9c193260-e794-4148-b402-dab7bdfd5786	44ce3879-2819-478a-9084-f15785c0e5fe	1dc8aebb-9216-4bf4-934e-526e32fa7d8f	fcb0a333-bb18-4bda-a48e-15b587e4146f	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - VERDE HÓRUS (P)	1	217.00	217.00	VERDE HÓRUS
f7def2c5-4e54-4a92-88ae-306e77fe1eef	0a3b2e63-431d-46e9-a313-6a8f945dec90	bf164b87-cfad-4bb6-9885-0b40b4857ed4	f269a319-db12-4fd7-9fa3-14660b6edc87	TOP REGATA NADADOR - VERMELHO RUBI (M)	1	399.00	399.00	VERMELHO RUBI
c82b3487-09cb-4cd9-bda4-cf4d2db511f7	0a3b2e63-431d-46e9-a313-6a8f945dec90	2adfffdd-1e23-4800-a123-f0ddadd83cf9	b02ea989-7c63-4187-83b7-b3f048e51c1c	SHORTS COM RECORTE E ESTAMPA - VERMELHO RUBI (M)	1	279.90	279.90	VERMELHO RUBI
7e33cf1e-1042-4de0-ab9e-8ad109fd39fd	0a3b2e63-431d-46e9-a313-6a8f945dec90	1eb39472-4b0e-4753-b75b-8187024d77d2	81502d34-8d77-41ca-a424-d68904ab43f8	BERMUDA FITNESS SELENITA - CINZA CLARO/ROSE ESCURO (M)	1	215.00	215.00	CINZA CLARO/ROSE ESCURO
392b6973-ae9a-4207-b777-6a8ffc09c77a	0a3b2e63-431d-46e9-a313-6a8f945dec90	c2ad6656-55cd-4bfb-a495-71b04535a657	9ff493a7-606d-49fb-a621-bb6462d7d8bf	TOP FITNESS SELENITA - CINZA CLARO/ROSE ESCURO (M)	1	160.00	160.00	CINZA CLARO/ROSE ESCURO
f8ca5c05-c5e5-4a87-ba9d-15d31aa402fa	ad3c7cc7-2684-49af-afc5-88c0bd35469a	1ff8c188-c391-4884-82fb-fb90ea649d97	a146a76b-353e-43d3-a206-71a0d5b1baf9	LEGGING FRISO CONTRASTANTE - VERMELHO RUBRO (G)	1	369.90	369.90	VERMELHO RUBRO
85760fbb-69a8-4f0f-8927-db768488fe06	ad3c7cc7-2684-49af-afc5-88c0bd35469a	85197957-d929-4d27-b954-d7ace210e9f1	37e5bd95-7a2e-4a97-9029-f40dc1241ed9	TOP DECOTE V ABERTURA COSTAS - VERMELHO RUBRO (G)	1	259.90	259.90	VERMELHO RUBRO
4fc3d753-a5a5-4145-b2bd-091f2c52d89f	ad3c7cc7-2684-49af-afc5-88c0bd35469a	76e1779f-f72d-4903-88a4-df32c0ddbf7a	1acf659d-4679-4407-b7c0-d2f56d142df9	LEGGING LINEA SHAPE UP - MARINHO ESCURIDÃO (G)	1	269.90	269.90	MARINHO ESCURIDÃO
e027934d-c5b2-4499-9f74-6680556f8cb7	ad3c7cc7-2684-49af-afc5-88c0bd35469a	e40245f6-771f-4c75-8131-58d2766506c8	a3e970dd-b90c-4ab7-b46a-79c0e54518cc	TOP LINEA MÉDIA SUSTENTAÇÃO - MARINHO ESCURIDÃO (G)	1	179.90	179.90	MARINHO ESCURIDÃO
d185f733-4239-492e-acbf-5602779059e1	ad3c7cc7-2684-49af-afc5-88c0bd35469a	9fd20c26-5d5b-4b11-80e5-ecf884019976	d16780dd-b03a-4966-bba6-a73e42771b6a	Regata Helena - Marinho Escuridão (G)	1	189.90	189.90	Marinho Escuridão
d2887fca-038e-4078-9f07-63a1260caea7	ad3c7cc7-2684-49af-afc5-88c0bd35469a	0d3caf74-bd91-49de-aaf0-35021ed180d3	dbe4c0cf-48a8-4b4b-aaf9-0139801f9d59	COLETE DRY FIT INTENSE - Preto (G)	1	199.90	199.90	Preto
be12bb68-402a-4f19-ada1-e836d7d38b6d	ad3c7cc7-2684-49af-afc5-88c0bd35469a	461a481e-12a3-4373-8ddd-cb410748e9cd	60c3c3d7-1e4d-43fc-b992-6244ec274848	TOP SUSTENCAO ALCA REGULAVEIS - PRETO (M)	1	299.90	299.90	PRETO
678cb169-4ec6-43ab-8f94-95ea989860c5	249b3b88-6270-4615-8765-b1ebcaded45e	b67f9c47-62d1-4363-9597-ff40721fa5fb	a0dbb204-8a04-4b4a-ac6b-950b1bc3136d	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - MARROM COURO (M)	1	217.00	217.00	MARROM COURO
72031481-9c2a-44b0-b43b-e29844c36ff5	249b3b88-6270-4615-8765-b1ebcaded45e	468a8286-c41a-4042-83b0-95d393857dc1	47f3362e-12bf-4ff7-8de3-79b83ecd570e	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - ROSA CALMY (M)	1	217.00	217.00	ROSA CALMY
fabda92b-87cd-411d-a5d7-39e618f21b64	249b3b88-6270-4615-8765-b1ebcaded45e	9a488d37-920c-4249-815c-4998efd3fcbe	d48d6fae-a2e0-4ac3-8953-e29637d01d66	LEGGING SHAPE UP MATCHPOINT - MARROM COURO (P)	1	337.00	337.00	MARROM COURO
2105f560-65bb-47c3-9ab0-a7886648db2a	249b3b88-6270-4615-8765-b1ebcaded45e	1dc8aebb-9216-4bf4-934e-526e32fa7d8f	4b9e195e-689b-45e0-96ba-2058b0587984	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - VERDE HÓRUS (M)	1	217.00	217.00	VERDE HÓRUS
c1a8e24d-6469-4f97-b9e2-974caa4e76cb	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	e5e74ca4-e1d2-4f50-9561-d28d3b586d8a	3f939022-d89a-4472-ad52-c69886e6ace5	Legging Recortes Com Bolsos Laterais - Preto (M)	1	320.00	320.00	Preto
8d1a1f00-9ae4-4cb6-8b7b-db90ac146c65	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	11f5db23-1e55-4980-a635-41fc0cf50d93	c8555d6b-4279-4d02-925f-fb1f7892d2e8	TOP DECOTE V ABERTURA COSTAS - PRETO (M)	1	259.90	259.90	PRETO
54bc779a-3300-47c2-aa33-e2d14ad06ccb	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	468a8286-c41a-4042-83b0-95d393857dc1	47f3362e-12bf-4ff7-8de3-79b83ecd570e	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - ROSA CALMY (M)	1	217.00	217.00	ROSA CALMY
96e9bdeb-2626-496f-8aab-b845e979dccf	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	20cb8218-2234-4f5b-8833-7a0ba8901c84	53cb7068-1bf5-48a1-89d7-f0c80dd4e6fb	LEGGING SHAPE UP MATCHPOINT - ROSA CALMY (M)	1	337.00	337.00	ROSA CALMY
0019b125-6091-4835-998f-a04651a878dc	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	bf164b87-cfad-4bb6-9885-0b40b4857ed4	f269a319-db12-4fd7-9fa3-14660b6edc87	TOP REGATA NADADOR - VERMELHO RUBI (M)	1	399.00	399.00	VERMELHO RUBI
7babcd6f-b07f-4bc3-8230-7b68666f01f0	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	cf50944b-9c24-4253-b741-2e63beb82308	88abc986-c7b1-4c79-9596-daa27165d53f	LEGGING COM RECORTES E ESTAMPA - VERMELHO RUBI (M)	1	399.90	399.90	VERMELHO RUBI
0ec62dcd-ea21-4c6b-86f3-5ed3c7b360cc	addc5e67-13d8-4857-940f-6e558a2b229b	0e2ebee8-3f2d-4863-815d-13007b2ffe28	abc231dd-0139-461c-a741-515062cfbbf3	TOP MÉDIA SUSTENTAÇÃO CONTRAST - BEGE AMÊNDOA (M)	1	207.00	207.00	BEGE AMÊNDOA
84cd3f78-109b-48b7-8ad6-db9dddeed2e4	addc5e67-13d8-4857-940f-6e558a2b229b	4cfd28a9-7638-44cc-87a6-6c5b8531ec84	58c86c87-17cd-4205-ab2f-b7e1b2ea27d5	LEGGING CONTRAST SHAPE UP - BEGE AMÊNDOA (M)	1	277.00	277.00	BEGE AMÊNDOA
4314bb6f-e611-487e-8138-f90b84f17e88	c6c01c35-8188-4f75-af63-3eec540c1526	99bfb9d0-1cfe-45e4-a877-89b22f69ddec	d202b9d5-d328-4621-8353-50f1aac82609	SHORTS LINEA SHAPE UP - MARROM NUTSHELL (M)	1	159.90	159.90	MARROM NUTSHELL
9a4df773-c44c-4c1d-86ea-a45c974ed68c	c6c01c35-8188-4f75-af63-3eec540c1526	99b1f132-5dfd-4cd8-bce2-38f71d12a8af	38ccdc4d-f590-41d1-89e6-0fb9b543b455	TOP LINEA MÉDIA SUSTENTAÇÃO - MARROM NUTSHELL (M)	1	179.90	179.90	MARROM NUTSHELL
6861becb-c0a0-489d-bfcf-f0b3a8a36eef	c6c01c35-8188-4f75-af63-3eec540c1526	316e0847-fb38-4f8e-b27d-5674bd1666bf	d7e05527-d991-4d25-a671-d4543832cd5c	BLUSA CROPPED SPOT TREVOS - PRETO (G)	1	119.90	119.90	PRETO
79e8e13f-8704-49a6-a9c0-4ebdd40b06f5	c6c01c35-8188-4f75-af63-3eec540c1526	75289bf7-308c-49ea-9910-14a0f72c86f9	0679b4ab-e28e-4d01-91ea-653dee1a096a	TOP PARK SLEEK FIT MÉDIA SUSTENTAÇÃO - AZUL VINTAGE (M)	1	149.90	149.90	AZUL VINTAGE
18e101fc-f3a7-47c4-b7d6-6a9b329a45f9	c6c01c35-8188-4f75-af63-3eec540c1526	ecba77b4-5fbd-4ca9-a21d-8d73c77b5d27	c11d1034-60bc-4da4-97b5-3fe9b0819315	SHORTS SLEEK FIT SHAPE UP - AZUL VINTAGE (M)	1	219.90	219.90	AZUL VINTAGE
ad1ba03e-26c6-41dd-8863-a0762d9653be	ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	bf164b87-cfad-4bb6-9885-0b40b4857ed4	f269a319-db12-4fd7-9fa3-14660b6edc87	TOP REGATA NADADOR - VERMELHO RUBI (M)	1	399.00	399.00	VERMELHO RUBI
6857d2d1-54a8-4b6c-a336-d46ff872272c	ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	2adfffdd-1e23-4800-a123-f0ddadd83cf9	b02ea989-7c63-4187-83b7-b3f048e51c1c	SHORTS COM RECORTE E ESTAMPA - VERMELHO RUBI (M)	1	279.90	279.90	VERMELHO RUBI
679d7030-a96d-401d-89ab-2a0e3445f31d	ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	ec9ab5f4-7f9e-46f1-ab0d-f8530834b1ac	d06f4fbb-b575-423d-9060-fbbe3a652f3a	Top Nadador Essentials - Marrom (M)	1	198.00	198.00	Marrom
26c1b5bd-6106-4658-bbd3-c9d87aece55e	ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	cbc0b5ff-58a5-4680-9ae8-706846963470	b6777ac1-a3d7-4eca-910e-0e5df3c9e2d2	Legging Essentials - Marrom (M)	1	270.00	270.00	Marrom
9b1e5b5b-703f-497d-932e-50487a3e77ed	7878276d-05fa-402d-89a7-5b736e94df21	cda5a2f7-8a67-4766-bdd6-bbc712cad09b	cb16b25d-4e95-488b-b5ab-a7d83264c334	Blusa Tule Básica - Branco (G)	1	139.90	139.90	Branco
ff5fe3b4-fddd-43a3-a1c2-4d591063e1cc	7878276d-05fa-402d-89a7-5b736e94df21	59c41dec-c3db-4783-9036-f32b38162602	337dae1b-7048-47bb-8a5c-d5b051dee765	Bermuda Fitness Montana - Vinho Barolo (G)	1	209.00	209.00	Vinho Barolo
07ceeb57-e56f-4d03-bcb4-eebafc411407	7878276d-05fa-402d-89a7-5b736e94df21	89ee27b6-e12c-48ee-bf00-722b97a38220	e965c682-05a6-4c7d-8f17-e1d25d5abe56	Short Fitness Street Bolso - Branco (M)	1	239.90	239.90	Branco
83d477e5-99e8-400e-a48d-d5335ba7b65e	8289852a-5b57-43f4-ab76-6a856d472dae	bd33b8f4-d6d5-409f-830f-47294e5461d1	61f7dbb1-86a0-40c3-927b-1a0a1c4f6ec3	BLUSA CROPPED SPOT TREVOS - AZUL MARINHO (G)	1	119.90	119.90	AZUL MARINHO
a48d5ab9-5c08-47f0-b996-a4b39d74180d	49415213-6157-4937-ac75-7f612ded322b	9a488d37-920c-4249-815c-4998efd3fcbe	e57d9bf8-af93-44a9-8c79-a21b761180d3	LEGGING SHAPE UP MATCHPOINT - MARROM COURO (G)	1	337.00	337.00	MARROM COURO
63b9571d-ee16-4f0c-a3b6-6c5ac9acdcc6	49415213-6157-4937-ac75-7f612ded322b	b67f9c47-62d1-4363-9597-ff40721fa5fb	399aafa0-b3fe-42b4-bcb2-570cb6dff3a4	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - MARROM COURO (G)	1	217.00	217.00	MARROM COURO
f174d0c8-fcb1-4a4b-902c-462d5f7cca52	661a2cdf-aaad-4d4e-acdf-986f971d731e	9a488d37-920c-4249-815c-4998efd3fcbe	d48d6fae-a2e0-4ac3-8953-e29637d01d66	LEGGING SHAPE UP MATCHPOINT - MARROM COURO (P)	1	337.00	337.00	MARROM COURO
645814c2-c414-414b-bc49-5266e149e4f5	661a2cdf-aaad-4d4e-acdf-986f971d731e	b67f9c47-62d1-4363-9597-ff40721fa5fb	ba4ab98b-684a-4d4c-ab17-0d6a3ad5a7ed	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - MARROM COURO (P)	1	217.00	217.00	MARROM COURO
8dcc31d5-5468-417e-b674-7237bb3959b2	0f63c759-5880-43f2-98f1-2932e52be8be	72307b52-03ee-438f-96d1-0d5ea050b9a5	6247138d-d9c4-4c64-abbf-0d916a02c5f7	TOP COM RECORTE E ABERTURA NAS COSTAS - PRETO (M)	1	259.90	259.90	PRETO
808916de-e759-4c93-ac68-158c7d32d4ef	0f63c759-5880-43f2-98f1-2932e52be8be	d389d258-964a-4d0e-b4ef-0387083ed1f5	d59c223a-5e65-4803-8c8e-30372a6ab15c	SAIA DRY SOBREPOSTA - PRETO (M)	1	229.90	229.90	PRETO
8b514a71-6194-436a-aa46-f17bb53d73f1	0f63c759-5880-43f2-98f1-2932e52be8be	ecba23cc-511a-45b8-85d9-27dc7cb8f0c4	b84fb933-537f-479e-94cd-d505268247f6	REGATA ETERNA CROPPED - VERDE CITRICO (M)	1	179.90	179.90	VERDE CITRICO
3a01d1bb-01c5-4c20-96cd-7c98b5a07052	0f63c759-5880-43f2-98f1-2932e52be8be	390efbab-b038-4088-9bd3-fdb4889b5ae7	0625571c-d980-48da-a6d5-9bc8543bac94	SAIA SHORTS ETERNA SOBREPOSTA EVASE - VERDE CITRICO (M)	1	199.90	199.90	VERDE CITRICO
cd1ddcc1-b635-4c2b-b0f7-bca93f9ea988	5fb759a0-739a-4fd1-a207-1712f5952fd7	c9f22b86-6bdb-47cd-9832-d47f617bd6bc	0d66f4a7-5370-471a-818b-b1aba224f865	Legging com Bolso e Estampa - Rosa (M)	1	329.90	329.90	Rosa
19181bc7-5214-4f1b-8126-16d1698765fa	5fb759a0-739a-4fd1-a207-1712f5952fd7	ef55c198-d3c5-41ce-afcb-a329e0f8865f	e510b82f-794f-4fc5-8b0d-694eda59843e	Top Média Sustentação Isis - Branco (M)	1	179.90	179.90	Branco
24bda208-98db-4f0e-8495-335c26495046	5fb759a0-739a-4fd1-a207-1712f5952fd7	26405f63-d9bc-48a6-b965-c6a5947af58a	567242f3-fbf7-4c33-b898-5da299762f14	Shorts Shape Up Bicolor Isis - Branco (M)	1	199.90	199.90	Branco
16fc8405-e8cd-4de7-b042-341ba311533c	5fb759a0-739a-4fd1-a207-1712f5952fd7	2ca91c0d-1c44-4b8b-83c7-35a12406f314	9d56baf5-d054-4bd0-8202-24f42974e871	Top Dupla Face - MARROM ANIS (M)	1	229.90	229.90	MARROM ANIS
cd6730bd-5e4c-45ac-8167-2d8b75bb2773	5fb759a0-739a-4fd1-a207-1712f5952fd7	7c051d7b-cdf7-4a19-aa50-9a0f6e308655	2b3e56f0-e679-4790-80c2-2be845e2016f	Top Fitness Nanny - Lilás (M)	1	209.00	209.00	Lilás
9767633d-d2f3-4029-b8b7-b19017018757	5fb759a0-739a-4fd1-a207-1712f5952fd7	8b1f499c-ee20-479e-8588-aa0811712935	afc619d5-dda1-4121-aec9-284bf43847c8	SHORTS 2 EM 1 ELASTICO - AZUL PISCINA (M)	1	349.90	349.90	AZUL PISCINA
8f17541b-0667-4a07-b946-fb253adff603	5fb759a0-739a-4fd1-a207-1712f5952fd7	c68f212a-8a4b-4d82-b22f-d56006f28c10	f64f3e40-e731-4197-87e3-9968eea5c8e8	TOP ELASTICO PERSONALIZADO NADADOR FINO - AZUL PISCINA (M)	1	199.90	199.90	AZUL PISCINA
6c540871-4c2e-43bd-9ad9-1d4444e11b64	5fb759a0-739a-4fd1-a207-1712f5952fd7	746529fd-29ba-4712-aa89-b7444bc978e3	b40cb1ca-263c-4a7f-98f9-5e1919ad0fbb	REGATA CROPPED RECORTE COSTAS - VIOLETA REAL (M)	1	169.90	169.90	VIOLETA REAL
ddbf73ff-69f6-48c0-b6db-f061a6ee40b0	5fb759a0-739a-4fd1-a207-1712f5952fd7	d495480f-e043-47f9-a70e-7b79eea14777	1a193382-f6d3-49a0-a4fe-43fcb616bb6f	SHORTS ETERNO COS ALTO AZUL CRISTALINO - AZUL CRISTALINO (M)	1	150.00	150.00	AZUL CRISTALINO
46b64f22-1b19-462f-b2eb-3d0d532fc012	5fb759a0-739a-4fd1-a207-1712f5952fd7	2a072449-b424-45a7-8b27-bd3d72d50dfe	1290cbd9-00b2-407d-9d07-4dc2b49dcf8e	TOP FRENTE UNICA DUPLA FACE COM SILK AZUL CRISTALINO - AZUL CRISTALINO (M)	1	270.00	270.00	AZUL CRISTALINO
93117a7e-6050-4ae4-a87d-76cb5a67023b	5fb759a0-739a-4fd1-a207-1712f5952fd7	0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8	fa6957ea-2a79-490d-b48d-e87ffd4ce8e2	Top Degrade - Rosa (M)	1	229.90	229.90	Rosa
af78851d-178a-4a35-925e-7d0dc866bd4f	5fb759a0-739a-4fd1-a207-1712f5952fd7	511252b4-4a5e-433a-ac9d-e31fd182144a	cd2dc712-8b2e-4c97-81de-1ceb232d08e4	TOP ELASTICO PERSONALIZADO ALTO GIRO - BRANCO OPTICO (M)	1	229.90	229.90	BRANCO OPTICO
415aecaf-dac9-41a4-8236-aa097105a048	5fb759a0-739a-4fd1-a207-1712f5952fd7	230c38d0-2506-44ca-a39a-564d5e06e802	dd821152-f254-4045-b363-bbfad44264c0	BERMUDA ELASTICO PERSONALIZADO ALTO GIRO - ROSA BAUNILHA (M)	1	219.90	219.90	ROSA BAUNILHA
8f377a08-a3df-408d-a291-e8276b005e59	5fb759a0-739a-4fd1-a207-1712f5952fd7	8d6da76c-03ee-4bc0-a8b0-a49424b4dee3	dfa20af5-fb85-4b7a-bb8a-9d0c2c0e73b2	TOP NADADOR ELASTICO PERSONALIZADO - ROSA BAUNILHA (M)	1	229.90	229.90	ROSA BAUNILHA
f7072ee7-9b4a-4ef4-8470-f5e80f20a6c2	5fb759a0-739a-4fd1-a207-1712f5952fd7	eeef784a-f4c3-49a4-b126-a4ff7cced463	1891fc6b-477f-450e-936b-58bde1c48678	BERMUDA ELASTICO PERSONALIZADO ALTO GIRO - ROSA AURORA (M)	1	219.90	219.90	ROSA AURORA
e5448213-16a1-4a59-a089-da5385b4f83f	5fb759a0-739a-4fd1-a207-1712f5952fd7	bd62d0cf-146b-4d56-9621-244e4e5352cd	1bd5cfd0-ce66-482b-8b68-1e2881f8b14e	TOP NADADOR ELASTICO PERSONALIZADO - ROSA AURORA (M)	1	229.90	229.90	ROSA AURORA
62c3a267-46b9-4a9e-bd49-ac8ef9d5fe9a	5fb759a0-739a-4fd1-a207-1712f5952fd7	1ff8c188-c391-4884-82fb-fb90ea649d97	17e3fdc4-3d00-48e3-825b-02fe474d9362	LEGGING FRISO CONTRASTANTE - VERMELHO RUBRO (M)	1	369.90	369.90	VERMELHO RUBRO
4359541d-48c4-414d-b65d-2698e70f41c0	5fb759a0-739a-4fd1-a207-1712f5952fd7	85197957-d929-4d27-b954-d7ace210e9f1	f133d26b-b48e-4334-b4fc-a2196a5e3b46	TOP DECOTE V ABERTURA COSTAS - VERMELHO RUBRO (M)	1	259.90	259.90	VERMELHO RUBRO
32b042e7-9bd0-471e-b6e7-b0349a3443c3	5fb759a0-739a-4fd1-a207-1712f5952fd7	37f7c903-b6a5-4451-9584-37760953d250	27e71a0c-b129-4441-931c-1846146781ac	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO - Branco Optico (M)	1	229.90	229.90	Branco Optico
1bedc284-a2aa-4959-9e15-d6b113a18adf	47652497-0be9-468b-975b-ade0ca3410df	75e05685-9baf-46cd-82f8-e02a4083bcf9	57cb77dc-031f-4053-87ed-6f0945fcb9ca	LEGGING ELASTICO PERSONALIZADO - AZUL VINIL (G)	1	329.90	329.90	AZUL VINIL
a81e6d45-a5e6-42f0-b32e-b3ef5709b1e4	7f7f4cdb-8718-4d55-8dfb-84d032f82b13	dc407b2b-d84b-4554-831b-795e0716bdbe	653ea9bb-38de-4b2e-b874-cf850b6d2775	CALÇA LEGGING CELESTIAL - AZUL BIC/AZUL CARIBE (G)	1	235.00	235.00	AZUL BIC/AZUL CARIBE
f76f44b1-1873-4f7c-abac-0e494b5c7de5	7f7f4cdb-8718-4d55-8dfb-84d032f82b13	e4d0e600-15d1-45b5-9391-240739862804	d5b608ff-d7e5-4aec-adb8-4f0216a55094	TOP FITNESS CELESTIAL - AZUL CARIBE (G)	1	160.00	160.00	AZUL CARIBE
940e7358-75bc-42ba-a0b7-5665f9f3dfb8	0b156dab-8965-4358-a6da-7e598e3ce2d9	0d252391-9224-48a8-8ec9-dd9cbcb683e4	c50700e6-efb9-4e92-8731-a9f9c240f23f	LEGGING ELÁSTICO AG WAY OF LIFE - VERMELHO RUBRO (P)	1	369.90	369.90	VERMELHO RUBRO
0950479d-a1c0-44cc-98fe-3a576464d933	0b156dab-8965-4358-a6da-7e598e3ce2d9	001a4eee-5381-447d-8b59-5795bded7918	25a5d914-3310-420f-b800-a76be89d2ef8	LEGGING DETALHE CONTRASTANTE - VERMELHO ROSADO (P)	1	369.90	369.90	VERMELHO ROSADO
be17efc9-92c5-4f50-875e-382ce2a36b2f	0b156dab-8965-4358-a6da-7e598e3ce2d9	2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7	e801fb7d-de70-43a4-a6d2-9ac34a1a46fa	LEGGING ELASTICO PERSONALIZADO - BRANCO OPTICO (P)	1	329.90	329.90	BRANCO OPTICO
cc1741a0-f062-451e-83d8-a682cc73dec1	0b156dab-8965-4358-a6da-7e598e3ce2d9	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248	04c4f56e-c091-4ec9-958a-4d0cfa3577e7	LEGGING DETALHE CONTRASTANTE - MARROM NOITE (P)	1	369.90	369.90	MARROM NOITE
dde66184-95d7-4112-9a82-1351e309c0a4	0b156dab-8965-4358-a6da-7e598e3ce2d9	d6fac8fe-af98-491e-97fb-8a6891baab68	2ad4b5cd-d1a5-4a7d-aa42-09d035b0ea85	LEGGING BOLSOS E ESTAMPA - LARANJA PÊSSEGO (P)	1	359.90	359.90	LARANJA PÊSSEGO
3d04d775-903a-4ba0-8a6e-23cb8ad50e98	0b156dab-8965-4358-a6da-7e598e3ce2d9	0bfa8bd6-dbed-482c-9fb1-8b2475c62d01	ddb7fdae-e69d-46b9-9183-cd83ce5f7920	LEGGING RECORTE ASSIMÉTRICO - Azul Noturno (P)	1	429.90	429.90	Azul Noturno
345a0c7d-7735-4e1f-bd0f-d5988a8f6ff1	0b156dab-8965-4358-a6da-7e598e3ce2d9	03b2fc1c-cf16-4880-872f-05e52f9f882b	3a6c1861-c427-4d42-961a-7fa27793ba4c	LEGGING SPORT WAY OF LIFE - PRETO (P)	1	329.90	329.90	PRETO
0b740491-2421-4cba-9a79-416d656f7af8	0b156dab-8965-4358-a6da-7e598e3ce2d9	3461894e-b04c-4295-8c83-17ee8bcac3f7	0bb72f89-aa0d-4329-af2f-155b1a47b0e3	JAQUETA CULTIVO - OFF WHITE (M)	1	249.90	249.90	OFF WHITE
5c8cbea5-4e6a-4430-9aac-a5ba23f60936	0b156dab-8965-4358-a6da-7e598e3ce2d9	a76afd4d-507a-49bc-816b-4d7d3f5a3a69	6cdb1b7f-bf3b-4cdc-8191-e8b9bce53c09	Jaqueta Mellow EveryPush - Amarelo (M)	1	222.99	222.99	Amarelo
a90d7e21-aa7d-492b-9d07-d61341e17afb	af0ccc75-7300-4f7d-a066-f56be7d19fb5	25cdeb8b-57a6-49cc-a961-473a1ce9ba6c	42aac000-d0c3-4bc0-8ebe-ab6ac601017a	LEGGING NP ADAPTIV EMPINA BUMBUM COM BOLSO - VERDE MARINA (M)	1	357.00	357.00	VERDE MARINA
c78da3a2-5005-4102-8063-c7a168ba1b71	af0ccc75-7300-4f7d-a066-f56be7d19fb5	cce759a5-641c-41dc-bf2d-be4339c668ce	718a833a-da5e-46d8-8f58-d7e45791fde7	TOP NP ADAPTIV - VERDE MARINA (M)	1	237.00	237.00	VERDE MARINA
78a43072-8f1b-4390-bac4-d016c2d4c25c	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	d90522e9-5428-43fc-98c4-a917b3e127a4	1ad33c8d-7d2f-4935-ad81-eb7de939222b	BLUSA UV CLÁSSICA - MARROM SIENA (M)	1	167.00	167.00	MARROM SIENA
e40e1683-16d6-4dfa-8312-ea57927e0951	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	f4fbf33a-b258-4b0e-a0da-d62990868a2e	2714d8bb-74b0-444f-9d1c-deab9d089cab	TOP ALÇA FINA PROTEÇÃO SOLAR - MARROM SIENA (M)	1	217.00	217.00	MARROM SIENA
33750d66-2b27-4240-8ba6-f551857e0a49	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	97eee61f-35ac-4a7b-a1ac-4d2d25327ecd	38bf25a4-9901-4d6a-8e2d-84b3d7de6b20	LEGGING CÓS INVISÍVEL COM BOLSOS - MARROM SIENA (M)	1	357.00	357.00	MARROM SIENA
815374d1-d583-42b4-9059-eb4548474ce6	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	44b4578a-2b74-4bf9-885c-c28036067785	ff85e743-74ff-4980-a5c3-12e837cf6716	LEGGING CÓS ALTO COM COMPRESSÃO - OFF WHITE (M)	1	397.00	397.00	OFF WHITE
fd9fdfe1-e2f4-496c-8fff-c696e5d3faef	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	accf8762-30d5-40d7-8a30-e1162f37f44d	a815d039-b643-40b9-891c-9b21a6f56ecf	TOP ALÇAS FINAS COM COMPRESSÃO - OFF WHITE (M)	1	237.00	237.00	OFF WHITE
999c8e36-8a05-4eb5-9b01-2ed69f2abe02	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735	c3949965-2005-4f23-9189-31068e7da0ec	BLUSA MANGA CURTA DRY FIT ZADAR - C0280 - VERDE MENTA (M)	1	159.90	159.90	C0280 - VERDE MENTA
1239b3f7-e660-4242-abfb-f9f52162d09d	067ac8b8-86a5-4710-9142-2277faccc67f	aaba247b-5e6f-45d6-8138-7f6c2154f2bd	85696341-d5ca-4ed1-9f38-0d7f97dfd336	BLUSA CROPPED SPOT TREVOS - ROSE (G)	1	119.90	119.90	ROSE
f8a264a0-eaab-4b54-a921-d4163e94d532	9b9885a5-a11b-4ee2-a68e-252311e8d49f	e0e8cdbf-efac-41fb-9b4d-981f769482e3	21dc7602-8646-441f-9c73-43c810424a9d	LEGGING ESPORTIVA COM BOLSOS - PRETO (M)	1	337.00	337.00	PRETO
afee6917-dc8f-4265-afca-ceaf7f61bc57	9b9885a5-a11b-4ee2-a68e-252311e8d49f	08cef4f7-a38c-4f00-8708-d10461e8496d	64accefa-150a-407f-b09e-efb5803ac0e6	TOP SOBREPOSIÇÃO COM PROTEÇÃO SOLAR - PRETO (M)	1	197.00	197.00	PRETO
8056b1b7-ce9a-4797-a884-d0222a4be4e4	be56aead-81ef-4271-be5b-76124e0d348e	12e3378b-1df5-487e-9e56-8e49bfb780df	7b4c7718-7125-4974-9344-b1b21bb41cce	Colete NYL - Verde Oceano (P)	1	297.00	297.00	Verde Oceano
77ca18b3-4dfe-46a3-8d98-78a4b23f1b1b	aa0a4526-e1b1-4a62-bfc4-d1e091e95891	cec93d51-6aeb-484f-a139-cac515ba14c9	bb07c323-a2e1-4eae-8c6c-bc19cd661351	BOMBER TEBAS - Branco (P)	1	249.90	249.90	Branco
a2e28711-faf8-4b63-9af3-6a37ea686daa	cd0b0dcc-5ca3-48f7-90f5-a8590cc26251	b1a76627-8254-44af-aaf5-99dd25c780d3	7aa1b0f2-bacc-4e26-ac40-5f8ed00a7337	Short Fitness Street Bolso - Azul Bic (G)	1	239.90	239.90	Azul Bic
4610d5bc-4e05-4845-a8d5-00f0c92edc56	cd0b0dcc-5ca3-48f7-90f5-a8590cc26251	75c94f89-3b69-470b-a567-ad924d9604f3	5fff32d1-7833-4fc0-9e46-ed9fce89b3da	Top Fitness Summer Liso - Azul Bic (G)	1	169.90	169.90	Azul Bic
bd72f582-5a6d-4443-a325-9268d2d6ea3f	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	aef9392c-32a9-4613-820e-af62ff4bf67a	e6d768ae-7f68-452f-85da-1fc2d0d627d2	TOP ADAPTIV ELÁSTICO PERSONALIZADO - LARANJA FLOW (M)	1	277.00	277.00	LARANJA FLOW
96734035-a6a9-403c-acb9-2794ec0a56d4	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0	c899e4e5-3dff-4cb5-8e97-f55953604a77	LEGGING ADAPTIV BOLSO CÓS - LARANJA FLOW (M)	1	367.00	367.00	LARANJA FLOW
c014527f-8bc0-4a3a-9099-0c78475f568c	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	8ae0556d-3282-40e2-91d9-32b84108bb97	1a91386f-598c-4f95-b61b-f07e69aa61ac	MACACÃO FITNESS ORQUÍDEA - MARROM CACAU/BRONZE BÚFALO (M)	1	429.90	429.90	MARROM CACAU/BRONZE BÚFALO
24549ee4-651d-42eb-bcb0-8baf96bdf044	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	8c82a054-9bcc-4286-b55c-aa974443ad8e	91f23387-601c-49c2-91a7-1bf12a3a91f1	MACACÃO FITNESS XANDA - ÉBANO (M)	1	399.90	399.90	ÉBANO
11b486c1-987c-49c0-89b4-0b9c48d1fdd6	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	cb20910e-33f4-4a25-8495-2d2233e0c65a	38228d5d-fe4b-47f1-90be-128691f9b9c9	LEGGING ADAPTIV COM COMPRESSÃO - VERMELHO MORANGO (M)	1	357.00	357.00	VERMELHO MORANGO
3cc0b01f-4027-42a8-866a-42404761ead8	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	dff7d74a-6295-417b-8ef6-c5e21d66f7a0	9b0faed0-8618-474a-85ad-2edf35ff1e8d	TOP ESPORTIVO SUSTENTAÇÃO - ROSA OLINDA (M)	1	297.00	297.00	ROSA OLINDA
c98be8f8-38be-4bb8-bcab-f23db326894b	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	bfd9dd8a-d38d-4e9e-a50c-55621630213c	8a85c55d-22f5-441b-9597-adcf19d80828	\tBLUSA CROPPED SPOT TREVOS - Roxo Deluxe (M)	1	119.90	119.90	Roxo Deluxe
a68ad958-34e7-4367-bdb5-d192c0de0455	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	3162db89-c536-455c-b655-c709782f43bc	285bccbf-599d-44a7-a2a9-5aa966b02dca	LEGGING ATLÉTIKA CÓS INVISÍVEL DUPLO BOLSO PARA CORRIDA - ROXO FIGO (M)	1	327.00	327.00	ROXO FIGO
2fa99cc9-4b16-4044-90a6-94e79a6bcb67	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d	adcc36b0-b687-4eb2-adb2-5b2b47a69a95	TOP CROPPED ATLÉTIKA COM BOLSO - ROXO FIGO (M)	1	257.00	257.00	ROXO FIGO
e5bb1c3b-5e28-4555-ac92-9958de5f98c6	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	ad7a7d20-ddb6-464e-9cab-000213aef72c	b7696686-67cf-4d53-bb54-7bf12aa0ee09	LEGGING CÓS ALTO COM COMPRESSÃO - PRETO (M)	1	397.00	397.00	PRETO
b1f24416-047b-4362-bcd3-9384f7bb94cf	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	a5d189a1-aeef-4619-846e-37ef41dc8aae	1c83eb18-3a55-494a-b790-abce3692ae22	TOP ALÇAS FINAS COM COMPRESSÃO - PRETO (M)	1	237.00	237.00	PRETO
bb718f9b-20cb-4e68-a50e-7ca158708769	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	12444a33-e5d1-4837-bbe5-b0b6bd5102c5	04fa7fde-32d8-445c-8e27-2d65ab134da9	LEGGING ESPORTIVA COM BOLSO - ROSA OLINDA (M)	1	357.00	357.00	ROSA OLINDA
26cae1b9-d647-4d27-bf32-8316162ab469	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	99bfb9d0-1cfe-45e4-a877-89b22f69ddec	d202b9d5-d328-4621-8353-50f1aac82609	SHORTS LINEA SHAPE UP - MARROM NUTSHELL (M)	1	159.90	159.90	MARROM NUTSHELL
47f90481-9b5c-470e-8794-c872b6dd911b	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	99b1f132-5dfd-4cd8-bce2-38f71d12a8af	38ccdc4d-f590-41d1-89e6-0fb9b543b455	TOP LINEA MÉDIA SUSTENTAÇÃO - MARROM NUTSHELL (M)	1	179.90	179.90	MARROM NUTSHELL
0a27be43-bd6c-4ace-b0c3-94c4bacf9917	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	b67f9c47-62d1-4363-9597-ff40721fa5fb	a0dbb204-8a04-4b4a-ac6b-950b1bc3136d	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO - MARROM COURO (M)	1	217.00	217.00	MARROM COURO
aab72e9c-88bc-4fc1-a29c-9219431d1b5f	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	9a488d37-920c-4249-815c-4998efd3fcbe	d7c53e61-e097-477e-88f1-2caa0e5ae5e8	LEGGING SHAPE UP MATCHPOINT - MARROM COURO (M)	1	337.00	337.00	MARROM COURO
9c40cd7a-ef2e-416d-8f25-8fbbfae42928	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	1ab57614-5f36-4656-a86d-8dab0ab7f111	74180736-bd1b-4dd0-8276-00e85d159590	Blusa Cropped Summer - Lilás (M)	1	177.00	177.00	Lilás
24759f36-a435-4836-9392-00ece68df6a7	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	a85fa1e4-9f26-4268-98b7-23ef8bac47a4	2f5b42ae-d1a7-46aa-a12d-0327ab589f64	Blusa Cropped Summer - Verde Claro (M)	1	177.00	177.00	Verde Claro
f62c43ad-3492-4c20-9cc2-7fcb78428dc9	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	f5308cd0-0f94-41a1-af0e-2ea227cf90d3	636691b5-9d3b-4417-acf5-10ff93e45b14	Short Fitness Summer - Lilás (M)	1	197.00	197.00	Lilás
b3bbe3b4-b9a3-4766-a2a8-b9e4d698e2c2	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	15f80495-da76-4b3f-ae33-ea1ac43890f3	1c708ad0-8e27-4f98-8046-dd86ff6695d8	Short Fitness Summer - Verde Claro (M)	1	197.00	197.00	Verde Claro
b5b20032-a489-4071-a420-c6e3bb7c9fbe	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	71078803-21e1-480a-a0b3-680bdc73e027	7d6f926f-f9d5-445c-b04d-dcd04e807d58	Top Fitness Summer Liso - Verde Claro (M)	1	187.00	187.00	Verde Claro
1896336b-b280-4898-9abf-c6915a6d2de8	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	dbc7eb53-e7db-49a6-9432-998937c2f04f	016dc6eb-8503-4713-8ac1-3cc611b87055	Top Fitness Summer Liso - Lilás (M)	1	187.00	187.00	Lilás
af2ee463-9b2d-46e4-8897-2fb8015323c2	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	847242be-5ae1-4357-b0f9-03a500793cb3	dea91b53-f126-46b8-9b27-2a56d64ad930	Short Boxer Boom - Preto (M)	1	257.00	257.00	Preto
0d304708-ad70-4b7d-b111-88f9cafbf7f2	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	968eed0e-6f20-46e0-b3a7-24be0a7003f4	72d70a5a-ff4e-4fea-9c3a-c94a84c4a73d	Top Fitness Summer Liso - Preto (M)	1	187.00	187.00	Preto
60c72504-e787-43a6-a83d-2f2f3cea8700	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	28f8967b-ef7d-43c1-8aad-ccfe909953e7	6c745069-7cf4-404f-a043-e91f10502e6b	Blusa Cropped Boom - Preto (M)	1	177.00	177.00	Preto
c9a2dc39-a9d2-4321-a7e8-a746a6f6547e	69d88638-e460-442b-9ae8-7fafd2ac5d1b	12444a33-e5d1-4837-bbe5-b0b6bd5102c5	5b31ab0e-47e6-4b6b-a1ce-447770c0eaf4	LEGGING ESPORTIVA COM BOLSO - ROSA OLINDA (G)	1	357.00	357.00	ROSA OLINDA
702266fc-cd3e-4ccc-8b45-c06a812ad7a9	69d88638-e460-442b-9ae8-7fafd2ac5d1b	dff7d74a-6295-417b-8ef6-c5e21d66f7a0	060f422e-fb42-4d20-b144-5c9cecec8a8f	TOP ESPORTIVO SUSTENTAÇÃO - ROSA OLINDA (G)	1	297.00	297.00	ROSA OLINDA
d8c6d625-62b6-40a5-9077-8285a4af6326	69d88638-e460-442b-9ae8-7fafd2ac5d1b	3162db89-c536-455c-b655-c709782f43bc	e5b33fa6-09ae-46d0-9e0e-501397d22bd2	LEGGING ATLÉTIKA CÓS INVISÍVEL DUPLO BOLSO PARA CORRIDA - ROXO FIGO (G)	1	327.00	327.00	ROXO FIGO
b5f8fb47-814a-4b94-a42d-9c02e0889790	69d88638-e460-442b-9ae8-7fafd2ac5d1b	cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d	be55417f-66a7-4edc-bd5d-40713af78353	TOP CROPPED ATLÉTIKA COM BOLSO - ROXO FIGO (G)	1	257.00	257.00	ROXO FIGO
8dfd473b-2754-4736-974d-aac0dcb99fa8	69d88638-e460-442b-9ae8-7fafd2ac5d1b	508022e6-0d24-4d5b-a11c-f8422dbf85b8	7f947c21-5111-463e-9ddb-36d3b98ddfc7	LEGGING CÓS BICOLOR DETALHE ESTAMPA - ROXO INTENSO (G)	1	369.90	369.90	ROXO INTENSO
bfe6a13a-9667-4416-964d-14b20bbc8241	69d88638-e460-442b-9ae8-7fafd2ac5d1b	3a7b5436-a329-48ed-841d-b103d2e3b4c9	d1992d20-f5e1-4d6c-8846-214a557e1e77	TOP SOBREPOSTO BICOLOR - ROXO INTENSO (G)	1	299.90	299.90	ROXO INTENSO
14fb10cf-2cf4-4147-b4f4-dd6fb87f3287	9765680c-d76a-4c5d-9b4c-2e186f210b43	12e3378b-1df5-487e-9e56-8e49bfb780df	4fc6a677-b548-4db6-8e33-90ad6e0078ab	Colete NYL - Verde Oceano (M)	1	297.00	297.00	Verde Oceano
0afb3dab-048f-4b9d-82f7-e871bfceb938	30274953-5922-4d2b-9972-e1db42931650	6dc84bb9-65fb-4f58-b048-a5c404b6c3ae	1d3b4649-3798-4fce-b520-11f96bf52a79	Calça Legging Apatita - Preto (M)	1	279.90	279.90	Preto
1252ebb2-f7e4-42ef-bd82-be5204d73115	0b39c086-50d5-4d9b-9f55-b219e6318742	a27d57a0-bc23-492a-9632-8082d16c7170	91ebd18e-ec62-487b-99f6-a80d132c5336	TOP NADADOR ELÁSTICO WAY OF LIFE - VERMELHO RUBRO (P)	1	259.90	259.90	VERMELHO RUBRO
edbb227a-3dfc-43ea-9cb0-2dddbe4587c7	0d5a22ef-78a9-4139-b8c2-c99e6a3fcde6	1d6c897d-8fd2-46ef-a23e-2a0f90e6f99c	2eeb224b-0f76-4aec-80d7-b7f5238dadb4	LEGGING DISFARÇA IMPERFEIÇÕES COM BOLSO - VERDE GALÁPAGOS (M)	1	297.00	297.00	VERDE GALÁPAGOS
0c5a6a7d-82d8-4718-ab1a-cb18a4776921	de8a6583-05af-4f2e-8cd9-ac2c4610d275	f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3	c79dc660-4f13-4af8-b89a-c03a5e68e9ce	LEGGING ELASTICO PERSONALIZADO - BEGE FRIO (P)	1	329.90	329.90	BEGE FRIO
0d5280b7-fcaf-44ef-8081-a5bd5303fc16	de8a6583-05af-4f2e-8cd9-ac2c4610d275	eafb3b17-fafe-4d6f-863b-b12a2fc6343f	421f6eb3-f13a-4eba-bac7-84790a6d1df1	TOP ELASTICO PERSONALIZADO ALTO GIRO - BEGE (P)	1	229.90	229.90	BEGE
fd342cb0-2c1c-45ad-84de-2742217660e0	fc41bd5c-40f3-415b-9ec5-24cd78e8a5d4	cc6ae999-7249-48b5-9450-f13d7ec9f8c1	53ac7a23-1934-44d6-943f-2109ac0ac42b	Bermuda Eterna Shine - Azul Marinho (M)	1	218.00	218.00	Azul Marinho
6ccd1f8a-8592-429e-be4e-6ee854170486	fc41bd5c-40f3-415b-9ec5-24cd78e8a5d4	c65bcd91-670c-46af-9dcb-d462ed643695	6d616edc-5de4-4020-9894-0a759fb90077	Top Shine Alcas Finas - Azul Marinho (M)	1	178.90	178.90	Azul Marinho
fcb214ba-facc-4144-a649-ff79cf22305e	22907bde-880d-4f8e-9584-4367d1582d0b	8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248	3287cf1c-1ac3-4a5f-86c8-5fdc9481a56a	LEGGING DETALHE CONTRASTANTE - MARROM NOITE (G)	1	369.90	369.90	MARROM NOITE
7eeffe17-3e45-4f5c-a01e-18b50d124a7d	46f01bfe-85a9-415a-b704-44ecf0c33c0e	ce60564c-7257-4134-ab7c-725150da593e	73d64d22-dc52-4ea2-8a57-bfd2320393b2	Regata Tule Celeste - Marrom Charuto (G)	1	129.90	129.90	Marrom Charuto
85c3b2f6-e7be-4d26-87e9-0102fd127edc	6311f079-8c03-46c5-81a1-e1ebc45c06b7	62bb5e2a-10dc-4edf-8d56-911c2a0fa863	939eb8a0-f0d3-47f0-9039-bead596f4a74	TOP ELÁSTICO PERSONALIZADO - Branco Optico (G)	1	229.90	229.90	Branco Optico
d15bd03b-e205-4119-98b9-5c8588a087bc	bfbe41ce-d230-45fa-81e2-1c999afed65d	1dab11ed-3bae-4f22-b579-31737836d5ee	87d32685-edbe-4161-8cbf-13c3cfddcdb1	LEGGING ELASTICO PERSONALIZADO ALTO GIRO - PRETO (P)	1	329.90	329.90	PRETO
0051e160-3644-42e8-b129-008a1478204e	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	d2a91312-c159-4008-8b7c-4a927a059a72	23d322a7-904d-4743-aa94-9bff534a3959	BLUSA DE TULE ALONGADA - ROSA BALLERINA (M)	1	157.00	157.00	ROSA BALLERINA
3730b3a9-e9f4-453d-9ff1-e27ebc25b67c	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	43e8ffde-910a-4f0f-8852-595937f36838	f1979516-1ae0-46bd-acde-953a5a7da108	BLUSA DE TULE CLÁSSICA - LARANJA FLOW (M)	1	117.00	117.00	LARANJA FLOW
396b5c92-7a22-44b1-9fe1-976a081aa7ad	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	ed862ad2-431e-4dc0-9833-72c64ed5c9f1	9c6c9b59-1ab6-4bf8-872d-a278f657e65d	BLUSA DE TULE TRANSPASSADA - PRETO (G)	1	137.00	137.00	PRETO
8cb93fa0-2bd5-4ac3-822c-6762ed7c0cbf	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	9d9b17fc-6f19-459c-afff-e483755963a0	33af098f-8e7f-4168-9570-295c1cacce37	LEGGING CANELADA EMPINA BUMBUM - MARROM COFFE (M)	1	297.00	297.00	MARROM COFFE
f0aa330a-4b0a-45a7-be72-4ebda7bdc3b7	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	92eddced-cd4e-4310-b470-09f2a230b729	bcb7c95e-df54-471e-ac09-bbba9559e725	TOP CROPPED CANELADO ALÇAS DUPLAS - MARROM COFFE (G)	1	157.00	157.00	MARROM COFFE
\.


--
-- Data for Name: produtos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.produtos (id, codigo_peca, descricao, preco_compra, preco_venda, created_at, fornecedor, custo_frete, custo_embalagem, descontinuado, cor, foto_url, sku_fornecedor, fotos) FROM stdin;
d53f3a9f-4254-492f-a580-66a6d17dc9b4	UPF20266716	LEGGING NP COM BOLSO NO CÓS	139.00	337.00	2026-09-16 19:02:08.18294+00	CAJU BRASIL	0	4.62	f	LILAS MELISSA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266716_1789585325177.jpg	023.07200558P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266716_1789585325177.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d53f3a9f-4254-492f-a580-66a6d17dc9b4_1789585340750.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d53f3a9f-4254-492f-a580-66a6d17dc9b4_1789585350443.jpg}
24d8a866-2155-4fdb-9d96-d46c996b7b33	UP006	BLUSA DRY FIT MANGA CURTA DELFINO	49.95	129.90	2026-01-28 00:24:24.009431+00	Vestem	0	4.62	f	C0009 - AMARELO NEON	\N	BMC668.BF_C0009	{}
25cdeb8b-57a6-49cc-a961-473a1ce9ba6c	UPF20262879	LEGGING NP ADAPTIV EMPINA BUMBUM COM BOLSO	167.00	357.00	2026-08-31 23:33:04.705829+00	CAJU BRASIL	0	4.62	f	VERDE MARINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262879_1788219183343.jpg	025.06701209	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262879_1788219183343.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/25cdeb8b-57a6-49cc-a961-473a1ce9ba6c_1788225360049.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/25cdeb8b-57a6-49cc-a961-473a1ce9ba6c_1788238948434.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/25cdeb8b-57a6-49cc-a961-473a1ce9ba6c_1788238963172.jpg}
e37154ed-ab5d-4afb-a128-bf216c3f61e5	UP017	BLUSA MANGA CURTA DRY FIT ZADAR	63.90	129.90	2026-01-28 00:24:33.537567+00	Vestem	0	4.62	f	C0346 - ROSA SATIN	\N	BMC654.PE_C0346	{}
abf441fa-cbdd-4904-ba8b-65c70f37f53b	UP024	CALÇA LEGGING STORM EVERYTONE	128.10	198.28	2026-01-28 00:24:36.256323+00	Ange	5.56	4.62	f	Cinza	\N	LG18441/storm	{}
7dff2a36-5d91-4e59-bb59-5992219a424f	UP032	CONJUNTO SHORTS E TOP	119.90	249.90	2026-01-28 00:24:40.781992+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	\N	CJ250.PE_C0257	{}
263dd6e2-b4e8-403f-a36b-91fe37617d1c	UP033	CONJUNTO TOP E LEGGING FUSO MANU	159.90	329.00	2026-01-28 00:24:41.142947+00	Vestem	0	4.62	f	C0310 - PRETO/BRANCO	\N	CJ181.CP_C0310	{}
870ee767-6395-4972-a6df-842ec8e56163	UP034	FUSO COM BOLSO NO CÓS BREEZE	124.90	229.00	2026-01-28 00:24:41.513826+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	\N	FS1404.V25_C0257	{}
8f699409-f2a8-4435-8b0a-7dec0fe9f9ff	UP035	FUSO COM BOLSOS LATERAIS WAVES	129.90	229.90	2026-01-28 00:24:41.858319+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	\N	FS1255.V25_C0173	{}
5b0303c9-e6b0-49ef-b4ed-95f34b8378ee	UP036	FUSO COM FRISO ASTRA	119.90	229.90	2026-01-28 00:24:42.212676+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	\N	FS1422.V25_C0173	{}
6c4d8e31-0d88-4ce5-b5a6-6cd127c673f0	UP037	FUSO COM RECORTES AURORA	119.90	229.90	2026-01-28 00:24:42.553494+00	Vestem	0	4.62	f	C0301 - AZUL ENSEADA	\N	FS1431.V25_C0301	{}
1196c057-6651-4221-b508-168b34eae212	UP038	FUSO COM RECORTES MARE	139.90	239.00	2026-01-28 00:24:42.907486+00	Vestem	0	4.62	f	C0247 - LARANJA ZIG ZAG	\N	FS1025.V25_C0247	{}
753da075-b425-4017-a158-ffc3439080da	UP039	FUSO COM RECORTES MARE	139.90	239.00	2026-01-28 00:24:43.25011+00	Vestem	0	4.62	f	C0428 - ROSA ELECTRA	\N	FS1025.V25_C0428	{}
4b80ba74-7234-4662-b19d-5e730e7f9571	UP001	BERMUDA 5 PRO PRETO	159.90	340.00	2026-01-28 00:24:20.087115+00	Alto Giro	6.36	4.62	f	PRO PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319289_1769559858980.jpg	319289	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319289_1769559858980.jpg}
3cdc2648-8b96-44e8-9bab-195ae75d5a35	UP041	GARRAFA SPORT WAY OF LIFE 760ML ROSA PASTEL	24.90	0.00	2026-01-28 00:24:44.107365+00	Alto Giro	6.36	4.62	f	ROSA PASTEL	\N	311701	{}
5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0	UPF20264454	LEGGING ADAPTIV BOLSO CÓS	167.00	367.00	2026-08-31 18:26:26.363738+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264454_1788200784409.jpg	025.07001208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264454_1788200784409.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0_1788239453865.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/5bfc6d98-dc89-45d8-9bf5-a45b09baa4d0_1788239463928.jpg}
a8233b13-73e4-46f4-ac6a-fbf4e5b24676	UPF20266208	BERMUDA DE CORRIDA COMPRESSÃO COM BOLSO	109.00	297.00	2026-09-16 19:23:33.810849+00	CAJU BRASIL	0	4.62	f	VERDE MARINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266208_1789586611313.jpg	026.01301209M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266208_1789586611313.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a8233b13-73e4-46f4-ac6a-fbf4e5b24676_1789586629745.jpg}
fc092e25-e25b-4cf5-abb7-ce6881fd3a54	UP048	LEGGING ELASTICO VERMELHO TINTO	149.90	320.00	2026-01-28 00:24:47.830113+00	Alto Giro	6.36	4.62	f	VERMELHO TINTO	\N	321138	{}
cd479f88-5df1-4756-8c2d-c1ab84b9fb67	UP053	LEGGING FUSO ANDY	119.90	219.00	2026-01-28 00:24:51.464918+00	Vestem	0	4.62	f	C0140 - OFF WHITE/ECRU	\N	FS1338.V24_C0140	{}
68eee4c1-6ae7-4045-a26d-4ccd7176df43	UP054	LEGGING FUSÔ AVIATOR	129.90	229.90	2026-01-28 00:24:51.823984+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	\N	FS1482.I25_C0173	{}
dbb74354-a5c2-40da-8ba6-7172c04733fd	UP040	GARRAFA SPORT WAY OF LIFE 760ML CINZA FERRO	24.90	0.00	2026-01-28 00:24:43.983264+00	Alto Giro	6.36	4.62	f	CINZA FERRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/311702_1769559883446.jpg	311702	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/311702_1769559883446.jpg}
395d35c2-9a98-4deb-a529-575292209199	UP072	LEGGING FUSO SEAMLESS ELIS	109.90	209.90	2026-01-28 00:25:03.401409+00	Vestem	0	4.62	f	C0280 - VERDE MENTA	\N	FS1357.V25_C0280	{}
3162db89-c536-455c-b655-c709782f43bc	UPF20265814	LEGGING ATLÉTIKA CÓS INVISÍVEL DUPLO BOLSO PARA CORRIDA	149.00	327.00	2026-08-31 19:30:32.068806+00	CAJU BRASIL	0	4.62	f	ROXO FIGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265814_1788204630036.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265814_1788204630036.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3162db89-c536-455c-b655-c709782f43bc_1788239742956.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3162db89-c536-455c-b655-c709782f43bc_1788239757002.jpg}
d9127c0d-1b71-427e-9991-34814b25e8f2	UP077	LEGGING FUSO TRICOLOR MOTION	109.90	215.00	2026-01-28 00:25:06.229617+00	Vestem	0	4.62	f	C0550 - EBANO	\N	FS1480.I25_C0550	{}
cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d	UPF20263468	TOP CROPPED ATLÉTIKA COM BOLSO	127.00	257.00	2026-08-31 19:29:48.706667+00	CAJU BRASIL	0	4.62	f	ROXO FIGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263468_1788204586491.jpg	025.01901212	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263468_1788204586491.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d_1788239780094.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cc3cdbf0-cd67-4ca0-9f22-da9de8e8967d_1788239790335.jpg}
d7d7b201-9a29-49bf-ae41-2f302f337110	UPF20264008	LEGGING ADAPTIV COM COMPRESSÃO E ELÁSTICO	149.00	337.00	2026-09-16 19:26:41.259983+00	CAJU BRASIL	0	4.62	f	AMARELO POLEN	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264008_1789586799344.jpg	026.05701135P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264008_1789586799344.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d7d7b201-9a29-49bf-ae41-2f302f337110_1789586817138.jpg}
32a7a79b-c8f5-4e09-8182-1944d1de5871	UP082	LEGGING SHAPE UP LOGOMANIA MYST	109.90	239.90	2026-01-28 00:25:09.467275+00	Vestem	0	4.62	f	E1332.V26 - VESTEM AZUL GAROA	\N	FS1372.ESS_E1332.V26	{}
7f22cf72-8496-41f6-821d-334ffd96a556	UP088	MACACAO LONGO FITNESS BRO	180.60	335.00	2026-01-28 00:25:13.536978+00	BRO	9.64	4.62	f	PRETO/TEX	\N		{}
74d58012-c42e-41c9-b4e9-14a3f046e43f	UP094	SHORT ALECRIM RIPPLE	71.01	141.19	2026-01-28 00:25:16.954449+00	Ange	5.56	4.62	f	Verde	\N	SH1514/alecrim	{}
424d591a-67df-4b58-b24c-847287c57fe5	UP100	Short Cocoa Everyenergy	70.41	141.96	2026-01-28 00:25:19.612954+00	Ange	6.93	4.62	f	Marrom	\N	SH1527/cocoa	{}
45ab48a9-9bb8-479a-ac06-8493a16f661b	UP101	Short Cocoa Everymove	85.92	156.47	2026-01-28 00:25:19.956902+00	Ange	6.93	4.62	f	Marrom	\N	SH1533/cocoa	{}
3eb37bde-1dcf-4f9a-9e08-8c1d605d5677	UP104	SHORT MARINHO COM BLACKOUT YOUTH	96.21	156.39	2026-01-28 00:25:21.225694+00	Ange	5.56	4.62	f	Azul	\N	SH1505/marinho	{}
749ede5e-8fd6-4cd9-bb4b-0f52b100de12	UP106	SHORT STORM EVERYLINE	79.10	149.28	2026-01-28 00:25:21.922621+00	Ange	5.56	4.62	f	Cinza	\N	SH1528/storm	{}
f438b6f9-4793-4180-be63-cc904f0c76b2	UP075	LEGGING FUSÔ SHAPE UP VESTEM ATHLETICA	109.90	209.00	2026-01-28 00:25:05.229956+00	Vestem	0	4.62	f	E1303.I25 - VESTEM ATHLETICA URBAN	\N	FS1470.I25_E1303.I25	{}
8883ceb1-8409-4d9a-a7d5-9e0b77aa9d94	UPF20263899	CROPPED COMFORT LOGO CAJUBRASIL	76.00	147.00	2026-09-16 12:59:21.331526+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263899_1789563559487.jpg	026.03200001G	{}
fa54a66c-e4ab-42e5-9f4c-46b297cd8bca	UPF20265882	TOP CROPPED ADAPTIV COM COMPRESSÃO	96.00	207.00	2026-09-16 19:35:03.178552+00	CAJU BRASIL	0	4.62	f	AZUL ECLIPSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265882_1789587301520.jpg	026.05600563P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265882_1789587301520.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fa54a66c-e4ab-42e5-9f4c-46b297cd8bca_1789587333260.jpg}
982f6554-aea1-48cf-b717-c62f92de6568	UP125	Top Cocoa Everyenergy	74.46	136.01	2026-01-28 00:25:34.112364+00	Ange	6.93	4.62	f	Marrom	\N	TP10501/cocoa	{}
b6f403e1-f88c-4232-87db-7ea4b8713d05	UP129	TOP CROCO DUPLA FACE RIPPLE	74.96	135.14	2026-01-28 00:25:35.905866+00	Ange	5.56	4.62	f	Verde	\N	TP10484/croco	{}
3c7b3a5f-f1aa-4f5a-bba2-c34c2c28fb77	UP139	TOP ELASTICO PERSONALIZADO COSTAS TULE PRETO	79.90	240.00	2026-01-28 00:25:42.828119+00	Alto Giro	6.36	4.62	f	TULE PRETO	\N	319580	{}
de16a930-eaac-4821-a2d8-241f58309991	UP112	SHORTS HYPE	109.90	164.00	2026-01-28 00:25:26.066527+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH648.I25_C0002_1769559925549.webp	SH648.I25_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH648.I25_C0002_1769559925549.webp}
92eddced-cd4e-4310-b470-09f2a230b729	UPF20264845	TOP CROPPED CANELADO ALÇAS DUPLAS	94.00	157.00	2026-09-16 13:00:38.219289+00	CAJU BRASIL	0	4.62	f	MARROM COFFE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264845_1789563636323.jpg	023.10900007M	{}
2c8461c4-e54d-44cf-b630-aaabb5572c1e	UP147	TOP LIMA COM BLACKOUT YOUTH	79.29	139.47	2026-01-28 00:25:47.685493+00	Ange	5.56	4.62	f	Verde	\N	TP10471/lima	{}
c0b9a395-5d2d-4349-841e-9b8e4ae1fb16	UPF20267941	LEGGING ADAPTIV COM COMPRESSÃO E ELÁSTICO	149.00	297.00	2026-09-16 19:36:33.582317+00	CAJU BRASIL	0	4.62	f	AZUL ECLIPSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267941_1789587390665.jpg	026.05700563P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267941_1789587390665.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c0b9a395-5d2d-4349-841e-9b8e4ae1fb16_1789587407687.jpg}
9d9b17fc-6f19-459c-afff-e483755963a0	UPF20263211	LEGGING CANELADA EMPINA BUMBUM	147.00	297.00	2026-09-16 13:01:29.106788+00	CAJU BRASIL	0	4.62	f	MARROM COFFE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263211_1789563687204.jpg	023.11000007M	{}
063ce64c-6690-475d-96d0-1930e7d65cf2	UP175	TOP NADADOR ELASTICO PERSONALIZADO VERMELHO TINTO	92.90	205.00	2026-01-28 00:26:07.228998+00	Alto Giro	6.36	4.62	f	VERMELHO TINTO	\N	321233	{}
6ab17bb2-6aa5-47ab-8d06-9657943a92a0	UP176	TOP POP RED EVERYLINE	75.09	135.27	2026-01-28 00:26:07.5639+00	Ange	5.56	4.62	f	Vermelho	\N	TP10503/popred	{}
3a6d422a-1801-4714-a965-e81816036b4b	UPF20267117	SHORT CURTO ADAPTIV E COMPRESSÃO COM BOLSO	114.00	257.00	2026-09-16 19:38:36.557538+00	CAJU BRASIL	0	4.62	f	AZUL ECLIPSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267117_1789587514513.jpg	026.05800563P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267117_1789587514513.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3a6d422a-1801-4714-a965-e81816036b4b_1789587532513.jpg}
3821f950-75b1-42be-94ce-514ac77674de	UP181	Top Serenity Everyline	75.09	136.64	2026-01-28 00:26:11.07607+00	Ange	6.93	4.62	f	Azul	\N	TP10503/serenity	{}
efd9997b-9730-4b62-90ac-cf329487482a	UP182	TOP SERENITY EVERYTONE	75.59	155.27	2026-01-28 00:26:11.429134+00	Ange	5.56	4.62	f	Azul	\N	TP10505/serenity	{}
d8c4b2ca-77cb-4f6b-bd05-969eec7fe34d	UP020	Calça Legging Cocoa Everytime	122.58	240.50	2026-01-28 00:24:34.841381+00	Ange	6.93	4.62	f	Marrom	\N	LG18444/cocoa	{}
bbca77cf-357c-4eac-a5a2-bd7c49055b36	UPF20269562	REGATA TULE DETALHE COSTAS	66.00	137.00	2026-09-16 13:03:31.127097+00	CAJU BRASIL	0	4.62	f	VINHO BAROLO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269562_1789563808845.jpg	023.10200886P	{}
b2613d94-7aa4-4753-b13c-297135533962	UPF20269152	LEGGING ZERO TRANSPARÊNCIA ADAPTIV COM COMPRESSÃO E BOLSOS	164.00	337.00	2026-09-16 19:44:07.933376+00	CAJU BRASIL	0	4.62	f	AZUL TOPAZIO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269152_1789587844394.jpg	026.02501210M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269152_1789587844394.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/b2613d94-7aa4-4753-b13c-297135533962_1789587860645.jpg}
c13c6bb2-b261-4906-aa83-2fc815cbcf33	UP019	Calça Legging Cocoa Everymove	157.06	223.61	2026-01-28 00:24:34.495894+00	Ange	6.93	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c13c6bb2-b261-4906-aa83-2fc815cbcf33_1771846414344.jpg	LG18446/cocoa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c13c6bb2-b261-4906-aa83-2fc815cbcf33_1771846414344.jpg}
ce60564c-7257-4134-ab7c-725150da593e	UPF20269631	Regata Tule Celeste	59.15	129.90	2026-02-26 18:32:39.445037+00	BRO	3.41	4.62	f	Marrom Charuto	\N	0488VR036000	{}
bd47c449-4163-4b39-a7a7-14083553b056	UPF20262583	TOP FITNESS MOTIV	88.05	164.90	2026-02-26 19:21:43.98891+00	BRO	6.2	4.62	f	Branco	\N	TP0585	{}
2dae49a4-9222-4a44-9a7b-408d7d2f90c1	UPF20268484	TOP ALTA SUSTENTAÇÃO COM COMPRESSÃO	89.00	197.00	2026-09-16 19:57:04.998372+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268484_1789588622469.jpg	026.03300633P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268484_1789588622469.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2dae49a4-9222-4a44-9a7b-408d7d2f90c1_1789588637946.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2dae49a4-9222-4a44-9a7b-408d7d2f90c1_1789588651011.jpg}
bfcc1f5d-691a-43e0-80f4-d6d7b87404b9	UPF20262460	JAQUETA CORTA VENTO MOVEMENT	174.90	289.90	2026-02-27 13:54:27.57963+00	Vestem	0	4.62	f	Cinza Pedra	\N	JAC261.V26	{}
9abc134e-a5ba-4ad7-9bc2-5436b8d81fc8	UPF20268704	TOP CLASSICO SPORTIVE	84.00	187.00	2026-09-16 13:25:42.015364+00	CAJU BRASIL	0	4.62	f	VERDE ESMERALDA	\N	001.00101168M	{}
cbc0b5ff-58a5-4680-9ae8-706846963470	UPF20265571	Legging Essentials	83.93	270.00	2026-02-28 18:00:43.485272+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265571_1772301642292.jpg	2611309	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265571_1772301642292.jpg}
46fb1325-8776-4858-99de-ec1423ced26f	UPF20266099	SHORT ZERO TRANSPARÊNCIA PARA CORRIDA BOLSO CÓS	129.00	257.00	2026-09-16 19:58:28.537529+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266099_1789588705901.jpg	026.03400633M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266099_1789588705901.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/46fb1325-8776-4858-99de-ec1423ced26f_1789588720334.jpg}
8a189df4-bf12-4c44-8b83-42773cb4082f	UPF20267247	TOP CROPPED NP CORRIDA SUSTENTAÇÃO	129.00	237.00	2026-09-16 13:26:47.175944+00	CAJU BRASIL	0	4.62	f	VERDE MARINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8a189df4-bf12-4c44-8b83-42773cb4082f_1789586508391.jpg	026.01101209P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8a189df4-bf12-4c44-8b83-42773cb4082f_1789586508391.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8a189df4-bf12-4c44-8b83-42773cb4082f_1789586518606.jpg}
44f22275-9ace-4eed-a585-0147c1cb9b9d	UPF20266383	TOP ADAPTIV COM COMPRESSÃO ALÇAS FINAS	82.00	197.00	2026-09-16 13:27:29.032472+00	CAJU BRASIL	0	4.62	f	AZUL TOPAZIO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/44f22275-9ace-4eed-a585-0147c1cb9b9d_1789587708113.jpg	026.02401210P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/44f22275-9ace-4eed-a585-0147c1cb9b9d_1789587708113.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/44f22275-9ace-4eed-a585-0147c1cb9b9d_1789587715679.jpg}
cda5a2f7-8a67-4766-bdd6-bbc712cad09b	UPF20261263	Blusa Tule Básica	66.60	139.90	2026-02-25 14:39:49.851319+00	BRO	3.41	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261263_1772030388944.jpg	646BR00100000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261263_1772030388944.jpg}
d2a91312-c159-4008-8b7c-4a927a059a72	UPF20262276	BLUSA DE TULE ALONGADA	86.00	157.00	2026-09-16 13:28:14.629165+00	CAJU BRASIL	0	4.62	f	ROSA BALLERINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d2a91312-c159-4008-8b7c-4a927a059a72_1789584991135.jpg	022.06201207M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d2a91312-c159-4008-8b7c-4a927a059a72_1789584991135.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/d2a91312-c159-4008-8b7c-4a927a059a72_1789585000294.jpg}
8993da5b-90c2-4af4-801d-b1b08e00be77	UPF20261013	LEGGING ZERO TRANSPARÊNCIA BOLSO CÓS COM COMPRESSÃO	169.00	337.00	2026-09-16 19:59:34.680171+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261013_1789588772694.jpg	026.03500633P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261013_1789588772694.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8993da5b-90c2-4af4-801d-b1b08e00be77_1789588791114.jpg}
c5b72bbb-6b92-46a3-a543-bde357e9eef8	UPF20261466	Regata Fitness Pulsar	71.40	139.90	2026-03-31 18:30:35.282667+00	BRO	8.69	4.62	f	Azul Titan	\N	TR2645344	{}
a1438632-772e-4035-ac6f-36c7030329d8	UPF20261682	Regata Fitness Pulsar	71.40	139.90	2026-03-31 18:33:45.285609+00	BRO	8.69	4.62	f	Verde Zump	\N	TR2645344	{}
253816a0-017a-42b6-aae4-128963fdc544	UPF20261966	Regata Fitness Pulsar	71.40	139.90	2026-03-31 18:34:47.69147+00	BRO	8.69	4.62	f	Verde Agave	\N	TR2645344	{}
28287d18-20dd-4210-9450-67c2e91e8345	UPF20265626	Regata Fitness Pulsar	71.40	139.90	2026-03-31 18:37:58.402561+00	BRO	8.69	4.62	f	Verde Forest	\N	TR2645344	{}
ed862ad2-431e-4dc0-9833-72c64ed5c9f1	UPF20265679	BLUSA DE TULE TRANSPASSADA	69.00	137.00	2026-09-16 13:28:56.813608+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ed862ad2-431e-4dc0-9833-72c64ed5c9f1_1789585582763.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ed862ad2-431e-4dc0-9833-72c64ed5c9f1_1789585582763.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ed862ad2-431e-4dc0-9833-72c64ed5c9f1_1789585594893.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ed862ad2-431e-4dc0-9833-72c64ed5c9f1_1789585604056.jpg}
f658305e-d395-429c-8c5c-d87c9e0a2c29	UPF20261783	TOP ALTA SUSTENTAÇÃO COM COMPRESSÃO	89.00	197.00	2026-09-16 20:02:24.580972+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261783_1789588942267.jpg	026.03300001M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261783_1789588942267.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f658305e-d395-429c-8c5c-d87c9e0a2c29_1789588964697.jpg}
a57e0149-55f4-432d-99d9-251483ecc644	UPF20261624	Short Fitness Street Bolso	128.55	239.90	2026-04-14 12:24:43.710996+00	BRO	9.47	4.62	t	Verde Água	\N	TR2645655	{}
963ba04d-3a66-4c13-aab0-640bb69ed947	UPF20261249	Short Fitness Street Bolso	128.55	239.90	2026-04-14 12:24:04.479718+00	BRO	9.47	4.62	t	Azul Bic	\N	TR2645655	{}
7bbe7a32-436b-4731-80f7-135caeb74157	UPF20265378	CROPPED COMFORT LOGO CAJUBRASIL	76.00	147.00	2026-09-16 18:11:43.097923+00	CAJU BRASIL	0	4.62	f	BRANCO	\N	026.03200002P	{}
21db8fae-3c39-4e2f-ab6d-0013477c0b3b	UPF20263987	T-Shirt Cropped Com Tule	98.90	229.90	2026-05-07 23:20:01.13142+00	Alto Giro	0	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/21db8fae-3c39-4e2f-ab6d-0013477c0b3b_1778224230775.jpg	2621710	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/21db8fae-3c39-4e2f-ab6d-0013477c0b3b_1778224230775.jpg}
35112591-d9b0-46f7-bcc3-56d06538fed0	UPF20265665	SHORT ZERO TRANSPARÊNCIA PARA CORRIDA BOLSO CÓS	129.00	257.00	2026-09-16 20:04:47.344599+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265665_1789589084780.jpg	026.03400001M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265665_1789589084780.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/35112591-d9b0-46f7-bcc3-56d06538fed0_1789589116934.jpg}
12340bde-9009-4c92-904d-b0ca61d085af	UPF20264698	Legging Eterna Cos Alto	88.83	290.90	2026-05-22 12:07:17.860712+00	Alto Giro	0	4.62	f	Preto	\N	101302	{}
de845772-4adf-4165-8eb9-4acb2ef1f46b	UPF20267864	Legging Cos Fusionado	111.93	350.00	2026-05-22 12:07:53.699889+00	Alto Giro	0	4.62	f	Preto	\N	121308	{}
d9074cc0-4cc0-4951-acc7-7465541abf71	UPF20267808	Regata Eterna Cropped	52.43	150.00	2026-05-22 12:10:17.233173+00	Alto Giro	0	4.62	f	Preto	\N	101622	{}
9b724805-0053-422f-ad26-a756d381a78e	UPF20269450	Top Eterno Costas Nadador	62.93	160.00	2026-05-22 12:13:34.836853+00	Alto Giro	0	4.62	f	Preto	\N	101528	{}
fc469e48-c097-4005-bbf7-9c8b7e488b82	UPF20263166	Bermuda Eterna com Bolsos	66.43	220.00	2026-05-22 12:19:41.817185+00	Alto Giro	0	4.62	f	Preto	\N	101114	{}
3e7cf9ec-8b8f-4bef-acb3-b2d54e5c2ad1	UPF20267004	Regata Eterna Gola V	59.43	120.00	2026-05-22 12:20:13.293739+00	Alto Giro	0	4.62	f	Preto	\N	101601	{}
443f6902-6e31-4726-b73a-f099e1b067a0	UPF20263304	T-shirt Eterna Gola Redonda	60.83	129.90	2026-05-22 12:21:35.506076+00	Alto Giro	0	4.62	f	Preto	\N	101702	{}
64544c42-05d0-4c1a-b988-0d0e07834e15	UPF20265801	T-shirt Eterna Gola V	62.23	129.90	2026-05-22 12:22:07.261156+00	Alto Giro	0	4.62	f	Preto	\N	101701	{}
7bbe0ce4-8a2d-47f3-92d7-e5c73dc392f2	UPF20266304	Shorts Sobreposto Eterna	83.23	220.00	2026-05-22 12:25:10.403645+00	Alto Giro	0	4.62	f	Preto	\N	101006	{}
35212ea8-1da9-4214-b94d-1b680875b8fb	UPF20268261	BERMUDA FITNESS SELENITA	102.80	215.00	2026-05-25 14:45:55.0165+00	BRO	6.56	4.62	f	AZUL MARINHO/AZUL GALÁXIA	\N	BER0722AZ10600000002	{}
1eb39472-4b0e-4753-b75b-8187024d77d2	UPF20264393	BERMUDA FITNESS SELENITA	102.80	215.00	2026-05-25 14:46:41.937839+00	BRO	6.56	4.62	f	CINZA CLARO/ROSE ESCURO	\N	BER0722CZ03600000002	{}
75fda0ae-993d-4cdb-8647-43b5dacd8e4e	UPF20263892	Shorts Degrade	115.90	259.90	2026-05-07 23:11:59.350919+00	Alto Giro	0	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/75fda0ae-993d-4cdb-8647-43b5dacd8e4e_1778224392018.jpg	2621021	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/75fda0ae-993d-4cdb-8647-43b5dacd8e4e_1778224392018.jpg}
87a7fcf6-8e18-4e39-8833-c6ec27ef5e0a	UPF20268095	REGATA TULE	59.00	137.00	2026-09-16 18:14:45.277025+00	CAJU BRASIL	0	4.62	f	AZUL SKY	\N	022.06300456P	{}
5c6dda5a-1ebd-4489-b45e-99ded1fcbd5b	UPF20262751	TOP FITNESS SELENITA	80.90	160.00	2026-05-25 14:56:37.090538+00	BRO	6.56	4.62	f	AZUL MARINHO/AZUL GALÁXIA	\N	TP0722AZ10600000002	{}
c2ad6656-55cd-4bfb-a495-71b04535a657	UPF20265031	TOP FITNESS SELENITA	80.90	160.00	2026-05-25 14:57:16.975671+00	BRO	6.56	4.62	f	CINZA CLARO/ROSE ESCURO	\N	TP0722CZ03600000002	{}
f2ad9e63-2c90-4472-bc1f-ab3936f125cf	UPF20269058	SHORTS SOBREPOSTO REFLETIVO	119.90	259.90	2026-05-25 22:56:25.26614+00	Alto Giro	0	4.62	f	MARROM INTENSO	\N	314718	{}
73caf4fa-855b-4629-b0dd-386d42210374	UPF20268422	MACACÃO ENERGY ADAPTIV	219.00	407.00	2026-09-16 20:09:02.25469+00	CAJU BRASIL	0	4.62	f	VERMELHO CARMIM	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268422_1789589339411.jpg	026.06900946P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268422_1789589339411.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/73caf4fa-855b-4629-b0dd-386d42210374_1789589355102.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/73caf4fa-855b-4629-b0dd-386d42210374_1789589363728.jpg}
32c8d197-fa1e-4cd7-8559-639d7b8a1359	UPF20269492	TOP ALTO GIRO SPORT	129.90	299.90	2026-05-25 23:00:24.733488+00	Alto Giro	0	4.62	f	PRETO	\N	314695	{}
5dcffd07-7cfd-4204-9e49-3401773bb7ab	UPF20265259	LEGGING ETERNA COM BOLSO	128.90	279.90	2026-05-25 23:07:33.309818+00	Alto Giro	0	4.62	f	AZUL NOTURNO	\N		{}
ecba23cc-511a-45b8-85d9-27dc7cb8f0c4	UPF20268334	REGATA ETERNA CROPPED	78.90	179.90	2026-05-25 23:09:03.133795+00	Alto Giro	0	4.62	f	VERDE CITRICO	\N	329626	{}
2b0404e5-ce5e-4a3d-8507-66d89e323326	UPF20262798	REGATA ETERNA CROPPED	78.90	179.90	2026-05-25 23:09:40.808072+00	Alto Giro	0	4.62	f	LARANJA PESSEGO	\N	329629	{}
03984ca4-0f91-49d0-903d-e6bc09e9e9d3	UPF20262920	CALÇA LEGGING CELESTIAL	119.00	235.00	2026-05-25 14:50:23.687663+00	BRO	6.56	4.62	f	ROXO DELUXE/ROSA FÚCSIA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262920_1779720622050.jpg	LG0666RX04200000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262920_1779720622050.jpg}
e4d0e600-15d1-45b5-9391-240739862804	UPF20268161	TOP FITNESS CELESTIAL	79.05	160.00	2026-05-25 14:51:47.60751+00	BRO	6.56	4.62	f	AZUL CARIBE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268161_1779720705079.jpg	TP0666AZ10300000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268161_1779720705079.jpg}
3a053da8-0523-4cc3-927b-1ebb65aab3a9	UPF20268202	BERMUDA COS ELASTICO BICOLOR	119.90	269.90	2026-05-26 13:59:13.340412+00	Alto Giro	0	4.62	f	ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3a053da8-0523-4cc3-927b-1ebb65aab3a9_1790166749698.jpg	326935	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3a053da8-0523-4cc3-927b-1ebb65aab3a9_1790166749698.jpg}
043497d1-0d8f-440c-9ae8-24f2cc7adf43	UPF20268812	REGATA TULE	59.00	137.00	2026-09-16 18:15:33.111424+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268812_1789582530600.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268812_1789582530600.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/043497d1-0d8f-440c-9ae8-24f2cc7adf43_1789582559140.jpg}
f2070b32-3f43-4580-a47d-7b1dad432779	UPF20264997	MACAQUINHO LOGO COM BOLSO	179.00	307.00	2026-09-16 20:11:25.56859+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264997_1789589484120.jpg	026.03600001M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264997_1789589484120.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f2070b32-3f43-4580-a47d-7b1dad432779_1789589498209.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f2070b32-3f43-4580-a47d-7b1dad432779_1789589508062.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f2070b32-3f43-4580-a47d-7b1dad432779_1789589518629.jpg}
e1eeabac-0b5c-414e-8292-b5487a1bc841	UPF20266141	TOP COS DE ELASTICO E ALCA DUPLA	119.90	239.90	2026-05-26 13:59:50.985859+00	Alto Giro	0	4.62	f	ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e1eeabac-0b5c-414e-8292-b5487a1bc841_1790166719091.jpg	325865	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e1eeabac-0b5c-414e-8292-b5487a1bc841_1790166719091.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e1eeabac-0b5c-414e-8292-b5487a1bc841_1790166729954.jpg}
9bec3a8f-030b-4b74-be80-24e3ced41e0c	UPF20266207	REGATA ELASTICO PERSONALIZADO	78.90	179.90	2026-05-26 13:07:49.75581+00	Alto Giro	0	4.62	f	BRANCO OPTICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266207_1779800851914.jpg	326789	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266207_1779800851914.jpg}
9ee05df7-4f09-4781-b42d-e4fe77cc1877	UPF20263454	REGATA TULE	59.00	137.00	2026-09-16 18:16:54.286545+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9ee05df7-4f09-4781-b42d-e4fe77cc1877_1789585022890.jpg	022.06301208P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9ee05df7-4f09-4781-b42d-e4fe77cc1877_1789585022890.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9ee05df7-4f09-4781-b42d-e4fe77cc1877_1789585032199.jpg}
f632628f-203a-4e8d-8151-c82c4116adad	UPF20269129	TOP DECOTE COSTAS ELÁSTICO PERSONALIZADO	98.90	229.90	2026-09-22 20:00:27.821181+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269129_1790107225869.jpg	330265	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269129_1790107225869.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f632628f-203a-4e8d-8151-c82c4116adad_1790107242654.jpg}
cc8c8918-e373-494a-8032-dbad1d9278df	UPF20263833	SAIA RETA DETALHE ESTAMPA	126.90	299.90	2026-06-30 20:52:02.259251+00	Alto Giro	0	4.62	f	ROSA PASTEL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cc8c8918-e373-494a-8032-dbad1d9278df_1790166765678.jpg	330146	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cc8c8918-e373-494a-8032-dbad1d9278df_1790166765678.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cc8c8918-e373-494a-8032-dbad1d9278df_1790166774790.jpg}
717f76a2-0f95-47ed-992a-808ba48cffa3	UPF20268970	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO	109.90	229.90	2026-06-30 20:27:42.686328+00	Alto Giro	0	4.62	f	Roxo Encanto	\N	329703	{}
769c8388-bf63-468c-b806-2f326b5af2ee	UPF20262088	LEGGING FRISO CONTRASTANTE	149.90	369.90	2026-06-30 20:40:35.833855+00	Alto Giro	0	4.62	f	Preto	\N	330254	{}
d389d258-964a-4d0e-b4ef-0387083ed1f5	UPF20269887	SAIA DRY SOBREPOSTA	109.90	229.90	2026-06-30 20:53:32.97266+00	Alto Giro	0	4.62	f	PRETO	\N	329332	{}
b3f898c9-4d5f-4155-afbc-33b49b1131f2	UPF20263260	SAIA DRY SOBREPOSTA	109.90	229.90	2026-06-30 20:54:25.196328+00	Alto Giro	0	4.62	f	AMARELO CREME	\N	329338	{}
72307b52-03ee-438f-96d1-0d5ea050b9a5	UPF20261371	TOP COM RECORTE E ABERTURA NAS COSTAS	139.90	259.90	2026-06-30 21:02:48.866877+00	Alto Giro	0	4.62	f	PRETO	\N	329582	{}
afc0bdf2-dca6-42b7-abcb-2cb7ff27cff7	UPF20267560	TOP COM RECORTE E ABERTURA NAS COSTAS	139.90	259.90	2026-06-30 21:04:54.987685+00	Alto Giro	0	4.62	f	AMARELO CREME	\N	329585	{}
6060f268-49b8-492f-aee7-d21656de929b	UPF20262868	TOP ALÇA FINA AG WAY OF LIFE	89.90	199.90	2026-06-30 21:10:47.66323+00	Alto Giro	0	4.62	f	BRANCO ÓPTICO	\N	330322	{}
2357e280-e696-4910-8e91-4393557c8a37	UPF20268722	TOP NADADOR ELÁSTICO WAY OF LIFE	119.90	259.90	2026-06-30 21:11:47.620337+00	Alto Giro	0	4.62	f	PRETO	\N	330634	{}
18fadb91-ef7c-4866-bd25-1d2ef25c1a85	UPF20264661	LEGGING HERO CAJUBRASIL	139.00	307.00	2026-09-16 18:48:49.974259+00	CAJU BRASIL	0	4.62	f	AZUL ECLIPSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264661_1789584527368.jpg	031.00100563M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264661_1789584527368.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/18fadb91-ef7c-4866-bd25-1d2ef25c1a85_1789584543425.jpg}
ce46e8b8-19e8-48b1-b9cc-030dd7c66660	UPF20269584	LEGGING DETALHE ELÁSTICO E BOLSO	179.90	369.90	2026-09-22 20:04:09.911027+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269584_1790107447077.jpg	330187	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269584_1790107447077.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ce46e8b8-19e8-48b1-b9cc-030dd7c66660_1790107468455.jpg}
6e18ff3f-06dc-4ad2-a18c-7a9dc33e4f66	UPF20267011	SHORTS SLEEK FIT SHAPE UP	104.90	209.90	2026-07-16 20:33:50.051206+00	Vestem	4.62	0	f	Marrom Castanho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267011_1784234026094.jpg	SH812.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267011_1784234026094.jpg}
409af360-66bc-471b-8317-a82430ee6c7d	UPF20263924	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:24:30.161579+00	BRO	3.07	4.62	f	ROXO AMETISTA	\N	7908388544280	{}
aaba247b-5e6f-45d6-8138-7f6c2154f2bd	UPF20265824	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:19:25.932087+00	BRO	3.07	4.62	f	ROSE	\N	7901052212966	{}
a3cd85f4-dbc5-4682-8322-3d18814912ff	UPF20264897	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:16:02.062579+00	BRO	3.07	4.62	f	CAQUI	\N	7901052212935	{}
23c409d8-f4d3-4878-8fe3-953870964111	UPF20266572	COLETE JULY	209.50	289.90	2026-07-22 12:35:03.998172+00	BRO	3.07	4.67	f	AZUL MARINHO	\N	7901052213307	{}
46c40d21-adf4-470a-b558-e79d835ad579	UPF20266479	SHORT JULY	142.85	210.00	2026-07-22 12:35:49.626437+00	BRO	3.07	4.62	f	AZUL MARINHO	\N	7901052213338	{}
1d5bfeeb-928f-4d0f-8e70-b5a7615d3172	UPF20268036	TOP HERO CAJUBRASIL	102.00	207.00	2026-09-16 18:50:06.781728+00	CAJU BRASIL	0	4.62	f	AZUL ECLIPSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268036_1789584603911.jpg	031.00200563P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268036_1789584603911.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1d5bfeeb-928f-4d0f-8e70-b5a7615d3172_1789584622716.jpg}
ebb9249d-6b6e-4440-a613-62700db7d0cf	UPF20266993	SHORTS 2 EM 1 BICOLOR	198.90	397.00	2026-09-22 20:15:53.524863+00	Alto Giro	0	4.62	f	LARANJA PÊSSEGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266993_1790108150039.jpg	330378	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266993_1790108150039.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ebb9249d-6b6e-4440-a613-62700db7d0cf_1790108170345.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ebb9249d-6b6e-4440-a613-62700db7d0cf_1790108181696.jpg}
2e5432cc-ab51-4605-b02c-49c5c00e2605	UPF20265470	TOP DUPLA FACE COSTAS CRUZADA	98.90	199.90	2026-07-23 01:03:03.568312+00	Alto Giro	0	4.62	f	BEGE CREMOSO	\N	330251	{}
8ae0556d-3282-40e2-91d9-32b84108bb97	UPF20266881	MACACÃO FITNESS ORQUÍDEA	207.10	429.90	2026-07-31 12:08:18.620162+00	BRO	10	4.62	f	MARROM CACAU/BRONZE BÚFALO	\N	7VR07700000004	{}
6e0276fd-af02-48e2-9eb2-2e75f957f888	UPF20262975	MACACÃO FITNESS MOTIV	180.95	379.90	2026-07-31 12:11:32.637861+00	BRO	10	4.62	f	PRETO	\N	MC0585PT00100000002	{}
4902c1b3-9178-4e16-9be8-4674f57b81dd	UPF20264495	MACAQUINHO FITNESS POLO	228.60	449.90	2026-07-31 12:12:12.906253+00	BRO	10	4.62	f	CINZA MESCLA ESCURO/BRANCO	\N	MC0714CCZ03500000001	{}
e2934091-9b05-4c69-b83a-f6b9c253e9b7	UPF20267227	LEGGING HERO CAJUBRASIL	139.00	307.00	2026-09-16 18:51:35.651556+00	CAJU BRASIL	0	4.62	f	VERMELHO CARMIM	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267227_1789584693131.jpg	031.00100946P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267227_1789584693131.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e2934091-9b05-4c69-b83a-f6b9c253e9b7_1789584708918.jpg}
43dcec98-8ce6-4b18-bfe5-2d43562e41dc	UPF20261004	SAIA SHORTS ETERNA SOBREPOSTA EVASE	134.90	199.90	2026-05-25 23:05:08.51421+00	Alto Giro	0	4.62	f	ROSA FELIZ	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261004_1779750305998.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261004_1779750305998.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/43dcec98-8ce6-4b18-bfe5-2d43562e41dc_1790166842896.jpg}
dba825df-6b52-4f67-8ffd-40f0354ae35d	UPF20261934	Top Fitness Summer Liso	85.65	187.00	2026-08-31 13:32:54.696078+00	BRO	7.42	4.62	f	Salmão Electric	\N		{}
968eed0e-6f20-46e0-b3a7-24be0a7003f4	UPF20263215	Top Fitness Summer Liso	85.65	187.00	2026-08-31 13:34:32.527828+00	BRO	7.42	4.62	f	Preto	\N	TP0106PT00102010004	{}
d19a3610-019e-4b86-8d02-3eb852229ac1	UPF20264442	LEGGING P EMPINA BUMBUM CLÁSSICA	119.00	297.00	2026-08-31 18:29:48.618739+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	\N	001.18201208	{}
2343ce27-26a5-4dcd-81d9-bae03d99784a	UPF20267197	TOP NP CLÁSSICO	89.00	157.00	2026-08-31 18:30:33.807796+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	\N	001.21701208	{}
82bb791e-f319-4a56-854f-0fee7efbdea0	UPF20269672	CROPPED TULE CLÁSSICO	57.00	107.00	2026-08-31 23:46:16.915121+00	CAJU BRASIL	0	4.62	f	ROSA OLINDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/82bb791e-f319-4a56-854f-0fee7efbdea0_1789581638686.jpg	001.15400034	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/82bb791e-f319-4a56-854f-0fee7efbdea0_1789581638686.jpg}
2330c025-6a8d-4527-a3f6-c06847d63ba2	UPF20269908	TOP HERO CAJUBRASIL	102.00	207.00	2026-09-16 18:52:36.747495+00	CAJU BRASIL	0	4.62	f	VERMELHO CARMIM	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269908_1789584754931.jpg	031.00200946M	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269908_1789584754931.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2330c025-6a8d-4527-a3f6-c06847d63ba2_1789584775920.jpg}
e6481b12-5b71-48fb-8014-ac527908b6fc	UPF20269885	Regata Cropped Recorte Costas	74.90	169.90	2026-05-07 23:18:13.123166+00	Alto Giro	0	4.62	f	ROSA LIGHT	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e6481b12-5b71-48fb-8014-ac527908b6fc_1790167479464.jpg	2621630	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e6481b12-5b71-48fb-8014-ac527908b6fc_1790167479464.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e6481b12-5b71-48fb-8014-ac527908b6fc_1790167488038.jpg}
f89024c3-9556-4a5d-9afe-c786c90928d2	UPF20265301	BLUSA UV CLÁSSICA	84.00	167.00	2026-08-31 18:33:32.651114+00	CAJU BRASIL	0	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f89024c3-9556-4a5d-9afe-c786c90928d2_1790262048730.jpg	001.20900002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f89024c3-9556-4a5d-9afe-c786c90928d2_1790262048730.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f89024c3-9556-4a5d-9afe-c786c90928d2_1790262065662.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f89024c3-9556-4a5d-9afe-c786c90928d2_1790262074817.jpg}
f6c11475-b890-40e4-90d7-bd6a63a7af3b	UP002	BERMUDA ALTO GIRO SPORT MARROM NOBRE	112.90	240.00	2026-01-28 00:24:21.062053+00	Alto Giro	6.36	4.62	f	 MARROM NOBRE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319126_1769559860545.jpg	319126	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319126_1769559860545.jpg}
498a47fd-de22-4035-ad7a-00e679abeba4	UP003	BERMUDA ALTO GIRO SPORT VERDE ESCURO	112.90	240.00	2026-01-28 00:24:21.997485+00	Alto Giro	6.36	4.62	f	VERDE ESCURO 	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp	319128	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319128_1769559861367.webp}
bbcba1b7-c542-4e19-92c7-df58f537cc63	UP004	BERMUDA CANELADA TN AG ROSA DOCE	119.90	260.00	2026-01-28 00:24:23.130977+00	Alto Giro	6.36	4.62	f	ROSA DOCE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319819_1769559862595.jpg	319819	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319819_1769559862595.jpg}
48999143-c489-469b-b0f4-d13827a99571	UP007	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:24.872903+00	Vestem	0	4.62	f	C0007 - LARANJA NEON	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0007_1769559864479.webp	BMC31.ESS_C0007	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0007_1769559864479.webp}
ea9742b4-b495-4787-a7cd-f53352a29c99	UP008	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:25.554466+00	Vestem	0	4.62	f	C0009 - AMARELO NEON	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0009_1769559865070.webp	BMC31.ESS_C0009	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0009_1769559865070.webp}
7eaeb75b-ea96-45fc-98fd-b6cd7063aee8	UP009	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:26.62663+00	Vestem	0	4.62	f	C0243 - ROSA ROMANCE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0243_1769559866172.webp	BMC31.ESS_C0243	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0243_1769559866172.webp}
e7a1f608-edb7-45e8-8a90-424636a6aee7	UP010	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:27.32919+00	Vestem	0	4.62	f	C0279 - LILAS LAVANDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0279_1769559866913.webp	BMC31.ESS_C0279	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0279_1769559866913.webp}
1b9c4839-a0e6-4f8b-bdbc-28f0753d4329	UP011	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:27.926318+00	Vestem	0	4.62	f	C0449 - VERDE TWIST	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0449_1769559867506.webp	BMC31.ESS_C0449	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0449_1769559867506.webp}
70604eae-b5d8-4a80-9999-58b39f210865	UP012	BLUSA MANGA CURTA DRY FIT JANICE	69.90	129.90	2026-01-28 00:24:28.632108+00	Vestem	0	4.62	f	C0528 - CORALINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0528_1769559868163.webp	BMC31.ESS_C0528	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC31.ESS_C0528_1769559868163.webp}
2a2efbb1-4ff4-494c-8249-8509f0d5b2b9	UP013	BLUSA MANGA CURTA DRY FIT SPRING	86.90	129.90	2026-01-28 00:24:29.235145+00	Vestem	0	4.62	f	C0009 - AMARELO NEON	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC792.I25_C0009_1769559868806.webp	BMC792.I25_C0009	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC792.I25_C0009_1769559868806.webp}
3ac1ddca-642d-4e59-be7f-6db747165549	UP014	BLUSA MANGA CURTA DRY FIT ZADAR	77.90	159.90	2026-01-28 00:24:29.798942+00	Vestem	0	4.62	f	C0001 - BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0001_1769559869418.webp	BMC654.ESS_C0001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0001_1769559869418.webp}
d90fc150-1d5a-4f27-988d-009d35eb6208	UP015	BLUSA MANGA CURTA DRY FIT ZADAR	77.90	159.90	2026-01-28 00:24:31.08193+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0002_1769559870534.webp	BMC654.ESS_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0002_1769559870534.webp}
3ab8ccdf-4ffb-4b25-b9dc-8588bdf38735	UP016	BLUSA MANGA CURTA DRY FIT ZADAR	77.90	159.90	2026-01-28 00:24:32.174149+00	Vestem	0	4.62	f	C0280 - VERDE MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0280_1769559871737.webp	BMC654.ESS_C0280	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/BMC654.ESS_C0280_1769559871737.webp}
ddfc3385-ddc8-4ade-bac2-7bdc6fbfa9a5	UP025	COLETE BRAVO	99.95	199.90	2026-01-28 00:24:37.224659+00	BRO	9.64	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/22-1-02-300-0277_1_1769559876474.png	22-1-02-300-0277_1	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/22-1-02-300-0277_1_1769559876474.png}
437b0672-0343-4c5b-905e-178b1335b989	UP023	CALÇA LEGGING STORM EVERYLIFT	164.54	234.72	2026-01-28 00:24:35.890385+00	Ange	5.56	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/437b0672-0343-4c5b-905e-178b1335b989_1771846610638.jpg	LG18436/storm	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/437b0672-0343-4c5b-905e-178b1335b989_1771846610638.jpg}
bef92425-0281-4d62-b06e-607e557d8c9d	UP031	CONJUNTO SAIA E TOP SABINA	94.90	179.90	2026-01-28 00:24:40.360835+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/CJ253.PE_C0002_1769559879853.webp	CJ253.PE_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/CJ253.PE_C0002_1769559879853.webp}
32abbbfd-598e-4841-acda-3308c99d10a8	UP030	COLETE JULY	190.40	289.90	2026-01-28 00:24:39.674411+00	BRO	9.64	4.62	f	VERDE MINT	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/32abbbfd-598e-4841-acda-3308c99d10a8_1770146758706.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/32abbbfd-598e-4841-acda-3308c99d10a8_1770146758706.jpg}
ca957b05-f901-457a-bb3f-4d2f51560b34	UP026	COLETE BRAVO	99.95	199.90	2026-01-28 00:24:38.256308+00	BRO	9.64	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ca957b05-f901-457a-bb3f-4d2f51560b34_1771768425176.jpg	22-1-02-300-0277_1	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ca957b05-f901-457a-bb3f-4d2f51560b34_1771768425176.jpg}
4f2c3123-b08d-4515-8cde-dfcff86273bc	UP018	Calça Legging Cocoa Everybeat	126.90	195.45	2026-01-28 00:24:34.143699+00	Ange	6.93	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/4f2c3123-b08d-4515-8cde-dfcff86273bc_1771846466612.jpg	LG18440/cocoa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/4f2c3123-b08d-4515-8cde-dfcff86273bc_1771846466612.jpg}
5222e144-e660-49e4-98a8-45093105323e	UP022	CALÇA LEGGING PISTACHE RISE	148.50	218.67	2026-01-28 00:24:35.540934+00	Ange	5.56	4.62	f	Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/5222e144-e660-49e4-98a8-45093105323e_1771846854412.jpg	LG18428/pistache	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/5222e144-e660-49e4-98a8-45093105323e_1771846854412.jpg}
aeb598db-17f0-4e9a-8804-cc5d10b440d4	UP045	LEGGING ASSIMETRICA LISTRAS E BOLSO VERMELHO VIBRANTE	149.90	320.00	2026-01-28 00:24:45.925396+00	Alto Giro	6.36	4.62	f	VERMELHO VIBRANTE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319588_1769559885373.jpg	319588	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319588_1769559885373.jpg}
6285de86-72ae-494c-896e-2089dab313a4	UP046	LEGGING COM RECORTES E SILK AZUL CRISTALINO	174.90	370.00	2026-01-28 00:24:46.844176+00	Alto Giro	6.36	4.62	f	AZUL CRISTALINO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322728_1769559886333.jpg	322728	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322728_1769559886333.jpg}
324a4866-e38e-4841-b189-c834b04f5205	UP047	LEGGING ELASTICO VERDE PRIMAVERA	149.90	320.00	2026-01-28 00:24:47.488687+00	Alto Giro	6.36	4.62	f	VERDE PRIMAVERA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319612_1769559887023.jpg	319612	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319612_1769559887023.jpg}
ecfc88c2-959c-42d7-92a1-cb6108b8330c	UP049	LEGGING ESSENTIALS AZUL LAGOA	129.90	260.00	2026-01-28 00:24:48.694779+00	Alto Giro	6.36	4.62	f	AZUL LAGOA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320522_1769559888005.jpg	320522	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320522_1769559888005.jpg}
bab94c54-9ef3-4197-9f5c-a0bbe357d309	UP050	LEGGING ESSENTIALS PRETO	129.90	270.00	2026-01-28 00:24:49.371516+00	Alto Giro	6.36	4.62	f	ESSENTIALS PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319145_1769559888886.jpg	319145	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319145_1769559888886.jpg}
5275a586-1b84-462a-b6f0-4eb0684d9cfe	UP051	LEGGING ESSENTIALS VERDE ESCURO	129.90	260.00	2026-01-28 00:24:50.123299+00	Alto Giro	6.36	4.62	f	VERDE ESCURO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319150_1769559889546.jpg	319150	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319150_1769559889546.jpg}
87e4682f-f04a-4e7c-88e9-0829fda3d325	UP052	LEGGING ETERNA COM BOLSO VERDE CALIDO	124.90	270.00	2026-01-28 00:24:50.816972+00	Alto Giro	6.36	4.62	f	VERDE CALIDO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320379_1769559890305.jpg	320379	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320379_1769559890305.jpg}
b70e4e91-97dc-47bd-8145-cc47cd6c4d76	UP055	LEGGING FUSÔ BALANCE	114.90	249.90	2026-01-28 00:24:52.697521+00	Vestem	0	4.62	f	C0575 - VERMELHO GRENADINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1524.V26_C0575_1769559892261.webp	FS1524.V26_C0575	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1524.V26_C0575_1769559892261.webp}
6f62ece9-e90b-491f-8545-4a95dafd4333	UP056	LEGGING FUSÔ BICOLOR FLEX	129.90	289.90	2026-01-28 00:24:53.318738+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1528.V26_C0173_1769559892875.webp	FS1528.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1528.V26_C0173_1769559892875.webp}
c8bdd838-eaa4-43de-8086-821d7afa061c	UP057	LEGGING FUSÔ BICOLOR VIVID	139.90	299.90	2026-01-28 00:24:53.93103+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1538.V26_C0173_1769559893504.webp	FS1538.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1538.V26_C0173_1769559893504.webp}
484e09bc-a947-442b-928c-bd89a7e0c5cb	UP058	LEGGING FUSÔ BICOLOR VIVID	139.90	299.90	2026-01-28 00:24:54.530964+00	Vestem	0	4.62	f	C0515 - ROXO AMETISTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1538.V26_C0515_1769559894102.webp	FS1538.V26_C0515	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1538.V26_C0515_1769559894102.webp}
8a010270-dd77-4bae-b479-312888222b7e	UP059	LEGGING FUSO COM BOLSOS CALM	121.90	269.00	2026-01-28 00:24:55.147923+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1559.V26_C0173_1769559894696.webp	FS1559.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1559.V26_C0173_1769559894696.webp}
6b2b4cd3-7722-463a-b9b7-b9ff98a3fd79	UP060	LEGGING FUSÔ COM BOLSOS MOVEMENT	149.90	329.90	2026-01-28 00:24:56.002061+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1522.V26_C0002_1769559895337.webp	FS1522.V26_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1522.V26_C0002_1769559895337.webp}
17651cc2-5ea4-4d8b-9a28-d829bcfa1abe	UP061	LEGGING FUSÔ COM BOLSOS MOVEMENT	149.90	329.90	2026-01-28 00:24:56.774777+00	Vestem	0	4.62	f	C0575 - VERMELHO GRENADINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1522.V26_C0575_1769559896394.webp	FS1522.V26_C0575	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1522.V26_C0575_1769559896394.webp}
d88b3467-2808-4435-8722-330c89f4dc47	UP062	LEGGING FUSÔ ELÁSTICO IMPULSE	144.90	299.90	2026-01-28 00:24:57.315997+00	Vestem	0	4.62	f	C0084 - AZUL SUBMARINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1537.V26_C0084_1769559896946.webp	FS1537.V26_C0084	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1537.V26_C0084_1769559896946.webp}
e9cd840d-7841-4501-bef1-d98121c15833	UP063	LEGGING FUSÔ GLOW	119.90	269.90	2026-01-28 00:24:58.012366+00	Vestem	0	4.62	f	C0538 - ROXO HORTENSIA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1530.V26_C0538_1769559897502.webp	FS1530.V26_C0538	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1530.V26_C0538_1769559897502.webp}
f6fb68a7-c01d-4417-94d2-0922286b048d	UP064	LEGGING FUSÔ HYPE	149.90	234.00	2026-01-28 00:24:58.599363+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1460.I25_C0002_1769559898198.webp	FS1460.I25_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1460.I25_C0002_1769559898198.webp}
00a58446-4e64-4cf1-9bf8-caae7a3a1ac1	UP067	LEGGING FUSÔ MYSTICAL	112.90	249.90	2026-01-28 00:25:00.467539+00	Vestem	0	4.62	f	E1341.V26 - VESTEM VERDE HERA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1535.V26_E1341.V26_1769559900079.webp	FS1535.V26_E1341.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1535.V26_E1341.V26_1769559900079.webp}
f5cf970b-cd2e-4074-ba56-ff9f6eed6013	UP068	LEGGING FUSÔ MYSTICAL	112.90	249.90	2026-01-28 00:25:01.093121+00	Vestem	0	4.62	f	E1342.V26 - VESTEM AZUL RETRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1535.V26_E1342.V26_1769559900666.webp	FS1535.V26_E1342.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1535.V26_E1342.V26_1769559900666.webp}
166da7ab-bc8a-4ff7-9bbe-1295d3c8d018	UP069	LEGGING FUSO PUSH UPS	149.90	329.00	2026-01-28 00:25:01.792983+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1561.V26_C0257_1769559901269.webp	FS1561.V26_C0257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1561.V26_C0257_1769559901269.webp}
c76c15fa-3429-45fe-986a-d38dd9065e4f	UP071	LEGGING FUSO SEAMLESS ELIS	99.90	219.90	2026-01-28 00:25:03.062991+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0257_1769559902639.webp	FS1357.V26_C0257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0257_1769559902639.webp}
1aeaf07c-7ac5-4914-932f-01e637ac21bb	UP070	LEGGING FUSÔ SCULPTING BASS	114.90	209.00	2026-01-28 00:25:02.429511+00	Vestem	0	4.62	f	E1308.I25 - JAGUAR NOTURNO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1456.I25_E1308.I25_1769559901971.webp	FS1456.I25_E1308.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1456.I25_E1308.I25_1769559901971.webp}
4c744423-e7a5-44a9-88d9-9ae2bcee022b	UP065	LEGGING FUSO LISBOA	119.90	209.00	2026-01-28 00:24:59.23921+00	Vestem	0	4.62	f	C0512 - VERDE EDEN	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1488.I25_C0512_1769559898780.webp	FS1488.I25_C0512	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1488.I25_C0512_1769559898780.webp}
cca084fb-beb8-44ba-aadd-e113cb1b3ea4	UP043	JAQUETA CORTA VENTO CRISTALE	190.45	369.90	2026-01-28 00:24:44.582038+00	BRO	9.64	4.62	f	UVA ROSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/cca084fb-beb8-44ba-aadd-e113cb1b3ea4_1770146493866.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/cca084fb-beb8-44ba-aadd-e113cb1b3ea4_1770146493866.jpg}
ab5cde9d-8617-4a59-ba71-23823bc4972b	UP073	LEGGING FUSO SEAMLESS ELIS	99.90	219.90	2026-01-28 00:25:04.021192+00	Vestem	0	4.62	f	C0601 - MARROM COFFEE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0601_1769559903577.webp	FS1357.V26_C0601	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0601_1769559903577.webp}
a8f9fedc-57eb-402f-b5a8-65f03b97f1a8	UP076	LEGGING FUSO TRICOLOR FORCE	124.90	279.00	2026-01-28 00:25:05.89446+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1542.V26_C0002_1769559905412.webp	FS1542.V26_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1542.V26_C0002_1769559905412.webp}
06407111-0b94-4b5a-be8c-b03601192c0f	UP079	LEGGING FUSO TRICOLOR TREK	139.90	210.00	2026-01-28 00:25:07.829833+00	Vestem	0	4.62	f	C0558 - MARINHO ESCURIDAO/ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1477.I25_C0558_1769559907451.webp	FS1477.I25_C0558	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1477.I25_C0558_1769559907451.webp}
e640cbfb-4205-4826-9f51-6c5db0b6f6a3	UP080	LEGGING SHAPE UP LOGOMANIA MYST	109.90	239.90	2026-01-28 00:25:08.35458+00	Vestem	0	4.62	f	E1289.V25 - VESTEM SHOCK	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1289.V25_1769559907997.webp	FS1372.ESS_E1289.V25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1289.V25_1769559907997.webp}
f5dd7fd3-05fb-4fd3-be0e-1931e62400ec	UP083	LEGGING SHAPE UP LOGOMANIA MYST	109.90	239.90	2026-01-28 00:25:10.028982+00	Vestem	0	4.62	f	E1344.I25 - VESTEM ADRENALINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1344.I25_1769559909637.webp	FS1372.ESS_E1344.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1344.I25_1769559909637.webp}
d6f3a94c-f481-4ce2-a8ac-5bc0cf146b72	UP084	LEGGING SUSTENTACAO RECORTES TULE PRETO	184.90	380.00	2026-01-28 00:25:10.648464+00	Alto Giro	6.36	4.62	f	TULE PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319827_1769559910204.jpg	319827	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319827_1769559910204.jpg}
629803ab-5af1-4d33-952e-439da2d8c1c1	UP085	LEGGING TEXTURAS E CONTORNO PRETO	169.90	360.00	2026-01-28 00:25:11.320562+00	Alto Giro	6.36	4.62	f	CONTORNO PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319832_1769559910816.jpg	319832	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319832_1769559910816.jpg}
a88f20ac-2cdd-448f-8ecc-83301fd91232	UP086	MACACAO DUBLIN	189.90	419.00	2026-01-28 00:25:12.135876+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/MAC269.V26_C0002_1769559911746.webp	MAC269.V26_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/MAC269.V26_C0002_1769559911746.webp}
4edfee0b-4759-4c94-8f6d-0c7faf1d696a	UP087	MACACAO DUBLIN	189.90	419.00	2026-01-28 00:25:12.964063+00	Vestem	0	4.62	f	C0292 - VERDE CROCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/MAC269.V26_C0292_1769559912530.webp	MAC269.V26_C0292	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/MAC269.V26_C0292_1769559912530.webp}
7d44dcae-2896-4cc3-a263-0fa96255ee45	UP089	REGATA COSTAS TRANSPASSADA DELMAR	73.90	139.00	2026-01-28 00:25:14.288427+00	Vestem	0	4.62	f	C0527 - LARANJA CAMELIA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/REG12.ESS_C0527_1769559913728.webp	REG12.ESS_C0527	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/REG12.ESS_C0527_1769559913728.webp}
bca813d2-0870-4fb4-b690-3b8ce744ca3c	UP108	SHORTS BICOLOR VIVID	86.90	189.90	2026-01-28 00:25:23.093809+00	Vestem	0	4.62	f	C0001 - BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH721.V26_C0001_1769559922452.webp	SH721.V26_C0001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH721.V26_C0001_1769559922452.webp}
32a6d01e-f913-44e2-9872-c04f433046fb	UP109	SHORTS ELASTICO PERSONALIZADO E TULE AZUL BLUEBERRY	99.90	210.00	2026-01-28 00:25:23.796027+00	Alto Giro	6.36	4.62	f	AZUL BLUEBERRY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322848_1769559923309.jpg	322848	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322848_1769559923309.jpg}
d495480f-e043-47f9-a70e-7b79eea14777	UP110	SHORTS ETERNO COS ALTO AZUL CRISTALINO	72.90	150.00	2026-01-28 00:25:24.648626+00	Alto Giro	6.36	4.62	f	AZUL CRISTALINO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318729_1769559923967.jpg	318729	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318729_1769559923967.jpg}
78ab4a79-1959-47b7-b3d3-f3050f815489	UP078	LEGGING FUSO TRICOLOR TREK	139.90	239.00	2026-01-28 00:25:06.810898+00	Vestem	0	4.62	f	C0557 - AZUL JEANS/MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1477.I25_C0557_1769559906394.webp	FS1477.I25_C0557	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1477.I25_C0557_1769559906394.webp}
7f9e2a22-cbe1-4b3f-979d-1f58e1fbbb97	UP074	LEGGING FUSO SEAMLESS ELIS	99.90	219.90	2026-01-28 00:25:04.840459+00	Vestem	0	4.62	f	C0608 - VERMELHO DESEJO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0608_1769559904445.webp	FS1357.V26_C0608	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1357.V26_C0608_1769559904445.webp}
f1e2c779-0cb7-4341-a46b-b7aac9105bd2	UP103	SHORT JULY	109.50	210.00	2026-01-28 00:25:20.869089+00	BRO	9.64	4.62	f	VERDE MINT	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/f1e2c779-0cb7-4341-a46b-b7aac9105bd2_1770146920326.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/f1e2c779-0cb7-4341-a46b-b7aac9105bd2_1770146920326.jpg}
d1cef6b1-1344-414a-a7dc-f871f502c42a	UP098	SHORT BOXER SENSE	95.20	199.90	2026-01-28 00:25:18.64233+00	BRO	9.64	4.62	f	CREME	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d1cef6b1-1344-414a-a7dc-f871f502c42a_1770145804881.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d1cef6b1-1344-414a-a7dc-f871f502c42a_1770145804881.jpg}
d69c6f1a-ffb2-4faf-aa55-974f59e94bf4	UP093	REGATA FITNESS DANIELE	69.00	139.90	2026-01-28 00:25:16.373583+00	BRO	9.64	4.62	f	ROXO AMETISTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d69c6f1a-ffb2-4faf-aa55-974f59e94bf4_1770146355889.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d69c6f1a-ffb2-4faf-aa55-974f59e94bf4_1770146355889.jpg}
c4c02bd8-32b4-4477-944e-359394fe8d3d	UP091	REGATA FITNESS DANIELE	69.00	139.90	2026-01-28 00:25:15.21306+00	BRO	9.64	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c4c02bd8-32b4-4477-944e-359394fe8d3d_1770146405983.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c4c02bd8-32b4-4477-944e-359394fe8d3d_1770146405983.jpg}
2eedfd04-a261-4e1f-80e7-569c5c6e05b9	UP105	SHORT NUDE RIPPLE	71.01	141.19	2026-01-28 00:25:21.577143+00	Ange	5.56	4.62	f	Nude	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2eedfd04-a261-4e1f-80e7-569c5c6e05b9_1771533816920.jpg	SH1514/nude	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2eedfd04-a261-4e1f-80e7-569c5c6e05b9_1771533816920.jpg}
1e7430fa-ca57-41dc-a6ae-e879229da39b	UP107	SHORT VINHO EARTH	72.21	162.39	2026-01-28 00:25:22.27997+00	Ange	5.56	4.62	f	Vinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/1e7430fa-ca57-41dc-a6ae-e879229da39b_1771846674556.jpg	SH1515/vinho	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/1e7430fa-ca57-41dc-a6ae-e879229da39b_1771846674556.jpg}
f9ecc97f-22e3-4b87-abb6-f1ff65cd95be	UP095	Short Areia Everylift	105.05	183.52	2026-01-28 00:25:17.314666+00	Ange	6.93	4.62	f	Creme	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/f9ecc97f-22e3-4b87-abb6-f1ff65cd95be_1771846810390.jpg	SH1526/areia	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/f9ecc97f-22e3-4b87-abb6-f1ff65cd95be_1771846810390.jpg}
714c73bc-4dcb-4d63-93e3-7871bf8af0bb	UP113	SHORTS SEAMLESS ELIS	59.90	129.90	2026-01-28 00:25:26.78464+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH577.V26_C0257_1769559926234.webp	SH577.V26_C0257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH577.V26_C0257_1769559926234.webp}
6bba510d-f3a4-4806-ab18-5d2095022144	UP114	SHORTS SHAPE UP LOGOMANIA MYST	64.90	139.90	2026-01-28 00:25:27.393568+00	Vestem	0	4.62	f	E1343.I25 - VESTEM CACTUS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH579.ESS_E1343.I25_1769559926962.webp	SH579.ESS_E1343.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/SH579.ESS_E1343.I25_1769559926962.webp}
ce9a4cf1-d4e1-4699-b547-373ab022c6c6	UP115	SHORTS SOBREPOSTO COS DE ELASTICO PRETO	164.90	320.00	2026-01-28 00:25:28.054143+00	Alto Giro	6.36	4.62	f	ELASTICO PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318846_1769559927560.jpg	318846	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318846_1769559927560.jpg}
fb0297cc-dc85-4d25-8294-28a449672fc9	UP116	T-SHIRT ETERNA GOLA V AZUL BLUEBERRY	86.90	160.00	2026-01-28 00:25:28.840642+00	Alto Giro	6.36	4.62	f	AZUL BLUEBERRY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319976_1769559928226.jpg	319976	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319976_1769559928226.jpg}
70d64c00-4d7d-4b67-9cee-739ca9d062d0	UP117	T-SHIRT ETERNA GOLA V ROSA DOCE	86.90	160.00	2026-01-28 00:25:29.549631+00	Alto Giro	6.36	4.62	f	ROSA DOCE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319969_1769559929011.jpg	319969	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319969_1769559929011.jpg}
ff195db1-072f-4d00-b808-4fceeb13362a	UP118	T-SHIRT ETERNA GOLA V VERDE BRISA	86.90	160.00	2026-01-28 00:25:30.221053+00	Alto Giro	6.36	4.62	f	VERDE BRISA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319961_1769559929720.jpg	319961	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319961_1769559929720.jpg}
c74b9db9-716a-46ba-b5a4-11b3983ae74d	UP119	T-SHIRT ETERNA GOLA V VERMELHO VIBRANTE	86.90	160.00	2026-01-28 00:25:30.879311+00	Alto Giro	6.36	4.62	f	VERMELHO VIBRANTE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319965_1769559930421.jpg	319965	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319965_1769559930421.jpg}
6f6a7e5e-8263-429f-b753-e2175699836b	UP120	TOP ALTA SUSTENTAÇÃO ELÁSTICO IMPULSE	99.90	199.90	2026-01-28 00:25:31.699974+00	Vestem	0	4.62	f	C0084 - AZUL SUBMARINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1188.V26_C0084_1769559931093.webp	TOP1188.V26_C0084	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1188.V26_C0084_1769559931093.webp}
f6035591-635d-44b0-9217-87e80cb5acab	UP121	TOP ALTA SUSTENTAÇÃO MOTION	94.90	133.00	2026-01-28 00:25:32.280801+00	Vestem	0	4.62	f	C0550 - EBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1130.I25_C0550_1769559931869.webp	TOP1130.I25_C0550	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1130.I25_C0550_1769559931869.webp}
665b3def-961c-4622-8c39-383a27f90e11	UP122	TOP ALTO GIRO SPORT VERDE ESCURO	98.90	200.00	2026-01-28 00:25:32.822972+00	Alto Giro	6.36	4.62	f	VERDE ESCURO 	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319140_1769559932456.jpg	319140	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319140_1769559932456.jpg}
3fbdb66b-d910-435f-b711-72813863cddb	UP133	TOP DUPLA FACE BICOLOR PRETO	104.90	220.00	2026-01-28 00:25:38.147643+00	Alto Giro	6.36	4.62	f	BICOLOR PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318860_1769559937593.jpg	318860	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318860_1769559937593.jpg}
b49bac40-5aca-44ea-91f9-36b138fae931	UP135	TOP ELASTICO COSTAS NADADOR PRETO	124.90	240.00	2026-01-28 00:25:40.0917+00	Alto Giro	6.36	4.62	f	NADADOR PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318850_1769559939698.jpg	318850	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318850_1769559939698.jpg}
4f7973c8-04fb-4671-8819-74aa2dee4038	UP136	TOP ELASTICO PERSONALIZADO ALTO GIRO PRETO	89.90	200.00	2026-01-28 00:25:40.737623+00	Alto Giro	6.36	4.62	f	GIRO PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318968_1769559940264.jpg	318968	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318968_1769559940264.jpg}
32c571f7-ef80-4948-a2ad-18e0771263a6	UP137	TOP ELASTICO PERSONALIZADO ALTO GIRO ROSA DOCE	89.90	200.00	2026-01-28 00:25:41.426658+00	Alto Giro	6.36	4.62	f	ROSA DOCE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/321159_1769559940910.jpg	321159	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/321159_1769559940910.jpg}
f4d73fad-c742-4a57-bc32-aec016eeee73	UP138	TOP ELASTICO PERSONALIZADO ALTO GIRO VERDE CALIDO	89.90	200.00	2026-01-28 00:25:42.244309+00	Alto Giro	6.36	4.62	f	VERDE CALIDO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319721_1769559941595.jpg	319721	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319721_1769559941595.jpg}
2a072449-b424-45a7-8b27-bd3d72d50dfe	UP141	TOP FRENTE UNICA DUPLA FACE COM SILK AZUL CRISTALINO	119.90	270.00	2026-01-28 00:25:43.835739+00	Alto Giro	6.36	4.62	f	AZUL CRISTALINO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322845_1769559943341.jpg	322845	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/322845_1769559943341.jpg}
93151ba2-86b2-4cd9-8f3b-207c55ebae57	UP142	TOP LEVE SUSTENTAÇÃO HYPE	86.90	129.90	2026-01-28 00:25:44.701059+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1111.I25_C0002_1769559944255.webp	TOP1111.I25_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1111.I25_C0002_1769559944255.webp}
48bbde29-773a-414d-93fd-005ae14f6e5a	UP143	TOP LEVE SUSTENTAÇÃO PARK	73.90	149.90	2026-01-28 00:25:45.548667+00	Vestem	0	4.62	f	C0280 - VERDE MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0280_1769559945143.webp	TOP678.ESS_C0280	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0280_1769559945143.webp}
3aef3c68-a258-4f54-9526-223fda41c8aa	UP144	TOP LEVE SUSTENTAÇÃO PARK	73.90	139.90	2026-01-28 00:25:46.107525+00	Vestem	0	4.62	f	C0515 - ROXO AMETISTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0515_1769559945738.webp	TOP678.ESS_C0515	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0515_1769559945738.webp}
81ddfb56-c909-4b6c-8acd-2bc33e5516d5	UP145	TOP LEVE SUSTENTAÇÃO PARK	73.90	139.90	2026-01-28 00:25:46.760572+00	Vestem	0	4.62	f	C0550 - EBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0550_1769559946278.webp	TOP678.ESS_C0550	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0550_1769559946278.webp}
97fba60a-fae3-497d-bd3a-081ba65a7d11	UP134	TOP ELASTICO COSTAS NADADOR BRANCO OPTICO	124.90	240.00	2026-01-28 00:25:39.07419+00	Alto Giro	6.36	4.62	f	BRANCO OPTICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318851_1769559938536.jpg	318851	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318851_1769559938536.jpg}
dbc5252a-ad89-4603-9fd3-960f017fa9e2	UP132	TOP CROPPED SENSE	72.35	179.90	2026-01-28 00:25:37.389967+00	BRO	9.64	4.62	f	MANTEIGA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/dbc5252a-ad89-4603-9fd3-960f017fa9e2_1770145617359.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/dbc5252a-ad89-4603-9fd3-960f017fa9e2_1770145617359.jpg}
8fa37df0-d45e-4e32-a938-707801477ad0	UP130	TOP CROPPED SENSE	72.35	179.90	2026-01-28 00:25:36.241153+00	BRO	9.64	4.62	f	AZUL NEBLINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8fa37df0-d45e-4e32-a938-707801477ad0_1770142931727.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8fa37df0-d45e-4e32-a938-707801477ad0_1770142931727.jpg}
8d43f80f-32fc-4b5f-9ba5-feee72d699b3	UP127	Top Cocoa Everymove	87.09	153.64	2026-01-28 00:25:34.784203+00	Ange	6.93	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8d43f80f-32fc-4b5f-9ba5-feee72d699b3_1771527776237.jpg	TP10509/cocoa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8d43f80f-32fc-4b5f-9ba5-feee72d699b3_1771527776237.jpg}
acdbdc4b-b73c-4199-884b-1dd0db809e91	UP124	TOP BRANCO E-WELLNESS	71.49	131.67	2026-01-28 00:25:33.757551+00	Ange	5.56	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/acdbdc4b-b73c-4199-884b-1dd0db809e91_1771533734529.jpg	TP10488/branco	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/acdbdc4b-b73c-4199-884b-1dd0db809e91_1771533734529.jpg}
901030fe-f800-403c-863a-3714907a8816	UP146	TOP LEVE SUSTENTAÇÃO PARK	73.90	139.90	2026-01-28 00:25:47.339945+00	Vestem	0	4.62	f	E1343.I25 - VESTEM CACTUS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0515_1769559946949.webp	TOP678.ESS_C0515	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP678.ESS_C0515_1769559946949.webp}
4e36014a-55f9-497d-935a-8d1e4694a596	UP148	TOP LISBOA	86.90	209.00	2026-01-28 00:25:48.289651+00	Vestem	0	4.62	f	C0512 - VERDE EDEN	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1139.I25_C0512_1769559947854.webp	TOP1139.I25_C0512	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1139.I25_C0512_1769559947854.webp}
0f66d00d-9186-4d6d-b34e-46f468a0eebf	UP150	TOP MÉDIA SUSTENTAÇÃO AVIATOR	86.90	129.90	2026-01-28 00:25:49.410892+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1132.I25_C0173_1769559948863.webp	TOP1132.I25_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1132.I25_C0173_1769559948863.webp}
5cf3abf2-83b4-498b-9d73-6def36cdbb73	UP151	TOP MÉDIA SUSTENTAÇÃO BALANCE	86.90	189.90	2026-01-28 00:25:50.338706+00	Vestem	0	4.62	f	C0575 - VERMELHO GRENADINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1202.V26_C0575_1769559949834.webp	TOP1202.V26_C0575	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1202.V26_C0575_1769559949834.webp}
a9a02cf1-6036-425e-bbe2-1a4966fcecf3	UP152	TOP MÉDIA SUSTENTAÇÃO BASS	86.90	125.00	2026-01-28 00:25:51.064892+00	Vestem	0	4.62	f	E1308.I25 - JAGUAR NOTURNO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1104.I25_E1308.I25_1769559950533.webp	TOP1104.I25_E1308.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1104.I25_E1308.I25_1769559950533.webp}
d60c95e7-2789-4e1a-a865-f58b037f5d1e	UP153	TOP MÉDIA SUSTENTAÇÃO BICOLOR FLEX	99.90	219.00	2026-01-28 00:25:51.877207+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1528.V26_C0173_1769559951319.webp	FS1528.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1528.V26_C0173_1769559951319.webp}
6e056781-f22f-4806-bdde-c66288659526	UP154	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID	86.90	189.90	2026-01-28 00:25:52.529663+00	Vestem	0	4.62	f	C0001 - BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0001_1769559952053.webp	TOP1189.V26_C0001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0001_1769559952053.webp}
a1368013-65de-43a2-8f20-e4291147b298	UP155	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID	86.90	189.90	2026-01-28 00:25:53.408349+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0173_1769559952937.webp	TOP1189.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0173_1769559952937.webp}
4fe6ebd8-4172-4b00-a7fd-b056179e8257	UP156	TOP MÉDIA SUSTENTAÇÃO BICOLOR VIVID	86.90	189.90	2026-01-28 00:25:54.023505+00	Vestem	0	4.62	f	C0515 - ROXO AMETISTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0515_1769559953596.webp	TOP1189.V26_C0515	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1189.V26_C0515_1769559953596.webp}
36d81da0-e329-4843-8d92-f91d82256467	UP157	TOP MÉDIA SUSTENTAÇÃO BLISS	86.90	189.90	2026-01-28 00:25:54.739094+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1169.V26_C0257_1769559954209.webp	TOP1169.V26_C0257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1169.V26_C0257_1769559954209.webp}
d1c4ced5-0e3e-4c44-8f20-9d559bc13a43	UP158	TOP MÉDIA SUSTENTAÇÃO CALM	94.90	209.00	2026-01-28 00:25:55.356499+00	Vestem	0	4.62	f	C0173 - MARINHO ESCURIDAO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1185.V26_C0173_1769559954939.webp	TOP1185.V26_C0173	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1185.V26_C0173_1769559954939.webp}
23fb179e-1177-4a97-961b-35b11922582f	UP159	TOP MÉDIA SUSTENTAÇÃO FLOW	74.90	108.00	2026-01-28 00:25:55.897728+00	Vestem	0	4.62	f	C0280 - VERDE MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1083.I25_C0280_1769559955524.webp	TOP1083.I25_C0280	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1083.I25_C0280_1769559955524.webp}
133ceda7-5f0f-40c2-a994-cff417dc9e2b	UP160	TOP MÉDIA SUSTENTAÇÃO GLOW	86.90	189.90	2026-01-28 00:25:56.587386+00	Vestem	0	4.62	f	C0001 - BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1182.V26_C0001_1769559956093.webp	TOP1182.V26_C0001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1182.V26_C0001_1769559956093.webp}
b0b1e84f-3b81-468c-9b4d-4fb6819d9d2d	UP161	TOP MÉDIA SUSTENTAÇÃO GLOW	86.90	189.90	2026-01-28 00:25:57.712803+00	Vestem	0	4.62	f	C0538 - ROXO HORTENSIA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1182.V26_C0538_1769559957232.webp	TOP1182.V26_C0538	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1182.V26_C0538_1769559957232.webp}
b226cbb8-5781-41b3-8647-a2b88fe9cf58	UP162	TOP MEDIA SUSTENTACAO LOGOMANIA MYST	79.90	159.90	2026-01-28 00:25:58.43386+00	Vestem	0	4.62	f	C0550 - EBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1343.I25_1769559957900.webp	TOP1007.ESS_E1343.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1343.I25_1769559957900.webp}
810df6a5-30b2-481d-bb29-e84596b54f6b	UP163	TOP MEDIA SUSTENTACAO LOGOMANIA MYST	79.90	159.90	2026-01-28 00:25:59.041954+00	Vestem	0	4.62	f	E1289.V25 - VESTEM SHOCK	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1289.V25_1769559958611.webp	TOP1007.ESS_E1289.V25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1289.V25_1769559958611.webp}
aae971a1-9054-47ca-99ca-8d2d58524cb4	UP164	TOP MEDIA SUSTENTACAO LOGOMANIA MYST	79.90	159.90	2026-01-28 00:25:59.84424+00	Vestem	0	4.62	f	E1301.I25 - VESTEM FLAMINGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1301.I25_1769559959447.webp	TOP1007.ESS_E1301.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1301.I25_1769559959447.webp}
a1512a34-000d-4db6-92d4-30a445282977	UP165	TOP MEDIA SUSTENTACAO LOGOMANIA MYST	79.90	159.90	2026-01-28 00:26:00.456852+00	Vestem	0	4.62	f	E1332.V26 - VESTEM AZUL GAROA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1332.V26_1769559960029.webp	TOP1007.ESS_E1332.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1007.ESS_E1332.V26_1769559960029.webp}
97e44051-9e10-45e5-a711-72817bb30a3b	UP166	TOP MÉDIA SUSTENTAÇÃO MOVEMENT	99.90	209.00	2026-01-28 00:26:01.001729+00	Vestem	0	4.62	f	C0575 - VERMELHO GRENADINE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1174.V26_C0575_1769559960632.webp	TOP1174.V26_C0575	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1174.V26_C0575_1769559960632.webp}
4c514054-93ff-408e-8c50-8420cf8e0e59	UP167	TOP MÉDIA SUSTENTAÇÃO MYSTICAL	86.90	189.90	2026-01-28 00:26:01.713168+00	Vestem	0	4.62	f	E1341.V26 - VESTEM VERDE HERA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1186.V26_E1341.V26_1769559961181.webp	TOP1186.V26_E1341.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1186.V26_E1341.V26_1769559961181.webp}
e6dcde65-5c3d-4edb-98af-3dd0b6bd878c	UP168	TOP MÉDIA SUSTENTAÇÃO MYSTICAL	86.90	189.90	2026-01-28 00:26:02.425682+00	Vestem	0	4.62	f	E1342.V26 - VESTEM AZUL RETRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1186.V26_E1342.V26_1769559961892.webp	TOP1186.V26_E1342.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1186.V26_E1342.V26_1769559961892.webp}
93bd5d41-ce0e-481d-86ae-f466a371adf8	UP169	TOP MÉDIA SUSTENTAÇÃO TREK	94.90	143.93	2026-01-28 00:26:03.167899+00	Vestem	0	4.62	f	C0557 - AZUL JEANS/MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1147.I25_C0557_1769559962791.webp	TOP1147.I25_C0557	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1147.I25_C0557_1769559962791.webp}
fba58f93-8a7d-48f3-8008-608ba8dcf407	UP170	TOP MÉDIA SUSTENTAÇÃO TREK	94.90	143.93	2026-01-28 00:26:04.058847+00	Vestem	0	4.62	f	C0558 - MARINHO ESCURIDAO/ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1147.I25_C0558_1769559963587.webp	TOP1147.I25_C0558	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1147.I25_C0558_1769559963587.webp}
b5bbae07-250d-478b-9fe9-b641f8f64561	UP171	TOP MÉDIA SUSTENTAÇÃO VESTEM ATHLETICA	79.90	115.00	2026-01-28 00:26:04.673627+00	Vestem	0	4.62	f	E1303.I25 - VESTEM ATHLETICA URBAN	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1119.I25_E1303.I25_1769559964226.webp	TOP1119.I25_E1303.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP1119.I25_E1303.I25_1769559964226.webp}
0bd12109-1bc9-4aca-bbeb-4a830e1e189b	UP172	TOP NADADOR ELASTICO PERSONALIZADO AZUL BLUEBERRY	92.90	205.00	2026-01-28 00:26:05.344492+00	Alto Giro	6.36	4.62	f	AZUL BLUEBERRY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319801_1769559964854.jpg	319801	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319801_1769559964854.jpg}
511252b4-4a5e-433a-ac9d-e31fd182144a	UP173	TOP ELASTICO PERSONALIZADO ALTO GIRO	92.90	229.90	2026-01-28 00:26:06.104314+00	Alto Giro	6.36	4.62	f	BRANCO OPTICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319766_1769559965536.jpg	319766	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319766_1769559965536.jpg}
97a1ff92-f4a2-4f35-9d24-231c598fd6b9	UP174	TOP NADADOR ELASTICO PERSONALIZADO VERDE PRIMAVERA	92.90	205.00	2026-01-28 00:26:06.880952+00	Alto Giro	6.36	4.62	f	VERDE PRIMAVERA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319770_1769559966495.jpg	319770	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/319770_1769559966495.jpg}
c859f056-4e38-4fb1-88ae-0ff574625416	UP178	TOP SEAMLESS ELIS	69.90	149.90	2026-01-28 00:26:08.67073+00	Vestem	0	4.62	f	C0257 - AZUL JEANS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0257_1769559968092.webp	TOP997.V26_C0257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0257_1769559968092.webp}
b08361e8-e792-49e3-bbfc-df7230e45714	UP179	TOP SEAMLESS ELIS	69.90	149.90	2026-01-28 00:26:09.585502+00	Vestem	0	4.62	f	C0601 - MARROM COFFEE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0601_1769559969068.webp	TOP997.V26_C0601	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0601_1769559969068.webp}
03c428f1-287d-4195-9cb0-44906ca53ce6	UP180	TOP SEAMLESS ELIS	69.90	149.90	2026-01-28 00:26:10.712365+00	Vestem	0	4.62	f	C0608 - VERMELHO DESEJO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0608_1769559970001.webp	TOP997.V26_C0608	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/TOP997.V26_C0608_1769559970001.webp}
4bb37cc9-72b8-40b6-b4e3-d4aa4ebe67f7	UP081	LEGGING SHAPE UP LOGOMANIA MYST	109.90	229.90	2026-01-28 00:25:09.133292+00	Vestem	0	4.62	f	E1301.I25 - VESTEM FLAMINGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1301.I25_1769559908747.webp	FS1372.ESS_E1301.I25	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1372.ESS_E1301.I25_1769559908747.webp}
0ef1c1c9-8c50-44e9-98c1-89a87e856803	UP066	LEGGING FUSO LISBOA	119.90	209.00	2026-01-28 00:24:59.804549+00	Vestem	0	4.62	f	C0515 - ROXO AMETISTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1488.I25_C0515_1769559899415.webp	FS1488.I25_C0515	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/FS1488.I25_C0515_1769559899415.webp}
0f044716-0ce3-4984-bc8c-4a6f00c8c8c7	UP184	TOP VERSATIL FRENTE E COSTAS PRETO	134.90	240.00	2026-01-28 00:26:12.564323+00	Alto Giro	6.36	4.62	f	COSTAS PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320753_1769559971966.jpg	320753	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/320753_1769559971966.jpg}
59aec366-a55e-4aa9-88d8-5659a6ce3af5	UP042	JAQUETA CORTA VENTO CRISTALE	190.45	369.90	2026-01-28 00:24:44.238565+00	BRO	9.64	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/59aec366-a55e-4aa9-88d8-5659a6ce3af5_1770146660343.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/59aec366-a55e-4aa9-88d8-5659a6ce3af5_1770146660343.jpg}
a34ab995-352a-4372-b146-d5cd1824f9ae	UP149	TOP MARROM DUPLA FACE RIPPLE	74.96	135.14	2026-01-28 00:25:48.67643+00	Ange	5.56	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a34ab995-352a-4372-b146-d5cd1824f9ae_1771527531700.jpg	TP10484/marrom	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a34ab995-352a-4372-b146-d5cd1824f9ae_1771527531700.jpg}
546abfef-6887-47c3-8357-f9f549784f09	UP111	SHORTS ETERNO COS ALTO VERDE PRIMAVERA	72.90	199.90	2026-01-28 00:25:25.359901+00	Alto Giro	6.36	4.62	f	 VERDE PRIMAVERA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318713_1769559924874.jpg	318713	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/318713_1769559924874.jpg}
98421a47-135d-40a1-91f6-2f93c718f08b	UP140	TOP FITNESS SUMMER	76.10	189.90	2026-01-28 00:25:43.16382+00	BRO	9.64	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/98421a47-135d-40a1-91f6-2f93c718f08b_1770142704204.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/98421a47-135d-40a1-91f6-2f93c718f08b_1770142704204.jpg}
7223beff-dc9d-4b53-8c4c-658b3763a6ea	UP029	COLETE JULY	190.40	289.90	2026-01-28 00:24:39.298533+00	BRO	9.64	4.62	f	MOSTARDA DIJON	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7223beff-dc9d-4b53-8c4c-658b3763a6ea_1770146703017.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7223beff-dc9d-4b53-8c4c-658b3763a6ea_1770146703017.jpg}
b550dd7b-3d20-4049-88ec-0b09875a58b1	UP131	TOP CROPPED SENSE	72.35	179.90	2026-01-28 00:25:36.818991+00	BRO	9.64	4.62	f	CREME	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/b550dd7b-3d20-4049-88ec-0b09875a58b1_1770145713081.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/b550dd7b-3d20-4049-88ec-0b09875a58b1_1770145713081.jpg}
d61bf2c1-9320-4a1b-9b7c-5d51c0ae1a00	UP102	SHORT JULY	109.50	210.00	2026-01-28 00:25:20.530096+00	BRO	9.64	4.62	f	MOSTARDA DIJON	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d61bf2c1-9320-4a1b-9b7c-5d51c0ae1a00_1770146726198.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d61bf2c1-9320-4a1b-9b7c-5d51c0ae1a00_1770146726198.jpg}
ecfe6c61-24fe-406d-a552-31ef3a28b4e3	UP099	SHORT BOXER SENSE	95.20	199.90	2026-01-28 00:25:19.249511+00	BRO	9.64	4.62	f	MANTEIGA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ecfe6c61-24fe-406d-a552-31ef3a28b4e3_1770145771226.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ecfe6c61-24fe-406d-a552-31ef3a28b4e3_1770145771226.jpg}
c63e0319-a5ae-463e-9b82-b98bb96a604d	UP028	COLETE CRISTALE	188.05	319.00	2026-01-28 00:24:38.948325+00	BRO	9.64	4.62	f	UVA ROSE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c63e0319-a5ae-463e-9b82-b98bb96a604d_1770145849969.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c63e0319-a5ae-463e-9b82-b98bb96a604d_1770145849969.jpg}
67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2	UP097	SHORT BOXER SENSE	95.20	199.90	2026-01-28 00:25:18.035813+00	BRO	9.64	4.62	f	AZUL NEBLINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2_1770145994131.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/67d8c093-02e2-4f8a-a1fb-a1c7c8f0b1c2_1770145994131.jpg}
10b05256-8c65-4a61-b046-7f5e5ce22ae9	UP092	REGATA FITNESS DANIELE	69.00	139.90	2026-01-28 00:25:15.811567+00	BRO	9.64	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/10b05256-8c65-4a61-b046-7f5e5ce22ae9_1770146381094.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/10b05256-8c65-4a61-b046-7f5e5ce22ae9_1770146381094.jpg}
fb6ada2a-d736-4f84-973a-0e74cd0d511a	UP044	JAQUETA FITNESS NICK	148.75	299.90	2026-01-28 00:24:44.958381+00	BRO	9.64	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/fb6ada2a-d736-4f84-973a-0e74cd0d511a_1770146450973.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/fb6ada2a-d736-4f84-973a-0e74cd0d511a_1770146450973.jpg}
076a4890-e615-4d78-a90d-0163749b7bcc	UP128	TOP CREAM EVERYLIFT	75.69	135.87	2026-01-28 00:25:35.577433+00	Ange	5.56	4.62	f	Creme	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/076a4890-e615-4d78-a90d-0163749b7bcc_1771527676678.jpg	TP10500/cream	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/076a4890-e615-4d78-a90d-0163749b7bcc_1771527676678.jpg}
8127c5c0-e3b9-445e-8b63-47335531be49	UP183	TOP STORM EVERYFORM	79.54	193.71	2026-01-28 00:26:11.789891+00	Ange	5.56	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8127c5c0-e3b9-445e-8b63-47335531be49_1771527277756.jpg	TP10502/storm	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/8127c5c0-e3b9-445e-8b63-47335531be49_1771527277756.jpg}
ed3fed61-279f-42a1-95f8-15b43036464a	UP177	TOP ROSA EARTH	77.77	147.95	2026-01-28 00:26:07.909843+00	Ange	5.56	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ed3fed61-279f-42a1-95f8-15b43036464a_1771527419975.jpg	TP10481/rosa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ed3fed61-279f-42a1-95f8-15b43036464a_1771527419975.jpg}
06941075-893f-4448-b265-9ad9c812b79f	UP123	TOP AREIA RISE	74.99	135.17	2026-01-28 00:25:33.392537+00	Ange	5.56	4.62	f	Creme	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/06941075-893f-4448-b265-9ad9c812b79f_1771534163730.jpg	TP10491/areia	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/06941075-893f-4448-b265-9ad9c812b79f_1771534163730.jpg}
a22bb2c5-11d9-497c-bad0-5be877f784d4	UP005	Blusa Cocoa Everybeat	91.41	152.96	2026-01-28 00:24:23.56664+00	Ange	6.93	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a22bb2c5-11d9-497c-bad0-5be877f784d4_1771534232617.jpg	BL17173/cocoa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a22bb2c5-11d9-497c-bad0-5be877f784d4_1771534232617.jpg}
ee417b1f-2f0c-418b-94ef-4864d15d4658	UP090	REGATA DRY FIT AVIATOR	72.90	108.00	2026-01-28 00:25:14.638368+00	Vestem	0	4.62	f	C0002 - PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ee417b1f-2f0c-418b-94ef-4864d15d4658_1771783862514.jpg	REG814.I25_C0002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/ee417b1f-2f0c-418b-94ef-4864d15d4658_1771783862514.jpg}
0dba3d38-30b5-4ae1-ace9-98357a7185de	UP021	CALÇA LEGGING CREAM EVERYTIME	122.58	229.13	2026-01-28 00:24:35.187448+00	Ange	5.56	4.62	f	Creme	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/0dba3d38-30b5-4ae1-ace9-98357a7185de_1771846555311.jpg	LG18444/cream	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/0dba3d38-30b5-4ae1-ace9-98357a7185de_1771846555311.jpg}
4659bbd2-b530-4d22-80fb-d3bf752e4169	UP096	SHORT AREIA RISE	98.29	158.47	2026-01-28 00:25:17.68763+00	Ange	5.56	4.62	f	Creme	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/4659bbd2-b530-4d22-80fb-d3bf752e4169_1771846757440.jpg	SH1521/areia	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/4659bbd2-b530-4d22-80fb-d3bf752e4169_1771846757440.jpg}
80b0e230-bee4-46c0-9ff3-bf55b59955d5	UPF20267714	TOP PRETO FRAME	73.57	134.29	2026-02-23 18:44:09.733086+00	Ange	6.1	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20267714_1771872248230.jpg	TP10519	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20267714_1771872248230.jpg}
8bfdd37a-d956-4320-975c-b0ac0a319317	UPF20261475	SHORT CASUAL RUN	106.69	167.41	2026-02-23 18:45:52.500331+00	Ange	6.1	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261475_1771872351524.jpg	SH1544	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261475_1771872351524.jpg}
628d2222-2c97-4bae-bb3d-8dc41a48f187	UPF20268015	MACAQUINHO COCOA	148.85	259.57	2026-02-23 18:50:40.858816+00	Ange	6.1	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268015_1771872639337.jpg	MC1234	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268015_1771872639337.jpg}
21f63dde-aa95-4131-ab22-e8726166ce0d	UPF20264418	Top Mescla Ground	68.20	128.92	2026-02-23 18:52:11.083043+00	Ange	6.1	4.62	f	CINZA 	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264418_1771872730080.jpg	TP10517	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264418_1771872730080.jpg}
bfba079a-f6ab-4577-8619-53f3ba184a4a	UPF20266353	Short Mescla Ground	86.42	147.14	2026-02-23 18:54:13.122863+00	Ange	6.1	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20266353_1771872852278.jpg	SH1542	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20266353_1771872852278.jpg}
a76afd4d-507a-49bc-816b-4d7d3f5a3a69	UPF20265406	Jaqueta Mellow EveryPush	162.27	222.99	2026-02-23 18:57:08.693883+00	Ange	6.1	4.62	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265406_1771873027124.jpg	CS2044	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265406_1771873027124.jpg}
3131bb7b-5f21-4483-a4fd-e6a5242faff6	UPF20261621	Short Saia Mellow EveryMatch	165.27	225.99	2026-02-23 18:59:47.435364+00	Ange	6.1	4.62	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261621_1771873186338.jpg	SH1522	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261621_1771873186338.jpg}
bdb8a6de-0cf6-41d9-8acd-244113c3bf13	UPF20263983	Regata Mellow EveryMatch	71.61	132.33	2026-02-23 19:00:53.033735+00	Ange	6.1	4.62	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263983_1771873252252.jpg	BL17168	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263983_1771873252252.jpg}
3d294cbf-70af-48ee-a64b-3128fa402808	UPF20268941	Top Mescla SoftLine	94.38	155.10	2026-02-23 19:02:57.059854+00	Ange	6.1	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268941_1771873376353.jpg	TP10514	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268941_1771873376353.jpg}
c1de500b-d49f-42e2-ae2b-b67e1d8b495d	UPF20264466	Short Saia Cinza CasualMotion	140.48	201.20	2026-02-23 19:03:58.784627+00	Ange	6.1	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264466_1771873437834.jpg	SH1537	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264466_1771873437834.jpg}
fac47062-4296-46a9-845f-ae567089a3f9	UPF20263351	Regata Tule Celeste	59.15	129.90	2026-02-26 13:29:18.114223+00	BRO	3.41	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263351_1772112556760.jpg	0488BR0010000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263351_1772112556760.jpg}
a592bf06-b2ab-486c-8373-545c90dc2ff0	UPF20269491	Short Cinza CasualRun	106.69	167.41	2026-02-23 19:05:37.650964+00	Ange	6.1	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a592bf06-b2ab-486c-8373-545c90dc2ff0_1771873551497.jpg	SH1544	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a592bf06-b2ab-486c-8373-545c90dc2ff0_1771873551497.jpg}
ace6e53f-58f0-4935-8a7c-78fbd4ffdf46	UPF20261518	Top Versátil Cítrico	55.35	106.07	2026-02-23 19:11:36.302861+00	Ange	6.1	4.62	f	Citrico	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261518_1771873895183.jpg	TP10420	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261518_1771873895183.jpg}
c9052f3f-10d3-4641-b067-808fa8dedd85	UPF20265347	Short Básico Estampado	83.74	144.46	2026-02-24 10:48:40.056893+00	Ange	6.1	4.62	f	Cítrico	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265347_1771930119077.jpg	SH1411	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265347_1771930119077.jpg}
2482e124-00de-4933-94c9-6ef22273f033	UPF20268325	REGATA FITNESS DANIELE	80.90	139.90	2026-02-25 14:42:13.983268+00	BRO	3.41	4.62	f	Vermelho Batom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268325_1772030533055.jpg	0010VR016000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268325_1772030533055.jpg}
4f61e39d-59f6-4273-8804-94a48c7e068a	UPF20261176	Blusa Tule Básica	66.60	139.90	2026-02-25 14:41:01.031085+00	BRO	3.41	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261176_1772030459683.jpg	646PT00100000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261176_1772030459683.jpg}
b6c34d57-c96f-42c2-8af7-2fa01667273f	UPF20261821	Blusa Tule Básica	66.60	139.90	2026-02-25 14:38:19.632449+00	BRO	3.41	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261821_1772030297823.jpg	646AZ04700000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261821_1772030297823.jpg}
3f3156ab-e52d-44e2-98f6-bfd6d3ff1be3	UPF20268186	Regata Tule Celeste	59.15	129.90	2026-02-26 13:30:48.048715+00	BRO	3.41	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268186_1772112647081.jpg	0488PT0010000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268186_1772112647081.jpg}
1461ace4-6809-494e-a5a0-17eb0ab766e1	UPF20263588	Regata Tule Celeste	59.15	129.90	2026-02-26 13:32:38.815241+00	BRO	3.41	4.62	f	Rosa Tulipe	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263588_1772112757613.jpg	0488RS0470000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263588_1772112757613.jpg}
0fdea5e8-ce59-4581-a6dc-16be6cf0b27f	UPF20263064	Regata Tule Celeste	59.15	129.90	2026-02-26 13:25:02.586153+00	BRO	3.41	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/0fdea5e8-ce59-4581-a6dc-16be6cf0b27f_1772112439211.jpg	0488AZ0470000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/0fdea5e8-ce59-4581-a6dc-16be6cf0b27f_1772112439211.jpg}
d9010f7d-2788-41a1-b104-8e82bbdee1f2	UPF20269421	Regata Tule Celeste	59.15	129.90	2026-02-26 13:42:15.431961+00	BRO	3.41	4.62	f	Castanho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269421_1772113333867.jpg	0488VR013000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269421_1772113333867.jpg}
cec93d51-6aeb-484f-a139-cac515ba14c9	UPF20264621	BOMBER TEBAS	125.95	249.90	2026-02-26 19:09:09.266786+00	BRO	6.2	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264621_1772132948100.jpg	JQ0644	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264621_1772132948100.jpg}
94d5e287-ab10-4835-bd37-6b0f58171be2	UPF20268517	CALÇA LEGGING TEBAS	128.55	249.90	2026-02-26 19:11:44.809662+00	BRO	6.2	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268517_1772133103414.jpg	LG0644	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268517_1772133103414.jpg}
68561129-9cd1-4cbc-b434-a2e9da1a8d61	UPF20263764	CALÇA LEGGING MOTIV	138.05	259.90	2026-02-26 19:13:08.605556+00	BRO	6.2	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263764_1772133187429.jpg	LG0585	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263764_1772133187429.jpg}
cec11c74-39a6-489c-a603-ab4ae4a3b1ff	UPF20268096	CALÇA LEGGING ALEXANDRIA	176.10	339.90	2026-02-26 19:15:14.99344+00	BRO	6.2	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268096_1772133313467.jpg	LG0354	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20268096_1772133313467.jpg}
2b760f88-2bba-42f7-8a5d-4da95c1b864c	UPF20266623	MACAQUINHO FITNESS MOTIV	152.35	299.90	2026-02-26 19:14:13.990807+00	BRO	6.2	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2b760f88-2bba-42f7-8a5d-4da95c1b864c_1772200001806.jpg	MC0585C	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2b760f88-2bba-42f7-8a5d-4da95c1b864c_1772200001806.jpg}
0d3caf74-bd91-49de-aaf0-35021ed180d3	UPF20263062	COLETE DRY FIT INTENSE	109.90	199.90	2026-02-27 13:48:34.759427+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263062_1772200113431.jpg	COL10.PE	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263062_1772200113431.jpg}
ec9ab5f4-7f9e-46f1-ab0d-f8530834b1ac	UPF20262269	Top Nadador Essentials	62.23	198.00	2026-02-28 18:01:20.302657+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262269_1772301679282.jpg	2611504	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262269_1772301679282.jpg}
d35665ce-46f4-4b59-a491-eb22731c6422	UPF20262249	JAQUETA CORTA VENTO MOVEMENT	174.90	289.90	2026-02-27 13:50:24.159699+00	Vestem	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d35665ce-46f4-4b59-a491-eb22731c6422_1772227088879.jpg	JAC261.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d35665ce-46f4-4b59-a491-eb22731c6422_1772227088879.jpg}
597f8eee-6577-4da4-9db9-24022243d8ce	UPF20263956	Top Recorte Anatomico Ag	88.83	280.00	2026-02-28 13:29:22.058205+00	Alto Giro	4.62	0	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263956_1772285360888.jpg	2611510	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20263956_1772285360888.jpg}
227b75b5-3579-432d-b6ff-8c115323186d	UPF20269115	Legging Recorte Lateral Ag	139.23	380.00	2026-02-28 13:30:10.336728+00	Alto Giro	0	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269115_1772285409372.jpg	2611311	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269115_1772285409372.jpg}
cc6ae999-7249-48b5-9450-f13d7ec9f8c1	UPF20269099	Bermuda Eterna Shine	62.93	218.00	2026-02-28 13:34:32.885831+00	Alto Giro	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269099_1772285671667.jpg	2611140	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20269099_1772285671667.jpg}
c65bcd91-670c-46af-9dcb-d462ed643695	UPF20264354	Top Shine Alcas Finas	55.93	178.90	2026-02-28 13:35:25.924087+00	Alto Giro	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264354_1772285725094.jpg	2611541	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20264354_1772285725094.jpg}
28be9554-3198-41e3-8d90-8bc13d4df232	UPF20261760	Legging Elastico Personalizado Alto Giro	104.93	320.00	2026-02-28 18:03:31.243319+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261760_1772301810203.jpg	2611307	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261760_1772301810203.jpg}
1fb4200e-1c94-4dd8-8107-cdbe29c66158	UPF20268646	Legging Eterna Shine	90.93	280.00	2026-02-28 13:36:03.07204+00	Alto Giro	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/1fb4200e-1c94-4dd8-8107-cdbe29c66158_1772285774008.jpg	2611340	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/1fb4200e-1c94-4dd8-8107-cdbe29c66158_1772285774008.jpg}
8a12b1fa-aeac-4389-aa75-4258b198ceb6	UPF20261436	Macaquinho Anticelulite	111.93	310.00	2026-02-28 16:08:42.084248+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261436_1772294920740.jpg	2611470	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261436_1772294920740.jpg}
313449c2-742e-466c-9229-5a66c4105768	UPF20261158	T-shirt Cropped Elastico Personalizado	80.43	218.90	2026-02-28 16:14:49.773443+00	Alto Giro	0	4.62	f	Vinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261158_1772295287836.jpg	2611750	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261158_1772295287836.jpg}
c215f201-699a-4fe2-a842-7fea0c782a32	UPF20265447	Bermuda Elastico Personalizado	87.43	280.00	2026-02-28 16:15:45.609796+00	Alto Giro	0	4.62	f	Laranja	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265447_1772295344601.jpg	2611150	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265447_1772295344601.jpg}
8903dc04-754f-4653-8c72-c9fefdf35a8c	UPF20265933	Legging Elastico Personalizado	111.93	320.00	2026-02-28 16:17:33.90547+00	Alto Giro	0	4.62	f	Vinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265933_1772295452862.jpg	2611351	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265933_1772295452862.jpg}
afd5f46a-ecd0-46b9-9d4d-85fc13bafb44	UPF20265827	Top Nadador Elastico Personalizado	111.93	235.00	2026-02-28 16:18:58.17516+00	Alto Giro	0	4.62	f	Vinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265827_1772295536779.jpg	2611551	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265827_1772295536779.jpg}
8c39e65a-756a-4a23-b4ff-358643ab6fa0	UPF20265452	Legging Com Cordao E Bolsos	97.93	380.00	2026-02-28 17:58:30.802346+00	Alto Giro	0	4.62	f	Off White	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265452_1772301509789.jpg	2611301	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20265452_1772301509789.jpg}
e404c7b0-4099-43e3-b305-c855fd4b734d	UPF20261415	Top Elastico Personalizado Alto Giro	60.83	205.00	2026-02-28 18:04:17.463242+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261415_1772301856334.jpg	2611506	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261415_1772301856334.jpg}
5004a2d6-dabd-448a-b318-6c1be0952e81	UPF20262933	Top Bicolor Costas Cruzadas	88.55	220.00	2026-02-28 17:57:32.751597+00	Alto Giro	0	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262933_1772301451721.jpg	2611501	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262933_1772301451721.jpg}
66ff3218-0f96-4717-8e6a-967d40e6b736	UPF20261552	JAQUETA CORTA VENTO MOVEMENT	174.90	289.90	2026-02-27 13:51:37.779658+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261552_1772200296472.jpg	JAC261.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20261552_1772200296472.jpg}
fbe4fa70-fb78-492d-9608-27c11090a41a	UPF20266301	Bermuda Cos Elastico Bicolor	119.90	269.90	2026-02-28 17:53:36.46924+00	Alto Giro	0	4.62	f	Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/fbe4fa70-fb78-492d-9608-27c11090a41a_1772471916036.jpg	2611130	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/fbe4fa70-fb78-492d-9608-27c11090a41a_1772471916036.jpg}
c5a4b82c-029b-4f7a-96e5-c2298729d874	UPF20269321	Top Elastico Degrade	90.93	225.00	2026-03-02 15:26:07.464029+00	Alto Giro	0	4.62	f	Laranja	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c5a4b82c-029b-4f7a-96e5-c2298729d874_1772465903021.jpg	2611571	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/c5a4b82c-029b-4f7a-96e5-c2298729d874_1772465903021.jpg}
19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f	UPF20262609	Legging Elastico Degrade	97.93	320.00	2026-03-02 15:26:43.34812+00	Alto Giro	0	4.62	f	Laranja	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f_1772465925656.jpg	2611371	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/19c9fa59-5c66-4ce3-9af0-8bfdc04ad31f_1772465925656.jpg}
7b2dd504-50ee-45ab-83c1-8ce5552c3394	UPF20268014	Top Alcas Finas E Costas De Tule	62.93	235.00	2026-03-02 15:29:48.33289+00	Alto Giro	0	4.62	f	Azul Claro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7b2dd504-50ee-45ab-83c1-8ce5552c3394_1772466007494.jpg	2611590	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7b2dd504-50ee-45ab-83c1-8ce5552c3394_1772466007494.jpg}
b4a8c083-7ce3-463f-bd4d-c8418d6ba579	UPF20267915	Macaquinho Com Ziper E Elastico	139.23	310.00	2026-03-02 15:24:27.974782+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/b4a8c083-7ce3-463f-bd4d-c8418d6ba579_1774121162816.jpg	2611401	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/b4a8c083-7ce3-463f-bd4d-c8418d6ba579_1774121162816.jpg}
e90473b4-52a3-476e-b132-2a33caa81ee6	UPF20262732	Jaqueta Dry Com Elastico	153.93	365.00	2026-02-28 17:51:03.042884+00	Alto Giro	0	4.62	f	Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e90473b4-52a3-476e-b132-2a33caa81ee6_1772471956587.jpg	2611930	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e90473b4-52a3-476e-b132-2a33caa81ee6_1772471956587.jpg}
e289df1e-64bb-4091-8c72-0c72aec52501	UPF20261266	JAQUETA CORTA VENTO MOVEMENT	174.90	289.90	2026-02-27 13:53:28.223461+00	Vestem	0	4.62	f	Lavanda	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e289df1e-64bb-4091-8c72-0c72aec52501_1772697052838.jpg	JAC261.V26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e289df1e-64bb-4091-8c72-0c72aec52501_1772697052838.jpg}
e5e74ca4-e1d2-4f50-9561-d28d3b586d8a	UPF20262324	Legging Recortes Com Bolsos Laterais	118.93	320.00	2026-03-02 15:25:19.725484+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e5e74ca4-e1d2-4f50-9561-d28d3b586d8a_1772465879142.jpg	2611330	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e5e74ca4-e1d2-4f50-9561-d28d3b586d8a_1772465879142.jpg}
7513ef03-93f3-43ae-99cf-93749679bb1d	UPF20265236	Legging Recortes Tule	125.93	380.00	2026-03-02 15:29:12.177731+00	Alto Giro	0	4.62	f	Azul Claro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7513ef03-93f3-43ae-99cf-93749679bb1d_1772465987903.jpg	2611390	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/7513ef03-93f3-43ae-99cf-93749679bb1d_1772465987903.jpg}
d62c33d5-ff0e-4a95-be05-d1ed90c8f5cd	UPF20264388	Top Nadador Com Bolso	83.93	280.00	2026-03-02 15:32:44.544342+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d62c33d5-ff0e-4a95-be05-d1ed90c8f5cd_1772466033170.jpg	2611561	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d62c33d5-ff0e-4a95-be05-d1ed90c8f5cd_1772466033170.jpg}
e78ea427-c4f8-4611-a943-ad1488bf5756	UPF20265791	Legging Com Bolsos Laterais	111.93	380.00	2026-03-02 15:35:16.934453+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e78ea427-c4f8-4611-a943-ad1488bf5756_1772466051964.jpg	2611360	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e78ea427-c4f8-4611-a943-ad1488bf5756_1772466051964.jpg}
d20563f4-ccda-4cca-842f-ee62eaeb6e1b	UPF20261340	Bermuda Com Bolsos Laterais	87.43	290.00	2026-03-02 15:35:57.61068+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d20563f4-ccda-4cca-842f-ee62eaeb6e1b_1772466074048.jpg	2611160	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d20563f4-ccda-4cca-842f-ee62eaeb6e1b_1772466074048.jpg}
2105858a-d98b-4d00-b607-d618524b7e24	UPF20261886	Top Com Sobreposicao De Tule	111.23	220.00	2026-03-02 15:31:49.362865+00	Alto Giro	0	4.62	f	Cinza Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2105858a-d98b-4d00-b607-d618524b7e24_1772466123765.jpg	2611581	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/2105858a-d98b-4d00-b607-d618524b7e24_1772466123765.jpg}
83ad5336-0f31-494c-b249-7ff2edfc1814	UPF20264656	Legging Com Recortes De Tule	132.93	380.00	2026-03-02 15:30:49.656936+00	Alto Giro	0	4.62	f	Cinza Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/83ad5336-0f31-494c-b249-7ff2edfc1814_1772466140939.jpg	2611381	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/83ad5336-0f31-494c-b249-7ff2edfc1814_1772466140939.jpg}
d2736922-2464-450c-9772-f5dfc945b560	UPF20263531	Regata Ampla Sobreposicao	69.23	218.00	2026-02-28 17:55:13.896059+00	Alto Giro	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d2736922-2464-450c-9772-f5dfc945b560_1772471759889.jpg	2611640	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/d2736922-2464-450c-9772-f5dfc945b560_1772471759889.jpg}
23f42e5e-8baf-451a-8232-4639513222a4	UPF20269237	Shorts Sobreposto Com Elastico	111.93	268.90	2026-02-28 17:49:40.864096+00	Alto Giro	0	4.62	f	Verde	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/23f42e5e-8baf-451a-8232-4639513222a4_1772471975035.jpg	2611031	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/23f42e5e-8baf-451a-8232-4639513222a4_1772471975035.jpg}
1af532e8-1f99-47b1-881a-33f63f18287a	UPF20262893	Short Preto Cityflow	107.36	168.08	2026-03-04 13:06:00.890747+00	Ange	6.1	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262893_1772629560123.jpg	SH1544	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/UPF20262893_1772629560123.jpg}
e18c6da6-b141-4d37-af6b-8f4f3a047267	UPF20264611	Legging Empina Invisível 	0.00	220.00	2026-03-05 14:42:20.479317+00	Vestem	4.62	0	f	Lavanda	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e18c6da6-b141-4d37-af6b-8f4f3a047267_1772721847949.jpg	FS1540NY	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/e18c6da6-b141-4d37-af6b-8f4f3a047267_1772721847949.jpg}
1ad0bc1e-06fb-4bdc-985c-eb6dea1e6114	UPF20261276	Top Fitness Veloz	90.45	179.90	2026-03-10 18:08:47.50858+00	BRO	9.89	4.62	f	Roxo Deluxe	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261276_1773166125562.jpg	TP0727RX00800000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261276_1773166125562.jpg}
65a7f4a2-7044-4aa5-a817-81f7cdfe34fb	UPF20266577	Bermuda Fitness Veloz	100.00	199.90	2026-03-10 18:39:15.456922+00	BRO	9.89	4.62	f	Roxo Deluxe	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266577_1773167953624.jpg	BER0727RX00800000004	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266577_1773167953624.jpg}
e2276700-5553-4a39-bda7-53118e24cade	UPF20269284	Top Fitness Veloz	90.45	179.90	2026-03-10 18:40:43.582331+00	BRO	9.89	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269284_1773168041485.jpg	TP0727AZ04700000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269284_1773168041485.jpg}
cea3440e-0830-4042-907b-81ea40c691ea	UPF20262977	Colete Bravo 	109.50	199.90	2026-03-16 15:21:32.066978+00	BRO	10.8	4.62	f	Rosa Fucsia	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cea3440e-0830-4042-907b-81ea40c691ea_1773777696155.jpg	22-1-02-300-027	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cea3440e-0830-4042-907b-81ea40c691ea_1773777696155.jpg}
11efebf1-53fc-48ef-a7f1-3a13af82c1f3	UPF20267416	Top Média Compressão Ícone 	0.00	129.90	2026-03-05 14:40:10.838532+00	Vestem	4.62	0	f	Lavanda	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/11efebf1-53fc-48ef-a7f1-3a13af82c1f3_1772721866148.jpg	Top1305.Ny	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/11efebf1-53fc-48ef-a7f1-3a13af82c1f3_1772721866148.jpg}
3d634e9c-b236-49f3-9d74-19a6a21bc730	UPF20265482	Bermuda Fitness Veloz	100.00	199.90	2026-03-10 18:41:47.964019+00	BRO	9.89	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265482_1773168106457.jpg	BER0727AZ04700000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265482_1773168106457.jpg}
3461894e-b04c-4295-8c83-17ee8bcac3f7	UPF20268690	JAQUETA CULTIVO	105.90	249.90	2026-02-27 13:55:26.771481+00	Vestem	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3461894e-b04c-4295-8c83-17ee8bcac3f7_1773177139491.jpg	JAC279.SP	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3461894e-b04c-4295-8c83-17ee8bcac3f7_1773177139491.jpg}
c3fef1a0-bd1e-48ab-b87e-260e3140dad9	UPF20263938	Colete Bravo 	109.50	199.90	2026-03-16 15:20:41.968964+00	BRO	10.8	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c3fef1a0-bd1e-48ab-b87e-260e3140dad9_1773674704054.jpg	22-1-02-300-027	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c3fef1a0-bd1e-48ab-b87e-260e3140dad9_1773674704054.jpg}
b1a76627-8254-44af-aaf5-99dd25c780d3	UPF20264213	Short Fitness Street Bolso	128.55	239.90	2026-03-31 18:09:09.80905+00	BRO	8.69	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264213_1774980548542.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264213_1774980548542.jpg}
ec88d356-7f2c-4efd-8caf-5e651313607f	UPF20262551	Colete Bravo 	109.50	199.90	2026-03-16 15:19:55.830931+00	BRO	10.8	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ec88d356-7f2c-4efd-8caf-5e651313607f_1773674723893.jpg	22-1-02-300-027	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ec88d356-7f2c-4efd-8caf-5e651313607f_1773674723893.jpg}
e8f954b3-9c64-4ef2-b505-652fbedecdd1	UPF20261028	Bermuda Fitness Veloz	100.00	199.90	2026-03-11 17:48:50.5221+00	BRO	9.89	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e8f954b3-9c64-4ef2-b505-652fbedecdd1_1775067681069.jpg	BER0727PT00100000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e8f954b3-9c64-4ef2-b505-652fbedecdd1_1775067681069.jpg}
1123a71a-461e-41a2-994b-c4921c097aa4	UPF20266379	Top Fitness Veloz	90.45	179.90	2026-03-10 18:43:09.346816+00	BRO	9.89	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1123a71a-461e-41a2-994b-c4921c097aa4_1775067699451.jpg	TP0727PT00100000004	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1123a71a-461e-41a2-994b-c4921c097aa4_1775067699451.jpg}
1726d8a8-7466-49d2-b541-78f16f78d316	UPF20263321	Short Fitness Street Bolso	128.55	239.90	2026-03-31 18:11:06.121411+00	BRO	8.69	4.62	f	Verde Água	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1726d8a8-7466-49d2-b541-78f16f78d316_1776170076383.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1726d8a8-7466-49d2-b541-78f16f78d316_1776170076383.jpg}
a26aa634-b21b-4b21-a127-702abfab1f20	UPF20261308	Top Cos De Elastico E Alca Dupla	83.93	220.00	2026-02-28 17:51:55.253425+00	Alto Giro	0	4.62	f	VERDE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a26aa634-b21b-4b21-a127-702abfab1f20_1772471934478.jpg	2611530	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/a26aa634-b21b-4b21-a127-702abfab1f20_1772471934478.jpg}
61a2649e-51cc-4f2f-b143-1113d41bc9fd	UPF20267017	Top Elastico Personalizado Nadador	84.90	219.90	2026-05-07 23:19:35.692599+00	Alto Giro	0	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/61a2649e-51cc-4f2f-b143-1113d41bc9fd_1778224258312.jpg	2621512	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/61a2649e-51cc-4f2f-b143-1113d41bc9fd_1778224258312.jpg}
e60e28a2-3d2f-4105-8a7c-a0dd5749fc35	UPF20262800	Short Fitness Street Bolso	128.55	239.90	2026-03-31 18:20:53.34188+00	BRO	8.69	4.62	f	Vermelho Classic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262800_1774981251657.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262800_1774981251657.jpg}
71e09487-ea2d-49ee-a27c-2f57bb005e30	UPF20263123	Top Ballerina Cirre	80.90	159.90	2026-03-31 18:22:07.804312+00	BRO	8.69	4.62	f	Vermelho Batom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263123_1774981326349.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263123_1774981326349.jpg}
2f01216e-2642-44c7-8bfb-12d31c8372df	UPF20269638	Calça Legging Cirre Básica	104.70	209.90	2026-03-31 18:23:05.477678+00	BRO	8.69	4.62	f	Vermelho Batom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269638_1774981384251.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269638_1774981384251.jpg}
75c94f89-3b69-470b-a567-ad924d9604f3	UPF20267434	Top Fitness Summer Liso	85.65	169.90	2026-03-31 18:25:05.133498+00	BRO	8.69	4.62	f	Azul Bic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267434_1774981503122.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267434_1774981503122.jpg}
598d5623-0507-4a89-b3a4-987c1cae56af	UPF20265425	Top Fitness Summer Liso	85.65	169.90	2026-03-31 18:26:54.214549+00	BRO	8.69	4.62	f	Vermelho Classic	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265425_1774981612910.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265425_1774981612910.jpg}
3879d0a9-cb07-47ba-8062-f0405051f2e2	UPF20269927	Regata Fitness Pulsar	71.40	139.90	2026-03-31 18:31:38.793492+00	BRO	8.69	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269927_1774981897490.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269927_1774981897490.jpg}
c9bf8fab-7dc3-4f86-8ede-4f0a1d34c466	UPF20264789	Colete Lyra	159.90	339.90	2026-03-31 18:41:24.041497+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264789_1774982482544.jpg	COL12.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264789_1774982482544.jpg}
88964da7-b084-44c7-9231-43645c98ebf2	UPF20261969	Legging Helena	147.90	299.90	2026-03-31 18:51:13.585877+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261969_1774983071348.jpg	FS1576.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261969_1774983071348.jpg}
ec60a756-d6ac-42ae-a91a-819307d66c1d	UPF20269319	Legging Isis	142.90	299.90	2026-03-31 19:12:25.424295+00	Vestem	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269319_1774984344177.jpg	FS1589.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269319_1774984344177.jpg}
787c677e-8541-4a37-8f76-1b0a338ce9d3	UPF20264217	Legging Helena	147.90	299.90	2026-03-31 18:52:13.836682+00	Vestem	0	4.62	f	Marinho Escurudão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264217_1774983132714.jpg	FS1576.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264217_1774983132714.jpg}
4d8f4d58-ffc9-4fb1-81e0-7f130a3aa960	UPF20261296	Legging Isis	142.90	299.90	2026-03-31 19:13:42.515846+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261296_1774984421245.jpg	FS1589.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261296_1774984421245.jpg}
9fd20c26-5d5b-4b11-80e5-ecf884019976	UPF20265680	Regata Helena	90.90	189.90	2026-03-31 19:18:05.417634+00	Vestem	0	4.62	f	Marinho Escuridão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265680_1774984684314.jpg	REG861.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265680_1774984684314.jpg}
3fd3798e-d793-4754-ab1c-a5566edc77e3	UPF20263238	Short Isis	99.90	199.90	2026-03-31 19:20:22.385622+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263238_1774984821278.jpg	SH772.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263238_1774984821278.jpg}
4bbc099b-fc0c-48a9-a621-8674934824b5	UPF20264112	Short Helena	104.90	199.90	2026-03-31 19:21:46.076996+00	Vestem	0	4.62	f	Marrom Sepia	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264112_1774984904576.jpg	SH791.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264112_1774984904576.jpg}
78fcd02f-ea2b-4665-9eb5-e29d71b525ec	UPF20268480	Short Running Lyra	147.90	319.90	2026-03-31 19:23:04.918171+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268480_1774984983694.jpg	SHR790.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268480_1774984983694.jpg}
ef55c198-d3c5-41ce-afcb-a329e0f8865f	UPF20265763	Top Média Sustentação Isis	86.90	179.90	2026-03-31 19:24:59.061817+00	Vestem	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265763_1774985097173.jpg	TOP1248.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265763_1774985097173.jpg}
6b088322-81c6-4e64-af59-76b9ab62f027	UPF20262806	Top Média Sustentação Isis	86.90	179.90	2026-03-31 19:26:04.67908+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262806_1774985163255.jpg	TOP1248.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262806_1774985163255.jpg}
0f2f9bb8-5eaf-46de-b5e5-b1455ccb8321	UPF20261281	Top Alta Sustentação Helena	99.90	199.90	2026-03-31 19:27:27.659772+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261281_1774985245999.jpg	TOP1279.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261281_1774985245999.jpg}
178c1bfb-c016-4a74-9879-bbe421693e9e	UPF20264087	Top Alta Sustentação Helena	99.90	199.90	2026-03-31 19:28:28.637287+00	Vestem	0	4.62	f	Marinho Escuridão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264087_1774985307159.jpg	TOP1279.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264087_1774985307159.jpg}
f58a6e05-302a-4ae7-9754-7eba7b2ab797	UPF20264372	Top Alta Sustentação Helena	99.90	199.90	2026-03-31 19:30:34.734965+00	Vestem	0	4.62	f	Marrom Sepia	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264372_1774985433259.jpg	TOP1279.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264372_1774985433259.jpg}
756a8f66-8f2d-4fca-9255-2b4c2faa1a96	UPF20265090	Top Leve Sustentação Heather	86.90	189.90	2026-03-31 19:33:47.658672+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265090_1774985625677.jpg	TOP1281.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265090_1774985625677.jpg}
d5b8a956-5d2c-4b3b-a02d-0fb2243ffa88	UPF20269451	Top Leve Sustentação Lyra	64.90	139.90	2026-03-31 19:34:48.900275+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269451_1774985687807.jpg	TOP1292.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269451_1774985687807.jpg}
bf5059d6-196f-41b7-ba5f-e1f5c29ded46	UPF20267009	Top Fitness Nanny	99.47	209.00	2026-04-01 12:40:57.808543+00	BRO	7.29	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267009_1775047255882.jpg	TP0052	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267009_1775047255882.jpg}
c0ec0db7-f802-4337-a426-5224eefa3342	UPF20268736	Top Fitness Nanny	99.47	209.00	2026-04-01 12:44:00.162911+00	BRO	7.29	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268736_1775047437764.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268736_1775047437764.jpg}
1d1fb844-0f07-4b09-a80c-0b02ba50570d	UPF20262544	Top Fitness Nanny	99.47	209.00	2026-04-01 12:44:56.399606+00	BRO	7.29	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262544_1775047495129.jpg	TP0052	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262544_1775047495129.jpg}
9a55dd2b-b128-425f-9a60-4661635c2a14	UPF20262186	Top Fitness Nanny	99.47	209.00	2026-04-01 12:46:04.525554+00	BRO	7.29	4.62	f	Rosa Fúcsia	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262186_1775047563112.jpg	TP0052	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262186_1775047563112.jpg}
fe2f9328-af80-4d72-aa25-8ed6a2430cb4	UPF20261822	Top Fitness Nanny	99.47	209.00	2026-04-01 12:49:18.381979+00	BRO	7.29	4.62	f	Verde Neon	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261822_1775047756404.jpg	TP0052	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261822_1775047756404.jpg}
7c051d7b-cdf7-4a19-aa50-9a0f6e308655	UPF20266899	Top Fitness Nanny	99.47	209.00	2026-04-01 12:48:23.123592+00	BRO	7.29	4.62	f	Lilás	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266899_1775047701706.jpg	TP0052	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266899_1775047701706.jpg}
41d2c32d-5cb2-49cc-8ba0-e2151436b298	UPF20267432	Bermuda Fitness Montana	99.47	209.00	2026-04-01 13:00:36.832029+00	BRO	7.29	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267432_1775048435416.jpg	BR0234	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267432_1775048435416.jpg}
15f7fd5b-846c-498e-8c6d-dbca6ed3f5d7	UPF20266365	Calça Legging Montana	131.15	269.90	2026-04-01 13:01:29.166525+00	BRO	7.29	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266365_1775048487698.jpg	LG0234	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266365_1775048487698.jpg}
6dc84bb9-65fb-4f58-b048-a5c404b6c3ae	UPF20264822	Calça Legging Apatita	135.70	279.90	2026-04-01 13:02:19.152945+00	BRO	7.29	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264822_1775048536970.jpg	LG0707	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264822_1775048536970.jpg}
bf3fe2fa-8837-49de-aadd-27b863410a0c	UPF20266768	Colete Bravo 	109.50	199.90	2026-03-16 15:22:08.12037+00	BRO	10.8	4.62	f	Rosa Frutilly	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bf3fe2fa-8837-49de-aadd-27b863410a0c_1773777671324.jpg	22-1-02-300-027	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bf3fe2fa-8837-49de-aadd-27b863410a0c_1773777671324.jpg}
02ca7973-0ef3-4180-8774-3fb42e9642cd	UP027	COLETE CRISTALE	188.05	319.00	2026-01-28 00:24:38.605904+00	BRO	9.64	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/02ca7973-0ef3-4180-8774-3fb42e9642cd_1775067601997.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/02ca7973-0ef3-4180-8774-3fb42e9642cd_1775067601997.jpg}
4912f884-71ef-4b99-ba46-3daae390bc79	UPF20264888	Calça Legging Mel Hiking	136.82	199.22	2026-05-05 13:22:13.530072+00	Ange	7.78	4.62	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264888_1777987332545.jpg	LG18401	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264888_1777987332545.jpg}
1775cd64-1b1e-455b-9912-e320c910d18a	UPF20268143	Top Fitness Copa 2026	95.20	179.90	2026-04-14 12:30:56.568977+00	BRO	9.47	4.62	f	Amarelo/Verde Croco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1775cd64-1b1e-455b-9912-e320c910d18a_1776169934464.jpg	TR2645655	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1775cd64-1b1e-455b-9912-e320c910d18a_1776169934464.jpg}
a5bed760-0886-43ce-9884-0b2fa9d7e122	UPF20264574	Top Fitness Summer Liso	85.65	169.90	2026-03-31 18:26:01.42381+00	BRO	8.69	4.62	f	Verde Água	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a5bed760-0886-43ce-9884-0b2fa9d7e122_1776170059315.jpg	TR2645344	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a5bed760-0886-43ce-9884-0b2fa9d7e122_1776170059315.jpg}
9437321d-7e2b-41a5-96cd-27b94663bc00	UPF20263111	Short Fitness Street Bolso	128.55	239.90	2026-04-14 12:16:05.942101+00	BRO	9.47	0	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9437321d-7e2b-41a5-96cd-27b94663bc00_1776169201770.jpg	TR2645655	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9437321d-7e2b-41a5-96cd-27b94663bc00_1776169201770.jpg}
33919956-5f82-408a-bf83-d948ffca4d4b	UPF20263719	Short Saia Storm EveryMatch	190.51	225.99	2026-05-05 13:27:31.654757+00	Ange	7.78	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/33919956-5f82-408a-bf83-d948ffca4d4b_1777987762299.jpg	SH1522	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/33919956-5f82-408a-bf83-d948ffca4d4b_1777987762299.jpg}
75ed12b3-85f8-4292-8d72-aee071febf28	UP126	Top Cocoa Everylift	75.69	157.89	2026-01-28 00:25:34.450797+00	Ange	6.93	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/75ed12b3-85f8-4292-8d72-aee071febf28_1771528546029.jpg	TP10500/cocoa	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/produtos/75ed12b3-85f8-4292-8d72-aee071febf28_1771528546029.jpg}
89ee27b6-e12c-48ee-bf00-722b97a38220	UPF20261082	Short Fitness Street Bolso	122.13	239.90	2026-04-01 12:53:54.200492+00	BRO	7.29	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261082_1775048032328.jpg	000199BL	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261082_1775048032328.jpg}
0b666f5a-9359-483e-9e74-26b41a5457a6	UPF20268423	Short Saia Rose DayLight	120.40	225.99	2026-05-05 13:13:23.572398+00	Ange	7.78	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268423_1777986802261.jpg	SH1551	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268423_1777986802261.jpg}
bf4acbba-69dd-4445-8a60-52a91652fb1b	UPF20261637	Regata Rose Daylight	76.02	216.13	2026-05-05 13:15:06.658737+00	Ange	7.78	132.33	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261637_1777986905323.jpg	BL17191	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261637_1777986905323.jpg}
1e0a66d1-dbc1-4ef8-8839-aece52724742	UPF20261128	Top Rose PureCore	99.06	161.46	2026-05-05 13:15:59.60236+00	Ange	7.78	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261128_1777986958339.jpg	TP10526	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261128_1777986958339.jpg}
8c16d307-f3a4-4c06-863a-d6ee02ea9869	UPF20261514	Short Rose WindFit	118.94	181.34	2026-05-05 13:17:00.971033+00	Ange	7.78	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261514_1777987019593.jpg	SH1550	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261514_1777987019593.jpg}
1ab6e617-34db-432e-9557-56d84a5d234e	UPF20269717	Short Preto CityFlow	123.08	185.48	2026-05-05 13:19:00.661035+00	Ange	7.78	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269717_1777987139016.jpg	SH1543	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269717_1777987139016.jpg}
efbdfcbf-4526-466f-a863-115f66bd0714	UPF20266571	Top Mel Victory	75.47	137.87	2026-05-05 13:21:22.044103+00	Ange	7.78	4.62	f	Amarelo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266571_1777987280652.jpg	TP10462	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266571_1777987280652.jpg}
5a486e27-2649-4704-90b2-09769d302dda	UPF20262851	Bermuda Gelo Run Drop	118.67	181.07	2026-05-05 13:24:34.936404+00	Ange	7.78	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/5a486e27-2649-4704-90b2-09769d302dda_1777987699469.jpg	BM1641	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/5a486e27-2649-4704-90b2-09769d302dda_1777987699469.jpg}
0b79f466-a4c6-4dcb-bad4-1a285ddb4377	UPF20264444	Top Gelo Run Drop	86.58	148.98	2026-05-05 13:23:59.389246+00	Ange	7.78	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0b79f466-a4c6-4dcb-bad4-1a285ddb4377_1777987714395.jpg	TP10479	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0b79f466-a4c6-4dcb-bad4-1a285ddb4377_1777987714395.jpg}
4dda8aa6-b238-4cf3-88a1-fa327584a3be	UPF20269572	Regata Storm EveryMatch	71.61	132.33	2026-05-05 13:26:43.282231+00	Ange	7.78	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/4dda8aa6-b238-4cf3-88a1-fa327584a3be_1777987739701.jpg	BL17168	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/4dda8aa6-b238-4cf3-88a1-fa327584a3be_1777987739701.jpg}
0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8	UPF20261839	Top Degrade	109.90	229.90	2026-05-07 23:11:25.716844+00	Alto Giro	0	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8_1778224374890.jpg	2621522	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0afa14e7-78ed-422e-b4b5-ab27bbe9d6b8_1778224374890.jpg}
c9f22b86-6bdb-47cd-9832-d47f617bd6bc	UPF20264404	Legging com Bolso e Estampa	142.90	329.90	2026-05-07 23:12:36.613281+00	Alto Giro	0	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c9f22b86-6bdb-47cd-9832-d47f617bd6bc_1778224409419.jpg	2621321	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c9f22b86-6bdb-47cd-9832-d47f617bd6bc_1778224409419.jpg}
271fec96-9aed-4d36-b71d-87147092ae3e	UPF20266551	Bermuda Detalhe Bicolor	109.90	279.90	2026-05-07 23:14:40.880759+00	Alto Giro	0	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/271fec96-9aed-4d36-b71d-87147092ae3e_1778224472337.jpg	2621110	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/271fec96-9aed-4d36-b71d-87147092ae3e_1778224472337.jpg}
fddb8bcb-6e9c-4c9e-bcf7-2341053e40cf	UPF20261916	Regata Nadador com Tule	79.90	219.90	2026-05-07 23:15:53.697029+00	Alto Giro	0	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fddb8bcb-6e9c-4c9e-bcf7-2341053e40cf_1778224598767.jpg	2621610	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fddb8bcb-6e9c-4c9e-bcf7-2341053e40cf_1778224598767.jpg}
bff71c24-ac1a-4a4c-822c-2c1b299b343d	UPF20269813	Top Alças Duplas	89.90	199.90	2026-05-07 23:17:02.226769+00	Alto Giro	0	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bff71c24-ac1a-4a4c-822c-2c1b299b343d_1778224637862.jpg	2412513	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bff71c24-ac1a-4a4c-822c-2c1b299b343d_1778224637862.jpg}
c26f24e0-e9c3-4e19-9e79-6e4ce4ee2189	UPF20262882	T-Shirt Cropped Torção	94.90	199.90	2026-05-07 23:13:50.324815+00	Alto Giro	0	4.62	f	Rosa	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c26f24e0-e9c3-4e19-9e79-6e4ce4ee2189_1778224427956.jpg	2621720	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c26f24e0-e9c3-4e19-9e79-6e4ce4ee2189_1778224427956.jpg}
a0f12306-5fce-4173-ac98-5b6350de1863	UPF20266253	Top Alça Cruzada nas Costas	89.90	219.90	2026-05-07 23:15:17.793215+00	Alto Giro	0	4.62	f	Cinza	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a0f12306-5fce-4173-ac98-5b6350de1863_1778224578079.jpg	2621510	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a0f12306-5fce-4173-ac98-5b6350de1863_1778224578079.jpg}
0b64b183-18e2-4aa8-9152-421260382cb3	UPF20265366	Shorts Sport Way of Life	119.90	265.90	2026-05-07 23:16:30.615033+00	Alto Giro	0	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0b64b183-18e2-4aa8-9152-421260382cb3_1778224619466.jpg	121001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0b64b183-18e2-4aa8-9152-421260382cb3_1778224619466.jpg}
c360ccbe-736e-4357-afc3-62f7cacc33b9	UPF20261825	Shorts 2 em 1 Elastico	154.90	329.90	2026-05-07 23:19:10.729405+00	Alto Giro	0	4.62	f	Azul	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c360ccbe-736e-4357-afc3-62f7cacc33b9_1778224280013.jpg	2621011	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/c360ccbe-736e-4357-afc3-62f7cacc33b9_1778224280013.jpg}
3b341cfb-7a4f-4fb4-b6b1-d1ce3a43f9b5	UPF20268282	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:52:27.27022+00	BRO	6.07	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268282_1778694745532.jpg	234AZ00402010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268282_1778694745532.jpg}
03d3e7a0-6398-47a7-aefd-e5811cddb10f	UPF20268308	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:53:37.772608+00	BRO	6.07	4.62	f	Cinza Mescla Escuro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268308_1778694815976.jpg	234CZ00402010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268308_1778694815976.jpg}
2dc364cf-d17f-4bb7-9b77-3727c544746c	UPF20266580	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:55:17.007196+00	BRO	6.07	4.62	f	Roxo Ametista	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266580_1778694914963.jpg	234RX00902010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266580_1778694914963.jpg}
59c41dec-c3db-4783-9036-f32b38162602	UPF20267294	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:56:55.269212+00	BRO	6.07	4.62	f	Vinho Barolo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267294_1778695013615.jpg	234VR01502010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267294_1778695013615.jpg}
877e5d32-474a-4f90-a4d4-f780e572d58a	UPF20262752	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:58:10.509109+00	BRO	6.07	4.62	f	Vermelho Batom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262752_1778695089051.jpg	234VR01602010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262752_1778695089051.jpg}
52a04c53-d12e-4d24-adb0-e99f550a3907	UPF20266546	COLETE JULY	190.40	289.90	2026-05-13 19:35:49.382413+00	BRO	6.07	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266546_1778700945839.jpg	736BR00100000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266546_1778700945839.jpg}
7e3d8939-6360-463f-9573-9188011607ed	UPF20267328	SHORT JULY	109.50	210.00	2026-05-13 19:36:36.622038+00	BRO	6.07	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267328_1778700994857.jpg	736BR00100000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267328_1778700994857.jpg}
cbd9bb0f-ff33-4a7e-9df3-230d91f25ee9	UPF20265450	SHORT JULY	109.50	210.00	2026-05-13 19:38:23.872582+00	BRO	6.07	4.62	f	Verde Escuro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265450_1778701101030.jpg	736VD00700000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265450_1778701101030.jpg}
fd8be7ee-558e-4606-a6fb-9bbfce5c5649	UPF20268981	COLETE JULY	190.40	289.90	2026-05-13 19:37:22.88549+00	BRO	6.07	4.62	f	Verde Escuro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268981_1778701040494.jpg	736VD00700000	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268981_1778701040494.jpg}
bd450fd1-8aa8-4c61-af95-30307a3f65aa	UPF20262509	Bermuda Fitness Montana	104.70	209.00	2026-05-13 17:54:27.277837+00	BRO	6.07	4.62	f	Rosa Malva	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bd450fd1-8aa8-4c61-af95-30307a3f65aa_1778701197061.jpg	234RS07002010	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bd450fd1-8aa8-4c61-af95-30307a3f65aa_1778701197061.jpg}
61f63760-95d2-493a-a81f-fdbdad335355	UPF20262071	Bermuda Recorte Lateral	79.90	255.00	2026-05-07 23:17:37.11203+00	Alto Giro	0	4.62	f	Marrom	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/61f63760-95d2-493a-a81f-fdbdad335355_1778224353915.jpg	2621530	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/61f63760-95d2-493a-a81f-fdbdad335355_1778224353915.jpg}
dc407b2b-d84b-4554-831b-795e0716bdbe	UPF20264370	CALÇA LEGGING CELESTIAL	119.00	235.00	2026-05-25 14:48:07.324377+00	BRO	6.56	4.62	f	AZUL BIC/AZUL CARIBE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264370_1779720485138.jpg	LG0666AZ10400000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264370_1779720485138.jpg}
b85faab3-1556-45b8-af50-804c9e70bbb2	UPF20262256	CALÇA LEGGING CELESTIAL	119.00	235.00	2026-05-25 14:49:34.992777+00	BRO	6.56	4.62	f	PRETO/VERDE ABSINTO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262256_1779720572979.jpg	LG0666PT08800000003	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262256_1779720572979.jpg}
254e1417-650b-4140-bb3e-9bf3ade91b50	UPF20266573	TOP FITNESS CELESTIAL	79.05	160.00	2026-05-25 14:54:05.842953+00	BRO	6.56	4.62	f	VERDE ABSINTO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266573_1779720843605.jpg	TP0666VD07300000003	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266573_1779720843605.jpg}
eeef784a-f4c3-49a4-b126-a4ff7cced463	UPF20269912	BERMUDA ELASTICO PERSONALIZADO ALTO GIRO	99.90	219.90	2026-05-26 12:32:44.25674+00	Alto Giro	0	4.62	f	ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269912_1779798761830.jpg	326109	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269912_1779798761830.jpg}
9a64e33d-81b5-435d-8649-8e44ae96c86c	UPF20262183	TOP FITNESS CELESTIAL	79.05	160.00	2026-05-25 14:53:16.281652+00	BRO	6.56	4.62	f	ROSA FÚCSIA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9a64e33d-81b5-435d-8649-8e44ae96c86c_1779720863358.jpg	TP0666RS02300000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9a64e33d-81b5-435d-8649-8e44ae96c86c_1779720863358.jpg}
0e389fbc-7e79-482e-accb-4e2e5b92b509	UPF20268733	LEGGING COS ALTO ZIPER FRENTE	129.90	299.90	2026-05-25 22:58:51.220464+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268733_1779749929066.jpg	314799	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268733_1779749929066.jpg}
8cdbc26f-24a3-4d84-9c3c-a4781c65304c	UPF20261174	TOP ANATOMICO ALCAS DUPLAS	89.90	199.90	2026-05-25 23:01:44.015488+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261174_1779750102361.jpg	316351	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261174_1779750102361.jpg}
461a481e-12a3-4373-8ddd-cb410748e9cd	UPF20263783	TOP SUSTENCAO ALCA REGULAVEIS	129.90	299.90	2026-05-25 23:02:33.476122+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263783_1779750152131.jpg	316345	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263783_1779750152131.jpg}
390efbab-b038-4088-9bd3-fdb4889b5ae7	UPF20261705	SAIA SHORTS ETERNA SOBREPOSTA EVASE	134.90	199.90	2026-05-25 23:04:09.435931+00	Alto Giro	0	4.62	f	VERDE CITRICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261705_1779750246259.jpg	329688	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261705_1779750246259.jpg}
bd62d0cf-146b-4d56-9621-244e4e5352cd	UPF20264451	TOP NADADOR ELASTICO PERSONALIZADO	94.90	229.90	2026-05-26 12:33:40.704116+00	Alto Giro	0	4.62	f	ROSA AURORA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264451_1779798818242.jpg	324918	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264451_1779798818242.jpg}
03dcd463-76cf-4c8f-83b6-22a0a3d72268	UPF20266595	TOP NADADOR COM CONTORNO	114.90	259.90	2026-05-25 23:03:22.094758+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/03dcd463-76cf-4c8f-83b6-22a0a3d72268_1779750329253.jpg	324689	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/03dcd463-76cf-4c8f-83b6-22a0a3d72268_1779750329253.jpg}
230c38d0-2506-44ca-a39a-564d5e06e802	UPF20267801	BERMUDA ELASTICO PERSONALIZADO ALTO GIRO	99.90	219.90	2026-05-26 12:36:17.245264+00	Alto Giro	0	4.62	f	ROSA BAUNILHA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267801_1779798975230.jpg	326121	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267801_1779798975230.jpg}
03b2fc1c-cf16-4880-872f-05e52f9f882b	UPF20263417	LEGGING SPORT WAY OF LIFE	139.90	329.90	2026-05-25 22:59:38.532269+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/03b2fc1c-cf16-4880-872f-05e52f9f882b_1779750350301.jpg	316354	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/03b2fc1c-cf16-4880-872f-05e52f9f882b_1779750350301.jpg}
8d6da76c-03ee-4bc0-a8b0-a49424b4dee3	UPF20268819	TOP NADADOR ELASTICO PERSONALIZADO	94.90	229.90	2026-05-26 12:37:13.461701+00	Alto Giro	0	4.62	f	ROSA BAUNILHA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268819_1779799031551.jpg	324931	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268819_1779799031551.jpg}
1dab11ed-3bae-4f22-b579-31737836d5ee	UPF20264312	LEGGING ELASTICO PERSONALIZADO ALTO GIRO	149.90	329.90	2026-05-26 12:41:17.933316+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264312_1779799276769.jpg	325648	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264312_1779799276769.jpg}
b69505bd-c95e-4f1d-8cc1-9d87cf033664	UPF20261578	TOP ELASTICO PERSONALIZADO ALTO GIRO	86.90	229.90	2026-05-26 12:42:04.219095+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261578_1779799322211.jpg	324981	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261578_1779799322211.jpg}
55e0343b-26ae-4c0f-98bd-a40b6a49418d	UPF20267886	SHORTS SOBREPOSTO REFLETIVO	119.90	259.90	2026-05-26 12:28:16.964379+00	Alto Giro	0	4.62	f	VERMELHO MARSALA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/55e0343b-26ae-4c0f-98bd-a40b6a49418d_1779798594014.jpg	322544	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/55e0343b-26ae-4c0f-98bd-a40b6a49418d_1779798594014.jpg}
3c34c887-2401-40e3-84b5-0eefedea12df	UPF20267245	SHORTS SOBREPOSTO REFLETIVO	119.90	259.90	2026-05-25 22:57:54.34798+00	Alto Giro	0	4.62	f	VERDE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3c34c887-2401-40e3-84b5-0eefedea12df_1779798633916.jpg	322547	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3c34c887-2401-40e3-84b5-0eefedea12df_1779798633916.jpg}
e80d740d-58dc-480e-969f-423f63dcc8bc	UPF20268939	LEGGING ELASTICO PERSONALIZADO ALTO GIRO	149.90	329.90	2026-05-26 12:51:43.183142+00	Alto Giro	0	4.62	f	BEGE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e80d740d-58dc-480e-969f-423f63dcc8bc_1779799921392.jpg	325658	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/e80d740d-58dc-480e-969f-423f63dcc8bc_1779799921392.jpg}
eafb3b17-fafe-4d6f-863b-b12a2fc6343f	UPF20268520	TOP ELASTICO PERSONALIZADO ALTO GIRO	86.90	229.90	2026-05-26 12:53:05.093703+00	Alto Giro	0	4.62	f	BEGE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268520_1779799983949.jpg	324989	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268520_1779799983949.jpg}
ab17bb5d-386a-4800-9597-5686055239d9	UPF20265511	MACAQUINHO CURTO ELASTICO PERSONALIZADO	174.90	399.90	2026-05-26 13:02:46.053796+00	Alto Giro	0	4.62	f	AZUL CIANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265511_1779800563453.jpg	326780	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265511_1779800563453.jpg}
244b0d4a-aba1-407a-90bf-fe4a6e464be3	UPF20261840	REGATA NADADOR COM TULE	79.90	179.90	2026-05-26 13:11:34.159269+00	Alto Giro	0	4.62	f	CINZA HORIZONTE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261840_1779801091970.jpg	327563	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261840_1779801091970.jpg}
f5c5e94d-bcb9-4f49-96ea-38f80502e452	UPF20268644	REGATA NADADOR COM TULE	79.90	179.90	2026-05-26 13:13:13.383384+00	Alto Giro	0	4.62	f	AZUL PISCINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268644_1779801190627.jpg	327567	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268644_1779801190627.jpg}
746529fd-29ba-4712-aa89-b7444bc978e3	UPF20266210	REGATA CROPPED RECORTE COSTAS	74.90	169.90	2026-05-26 13:19:00.572115+00	Alto Giro	0	4.62	f	VIOLETA REAL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266210_1779801538423.jpg	327761	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266210_1779801538423.jpg}
e56cbf93-b2fd-4251-b400-757de41fe7a4	UPF20262633	REGATA CROPPED RECORTE COSTAS	74.90	169.90	2026-05-26 13:19:57.696354+00	Alto Giro	0	4.62	f	LILAS ENCANTO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262633_1779801595866.jpg	327763	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262633_1779801595866.jpg}
db44cd4c-ca3e-49c9-9fc8-a5c50e8a1f01	UPF20269474	LEGGING COM RECORTES E ESTAMPA	189.90	399.90	2026-05-26 13:27:30.035041+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269474_1779802047741.jpg	327772	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269474_1779802047741.jpg}
cb527f95-20c9-4c42-82a0-1236ccab1f86	UPF20263596	TOP REGATA NADADOR	184.90	399.00	2026-05-26 13:28:28.388685+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263596_1779802106374.jpg	327790	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263596_1779802106374.jpg}
bf164b87-cfad-4bb6-9885-0b40b4857ed4	UPF20269219	TOP REGATA NADADOR	184.90	399.00	2026-05-26 13:29:25.095228+00	Alto Giro	0	4.62	f	VERMELHO RUBI	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269219_1779802163563.jpg	327793	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269219_1779802163563.jpg}
cf50944b-9c24-4253-b741-2e63beb82308	UPF20266382	LEGGING COM RECORTES E ESTAMPA	189.90	399.90	2026-05-26 13:30:14.707558+00	Alto Giro	0	4.62	f	VERMELHO RUBI	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266382_1779802212755.jpg	327776	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266382_1779802212755.jpg}
2adfffdd-1e23-4800-a123-f0ddadd83cf9	UPF20262992	SHORTS COM RECORTE E ESTAMPA	124.90	279.90	2026-05-26 13:31:10.261778+00	Alto Giro	0	4.62	f	VERMELHO RUBI	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262992_1779802267980.jpg	327779	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262992_1779802267980.jpg}
df6a97ff-20c2-42af-b5e5-d1d7117a0750	UPF20266639	BERMUDA DETALHE BICOLOR	109.90	249.90	2026-05-26 13:42:39.031804+00	Alto Giro	0	4.62	f	VERMELHO ROSADO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266639_1779802956929.jpg	327655	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266639_1779802956929.jpg}
001a4eee-5381-447d-8b59-5795bded7918	UPF20269194	LEGGING DETALHE CONTRASTANTE	149.90	369.90	2026-05-26 13:43:20.595833+00	Alto Giro	0	4.62	f	VERMELHO ROSADO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269194_1779802999103.jpg	327649	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269194_1779802999103.jpg}
96270ce4-a952-4a02-bb35-c1cf555e2f8c	UPF20266165	TOP TRANSPASSADO EM V	115.90	259.90	2026-05-26 13:45:03.145218+00	Alto Giro	0	4.62	f	VERMELHO ROSADO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266165_1779803101530.jpg	327646	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266165_1779803101530.jpg}
2ca91c0d-1c44-4b8b-83c7-35a12406f314	UPF20267658	Top Dupla Face	109.90	229.90	2026-05-07 23:18:45.806851+00	Alto Giro	0	4.62	f	MARROM ANIS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2ca91c0d-1c44-4b8b-83c7-35a12406f314_1778224308544.jpg	2621130	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2ca91c0d-1c44-4b8b-83c7-35a12406f314_1778224308544.jpg}
8c6fcd6e-16e2-4b6c-bbfa-4b6b5797a248	UPF20265110	LEGGING DETALHE CONTRASTANTE	149.90	369.90	2026-05-26 13:54:11.662098+00	Alto Giro	0	4.62	f	MARROM NOITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265110_1779803650222.jpg	327652	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265110_1779803650222.jpg}
c68f212a-8a4b-4d82-b22f-d56006f28c10	UPF20267181	TOP ELASTICO PERSONALIZADO NADADOR FINO	84.90	199.90	2026-05-26 13:55:51.338174+00	Alto Giro	0	4.62	f	AZUL PISCINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267181_1779803743348.jpg	327583	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267181_1779803743348.jpg}
5a9db7ea-c12c-4eab-ae6e-3b2ade4da98b	UPF20263375	TOP NADADOR ELASTICO PERSONALIZADO	94.90	229.90	2026-05-26 14:04:01.325967+00	Alto Giro	0	4.62	f	CINZA HORIZONTE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263375_1779804232321.jpg	324926	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263375_1779804232321.jpg}
9b18bfa1-5be2-4276-8c1f-0e4d0281231f	UPF20268332	TOP ELASTICO PERSONALIZADO ALTO GIRO	86.90	229.90	2026-05-26 14:06:39.613592+00	Alto Giro	0	4.62	f	AZUL VINIL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268332_1779804397903.jpg	325002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268332_1779804397903.jpg}
30881abb-d3f6-44c3-8684-d9d34df5545d	UPF20261703	T-SHIRT CROPPED	89.90	199.90	2026-05-26 14:08:18.743154+00	Alto Giro	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261703_1779804495177.jpg	327742	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261703_1779804495177.jpg}
8c5c138d-e2b4-4931-bcd2-8329534ce9e1	UPF20262556	TOP ALCA CRUZADA NAS COSTAS	89.90	219.90	2026-05-26 13:44:08.065178+00	Alto Giro	0	4.62	f	VERMELHO ROSADO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262556_1779803046446.jpg	327592	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262556_1779803046446.jpg}
2ce7d50a-d254-4860-bf0b-8f18b4c67d85	UPF20262067	LEGGING ETERNA ANTICELULITE COS ALTO	149.90	329.90	2026-05-25 23:08:23.495209+00	Alto Giro	0	4.62	f	AZUL NOTURNO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2ce7d50a-d254-4860-bf0b-8f18b4c67d85_1779826778880.jpg	329588	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2ce7d50a-d254-4860-bf0b-8f18b4c67d85_1779826778880.jpg}
f1f37c0b-af2d-4a47-bb00-d8e7f832a4c0	UPF20264072	Bermuda Shape Up Freya	94.90	209.90	2026-06-19 13:02:28.467118+00	Vestem	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264072_1781874145558.jpg	BER265.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264072_1781874145558.jpg}
8b1f499c-ee20-479e-8588-aa0811712935	UPF20262331	SHORTS 2 EM 1 ELASTICO	154.90	349.90	2026-06-03 11:30:03.370373+00	Alto Giro	0	4.62	f	AZUL PISCINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8b1f499c-ee20-479e-8588-aa0811712935_1780487257727.jpg	327505	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/8b1f499c-ee20-479e-8588-aa0811712935_1780487257727.jpg}
56d8eaf0-17ed-4d25-99f1-74144b557ab9	UPF20268120	Top Alta Sustentação com Abertura Freya	99.90	219.90	2026-06-19 13:04:04.548099+00	Vestem	0	4.62	f	Azul Marinho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268120_1781874242237.jpg	TOP1231.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268120_1781874242237.jpg}
5a1309a8-2b53-440e-9dcd-463538d23141	UPF20267997	Legging Bicolor com Bolsos Helena	147.90	299.90	2026-06-19 13:07:28.149026+00	Vestem	0	4.62	f	Marrom Sépia	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267997_1781874445086.jpg	FS1576.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267997_1781874445086.jpg}
2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7	UPF20262785	LEGGING ELASTICO PERSONALIZADO	149.90	329.90	2026-06-03 11:25:02.570587+00	Alto Giro	0	4.62	f	BRANCO OPTICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7_1781875556576.jpg	325653	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/2eff132e-a0cf-4eeb-aa55-a45d90d1c1e7_1781875556576.jpg}
4005334e-6610-41dc-95b2-6eee8ad8e419	UPF20265777	Legging Shape Up Transpassado Bicolor Yara	124.90	279.90	2026-06-19 13:10:54.053457+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265777_1781874651172.jpg	FS1594.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265777_1781874651172.jpg}
098e7ef6-19cd-4fb2-bac7-da38efb9ad72	UPF20269349	Top Média Sustentação Transpassado Bicolor Yara	99.90	219.90	2026-06-19 13:11:50.866674+00	Vestem	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269349_1781874707902.jpg	TOP1253.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269349_1781874707902.jpg}
9c643407-daf7-4827-bf3f-19706be83648	UPF20265057	Legging Shape Up Transpassado Bicolor Yara	124.90	279.90	2026-06-19 13:12:56.879919+00	Vestem	0	4.62	f	Marinho Escuridão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265057_1781874774038.jpg	FS1594.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265057_1781874774038.jpg}
c822c582-3b36-4455-863a-54c47b4611a5	UPF20261394	Shorts Shape Up Transpassado Bicolor Yara	94.90	209.90	2026-06-19 13:13:54.941475+00	Vestem	0	4.62	f	Marinho Escuridão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261394_1781874831485.jpg	SH777.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261394_1781874831485.jpg}
d5723028-0256-43b6-9d2c-dee1033aa63a	UPF20266022	Top Média Sustentação Transpassado Bicolor Yara	99.90	219.90	2026-06-19 13:14:55.60943+00	Vestem	0	4.62	f	Marinho Escuridão	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266022_1781874892837.jpg	TOP1253.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266022_1781874892837.jpg}
26405f63-d9bc-48a6-b965-c6a5947af58a	UPF20267408	Shorts Shape Up Bicolor Isis	99.90	199.90	2026-06-19 13:18:14.083224+00	Vestem	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267408_1781875091440.jpg	SH772.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267408_1781875091440.jpg}
c507f310-9f7b-401b-84a1-08b2910b50a9	UPF20261920	Top Média Sustentação com Silk Nix	104.90	219.90	2026-06-19 13:20:43.273458+00	Vestem	0	4.62	f	Vermelho Barolo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261920_1781875240279.jpg	TOP1249.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261920_1781875240279.jpg}
33ab8e86-97c7-4442-b8ce-27ed8b70ff04	UPF20267697	Shorts Shape Up com Silk Nix	99.90	219.90	2026-06-19 13:21:32.385854+00	Vestem	0	4.62	f	Vermelho Barolo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267697_1781875289277.jpg	SH773.O26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267697_1781875289277.jpg}
75e05685-9baf-46cd-82f8-e02a4083bcf9	UPF20267596	LEGGING ELASTICO PERSONALIZADO	149.90	329.90	2026-06-03 11:28:46.553901+00	Alto Giro	0	4.62	f	AZUL VINIL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/75e05685-9baf-46cd-82f8-e02a4083bcf9_1781875358170.jpg	325672	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/75e05685-9baf-46cd-82f8-e02a4083bcf9_1781875358170.jpg}
f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3	UPF20268276	LEGGING ELASTICO PERSONALIZADO	149.90	329.90	2026-06-03 11:27:41.083783+00	Alto Giro	0	4.62	f	BEGE FRIO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3_1781875510234.jpg	325657	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f4ef2e4e-1874-4fad-afd4-fcfc7eed3ff3_1781875510234.jpg}
d9158d5b-3529-4301-b4e5-e1bcdc4158c4	UPF20262234	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO	109.90	229.90	2026-06-30 18:38:02.727399+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262234_1782844680549.jpg	329695	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262234_1782844680549.jpg}
37f7c903-b6a5-4451-9584-37760953d250	UPF20262810	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO	109.90	229.90	2026-06-30 18:50:22.26744+00	Alto Giro	0	4.62	f	Branco Optico	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262810_1782845419854.jpg	329700	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262810_1782845419854.jpg}
326add3c-eb17-495c-926f-374e8b982837	UPF20262323	BERMUDA RECORTES AG WAY OF LIFE	149.90	349.90	2026-06-30 20:32:31.982291+00	Alto Giro	0	4.62	f	BRANCO ÓPTICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262323_1782851550066.jpg	330220	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262323_1782851550066.jpg}
2a66ac9d-0c8e-4c7b-a7b7-d6e615dd8d28	UPF20268273	TOP ELÁSTICO PERSONALIZADO	86.90	229.90	2026-06-30 20:57:57.084541+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268273_1782853073231.jpg	329658	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268273_1782853073231.jpg}
62bb5e2a-10dc-4edf-8d56-911c2a0fa863	UPF20262230	TOP ELÁSTICO PERSONALIZADO	86.90	229.90	2026-06-30 20:59:12.710558+00	Alto Giro	0	4.62	f	Branco Optico	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262230_1782853150218.jpg	329664	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262230_1782853150218.jpg}
e40245f6-771f-4c75-8131-58d2766506c8	UPF20262275	TOP LINEA MÉDIA SUSTENTAÇÃO	86.90	179.90	2026-07-23 00:30:34.188388+00	Vestem	0	4.62	f	MARINHO ESCURIDÃO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262275_1784766632630.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262275_1784766632630.jpg}
11f5db23-1e55-4980-a635-41fc0cf50d93	UPF20265198	TOP DECOTE V ABERTURA COSTAS	139.90	259.90	2026-06-30 21:05:36.642746+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/11f5db23-1e55-4980-a635-41fc0cf50d93_1782866947034.jpg	329357	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/11f5db23-1e55-4980-a635-41fc0cf50d93_1782866947034.jpg}
3d4d4732-f830-49fa-a7ea-72b7ba66801e	UPF20267547	TOP ELÁSTICO PERSONALIZADO	86.90	229.90	2026-06-30 20:59:55.019282+00	Alto Giro	0	4.62	f	Roxo Malva	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3d4d4732-f830-49fa-a7ea-72b7ba66801e_1782866738946.jpg	329674	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3d4d4732-f830-49fa-a7ea-72b7ba66801e_1782866738946.jpg}
30839a14-f92a-41a3-923f-2340724763b0	UPF20264361	TOP DECOTE COSTAS ELÁSTICO PERSONALIZADO	98.90	229.90	2026-06-30 21:01:53.19165+00	Alto Giro	0	4.62	f	ROXO VIOLETA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/30839a14-f92a-41a3-923f-2340724763b0_1782866842754.jpg	330268	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/30839a14-f92a-41a3-923f-2340724763b0_1782866842754.jpg}
0d252391-9224-48a8-8ec9-dd9cbcb683e4	UPF20268958	LEGGING ELÁSTICO AG WAY OF LIFE	178.90	369.90	2026-06-30 20:49:17.434488+00	Alto Giro	0	4.62	f	VERMELHO RUBRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0d252391-9224-48a8-8ec9-dd9cbcb683e4_1782866900217.jpg	330229	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0d252391-9224-48a8-8ec9-dd9cbcb683e4_1782866900217.jpg}
a1d510e0-4be6-4d40-b8ed-6ecd2a598060	UPF20262592	SAIA DRY SOBREPOSTA	109.90	229.90	2026-06-30 20:52:48.661175+00	Alto Giro	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a1d510e0-4be6-4d40-b8ed-6ecd2a598060_1782867070220.jpg	329329	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a1d510e0-4be6-4d40-b8ed-6ecd2a598060_1782867070220.jpg}
a2e9454e-e59e-4c92-aa00-0cf93c3ea168	UPF20269490	LEGGING RECORTE ASSIMÉTRICO	179.90	429.90	2026-06-30 20:45:39.901826+00	Alto Giro	0	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a2e9454e-e59e-4c92-aa00-0cf93c3ea168_1782867273919.jpg	330284	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a2e9454e-e59e-4c92-aa00-0cf93c3ea168_1782867273919.jpg}
508022e6-0d24-4d5b-a11c-f8422dbf85b8	UPF20262555	LEGGING CÓS BICOLOR DETALHE ESTAMPA	149.90	369.90	2026-06-30 20:37:43.384239+00	Alto Giro	0	4.62	f	ROXO INTENSO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/508022e6-0d24-4d5b-a11c-f8422dbf85b8_1783043225842.jpg	330151	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/508022e6-0d24-4d5b-a11c-f8422dbf85b8_1783043225842.jpg}
a27d57a0-bc23-492a-9632-8082d16c7170	UPF20269403	TOP NADADOR ELÁSTICO WAY OF LIFE	119.90	259.90	2026-06-30 21:12:36.064735+00	Alto Giro	0	4.62	f	VERMELHO RUBRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a27d57a0-bc23-492a-9632-8082d16c7170_1782860300247.jpg	330636	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a27d57a0-bc23-492a-9632-8082d16c7170_1782860300247.jpg}
85197957-d929-4d27-b954-d7ace210e9f1	UPF20264988	TOP DECOTE V ABERTURA COSTAS	139.90	259.90	2026-06-30 21:06:33.274901+00	Alto Giro	0	4.62	f	VERMELHO RUBRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/85197957-d929-4d27-b954-d7ace210e9f1_1782860327482.jpg	329360	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/85197957-d929-4d27-b954-d7ace210e9f1_1782860327482.jpg}
67ca82be-45c3-44d6-add9-baa452eb77ff	UPF20261162	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:17:41.315996+00	BRO	3.07	4.62	f	BRANCO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/67ca82be-45c3-44d6-add9-baa452eb77ff_1784723460419.jpg	7908388573020	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/67ca82be-45c3-44d6-add9-baa452eb77ff_1784723460419.jpg}
314cbea3-f0b7-41f4-b609-59e904d83a35	UPF20268449	BERMUDA ELÁSTICO PERSONALIZADO ALTO GIRO	109.90	229.90	2026-06-30 20:30:49.612161+00	Alto Giro	0	4.62	f	Roxo Malva	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/314cbea3-f0b7-41f4-b609-59e904d83a35_1782866718791.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/314cbea3-f0b7-41f4-b609-59e904d83a35_1782866718791.jpg}
39ccf293-fcfe-4409-9588-290e3419c592	UPF20269759	LEGGING RECORTES AG WAY OF LIFE	149.90	369.90	2026-06-30 20:47:55.664077+00	Alto Giro	0	4.62	f	Azul Céu	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/39ccf293-fcfe-4409-9588-290e3419c592_1782866779673.jpg	330362	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/39ccf293-fcfe-4409-9588-290e3419c592_1782866779673.jpg}
42d326ad-5ca4-4a70-9827-56795a80e6be	UPF20263082	TOP ALÇA FINA AG WAY OF LIFE	89.90	199.90	2026-06-30 21:09:50.262683+00	Alto Giro	0	4.62	f	AZUL CÉU	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/42d326ad-5ca4-4a70-9827-56795a80e6be_1782866803521.jpg	330320	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/42d326ad-5ca4-4a70-9827-56795a80e6be_1782866803521.jpg}
a10ea09b-2ce4-45b7-aea5-0629d630e5f7	UPF20269088	LEGGING DETALHE ELÁSTICO E BOLSO	179.90	369.90	2026-06-30 20:39:07.997784+00	Alto Giro	0	4.62	f	ROXO VIOLETA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a10ea09b-2ce4-45b7-aea5-0629d630e5f7_1782866860732.jpg	330189	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/a10ea09b-2ce4-45b7-aea5-0629d630e5f7_1782866860732.jpg}
1ff8c188-c391-4884-82fb-fb90ea649d97	UPF20264573	LEGGING FRISO CONTRASTANTE	149.90	369.90	2026-06-30 20:41:52.823484+00	Alto Giro	0	4.62	f	VERMELHO RUBRO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1ff8c188-c391-4884-82fb-fb90ea649d97_1782866918013.jpg	330257	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1ff8c188-c391-4884-82fb-fb90ea649d97_1782866918013.jpg}
0bfa8bd6-dbed-482c-9fb1-8b2475c62d01	UPF20265757	LEGGING RECORTE ASSIMÉTRICO	179.90	429.90	2026-06-30 20:46:39.039849+00	Alto Giro	0	4.62	f	Azul Noturno	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0bfa8bd6-dbed-482c-9fb1-8b2475c62d01_1782867250784.jpg	330286	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/0bfa8bd6-dbed-482c-9fb1-8b2475c62d01_1782867250784.jpg}
3a7b5436-a329-48ed-841d-b103d2e3b4c9	UPF20269876	TOP SOBREPOSTO BICOLOR	168.90	299.90	2026-06-30 21:00:57.579685+00	Alto Giro	0	4.62	f	ROXO INTENSO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3a7b5436-a329-48ed-841d-b103d2e3b4c9_1783043195830.jpg	330277	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3a7b5436-a329-48ed-841d-b103d2e3b4c9_1783043195830.jpg}
69e1d89e-c197-4a93-997b-14bc02e1a31a	UPF20267541	TOP PARK SLEEK FIT MÉDIA SUSTENTAÇÃO	69.90	159.90	2026-07-16 20:30:59.99182+00	Vestem	4.62	0	f	Marrom Castanho	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267541_1784233856774.jpg	TOP1312.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267541_1784233856774.jpg}
334f3a3a-1926-4a22-a982-d8f6a40ae667	UPF20269122	BLUSA MANGA CURTA CROPPED SLEEK FIT TELA	94.90	199.90	2026-07-16 20:28:55.629422+00	Vestem	4.62	0	f	Chumbo	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269122_1784233732695.jpg	BMC871.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269122_1784233732695.jpg}
bfd9dd8a-d38d-4e9e-a50c-55621630213c	UPF20261593	\tBLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-20 04:12:20.950869+00	BRO	4.13	4.62	f	Roxo Deluxe	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261593_1784520736609.jpg	7908388592687	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261593_1784520736609.jpg}
dbb7e21c-ac6e-40c0-a691-780ac8dfb450	UPF20263598	TOP CROPPED PINK SUPLEX	87.85	174.50	2026-07-22 12:38:29.547279+00	BRO	3.07	4.62	f	ÉBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263598_1784723908376.jpg	7901052217107	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263598_1784723908376.jpg}
3b5891a1-fc87-4940-ab0d-0a8433ff333d	UPF20269518	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:25:13.367974+00	BRO	3.07	4.62	f	VERDE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3b5891a1-fc87-4940-ab0d-0a8433ff333d_1784723334114.jpg	7901052210061	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/3b5891a1-fc87-4940-ab0d-0a8433ff333d_1784723334114.jpg}
bd33b8f4-d6d5-409f-830f-47294e5461d1	UPF20263173	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:16:54.829058+00	BRO	3.07	4.62	f	AZUL MARINHO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bd33b8f4-d6d5-409f-830f-47294e5461d1_1784723422498.jpg	7901052210085	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/bd33b8f4-d6d5-409f-830f-47294e5461d1_1784723422498.jpg}
6e4f0580-1905-4289-b0e2-9ad9c1db84d1	UPF20262321	CALÇA LEGGING MONTANA LISO	138.05	289.90	2026-07-22 12:39:38.465643+00	BRO	3.07	4.62	f	ÉBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262321_1784723977010.jpg	7901052217046	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262321_1784723977010.jpg}
316e0847-fb38-4f8e-b27d-5674bd1666bf	UPF20264188	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:18:25.650472+00	BRO	3.07	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/316e0847-fb38-4f8e-b27d-5674bd1666bf_1784723562846.jpg	7908388572986	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/316e0847-fb38-4f8e-b27d-5674bd1666bf_1784723562846.jpg}
4607c983-b3ce-4528-b0df-7be410246578	UPF20265840	BLUSA MANGA CURTA CROPPED SLEEK FIT TELA	94.90	189.90	2026-07-23 00:15:11.944222+00	Vestem	0	4.62	f	CHUMBO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265840_1784765710618.jpg	BMC871.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265840_1784765710618.jpg}
9337d5ae-36a0-4a21-afa7-10b2ad8d4e5d	UPF20265333	TOP FITNESS FOGGY	109.50	209.90	2026-07-22 12:41:18.283778+00	BRO	3.07	4.62	f	AZUL SKY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9337d5ae-36a0-4a21-afa7-10b2ad8d4e5d_1784765058994.jpg	7901052212355	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/9337d5ae-36a0-4a21-afa7-10b2ad8d4e5d_1784765058994.jpg}
46389cbf-b8d5-49de-8278-7f8efe157f36	UPF20263693	CALÇA LEGGING FOGGY	142.85	299.90	2026-07-22 12:41:58.822818+00	BRO	3.07	4.62	f	AZUL SKY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/46389cbf-b8d5-49de-8278-7f8efe157f36_1784765078132.jpg	7901052212416	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/46389cbf-b8d5-49de-8278-7f8efe157f36_1784765078132.jpg}
281effef-a0ef-4e40-b504-bb72e4af97cf	UPF20262182	BLUSA MANGA CURTA CROPPED SLEEK FIT TELA	94.90	189.90	2026-07-16 20:24:55.959132+00	Vestem	0	4.62	f	Branco	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262182_1784233492525.jpg	BMC871.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262182_1784233492525.jpg}
76e1779f-f72d-4903-88a4-df32c0ddbf7a	UPF20261707	LEGGING LINEA SHAPE UP	124.90	269.90	2026-07-23 00:18:34.403935+00	Vestem	0	4.62	f	MARINHO ESCURIDÃO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261707_1784765912374.jpg	FS1660.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261707_1784765912374.jpg}
c8d3440d-0a34-4e5a-8154-3a2a2d065f88	UPF20261282	SHORTS SLEEK FIT SHAPE UP	104.90	219.90	2026-07-23 00:22:50.998792+00	Vestem	0	4.62	f	MARROM CASTANHO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261282_1784766167822.jpg	SH812.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261282_1784766167822.jpg}
ecba77b4-5fbd-4ca9-a21d-8d73c77b5d27	UPF20263968	SHORTS SLEEK FIT SHAPE UP	104.90	219.90	2026-07-23 00:24:53.960988+00	Vestem	0	4.62	f	AZUL VINTAGE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263968_1784766291474.jpg	SH812.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263968_1784766291474.jpg}
8929682c-550d-4126-87d4-8561dd141c94	UPF20266476	SHORTS LINEA SHAPE UP	74.90	159.90	2026-07-23 00:25:51.793307+00	Vestem	0	4.62	f	MARINHO ESCURIDÃO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266476_1784766350484.jpg	SH828.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266476_1784766350484.jpg}
99bfb9d0-1cfe-45e4-a877-89b22f69ddec	UPF20269697	SHORTS LINEA SHAPE UP	74.90	159.90	2026-07-23 00:27:16.563842+00	Vestem	0	4.62	f	MARROM NUTSHELL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269697_1784766435134.jpg	SH828.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269697_1784766435134.jpg}
4e5f7259-292f-4235-a7f5-33322c291888	UPF20267115	TOP PARK SLEEK FIT MÉDIA SUSTENTAÇÃO	69.90	149.90	2026-07-23 00:28:32.655892+00	Vestem	0	4.62	f	MARROM CASTANHO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267115_1784766510288.jpg	TOP1312.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267115_1784766510288.jpg}
75289bf7-308c-49ea-9910-14a0f72c86f9	UPF20264522	TOP PARK SLEEK FIT MÉDIA SUSTENTAÇÃO	69.90	149.90	2026-07-23 00:29:17.068165+00	Vestem	0	4.62	f	AZUL VINTAGE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264522_1784766554920.jpg	TOP1312.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264522_1784766554920.jpg}
99b1f132-5dfd-4cd8-bce2-38f71d12a8af	UPF20265792	TOP LINEA MÉDIA SUSTENTAÇÃO	86.90	179.90	2026-07-23 00:31:25.839739+00	Vestem	0	4.62	f	MARROM NUTSHELL	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265792_1784766682747.jpg	TOP1334.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265792_1784766682747.jpg}
b4569222-dc3c-4d38-a01c-51552d0d23d7	UPF20265151	BERMUDA COM BOLSOS E ESTAMPA	149.90	349.90	2026-07-23 00:55:26.294278+00	Alto Giro	0	4.62	f	LARANJA PÊSSEGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265151_1784768124728.jpg	330777	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265151_1784768124728.jpg}
1a77ad94-37c6-4d5d-9a18-ab679cb39175	UPF20267335	BERMUDA COM BOLSOS E ESTAMPA	149.90	349.90	2026-07-23 00:53:44.892169+00	Alto Giro	0	4.62	f	VERDE CÍTRICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267335_1784768023591.jpg	330775	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267335_1784768023591.jpg}
51df7326-c23d-4ce8-bb6b-f81662867894	UPF20267474	BERMUDA RECORTES AG WAY OF LIFE	149.90	349.90	2026-07-23 00:56:55.172405+00	Alto Giro	0	4.62	f	AZUL CÉU	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267474_1784768212560.jpg	330218	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267474_1784768212560.jpg}
20cb8218-2234-4f5b-8833-7a0ba8901c84	UPF20269467	LEGGING SHAPE UP MATCHPOINT	159.90	337.00	2026-07-31 12:26:52.757226+00	Vestem	0	4.62	f	ROSA CALMY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269467_1785500811810.jpg	FS1642.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269467_1785500811810.jpg}
1d1a3201-afad-4946-9463-0c5b125e2615	UPF20265229	LEGGING BOLSOS E ESTAMPA	189.90	359.90	2026-07-23 00:57:48.499269+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1d1a3201-afad-4946-9463-0c5b125e2615_1784768292598.jpg	330781	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1d1a3201-afad-4946-9463-0c5b125e2615_1784768292598.jpg}
d6fac8fe-af98-491e-97fb-8a6891baab68	UPF20264467	LEGGING BOLSOS E ESTAMPA	189.90	359.90	2026-07-23 00:59:12.535189+00	Alto Giro	0	4.62	f	LARANJA PÊSSEGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264467_1784768351185.jpg	330783	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264467_1784768351185.jpg}
4bde4343-0684-40a3-a694-abf824e2fe33	UPF20266087	MACACÃO ELÁSTICO AG WAY OF LIFE	268.90	479.90	2026-07-23 01:00:33.978477+00	Alto Giro	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266087_1784768431356.jpg	330411	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266087_1784768431356.jpg}
9a95b489-962f-4d5b-a175-ab5c3d725cbb	UPF20265883	MACACÃO ELÁSTICO AG WAY OF LIFE	268.90	479.90	2026-07-23 01:01:11.37955+00	Alto Giro	0	4.62	f	AZUL NOTURNO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265883_1784768468734.jpg	330414	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265883_1784768468734.jpg}
4d2893f2-7535-415a-884e-dd060eeb6cbc	UPF20267059	TOP DUPLA FACE COSTAS CRUZADA	98.90	199.90	2026-07-23 01:02:22.498691+00	Alto Giro	0	4.62	f	LARANJA PÊSSEGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267059_1784768540176.jpg	330247	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267059_1784768540176.jpg}
a6368ef1-e4ce-40d1-b616-fb9693a14a0e	UPF20265399	T-SHIRT TULE LISTRAS	89.90	219.90	2026-07-23 01:04:13.038326+00	Alto Giro	0	4.62	f	BEGE CREMOSO/VERDE CÍTRICO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265399_1784768650802.jpg	330576	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265399_1784768650802.jpg}
fc98af9b-2b1e-4adc-8de7-60508fb088f8	UPF20265103	BLUSA CROPPED SPOT TREVOS	57.10	119.90	2026-07-22 12:26:44.770111+00	BRO	3.07	4.62	f	VERMELHO BATOM	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fc98af9b-2b1e-4adc-8de7-60508fb088f8_1784723294344.jpg	7908388523216	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fc98af9b-2b1e-4adc-8de7-60508fb088f8_1784723294344.jpg}
7dc15126-a8ea-419b-9a69-9965641c91c1	UPF20268471	MACACÃO FITNESS XANDA	190.45	399.90	2026-07-31 12:09:14.927908+00	BRO	10	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268471_1785499753693.jpg	 9PT00100000003	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268471_1785499753693.jpg}
8c82a054-9bcc-4286-b55c-aa974443ad8e	UPF20263706	MACACÃO FITNESS XANDA	190.45	399.90	2026-07-31 12:10:05.928831+00	BRO	10	4.62	f	ÉBANO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263706_1785499805197.jpg	 9VR04400000003	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263706_1785499805197.jpg}
8f41c22d-86bc-445b-93ed-a43e0052c10b	UPF20264176	MACACÃO FITNESS LEAN GIRL	190.45	399.90	2026-07-31 12:13:27.270755+00	BRO	10	4.62	f	AZUL MARINHO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264176_1785500005475.jpg	MC0747AZ00400000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264176_1785500005475.jpg}
298bf824-e4f4-49a6-9b8e-e18c15df00c6	UPF20268383	MACACÃO FITNESS LEAN GIRL	190.45	399.90	2026-07-31 12:14:14.134545+00	BRO	10	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268383_1785500053146.jpg	MC0747PT00100000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268383_1785500053146.jpg}
468a8286-c41a-4042-83b0-95d393857dc1	UPF20262714	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO	104.90	217.00	2026-07-31 12:28:37.665255+00	Vestem	0	4.62	f	ROSA CALMY	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262714_1785500916581.jpg	TOP1314.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262714_1785500916581.jpg}
9a488d37-920c-4249-815c-4998efd3fcbe	UPF20267867	LEGGING SHAPE UP MATCHPOINT	159.90	337.00	2026-07-31 12:31:32.465272+00	Vestem	0	4.62	f	MARROM COURO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267867_1785501089295.jpg	FS1642.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267867_1785501089295.jpg}
b67f9c47-62d1-4363-9597-ff40721fa5fb	UPF20268203	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO	104.90	217.00	2026-07-31 12:32:47.544441+00	Vestem	0	4.62	f	MARROM COURO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268203_1785501166811.jpg	TOP1314.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268203_1785501166811.jpg}
eb554f6d-638d-4599-a492-a67e62b78779	UPF20261040	LEGGING SHAPE UP MATCHPOINT	159.90	337.00	2026-07-31 12:33:43.010312+00	Vestem	0	4.62	f	BEGE BRULÉE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261040_1785501222215.jpg	FS1642.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261040_1785501222215.jpg}
df47824c-8073-4c51-8386-9a2e0d702e25	UPF20268116	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO	104.90	217.00	2026-07-31 12:34:35.019028+00	Vestem	0	4.62	f	BEGE BRULÉE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268116_1785501273390.jpg	TOP1314.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268116_1785501273390.jpg}
ede8cd0a-4aac-4a12-b5f2-24b5c9319f99	UPF20261103	LEGGING SHAPE UP MATCHPOINT 	159.90	337.00	2026-07-31 12:35:40.488166+00	Vestem	0	4.62	f	VERDE HÓRUS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261103_1785501339283.jpg	FS1642.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261103_1785501339283.jpg}
a107e628-ba0d-4207-92e8-7bd844beca8c	UPF20265059	SHORTS SHAPE UP MATCHPOINT	109.90	217.00	2026-07-31 12:36:43.199885+00	Vestem	0	4.62	f	VERDE HÓRUS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265059_1785501401972.jpg	SH814.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265059_1785501401972.jpg}
1dc8aebb-9216-4bf4-934e-526e32fa7d8f	UPF20262919	TOP POLO MATCHPOINT MÉDIA SUSTENTAÇÃO	104.90	217.00	2026-07-31 12:37:33.329599+00	Vestem	0	4.62	f	VERDE HÓRUS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262919_1785501452495.jpg	TOP1314.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262919_1785501452495.jpg}
493d0744-d854-4b40-9a9b-62dcf4538682	UPF20265222	LEGGING PEACH SHAPE UP COM AMARRAÇÃO	159.90	357.00	2026-07-31 12:41:26.929236+00	Vestem	0	4.62	f	OFF WHITE ORGANIC	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265222_1785501686113.jpg	FS1643.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265222_1785501686113.jpg}
f6006a13-c5f1-410f-a5a1-4c6cca27f391	UPF20262214	TOP CROPPED PEACH MÉDIA SUSTENTAÇÃO	126.90	277.00	2026-07-31 12:42:15.747455+00	Vestem	0	4.62	f	OFF WHITE ORGANIC	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262214_1785501734742.jpg	TOP1319.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262214_1785501734742.jpg}
36acb101-7da7-4eba-add3-1abde739b408	UPF20268928	SAIA PEACH COM AMARRAÇÃO	149.90	337.00	2026-07-31 12:43:34.603987+00	Vestem	0	4.62	f	OFF WHITE ORGANIC	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268928_1785501813452.jpg	SA187.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268928_1785501813452.jpg}
4802bbea-1e6f-49f2-a250-6c7b50ac723b	UPF20267631	LEGGING CONTRAST SHAPE UP	119.90	277.00	2026-07-31 12:47:22.570643+00	Vestem	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267631_1785502039906.jpg	FS1652.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267631_1785502039906.jpg}
a85b331b-f896-424f-9e68-e89ec02baa9d	UPF20262804	SHORTS CONTRAST	89.90	197.00	2026-07-31 12:48:30.142812+00	Vestem	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262804_1785502107954.jpg	SH822.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262804_1785502107954.jpg}
8fd67591-1770-4592-ad69-6a114992c9f5	UPF20263233	TOP MÉDIA SUSTENTAÇÃO CONTRAST	94.90	207.00	2026-07-31 12:49:25.934178+00	Vestem	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263233_1785502164079.jpg	TOP1329.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263233_1785502164079.jpg}
4cfd28a9-7638-44cc-87a6-6c5b8531ec84	UPF20268284	LEGGING CONTRAST SHAPE UP	119.90	277.00	2026-07-31 12:56:36.731635+00	Vestem	0	4.62	f	BEGE AMÊNDOA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268284_1785502594623.jpg	FS1652.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268284_1785502594623.jpg}
0e2ebee8-3f2d-4863-815d-13007b2ffe28	UPF20267140	TOP MÉDIA SUSTENTAÇÃO CONTRAST	94.90	207.00	2026-07-31 12:57:24.085121+00	Vestem	0	4.62	f	BEGE AMÊNDOA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267140_1785502642378.jpg	TOP1329.I26	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267140_1785502642378.jpg}
69f39cbe-2daf-4887-9e45-9a756c8ddc3c	UPF20269890	Colete NYL	161.90	297.00	2026-08-27 18:21:25.31756+00	BRO	7.42	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269890_1787854882433.jpg	CL0752PT00100000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269890_1787854882433.jpg}
12e3378b-1df5-487e-9e56-8e49bfb780df	UPF20261088	Colete NYL	161.90	297.00	2026-08-27 18:22:25.634791+00	BRO	7.42	4.62	f	Verde Oceano	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261088_1787854942066.jpg	CL0752VD06800000001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261088_1787854942066.jpg}
4dc0559a-ba74-40d1-aa2e-644be03b57ee	UPF20266988	Blusa Cropped Summer	76.10	177.00	2026-08-28 11:41:55.022568+00	BRO	7.42	4.62	f	Salmão Electric	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266988_1787917311756.jpg	BL0106LJ01700000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266988_1787917311756.jpg}
1ab57614-5f36-4656-a86d-8dab0ab7f111	UPF20261187	Blusa Cropped Summer	76.10	177.00	2026-08-28 11:42:50.587806+00	BRO	7.42	4.62	f	Lilás	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261187_1787917366719.jpg	BL0106RX00300000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261187_1787917366719.jpg}
a85fa1e4-9f26-4268-98b7-23ef8bac47a4	UPF20268086	Blusa Cropped Summer	76.10	177.00	2026-08-28 11:43:45.127205+00	BRO	7.42	4.62	f	Verde Claro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268086_1787917422527.jpg	BL0106VD00800000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268086_1787917422527.jpg}
28f8967b-ef7d-43c1-8aad-ccfe909953e7	UPF20263804	Blusa Cropped Boom	76.25	177.00	2026-08-28 11:44:35.997335+00	BRO	7.42	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263804_1787917473784.jpg	BL0772PT00100000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263804_1787917473784.jpg}
363adf14-a657-476b-83a9-325ebfa6167f	UPF20262498	CROPPED TULE CLÁSSICO	57.00	107.00	2026-08-31 18:17:51.246093+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262498_1788200269898.jpg	001.15401208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262498_1788200269898.jpg}
ba30cb7f-37d2-4b52-b782-484f0582778a	UPF20264487	Short Fitness Summer	99.95	197.00	2026-08-31 12:57:29.233395+00	BRO	7.42	4.62	f	Salmão Electric	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ba30cb7f-37d2-4b52-b782-484f0582778a_1788181107451.jpg	SH0106LJ01700000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/ba30cb7f-37d2-4b52-b782-484f0582778a_1788181107451.jpg}
f5308cd0-0f94-41a1-af0e-2ea227cf90d3	UPF20264759	Short Fitness Summer	99.95	197.00	2026-08-31 13:00:13.67641+00	BRO	7.42	4.62	f	Lilás	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264759_1788181211170.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264759_1788181211170.jpg}
15f80495-da76-4b3f-ae33-ea1ac43890f3	UPF20262336	Short Fitness Summer	99.95	197.00	2026-08-31 13:04:12.106513+00	BRO	7.42	4.62	f	Verde Claro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262336_1788181448306.jpg	SH0106VD00800000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262336_1788181448306.jpg}
847242be-5ae1-4357-b0f9-03a500793cb3	UPF20266256	Short Boxer Boom	142.85	257.00	2026-08-31 13:16:43.610629+00	BRO	7.42	4.62	f	Preto	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266256_1788182201052.jpg	SH0772PT00100000002	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266256_1788182201052.jpg}
dbc7eb53-e7db-49a6-9432-998937c2f04f	UPF20261743	Top Fitness Summer Liso	85.65	187.00	2026-08-31 13:35:36.636599+00	BRO	7.42	4.62	f	Lilás	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261743_1788183333589.jpg	TP0106RX00302010004	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261743_1788183333589.jpg}
71078803-21e1-480a-a0b3-680bdc73e027	UPF20264678	Top Fitness Summer Liso	85.65	187.00	2026-08-31 13:36:51.650684+00	BRO	7.42	4.62	f	Verde Claro	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264678_1788183409686.jpg	TP0106VD00802010004	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264678_1788183409686.jpg}
43e8ffde-910a-4f0f-8852-595937f36838	UPF20269234	BLUSA DE TULE CLÁSSICA	62.00	117.00	2026-08-31 18:16:42.909411+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269234_1788200200605.jpg	001.14501208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269234_1788200200605.jpg}
6b8e72cb-598a-4bd0-8dd1-fd6e3ec0c576	UPF20265255	TOP NP ADAPTIV	114.00	237.00	2026-08-31 18:23:19.042556+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265255_1788200596630.jpg	025.06601208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265255_1788200596630.jpg}
e4230a11-cca2-445f-b228-28d109ac89e5	UPF20266202	LEGGING NP ADAPTIV EMPINA BUMBUM COM BOLSO	167.00	357.00	2026-08-31 18:24:27.699831+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266202_1788200666608.jpg	025.06701208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266202_1788200666608.jpg}
aef9392c-32a9-4613-820e-af62ff4bf67a	UPF20269255	TOP ADAPTIV ELÁSTICO PERSONALIZADO	119.00	277.00	2026-08-31 18:25:38.185251+00	CAJU BRASIL	0	4.62	f	LARANJA FLOW	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269255_1788200736038.jpg	025.06901208	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269255_1788200736038.jpg}
f1d8ca78-cc35-4f92-b62e-043175c1094f	UPF20262121	VESTIDO COM COMPRESSÃO E BOLSO	284.00	457.00	2026-08-31 18:32:29.404418+00	CAJU BRASIL	0	4.62	f	AZUL BIC	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262121_1788201147804.jpg	025.08400464	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262121_1788201147804.jpg}
d90522e9-5428-43fc-98c4-a917b3e127a4	UPF20265668	BLUSA UV CLÁSSICA	84.00	167.00	2026-08-31 18:34:41.856786+00	CAJU BRASIL	0	4.62	f	MARROM SIENA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265668_1788201279639.jpg	001.20901211	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265668_1788201279639.jpg}
97eee61f-35ac-4a7b-a1ac-4d2d25327ecd	UPF20263829	LEGGING CÓS INVISÍVEL COM BOLSOS	162.00	357.00	2026-08-31 18:36:24.197487+00	CAJU BRASIL	0	4.62	f	MARROM SIENA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263829_1788201382177.jpg	025.07601211	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20263829_1788201382177.jpg}
12444a33-e5d1-4837-bbe5-b0b6bd5102c5	UPF20263227	LEGGING ESPORTIVA COM BOLSO	149.00	357.00	2026-08-31 23:48:31.942401+00	CAJU BRASIL	0	4.62	f	ROSA OLINDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/12444a33-e5d1-4837-bbe5-b0b6bd5102c5_1788220127369.jpg	025.06400034	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/12444a33-e5d1-4837-bbe5-b0b6bd5102c5_1788220127369.jpg}
f4fbf33a-b258-4b0e-a0da-d62990868a2e	UPF20267070	TOP ALÇA FINA PROTEÇÃO SOLAR	104.00	217.00	2026-08-31 18:35:25.885281+00	CAJU BRASIL	0	4.62	f	MARROM SIENA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f4fbf33a-b258-4b0e-a0da-d62990868a2e_1788201400332.jpg	025.07501211	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/f4fbf33a-b258-4b0e-a0da-d62990868a2e_1788201400332.jpg}
accf8762-30d5-40d7-8a30-e1162f37f44d	UPF20261789	TOP ALÇAS FINAS COM COMPRESSÃO	109.00	237.00	2026-08-31 18:48:19.453582+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261789_1788202096997.jpg	025.03600633	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261789_1788202096997.jpg}
44b4578a-2b74-4bf9-885c-c28036067785	UPF20262749	LEGGING CÓS ALTO COM COMPRESSÃO	184.00	397.00	2026-08-31 18:49:12.298739+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262749_1788202150084.jpg	025.03700633	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262749_1788202150084.jpg}
08cef4f7-a38c-4f00-8708-d10461e8496d	UPF20265254	TOP SOBREPOSIÇÃO COM PROTEÇÃO SOLAR	119.00	197.00	2026-08-31 19:24:23.764354+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265254_1788204261487.jpg	025.00100001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265254_1788204261487.jpg}
e0e8cdbf-efac-41fb-9b4d-981f769482e3	UPF20261127	LEGGING ESPORTIVA COM BOLSOS	159.00	337.00	2026-08-31 19:25:27.921816+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261127_1788204326043.jpg	025.00200001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261127_1788204326043.jpg}
a5d189a1-aeef-4619-846e-37ef41dc8aae	UPF20262712	TOP ALÇAS FINAS COM COMPRESSÃO	109.00	237.00	2026-08-31 19:26:29.679132+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262712_1788204387347.jpg	025.03600001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262712_1788204387347.jpg}
ad7a7d20-ddb6-464e-9cab-000213aef72c	UPF20264699	LEGGING CÓS ALTO COM COMPRESSÃO	184.00	397.00	2026-08-31 19:28:21.08544+00	CAJU BRASIL	0	4.62	f	PRETO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264699_1788204498414.jpg	025.03700001	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264699_1788204498414.jpg}
9e40eb7f-300e-4d29-aaca-7dbfcf5ae35f	UPF20268165	TOP CROPPED ADAPTIV COM COMPRESSÃO	99.00	227.00	2026-08-31 19:31:37.324434+00	CAJU BRASIL	0	4.62	f	VERMELHO MORANGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268165_1788204695195.jpg	025.03101215	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268165_1788204695195.jpg}
cb20910e-33f4-4a25-8495-2d2233e0c65a	UPF20265226	LEGGING ADAPTIV COM COMPRESSÃO	169.00	357.00	2026-08-31 19:32:25.886136+00	CAJU BRASIL	0	4.62	f	VERMELHO MORANGO	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265226_1788204743162.jpg	025.03201215	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265226_1788204743162.jpg}
8cb2a4a5-8f52-458a-aff1-b630519a1412	UPF20265926	TOP ALÇA FINA	89.00	197.00	2026-08-31 19:33:39.254846+00	CAJU BRASIL	0	4.62	f	VERDE MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265926_1788204817383.jpg	025.07200028	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265926_1788204817383.jpg}
f7ab7d75-c6a6-42dc-ba7d-11e1ee91d2fb	UPF20269369	LEGGING COMFY BOLSOS CÓS	167.00	357.00	2026-08-31 19:34:24.18577+00	CAJU BRASIL	0	4.62	f	VERDE MENTA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269369_1788204856526.jpg		{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269369_1788204856526.jpg}
41bf3df1-cfc1-4d54-96d5-185b589c8219	UPF20264179	TOP ALÇA FINA	89.00	197.00	2026-08-31 23:50:00.235592+00	CAJU BRASIL	0	4.62	f	ROSA OLINDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264179_1788220198571.jpg	025.07200034	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264179_1788220198571.jpg}
691998be-432b-47ff-ba8f-7d36e544ccae	UPF20268673	TOP SUSTENTAÇÃO COM TEXTURA	139.00	207.00	2026-08-31 23:52:48.948083+00	CAJU BRASIL	0	4.62	f	VINHO ROMA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268673_1788220365858.jpg	025.00801107	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20268673_1788220365858.jpg}
737a3ccd-d10f-4dda-8204-a1ad9b500c1e	UPF20265866	LEGGING DISFARÇA IMPERFEIÇÕES COM BOLSO	149.00	297.00	2026-08-31 23:54:28.522341+00	CAJU BRASIL	0	4.62	f	VINHO ROMA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265866_1788220465166.jpg	025.00901107	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265866_1788220465166.jpg}
cce759a5-641c-41dc-bf2d-be4339c668ce	UPF20264838	TOP NP ADAPTIV	114.00	237.00	2026-08-31 23:32:13.341698+00	CAJU BRASIL	0	4.62	f	VERDE MARINA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264838_1788219129916.jpg	025.06601209	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264838_1788219129916.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/cce759a5-641c-41dc-bf2d-be4339c668ce_1788225394955.jpg}
68bab43b-5906-4487-b2b1-27cd035c32c7	UPF20261232	LEGGING ESPORTIVA COM BOLSOS	159.00	337.00	2026-08-31 18:52:53.423089+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261232_1788202372171.jpg	025.00200633	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20261232_1788202372171.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/68bab43b-5906-4487-b2b1-27cd035c32c7_1788248754980.jpg}
7a369a01-ab99-4d15-a35b-c9dd79978c2c	UPF20264682	TOP SOBREPOSIÇÃO COM PROTEÇÃO SOLAR	119.00	197.00	2026-08-31 18:51:48.312112+00	CAJU BRASIL	0	4.62	f	OFF WHITE	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264682_1788202305941.jpg	025.00100633	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264682_1788202305941.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/7a369a01-ab99-4d15-a35b-c9dd79978c2c_1788248796097.jpg}
fa4f77fc-9010-4930-8f97-9ddcf522c252	UPF20267982	LEGGING COMFY BOLSOS CÓS	167.00	357.00	2026-08-31 23:50:47.845974+00	CAJU BRASIL	0	4.62	f	ROSA OLINDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267982_1788220244924.jpg	025.07300034	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20267982_1788220244924.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/fa4f77fc-9010-4930-8f97-9ddcf522c252_1788293725582.jpg}
dff7d74a-6295-417b-8ef6-c5e21d66f7a0	UPF20262103	TOP ESPORTIVO SUSTENTAÇÃO	134.00	297.00	2026-08-31 23:47:30.623001+00	CAJU BRASIL	0	4.62	f	ROSA OLINDA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262103_1788220049207.jpg	025.06300034	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20262103_1788220049207.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/dff7d74a-6295-417b-8ef6-c5e21d66f7a0_1788293752213.jpg}
1d6c897d-8fd2-46ef-a23e-2a0f90e6f99c	UPF20266480	LEGGING DISFARÇA IMPERFEIÇÕES COM BOLSO	149.00	297.00	2026-08-31 23:58:18.966381+00	CAJU BRASIL	0	4.62	f	VERDE GALÁPAGOS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266480_1788220697266.jpg	025.00900024	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20266480_1788220697266.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/1d6c897d-8fd2-46ef-a23e-2a0f90e6f99c_1788225275704.jpg}
5b37491b-1b89-4fd7-8977-35abe967d14a	UPF20269567	TOP SUSTENTAÇÃO COM TEXTURA	139.00	207.00	2026-08-31 23:57:34.701266+00	CAJU BRASIL	0	4.62	f	VERDE GALÁPAGOS	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269567_1788220651686.jpg	025.00800024	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20269567_1788220651686.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/5b37491b-1b89-4fd7-8977-35abe967d14a_1788225299912.jpg}
7e4d790e-3d22-4e1c-89d8-6613d04c6955	UPF20264945	TOP NP COM BRILHO	107.00	237.00	2026-09-16 19:00:01.487793+00	CAJU BRASIL	0	4.62	f	LILAS MELISSA	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264945_1789585199249.jpg	023.07100558P	{https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20264945_1789585199249.jpg,https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/7e4d790e-3d22-4e1c-89d8-6613d04c6955_1789585232351.jpg}
\.


--
-- Data for Name: tamanhos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.tamanhos (id, nome, ordem) FROM stdin;
2d8adf35-cf48-43c9-acbc-b0f1eded13e4	PP	10
394dd3f4-45e4-4eaf-9028-3260e229bb65	P	20
d4c5c7d6-cc72-4381-80e6-9b87e99fe772	M	30
88d8c3ff-c506-43a2-a7ba-2617fd7c679d	G	40
05e02b30-0867-4b3b-8518-0a0805db9706	GG	50
\.


--
-- Data for Name: venda_draft_itens; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.venda_draft_itens (id, draft_id, produto_id, estoque_id, descricao, cor, tamanho, preco, custo, qtd, foto_url, ean, created_at) FROM stdin;
a9b78c2a-fe36-4440-bd71-c37e480e0444	b0063572-4d64-4325-a749-7936d0a5657e	b4569222-dc3c-4d38-a01c-51552d0d23d7	4ca420ab-4d92-4ece-9b88-e9bf70a06d0c	BERMUDA COM BOLSOS E ESTAMPA	LARANJA PÊSSEGO	P	349.9	154.52	1	https://jdduvyrrilnxlwbieqjr.supabase.co/storage/v1/object/public/produtos/migracao/UPF20265151_1784768124728.jpg	\N	2026-08-31 21:57:48.881744+00
\.


--
-- Data for Name: venda_drafts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.venda_drafts (id, titulo, created_at, updated_at, user_id) FROM stdin;
b0063572-4d64-4325-a749-7936d0a5657e	Carrinho salvo	2026-08-31 21:57:21.319901+00	2026-08-31 21:57:48.664974+00	a71190dd-e547-4c5f-bb89-545b283ca256
\.


--
-- Data for Name: venda_pagamentos; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.venda_pagamentos (id, venda_id, forma, valor, parcelas, crediario_frequencia, ordem, created_at) FROM stdin;
3164add0-356b-49e3-b65a-4fbfbbdaab17	10fd7815-9ba0-4c7f-a124-04e275ae2d91	credito	239.90	1	\N	1	2026-05-21 17:57:18.000819+00
c94d531e-cc33-4857-8e33-5a1668552a5a	44ce3879-2819-478a-9084-f15785c0e5fe	credito	434.00	2	\N	1	2026-08-06 20:10:49.878036+00
8bb9e0ac-751f-4a3e-a698-9a6677e3a7f3	fda15600-10c7-45bc-b08a-df44caab1a97	pix	455.81	1	\N	1	2026-05-06 14:20:53.07651+00
ddb515ae-72ad-4d8b-9284-a781425aa89a	21d0a14e-fe32-4cce-a53f-dd04256d1836	credito	579.80	1	\N	1	2026-03-06 14:53:50.796078+00
c82613a8-a515-49a8-8113-f1a37a5cd05a	1871e295-fb6f-4022-8cb2-5ce142c003e5	crediario	129.80	1	mensal	1	2026-07-27 22:00:29.672289+00
83541abb-b3ae-4c51-99b4-f7152f633e31	73fac3fc-117b-4739-9e41-0994acab437d	pix	240.80	1	\N	1	2026-06-12 20:33:41.211734+00
09c3b61a-6e8c-4719-976c-b486e82a9bb6	79ca1441-55e3-47b3-a1fa-90a4fc49d27d	pix	640.14	1	\N	1	2026-03-02 23:52:50.836482+00
e3c967b5-a0ba-41fd-8657-e6d7abaf8803	716d1344-1503-41fc-8eb4-8a7547bde1bd	credito	119.90	1	\N	1	2026-07-22 13:14:11.045707+00
e5b8a61f-fa89-43c6-8971-54eee973bb87	12d68805-4d98-41ff-be17-c5dc737b75fd	credito	509.80	4	\N	1	2026-03-07 17:26:04.230685+00
c8194529-c6aa-48b0-a6ba-778d147a75ee	719e410d-7728-48d8-a3f9-f7473ad72efd	credito	240.00	1	\N	1	2026-04-30 01:57:36.376687+00
faec4b7d-b934-4030-9729-f392724f6dbf	e30df005-79ed-4d50-adbd-6b075a3a858c	credito	719.60	6	\N	1	2026-02-04 18:57:53.896729+00
1b779adc-2e05-4262-8db5-d922e6ed5f48	7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	pix	1500.40	1	\N	1	2026-04-26 00:11:17.647437+00
55e2c686-8f78-4733-9eea-e52537c2bda8	07406a7e-bbf2-4886-a4ce-b3e7952a2fb4	credito	699.80	1	\N	1	2026-03-06 10:09:02.332897+00
1d41d143-538f-459d-8166-91fd03eee820	178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	credito	1235.36	6	\N	1	2026-02-04 19:55:50.553776+00
afc75b0a-576d-42ad-87fe-713ba6857655	e1cb8ba5-583d-4552-ba38-d59bf16a8dbb	crediario	179.90	1	quinzenal	1	2026-06-05 13:20:18.172301+00
8dcf18f1-dab9-4e2e-a1f8-ac0031caaddf	bf87a8b8-08fc-4399-9c10-93390b92977b	credito	279.80	1	\N	1	2026-04-04 13:25:28.417668+00
71a3feaf-9f87-4eb1-89fb-efe2c7a89e93	9431a927-7040-4ed8-98d5-4630dac31865	credito	499.90	6	\N	1	2026-06-11 23:59:38.179872+00
61e6116f-f08f-4658-9b6a-44fd3370181d	5d1f3636-8fef-46ca-9cd8-f60b1ecb28ab	pix	275.41	1	\N	1	2026-05-12 19:17:56.607721+00
3131e239-6b50-42d8-98da-e5c51c4a7793	249b3b88-6270-4615-8765-b1ebcaded45e	credito	988.00	6	\N	1	2026-08-12 21:51:23.014341+00
ca4cd0b8-b350-4a18-8a06-6d2e62f6766c	9bc77b51-8fa3-4403-95be-a2021c885604	pix	369.90	1	\N	1	2026-02-04 15:58:30.693628+00
00288dda-5603-431a-89b4-17c1f1e6cacb	15f3a142-3361-4841-8ed5-9f51f2323815	credito	160.00	1	\N	1	2026-03-13 15:42:58.240639+00
678f07b1-88cb-46f8-8a31-393185ba1d6b	ef139de1-d72f-4316-967d-bf1517e4a06f	credito	418.00	1	\N	1	2026-04-20 18:59:17.593541+00
d845b555-8449-47b2-bb99-b3b7684fe1b1	3b91814b-8a9b-413a-a8ee-66a712f6613d	credito	479.80	1	\N	1	2026-04-28 19:38:34.658538+00
96c70f00-da0e-4d4f-a8db-5baa5e81e06e	4cb77150-9c30-42bf-962b-657dafcd0c15	pix	175.00	1	\N	1	2026-03-23 19:19:09.030151+00
1d837485-5532-4c89-8d30-35c3d3fea3a5	7878276d-05fa-402d-89a7-5b736e94df21	credito	529.92	1	\N	1	2026-08-16 00:44:11.901989+00
e7f2070a-6f48-4433-b6c8-171ced3fe140	fb3d69f8-e303-43f2-a588-2c63f56d9dd9	pix	351.31	1	\N	1	2026-07-16 20:54:03.034708+00
e19567a5-544f-4d56-91d0-642f07f0c908	d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	crediario	3375.33	1	quinzenal	1	2026-06-01 01:12:54.424878+00
46b0df8f-67c8-404e-94ed-55eb42e354f0	7caedb35-8690-4a93-b3b0-ad139b8e2550	pix	500.80	1	\N	1	2026-07-06 19:47:45.800539+00
adf04222-700f-4c10-853d-d1a61800b106	cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	credito	1115.25	1	\N	1	2026-05-27 00:22:45.166862+00
99c9a6c6-1a3a-446a-b8df-6fb8e0e424b6	22ed3572-8295-462e-8ff2-abf353e5a1ff	credito	618.00	1	\N	1	2026-02-09 14:12:45.230731+00
65802606-377a-456e-bc5d-1d2e3a8ffa89	3f29919a-5012-4fd9-80f9-89521f5d041d	pix	219.80	1	\N	1	2026-04-26 19:21:58.194969+00
a5339313-f50f-49b0-b29b-19fea3b60be4	8534b434-f91e-4942-90c9-30909f036ed3	credito	289.80	3	\N	1	2026-03-26 14:54:54.99162+00
c8413518-8941-40e8-a20a-8be609211b00	a771d56c-f3a0-4bb4-b8da-d09dacfbc874	credito	1809.30	1	\N	1	2026-06-26 15:55:01.696179+00
ada3baa5-e3b7-47ad-a9a3-09ae24297da7	6813c9ec-1007-4a41-bb18-a9956f13db8f	credito	499.90	1	\N	1	2026-06-09 19:55:14.242003+00
aa21e1f8-1460-4f23-baa8-ffac7dc7d301	8828bc22-2eb9-4f73-99c8-c86fb41d4fb4	credito	199.90	1	\N	1	2026-05-14 18:36:42.647863+00
b09bd038-e19d-468e-a8fe-67fce0b7d1fd	40757cf5-57b0-47c1-9b20-84af21d31c08	pix	267.80	1	\N	1	2026-08-01 15:44:12.238536+00
cd66c571-693b-46ca-8bef-38a118b3abf1	50780636-1df1-4faa-aa12-0592fc1d85f7	credito	800.00	6	\N	1	2026-01-28 08:50:53.677587+00
55382537-c1d0-4bc4-8159-a42ea6f825ea	136bae77-5194-4318-9fe2-0d9cbef9a9b4	credito	415.00	3	\N	1	2026-02-17 16:10:34.329741+00
0895af2b-88bf-4ae5-9840-afb3dc6b12b0	78887ce5-2c9b-4ee5-8945-39805bfa5206	pix	464.70	1	\N	1	2026-03-14 13:09:06.990802+00
b155a707-8849-48b2-a751-5fc2cc1aac5e	c69c1fdb-e741-4513-aa4a-ba83b4c699b3	credito	1770.80	1	\N	1	2026-08-13 00:15:26.008893+00
bfc3f0f8-5e26-4d4d-bd43-f52d760fda17	bd43127b-736e-4833-808d-fd71ce103c1d	pix	519.80	1	\N	1	2026-04-15 13:23:20.693504+00
7ac96d37-15ea-461e-bbb4-c041b370aa03	addc5e67-13d8-4857-940f-6e558a2b229b	crediario	484.00	1	mensal	1	2026-08-13 19:18:21.988169+00
34c25ece-5542-46d4-b6d9-4c64bebbfe4a	94e02f85-247a-4dde-8fe5-4e3380b3a1f4	credito	300.00	1	\N	1	2026-03-20 20:02:34.290655+00
e683f772-ea35-44a7-b1a5-2f2d811c6b2e	5aebee91-b1f7-4309-92fe-111743a716c8	pix	184.00	1	\N	1	2026-04-29 15:47:21.753192+00
86b58aa1-489f-437e-87d4-8a57b7d458b5	08cff621-3183-45f3-876c-d3e7f04fff90	pix	199.90	1	\N	1	2026-04-09 12:21:14.804825+00
687d67a9-da54-4dc4-8ff4-2f52f76225d5	ad3c7cc7-2684-49af-afc5-88c0bd35469a	credito	1592.37	6	\N	1	2026-08-12 01:03:56.65875+00
9ba1a625-6973-4b1e-ae36-0ecfd854a109	1b0dc0b3-cad0-4bb3-8c98-ebb66aae4ddc	pix	109.00	1	\N	1	2026-05-22 19:51:01.095182+00
c1e7eb00-d8fe-4232-99f6-2ce78bcad9a5	19b419d7-f1f7-4764-b375-b2cbda99704e	credito	679.70	1	\N	1	2026-04-15 17:14:44.053532+00
ee1bc05e-f5d2-44b7-8f73-b277e00396e5	0f101e5a-c55c-4747-8ccf-e5ee06fb4cf2	pix	129.90	1	\N	1	2026-05-15 01:24:51.50143+00
04899a86-79fe-42ef-a409-bc59f2990c6f	6c1b5939-0e32-4737-89af-6344c1f9b24f	pix	379.80	1	\N	1	2026-04-03 16:47:33.773719+00
e6364eb5-8eb2-454c-8698-d6e404e50c63	1fe9b44b-e800-42c2-8860-751501baf75c	credito	277.97	1	\N	1	2026-02-08 17:18:57.014812+00
be9ce8e2-a9fd-4726-be04-95eb8d2b734d	8e8930cf-5748-4db9-841d-f21d3e34bf90	credito	560.88	3	\N	1	2026-01-29 21:12:17.182092+00
bf9c57b3-9071-43bc-ae80-56dbe06c0a30	83b28183-0eed-4fa9-a132-e5102c239527	pix	61.90	1	\N	1	2026-04-22 19:18:36.363258+00
39068445-b448-4403-bcc1-4705471714a2	05e78f2f-b675-4088-9972-ce575938e01c	pix	134.29	1	\N	1	2026-06-02 18:29:45.275414+00
e37f8663-a0d9-45f0-a260-e3c71245eaff	6cc62712-62ab-432d-863c-d12a13122ac4	pix	67.90	1	\N	1	2026-06-16 23:52:41.763072+00
46877505-bf8a-42b0-8af7-48b44ea2ca8c	c3878d85-0946-43fc-ac2b-b4e596d5b2a6	pix	289.90	1	\N	1	2026-05-07 19:12:38.574171+00
bf78e6bf-9310-4856-99be-e7dd216992bb	c6c01c35-8188-4f75-af63-3eec540c1526	credito	829.50	4	\N	1	2026-08-14 00:01:24.577883+00
741fa989-592c-419f-adde-07f29eea94ac	46bb9fa7-449f-408b-9ea1-d9ba76fd045b	pix	77.90	1	\N	1	2026-03-14 13:12:09.098835+00
cae25390-ce6e-4260-8e49-9367ea73c01e	1882538b-8b9b-424e-a1f7-ecb2c099209c	pix	269.90	1	\N	1	2026-05-08 12:51:32.847609+00
cc78f44f-411a-4705-a82b-369a2771710d	a70452b0-1880-47cd-908e-154924638f34	credito	2928.20	1	\N	1	2026-06-21 00:46:02.082996+00
9916d062-53f1-4fec-bfe5-2cd1ebe47d8e	bdd3797f-f159-4360-ba05-59b95ee6da3e	pix	324.00	1	\N	1	2026-02-14 10:39:46.35188+00
a1d8517c-6462-4760-ac69-56407848df51	bee19e29-193f-45d2-819d-9760948fd45d	crediario	499.80	1	mensal	1	2026-07-03 18:44:11.817392+00
9334bc61-178e-44e9-9dbb-6688caf8de17	45f0a747-a320-4429-b960-709b4666e22c	credito	538.32	1	\N	1	2026-04-02 14:48:20.230468+00
da8b43be-085e-4cb5-a924-66dd21d7ed87	c38b79a8-9005-4b52-b009-cb24693fa29f	credito	358.32	1	\N	1	2026-06-26 18:11:49.710846+00
ed152152-114d-4e68-b28c-e6125a1f7f25	3d728f6c-e38d-4137-b099-545946a2e3cc	credito	769.70	1	\N	1	2026-07-01 17:12:22.38039+00
f279a6d1-8ee7-4b63-84ea-ad56c167e4bb	ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	credito	1146.90	4	\N	1	2026-08-14 12:04:23.377605+00
dedc7359-1849-4bed-b6dd-0388929ec0e7	41ee7f32-7015-4352-bcb1-a869faf314fd	pix	359.82	1	\N	1	2026-04-04 13:17:00.186843+00
38b43499-4898-4a42-98ea-400b736028dd	d5f32451-caad-4a78-80db-2f6f370284cd	pix	655.83	1	\N	1	2026-02-20 17:25:19.980754+00
6e8cd059-78b9-4122-a736-8d78ea6fa8c8	9a8b5fc0-6438-4c46-95d4-cf6e4048c49d	dinheiro	620.00	1	\N	1	2026-05-22 23:28:15.798456+00
81b39086-200a-4639-8167-dc41610a3124	968f323b-e225-4869-984d-bdf058330c8c	credito	448.90	1	\N	1	2026-06-06 15:32:14.475137+00
a7ff10ff-3c91-4bba-83a3-10dbe9a2f754	271f0269-611b-47ca-924f-53fb4f9e4a82	credito	525.00	4	\N	1	2026-02-26 13:45:21.922107+00
05132d5d-d4ad-4d21-9afb-40d6c613404b	e95183be-3c02-4a88-a1a6-7449f2175023	pix	310.00	1	\N	1	2026-01-29 22:53:52.90083+00
939cd1e6-1b42-44cc-8e8b-641afd564a74	6d07bd7d-573b-443f-8edc-5972e052b948	credito	759.60	4	\N	1	2026-03-13 20:02:47.909076+00
8ffec81c-8ca2-4157-8b25-1baa1649d57d	416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	credito	1369.64	1	\N	1	2026-05-29 03:35:51.471492+00
5ad26b9c-5b01-423c-b531-0a73bc7ff3a7	7676aaca-25c7-4e74-9051-45e42fedc114	credito	474.81	1	\N	1	2026-05-03 13:19:38.616079+00
f5a5dae0-4e72-4067-ba16-4f5871939b3c	8d1fbc53-56a0-43b3-b898-491312a47646	pix	330.00	1	\N	1	2026-05-13 20:03:17.410898+00
e67fcc89-5bec-4961-bc07-e89d061ec9b7	f9e83c9e-f4c5-4590-93c9-82e21d71a414	credito	755.70	1	\N	1	2026-05-28 18:32:32.489709+00
44ca2ac6-f7aa-4106-92cf-ab744914e287	aac20eed-6110-46b6-9a1e-fe4a81cbef07	credito	391.72	2	\N	1	2026-03-20 20:17:08.071094+00
231b07c6-89d0-45a2-a427-ebbae65abc9e	1f0641b3-2c24-4162-85c8-701513526fb7	credito	418.00	2	\N	1	2026-05-13 19:52:54.713731+00
3c29400a-c6b4-427b-8426-28cf88226da0	fa318a38-f899-4179-9f8e-672fddac185d	credito	578.57	1	\N	1	2026-04-06 19:30:33.42611+00
bab429b6-6966-4933-8eb7-fce33870046d	390b45e6-b74a-48c2-811c-d582b1907a1c	pix	460.90	1	\N	1	2026-04-22 19:12:40.047682+00
d399a315-35a0-4422-9442-1873c88c1dbc	14feb63e-54b5-41ef-9274-0908b7eb4cab	credito	296.33	1	\N	1	2026-03-10 17:48:58.722517+00
95c01332-9f95-406a-879c-c86f549852ea	7ce6ce23-ca2e-4bc2-9569-6256979be0cb	pix	198.00	1	\N	1	2026-04-09 20:42:21.502533+00
76c13b2b-80df-4f7d-9e9c-fd00911fe912	e0461218-e0fc-420d-96c4-3ba16e63add3	credito	439.90	1	\N	1	2026-03-14 15:49:58.506691+00
e6a57f30-5497-4bb4-a141-2cd639b1683c	319e1273-25d3-4963-b3ee-414be1bfd801	credito	464.90	1	\N	1	2026-07-02 12:56:00.315348+00
4de56867-059c-4d05-8067-65f82b1ec167	a545d132-497c-41d0-9052-7b96bb3f9a84	credito	339.80	3	\N	1	2026-02-19 17:11:54.606343+00
48bf973a-ca3b-4791-913f-6082aeb6daa1	3310eb3d-0a5c-4516-a8da-ddb1122c7567	credito	898.80	1	\N	1	2026-04-30 15:41:13.656667+00
1c6fe1fa-03bc-4587-b85a-9b185d84f56f	5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	crediario	566.60	1	quinzenal	1	2026-08-01 08:36:20.763766+00
31fa24c6-3eb3-4b2d-9ba2-2c625f65caa0	25773b86-715a-4f92-8433-20fb7fabf595	crediario	219.80	1	mensal	1	2026-08-01 08:24:28.01768+00
20d494f4-3360-4071-b833-986ebe705279	783960f7-8b70-498d-bf46-31f40ca6b2eb	pix	200.90	1	\N	1	2026-07-27 18:10:21.529626+00
b0037cd4-c87e-42ff-8584-cac8789eca08	995e79b0-dfcb-48a7-9cd9-bf89cafe8f33	pix	62.90	1	\N	1	2026-05-22 12:31:13.183726+00
32a9ec8f-8196-423b-b20a-3057e059462c	b4f7d41c-6d78-4a29-a39f-77b81f1b0434	pix	196.80	1	\N	1	2026-07-04 15:34:01.902668+00
1a65f38b-fbc8-4509-8033-cd34ab22d356	9e0a854e-eccf-43ae-87d3-18a676af89a2	pix	462.27	1	\N	1	2026-03-05 13:45:55.140433+00
95be99b8-6c3a-4cad-a9b7-8c6d819b6371	06188a9f-9ffd-4ed9-9c51-35ca0dd88212	credito	1117.80	6	\N	1	2026-04-16 15:38:12.282751+00
3943b2f2-6a91-442d-aab8-947b07f5232e	898c5028-dbbb-4708-8a72-ff154f72c37c	credito	369.90	1	\N	1	2026-03-02 19:07:39.799933+00
6bf3f4fe-5ebe-443e-973a-19b630e1385d	cf7d6e22-eb97-4eaa-9396-ede63576eb4d	credito	379.80	1	\N	1	2026-05-22 13:37:39.186154+00
1e222e12-41f0-40c6-ae06-b7110ed03019	c6db1718-62cf-48ef-a9a5-f5870431d1ee	credito	507.80	2	\N	1	2026-04-02 14:43:23.776951+00
c6c1af8c-ddf3-4bb5-96b2-8104143d7fb2	58049dd1-19ca-4b89-82cb-1e693c542e4c	pix	259.57	1	\N	1	2026-05-13 14:15:44.818264+00
c3342774-221c-4a06-b560-757c95f6e7b6	657db4fa-adf1-4e2d-9a28-98a0041311b9	credito	488.80	3	\N	1	2026-02-24 17:36:30.548342+00
abc60f0b-a76d-495a-b0ba-ee8a8bf7bf3a	0a3b2e63-431d-46e9-a313-6a8f945dec90	pix	953.90	1	\N	1	2026-08-08 14:30:24.823079+00
4ebd6d5f-9a15-4aed-a543-d41a122b187f	a0d80b27-f650-4618-84d9-b06369488431	dinheiro	380.00	1	\N	1	2026-03-26 14:49:31.599711+00
4c6de066-46d9-4806-ac2d-470908ab5739	b2db3b18-16a8-4696-863b-0c870c31b040	pix	129.90	1	\N	1	2026-04-29 10:19:18.824788+00
84f124b3-63ea-4697-a320-db19db6378d1	30309d16-15c5-4f4b-866a-e959451719a4	pix	139.90	1	\N	1	2026-06-01 19:57:26.807294+00
c46ea85a-00f4-42d8-abb5-b94f1f850d4c	3a385a02-2b2d-4546-bdbf-4d8b98e5d53f	credito	539.70	6	\N	1	2026-02-07 13:44:39.358152+00
1f0a981d-7658-4278-b95b-6263c15ce240	0455e7f3-b7d4-4fb0-9a70-552f05285c1c	credito	209.00	1	\N	1	2026-05-13 20:15:17.171555+00
b57dd65f-b42a-4483-b3fa-67d4b95f2887	ac6246c5-9ab3-4e5b-a2c8-1df457a148ed	dinheiro	539.70	1	\N	1	2026-04-08 15:14:15.094686+00
279f98d2-e4c9-48f5-ba3c-678a2ea52fc7	023b9f31-a3c3-404f-938e-58215f18b3a4	credito	941.11	1	\N	1	2026-04-21 00:22:24.625841+00
ae5e41c0-f08c-4aff-b394-0579686bd88e	ed7eeb3c-f871-4c6e-aa43-488a64d93e1a	credito	199.90	1	\N	1	2026-04-22 12:52:32.475054+00
23a4279d-4eac-4c19-a7dd-6a3f96f58866	228867b0-244e-44d9-a65f-9c0af5bdc2f4	credito	626.81	1	\N	1	2026-05-06 20:41:03.438232+00
9454ef8d-6bd3-4b4f-b3de-8f437186b365	615d7e05-5fc0-48cf-b653-ee6c11d0567a	pix	269.80	1	\N	1	2026-06-30 21:15:56.368355+00
5fa8240b-4ece-44bf-a582-35ef0d1f008a	c93e7bf8-0fe3-4069-8ba6-fa0bff528634	credito	499.80	2	\N	1	2026-02-10 15:31:36.254482+00
089fab0b-3a51-48ee-8389-84cdfdb75bdf	7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	credito	2439.20	6	\N	1	2026-03-09 14:34:49.392884+00
0ebb40c3-738a-4382-ab5e-2c2857c9cbb5	70b3de88-4be4-4917-9b7f-329d4b43795b	credito	1475.95	6	\N	1	2026-01-29 21:33:42.439459+00
326ce5f9-c775-4e44-a0aa-f3e7367d2dbe	b24f4633-230e-471f-ba24-21c5bebd1113	credito	460.00	1	\N	1	2026-06-07 14:05:52.633627+00
081ba141-695f-413f-89c8-c7e7fae7a13b	b53f59e6-8f32-4554-80db-5b2e7ff60841	pix	104.00	1	\N	1	2026-04-08 16:36:38.535109+00
c75358b0-8e43-4fec-b605-e325cec836f3	bd33264b-59b5-418c-8869-68201818c57a	crediario	199.90	1	quinzenal	1	2026-07-01 13:56:57.957035+00
6ef4fee1-bb48-4626-ab1c-b4a2d25f8fc1	313756d4-156d-447e-be65-23f74b6034e5	pix	198.00	1	\N	1	2026-04-09 19:39:08.088668+00
648677bd-bfe6-4bee-83f3-f24d7946389b	18cd6848-d998-4fae-9a23-6b0bcb951fd7	pix	160.00	1	\N	1	2026-01-30 00:17:35.941534+00
0e8ada22-93ef-4e96-9629-f74c9daa3b7c	9358736e-dc18-45f7-8ef5-75bfd27924a4	credito	209.00	1	\N	1	2026-05-14 02:14:44.113916+00
146e39df-c8f8-4016-bb60-85c1a8731397	2e744f06-0c9d-452d-8c90-8806905bd4e0	pix	2993.76	1	\N	1	2026-05-11 02:26:34.404736+00
5bb56fa6-cfca-43b3-b258-005eee3495ac	58468760-bada-4195-b6f5-4dfa8bda8313	pix	155.90	1	\N	1	2026-05-22 12:29:20.679654+00
546d8b3d-8f14-4dcd-a44f-0573fd3ec48c	d7b0855c-a27c-45f1-bed3-90c1deaddcea	credito	209.00	1	\N	1	2026-05-13 22:54:06.757951+00
93c7c476-da85-4390-892f-8d92c0a89202	99252fc8-5b21-4d74-8d42-8ae7ed615c5b	credito	199.90	1	\N	1	2026-04-14 12:26:44.642523+00
b49d56e5-dd8c-4be3-93e9-fb7c17241c90	09069f38-1e9a-4440-adf7-516ce9758547	credito	782.24	1	\N	1	2026-04-21 21:33:09.713823+00
373626e1-6bda-484e-92da-bab706c202eb	15614157-7336-4210-99f9-9cbf371e4a11	pix	249.90	1	\N	1	2026-03-16 18:29:25.665866+00
a11adf7c-f712-4fe1-87c2-7a4f35c2b593	fa8f9f11-b36c-4d86-9a49-a86dce8433f7	credito	1025.60	6	\N	1	2026-03-03 21:54:38.951608+00
da13b25c-d8e3-4528-b83d-303e46353a07	b6d7ce40-b699-4914-9ee1-b3f4b127b285	pix	89.90	1	\N	1	2026-07-02 18:15:04.082323+00
3d827b98-2d57-493f-bcef-ed1986e85875	1970c736-adbe-45a5-82f9-f744633a36ee	credito	482.08	1	\N	1	2026-05-04 18:35:02.89857+00
84ed6c2c-f957-4c07-b3df-9b2a6a2935ce	a1f31cad-6062-4ebc-8598-16ae90f366d3	pix	322.81	1	\N	1	2026-03-12 11:44:44.378132+00
dce45571-0949-43aa-a239-0231611e9c9c	b5890cc9-86c0-40e9-9d56-fc079223159b	pix	209.80	1	\N	1	2026-04-25 15:25:42.032047+00
0639c947-0df0-4565-bafe-afed04261270	fa9b359c-6a5f-4edc-800e-1e07336ced79	pix	129.90	1	\N	1	2026-06-19 18:08:45.211772+00
9cccad9e-9d58-4bc6-9fde-dfe25a58c31a	28cc2232-8cfd-42d1-b38e-4a5668fdad11	credito	347.70	1	\N	1	2026-05-11 02:43:09.961969+00
c8bf419d-392e-4fd1-b7e6-494d6634df01	c2ddf683-8768-4178-b1fa-6bef806ad340	pix	174.90	1	\N	1	2026-03-07 13:28:00.714803+00
a056cfae-d82b-4a50-be3f-34c61906711e	d2ac5fb3-efaa-4864-9f12-edddd4118831	pix	332.01	1	\N	1	2026-07-23 19:18:37.650956+00
aa6ebd78-c22a-4c70-a2c9-845ae720e795	2193d452-0c1e-4500-a3ff-d95f44e2e811	pix	329.70	1	\N	1	2026-06-05 20:21:09.52115+00
5756e1a0-a088-454e-8607-071a8051685a	8f7f1d2e-d845-4d95-a2d2-857cf11e5358	pix	359.82	1	\N	1	2026-03-06 01:06:58.787407+00
37c12eb9-2466-475e-9c3a-92eee93f620f	f1a029fc-60c5-4f80-868c-bc17a62963ba	credito	249.90	1	\N	1	2026-04-01 19:31:29.898892+00
50a89e86-bb24-4bad-8311-d915221b35a7	3a18bedc-cd9a-463f-b00f-1ccc82206bfa	crediario	599.80	1	quinzenal	1	2026-07-11 03:36:02.353817+00
d34dcffa-3444-41e0-9b69-366c630aacdf	8289852a-5b57-43f4-ab76-6a856d472dae	crediario	119.90	1	mensal	1	2026-08-18 17:08:35.202186+00
20618f2f-0087-4682-a41e-25ebfd8aca3a	661a2cdf-aaad-4d4e-acdf-986f971d731e	credito	554.00	3	\N	1	2026-08-22 13:23:48.894235+00
65df44b8-14df-4d7f-97b8-9a6c3a1ed67c	0f63c759-5880-43f2-98f1-2932e52be8be	pix	782.64	1	\N	1	2026-08-22 18:40:34.275228+00
a0e830b2-fd52-4b73-9e84-efe7a5aa93a7	5fb759a0-739a-4fd1-a207-1712f5952fd7	credito	4507.40	8	\N	1	2026-08-22 19:34:23.103363+00
fb730ccb-51db-481e-8a47-c143ebf48603	47652497-0be9-468b-975b-ade0ca3410df	credito	329.90	3	\N	1	2026-08-26 19:39:50.369537+00
2cce7492-fb97-420f-bf77-9c57a249c5ca	0b156dab-8965-4358-a6da-7e598e3ce2d9	credito	3282.09	6	\N	1	2026-08-29 14:16:05.766992+00
5c35219b-8a7b-48d8-9766-c9a6c16864d5	067ac8b8-86a5-4710-9142-2277faccc67f	crediario	119.90	1	mensal	1	2026-09-02 01:41:24.131945+00
29104233-d456-4a6f-8648-284bac55914e	49415213-6157-4937-ac75-7f612ded322b	crediario	260.00	1	semanal	1	2026-08-22 00:27:20.830205+00
02cb23ad-c5be-4df4-a9c6-f6bb138a689b	46f01bfe-85a9-415a-b704-44ecf0c33c0e	credito	129.90	6	\N	1	2026-09-22 19:57:33.913195+00
65309eb3-081a-4d56-9418-8038c7d9b1c5	f3d70443-3269-4cbb-bad9-0b67e6a68a5e	crediario	722.90	1	mensal	1	2026-08-31 23:41:34.612344+00
08f5135a-d4a3-4093-8a7c-d02b2727e4df	6311f079-8c03-46c5-81a1-e1ebc45c06b7	crediario	229.90	1	mensal	1	2026-09-23 13:14:37.176689+00
5642f4cb-c990-4b3b-b59d-db1d0ef78e50	7f7f4cdb-8718-4d55-8dfb-84d032f82b13	crediario	220.00	1	mensal	1	2026-08-27 21:29:49.203418+00
a47c3b02-f653-4d90-b071-329bfa58b45a	9b9885a5-a11b-4ee2-a68e-252311e8d49f	pix	534.00	1	\N	1	2026-09-02 15:07:43.762552+00
5fcebe9f-2f2f-413f-994e-594f0f280597	af0ccc75-7300-4f7d-a066-f56be7d19fb5	crediario	291.00	1	mensal	1	2026-09-01 07:12:23.90837+00
36018eb2-47f6-4bae-a762-8c9a4ed5864d	be56aead-81ef-4271-be5b-76124e0d348e	crediario	297.00	1	quinzenal	1	2026-09-03 15:45:40.349678+00
baa036bb-85d4-4d93-9b89-50caa2721171	aa0a4526-e1b1-4a62-bfc4-d1e091e95891	pix	249.90	1	\N	1	2026-09-04 00:45:04.572656+00
c88372a3-7f84-4f7a-b7b4-b354d3abfe12	cd0b0dcc-5ca3-48f7-90f5-a8590cc26251	credito	365.80	3	\N	1	2026-09-04 17:11:31.035432+00
134211af-8bab-4591-b914-29dbb5f0cefc	9765680c-d76a-4c5d-9b4c-2e186f210b43	credito	297.00	2	\N	1	2026-09-11 14:59:09.426873+00
a0cb9aba-78ad-4bed-83b5-48c267dc9553	c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	crediario	5977.90	1	quinzenal	1	2026-07-23 23:23:56.742045+00
83788256-9336-481b-bf0d-6b213ff9e519	69d88638-e460-442b-9ae8-7fafd2ac5d1b	crediario	1035.80	1	mensal	1	2026-09-09 18:10:25.294671+00
0d60e656-383e-4133-9c38-d7a46d3a2c33	30274953-5922-4d2b-9972-e1db42931650	crediario	279.90	1	mensal	1	2026-09-14 13:54:35.458312+00
2f18b262-15b2-476e-8216-5d600233c76f	0b39c086-50d5-4d9b-9f55-b219e6318742	pix	259.90	1	\N	1	2026-09-14 17:23:19.083+00
ce5929a6-7dd1-44f7-9ab9-9e161e54621b	0d5a22ef-78a9-4139-b8c2-c99e6a3fcde6	credito	297.00	2	\N	1	2026-09-15 19:20:40.35254+00
94af2576-7982-48f9-a561-5d5e2037db39	8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	crediario	6459.50	1	quinzenal	1	2026-09-04 17:25:35.847851+00
1a815c38-829c-442d-a304-65b28559dcf9	de8a6583-05af-4f2e-8cd9-ac2c4610d275	credito	559.80	3	\N	1	2026-09-22 15:12:51.35247+00
77a3b3cc-1f4d-41da-aec1-903ccc0ba2fa	fc41bd5c-40f3-415b-9ec5-24cd78e8a5d4	credito	378.90	3	\N	1	2026-09-22 15:46:19.098442+00
3a8e447b-e56f-4ee8-b67c-d7b542b8e378	22907bde-880d-4f8e-9584-4367d1582d0b	credito	369.90	3	\N	1	2026-09-22 18:58:06.483052+00
3146a20f-277e-4e6e-9a91-08d538d90c97	bfbe41ce-d230-45fa-81e2-1c999afed65d	credito	329.90	3	\N	1	2026-09-24 14:57:09.583086+00
6e06bbce-e5a2-4a94-a68e-0ec633d3ca8b	0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	credito	865.00	6	\N	1	2026-09-25 00:20:13.857142+00
\.


--
-- Data for Name: vendas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.vendas (id, codigo_venda, valor_total, forma_pagamento, created_at, desconto, valor_liquido, parcelas, nome_cliente, crediario_frequencia) FROM stdin;
50780636-1df1-4faa-aa12-0592fc1d85f7	14	800.00	credito	2026-01-28 08:50:53.677587+00	0.00	800.00	6	\N	\N
8e8930cf-5748-4db9-841d-f21d3e34bf90	16	560.88	credito	2026-01-29 21:12:17.182092+00	0.00	560.88	3	\N	\N
70b3de88-4be4-4917-9b7f-329d4b43795b	17	1475.95	credito	2026-01-29 21:33:42.439459+00	0.00	1475.95	6	\N	\N
e95183be-3c02-4a88-a1a6-7449f2175023	18	310.11	pix	2026-01-29 22:53:52.90083+00	0.11	310.00	1	\N	\N
18cd6848-d998-4fae-9a23-6b0bcb951fd7	19	160.00	pix	2026-01-30 00:17:35.941534+00	0.00	160.00	1	\N	\N
9bc77b51-8fa3-4403-95be-a2021c885604	20	369.90	pix	2026-02-04 15:58:30.693628+00	0.00	369.90	1	\N	\N
e30df005-79ed-4d50-adbd-6b075a3a858c	21	719.60	credito	2026-02-04 18:57:53.896729+00	0.00	719.60	6	\N	\N
178b9d11-6d16-4c8d-a4e4-ca2bef8c4c3a	22	1235.36	credito	2026-02-04 19:55:50.553776+00	0.00	1235.36	6	\N	\N
3a385a02-2b2d-4546-bdbf-4d8b98e5d53f	23	539.70	credito	2026-02-07 13:44:39.358152+00	0.00	539.70	6	\N	\N
1fe9b44b-e800-42c2-8860-751501baf75c	24	277.97	credito	2026-02-08 17:18:57.014812+00	0.00	277.97	1	\N	\N
22ed3572-8295-462e-8ff2-abf353e5a1ff	25	618.00	credito	2026-02-09 14:12:45.230731+00	0.00	618.00	1	\N	\N
c93e7bf8-0fe3-4069-8ba6-fa0bff528634	26	499.80	credito	2026-02-10 15:31:36.254482+00	0.00	499.80	2	\N	\N
bdd3797f-f159-4360-ba05-59b95ee6da3e	27	353.55	pix	2026-02-14 10:39:46.35188+00	29.55	324.00	1	\N	\N
136bae77-5194-4318-9fe2-0d9cbef9a9b4	28	415.00	credito	2026-02-17 16:10:34.329741+00	0.00	415.00	3	\N	\N
a545d132-497c-41d0-9052-7b96bb3f9a84	30	339.80	credito	2026-02-19 17:11:54.606343+00	0.00	339.80	3	\N	\N
d5f32451-caad-4a78-80db-2f6f370284cd	32	728.70	pix	2026-02-20 17:25:19.980754+00	72.87	655.83	1	\N	\N
657db4fa-adf1-4e2d-9a28-98a0041311b9	34	488.80	credito	2026-02-24 17:36:30.548342+00	0.00	488.80	3	\N	\N
271f0269-611b-47ca-924f-53fb4f9e4a82	35	525.00	credito	2026-02-26 13:45:21.922107+00	0.00	525.00	4	\N	\N
898c5028-dbbb-4708-8a72-ff154f72c37c	37	369.90	credito	2026-03-02 19:07:39.799933+00	0.00	369.90	1	\N	\N
79ca1441-55e3-47b3-a1fa-90a4fc49d27d	38	640.14	pix	2026-03-02 23:52:50.836482+00	0.00	640.14	1	\N	\N
fa8f9f11-b36c-4d86-9a49-a86dce8433f7	40	1025.60	credito	2026-03-03 21:54:38.951608+00	0.00	1025.60	6	\N	\N
9e0a854e-eccf-43ae-87d3-18a676af89a2	41	462.27	pix	2026-03-05 13:45:55.140433+00	0.00	462.27	1	\N	\N
8f7f1d2e-d845-4d95-a2d2-857cf11e5358	42	399.80	pix	2026-03-06 01:06:58.787407+00	39.98	359.82	1	\N	\N
07406a7e-bbf2-4886-a4ce-b3e7952a2fb4	43	699.80	credito	2026-03-06 10:09:02.332897+00	0.00	699.80	1	\N	\N
21d0a14e-fe32-4cce-a53f-dd04256d1836	44	579.80	credito	2026-03-06 14:53:50.796078+00	0.00	579.80	1	\N	\N
c2ddf683-8768-4178-b1fa-6bef806ad340	45	344.90	pix	2026-03-07 13:28:00.714803+00	170.00	174.90	1	\N	\N
12d68805-4d98-41ff-be17-c5dc737b75fd	46	509.80	credito	2026-03-07 17:26:04.230685+00	0.00	509.80	4	\N	\N
7911cbbf-3d9e-4304-9b98-271b0ed3a4d5	47	2439.20	credito	2026-03-09 14:34:49.392884+00	0.00	2439.20	6	\N	\N
14feb63e-54b5-41ef-9274-0908b7eb4cab	49	296.33	credito	2026-03-10 17:48:58.722517+00	0.00	296.33	1	\N	\N
a1f31cad-6062-4ebc-8598-16ae90f366d3	50	339.80	pix	2026-03-12 11:44:44.378132+00	16.99	322.81	1	\N	\N
15f3a142-3361-4841-8ed5-9f51f2323815	51	160.00	credito	2026-03-13 15:42:58.240639+00	0.00	160.00	1	\N	\N
6d07bd7d-573b-443f-8edc-5972e052b948	52	759.60	credito	2026-03-13 20:02:47.909076+00	0.00	759.60	4	\N	\N
78887ce5-2c9b-4ee5-8945-39805bfa5206	53	899.70	pix	2026-03-14 13:09:06.990802+00	435.00	464.70	1	\N	\N
46bb9fa7-449f-408b-9ea1-d9ba76fd045b	54	159.90	pix	2026-03-14 13:12:09.098835+00	82.00	77.90	1	\N	\N
e0461218-e0fc-420d-96c4-3ba16e63add3	55	439.90	credito	2026-03-14 15:49:58.506691+00	0.00	439.90	1	\N	\N
15614157-7336-4210-99f9-9cbf371e4a11	56	249.90	pix	2026-03-16 18:29:25.665866+00	0.00	249.90	1	\N	\N
94e02f85-247a-4dde-8fe5-4e3380b3a1f4	57	799.90	credito	2026-03-20 20:02:34.290655+00	499.90	300.00	1	\N	\N
aac20eed-6110-46b6-9a1e-fe4a81cbef07	58	1053.90	credito	2026-03-20 20:17:08.071094+00	662.18	391.72	2	\N	\N
4cb77150-9c30-42bf-962b-657dafcd0c15	59	289.90	pix	2026-03-23 19:19:09.030151+00	114.90	175.00	1	\N	\N
a0d80b27-f650-4618-84d9-b06369488431	60	380.00	dinheiro	2026-03-26 14:49:31.599711+00	0.00	380.00	1	\N	\N
8534b434-f91e-4942-90c9-30909f036ed3	61	289.80	credito	2026-03-26 14:54:54.99162+00	0.00	289.80	3	\N	\N
f1a029fc-60c5-4f80-868c-bc17a62963ba	62	249.90	credito	2026-04-01 19:31:29.898892+00	0.00	249.90	1	\N	\N
c6db1718-62cf-48ef-a9a5-f5870431d1ee	63	507.80	credito	2026-04-02 14:43:23.776951+00	0.00	507.80	2	\N	\N
45f0a747-a320-4429-b960-709b4666e22c	64	558.32	credito	2026-04-02 14:48:20.230468+00	20.00	538.32	1	\N	\N
6c1b5939-0e32-4737-89af-6344c1f9b24f	66	379.80	pix	2026-04-03 16:47:33.773719+00	0.00	379.80	1	\N	\N
41ee7f32-7015-4352-bcb1-a869faf314fd	67	399.80	pix	2026-04-04 13:17:00.186843+00	39.98	359.82	1	\N	\N
bf87a8b8-08fc-4399-9c10-93390b92977b	68	279.80	credito	2026-04-04 13:25:28.417668+00	0.00	279.80	1	\N	\N
fa318a38-f899-4179-9f8e-672fddac185d	69	578.57	credito	2026-04-06 19:30:33.42611+00	0.00	578.57	1	\N	\N
ac6246c5-9ab3-4e5b-a2c8-1df457a148ed	70	539.70	dinheiro	2026-04-08 15:14:15.094686+00	0.00	539.70	1	\N	\N
b53f59e6-8f32-4554-80db-5b2e7ff60841	71	209.00	pix	2026-04-08 16:36:38.535109+00	105.00	104.00	1	\N	\N
08cff621-3183-45f3-876c-d3e7f04fff90	72	199.90	pix	2026-04-09 12:21:14.804825+00	0.00	199.90	1	\N	\N
313756d4-156d-447e-be65-23f74b6034e5	73	209.00	pix	2026-04-09 19:39:08.088668+00	11.00	198.00	1	\N	\N
7ce6ce23-ca2e-4bc2-9569-6256979be0cb	74	209.00	pix	2026-04-09 20:42:21.502533+00	11.00	198.00	1	\N	\N
99252fc8-5b21-4d74-8d42-8ae7ed615c5b	75	199.90	credito	2026-04-14 12:26:44.642523+00	0.00	199.90	1	\N	\N
bd43127b-736e-4833-808d-fd71ce103c1d	76	519.80	pix	2026-04-15 13:23:20.693504+00	0.00	519.80	1	\N	\N
19b419d7-f1f7-4764-b375-b2cbda99704e	77	679.70	credito	2026-04-15 17:14:44.053532+00	0.00	679.70	1	\N	\N
06188a9f-9ffd-4ed9-9c51-35ca0dd88212	79	1122.80	credito	2026-04-16 15:38:12.282751+00	5.00	1117.80	6	\N	\N
ef139de1-d72f-4316-967d-bf1517e4a06f	80	418.00	credito	2026-04-20 18:59:17.593541+00	0.00	418.00	1	\N	\N
023b9f31-a3c3-404f-938e-58215f18b3a4	81	941.11	credito	2026-04-21 00:22:24.625841+00	0.00	941.11	1	\N	\N
09069f38-1e9a-4440-adf7-516ce9758547	83	782.24	credito	2026-04-21 21:33:09.713823+00	0.00	782.24	1	\N	\N
ed7eeb3c-f871-4c6e-aa43-488a64d93e1a	84	199.90	credito	2026-04-22 12:52:32.475054+00	0.00	199.90	1	\N	\N
390b45e6-b74a-48c2-811c-d582b1907a1c	85	896.90	pix	2026-04-22 19:12:40.047682+00	436.00	460.90	1	\N	\N
83b28183-0eed-4fa9-a132-e5102c239527	86	129.90	pix	2026-04-22 19:18:36.363258+00	68.00	61.90	1	\N	\N
b5890cc9-86c0-40e9-9d56-fc079223159b	87	379.80	pix	2026-04-25 15:25:42.032047+00	170.00	209.80	1	\N	\N
7db0f9fb-0959-4ba8-bbc8-ce7210a83fb0	89	1559.40	pix	2026-04-26 00:11:17.647437+00	59.00	1500.40	1	\N	\N
3f29919a-5012-4fd9-80f9-89521f5d041d	90	379.80	pix	2026-04-26 19:21:58.194969+00	160.00	219.80	1	\N	\N
3b91814b-8a9b-413a-a8ee-66a712f6613d	91	479.80	credito	2026-04-28 19:38:34.658538+00	0.00	479.80	1	\N	\N
b2db3b18-16a8-4696-863b-0c870c31b040	92	129.90	pix	2026-04-29 10:19:18.824788+00	0.00	129.90	1	\N	\N
5aebee91-b1f7-4309-92fe-111743a716c8	93	320.00	pix	2026-04-29 15:47:21.753192+00	136.00	184.00	1	\N	\N
719e410d-7728-48d8-a3f9-f7473ad72efd	94	240.00	credito	2026-04-30 01:57:36.376687+00	0.00	240.00	1	\N	\N
3310eb3d-0a5c-4516-a8da-ddb1122c7567	95	898.80	credito	2026-04-30 15:41:13.656667+00	0.00	898.80	1	\N	\N
7676aaca-25c7-4e74-9051-45e42fedc114	96	499.80	credito	2026-05-03 13:19:38.616079+00	24.99	474.81	1	\N	\N
1970c736-adbe-45a5-82f9-f744633a36ee	98	567.15	credito	2026-05-04 18:35:02.89857+00	85.07	482.08	1	\N	\N
fda15600-10c7-45bc-b08a-df44caab1a97	99	479.80	pix	2026-05-06 14:20:53.07651+00	23.99	455.81	1	\N	\N
228867b0-244e-44d9-a65f-9c0af5bdc2f4	100	659.80	credito	2026-05-06 20:41:03.438232+00	32.99	626.81	1	\N	\N
c3878d85-0946-43fc-ac2b-b4e596d5b2a6	101	289.90	pix	2026-05-07 19:12:38.574171+00	0.00	289.90	1	\N	\N
1882538b-8b9b-424e-a1f7-ecb2c099209c	102	538.90	pix	2026-05-08 12:51:32.847609+00	269.00	269.90	1	\N	\N
2e744f06-0c9d-452d-8c90-8806905bd4e0	103	3326.40	pix	2026-05-11 02:26:34.404736+00	332.64	2993.76	1	\N	\N
28cc2232-8cfd-42d1-b38e-4a5668fdad11	104	759.70	credito	2026-05-11 02:43:09.961969+00	412.00	347.70	1	\N	\N
5d1f3636-8fef-46ca-9cd8-f60b1ecb28ab	105	289.90	pix	2026-05-12 19:17:56.607721+00	14.50	275.41	1	\N	\N
58049dd1-19ca-4b89-82cb-1e693c542e4c	106	259.57	pix	2026-05-13 14:15:44.818264+00	0.00	259.57	1	\N	\N
1f0641b3-2c24-4162-85c8-701513526fb7	107	418.00	credito	2026-05-13 19:52:54.713731+00	0.00	418.00	2	\N	\N
8d1fbc53-56a0-43b3-b898-491312a47646	108	627.00	pix	2026-05-13 20:03:17.410898+00	297.00	330.00	1	\N	\N
0455e7f3-b7d4-4fb0-9a70-552f05285c1c	109	209.00	credito	2026-05-13 20:15:17.171555+00	0.00	209.00	1	\N	\N
10fd7815-9ba0-4c7f-a124-04e275ae2d91	115	239.90	credito	2026-05-21 17:57:18.000819+00	0.00	239.90	1	\N	\N
9358736e-dc18-45f7-8ef5-75bfd27924a4	111	209.00	credito	2026-05-14 02:14:44.113916+00	0.00	209.00	1	\N	\N
d7b0855c-a27c-45f1-bed3-90c1deaddcea	110	209.00	credito	2026-05-13 22:54:06.757951+00	0.00	209.00	1	\N	\N
0f101e5a-c55c-4747-8ccf-e5ee06fb4cf2	114	129.90	pix	2026-05-15 01:24:51.50143+00	0.00	129.90	1	\N	\N
8828bc22-2eb9-4f73-99c8-c86fb41d4fb4	112	199.90	credito	2026-05-14 18:36:42.647863+00	0.00	199.90	1	\N	\N
995e79b0-dfcb-48a7-9cd9-bf89cafe8f33	117	129.90	pix	2026-05-22 12:31:13.183726+00	67.00	62.90	1	Nenizia	\N
58468760-bada-4195-b6f5-4dfa8bda8313	116	510.90	pix	2026-05-22 12:29:20.679654+00	355.00	155.90	1	Naiara	\N
cf7d6e22-eb97-4eaa-9396-ede63576eb4d	119	379.80	credito	2026-05-22 13:37:39.186154+00	0.00	379.80	1	Joria Maia	\N
1b0dc0b3-cad0-4bb3-8c98-ebb66aae4ddc	120	209.00	pix	2026-05-22 19:51:01.095182+00	100.00	109.00	1	\N	\N
9a8b5fc0-6438-4c46-95d4-cf6e4048c49d	121	640.00	dinheiro	2026-05-22 23:28:15.798456+00	20.00	620.00	1	Nivia	\N
cd0d20ac-699b-4d5b-afcc-ae6260cd5bff	122	1115.25	credito	2026-05-27 00:22:45.166862+00	0.00	1115.25	1	Patricia	\N
f9e83c9e-f4c5-4590-93c9-82e21d71a414	123	755.70	credito	2026-05-28 18:32:32.489709+00	0.00	755.70	1	Nelma Sampaio	\N
416d0374-84c4-44e5-bf85-8f1bdd3ec3e5	124	1819.64	credito	2026-05-29 03:35:51.471492+00	450.00	1369.64	1	Anderleia Oliveira	\N
30309d16-15c5-4f4b-866a-e959451719a4	126	279.90	pix	2026-06-01 19:57:26.807294+00	140.00	139.90	1	Nenizia Praxedes	\N
05e78f2f-b675-4088-9972-ce575938e01c	127	134.29	pix	2026-06-02 18:29:45.275414+00	0.00	134.29	1	Nivia	\N
2193d452-0c1e-4500-a3ff-d95f44e2e811	129	779.70	pix	2026-06-05 20:21:09.52115+00	450.00	329.70	1	Naiara	\N
968f323b-e225-4869-984d-bdf058330c8c	130	448.90	credito	2026-06-06 15:32:14.475137+00	0.00	448.90	1	\N	\N
b24f4633-230e-471f-ba24-21c5bebd1113	131	460.00	credito	2026-06-07 14:05:52.633627+00	0.00	460.00	1	\N	\N
6813c9ec-1007-4a41-bb18-a9956f13db8f	132	499.90	credito	2026-06-09 19:55:14.242003+00	0.00	499.90	1	\N	\N
9431a927-7040-4ed8-98d5-4630dac31865	133	499.90	credito	2026-06-11 23:59:38.179872+00	0.00	499.90	6	\N	\N
73fac3fc-117b-4739-9e41-0994acab437d	136	509.80	pix	2026-06-12 20:33:41.211734+00	269.00	240.80	1	\N	\N
783960f7-8b70-498d-bf46-31f40ca6b2eb	159	229.90	pix	2026-07-27 18:10:21.529626+00	29.00	200.90	1	\N	\N
e1cb8ba5-583d-4552-ba38-d59bf16a8dbb	128	179.90	crediario	2026-06-05 13:20:18.172301+00	0.00	179.90	1	Ana Luiza	quinzenal
3a18bedc-cd9a-463f-b00f-1ccc82206bfa	154	599.80	crediario	2026-07-11 03:36:02.353817+00	0.00	599.80	4	Vanessa	quinzenal
1871e295-fb6f-4022-8cb2-5ce142c003e5	160	239.80	crediario	2026-07-27 22:00:29.672289+00	110.00	129.80	1	Nenizia	mensal
8289852a-5b57-43f4-ab76-6a856d472dae	179	119.90	crediario	2026-08-18 16:33:11.649169+00	0.00	119.90	1	Ana Luiza	mensal
40757cf5-57b0-47c1-9b20-84af21d31c08	163	619.80	pix	2026-08-01 15:44:12.238536+00	352.00	267.80	1	Naiara	\N
6cc62712-62ab-432d-863c-d12a13122ac4	137	129.90	pix	2026-06-16 23:52:41.763072+00	62.00	67.90	1	\N	\N
fa9b359c-6a5f-4edc-800e-1e07336ced79	138	129.90	pix	2026-06-19 18:08:45.211772+00	0.00	129.90	1	\N	\N
a70452b0-1880-47cd-908e-154924638f34	139	2928.20	credito	2026-06-21 00:46:02.082996+00	0.00	2928.20	1	\N	\N
a771d56c-f3a0-4bb4-b8da-d09dacfbc874	140	1809.30	credito	2026-06-26 15:55:01.696179+00	0.00	1809.30	1	Daniele Cavalcanti	\N
c38b79a8-9005-4b52-b009-cb24693fa29f	141	358.32	credito	2026-06-26 18:11:49.710846+00	0.00	358.32	1	Nathalia	\N
25773b86-715a-4f92-8433-20fb7fabf595	161	479.80	crediario	2026-08-01 08:24:28.01768+00	260.00	219.80	2	Nenizia Praxedes	mensal
44ce3879-2819-478a-9084-f15785c0e5fe	164	434.00	credito	2026-08-06 20:10:49.878036+00	0.00	434.00	2	Adriana Brito	\N
615d7e05-5fc0-48cf-b653-ee6c11d0567a	142	629.80	pix	2026-06-30 21:15:56.368355+00	360.00	269.80	1	Narjara	\N
3d728f6c-e38d-4137-b099-545946a2e3cc	145	769.70	credito	2026-07-01 17:12:22.38039+00	0.00	769.70	1	Suze Terra	\N
0a3b2e63-431d-46e9-a313-6a8f945dec90	165	1053.90	pix	2026-08-08 14:30:24.823079+00	100.00	953.90	1	Odalea	\N
bd33264b-59b5-418c-8869-68201818c57a	144	199.90	crediario	2026-07-01 13:56:57.957035+00	0.00	199.90	1	Ana Luiza	quinzenal
319e1273-25d3-4963-b3ee-414be1bfd801	146	464.90	credito	2026-07-02 12:56:00.315348+00	0.00	464.90	1	\N	\N
b6d7ce40-b699-4914-9ee1-b3f4b127b285	147	199.90	pix	2026-07-02 18:15:04.082323+00	110.00	89.90	1	Narjara	\N
b4f7d41c-6d78-4a29-a39f-77b81f1b0434	150	459.80	pix	2026-07-04 15:34:01.902668+00	263.00	196.80	1	\N	\N
7caedb35-8690-4a93-b3b0-ad139b8e2550	153	569.80	pix	2026-07-06 19:47:45.800539+00	69.00	500.80	1	Renato	\N
bee19e29-193f-45d2-819d-9760948fd45d	148	499.80	crediario	2026-07-03 18:44:11.817392+00	0.00	499.80	2	Nivia Farias	mensal
fb3d69f8-e303-43f2-a588-2c63f56d9dd9	155	369.80	pix	2026-07-16 20:54:03.034708+00	18.49	351.31	1	Laiara	\N
716d1344-1503-41fc-8eb4-8a7547bde1bd	156	119.90	credito	2026-07-22 13:14:11.045707+00	0.00	119.90	1	\N	\N
d44fb59b-3ae9-4c1b-8848-2e89db5c3ec7	125	3375.33	crediario	2026-06-01 01:12:54.424878+00	0.00	3375.33	7	Vanessa Barros	quinzenal
d2ac5fb3-efaa-4864-9f12-edddd4118831	157	368.90	pix	2026-07-23 19:18:37.650956+00	36.89	332.01	1	\N	\N
ad3c7cc7-2684-49af-afc5-88c0bd35469a	168	1769.30	credito	2026-08-12 01:03:56.65875+00	176.93	1592.37	6	\N	\N
249b3b88-6270-4615-8765-b1ebcaded45e	169	988.00	credito	2026-08-12 21:51:23.014341+00	0.00	988.00	6	Andrea Conde	\N
c69c1fdb-e741-4513-aa4a-ba83b4c699b3	171	1932.80	credito	2026-08-13 00:15:26.008893+00	162.00	1770.80	1	Midian	\N
ed0cd0e6-33ed-4b1b-b6f0-162555cf53cb	174	1146.90	credito	2026-08-14 12:04:23.377605+00	0.00	1146.90	4	Andrezza Costa	\N
c6c01c35-8188-4f75-af63-3eec540c1526	173	829.50	credito	2026-08-14 00:01:24.577883+00	0.00	829.50	4	Nivia Farias	\N
addc5e67-13d8-4857-940f-6e558a2b229b	172	484.00	crediario	2026-08-13 19:18:21.988169+00	0.00	484.00	2	Fernanda Karolina	mensal
7878276d-05fa-402d-89a7-5b736e94df21	175	588.80	credito	2026-08-16 00:44:11.901989+00	58.88	529.92	1	\N	\N
067ac8b8-86a5-4710-9142-2277faccc67f	193	119.90	crediario	2026-09-02 01:41:24.131945+00	0.00	119.90	1	Ana Luiza	mensal
af0ccc75-7300-4f7d-a066-f56be7d19fb5	190	594.00	crediario	2026-08-31 23:34:28.23389+00	303.00	291.00	2	Narjara	mensal
49415213-6157-4937-ac75-7f612ded322b	181	554.00	crediario	2026-08-22 00:27:20.830205+00	294.00	260.00	2	Dorinha	semanal
7f7f4cdb-8718-4d55-8dfb-84d032f82b13	188	395.00	crediario	2026-08-27 21:29:49.203418+00	175.00	220.00	1	Presente da Dorinha	mensal
661a2cdf-aaad-4d4e-acdf-986f971d731e	182	554.00	credito	2026-08-22 13:23:48.894235+00	0.00	554.00	3	Cris	\N
0f63c759-5880-43f2-98f1-2932e52be8be	183	869.60	pix	2026-08-22 18:40:34.275228+00	86.96	782.64	1	Rayane Gonçalves	\N
5fb759a0-739a-4fd1-a207-1712f5952fd7	185	4507.40	credito	2026-08-22 19:34:23.103363+00	0.00	4507.40	8	Rayane Gonçalves	\N
47652497-0be9-468b-975b-ade0ca3410df	187	329.90	credito	2026-08-26 19:39:50.369537+00	0.00	329.90	3	Ana Carolina Magalhães	\N
0b156dab-8965-4358-a6da-7e598e3ce2d9	189	3282.09	credito	2026-08-29 14:16:05.766992+00	0.00	3282.09	6	Sinthia Azevedo	\N
69d88638-e460-442b-9ae8-7fafd2ac5d1b	201	1907.80	crediario	2026-09-09 18:10:25.294671+00	872.00	1035.80	4	Dorinha	mensal
f3d70443-3269-4cbb-bad9-0b67e6a68a5e	192	1534.90	crediario	2026-08-31 23:41:34.612344+00	812.00	722.90	6	Nenizia Praxedes	mensal
be56aead-81ef-4271-be5b-76124e0d348e	197	297.00	crediario	2026-09-03 15:45:40.349678+00	0.00	297.00	1	Joyce Matos	quinzenal
aa0a4526-e1b1-4a62-bfc4-d1e091e95891	198	249.90	pix	2026-09-04 00:45:04.572656+00	0.00	249.90	1	Rakel	\N
9b9885a5-a11b-4ee2-a68e-252311e8d49f	194	534.00	pix	2026-09-02 15:07:43.762552+00	0.00	534.00	1	Daniele Cavalcanti	\N
5fc1f5a7-fcd5-4438-a41e-5c028432a5a9	162	1169.60	crediario	2026-08-01 08:36:20.763766+00	603.00	566.60	4	Narjara	quinzenal
cd0b0dcc-5ca3-48f7-90f5-a8590cc26251	199	409.80	credito	2026-09-04 17:11:31.035432+00	44.00	365.80	3	Dani	\N
9765680c-d76a-4c5d-9b4c-2e186f210b43	202	297.00	credito	2026-09-11 14:59:09.426873+00	0.00	297.00	2	Eluana	\N
c7eba4ad-e71f-4afd-afa5-1a6daeb35fd5	158	5977.90	crediario	2026-07-23 23:23:56.742045+00	0.00	5977.90	6	Vanessa Barros	quinzenal
30274953-5922-4d2b-9972-e1db42931650	203	279.90	crediario	2026-09-14 13:54:35.458312+00	0.00	279.90	2	Lorena	mensal
0b39c086-50d5-4d9b-9f55-b219e6318742	204	259.90	pix	2026-09-14 17:23:19.083+00	0.00	259.90	1	Juliana	\N
0d5a22ef-78a9-4139-b8c2-c99e6a3fcde6	205	297.00	credito	2026-09-15 19:20:40.35254+00	0.00	297.00	2	Vina	\N
8f3ca01d-45eb-4b14-ac61-4466e1cd4c19	200	6459.50	crediario	2026-09-04 17:25:35.847851+00	0.00	6459.50	10	Vanessa Barros	quinzenal
de8a6583-05af-4f2e-8cd9-ac2c4610d275	206	559.80	credito	2026-09-22 15:12:51.35247+00	0.00	559.80	3	Renata	\N
fc41bd5c-40f3-415b-9ec5-24cd78e8a5d4	207	396.90	credito	2026-09-22 15:46:19.098442+00	18.00	378.90	3	Nivia Souza	\N
22907bde-880d-4f8e-9584-4367d1582d0b	208	369.90	credito	2026-09-22 18:58:06.483052+00	0.00	369.90	3	Rosa	\N
46f01bfe-85a9-415a-b704-44ecf0c33c0e	209	129.90	credito	2026-09-22 19:57:33.913195+00	0.00	129.90	6	Rosa	\N
6311f079-8c03-46c5-81a1-e1ebc45c06b7	210	229.90	crediario	2026-09-23 13:14:37.176689+00	0.00	229.90	2	Ana Luiza	mensal
bfbe41ce-d230-45fa-81e2-1c999afed65d	211	329.90	credito	2026-09-24 14:57:09.583086+00	0.00	329.90	3	Samila	\N
0a67c5d3-e8cb-47c0-ad6c-3003a4b41eb7	213	865.00	credito	2026-09-25 00:20:13.857142+00	0.00	865.00	6	Adriana Barbosa	\N
\.


--
-- Name: vendas_codigo_venda_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.vendas_codigo_venda_seq', 213, true);


--
-- Name: app_users app_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_pkey PRIMARY KEY (user_id);


--
-- Name: catalogo_carrinho_itens catalogo_carrinho_itens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinho_itens
    ADD CONSTRAINT catalogo_carrinho_itens_pkey PRIMARY KEY (id);


--
-- Name: catalogo_carrinhos catalogo_carrinhos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinhos
    ADD CONSTRAINT catalogo_carrinhos_pkey PRIMARY KEY (id);


--
-- Name: catalogo_carrinhos catalogo_carrinhos_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinhos
    ADD CONSTRAINT catalogo_carrinhos_token_key UNIQUE (token);


--
-- Name: crediario_parcelas crediario_parcelas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crediario_parcelas
    ADD CONSTRAINT crediario_parcelas_pkey PRIMARY KEY (id);


--
-- Name: crediario_parcelas crediario_parcelas_venda_id_numero_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crediario_parcelas
    ADD CONSTRAINT crediario_parcelas_venda_id_numero_key UNIQUE (venda_id, numero);


--
-- Name: estoque estoque_codigo_barras_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.estoque
    ADD CONSTRAINT estoque_codigo_barras_key UNIQUE (codigo_barras);


--
-- Name: estoque estoque_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.estoque
    ADD CONSTRAINT estoque_pkey PRIMARY KEY (id);


--
-- Name: itens_venda itens_venda_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.itens_venda
    ADD CONSTRAINT itens_venda_pkey PRIMARY KEY (id);


--
-- Name: produtos produtos_codigo_peca_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.produtos
    ADD CONSTRAINT produtos_codigo_peca_key UNIQUE (codigo_peca);


--
-- Name: produtos produtos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.produtos
    ADD CONSTRAINT produtos_pkey PRIMARY KEY (id);


--
-- Name: tamanhos tamanhos_nome_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tamanhos
    ADD CONSTRAINT tamanhos_nome_key UNIQUE (nome);


--
-- Name: tamanhos tamanhos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tamanhos
    ADD CONSTRAINT tamanhos_pkey PRIMARY KEY (id);


--
-- Name: venda_draft_itens venda_draft_itens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_draft_itens
    ADD CONSTRAINT venda_draft_itens_pkey PRIMARY KEY (id);


--
-- Name: venda_drafts venda_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_drafts
    ADD CONSTRAINT venda_drafts_pkey PRIMARY KEY (id);


--
-- Name: venda_pagamentos venda_pagamentos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_pagamentos
    ADD CONSTRAINT venda_pagamentos_pkey PRIMARY KEY (id);


--
-- Name: vendas vendas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendas
    ADD CONSTRAINT vendas_pkey PRIMARY KEY (id);


--
-- Name: catalogo_carrinho_itens_carrinho_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX catalogo_carrinho_itens_carrinho_id_idx ON public.catalogo_carrinho_itens USING btree (carrinho_id);


--
-- Name: catalogo_carrinhos_token_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX catalogo_carrinhos_token_idx ON public.catalogo_carrinhos USING btree (token);


--
-- Name: idx_crediario_parcelas_pagamento_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_crediario_parcelas_pagamento_id ON public.crediario_parcelas USING btree (pagamento_id);


--
-- Name: idx_crediario_parcelas_pendentes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_crediario_parcelas_pendentes ON public.crediario_parcelas USING btree (pago, data_vencimento);


--
-- Name: idx_crediario_parcelas_venda; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_crediario_parcelas_venda ON public.crediario_parcelas USING btree (venda_id);


--
-- Name: idx_venda_draft_itens_draft_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venda_draft_itens_draft_id ON public.venda_draft_itens USING btree (draft_id);


--
-- Name: idx_venda_drafts_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venda_drafts_updated_at ON public.venda_drafts USING btree (updated_at DESC);


--
-- Name: idx_venda_pagamentos_forma; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venda_pagamentos_forma ON public.venda_pagamentos USING btree (forma);


--
-- Name: idx_venda_pagamentos_venda_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venda_pagamentos_venda_id ON public.venda_pagamentos USING btree (venda_id);


--
-- Name: venda_drafts trg_set_user_id_on_insert_venda_drafts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_user_id_on_insert_venda_drafts BEFORE INSERT ON public.venda_drafts FOR EACH ROW EXECUTE FUNCTION public.set_user_id_on_insert();


--
-- Name: venda_drafts trg_touch_venda_drafts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_touch_venda_drafts BEFORE UPDATE ON public.venda_drafts FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: app_users app_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: catalogo_carrinho_itens catalogo_carrinho_itens_carrinho_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinho_itens
    ADD CONSTRAINT catalogo_carrinho_itens_carrinho_id_fkey FOREIGN KEY (carrinho_id) REFERENCES public.catalogo_carrinhos(id) ON DELETE CASCADE;


--
-- Name: catalogo_carrinho_itens catalogo_carrinho_itens_produto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinho_itens
    ADD CONSTRAINT catalogo_carrinho_itens_produto_id_fkey FOREIGN KEY (produto_id) REFERENCES public.produtos(id);


--
-- Name: catalogo_carrinhos catalogo_carrinhos_importado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalogo_carrinhos
    ADD CONSTRAINT catalogo_carrinhos_importado_por_fkey FOREIGN KEY (importado_por) REFERENCES auth.users(id);


--
-- Name: crediario_parcelas crediario_parcelas_pagamento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crediario_parcelas
    ADD CONSTRAINT crediario_parcelas_pagamento_id_fkey FOREIGN KEY (pagamento_id) REFERENCES public.venda_pagamentos(id) ON DELETE CASCADE;


--
-- Name: crediario_parcelas crediario_parcelas_venda_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crediario_parcelas
    ADD CONSTRAINT crediario_parcelas_venda_id_fkey FOREIGN KEY (venda_id) REFERENCES public.vendas(id) ON DELETE CASCADE;


--
-- Name: estoque estoque_produto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.estoque
    ADD CONSTRAINT estoque_produto_id_fkey FOREIGN KEY (produto_id) REFERENCES public.produtos(id);


--
-- Name: estoque estoque_tamanho_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.estoque
    ADD CONSTRAINT estoque_tamanho_id_fkey FOREIGN KEY (tamanho_id) REFERENCES public.tamanhos(id) ON DELETE RESTRICT;


--
-- Name: itens_venda itens_venda_estoque_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.itens_venda
    ADD CONSTRAINT itens_venda_estoque_id_fkey FOREIGN KEY (estoque_id) REFERENCES public.estoque(id);


--
-- Name: itens_venda itens_venda_produto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.itens_venda
    ADD CONSTRAINT itens_venda_produto_id_fkey FOREIGN KEY (produto_id) REFERENCES public.produtos(id);


--
-- Name: itens_venda itens_venda_venda_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.itens_venda
    ADD CONSTRAINT itens_venda_venda_id_fkey FOREIGN KEY (venda_id) REFERENCES public.vendas(id) ON DELETE CASCADE;


--
-- Name: venda_draft_itens venda_draft_itens_draft_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_draft_itens
    ADD CONSTRAINT venda_draft_itens_draft_id_fkey FOREIGN KEY (draft_id) REFERENCES public.venda_drafts(id) ON DELETE CASCADE;


--
-- Name: venda_draft_itens venda_draft_itens_estoque_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_draft_itens
    ADD CONSTRAINT venda_draft_itens_estoque_id_fkey FOREIGN KEY (estoque_id) REFERENCES public.estoque(id);


--
-- Name: venda_draft_itens venda_draft_itens_produto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_draft_itens
    ADD CONSTRAINT venda_draft_itens_produto_id_fkey FOREIGN KEY (produto_id) REFERENCES public.produtos(id);


--
-- Name: venda_pagamentos venda_pagamentos_venda_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venda_pagamentos
    ADD CONSTRAINT venda_pagamentos_venda_id_fkey FOREIGN KEY (venda_id) REFERENCES public.vendas(id) ON DELETE CASCADE;


--
-- Name: produtos admin delete produtos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin delete produtos" ON public.produtos FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: produtos admin insert produtos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin insert produtos" ON public.produtos FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: estoque admin manage estoque; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage estoque" ON public.estoque TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: produtos admin read produtos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin read produtos" ON public.produtos FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: tamanhos admin read tamanhos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin read tamanhos" ON public.tamanhos FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: produtos admin update produtos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin update produtos" ON public.produtos FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: app_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;

--
-- Name: catalogo_carrinho_itens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.catalogo_carrinho_itens ENABLE ROW LEVEL SECURITY;

--
-- Name: catalogo_carrinhos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.catalogo_carrinhos ENABLE ROW LEVEL SECURITY;

--
-- Name: crediario_parcelas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.crediario_parcelas ENABLE ROW LEVEL SECURITY;

--
-- Name: crediario_parcelas crediario_parcelas_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crediario_parcelas_delete ON public.crediario_parcelas FOR DELETE TO authenticated USING (public.is_sales());


--
-- Name: crediario_parcelas crediario_parcelas_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crediario_parcelas_insert ON public.crediario_parcelas FOR INSERT TO authenticated WITH CHECK (public.is_sales());


--
-- Name: crediario_parcelas crediario_parcelas_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crediario_parcelas_select ON public.crediario_parcelas FOR SELECT TO authenticated USING (public.is_sales());


--
-- Name: crediario_parcelas crediario_parcelas_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crediario_parcelas_update ON public.crediario_parcelas FOR UPDATE TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: estoque; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.estoque ENABLE ROW LEVEL SECURITY;

--
-- Name: itens_venda; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.itens_venda ENABLE ROW LEVEL SECURITY;

--
-- Name: produtos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.produtos ENABLE ROW LEVEL SECURITY;

--
-- Name: app_users read own app_users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read own app_users" ON public.app_users FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: venda_drafts sales delete all drafts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales delete all drafts" ON public.venda_drafts FOR DELETE TO authenticated USING (public.is_sales());


--
-- Name: venda_draft_itens sales manage all draft itens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales manage all draft itens" ON public.venda_draft_itens TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: venda_drafts sales read all drafts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales read all drafts" ON public.venda_drafts FOR SELECT TO authenticated USING (public.is_sales());


--
-- Name: catalogo_carrinho_itens sales read carrinho itens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales read carrinho itens" ON public.catalogo_carrinho_itens FOR SELECT TO authenticated USING (public.is_sales());


--
-- Name: catalogo_carrinhos sales read carrinhos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales read carrinhos" ON public.catalogo_carrinhos FOR SELECT TO authenticated USING (public.is_sales());


--
-- Name: venda_drafts sales update all drafts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales update all drafts" ON public.venda_drafts FOR UPDATE TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: catalogo_carrinhos sales update carrinhos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales update carrinhos" ON public.catalogo_carrinhos FOR UPDATE TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: venda_drafts sales/admin insert drafts; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales/admin insert drafts" ON public.venda_drafts FOR INSERT TO authenticated WITH CHECK ((public.is_sales() AND (user_id = auth.uid())));


--
-- Name: itens_venda sales/admin manage itens_venda; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales/admin manage itens_venda" ON public.itens_venda TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: venda_pagamentos sales/admin manage venda_pagamentos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales/admin manage venda_pagamentos" ON public.venda_pagamentos TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: vendas sales/admin manage vendas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "sales/admin manage vendas" ON public.vendas TO authenticated USING (public.is_sales()) WITH CHECK (public.is_sales());


--
-- Name: tamanhos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tamanhos ENABLE ROW LEVEL SECURITY;

--
-- Name: venda_draft_itens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venda_draft_itens ENABLE ROW LEVEL SECURITY;

--
-- Name: venda_drafts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venda_drafts ENABLE ROW LEVEL SECURITY;

--
-- Name: venda_pagamentos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venda_pagamentos ENABLE ROW LEVEL SECURITY;

--
-- Name: vendas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vendas ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict 8oSzjiWHr0iueflro1krWzHr6iYroqzPjujDNM5VrctnFjABXpUgXrl9V0gIoa4

