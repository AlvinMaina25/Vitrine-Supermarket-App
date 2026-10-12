-- =============================================================================
-- PHASE 6C.2.2A.1 database test: inventory adjustment HISTORY foundation.
--
-- STATUS: written for migration 20261004090000_phase6c2_inventory_adjustment_history.sql.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004090000_phase6c2_inventory_adjustment_history.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c2_inventory_adjustment_history.test.sql
--
-- (Supabase SQL Editor: paste the whole file and Run. An empty "ok" result with no error means
-- every check passed; any failure raises "FAIL: <name>".)
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.2.2A.1 TESTS PASSED" = all passed.
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them: every fixture row is named 't6c2a1' / 'T6C2A1', and the whole run is
-- rolled back. It does not assume the history table is empty.
--
-- WHAT THIS PHASE IS, AND WHAT THE TEST GUARDS
--   One audit table, public.inventory_adjustments. NO stock change, NO function, NO trigger, NO
--   browser access. This test is the boundary of THAT phase: sections D and E assert that no
--   adjustment function / history reader exists yet. The phase that adds one must update those two
--   allow-lists (exactly as 6C.2.1 updated the earlier phases' allow-lists); nothing else here
--   should need to change.
--
-- ABOUT "THE MIGRATION CONTAINS NO STOCK MUTATION": a SQL script cannot read the repo's files, and
--   this test must also run in the Supabase SQL Editor. The text-level assertion (the migration
--   file, with comments and string literals removed, contains no UPDATE / INSERT / DELETE /
--   function / trigger / view) lives in tests/inventory-adjustment-history-migration.test.ts and
--   runs with `npm test`. THIS file proves the same thing from the DATABASE side: the migration
--   left no function or trigger behind, history writes do not move any stock value, and the
--   stock columns, constraints and defaults are exactly as before. The migration also checks all
--   of this itself, inside its own transaction, before it commits.
--
-- COVERS
--   A  structure: table, columns, types, primary key, foreign keys, NOT NULL, CHECKs, defaults, indexes
--   B  constraint behaviour: every CHECK / NOT NULL / FK rejects exactly what it should; valid rows pass
--   C  security: no browser privilege of any kind, RLS default deny (even against a stray grant)
--   D  stock authority: the stock columns are unchanged, the table is not a second stock source
--   E  nothing else was added: no function, no trigger, no policy
--   F  regression: 6C.2.1, 6C.1B.2, 6C.1B.1, 6C.1A, 6B.2, 6B.1, 6A, 5B.2, 5A.2
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
create temp table t_att (k text primary key, state text, cons text, msg text);

-- Run ONE statement as a database role with a given JWT user, and record the result or the error.
create or replace function pg_temp.run_claims(p_k text, p_role text, p_claims jsonb, p_sql text)
returns void language plpgsql as $$
declare
  v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims::text, ''), true);
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
  insert into t_res values (p_k, v_res, v_err, v_state, nullif(v_detail, ''))
  on conflict (k) do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end;
$$;

create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
begin
  perform pg_temp.run_claims(p_k, p_role,
    case when p_uid is null then null else jsonb_build_object('sub', p_uid, 'role', p_role) end,
    p_sql);
end;
$$;

-- Run ONE statement as the test owner and record SQLSTATE + the violated constraint's name.
create or replace function pg_temp.attempt(p_k text, p_sql text)
returns void language plpgsql as $$
declare
  v_state text; v_cons text; v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_cons = constraint_name, v_msg = message_text;
  end;
  insert into t_att values (p_k, v_state, nullif(v_cons, ''), v_msg)
  on conflict (k) do update set state = excluded.state, cons = excluded.cons, msg = excluded.msg;
end;
$$;

-- The statement was REJECTED with this SQLSTATE (and, when given, by this constraint).
create or replace function pg_temp.rejected(p_k text, p_state text, p_cons text, p_name text)
returns void language plpgsql as $$
declare r t_att;
begin
  select * into r from t_att where k = p_k;
  if r.k is null then raise exception 'FAIL: % (nothing recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.state is not null and r.state = p_state and r.cons is not distinct from p_cons,
    p_name || ' [' || coalesce(r.state, 'ACCEPTED') || ' ' || coalesce(r.cons, '-') || ']');
end;
$$;

-- The statement was ACCEPTED (no error).
create or replace function pg_temp.accepted(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_att;
begin
  select * into r from t_att where k = p_k;
  if r.k is null then raise exception 'FAIL: % (nothing recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.state is null, p_name || ' [' || coalesce(r.state || ' ' || r.msg, 'ok') || ']');
end;
$$;

-- Refused by the database privilege system (42501), before or while running; never "0 rows".
create or replace function pg_temp.denied(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

create or replace function pg_temp.gated(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.detail = 'not_authorised' and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ']');
end;
$$;

create or replace function pg_temp.no_execute(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.res is null
                     and r.detail is distinct from 'not_authorised',
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || r.err || ']');
end;
$$;

create or replace function pg_temp.succeeded(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is null and r.res is not null,
    p_name || ' [' || coalesce(r.state, 'ok') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

-- ---------------------------------------------------------------------------
-- Phase-specific helpers
-- ---------------------------------------------------------------------------
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6db' || lpad(n::text, 9, '0'))::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6dc000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6dd000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.a(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6de000000' || lpad(n::text, 3, '0'))::uuid $$;

-- Try to insert ONE history row as the owner (NULL arguments become SQL NULL).
create or replace function pg_temp.try_ins(p_k text, p_product uuid, p_variant uuid, p_prev integer,
                                           p_delta integer, p_new integer, p_reason text, p_note text)
returns void language plpgsql as $$
begin
  perform pg_temp.attempt(p_k, format(
    'insert into public.inventory_adjustments (product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note) values (%L, %L, %L, %L, %L, %L, %L)',
    p_product, p_variant, p_prev, p_delta, p_new, p_reason, p_note));
end;
$$;

-- Hashes (to prove "nothing was written").
create or replace function pg_temp.prod_hash() returns text language sql as $$
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p $$;
create or replace function pg_temp.var_hash() returns text language sql as $$
  select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v $$;
create or replace function pg_temp.ord_hash() returns text language sql as $$
  select md5(coalesce((select string_agg(o::text, '|' order by o.id) from public.orders o), '')
          || '#' || coalesce((select string_agg(i::text, '|' order by i.id) from public.order_items i), '')) $$;
create or replace function pg_temp.acl_hash() returns text language sql as $$
  select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                 '|' order by c.relname), ''))
  from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
    and c.relname in ('products', 'product_variants', 'orders', 'order_items', 'order_status_history', 'user_roles') $$;
