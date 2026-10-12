-- =============================================================================
-- PHASE 6A database test: admin operations foundation.
--
-- STATUS: written for migration 20261004010000_phase6a_admin_operations_foundation.sql.
-- Run only on a throwaway local PostgreSQL 16 with a Supabase-style shim. NOT run against the
-- dedicated Phase-5 development Supabase database.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004010000_phase6a_admin_operations_foundation.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6a_admin_operations_foundation.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6A TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST.
--
-- DATABASE NOT EMPTY? Dashboard numbers are asserted as DELTAS from a snapshot taken before the
-- fixtures exist, and cross-checked against independent owner-level SQL, so existing data in a
-- dev database does not break the test.
--
-- WRITE ATTEMPTS: depending on table grants a browser-role write fails with 42501 (no privilege,
-- or an RLS violation on INSERT) or matches 0 rows (RLS filter on UPDATE/DELETE). Both are
-- "blocked"; each such check ALSO re-reads the row as the owner to prove nothing changed.
--
-- Fixtures use the marker 'T6A' and UUIDs ending in 6a... .
-- =============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Helpers (pg_temp: gone at the end of the session)
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

create temp table t_res (k text primary key, res text, err text, state text, detail text);

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

-- Same as run(), but the JWT carries extra claims (to prove claims other than the verified
-- `sub` cannot grant admin access).
create or replace function pg_temp.run_claims(p_k text, p_role text, p_claims jsonb, p_sql text)
returns void language plpgsql as $$
declare
  v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims', p_claims::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_claims ->> 'sub', ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_claims ->> 'role', ''), true);
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

create or replace function pg_temp.j(p_k text) returns jsonb language sql as $$
  select res::jsonb from t_res where k = p_k $$;

-- numeric value at a JSON path of a recorded dashboard
create or replace function pg_temp.jn(p_k text, p_path text[]) returns numeric language sql as $$
  select (res::jsonb #>> p_path)::numeric from t_res where k = p_k $$;

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

-- A write was blocked: SQLSTATE 42501, or it matched 0 rows. Never "succeeded".
create or replace function pg_temp.expect_blocked(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(
    (r.err is not null and r.state = '42501') or (r.err is null and r.res = '0'),
    p_name || ' [' || coalesce(r.state, 'no error') || ' / ' || coalesce(r.res, 'NULL') || ']');
end;
$$;

-- Fixture id helpers
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a100000000' || n)::uuid $$;      -- users 1..5
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a2000000' || lpad(n::text, 3, '0'))::uuid $$;   -- products
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a3000000' || lpad(n::text, 3, '0'))::uuid $$;   -- variants

create or replace function pg_temp.dash(p_k text, p_role text, p_uid uuid, p_recent integer, p_thr integer)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    format('select public.admin_dashboard_summary(%s, %s)::text', coalesce(p_recent::text, 'null'), coalesce(p_thr::text, 'null')));
end;
$$;

create or replace function pg_temp.place(
  p_k text, p_uid uuid, p_method text, p_payment text, p_product uuid, p_qty integer
) returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, 'authenticated', p_uid, format(
    $f$select public.create_order(
         jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'variant_id', null, 'quantity', %s)),
         %L, %L::public.payment_method, null, null, null, null, null, null, null, null, null)::text$f$,
    p_product, p_qty, p_method, p_payment));
end;
$$;

create or replace function pg_temp.set_status(p_k text, p_role text, p_uid uuid, p_order text, p_status text, p_note text default null)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format(
    'select public.set_order_status(%L::uuid, %L::public.order_status, %L)::text', p_order, p_status, p_note));
end;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures, step 1: the roles the dashboard needs before the baseline snapshot.
-- Admin 1 and the baseline exist BEFORE any customer/catalogue/order fixture.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(4), 't6a-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6A Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(4), 'admin');

-- Baseline dashboard (threshold 3). Also proves the function works on whatever data exists.
select pg_temp.dash('s0', 'authenticated', pg_temp.u(4), 5, 3);
select pg_temp.ok(pg_temp.res('s0') is not null, 'BASELINE: admin can call admin_dashboard_summary on the current data');

-- Fixtures, step 2: customers, staff, a second admin (the last two must NOT count as customers).
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6a-customer1@example.test', 'authenticated', 'authenticated', '{"full_name":"T6A Customer One"}'),
  (pg_temp.u(2), 't6a-customer2@example.test', 'authenticated', 'authenticated', '{"full_name":"T6A Customer Two"}'),
  (pg_temp.u(3), 't6a-staff@example.test',     'authenticated', 'authenticated', '{"full_name":"T6A Staff"}'),
  (pg_temp.u(5), 't6a-admin2@example.test',    'authenticated', 'authenticated', '{"full_name":"T6A Admin Two"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(3), 'staff'),
  (pg_temp.u(5), 'admin');

-- Catalogue: PA healthy, PB low (3 -> 2 after an order), PC out (0), PD out (flag), PE boundary (4),
-- PF inactive. Threshold in this test is 3.
insert into public.categories (id, slug, name, is_active) values
  ('00000000-0000-4000-8000-6a4000000001', 't6a-cat-off', 'T6A inactive category', false);

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active, sku) values
  (pg_temp.p(1), 't6a-pa', 'T6A PA healthy',   1000, 50, true,  true,  'T6A-PA'),
  (pg_temp.p(2), 't6a-pb', 'T6A PB low',       5000, 3,  true,  true,  'T6A-PB'),
  (pg_temp.p(3), 't6a-pc', 'T6A PC zero',      700,  0,  true,  true,  'T6A-PC'),
  (pg_temp.p(4), 't6a-pd', 'T6A PD flagged',   800,  50, false, true,  'T6A-PD'),
  (pg_temp.p(5), 't6a-pe', 'T6A PE boundary',  900,  4,  true,  true,  'T6A-PE'),
  (pg_temp.p(6), 't6a-pf', 'T6A PF inactive',  600,  1,  true,  false, 'T6A-PF');

