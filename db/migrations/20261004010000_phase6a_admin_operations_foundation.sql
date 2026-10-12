-- =============================================================================
-- PHASE 6A - Admin operations foundation.
--
-- STATUS: written and run only against a throwaway local PostgreSQL 16 (see the Phase 6A
-- report). NOT applied to the Phase-5 development Supabase database.
--
-- Apply ONCE, after 20261003010000_phase5b2_security_authorization_hardening.sql. Do not edit
-- or re-run any older migration. One transaction: if any statement or the final self-check
-- fails, nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   1. public.require_admin()            internal admin gate, so every future admin RPC fails
--                                        the same way (42501 / not_authorised) from ONE place.
--   2. Admin read policies                admins (only) can read ALL products, variants and
--                                        categories (including inactive ones) and ALL profiles.
--   3. public.admin_dashboard_summary()  one admin-only, read-only RPC aggregating tables that
--                                        already exist.
--
-- WHAT ALREADY EXISTED (Phase 5) AND IS REUSED UNCHANGED
--   * Orders, order items, order status history: staff AND admin read everything through the
--     existing "staff read all" policies. Nobody in the browser can UPDATE orders; status
--     changes go through set_order_status(). Not touched.
--   * Delivery methods/zones/zone fees/slot templates/slot overrides: staff read all, admin-only
--     INSERT/UPDATE (5B.2). Not touched.
--   * user_roles: admins read all (010000). Not touched. Roles are still granted only by the
--     service role / SQL editor.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No payment table, provider, webhook or payment record. The schema has none; see report.
--   * No write path for products, inventory, customers, orders or delivery. No new table, no
--     new column, no new grant on any table. Admin product/inventory/customer WRITES are later
--     phases and need their own reviewed policies or RPCs.
--   * No change to Phase 5 policies, grants or functions.
--
-- ACCESS MODEL FOR THE NEW OBJECTS
--   customer / anon : nothing new. They cannot read other users' profiles or inactive catalog
--                     rows, and cannot execute the dashboard function.
--   staff           : nothing new (staff stay fulfilment-only: no catalog-wide, profile or
--                     dashboard access).
--   admin           : read everything listed above, and call admin_dashboard_summary().
--   service_role    : unchanged (bypasses RLS as before). It does NOT pass require_admin(),
--                     because that gate is keyed to a signed-in admin user (auth.uid()).
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS - fail early and clearly if the database is not in the expected state.
-- =============================================================================
do $pre$
declare
  v_sig text;
begin
  if to_regclass('public.products') is null
     or to_regclass('public.product_variants') is null
     or to_regclass('public.categories') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.user_roles') is null
     or to_regclass('public.delivery_methods') is null
     or to_regclass('public.delivery_zones') is null
     or to_regclass('public.delivery_slot_templates') is null then
    raise exception 'Phase 6A precondition failed: expected tables are missing. Apply all earlier migrations first.';
  end if;

  -- Phase 5B.2 must be applied: this migration builds on is_admin() and on the closed orders write path.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'restocked_at'
  ) then
    raise exception 'Phase 6A precondition failed: Phase 5B.2 is not applied (orders.restocked_at is missing).';
  end if;

  foreach v_sig in array array[
    'public.is_admin(uuid)',
    'public.is_staff(uuid)',
    'public.set_order_status(uuid,public.order_status,text)',
    'public.order_status_holds_delivery_slot(public.order_status)'
  ] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6A precondition failed: function % does not exist (is Phase 5B.2 applied?).', v_sig;
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE') then
    raise exception 'Phase 6A precondition failed: a browser role can UPDATE public.orders. Phase 5B.2 guarantees are not in place.';
  end if;

  if to_regprocedure('public.require_admin()') is not null
     or to_regprocedure('public.admin_dashboard_summary(integer,integer)') is not null then
    raise exception 'Phase 6A appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. require_admin()  - the one admin gate for admin RPCs.
--
-- Returns the caller's id, or raises exactly the error set_order_status() uses for an
-- unauthorised caller (SQLSTATE 42501, DETAIL not_authorised). Authorisation is decided from
-- the caller's own verified JWT (auth.uid()) and public.user_roles, never from an argument.
-- INTERNAL: no browser role can execute it directly. SECURITY DEFINER functions that call it
-- run as their owner, so they can.
-- =============================================================================
create or replace function public.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null or not public.is_admin(v_user) then
    raise exception 'You are not allowed to perform this admin action.'
      using errcode = '42501', detail = 'not_authorised';
  end if;
  return v_user;
