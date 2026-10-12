-- Phase 9C test: admin_list_inventory_adjustments() returns movement_kind + order_id and masks customer actors.
-- Needs migrations up to 20261010010000 applied (9B + 9C). Runs in EITHER of two ways, as ONE script:
--   1. psql:             psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f db/tests/phase9c_inventory_history_movement_labels.test.sql
--   2. Supabase SQL Editor: paste the whole file and run it. (The editor may ask you to confirm a "destructive"
--      query because the text contains DELETE; the file only does that inside refused, rolled-back sub-transactions,
--      and the whole script ends with ROLLBACK.)
-- No psql-only features are used (no meta-commands, no :'variable' substitution), so the editor accepts it.
-- Result: everything is rolled back at the end. A failed check raises "FAIL: <name>" and stops the script (the editor
-- shows it as an error; after a failure run ROLLBACK; once). Success = no error: psql prints "PASS: <name>" notices;
-- the editor does not show notices, so there success is "Success. No rows returned", which is only reachable if the
-- final guard saw every earlier check.
-- Fixtures use slugs / codes prefixed t9c-. Run it on a dev / staging project, not during live traffic.
-- Works on a database that already has ledger rows: every ledger assertion is scoped to the fixture products.
begin;

create temp table t9c_log (seq serial primary key, name text not null);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: %', n;
  end if;
  insert into pg_temp.t9c_log (name) values (n);
  raise notice 'PASS: %', n;
end $$;

-- Runs a statement as a given role / auth user in a sub-transaction; returns SQLSTATE and DETAIL ('00000' on success).
create or replace function pg_temp.try_as(p_role text, p_uid uuid, q text, out state text, out detail text) language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  state := '00000'; detail := null;
  begin
    execute format('set local role %I', p_role);
    execute q;
  exception when others then
    get stacked diagnostics state = returned_sqlstate, detail = pg_exception_detail;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- admin_list_inventory_adjustments(<named args>) as the 'authenticated' role signed in as p_uid; returns the jsonb.
create or replace function pg_temp.hist(p_uid uuid, p_args text default '') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
  execute 'select public.admin_list_inventory_adjustments(' || p_args || ')' into r;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return r;
end $$;

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000009c0001', 't9c-customer@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009c0002', 't9c-admin@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009c0003', 't9c-admin2@example.test',   'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009c0004', 't9c-staff@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009c0005', 't9c-gone@example.test',     'authenticated', 'authenticated');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-0000009c0002', 'admin'),
  ('00000000-0000-4000-8000-0000009c0003', 'admin'),
  ('00000000-0000-4000-8000-0000009c0004', 'staff');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-0000009c00a1', 't9c-p1', 'T9C P1', 1000, 100, true, true),
  ('00000000-0000-4000-8000-0000009c00a2', 't9c-p2', 'T9C P2 (variants)', 2000, 10, true, true);
insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, sku) values
  ('00000000-0000-4000-8000-0000009c00b1', '00000000-0000-4000-8000-0000009c00a2', 'T9C V1', 2000, 50, 'T9C-V1');

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t9c_free', 'T9C pickup', 0, null, 0, false, false, true);
update public.promotions set is_active = false where code is null;   -- no automatic promotion may touch the fixtures

create or replace function pg_temp.p1() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c00a1'::uuid $$;
create or replace function pg_temp.p2() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c00a2'::uuid $$;
create or replace function pg_temp.v1() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c00b1'::uuid $$;
create or replace function pg_temp.cust() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c0001'::uuid $$;
create or replace function pg_temp.adm() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c0002'::uuid $$;
create or replace function pg_temp.adm2() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c0003'::uuid $$;
create or replace function pg_temp.staff() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c0004'::uuid $$;
create or replace function pg_temp.gone() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009c0005'::uuid $$;

-- create_order() as the customer (returns the order id, NULL on refusal).
create or replace function pg_temp.place(p_items jsonb) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.cust(), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.cust()::text, true);
  begin
    v_id := public.create_order(p_items, 't9c_free', 'cash_on_delivery', null, null, null, null, null, null, null, null, null, null);
  exception when others then
    v_id := null;
  end;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return v_id;
end $$;

-- Sets the signed-in user for the plain statements that follow (they run as the connecting role; auth.uid() is what matters).
create or replace function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
end $$;

-- Ledger rows of the two fixture products only (a real project has other history).
create or replace function pg_temp.mine() returns setof public.inventory_adjustments language sql as $$
  select a.* from public.inventory_adjustments a where a.product_id in (pg_temp.p1(), pg_temp.p2()) $$;

