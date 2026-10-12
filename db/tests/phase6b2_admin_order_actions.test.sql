-- =============================================================================
-- PHASE 6B.2 database test: admin order actions backend.
--
-- STATUS: written for migration 20261004030000_phase6b2_admin_order_actions.sql.
-- NOT RUN. It has not been executed against local PostgreSQL or against the dedicated
-- Phase-5 development Supabase database. Treat every assertion as unproven until it is.
--
-- HOW TO RUN (the dedicated Phase-5 DEV database with ALL migrations through
-- 20261004030000_phase6b2_admin_order_actions.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b2_admin_order_actions.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6B.2 TESTS PASSED" means all
-- passed (the last statement also returns one row, column ok, for the Supabase SQL editor).
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST. A rejected call is
-- rolled back with its sub-transaction, exactly as a failed RPC is.
--
-- NOT-EMPTY PROOF: every "denied" check also proves the order is UNTOUCHED (status, history
-- row count, stock) and is followed by an admin positive control on the same fixture. Denial
-- is asserted as an ERROR (42501), never as "0 rows".
--
-- All fixtures are real: orders come from create_order(); the only owner-level writes are the
-- ones the browser cannot do anyway (a refunded order, an admin role being revoked).
--
-- NOT COVERED HERE: a true two-session race. One session cannot prove a lock holds under
-- concurrency. What IS asserted: the function takes FOR UPDATE on the order row (static check),
-- and repeated / cycled cancellations cannot mint stock (idempotency, sections B and G).
-- Fixtures carry the marker 'T6C'.
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
-- Extra helpers for this file
-- ---------------------------------------------------------------------------
create temp table t_val (k text primary key, v integer);
create or replace function pg_temp.rec(p_k text, p_v integer) returns void language sql as $$
  insert into t_val values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create or replace function pg_temp.val(p_k text) returns integer language sql as $$
  select v from t_val where k = p_k $$;

create or replace function pg_temp.d(p_days integer) returns date language sql stable as $$
  select ((now() at time zone 'Africa/Nairobi')::date + p_days) $$;

-- owner-level reads (call only at top level, not under SET ROLE)
create or replace function pg_temp.st(p_order text) returns text language sql as $$
  select status::text from public.orders where id = p_order::uuid $$;
create or replace function pg_temp.pay(p_order text) returns text language sql as $$
  select payment_status::text from public.orders where id = p_order::uuid $$;
create or replace function pg_temp.restocked(p_order text) returns boolean language sql as $$
  select restocked_at is not null from public.orders where id = p_order::uuid $$;
create or replace function pg_temp.hc(p_order text) returns integer language sql as $$
  select count(*)::integer from public.order_status_history where order_id = p_order::uuid $$;
create or replace function pg_temp.pstock(n integer) returns integer language sql as $$
  select stock_quantity from public.products where id = pg_temp.p(n) $$;
create or replace function pg_temp.vstock() returns integer language sql as $$
  select stock_quantity from public.product_variants where id = '00000000-0000-4000-8000-6c2000000001' $$;

-- admin_set_order_status(...) as a role
create or replace function pg_temp.act(
  p_k text, p_role text, p_uid uuid, p_order text, p_status text,
  p_note text default null, p_override boolean default false)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format(
    'select public.admin_set_order_status(%L::uuid, %L::public.order_status, %L, %L::boolean)::text',
    p_order, p_status, p_note, p_override));
end;
$$;

-- an order with one line (optionally a variant, optionally a slot), through create_order()
create or replace function pg_temp.place_line(
  p_k text, p_uid uuid, p_method text, p_payment text, p_product uuid, p_variant uuid, p_qty integer,
  p_slot_date date default null, p_slot_start time default null, p_slot_end time default null)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, 'authenticated', p_uid, format(
    $f$select public.create_order(
         jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'variant_id', %L::uuid, 'quantity', %s)),
         %L, %L::public.payment_method, null, %L::date, %L::time, %L::time, null, null, null, null, null)::text$f$,
    p_product, p_variant, p_qty, p_method, p_payment, p_slot_date, p_slot_start, p_slot_end));
end;
$$;

-- admin result accessors
create or replace function pg_temp.ak(p_k text, p_path text[]) returns text language sql as $$
  select res::jsonb #>> p_path from t_res where k = p_k $$;

-- The call was refused / rolled back: an error, and the order is exactly as it was.
create or replace function pg_temp.untouched(p_order text, p_status text, p_hist integer, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.ok(pg_temp.st(p_order) = p_status and pg_temp.hc(p_order) = p_hist, p_name);
end;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c-customer1@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C Customer One"}'),
  (pg_temp.u(2), 't6c-customer2@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C Customer Two"}'),
  (pg_temp.u(3), 't6c-staff@example.test',     'authenticated', 'authenticated', '{"full_name":"T6C Staff"}'),
  (pg_temp.u(4), 't6c-admin@example.test',     'authenticated', 'authenticated', '{"full_name":"T6C Admin"}'),
  (pg_temp.u(5), 't6c-admin2@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C Admin Two"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(3), 'staff'),
  (pg_temp.u(4), 'admin');                     -- u5 gets the admin role later, in section D

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active, sku) values
  (pg_temp.p(1), 't6c-pa', 'T6C PA', 1000, 100, true, true, 'T6C-PA'),
  (pg_temp.p(2), 't6c-pb', 'T6C PB', 5000, 100, true, true, 'T6C-PB');
insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, is_active) values
  ('00000000-0000-4000-8000-6c2000000001', pg_temp.p(2), 'T6C variant', 5500, 20, true);

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('t6c_pick', 'T6C pickup',      0, null, 0, false, false, true),
  ('t6c_slot', 'T6C slot pickup', 0, null, 0, true,  false, true);
