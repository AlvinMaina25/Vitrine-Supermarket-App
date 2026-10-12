-- =============================================================================
-- PHASE 6C.2.2A.2 database test: admin inventory stock ADJUSTMENT engine.
--
-- STATUS: written for migration 20261004100000_phase6c2_admin_inventory_adjustment.sql.
-- NOT RUN against any database by the author (no PostgreSQL was available); run it on the
-- dedicated Phase-5 DEV database AFTER that migration has been applied there.
--
-- HOW TO RUN (as the postgres/owner role):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c2_admin_inventory_adjustment.test.sql
-- (Supabase SQL Editor: paste the whole file and Run.)
--
-- One transaction, rolled back at the end: no fixture, stock change or history row survives.
-- Each pass prints "PASS: <name>"; a failure raises "FAIL: <name>".
-- "ALL PHASE 6C.2.2A.2 TESTS PASSED" = everything passed.
--
-- DATABASE-DATA NOTE: every fixture row is named 't6c2a2' / 'T6C2A2'. Real products are never
-- touched. Concurrency (two sessions) is NOT tested here; that is Phase 6C.2.2B.2.
--
-- COVERS
--   A  authorization: admin ok; customer / staff / anon / signed-out / forged claim / service_role refused
--   B  product-level adjustment (+/-), history row, in_stock preserved
--   C  variant-level adjustment (+/-), parent product untouched, mismatch refused
--   D  validation + atomicity (stock and history unchanged after EVERY refusal)
--   E  atomic rollback of a successful call, and the stock-equals-history invariant
--   F  security attributes and privileges
--   G  regression of earlier phases (admin API allow-list now has fourteen functions)
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
  select ('00000000-0000-4000-8000-6df' || lpad(n::text, 9, '0'))::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6e0000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6e1000000' || lpad(n::text, 3, '0'))::uuid $$;

-- Call admin_adjust_inventory as a role / JWT user. p_delta is text so overflow literals can be tried.
create or replace function pg_temp.adj(p_k text, p_role text, p_uid uuid, p_prod uuid, p_delta text,
                                       p_reason text, p_var uuid default null, p_note text default null)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format(
    'select public.admin_adjust_inventory(%L::uuid, %s::integer, %L, %L::uuid, %L)::text',
    p_prod, coalesce(p_delta, 'null'), p_reason, p_var, p_note));
end;
$$;

-- Refused by the function with SQLSTATE P0001 and this DETAIL.
create or replace function pg_temp.refused(p_k text, p_detail text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = 'P0001' and r.detail = p_detail and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

-- Stock of every fixture unit + count of history rows of fixture products.
create or replace function pg_temp.sig() returns text language sql as $$
  select md5(
    coalesce((select string_agg(p.id::text || ':' || p.stock_quantity || ':' || p.in_stock, '|' order by p.id)
              from public.products p where p.slug like 't6c2a2-%'), '')
    || '#' ||
    coalesce((select string_agg(v.id::text || ':' || v.stock_quantity, '|' order by v.id)
              from public.product_variants v where v.sku like 'T6C2A2-%'), '')
    || '#' ||
    (select count(*) from public.inventory_adjustments a
     where a.product_id in (select id from public.products where slug like 't6c2a2-%'))::text) $$;
create temp table t_snap (k text primary key, h text);
create or replace function pg_temp.snap() returns void language sql as $$
  insert into t_snap values ('s', pg_temp.sig()) on conflict (k) do update set h = excluded.h $$;
create or replace function pg_temp.same(p_name text) returns void language plpgsql as $$
begin
  perform pg_temp.ok(pg_temp.sig() = (select h from t_snap where k = 's'),
    'NOTHING CHANGED after refusal: ' || p_name || ' (every fixture stock value, in_stock flag and the history row count are exactly as before)');
end;
$$;

create or replace function pg_temp.pstock(n integer) returns integer language sql as $$
  select stock_quantity from public.products where id = pg_temp.p(n) $$;
create or replace function pg_temp.vstock(n integer) returns integer language sql as $$
  select stock_quantity from public.product_variants where id = pg_temp.v(n) $$;
create or replace function pg_temp.hist(p_prod integer) returns bigint language sql as $$
  select count(*) from public.inventory_adjustments where product_id = pg_temp.p(p_prod) $$;
create or replace function pg_temp.j(p_k text) returns jsonb language sql as $$
  select res::jsonb from t_res where k = p_k $$;

create temp table t_h (k text primary key, h text);
create or replace function pg_temp.ord_hash() returns text language sql as $$
  select md5(coalesce((select string_agg(o::text, '|' order by o.id) from public.orders o), '')
          || '#' || coalesce((select string_agg(i::text, '|' order by i.id) from public.order_items i), '')) $$;
create or replace function pg_temp.acl_hash() returns text language sql as $$
  select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                 '|' order by c.relname), ''))
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') $$;
create or replace function pg_temp.pol_hash() returns text language sql as $$
  select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                 '|' order by tablename, policyname), ''))
  from pg_policies where schemaname = 'public' $$;

