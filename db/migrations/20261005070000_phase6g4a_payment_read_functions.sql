-- =============================================================================
-- PHASE 6G.4-A - three payment READ functions. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005060000. One transaction. Read-only: no table, column, index, policy
-- or table grant is created or changed (payment_transactions privileges/policies are 6G.4-B).
--
-- ADDS (all SECURITY DEFINER, STABLE, search_path = public, pg_temp; execute for authenticated only):
--   admin_list_payment_transactions(order, status, provider, from, to, limit, offset)  - admin only
--   admin_get_payment_transaction(id)                                                  - admin only
--   get_my_order_payments(order_id)                                                    - caller's own order only
-- Gate for the admin ones: require_admin() (admin only; staff are denied), first statement.
-- List: created_at >= p_from and < p_to (either bound may be null = open). All filters optional.
--   limit < 1, offset < 0, from >= to, provider > 40 chars -> P0001 / invalid_arguments.
--   limit > 100 is capped to 100. Newest first (created_at desc, id desc).
-- Customer function exposes only: id, order_id, method, amount_cents, currency, status, created_at,
--   completed_at. Never provider, provider_reference, failure_*, idempotency_key, updated_at.
--   Another customer's order and a non-existent order both raise P0001 / order_not_found.
-- Money is integer cents. No data is written.
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.payment_transactions') is null
     or not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                    where n.nspname = 'public' and t.typname = 'payment_transaction_status')
     or to_regprocedure('public.create_payment_attempt(uuid,text,public.payment_method,text)') is null
     or to_regprocedure('public.mark_payment_processing(uuid,text)') is null
     or to_regprocedure('public.get_order_for_payment(uuid)') is null
     or to_regprocedure('public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)') is null
     or to_regprocedure('public.record_cod_payment(uuid,text)') is null
     or to_regprocedure('public.require_admin()') is null then
    raise exception 'Phase 6G.4-A precondition failed: apply migrations up to 20261005060000 (6G.1-6G.3) first.';
  end if;
  if to_regprocedure('public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)') is not null
     or to_regprocedure('public.admin_get_payment_transaction(uuid)') is not null
     or to_regprocedure('public.get_my_order_payments(uuid)') is not null then
    raise exception 'Phase 6G.4-A appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. Admin list ---------------------------------------------------------------
create function public.admin_list_payment_transactions(
  p_order_id uuid default null,
  p_status public.payment_transaction_status default null,
  p_provider text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer;
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_admin();

  if p_limit is null or p_limit < 1
     or p_offset is null or p_offset < 0
     or (p_from is not null and p_to is not null and p_from >= p_to)
     or (p_provider is not null and char_length(p_provider) > 40) then
    raise exception 'Invalid payment transaction list arguments.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_limit := least(p_limit, 100);

  select count(*) into v_total
  from public.payment_transactions t
  where (p_order_id is null or t.order_id = p_order_id)
    and (p_status is null or t.status = p_status)
    and (p_provider is null or t.provider = p_provider)
    and (p_from is null or t.created_at >= p_from)
    and (p_to is null or t.created_at < p_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'order_id', x.order_id,
           'provider', x.provider,
           'method', x.method,
           'amount_cents', x.amount_cents,
           'currency', x.currency,
           'status', x.status,
           'provider_reference', x.provider_reference,
           'failure_code', x.failure_code,
           'failure_message', x.failure_message,
           'created_at', x.created_at,
           'updated_at', x.updated_at,
           'completed_at', x.completed_at
         ) order by x.created_at desc, x.id desc), '[]'::jsonb)
  into v_rows
  from (
    select t.*
    from public.payment_transactions t
    where (p_order_id is null or t.order_id = p_order_id)
      and (p_status is null or t.status = p_status)
      and (p_provider is null or t.provider = p_provider)
      and (p_from is null or t.created_at >= p_from)
      and (p_to is null or t.created_at < p_to)
    order by t.created_at desc, t.id desc
    limit v_limit offset p_offset
  ) x;

  return jsonb_build_object('total_count', v_total, 'limit', v_limit, 'offset', p_offset, 'transactions', v_rows);