insert into public.delivery_slot_templates
  (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
values ('00000000-0000-4000-8000-6c2000000e01', 'T6C slot', '04:10', '04:40', null, 1, 100, true);

select pg_temp.place_line('o1', pg_temp.u(1), 't6c_pick', 'cash_on_delivery', pg_temp.p(1), null, 2);
select pg_temp.place_line('o2', pg_temp.u(1), 't6c_pick', 'mpesa',            pg_temp.p(1), null, 1);
select pg_temp.place_line('o3', pg_temp.u(2), 't6c_pick', 'cash_on_delivery', pg_temp.p(2), null, 3);
select pg_temp.place_line('o4', pg_temp.u(2), 't6c_pick', 'cash_on_delivery', pg_temp.p(1), null, 4);
select pg_temp.place_line('o5', pg_temp.u(1), 't6c_pick', 'cash_on_delivery', pg_temp.p(2), '00000000-0000-4000-8000-6c2000000001', 2);
select pg_temp.place_line('oc', pg_temp.u(1), 't6c_pick', 'cash_on_delivery', pg_temp.p(2), null, 1);
select pg_temp.place_line('os', pg_temp.u(2), 't6c_pick', 'cash_on_delivery', pg_temp.p(2), null, 1);
select pg_temp.place_line('o6', pg_temp.u(2), 't6c_pick', 'cash_on_delivery', pg_temp.p(2), null, 1);
select pg_temp.place_line('o7', pg_temp.u(2), 't6c_pick', 'cash_on_delivery', pg_temp.p(1), null, 1);
select pg_temp.ok(
  (select count(*) from t_res where k in ('o1','o2','o3','o4','o5','oc','os','o6','o7') and err is null and res is not null) = 9,
  'FIXTURE: nine orders placed through create_order()');
select pg_temp.ok(pg_temp.st(pg_temp.res('o1')) = 'pending' and pg_temp.st(pg_temp.res('o2')) = 'awaiting_payment',
  'FIXTURE: cash order is pending, M-Pesa order is awaiting_payment');

-- A refunded order (payment outcomes are written by the owner / service role only).
update public.orders set status = 'refunded' where id = pg_temp.res('o6')::uuid;
select pg_temp.ok(pg_temp.st(pg_temp.res('o6')) = 'refunded', 'FIXTURE: O6 is refunded');

-- Baselines AFTER all fixture reservations.
select pg_temp.rec('p1_base', pg_temp.pstock(1));
select pg_temp.rec('p2_base', pg_temp.pstock(2));
select pg_temp.rec('v_base',  pg_temp.vstock());

-- ===========================================================================
-- A. ADMIN CAN PERFORM VALID TRANSITIONS (through the existing state machine)
-- ===========================================================================
select pg_temp.act('a1', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'processing');
select pg_temp.ok((select err from t_res where k = 'a1') is null and pg_temp.res('a1') is not null,
  'A1: admin_set_order_status succeeds for an admin');
select pg_temp.ok(pg_temp.ak('a1', array['changed']) = 'true'
  and pg_temp.ak('a1', array['previous_status']) = 'pending'
  and pg_temp.ak('a1', array['order','status']) = 'processing'
  and pg_temp.ak('a1', array['order','id']) = pg_temp.res('o1'),
  'A2: the returned order reflects the new status (changed, previous_status, order.status, order.id)');
select pg_temp.ok(
  (select jsonb_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.j('a1')) k)
    = '["changed","history_entry","order","previous_status"]'::jsonb
  and (select jsonb_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.j('a1') -> 'order') k)
    = '["currency","delivery_method","delivery_slot_date","id","order_number","payment_method","payment_status","placed_at","restocked_at","status","total_cents","updated_at"]'::jsonb
  and (select jsonb_agg(k order by k collate "C") from jsonb_object_keys(pg_temp.j('a1') -> 'history_entry') k)
    = '["changed_by","created_at","id","new_status","note","payment_status","previous_status"]'::jsonb,
  'A3: the result exposes only the documented keys (no address, notes, customer contact or items)');
select pg_temp.ok(
  pg_temp.ak('a1', array['history_entry','new_status']) = 'processing'
  and pg_temp.ak('a1', array['history_entry','previous_status']) = 'pending'
  and pg_temp.ak('a1', array['history_entry','changed_by']) = pg_temp.u(4)::text
  and exists (
    select 1 from public.order_status_history h
    where h.id = (pg_temp.ak('a1', array['history_entry','id']))::uuid
      and h.order_id = pg_temp.res('o1')::uuid
      and h.previous_status = 'pending' and h.new_status = 'processing'
      and h.changed_by = pg_temp.u(4)),
  'A4: order_status_history holds the transition, written by set_order_status() with the admin as changed_by');
select pg_temp.ok(pg_temp.hc(pg_temp.res('o1')) = 2 and pg_temp.pay(pg_temp.res('o1')) = 'pending'
  and pg_temp.ak('a1', array['order','payment_status']) = 'pending',
  'A5: exactly one history row was added and payment_status did not move');

-- The full standard fulfilment chain, one admin action per step.
select pg_temp.act('a_pick', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'picking');
select pg_temp.act('a_pack', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'packed');
select pg_temp.act('a_disp', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'dispatched');
select pg_temp.act('a_out',  'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'out_for_delivery');
select pg_temp.act('a_del',  'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'delivered');
select pg_temp.ok(
  pg_temp.ak('a_pick', array['order','status']) = 'picking'
  and pg_temp.ak('a_pack', array['order','status']) = 'packed'
  and pg_temp.ak('a_disp', array['order','status']) = 'dispatched'
  and pg_temp.ak('a_out',  array['order','status']) = 'out_for_delivery'
  and pg_temp.ak('a_del',  array['order','status']) = 'delivered'
  and (select count(*) from t_res where k in ('a_pick','a_pack','a_disp','a_out','a_del') and err is null) = 5,
  'A6: processing -> picking -> packed -> dispatched -> out_for_delivery -> delivered all succeed');
select pg_temp.ok(pg_temp.hc(pg_temp.res('o1')) = 7 and pg_temp.st(pg_temp.res('o1')) = 'delivered',
  'A7: every step left its own history row (placed + 6 transitions)');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('p1_base') and not pg_temp.restocked(pg_temp.res('o1')),
  'A8: moving an order through fulfilment does not touch stock');

-- Repeating a terminal action follows the set_order_status() contract: a no-op.
select pg_temp.act('a_rep', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'delivered');
select pg_temp.ok(pg_temp.ak('a_rep', array['changed']) = 'false'
  and jsonb_typeof(pg_temp.j('a_rep') -> 'history_entry') = 'null'
  and pg_temp.ak('a_rep', array['previous_status']) = 'delivered'
  and pg_temp.hc(pg_temp.res('o1')) = 7,
  'A9: repeating delivered -> delivered returns changed=false, no history row, no error');

-- Leaving a terminal state is not a standard move.
select pg_temp.act('a_t1', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'cancelled');
select pg_temp.expect_err('a_t1', 'P0001', 'admin_note_required', 'A10: delivered -> cancelled without a reason is refused');
select pg_temp.act('a_t2', 'authenticated', pg_temp.u(4), pg_temp.res('o1'), 'cancelled', 'T6C late cancel');
select pg_temp.expect_err('a_t2', 'P0001', 'override_not_requested',
  'A11: delivered -> cancelled with a note but without p_override is refused (rolled back)');
select pg_temp.untouched(pg_temp.res('o1'), 'delivered', 7, 'A12: after A10/A11 the order is still delivered with 7 history rows');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('p1_base') and not pg_temp.restocked(pg_temp.res('o1')),
  'A13: and no stock moved');