-- ---------------------------------------------------------------------------
-- Fixtures
--   u1 customer, u2 staff, u3 admin
--   p1 Milk stock 20 in_stock, variants v1 (7), v2 (0);  p2 Rice stock 0 NOT in_stock;
--   p3 Spare stock 9 with variant v3 (4) (a variant of ANOTHER product, for mismatch tests);
--   p4 Bulk stock 2147483640 (integer-range boundary)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c2a2-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C2A2 Customer"}'),
  (pg_temp.u(2), 't6c2a2-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2A2 Staff"}'),
  (pg_temp.u(3), 't6c2a2-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2A2 Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

insert into public.products (id, slug, name, sku, price_cents, unit_label, stock_quantity, in_stock, is_active) values
  (pg_temp.p(1), 't6c2a2-milk',  'T6C2A2 Milk',  'T6C2A2-MILK',  500, '1 L',  20, true,  true),
  (pg_temp.p(2), 't6c2a2-rice',  'T6C2A2 Rice',  'T6C2A2-RICE',  700, '1 kg',  0, false, true),
  (pg_temp.p(3), 't6c2a2-spare', 'T6C2A2 Spare', 'T6C2A2-SPARE', 100, null,    9, true,  true),
  (pg_temp.p(4), 't6c2a2-bulk',  'T6C2A2 Bulk',  'T6C2A2-BULK',  100, null, 2147483640, true, true);
insert into public.product_variants (id, product_id, name, sku, price_cents, stock_quantity, position, is_active) values
  (pg_temp.v(1), pg_temp.p(1), 'T6C2A2 Milk 1L', 'T6C2A2-MILK-1L', 500, 7, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6C2A2 Milk 2L', 'T6C2A2-MILK-2L', 900, 0, 2, true),
  (pg_temp.v(3), pg_temp.p(3), 'T6C2A2 Spare Var', 'T6C2A2-SPARE-V', 100, 4, 1, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c2a2-%') = 4
  and (select count(*) from public.product_variants where sku like 'T6C2A2-%') = 3,
  'FIXTURE: four test products and three test variants exist');

insert into t_h values
  ('ord0', pg_temp.ord_hash()),
  ('acl0', pg_temp.acl_hash()),
  ('pol0', pg_temp.pol_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))),
  ('fn0',  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace));
select pg_temp.snap();

-- ===========================================================================
-- A. AUTHORIZATION (everything refused here must change nothing)
-- ===========================================================================
select pg_temp.adj('a_cust', 'authenticated', pg_temp.u(1), pg_temp.p(1), '5', 'T6C2A2 customer try');
select pg_temp.gated('a_cust', 'A1 a customer cannot adjust stock (require_admin: 42501 not_authorised)');
select pg_temp.same('A1 customer');

select pg_temp.adj('a_staff', 'authenticated', pg_temp.u(2), pg_temp.p(1), '5', 'T6C2A2 staff try');
select pg_temp.gated('a_staff', 'A2 staff cannot adjust stock (admin only)');
select pg_temp.same('A2 staff');

select pg_temp.adj('a_anon', 'anon', null, pg_temp.p(1), '5', 'T6C2A2 anon try');
select pg_temp.no_execute('a_anon', 'A3 anon cannot call the function at all (EXECUTE revoked, permission denied)');
select pg_temp.same('A3 anon');

select pg_temp.adj('a_out', 'authenticated', null, pg_temp.p(1), '5', 'T6C2A2 signed-out try');
select pg_temp.gated('a_out', 'A4 a signed-out caller (authenticated role, no JWT subject) is refused by require_admin()');
select pg_temp.same('A4 signed-out');

-- Forged claims: a customer's JWT that CLAIMS admin in every place a careless implementation might look.
select pg_temp.run_claims('a_forged', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'is_admin', true, 'admin', true,
                     'app_metadata', jsonb_build_object('role', 'admin', 'roles', jsonb_build_array('admin')),
                     'user_metadata', jsonb_build_object('role', 'admin')),
  format('select public.admin_adjust_inventory(%L::uuid, 5, %L)::text', pg_temp.p(1), 'T6C2A2 forged try'));
