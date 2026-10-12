-- Phase 9B test: inventory movements (ledger rows from triggers), append-only ledger, low_stock_threshold.
-- Needs migrations up to 20261009040000 applied. Runs in EITHER of two ways, as ONE script:
--   1. psql:             psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f db/tests/phase9b_inventory_movements.test.sql
--   2. Supabase SQL Editor: paste the whole file and run it. (The editor may ask you to confirm a "destructive"
--      query because the text contains DELETE / TRUNCATE; the file only ever does those inside refused,
--      rolled-back sub-transactions or on its own fixtures, and the whole script ends with ROLLBACK.)
-- No psql-only features are used (no meta-commands, no :'variable' substitution), so the editor accepts it.
-- Result: the script rolls everything back at the end. A failed check raises "FAIL: <name>" and stops the script
-- (the editor shows it as an error; after a failure run ROLLBACK; once). Success = no error: psql prints
-- "PASS: <name>" notices (61 of them); the editor does not show notices, so there success is
-- "Success. No rows returned", which is only reachable if the final guard saw all 60 earlier checks.
-- Fixtures use slugs / codes prefixed t9b-. Run it on a dev / staging project, not during live traffic.
-- Works on a database that already has ledger rows (whole-ledger checks are relative to a snapshot).
begin;

create temp table t9b_log (seq serial primary key, name text not null);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: %', n;
  end if;
  insert into pg_temp.t9b_log (name) values (n);
  raise notice 'PASS: %', n;
end $$;

-- Runs a statement as the current role in a sub-transaction; returns SQLSTATE, constraint, DETAIL ('00000' on success).
create or replace function pg_temp.try(q text, out state text, out cons text, out detail text) language plpgsql as $$
begin
  state := '00000'; cons := null; detail := null;
  begin
    execute q;
  exception when others then
    get stacked diagnostics state = returned_sqlstate, cons = constraint_name, detail = pg_exception_detail;
  end;
end $$;

-- Same, but as a given role / auth user (role is reset afterwards).
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

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000009b0001', 't9b-customer@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009b0002', 't9b-admin@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000009b0003', 't9b-admin2@example.test',   'authenticated', 'authenticated');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-0000009b0002', 'admin'),
  ('00000000-0000-4000-8000-0000009b0003', 'admin');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-0000009b00a1', 't9b-p1', 'T9B P1', 1000, 100, true, true),
  ('00000000-0000-4000-8000-0000009b00a2', 't9b-p2', 'T9B P2 (variants)', 2000, 10, true, true),
  ('00000000-0000-4000-8000-0000009b00a3', 't9b-p3', 'T9B P3', 500, 20, true, true);
insert into public.product_variants (id, product_id, name, price_cents, stock_quantity, sku) values
  ('00000000-0000-4000-8000-0000009b00b1', '00000000-0000-4000-8000-0000009b00a2', 'T9B V1', 2000, 50, 'T9B-V1');

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t9b_free', 'T9B pickup', 0, null, 0, false, false, true);
update public.promotions set is_active = false where code is null;   -- no automatic promotion may touch the fixtures

create or replace function pg_temp.p(i int) returns uuid language sql as $$ select ('00000000-0000-4000-8000-0000009b00a' || i)::uuid $$;
create or replace function pg_temp.v1() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009b00b1'::uuid $$;
create or replace function pg_temp.cust() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009b0001'::uuid $$;
create or replace function pg_temp.adm() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009b0002'::uuid $$;
create or replace function pg_temp.adm2() returns uuid language sql as $$ select '00000000-0000-4000-8000-0000009b0003'::uuid $$;

-- Ledger rows of a unit (product-level when v is null).
create or replace function pg_temp.n(p uuid, v uuid default null) returns bigint language sql as $$
  select count(*) from public.inventory_adjustments a
  where a.product_id = p and a.variant_id is not distinct from v $$;
create or replace function pg_temp.all_n() returns bigint language sql as $$ select count(*) from public.inventory_adjustments $$;
create or replace function pg_temp.pstock(p uuid) returns integer language sql as $$ select stock_quantity from public.products where id = p $$;
create or replace function pg_temp.vstock(v uuid) returns integer language sql as $$ select stock_quantity from public.product_variants where id = v $$;