create or replace function pg_temp.pol_hash() returns text language sql as $$
  select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                 '|' order by tablename, policyname), ''))
  from pg_policies where schemaname = 'public' $$;

create temp table t_h (k text primary key, h text);

-- ---------------------------------------------------------------------------
-- Fixtures
--   u1 customer, u2 staff, u3 admin, u4 a throw-away admin used only to prove ON DELETE SET NULL
--   p1 Milk (stock 20) with variants v1 (stock 7), v2 (stock 0);  p2 Rice (stock 0), no variants
--   p3 a spare product with no history (proves RESTRICT only blocks products that HAVE history)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c2a1-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C2A1 Customer"}'),
  (pg_temp.u(2), 't6c2a1-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2A1 Staff"}'),
  (pg_temp.u(3), 't6c2a1-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2A1 Admin"}'),
  (pg_temp.u(4), 't6c2a1-admin2@example.test',   'authenticated', 'authenticated', '{"full_name":"T6C2A1 Admin Two"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin'),
  (pg_temp.u(4), 'admin');

insert into public.products
  (id, slug, name, brand, sku, price_cents, unit_label, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1), 't6c2a1-milk',  'T6C2A1 Milk',  'T6C2A1Brand', 'T6C2A1-MILK',  500, '1 L',  20, true,  true),
  (pg_temp.p(2), 't6c2a1-rice',  'T6C2A1 Rice',  null,          'T6C2A1-RICE',  700, '1 kg',  0, false, true),
  (pg_temp.p(3), 't6c2a1-spare', 'T6C2A1 Spare', null,          'T6C2A1-SPARE', 100, null,    9, true,  true);
insert into public.product_variants
  (id, product_id, name, sku, price_cents, stock_quantity, position, is_active)
values
  (pg_temp.v(1), pg_temp.p(1), 'T6C2A1 Milk 1L', 'T6C2A1-MILK-1L', 500, 7, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6C2A1 Milk 2L', 'T6C2A1-MILK-2L', 900, 0, 2, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c2a1-%') = 3
  and (select count(*) from public.product_variants where id in (pg_temp.v(1), pg_temp.v(2))) = 2,
  'FIXTURE: three test products and two test variants exist');

insert into t_h values
  ('prod0', pg_temp.prod_hash()),
  ('var0', pg_temp.var_hash()),
  ('ord0', pg_temp.ord_hash()),
  ('acl0', pg_temp.acl_hash()),
  ('pol0', pg_temp.pol_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))),
  ('fn0',  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace));

-- ===========================================================================
-- A. STRUCTURE
-- ===========================================================================
select pg_temp.ok(
  (select count(*) from pg_class c where c.oid = to_regclass('public.inventory_adjustments') and c.relkind = 'r') = 1,
  'A1 TABLE: public.inventory_adjustments exists and is an ordinary table');

select pg_temp.ok(
  (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
   from pg_attribute a
   where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped)
  = 'id:uuid,product_id:uuid,variant_id:uuid,previous_quantity:integer,adjustment_quantity:integer,new_quantity:integer,reason:text,note:text,changed_by:uuid,created_at:timestamp with time zone,order_id:uuid,movement_kind:text',
  'A2 COLUMNS + TYPES: exactly id, product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note, changed_by, created_at, then the Phase 9B order_id and movement_kind, with the intended data types');

select pg_temp.ok(
  (select array_agg(a.attname::text order by a.attname::text)
   from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.conrelid = 'public.inventory_adjustments'::regclass and c.contype = 'p') = array['id'],
  'A3 PRIMARY KEY: the primary key is exactly (id)');

select pg_temp.ok(
  (select string_agg(a.attname, ',' order by a.attnum)
   from pg_attribute a
   where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attnotnull)
  = 'id,product_id,previous_quantity,adjustment_quantity,new_quantity,reason,created_at,movement_kind'
  and (select count(*) from pg_attribute a
       where a.attrelid = 'public.inventory_adjustments'::regclass and a.attname in ('variant_id', 'note', 'changed_by', 'order_id')
         and not a.attnotnull) = 4,
  'A4 NOT NULL: id, product_id, the three quantities, reason, created_at and (Phase 9B) movement_kind are NOT NULL; variant_id, note, changed_by and (Phase 9B) order_id are nullable');

select pg_temp.ok(
  (select string_agg(a.attname || '->' ||
            (select n.nspname || '.' || cl.relname from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
             where cl.oid = c.confrelid) || ':' || c.confdeltype::text, ' | ' order by a.attname::text)
   from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.conrelid = 'public.inventory_adjustments'::regclass and c.contype = 'f' and array_length(c.conkey, 1) = 1)
  = 'changed_by->auth.users:n | order_id->public.orders:r | product_id->public.products:r | variant_id->public.product_variants:r',
  'A5 FOREIGN KEYS: product_id -> products (RESTRICT), variant_id -> product_variants (RESTRICT), changed_by -> auth.users (SET NULL), and (Phase 9B) order_id -> orders (RESTRICT); no others');

select pg_temp.ok(
  (select string_agg(conname, ',' order by conname collate "C") from pg_constraint
   where conrelid = 'public.inventory_adjustments'::regclass and contype = 'c')
  = 'inventory_adjustments_delta_nonzero,inventory_adjustments_movement_kind_valid,inventory_adjustments_new_nonnegative,inventory_adjustments_note_valid,inventory_adjustments_order_id_kind,inventory_adjustments_previous_nonnegative,inventory_adjustments_quantities_consistent,inventory_adjustments_reason_valid',
  'A6 CHECKS: the eight CHECK constraints exist (the six of 6C.2.2A.1: delta_nonzero, new_nonnegative, note_valid, previous_nonnegative, quantities_consistent, reason_valid; plus Phase 9B movement_kind_valid and order_id_kind)');