select pg_temp.gated('a_forged', 'A5 a forged admin claim in the JWT cannot bypass require_admin() (roles come from user_roles)');
select pg_temp.same('A5 forged claim');

-- service_role: a server key carries no auth.uid(), so require_admin() refuses it. Either the EXECUTE
-- ACL or the gate refuses with 42501; what must hold is that it can NOT adjust stock.
select pg_temp.run_claims('a_service', 'service_role', jsonb_build_object('role', 'service_role'),
  format('select public.admin_adjust_inventory(%L::uuid, 5, %L)::text', pg_temp.p(1), 'T6C2A2 service try'));
select pg_temp.ok((select err is not null and state = '42501' and res is null from t_res where k = 'a_service'),
  'A6 service_role is refused (42501): it has no auth.uid(), so it is not an admin and cannot adjust stock [' ||
  coalesce((select state || ' ' || coalesce(detail, '-') from t_res where k = 'a_service'), 'no result') || ']');
select pg_temp.same('A6 service_role');

-- ===========================================================================
-- B. PRODUCT-LEVEL ADJUSTMENT
-- ===========================================================================
select pg_temp.adj('b_add', 'authenticated', pg_temp.u(3), pg_temp.p(1), '10', '  T6C2A2 delivery received  ', null, '  pallet 7  ');
select pg_temp.succeeded('b_add', 'B1 an admin can add stock to a product');
select pg_temp.ok(pg_temp.pstock(1) = 30, 'B2 product stock went 20 -> 30');
select pg_temp.ok(pg_temp.hist(1) = 1, 'B3 exactly one history row was written');
select pg_temp.ok(exists (
    select 1 from public.inventory_adjustments a
    where a.product_id = pg_temp.p(1) and a.variant_id is null
      and a.previous_quantity = 20 and a.adjustment_quantity = 10 and a.new_quantity = 30
      and a.reason = 'T6C2A2 delivery received' and a.note = 'pallet 7'
      and a.changed_by = pg_temp.u(3) and a.created_at is not null),
  'B4 the row has previous 20, delta +10, new 30, trimmed reason and note, and changed_by = the calling admin (auth.uid())');
select pg_temp.ok(
  (pg_temp.j('b_add') ->> 'adjustment_id')::uuid = (select id from public.inventory_adjustments where product_id = pg_temp.p(1))
  and (pg_temp.j('b_add') ->> 'product_id')::uuid = pg_temp.p(1)
  and pg_temp.j('b_add') -> 'variant_id' = 'null'::jsonb
  and (pg_temp.j('b_add') ->> 'previous_quantity')::int = 20
  and (pg_temp.j('b_add') ->> 'adjustment_quantity')::int = 10
  and (pg_temp.j('b_add') ->> 'new_quantity')::int = 30
  and pg_temp.j('b_add') ->> 'kind' = 'product',
  'B5 the JSON result carries adjustment_id, product_id, variant_id (null), previous / adjustment / new quantity');
select pg_temp.ok((select in_stock from public.products where id = pg_temp.p(1)) = true
  and pg_temp.vstock(1) = 7 and pg_temp.vstock(2) = 0,
  'B6 in_stock is preserved and the variants of that product were not touched');
select pg_temp.snap();

select pg_temp.adj('b_rem', 'authenticated', pg_temp.u(3), pg_temp.p(1), '-3', 'T6C2A2 spoilage');
select pg_temp.succeeded('b_rem', 'B7 an admin can remove stock from a product');
select pg_temp.ok(pg_temp.pstock(1) = 27 and pg_temp.hist(1) = 2
  and exists (select 1 from public.inventory_adjustments a
              where a.product_id = pg_temp.p(1) and a.previous_quantity = 30 and a.adjustment_quantity = -3
                and a.new_quantity = 27 and a.note is null and a.changed_by = pg_temp.u(3)),
  'B8 stock 30 -> 27, a second row (previous 30, delta -3, new 27, no note, changed_by = admin)');

-- in_stock is a manual flag: restocking a product that is flagged out of stock must NOT flip it.
select pg_temp.adj('b_flag', 'authenticated', pg_temp.u(3), pg_temp.p(2), '5', 'T6C2A2 restock rice');
select pg_temp.succeeded('b_flag', 'B9 an admin can restock a product that is flagged out of stock');
select pg_temp.ok(pg_temp.pstock(2) = 5 and (select in_stock from public.products where id = pg_temp.p(2)) = false,
  'B10 stock 0 -> 5 and in_stock is still false (the flag is manual and preserved, not derived)');

