-- =============================================================================
-- PHASE 5B.2 database test: security authorization hardening.
--
-- STATUS: written for migration 20261003010000_phase5b2_security_authorization_hardening.sql.
-- It has NOT been run against the dedicated Phase-5 development Supabase database.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261003010000_phase5b2_security_authorization_hardening.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase5b2_security_authorization_hardening.test.sql
--
-- Everything runs in ONE transaction that is rolled back at the end, so no fixture survives.
-- A failed check raises "FAIL: <name>" and aborts; each pass prints "PASS: <name>".
-- Reaching "ALL PHASE 5B.2 TESTS PASSED" means every check passed.
-- If you paste it into the Supabase SQL Editor, paste the WHOLE file (BEGIN ... ROLLBACK).
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings (request.jwt.claims / .sub /
-- .role) and `SET LOCAL ROLE anon|authenticated|service_role`, runs one SQL statement and
-- captures its single result value or the error (SQLSTATE, message, DETAIL). So privileges, RLS
-- and auth.uid() are exercised exactly as PostgREST would exercise them.
--
-- WHAT A SINGLE SESSION CANNOT PROVE: true parallelism. "Concurrent restock" is covered by
-- repeated and cross-path attempts here (the idempotency lives in a column stamped inside the
-- same row update, so any later attempt sees it). The row-lock argument for two simultaneous
-- sessions is in the report; a two-session script is listed there as a follow-up.
--
-- Fixtures use the marker 'T5B2' in names and counties, and fixed UUIDs starting 5b2.
-- Dates are relative to "today" in Africa/Nairobi.
-- =============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Helpers (all in pg_temp, gone at the end of the session)
-- ---------------------------------------------------------------------------
create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_name;
  end if;
  raise notice 'PASS: %', p_name;
end;
$$;

create or replace function pg_temp.d(p_days integer)
returns date language sql stable as $$
  select ((now() at time zone 'Africa/Nairobi')::date + p_days);
$$;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

-- Run ONE statement as a role / user and record its result under key k.
create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
declare
  v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims',
    case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claim.role', p_role, true);
  begin
    execute format('set local role %I', p_role);
    execute p_sql into v_res;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_res values (p_k, v_res, v_err, v_state, v_detail)
  on conflict (k) do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end;
$$;

-- Owner-level scalar query (no role switch).
create or replace function pg_temp.q(p_sql text)
returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end;
$$;

create or replace function pg_temp.res(p_k text) returns text language sql as $$
  select res from t_res where k = p_k $$;

-- The statement succeeded and returned exactly this value.
create or replace function pg_temp.expect(p_k text, p_value text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  if r.err is not null then
    raise exception 'FAIL: % (unexpected error % %: %)', p_name, r.state, coalesce(r.detail, ''), r.err;
  end if;
  perform pg_temp.ok(r.res is not distinct from p_value, p_name || ' [got ' || coalesce(r.res, 'NULL') || ']');
end;
$$;

-- The statement failed with this SQLSTATE and (when given) this DETAIL code.
create or replace function pg_temp.expect_err(p_k text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  if r.err is null then
    raise exception 'FAIL: % (expected an error, got result %)', p_name, coalesce(r.res, 'NULL');
  end if;
  perform pg_temp.ok(
    r.state = p_state and (p_detail is null or r.detail = p_detail),
    p_name || ' [' || r.state || ' ' || coalesce(r.detail, '-') || ']');
end;
$$;

-- Place an order through the real RPC as an authenticated customer.
create or replace function pg_temp.place(
  p_k text, p_uid uuid, p_method text,
  p_payment text default 'cash_on_delivery',
  p_address uuid default null,
  p_zone uuid default null,
  p_qty integer default 1,
  p_product uuid default '00000000-0000-4000-8000-5b2200000001',
  p_variant uuid default null,
  p_expected integer default null,
  p_slot_date date default null,
  p_slot_start time default null,
  p_slot_end time default null,
  p_idem text default null
) returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, 'authenticated', p_uid, format(
    $f$select public.create_order(
         jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'variant_id', %L::uuid, 'quantity', %s)),
         %L, %L::public.payment_method, %L::uuid, %L::date, %L::time, %L::time,
         null, null, %L, %L::integer, %L::uuid)::text$f$,
    p_product, p_variant, p_qty, p_method, p_payment, p_address,
    p_slot_date, p_slot_start, p_slot_end, p_idem, p_expected, p_zone));
end;
$$;

-- Staff/admin status change through the RPC.
create or replace function pg_temp.set_status(p_k text, p_role text, p_uid uuid, p_order text, p_status text, p_note text default null)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format(
    'select public.set_order_status(%L::uuid, %L::public.order_status, %L)::text', p_order, p_status, p_note));
end;
$$;

create or replace function pg_temp.stock(p_id uuid) returns integer language sql as $$
  select stock_quantity from public.products where id = p_id $$;
create or replace function pg_temp.vstock(p_id uuid) returns integer language sql as $$
  select stock_quantity from public.product_variants where id = p_id $$;
create or replace function pg_temp.ostatus(p_id text) returns text language sql as $$
  select status::text from public.orders where id = p_id::uuid $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
-- Users: two customers, one staff, one admin.
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-5b2100000001', 't5b2-customer1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-5b2100000002', 't5b2-customer2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-5b2100000003', 't5b2-staff@example.test',     'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-5b2100000004', 't5b2-admin@example.test',     'authenticated', 'authenticated');

insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-5b2100000003', 'staff'),
  ('00000000-0000-4000-8000-5b2100000004', 'admin');

-- Products: P1 plain active; P_OFF inactive; PV active with one active and one inactive variant.
insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-5b2200000001', 't5b2-p1',  'T5B2 product',          10000, 20, true, true),
  ('00000000-0000-4000-8000-5b2200000002', 't5b2-off', 'T5B2 inactive product', 11100, 7,  true, false),
  ('00000000-0000-4000-8000-5b2200000003', 't5b2-pv',  'T5B2 variant product',  2000,  10, true, true);

insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, is_active) values
  ('00000000-0000-4000-8000-5b2200000011', '00000000-0000-4000-8000-5b2200000003', 'T5B2 active variant',   2500, 5, true),
  ('00000000-0000-4000-8000-5b2200000012', '00000000-0000-4000-8000-5b2200000003', 'T5B2 inactive variant', 2600, 4, false);

-- Delivery methods: with address / pickup / pickup with slot / inactive.
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('tb2_addr', 'T5B2 address delivery', 30000, null, 0, false, true,  true),
  ('tb2_pick', 'T5B2 pickup',           0,     null, 0, false, false, true),
  ('tb2_slot', 'T5B2 pickup slot',      0,     null, 0, true,  false, true),
  ('tb2_off',  'T5B2 inactive',         0,     null, 0, false, false, false);

-- Zones. Counties are unique to this test so seeded zones can never cover these addresses.
insert into public.delivery_zones (id, code, name, county, towns, position, is_active) values
  ('00000000-0000-4000-8000-5b2300000001', 't5b2-alpha',  'T5B2 Alpha towns',  'T5B2-Alpha', '{Westlands,Kilimani}', 1, true),
  ('00000000-0000-4000-8000-5b2300000002', 't5b2-beta',   'T5B2 Beta (cheap)', 'T5B2-Beta',  '{Nyali}',              2, true),
  ('00000000-0000-4000-8000-5b2300000003', 't5b2-off',    'T5B2 inactive',     'T5B2-Alpha', '{Westlands}',          3, false),
  ('00000000-0000-4000-8000-5b2300000004', 't5b2-nogeo',  'T5B2 no geography', null,         '{}',                   4, true),
  ('00000000-0000-4000-8000-5b2300000005', 't5b2-gamma',  'T5B2 Gamma county', 'T5B2-Gamma', '{}',                   5, true),
  ('00000000-0000-4000-8000-5b2300000006', 't5b2-gamma2', 'T5B2 Gamma Thika',  'T5B2-Gamma', '{Thika}',               6, true);