-- Variants: V1 low(1) V2 out(0) V3 inactive(0) V4 healthy(5) on PA; V5 out(0) on inactive PF.
insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, is_active) values
  (pg_temp.v(1), pg_temp.p(1), 'T6A V1 low',      1100, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6A V2 zero',     1200, 0, true),
  (pg_temp.v(3), pg_temp.p(1), 'T6A V3 inactive', 1300, 0, false),
  (pg_temp.v(4), pg_temp.p(1), 'T6A V4 healthy',  1400, 5, true),
  (pg_temp.v(5), pg_temp.p(6), 'T6A V5 on inactive product', 1500, 0, true);

-- Delivery: a pickup method with no slot/address (orders via the real create_order), and zones.
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6a_pick', 'T6A pickup', 0, null, 0, false, false, true);

insert into public.delivery_zones (id, code, name, county, towns, position, is_active) values
  ('00000000-0000-4000-8000-6a5000000001', 't6a-zone',     'T6A active zone',   'T6A', '{Alpha}', 900, true),
  ('00000000-0000-4000-8000-6a5000000002', 't6a-zone-off', 'T6A inactive zone', 'T6A', '{Beta}',  901, false);

-- ===========================================================================
-- ORDERS through the real RPC, then real status changes
-- ===========================================================================
select pg_temp.place('o1', pg_temp.u(1), 't6a_pick', 'cash_on_delivery', pg_temp.p(1), 2);   -- 2000
select pg_temp.place('o2', pg_temp.u(1), 't6a_pick', 'mpesa',            pg_temp.p(1), 1);   -- 1000
select pg_temp.place('o3', pg_temp.u(2), 't6a_pick', 'cash_on_delivery', pg_temp.p(2), 1);   -- 5000
select pg_temp.place('o4', pg_temp.u(2), 't6a_pick', 'cash_on_delivery', pg_temp.p(1), 3);   -- 3000
select pg_temp.ok(
  (select count(*) from t_res where k in ('o1','o2','o3','o4') and err is null and res is not null) = 4,
  'FIXTURE: four orders placed through create_order()');

-- Staff drive real status changes through set_order_status().
select pg_temp.set_status('st3', 'authenticated', pg_temp.u(3), pg_temp.res('o3'), 'processing');
select pg_temp.set_status('st4', 'authenticated', pg_temp.u(3), pg_temp.res('o4'), 'cancelled');
select pg_temp.expect('st3', 'processing', 'FIXTURE: staff moved order 3 to processing');
select pg_temp.expect('st4', 'cancelled',  'FIXTURE: staff cancelled order 4');

-- Slot dates (owner-level; browser roles cannot touch orders): O1 today, O2 in 2 days, O4 (cancelled) today.
update public.orders set delivery_slot_date = (now() at time zone 'Africa/Nairobi')::date
  where id = pg_temp.res('o1')::uuid;
update public.orders set delivery_slot_date = (now() at time zone 'Africa/Nairobi')::date + 2
  where id = pg_temp.res('o2')::uuid;
update public.orders set delivery_slot_date = (now() at time zone 'Africa/Nairobi')::date
  where id = pg_temp.res('o4')::uuid;

-- ===========================================================================
-- A. DASHBOARD: admin sees correct data (deltas + independent cross-check)
-- ===========================================================================
select pg_temp.dash('s1', 'authenticated', pg_temp.u(4), 3, 3);
select pg_temp.dash('s1b', 'authenticated', pg_temp.u(5), 10, 3);   -- the second admin, defaults of recent

select pg_temp.ok(pg_temp.res('s1') is not null and (select err from t_res where k = 's1') is null,
  'ADMIN: admin calls admin_dashboard_summary successfully');
select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.j('s1'))) = 11
  and pg_temp.j('s1') ?& array['generated_at','time_zone','low_stock_threshold','orders','payments','delivery',
                               'products','variants','low_stock_items','customers','recent_orders'],
  'SHAPE: exactly the eleven documented top-level keys are present');
select pg_temp.ok(pg_temp.j('s1') ->> 'time_zone' = 'Africa/Nairobi' and pg_temp.jn('s1', array['low_stock_threshold']) = 3,
  'SHAPE: time zone and echoed threshold');

-- orders
select pg_temp.ok(
  pg_temp.jn('s1', array['orders','total']) - pg_temp.jn('s0', array['orders','total']) = 4
  and pg_temp.jn('s1', array['orders','total']) = (select count(*) from public.orders),
  'ORDERS: total grew by 4 and equals an independent count');
select pg_temp.ok(
  pg_temp.jn('s1', array['orders','by_status','pending'])          - pg_temp.jn('s0', array['orders','by_status','pending']) = 1
  and pg_temp.jn('s1', array['orders','by_status','awaiting_payment']) - pg_temp.jn('s0', array['orders','by_status','awaiting_payment']) = 1
  and pg_temp.jn('s1', array['orders','by_status','processing'])       - pg_temp.jn('s0', array['orders','by_status','processing']) = 1
  and pg_temp.jn('s1', array['orders','by_status','cancelled'])        - pg_temp.jn('s0', array['orders','by_status','cancelled']) = 1,
  'ORDERS: by_status deltas are pending +1, awaiting_payment +1, processing +1, cancelled +1');
select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.j('s1') #> array['orders','by_status']))
    = (select count(*) from unnest(enum_range(null::public.order_status)))
  and (select bool_and(pg_temp.jn('s1', array['orders','by_status', s::text]) = (select count(*) from public.orders o where o.status = s))
       from unnest(enum_range(null::public.order_status)) s),
  'ORDERS: by_status lists every enum value and each equals an independent count');
select pg_temp.ok(
  pg_temp.jn('s1', array['orders','gross_value_cents']) - pg_temp.jn('s0', array['orders','gross_value_cents']) = 8000
  and pg_temp.jn('s1', array['orders','gross_value_cents'])
      = (select coalesce(sum(total_cents), 0) from public.orders where status not in ('cancelled', 'refunded')),
  'ORDERS: gross value delta = 2000+1000+5000 (cancelled order excluded) and equals an independent sum');