-- ===========================================================================
-- B. CANCELLATION, RESTOCK AND IDEMPOTENCY
-- ===========================================================================
select pg_temp.act('b1', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'cancelled', 'T6C customer asked');
select pg_temp.ok(pg_temp.ak('b1', array['changed']) = 'true'
  and pg_temp.ak('b1', array['order','status']) = 'cancelled'
  and pg_temp.ak('b1', array['order','restocked_at']) is not null
  and pg_temp.ak('b1', array['history_entry','note']) = 'T6C customer asked'
  and pg_temp.ak('b1', array['history_entry','previous_status']) = 'pending',
  'B1: admin cancels a pending order; restocked_at is set; the note is the history note');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('p1_base') + 4 and pg_temp.restocked(pg_temp.res('o4')),
  'B2: cancelling returned the 4 reserved units to stock');
select pg_temp.act('b3', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'cancelled');
select pg_temp.ok(pg_temp.ak('b3', array['changed']) = 'false'
  and pg_temp.ak('b3', array['order','restocked_at']) = pg_temp.ak('b1', array['order','restocked_at'])
  and pg_temp.pstock(1) = pg_temp.val('p1_base') + 4 and pg_temp.hc(pg_temp.res('o4')) = 2,
  'B3: cancelling again is a no-op: no second restock, same restocked_at, no history row');

select pg_temp.act('b4', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'pending');
select pg_temp.expect_err('b4', 'P0001', 'admin_note_required', 'B4: reactivating without a reason is refused');
select pg_temp.act('b5', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'pending', 'T6C reinstate');
select pg_temp.expect_err('b5', 'P0001', 'override_not_requested', 'B5: reactivating with a note but without p_override is refused');
select pg_temp.untouched(pg_temp.res('o4'), 'cancelled', 2, 'B6: refused reactivations changed nothing (status, history)');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('p1_base') + 4 and pg_temp.restocked(pg_temp.res('o4')),
  'B7: refused reactivations changed no stock and kept restocked_at');

select pg_temp.act('b8', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'pending', 'T6C reinstate', true);
select pg_temp.ok(pg_temp.ak('b8', array['changed']) = 'true'
  and pg_temp.ak('b8', array['order','status']) = 'pending'
  and pg_temp.ak('b8', array['order','restocked_at']) is null
  and pg_temp.ak('b8', array['history_entry','note']) = 'Admin override: T6C reinstate',
  'B8: with p_override => true and a reason the override stands, recorded as "Admin override: ..."');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('p1_base') and not pg_temp.restocked(pg_temp.res('o4')),
  'B9: reactivation re-reserved the stock and cleared restocked_at');
select pg_temp.act('b10', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'cancelled');
select pg_temp.act('b11', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'cancelled');
select pg_temp.ok(pg_temp.ak('b10', array['changed']) = 'true' and pg_temp.ak('b11', array['changed']) = 'false'
  and pg_temp.pstock(1) = pg_temp.val('p1_base') + 4 and pg_temp.restocked(pg_temp.res('o4')),
  'B10: cancel -> reactivate -> cancel -> cancel leaves stock at base + 4 (stock cannot be minted)');

-- Variant line: the variant's stock is restocked, the product's is not.
select pg_temp.rec('p2_before_o5', pg_temp.pstock(2));
select pg_temp.act('b12', 'authenticated', pg_temp.u(4), pg_temp.res('o5'), 'cancelled');
select pg_temp.ok(pg_temp.ak('b12', array['order','status']) = 'cancelled'
  and pg_temp.vstock() = pg_temp.val('v_base') + 2
  and pg_temp.pstock(2) = pg_temp.val('p2_before_o5'),
  'B11: cancelling an order with a variant line restocks that variant by its quantity');

-- Payment-gated order (M-Pesa, not paid).
select pg_temp.act('b13', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'processing');
select pg_temp.expect_err('b13', 'P0001', 'admin_note_required', 'B12: awaiting_payment -> processing is not a standard move');
select pg_temp.act('b14', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'processing', 'T6C try to fulfil unpaid', true);
select pg_temp.expect_err('b14', 'P0001', 'payment_not_confirmed',
  'B13: even with an override an unpaid M-Pesa order cannot enter fulfilment (payment gate)');
select pg_temp.act('b15', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'paid', 'T6C fake payment', true);
select pg_temp.expect_err('b15', 'P0001', 'payment_state_reserved', 'B14: an admin cannot mark an order paid (even with override)');
select pg_temp.act('b16', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'refunded', 'T6C fake refund', true);
select pg_temp.expect_err('b16', 'P0001', 'payment_state_reserved', 'B15: an admin cannot mark an order refunded (even with override)');
select pg_temp.untouched(pg_temp.res('o2'), 'awaiting_payment', 1, 'B16: those refusals changed nothing');
select pg_temp.act('b17', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'cancelled');
select pg_temp.ok(pg_temp.ak('b17', array['order','status']) = 'cancelled'
  and pg_temp.pay(pg_temp.res('o2')) = 'pending'
  and pg_temp.pstock(1) = pg_temp.val('p1_base') + 4 + 1,
  'B17: awaiting_payment -> cancelled is standard; payment_status stays pending; its unit is restocked');

