-- =============================================================================
-- PHASE 6G.3 - apply_payment_outcome() + cash on delivery. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005050000 (6G.2). One transaction.
--
-- ADDS (SECURITY DEFINER, search_path = public, pg_temp):
--   apply_payment_outcome(p_transaction_id, p_outcome, p_provider_reference, p_amount_cents,
--                         p_currency, p_failure_code, p_failure_message) -> jsonb   service_role ONLY
--   record_cod_payment(p_order_id, p_reason)                              -> jsonb   authenticated ONLY,
--                                                                                    require_admin() inside
-- REPLACES create_payment_attempt (same signature/grants/behaviour) with ONE extra refusal:
--   method = 'cash_on_delivery' -> method_not_supported (record_cod_payment is the only COD path).
-- DOES NOT: add provider/M-Pesa/card/webhook code, touch inventory, delivery, customers, tables or
--   earlier migrations, or change set_order_status().
--
-- ORDER STATUS: set_order_status() needs a staff JWT (service_role has none), refuses to set 'paid',
--   and allows awaiting_payment -> cancelled only (anything else is an admin override). So it cannot
--   legally advance a paid online order, and this migration does NOT change orders.status. A success
--   sets orders.payment_status = 'paid' only, which satisfies set_order_status()'s payment gate so
--   staff can then move the order along. Failed/cancelled/expired leave the order untouched.
--
-- Money: integer cents, taken from the order in the database. Replies: { changed, transaction[, rejected] }.
-- Refusals are SQLSTATE P0001 with a DETAIL code:
--   apply_payment_outcome: invalid_arguments, invalid_reference, transaction_not_found,
--     invalid_transition (terminal transaction, different outcome), order_not_found,
--     order_not_payable (order cancelled/refunded), order_already_paid (first success wins),
--     reference_conflict, provider_reference_in_use.
--     A succeeded report whose amount/currency differs from the order is NOT raised: the transaction is
--     stored as failed (amount_mismatch / currency_mismatch), returned with rejected = <code>.
--   record_cod_payment: not_authorised (42501), invalid_arguments, order_not_found,
--     not_cash_on_delivery, order_not_payable, order_already_paid, order_status_not_allowed,
--     order_amount_invalid.
--   create_payment_attempt (new): method_not_supported.
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.payment_transactions') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.create_payment_attempt(uuid,text,public.payment_method,text)') is null
     or to_regprocedure('public.mark_payment_processing(uuid,text)') is null
     or to_regprocedure('public.get_order_for_payment(uuid)') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.set_order_status(uuid,public.order_status,text)') is null then
    raise exception 'Phase 6G.3 precondition failed: apply 20261005040000 (6G.1) and 20261005050000 (6G.2) first.';
  end if;
  if to_regprocedure('public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)') is not null
     or to_regprocedure('public.record_cod_payment(uuid,text)') is not null then
    raise exception 'Phase 6G.3 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. apply_payment_outcome ----------------------------------------------------------------------