insert into public.delivery_zone_fees (id, zone_id, method_code, fee_cents, min_order_cents, is_active) values
  ('00000000-0000-4000-8000-5b2500000001', '00000000-0000-4000-8000-5b2300000001', 'tb2_addr', 15000, 0, true),
  ('00000000-0000-4000-8000-5b2500000002', '00000000-0000-4000-8000-5b2300000002', 'tb2_addr', 5000,  0, true),
  ('00000000-0000-4000-8000-5b2500000003', '00000000-0000-4000-8000-5b2300000005', 'tb2_addr', 20000, 0, true),
  ('00000000-0000-4000-8000-5b2500000004', '00000000-0000-4000-8000-5b2300000006', 'tb2_addr', 22000, 0, true),
  -- A zone fee rule for pickup in the cheap zone: must NOT leak into a pickup order.
  ('00000000-0000-4000-8000-5b2500000005', '00000000-0000-4000-8000-5b2300000002', 'tb2_pick', 9999,  0, true);

-- Addresses of customer 1 (and one of customer 2).
insert into public.addresses (id, user_id, full_name, phone, address_line_1, city, county) values
  ('00000000-0000-4000-8000-5b2400000001', '00000000-0000-4000-8000-5b2100000001', 'C1 Westlands', '0700000001', '1 Test Rd', 'Westlands',        'T5B2-Alpha'),
  ('00000000-0000-4000-8000-5b2400000002', '00000000-0000-4000-8000-5b2100000001', 'C1 Ruiru',     '0700000001', '2 Test Rd', 'Ruiru',            'T5B2-Gamma'),
  ('00000000-0000-4000-8000-5b2400000003', '00000000-0000-4000-8000-5b2100000001', 'C1 Thika',     '0700000001', '3 Test Rd', 'Thika',            'T5B2-Gamma'),
  ('00000000-0000-4000-8000-5b2400000004', '00000000-0000-4000-8000-5b2100000001', 'C1 Nowhere',   '0700000001', '4 Test Rd', 'Nowhere',          'T5B2-Omega'),
  ('00000000-0000-4000-8000-5b2400000005', '00000000-0000-4000-8000-5b2100000001', 'C1 Spaced',    '0700000001', '5 Test Rd', '  westlands  ',    't5b2-ALPHA'),
  ('00000000-0000-4000-8000-5b2400000006', '00000000-0000-4000-8000-5b2100000002', 'C2 Westlands', '0700000002', '6 Test Rd', 'Westlands',        'T5B2-Alpha');

-- A slot template for the reactivation-capacity regression (capacity 1).
insert into public.delivery_slot_templates (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
values ('00000000-0000-4000-8000-5b2600000001', 'T5B2 slot', '03:00', '03:30', null, 1, 100, true);

-- ===========================================================================
-- FUNCTIONS: privilege matrix (owner view of the grants)
-- ===========================================================================
select pg_temp.ok(
  not exists (
    select 1
    from unnest(array[
      'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)',
      'public.set_order_status(uuid,public.order_status,text)',
      'public.has_role(uuid,public.app_role)', 'public.is_staff(uuid)', 'public.is_admin(uuid)',
      'public.delivery_slot_booked_count(date,time,time)', 'public.delivery_slot_effective_capacity(uuid,date)',
      'public.delivery_slot_evaluate(date,time,time)', 'public.delivery_slot_acquire_lock(date,time,time)',
      'public.lock_delivery_slot(date,time,time)', 'public.next_order_number()',
      'public.order_status_holds_delivery_slot(public.order_status)',
      'public.delivery_text_key(text)', 'public.delivery_zone_covers_address(uuid,text,text)',
      'public.restock_cancelled_order()', 'public.log_order_status_change()',
      'public.guard_order_reactivation_capacity()', 'public.handle_new_user()',
      'public.handle_user_email_change()', 'public.set_updated_at()', 'public.addresses_single_default()'
    ]) as f(sig)
    where has_function_privilege('anon', f.sig, 'EXECUTE')),
  'FUNCTIONS: anon can execute only the client-callable (class A) functions');

select pg_temp.ok(
  not exists (
    select 1
    from unnest(array[
      'public.delivery_slot_booked_count(date,time,time)', 'public.delivery_slot_effective_capacity(uuid,date)',
      'public.delivery_slot_evaluate(date,time,time)', 'public.delivery_slot_acquire_lock(date,time,time)',
      'public.lock_delivery_slot(date,time,time)', 'public.next_order_number()',
      'public.order_status_holds_delivery_slot(public.order_status)',
      'public.delivery_text_key(text)', 'public.delivery_zone_covers_address(uuid,text,text)',
      'public.restock_cancelled_order()', 'public.log_order_status_change()',
      'public.guard_order_reactivation_capacity()', 'public.handle_new_user()',
      'public.handle_user_email_change()', 'public.set_updated_at()', 'public.addresses_single_default()'
    ]) as f(sig)
    where has_function_privilege('authenticated', f.sig, 'EXECUTE')),
  'FUNCTIONS: authenticated cannot execute internal (C) or trigger-only (D) functions');

select pg_temp.ok(
  has_function_privilege('anon', 'public.validate_cart(jsonb)', 'EXECUTE')
  and has_function_privilege('anon', 'public.validate_delivery_selection(text,uuid,integer)', 'EXECUTE')
  and has_function_privilege('anon', 'public.validate_delivery_slot(date,time,time)', 'EXECUTE')
  and has_function_privilege('anon', 'public.get_delivery_slot_availability(date,date)', 'EXECUTE')
  and has_function_privilege('anon', 'public.resolve_delivery_fee(text,uuid,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.validate_cart(jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.is_staff(uuid)', 'EXECUTE'),
  'FUNCTIONS: required application RPCs are still executable (A for anon+auth, B for auth)');

select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'FUNCTIONS: every SECURITY DEFINER function pins search_path = public, pg_temp');

-- anon is refused at the privilege layer
select pg_temp.run('anon_is_staff', 'anon', null, $q$select public.is_staff('00000000-0000-4000-8000-5b2100000003')::text$q$);
select pg_temp.expect_err('anon_is_staff', '42501', null, 'FUNCTIONS: anon cannot call is_staff()');
select pg_temp.run('anon_has_role', 'anon', null, $q$select public.has_role('00000000-0000-4000-8000-5b2100000004','admin')::text$q$);
select pg_temp.expect_err('anon_has_role', '42501', null, 'FUNCTIONS: anon cannot call has_role()');
select pg_temp.run('anon_create_order', 'anon', null,
  $q$select public.create_order('[]'::jsonb,'tb2_pick','cash_on_delivery')::text$q$);
select pg_temp.expect_err('anon_create_order', '42501', null, 'FUNCTIONS: anon cannot call create_order()');
select pg_temp.run('anon_set_status', 'anon', null,
  $q$select public.set_order_status('00000000-0000-4000-8000-5b2100000001','processing')::text$q$);
select pg_temp.expect_err('anon_set_status', '42501', null, 'FUNCTIONS: anon cannot call set_order_status()');
select pg_temp.run('cust_trigger_fn', 'authenticated', '00000000-0000-4000-8000-5b2100000001', $q$select public.restock_cancelled_order()::text$q$);
select pg_temp.expect_err('cust_trigger_fn', '42501', null, 'FUNCTIONS: authenticated cannot call a trigger function directly');
select pg_temp.run('cust_internal_fn', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$select public.lock_delivery_slot(current_date, '03:00', '03:30')::text$q$);
select pg_temp.expect_err('cust_internal_fn', '42501', null, 'FUNCTIONS: authenticated cannot call lock_delivery_slot()');