-- ===========================================================================
-- C. INVALID TRANSITIONS AND ARGUMENTS FAIL
-- ===========================================================================
select pg_temp.act('c1', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'delivered');
select pg_temp.expect_err('c1', 'P0001', 'admin_note_required', 'C1: a jump pending -> delivered fails');
select pg_temp.act('c2', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'packed', 'T6C skip ahead');
select pg_temp.expect_err('c2', 'P0001', 'override_not_requested', 'C2: a jump pending -> packed with a note, no p_override, fails');
select pg_temp.untouched(pg_temp.res('o3'), 'pending', 1, 'C3: refused jumps changed nothing');
select pg_temp.act('c4', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'bogus');
select pg_temp.expect_err('c4', '22P02', null, 'C4: a status that is not in the enum is rejected');
select pg_temp.act('c5', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), null);
select pg_temp.expect_err('c5', 'P0001', 'invalid_arguments', 'C5: a NULL status is rejected');
select pg_temp.run('c6', 'authenticated', pg_temp.u(4),
  $$select public.admin_set_order_status(null, 'processing'::public.order_status)::text$$);
select pg_temp.expect_err('c6', 'P0001', 'invalid_arguments', 'C6: a NULL order id is rejected');
select pg_temp.act('c7', 'authenticated', pg_temp.u(4), '00000000-0000-4000-8000-6c2000000fff', 'processing');
select pg_temp.expect_err('c7', 'P0001', 'order_not_found', 'C7: an unknown order is rejected');
select pg_temp.act('c8', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'processing', repeat('x', 401));
select pg_temp.expect_err('c8', 'P0001', 'note_too_long', 'C8: a note over 400 characters is rejected');
select pg_temp.act('c9', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'awaiting_payment', 'T6C wrong label', true);
select pg_temp.expect_err('c9', 'P0001', 'payment_method_mismatch',
  'C9: a cash-on-delivery order cannot be put into awaiting_payment (even with override)');
select pg_temp.untouched(pg_temp.res('o3'), 'pending', 1, 'C10: C4-C9 changed nothing');

select pg_temp.act('c11', 'authenticated', pg_temp.u(4), pg_temp.res('o6'), 'pending', 'T6C undo refund', true);
select pg_temp.expect_err('c11', 'P0001', 'transition_not_allowed', 'C11: nothing leaves refunded (override included)');
select pg_temp.act('c12', 'authenticated', pg_temp.u(4), pg_temp.res('o6'), 'cancelled', 'T6C cancel refunded', true);
select pg_temp.expect_err('c12', 'P0001', 'transition_not_allowed', 'C12: refunded -> cancelled is refused too');
select pg_temp.ok(pg_temp.st(pg_temp.res('o6')) = 'refunded', 'C13: O6 is still refunded');

-- A deliberate, explained override is the one way off the standard path.
select pg_temp.act('c14', 'authenticated', pg_temp.u(4), pg_temp.res('o3'), 'picking', 'T6C manual correction', true);
select pg_temp.ok(pg_temp.ak('c14', array['changed']) = 'true'
  and pg_temp.ak('c14', array['order','status']) = 'picking'
  and pg_temp.ak('c14', array['history_entry','note']) = 'Admin override: T6C manual correction'
  and pg_temp.ak('c14', array['history_entry','changed_by']) = pg_temp.u(4)::text,
  'C14: pending -> picking works only as an explicit override, with its reason in the history');

-- The override marker is reserved: a note cannot forge it, with or without p_override.
select pg_temp.act('c15a', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'processing', 'Admin override: forged marker');
select pg_temp.expect_err('c15a', 'P0001', 'note_reserved_prefix', 'C15: a note starting with "Admin override:" is refused on a standard move');
select pg_temp.act('c15b', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'picking', '  ADMIN OVERRIDE:x', true);
select pg_temp.expect_err('c15b', 'P0001', 'note_reserved_prefix', 'C16: the reserved prefix is refused case-insensitively and with p_override => true');
select pg_temp.untouched(pg_temp.res('o7'), 'pending', 1, 'C17: refused reserved-prefix notes changed nothing');

-- p_override => true PERMITS an override; it does not turn a standard move into one.
select pg_temp.act('c18', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'processing', null, true);
select pg_temp.ok(pg_temp.ak('c18', array['changed']) = 'true'
  and pg_temp.ak('c18', array['order','status']) = 'processing'
  and pg_temp.ak('c18', array['history_entry','note']) is null,
  'C18: a standard move with p_override => true succeeds and is recorded as a plain move (no override label)');
select pg_temp.act('c19', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'picking', 'T6C routine note', true);
select pg_temp.ok(pg_temp.ak('c19', array['history_entry','note']) = 'T6C routine note'
  and pg_temp.ak('c19', array['order','status']) = 'picking',
  'C19: a standard move with a note and p_override => true keeps the note unlabelled');

-- Override still needs a real reason, even when confirmed.
select pg_temp.act('c20', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'delivered', null, true);
select pg_temp.expect_err('c20', 'P0001', 'admin_note_required', 'C20: an override with no reason is refused');
select pg_temp.act('c21', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'delivered', 'ab', true);
select pg_temp.expect_err('c21', 'P0001', 'admin_note_required', 'C21: an override with a 2-character reason is refused');
select pg_temp.untouched(pg_temp.res('o7'), 'picking', 3, 'C22: refused overrides changed nothing (placed + processing + picking)');

-- Override matrix: what stays impossible WITH p_override => true.
select pg_temp.act('c23', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'paid', 'T6C matrix', true);
select pg_temp.expect_err('c23', 'P0001', 'payment_state_reserved', 'C23: override cannot target paid');
select pg_temp.act('c24', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'refunded', 'T6C matrix', true);
select pg_temp.expect_err('c24', 'P0001', 'payment_state_reserved', 'C24: override cannot target refunded');
select pg_temp.act('c25', 'authenticated', pg_temp.u(4), pg_temp.res('o2'), 'picking', 'T6C matrix unpaid', true);
select pg_temp.expect_err('c25', 'P0001', 'payment_not_confirmed', 'C25: override cannot move an online-payment order that is not confirmed paid into fulfilment');
select pg_temp.act('c26', 'authenticated', pg_temp.u(4), pg_temp.res('o6'), 'processing', 'T6C matrix refunded', true);
select pg_temp.expect_err('c26', 'P0001', 'transition_not_allowed', 'C26: override cannot move anything out of refunded');
select pg_temp.untouched(pg_temp.res('o7'), 'picking', 3, 'C27: the matrix refusals left the order as it was');
select pg_temp.ok(pg_temp.pay(pg_temp.res('o7')) = 'pending' and pg_temp.pay(pg_temp.res('o2')) = 'pending'
  and pg_temp.st(pg_temp.res('o6')) = 'refunded',
  'C28: and no payment_status moved, O6 is still refunded');