end;
$$;

revoke all on function public.require_admin() from public, anon, authenticated;

-- =============================================================================
-- 2. ADMIN READ POLICIES  (SELECT only, authenticated, admin only)
--
-- Existing policies stay as they are. PostgreSQL ORs permissive policies for the same command,
-- so these ADD access for admins and take nothing from anyone else. No INSERT/UPDATE/DELETE
-- policy and no new grant is created: admin product/inventory/customer writes are later work.
--   products / product_variants / categories : the public policies only show ACTIVE rows, so an
--     admin could not see (or later re-activate) hidden catalogue entries. Needed for admin
--     product and inventory access.
--   profiles : own-row only until now. Needed for admin customer access.
-- Staff are intentionally NOT included (staff = fulfilment). Widening it is a decision for the
-- owner, see the report.
-- =============================================================================
create policy "Products: admin read all"
  on public.products for select to authenticated
  using (public.is_admin(auth.uid()));

create policy "Variants: admin read all"
  on public.product_variants for select to authenticated
  using (public.is_admin(auth.uid()));

create policy "Categories: admin read all"
  on public.categories for select to authenticated
  using (public.is_admin(auth.uid()));

create policy "Profiles: admin read all"
  on public.profiles for select to authenticated
  using (public.is_admin(auth.uid()));