-- create_order() as the customer (own transaction scope inside; returns order id or NULL on refusal).
create or replace function pg_temp.place(p_items jsonb) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.cust(), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.cust()::text, true);
  begin
    v_id := public.create_order(p_items, 't9b_free', 'cash_on_delivery', null, null, null, null, null, null, null, null, null, null);
  exception when others then
    v_id := null;
  end;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return v_id;
end $$;

create temp table t_o (k text primary key, id uuid);
-- Snapshot of the whole ledger BEFORE the first order: a real project already has ledger history, so absolute
-- row counts would only hold on an empty database. Whole-ledger checks below are relative to this.
create temp table t_base as select pg_temp.all_n() as n;

-- ---------------------------------------------------------------- S: structure
select pg_temp.ok(
  (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
     from pg_attribute a where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped)
  like '%,created_at:timestamp with time zone,order_id:uuid,movement_kind:text',
  'S1 the ledger gained order_id uuid and movement_kind text (existing columns kept)');
select pg_temp.ok(
  exists (select 1 from pg_constraint where conrelid = 'public.inventory_adjustments'::regclass and contype = 'f'
            and confrelid = 'public.orders'::regclass and confdeltype = 'r'),
  'S2 order_id references orders ON DELETE RESTRICT');
select pg_temp.ok(
  (select count(*) from pg_trigger t where not t.tgisinternal and t.tgname in
     ('products_inventory_log_update', 'product_variants_inventory_log_update', 'orders_inventory_ctx_set',
      'orders_inventory_ctx_clear', 'inventory_adjustments_append_only', 'inventory_adjustments_no_truncate')
     and t.tgenabled = 'O') = 6,
  'S3 the six Phase 9B triggers exist and are enabled');
select pg_temp.ok(
  pg_get_triggerdef((select oid from pg_trigger where tgname = 'products_inventory_log_update')) ilike '%AFTER UPDATE OF stock_quantity ON public.products%'
  and pg_get_triggerdef((select oid from pg_trigger where tgname = 'products_inventory_log_update')) ilike '%old.stock_quantity IS DISTINCT FROM new.stock_quantity%'
  and pg_get_triggerdef((select oid from pg_trigger where tgname = 'product_variants_inventory_log_update')) ilike '%AFTER UPDATE OF stock_quantity ON public.product_variants%',
  'S4 the stock triggers are AFTER UPDATE OF stock_quantity ... WHEN (old IS DISTINCT FROM new)');
select pg_temp.ok(
  (select bool_and(p.prosecdef and p.proconfig::text like '%search_path=public, pg_temp%'
                   and not has_function_privilege('anon', p.oid, 'EXECUTE')
                   and not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
     from pg_proc p where p.proname in ('inventory_log_stock_change', 'inventory_order_ctx_set', 'inventory_order_ctx_clear', 'inventory_adjustments_guard')
       and p.pronamespace = 'public'::regnamespace)
  and (select count(*) from pg_proc p where p.proname in ('inventory_log_stock_change', 'inventory_order_ctx_set', 'inventory_order_ctx_clear', 'inventory_adjustments_guard')
         and p.pronamespace = 'public'::regnamespace) = 4,
  'S5 the four trigger functions are SECURITY DEFINER, pin search_path and are not executable by anon / authenticated');
select pg_temp.ok(
  (select prosrc from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace) not ilike '%inventory_adjustments%'
  and (select prosrc from pg_proc where proname = 'restock_cancelled_order' and pronamespace = 'public'::regnamespace) not ilike '%inventory_adjustments%',
  'S6 create_order() and restock_cancelled_order() do not reference the ledger (they are unchanged)');
select pg_temp.ok(
  (select count(*) from pg_indexes where schemaname = 'public'
     and indexname in ('inventory_adjustments_product_idx', 'inventory_adjustments_variant_idx')) = 2
  and (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'inventory_adjustments') = 4,
  'S7 the two existing ledger indexes are still there and no duplicate was added (pkey + 2 old + order_idx = 4)');
select pg_temp.ok(
  (select indexdef from pg_indexes where indexname = 'products_low_stock_idx') ilike '%low_stock_threshold IS NOT NULL%stock_quantity <= low_stock_threshold%'
  and (select indexdef from pg_indexes where indexname = 'product_variants_low_stock_idx') ilike '%low_stock_threshold IS NOT NULL%stock_quantity <= low_stock_threshold%',
  'S8 a partial low-stock index exists on each stock table');

-- ---------------------------------------------------------------- O: order deduction
insert into t_o values ('o1', pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p(1), 'variant_id', null, 'quantity', 3))));
select pg_temp.ok((select id from t_o where k = 'o1') is not null, 'O0 fixture: the customer placed an order for 3 x P1');
select pg_temp.ok(
  pg_temp.pstock(pg_temp.p(1)) = 97 and pg_temp.n(pg_temp.p(1)) = 1
  and (select (previous_quantity, adjustment_quantity, new_quantity, movement_kind, order_id, changed_by)
         is not distinct from (100, -3, 97, 'stock_change', null::uuid, pg_temp.cust())
         from public.inventory_adjustments where product_id = pg_temp.p(1)),
  'O1 an order creates EXACTLY ONE movement: 100 -> 97, kind stock_change, order_id NULL (documented limit), actor = the customer');