-- Exactly to zero is allowed (not negative).
select pg_temp.adj('b_zero', 'authenticated', pg_temp.u(3), pg_temp.p(3), '-9', 'T6C2A2 write-off');
select pg_temp.succeeded('b_zero', 'B11 removing exactly the whole stock (9 -> 0) is allowed');
select pg_temp.ok(pg_temp.pstock(3) = 0 and (select in_stock from public.products where id = pg_temp.p(3)) = true,
  'B12 stock reached 0 and in_stock was not changed');

-- Integer range boundary: 2147483640 + 7 = 2147483647 is allowed.
select pg_temp.adj('b_max', 'authenticated', pg_temp.u(3), pg_temp.p(4), '7', 'T6C2A2 boundary');
select pg_temp.succeeded('b_max', 'B13 an adjustment landing exactly on 2147483647 is allowed');
select pg_temp.ok(pg_temp.pstock(4) = 2147483647, 'B14 stock is 2147483647');
select pg_temp.snap();

-- ===========================================================================
-- C. VARIANT-LEVEL ADJUSTMENT
-- ===========================================================================
select pg_temp.adj('c_add', 'authenticated', pg_temp.u(3), pg_temp.p(1), '3', 'T6C2A2 variant delivery', pg_temp.v(1), 'crate');
select pg_temp.succeeded('c_add', 'C1 an admin can add stock to a variant');
select pg_temp.ok(pg_temp.vstock(1) = 10, 'C2 variant stock went 7 -> 10');
select pg_temp.ok(pg_temp.pstock(1) = 27 and (select in_stock from public.products where id = pg_temp.p(1)) = true
  and pg_temp.vstock(2) = 0,
  'C3 the PARENT product stock (27) and in_stock are unchanged, and the other variant is untouched');
select pg_temp.ok(exists (
    select 1 from public.inventory_adjustments a
    where a.product_id = pg_temp.p(1) and a.variant_id = pg_temp.v(1)
      and a.previous_quantity = 7 and a.adjustment_quantity = 3 and a.new_quantity = 10
      and a.reason = 'T6C2A2 variant delivery' and a.note = 'crate' and a.changed_by = pg_temp.u(3))
  and (select count(*) from public.inventory_adjustments where variant_id = pg_temp.v(1)) = 1,
  'C4 exactly one history row for the variant: product_id, variant_id, previous 7, delta +3, new 10, changed_by = admin');
select pg_temp.ok((pg_temp.j('c_add') ->> 'variant_id')::uuid = pg_temp.v(1)
  and (pg_temp.j('c_add') ->> 'new_quantity')::int = 10 and pg_temp.j('c_add') ->> 'kind' = 'variant',
  'C5 the JSON result names the variant and the new quantity');

select pg_temp.adj('c_rem', 'authenticated', pg_temp.u(3), pg_temp.p(1), '-4', 'T6C2A2 variant damage', pg_temp.v(1));
select pg_temp.succeeded('c_rem', 'C6 an admin can remove stock from a variant');
select pg_temp.ok(pg_temp.vstock(1) = 6 and pg_temp.pstock(1) = 27
  and exists (select 1 from public.inventory_adjustments a
              where a.variant_id = pg_temp.v(1) and a.previous_quantity = 10 and a.adjustment_quantity = -4 and a.new_quantity = 6),
  'C7 variant 10 -> 6, product still 27, row (previous 10, delta -4, new 6)');
select pg_temp.snap();

select pg_temp.adj('c_mismatch', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'T6C2A2 mismatch', pg_temp.v(3));
select pg_temp.refused('c_mismatch', 'variant_product_mismatch', 'C8 a variant of ANOTHER product is refused');
select pg_temp.same('C8 mismatch');
select pg_temp.ok(pg_temp.vstock(3) = 4, 'C9 the other product''s variant stock is untouched (4)');

-- ===========================================================================
-- D. VALIDATION (each refusal must change nothing)
-- ===========================================================================
select pg_temp.adj('d_zero', 'authenticated', pg_temp.u(3), pg_temp.p(1), '0', 'T6C2A2 zero');
select pg_temp.refused('d_zero', 'zero_adjustment_not_allowed', 'D1 a zero delta is refused');
select pg_temp.same('D1 zero');
select pg_temp.adj('d_zero_v', 'authenticated', pg_temp.u(3), pg_temp.p(1), '0', 'T6C2A2 zero', pg_temp.v(1));
select pg_temp.refused('d_zero_v', 'zero_adjustment_not_allowed', 'D2 a zero delta on a variant is refused');
select pg_temp.same('D2 zero variant');

