-- =============================================================================
-- PHASE 6B.1 - Admin orders backend.
--
-- STATUS: written, NOT applied to any database. Not run against local PostgreSQL or the
-- Phase-5 development Supabase database.
--
-- Apply ONCE, after 20261004010000_phase6a_admin_operations_foundation.sql. Do not edit or
-- re-run any older migration. One transaction: if any statement or the final self-check
-- fails, nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   1. public.admin_list_orders(...)   admin-only, read-only: list / search / filter / page.
--   2. public.admin_get_order(uuid)    admin-only, read-only: one order in full (customer,
--                                      items, delivery, payment fields, status history).
--   3. orders_placed_at_idx            one index so the date filter and the newest-first
--                                      sort do not scan the whole table.
--
-- WHY RPCs AND NOT JUST THE EXISTING POLICIES
--   Staff and admin can already SELECT every order, item and history row ("staff read all").
--   What admins cannot do today is search by customer name / email / phone (profiles are
--   admin-only since 6A, and staff are deliberately NOT given them) or fetch an order with
--   its customer and history in one authorised call. Two SECURITY DEFINER functions behind
--   public.require_admin() give exactly that, from ONE gate, with no new policy and no new
--   grant on any table. Staff keep their existing fulfilment access; they do not get
--   customer contact details through these functions.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No order write path. Status changes remain public.set_order_status() (Phase 5B.2),
--     unchanged: staff/admin check, no paid/refunded from a browser role, transition rules,
--     admin override with a reason. No second mechanism, no UPDATE grant or policy on orders.
--   * No payment table, provider, webhook or payment writer. "Payment information" is what
--     orders already records: payment_method, payment_status, currency and the amounts.
--   * No new table, column, type, policy or table grant. No existing policy, grant or
--     function is changed.
--
-- PRIVACY
--   Customer data comes from public.profiles only (id, full_name, email, phone, created_at).
--   Nothing is read from auth.users, so no password hash, token or auth metadata can leak.
--
-- ACCESS MODEL
--   anon          : EXECUTE revoked (permission denied, 42501).
--   authenticated : EXECUTE granted, but require_admin() runs FIRST and raises 42501 /
--                   not_authorised for anyone who is not an admin.
--   service_role  : unchanged; it does not pass require_admin() (no auth.uid()).
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_dashboard_summary(integer,integer)') is null then
    raise exception 'Phase 6B.1 precondition failed: Phase 6A is not applied (require_admin() / admin_dashboard_summary() missing).';
  end if;

  if to_regprocedure('public.set_order_status(uuid,public.order_status,text)') is null
     or to_regprocedure('public.is_admin(uuid)') is null then
    raise exception 'Phase 6B.1 precondition failed: Phase 5B.2 functions are missing.';
  end if;

  if to_regclass('public.orders') is null or to_regclass('public.order_items') is null
     or to_regclass('public.order_status_history') is null or to_regclass('public.profiles') is null then
    raise exception 'Phase 6B.1 precondition failed: expected tables are missing.';
  end if;

  -- Columns this migration reads. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'orders'
        and column_name in ('delivery_zone_id', 'delivery_zone_code', 'delivery_zone_name',
                            'delivery_method_label', 'delivery_slot_template_id',
                            'delivery_fee_rule', 'restocked_at')) <> 7 then
    raise exception 'Phase 6B.1 precondition failed: orders delivery snapshot / restocked_at columns are missing.';
  end if;

  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE') then
    raise exception 'Phase 6B.1 precondition failed: a browser role can UPDATE public.orders. Phase 5B.2 guarantees are not in place.';
  end if;

  if to_regprocedure('public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)') is not null
     or to_regprocedure('public.admin_get_order(uuid)') is not null then
    raise exception 'Phase 6B.1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. INDEX  (newest-first listing and the placed_at range filter)
-- =============================================================================
create index if not exists orders_placed_at_idx on public.orders (placed_at desc, id desc);