select pg_temp.ok(
  (select reason from public.inventory_adjustments where product_id = pg_temp.p(1)) like 'Stock changed outside the admin tool%'
  and pg_temp.all_n() = (select n from t_base) + 1,
  'O2 the reason says the source is not attributed, and nothing else was written');

insert into t_o values ('o2', pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p(2), 'variant_id', pg_temp.v1(), 'quantity', 2))));
select pg_temp.ok(
  pg_temp.vstock(pg_temp.v1()) = 48 and pg_temp.n(pg_temp.p(2), pg_temp.v1()) = 1 and pg_temp.n(pg_temp.p(2)) = 0
  and (select (previous_quantity, adjustment_quantity, new_quantity) = (50, -2, 48)
         from public.inventory_adjustments where variant_id = pg_temp.v1()),
  'O3 a variant order creates exactly one VARIANT-level movement and none on the parent product');

insert into t_o values ('o3', pg_temp.place(jsonb_build_array(
  jsonb_build_object('product_id', pg_temp.p(1), 'variant_id', null, 'quantity', 1),
  jsonb_build_object('product_id', pg_temp.p(3), 'variant_id', null, 'quantity', 4))));
select pg_temp.ok(pg_temp.n(pg_temp.p(1)) = 2 and pg_temp.n(pg_temp.p(3)) = 1 and pg_temp.pstock(pg_temp.p(3)) = 16,
  'O4 a two-product order writes one movement per product');

-- ---------------------------------------------------------------- N: refusals leave no movement
select pg_temp.ok(
  (select state = '23514' and cons = 'products_stock_nonnegative'
     from pg_temp.try('update public.products set stock_quantity = -1 where id = ''00000000-0000-4000-8000-0000009b00a1''')),
  'N1 negative product stock is refused (23514 / products_stock_nonnegative)');
select pg_temp.ok(
  (select state = '23514' and cons = 'product_variants_stock_nonnegative'
     from pg_temp.try('update public.product_variants set stock_quantity = -1 where id = ''00000000-0000-4000-8000-0000009b00b1''')),
  'N2 negative variant stock is refused (23514 / product_variants_stock_nonnegative)');
select pg_temp.ok(pg_temp.pstock(pg_temp.p(1)) = 96 and pg_temp.vstock(pg_temp.v1()) = 48 and pg_temp.n(pg_temp.p(1)) = 2
  and pg_temp.n(pg_temp.p(2), pg_temp.v1()) = 1,
  'N3 the refused changes left stock and the ledger untouched (no movement for a refused change)');
select pg_temp.ok(
  pg_temp.place(jsonb_build_array(jsonb_build_object('product_id', pg_temp.p(3), 'variant_id', null, 'quantity', 1000))) is null
  and pg_temp.n(pg_temp.p(3)) = 1 and pg_temp.pstock(pg_temp.p(3)) = 16,
  'N4 an order for more than the stock is refused and writes no movement');

-- no-ops write nothing; INSERT is an opening balance (documented decision) and writes nothing
update public.products set stock_quantity = stock_quantity where id = pg_temp.p(3);
update public.products set name = 'T9B P3 renamed' where id = pg_temp.p(3);
update public.products set stock_quantity = 16 where id = pg_temp.p(3);
select pg_temp.ok(pg_temp.n(pg_temp.p(3)) = 1, 'N5 an update that leaves stock equal (or changes another column) writes no movement');
insert into public.products (id, slug, name, price_cents, stock_quantity) values
  ('00000000-0000-4000-8000-0000009b00a4', 't9b-p4', 'T9B P4', 100, 30);