end;
$$;

comment on function public.admin_list_payment_transactions(uuid, public.payment_transaction_status, text, timestamptz, timestamptz, integer, integer) is
  'Phase 6G.4-A. Admin-only, read-only filtered/paged list of payment attempts (limit capped at 100).';

-- 2. Admin detail -------------------------------------------------------------
create function public.admin_get_payment_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_row jsonb;
begin
  perform public.require_admin();

  if p_transaction_id is null then
    raise exception 'Invalid payment transaction id.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select jsonb_build_object(
           'id', t.id,
           'order_id', t.order_id,
           'provider', t.provider,
           'method', t.method,
           'amount_cents', t.amount_cents,
           'currency', t.currency,
           'status', t.status,
           'provider_reference', t.provider_reference,
           'idempotency_key', t.idempotency_key,
           'failure_code', t.failure_code,
           'failure_message', t.failure_message,
           'created_at', t.created_at,
           'updated_at', t.updated_at,
           'completed_at', t.completed_at)
  into v_row
  from public.payment_transactions t
  where t.id = p_transaction_id;

  if v_row is null then
    raise exception 'Payment transaction not found.'
      using errcode = 'P0001', detail = 'transaction_not_found';
  end if;

  return v_row;
end;
$$;

comment on function public.admin_get_payment_transaction(uuid) is
  'Phase 6G.4-A. Admin-only, read-only single payment attempt, including idempotency_key.';

-- 3. Customer: own order's payments (safe fields only) -------------------------
create function public.get_my_order_payments(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rows jsonb;
begin
  if v_uid is null then
    raise exception 'You must be signed in.'
      using errcode = '42501', detail = 'not_authorised';
  end if;

  if p_order_id is null
     or not exists (select 1 from public.orders o where o.id = p_order_id and o.user_id = v_uid) then
    raise exception 'Order not found.'
      using errcode = 'P0001', detail = 'order_not_found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'order_id', t.order_id,
           'method', t.method,
           'amount_cents', t.amount_cents,
           'currency', t.currency,
           'status', t.status,
           'created_at', t.created_at,
           'completed_at', t.completed_at
         ) order by t.created_at desc, t.id desc), '[]'::jsonb)
  into v_rows
  from public.payment_transactions t
  where t.order_id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'transactions', v_rows);
end;
$$;

comment on function public.get_my_order_payments(uuid) is
  'Phase 6G.4-A. Caller''s own order only; exposes no provider, reference, failure or idempotency data.';

-- 4. Privileges ---------------------------------------------------------------
revoke all on function public.admin_list_payment_transactions(uuid, public.payment_transaction_status, text, timestamptz, timestamptz, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_get_payment_transaction(uuid) from public, anon, authenticated;
revoke all on function public.get_my_order_payments(uuid) from public, anon, authenticated;
grant execute on function public.admin_list_payment_transactions(uuid, public.payment_transaction_status, text, timestamptz, timestamptz, integer, integer) to authenticated;
grant execute on function public.admin_get_payment_transaction(uuid) to authenticated;
grant execute on function public.get_my_order_payments(uuid) to authenticated;

-- 5. Self-check ---------------------------------------------------------------
do $chk$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)',
    'public.admin_get_payment_transaction(uuid)',
    'public.get_my_order_payments(uuid)'] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6G.4-A self-check failed: % is missing.', v_sig;
    end if;
    if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
               and (not p.prosecdef or p.provolatile <> 's'
                    or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
      raise exception 'Phase 6G.4-A self-check failed: % is not STABLE SECURITY DEFINER with pinned search_path.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig::regprocedure, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig::regprocedure, 'EXECUTE') then
      raise exception 'Phase 6G.4-A self-check failed: wrong execute privileges on %.', v_sig;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
               where p.oid = v_sig::regprocedure and a.grantee = 0) then
      raise exception 'Phase 6G.4-A self-check failed: PUBLIC can execute %.', v_sig;
    end if;
  end loop;
end
$chk$;

commit;