create temp table t_o (k text primary key, id uuid);

-- ---------------------------------------------------------------- scenario data (every kind of movement)
-- o1: customer orders 3 x P1.  o2: customer orders 2 x P2 variant V1.  o3: customer orders 1 x P1.
insert into t_o values
  ('o1', pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p1(), 'variant_id', null, 'quantity', 3)))),
  ('o2', pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p2(), 'variant_id', pg_temp.v1(), 'quantity', 2)))),
  ('o3', pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p1(), 'variant_id', null, 'quantity', 1))));
select pg_temp.ok((select count(*) from t_o where id is not null) = 3,
  'F1 fixtures: the customer placed three orders (each logged as a stock_change by the 9B trigger)');

-- o1 cancelled, then reactivated, by the ADMIN; o2 cancelled by STAFF; o3 cancelled by the CUSTOMER.
select pg_temp.act_as(pg_temp.adm());
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o1');
update public.orders set status = 'pending'   where id = (select id from t_o where k = 'o1');
select pg_temp.act_as(pg_temp.staff());
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o2');
select pg_temp.act_as(pg_temp.cust());
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o3');
-- A direct change with nobody signed in (the SQL editor / service role) and an admin adjustment by each admin.
select pg_temp.act_as(null);
update public.products set stock_quantity = stock_quantity + 7 where id = pg_temp.p1();
create temp table t_adj as
  select (select state from pg_temp.try_as('authenticated', pg_temp.adm(),
            'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009c00a1'', 5, ''t9c recount'', null, ''counted twice'')')) as s1,
         (select state from pg_temp.try_as('authenticated', pg_temp.adm2(),
            'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009c00a2'', -1, ''t9c variant recount'', ''00000000-0000-4000-8000-0000009c00b1'', null)')) as s2;
select pg_temp.ok((select s1 = '00000' from t_adj),
  'F2 fixtures: admin 1 adjusted P1 by +5 through admin_adjust_inventory()');
select pg_temp.ok((select s2 = '00000' from t_adj),
  'F3 fixtures: admin 2 adjusted the P2 variant by -1 through admin_adjust_inventory()');
-- A legacy-shaped ledger row whose actor account was later deleted (changed_by NULL, default kind admin_adjustment).
insert into public.inventory_adjustments (product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note, changed_by)
values (pg_temp.p2(), null, 10, 4, 14, 't9c legacy row', null, null);
-- A ledger row for an actor whose account still exists but who holds NO staff / admin role and did an admin adjustment:
-- (an admin who was later demoted). The admin_adjustment kind keeps showing its actor.
insert into public.inventory_adjustments (product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note, changed_by)
values (pg_temp.p2(), null, 14, 1, 15, 't9c demoted admin row', null, pg_temp.gone());

-- ---------------------------------------------------------------- S: function shape (unchanged contract)
select pg_temp.ok(
  (select pg_get_function_arguments(oid) = 'p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid, p_variant_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone'
          and pg_get_function_result(oid) = 'jsonb'
     from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure)
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_list_inventory_adjustments') = 1,
  'S1 same signature and result type as 6C.2.2B.1, still exactly one overload');
select pg_temp.ok(
  (select p.prosecdef and p.provolatile = 's' and p.proconfig::text like '%search_path=public, pg_temp%'
     from pg_proc p where p.oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure)
  and not has_function_privilege('anon', 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure
                    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'S2 SECURITY DEFINER, STABLE, search_path pinned, EXECUTE for authenticated only (not anon, not PUBLIC)');
select pg_temp.ok(
  (select position('public.require_admin()' in p.prosrc) > 0
          and position('public.require_admin()' in p.prosrc) < position('public.inventory_adjustments' in p.prosrc)
          and p.prosrc !~* '\m(insert\s+into|update\s+public|delete\s+from|truncate|execute)\M'
          and p.prosrc !~* '\m(orders|order_items|profiles|addresses|payment_transactions)\M'
          and p.prosrc !~* 'auth\.users'
     from pg_proc p where p.oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure),
  'S3 require_admin() is the first guard; the body is read-only and never reads orders, profiles, addresses or auth.users');

-- ---------------------------------------------------------------- snapshots (reading must change nothing)
create temp table t_before as
  select (select count(*) from public.inventory_adjustments) as led,
         (select md5(string_agg(a::text, '|' order by a.id)) from public.inventory_adjustments a) as led_hash,
         (select md5(string_agg(p.id::text || ':' || p.stock_quantity::text, '|' order by p.id)) from public.products p) as stock_hash;

-- One full read as admin 1, product-filtered to the two fixture products via two calls merged.
create temp table t_h1 as select pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_product_id => ''00000000-0000-4000-8000-0000009c00a1''') as j;
create temp table t_h2 as select pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_product_id => ''00000000-0000-4000-8000-0000009c00a2''') as j;
create temp table t_rows as
  select e.value as r from t_h1, jsonb_array_elements(t_h1.j -> 'adjustments') e
  union all
  select e.value from t_h2, jsonb_array_elements(t_h2.j -> 'adjustments') e;