select pg_temp.ok(pg_temp.n(pg_temp.p(4)) = 0, 'N6 INSERT with stock > 0 is an opening balance: no movement (decision documented in the migration)');
update public.products set stock_quantity = 31 where id = pg_temp.p(4);
select pg_temp.ok(pg_temp.n(pg_temp.p(4)) = 1
  and (select (previous_quantity, adjustment_quantity, new_quantity, movement_kind) = (30, 1, 31, 'stock_change')
         from public.inventory_adjustments where product_id = pg_temp.p(4)),
  'N7 a later direct change of that product writes exactly one movement (30 -> 31)');

-- ---------------------------------------------------------------- C: cancel / restock / reactivation
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.adm(), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', pg_temp.adm()::text, true);
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o1');
select pg_temp.ok(
  pg_temp.n(pg_temp.p(1)) = 3 and pg_temp.pstock(pg_temp.p(1)) = 99
  and (select (adjustment_quantity, movement_kind, order_id, changed_by)
         = (3, 'order_restock', (select id from t_o where k = 'o1'), pg_temp.adm())
         from public.inventory_adjustments where product_id = pg_temp.p(1) and movement_kind = 'order_restock'),
  'C1 cancelling an order creates EXACTLY ONE movement: +3, kind order_restock, order_id = that order, actor = the admin');
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o1');
select pg_temp.ok(pg_temp.n(pg_temp.p(1)) = 3 and pg_temp.pstock(pg_temp.p(1)) = 99,
  'C2 cancelling an already cancelled order writes nothing (restock is idempotent)');
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o2');
select pg_temp.ok(
  pg_temp.vstock(pg_temp.v1()) = 50 and pg_temp.n(pg_temp.p(2), pg_temp.v1()) = 2 and pg_temp.n(pg_temp.p(2)) = 0
  and (select order_id = (select id from t_o where k = 'o2') and adjustment_quantity = 2
         from public.inventory_adjustments where variant_id = pg_temp.v1() and movement_kind = 'order_restock'),
  'C3 cancelling a variant order creates exactly one VARIANT movement carrying the order id');
update public.orders set status = 'cancelled' where id = (select id from t_o where k = 'o3');
select pg_temp.ok(pg_temp.n(pg_temp.p(1)) = 4 and pg_temp.n(pg_temp.p(3)) = 2
  and (select count(*) from public.inventory_adjustments where order_id = (select id from t_o where k = 'o3')) = 2,
  'C4 cancelling a two-product order creates one movement per product, both with that order id');
update public.orders set status = 'pending' where id = (select id from t_o where k = 'o1');
select pg_temp.ok(
  pg_temp.n(pg_temp.p(1)) = 5 and pg_temp.pstock(pg_temp.p(1)) = 97
  and (select (adjustment_quantity, movement_kind, order_id) is not distinct from (-3, 'order_reactivation', (select id from t_o where k = 'o1'))
         from public.inventory_adjustments where movement_kind = 'order_reactivation' and order_id = (select id from t_o where k = 'o1')),
  'C5 reactivating the order creates exactly one movement: -3, kind order_reactivation, order_id set');
select pg_temp.ok(current_setting('app.inventory_order_id', true) = '',
  'C6 the order context is cleared after the status change (a later stock change is not attributed to the order)');
update public.products set stock_quantity = stock_quantity + 1 where id = pg_temp.p(3);
select pg_temp.ok(
  (select (movement_kind, order_id) is not distinct from ('stock_change', null::uuid) from public.inventory_adjustments
    where product_id = pg_temp.p(3) and adjustment_quantity = 1) and pg_temp.n(pg_temp.p(3)) = 3,
  'C7 a direct change right after is a plain stock_change with no order id');
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
select pg_temp.ok(
  (select state = '23503' from pg_temp.try('delete from public.orders where id = (select id from t_o where k = ''o1'')')),
  'C8 an order with a movement cannot be hard-deleted (order_id ON DELETE RESTRICT)');

-- ---------------------------------------------------------------- A: admin adjust writes ONE row (no double write)
create temp table t_n0 as select pg_temp.all_n() as n;
create temp table t_g1 as select state from pg_temp.try_as('authenticated', pg_temp.adm(),
  'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009b00a1'', 5, ''t9b recount'', null, ''note'')');