create function public.apply_payment_outcome(
  p_transaction_id uuid,
  p_outcome public.payment_transaction_status,
  p_provider_reference text default null,
  p_amount_cents integer default null,
  p_currency text default null,
  p_failure_code text default null,
  p_failure_message text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref text := nullif(btrim(coalesce(p_provider_reference, '')), '');
  v_cur text := upper(btrim(coalesce(p_currency, '')));
  v_code text := nullif(left(btrim(regexp_replace(coalesce(p_failure_code, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');
  v_msg text := nullif(left(btrim(regexp_replace(coalesce(p_failure_message, ''), '[[:cntrl:]]', ' ', 'g')), 300), '');
  v_txn public.payment_transactions%rowtype;
  v_order public.orders%rowtype;
  v_reject text;
  v_action text;
begin
  if p_transaction_id is null or p_outcome is null
     or p_outcome not in ('succeeded', 'failed', 'cancelled', 'expired') then
    raise exception 'A transaction and an outcome (succeeded, failed, cancelled or expired) are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if v_ref is not null and char_length(v_ref) > 200 then
    raise exception 'A provider reference is at most 200 characters.'
      using errcode = 'P0001', detail = 'invalid_reference';
  end if;
  if p_outcome = 'succeeded' and (p_amount_cents is null or p_amount_cents <= 0 or v_cur !~ '^[A-Z]{3}$') then
    raise exception 'A success needs the paid amount (cents) and a 3-letter currency.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Lock order: transaction first, then its order. Always.
  select * into v_txn from public.payment_transactions t where t.id = p_transaction_id for update;
  if not found then
    raise exception 'That payment transaction could not be found.'
      using errcode = 'P0001', detail = 'transaction_not_found';
  end if;
  select * into v_order from public.orders o where o.id = v_txn.order_id for update;
  if not found then
    raise exception 'That order could not be found.' using errcode = 'P0001', detail = 'order_not_found';
  end if;

  -- Replay of the same outcome: nothing is written.
  if v_txn.status = p_outcome then
    return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_txn));
  end if;
  -- Terminal states never change (a succeeded transaction is never downgraded).
  if v_txn.status not in ('pending', 'processing') then
    raise exception 'This transaction is already % and cannot become %.', v_txn.status, p_outcome
      using errcode = 'P0001', detail = 'invalid_transition';
  end if;

  if p_outcome = 'succeeded' then
    if v_order.status in ('cancelled', 'refunded') or v_order.payment_status = 'refunded' then
      raise exception 'This order cannot be paid for.' using errcode = 'P0001', detail = 'order_not_payable';
    end if;
    if v_order.status = 'paid' or v_order.payment_status in ('paid', 'partially_refunded') then
      raise exception 'This order is already paid.' using errcode = 'P0001', detail = 'order_already_paid';
    end if;

    if v_cur <> v_order.currency or v_cur <> v_txn.currency then
      v_reject := 'currency_mismatch';
    elsif p_amount_cents <> v_order.total_cents or v_txn.amount_cents <> v_order.total_cents then
      v_reject := 'amount_mismatch';
    end if;
  end if;

  if v_reject is not null then
    update public.payment_transactions t
       set status = 'failed', failure_code = v_reject,
           failure_message = 'Reported ' || p_amount_cents::text || ' ' || v_cur || ' does not match the order.',
           completed_at = now()
     where t.id = v_txn.id
    returning * into v_txn;
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (null, 'payment_' || v_reject, v_txn.order_id,
            left('transaction ' || v_txn.id::text || ': ' || v_txn.failure_message, 500));
    return jsonb_build_object('changed', true, 'rejected', v_reject, 'transaction', to_jsonb(v_txn));
  end if;

  if v_ref is not null and v_txn.provider_reference is not null and v_txn.provider_reference <> v_ref then
    raise exception 'This transaction already has a different provider reference.'
      using errcode = 'P0001', detail = 'reference_conflict';
  end if;

  begin
    update public.payment_transactions t
       set status = p_outcome,
           provider_reference = coalesce(v_ref, t.provider_reference),
           failure_code = case when p_outcome = 'succeeded' then null else v_code end,
           failure_message = case when p_outcome = 'succeeded' then null else v_msg end,
           completed_at = now()
     where t.id = v_txn.id
    returning * into v_txn;
  exception when unique_violation then
    raise exception 'That provider reference is already used by another transaction.'
      using errcode = 'P0001', detail = 'provider_reference_in_use';
  end;

  if p_outcome = 'succeeded' then
    update public.orders o set payment_status = 'paid' where o.id = v_order.id;
  end if;

  v_action := 'payment_' || p_outcome::text;
  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (null, v_action, v_txn.order_id,
          left('transaction ' || v_txn.id::text
               || coalesce(': ' || v_code, '') || coalesce(' - ' || v_msg, ''), 500));

  return jsonb_build_object('changed', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- 2. record_cod_payment -------------------------------------------------------------------------
create function public.record_cod_payment(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.require_admin();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_order public.orders%rowtype;
  v_txn public.payment_transactions%rowtype;
begin
  if p_order_id is null or char_length(v_reason) not between 3 and 400 then
    raise exception 'An order and a reason (3-400 characters) are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'That order could not be found.' using errcode = 'P0001', detail = 'order_not_found';
  end if;

  if v_order.payment_method <> 'cash_on_delivery' then
    raise exception 'This is not a cash on delivery order.' using errcode = 'P0001', detail = 'not_cash_on_delivery';
  end if;

  -- Replay: already settled by cash on delivery.
  select * into v_txn from public.payment_transactions t
   where t.order_id = v_order.id and t.provider = 'cod' and t.status = 'succeeded' limit 1;
  if found then
    return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_txn));
  end if;

  if v_order.status in ('cancelled', 'refunded') or v_order.payment_status = 'refunded' then
    raise exception 'This order cannot be paid for.' using errcode = 'P0001', detail = 'order_not_payable';
  end if;
  if v_order.status = 'paid' or v_order.payment_status in ('paid', 'partially_refunded') then
    raise exception 'This order is already paid.' using errcode = 'P0001', detail = 'order_already_paid';
  end if;
  if v_order.status not in ('out_for_delivery', 'delivered') then
    raise exception 'Cash can only be recorded once the order is out for delivery or delivered.'
      using errcode = 'P0001', detail = 'order_status_not_allowed';
  end if;
  if v_order.total_cents is null or v_order.total_cents <= 0 then
    raise exception 'This order has no payable amount.' using errcode = 'P0001', detail = 'order_amount_invalid';
  end if;

  insert into public.payment_transactions
    (order_id, provider, method, amount_cents, currency, status, idempotency_key, completed_at)
  values (v_order.id, 'cod', 'cash_on_delivery', v_order.total_cents, v_order.currency,
          'succeeded', 'cod:' || v_order.id::text, now())
  returning * into v_txn;

  update public.orders o set payment_status = 'paid' where o.id = v_order.id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'cod_payment_recorded', v_order.id, v_reason);

  return jsonb_build_object('changed', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- 3. create_payment_attempt: identical to 6G.2 plus the COD refusal -------------------------------
create or replace function public.create_payment_attempt(
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

  if p_method = 'cash_on_delivery' then
    raise exception 'Cash on delivery is recorded by an admin, not through a payment attempt.'
      using errcode = 'P0001', detail = 'method_not_supported';
  end if;

  select * into v_existing from public.payment_transactions t where t.idempotency_key = v_key;
  if found then
    if v_existing.order_id <> p_order_id or v_existing.provider <> v_provider or v_existing.method <> p_method then
      raise exception 'That idempotency key was already used for a different payment request.'
        using errcode = 'P0001', detail = 'idempotency_key_conflict';
    end if;
    return jsonb_build_object('changed', false, 'transaction', to_jsonb(v_existing));
  end if;

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

-- 4. Privileges ----------------------------------------------------------------------------------
revoke all on function public.apply_payment_outcome(uuid, public.payment_transaction_status, text, integer, text, text, text)
  from public, anon, authenticated;
grant execute on function public.apply_payment_outcome(uuid, public.payment_transaction_status, text, integer, text, text, text)
  to service_role;

revoke all on function public.create_payment_attempt(uuid, text, public.payment_method, text) from public, anon, authenticated;
grant execute on function public.create_payment_attempt(uuid, text, public.payment_method, text) to service_role;

revoke all on function public.record_cod_payment(uuid, text) from public, anon, service_role;
grant execute on function public.record_cod_payment(uuid, text) to authenticated;

-- 5. Self-check ----------------------------------------------------------------------------------
do $chk$
declare
  v_fn regprocedure;
begin
  foreach v_fn in array array[
    'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)'::regprocedure,
    'public.record_cod_payment(uuid,text)'::regprocedure,
    'public.create_payment_attempt(uuid,text,public.payment_method,text)'::regprocedure] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_fn and p.prosecdef
                     and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%public%pg_temp%')) then
      raise exception 'Phase 6G.3 self-check failed: % is not SECURITY DEFINER with search_path = public, pg_temp.', v_fn;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 6G.3 self-check failed: % is executable by PUBLIC.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'Phase 6G.3 self-check failed: anon can execute %.', v_fn;
    end if;
  end loop;

  foreach v_fn in array array[
    'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)'::regprocedure,
    'public.create_payment_attempt(uuid,text,public.payment_method,text)'::regprocedure] loop
    if has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or not has_function_privilege('service_role', v_fn, 'EXECUTE') then
      raise exception 'Phase 6G.3 self-check failed: % must be executable by service_role only.', v_fn;
    end if;
  end loop;

  if not has_function_privilege('authenticated', 'public.record_cod_payment(uuid,text)'::regprocedure, 'EXECUTE')
     or has_function_privilege('service_role', 'public.record_cod_payment(uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'Phase 6G.3 self-check failed: record_cod_payment must be executable by authenticated only.';
  end if;

  if (select p.prosrc from pg_proc p
       where p.oid = 'public.create_payment_attempt(uuid,text,public.payment_method,text)'::regprocedure)
     not like '%method_not_supported%' then
    raise exception 'Phase 6G.3 self-check failed: create_payment_attempt does not refuse cash_on_delivery.';
  end if;
end
$chk$;

commit;