-- ---------------------------------------------------------------- K: the new keys
select pg_temp.ok(
  (select count(*) from t_rows) = (select count(*) from pg_temp.mine())
  and (select (t_h1.j ->> 'total')::int + (t_h2.j ->> 'total')::int from t_h1, t_h2) = (select count(*) from pg_temp.mine()),
  'K1 the reader returns every ledger row of the fixture products (total and rows agree with the ledger)');
select pg_temp.ok(
  (select bool_and(r ? 'movement_kind' and r ? 'order_id') from t_rows)
  and (select bool_and(jsonb_typeof(r -> 'movement_kind') = 'string') from t_rows),
  'K2 every row carries movement_kind (a string) and an order_id key (null when there is no order)');
select pg_temp.ok(
  (select array_agg(k order by k) from (select jsonb_object_keys(r) k from (select r from t_rows limit 1) x) y)
  = array['adjustment_quantity','changed_by','created_at','id','movement_kind','new_quantity','note','order_id','previous_quantity',
          'product_id','product_name','product_sku','reason','variant_id','variant_name','variant_sku'],
  'K3 each row has exactly the 14 pre-9C keys plus movement_kind and order_id, nothing else (no customer or order detail)');
select pg_temp.ok(
  (select count(distinct r ->> 'movement_kind') from t_rows) = 4
  and (select bool_and(r ->> 'movement_kind' in ('admin_adjustment','order_restock','order_reactivation','stock_change')) from t_rows),
  'K4 all four movement kinds are present in the fixture history and nothing else appears');
select pg_temp.ok(
  (select bool_and((r ->> 'movement_kind' = 'order_restock' or r ->> 'movement_kind' = 'order_reactivation') = (r -> 'order_id' <> 'null'::jsonb))
     from t_rows),
  'K5 order_id is set exactly on order_restock / order_reactivation rows and null on admin_adjustment / stock_change rows');
select pg_temp.ok(
  (select bool_and(r ->> 'movement_kind' = a.movement_kind and (r ->> 'order_id')::uuid is not distinct from a.order_id
                   and (r ->> 'reason') = a.reason and (r ->> 'note') is not distinct from a.note
                   and (r ->> 'adjustment_quantity')::int = a.adjustment_quantity
                   and (r ->> 'previous_quantity')::int = a.previous_quantity and (r ->> 'new_quantity')::int = a.new_quantity)
     from t_rows tr join pg_temp.mine() a on a.id = (tr.r ->> 'id')::uuid),
  'K6 kind, order_id, reason, note and quantities are returned exactly as stored (stored reason text is not rewritten)');