select pg_temp.ok((select state from t_g1) = '00000', 'A0 the admin adjustment succeeds');
select pg_temp.ok(
  pg_temp.all_n() = (select n from t_n0) + 1 and pg_temp.pstock(pg_temp.p(1)) = 102
  and (select (movement_kind, adjustment_quantity, reason, note, changed_by) = ('admin_adjustment', 5, 't9b recount', 'note', pg_temp.adm())
         from public.inventory_adjustments where reason = 't9b recount'),
  'A1 admin_adjust_inventory writes EXACTLY ONE ledger row (its own, with reason / note / actor), not two');
select pg_temp.ok(current_setting('app.inventory_ledger_skip', true) = '', 'A2 the skip flag is cleared right after the update');
update public.products set stock_quantity = 103 where id = pg_temp.p(1);
select pg_temp.ok(pg_temp.n(pg_temp.p(1)) = 7 and pg_temp.pstock(pg_temp.p(1)) = 103,
  'A3 a direct change in the same transaction AFTER an admin adjustment still writes its movement (flag does not linger)');
create temp table t_g2 as select state from pg_temp.try_as('authenticated', pg_temp.adm(),
  'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009b00a2'', -4, ''t9b variant recount'', ''00000000-0000-4000-8000-0000009b00b1'', null)');
select pg_temp.ok((select state from t_g2) = '00000' and pg_temp.vstock(pg_temp.v1()) = 46
  and (select count(*) from public.inventory_adjustments where reason = 't9b variant recount' and variant_id = pg_temp.v1()) = 1
  and pg_temp.n(pg_temp.p(2), pg_temp.v1()) = 3,
  'A4 a variant adjustment writes exactly one row (variant ledger: order + restock + this = 3)');
select pg_temp.ok((select count(*) from public.admin_audit_log where action = 'inventory_adjusted' and actor_id = pg_temp.adm()) = 2,
  'A5 the 6I.2 audit write is unchanged: one audit row per adjustment');
create temp table t_n1 as select pg_temp.all_n() as n;
create temp table t_g3 as select state, detail from pg_temp.try_as('authenticated', pg_temp.adm(),
  'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009b00a1'', -9999, ''t9b too much'', null, null)');
select pg_temp.ok((select state from t_g3) = 'P0001' and (select detail from t_g3) = 'negative_stock_not_allowed'
  and pg_temp.all_n() = (select n from t_n1) and pg_temp.pstock(pg_temp.p(1)) = 103,
  'A6 an adjustment that would go negative is refused (P0001 negative_stock_not_allowed) and leaves no movement');
create temp table t_g4 as select state from pg_temp.try_as('authenticated', pg_temp.cust(),
  'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009b00a1'', 1, ''t9b customer'', null, null)');
select pg_temp.ok((select state from t_g4) = '42501' and pg_temp.all_n() = (select n from t_n1),
  'A7 a customer is still refused by the admin gate (42501) and nothing is written');

-- ---------------------------------------------------------------- L: append-only ledger
create temp table t_row as select id from public.inventory_adjustments where reason = 't9b recount';
select pg_temp.ok((select state = 'P0001' and detail = 'inventory_ledger_append_only'
    from pg_temp.try('update public.inventory_adjustments set reason = ''x'' where id = (select id from t_row)')),
  'L1 the owner path cannot UPDATE a ledger row (append-only trigger)');
select pg_temp.ok((select state = 'P0001' and detail = 'inventory_ledger_append_only'
    from pg_temp.try('update public.inventory_adjustments set new_quantity = new_quantity where id = (select id from t_row)')),
  'L2 even a no-change-looking UPDATE of another column is refused');
select pg_temp.ok((select state = 'P0001' and detail = 'inventory_ledger_append_only'
    from pg_temp.try('delete from public.inventory_adjustments where id = (select id from t_row)')),
  'L3 the owner path cannot DELETE a ledger row');
select pg_temp.ok((select state = 'P0001' and detail = 'inventory_ledger_append_only'
    from pg_temp.try('truncate public.inventory_adjustments')),
  'L4 the owner path cannot TRUNCATE the ledger');