select pg_temp.ok(
  pg_temp.jn('s1', array['orders','placed_today']) - pg_temp.jn('s0', array['orders','placed_today']) = 4,
  'ORDERS: placed_today grew by 4 (Africa/Nairobi day)');

-- payments: only what orders already record
select pg_temp.ok(
  pg_temp.jn('s1', array['payments','by_method','cash_on_delivery']) - pg_temp.jn('s0', array['payments','by_method','cash_on_delivery']) = 3
  and pg_temp.jn('s1', array['payments','by_method','mpesa']) - pg_temp.jn('s0', array['payments','by_method','mpesa']) = 1
  and pg_temp.jn('s1', array['payments','by_status','pending']) - pg_temp.jn('s0', array['payments','by_status','pending']) = 4
  and pg_temp.jn('s1', array['payments','by_status','paid']) = pg_temp.jn('s0', array['payments','by_status','paid']),
  'PAYMENTS: method and status counts follow the orders; no order became paid');
select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.j('s1') #> array['payments','by_status']))
    = (select count(*) from unnest(enum_range(null::public.payment_status)))
  and (select count(*) from jsonb_object_keys(pg_temp.j('s1') #> array['payments','by_method']))
    = (select count(*) from unnest(enum_range(null::public.payment_method))),
  'PAYMENTS: every payment_status and payment_method value is listed');
select pg_temp.ok(
  not (pg_temp.j('s1') -> 'payments') ?| array['transactions','provider','revenue','collected','refunds','webhook'],
  'PAYMENTS: the dashboard reports no invented payment concept (no transactions/revenue/provider keys)');

-- delivery
select pg_temp.ok(
  pg_temp.jn('s1', array['delivery','scheduled_today'])    - pg_temp.jn('s0', array['delivery','scheduled_today']) = 1
  and pg_temp.jn('s1', array['delivery','scheduled_upcoming']) - pg_temp.jn('s0', array['delivery','scheduled_upcoming']) = 1,
  'DELIVERY: scheduled_today +1 and scheduled_upcoming +1 (the cancelled order holding today is excluded)');
select pg_temp.ok(
  (select (e ->> 'orders')::integer from jsonb_array_elements(pg_temp.j('s1') #> array['delivery','by_method']) e
   where e ->> 'code' = 't6a_pick') = 3,
  'DELIVERY: by_method counts the 3 non-cancelled orders of the fixture method');
select pg_temp.ok(
  pg_temp.jn('s1', array['delivery','configuration','active_zones']) - pg_temp.jn('s0', array['delivery','configuration','active_zones']) = 1
  and pg_temp.jn('s1', array['delivery','configuration','active_zones']) = (select count(*) from public.delivery_zones where is_active)
  and pg_temp.jn('s1', array['delivery','configuration','active_methods']) = (select count(*) from public.delivery_methods where is_active)
  and pg_temp.jn('s1', array['delivery','configuration','active_slot_templates']) = (select count(*) from public.delivery_slot_templates where is_active),
  'DELIVERY: configuration counts equal independent counts (inactive zone not counted)');

-- products / variants
select pg_temp.ok(
  pg_temp.jn('s1', array['products','total'])        - pg_temp.jn('s0', array['products','total']) = 6
  and pg_temp.jn('s1', array['products','active'])   - pg_temp.jn('s0', array['products','active']) = 5
  and pg_temp.jn('s1', array['products','inactive']) - pg_temp.jn('s0', array['products','inactive']) = 1,
  'PRODUCTS: total +6, active +5, inactive +1 (admin sees inactive products)');
select pg_temp.ok(
  pg_temp.jn('s1', array['products','out_of_stock']) - pg_temp.jn('s0', array['products','out_of_stock']) = 2
  and pg_temp.jn('s1', array['products','low_stock']) - pg_temp.jn('s0', array['products','low_stock']) = 1,
  'PRODUCTS: out_of_stock +2 (zero stock, not-in-stock flag), low_stock +1 (stock 2 <= 3; stock 4 and inactive excluded)');
select pg_temp.ok(
  pg_temp.jn('s1', array['variants','total'])        - pg_temp.jn('s0', array['variants','total']) = 5
  and pg_temp.jn('s1', array['variants','active'])   - pg_temp.jn('s0', array['variants','active']) = 4
  and pg_temp.jn('s1', array['variants','out_of_stock']) - pg_temp.jn('s0', array['variants','out_of_stock']) = 1
  and pg_temp.jn('s1', array['variants','low_stock'])    - pg_temp.jn('s0', array['variants','low_stock']) = 1,
  'VARIANTS: total +5, active +4, out_of_stock +1, low_stock +1 (inactive variant / inactive parent excluded)');
select pg_temp.ok(
  (select stock_quantity from public.products where id = pg_temp.p(2)) = 2
  and (select stock_quantity from public.products where id = pg_temp.p(1)) = 47,
  'FIXTURE: stock after the orders is as the low-stock expectations assume (PB 3->2; PA 50-2-1-3+3 restock = 47)');

-- low-stock list: needs-attention items, out-of-stock before low-stock, then lowest quantity; at most 10
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('s1') -> 'low_stock_items') <= 10
  and (select coalesce(bool_and(
         (a.rk < a.next_rk) or (a.rk = a.next_rk and a.q <= a.next_q)), true)
       from (
         select case when e ->> 'state' = 'out_of_stock' then 0 else 1 end as rk,
                (e ->> 'stock_quantity')::integer as q,
                coalesce(lead(case when e ->> 'state' = 'out_of_stock' then 0 else 1 end) over (order by ord), 2) as next_rk,
                coalesce(lead((e ->> 'stock_quantity')::integer) over (order by ord), 2147483647) as next_q
         from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') with ordinality as t(e, ord)) a),
  'LOW STOCK: at most 10 items; out_of_stock before low_stock, then ascending quantity');
-- Attention-item membership is only deterministic when every item fits in the 10-row cap.
select pg_temp.ok(
  case
    when (select count(*) from public.products where is_active and (not in_stock or stock_quantity = 0 or stock_quantity between 1 and 3))
       + (select count(*) from public.product_variants v join public.products p on p.id = v.product_id
          where v.is_active and p.is_active and v.stock_quantity <= 3) > 10
      then true   -- existing data crowds the cap; shape/order already asserted above
    else
      (select count(*) from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e
        where e ->> 'name' like 'T6A %'
          and ((e ->> 'kind' = 'product' and e ->> 'name' in ('T6A PB low', 'T6A PC zero', 'T6A PD flagged'))
            or (e ->> 'kind' = 'variant' and e ->> 'variant_name' in ('T6A V1 low', 'T6A V2 zero')))) = 5
      and not exists (select 1 from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e
                      where e ->> 'name' in ('T6A PA healthy', 'T6A PE boundary', 'T6A PF inactive')
                        and e ->> 'variant_name' is null)
      and not exists (select 1 from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e
                      where e ->> 'variant_name' in ('T6A V3 inactive', 'T6A V4 healthy', 'T6A V5 on inactive product'))
  end,
  'LOW STOCK: PB, PC, PD, V1, V2 listed; healthy, boundary(4), inactive product/variant items are not');
select pg_temp.ok(
  case
    when (select count(*) from public.products where is_active and (not in_stock or stock_quantity = 0 or stock_quantity between 1 and 3))
       + (select count(*) from public.product_variants v join public.products p on p.id = v.product_id
          where v.is_active and p.is_active and v.stock_quantity <= 3) > 10
      then true   -- existing data crowds the 10-row cap; state labels cannot be asserted deterministically
    else
      (select e ->> 'state' from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e where e ->> 'name' = 'T6A PD flagged') = 'out_of_stock'
      and (select e ->> 'state' from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e where e ->> 'name' = 'T6A PC zero') = 'out_of_stock'
      and (select e ->> 'state' from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e where e ->> 'name' = 'T6A PB low') = 'low_stock'
      and (select e ->> 'state' from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e where e ->> 'variant_name' = 'T6A V1 low') = 'low_stock'
      and (select e ->> 'state' from jsonb_array_elements(pg_temp.j('s1') -> 'low_stock_items') e where e ->> 'variant_name' = 'T6A V2 zero') = 'out_of_stock'
  end,
  'LOW STOCK: states are correct (flagged/zero = out_of_stock, 1..threshold = low_stock)');

-- customers: the two customers count; staff and the second admin do not
select pg_temp.ok(
  pg_temp.jn('s1', array['customers','total']) - pg_temp.jn('s0', array['customers','total']) = 2
  and pg_temp.jn('s1', array['customers','new_last_30_days']) - pg_temp.jn('s0', array['customers','new_last_30_days']) = 2
  and pg_temp.jn('s1', array['customers','total'])
      = (select count(*) from public.profiles pr
         where not exists (select 1 from public.user_roles ur where ur.user_id = pr.id and ur.role in ('staff','admin'))),
  'CUSTOMERS: +2 (staff and admin accounts are not customers) and equals an independent count');

-- recent orders: newest first, limited, no private contact data
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('s1') -> 'recent_orders') = least(3, (select count(*) from public.orders))
  and pg_temp.j('s1') #>> array['recent_orders','0','order_number']
      = (select order_number from public.orders order by placed_at desc, id desc limit 1),
  'RECENT: limit honoured and the newest order comes first');