select pg_temp.ok(
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where d.adrelid = 'public.inventory_adjustments'::regclass and a.attname = 'created_at') = 'now()'
  and (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
       where d.adrelid = 'public.inventory_adjustments'::regclass and a.attname = 'id') = 'gen_random_uuid()',
  'A7 DEFAULTS: created_at defaults to now(); id defaults to gen_random_uuid()');

select pg_temp.ok(
  (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'inventory_adjustments'
     and indexname = 'inventory_adjustments_product_idx' and indexdef like '%(product_id, created_at DESC)%') = 1
  and (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'inventory_adjustments'
         and indexname = 'inventory_adjustments_variant_idx' and indexdef like '%(variant_id, created_at DESC)%'
         and indexdef like '%WHERE (variant_id IS NOT NULL)%') = 1,
  'A8 INDEXES: product (product_id, created_at desc) and variant (variant_id, created_at desc, only where variant_id is not null) indexes exist');

select pg_temp.ok(obj_description('public.inventory_adjustments'::regclass, 'pg_class') like '%AUDIT / HISTORY%'
  and obj_description('public.inventory_adjustments'::regclass, 'pg_class') like '%NOT a stock source%',
  'A9 DOCUMENTED: the table comment says it is an audit / history table and not a stock source');

-- ===========================================================================
-- B. CONSTRAINT BEHAVIOUR (as the owner; each bad row breaks EXACTLY ONE rule)
-- ===========================================================================
-- Valid rows first (positive controls): one product-level, one variant-level.
insert into public.inventory_adjustments
  (id, product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note, changed_by)
values
  (pg_temp.a(1), pg_temp.p(1), null,         20, -3, 17, 'T6C2A1 damaged goods', 'two bottles broke', pg_temp.u(3)),
  (pg_temp.a(2), pg_temp.p(1), pg_temp.v(1),  7,  5, 12, 'T6C2A1 recount',        null,                pg_temp.u(3));

select pg_temp.ok(
  (select count(*) from public.inventory_adjustments where id in (pg_temp.a(1), pg_temp.a(2))) = 2
  and (select created_at from public.inventory_adjustments where id = pg_temp.a(1)) = now()
  and (select created_at from public.inventory_adjustments where id = pg_temp.a(2)) is not null,
  'B1 VALID ROWS: a product-level and a variant-level adjustment insert, and created_at is filled in by its default');

-- Nullability and references
select pg_temp.try_ins('b_nullprod', null, null, 5, 1, 6, 'T6C2A1 x', null);
select pg_temp.rejected('b_nullprod', '23502', null, 'B2 product_id is required (NOT NULL)');
select pg_temp.try_ins('b_nullprev', pg_temp.p(1), null, null, 1, 6, 'T6C2A1 x', null);
select pg_temp.rejected('b_nullprev', '23502', null, 'B3 previous_quantity is required (NOT NULL)');
select pg_temp.try_ins('b_nulldelta', pg_temp.p(1), null, 5, null, 6, 'T6C2A1 x', null);
select pg_temp.rejected('b_nulldelta', '23502', null, 'B4 adjustment_quantity is required (NOT NULL)');
select pg_temp.try_ins('b_nullnew', pg_temp.p(1), null, 5, 1, null, 'T6C2A1 x', null);
select pg_temp.rejected('b_nullnew', '23502', null, 'B5 new_quantity is required (NOT NULL)');
select pg_temp.try_ins('b_nullreason', pg_temp.p(1), null, 5, 1, 6, null, null);
select pg_temp.rejected('b_nullreason', '23502', null, 'B6 reason is required (NOT NULL)');
select pg_temp.try_ins('b_noprod', pg_temp.p(99), null, 5, 1, 6, 'T6C2A1 x', null);
select pg_temp.rejected('b_noprod', '23503', 'inventory_adjustments_product_id_fkey', 'B7 an unknown product_id is rejected by the foreign key');
select pg_temp.try_ins('b_novar', pg_temp.p(1), pg_temp.v(99), 5, 1, 6, 'T6C2A1 x', null);
select pg_temp.rejected('b_novar', '23503', 'inventory_adjustments_variant_id_fkey', 'B8 an unknown variant_id is rejected by the foreign key');
select pg_temp.attempt('b_nouser',
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, changed_by) values (%L, 5, 1, 6, %L, %L)',
         pg_temp.p(1), 'T6C2A1 x', pg_temp.u(99)));
select pg_temp.rejected('b_nouser', '23503', 'inventory_adjustments_changed_by_fkey', 'B9 an unknown changed_by user is rejected by the foreign key');

-- Quantities
select pg_temp.try_ins('b_prevneg', pg_temp.p(1), null, -1, 1, 0, 'T6C2A1 x', null);
select pg_temp.rejected('b_prevneg', '23514', 'inventory_adjustments_previous_nonnegative', 'B10 previous_quantity cannot be negative');
select pg_temp.try_ins('b_newneg', pg_temp.p(1), null, 0, -1, -1, 'T6C2A1 x', null);
select pg_temp.rejected('b_newneg', '23514', 'inventory_adjustments_new_nonnegative', 'B11 new_quantity cannot be negative (a history row cannot describe a state the stock tables reject)');
select pg_temp.try_ins('b_zero', pg_temp.p(1), null, 5, 0, 5, 'T6C2A1 x', null);
select pg_temp.rejected('b_zero', '23514', 'inventory_adjustments_delta_nonzero', 'B12 an adjustment of zero is rejected');
select pg_temp.try_ins('b_sum', pg_temp.p(1), null, 5, 3, 9, 'T6C2A1 x', null);
select pg_temp.rejected('b_sum', '23514', 'inventory_adjustments_quantities_consistent', 'B13 new_quantity must equal previous_quantity + adjustment_quantity');
select pg_temp.try_ins('b_sum2', pg_temp.p(1), null, 5, -3, 3, 'T6C2A1 x', null);
select pg_temp.rejected('b_sum2', '23514', 'inventory_adjustments_quantities_consistent', 'B14 the sum rule also rejects a wrong negative adjustment');
select pg_temp.try_ins('b_overflow', pg_temp.p(1), null, 2147483647, 2147483647, 2147483647, 'T6C2A1 x', null);
select pg_temp.rejected('b_overflow', '23514', 'inventory_adjustments_quantities_consistent', 'B15 the sum rule is evaluated in bigint: two huge integers cannot overflow into a pass or a 22003 error');
select pg_temp.try_ins('b_ok_big', pg_temp.p(1), null, 2147483647, -2147483647, 0, 'T6C2A1 big', null);
select pg_temp.accepted('b_ok_big', 'B16 the largest legal values still insert (2147483647 -> 0)');