-- =============================================================================
-- 3. admin_dashboard_summary()
--
-- Read-only. Admin only (require_admin() runs FIRST, before arguments are even looked at).
-- SECURITY DEFINER so it can aggregate across all customers; the gate above is its only door.
-- Every figure comes from an existing table; no new business rule is invented:
--   * "active" orders use the existing public.order_status_holds_delivery_slot() predicate
--     (= not cancelled / refunded), the single definition the delivery code already uses.
--   * "today" is Africa/Nairobi, the store clock the delivery code already uses.
--   * Counts by status / payment status / payment method list EVERY enum value (zero when
--     none), so a client never has to guess which keys exist.
--
-- p_recent_orders_limit  1..50    (default 10)  how many recent orders to return
-- p_low_stock_threshold  0..1000  (default 10)  quantity at or below which an in-stock item
--                                               counts as "low". The schema has NO per-product
--                                               reorder level, so this is a caller-supplied
--                                               cut-off, not stored business data.
--
-- NOT revenue: gross_value_cents sums total_cents of non-cancelled orders, including unpaid and
-- cash-on-delivery orders. No payment is ever "collected" in the current schema.
-- Stock definitions (active products/variants only):
--   product out_of_stock : not in_stock flag, or stock_quantity = 0
--   product low_stock    : in_stock and 1 <= stock_quantity <= threshold
--   variant out_of_stock : stock_quantity = 0 (variants have no in_stock flag)
--   variant low_stock    : 1 <= stock_quantity <= threshold
-- Customers = profiles of users who hold NO staff/admin role (customer is the implicit role).
-- =============================================================================
create or replace function public.admin_dashboard_summary(
  p_recent_orders_limit integer default 10,
  p_low_stock_threshold integer default 10
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_orders jsonb;
  v_payments jsonb;
  v_delivery jsonb;
  v_products jsonb;
  v_variants jsonb;
  v_low_stock jsonb;
  v_customers jsonb;
  v_recent jsonb;
begin
  perform public.require_admin();

  if p_recent_orders_limit is null or p_recent_orders_limit < 1 or p_recent_orders_limit > 50
     or p_low_stock_threshold is null or p_low_stock_threshold < 0 or p_low_stock_threshold > 1000 then
    raise exception 'Invalid dashboard arguments (recent orders 1-50, low-stock threshold 0-1000).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- ORDERS ---------------------------------------------------------------------------------
  select jsonb_build_object(
    'total', (select count(*) from public.orders),
    'placed_today', (
      select count(*) from public.orders o
      where (o.placed_at at time zone 'Africa/Nairobi')::date = v_today),
    'gross_value_cents', (
      select coalesce(sum(o.total_cents), 0) from public.orders o
      where public.order_status_holds_delivery_slot(o.status)),
    'by_status', (
      select jsonb_object_agg(e.v::text, coalesce(c.n, 0))
      from unnest(enum_range(null::public.order_status)) as e(v)
      left join (select status, count(*)::integer as n from public.orders group by status) c
        on c.status = e.v)
  ) into v_orders;

  -- PAYMENTS (only what orders.payment_status / payment_method already record) -------------
  select jsonb_build_object(
    'by_status', (
      select jsonb_object_agg(e.v::text, coalesce(c.n, 0))
      from unnest(enum_range(null::public.payment_status)) as e(v)
      left join (select payment_status as s, count(*)::integer as n from public.orders group by payment_status) c
        on c.s = e.v),
    'by_method', (
      select jsonb_object_agg(e.v::text, coalesce(c.n, 0))
      from unnest(enum_range(null::public.payment_method)) as e(v)
      left join (select payment_method as m, count(*)::integer as n from public.orders group by payment_method) c
        on c.m = e.v)
  ) into v_payments;

  -- DELIVERY -------------------------------------------------------------------------------
  select jsonb_build_object(
    'scheduled_today', (
      select count(*) from public.orders o
      where o.delivery_slot_date = v_today
        and public.order_status_holds_delivery_slot(o.status)),
    'scheduled_upcoming', (
      select count(*) from public.orders o
      where o.delivery_slot_date > v_today
        and public.order_status_holds_delivery_slot(o.status)),
    'by_method', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', m.code, 'label', m.label, 'is_active', m.is_active,
               'orders', (select count(*) from public.orders o
                          where o.delivery_method = m.code
                            and public.order_status_holds_delivery_slot(o.status))
             ) order by m.position, m.code), '[]'::jsonb)
      from public.delivery_methods m),
    'configuration', jsonb_build_object(
      'active_methods', (select count(*) from public.delivery_methods where is_active),
      'active_zones', (select count(*) from public.delivery_zones where is_active),
      'active_slot_templates', (select count(*) from public.delivery_slot_templates where is_active))
  ) into v_delivery;

  -- PRODUCTS / VARIANTS --------------------------------------------------------------------
  select jsonb_build_object(
    'total', count(*),
    'active', count(*) filter (where p.is_active),
    'inactive', count(*) filter (where not p.is_active),
    'out_of_stock', count(*) filter (where p.is_active and (not p.in_stock or p.stock_quantity = 0)),
    'low_stock', count(*) filter (
      where p.is_active and p.in_stock
        and p.stock_quantity between 1 and p_low_stock_threshold)
  ) into v_products
  from public.products p;

  select jsonb_build_object(
    'total', count(*),
    'active', count(*) filter (where v.is_active),
    'out_of_stock', count(*) filter (where v.is_active and p.is_active and v.stock_quantity = 0),
    'low_stock', count(*) filter (
      where v.is_active and p.is_active
        and v.stock_quantity between 1 and p_low_stock_threshold)
  ) into v_variants
  from public.product_variants v
  join public.products p on p.id = v.product_id;

  -- Items needing attention (at most 10): out-of-stock first, then low stock, lowest quantity first.
  -- (A product flagged not-in-stock can still have a quantity, so quantity alone must not decide.)
  select coalesce(jsonb_agg(l.j order by l.rk, l.qty, l.name, l.vname nulls first), '[]'::jsonb)
  into v_low_stock
  from (
    select * from (
      select
        jsonb_build_object(
          'kind', 'product', 'product_id', p.id, 'variant_id', null,
          'name', p.name, 'variant_name', null, 'sku', p.sku,
          'stock_quantity', p.stock_quantity,
          'state', case when not p.in_stock or p.stock_quantity = 0 then 'out_of_stock' else 'low_stock' end
        ) as j,
        case when not p.in_stock or p.stock_quantity = 0 then 0 else 1 end as rk,
        p.stock_quantity as qty, p.name as name, null::text as vname
      from public.products p
      where p.is_active
        and (not p.in_stock or p.stock_quantity = 0
             or p.stock_quantity between 1 and p_low_stock_threshold)
      union all
      select
        jsonb_build_object(
          'kind', 'variant', 'product_id', p.id, 'variant_id', v.id,
          'name', p.name, 'variant_name', v.name, 'sku', v.sku,
          'stock_quantity', v.stock_quantity,
          'state', case when v.stock_quantity = 0 then 'out_of_stock' else 'low_stock' end
        ),
        case when v.stock_quantity = 0 then 0 else 1 end,
        v.stock_quantity, p.name, v.name
      from public.product_variants v
      join public.products p on p.id = v.product_id
      where v.is_active and p.is_active
        and v.stock_quantity <= p_low_stock_threshold
    ) u
    order by u.rk, u.qty, u.name, u.vname nulls first
    limit 10
  ) l;

  -- CUSTOMERS ------------------------------------------------------------------------------
  select jsonb_build_object(
    'total', count(*),
    'new_last_30_days', count(*) filter (where pr.created_at >= now() - interval '30 days')
  ) into v_customers
  from public.profiles pr
  where not exists (
    select 1 from public.user_roles ur
    where ur.user_id = pr.id and ur.role in ('staff', 'admin'));

  -- RECENT ORDERS (no email, phone or address - a name for display only) -------------------
  select coalesce(jsonb_agg(r.j order by r.placed_at desc, r.id desc), '[]'::jsonb)
  into v_recent
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
        'total_cents', o.total_cents,
        'currency', o.currency,
        'placed_at', o.placed_at,
        'customer_name', coalesce(nullif(btrim(pr.full_name), ''),
                                  nullif(btrim(o.delivery_address ->> 'full_name'), ''))
      ) as j
    from public.orders o
    left join public.profiles pr on pr.id = o.user_id
    order by o.placed_at desc, o.id desc
    limit p_recent_orders_limit
  ) r;

  return jsonb_build_object(
    'generated_at', now(),
    'time_zone', 'Africa/Nairobi',
    'low_stock_threshold', p_low_stock_threshold,
    'orders', v_orders,
    'payments', v_payments,
    'delivery', v_delivery,
    'products', v_products,
    'variants', v_variants,
    'low_stock_items', v_low_stock,
    'customers', v_customers,
    'recent_orders', v_recent
  );