-- ===========================================================================
-- CUSTOMER: cannot probe roles
-- ===========================================================================
select pg_temp.run('c1_probe_staff', 'authenticated', '00000000-0000-4000-8000-5b2100000001', $q$select public.is_staff('00000000-0000-4000-8000-5b2100000003')::text$q$);
select pg_temp.expect('c1_probe_staff', 'false', 'CUSTOMER: asking is_staff() about the staff user returns false');
select pg_temp.run('c1_probe_admin', 'authenticated', '00000000-0000-4000-8000-5b2100000001', $q$select public.has_role('00000000-0000-4000-8000-5b2100000004','admin')::text$q$);
select pg_temp.expect('c1_probe_admin', 'false', 'CUSTOMER: asking has_role(admin) about the admin returns false');
select pg_temp.run('c1_probe_admin2', 'authenticated', '00000000-0000-4000-8000-5b2100000001', $q$select public.is_admin('00000000-0000-4000-8000-5b2100000004')::text$q$);
select pg_temp.expect('c1_probe_admin2', 'false', 'CUSTOMER: asking is_admin() about the admin returns false');
select pg_temp.run('c1_self', 'authenticated', '00000000-0000-4000-8000-5b2100000001', $q$select public.is_staff('00000000-0000-4000-8000-5b2100000001')::text$q$);
select pg_temp.expect('c1_self', 'false', 'CUSTOMER: is_staff(self) is false');
select pg_temp.run('staff_self', 'authenticated', '00000000-0000-4000-8000-5b2100000003', $q$select public.is_staff('00000000-0000-4000-8000-5b2100000003')::text$q$);
select pg_temp.expect('staff_self', 'true', 'STAFF: is_staff(self) is true (RLS policies keep working)');
select pg_temp.run('staff_admin_self', 'authenticated', '00000000-0000-4000-8000-5b2100000003', $q$select public.is_admin('00000000-0000-4000-8000-5b2100000003')::text$q$);
select pg_temp.expect('staff_admin_self', 'false', 'STAFF: is_admin(self) is false');
select pg_temp.run('staff_probe_admin', 'authenticated', '00000000-0000-4000-8000-5b2100000003', $q$select public.is_admin('00000000-0000-4000-8000-5b2100000004')::text$q$);
select pg_temp.expect('staff_probe_admin', 'false', 'STAFF: cannot probe whether another user is admin');
select pg_temp.run('admin_self', 'authenticated', '00000000-0000-4000-8000-5b2100000004', $q$select (public.is_admin('00000000-0000-4000-8000-5b2100000004') and public.is_staff('00000000-0000-4000-8000-5b2100000004') and public.has_role('00000000-0000-4000-8000-5b2100000004','admin'))::text$q$);
select pg_temp.expect('admin_self', 'true', 'ADMIN: admin is admin and staff');
select pg_temp.run('svc_probe', 'service_role', null, $q$select public.is_staff('00000000-0000-4000-8000-5b2100000003')::text$q$);
select pg_temp.expect('svc_probe', 'true', 'FUNCTIONS: service_role can still check any user (server-side use)');