-- Reason and note
select pg_temp.try_ins('b_reason_empty', pg_temp.p(1), null, 5, 1, 6, '', null);
select pg_temp.rejected('b_reason_empty', '23514', 'inventory_adjustments_reason_valid', 'B17 an empty reason is rejected');
select pg_temp.try_ins('b_reason_blank', pg_temp.p(1), null, 5, 1, 6, '   ', null);
select pg_temp.rejected('b_reason_blank', '23514', 'inventory_adjustments_reason_valid', 'B18 a blank (spaces only) reason is rejected');
select pg_temp.try_ins('b_reason_pad', pg_temp.p(1), null, 5, 1, 6, ' padded', null);
select pg_temp.rejected('b_reason_pad', '23514', 'inventory_adjustments_reason_valid', 'B19 a reason with leading / trailing whitespace is rejected (stored trimmed)');
select pg_temp.try_ins('b_reason_long', pg_temp.p(1), null, 5, 1, 6, repeat('r', 121), null);
select pg_temp.rejected('b_reason_long', '23514', 'inventory_adjustments_reason_valid', 'B20 a 121-character reason is rejected');
select pg_temp.try_ins('b_reason_max', pg_temp.p(1), null, 5, 1, 6, repeat('r', 120), null);
select pg_temp.accepted('b_reason_max', 'B21 a 120-character reason is accepted');
select pg_temp.try_ins('b_note_empty', pg_temp.p(1), null, 5, 1, 6, 'T6C2A1 x', '');
select pg_temp.rejected('b_note_empty', '23514', 'inventory_adjustments_note_valid', 'B22 an empty note is rejected (use NULL for no note)');
select pg_temp.try_ins('b_note_pad', pg_temp.p(1), null, 5, 1, 6, 'T6C2A1 x', 'note ');
select pg_temp.rejected('b_note_pad', '23514', 'inventory_adjustments_note_valid', 'B23 a note with trailing whitespace is rejected');
select pg_temp.try_ins('b_note_long', pg_temp.p(1), null, 5, 1, 6, 'T6C2A1 x', repeat('n', 501));
select pg_temp.rejected('b_note_long', '23514', 'inventory_adjustments_note_valid', 'B24 a 501-character note is rejected');
select pg_temp.try_ins('b_note_max', pg_temp.p(1), null, 5, 1, 6, 'T6C2A1 x', repeat('n', 500));
select pg_temp.accepted('b_note_max', 'B25 a 500-character note is accepted');
select pg_temp.try_ins('b_note_null', pg_temp.p(1), null, 5, 1, 6, 'T6C2A1 x', null);
select pg_temp.accepted('b_note_null', 'B26 a NULL note is accepted');

-- A shorthand-free variant row with no changed_by is also valid (changed_by is nullable).
select pg_temp.try_ins('b_noby', pg_temp.p(1), pg_temp.v(2), 0, 4, 4, 'T6C2A1 restock', null);
select pg_temp.accepted('b_noby', 'B27 changed_by may be NULL (history survives the loss of a user)');

-- Foreign-key DELETE rules
select pg_temp.attempt('b_del_prod', format('delete from public.products where id = %L', pg_temp.p(1)));
select pg_temp.rejected('b_del_prod', '23503', 'inventory_adjustments_product_id_fkey', 'B28 a product that has history cannot be deleted (ON DELETE RESTRICT)');
select pg_temp.attempt('b_del_var', format('delete from public.product_variants where id = %L', pg_temp.v(1)));
select pg_temp.rejected('b_del_var', '23503', 'inventory_adjustments_variant_id_fkey', 'B29 a variant that has history cannot be deleted (ON DELETE RESTRICT)');
select pg_temp.attempt('b_del_spare', format('delete from public.products where id = %L', pg_temp.p(3)));
select pg_temp.accepted('b_del_spare', 'B30 a product WITHOUT history can still be deleted (RESTRICT blocks only what has history)');
select pg_temp.ok((select count(*) from public.products where id = pg_temp.p(3)) = 0
  and (select count(*) from public.products where id = pg_temp.p(1)) = 1
  and (select count(*) from public.inventory_adjustments where product_id = pg_temp.p(1)) >= 2,
  'B31 the spare product is gone; the product and history that were protected are untouched');

insert into public.inventory_adjustments
  (id, product_id, previous_quantity, adjustment_quantity, new_quantity, reason, changed_by)
values (pg_temp.a(3), pg_temp.p(2), 0, 6, 6, 'T6C2A1 by throw-away admin', pg_temp.u(4));
delete from auth.users where id = pg_temp.u(4);
select pg_temp.ok(
  (select count(*) from public.inventory_adjustments where id = pg_temp.a(3)) = 1
  and (select changed_by from public.inventory_adjustments where id = pg_temp.a(3)) is null,
  'B32 deleting the admin who made an adjustment keeps the history row and sets changed_by to NULL');

-- The history is NOT the stock: rows were written, the stock columns did not move.
select pg_temp.ok(
  (select stock_quantity from public.products where id = pg_temp.p(1)) = 20
  and (select stock_quantity from public.product_variants where id = pg_temp.v(1)) = 7
  and (select stock_quantity from public.product_variants where id = pg_temp.v(2)) = 0
  and (select stock_quantity from public.products where id = pg_temp.p(2)) = 0
  and (select in_stock from public.products where id = pg_temp.p(1)) = true,
  'B33 NO STOCK CHANGE: the history says 20 -> 17, 7 -> 12 and 0 -> 4, yet products / variants still hold 20, 7 and 0 (and in_stock is untouched)');

-- ===========================================================================
-- C. SECURITY: no browser privilege of any kind; row level security as a second wall
-- ===========================================================================
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'INSERT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'UPDATE')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'REFERENCES')),
  'C1 NO BROWSER GRANTS: anon and authenticated hold no table or column privilege (not even SELECT) on inventory_adjustments');