-- =============================================================================
-- 2. admin_list_orders()
--
-- Returns { total, limit, offset, orders: [...] }, newest first (placed_at desc, id desc).
-- Every filter is optional and they combine with AND.
--   p_search          case-insensitive substring over: order number, customer profile name /
--                     email / phone, and the delivery-address snapshot name / phone.
--                     LIKE wildcards in the input are escaped, so '%' and '_' are literal.
--                     At most 100 characters.
--   p_status / p_payment_status / p_payment_method   exact enum match.
--   p_placed_from / p_placed_to   INCLUSIVE calendar days in Africa/Nairobi (the store clock
--                     used everywhere else). from <= to is required.
--   p_limit           1..100 (default 25).   p_offset  >= 0 (default 0).
-- `total` is the count of ALL matching rows (not just this page).
--
-- Each row carries list fields only: no address snapshot, notes, items or history.
-- =============================================================================
create or replace function public.admin_list_orders(
  p_search text default null,
  p_status public.order_status default null,
  p_payment_status public.payment_status default null,
  p_payment_method public.payment_method default null,
  p_placed_from date default null,
  p_placed_to date default null,
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
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pattern text;
  v_from timestamptz;
  v_to timestamptz;
  v_total bigint;
  v_rows jsonb;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0
     or (v_search is not null and char_length(v_search) > 100)
     or (p_placed_from is not null and p_placed_to is not null and p_placed_from > p_placed_to) then
    raise exception 'Invalid order list arguments (limit 1-100, offset >= 0, search up to 100 characters, from <= to).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if v_search is not null then
    v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  if p_placed_from is not null then
    v_from := p_placed_from::timestamp at time zone 'Africa/Nairobi';
  end if;
  if p_placed_to is not null then
    v_to := (p_placed_to + 1)::timestamp at time zone 'Africa/Nairobi';   -- exclusive upper bound
  end if;

  select count(*) into v_total
  from public.orders o
  left join public.profiles pr on pr.id = o.user_id
  where (p_status is null or o.status = p_status)
    and (p_payment_status is null or o.payment_status = p_payment_status)
    and (p_payment_method is null or o.payment_method = p_payment_method)
    and (v_from is null or o.placed_at >= v_from)
    and (v_to is null or o.placed_at < v_to)
    and (v_pattern is null
         or o.order_number ilike v_pattern
         or pr.full_name ilike v_pattern
         or pr.email ilike v_pattern
         or pr.phone ilike v_pattern
         or (o.delivery_address ->> 'full_name') ilike v_pattern
         or (o.delivery_address ->> 'phone') ilike v_pattern);

  select coalesce(jsonb_agg(r.j order by r.placed_at desc, r.id desc), '[]'::jsonb)
  into v_rows
  from (
    select
      o.id, o.placed_at,
      jsonb_build_object(
        'id', o.id,
        'order_number', o.order_number,
        'status', o.status,
        'payment_status', o.payment_status,
        'payment_method', o.payment_method,
        'delivery_method', o.delivery_method,
        'delivery_method_label', o.delivery_method_label,
        'delivery_slot_date', o.delivery_slot_date,
        'subtotal_cents', o.subtotal_cents,
        'delivery_fee_cents', o.delivery_fee_cents,
        'discount_cents', o.discount_cents,
        'total_cents', o.total_cents,
        'currency', o.currency,
        'placed_at', o.placed_at,
        'customer', jsonb_build_object(
          'id', o.user_id,
          'full_name', coalesce(nullif(btrim(pr.full_name), ''),
                                nullif(btrim(o.delivery_address ->> 'full_name'), '')),
          'email', pr.email,
          'phone', coalesce(nullif(btrim(pr.phone), ''),
                            nullif(btrim(o.delivery_address ->> 'phone'), '')))
      ) as j
    from public.orders o
    left join public.profiles pr on pr.id = o.user_id
    where (p_status is null or o.status = p_status)
      and (p_payment_status is null or o.payment_status = p_payment_status)
      and (p_payment_method is null or o.payment_method = p_payment_method)
      and (v_from is null or o.placed_at >= v_from)
      and (v_to is null or o.placed_at < v_to)
      and (v_pattern is null
           or o.order_number ilike v_pattern
           or pr.full_name ilike v_pattern
           or pr.email ilike v_pattern
           or pr.phone ilike v_pattern
           or (o.delivery_address ->> 'full_name') ilike v_pattern
           or (o.delivery_address ->> 'phone') ilike v_pattern)
    order by o.placed_at desc, o.id desc
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'orders', v_rows
  );
end;
$$;

comment on function public.admin_list_orders(text, public.order_status, public.payment_status, public.payment_method, date, date, integer, integer) is
  'Phase 6B.1. Admin-only, read-only order list/search/filter. Gate: require_admin().';

revoke all on function public.admin_list_orders(text, public.order_status, public.payment_status, public.payment_method, date, date, integer, integer)
  from public, anon, authenticated;
grant execute on function public.admin_list_orders(text, public.order_status, public.payment_status, public.payment_method, date, date, integer, integer)
  to authenticated;

-- =============================================================================
-- 3. admin_get_order()
--
-- One order in full, as a single jsonb document:
--   order     the orders row as stored (to_jsonb). The table holds no credentials, so an
--             admin seeing the whole row exposes nothing secret.
--   customer  profile fields only (id, full_name, email, phone, created_at); null fields if
--             the profile row is missing. Never auth.users.
--   delivery  method / label, zone, slot (date, start, end, label, template), fee + the fee
--             rule snapshot, the address SNAPSHOT taken at order time, instructions, and the
--             live address id (may be null after the customer deleted that address).
--   payment   method, status, currency and the amounts already stored on the order.
--             No transaction/provider data exists in the schema, so none is invented.
--   items     order_items in creation order (full snapshot rows).
--   history   order_status_history oldest first, with the changer's display name from profiles.
-- Unknown id -> P0001 / order_not_found (after the admin gate, so non-admins learn nothing).
-- =============================================================================
create or replace function public.admin_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_customer jsonb;
  v_items jsonb;
  v_history jsonb;
begin
  perform public.require_admin();

  if p_order_id is null then
    raise exception 'An order id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'That order could not be found.'
      using errcode = 'P0001', detail = 'order_not_found';
  end if;

  select jsonb_build_object(
           'id', v_order.user_id,
           'full_name', pr.full_name,
           'email', pr.email,
           'phone', pr.phone,
           'created_at', pr.created_at)
  into v_customer
  from (select v_order.user_id as id) u
  left join public.profiles pr on pr.id = u.id;

  select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at, i.id), '[]'::jsonb)
  into v_items
  from public.order_items i
  where i.order_id = v_order.id;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', h.id,
             'previous_status', h.previous_status,
             'new_status', h.new_status,
             'payment_status', h.payment_status,
             'changed_by', h.changed_by,
             'changed_by_name', pc.full_name,
             'note', h.note,
             'created_at', h.created_at)
           order by h.created_at, h.id), '[]'::jsonb)
  into v_history
  from public.order_status_history h
  left join public.profiles pc on pc.id = h.changed_by
  where h.order_id = v_order.id;

  return jsonb_build_object(
    'order', to_jsonb(v_order),
    'customer', v_customer,
    'delivery', jsonb_build_object(
      'method', v_order.delivery_method,
      'method_label', v_order.delivery_method_label,
      'zone_id', v_order.delivery_zone_id,
      'zone_code', v_order.delivery_zone_code,
      'zone_name', v_order.delivery_zone_name,
      'slot_date', v_order.delivery_slot_date,
      'slot_start', v_order.delivery_slot_start,
      'slot_end', v_order.delivery_slot_end,
      'slot_label', v_order.delivery_slot_label,
      'slot_template_id', v_order.delivery_slot_template_id,
      'fee_cents', v_order.delivery_fee_cents,
      'fee_rule', v_order.delivery_fee_rule,
      'address', v_order.delivery_address,
      'address_id', v_order.delivery_address_id,
      'customer_notes', v_order.customer_notes),
    'payment', jsonb_build_object(
      'method', v_order.payment_method,
      'status', v_order.payment_status,
      'currency', v_order.currency,
      'subtotal_cents', v_order.subtotal_cents,
      'delivery_fee_cents', v_order.delivery_fee_cents,
      'discount_cents', v_order.discount_cents,
      'total_cents', v_order.total_cents),
    'items', v_items,
    'history', v_history
  );
