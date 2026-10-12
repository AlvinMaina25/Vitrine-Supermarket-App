-- =============================================================================
-- PHASE 6B.2 - Admin order actions backend.
--
-- STATUS: written, NOT applied to any database. Not run against local PostgreSQL or the
-- dedicated Phase-5 development Supabase database.
--
-- Apply ONCE, after 20261004020000_phase6b1_admin_orders_backend.sql. Do not edit or re-run
-- any older migration. One transaction: if any statement or the final self-check fails,
-- nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   public.admin_set_order_status(p_order_id, p_status, p_note, p_override)
--     ONE admin-only action. Every admin order action (confirm/process, pick, pack, dispatch,
--     deliver, cancel) is a status change, so one function covers them all.
--
-- HOW IT WORKS - IT IS A GATE AND A RECEIPT AROUND set_order_status(), NOT A NEW STATE MACHINE
--   1. require_admin()   (Phase 6A)  - rejects anon, customers, staff, forged claims,
--                                      service_role without a user. 42501 / not_authorised.
--   2. locks the order row (SELECT ... FOR UPDATE) and records the previous status and the
--      ids of the existing history rows.
--   3. calls public.set_order_status() (Phase 5B.2), UNCHANGED. That function alone decides
--      whether the transition is valid, and its triggers alone do the restock / re-reserve,
--      the delivery-slot capacity guard and the history row. auth.uid() is the caller's JWT
--      subject inside a SECURITY DEFINER function, so set_order_status() still sees the
--      signed-in admin and records them as changed_by.
--   4. verifies the receipt: payment_status did not move; if the status moved, exactly one
--      new history row exists. Otherwise it raises and the whole call rolls back.
--   5. returns a compact result: changed, previous status, the order summary, the history row.
--
-- ADMIN OVERRIDE IS OPT-IN (p_override)
--   p_override => true PERMITS an override, it does not force one: a standard move is made as
--   normal either way. Even with p_override => true set_order_status() still refuses: paid /
--   refunded targets (payment_state_reserved), any move out of refunded (transition_not_allowed),
--   an unpaid online-payment order entering fulfilment (payment_not_confirmed), a status that
--   contradicts the payment method (payment_method_mismatch), a missing reason
--   (admin_note_required), and reactivation into a full / closed slot or without stock
--   (reactivation_* from the triggers). The restock / re-reserve and history logic is the
--   triggers' and runs unchanged.
--   set_order_status() lets an admin make a non-standard transition when a reason of 3+
--   characters is given; it records that as "Admin override: <reason>" in the history. That is
--   part of the Phase 5B.2 contract and is NOT widened here. But a note alone must not turn a
--   routine UI action into an arbitrary jump, so this function only lets an override stand
--   when the caller says so explicitly (p_override => true). If set_order_status() performed
--   an override and p_override is false, the call is rolled back with DETAIL
--   override_not_requested. No transition table is copied here: the override is recognised by
--   the history note that set_order_status() itself writes.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No UPDATE grant or policy on orders. No change to RLS, table privileges, set_order_status(),
--     the triggers, create_order() or any earlier migration.
--   * No payment writer. 'paid' / 'refunded' are still refused by set_order_status()
--     (payment_state_reserved); payment_status is never written here. No provider, webhook,
--     secret or fake confirmation.
--   * No second status mechanism, no stock or delivery-slot code of its own.
--
-- ACCESS MODEL
--   anon / PUBLIC : EXECUTE revoked.
--   authenticated : EXECUTE granted, but require_admin() runs FIRST and refuses non-admins.
--   service_role  : unchanged; it does not pass require_admin() (no auth.uid()).
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.require_admin()',
    'public.is_admin(uuid)',
    'public.set_order_status(uuid,public.order_status,text)',
    'public.admin_get_order(uuid)',
    'public.restock_cancelled_order()',
    'public.log_order_status_change()',
    'public.guard_order_reactivation_capacity()'
  ] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6B.2 precondition failed: function % does not exist (are Phase 5B.2, 6A and 6B.1 applied?).', v_sig;
    end if;
  end loop;

  if to_regclass('public.orders') is null or to_regclass('public.order_status_history') is null then
    raise exception 'Phase 6B.2 precondition failed: expected tables are missing.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'orders'
        and column_name in ('status', 'payment_status', 'restocked_at', 'updated_at')) <> 4 then
    raise exception 'Phase 6B.2 precondition failed: orders status / payment_status / restocked_at / updated_at columns are missing.';
  end if;

  if (select count(*) from pg_proc
      where pronamespace = 'public'::regnamespace and proname = 'set_order_status') <> 1 then
    raise exception 'Phase 6B.2 precondition failed: expected exactly one set_order_status().';
  end if;

  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE') then
    raise exception 'Phase 6B.2 precondition failed: a browser role can UPDATE public.orders. Phase 5B.2 guarantees are not in place.';
  end if;

  if to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)') is not null then
    raise exception 'Phase 6B.2 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_set_order_status()
