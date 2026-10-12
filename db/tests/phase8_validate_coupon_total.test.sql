-- =============================================================================
-- PHASE 8 follow-up database test: validate_coupon() returns the server's final payable total.
--
-- STATUS: written for migration 20261009020000_phase8_validate_coupon_total.sql.
-- NOT RUN against any database when it was written (no PostgreSQL was available).
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261009020000_phase8_validate_coupon_total.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase8_validate_coupon_total.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises "FAIL: <name>";
-- each pass prints "PASS: <name>". "ALL PHASE 8 TOTAL TESTS PASSED" means all passed. Fixture codes and
-- methods start with P8T / p8t_. Automatic promotions are deactivated INSIDE the transaction (rolled back).
--
-- COVERS  1 shape and privileges   2 no delivery selection -> old reply, no total keys
--         3 pickup / fee / free-over totals with a percentage, a capped-by-subtotal fixed and no coupon
--         4 rejected coupon, unknown or inactive method -> no amounts
--         5 the total equals what create_order() charges, and expected = total is accepted (total - 1 is not)
-- =============================================================================
begin;

create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_name;
  end if;
  raise notice 'PASS: %', p_name;
end;
$$;

update public.promotions set is_active = false where code is null;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-000000000901', 'p8t-u1@example.test', 'authenticated', 'authenticated');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-0000000009b1', 'p8t-product', 'P8T product', 10000, 1000, true, true);

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('p8t_free', 'P8T pickup, free',          0,    null,  0, false, false, true),
  ('p8t_fee',  'P8T pickup, fee 5000',      5000, null,  0, false, false, true),
  ('p8t_over', 'P8T fee 5000, free over 1', 5000, 1,     0, false, false, true),
  ('p8t_off',  'P8T inactive',              5000, null,  0, false, false, false);

insert into public.promotions (code, name, discount_type, value, max_discount_cents, min_order_cents, is_active) values
  ('P8T-TEN',    'Ten percent', 'percentage', 1000,  null, 0, true),
  ('P8T-FIXBIG', 'Fixed huge',  'fixed',      99999, null, 0, true),
  ('P8T-OFF',    'Inactive',    'percentage', 1000,  null, 0, false);

create temp table t_res (k text primary key, res text, err text, state text, detail text);
create or replace function pg_temp.u1() returns uuid language sql as $$ select '00000000-0000-4000-8000-000000000901'::uuid $$;
create or replace function pg_temp.items(p_qty integer default 1) returns text language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', '00000000-0000-4000-8000-0000000009b1', 'variant_id', null, 'quantity', p_qty))::text $$;

-- Runs p_sql as a real API role (anon / authenticated) and records result or error.
create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claim.role', case when p_uid is null then '' else p_role end, true);
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
  insert into t_res values (p_k, v_res, v_err, v_state, nullif(v_detail, ''))
  on conflict (k) do update set res = excluded.res, err = excluded.err, state = excluded.state, detail = excluded.detail;
end;
$$;

-- validate_coupon as a signed-in customer: code and method may be NULL.
create or replace function pg_temp.vc(p_k text, p_code text, p_method text, p_qty integer default 1)
returns void language sql as $$
  select pg_temp.run(p_k, 'authenticated', pg_temp.u1(),
    format('select public.validate_coupon(%L::jsonb, %L, %L)::text', pg_temp.items(p_qty), p_code, p_method)) $$;
create or replace function pg_temp.r(p_k text) returns jsonb language sql as $$ select res::jsonb from t_res where k = p_k $$;

-- ---------------------------------------------------------------------------
-- 1. Shape and privileges
-- ---------------------------------------------------------------------------
select pg_temp.run('anon', 'anon', null,
  format('select public.validate_coupon(%L::jsonb, %L, %L)::text', pg_temp.items(), 'P8T-TEN', 'p8t_fee'));