select pg_temp.ok(
  not exists (select 1 from pg_attribute where attrelid = 'public.inventory_adjustments'::regclass and attacl is not null)
  and not exists (
    select 1 from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
    where c.oid = 'public.inventory_adjustments'::regclass and a.grantee = 0),
  'C2 NO PUBLIC GRANT: the PUBLIC pseudo-role holds nothing on the table and no column-level ACL exists');

-- C3: identify the table owner explicitly, then look ONLY at grantees other than that owner.
-- The owner's own ACL entry (postgres on this project) is never a failure. Grantees are compared
-- as a DISTINCT set, so it does not matter how many individual privileges service_role holds.
-- PUBLIC (grantee 0) has no role row, so it is reported as 'PUBLIC' and would fail this check.
select pg_temp.ok(
  coalesce((
    select array_agg(g.grantee_name order by g.grantee_name)
    from (
      select distinct
             case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as grantee_name
      from pg_class c
      cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.inventory_adjustments'::regclass
        and a.grantee <> c.relowner            -- exclude the table owner (postgres)
    ) g
  ), array[]::text[]) = array['service_role']
  and has_table_privilege('service_role', 'public.inventory_adjustments', 'INSERT')
  and has_table_privilege('service_role', 'public.inventory_adjustments', 'SELECT'),
  'C3 GRANTS: excluding the table owner, the only grantee of the table is service_role (anon, authenticated and PUBLIC hold nothing)');

