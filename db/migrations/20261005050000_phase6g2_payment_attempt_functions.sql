-- =============================================================================
-- PHASE 6G.2 - payment attempt functions. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005040000 (6G.1). One transaction.
--
-- ADDS three SECURITY DEFINER functions, callable by service_role ONLY:
--   get_order_for_payment(p_order_id)                                  -> jsonb
--   create_payment_attempt(p_order_id, p_provider, p_method, p_idempotency_key) -> jsonb
--   mark_payment_processing(p_transaction_id, p_provider_reference)    -> jsonb
-- DOES NOT: change tables, grants or RLS of 6G.1, touch orders / orders.status / orders.payment_status,
--   mark anything paid or succeeded, or add any provider (M-Pesa/card/webhook) code.
--
-- The amount is ALWAYS read from orders.total_cents / orders.currency inside the database; no function
-- takes an amount. Both writers return { changed: boolean, transaction: {...} }.
--
-- Refusals are SQLSTATE P0001 with a DETAIL code:
--   all:                       invalid_arguments
--   get_order_for_payment:     order_not_found
--   create_payment_attempt:    order_not_found, order_not_payable (order cancelled/refunded),
--                              order_already_paid (paid or partially refunded),
--                              order_amount_invalid (total <= 0), idempotency_key_conflict
--   mark_payment_processing:   transaction_not_found, invalid_reference,
--                              invalid_transition (any state but pending/processing),
--                              reference_conflict (different reference than already recorded),
--                              provider_reference_in_use
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.payment_transactions') is null
     or not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                    where n.nspname = 'public' and t.typname = 'payment_transaction_status')
     or to_regclass('public.orders') is null then
    raise exception 'Phase 6G.2 precondition failed: apply 20261005040000 (Phase 6G.1) first.';
  end if;
  if to_regprocedure('public.get_order_for_payment(uuid)') is not null
     or to_regprocedure('public.create_payment_attempt(uuid,text,public.payment_method,text)') is not null
     or to_regprocedure('public.mark_payment_processing(uuid,text)') is not null then
    raise exception 'Phase 6G.2 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. get_order_for_payment ----------------------------------------------------------------------
create function public.get_order_for_payment(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_order_id is null then
    raise exception 'An order is required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_order from public.orders o where o.id = p_order_id;
  if not found then
    raise exception 'That order could not be found.' using errcode = 'P0001', detail = 'order_not_found';
  end if;

  return jsonb_build_object(
    'id', v_order.id,
    'total_cents', v_order.total_cents,
    'currency', v_order.currency,
    'status', v_order.status,
    'payment_status', v_order.payment_status
  );
end;
$$;

-- 2. create_payment_attempt ---------------------------------------------------------------------
create function public.create_payment_attempt(
  p_order_id uuid,
  p_provider text,
  p_method public.payment_method,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider text := btrim(coalesce(p_provider, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_order public.orders%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_new public.payment_transactions%rowtype;
begin
  if p_order_id is null or p_method is null
     or char_length(v_provider) not between 1 and 40
     or char_length(v_key) not between 1 and 200 then
    raise exception 'An order, a provider (1-40 characters), a method and an idempotency key (1-200 characters) are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Replay: the same key returns the stored attempt, provided it is the same request.
  select * into v_existing from public.payment_transactions t where t.idempotency_key = v_key;
  if found then
    if v_existing.order_id <> p_order_id or v_existing.provider <> v_provider or v_existing.method <> p_method then
      raise exception 'That idempotency key was already used for a different payment request.'
        using errcode = 'P0001', detail = 'idempotency_key_conflict';
    end if;
    return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_existing));
  end if;

  -- Serialise attempts per order, then judge the order as it is now.
  select * into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'That order could not be found.' using errcode = 'P0001', detail = 'order_not_found';
  end if;

  if v_order.status in ('cancelled', 'refunded') or v_order.payment_status = 'refunded' then
    raise exception 'This order cannot be paid for.' using errcode = 'P0001', detail = 'order_not_payable';
  end if;
  if v_order.status = 'paid' or v_order.payment_status in ('paid', 'partially_refunded') then
    raise exception 'This order is already paid.' using errcode = 'P0001', detail = 'order_already_paid';
  end if;
  if v_order.total_cents is null or v_order.total_cents <= 0 then
    raise exception 'This order has no payable amount.' using errcode = 'P0001', detail = 'order_amount_invalid';
  end if;

  begin
    insert into public.payment_transactions (order_id, provider, method, amount_cents, currency, idempotency_key)
    values (v_order.id, v_provider, p_method, v_order.total_cents, v_order.currency, v_key)
    returning * into v_new;
  exception when unique_violation then
    -- A concurrent request with the same key won the race: treat as a replay.
    select * into v_existing from public.payment_transactions t where t.idempotency_key = v_key;
    if not found then
      raise;
    end if;
    if v_existing.order_id <> p_order_id or v_existing.provider <> v_provider or v_existing.method <> p_method then
      raise exception 'That idempotency key was already used for a different payment request.'
        using errcode = 'P0001', detail = 'idempotency_key_conflict';
    end if;
    return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_existing));
  end;

  return jsonb_build_object('changed', true, 'transaction', to_jsonb(v_new));