-- ---------------------------------------------------------------- L: each movement labelled correctly
select pg_temp.ok(
  (select count(*) from t_rows where r ->> 'movement_kind' = 'stock_change' and (r -> 'order_id') = 'null'::jsonb
      and (r ->> 'adjustment_quantity')::int < 0) >= 3
  and (select count(*) from pg_temp.mine() a where a.movement_kind = 'stock_change' and a.changed_by = pg_temp.cust()) = 3,
  'L1 the three order placements are stock_change rows with order_id null (stored actor is the customer, as 9B records it)');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'order_restock'
      and (tr.r ->> 'order_id')::uuid = (select id from t_o where k = 'o1')
      and (tr.r ->> 'adjustment_quantity')::int = 3 and (tr.r ->> 'changed_by')::uuid = pg_temp.adm()) = 1,
  'L2 cancelling o1 as admin: order_restock, +3, order_id = o1, actor = the admin');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'order_reactivation'
      and (tr.r ->> 'order_id')::uuid = (select id from t_o where k = 'o1')
      and (tr.r ->> 'adjustment_quantity')::int = -3 and (tr.r ->> 'changed_by')::uuid = pg_temp.adm()) = 1,
  'L3 reactivating o1 as admin: order_reactivation, -3, order_id = o1, actor = the admin');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'order_restock'
      and (tr.r ->> 'order_id')::uuid = (select id from t_o where k = 'o2')
      and (tr.r ->> 'variant_id')::uuid = pg_temp.v1() and (tr.r ->> 'changed_by')::uuid = pg_temp.staff()) = 1,
  'L4 cancelling o2 (a variant order) as STAFF: order_restock on the variant with order_id = o2; the staff actor is shown');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'order_restock'
      and (tr.r ->> 'order_id')::uuid = (select id from t_o where k = 'o3')
      and (tr.r -> 'changed_by') = 'null'::jsonb) = 1
  and (select count(*) from pg_temp.mine() a where a.movement_kind = 'order_restock'
         and a.order_id = (select id from t_o where k = 'o3') and a.changed_by = pg_temp.cust()) = 1,
  'L5 cancelling o3 as the CUSTOMER: order_restock keeps its order_id, but the customer actor is masked (null) in the API though stored');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'stock_change' and (tr.r ->> 'adjustment_quantity')::int = 7
      and (tr.r -> 'changed_by') = 'null'::jsonb and (tr.r -> 'order_id') = 'null'::jsonb) = 1,
  'L6 a direct SQL change (+7, nobody signed in) is a stock_change with no order and no actor');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'admin_adjustment' and tr.r ->> 'reason' = 't9c recount'
      and (tr.r ->> 'changed_by')::uuid = pg_temp.adm() and (tr.r -> 'order_id') = 'null'::jsonb and tr.r ->> 'note' = 'counted twice') = 1
  and (select count(*) from t_rows tr where tr.r ->> 'movement_kind' = 'admin_adjustment' and tr.r ->> 'reason' = 't9c variant recount'
         and (tr.r ->> 'changed_by')::uuid = pg_temp.adm2() and (tr.r ->> 'variant_id')::uuid = pg_temp.v1()) = 1,
  'L7 admin adjustments keep their reason, note and acting admin; order_id is null');
select pg_temp.ok(
  (select count(*) from t_rows tr where tr.r ->> 'reason' = 't9c legacy row' and tr.r ->> 'movement_kind' = 'admin_adjustment'
      and (tr.r -> 'changed_by') = 'null'::jsonb) = 1
  and (select count(*) from t_rows tr where tr.r ->> 'reason' = 't9c demoted admin row' and tr.r ->> 'movement_kind' = 'admin_adjustment'
         and (tr.r ->> 'changed_by')::uuid = pg_temp.gone()) = 1,
  'L8 an admin_adjustment always shows its stored actor (also a since-demoted one) and null when the account is gone');

-- ---------------------------------------------------------------- P: privacy
select pg_temp.ok(
  position(pg_temp.cust()::text in (select t_h1.j::text || t_h2.j::text from t_h1, t_h2)) = 0
  and (select count(*) from pg_temp.mine() a where a.changed_by = pg_temp.cust()) >= 4,
  'P1 the customer''s user id appears nowhere in the response although it is stored on 4+ ledger rows');
select pg_temp.ok(
  (select count(*) from t_rows where r ->> 'changed_by' is not null
      and (r ->> 'changed_by')::uuid not in (pg_temp.adm(), pg_temp.adm2(), pg_temp.staff(), pg_temp.gone())) = 0,
  'P2 every changed_by in the response is an admin / staff / admin-adjustment actor');
select pg_temp.ok(
  (pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_changed_by => ''00000000-0000-4000-8000-0000009c0001''') ->> 'total')::int = 0
  and (pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_changed_by => ''00000000-0000-4000-8000-0000009c0002''') ->> 'total')::int
      = (select count(*) from pg_temp.mine() a where a.changed_by = pg_temp.adm()),
  'P3 the actor filter sees the masked value: a customer id matches nothing, an admin id matches that admin''s rows');

-- ---------------------------------------------------------------- A: authorization, arguments, ordering
select pg_temp.ok(
  (select state = '42501' and detail = 'not_authorised' from pg_temp.try_as('authenticated', pg_temp.cust(),
     'select public.admin_list_inventory_adjustments()')),
  'A1 a customer is refused (42501 / not_authorised)');
select pg_temp.ok(
  (select state = '42501' and detail = 'not_authorised' from pg_temp.try_as('authenticated', pg_temp.staff(),
     'select public.admin_list_inventory_adjustments()')),
  'A2 a staff user who is not an admin is refused (42501 / not_authorised)');
select pg_temp.ok(
  (select state = '42501' from pg_temp.try_as('anon', null, 'select public.admin_list_inventory_adjustments()')),
  'A3 anon cannot execute it (42501)');