select pg_temp.ok(
  (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments'),
  'C4 RLS: row level security is ON and there is no policy at all (default deny)');

-- Each browser role, each verb: refused with 42501 while rows exist (so never "0 rows").
select pg_temp.ok((select count(*) from public.inventory_adjustments) >= 5, 'C5 PRECONDITION: the history table holds rows to protect');

select pg_temp.run('c_anon_sel', 'anon', null, 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('c_anon_sel', 'C6 anon cannot SELECT from inventory_adjustments');
select pg_temp.run('c_cust_sel', 'authenticated', pg_temp.u(1), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('c_cust_sel', 'C7 a customer cannot SELECT from inventory_adjustments');
select pg_temp.run('c_staff_sel', 'authenticated', pg_temp.u(2), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('c_staff_sel', 'C8 staff cannot SELECT from inventory_adjustments');
select pg_temp.run('c_admin_sel', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('c_admin_sel', 'C9 even an ADMIN cannot read the table directly (a later phase reads it through a gated function)');

select pg_temp.run('c_anon_ins', 'anon', null,
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason) values (%L, 20, 1, 21, %L) returning id::text', pg_temp.p(1), 'T6C2A1 forged'));
select pg_temp.denied('c_anon_ins', 'C10 anon cannot INSERT');
select pg_temp.run('c_cust_ins', 'authenticated', pg_temp.u(1),
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason) values (%L, 20, 1, 21, %L) returning id::text', pg_temp.p(1), 'T6C2A1 forged'));
select pg_temp.denied('c_cust_ins', 'C11 a customer cannot INSERT');
select pg_temp.run('c_admin_ins', 'authenticated', pg_temp.u(3),
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, changed_by) values (%L, 20, 1, 21, %L, %L) returning id::text', pg_temp.p(1), 'T6C2A1 forged', pg_temp.u(3)));
select pg_temp.denied('c_admin_ins', 'C12 even an admin cannot INSERT directly (only a future SECURITY DEFINER function will)');

select pg_temp.run('c_anon_upd', 'anon', null,
  format('update public.inventory_adjustments set new_quantity = 999, adjustment_quantity = 979 where id = %L returning id::text', pg_temp.a(1)));
select pg_temp.denied('c_anon_upd', 'C13 anon cannot UPDATE');
select pg_temp.run('c_cust_upd', 'authenticated', pg_temp.u(1),
  format('update public.inventory_adjustments set reason = %L where id = %L returning id::text', 'T6C2A1 rewritten', pg_temp.a(1)));
select pg_temp.denied('c_cust_upd', 'C14 a customer cannot UPDATE');
select pg_temp.run('c_admin_upd', 'authenticated', pg_temp.u(3),
  format('update public.inventory_adjustments set reason = %L where id = %L returning id::text', 'T6C2A1 rewritten', pg_temp.a(1)));
select pg_temp.denied('c_admin_upd', 'C15 even an admin cannot UPDATE (history is not editable from the browser)');

select pg_temp.run('c_anon_del', 'anon', null,
  format('delete from public.inventory_adjustments where id = %L returning id::text', pg_temp.a(1)));
select pg_temp.denied('c_anon_del', 'C16 anon cannot DELETE');
select pg_temp.run('c_cust_del', 'authenticated', pg_temp.u(1),
  format('delete from public.inventory_adjustments where id = %L returning id::text', pg_temp.a(1)));
select pg_temp.denied('c_cust_del', 'C17 a customer cannot DELETE');
select pg_temp.run('c_admin_del', 'authenticated', pg_temp.u(3),
  format('delete from public.inventory_adjustments where id = %L returning id::text', pg_temp.a(1)));
select pg_temp.denied('c_admin_del', 'C18 even an admin cannot DELETE');

-- Positive control: the denials above are about privileges, not a broken table.
select pg_temp.run('c_svc_sel', 'service_role', null, 'select count(*)::text from public.inventory_adjustments');
select pg_temp.succeeded('c_svc_sel', 'C19 POSITIVE CONTROL: service_role can read the table, so the refusals above are real privilege refusals');

select pg_temp.ok(
  (select reason from public.inventory_adjustments where id = pg_temp.a(1)) = 'T6C2A1 damaged goods'
  and (select new_quantity from public.inventory_adjustments where id = pg_temp.a(1)) = 17
  and (select count(*) from public.inventory_adjustments where reason in ('T6C2A1 forged', 'T6C2A1 rewritten')) = 0,
  'C20 the refused UPDATE / INSERT / DELETE attempts changed nothing');

-- DEFENCE IN DEPTH: suppose someone grants the browser roles privileges by mistake. With RLS on and
-- no policy the table must still show nothing and accept nothing.
grant select, insert, update, delete on public.inventory_adjustments to authenticated;
select pg_temp.run('c_stray_sel', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.ok((select res from t_res where k = 'c_stray_sel') = '0' and (select err from t_res where k = 'c_stray_sel') is null,
  'C21 DEFAULT DENY: even with a stray SELECT grant, authenticated (an admin) sees 0 rows because RLS has no policy');
select pg_temp.run('c_stray_ins', 'authenticated', pg_temp.u(3),
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, changed_by) values (%L, 20, 1, 21, %L, %L) returning id::text', pg_temp.p(1), 'T6C2A1 forged', pg_temp.u(3)));
select pg_temp.ok((select state from t_res where k = 'c_stray_ins') = '42501'
  and (select err from t_res where k = 'c_stray_ins') ilike '%row-level security%',
  'C22 DEFAULT DENY: even with a stray INSERT grant, RLS refuses the row (42501, row-level security)');
select pg_temp.run('c_stray_upd', 'authenticated', pg_temp.u(3),
  format('update public.inventory_adjustments set reason = %L where id = %L returning id::text', 'T6C2A1 rewritten', pg_temp.a(1)));
select pg_temp.run('c_stray_del', 'authenticated', pg_temp.u(3),
  format('delete from public.inventory_adjustments where id = %L returning id::text', pg_temp.a(1)));
select pg_temp.ok((select err from t_res where k = 'c_stray_upd') is null and (select res from t_res where k = 'c_stray_upd') is null
  and (select err from t_res where k = 'c_stray_del') is null and (select res from t_res where k = 'c_stray_del') is null
  and (select reason from public.inventory_adjustments where id = pg_temp.a(1)) = 'T6C2A1 damaged goods',
  'C23 DEFAULT DENY: even with stray UPDATE / DELETE grants, no row is visible to change and the history is intact');
revoke all on public.inventory_adjustments from authenticated;

select pg_temp.ok(not exists (
    select 1 from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)),
  'C24 the temporary stray grant is gone again (the table is back to no browser privilege)');

-- No browser write privilege on any stock / order / role table (table OR column level)
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.inventory_adjustments'), ('public.products'), ('public.product_variants'),
                 ('public.orders'), ('public.order_items'), ('public.order_status_history'), ('public.user_roles')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'C25 NO BROWSER WRITES: anon / authenticated cannot INSERT, UPDATE, DELETE or TRUNCATE inventory_adjustments, products, product_variants, orders, order_items, order_status_history or user_roles');

-- ===========================================================================
-- D. STOCK AUTHORITY UNCHANGED; the history table is not a second stock source
-- ===========================================================================
select pg_temp.ok(
  (select format_type(atttypid, atttypmod) || ':' || attnotnull::text from pg_attribute
   where attrelid = 'public.products'::regclass and attname = 'stock_quantity') = 'integer:true'
  and (select format_type(atttypid, atttypmod) || ':' || attnotnull::text from pg_attribute
       where attrelid = 'public.products'::regclass and attname = 'in_stock') = 'boolean:true'
  and (select format_type(atttypid, atttypmod) || ':' || attnotnull::text from pg_attribute
       where attrelid = 'public.product_variants'::regclass and attname = 'stock_quantity') = 'integer:true'
  and (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
       where d.adrelid = 'public.products'::regclass and a.attname = 'stock_quantity') = '0'
  and (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
       where d.adrelid = 'public.product_variants'::regclass and a.attname = 'stock_quantity') = '0',
  'D1 STOCK COLUMNS: products.stock_quantity / in_stock and product_variants.stock_quantity keep their types, NOT NULL and defaults');
select pg_temp.ok(
  (select pg_get_constraintdef(oid) from pg_constraint
   where conrelid = 'public.products'::regclass and conname = 'products_stock_nonnegative') = 'CHECK ((stock_quantity >= 0))'
  and (select pg_get_constraintdef(oid) from pg_constraint
       where conrelid = 'public.product_variants'::regclass and conname = 'product_variants_stock_nonnegative') = 'CHECK ((stock_quantity >= 0))',
  'D2 STOCK CHECKS: products_stock_nonnegative and product_variants_stock_nonnegative are unchanged');
select pg_temp.ok(
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'product_variants' and column_name = 'in_stock'),
  'D3 product_variants still has no in_stock column (none was invented)');
select pg_temp.ok(
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'inventory_adjustments'
                and column_name in ('current_quantity', 'stock_quantity', 'quantity', 'balance', 'on_hand', 'in_stock', 'stock')),
  'D4 NOT A SECOND SOURCE: inventory_adjustments has no current_quantity / stock_quantity / balance / in_stock column; only per-adjustment snapshots');
select pg_temp.ok(
  (select array_agg(relname::text order by relname::text) from pg_class
   where relnamespace = 'public'::regnamespace and relkind in ('r', 'p', 'v', 'm') and relname ~* '(inventor|stock|adjust)')
  = array['inventory_adjustments'],
  'D5 the ONLY table / view in public named like inventory, stock or adjust is inventory_adjustments (no second inventory table, no view)');
select pg_temp.ok(
  (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))
    = (select h from t_h where k = 'rel0'),
  'D6 this run created no table (the one new table was already there before the test began)');
-- products / variants: the only differences since the snapshot are the spare product deleted in B30
select pg_temp.ok(
  (select count(*) from public.products where slug like 't6c2a1-%') = 2
  and (select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text, '|' order by p.id)
       from public.products p where slug like 't6c2a1-%')
      = pg_temp.p(1)::text || ':20:true|' || pg_temp.p(2)::text || ':0:false'
  and (select string_agg(v.id::text || ':' || v.stock_quantity::text, '|' order by v.id)
       from public.product_variants v where v.product_id = pg_temp.p(1))
      = pg_temp.v(1)::text || ':7|' || pg_temp.v(2)::text || ':0',
  'D8 NO STOCK MUTATION: after every history write, every fixture stock_quantity / in_stock is exactly what it was (20 / true, 0 / false, 7, 0)');
select pg_temp.ok(
  pg_temp.ord_hash() = (select h from t_h where k = 'ord0'),
  'D9 orders and order items are byte-for-byte unchanged (order stock logic untouched)');