-- user_roles stays closed to writes from the browser
select pg_temp.run('c1_grant_self', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$with i as (insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-5b2100000001','admin') returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('c1_grant_self', '42501', null, 'CUSTOMER: cannot grant themselves a role');
select pg_temp.run('staff_grant_self', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with i as (insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-5b2100000003','admin') returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('staff_grant_self', '42501', null, 'STAFF: cannot grant themselves admin');

-- ===========================================================================
-- REGRESSION: create_order() pricing, stock and idempotency (COD pickup)
-- ===========================================================================
select pg_temp.place('o_base', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 2, p_idem => 't5b2-idem-1');
select pg_temp.ok(pg_temp.res('o_base') is not null, 'REGRESSION: create_order() places a pickup order');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'REGRESSION: stock reserved (20 - 2 = 18)');
select pg_temp.ok(
  (select subtotal_cents = 20000 and delivery_fee_cents = 0 and total_cents = 20000
          and status = 'pending' and payment_status = 'pending' and restocked_at is null
   from public.orders where id = pg_temp.res('o_base')::uuid),
  'REGRESSION: price comes from the database; COD order is pending / unpaid / stock held');
select pg_temp.ok(
  (select unit_price_cents = 10000 and line_total_cents = 20000 and quantity = 2
   from public.order_items where order_id = pg_temp.res('o_base')::uuid),
  'REGRESSION: order item is a server-priced snapshot');
select pg_temp.place('o_base_replay', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 2, p_idem => 't5b2-idem-1');
select pg_temp.ok(pg_temp.res('o_base_replay') = pg_temp.res('o_base') and pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18,
  'REGRESSION: idempotent replay returns the same order and reserves no extra stock');
select pg_temp.place('o_bad_total', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 1, p_expected => 1);
select pg_temp.expect_err('o_bad_total', 'P0001', null, 'REGRESSION: a client total that disagrees vetoes the order');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'REGRESSION: a rejected order leaves stock untouched');
select pg_temp.place('o_over', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 99);
select pg_temp.expect_err('o_over', 'P0001', null, 'REGRESSION: stock limit still enforced');

-- ===========================================================================
-- CUSTOMER: cannot change status, mark paid/refunded, or touch another customer's order
-- ===========================================================================
select pg_temp.run('c1_upd_status', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  format($q$with u as (update public.orders set status = 'cancelled' where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c1_upd_status', '42501', null, 'CUSTOMER: cannot UPDATE own order status');
select pg_temp.run('c1_upd_paid', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  format($q$with u as (update public.orders set status = 'paid', payment_status = 'paid' where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c1_upd_paid', '42501', null, 'CUSTOMER: cannot mark own order paid');
select pg_temp.run('c1_upd_refunded', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  format($q$with u as (update public.orders set status = 'refunded' where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c1_upd_refunded', '42501', null, 'CUSTOMER: cannot mark own order refunded');
select pg_temp.run('c1_upd_total', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  format($q$with u as (update public.orders set total_cents = 1, subtotal_cents = 1 where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c1_upd_total', '42501', null, 'CUSTOMER: cannot rewrite order totals');
select pg_temp.run('c1_upd_restocked', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  format($q$with u as (update public.orders set restocked_at = now() where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c1_upd_restocked', '42501', null, 'CUSTOMER: cannot write restocked_at');
select pg_temp.set_status('c1_rpc', 'authenticated', '00000000-0000-4000-8000-5b2100000001', pg_temp.res('o_base'), 'cancelled');
select pg_temp.expect_err('c1_rpc', '42501', 'not_authorised', 'CUSTOMER: set_order_status() refuses a customer on their own order');
select pg_temp.set_status('c1_rpc_paid', 'authenticated', '00000000-0000-4000-8000-5b2100000001', pg_temp.res('o_base'), 'paid');
select pg_temp.expect_err('c1_rpc_paid', '42501', 'not_authorised', 'CUSTOMER: set_order_status(paid) refused for a customer');
select pg_temp.run('c2_sees', 'authenticated', '00000000-0000-4000-8000-5b2100000002',
  format($q$select count(*)::text from public.orders where id = %L$q$, pg_temp.res('o_base')));
select pg_temp.expect('c2_sees', '0', 'CUSTOMER: another customer cannot read the order');
select pg_temp.set_status('c2_rpc', 'authenticated', '00000000-0000-4000-8000-5b2100000002', pg_temp.res('o_base'), 'cancelled');
select pg_temp.expect_err('c2_rpc', '42501', 'not_authorised', 'CUSTOMER: another customer cannot cancel the order through the RPC');
select pg_temp.run('c2_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000002',
  format($q$with u as (update public.orders set status = 'cancelled' where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('c2_upd', '42501', null, 'CUSTOMER: another customer cannot UPDATE the order');
select pg_temp.ok(pg_temp.ostatus(pg_temp.res('o_base')) = 'pending', 'CUSTOMER: order status is unchanged after all of the above');

-- ===========================================================================
-- STAFF: cannot mark paid / refunded, workflow works, direct UPDATE is gone
-- ===========================================================================
select pg_temp.set_status('s_paid', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'paid');
select pg_temp.expect_err('s_paid', 'P0001', 'payment_state_reserved', 'STAFF: cannot mark an order paid');
select pg_temp.set_status('s_refunded', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'refunded');
select pg_temp.expect_err('s_refunded', 'P0001', 'payment_state_reserved', 'STAFF: cannot mark an order refunded');
select pg_temp.run('s_direct', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  format($q$with u as (update public.orders set status = 'paid' where id = %L returning 1) select count(*)::text from u$q$, pg_temp.res('o_base')));
select pg_temp.expect_err('s_direct', '42501', null, 'STAFF: direct UPDATE of orders.status is no longer possible');
select pg_temp.ok(pg_temp.ostatus(pg_temp.res('o_base')) = 'pending', 'STAFF: order is still pending after the refused attempts');

select pg_temp.run('s_read_all', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  format($q$select count(*)::text from public.orders where id = %L$q$, pg_temp.res('o_base')));
select pg_temp.expect('s_read_all', '1', 'STAFF: can still read all orders');

select pg_temp.set_status('s_skip', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'delivered');
select pg_temp.expect_err('s_skip', 'P0001', 'transition_not_allowed', 'STAFF: cannot skip steps (pending -> delivered)');

select pg_temp.set_status('s_step1', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'processing');
select pg_temp.expect('s_step1', 'processing', 'STAFF: pending -> processing');
select pg_temp.set_status('s_step2', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'picking');
select pg_temp.expect('s_step2', 'picking', 'STAFF: processing -> picking');
select pg_temp.set_status('s_step3', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'packed');
select pg_temp.expect('s_step3', 'packed', 'STAFF: picking -> packed');
select pg_temp.set_status('s_step4', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'dispatched');
select pg_temp.expect('s_step4', 'dispatched', 'STAFF: packed -> dispatched');
select pg_temp.set_status('s_step5', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'out_for_delivery');
select pg_temp.expect('s_step5', 'out_for_delivery', 'STAFF: dispatched -> out_for_delivery');
select pg_temp.set_status('s_step6', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'delivered');
select pg_temp.expect('s_step6', 'delivered', 'STAFF: out_for_delivery -> delivered');
select pg_temp.ok(
  (select count(*) = 7 and bool_and(changed_by is not null or new_status = 'pending')
   from public.order_status_history where order_id = pg_temp.res('o_base')::uuid),
  'STAFF: every step is recorded in order_status_history (placed + 6 changes)');
select pg_temp.ok(
  (select changed_by = '00000000-0000-4000-8000-5b2100000003' from public.order_status_history
   where order_id = pg_temp.res('o_base')::uuid and new_status = 'delivered'),
  'STAFF: history records which staff user made the change');
select pg_temp.set_status('s_back', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'pending');
select pg_temp.expect_err('s_back', 'P0001', 'transition_not_allowed', 'STAFF: cannot move a delivered order back');
select pg_temp.set_status('s_cancel_delivered', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'cancelled');
select pg_temp.expect_err('s_cancel_delivered', 'P0001', 'transition_not_allowed', 'STAFF: cannot cancel a delivered order');
select pg_temp.set_status('s_ghost', 'authenticated', '00000000-0000-4000-8000-5b2100000003', '00000000-0000-4000-8000-5b2f00000000', 'cancelled');
select pg_temp.expect_err('s_ghost', 'P0001', 'order_not_found', 'STAFF: unknown order is reported, not silently ignored');
select pg_temp.set_status('s_long', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_base'), 'cancelled', repeat('x', 401));
select pg_temp.expect_err('s_long', 'P0001', 'note_too_long', 'STAFF: over-long note is refused');

-- ===========================================================================
-- RESTOCKING: first cancellation restocks once; repeats and cycles cannot mint stock
-- ===========================================================================
select pg_temp.place('o_r', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 3);
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 15, 'RESTOCK: 3 units reserved (18 - 3 = 15)');
select pg_temp.set_status('r_cancel1', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_r'), 'cancelled');
select pg_temp.expect('r_cancel1', 'cancelled', 'RESTOCK: staff cancels the order');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'RESTOCK: first cancellation returns the stock (15 + 3 = 18)');
select pg_temp.ok((select restocked_at is not null from public.orders where id = pg_temp.res('o_r')::uuid),
  'RESTOCK: restocked_at is stamped');
-- Staff cannot reactivate, so the staff cancel -> pending -> cancel cycle is closed.
select pg_temp.set_status('r_reopen', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_r'), 'pending');
select pg_temp.expect_err('r_reopen', 'P0001', 'transition_not_allowed', 'RESTOCK/STAFF: staff cannot reactivate a cancelled order');
select pg_temp.set_status('r_cancel2', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_r'), 'cancelled');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'RESTOCK: a repeated cancel request restores nothing more (still 18)');

-- Lower-level paths that skip the RPC (service role / SQL editor): cycles stay balanced.
update public.orders set status = 'pending' where id = pg_temp.res('o_r')::uuid;
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 15, 'RESTOCK: reactivation re-reserves the stock (18 - 3 = 15)');
select pg_temp.ok((select restocked_at is null from public.orders where id = pg_temp.res('o_r')::uuid),
  'RESTOCK: reactivation clears restocked_at');
update public.orders set status = 'cancelled' where id = pg_temp.res('o_r')::uuid;
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'RESTOCK: cancelling again restores once (back to 18)');
update public.orders set status = 'pending' where id = pg_temp.res('o_r')::uuid;
update public.orders set status = 'cancelled' where id = pg_temp.res('o_r')::uuid;
update public.orders set status = 'pending' where id = pg_temp.res('o_r')::uuid;
update public.orders set status = 'cancelled' where id = pg_temp.res('o_r')::uuid;
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'RESTOCK: repeated cancel/reactivate cycles leave stock unchanged (18)');
update public.orders set status = 'refunded' where id = pg_temp.res('o_r')::uuid;
update public.orders set status = 'cancelled' where id = pg_temp.res('o_r')::uuid;
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'RESTOCK: cancelled -> refunded -> cancelled does not restock again (18)');

-- Variant stock follows the same rule.
select pg_temp.place('o_v', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 2, p_product => '00000000-0000-4000-8000-5b2200000003', p_variant => '00000000-0000-4000-8000-5b2200000011');
select pg_temp.ok(pg_temp.vstock('00000000-0000-4000-8000-5b2200000011') = 3, 'RESTOCK: variant stock reserved (5 - 2 = 3)');
select pg_temp.set_status('v_cancel', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_v'), 'cancelled');
select pg_temp.ok(pg_temp.vstock('00000000-0000-4000-8000-5b2200000011') = 5 and pg_temp.stock('00000000-0000-4000-8000-5b2200000003') = 10, 'RESTOCK: variant stock returned once, product stock untouched');
update public.orders set status = 'pending' where id = pg_temp.res('o_v')::uuid;
update public.orders set status = 'cancelled' where id = pg_temp.res('o_v')::uuid;
update public.orders set status = 'pending' where id = pg_temp.res('o_v')::uuid;
update public.orders set status = 'cancelled' where id = pg_temp.res('o_v')::uuid;
select pg_temp.ok(pg_temp.vstock('00000000-0000-4000-8000-5b2200000011') = 5, 'RESTOCK: variant cycles leave stock unchanged (5)');

-- A delivered order is never restocked by a later cancellation (no stock came back).
select pg_temp.ok((select restocked_at is null from public.orders where id = pg_temp.res('o_base')::uuid),
  'RESTOCK: a delivered order has no restocked_at');

-- Reactivation with not enough stock is refused and rolls back.
select pg_temp.place('o_low', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 3);
select pg_temp.set_status('low_cancel', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_low'), 'cancelled');
update public.products set stock_quantity = 1 where id = '00000000-0000-4000-8000-5b2200000001';
select pg_temp.set_status('low_reopen', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_low'), 'pending', 'customer wants it back');
select pg_temp.expect_err('low_reopen', 'P0001', 'reactivation_insufficient_stock', 'RESTOCK/ADMIN: reactivation without enough stock is refused');
select pg_temp.ok(pg_temp.ostatus(pg_temp.res('o_low')) = 'cancelled' and pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 1,
  'RESTOCK/ADMIN: the refused reactivation changed nothing');
update public.products set stock_quantity = 20 where id = '00000000-0000-4000-8000-5b2200000001';

-- ===========================================================================
-- ADMIN: documented manual override, tested
-- ===========================================================================
select pg_temp.place('o_a', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_qty => 2);
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'ADMIN: fixture order reserves 2 (20 - 2 = 18)');
select pg_temp.set_status('a_cancel', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_a'), 'cancelled');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 20, 'ADMIN: staff cancels, stock back to 20');
select pg_temp.set_status('a_nonote', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a'), 'pending');
select pg_temp.expect_err('a_nonote', 'P0001', 'admin_note_required', 'ADMIN: override without a reason is refused');
select pg_temp.set_status('a_shortnote', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a'), 'pending', 'ab');
select pg_temp.expect_err('a_shortnote', 'P0001', 'admin_note_required', 'ADMIN: override with a one-word reason is refused');
select pg_temp.set_status('a_paid', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a'), 'paid', 'trying to force it');
select pg_temp.expect_err('a_paid', 'P0001', 'payment_state_reserved', 'ADMIN: cannot mark an order paid either');
select pg_temp.set_status('a_refunded', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a'), 'refunded', 'trying to force it');
select pg_temp.expect_err('a_refunded', 'P0001', 'payment_state_reserved', 'ADMIN: cannot mark an order refunded either');
select pg_temp.set_status('a_reopen', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a'), 'pending', 'customer called, reinstating');
select pg_temp.expect('a_reopen', 'pending', 'ADMIN: documented override - reactivate a cancelled COD order with a reason');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 18, 'ADMIN: reactivation re-reserved the stock (18)');
select pg_temp.ok(
  (select note = 'Admin override: customer called, reinstating' and changed_by = '00000000-0000-4000-8000-5b2100000004'
   from public.order_status_history
   where order_id = pg_temp.res('o_a')::uuid and new_status = 'pending' and previous_status = 'cancelled'),
  'ADMIN: override is logged with the actor and an "Admin override:" note');
select pg_temp.set_status('a_cancel2', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_a'), 'cancelled');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 20, 'ADMIN/STAFF: cancelling after the override restocks once (20)');
select pg_temp.set_status('a_cancel3', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_a'), 'cancelled');
select pg_temp.ok(pg_temp.stock('00000000-0000-4000-8000-5b2200000001') = 20, 'ADMIN/STAFF: and not twice (20)');
-- Correcting a fulfilment status is also an override.
select pg_temp.place('o_a2', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick');
select pg_temp.set_status('a2_skip', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_a2'), 'packed');
select pg_temp.expect_err('a2_skip', 'P0001', 'transition_not_allowed', 'ADMIN/STAFF: staff cannot jump to packed');
select pg_temp.set_status('a2_skip_admin', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a2'), 'packed', 'picked offline, fixing record');
select pg_temp.expect('a2_skip_admin', 'packed', 'ADMIN: can correct a fulfilment status with a reason');
-- A refunded order (set by a future server process) cannot be pulled back by the browser.
update public.orders set status = 'refunded' where id = pg_temp.res('o_a2')::uuid;
select pg_temp.set_status('a2_unrefund', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a2'), 'pending', 'undo refund');
select pg_temp.expect_err('a2_unrefund', 'P0001', 'transition_not_allowed', 'ADMIN: cannot override out of refunded');

-- ===========================================================================
-- PAYMENT GATE: online orders cannot be fulfilled until payment_status = paid
-- ===========================================================================
select pg_temp.place('o_on', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_payment => 'mpesa');
select pg_temp.ok((select status = 'awaiting_payment' and payment_status = 'pending' from public.orders where id = pg_temp.res('o_on')::uuid),
  'PAYMENT: an M-Pesa order starts awaiting_payment / pending');
select pg_temp.set_status('on_s_proc', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_on'), 'processing');
select pg_temp.expect_err('on_s_proc', 'P0001', 'transition_not_allowed', 'PAYMENT: staff cannot start fulfilling an unpaid online order');
select pg_temp.set_status('on_a_proc', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_on'), 'processing', 'customer says they paid');
select pg_temp.expect_err('on_a_proc', 'P0001', 'payment_not_confirmed', 'PAYMENT: even an admin override cannot fulfil an unpaid online order');
select pg_temp.set_status('on_a_pend', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_on'), 'pending', 'wrong label');
select pg_temp.expect_err('on_a_pend', 'P0001', 'payment_method_mismatch', 'PAYMENT: "pending" is reserved for cash on delivery');
select pg_temp.set_status('on_cancel', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_on'), 'cancelled');
select pg_temp.expect('on_cancel', 'cancelled', 'PAYMENT: staff can cancel an unpaid online order');
select pg_temp.set_status('on_reopen', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_on'), 'awaiting_payment', 'customer retrying payment');
select pg_temp.expect('on_reopen', 'awaiting_payment', 'PAYMENT: admin can reopen a cancelled online order as awaiting_payment');
select pg_temp.set_status('cod_await', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('o_a2'), 'awaiting_payment', 'x-check');
select pg_temp.expect_err('cod_await', 'P0001', 'transition_not_allowed', 'PAYMENT: (refunded stays untouchable)');
-- A future verified server process (service role / SQL) confirms payment; the workflow then proceeds.
update public.orders set payment_status = 'paid', status = 'paid' where id = pg_temp.res('o_on')::uuid;
select pg_temp.set_status('on_paid_proc', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('o_on'), 'processing');
select pg_temp.expect('on_paid_proc', 'processing', 'PAYMENT: once a server marks it paid, staff can fulfil it');

-- ===========================================================================
-- STAFF vs ADMIN: configuration writes
-- ===========================================================================
select pg_temp.run('s_fee_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with u as (update public.delivery_zone_fees set fee_cents = 0 where id = '00000000-0000-4000-8000-5b2500000002' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('s_fee_upd', '42501', null, 'STAFF: cannot change a zone fee (6F.4: no UPDATE privilege)');
select pg_temp.run('s_fee_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with i as (insert into public.delivery_zone_fees (zone_id, method_code, fee_cents) values ('00000000-0000-4000-8000-5b2300000004','tb2_addr',0) returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('s_fee_ins', '42501', null, 'STAFF: cannot add a zone fee');
select pg_temp.run('s_zone_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with i as (insert into public.delivery_zones (code, name) values ('t5b2-staff-zone','x') returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('s_zone_ins', '42501', null, 'STAFF: cannot add a delivery zone');
select pg_temp.run('s_zone_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with u as (update public.delivery_zones set is_active = false where id = '00000000-0000-4000-8000-5b2300000001' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('s_zone_upd', '42501', null, 'STAFF: cannot (de)activate a zone (6F.4: no UPDATE privilege)');
select pg_temp.run('s_method_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with u as (update public.delivery_methods set base_fee_cents = 0 where code = 'tb2_addr' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('s_method_upd', '42501', null, 'STAFF: cannot change a delivery method fee (6F.4: no UPDATE privilege)');
select pg_temp.run('s_method_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with i as (insert into public.delivery_methods (code, label) values ('tb2_staff','x') returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('s_method_ins', '42501', null, 'STAFF: cannot add a delivery method');
select pg_temp.run('s_slot_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$with u as (update public.delivery_slot_templates set capacity = 999 where id = '00000000-0000-4000-8000-5b2600000001' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('s_slot_upd', '42501', null, 'STAFF: cannot change slot capacity (6F.4: no UPDATE privilege)');
select pg_temp.run('s_override_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  format($q$with i as (insert into public.delivery_slot_overrides (template_id, slot_date, capacity) values ('00000000-0000-4000-8000-5b2600000001', %L, 999) returning 1) select count(*)::text from i$q$, pg_temp.d(5)));
select pg_temp.expect_err('s_override_ins', '42501', null, 'STAFF: cannot add a slot override');
select pg_temp.run('s_read_inactive', 'authenticated', '00000000-0000-4000-8000-5b2100000003',
  $q$select count(*)::text from public.delivery_zones where id = '00000000-0000-4000-8000-5b2300000003'$q$);
select pg_temp.expect('s_read_inactive', '1', 'STAFF: can still READ inactive delivery configuration');
select pg_temp.run('c_fee_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$with u as (update public.delivery_zone_fees set fee_cents = 0 where id = '00000000-0000-4000-8000-5b2500000002' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('c_fee_upd', '42501', null, 'CUSTOMER: cannot change a zone fee (6F.4: no UPDATE privilege)');
select pg_temp.run('c_read_inactive', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$select count(*)::text from public.delivery_zones where id = '00000000-0000-4000-8000-5b2300000003'$q$);
select pg_temp.expect('c_read_inactive', '0', 'CUSTOMER: cannot read inactive delivery zones');

select pg_temp.run('a_fee_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000004',
  $q$with u as (update public.delivery_zone_fees set fee_cents = 5000 where id = '00000000-0000-4000-8000-5b2500000002' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('a_fee_upd', '42501', null, 'ADMIN: cannot change a zone fee directly (6F.4: use admin_save_delivery_zone_fee)');
select pg_temp.run('a_zone_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000004',
  $q$with i as (insert into public.delivery_zones (code, name, county) values ('t5b2-admin-zone','admin zone','T5B2-Admin') returning 1) select count(*)::text from i$q$);
select pg_temp.expect_err('a_zone_ins', '42501', null, 'ADMIN: cannot add a zone directly (6F.4: use admin_save_delivery_zone)');
select pg_temp.run('a_method_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000004',
  $q$with u as (update public.delivery_methods set base_fee_cents = 30000 where code = 'tb2_addr' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('a_method_upd', '42501', null, 'ADMIN: cannot change a method directly (6F.4: use admin_update_delivery_method)');
select pg_temp.run('a_slot_upd', 'authenticated', '00000000-0000-4000-8000-5b2100000004',
  $q$with u as (update public.delivery_slot_templates set capacity = 1 where id = '00000000-0000-4000-8000-5b2600000001' returning 1) select count(*)::text from u$q$);
select pg_temp.expect_err('a_slot_upd', '42501', null, 'ADMIN: cannot change slot capacity directly (6F.4: use admin_save_delivery_slot_template)');
select pg_temp.run('a_override_ins', 'authenticated', '00000000-0000-4000-8000-5b2100000004',
  format($q$with i as (insert into public.delivery_slot_overrides (template_id, slot_date, capacity) values ('00000000-0000-4000-8000-5b2600000001', %L, 1) returning 1) select count(*)::text from i$q$, pg_temp.d(6)));
select pg_temp.expect_err('a_override_ins', '42501', null, 'ADMIN: cannot add a slot override directly (6F.4: use admin_save_delivery_slot_override)');

-- ===========================================================================
-- DELIVERY: zone must cover the customer's address; the fee follows the validated zone
-- ===========================================================================
select pg_temp.ok(public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000001', 'T5B2-Alpha', 'Westlands'), 'DELIVERY: zone Alpha covers Westlands, T5B2-Alpha');
select pg_temp.ok(public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000001', ' t5b2-alpha ', 'WESTLANDS'), 'DELIVERY: matching ignores case and whitespace');
select pg_temp.ok(not public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000001', 'T5B2-Beta', 'Westlands'), 'DELIVERY: wrong county does not match');
select pg_temp.ok(not public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000001', 'T5B2-Alpha', 'Nyali'), 'DELIVERY: wrong town does not match');
select pg_temp.ok(not public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000004', 'T5B2-Alpha', 'Westlands'), 'DELIVERY: a zone with no county and no towns covers nothing');
select pg_temp.ok(not public.delivery_zone_covers_address('00000000-0000-4000-8000-5b2300000003', 'T5B2-Alpha', 'Westlands'), 'DELIVERY: an inactive zone covers nothing');

-- Valid combination, with the zone the client chose
select pg_temp.place('d_ok', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000001', p_zone => '00000000-0000-4000-8000-5b2300000001', p_expected => 25000);
select pg_temp.ok(pg_temp.res('d_ok') is not null, 'DELIVERY: valid address + matching zone places an order');
select pg_temp.ok(
  (select delivery_fee_cents = 15000 and total_cents = 25000 and delivery_zone_code = 't5b2-alpha'
          and delivery_zone_id = '00000000-0000-4000-8000-5b2300000001' and delivery_address->>'city' = 'Westlands'
   from public.orders where id = pg_temp.res('d_ok')::uuid),
  'DELIVERY: fee 15000 is the validated zone''s fee; zone and address are snapshotted');

-- The cheap-zone attack
select pg_temp.place('d_cheap', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000001', p_zone => '00000000-0000-4000-8000-5b2300000002');
select pg_temp.expect_err('d_cheap', 'P0001', 'zone_address_mismatch', 'DELIVERY/CUSTOMER: cannot pick the cheaper Beta zone for a Westlands address');
select pg_temp.place('d_nogeo', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000001', p_zone => '00000000-0000-4000-8000-5b2300000004');
select pg_temp.expect_err('d_nogeo', 'P0001', 'zone_address_mismatch', 'DELIVERY/CUSTOMER: cannot pick a zone that has no geography');
select pg_temp.place('d_inactive', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000001', p_zone => '00000000-0000-4000-8000-5b2300000003');
select pg_temp.expect_err('d_inactive', 'P0001', 'zone_inactive', 'DELIVERY/CUSTOMER: cannot pick an inactive zone');
select pg_temp.place('d_unknown', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000001', p_zone => '00000000-0000-4000-8000-5b2f00000001');
select pg_temp.expect_err('d_unknown', 'P0001', 'zone_unknown', 'DELIVERY/CUSTOMER: cannot invent a zone id');
select pg_temp.place('d_badaddr', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000004', p_zone => '00000000-0000-4000-8000-5b2300000001');
select pg_temp.expect_err('d_badaddr', 'P0001', 'zone_address_mismatch', 'DELIVERY/CUSTOMER: an address outside Alpha cannot use zone Alpha');
select pg_temp.place('d_other', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000006', p_zone => '00000000-0000-4000-8000-5b2300000001');
select pg_temp.expect_err('d_other', 'P0001', null, 'DELIVERY/CUSTOMER: cannot use another customer''s address');

-- Zone derived from the address when none is sent
select pg_temp.place('d_derive', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000002');
select pg_temp.ok(
  (select delivery_zone_code = 't5b2-gamma' and delivery_fee_cents = 20000
   from public.orders where id = pg_temp.res('d_derive')::uuid),
  'DELIVERY: with no zone sent, the single covering zone (Gamma) is derived and its fee used');
select pg_temp.place('d_spaced', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000005');
select pg_temp.ok(
  (select delivery_zone_code = 't5b2-alpha' from public.orders where id = pg_temp.res('d_spaced')::uuid),
  'DELIVERY: derivation ignores case and padding in the address');
select pg_temp.place('d_ambig', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000003');
select pg_temp.expect_err('d_ambig', 'P0001', 'zone_required', 'DELIVERY: two covering zones and none chosen -> zone_required');
select pg_temp.place('d_ambig_ok', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000003', p_zone => '00000000-0000-4000-8000-5b2300000006');
select pg_temp.ok(
  (select delivery_zone_code = 't5b2-gamma2' and delivery_fee_cents = 22000
   from public.orders where id = pg_temp.res('d_ambig_ok')::uuid),
  'DELIVERY: with two covering zones, the chosen one is accepted and priced');
select pg_temp.place('d_none', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_address => '00000000-0000-4000-8000-5b2400000004');
select pg_temp.expect_err('d_none', 'P0001', 'zone_unserviceable', 'DELIVERY: an address no zone covers -> zone_unserviceable');
select pg_temp.place('d_noaddr', '00000000-0000-4000-8000-5b2100000001', 'tb2_addr', p_zone => '00000000-0000-4000-8000-5b2300000001');
select pg_temp.expect_err('d_noaddr', 'P0001', null, 'DELIVERY: address delivery without an address is refused');

-- A zone sent with a no-address method is ignored (cannot drag a zone fee rule into pickup)
select pg_temp.place('d_pick_zone', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_zone => '00000000-0000-4000-8000-5b2300000002');
select pg_temp.ok(
  (select delivery_fee_cents = 0 and delivery_zone_id is null and delivery_address is null
   from public.orders where id = pg_temp.res('d_pick_zone')::uuid),
  'DELIVERY: a valid zone sent with pickup is not used (fee 0, no zone, no address)');

select pg_temp.place('d_pick_zone_unknown', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_zone => '00000000-0000-4000-8000-5b2f00000001');
select pg_temp.expect_err('d_pick_zone_unknown', 'P0001', 'zone_unknown', 'DELIVERY: an unknown zone sent with pickup is still rejected (existing behaviour kept)');
select pg_temp.place('d_pick_zone_off', '00000000-0000-4000-8000-5b2100000001', 'tb2_pick', p_zone => '00000000-0000-4000-8000-5b2300000003');
select pg_temp.expect_err('d_pick_zone_off', 'P0001', 'zone_inactive', 'DELIVERY: an inactive zone sent with pickup is still rejected');

-- Rejected delivery orders reserved no stock
select pg_temp.ok(
  (select count(*) = 0 from public.orders
   where user_id = '00000000-0000-4000-8000-5b2100000001' and delivery_method = 'tb2_addr'
     and id::text not in (pg_temp.res('d_ok'), pg_temp.res('d_derive'), pg_temp.res('d_spaced'), pg_temp.res('d_ambig_ok'))),
  'DELIVERY: rejected selections created no orders');

-- ===========================================================================
-- INACTIVE DATA: validate_cart / validate_delivery_selection
-- ===========================================================================
select pg_temp.run('vc_off', 'anon', null,
  $q$select count(*)::text from public.validate_cart(jsonb_build_array(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2200000002','variant_id',null,'quantity',1)))$q$);
select pg_temp.expect('vc_off', '0', 'INACTIVE: validate_cart() returns nothing for an inactive product (no name, price or stock leaks)');
select pg_temp.run('vc_unknown', 'anon', null,
  $q$select count(*)::text from public.validate_cart(jsonb_build_array(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2f00000009','variant_id',null,'quantity',1)))$q$);
select pg_temp.expect('vc_unknown', '0', 'INACTIVE: an unknown product looks exactly like an inactive one');
select pg_temp.run('vc_voff', 'anon', null,
  $q$select (available::text || '/' || reason || '/' || coalesce(unit_price_cents::text,'null') || '/' || coalesce(stock_quantity::text,'null'))
     from public.validate_cart(jsonb_build_array(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2200000003','variant_id','00000000-0000-4000-8000-5b2200000012','quantity',1)))$q$);
select pg_temp.expect('vc_voff', 'false/variant_unavailable/null/null', 'INACTIVE: inactive variant is not purchasable and returns no price or stock');
select pg_temp.run('vc_ok', 'anon', null,
  $q$select (available::text || '/' || reason || '/' || unit_price_cents::text)
     from public.validate_cart(jsonb_build_array(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2200000001','variant_id',null,'quantity',1)))$q$);
select pg_temp.expect('vc_ok', 'true/ok/10000', 'INACTIVE/REGRESSION: an active product still validates with its server price');
select pg_temp.run('vc_vok', 'anon', null,
  $q$select (available::text || '/' || unit_price_cents::text || '/' || variant_id::text)
     from public.validate_cart(jsonb_build_array(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2200000003','variant_id','00000000-0000-4000-8000-5b2200000011','quantity',1)))$q$);
select pg_temp.expect('vc_vok', 'true/2500/00000000-0000-4000-8000-5b2200000011', 'INACTIVE/REGRESSION: an active variant validates with its price; the row carries the caller''s variant id');

select pg_temp.run('vd_off', 'anon', null,
  $q$select (is_valid::text || '/' || error_code || '/' || coalesce(method_label, 'null')) from public.validate_delivery_selection('tb2_off', null, 10000)$q$);
select pg_temp.expect('vd_off', 'false/method_inactive/null', 'INACTIVE: an inactive delivery method does not validate and its label is not returned');
select pg_temp.run('vd_unknown', 'anon', null,
  $q$select (is_valid::text || '/' || error_code) from public.validate_delivery_selection('tb2_nope', null, 10000)$q$);
select pg_temp.expect('vd_unknown', 'false/method_unknown', 'INACTIVE: an unknown method does not validate');
select pg_temp.run('vd_zoff', 'anon', null,
  $q$select (is_valid::text || '/' || error_code || '/' || coalesce(zone_name, 'null') || '/' || coalesce(zone_code, 'null') || '/' || coalesce(fee_cents::text, 'null'))
     from public.validate_delivery_selection('tb2_addr', '00000000-0000-4000-8000-5b2300000003', 10000)$q$);
select pg_temp.expect('vd_zoff', 'false/zone_inactive/null/null/null', 'INACTIVE: an inactive zone does not validate; no name, code or fee is returned');
select pg_temp.run('vd_ok', 'anon', null,
  $q$select (is_valid::text || '/' || fee_cents::text || '/' || method_label || '/' || zone_code)
     from public.validate_delivery_selection('tb2_addr', '00000000-0000-4000-8000-5b2300000001', 10000)$q$);
select pg_temp.expect('vd_ok', 'true/15000/T5B2 address delivery/t5b2-alpha', 'REGRESSION: an active method + zone still validates with the zone fee');
select pg_temp.run('vd_nozone', 'anon', null,
  $q$select (is_valid::text || '/' || error_code) from public.validate_delivery_selection('tb2_addr', null, 10000)$q$);
select pg_temp.expect('vd_nozone', 'false/zone_required', 'REGRESSION: address delivery without a zone still reports zone_required to the quote');
select pg_temp.run('vd_fee', 'anon', null,
  $q$select fee_cents::text from public.resolve_delivery_fee('tb2_addr', '00000000-0000-4000-8000-5b2300000002', 10000)$q$);
select pg_temp.expect('vd_fee', '5000', 'REGRESSION: resolve_delivery_fee() still works for anon');
select pg_temp.run('cart_cap', 'anon', null,
  $q$select count(*)::text from public.validate_cart((select jsonb_agg(jsonb_build_object('product_id','00000000-0000-4000-8000-5b2200000001','variant_id',null,'quantity',1)) from generate_series(1,101)))$q$);
select pg_temp.expect_err('cart_cap', 'P0001', null, 'INACTIVE: validate_cart() refuses more than 100 lines');
select pg_temp.run('slot_avail', 'anon', null,
  format($q$select count(*)::text from public.get_delivery_slot_availability(%L, %L)$q$, pg_temp.d(1), pg_temp.d(3)));
select pg_temp.ok(pg_temp.res('slot_avail') is not null and (select err is null from t_res where k = 'slot_avail'),
  'REGRESSION: get_delivery_slot_availability() still works for anon');

-- ===========================================================================
-- TRIGGERS still work for roles that lost EXECUTE on the trigger functions
-- ===========================================================================
select pg_temp.ok(
  (select count(*) = 4 from public.profiles where id::text like '00000000-0000-4000-8000-5b21%'),
  'TRIGGERS: handle_new_user() created a profile for each new auth user');
update auth.users set email = 't5b2-customer1-new@example.test' where id = '00000000-0000-4000-8000-5b2100000001';
select pg_temp.ok(
  (select email = 't5b2-customer1-new@example.test' from public.profiles where id = '00000000-0000-4000-8000-5b2100000001'),
  'TRIGGERS: handle_user_email_change() still syncs profiles.email');
select pg_temp.run('trg_profile', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$with u as (update public.profiles set full_name = 'T5B2 Name' where id = '00000000-0000-4000-8000-5b2100000001' returning 1) select count(*)::text from u$q$);
select pg_temp.expect('trg_profile', '1', 'TRIGGERS: a customer can update their profile (set_updated_at trigger fires)');
select pg_temp.run('trg_addr1', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$with u as (update public.addresses set is_default = true where id = '00000000-0000-4000-8000-5b2400000001' returning 1) select count(*)::text from u$q$);
select pg_temp.expect('trg_addr1', '1', 'TRIGGERS: a customer can set a default address');
select pg_temp.run('trg_addr2', 'authenticated', '00000000-0000-4000-8000-5b2100000001',
  $q$with u as (update public.addresses set is_default = true where id = '00000000-0000-4000-8000-5b2400000002' returning 1) select count(*)::text from u$q$);
select pg_temp.expect('trg_addr2', '1', 'TRIGGERS: and move the default (addresses_single_default fires)');
select pg_temp.ok(
  (select count(*) = 1 and bool_and(id = '00000000-0000-4000-8000-5b2400000002')
   from public.addresses where user_id = '00000000-0000-4000-8000-5b2100000001' and is_default),
  'TRIGGERS: exactly one default address remains');

-- The reactivation capacity guard (migration 070000) still coexists with the new restock trigger.
select pg_temp.place('sl_1', '00000000-0000-4000-8000-5b2100000001', 'tb2_slot', p_slot_date => pg_temp.d(3), p_slot_start => '03:00', p_slot_end => '03:30');
select pg_temp.ok(pg_temp.res('sl_1') is not null, 'REGRESSION: a slot order is accepted while the slot has room');
select pg_temp.place('sl_2', '00000000-0000-4000-8000-5b2100000001', 'tb2_slot', p_slot_date => pg_temp.d(3), p_slot_start => '03:00', p_slot_end => '03:30');
select pg_temp.expect_err('sl_2', 'P0001', 'slot_full', 'REGRESSION: a full slot still rejects new orders');
select pg_temp.set_status('sl_cancel', 'authenticated', '00000000-0000-4000-8000-5b2100000003', pg_temp.res('sl_1'), 'cancelled');
select pg_temp.place('sl_3', '00000000-0000-4000-8000-5b2100000001', 'tb2_slot', p_slot_date => pg_temp.d(3), p_slot_start => '03:00', p_slot_end => '03:30');
select pg_temp.ok(pg_temp.res('sl_3') is not null, 'REGRESSION: cancelling frees the slot');
select pg_temp.set_status('sl_reopen', 'authenticated', '00000000-0000-4000-8000-5b2100000004', pg_temp.res('sl_1'), 'pending', 'slot check');
select pg_temp.expect_err('sl_reopen', 'P0001', 'reactivation_slot_full', 'REGRESSION: reactivating into a full slot is still refused (capacity guard)');
select pg_temp.ok(pg_temp.ostatus(pg_temp.res('sl_1')) = 'cancelled'
                  and (select restocked_at is not null from public.orders where id = pg_temp.res('sl_1')::uuid),
  'REGRESSION: the refused reactivation rolled back, including the stock re-reservation');

-- ===========================================================================
-- RLS and Phase 5A.2-style privilege baseline
-- (Phase 5A.2's own files were not available when this test was written, so these are
--  generic invariants that must hold under any sane hardening. Extend with 5A.2's checks.)
-- ===========================================================================
select pg_temp.ok(
  not exists (
    select 1 from pg_class c
    where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                    'public.order_status_history'::regclass, 'public.user_roles'::regclass,
                    'public.profiles'::regclass, 'public.addresses'::regclass,
                    'public.delivery_methods'::regclass, 'public.delivery_zones'::regclass,
                    'public.delivery_zone_fees'::regclass, 'public.delivery_slot_templates'::regclass,
                    'public.delivery_slot_overrides'::regclass, 'public.products'::regclass,
                    'public.product_variants'::regclass, 'public.categories'::regclass)
      and not c.relrowsecurity),
  'RLS: row level security is still enabled on every protected table');
select pg_temp.ok(
  exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and policyname = 'Orders: read own')
  and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and policyname = 'Orders: staff read all')
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and cmd in ('UPDATE', 'ALL', 'INSERT', 'DELETE')),
  'RLS: customers read own orders, staff read all, and nobody has a write policy on orders');
select pg_temp.ok(
  not exists (select 1 from pg_policies
              where schemaname = 'public'
                and tablename in ('delivery_methods', 'delivery_zones', 'delivery_zone_fees',
                                  'delivery_slot_templates', 'delivery_slot_overrides')
                and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
                and (coalesce(qual, '') || coalesce(with_check, '')) like '%is_staff%'),
  'RLS: no delivery-configuration write policy is still staff-level');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.orders', 'SELECT')
  and not has_table_privilege('anon', 'public.order_items', 'SELECT')
  and not has_table_privilege('anon', 'public.user_roles', 'SELECT')
  and not has_table_privilege('anon', 'public.addresses', 'SELECT')
  and not has_table_privilege('anon', 'public.profiles', 'SELECT'),
  'PRIVILEGES: anon has no access to orders, items, roles, addresses or profiles');
select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.orders', 'INSERT')
  and not has_table_privilege('authenticated', 'public.orders', 'DELETE')
  and not has_table_privilege('authenticated', 'public.order_items', 'INSERT')
  and not has_any_column_privilege('authenticated', 'public.order_items', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.order_items', 'DELETE')
  and not has_table_privilege('authenticated', 'public.user_roles', 'INSERT')
  and not has_any_column_privilege('authenticated', 'public.user_roles', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.user_roles', 'DELETE')
  and not has_table_privilege('authenticated', 'public.order_status_history', 'INSERT')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('anon', 'public.orders', 'UPDATE'),
  'PRIVILEGES: authenticated cannot write orders, items, history or roles; no UPDATE on any orders column');

do $$ begin raise notice 'ALL PHASE 5B.2 TESTS PASSED'; end $$;

rollback;