-- Override into a full slot / without stock are refused by the existing triggers (slot case: G5).
select pg_temp.rec('p1_before_h', pg_temp.pstock(1));
update public.products set stock_quantity = 0 where id = pg_temp.p(1);
select pg_temp.act('c29', 'authenticated', pg_temp.u(4), pg_temp.res('o4'), 'pending', 'T6C no stock', true);
select pg_temp.expect_err('c29', 'P0001', 'reactivation_insufficient_stock',
  'C29: override reactivation without enough stock is refused by the existing re-reserve trigger');
update public.products set stock_quantity = pg_temp.val('p1_before_h') where id = pg_temp.p(1);
select pg_temp.untouched(pg_temp.res('o4'), 'cancelled', 4, 'C30: the refused reactivation left O4 cancelled with its 4 history rows (placed, cancel, override reactivate, cancel)');
select pg_temp.ok(pg_temp.restocked(pg_temp.res('o4')) and pg_temp.pstock(1) = pg_temp.val('p1_before_h'),
  'C31: restocked_at kept and stock back at its pre-test value');

-- ===========================================================================
-- D. AUTHORISATION: every refusal leaves the order untouched, an admin then succeeds
-- ===========================================================================
select pg_temp.rec('p2_before_d', pg_temp.pstock(2));
select pg_temp.act('d1', 'anon', null, pg_temp.res('oc'), 'processing');
select pg_temp.denied('d1', 'D1: anon cannot execute admin_set_order_status');
select pg_temp.act('d2', 'authenticated', null, pg_temp.res('oc'), 'processing');
select pg_temp.gated('d2', 'D2: signed-out (authenticated role, no JWT subject) is refused by the admin gate');
select pg_temp.act('d3', 'authenticated', pg_temp.u(1), pg_temp.res('oc'), 'processing');
select pg_temp.gated('d3', 'D3: a customer cannot act on their OWN order');
select pg_temp.act('d4', 'authenticated', pg_temp.u(3), pg_temp.res('oc'), 'processing');
select pg_temp.gated('d4', 'D4: staff who are not admins are refused');
select pg_temp.run_claims('d5', 'authenticated',
  json_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'is_admin', true, 'user_role', 'admin',
    'app_metadata', json_build_object('role', 'admin', 'roles', json_build_array('admin')),
    'user_metadata', json_build_object('role', 'admin'))::jsonb,
  format('select public.admin_set_order_status(%L::uuid, ''processing''::public.order_status)::text', pg_temp.res('oc')));
select pg_temp.gated('d5', 'D5: a forged JWT claiming admin (customer subject) is refused');
select pg_temp.run_claims('d6', 'authenticated',
  json_build_object('sub', pg_temp.u(3), 'role', 'authenticated', 'is_admin', true, 'user_role', 'admin',
    'app_metadata', json_build_object('role', 'admin'))::jsonb,
  format('select public.admin_set_order_status(%L::uuid, ''processing''::public.order_status)::text', pg_temp.res('oc')));
select pg_temp.gated('d6', 'D6: a forged JWT claiming admin (staff subject) is refused');
select pg_temp.run_claims('d7', 'authenticated',
  json_build_object('sub', pg_temp.u(1), 'role', 'service_role')::jsonb,
  format('select public.admin_set_order_status(%L::uuid, ''processing''::public.order_status)::text', pg_temp.res('oc')));
select pg_temp.gated('d7', 'D7: a customer JWT claiming role service_role is refused');
select pg_temp.act('d8', 'service_role', null, pg_temp.res('oc'), 'processing');
select pg_temp.denied('d8', 'D8: service_role without an application user context is refused (gate 42501, or no EXECUTE)');
select pg_temp.untouched(pg_temp.res('oc'), 'pending', 1, 'D9: after D1-D8 the order is still pending with its one history row');
select pg_temp.ok(pg_temp.pstock(2) = pg_temp.val('p2_before_d') and not pg_temp.restocked(pg_temp.res('oc')),
  'D10: and no stock moved');

select pg_temp.act('d11', 'authenticated', pg_temp.u(4), pg_temp.res('oc'), 'processing');
select pg_temp.ok(pg_temp.ak('d11', array['order','status']) = 'processing' and pg_temp.hc(pg_temp.res('oc')) = 2,
  'D11: POSITIVE CONTROL - the admin performs the very same call on the very same order');

-- Staff keep their Phase 5B.2 powers through set_order_status(), and only those.
select pg_temp.set_status('d12', 'authenticated', pg_temp.u(3), pg_temp.res('os'), 'processing');
select pg_temp.expect('d12', 'processing', 'D12: staff can still use set_order_status() (Phase 5B.2 separation intact)');
select pg_temp.act('d13', 'authenticated', pg_temp.u(3), pg_temp.res('os'), 'picking');
select pg_temp.gated('d13', 'D13: but the same staff member cannot use the admin action');
select pg_temp.untouched(pg_temp.res('os'), 'processing', 2, 'D14: the refused staff action changed nothing');

-- The identity comes from the JWT, and the role is checked live on every call.
insert into public.user_roles (user_id, role) values (pg_temp.u(5), 'admin');
select pg_temp.act('d15', 'authenticated', pg_temp.u(5), pg_temp.res('oc'), 'picking');
select pg_temp.ok(pg_temp.ak('d15', array['history_entry','changed_by']) = pg_temp.u(5)::text
  and pg_temp.ak('d15', array['order','status']) = 'picking',
  'D15: a second admin acts, and the history records THAT admin (changed_by from the JWT subject)');
delete from public.user_roles where user_id = pg_temp.u(5) and role = 'admin';
select pg_temp.act('d16', 'authenticated', pg_temp.u(5), pg_temp.res('oc'), 'packed');
select pg_temp.gated('d16', 'D16: once the admin role is revoked the same user is refused immediately');
select pg_temp.untouched(pg_temp.res('oc'), 'picking', 3, 'D17: the revoked admin changed nothing (placed + processing + picking)');