select pg_temp.adj('d_neg', 'authenticated', pg_temp.u(3), pg_temp.p(1), '-28', 'T6C2A2 too much');
select pg_temp.refused('d_neg', 'negative_stock_not_allowed', 'D3 removing more than the product holds (27, -28) is refused, not clamped to 0');
select pg_temp.same('D3 negative product');
select pg_temp.adj('d_neg_v', 'authenticated', pg_temp.u(3), pg_temp.p(1), '-7', 'T6C2A2 too much', pg_temp.v(1));
select pg_temp.refused('d_neg_v', 'negative_stock_not_allowed', 'D4 removing more than the variant holds (6, -7) is refused');
select pg_temp.same('D4 negative variant');
select pg_temp.adj('d_neg_min', 'authenticated', pg_temp.u(3), pg_temp.p(1), '(-2147483647 - 1)', 'T6C2A2 minimum integer');
select pg_temp.refused('d_neg_min', 'negative_stock_not_allowed', 'D5 the smallest integer delta is refused cleanly (no overflow)');
select pg_temp.same('D5 min int');

select pg_temp.adj('d_over', 'authenticated', pg_temp.u(3), pg_temp.p(4), '1', 'T6C2A2 over the top');
select pg_temp.refused('d_over', 'stock_overflow', 'D6 2147483647 + 1 is refused (stock_overflow)');
select pg_temp.same('D6 overflow');
select pg_temp.adj('d_over2', 'authenticated', pg_temp.u(3), pg_temp.p(1), '2147483647', 'T6C2A2 huge');
select pg_temp.refused('d_over2', 'stock_overflow', 'D7 27 + 2147483647 is refused (computed in bigint, no wrap-around)');
select pg_temp.same('D7 overflow 2');
select pg_temp.adj('d_over3', 'authenticated', pg_temp.u(3), pg_temp.p(1), '2147483648', 'T6C2A2 beyond integer');
select pg_temp.ok((select err is not null and state = '22003' and res is null from t_res where k = 'd_over3'),
  'D8 a delta beyond the integer range is rejected by the type (22003) before anything runs');
select pg_temp.same('D8 beyond integer');