--
-- Arguments
--   p_order_id  the order.
--   p_status    the requested status (any order_status value; set_order_status() decides).
--   p_note      optional note, recorded in the history. At most 400 characters. Required (3+
--               characters) by set_order_status() for an admin override.
--   p_override  default false. true = "I mean to make a manual override if the move is not a
--               standard transition". See the header.
--
-- Returns jsonb:
--   {
--     "changed": boolean,              false when the order already had that status (no-op,
--                                      no history row - the set_order_status() contract)
--     "previous_status": order_status,
--     "order": { id, order_number, status, payment_status, payment_method, delivery_method,
--                delivery_slot_date, total_cents, currency, placed_at, updated_at,
--                restocked_at },
--     "history_entry": { id, previous_status, new_status, payment_status, changed_by, note,
--                        created_at } | null      the row this call wrote (null when unchanged)
--   }
-- No customer contact data, address, notes or items: fetch those with admin_get_order().
--
-- Errors (SQLSTATE / DETAIL): 42501 not_authorised (admin gate); P0001 invalid_arguments,
-- note_reserved_prefix, order_not_found, override_not_requested, plus everything set_order_status() raises
-- (payment_state_reserved, transition_not_allowed, admin_note_required, payment_not_confirmed,
-- payment_method_mismatch, note_too_long, reactivation_* from the triggers).
--
-- Concurrency: the order row is locked first, so two admins acting on one order are serialised
-- and the second sees the first's committed status (and restocked_at). Stock rows and the
-- delivery-slot advisory lock are taken by the existing triggers, in their existing order.
-- =============================================================================
create or replace function public.admin_set_order_status(
  p_order_id uuid,
  p_status public.order_status,
  p_note text default null,
  p_override boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_before public.orders%rowtype;
  v_after public.orders%rowtype;
  v_prev_ids uuid[];
  v_entry public.order_status_history%rowtype;
  v_changed boolean;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_order_id is null or p_status is null then
    raise exception 'An order and a new status are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- 'Admin override:' is the marker set_order_status() writes for an override. A caller-supplied
  -- note may not start with it: otherwise a standard move could be mislabelled as an override in
  -- the audit trail, and the override receipt below could not tell the two apart.
  if btrim(coalesce(p_note, '')) ilike 'admin override:%' then
    raise exception 'A note may not start with "Admin override:". That prefix is added automatically to overrides.'
      using errcode = 'P0001', detail = 'note_reserved_prefix';
  end if;

  -- Serialise concurrent admin actions on this order and read its state as of the lock.
  select * into v_before from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'That order could not be found.'
      using errcode = 'P0001', detail = 'order_not_found';
  end if;

  select coalesce(array_agg(h.id), '{}'::uuid[]) into v_prev_ids
  from public.order_status_history h
  where h.order_id = p_order_id;

  -- THE state machine. Validation, payment gate, restock / re-reserve, slot capacity guard and
  -- the history row all happen inside this call and its triggers. Its errors propagate as-is.
  perform public.set_order_status(p_order_id, p_status, p_note);

  select * into v_after from public.orders where id = p_order_id;
  v_changed := v_after.status is distinct from v_before.status;

  -- Receipt 1: this layer never moves payment state.
  if v_after.payment_status is distinct from v_before.payment_status then
    raise exception 'An order status action must not change the payment status.'
      using errcode = 'P0001', detail = 'payment_status_changed';
  end if;

  if v_changed then
    -- Receipt 2: a status change always leaves its history row (found by id, not by timestamp,
    -- because rows written in one transaction share now()).
    select h.* into v_entry
    from public.order_status_history h
    where h.order_id = p_order_id
      and h.id <> all (v_prev_ids)
      and h.new_status = v_after.status
    order by h.created_at desc, h.id desc
    limit 1;

    if not found then
      raise exception 'The status change was not recorded in the order history.'
        using errcode = 'P0001', detail = 'history_missing';
    end if;

    -- Receipt 3: an override only stands when the caller asked for one. The marker is the note
    -- set_order_status() writes for an override; raising here rolls the whole call back.
    if coalesce(p_override, false) is not true and v_entry.note like 'Admin override: %' then
      raise exception 'That status change is not a standard transition. Confirm the administrative override to proceed.'
        using errcode = 'P0001', detail = 'override_not_requested';
    end if;
  end if;

  return jsonb_build_object(
    'changed', v_changed,
    'previous_status', v_before.status,
    'order', jsonb_build_object(
      'id', v_after.id,
      'order_number', v_after.order_number,
      'status', v_after.status,
      'payment_status', v_after.payment_status,
      'payment_method', v_after.payment_method,
      'delivery_method', v_after.delivery_method,
      'delivery_slot_date', v_after.delivery_slot_date,
      'total_cents', v_after.total_cents,
      'currency', v_after.currency,
      'placed_at', v_after.placed_at,
      'updated_at', v_after.updated_at,
      'restocked_at', v_after.restocked_at),
    'history_entry', case when v_changed then jsonb_build_object(
      'id', v_entry.id,
      'previous_status', v_entry.previous_status,
      'new_status', v_entry.new_status,
      'payment_status', v_entry.payment_status,
      'changed_by', v_entry.changed_by,
      'note', v_entry.note,
      'created_at', v_entry.created_at) end
  );
end;
$$;

comment on function public.admin_set_order_status(uuid, public.order_status, text, boolean) is
  'Phase 6B.2. Admin-only order action. Gate: require_admin(); the transition itself is validated and applied by set_order_status() (Phase 5B.2), unchanged.';

revoke all on function public.admin_set_order_status(uuid, public.order_status, text, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_order_status(uuid, public.order_status, text, boolean)
  to authenticated;

-- =============================================================================
-- 2. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn constant text := 'public.admin_set_order_status(uuid,public.order_status,text,boolean)';
begin
  if exists (
    select 1 from pg_proc p
    where p.oid = v_fn::regprocedure
      and (not p.prosecdef or p.provolatile <> 'v'
           or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
  ) then
    raise exception 'Phase 6B.2 self-check failed: admin_set_order_status is not VOLATILE SECURITY DEFINER with a pinned search_path.';
  end if;

  if has_function_privilege('anon', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
    raise exception 'Phase 6B.2 self-check failed: admin_set_order_status privileges are wrong.';
  end if;

  if exists (
    select 1 from information_schema.routine_privileges
    where routine_schema = 'public' and routine_name = 'admin_set_order_status'
      and grantee = 'PUBLIC'
  ) then
    raise exception 'Phase 6B.2 self-check failed: PUBLIC can execute admin_set_order_status.';
  end if;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6B.2 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- set_order_status() is still the one status mechanism, with its Phase 5B.2 privileges.
  if (select count(*) from pg_proc
      where pronamespace = 'public'::regnamespace and proname = 'set_order_status') <> 1
     or has_function_privilege('anon', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE') then
    raise exception 'Phase 6B.2 self-check failed: set_order_status() is not as Phase 5B.2 left it.';
  end if;

  -- Orders stay closed to browser writes.
  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_table_privilege('anon', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE')
     or has_table_privilege('authenticated', 'public.orders', 'INSERT')
     or has_table_privilege('authenticated', 'public.orders', 'DELETE') then
    raise exception 'Phase 6B.2 self-check failed: a browser role can write public.orders.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('orders', 'order_items', 'order_status_history')
      and cmd in ('UPDATE', 'INSERT', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6B.2 self-check failed: a write policy exists on an order table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                    'public.order_status_history'::regclass, 'public.user_roles'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6B.2 self-check failed: row level security is off on a protected table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6B.2 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;

  -- One status writer, one gate in front of it: only set_order_status() updates orders, and only
  -- admin_set_order_status() calls it from the database.
  if (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}')
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
        and p.prosrc ~* 'update\s+(public\.)?orders\M') <> array['set_order_status'] then
    raise exception 'Phase 6B.2 self-check failed: the set of functions that UPDATE orders is not exactly set_order_status().';
  end if;
  if (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}')
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
        and p.prosrc ~* 'set_order_status\s*\(') <> array['admin_set_order_status'] then
    raise exception 'Phase 6B.2 self-check failed: the set of functions that call set_order_status() is not exactly admin_set_order_status().';
  end if;
end
$check$;

commit;