select pg_temp.ok(
  (select state = 'P0001' and detail = 'invalid_arguments' from pg_temp.try_as('authenticated', pg_temp.adm(),
     'select public.admin_list_inventory_adjustments(p_limit => 0)'))
  and (select state = 'P0001' and detail = 'invalid_arguments' from pg_temp.try_as('authenticated', pg_temp.adm(),
     'select public.admin_list_inventory_adjustments(p_offset => -1)')),
  'A4 invalid arguments are still refused (P0001 / invalid_arguments)');
select pg_temp.ok(
  (select array_agg(r ->> 'id' order by ord) from (select r, row_number() over () ord from (
      select e.value as r from jsonb_array_elements(pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_product_id => ''00000000-0000-4000-8000-0000009c00a1''') -> 'adjustments') e) z) y)
  = (select array_agg(a.id::text order by a.created_at desc, a.id desc) from pg_temp.mine() a where a.product_id = pg_temp.p1()),
  'A5 the fixed order created_at desc, id desc is unchanged');
select pg_temp.ok(
  (pg_temp.hist(pg_temp.adm(), 'p_limit => 2, p_offset => 1, p_product_id => ''00000000-0000-4000-8000-0000009c00a1''') -> 'adjustments') is not null
  and jsonb_array_length(pg_temp.hist(pg_temp.adm(), 'p_limit => 2, p_offset => 1, p_product_id => ''00000000-0000-4000-8000-0000009c00a1''') -> 'adjustments') = 2
  and (pg_temp.hist(pg_temp.adm(), 'p_limit => 2, p_offset => 1, p_product_id => ''00000000-0000-4000-8000-0000009c00a1''') ->> 'total')::int
      = (select count(*) from pg_temp.mine() a where a.product_id = pg_temp.p1()),
  'A6 limit / offset paging and the total still work');
select pg_temp.ok(
  (pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_variant_id => ''00000000-0000-4000-8000-0000009c00b1''') ->> 'total')::int
      = (select count(*) from pg_temp.mine() a where a.variant_id = pg_temp.v1())
  and (pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_product_id => ''00000000-0000-4000-8000-0000009c00a2'', p_reason => ''t9c recount''') ->> 'total')::int = 0
  and (pg_temp.hist(pg_temp.adm(), 'p_limit => 100, p_product_id => ''00000000-0000-4000-8000-0000009c00a1'', p_reason => ''t9c recount''') ->> 'total')::int = 1,
  'A7 the variant and exact-reason filters still work');

-- ---------------------------------------------------------------- R: reading changes nothing
select pg_temp.ok(
  (select led = (select count(*) from public.inventory_adjustments)
          and led_hash = (select md5(string_agg(a::text, '|' order by a.id)) from public.inventory_adjustments a)
          and stock_hash = (select md5(string_agg(p.id::text || ':' || p.stock_quantity::text, '|' order by p.id)) from public.products p)
     from t_before),
  'R1 calling the reader wrote no ledger row, changed no ledger row and moved no stock');
select pg_temp.ok(
  (select count(*) from pg_trigger t where not t.tgisinternal and t.tgname in
     ('products_inventory_log_update', 'product_variants_inventory_log_update', 'orders_inventory_ctx_set',
      'orders_inventory_ctx_clear', 'inventory_adjustments_append_only', 'inventory_adjustments_no_truncate') and t.tgenabled = 'O') = 6
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
         and proname in ('inventory_log_stock_change', 'inventory_order_ctx_set', 'inventory_order_ctx_clear', 'inventory_adjustments_guard')) = 4
  and (select prosrc like '%app.inventory_ledger_skip%' from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
  and (select prosrc not ilike '%movement_kind%' from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace limit 1)
  and (select prosrc not ilike '%inventory_adjustments%' from pg_proc where proname = 'restock_cancelled_order' and pronamespace = 'public'::regnamespace),
  'R2 the 9B triggers, admin_adjust_inventory (with its skip flag), create_order and restock_cancelled_order are as 9B left them');
select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.inventory_adjustments', 'SELECT')
  and not has_table_privilege('anon', 'public.inventory_adjustments', 'SELECT')
  and (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments'),
  'R3 the ledger is still closed to browser roles: this function stays its only read path');

select pg_temp.ok((select count(*) from pg_temp.t9c_log) = 33,
  'ALL PHASE 9C INVENTORY HISTORY LABEL TESTS PASSED (all 33 earlier checks ran; none was skipped)');
rollback;