-- ===========================================================================
-- E. NO BROWSER WRITE PATH TO orders
-- ===========================================================================
select pg_temp.run('e1', 'authenticated', pg_temp.u(4),
  format($$with x as (update public.orders set status = 'cancelled' where id = %L::uuid returning 1) select count(*)::text from x$$, pg_temp.res('o3')));
select pg_temp.expect_blocked('e1', 'E1: an admin cannot UPDATE orders.status directly');
select pg_temp.run('e2', 'authenticated', pg_temp.u(4),
  format($$with x as (update public.orders set payment_status = 'paid' where id = %L::uuid returning 1) select count(*)::text from x$$, pg_temp.res('o3')));
select pg_temp.expect_blocked('e2', 'E2: an admin cannot UPDATE orders.payment_status directly');
select pg_temp.run('e3', 'authenticated', pg_temp.u(3),
  format($$with x as (update public.orders set status = 'cancelled' where id = %L::uuid returning 1) select count(*)::text from x$$, pg_temp.res('o3')));
select pg_temp.expect_blocked('e3', 'E3: staff cannot UPDATE orders directly');
select pg_temp.run('e4', 'authenticated', pg_temp.u(4),
  format($$with x as (delete from public.order_status_history where order_id = %L::uuid returning 1) select count(*)::text from x$$, pg_temp.res('o3')));
select pg_temp.expect_blocked('e4', 'E4: an admin cannot delete history rows');
select pg_temp.untouched(pg_temp.res('o3'), 'picking', 2, 'E5: the order is exactly as the admin action left it');
select pg_temp.ok(pg_temp.pay(pg_temp.res('o3')) = 'pending', 'E6: payment_status is untouched');

-- ===========================================================================
-- F. STATIC SECURITY CONFIGURATION
-- ===========================================================================
select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
  and not has_table_privilege('anon', 'public.orders', 'UPDATE')
  and not has_any_column_privilege('anon', 'public.orders', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.orders', 'INSERT')
  and not has_table_privilege('authenticated', 'public.orders', 'DELETE'),
  'F1: no browser role has UPDATE (table or column), INSERT or DELETE on public.orders');
select pg_temp.ok(
  not exists (select 1 from pg_policies where schemaname = 'public'
              and tablename in ('orders', 'order_items', 'order_status_history')
              and cmd in ('UPDATE', 'INSERT', 'DELETE', 'ALL'))
  and not exists (select 1 from pg_class c
                  where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                                  'public.order_status_history'::regclass, 'public.user_roles'::regclass)
                    and not c.relrowsecurity),
  'F2: no write policy on the order tables and RLS is still on for them and user_roles');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_set_order_status') = 1
  and exists (select 1 from pg_proc p
              where p.oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure
                and p.prosecdef and p.provolatile = 'v'
                and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'),
  'F3: exactly one admin_set_order_status(); VOLATILE, SECURITY DEFINER, search_path = public, pg_temp');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_set_order_status(uuid,public.order_status,text,boolean)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_set_order_status(uuid,public.order_status,text,boolean)', 'EXECUTE')
  and not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'F4: anon and PUBLIC cannot EXECUTE admin_set_order_status; authenticated can (and the function gates itself)');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE')
  and (select prosrc from pg_proc where oid = 'public.require_admin()'::regprocedure) like '%not_authorised%'
  and (select prosrc from pg_proc where oid = 'public.require_admin()'::regprocedure) like '%is_admin%',
  'F5: require_admin() is intact and still not executable by a browser role');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'set_order_status') = 1
  and not has_function_privilege('anon', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
  and (select prosrc from pg_proc where oid = 'public.set_order_status(uuid,public.order_status,text)'::regprocedure)
        like '%payment_state_reserved%'
  and (select prosrc from pg_proc where oid = 'public.set_order_status(uuid,public.order_status,text)'::regprocedure)
        like '%admin_note_required%',
  'F6: there is still exactly one set_order_status(), with its Phase 5B.2 rules and privileges (no second state machine)');
select pg_temp.ok(
  (select prosrc from pg_proc where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure)
    like '%public.require_admin()%'
  and (select prosrc from pg_proc where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure)
    like '%public.set_order_status(%'
  and (select lower(prosrc) from pg_proc where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure)
    like '%for update%'
  -- Phase 6I.2: the function now also writes ONE admin_audit_log row. That insert is the only write
  -- allowed; any other table write, stock change or payment_status change is still refused.
  and (select regexp_replace(lower(prosrc), 'insert into public\.admin_audit_log', '', 'g') from pg_proc where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure)
    !~ '(update public\.|insert into|delete from|stock_quantity|set payment_status)'
  and (select (length(lower(prosrc)) - length(replace(lower(prosrc), 'insert into public.admin_audit_log', ''))) / length('insert into public.admin_audit_log')
       from pg_proc where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure) = 1,
  'F7: the function gates with require_admin(), locks the order row, delegates to set_order_status(), and writes no table itself except its single admin_audit_log row (6I.2)');
select pg_temp.ok(
  (select count(*) from pg_trigger t
   where not t.tgisinternal and t.tgenabled <> 'D'
     and t.tgrelid = 'public.orders'::regclass
     and t.tgfoid in ('public.restock_cancelled_order()'::regprocedure,
                      'public.guard_order_reactivation_capacity()'::regprocedure,
                      'public.log_order_status_change()'::regprocedure)) >= 3,
  'F8: the restock, reactivation-capacity and history triggers on orders are still enabled');
select pg_temp.ok(
  -- Later phases added admin functions: 6G.4A payment readers, 6I.1 audit-log reader and its two trigger functions.
  -- Sorted bytewise (collate "C") so the comparison does not depend on the database collation.
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
    = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[]
  and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                  and (proname ~* '(mark|set).*(paid|refund)' or proname ~* 'admin.*(payment|refund)')
                  and proname !~ '^admin_(get|list)_(payment|refund)'),  -- read-only 6G.4A readers are allowed; any writer is not
  'F9: the admin API is exactly the known functions (the original fifteen, plus the 6G.4A payment readers and the 6I.1 audit-log reader and its two trigger functions) (admin_list_inventory_adjustments from 6C.2.2B.1 + admin_adjust_inventory from 6C.2.2A.2 + 4 from 6A-6B.2 + admin_list_products from 6C.1A.1 + admin_get_product from 6C.1A.2 + admin_create_product / admin_update_product from 6C.1B.1 + admin_set_product_active / admin_create_product_variant / admin_update_product_variant from 6C.1B.2 + admin_list_inventory / admin_get_inventory from 6C.2.1); no payment or refund writer exists');