select pg_temp.ok(
  (select bool_and(
     (select array_agg(k order by k) from jsonb_object_keys(e) k)
     = array['currency','customer_name','delivery_method','id','order_number','payment_method','payment_status','placed_at','status','total_cents'])
   from jsonb_array_elements(pg_temp.j('s1') -> 'recent_orders') e),
  'RECENT: each recent order exposes exactly the display fields (no email, phone, address, notes, user_id)');
select pg_temp.ok(
  (select e ->> 'customer_name' from jsonb_array_elements(pg_temp.j('s1b') -> 'recent_orders') e
   where e ->> 'id' = pg_temp.res('o1')) = 'T6A Customer One',
  'RECENT: customer name comes from the profile');
select pg_temp.ok(
  pg_temp.res('s1b') is not null and (select err from t_res where k = 's1b') is null,
  'ADMIN: a second admin (default-sized call) also succeeds');
select pg_temp.ok(
  (select provolatile from pg_proc where oid = 'public.admin_dashboard_summary(integer,integer)'::regprocedure) = 's'
  and (select provolatile from pg_proc where oid = 'public.require_admin()'::regprocedure) = 's',
  'FUNCTIONS: dashboard and admin gate are STABLE (cannot write)');

-- ===========================================================================
-- B. DASHBOARD: everyone who is not an admin is refused, on the database side
-- ===========================================================================
select pg_temp.dash('d_c1', 'authenticated', pg_temp.u(1), 5, 3);
select pg_temp.dash('d_st', 'authenticated', pg_temp.u(3), 5, 3);
select pg_temp.dash('d_an', 'anon', null, 5, 3);
select pg_temp.dash('d_sr', 'service_role', null, 5, 3);
select pg_temp.dash('d_unk', 'authenticated', gen_random_uuid(), 5, 3);
select pg_temp.expect_err('d_c1', '42501', 'not_authorised', 'DENIED: customer cannot read the admin dashboard');
select pg_temp.expect_err('d_st', '42501', 'not_authorised', 'DENIED: staff cannot read the admin dashboard');
select pg_temp.expect_err('d_an', '42501', null,             'DENIED: anon cannot execute the admin dashboard');
select pg_temp.expect_err('d_sr', '42501', 'not_authorised', 'DENIED: service_role without an admin user does not pass the admin gate');
select pg_temp.expect_err('d_unk','42501', 'not_authorised', 'DENIED: a signed-in user with no roles is refused');