-- ===========================================================================
-- E. NOTHING ELSE WAS ADDED: no function, no trigger, no policy
-- ===========================================================================
select pg_temp.ok(
  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace) = (select h from t_h where k = 'fn0')
  and (select array_agg(proname::text order by proname::text) from pg_proc
       where pronamespace = 'public'::regnamespace and proname ~* '(inventor|stock|adjust|history)')
      in (array['admin_get_inventory', 'admin_list_inventory', 'restock_cancelled_order'],
          array['admin_adjust_inventory', 'admin_get_inventory', 'admin_list_inventory', 'restock_cancelled_order'],
          array['admin_adjust_inventory', 'admin_get_inventory', 'admin_list_inventory', 'admin_list_inventory_adjustments', 'restock_cancelled_order'],
          array['admin_adjust_inventory', 'admin_get_inventory', 'admin_list_inventory', 'admin_list_inventory_adjustments',
                'inventory_adjustments_guard', 'inventory_log_stock_change', 'inventory_order_ctx_clear', 'inventory_order_ctx_set',
                'restock_cancelled_order']),
  'E1 NO NEW FUNCTION: the only inventory / stock / adjust / history-named functions are the two 6C.2.1 readers, the pre-existing order-restock trigger function and (optionally, once the later phases are applied) admin_adjust_inventory, admin_list_inventory_adjustments and the four Phase 9B inventory_* trigger functions');
select pg_temp.ok(
  (select array_agg(proname::text order by proname::text) from pg_proc
   where pronamespace = 'public'::regnamespace and prosrc ilike '%inventory_adjustments%') is not distinct from case when to_regprocedure('public.admin_adjust_inventory(uuid,integer,text,uuid,text)') is null
                                 then null
                                 when to_regprocedure('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)') is null
                                 then array['admin_adjust_inventory']
                                 when to_regprocedure('public.inventory_log_stock_change()') is null
                                 then array['admin_adjust_inventory', 'admin_list_inventory_adjustments']
                                 else array['admin_adjust_inventory', 'admin_list_inventory_adjustments',
                                            'inventory_adjustments_guard', 'inventory_log_stock_change'] end,
  'E2 ONLY THE WRITERS USE THE TABLE: no function references inventory_adjustments before 6C.2.2A.2; afterwards admin_adjust_inventory, the read-only admin_list_inventory_adjustments (6C.2.2B.1) and, from Phase 9B, the append-only guard and the stock-movement trigger function');
select pg_temp.ok(
  (select coalesce(string_agg(t.tgname, ',' order by t.tgname collate "C"), '') from pg_trigger t
   where t.tgrelid = 'public.inventory_adjustments'::regclass and not t.tgisinternal)
    in ('', 'inventory_adjustments_append_only,inventory_adjustments_no_truncate')
  and not exists (
    select 1 from pg_trigger t
    where not t.tgisinternal and t.tgrelid in ('public.products'::regclass, 'public.product_variants'::regclass)
      and t.tgfoid::regproc::text not in ('set_updated_at', 'public.set_updated_at', 'inventory_log_stock_change', 'public.inventory_log_stock_change')),
  'E3 TRIGGERS: inventory_adjustments has none (before Phase 9B) or exactly the two Phase 9B append-only guards, and products / product_variants carry only their updated_at trigger plus the Phase 9B stock-movement trigger');
select pg_temp.ok(
  pg_temp.pol_hash() = (select h from t_h where k = 'pol0'),
  'E4 NO POLICY CHANGE: every policy in public is exactly as before the test (the new table has none)');

-- ===========================================================================
-- F. REGRESSION: the earlier phases' security invariants still hold
-- ===========================================================================
select pg_temp.ok(
  pg_temp.acl_hash() = (select h from t_h where k = 'acl0'),
  'F1 the grants and RLS flags of products, product_variants, orders, order_items, order_status_history and user_roles are exactly as before the test');

-- 5A.2: no broad table privileges for browser roles anywhere in public
select pg_temp.ok(not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated')) r(role)
    cross join (values ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege(r.role, c.oid, pv.priv)),
  'F2 REGRESSION 5A.2: anon / authenticated hold no TRUNCATE / REFERENCES / TRIGGER on any public table (the new table included)');

-- 5B.2: SECURITY DEFINER hygiene, role helpers, RLS on protected tables, no write policies
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'F3 REGRESSION 5B.2: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.run('f_anon_staff', 'anon', null, $q$select public.is_staff('00000000-0000-4000-8000-6db000000003')::text$q$);
select pg_temp.no_execute('f_anon_staff', 'F4 REGRESSION 5B.2: anon still cannot call is_staff()');
select pg_temp.run('f_anon_role', 'anon', null, $q$select public.has_role('00000000-0000-4000-8000-6db000000003','admin')::text$q$);
select pg_temp.no_execute('f_anon_role', 'F5 REGRESSION 5B.2: anon still cannot call has_role()');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.orders', 'SELECT')
  and not has_table_privilege('anon', 'public.order_items', 'SELECT')
  and not has_table_privilege('anon', 'public.user_roles', 'SELECT')
  and not has_table_privilege('anon', 'public.addresses', 'SELECT')
  and not has_table_privilege('anon', 'public.profiles', 'SELECT')
  and not has_any_column_privilege('authenticated', 'public.user_roles', 'UPDATE')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE'),
  'F6 REGRESSION 5B.2: anon has no access to orders, items, roles, addresses or profiles; authenticated cannot write orders or roles');
select pg_temp.ok(
  not exists (select 1 from pg_class c
              where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                              'public.order_status_history'::regclass, 'public.user_roles'::regclass,
                              'public.delivery_methods'::regclass, 'public.delivery_zones'::regclass,
                              'public.delivery_zone_fees'::regclass, 'public.delivery_slot_templates'::regclass,
                              'public.delivery_slot_overrides'::regclass, 'public.addresses'::regclass,
                              'public.products'::regclass, 'public.product_variants'::regclass,
                              'public.inventory_adjustments'::regclass)
                and not c.relrowsecurity),
  'F7 REGRESSION 5B.2: row level security is on for every protected table (and the new one)');