end;
$$;

comment on function public.admin_get_order(uuid) is
  'Phase 6B.1. Admin-only, read-only full order detail. Gate: require_admin().';

revoke all on function public.admin_get_order(uuid) from public, anon, authenticated;
grant execute on function public.admin_get_order(uuid) to authenticated;

-- =============================================================================
-- 4. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_list constant text :=
    'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)';
  v_get constant text := 'public.admin_get_order(uuid)';
begin
  if exists (
    select 1 from pg_proc p
    where p.oid in (v_list::regprocedure, v_get::regprocedure)
      and (not p.prosecdef or p.provolatile <> 's'
           or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
  ) then
    raise exception 'Phase 6B.1 self-check failed: a new function is not STABLE SECURITY DEFINER with a pinned search_path.';
  end if;

  if has_function_privilege('anon', v_list, 'EXECUTE') or has_function_privilege('anon', v_get, 'EXECUTE')
     or not has_function_privilege('authenticated', v_list, 'EXECUTE')
     or not has_function_privilege('authenticated', v_get, 'EXECUTE') then
    raise exception 'Phase 6B.1 self-check failed: admin order function privileges are wrong.';
  end if;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6B.1 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- Phase 5B.2 / 5A.2 guarantees still hold: orders stay closed to browser writes.
  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_table_privilege('anon', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE')
     or has_table_privilege('authenticated', 'public.orders', 'INSERT')
     or has_table_privilege('authenticated', 'public.orders', 'DELETE') then
    raise exception 'Phase 6B.1 self-check failed: a browser role can write public.orders.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('orders', 'order_items', 'order_status_history')
      and cmd in ('UPDATE', 'INSERT', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6B.1 self-check failed: a write policy exists on an order table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                    'public.order_status_history'::regclass, 'public.profiles'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6B.1 self-check failed: row level security is off on a protected table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6B.1 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