-- Forged extra claims do not grant admin: only user_roles for the verified sub counts.
select pg_temp.run_claims('d_forge1', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin', 'roles', jsonb_build_array('admin'))),
  'select public.admin_dashboard_summary(5, 3)::text');
select pg_temp.expect_err('d_forge1', '42501', 'not_authorised', 'DENIED: customer with admin-looking JWT claims is still refused');
select pg_temp.run_claims('d_forge2', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'service_role'),
  'select public.admin_dashboard_summary(5, 3)::text');
select pg_temp.expect_err('d_forge2', '42501', 'not_authorised', 'DENIED: customer whose claims say service_role is refused (no admin row)');

-- The gate runs before argument checks, so a non-admin learns nothing about the arguments.
select pg_temp.dash('d_c1_bad', 'authenticated', pg_temp.u(1), 0, 3);
select pg_temp.expect_err('d_c1_bad', '42501', 'not_authorised', 'DENIED: customer with invalid arguments still gets not_authorised, not invalid_arguments');

-- Admin argument validation
select pg_temp.dash('a_r0',  'authenticated', pg_temp.u(4), 0, 3);
select pg_temp.dash('a_r51', 'authenticated', pg_temp.u(4), 51, 3);
select pg_temp.dash('a_tm1', 'authenticated', pg_temp.u(4), 5, -1);
select pg_temp.dash('a_t1001', 'authenticated', pg_temp.u(4), 5, 1001);
select pg_temp.dash('a_null', 'authenticated', pg_temp.u(4), null, null);
select pg_temp.dash('a_edge', 'authenticated', pg_temp.u(4), 50, 1000);
select pg_temp.dash('a_edge0', 'authenticated', pg_temp.u(4), 1, 0);
select pg_temp.expect_err('a_r0',    'P0001', 'invalid_arguments', 'ARGS: recent orders 0 rejected');
select pg_temp.expect_err('a_r51',   'P0001', 'invalid_arguments', 'ARGS: recent orders 51 rejected');
select pg_temp.expect_err('a_tm1',   'P0001', 'invalid_arguments', 'ARGS: negative threshold rejected');
select pg_temp.expect_err('a_t1001', 'P0001', 'invalid_arguments', 'ARGS: threshold 1001 rejected');
select pg_temp.expect_err('a_null',  'P0001', 'invalid_arguments', 'ARGS: nulls rejected');
select pg_temp.ok((select err from t_res where k = 'a_edge') is null and (select err from t_res where k = 'a_edge0') is null,
  'ARGS: boundary values 50/1000 and 1/0 are accepted');

-- Default arguments through the real call shape
select pg_temp.run('a_default', 'authenticated', pg_temp.u(4), 'select public.admin_dashboard_summary()::text');
select pg_temp.ok((select err from t_res where k = 'a_default') is null
  and pg_temp.jn('a_default', array['low_stock_threshold']) = 10
  and jsonb_array_length(pg_temp.j('a_default') -> 'recent_orders') = least(10, (select count(*) from public.orders)),
  'ARGS: defaults are recent=10, threshold=10');

-- The internal gate cannot be called by any browser role, admin included.
select pg_temp.run('g_admin', 'authenticated', pg_temp.u(4), 'select public.require_admin()::text');
select pg_temp.run('g_cust',  'authenticated', pg_temp.u(1), 'select public.require_admin()::text');
select pg_temp.run('g_anon',  'anon', null, 'select public.require_admin()::text');
select pg_temp.expect_err('g_admin', '42501', null, 'GATE: require_admin() is not callable directly, even by an admin');
select pg_temp.expect_err('g_cust',  '42501', null, 'GATE: require_admin() is not callable by a customer');
select pg_temp.expect_err('g_anon',  '42501', null, 'GATE: require_admin() is not callable by anon');

-- ===========================================================================
-- C. ADMIN READ ACCESS (new policies) and who does NOT get it
-- ===========================================================================
-- products (inactive PF), variants (inactive V3), categories (inactive), profiles
select pg_temp.run('r_pa', 'authenticated', pg_temp.u(4), format('select count(*)::text from public.products where id = %L', pg_temp.p(6)));
select pg_temp.run('r_ps', 'authenticated', pg_temp.u(3), format('select count(*)::text from public.products where id = %L', pg_temp.p(6)));
select pg_temp.run('r_pc', 'authenticated', pg_temp.u(1), format('select count(*)::text from public.products where id = %L', pg_temp.p(6)));
select pg_temp.run('r_pn', 'anon', null,                  format('select count(*)::text from public.products where id = %L', pg_temp.p(6)));
select pg_temp.expect('r_pa', '1', 'READ: admin sees an inactive product');
select pg_temp.expect('r_ps', '0', 'READ: staff do not see an inactive product');
select pg_temp.expect('r_pc', '0', 'READ: customer does not see an inactive product');
select pg_temp.expect('r_pn', '0', 'READ: anon does not see an inactive product');

select pg_temp.run('r_va', 'authenticated', pg_temp.u(4), format('select count(*)::text from public.product_variants where id in (%L, %L)', pg_temp.v(3), pg_temp.v(5)));
select pg_temp.run('r_vs', 'authenticated', pg_temp.u(3), format('select count(*)::text from public.product_variants where id in (%L, %L)', pg_temp.v(3), pg_temp.v(5)));
select pg_temp.run('r_vc', 'authenticated', pg_temp.u(1), format('select count(*)::text from public.product_variants where id in (%L, %L)', pg_temp.v(3), pg_temp.v(5)));
select pg_temp.expect('r_va', '2', 'READ: admin sees inactive variants (and variants of an inactive product)');
select pg_temp.expect('r_vs', '0', 'READ: staff do not see inactive variants');
select pg_temp.expect('r_vc', '0', 'READ: customer does not see inactive variants');