select pg_temp.ok((select state = 'P0001' and detail = 'inventory_ledger_append_only'
    from pg_temp.try('truncate public.products cascade')),
  'L5 TRUNCATE ... CASCADE through products is refused too (the guard fires on the cascaded ledger)');
select pg_temp.ok(
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(), 'update public.inventory_adjustments set reason = ''x''')) and
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(), 'delete from public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(), 'truncate public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('anon', null, 'update public.inventory_adjustments set reason = ''x''')) and
  (select state = '42501' from pg_temp.try_as('anon', null, 'delete from public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('anon', null, 'truncate public.inventory_adjustments')),
  'L6 authenticated (even an admin) and anon hold no UPDATE / DELETE / TRUNCATE (42501)');
select pg_temp.ok(
  (select state = '42501' from pg_temp.try_as('service_role', null, 'update public.inventory_adjustments set reason = ''x''')) and
  (select state = '42501' from pg_temp.try_as('service_role', null, 'delete from public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('service_role', null, 'truncate public.inventory_adjustments')),
  'L7 service_role holds no UPDATE / DELETE / TRUNCATE either (42501)');
select pg_temp.ok(
  (select state = '00000' from pg_temp.try_as('service_role', null, 'select count(*) from public.inventory_adjustments')),
  'L8 POSITIVE CONTROL: service_role can still read the ledger, so the refusals above are real');
select pg_temp.ok(
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(), 'select count(*) from public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('anon', null, 'select count(*) from public.inventory_adjustments')) and
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(),
     'insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason) values (''00000000-0000-4000-8000-0000009b00a1'', 1, 1, 2, ''forged'')')),
  'L9 browser roles still cannot read or insert the ledger');
create temp table t_g5 as select state from pg_temp.try_as('service_role', null,
  'insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason) values (''00000000-0000-4000-8000-0000009b00a1'', 1, 1, 2, ''t9b service insert'')');
select pg_temp.ok((select state from t_g5) = '00000'
  and (select movement_kind from public.inventory_adjustments where reason = 't9b service insert') = 'admin_adjustment',
  'L10 service_role may append (the default kind is admin_adjustment, as for every pre-9B row)');
select pg_temp.ok(
  (select state = '23514' and cons = 'inventory_adjustments_movement_kind_valid' from pg_temp.try(
     'insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, movement_kind) values (''00000000-0000-4000-8000-0000009b00a1'', 1, 1, 2, ''t9b bad kind'', ''made_up'')'))
  and (select state = '23514' and cons = 'inventory_adjustments_order_id_kind' from pg_temp.try(
     format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, order_id) values (%L, 1, 1, 2, ''t9b order on admin row'', %L)',
            pg_temp.p(1), (select id from t_o where k = 'o1')))),
  'L11 an unknown movement_kind, or an order_id on a non-order kind, is refused (23514)');

-- changed_by -> NULL is the ONE allowed transition (this is what ON DELETE SET NULL does)
create temp table t_row2 as select id from public.inventory_adjustments where reason = 't9b variant recount';
select pg_temp.ok((select state = 'P0001' from pg_temp.try(
  format('update public.inventory_adjustments set changed_by = %L where id = (select id from t_row2)', pg_temp.adm2()))),
  'L12 changing changed_by to ANOTHER user is refused');
select pg_temp.ok((select state = 'P0001' from pg_temp.try(
  'update public.inventory_adjustments set changed_by = null, reason = ''x'' where id = (select id from t_row2)')),
  'L13 changed_by -> NULL together with any other change is refused');
create temp table t_g6 as select state from pg_temp.try(
  'update public.inventory_adjustments set changed_by = null where id = (select id from t_row2)');
select pg_temp.ok((select state from t_g6) = '00000'
  and (select changed_by is null from public.inventory_adjustments where id = (select id from t_row2)),
  'L14 changed_by -> NULL alone is allowed (the auth.users ON DELETE SET NULL action)');
select pg_temp.ok((select state = 'P0001' from pg_temp.try(
  format('update public.inventory_adjustments set changed_by = %L where id = (select id from t_row2)', pg_temp.adm()))),
  'L15 NULL -> a user is refused (no re-attribution)');
-- the real thing: deleting a user who has ledger rows must work and null the column
create temp table t_g7 as select state from pg_temp.try_as('authenticated', pg_temp.adm2(),
  'select public.admin_adjust_inventory(''00000000-0000-4000-8000-0000009b00a3'', 2, ''t9b admin2 adjust'', null, null)');