select pg_temp.adj('d_noprod', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6e0999999999'::uuid, '1', 'T6C2A2 ghost');
select pg_temp.refused('d_noprod', 'product_not_found', 'D9 a nonexistent product is refused');
select pg_temp.same('D9 no product');
select pg_temp.adj('d_novar', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'T6C2A2 ghost', '00000000-0000-4000-8000-6e1999999999'::uuid);
select pg_temp.refused('d_novar', 'variant_not_found', 'D10 a nonexistent variant is refused');
select pg_temp.same('D10 no variant');
select pg_temp.adj('d_mis2', 'authenticated', pg_temp.u(3), pg_temp.p(3), '1', 'T6C2A2 mismatch', pg_temp.v(1));
select pg_temp.refused('d_mis2', 'variant_product_mismatch', 'D11 the mismatch is refused in the other direction too (variant of p1 with product p3)');
select pg_temp.same('D11 mismatch 2');
select pg_temp.adj('d_nullprod', 'authenticated', pg_temp.u(3), null, '1', 'T6C2A2 null product');
select pg_temp.refused('d_nullprod', 'invalid_arguments', 'D12 a NULL product id is refused');
select pg_temp.same('D12 null product');
select pg_temp.adj('d_nulldelta', 'authenticated', pg_temp.u(3), pg_temp.p(1), null, 'T6C2A2 null delta');
select pg_temp.refused('d_nulldelta', 'invalid_arguments', 'D13 a NULL delta is refused');
select pg_temp.same('D13 null delta');

select pg_temp.adj('d_r_null', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', null);
select pg_temp.refused('d_r_null', 'invalid_arguments', 'D14 a NULL reason is refused');
select pg_temp.adj('d_r_blank', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', '');
select pg_temp.refused('d_r_blank', 'invalid_arguments', 'D15 an empty reason is refused');
select pg_temp.adj('d_r_space', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', '     ');
select pg_temp.refused('d_r_space', 'invalid_arguments', 'D16 a whitespace-only reason is refused');
select pg_temp.adj('d_r_long', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', repeat('r', 121));
select pg_temp.refused('d_r_long', 'invalid_arguments', 'D17 a 121-character reason is refused');
select pg_temp.same('D14-D17 reasons');
select pg_temp.adj('d_n_long', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'T6C2A2 long note', null, repeat('n', 501));
select pg_temp.refused('d_n_long', 'invalid_arguments', 'D18 a 501-character note is refused');
select pg_temp.adj('d_n_blank', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'T6C2A2 blank note', null, '   ');
select pg_temp.refused('d_n_blank', 'invalid_arguments', 'D19 a blank note is refused (the history table forbids an empty note)');
select pg_temp.same('D18-D19 notes');

-- Boundaries that ARE allowed: 120-character reason, 500-character note.
select pg_temp.adj('d_edge', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', repeat('r', 120), null, repeat('n', 500));
select pg_temp.succeeded('d_edge', 'D20 a 120-character reason and a 500-character note are accepted');
select pg_temp.ok(pg_temp.pstock(1) = 28 and exists (
    select 1 from public.inventory_adjustments a
    where a.product_id = pg_temp.p(1) and a.new_quantity = 28 and char_length(a.reason) = 120 and char_length(a.note) = 500),
  'D21 stock 27 -> 28 and the row holds the full-length reason and note');
select pg_temp.snap();

-- ===========================================================================
-- E. ATOMICITY and the stock-equals-history invariant
-- ===========================================================================
-- A successful call whose transaction later aborts must leave neither the stock change nor the row.
do $$
declare v_msg text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', pg_temp.u(3), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.u(3)::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    execute 'set local role authenticated';
    perform public.admin_adjust_inventory(pg_temp.p(1), 5, 'T6C2A2 rollback probe');
    execute 'reset role';  -- the test owner reads the in-flight state
    raise exception 'PROBE:%:%', (select stock_quantity from public.products where id = pg_temp.p(1)),
      (select count(*) from public.inventory_adjustments where product_id = pg_temp.p(1));
  exception when others then
    get stacked diagnostics v_msg = message_text;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_h values ('probe', v_msg);
end $$;
select pg_temp.ok((select h from t_h where k = 'probe') = 'PROBE:33:' || (pg_temp.hist(1) + 1)::text,
  'E1 inside the aborted transaction the call HAD changed stock (28 -> 33) and written its history row (stock and history move together)');
select pg_temp.same('E1 aborted success: both the stock change and the history row rolled back together');

-- Stock = starting stock + the sum of that unit's recorded deltas (nothing changed stock without a row).
select pg_temp.ok(
  pg_temp.pstock(1) = 20 + (select sum(adjustment_quantity) from public.inventory_adjustments
                            where product_id = pg_temp.p(1) and variant_id is null)
  and pg_temp.vstock(1) = 7 + (select sum(adjustment_quantity) from public.inventory_adjustments
                               where variant_id = pg_temp.v(1))
  and pg_temp.pstock(2) = 0 + (select sum(adjustment_quantity) from public.inventory_adjustments where product_id = pg_temp.p(2))
  and pg_temp.pstock(3) = 9 + (select sum(adjustment_quantity) from public.inventory_adjustments where product_id = pg_temp.p(3) and variant_id is null)
  and pg_temp.vstock(3) = 4,
  'E2 INVARIANT: every unit''s stock equals its starting stock plus the sum of its history deltas');
select pg_temp.ok(not exists (
    select 1 from public.inventory_adjustments a
    where a.product_id in (select id from public.products where slug like 't6c2a2-%')
      and (a.new_quantity <> a.previous_quantity + a.adjustment_quantity or a.changed_by is null)),
  'E3 every history row is internally consistent and attributed');
-- ===========================================================================
-- F. SECURITY ATTRIBUTES
-- ===========================================================================
select pg_temp.ok(
  (select count(*) from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure) = 1
  and (select prosecdef from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure),
  'F1 admin_adjust_inventory(uuid, integer, text, uuid, text) exists and is SECURITY DEFINER');
select pg_temp.ok(
  (select proconfig::text from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
    like '%search_path=public, pg_temp%',
  'F2 search_path is pinned to public, pg_temp');
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure
                    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'F3 authenticated can EXECUTE; anon cannot; PUBLIC cannot');
select pg_temp.ok(
  position('public.require_admin()' in (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace)) > 0
  and position('public.require_admin()' in (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace))
      < position('for update' in (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace)),
  'F4 the body calls require_admin() before it locks or writes anything');
select pg_temp.ok(
  (select pg_get_function_arguments(oid) from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
  = 'p_product_id uuid, p_adjustment_quantity integer, p_reason text, p_variant_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text',
  'F5 the signature accepts a DELTA only: no final quantity, no previous / new quantity, no user id');
select pg_temp.ok(
  (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace) ~* 'for key share'
  and (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace) ~* 'for update'
  and (select prosrc from pg_proc where proname = 'admin_adjust_inventory' and pronamespace = 'public'::regnamespace) ~* 'auth\.uid\(\)',
  'F6 the body locks rows (FOR UPDATE / FOR KEY SHARE) and takes the actor from auth.uid()');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.products', 'UPDATE') and not has_table_privilege('authenticated', 'public.products', 'UPDATE')
  and not has_any_column_privilege('anon', 'public.products', 'UPDATE') and not has_any_column_privilege('authenticated', 'public.products', 'UPDATE'),
  'F7 no browser UPDATE privilege on products (table or column)');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.product_variants', 'UPDATE') and not has_table_privilege('authenticated', 'public.product_variants', 'UPDATE')
  and not has_any_column_privilege('anon', 'public.product_variants', 'UPDATE') and not has_any_column_privilege('authenticated', 'public.product_variants', 'UPDATE'),
  'F8 no browser UPDATE privilege on product_variants (table or column)');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.inventory_adjustments', 'INSERT') and not has_table_privilege('authenticated', 'public.inventory_adjustments', 'INSERT')
  and not has_any_column_privilege('anon', 'public.inventory_adjustments', 'INSERT') and not has_any_column_privilege('authenticated', 'public.inventory_adjustments', 'INSERT')
  and not has_table_privilege('authenticated', 'public.inventory_adjustments', 'SELECT')
  and not has_table_privilege('anon', 'public.inventory_adjustments', 'SELECT'),
  'F9 no browser INSERT (or SELECT) privilege on inventory_adjustments');
select pg_temp.run('f_direct_upd', 'authenticated', pg_temp.u(3),
  format('update public.products set stock_quantity = 999 where id = %L returning id::text', pg_temp.p(1)));
select pg_temp.denied('f_direct_upd', 'F10 even an ADMIN cannot UPDATE products.stock_quantity directly - only through the function');
select pg_temp.run('f_direct_ins', 'authenticated', pg_temp.u(3),
  format('insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason, changed_by) values (%L, 1, 1, 2, %L, %L) returning id::text', pg_temp.p(1), 'T6C2A2 forged', pg_temp.u(3)));
select pg_temp.denied('f_direct_ins', 'F11 even an ADMIN cannot INSERT into inventory_adjustments directly');
select pg_temp.same('F10-F11 direct writes');
select pg_temp.ok(
  (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
  and (select coalesce(string_agg(t.tgname, ',' order by t.tgname collate "C"), '') from pg_trigger t
       where t.tgrelid = 'public.inventory_adjustments'::regclass and not t.tgisinternal)
      in ('', 'inventory_adjustments_append_only,inventory_adjustments_no_truncate'),
  'F12 the history table still has RLS on, no policy and no trigger other than (from Phase 9B) the two append-only guards');
select pg_temp.ok(
  (select array_agg(proname::text order by proname::text) from pg_proc
   where pronamespace = 'public'::regnamespace and proname ~* '(adjust|history)')
  in (array['admin_adjust_inventory'],
      array['admin_adjust_inventory', 'admin_list_inventory_adjustments'],
      array['admin_adjust_inventory', 'admin_list_inventory_adjustments', 'inventory_adjustments_guard']),
  'F13 the only adjust / history-named functions are admin_adjust_inventory, (once 6C.2.2B.1 is applied) the read-only admin_list_inventory_adjustments and (from Phase 9B) the append-only guard trigger function; no other writer or reader exists');
select pg_temp.ok(
  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace) = (select h from t_h where k = 'fn0')
  and pg_temp.acl_hash() = (select h from t_h where k = 'acl0')
  and pg_temp.pol_hash() = (select h from t_h where k = 'pol0')
  and (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')) = (select h from t_h where k = 'rel0'),
  'F14 running the function added no function, table, grant, RLS flag or policy');
select pg_temp.ok(pg_temp.ord_hash() = (select h from t_h where k = 'ord0'),
  'F15 orders and order items are byte-for-byte unchanged');
select pg_temp.ok(
  (select count(*) from pg_trigger t
   where not t.tgisinternal and t.tgenabled <> 'D' and t.tgrelid = 'public.orders'::regclass
     and t.tgfoid in ('public.restock_cancelled_order()'::regprocedure,
                      'public.guard_order_reactivation_capacity()'::regprocedure,
                      'public.log_order_status_change()'::regprocedure)) >= 3
  and (select count(*) from pg_proc where proname in ('create_order', 'set_order_status')
       and pronamespace = 'public'::regnamespace and prosrc ilike '%inventory_adjustments%') = 0,
  'F16 the order triggers are still enabled and create_order / set_order_status do not reference the history table (order stock logic untouched)');

-- ===========================================================================
-- G. REGRESSION: earlier phases
-- ===========================================================================
select pg_temp.ok(
  -- Later phases added admin functions (6G.4A payment readers; 6I.1 audit-log reader + 2 trigger functions);
  -- 6G.3 payment writers update only orders.payment_status. Compared bytewise (collate "C").
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
    = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[],
  'G1 the admin API is exactly the fifteen known functions (the thirteen from earlier phases + admin_adjust_inventory + 6C.2.2B.1 admin_list_inventory_adjustments)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%'
      -- 6I.1: admin_audit_log_block_change/_truncate are trigger functions (not callable RPCs), so the RPC rules do not apply.
      and p.proname !~ '^admin_audit_log_block_'
      and (not p.prosecdef
           or has_function_privilege('anon', p.oid, 'EXECUTE')
           or not has_function_privilege('authenticated', p.oid, 'EXECUTE')
           or position('public.require_admin()' in p.prosrc) = 0
           or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')),
  'G2 every admin_* function is SECURITY DEFINER, pins search_path, calls require_admin(), is not executable by anon and is executable by authenticated');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'G3 a browser role still cannot execute require_admin() directly');
select pg_temp.ok(
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
              and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'G4 REGRESSION 5B.2: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.ok(
  not exists (select 1 from pg_class c
              where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass, 'public.order_status_history'::regclass,
                              'public.user_roles'::regclass, 'public.addresses'::regclass, 'public.products'::regclass,
                              'public.product_variants'::regclass, 'public.inventory_adjustments'::regclass)
                and not c.relrowsecurity)
  and not exists (select 1 from pg_policies where schemaname = 'public'
                  and tablename in ('orders', 'order_items', 'order_status_history', 'products', 'product_variants',
                                    'categories', 'inventory_adjustments')
                  and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  'G5 REGRESSION 5B.2 / 6B / 6C: RLS is on for the protected tables and no write policy exists on them');
select pg_temp.run('g_inv_s', 'authenticated', pg_temp.u(2), $$select public.admin_list_inventory(p_search => 'T6C2A2')::text$$);
select pg_temp.gated('g_inv_s', 'G6 REGRESSION 6C.2.1: admin_list_inventory still refuses staff');
select pg_temp.run('g_inv_a', 'authenticated', pg_temp.u(3), $$select public.admin_list_inventory(p_search => 'T6C2A2')::text$$);
select pg_temp.ok((select (res::jsonb ->> 'total')::integer from t_res where k = 'g_inv_a') = 7,
  'G7 REGRESSION 6C.2.1: admin_list_inventory (admin) still lists the stock units (p1 + its 2 variants, p2, p3 + its variant, p4 = 7)');
select pg_temp.run('g_ord_a', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('g_ord_a', 'G8 REGRESSION 6B.1: admin_list_orders still works for an admin');
select pg_temp.run('g_prod_c', 'authenticated', pg_temp.u(1), 'select public.admin_list_products()::text');
select pg_temp.gated('g_prod_c', 'G9 REGRESSION 6C.1A: admin_list_products still refuses a customer');
select pg_temp.run('g_upd_s', 'authenticated', pg_temp.u(2),
  format($q$select public.admin_update_product(%L::uuid, '{"stock_quantity": 999}'::jsonb)::text$q$, pg_temp.p(1)));
select pg_temp.gated('g_upd_s', 'G10 REGRESSION 6C.1B.1: admin_update_product still refuses staff, and stock is not editable through it');
select pg_temp.run('g_upd_a', 'authenticated', pg_temp.u(3),
  format($q$select public.admin_update_product(%L::uuid, '{"stock_quantity": 999}'::jsonb)::text$q$, pg_temp.p(1)));
select pg_temp.refused('g_upd_a', 'unsupported_field', 'G11 REGRESSION 6C.1B.1: even an admin cannot set stock_quantity through admin_update_product');
select pg_temp.snap();

do $$ begin raise notice 'ALL PHASE 6C.2.2A.2 TESTS PASSED'; end $$;

rollback;
