-- =============================================================================
-- PHASE 6B.1 database test: admin orders backend.
--
-- STATUS: written for migration 20261004020000_phase6b1_admin_orders_backend.sql.
-- NOT RUN. It has not been executed against local PostgreSQL or against the dedicated
-- Phase-5 development Supabase database. Treat every assertion as unproven until it is.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004020000_phase6b1_admin_orders_backend.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b1_admin_orders_backend.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6B.1 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST.
--
-- NOT-EMPTY PROOF: every "denied" check has a matching positive control in which an admin gets
-- the SAME fixture rows back, and every filter check has a positive control showing the
-- unfiltered set is non-empty. An empty result is never accepted as proof of authorisation:
-- denial is asserted as an ERROR (42501), not as "0 rows".
--
-- Fixtures carry the marker 'T6B' (names, emails, SKUs) and UUIDs containing 6b... .
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


-- Fixture ids: users 1..5
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6b100000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6b2000000' || lpad(n::text, 3, '0'))::uuid $$;

-- admin_list_orders(<named args>) as a role; admin_get_order(id) as a role
create or replace function pg_temp.list(p_k text, p_role text, p_uid uuid, p_args text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_list_orders(' || p_args || ')::text');
end;
$$;

create or replace function pg_temp.get(p_k text, p_role text, p_uid uuid, p_order text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format('select public.admin_get_order(%L::uuid)::text', p_order));
end;
$$;

create or replace function pg_temp.n(p_k text) returns integer language sql as $$
  select jsonb_array_length(pg_temp.j(p_k) -> 'orders') $$;
create or replace function pg_temp.tot(p_k text) returns integer language sql as $$
  select (pg_temp.j(p_k) ->> 'total')::integer $$;
create or replace function pg_temp.in_list(p_k text, p_order text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(pg_temp.j(p_k) -> 'orders') e where e ->> 'id' = p_order) $$;

-- An admin function call was REFUSED: an error with SQLSTATE 42501 and no result.
create or replace function pg_temp.denied(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ']');
end;
$$;

-- Refused by the admin gate specifically (SQLSTATE 42501 + DETAIL not_authorised).
create or replace function pg_temp.gated(p_k text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.expect_err(p_k, '42501', 'not_authorised', p_name);
end;
$$;

-- WHY THIS EXISTS: this whole file is ONE transaction, and now() is constant inside a transaction.
-- Every history row written by the triggers (and every default created_at) therefore carries the
-- SAME timestamp, and admin_get_order() - which orders history by (created_at, id) - would break
-- the tie by random UUID. The production ordering is fine; the fixture just has to give the rows
-- distinct timestamps. Call this right after each step that writes history: it moves the rows
-- written in this transaction (created_at = now()) to now() - p_minutes_ago, so later steps get
-- later timestamps. Owner-level, fixture only; browser roles still cannot write history.
create or replace function pg_temp.stamp_history(p_minutes_ago integer)
returns void language plpgsql as $$
begin
  update public.order_status_history
     set created_at = now() - make_interval(mins => p_minutes_ago)
   where created_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6b-customer1@example.test', 'authenticated', 'authenticated',
     '{"full_name":"T6B Customer One","phone":"+254700616001"}'),
  (pg_temp.u(2), 't6b-customer2@example.test', 'authenticated', 'authenticated',
     '{"full_name":"T6B Customer Two","phone":"+254700616002"}'),
  (pg_temp.u(3), 't6b-staff@example.test',     'authenticated', 'authenticated', '{"full_name":"T6B Staff"}'),
  (pg_temp.u(4), 't6b-admin@example.test',     'authenticated', 'authenticated', '{"full_name":"T6B Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(3), 'staff'),
  (pg_temp.u(4), 'admin');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active, sku) values
  (pg_temp.p(1), 't6b-pa', 'T6B PA', 1000, 50, true, true, 'T6B-PA'),
  (pg_temp.p(2), 't6b-pb', 'T6B PB', 5000, 50, true, true, 'T6B-PB');

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6b_pick', 'T6B pickup', 0, null, 0, false, false, true);

-- Orders through the real create_order()
select pg_temp.place('o1', pg_temp.u(1), 't6b_pick', 'cash_on_delivery', pg_temp.p(1), 2);   -- 2000
select pg_temp.place('o2', pg_temp.u(1), 't6b_pick', 'mpesa',            pg_temp.p(1), 1);   -- 1000
select pg_temp.place('o3', pg_temp.u(2), 't6b_pick', 'cash_on_delivery', pg_temp.p(2), 1);   -- 5000
select pg_temp.place('o4', pg_temp.u(2), 't6b_pick', 'cash_on_delivery', pg_temp.p(1), 3);   -- 3000
select pg_temp.ok(
  (select count(*) from t_res where k in ('o1','o2','o3','o4') and err is null and res is not null) = 4,
  'FIXTURE: four orders placed through create_order()');
select pg_temp.stamp_history(60);   -- every "Order placed" row is the oldest history row of its order

-- Real status changes through set_order_status(): O3 pending -> processing -> picking (staff),
-- O4 cancelled by the admin.
select pg_temp.set_status('f3a', 'authenticated', pg_temp.u(3), pg_temp.res('o3'), 'processing');
select pg_temp.stamp_history(50);
select pg_temp.set_status('f3b', 'authenticated', pg_temp.u(3), pg_temp.res('o3'), 'picking');
select pg_temp.stamp_history(40);
select pg_temp.set_status('f4',  'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'cancelled', 'T6B customer called');
select pg_temp.stamp_history(50);
select pg_temp.expect('f3a', 'processing', 'FIXTURE: staff moved O3 to processing');
select pg_temp.expect('f3b', 'picking',    'FIXTURE: staff moved O3 to picking');
select pg_temp.expect('f4',  'cancelled',  'FIXTURE: admin cancelled O4');

-- Owner-level fixture data that the browser cannot write:
--   O3 gets a delivery snapshot, slot, zone, fee rule (recipient differs from the account name);
--   O2's payment_status is failed (an unpaid mpesa order whose payment attempt failed);
--   O4 was placed three days ago; O1 gets a second order item.
update public.orders set
  delivery_address = jsonb_build_object(
    'full_name', 'T6B Recipient Zed', 'phone', '+254711616999', 'label', 'Home',
    'address_line_1', '12 T6B Road', 'address_line_2', null, 'city', 'Nairobi', 'county', 'Nairobi',
    'postal_code', '00100', 'delivery_instructions', 'T6B gate code 1234'),
  delivery_slot_date = (now() at time zone 'Africa/Nairobi')::date + 1,
  delivery_slot_start = '09:00', delivery_slot_end = '11:00', delivery_slot_label = 'T6B morning',
  delivery_zone_name = 'T6B zone', delivery_zone_code = 't6b-zone',
  delivery_method_label = 'T6B pickup',
  delivery_fee_rule = '{"source":"zone","base_fee_cents":0}'::jsonb
where id = pg_temp.res('o3')::uuid;
update public.orders set payment_status = 'failed' where id = pg_temp.res('o2')::uuid;
select pg_temp.stamp_history(45);
update public.orders set placed_at = now() - interval '3 days' where id = pg_temp.res('o4')::uuid;
-- The extra item is given an explicit, later created_at. Without it, it would tie with the item
-- create_order() wrote (same transaction => same now()) and (created_at, id) would be decided by
-- random UUIDs.
insert into public.order_items (order_id, product_name, sku, unit_price_cents, quantity, line_total_cents, created_at)
values (pg_temp.res('o1')::uuid, 'T6B extra item', 'T6B-X', 250, 2, 500, now() + interval '1 second');

-- Guard: after stamping, no two history rows of the same fixture order share a timestamp, so every
-- history-order assertion below is decided by created_at and never by a random UUID tie-break.
select pg_temp.ok(
  not exists (
    select 1 from public.order_status_history
    where order_id in (pg_temp.res('o1')::uuid, pg_temp.res('o2')::uuid, pg_temp.res('o3')::uuid, pg_temp.res('o4')::uuid)
    group by order_id, created_at having count(*) > 1)
  and (select count(*) from public.order_status_history where order_id = pg_temp.res('o3')::uuid) = 3
  and (select count(*) from public.order_status_history where order_id = pg_temp.res('o2')::uuid) = 2,
  'FIXTURE: history rows of each fixture order have distinct timestamps (O3 has 3 rows, O2 has 2)');

-- ===========================================================================
-- A. ADMIN CAN LIST ORDERS
-- ===========================================================================
select pg_temp.list('a1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_limit => 100$$);
select pg_temp.ok((select err from t_res where k = 'a1') is null and pg_temp.res('a1') is not null,
  'LIST: admin calls admin_list_orders successfully');
select pg_temp.ok(pg_temp.j('a1') ?& array['total','limit','offset','orders']
  and (select count(*) from jsonb_object_keys(pg_temp.j('a1'))) = 4,
  'LIST: exactly total/limit/offset/orders are returned');
select pg_temp.ok(pg_temp.tot('a1') = 4 and pg_temp.n('a1') = 4
  and pg_temp.in_list('a1', pg_temp.res('o1')) and pg_temp.in_list('a1', pg_temp.res('o2'))
  and pg_temp.in_list('a1', pg_temp.res('o3')) and pg_temp.in_list('a1', pg_temp.res('o4')),
  'LIST: all four fixture orders (two customers) are returned');
select pg_temp.ok(
  (select string_agg(e ->> 'id', ',' order by ord) from jsonb_array_elements(pg_temp.j('a1') -> 'orders') with ordinality t(e, ord))
  = (select string_agg(id::text, ',' order by placed_at desc, id desc) from public.orders
     where user_id in (pg_temp.u(1), pg_temp.u(2))),
  'LIST: order is newest first (placed_at desc, id desc), matching an independent query');
select pg_temp.ok(
  (select bool_and(e ?& array['id','order_number','status','payment_status','payment_method','delivery_method',
                              'delivery_method_label','delivery_slot_date','subtotal_cents','delivery_fee_cents',
                              'discount_cents','total_cents','currency','placed_at','customer']
                   and (select count(*) from jsonb_object_keys(e)) = 15)
   from jsonb_array_elements(pg_temp.j('a1') -> 'orders') e),
  'LIST: every row has exactly the documented list fields');
select pg_temp.ok(
  (select e ->> 'status' = 'picking' and e ->> 'payment_method' = 'cash_on_delivery' and (e ->> 'total_cents')::int = 5000
          and e -> 'customer' ->> 'full_name' = 'T6B Customer Two'
   from jsonb_array_elements(pg_temp.j('a1') -> 'orders') e where e ->> 'id' = pg_temp.res('o3')),
  'LIST: O3 row shows its status, method, total and customer name');
select pg_temp.list('a2', 'authenticated', pg_temp.u(4), '');
select pg_temp.ok((select err from t_res where k = 'a2') is null and pg_temp.tot('a2') >= 4 and pg_temp.n('a2') <= 25
  and pg_temp.tot('a2') = (select count(*) from public.orders),
  'LIST: with no arguments, defaults apply (limit 25) and total equals an independent count of all orders');

-- ===========================================================================
-- B. SEARCH
-- ===========================================================================
select pg_temp.list('b_num', 'authenticated', pg_temp.u(4),
  format('p_search => %L', (select order_number from public.orders where id = pg_temp.res('o2')::uuid)));
select pg_temp.ok(pg_temp.tot('b_num') = 1 and pg_temp.in_list('b_num', pg_temp.res('o2')), 'SEARCH: by exact order number finds that order only');
select pg_temp.list('b_numlc', 'authenticated', pg_temp.u(4),
  format('p_search => %L', lower((select order_number from public.orders where id = pg_temp.res('o2')::uuid))));
select pg_temp.ok(pg_temp.in_list('b_numlc', pg_temp.res('o2')), 'SEARCH: order number search is case-insensitive');
select pg_temp.list('b_name', 'authenticated', pg_temp.u(4), $$p_search => 'customer one'$$);
select pg_temp.ok(pg_temp.tot('b_name') = 2 and pg_temp.in_list('b_name', pg_temp.res('o1')) and pg_temp.in_list('b_name', pg_temp.res('o2')),
  'SEARCH: by customer name (case-insensitive substring) finds that customer''s two orders');
select pg_temp.list('b_mail', 'authenticated', pg_temp.u(4), $$p_search => 't6b-customer2@example'$$);
select pg_temp.ok(pg_temp.tot('b_mail') = 2 and pg_temp.in_list('b_mail', pg_temp.res('o3')) and pg_temp.in_list('b_mail', pg_temp.res('o4')),
  'SEARCH: by customer email finds that customer''s orders');
select pg_temp.list('b_phone', 'authenticated', pg_temp.u(4), $$p_search => '616001'$$);
select pg_temp.ok(pg_temp.tot('b_phone') = 2 and pg_temp.in_list('b_phone', pg_temp.res('o1')), 'SEARCH: by customer profile phone');
select pg_temp.list('b_snap', 'authenticated', pg_temp.u(4), $$p_search => 'Recipient Zed'$$);
select pg_temp.ok(pg_temp.tot('b_snap') = 1 and pg_temp.in_list('b_snap', pg_temp.res('o3')), 'SEARCH: by delivery-address snapshot name');
select pg_temp.list('b_snapph', 'authenticated', pg_temp.u(4), $$p_search => '616999'$$);
select pg_temp.ok(pg_temp.tot('b_snapph') = 1 and pg_temp.in_list('b_snapph', pg_temp.res('o3')), 'SEARCH: by delivery-address snapshot phone');
select pg_temp.list('b_none', 'authenticated', pg_temp.u(4), $$p_search => 'T6B-no-such-customer-zzz'$$);
select pg_temp.ok((select err from t_res where k = 'b_none') is null and pg_temp.tot('b_none') = 0 and pg_temp.n('b_none') = 0,
  'SEARCH: a term that matches nothing returns an empty list without error');
select pg_temp.list('b_wild1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B%Customer'$$);
select pg_temp.list('b_wild2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B_Customer'$$);
select pg_temp.ok(pg_temp.tot('b_wild1') = 0 and pg_temp.tot('b_wild2') = 0,
  'SEARCH: % and _ are literal (an unescaped pattern would have matched "T6B Customer ...")');
select pg_temp.list('b_blank', 'authenticated', pg_temp.u(4), $$p_search => '   '$$);
select pg_temp.ok(pg_temp.tot('b_blank') = (select count(*) from public.orders), 'SEARCH: a blank search is ignored');

-- ===========================================================================
-- C. FILTERS (each with a positive control: search T6B alone returns all 4)
-- ===========================================================================
select pg_temp.list('c_st1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_status => 'pending'$$);
select pg_temp.list('c_st2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_status => 'awaiting_payment'$$);
select pg_temp.list('c_st3', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_status => 'picking'$$);
select pg_temp.list('c_st4', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_status => 'cancelled'$$);
select pg_temp.ok(
  pg_temp.tot('c_st1') = 1 and pg_temp.in_list('c_st1', pg_temp.res('o1'))
  and pg_temp.tot('c_st2') = 1 and pg_temp.in_list('c_st2', pg_temp.res('o2'))
  and pg_temp.tot('c_st3') = 1 and pg_temp.in_list('c_st3', pg_temp.res('o3'))
  and pg_temp.tot('c_st4') = 1 and pg_temp.in_list('c_st4', pg_temp.res('o4')),
  'FILTER status: pending/awaiting_payment/picking/cancelled each select exactly the right order');

select pg_temp.list('c_pm1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_method => 'mpesa'$$);
select pg_temp.list('c_pm2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_method => 'cash_on_delivery'$$);
select pg_temp.list('c_pm3', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_method => 'card'$$);
select pg_temp.ok(
  pg_temp.tot('c_pm1') = 1 and pg_temp.in_list('c_pm1', pg_temp.res('o2'))
  and pg_temp.tot('c_pm2') = 3 and not pg_temp.in_list('c_pm2', pg_temp.res('o2'))
  and pg_temp.tot('c_pm3') = 0,
  'FILTER payment_method: mpesa = O2, cash_on_delivery = the other three, card = none');

select pg_temp.list('c_ps1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_status => 'failed'$$);
select pg_temp.list('c_ps2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_status => 'pending'$$);
select pg_temp.list('c_ps3', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_payment_status => 'paid'$$);
select pg_temp.ok(
  pg_temp.tot('c_ps1') = 1 and pg_temp.in_list('c_ps1', pg_temp.res('o2'))
  and pg_temp.tot('c_ps2') = 3 and not pg_temp.in_list('c_ps2', pg_temp.res('o2'))
  and pg_temp.tot('c_ps3') = 0,
  'FILTER payment_status: failed = O2, pending = the other three, paid = none (nothing is paid)');

select pg_temp.list('c_combo1', 'authenticated', pg_temp.u(4),
  $$p_search => 'T6B', p_payment_method => 'cash_on_delivery', p_status => 'pending'$$);
select pg_temp.list('c_combo2', 'authenticated', pg_temp.u(4),
  $$p_search => 'T6B', p_payment_method => 'mpesa', p_status => 'pending'$$);
select pg_temp.ok(pg_temp.tot('c_combo1') = 1 and pg_temp.in_list('c_combo1', pg_temp.res('o1')) and pg_temp.tot('c_combo2') = 0,
  'FILTER: filters combine with AND');

-- Dates are Africa/Nairobi calendar days, inclusive. O1-O3 were placed now, O4 three days ago.
select pg_temp.list('c_d1', 'authenticated', pg_temp.u(4), format(
  $$p_search => 'T6B', p_placed_from => %L, p_placed_to => %L$$,
  (now() at time zone 'Africa/Nairobi')::date, (now() at time zone 'Africa/Nairobi')::date));
select pg_temp.list('c_d2', 'authenticated', pg_temp.u(4), format(
  $$p_search => 'T6B', p_placed_from => %L, p_placed_to => %L$$,
  (now() at time zone 'Africa/Nairobi')::date - 4, (now() at time zone 'Africa/Nairobi')::date - 2));
select pg_temp.list('c_d3', 'authenticated', pg_temp.u(4), format(
  $$p_search => 'T6B', p_placed_from => %L$$, (now() at time zone 'Africa/Nairobi')::date + 1));
select pg_temp.list('c_d4', 'authenticated', pg_temp.u(4), format(
  $$p_search => 'T6B', p_placed_to => %L$$, (now() at time zone 'Africa/Nairobi')::date - 1));
select pg_temp.list('c_d5', 'authenticated', pg_temp.u(4), format(
  $$p_search => 'T6B', p_placed_from => %L$$, (now() at time zone 'Africa/Nairobi')::date - 4));
select pg_temp.ok(
  pg_temp.tot('c_d1') = 3 and not pg_temp.in_list('c_d1', pg_temp.res('o4'))
  and pg_temp.tot('c_d2') = 1 and pg_temp.in_list('c_d2', pg_temp.res('o4'))
  and pg_temp.tot('c_d3') = 0
  and pg_temp.tot('c_d4') = 1 and pg_temp.in_list('c_d4', pg_temp.res('o4'))
  and pg_temp.tot('c_d5') = 4,
  'FILTER date: today-only = O1-O3; a past window = O4; the future = none; "to yesterday" = O4; open-ended from = all');

-- Pagination: two pages of two are disjoint, together equal the full set, and total never changes.
select pg_temp.list('c_p1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_limit => 2, p_offset => 0$$);
select pg_temp.list('c_p2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_limit => 2, p_offset => 2$$);
select pg_temp.list('c_p3', 'authenticated', pg_temp.u(4), $$p_search => 'T6B', p_limit => 2, p_offset => 4$$);
select pg_temp.ok(
  pg_temp.n('c_p1') = 2 and pg_temp.n('c_p2') = 2 and pg_temp.n('c_p3') = 0
  and pg_temp.tot('c_p1') = 4 and pg_temp.tot('c_p2') = 4 and pg_temp.tot('c_p3') = 4
  and (select count(distinct e ->> 'id') from (
         select e from jsonb_array_elements(pg_temp.j('c_p1') -> 'orders') e
         union all select e from jsonb_array_elements(pg_temp.j('c_p2') -> 'orders') e) x) = 4
  and (select string_agg(e ->> 'id', ',' order by ord) from (
         select e, ord from jsonb_array_elements(pg_temp.j('c_p1') -> 'orders') with ordinality t(e, ord)
         union all
         select e, ord + 2 from jsonb_array_elements(pg_temp.j('c_p2') -> 'orders') with ordinality t(e, ord)) x)
      = (select string_agg(e ->> 'id', ',' order by ord) from jsonb_array_elements(pg_temp.j('a1') -> 'orders') with ordinality t(e, ord)),
  'FILTER paging: limit/offset pages are disjoint, in order, total stays 4, and an offset past the end is empty');

-- Argument validation (as an admin, so this is validation, not authorisation)
select pg_temp.list('c_i1', 'authenticated', pg_temp.u(4), 'p_limit => 0');
select pg_temp.list('c_i2', 'authenticated', pg_temp.u(4), 'p_limit => 101');
select pg_temp.list('c_i3', 'authenticated', pg_temp.u(4), 'p_offset => -1');
select pg_temp.list('c_i4', 'authenticated', pg_temp.u(4), $$p_placed_from => '2026-10-05', p_placed_to => '2026-10-04'$$);
select pg_temp.list('c_i5', 'authenticated', pg_temp.u(4), format('p_search => %L', repeat('x', 101)));
select pg_temp.list('c_i6', 'authenticated', pg_temp.u(4), 'p_limit => null');
select pg_temp.expect_err('c_i1', 'P0001', 'invalid_arguments', 'VALIDATION: limit 0 is rejected');
select pg_temp.expect_err('c_i2', 'P0001', 'invalid_arguments', 'VALIDATION: limit 101 is rejected');
select pg_temp.expect_err('c_i3', 'P0001', 'invalid_arguments', 'VALIDATION: negative offset is rejected');
select pg_temp.expect_err('c_i4', 'P0001', 'invalid_arguments', 'VALIDATION: from after to is rejected');
select pg_temp.expect_err('c_i5', 'P0001', 'invalid_arguments', 'VALIDATION: a 101-character search is rejected');
select pg_temp.expect_err('c_i6', 'P0001', 'invalid_arguments', 'VALIDATION: a null limit is rejected');

-- ===========================================================================
-- D. ORDER DETAIL: order, customer, items, delivery, payment, history
-- ===========================================================================
select pg_temp.get('d3', 'authenticated', pg_temp.u(4), pg_temp.res('o3'));
select pg_temp.get('d1', 'authenticated', pg_temp.u(4), pg_temp.res('o1'));
select pg_temp.get('d2', 'authenticated', pg_temp.u(4), pg_temp.res('o2'));
select pg_temp.ok((select err from t_res where k = 'd3') is null and pg_temp.res('d3') is not null,
  'DETAIL: admin calls admin_get_order successfully');
select pg_temp.ok(pg_temp.j('d3') ?& array['order','customer','delivery','payment','items','history']
  and (select count(*) from jsonb_object_keys(pg_temp.j('d3'))) = 6,
  'DETAIL: exactly order/customer/delivery/payment/items/history are returned');
select pg_temp.ok(
  pg_temp.j('d3') #>> '{order,id}' = pg_temp.res('o3')
  and pg_temp.j('d3') #>> '{order,status}' = 'picking'
  and (pg_temp.j('d3') #>> '{order,total_cents}')::int = 5000
  and pg_temp.j('d3') #>> '{order,order_number}' = (select order_number from public.orders where id = pg_temp.res('o3')::uuid),
  'DETAIL: the order block carries id, number, status and total');

-- customer
select pg_temp.ok(
  pg_temp.j('d3') #>> '{customer,id}' = pg_temp.u(2)::text
  and pg_temp.j('d3') #>> '{customer,full_name}' = 'T6B Customer Two'
  and pg_temp.j('d3') #>> '{customer,email}' = 't6b-customer2@example.test'
  and pg_temp.j('d3') #>> '{customer,phone}' = '+254700616002'
  and (pg_temp.j('d3') #>> '{customer,created_at}') is not null,
  'CUSTOMER: name, email, phone and member-since come from the customer''s profile');
select pg_temp.ok(
  (select array_agg(k order by k) from jsonb_object_keys(pg_temp.j('d3') -> 'customer') k)
    = array['created_at','email','full_name','id','phone'],
  'CUSTOMER PRIVACY: the customer block has exactly five profile fields');
select pg_temp.ok(
  pg_temp.res('d3') !~* '(password|encrypted|token|secret|raw_user_meta|app_metadata|service_role|jwt|refresh)'
  and pg_temp.res('a1') !~* '(password|encrypted|token|secret|raw_user_meta|app_metadata|service_role|jwt|refresh)',
  'CUSTOMER PRIVACY: neither the detail nor the list payload mentions passwords, tokens, secrets or auth metadata');

-- items
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('d3') -> 'items') = 1
  and pg_temp.j('d3') #>> '{items,0,product_name}' = 'T6B PB'
  and (pg_temp.j('d3') #>> '{items,0,quantity}')::int = 1
  and (pg_temp.j('d3') #>> '{items,0,unit_price_cents}')::int = 5000
  and (pg_temp.j('d3') #>> '{items,0,line_total_cents}')::int = 5000
  and pg_temp.j('d3') #>> '{items,0,order_id}' = pg_temp.res('o3'),
  'ITEMS: O3 returns its one item with name, quantity, unit price and line total');
-- O1 has exactly two items: the one create_order() wrote and the extra fixture item.
-- Primary assertions are ORDER-INDEPENDENT: they prove the right rows, not their array position.
-- Split into small checks, each reporting what it actually got, so a failure names its cause.
-- (Name comparison uses COLLATE "C": the database default collation, e.g. en_US, sorts
-- 'T6B extra item' BEFORE 'T6B PA', so an un-collated sort is not a stable thing to compare.)
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('d1') -> 'items') = 2
  and (select count(*) from public.order_items where order_id = pg_temp.res('o1')::uuid) = 2,
  'ITEMS: O1 returns exactly 2 items, matching the owner-level row count [got '
    || jsonb_array_length(pg_temp.j('d1') -> 'items') || ' returned / '
    || (select count(*) from public.order_items where order_id = pg_temp.res('o1')::uuid) || ' stored]');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(pg_temp.j('d1') -> 'items') e
   where e ->> 'order_id' = pg_temp.res('o1')) = 2
  and (select count(distinct e ->> 'id') from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) = 2,
  'ITEMS: both returned items are distinct rows with order_id = O1');
select pg_temp.ok(
  (select array_agg(e ->> 'product_name' order by (e ->> 'product_name') collate "C")
   from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) = array['T6B PA', 'T6B extra item'],
  'ITEMS: the two names are exactly T6B PA and T6B extra item [got '
    || (select string_agg(e ->> 'product_name', ' | ' order by (e ->> 'product_name') collate "C")
        from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) || ']');
select pg_temp.ok(
  (select sum((e ->> 'line_total_cents')::int) from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) = 2500
  and (select sum((e ->> 'quantity')::int) from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) = 4,
  'ITEMS: O1 line totals add up to 2500 and quantities to 4 [got '
    || (select sum((e ->> 'line_total_cents')::int) from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) || ' / '
    || (select sum((e ->> 'quantity')::int) from jsonb_array_elements(pg_temp.j('d1') -> 'items') e) || ']');
-- Cross-order isolation: the returned item ids are EXACTLY the owner-level item ids of O1, and
-- none of them belongs to any other order (other fixture orders do have items, so this is not vacuous).
select pg_temp.ok(
  (select count(*) from public.order_items where order_id <> pg_temp.res('o1')::uuid
     and order_id in (pg_temp.res('o2')::uuid, pg_temp.res('o3')::uuid, pg_temp.res('o4')::uuid)) >= 3
  and (select array_agg(e ->> 'id' order by e ->> 'id') from jsonb_array_elements(pg_temp.j('d1') -> 'items') e)
      = (select array_agg(id::text order by id::text) from public.order_items where order_id = pg_temp.res('o1')::uuid)
  and not exists (
    select 1 from jsonb_array_elements(pg_temp.j('d1') -> 'items') e
    where (e ->> 'id')::uuid in (select id from public.order_items where order_id <> pg_temp.res('o1')::uuid)),
  'ITEMS: cross-order isolation - O1''s returned ids equal O1''s own item ids and none belongs to another order');
-- Ordering contract: items are ordered by (created_at, id). The fixture gave the extra item a
-- strictly later created_at, so here the order is decided by created_at, not by UUID luck.
select pg_temp.ok(
  (select array_agg(e ->> 'product_name' order by ord)
   from jsonb_array_elements(pg_temp.j('d1') -> 'items') with ordinality t(e, ord))
  = array['T6B PA', 'T6B extra item'],
  'ITEMS: ordered by created_at - the earlier create_order() item comes before the later fixture item');

-- delivery
select pg_temp.ok(
  pg_temp.j('d3') #>> '{delivery,method}' = 't6b_pick'
  and pg_temp.j('d3') #>> '{delivery,method_label}' = 'T6B pickup'
  and pg_temp.j('d3') #>> '{delivery,zone_name}' = 'T6B zone'
  and pg_temp.j('d3') #>> '{delivery,zone_code}' = 't6b-zone'
  and pg_temp.j('d3') #>> '{delivery,slot_start}' = '09:00:00'
  and pg_temp.j('d3') #>> '{delivery,slot_end}' = '11:00:00'
  and pg_temp.j('d3') #>> '{delivery,slot_label}' = 'T6B morning'
  and (pg_temp.j('d3') #>> '{delivery,slot_date}')::date = (now() at time zone 'Africa/Nairobi')::date + 1
  and pg_temp.j('d3') #>> '{delivery,fee_rule,source}' = 'zone'
  and (pg_temp.j('d3') #>> '{delivery,fee_cents}')::int = 0,
  'DELIVERY: method, zone, slot window/label/date and fee rule are returned');
select pg_temp.ok(
  pg_temp.j('d3') #>> '{delivery,address,full_name}' = 'T6B Recipient Zed'
  and pg_temp.j('d3') #>> '{delivery,address,phone}' = '+254711616999'
  and pg_temp.j('d3') #>> '{delivery,address,address_line_1}' = '12 T6B Road'
  and pg_temp.j('d3') #>> '{delivery,address,city}' = 'Nairobi'
  and pg_temp.j('d3') #>> '{delivery,address,delivery_instructions}' = 'T6B gate code 1234',
  'DELIVERY: the address snapshot (recipient, phone, street, city, instructions) is returned');
select pg_temp.ok(
  (pg_temp.j('d1') #> '{delivery,address}') = 'null'::jsonb and pg_temp.j('d1') #>> '{delivery,method}' = 't6b_pick',
  'DELIVERY: a pickup order has no address and still returns its method');

-- payment (only what orders already record)
select pg_temp.ok(
  pg_temp.j('d2') #>> '{payment,method}' = 'mpesa'
  and pg_temp.j('d2') #>> '{payment,status}' = 'failed'
  and pg_temp.j('d2') #>> '{payment,currency}' = 'KES'
  and (pg_temp.j('d2') #>> '{payment,total_cents}')::int = 1000
  and (pg_temp.j('d2') #>> '{payment,subtotal_cents}')::int = 1000
  and (select count(*) from jsonb_object_keys(pg_temp.j('d2') -> 'payment')) = 7,
  'PAYMENT: method, status, currency and amounts as stored; no invented transaction/provider fields');

-- history
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('d3') -> 'history') = 3
  and (select array_agg(e ->> 'new_status' order by ord) from jsonb_array_elements(pg_temp.j('d3') -> 'history') with ordinality t(e, ord))
      = array['pending', 'processing', 'picking']
  and pg_temp.j('d3') #>> '{history,0,previous_status}' is null
  and pg_temp.j('d3') #>> '{history,0,note}' = 'Order placed'
  and pg_temp.j('d3') #>> '{history,1,previous_status}' = 'pending'
  and pg_temp.j('d3') #>> '{history,2,previous_status}' = 'processing',
  'HISTORY: O3 shows placed -> processing -> picking, oldest first');
select pg_temp.ok(
  pg_temp.j('d3') #>> '{history,1,changed_by}' = pg_temp.u(3)::text
  and pg_temp.j('d3') #>> '{history,1,changed_by_name}' = 'T6B Staff'
  and pg_temp.j('d3') #>> '{history,0,changed_by_name}' = 'T6B Customer Two',
  'HISTORY: each entry names who made the change (staff for the status moves, the customer for placement)');
select pg_temp.get('d4', 'authenticated', pg_temp.u(4), pg_temp.res('o4'));
select pg_temp.ok(
  pg_temp.j('d4') #>> '{history,-1,new_status}' = 'cancelled'
  and pg_temp.j('d4') #>> '{history,-1,previous_status}' = 'pending'
  and pg_temp.j('d4') #>> '{history,-1,note}' = 'T6B customer called'
  and pg_temp.j('d4') #>> '{history,-1,changed_by_name}' = 'T6B Admin',
  'HISTORY: a status change made through set_order_status() (with its note and author) appears in the admin detail');
select pg_temp.ok(
  jsonb_array_length(pg_temp.j('d2') -> 'history') = 2
  and pg_temp.j('d2') #>> '{history,-1,note}' = 'Payment status updated to failed'
  and pg_temp.j('d2') #>> '{history,-1,payment_status}' = 'failed',
  'HISTORY: a payment-status change is recorded in the history');

-- not found / null
select pg_temp.get('d_nf', 'authenticated', pg_temp.u(4), '00000000-0000-4000-8000-6b9999999999');
select pg_temp.expect_err('d_nf', 'P0001', 'order_not_found', 'DETAIL: an unknown order id is reported as order_not_found to an admin');
select pg_temp.run('d_null', 'authenticated', pg_temp.u(4), 'select public.admin_get_order(null)::text');
select pg_temp.expect_err('d_null', 'P0001', 'invalid_arguments', 'DETAIL: a null order id is rejected');

-- ===========================================================================
-- E. NON-ADMINS AND ANONYMOUS ARE DENIED (with positive controls above: admin got the same rows)
-- ===========================================================================
-- customer (also asking about their OWN order and with a list that would match their own data)
select pg_temp.list('e_c_l', 'authenticated', pg_temp.u(1), $$p_search => 'T6B'$$);
select pg_temp.list('e_c_l0', 'authenticated', pg_temp.u(1), '');
select pg_temp.get('e_c_own', 'authenticated', pg_temp.u(1), pg_temp.res('o1'));
select pg_temp.get('e_c_oth', 'authenticated', pg_temp.u(1), pg_temp.res('o3'));
select pg_temp.get('e_c_nf', 'authenticated', pg_temp.u(1), '00000000-0000-4000-8000-6b9999999999');
select pg_temp.gated('e_c_l',   'DENIED customer: admin_list_orders (with a search)');
select pg_temp.gated('e_c_l0',  'DENIED customer: admin_list_orders (no arguments)');
select pg_temp.gated('e_c_own', 'DENIED customer: admin_get_order on their OWN order');
select pg_temp.gated('e_c_oth', 'DENIED customer: admin_get_order on someone else''s order');
select pg_temp.gated('e_c_nf',  'DENIED customer: unknown id gives the same refusal (the gate runs first, nothing is revealed)');
select pg_temp.ok(
  (select res from t_res where k in ('e_c_l','e_c_l0','e_c_own','e_c_oth','e_c_nf') and res is not null limit 1) is null,
  'DENIED customer: no call returned any data');

-- staff: fulfilment role, not an admin
select pg_temp.list('e_s_l', 'authenticated', pg_temp.u(3), $$p_search => 'T6B'$$);
select pg_temp.get('e_s_g', 'authenticated', pg_temp.u(3), pg_temp.res('o1'));
select pg_temp.gated('e_s_l', 'DENIED staff: admin_list_orders');
select pg_temp.gated('e_s_g', 'DENIED staff: admin_get_order');

-- authenticated role but no user in the JWT, and a service-role call (no auth.uid())
select pg_temp.run('e_n_l', 'authenticated', null, $$select public.admin_list_orders()::text$$);
select pg_temp.run('e_n_g', 'authenticated', null, format('select public.admin_get_order(%L::uuid)::text', pg_temp.res('o1')));
select pg_temp.gated('e_n_l', 'DENIED signed-out JWT: admin_list_orders');
select pg_temp.gated('e_n_g', 'DENIED signed-out JWT: admin_get_order');
select pg_temp.run('e_sr_l', 'service_role', null, $$select public.admin_list_orders()::text$$);
select pg_temp.run('e_sr_g', 'service_role', null, format('select public.admin_get_order(%L::uuid)::text', pg_temp.res('o1')));
select pg_temp.denied('e_sr_l', 'DENIED service_role without a user: admin_list_orders (no auth.uid())');
select pg_temp.denied('e_sr_g', 'DENIED service_role without a user: admin_get_order (no auth.uid())');

-- anonymous
select pg_temp.run('e_a_l', 'anon', null, $$select public.admin_list_orders()::text$$);
select pg_temp.run('e_a_g', 'anon', null, format('select public.admin_get_order(%L::uuid)::text', pg_temp.res('o1')));
select pg_temp.denied('e_a_l', 'DENIED anonymous: admin_list_orders (permission denied)');
select pg_temp.denied('e_a_g', 'DENIED anonymous: admin_get_order (permission denied)');

-- Claims other than the verified user id cannot grant admin: a customer whose JWT claims "admin".
select pg_temp.run_claims('e_claim', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin', 'roles', jsonb_build_array('admin'))),
  $$select public.admin_list_orders()::text$$);
select pg_temp.gated('e_claim', 'DENIED customer with forged admin claims in the JWT');

-- Admin role is checked live: removing it revokes access in the same transaction.
select pg_temp.list('e_rev1', 'authenticated', pg_temp.u(4), $$p_search => 'T6B'$$);
delete from public.user_roles where user_id = pg_temp.u(4) and role = 'admin';
select pg_temp.list('e_rev2', 'authenticated', pg_temp.u(4), $$p_search => 'T6B'$$);
select pg_temp.ok(pg_temp.tot('e_rev1') = 4, 'REVOCATION control: the admin could list before the role was removed');
select pg_temp.gated('e_rev2', 'REVOCATION: the same user is refused once the admin role is removed');
insert into public.user_roles (user_id, role) values (pg_temp.u(4), 'admin');
select pg_temp.list('e_rev3', 'authenticated', pg_temp.u(4), $$p_search => 'T6B'$$);
select pg_temp.ok(pg_temp.tot('e_rev3') = 4, 'REVOCATION: access returns when the role is granted again');

-- ===========================================================================
-- F. PHASE 5B.2 ORDER-STATUS AUTHORISATION IS INTACT; PAYMENT STATE CANNOT BE MANIPULATED
-- ===========================================================================
-- Fresh COD order for status tests.
select pg_temp.place('o5', pg_temp.u(1), 't6b_pick', 'cash_on_delivery', pg_temp.p(1), 1);
select pg_temp.ok((select err from t_res where k = 'o5') is null and pg_temp.res('o5') is not null, 'FIXTURE: order 5 placed');
select pg_temp.stamp_history(60);

select pg_temp.set_status('f_cust', 'authenticated', pg_temp.u(1), pg_temp.res('o5'), 'processing');
select pg_temp.set_status('f_anon', 'anon', null, pg_temp.res('o5'), 'processing');
select pg_temp.gated('f_cust', 'STATUS: a customer still cannot call set_order_status');
select pg_temp.denied('f_anon', 'STATUS: anonymous still cannot call set_order_status');

select pg_temp.set_status('f_paid_s', 'authenticated', pg_temp.u(3), pg_temp.res('o5'), 'paid');
select pg_temp.set_status('f_paid_a', 'authenticated', pg_temp.u(4), pg_temp.res('o5'), 'paid');
select pg_temp.set_status('f_ref_s',  'authenticated', pg_temp.u(3), pg_temp.res('o5'), 'refunded');
select pg_temp.set_status('f_ref_a',  'authenticated', pg_temp.u(4), pg_temp.res('o5'), 'refunded', 'T6B try refund');
select pg_temp.expect_err('f_paid_s', 'P0001', 'payment_state_reserved', 'STATUS: staff cannot mark an order paid');
select pg_temp.expect_err('f_paid_a', 'P0001', 'payment_state_reserved', 'STATUS: even an admin cannot mark an order paid');
select pg_temp.expect_err('f_ref_s',  'P0001', 'payment_state_reserved', 'STATUS: staff cannot mark an order refunded');
select pg_temp.expect_err('f_ref_a',  'P0001', 'payment_state_reserved', 'STATUS: even an admin cannot mark an order refunded');

-- Unpaid online order (O2) cannot enter fulfilment, for staff or admin.
select pg_temp.set_status('f_pay_s', 'authenticated', pg_temp.u(3), pg_temp.res('o2'), 'processing');
select pg_temp.set_status('f_pay_a', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'processing', 'T6B force it');
select pg_temp.expect_err('f_pay_s', 'P0001', 'transition_not_allowed', 'STATUS: staff cannot move an unpaid mpesa order into fulfilment');
select pg_temp.expect_err('f_pay_a', 'P0001', 'payment_not_confirmed', 'STATUS: an admin override cannot fulfil an unpaid mpesa order either');

-- Non-standard transition: staff refused, admin needs a reason.
select pg_temp.set_status('f_tr_s', 'authenticated', pg_temp.u(3), pg_temp.res('o5'), 'delivered');
select pg_temp.set_status('f_tr_a', 'authenticated', pg_temp.u(4), pg_temp.res('o5'), 'delivered');
select pg_temp.expect_err('f_tr_s', 'P0001', 'transition_not_allowed', 'STATUS: staff cannot make a non-standard transition');
select pg_temp.expect_err('f_tr_a', 'P0001', 'admin_note_required', 'STATUS: an admin override still requires a reason');

-- The legitimate paths still work and show up in the admin detail.
select pg_temp.set_status('f_ok_s', 'authenticated', pg_temp.u(3), pg_temp.res('o5'), 'processing');
select pg_temp.stamp_history(50);
select pg_temp.set_status('f_ok_a', 'authenticated', pg_temp.u(4), pg_temp.res('o5'), 'cancelled', 'T6B admin cancel');
select pg_temp.stamp_history(40);
select pg_temp.expect('f_ok_s', 'processing', 'STATUS: staff can still make a standard transition (pending -> processing)');
select pg_temp.expect('f_ok_a', 'cancelled',  'STATUS: an admin can still cancel');
select pg_temp.get('f_d5', 'authenticated', pg_temp.u(4), pg_temp.res('o5'));
select pg_temp.ok(
  pg_temp.j('f_d5') #>> '{order,status}' = 'cancelled'
  and (select array_agg(e ->> 'new_status' order by ord) from jsonb_array_elements(pg_temp.j('f_d5') -> 'history') with ordinality t(e, ord))
      = array['pending', 'processing', 'cancelled']
  and pg_temp.j('f_d5') #>> '{history,2,changed_by_name}' = 'T6B Admin',
  'STATUS: admin_get_order shows the status moves made through set_order_status() and who made them');
select pg_temp.ok(
  pg_temp.j('f_d5') #>> '{order,payment_status}' = 'pending'
  and (select payment_status::text from public.orders where id = pg_temp.res('o5')::uuid) = 'pending',
  'STATUS: none of the attempts above changed payment_status');

-- Direct writes to orders from every browser role are blocked, and the rows are re-read as owner.
select pg_temp.run('w_c', 'authenticated', pg_temp.u(1),
  format($$with u as (update public.orders set payment_status = 'paid', status = 'paid' where id = %L returning 1) select count(*)::text from u$$, pg_temp.res('o1')));
select pg_temp.run('w_s', 'authenticated', pg_temp.u(3),
  format($$with u as (update public.orders set payment_status = 'paid' where id = %L returning 1) select count(*)::text from u$$, pg_temp.res('o1')));
select pg_temp.run('w_a', 'authenticated', pg_temp.u(4),
  format($$with u as (update public.orders set payment_status = 'paid', total_cents = 1, subtotal_cents = 1 where id = %L returning 1) select count(*)::text from u$$, pg_temp.res('o1')));
select pg_temp.run('w_an', 'anon', null,
  format($$with u as (update public.orders set payment_status = 'paid' where id = %L returning 1) select count(*)::text from u$$, pg_temp.res('o1')));
select pg_temp.expect_blocked('w_c',  'WRITE: a customer cannot update an order''s payment or status directly');
select pg_temp.expect_blocked('w_s',  'WRITE: staff cannot update an order''s payment status directly');
select pg_temp.expect_blocked('w_a',  'WRITE: an admin cannot update an order''s payment status or totals directly');
select pg_temp.expect_blocked('w_an', 'WRITE: anonymous cannot update orders');
select pg_temp.run('w_i', 'authenticated', pg_temp.u(4),
  format($$with i as (insert into public.order_status_history (order_id, new_status) values (%L, 'paid') returning 1) select count(*)::text from i$$, pg_temp.res('o1')));
select pg_temp.run('w_d', 'authenticated', pg_temp.u(4),
  format($$with d as (delete from public.orders where id = %L returning 1) select count(*)::text from d$$, pg_temp.res('o1')));
select pg_temp.expect_blocked('w_i', 'WRITE: an admin cannot insert a history row directly');
select pg_temp.expect_blocked('w_d', 'WRITE: an admin cannot delete an order directly');
select pg_temp.ok(
  (select payment_status::text = 'pending' and status::text = 'pending' and total_cents = 2000 and subtotal_cents = 2000
   from public.orders where id = pg_temp.res('o1')::uuid)
  and (select count(*) from public.order_status_history where order_id = pg_temp.res('o1')::uuid) = 1,
  'WRITE: re-read as owner, O1 is unchanged (pending / pending / 2000) with a single history row');
select pg_temp.get('w_d1', 'authenticated', pg_temp.u(4), pg_temp.res('o1'));
select pg_temp.ok(pg_temp.j('w_d1') #>> '{payment,status}' = 'pending' and (pg_temp.j('w_d1') #>> '{payment,total_cents}')::int = 2000,
  'WRITE: the admin detail also reports O1 unchanged');

-- ===========================================================================
-- G. EXISTING RLS / PHASE 5A.2 PRIVILEGE HARDENING INTACT
-- ===========================================================================
select pg_temp.run('g_own', 'authenticated', pg_temp.u(1), $$select count(*)::text from public.orders$$);
select pg_temp.run('g_oth', 'authenticated', pg_temp.u(1), format($$select count(*)::text from public.orders where user_id = %L$$, pg_temp.u(2)));
select pg_temp.run('g_ownitems', 'authenticated', pg_temp.u(1), format($$select count(*)::text from public.order_items where order_id = %L$$, pg_temp.res('o3')));
select pg_temp.run('g_prof', 'authenticated', pg_temp.u(1), format($$select count(*)::text from public.profiles where id = %L$$, pg_temp.u(2)));
select pg_temp.run('g_staff_o', 'authenticated', pg_temp.u(3),
  format($$select count(*)::text from public.orders where user_id in (%L, %L)$$, pg_temp.u(1), pg_temp.u(2)));
select pg_temp.run('g_staff_p', 'authenticated', pg_temp.u(3), $$select count(*)::text from public.profiles where email like 't6b-customer%'$$);
select pg_temp.run('g_adm_p', 'authenticated', pg_temp.u(4), $$select count(*)::text from public.profiles where email like 't6b-customer%'$$);
select pg_temp.run('g_anon', 'anon', null, $$select count(*)::text from public.orders$$);
select pg_temp.ok((select err from t_res where k = 'g_own') is null and pg_temp.res('g_own')::int >= 3, 'RLS control: a customer can read their own orders (>= 3)');
select pg_temp.expect('g_oth', '0', 'RLS: a customer still cannot read another customer''s orders');
select pg_temp.expect('g_ownitems', '0', 'RLS: a customer still cannot read another customer''s order items');
select pg_temp.expect('g_prof', '0', 'RLS: a customer still cannot read another customer''s profile');
select pg_temp.expect('g_staff_o', '5', 'RLS control: staff still read all orders (fulfilment access unchanged)');
select pg_temp.expect('g_staff_p', '0', 'RLS: staff still cannot read customer profiles (6B.1 did not widen this)');
select pg_temp.expect('g_adm_p', '2', 'RLS control: an admin reads both customer profiles');
select pg_temp.denied('g_anon', 'PRIVILEGES: anonymous still cannot select from orders');

select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.orders', 'INSERT')
  and not has_table_privilege('authenticated', 'public.orders', 'DELETE')
  and not has_table_privilege('authenticated', 'public.orders', 'TRUNCATE')
  and not has_any_column_privilege('anon', 'public.orders', 'UPDATE'),
  'PRIVILEGES: no browser role holds UPDATE/INSERT/DELETE/TRUNCATE on orders');
-- NOTE: has_table_privilege accepts every privilege type; has_any_column_privilege accepts only
-- SELECT, INSERT, UPDATE and REFERENCES (DELETE/TRUNCATE/TRIGGER raise 22023), hence the guard.
-- CASE, not AND: PostgreSQL does not guarantee left-to-right evaluation of AND/OR, but does for CASE.
select pg_temp.ok(
  not exists (
    select 1 from unnest(array['public.orders', 'public.order_items', 'public.order_status_history', 'public.profiles']) t,
                  unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) priv
    where has_table_privilege('anon', t, priv)
          or (case when priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                   then has_any_column_privilege('anon', t, priv) else false end)),
  'PRIVILEGES: anon holds no privilege on orders, order_items, order_status_history or profiles');
select pg_temp.ok(
  not exists (
    select 1 from unnest(array['public.order_items', 'public.order_status_history']) t,
                  unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) priv
    where has_table_privilege('authenticated', t, priv)
          or (case when priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                   then has_any_column_privilege('authenticated', t, priv) else false end))
  and has_table_privilege('authenticated', 'public.order_items', 'SELECT')
  and has_table_privilege('authenticated', 'public.order_status_history', 'SELECT'),
  'PRIVILEGES: authenticated holds only SELECT on order_items and order_status_history');
select pg_temp.ok(
  not exists (select 1 from pg_policies where schemaname = 'public'
              and tablename in ('orders', 'order_items', 'order_status_history')
              and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  'POLICIES: no write policy exists on orders, order_items or order_status_history');
select pg_temp.ok(
  not exists (select 1 from pg_class where oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                'public.order_status_history'::regclass, 'public.profiles'::regclass) and not relrowsecurity),
  'RLS: row level security is still on for orders, items, history and profiles');

-- The new functions
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_get_order(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated',
        'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_order(uuid)', 'EXECUTE')
  and not has_function_privilege('anon',
        'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'PRIVILEGES: the admin order functions are executable by authenticated only; require_admin() by nobody in the browser');
select pg_temp.ok(
  (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('admin_list_orders', 'admin_get_order')) = 2
  and not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname in ('admin_list_orders', 'admin_get_order')
      and (not p.prosecdef or p.provolatile <> 's' or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')),
  'PRIVILEGES: exactly one overload of each; STABLE, SECURITY DEFINER, search_path = public, pg_temp');
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'PRIVILEGES: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'set_order_status') = 1
  and not has_function_privilege('anon', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE'),
  'STATUS: there is still exactly one set_order_status(), with its Phase 5B.2 privileges (no second status mechanism)');
-- Phase 6B.2 added ONE intentional admin status action, admin_set_order_status(uuid, order_status,
-- text, boolean). It is exempted here by exact signature AND only while its body is the gate
-- (require_admin()) in front of the one engine (set_order_status()). Any other function matching
-- the pattern, a second overload, or a look-alike with a different body still fails this check.
-- Before Phase 6B.2 is applied the exemption matches nothing, so this assertion is unchanged for 6B.1.
select pg_temp.ok(
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
              and (p.proname ~* '(admin).*(status|payment|refund)' or p.proname ~* '(mark|set).*(paid|refund)')
              and p.proname not in ('admin_dashboard_summary')
              and not (p.oid = to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)')
                       and p.prosecdef
                       and p.prosrc like '%public.require_admin()%'
                       and p.prosrc like '%public.set_order_status(%')),
  'STATUS: no admin status/payment/refund writer function was added (6B.2 admin_set_order_status exempt only as the require_admin() gate over set_order_status())');
select pg_temp.ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'orders' and indexname = 'orders_placed_at_idx'),
  'INDEX: orders_placed_at_idx exists');

do $$ begin raise notice 'ALL PHASE 6B.1 TESTS PASSED'; end $$;

rollback;