end;
$$;

comment on function public.admin_dashboard_summary(integer, integer) is
  'Phase 6A. Admin-only, read-only dashboard aggregates over existing tables. Not revenue; no payment records exist yet.';

revoke all on function public.admin_dashboard_summary(integer, integer) from public, anon, authenticated;
grant execute on function public.admin_dashboard_summary(integer, integer) to authenticated;

-- =============================================================================
-- 4. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
begin
  -- New functions: pinned search_path, correct privileges.
  if exists (
    select 1 from pg_proc p
    where p.oid in ('public.require_admin()'::regprocedure,
                    'public.admin_dashboard_summary(integer,integer)'::regprocedure)
      and (not p.prosecdef or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
  ) then
    raise exception 'Phase 6A self-check failed: a new function is not SECURITY DEFINER with a pinned search_path.';
  end if;

  if has_function_privilege('anon', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE') then
    raise exception 'Phase 6A self-check failed: admin_dashboard_summary privileges are wrong.';
  end if;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6A self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- The four admin read policies exist, are SELECT-only and use the admin check.
  if (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'SELECT'
        and policyname in ('Products: admin read all', 'Variants: admin read all',
                           'Categories: admin read all', 'Profiles: admin read all')
        and qual like '%is_admin%') <> 4 then
    raise exception 'Phase 6A self-check failed: an admin read policy is missing or does not use is_admin().';
  end if;

  -- Nothing was opened for writing on the tables this migration touched: no browser-role
  -- write POLICY exists on the catalogue (RLS then rejects any write, whatever table grants say).
  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6A self-check failed: a write policy exists on a catalogue table.';
  end if;

  -- Phase 5B.2 guarantees still hold.
  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_table_privilege('anon', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE') then
    raise exception 'Phase 6A self-check failed: a browser role can UPDATE public.orders.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'orders' and cmd in ('UPDATE', 'ALL')
  ) then
    raise exception 'Phase 6A self-check failed: an UPDATE policy exists on public.orders.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass,
                    'public.categories'::regclass, 'public.profiles'::regclass,
                    'public.orders'::regclass, 'public.user_roles'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6A self-check failed: row level security is off on a protected table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6A self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