select pg_temp.ok(
  (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     -- Phase 6G.3 added apply_payment_outcome() and record_cod_payment(), which update ONLY
     -- orders.payment_status (never orders.status). So the invariant is about writers of orders.status:
     -- an UPDATE of orders whose SET list starts with status. SQL comments are ignored.
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'update\s+(public\.)?orders(\s+[a-z_]+)?\s+set\s+status\M') = array['set_order_status']
  and (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'set_order_status\s*\(') = array['admin_set_order_status'],
  'F12: structurally ONE status writer - only set_order_status() updates orders.status (payment_status writers from 6G.3 are separate), and only admin_set_order_status() calls it');
select pg_temp.ok(
  not exists (select 1 from pg_trigger t where not t.tgisinternal and t.tgrelid = 'public.orders'::regclass
              and t.tgfoid in (select oid from pg_proc where pronamespace = 'public'::regnamespace
                               and proname in ('admin_set_order_status', 'require_admin'))),
  'F13: the admin action is not wired in as a trigger');
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'F10: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_order') = 1
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
       and proname in ('is_admin', 'is_staff', 'has_role')) = 3,
  'F11: create_order() and the role helpers are unchanged in number (no overloads added)');

-- ===========================================================================
-- G. DELIVERY SLOT BEHAVIOUR IS PRESERVED
-- ===========================================================================
select pg_temp.rec('g_base', pg_temp.pstock(1));
select pg_temp.place_line('s1', pg_temp.u(1), 't6c_slot', 'cash_on_delivery', pg_temp.p(1), null, 1, pg_temp.d(2), '04:10', '04:40');
select pg_temp.ok((select err from t_res where k = 's1') is null and pg_temp.res('s1') is not null
  and public.delivery_slot_booked_count(pg_temp.d(2), '04:10', '04:40') = 1
  and pg_temp.pstock(1) = pg_temp.val('g_base') - 1,
  'G1: FIXTURE - an order holds the capacity-1 slot and reserved one unit');
select pg_temp.place_line('s2x', pg_temp.u(2), 't6c_slot', 'cash_on_delivery', pg_temp.p(1), null, 1, pg_temp.d(2), '04:10', '04:40');
select pg_temp.ok((select err from t_res where k = 's2x') is not null,
  'G2: CONTROL - while the slot is full a second order for it is refused');

select pg_temp.act('g3', 'authenticated', pg_temp.u(4), pg_temp.res('s1'), 'cancelled', 'T6C free the slot');
select pg_temp.ok(pg_temp.ak('g3', array['order','status']) = 'cancelled'
  and public.delivery_slot_booked_count(pg_temp.d(2), '04:10', '04:40') = 0
  and pg_temp.pstock(1) = pg_temp.val('g_base'),
  'G3: an admin cancellation frees the delivery slot and restocks');
select pg_temp.place_line('s2', pg_temp.u(2), 't6c_slot', 'cash_on_delivery', pg_temp.p(1), null, 1, pg_temp.d(2), '04:10', '04:40');
select pg_temp.ok((select err from t_res where k = 's2') is null
  and public.delivery_slot_booked_count(pg_temp.d(2), '04:10', '04:40') = 1
  and pg_temp.pstock(1) = pg_temp.val('g_base') - 1,
  'G4: the freed slot is bookable again');

select pg_temp.act('g5', 'authenticated', pg_temp.u(4), pg_temp.res('s1'), 'pending', 'T6C reinstate into full slot', true);
select pg_temp.expect_err('g5', 'P0001', 'reactivation_slot_full',
  'G5: reactivating the first order into the now-full slot is refused by the existing capacity guard');
select pg_temp.untouched(pg_temp.res('s1'), 'cancelled', 2, 'G6: the refused reactivation left the order cancelled with 2 history rows');
select pg_temp.ok(pg_temp.pstock(1) = pg_temp.val('g_base') - 1 and pg_temp.restocked(pg_temp.res('s1'))
  and public.delivery_slot_booked_count(pg_temp.d(2), '04:10', '04:40') = 1,
  'G7: and re-reserved no stock, kept restocked_at, and did not overbook the slot');

select pg_temp.act('g8', 'authenticated', pg_temp.u(4), pg_temp.res('s2'), 'cancelled');
select pg_temp.act('g9', 'authenticated', pg_temp.u(4), pg_temp.res('s1'), 'pending', 'T6C reinstate into free slot', true);
select pg_temp.ok(pg_temp.ak('g9', array['order','status']) = 'pending'
  and pg_temp.ak('g9', array['order','restocked_at']) is null
  and public.delivery_slot_booked_count(pg_temp.d(2), '04:10', '04:40') = 1
  and pg_temp.pstock(1) = pg_temp.val('g_base') - 1,
  'G8: once the slot has room the reactivation succeeds: slot taken once, stock re-reserved once');

-- ===========================================================================
-- H. REGRESSION: Phase 5B.2, 6A and 6B.1 behaviour is unchanged next to the new function
-- ===========================================================================
-- 5B.2: set_order_status() keeps its own authorisation (customer refused, staff limited).
select pg_temp.set_status('h1', 'authenticated', pg_temp.u(1), pg_temp.res('o7'), 'packed');
select pg_temp.gated('h1', 'H1 (5B.2): a customer still cannot call set_order_status()');
select pg_temp.set_status('h2', 'authenticated', pg_temp.u(3), pg_temp.res('o7'), 'delivered', 'T6C staff jump');
select pg_temp.expect_err('h2', 'P0001', 'transition_not_allowed', 'H2 (5B.2): staff still cannot make a non-standard move, with or without a note');
select pg_temp.set_status('h3', 'authenticated', pg_temp.u(3), pg_temp.res('o7'), 'packed');
select pg_temp.expect('h3', 'packed', 'H3 (5B.2): staff can still make a standard move through set_order_status()');
select pg_temp.untouched(pg_temp.res('o7'), 'packed', 4, 'H4 (5B.2): exactly the one standard staff move was recorded');
select pg_temp.set_status('h5', 'authenticated', pg_temp.u(4), pg_temp.res('o7'), 'paid', 'T6C direct');
select pg_temp.expect_err('h5', 'P0001', 'payment_state_reserved', 'H5 (5B.2): set_order_status() itself still refuses paid for an admin');