select pg_temp.ok((select state from t_g7) = '00000'
  and (select changed_by from public.inventory_adjustments where reason = 't9b admin2 adjust') = pg_temp.adm2(),
  'L16 fixture: a second admin has a ledger row');
delete from public.user_roles where user_id = pg_temp.adm2();
delete from auth.users where id = pg_temp.adm2();
select pg_temp.ok(
  not exists (select 1 from auth.users where id = pg_temp.adm2())
  and (select changed_by is null and reason = 't9b admin2 adjust' and adjustment_quantity = 2
         from public.inventory_adjustments where reason = 't9b admin2 adjust'),
  'L17 deleting an auth user works: the ledger row survives with changed_by NULL and nothing else changed');

-- ---------------------------------------------------------------- T: low_stock_threshold
select pg_temp.ok(
  (select count(*) from public.products where low_stock_threshold is not null and slug like 't9b-%') = 0
  and (select count(*) from public.product_variants where low_stock_threshold is not null and sku like 'T9B-%') = 0,
  'T1 low_stock_threshold defaults to NULL on both tables');
select pg_temp.ok(
  (select state = '23514' and cons = 'products_low_stock_threshold_valid'
     from pg_temp.try('update public.products set low_stock_threshold = -1 where id = ''00000000-0000-4000-8000-0000009b00a1''')) and
  (select state = '23514' and cons = 'products_low_stock_threshold_valid'
     from pg_temp.try('update public.products set low_stock_threshold = 1001 where id = ''00000000-0000-4000-8000-0000009b00a1''')),
  'T2 products.low_stock_threshold rejects -1 and 1001 (23514)');
select pg_temp.ok(
  (select state = '23514' and cons = 'product_variants_low_stock_threshold_valid'
     from pg_temp.try('update public.product_variants set low_stock_threshold = -1 where id = ''00000000-0000-4000-8000-0000009b00b1''')) and
  (select state = '23514' and cons = 'product_variants_low_stock_threshold_valid'
     from pg_temp.try('update public.product_variants set low_stock_threshold = 1001 where id = ''00000000-0000-4000-8000-0000009b00b1''')),
  'T3 product_variants.low_stock_threshold rejects -1 and 1001 (23514)');
update public.products set low_stock_threshold = 0 where id = pg_temp.p(1);
update public.products set low_stock_threshold = 1000 where id = pg_temp.p(3);
update public.products set low_stock_threshold = null where id = pg_temp.p(1);
update public.product_variants set low_stock_threshold = 1000 where id = pg_temp.v1();
select pg_temp.ok(
  (select low_stock_threshold from public.products where id = pg_temp.p(3)) = 1000
  and (select low_stock_threshold from public.product_variants where id = pg_temp.v1()) = 1000
  and (select low_stock_threshold is null from public.products where id = pg_temp.p(1)),
  'T4 the boundaries 0, 1000 and NULL are accepted');
select pg_temp.ok(pg_temp.n(pg_temp.p(1)) = 8 and pg_temp.n(pg_temp.p(3)) = 4,
  'T5 changing a threshold is not a stock change and writes no movement (P1 stayed at 8 rows incl. the L10 service insert, P3 has its 4)');
select pg_temp.ok(
  (select state = '42501' from pg_temp.try_as('anon', null, 'update public.products set low_stock_threshold = 5')) and
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.cust(), 'update public.products set low_stock_threshold = 5')) and
  (select state = '42501' from pg_temp.try_as('authenticated', pg_temp.adm(), 'update public.product_variants set low_stock_threshold = 5')),
  'T6 browser roles (even an admin) cannot write low_stock_threshold');
set local enable_seqscan = off;
select pg_temp.ok(
  exists (select 1 from public.products where low_stock_threshold is not null and stock_quantity <= low_stock_threshold and id = pg_temp.p(3)),
  'T7 the low-stock predicate finds a product at or below its own threshold (P3: its stock is far below 1000)');
reset enable_seqscan;

select pg_temp.ok((select count(*) from pg_temp.t9b_log) = 60,
  'ALL PHASE 9B INVENTORY MOVEMENT TESTS PASSED (all 60 earlier checks ran; none was skipped)');
rollback;