do $$
begin
  perform pg_temp.ok((select count(*) from pg_proc where proname = 'validate_coupon'
    and pronamespace = 'public'::regnamespace) = 1, 'exactly one validate_coupon() overload');
  perform pg_temp.ok((select pronargs from pg_proc where proname = 'validate_coupon'
    and pronamespace = 'public'::regnamespace) = 4, 'validate_coupon() takes 4 arguments (items, code, delivery method, zone)');
  perform pg_temp.ok(to_regprocedure('public.validate_coupon(jsonb,text)') is null, 'the old 2-argument function is gone');
  perform pg_temp.ok(not exists (
    select 1 from pg_proc p, unnest(p.proargnames) n
     where p.proname = 'validate_coupon' and p.pronamespace = 'public'::regnamespace
       and (n ilike '%discount%' or n ilike '%fee%' or n ilike '%subtotal%' or n ilike '%total%' or n ilike '%amount%')),
    'no argument can carry an amount');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.validate_coupon(jsonb,text,text,uuid)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.validate_coupon(jsonb,text,text,uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.validate_coupon(jsonb,text,text,uuid)', 'EXECUTE'),
    'authenticated only (not anon, not service_role)');
  perform pg_temp.ok((select err is not null and state = '42501' and res is null from t_res where k = 'anon'),
    'anon cannot call validate_coupon');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Without a delivery method: the old reply exactly, no total keys
-- ---------------------------------------------------------------------------
select pg_temp.vc('nodel_code', 'p8t-ten', null);
select pg_temp.vc('nodel_none',  null,      null);
do $$
begin
  perform pg_temp.ok(pg_temp.r('nodel_code') = jsonb_build_object('ok', true, 'applied', true, 'code', 'P8T-TEN',
      'name', 'Ten percent', 'discount_type', 'percentage', 'discount_value', 1000, 'discount_cents', 1000,
      'subtotal_cents', 10000, 'eligible_cents', 10000),
    'no delivery method: exactly the Phase 8 reply (no delivery_fee_cents, no total_cents)');
  perform pg_temp.ok(pg_temp.r('nodel_none') = '{"ok": true, "applied": false, "subtotal_cents": 10000, "discount_cents": 0}'::jsonb,
    'no delivery method, no coupon: nothing applies, no total');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Totals with a valid delivery selection
-- ---------------------------------------------------------------------------
select pg_temp.vc('free_ten',   'P8T-TEN',    'p8t_free');
select pg_temp.vc('fee_ten',    'P8T-TEN',    'p8t_fee');
select pg_temp.vc('fee_big',    'P8T-FIXBIG', 'p8t_fee');
select pg_temp.vc('fee_none',   null,         'p8t_fee');
select pg_temp.vc('fee_ten_x3', 'P8T-TEN',    'p8t_fee', 3);
select pg_temp.vc('over_ten',   'P8T-TEN',    'p8t_over');
do $$
begin
  perform pg_temp.ok((pg_temp.r('free_ten') ->> 'delivery_fee_cents')::int = 0
    and (pg_temp.r('free_ten') ->> 'total_cents')::int = 9000, 'free pickup + 10%: 10000 - 1000 = 9000');
  perform pg_temp.ok((pg_temp.r('fee_ten') ->> 'delivery_fee_cents')::int = 5000
    and (pg_temp.r('fee_ten') ->> 'discount_cents')::int = 1000
    and (pg_temp.r('fee_ten') ->> 'total_cents')::int = 14000,
    'fee 5000 + 10%: 10000 + 5000 - 1000 = 14000 (delivery is not discounted)');
  perform pg_temp.ok((pg_temp.r('fee_big') ->> 'discount_cents')::int = 10000
    and (pg_temp.r('fee_big') ->> 'total_cents')::int = 5000,
    'a fixed coupon above the basket cannot go past the subtotal: total = the delivery fee');
  perform pg_temp.ok((pg_temp.r('fee_none') ->> 'total_cents')::int = 15000
    and (pg_temp.r('fee_none') ->> 'applied') = 'false', 'no coupon: subtotal + fee = 15000');
  perform pg_temp.ok((pg_temp.r('fee_ten_x3') ->> 'subtotal_cents')::int = 30000
    and (pg_temp.r('fee_ten_x3') ->> 'total_cents')::int = 30000 + 5000 - 3000, 'quantity 3: priced from the database (30000 + 5000 - 3000)');
  perform pg_temp.ok((pg_temp.r('over_ten') ->> 'delivery_fee_cents')::int
      = (select v.fee_cents from public.validate_delivery_selection('p8t_over', null, 10000) v)
    and (pg_temp.r('over_ten') ->> 'total_cents')::int
      = 10000 + (select v.fee_cents from public.validate_delivery_selection('p8t_over', null, 10000) v) - 1000,
    'the fee is the one validate_delivery_selection() gives for the UNDISCOUNTED subtotal');