-- 5B.2: customers see only their own orders; no browser write path to roles.
select pg_temp.run('h6', 'authenticated', pg_temp.u(1),
  format('select count(*)::text from public.orders where id = %L::uuid', pg_temp.res('o3')));
select pg_temp.expect('h6', '0', 'H6 (5B.2 RLS): a customer cannot read another customer''s order');
select pg_temp.run('h7', 'authenticated', pg_temp.u(1),
  format('select count(*)::text from public.orders where id = %L::uuid', pg_temp.res('o1')));
select pg_temp.expect('h7', '1', 'H7 (5B.2 RLS): ...but can read their own');
select pg_temp.run('h8', 'authenticated', pg_temp.u(1),
  format('with i as (insert into public.user_roles (user_id, role) values (%L, %L) returning 1) select count(*)::text from i', pg_temp.u(1), 'admin'));
select pg_temp.expect_blocked('h8', 'H8 (6A): a customer still cannot make themselves admin');
-- H9: role semantics (Phase 5B.2 contract: is_admin()/is_staff() answer only about the CALLER,
-- so they must be asked as that user; at owner level there is no JWT and they return false for
-- everyone). is_staff() is true for staff AND admin; is_admin() is true for admin only.
select pg_temp.ok(
  (select array_agg(role::text order by role::text) from public.user_roles where user_id = pg_temp.u(4)) = array['admin']
  and (select array_agg(role::text order by role::text) from public.user_roles where user_id = pg_temp.u(3)) = array['staff']
  and not exists (select 1 from public.user_roles where user_id = pg_temp.u(1)),
  'H9a (6A): FIXTURE - the admin user holds only admin, the staff user only staff, the customer no role (user_roles read at owner level)');
select pg_temp.run('h9_adm', 'authenticated', pg_temp.u(4),
  format('select public.is_admin(%L)::text || '','' || public.is_staff(%L)::text', pg_temp.u(4), pg_temp.u(4)));
select pg_temp.run('h9_stf', 'authenticated', pg_temp.u(3),
  format('select public.is_admin(%L)::text || '','' || public.is_staff(%L)::text', pg_temp.u(3), pg_temp.u(3)));
select pg_temp.run('h9_cus', 'authenticated', pg_temp.u(1),
  format('select public.is_admin(%L)::text || '','' || public.is_staff(%L)::text', pg_temp.u(1), pg_temp.u(1)));
select pg_temp.expect('h9_adm', 'true,true',   'H9b (6A): the admin is_admin = true and is_staff = true (admin is staff by the 5B.2 contract)');
select pg_temp.expect('h9_stf', 'false,true',  'H9c (6A): staff is_admin = false (staff is not admin) and is_staff = true');
select pg_temp.expect('h9_cus', 'false,false', 'H9d (6A): a customer is neither admin nor staff');
-- Asking about SOMEONE ELSE still returns false (no role probing), including about the admin.
select pg_temp.run('h9_x1', 'authenticated', pg_temp.u(1),
  format('select public.is_admin(%L)::text || '','' || public.is_staff(%L)::text', pg_temp.u(4), pg_temp.u(4)));
select pg_temp.run('h9_x2', 'authenticated', pg_temp.u(3),
  format('select public.is_admin(%L)::text || '','' || public.is_staff(%L)::text', pg_temp.u(4), pg_temp.u(4)));
select pg_temp.expect('h9_x1', 'false,false', 'H9e (5B.2): a customer cannot learn that another user is admin or staff');
select pg_temp.expect('h9_x2', 'false,false', 'H9f (5B.2): staff cannot learn that another user is admin or staff');

-- 6A / 6B.1: the admin reads are still admin-only and see this phase's changes.
select pg_temp.run('h10', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.gated('h10', 'H10 (6B.1): staff are still refused by admin_list_orders()');
select pg_temp.run('h11', 'authenticated', pg_temp.u(1), 'select public.admin_list_orders()::text');
select pg_temp.gated('h11', 'H11 (6B.1): customers are still refused by admin_list_orders()');
select pg_temp.run('h12', 'authenticated', pg_temp.u(4), 'select public.admin_list_orders()::text');
select pg_temp.ok((select err from t_res where k = 'h12') is null
  and jsonb_typeof(pg_temp.j('h12') -> 'orders') = 'array' and (pg_temp.j('h12') ->> 'total')::integer >= 9,
  'H12 (6B.1): an admin still lists orders (the fixtures are visible)');
select pg_temp.run('h13', 'authenticated', pg_temp.u(3), format('select public.admin_get_order(%L::uuid)::text', pg_temp.res('o7')));
select pg_temp.gated('h13', 'H13 (6B.1): staff are still refused by admin_get_order()');
select pg_temp.run('h14', 'authenticated', pg_temp.u(4), format('select public.admin_get_order(%L::uuid)::text', pg_temp.res('o7')));
select pg_temp.ok((select err from t_res where k = 'h14') is null
  and pg_temp.j('h14') -> 'order' ->> 'status' = 'packed'
  and exists (select 1 from jsonb_array_elements(pg_temp.j('h14') -> 'history') e
              where e ->> 'new_status' = 'picking' and e ->> 'note' = 'T6C routine note'),
  'H14 (6B.1): admin_get_order() shows the order''s current status and the history written by admin_set_order_status()');
select pg_temp.run('h15', 'authenticated', pg_temp.u(3), 'select public.admin_dashboard_summary()::text');
select pg_temp.gated('h15', 'H15 (6A): staff are still refused by admin_dashboard_summary()');
select pg_temp.run('h16', 'authenticated', pg_temp.u(4), 'select public.admin_dashboard_summary()::text');
select pg_temp.ok((select err from t_res where k = 'h16') is null and pg_temp.j('h16') is not null,
  'H16 (6A): an admin still reads the dashboard summary');
select pg_temp.run('h17', 'anon', null, 'select public.admin_dashboard_summary()::text');
select pg_temp.denied('h17', 'H17 (6A): anon still cannot execute the admin dashboard');

do $$ begin raise notice 'ALL PHASE 6B.2 TESTS PASSED'; end $$;

rollback;

select 'ALL PHASE 6B.2 TESTS PASSED'::text as ok;