select pg_temp.run('r_ca', 'authenticated', pg_temp.u(4), $$select count(*)::text from public.categories where slug = 't6a-cat-off'$$);
select pg_temp.run('r_cs', 'authenticated', pg_temp.u(3), $$select count(*)::text from public.categories where slug = 't6a-cat-off'$$);
select pg_temp.run('r_cn', 'anon', null,                  $$select count(*)::text from public.categories where slug = 't6a-cat-off'$$);
select pg_temp.expect('r_ca', '1', 'READ: admin sees an inactive category');
select pg_temp.expect('r_cs', '0', 'READ: staff do not see an inactive category');
select pg_temp.expect('r_cn', '0', 'READ: anon does not see an inactive category');

select pg_temp.run('r_pra', 'authenticated', pg_temp.u(4), 'select count(*)::text from public.profiles');
select pg_temp.run('r_prs', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.profiles');
select pg_temp.run('r_prc', 'authenticated', pg_temp.u(1), 'select count(*)::text from public.profiles');
select pg_temp.run('r_prc2', 'authenticated', pg_temp.u(1), format('select count(*)::text from public.profiles where id = %L', pg_temp.u(2)));
select pg_temp.run('r_prn', 'anon', null, 'select count(*)::text from public.profiles');
select pg_temp.expect('r_pra', (select count(*)::text from public.profiles), 'READ: admin sees every profile');
select pg_temp.expect('r_prs', '1', 'READ: staff see only their own profile');
select pg_temp.expect('r_prc', '1', 'READ: a customer sees only their own profile');
select pg_temp.expect('r_prc2', '0', 'READ: customer 1 cannot read customer 2''s profile');
select pg_temp.ok((select err from t_res where k = 'r_prn') is not null or (select res from t_res where k = 'r_prn') = '0',
  'READ: anon cannot read profiles');

-- orders / items / history (existing Phase 5 behaviour, re-proved here)
select pg_temp.run('o_adm', 'authenticated', pg_temp.u(4), 'select count(*)::text from public.orders');
select pg_temp.run('o_stf', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.orders');
select pg_temp.run('o_c1',  'authenticated', pg_temp.u(1), 'select count(*)::text from public.orders');
select pg_temp.run('o_c1x', 'authenticated', pg_temp.u(1), format('select count(*)::text from public.orders where user_id = %L', pg_temp.u(2)));
select pg_temp.run('oi_c1x','authenticated', pg_temp.u(1), format($f$select count(*)::text from public.order_items where order_id = %L$f$, pg_temp.res('o3')));
select pg_temp.run('oh_c1x','authenticated', pg_temp.u(1), format($f$select count(*)::text from public.order_status_history where order_id = %L$f$, pg_temp.res('o3')));
select pg_temp.run('oi_adm','authenticated', pg_temp.u(4), format($f$select count(*)::text from public.order_items where order_id = %L$f$, pg_temp.res('o3')));
select pg_temp.run('o_an',  'anon', null, 'select count(*)::text from public.orders');
select pg_temp.expect('o_adm', (select count(*)::text from public.orders), 'ORDERS READ: admin sees every order');
select pg_temp.expect('o_stf', (select count(*)::text from public.orders), 'ORDERS READ: staff see every order (fulfilment)');
select pg_temp.expect('o_c1', '2', 'ORDERS READ: customer 1 sees exactly their own 2 orders');
select pg_temp.expect('o_c1x', '0', 'ORDERS READ: customer 1 cannot see customer 2''s orders');
select pg_temp.expect('oi_c1x', '0', 'ORDERS READ: customer 1 cannot see customer 2''s order items');
select pg_temp.expect('oh_c1x', '0', 'ORDERS READ: customer 1 cannot see customer 2''s order history');
select pg_temp.expect('oi_adm', '1', 'ORDERS READ: admin sees order items');
select pg_temp.ok((select err from t_res where k = 'o_an') is not null or (select res from t_res where k = 'o_an') = '0',
  'ORDERS READ: anon sees no orders');

-- user_roles: admin reads all, others only their own
select pg_temp.run('ur_adm', 'authenticated', pg_temp.u(4), 'select count(*)::text from public.user_roles');
select pg_temp.run('ur_stf', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.user_roles');
select pg_temp.run('ur_c1',  'authenticated', pg_temp.u(1), 'select count(*)::text from public.user_roles');
select pg_temp.expect('ur_adm', (select count(*)::text from public.user_roles), 'ROLES READ: admin sees all role rows');
select pg_temp.expect('ur_stf', '1', 'ROLES READ: staff see only their own role row');
select pg_temp.expect('ur_c1', '0', 'ROLES READ: a customer (no role row) sees none');

-- delivery configuration: staff + admin read inactive zones, customers do not
select pg_temp.run('dz_adm', 'authenticated', pg_temp.u(4), $$select count(*)::text from public.delivery_zones where code = 't6a-zone-off'$$);
select pg_temp.run('dz_stf', 'authenticated', pg_temp.u(3), $$select count(*)::text from public.delivery_zones where code = 't6a-zone-off'$$);
select pg_temp.run('dz_c1',  'authenticated', pg_temp.u(1), $$select count(*)::text from public.delivery_zones where code = 't6a-zone-off'$$);
select pg_temp.expect('dz_adm', '1', 'DELIVERY READ: admin sees inactive zones');
select pg_temp.expect('dz_stf', '1', 'DELIVERY READ: staff see inactive zones');
select pg_temp.expect('dz_c1',  '0', 'DELIVERY READ: customers do not see inactive zones');

-- ===========================================================================
-- D. WRITE BOUNDARIES: nothing new can be written from the browser
-- ===========================================================================
-- Admin cannot write the catalogue or profiles (no write path exists yet - later phase).
select pg_temp.run('w_pi', 'authenticated', pg_temp.u(4),
  $$with i as (insert into public.products (slug, name, price_cents) values ('t6a-hacked', 'T6A hacked', 1) returning 1) select count(*)::text from i$$);
select pg_temp.run('w_pu', 'authenticated', pg_temp.u(4),
  format('with u as (update public.products set price_cents = 1 where id = %L returning 1) select count(*)::text from u', pg_temp.p(1)));
select pg_temp.run('w_pd', 'authenticated', pg_temp.u(4),
  format('with d as (delete from public.products where id = %L returning 1) select count(*)::text from d', pg_temp.p(1)));
select pg_temp.run('w_vu', 'authenticated', pg_temp.u(4),
  format('with u as (update public.product_variants set stock_quantity = 999 where id = %L returning 1) select count(*)::text from u', pg_temp.v(1)));
select pg_temp.run('w_cu', 'authenticated', pg_temp.u(4),
  $$with u as (update public.categories set name = 'hacked' where slug = 't6a-cat-off' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_pru', 'authenticated', pg_temp.u(4),
  format('with u as (update public.profiles set full_name = %L where id = %L returning 1) select count(*)::text from u', 'Hacked', pg_temp.u(1)));
select pg_temp.expect_blocked('w_pi',  'WRITE: admin cannot insert a product (no admin write path yet)');
select pg_temp.expect_blocked('w_pu',  'WRITE: admin cannot update a product price');
select pg_temp.expect_blocked('w_pd',  'WRITE: admin cannot delete a product');
select pg_temp.expect_blocked('w_vu',  'WRITE: admin cannot change variant stock');
select pg_temp.expect_blocked('w_cu',  'WRITE: admin cannot update a category');
select pg_temp.expect_blocked('w_pru', 'WRITE: admin cannot edit another user''s profile');
select pg_temp.ok(
  not exists (select 1 from public.products where slug = 't6a-hacked')
  and (select price_cents from public.products where id = pg_temp.p(1)) = 1000
  and exists (select 1 from public.products where id = pg_temp.p(1))
  and (select stock_quantity from public.product_variants where id = pg_temp.v(1)) = 1
  and (select name from public.categories where slug = 't6a-cat-off') = 'T6A inactive category'
  and (select full_name from public.profiles where id = pg_temp.u(1)) = 'T6A Customer One',
  'WRITE: owner re-read confirms none of the admin write attempts changed anything');

-- Customers/staff cannot write the catalogue either
select pg_temp.run('w_cu1', 'authenticated', pg_temp.u(1),
  format('with u as (update public.products set price_cents = 1 where id = %L returning 1) select count(*)::text from u', pg_temp.p(1)));
select pg_temp.run('w_su1', 'authenticated', pg_temp.u(3),
  format('with u as (update public.products set stock_quantity = 9999 where id = %L returning 1) select count(*)::text from u', pg_temp.p(1)));
select pg_temp.expect_blocked('w_cu1', 'WRITE: customer cannot update a product');
select pg_temp.expect_blocked('w_su1', 'WRITE: staff cannot update product stock');

-- Roles cannot be granted from the browser, by anyone
select pg_temp.run('w_r1', 'authenticated', pg_temp.u(1),
  format('with i as (insert into public.user_roles (user_id, role) values (%L, %L) returning 1) select count(*)::text from i', pg_temp.u(1), 'admin'));
select pg_temp.run('w_r2', 'authenticated', pg_temp.u(3),
  format('with i as (insert into public.user_roles (user_id, role) values (%L, %L) returning 1) select count(*)::text from i', pg_temp.u(3), 'admin'));
select pg_temp.run('w_r3', 'authenticated', pg_temp.u(4),
  format('with i as (insert into public.user_roles (user_id, role) values (%L, %L) returning 1) select count(*)::text from i', pg_temp.u(1), 'admin'));
select pg_temp.expect_blocked('w_r1', 'ROLES WRITE: a customer cannot make themselves admin');
select pg_temp.expect_blocked('w_r2', 'ROLES WRITE: staff cannot make themselves admin');
select pg_temp.expect_blocked('w_r3', 'ROLES WRITE: an admin cannot grant roles from the browser');
select pg_temp.ok((select count(*) from public.user_roles where user_id = pg_temp.u(1)) = 0
  and (select count(*) from public.user_roles where user_id = pg_temp.u(3) and role = 'admin') = 0,
  'ROLES WRITE: owner re-read confirms no role was granted');

-- ===========================================================================
-- E. PHASE 5 REGRESSION (re-proved after the 6A objects exist)
-- ===========================================================================
-- Browser users cannot UPDATE orders (including to fabricate paid/refunded)
select pg_temp.run('ou_adm', 'authenticated', pg_temp.u(4),
  format($f$with u as (update public.orders set payment_status = 'paid', status = 'paid' where id = %L returning 1) select count(*)::text from u$f$, pg_temp.res('o1')));
select pg_temp.run('ou_stf', 'authenticated', pg_temp.u(3),
  format($f$with u as (update public.orders set status = 'refunded' where id = %L returning 1) select count(*)::text from u$f$, pg_temp.res('o1')));
select pg_temp.run('ou_c1', 'authenticated', pg_temp.u(1),
  format($f$with u as (update public.orders set payment_status = 'paid' where id = %L returning 1) select count(*)::text from u$f$, pg_temp.res('o1')));
select pg_temp.run('ou_c1t', 'authenticated', pg_temp.u(1),
  format($f$with u as (update public.orders set total_cents = 1, subtotal_cents = 1 where id = %L returning 1) select count(*)::text from u$f$, pg_temp.res('o1')));
select pg_temp.expect_blocked('ou_adm', 'REGRESSION: admin cannot UPDATE orders directly to paid');
select pg_temp.expect_blocked('ou_stf', 'REGRESSION: staff cannot UPDATE orders directly to refunded');
select pg_temp.expect_blocked('ou_c1',  'REGRESSION: customer cannot mark their order paid');
select pg_temp.expect_blocked('ou_c1t', 'REGRESSION: customer cannot change an order total');
select pg_temp.ok(
  (select status::text || '/' || payment_status::text || '/' || total_cents from public.orders where id = pg_temp.res('o1')::uuid) = 'pending/pending/2000',
  'REGRESSION: owner re-read confirms the order is unchanged (pending/pending/2000)');

-- set_order_status: customer refused, staff may fulfil, paid/refunded unreachable, payment gate holds
select pg_temp.set_status('ss_c',  'authenticated', pg_temp.u(1), pg_temp.res('o1'), 'processing');
select pg_temp.set_status('ss_s',  'authenticated', pg_temp.u(3), pg_temp.res('o1'), 'processing');
select pg_temp.set_status('ss_ap', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'paid');
select pg_temp.set_status('ss_ar', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'refunded');
select pg_temp.set_status('ss_sp', 'authenticated', pg_temp.u(3), pg_temp.res('o1'), 'paid');
select pg_temp.set_status('ss_gate','authenticated', pg_temp.u(4), pg_temp.res('o2'), 'processing', 'try to skip payment');
select pg_temp.set_status('ss_an', 'anon', null, pg_temp.res('o1'), 'processing');
select pg_temp.expect_err('ss_c',  '42501', 'not_authorised', 'REGRESSION: customer cannot call set_order_status');
select pg_temp.expect('ss_s', 'processing', 'REGRESSION: staff can still move an order along the fulfilment workflow');
select pg_temp.expect_err('ss_ap', 'P0001', 'payment_state_reserved', 'REGRESSION: admin cannot set paid');
select pg_temp.expect_err('ss_ar', 'P0001', 'payment_state_reserved', 'REGRESSION: admin cannot set refunded');
select pg_temp.expect_err('ss_sp', 'P0001', 'payment_state_reserved', 'REGRESSION: staff cannot set paid');
select pg_temp.expect_err('ss_gate','P0001', 'payment_not_confirmed', 'REGRESSION: an unpaid M-Pesa order cannot be fulfilled, even by an admin override');
select pg_temp.expect_err('ss_an', '42501', null, 'REGRESSION: anon cannot execute set_order_status');

-- Delivery configuration stays admin-write only
select pg_temp.run('dw_stf', 'authenticated', pg_temp.u(3),
  $$with u as (update public.delivery_zones set name = 'T6A staff edit' where code = 't6a-zone' returning 1) select count(*)::text from u$$);
select pg_temp.run('dw_c1', 'authenticated', pg_temp.u(1),
  $$with u as (update public.delivery_zones set name = 'T6A customer edit' where code = 't6a-zone' returning 1) select count(*)::text from u$$);
select pg_temp.run('dw_stfm', 'authenticated', pg_temp.u(3),
  $$with u as (update public.delivery_methods set base_fee_cents = 0 where code = 'standard' returning 1) select count(*)::text from u$$);
select pg_temp.run('dw_adm', 'authenticated', pg_temp.u(4),
  $$with u as (update public.delivery_zones set name = 'T6A admin edit' where code = 't6a-zone' returning 1) select count(*)::text from u$$);
select pg_temp.expect_blocked('dw_stf', 'REGRESSION: staff cannot edit a delivery zone');
select pg_temp.expect_blocked('dw_c1',  'REGRESSION: customer cannot edit a delivery zone');
select pg_temp.expect_blocked('dw_stfm', 'REGRESSION: staff cannot edit a delivery method fee');
select pg_temp.expect('dw_adm', '1', 'ADMIN: admin can still edit delivery configuration');
select pg_temp.ok((select name from public.delivery_zones where code = 't6a-zone') = 'T6A admin edit',
  'ADMIN: owner re-read shows only the admin edit landed');

-- Role helpers answer only about the caller
select pg_temp.run('h_c', 'authenticated', pg_temp.u(1), format('select public.is_admin(%L)::text', pg_temp.u(4)));
select pg_temp.run('h_s', 'authenticated', pg_temp.u(3), format('select public.has_role(%L, %L)::text', pg_temp.u(4), 'admin'));
select pg_temp.run('h_a', 'authenticated', pg_temp.u(4), format('select public.is_admin(%L)::text', pg_temp.u(4)));
select pg_temp.run('h_an', 'anon', null, format('select public.is_admin(%L)::text', pg_temp.u(4)));
select pg_temp.expect('h_c', 'false', 'REGRESSION: a customer cannot probe whether someone else is admin');
select pg_temp.expect('h_s', 'false', 'REGRESSION: staff cannot probe whether someone else is admin');
select pg_temp.expect('h_a', 'true',  'REGRESSION: an admin gets true about themselves');
select pg_temp.expect_err('h_an', '42501', null, 'REGRESSION: anon cannot execute is_admin');

-- ===========================================================================
-- F. PRIVILEGES AND DEFINER HYGIENE
-- ===========================================================================
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'PRIVILEGES: dashboard = authenticated only; require_admin = nobody in the browser');
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'PRIVILEGES: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.ok(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT'
     and policyname in ('Products: admin read all','Variants: admin read all','Categories: admin read all','Profiles: admin read all')) = 4
  and not exists (select 1 from pg_policies where schemaname = 'public'
     and tablename in ('products','product_variants','categories') and cmd in ('INSERT','UPDATE','DELETE','ALL'))
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and cmd in ('UPDATE','ALL','INSERT','DELETE')),
  'POLICIES: 4 admin read policies exist; no write policy on the catalogue; none on orders');
select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('anon', 'public.orders', 'UPDATE'),
  'PRIVILEGES: no browser role holds UPDATE on any orders column');

-- Informational only (not an assertion - a later payment phase will legitimately add these).
do $$
declare v_names text;
begin
  select string_agg(tablename, ', ') into v_names
  from pg_tables where schemaname = 'public' and tablename ~* '(payment|webhook|transaction|refund)';
  raise notice 'INFO: public tables that look payment-related: %', coalesce(v_names, '(none - payments are not implemented)');
end $$;

do $$ begin raise notice 'ALL PHASE 6A TESTS PASSED'; end $$;

rollback;