end $$;

-- ---------------------------------------------------------------------------
-- 4. No amounts when the answer is unknown or refused
-- ---------------------------------------------------------------------------
select pg_temp.vc('rej_unknown',  'P8T-NOPE', 'p8t_fee');
select pg_temp.vc('rej_inactive', 'P8T-OFF',  'p8t_fee');
select pg_temp.vc('bad_method',   'P8T-TEN',  'p8t_does_not_exist');
select pg_temp.vc('off_method',   'P8T-TEN',  'p8t_off');
do $$
begin
  perform pg_temp.ok(pg_temp.r('rej_unknown') = '{"ok": false, "error": "invalid"}'::jsonb, 'unknown coupon: rejected, no amounts');
  perform pg_temp.ok(pg_temp.r('rej_inactive') = '{"ok": false, "error": "invalid"}'::jsonb, 'inactive coupon: rejected, no amounts');
  perform pg_temp.ok(pg_temp.r('bad_method') = pg_temp.r('nodel_code'), 'unknown delivery method: the coupon still previews, but no total');
  perform pg_temp.ok(pg_temp.r('off_method') = pg_temp.r('nodel_code'), 'inactive delivery method: no total');
  perform pg_temp.ok(not (pg_temp.r('bad_method') ? 'total_cents') and not (pg_temp.r('off_method') ? 'delivery_fee_cents'),
    'the total keys are absent, never guessed');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Parity with create_order(): the preview total is exactly what the order is charged
-- ---------------------------------------------------------------------------
create or replace function pg_temp.order_total(p_code text, p_method text, p_expected integer)
returns table (order_id uuid, msg text) language plpgsql as $$
declare v_id uuid; v_msg text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u1(), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.u1()::text, true);
  begin
    v_id := public.create_order(
      pg_temp.items()::jsonb, p_method, 'cash_on_delivery', null, null, null, null, null, null,
      null, p_expected, null, p_code);
    return query select v_id, null::text;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    return query select null::uuid, v_msg;
  end;
end;
$$;

create temp table t_par as
  select 'wrong'::text as k, o.* from pg_temp.order_total('P8T-TEN', 'p8t_fee',
    ((pg_temp.r('fee_ten') ->> 'total_cents')::int - 1)) o;
insert into t_par
  select 'right', o.* from pg_temp.order_total('P8T-TEN', 'p8t_fee', (pg_temp.r('fee_ten') ->> 'total_cents')::int) o;
do $$
begin
  perform pg_temp.ok((select order_id is null and msg like 'Prices or delivery fees have changed%' from t_par where k = 'wrong'),
    'expected total = server total - 1 is refused by create_order()');
  perform pg_temp.ok((select order_id is not null from t_par where k = 'right'),
    'expected total = the total validate_coupon() returned is accepted by create_order()');
  perform pg_temp.ok((select o.total_cents = (pg_temp.r('fee_ten') ->> 'total_cents')::int
                        and o.delivery_fee_cents = (pg_temp.r('fee_ten') ->> 'delivery_fee_cents')::int
                        and o.discount_cents = (pg_temp.r('fee_ten') ->> 'discount_cents')::int
                        and o.subtotal_cents = (pg_temp.r('fee_ten') ->> 'subtotal_cents')::int
                      from public.orders o join t_par p on p.order_id = o.id where p.k = 'right'),
    'the stored order matches the preview: subtotal, fee, discount and total');
end $$;

do $$ begin raise notice 'ALL PHASE 8 TOTAL TESTS PASSED'; end $$;
rollback;