end;
$$;

-- 3. mark_payment_processing --------------------------------------------------------------------
create function public.mark_payment_processing(p_transaction_id uuid, p_provider_reference text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref text := btrim(coalesce(p_provider_reference, ''));
  v_txn public.payment_transactions%rowtype;
begin
  if p_transaction_id is null then
    raise exception 'A payment transaction is required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if char_length(v_ref) not between 1 and 200 then
    raise exception 'A provider reference of 1-200 characters is required.'
      using errcode = 'P0001', detail = 'invalid_reference';
  end if;

  select * into v_txn from public.payment_transactions t where t.id = p_transaction_id for update;
  if not found then
    raise exception 'That payment transaction could not be found.'
      using errcode = 'P0001', detail = 'transaction_not_found';
  end if;

  if v_txn.status = 'processing' then
    if v_txn.provider_reference is not distinct from v_ref then
      return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_txn));
    end if;
    raise exception 'This transaction is already processing under a different provider reference.'
      using errcode = 'P0001', detail = 'reference_conflict';
  end if;

  if v_txn.status <> 'pending' then
    raise exception 'Only a pending transaction can be marked processing.'
      using errcode = 'P0001', detail = 'invalid_transition';
  end if;

  if v_txn.provider_reference is not null and v_txn.provider_reference <> v_ref then
    raise exception 'This transaction already has a different provider reference.'
      using errcode = 'P0001', detail = 'reference_conflict';
  end if;

  begin
    update public.payment_transactions t
       set status = 'processing', provider_reference = v_ref
     where t.id = v_txn.id
    returning * into v_txn;
  exception when unique_violation then
    raise exception 'That provider reference is already used by another transaction.'
      using errcode = 'P0001', detail = 'provider_reference_in_use';
  end;

  return jsonb_build_object('changed', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- 4. Privileges: service_role only ---------------------------------------------------------------
revoke all on function public.get_order_for_payment(uuid) from public, anon, authenticated;
revoke all on function public.create_payment_attempt(uuid, text, public.payment_method, text) from public, anon, authenticated;
revoke all on function public.mark_payment_processing(uuid, text) from public, anon, authenticated;

grant execute on function public.get_order_for_payment(uuid) to service_role;
grant execute on function public.create_payment_attempt(uuid, text, public.payment_method, text) to service_role;
grant execute on function public.mark_payment_processing(uuid, text) to service_role;

-- 5. Self-check ----------------------------------------------------------------------------------
do $chk$
declare
  v_fn regprocedure;
begin
  foreach v_fn in array array[
    'public.get_order_for_payment(uuid)'::regprocedure,
    'public.create_payment_attempt(uuid,text,public.payment_method,text)'::regprocedure,
    'public.mark_payment_processing(uuid,text)'::regprocedure] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_fn and p.prosecdef
                     and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%public%pg_temp%')) then
      raise exception 'Phase 6G.2 self-check failed: % is not SECURITY DEFINER with search_path = public, pg_temp.', v_fn;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = v_fn
                 and (a.grantee = 0
                      or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated')))) then
      raise exception 'Phase 6G.2 self-check failed: % is executable by public/anon/authenticated.', v_fn;
    end if;
    if not has_function_privilege('service_role', v_fn, 'EXECUTE') then
      raise exception 'Phase 6G.2 self-check failed: service_role cannot execute %.', v_fn;
    end if;
  end loop;
end
$chk$;

commit;