select pg_temp.ok(
  not exists (select 1 from pg_policies where schemaname = 'public'
              and tablename in ('orders', 'order_items', 'order_status_history', 'products', 'product_variants',
                                'categories', 'inventory_adjustments')
              and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  'F8 REGRESSION 5B.2 / 6B / 6C: no write policy exists on orders, order items, order history, products, variants, categories or the history table');

-- 6A / 6B / 6C: every admin_* function is still gated, SECURITY DEFINER and not executable by anon
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'admin\_%') >= 13
  and not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%'
      -- 6I.1: admin_audit_log_block_change/_truncate are trigger functions (not callable RPCs), so the RPC rules do not apply.
      and p.proname !~ '^admin_audit_log_block_'
      and (not p.prosecdef
           or has_function_privilege('anon', p.oid, 'EXECUTE')
           or not has_function_privilege('authenticated', p.oid, 'EXECUTE')
           or position('public.require_admin()' in p.prosrc) = 0)),
  'F9 REGRESSION 6A-6C: every admin_* function (13 at this phase) are SECURITY DEFINER, call require_admin() first, are not executable by anon and are executable by authenticated');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'F10 REGRESSION 6A: a browser role cannot execute require_admin() directly');
select pg_temp.ok(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT'
     and policyname in ('Products: admin read all', 'Variants: admin read all',
                        'Categories: admin read all', 'Profiles: admin read all')) = 4,
  'F11 REGRESSION 6A: the four admin read-all policies still exist');

-- Gates, behaviourally: refused for staff / customer / anon, working for the admin
select pg_temp.run('f_dash_c', 'authenticated', pg_temp.u(1), 'select public.admin_dashboard_summary()::text');
select pg_temp.gated('f_dash_c', 'F12 REGRESSION 6A: admin_dashboard_summary refuses a customer');
select pg_temp.run('f_dash_a', 'authenticated', pg_temp.u(3), 'select public.admin_dashboard_summary()::text');
select pg_temp.succeeded('f_dash_a', 'F13 REGRESSION 6A: admin_dashboard_summary works for an admin');
select pg_temp.run('f_ord_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_orders()::text');
select pg_temp.gated('f_ord_s', 'F14 REGRESSION 6B.1: admin_list_orders refuses staff');
select pg_temp.run('f_ord_a', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('f_ord_a', 'F15 REGRESSION 6B.1: admin_list_orders works for an admin');
select pg_temp.run('f_prod_c', 'authenticated', pg_temp.u(1), 'select public.admin_list_products()::text');
select pg_temp.gated('f_prod_c', 'F16 REGRESSION 6C.1A: admin_list_products refuses a customer');
select pg_temp.run('f_prod_a', 'authenticated', pg_temp.u(3), 'select public.admin_list_products()::text');
select pg_temp.succeeded('f_prod_a', 'F17 REGRESSION 6C.1A: admin_list_products works for an admin');
select pg_temp.run('f_inv_s', 'authenticated', pg_temp.u(2), $$select public.admin_list_inventory(p_search => 'T6C2A1')::text$$);
select pg_temp.gated('f_inv_s', 'F18 REGRESSION 6C.2.1: admin_list_inventory refuses staff');
select pg_temp.run('f_inv_n', 'anon', null, $$select public.admin_list_inventory(p_search => 'T6C2A1')::text$$);
select pg_temp.no_execute('f_inv_n', 'F19 REGRESSION 6C.2.1: admin_list_inventory refuses anon (permission denied)');
select pg_temp.run('f_inv_a', 'authenticated', pg_temp.u(3), $$select public.admin_list_inventory(p_search => 'T6C2A1')::text$$);
select pg_temp.ok((select (res::jsonb ->> 'total')::integer from t_res where k = 'f_inv_a') = 4,
  'F20 REGRESSION 6C.2.1: admin_list_inventory works for an admin and still reports the stock tables (product + 2 variants of Milk, product Rice = 4 units) - not the history table');
select pg_temp.run('f_invg_a', 'authenticated', pg_temp.u(3),
  format('select public.admin_get_inventory(%L::uuid, %L::uuid)::text', pg_temp.p(1), pg_temp.v(1)));
select pg_temp.ok((select (res::jsonb -> 'inventory' ->> 'stock_quantity')::integer from t_res where k = 'f_invg_a') = 7,
  'F21 REGRESSION 6C.2.1: admin_get_inventory still returns the variant''s real stock (7), not a history snapshot (12)');

-- The write RPCs still refuse every non-admin and still change nothing when refused
select pg_temp.run('f_w_c1', 'authenticated', pg_temp.u(1),
  format('select public.admin_set_product_active(%L::uuid, false)::text', pg_temp.p(1)));
select pg_temp.gated('f_w_c1', 'F22 REGRESSION 6C.1B.2: admin_set_product_active refuses a customer');
select pg_temp.run('f_w_s1', 'authenticated', pg_temp.u(2),
  format($q$select public.admin_update_product(%L::uuid, '{"stock_quantity": 999}'::jsonb)::text$q$, pg_temp.p(1)));
select pg_temp.gated('f_w_s1', 'F23 REGRESSION 6C.1B.1: admin_update_product refuses staff (so stock cannot be edited through it by a non-admin)');
select pg_temp.run('f_w_c2', 'authenticated', pg_temp.u(1),
  format($q$select public.admin_update_product_variant(%L::uuid, '{"stock_quantity": 999}'::jsonb)::text$q$, pg_temp.v(1)));
select pg_temp.gated('f_w_c2', 'F24 REGRESSION 6C.1B.2: admin_update_product_variant refuses a customer');
select pg_temp.run('f_w_n1', 'anon', null,
  format('select public.admin_set_product_active(%L::uuid, false)::text', pg_temp.p(1)));
select pg_temp.no_execute('f_w_n1', 'F25 REGRESSION 6C.1B.2: admin_set_product_active refuses anon (permission denied)');
select pg_temp.run('f_w_s2', 'authenticated', pg_temp.u(2),
  format('select public.admin_set_order_status(%L::uuid, %L::order_status, %L, false)::text', pg_temp.p(1), 'cancelled', 'x'));
select pg_temp.gated('f_w_s2', 'F26 REGRESSION 6B.2: admin_set_order_status refuses staff');
select pg_temp.ok(
  (select stock_quantity from public.products where id = pg_temp.p(1)) = 20
  and (select is_active from public.products where id = pg_temp.p(1)) = true
  and (select stock_quantity from public.product_variants where id = pg_temp.v(1)) = 7
  and pg_temp.ord_hash() = (select h from t_h where k = 'ord0'),
  'F27 the refused write calls changed no stock, no product flag and no order');

do $$ begin raise notice 'ALL PHASE 6C.2.2A.1 TESTS PASSED'; end $$;

rollback;
