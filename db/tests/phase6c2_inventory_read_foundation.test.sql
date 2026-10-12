-- =============================================================================
-- PHASE 6C.2.1 database test: admin inventory READ foundation.
--
-- STATUS: written for migration 20261004080000_phase6c2_inventory_read_foundation.sql.
-- NOT run against any database when it was written (no PostgreSQL was available); see the report.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004080000_phase6c2_inventory_read_foundation.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c2_inventory_read_foundation.test.sql
--
-- (Supabase SQL Editor: paste the whole file and Run. The editor shows only the last result, so
-- an empty "ok" row with no error means every check passed; any failure raises "FAIL: <name>".)
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.2.1 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST. Authorization is the
-- REAL public.require_admin() / public.user_roles; nothing is faked.
--
-- NOT-EMPTY PROOF: every refusal is asserted as an ERROR (42501), never as "0 rows", and is
-- followed by a positive control in which the admin succeeds with the same kind of arguments.
-- Hashes of products / product_variants / orders / order_items prove the reads wrote nothing.
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them: every assertion is scoped to fixture rows (slug / name 't6c2' /
-- 'T6C2'), the only writes are to fixture rows, and the whole run is rolled back.
--
-- NOTE: the older tests db/tests/phase6b2, phase6c1a2, phase6c1b1 and phase6c1b2 contain exact
-- allow-lists of admin / inventory-named functions. They were updated (test-only) to include the
-- two read functions of this phase, so run THEM after applying this migration, not before.
--
-- COVERS
--   A  authorization: admin ok; staff / customer / anon / signed-out / forged / service_role refused
--   B  admin_list_inventory: shape, rows, order, pagination, search (escaping), filters, validation
--   C  admin_get_inventory: product unit, variant unit, errors, equals the list rows
--   D  function security: SECURITY DEFINER, STABLE, search_path, require_admin, ACL, no table privileges
--   E  reads modify nothing (stock, flags, orders, order items)
--   F  the reads see what the earlier admin write RPCs change
--   G  regression: 6C.1B.2, 6C.1B.1, 6C.1A.2, 6C.1A.1, 6B.2, 6B.1, 6A, 5B.2, 5A.2
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
  -- PL/pgSQL returns '' (not NULL) from pg_exception_detail when an error has no DETAIL line.
  -- Normalise to NULL so "no detail" assertions (expect_err(..., null, ...)) mean what they say.
  insert into t_res values (p_k, v_res, v_err, v_state, nullif(v_detail, ''))
  on conflict (k) do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end;
$$;

-- Normal signed-in (or signed-out when p_uid is null) call.
create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
begin
  perform pg_temp.run_claims(p_k, p_role,
    case when p_uid is null then null else jsonb_build_object('sub', p_uid, 'role', p_role) end,
    p_sql);
end;
$$;

create or replace function pg_temp.res(p_k text) returns text language sql as $$
  select res from t_res where k = p_k $$;
create or replace function pg_temp.j(p_k text) returns jsonb language sql as $$
  select res::jsonb from t_res where k = p_k $$;

-- Call admin_list_products(<args>) as a role.
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

-- Refused before the function body ran: plain "permission denied" (42501, no detail), no result.
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

create or replace function pg_temp.expect_err(p_k text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  if r.err is null then
    raise exception 'FAIL: % (expected an error, got a result)', p_name;
  end if;
  perform pg_temp.ok(r.state = p_state and r.detail is not distinct from p_detail,
    p_name || ' [' || r.state || ' ' || coalesce(r.detail, '-') || ']');
end;
$$;

-- A statement succeeded (no error, a result recorded).
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

-- A write was blocked: SQLSTATE 42501 (no table privilege) - never "succeeded", never 0 rows.
create or replace function pg_temp.write_denied(p_k text, p_name text)
returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501', p_name || ' [' || coalesce(r.state, 'no error') || ']');
end;
$$;

-- Sorted, comma-joined top-level keys of a jsonb object.
create or replace function pg_temp.keys(p_j jsonb) returns text language sql as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(p_j) k $$;

-- ---------------------------------------------------------------------------
-- Phase-specific helpers
-- ---------------------------------------------------------------------------
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d800000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d9000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6da000000' || lpad(n::text, 3, '0'))::uuid $$;

-- admin_list_inventory(<named args>) as a role.
create or replace function pg_temp.li(p_k text, p_role text, p_uid uuid, p_args text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_list_inventory(' || p_args || ')::text');
end;
$$;
-- admin_get_inventory(product, variant) as a role.
create or replace function pg_temp.gi(p_k text, p_role text, p_uid uuid, p_pid uuid, p_vid uuid)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    format('select public.admin_get_inventory(%L::uuid, %L::uuid)::text', p_pid, p_vid));
end;
$$;
-- The admin lists with the given args (fixtures are always found with p_search => 'T6C2').
create or replace function pg_temp.adm_li(p_k text, p_args text)
returns void language plpgsql as $$
begin
  perform pg_temp.li(p_k, 'authenticated', pg_temp.u(3), p_args);
end;
$$;
create or replace function pg_temp.li_bad(p_k text, p_args text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.adm_li(p_k, p_args);
  perform pg_temp.expect_err(p_k, 'P0001', 'invalid_arguments', p_name);
end;
$$;

-- Unit ids (variant id for a variant unit, product id for a product unit) of a result page, in order.
create or replace function pg_temp.ids(p_arr jsonb) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> 'variant_id', e ->> 'product_id') order by o), '{}'::text[])
  from jsonb_array_elements(p_arr) with ordinality t(e, o) $$;
create or replace function pg_temp.inv(p_k text) returns jsonb language sql as $$
  select (res::jsonb) -> 'inventory' from t_res where k = p_k $$;
-- A jsonb object has exactly these keys (collation-proof).
create or replace function pg_temp.haskeys(p_j jsonb, p_keys text[]) returns boolean language sql as $$
  select p_j ?& p_keys and (select count(*) from jsonb_object_keys(p_j)) = array_length(p_keys, 1) $$;

-- Expected inventory rows, built straight from the tables (owner view, no role switch).
create or replace function pg_temp.inv_p(p_id uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'kind', 'product', 'product_id', p.id, 'variant_id', null, 'sku', p.sku,
    'product_name', p.name, 'product_slug', p.slug, 'variant_name', null,
    'price_cents', p.price_cents, 'stock_quantity', p.stock_quantity, 'in_stock', p.in_stock,
    'is_active', p.is_active, 'product_is_active', p.is_active,
    'variant_count', (select count(*) from public.product_variants x where x.product_id = p.id),
    'updated_at', p.updated_at)
  from public.products p where p.id = p_id $$;
create or replace function pg_temp.inv_v(p_id uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'kind', 'variant', 'product_id', p.id, 'variant_id', v.id, 'sku', v.sku,
    'product_name', p.name, 'product_slug', p.slug, 'variant_name', v.name,
    'price_cents', v.price_cents, 'stock_quantity', v.stock_quantity, 'in_stock', null,
    'is_active', v.is_active, 'product_is_active', p.is_active, 'variant_count', null,
    'updated_at', v.updated_at)
  from public.product_variants v join public.products p on p.id = v.product_id
  where v.id = p_id $$;
create or replace function pg_temp.inv_u(p_id uuid) returns jsonb language sql as $$
  select coalesce(pg_temp.inv_p(p_id), pg_temp.inv_v(p_id)) $$;

-- Hashes (to prove "nothing was written").
create or replace function pg_temp.prod_hash() returns text language sql as $$
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p $$;
create or replace function pg_temp.var_hash() returns text language sql as $$
  select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v $$;
create or replace function pg_temp.ord_hash() returns text language sql as $$
  select md5(coalesce((select string_agg(o::text, '|' order by o.id) from public.orders o), '')
          || '#' || coalesce((select string_agg(i::text, '|' order by i.id) from public.order_items i), '')) $$;
-- The inventory columns of the fixtures (variant stock; product stock + in_stock + is_active).
create or replace function pg_temp.stock_hash() returns text language sql as $$
  select md5(
    coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text || ':' || v.is_active::text, '|' order by v.id)
              from public.product_variants v where v.product_id in (pg_temp.p(1), pg_temp.p(2), pg_temp.p(3), pg_temp.p(4))), '')
    || '#' ||
    coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text || ':' || p.is_active::text, '|' order by p.id)
              from public.products p where p.id in (pg_temp.p(1), pg_temp.p(2), pg_temp.p(3), pg_temp.p(4))), '')) $$;

create temp table t_h (k text primary key, h text);

-- ---------------------------------------------------------------------------
-- Fixtures
--   p1 Milk   active, stock 20, in_stock, brand 'T6C2Brand'; variants v1 (1L, stock 7, active),
--                                                              v2 (2L, stock 0, INACTIVE)
--   p2 Rice   INACTIVE, stock 0, in_stock false, no variants
--   p3 Juice  active, name contains the literal characters % and _; variant v3 (active, stock 4)
--   p4 Tea    INACTIVE product with an ACTIVE variant v4 (product_is_active false, is_active true)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c2-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C2 Customer"}'),
  (pg_temp.u(2), 't6c2-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2 Staff"}'),
  (pg_temp.u(3), 't6c2-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2 Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

insert into public.products
  (id, slug, name, brand, sku, price_cents, unit_label, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1), 't6c2-milk',  'T6C2 Milk',             'T6C2Brand', 'T6C2-MILK',  500, '1 L',  20, true,  true),
  (pg_temp.p(2), 't6c2-rice',  'T6C2 Rice',             null,        'T6C2-RICE',  700, '1 kg',  0, false, false),
  (pg_temp.p(3), 't6c2-juice', 'T6C2 100%_Pure Juice',  null,        'T6C2-JUICE', 300, null,     5, true,  true),
  (pg_temp.p(4), 't6c2-tea',   'T6C2 Tea',              null,        'T6C2-TEA',   250, null,     3, true,  false);

insert into public.product_variants
  (id, product_id, name, sku, price_cents, stock_quantity, position, is_active)
values
  (pg_temp.v(1), pg_temp.p(1), 'T6C2 Milk 1L',   'T6C2-MILK-1L',  500, 7, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6C2 Milk 2L',   'T6C2-MILK-2L',  900, 0, 2, false),
  (pg_temp.v(3), pg_temp.p(3), 'T6C2 Juice Pack','T6C2-JUICE-P',  400, 4, 1, true),
  (pg_temp.v(4), pg_temp.p(4), 'T6C2 Tea Box',   'T6C2-TEA-B',    200, 2, 1, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c2-%') = 4
  and (select count(*) from public.product_variants where id in (pg_temp.v(1), pg_temp.v(2), pg_temp.v(3), pg_temp.v(4))) = 4,
  'FIXTURE: four test products (milk, rice, juice, tea) and four variants exist');

insert into t_h values
  ('prod0', pg_temp.prod_hash()),
  ('var0', pg_temp.var_hash()),
  ('ord0', pg_temp.ord_hash()),
  ('stock0', pg_temp.stock_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))),
  ('pol0', (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''), '|'
                                           order by tablename, policyname), ''))
            from pg_policies where schemaname = 'public' and tablename in ('products', 'product_variants'))),
  ('acl0', (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, ''), '|' order by c.relname), ''))
            from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
              and c.relname in ('products', 'product_variants', 'orders', 'order_items', 'user_roles')));

-- The fixture units in the order the list must return them for p_search => 'T6C2':
--   product name, then product unit before its variants, then variant position.
--   Juice (p3, v3), Milk (p1, v1, v2), Rice (p2), Tea (p4, v4).
create temp table t_exp as
  select array[pg_temp.p(3)::text, pg_temp.v(3)::text,
               pg_temp.p(1)::text, pg_temp.v(1)::text, pg_temp.v(2)::text,
               pg_temp.p(2)::text,
               pg_temp.p(4)::text, pg_temp.v(4)::text] as all_ids;

-- ===========================================================================
-- A. AUTHORIZATION
--    Every refusal is an ERROR (42501), never "0 rows", uses VALID arguments (without the gate
--    it would succeed) and is followed by a positive control in which the admin succeeds.
-- ===========================================================================
-- STAFF (staff is not admin)
select pg_temp.li('a_s_li', 'authenticated', pg_temp.u(2), $$p_search => 'T6C2'$$);
select pg_temp.gated('a_s_li', 'STAFF cannot list inventory (42501 / not_authorised)');
select pg_temp.gi('a_s_gi', 'authenticated', pg_temp.u(2), pg_temp.p(1), null);
select pg_temp.gated('a_s_gi', 'STAFF cannot get a product inventory unit (42501 / not_authorised)');
select pg_temp.gi('a_s_gv', 'authenticated', pg_temp.u(2), pg_temp.p(1), pg_temp.v(1));
select pg_temp.gated('a_s_gv', 'STAFF cannot get a variant inventory unit (42501 / not_authorised)');
-- CUSTOMER
select pg_temp.li('a_c_li', 'authenticated', pg_temp.u(1), $$p_search => 'T6C2'$$);
select pg_temp.gated('a_c_li', 'CUSTOMER cannot list inventory (42501 / not_authorised)');
select pg_temp.gi('a_c_gi', 'authenticated', pg_temp.u(1), pg_temp.p(1), null);
select pg_temp.gated('a_c_gi', 'CUSTOMER cannot get a product inventory unit (42501 / not_authorised)');
select pg_temp.gi('a_c_gv', 'authenticated', pg_temp.u(1), pg_temp.p(1), pg_temp.v(1));
select pg_temp.gated('a_c_gv', 'CUSTOMER cannot get a variant inventory unit (42501 / not_authorised)');
-- ANON (even carrying the admin user id in its claims): refused before the function body runs
select pg_temp.li('a_a_li', 'anon', pg_temp.u(3), $$p_search => 'T6C2'$$);
select pg_temp.no_execute('a_a_li', 'ANON cannot execute admin_list_inventory (even carrying the admin user id)');
select pg_temp.gi('a_a_gi', 'anon', pg_temp.u(3), pg_temp.p(1), null);
select pg_temp.no_execute('a_a_gi', 'ANON cannot execute admin_get_inventory (even carrying the admin user id)');
-- SIGNED OUT (anon, no JWT)
select pg_temp.li('a_o_li', 'anon', null, $$p_search => 'T6C2'$$);
select pg_temp.no_execute('a_o_li', 'SIGNED OUT (anon, no JWT) cannot execute admin_list_inventory');
select pg_temp.gi('a_o_gi', 'anon', null, pg_temp.p(1), null);
select pg_temp.no_execute('a_o_gi', 'SIGNED OUT (anon, no JWT) cannot execute admin_get_inventory');
-- SIGNED OUT as the authenticated role (auth.uid() is null)
select pg_temp.li('a_n_li', 'authenticated', null, $$p_search => 'T6C2'$$);
select pg_temp.gated('a_n_li', 'SIGNED OUT (authenticated role, auth.uid() null): list refused by the admin gate');
select pg_temp.gi('a_n_gi', 'authenticated', null, pg_temp.p(1), null);
select pg_temp.gated('a_n_gi', 'SIGNED OUT (authenticated role, auth.uid() null): detail refused by the admin gate');
-- FORGED claims
select pg_temp.run_claims('a_f_li', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin'), 'is_admin', true),
  $$select public.admin_list_inventory(p_search => 'T6C2')::text$$);
select pg_temp.gated('a_f_li', 'FORGED: customer JWT with admin claims in every claim location is refused (list)');
select pg_temp.run_claims('a_f_gi', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(2), 'role', 'service_role', 'admin', true),
  format($$select public.admin_get_inventory(%L::uuid)::text$$, pg_temp.p(1)));
select pg_temp.gated('a_f_gi', 'FORGED: staff JWT claiming role=service_role / admin=true is refused (detail)');
select pg_temp.run_claims('a_f_gh', 'authenticated',
  jsonb_build_object('sub', '00000000-0000-4000-8000-6d8fffffffff', 'role', 'authenticated'),
  $$select public.admin_list_inventory()::text$$);
select pg_temp.gated('a_f_gh', 'FORGED: a well-formed JWT for a user id that does not exist is refused (list)');
-- SERVICE ROLE without an admin user (no auth.uid())
select pg_temp.li('a_v_li', 'service_role', null, $$p_search => 'T6C2'$$);
select pg_temp.gated('a_v_li', 'SERVICE ROLE without an admin user is refused by the gate (list; no auth.uid())');
select pg_temp.gi('a_v_gi', 'service_role', null, pg_temp.p(1), null);
select pg_temp.gated('a_v_gi', 'SERVICE ROLE without an admin user is refused by the gate (detail)');

-- The gate runs BEFORE argument validation and BEFORE the existence check: a refused caller learns
-- nothing about the rules or about which rows exist.
select pg_temp.li('a_g1', 'authenticated', pg_temp.u(1), 'p_limit => 0, p_offset => -5');
select pg_temp.gated('a_g1', 'GATE ORDER: customer with invalid list arguments gets not_authorised, not invalid_arguments');
select pg_temp.li('a_g2', 'authenticated', pg_temp.u(2), $$p_search => repeat('x', 500)$$);
select pg_temp.gated('a_g2', 'GATE ORDER: staff with an over-long search gets not_authorised');
select pg_temp.gi('a_g3', 'authenticated', pg_temp.u(1), null, null);
select pg_temp.gated('a_g3', 'GATE ORDER: customer with a NULL product id gets not_authorised, not invalid_arguments');
select pg_temp.gi('a_g4', 'authenticated', pg_temp.u(2), '00000000-0000-4000-8000-6d9fffffffff', '00000000-0000-4000-8000-6dafffffffff');
select pg_temp.gated('a_g4', 'GATE ORDER: staff with an unknown product and variant id gets not_authorised (no existence leak)');

select pg_temp.ok(pg_temp.prod_hash() = (select h from t_h where k = 'prod0')
  and pg_temp.var_hash() = (select h from t_h where k = 'var0'),
  'REFUSED CALLS WROTE NOTHING: a hash of every product row and every variant row is unchanged after all refused attempts');

-- Positive controls: the admin succeeds with the SAME kind of arguments that were refused above.
select pg_temp.li('a_adm_li', 'authenticated', pg_temp.u(3), $$p_search => 'T6C2'$$);
select pg_temp.succeeded('a_adm_li', 'ADMIN can list inventory (positive control for the list refusals above)');
select pg_temp.gi('a_adm_gi', 'authenticated', pg_temp.u(3), pg_temp.p(1), null);
select pg_temp.succeeded('a_adm_gi', 'ADMIN can get a product inventory unit (positive control for the detail refusals above)');
select pg_temp.gi('a_adm_gv', 'authenticated', pg_temp.u(3), pg_temp.p(1), pg_temp.v(1));
select pg_temp.succeeded('a_adm_gv', 'ADMIN can get a variant inventory unit (positive control for the variant refusals above)');

-- ===========================================================================
-- B. admin_list_inventory
-- ===========================================================================
select pg_temp.adm_li('b_all', $$p_search => 'T6C2', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.haskeys(pg_temp.j('b_all'), array['total', 'limit', 'offset', 'inventory'])
  and (pg_temp.j('b_all') ->> 'total')::integer = 8
  and (pg_temp.j('b_all') ->> 'limit')::integer = 100
  and (pg_temp.j('b_all') ->> 'offset')::integer = 0
  and jsonb_typeof(pg_temp.j('b_all') -> 'inventory') = 'array'
  and jsonb_array_length(pg_temp.j('b_all') -> 'inventory') = 8,
  'LIST: result is { total, limit, offset, inventory } with 8 units for the 4 products + 4 variants (one product unit per product, one unit per variant)');
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_all') -> 'inventory') = (select all_ids from t_exp),
  'LIST ORDER: product name, then the product unit before its variants, then variant position (Juice, Milk, Rice, Tea)');
select pg_temp.ok(
  (select bool_and(pg_temp.haskeys(e, array['kind', 'product_id', 'variant_id', 'sku', 'product_name', 'product_slug',
                                           'variant_name', 'price_cents', 'stock_quantity', 'in_stock', 'is_active',
                                           'product_is_active', 'variant_count', 'updated_at']))
   from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e),
  'LIST ROW SHAPE: every row has exactly the 14 documented keys (variant rows carry null, never a missing key)');
select pg_temp.ok(
  (select bool_and(e = pg_temp.inv_u(coalesce(e ->> 'variant_id', e ->> 'product_id')::uuid))
   from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e),
  'LIST VALUES: every returned row equals the stored product / variant data (sku, names, price, stock, flags, updated_at)');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'kind' = 'product') = 4
  and (select count(*) from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'kind' = 'variant') = 4
  and (select bool_and(e -> 'variant_id' = 'null'::jsonb and e -> 'variant_name' = 'null'::jsonb
                       and jsonb_typeof(e -> 'in_stock') = 'boolean' and jsonb_typeof(e -> 'variant_count') = 'number')
       from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'kind' = 'product')
  and (select bool_and(e -> 'in_stock' = 'null'::jsonb and e -> 'variant_count' = 'null'::jsonb
                       and e ->> 'variant_id' is not null and e ->> 'variant_name' is not null)
       from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'kind' = 'variant'),
  'LIST KINDS: product rows have a boolean in_stock, a variant_count and null variant fields; variant rows have in_stock null (the table has no such column) and variant_count null');
select pg_temp.ok(
  (select (e ->> 'variant_count')::integer from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'product_id' = pg_temp.p(1)::text and e ->> 'kind' = 'product') = 2
  and (select (e ->> 'variant_count')::integer from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'product_id' = pg_temp.p(2)::text and e ->> 'kind' = 'product') = 0,
  'LIST: variant_count is 2 for the milk product and 0 for the product without variants');
select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e
          where e ->> 'product_id' = pg_temp.p(2)::text and e ->> 'kind' = 'product'
            and (e ->> 'stock_quantity')::integer = 0 and (e ->> 'in_stock')::boolean = false and (e ->> 'is_active')::boolean = false)
  and exists (select 1 from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e
              where e ->> 'variant_id' = pg_temp.v(2)::text and (e ->> 'stock_quantity')::integer = 0 and (e ->> 'is_active')::boolean = false)
  and exists (select 1 from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e
              where e ->> 'variant_id' = pg_temp.v(4)::text and (e ->> 'is_active')::boolean = true and (e ->> 'product_is_active')::boolean = false),
  'LIST: inactive, out-of-stock and zero-stock units are included, and an active variant of an inactive product shows is_active true with product_is_active false');
select pg_temp.ok(
  (select e ->> 'stock_quantity' from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'product_id' = pg_temp.p(1)::text and e ->> 'kind' = 'product') = '20'
  and (select e ->> 'stock_quantity' from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'variant_id' = pg_temp.v(1)::text) = '7'
  and (select e ->> 'sku' from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'variant_id' = pg_temp.v(1)::text) = 'T6C2-MILK-1L'
  and (select e ->> 'price_cents' from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') e where e ->> 'variant_id' = pg_temp.v(2)::text) = '900',
  'LIST: product stock (20) and variant stock (7) are independent, each unit shows its OWN sku and price');

-- Pagination
select pg_temp.adm_li('b_pg1', $$p_search => 'T6C2', p_limit => 3, p_offset => 0$$);
select pg_temp.adm_li('b_pg2', $$p_search => 'T6C2', p_limit => 3, p_offset => 3$$);
select pg_temp.adm_li('b_pg3', $$p_search => 'T6C2', p_limit => 3, p_offset => 6$$);
select pg_temp.adm_li('b_pg4', $$p_search => 'T6C2', p_limit => 3, p_offset => 9$$);
select pg_temp.ok(
  (pg_temp.j('b_pg1') ->> 'total')::integer = 8 and (pg_temp.j('b_pg2') ->> 'total')::integer = 8
  and (pg_temp.j('b_pg3') ->> 'total')::integer = 8
  and jsonb_array_length(pg_temp.j('b_pg1') -> 'inventory') = 3
  and jsonb_array_length(pg_temp.j('b_pg2') -> 'inventory') = 3
  and jsonb_array_length(pg_temp.j('b_pg3') -> 'inventory') = 2
  and (pg_temp.j('b_pg2') ->> 'offset')::integer = 3 and (pg_temp.j('b_pg1') ->> 'limit')::integer = 3
  and pg_temp.ids(pg_temp.j('b_pg1') -> 'inventory') || pg_temp.ids(pg_temp.j('b_pg2') -> 'inventory')
      || pg_temp.ids(pg_temp.j('b_pg3') -> 'inventory') = (select all_ids from t_exp),
  'PAGINATION: limit 3 pages (3 + 3 + 2) concatenate to the full ordered result; total stays 8 on every page; limit / offset are echoed');
select pg_temp.ok(
  (pg_temp.j('b_pg4') ->> 'total')::integer = 8 and jsonb_array_length(pg_temp.j('b_pg4') -> 'inventory') = 0
  and pg_temp.j('b_pg4') -> 'inventory' = '[]'::jsonb,
  'PAGINATION: an offset past the end returns an empty array (not null) and the real total');
select pg_temp.adm_li('b_big_off', $$p_search => 'T6C2', p_limit => 100, p_offset => 2147483647$$);
select pg_temp.ok((pg_temp.j('b_big_off') ->> 'total')::integer = 8 and jsonb_array_length(pg_temp.j('b_big_off') -> 'inventory') = 0,
  'PAGINATION: the largest integer offset with limit 100 does not overflow');
select pg_temp.adm_li('b_def', '');
select pg_temp.ok(
  (pg_temp.j('b_def') ->> 'limit')::integer = 50 and (pg_temp.j('b_def') ->> 'offset')::integer = 0
  and (pg_temp.j('b_def') ->> 'total')::integer >= 8
  and jsonb_array_length(pg_temp.j('b_def') -> 'inventory') <= 50,
  'DEFAULTS: admin_list_inventory() uses limit 50, offset 0 and returns at most 50 rows');

-- Validation (only after the gate)
select pg_temp.li_bad('b_v1', 'p_limit => 0', 'VALIDATION: limit 0 is rejected (P0001 / invalid_arguments)');
select pg_temp.li_bad('b_v2', 'p_limit => 101', 'VALIDATION: limit 101 is rejected');
select pg_temp.li_bad('b_v3', 'p_limit => null', 'VALIDATION: NULL limit is rejected');
select pg_temp.li_bad('b_v4', 'p_offset => -1', 'VALIDATION: negative offset is rejected');
select pg_temp.li_bad('b_v5', 'p_offset => null', 'VALIDATION: NULL offset is rejected');
select pg_temp.li_bad('b_v6', $$p_search => repeat('x', 101)$$, 'VALIDATION: a 101-character search is rejected');
select pg_temp.adm_li('b_v7', $$p_search => repeat('x', 100)$$);
select pg_temp.ok((pg_temp.j('b_v7') ->> 'total')::integer = 0 and pg_temp.j('b_v7') -> 'inventory' = '[]'::jsonb,
  'VALIDATION: a 100-character search is accepted (and matches nothing)');

-- Search
select pg_temp.adm_li('b_s_name', $$p_search => 't6c2 milk', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_s_name') -> 'inventory') = array[pg_temp.p(1)::text, pg_temp.v(1)::text, pg_temp.v(2)::text]
  and (pg_temp.j('b_s_name') ->> 'total')::integer = 3,
  'SEARCH: case-insensitive product name match returns the product unit AND its variants (parent match)');
select pg_temp.adm_li('b_s_vsku', $$p_search => 'T6C2-MILK-1L', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_s_vsku') -> 'inventory') = array[pg_temp.v(1)::text]
  and (pg_temp.j('b_s_vsku') ->> 'total')::integer = 1,
  'SEARCH: a variant sku matches only that variant unit (not the product unit, not its sibling)');
select pg_temp.adm_li('b_s_psku', $$p_search => 't6c2-rice', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_s_psku') -> 'inventory') = array[pg_temp.p(2)::text],
  'SEARCH: a product sku / slug matches the product unit');
select pg_temp.adm_li('b_s_vname', $$p_search => 'Juice Pack', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_s_vname') -> 'inventory') = array[pg_temp.v(3)::text],
  'SEARCH: a variant name matches only that variant unit');
select pg_temp.adm_li('b_s_brand', $$p_search => 'T6C2Brand', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_s_brand') -> 'inventory') = array[pg_temp.p(1)::text, pg_temp.v(1)::text, pg_temp.v(2)::text],
  'SEARCH: a product brand matches the product unit and its variants');
select pg_temp.adm_li('b_s_trim', $$p_search => '   T6C2 Rice   ', p_limit => 100$$);
select pg_temp.ok(pg_temp.ids(pg_temp.j('b_s_trim') -> 'inventory') = array[pg_temp.p(2)::text],
  'SEARCH: surrounding whitespace is trimmed');
select pg_temp.adm_li('b_s_blank', $$p_search => '   ', p_limit => 100$$);
select pg_temp.adm_li('b_s_null', $$p_search => null, p_limit => 100$$);
select pg_temp.ok(
  (pg_temp.j('b_s_blank') ->> 'total') = (pg_temp.j('b_s_null') ->> 'total')
  and (pg_temp.j('b_s_blank') ->> 'total')::integer >= 8,
  'SEARCH: a blank search behaves exactly like no search');
-- Escaping: % _ and \ are literal. Without escaping, each of these would match fixtures.
select pg_temp.adm_li('b_e_pct', $$p_search => 'T6C2%', p_limit => 100$$);
select pg_temp.adm_li('b_e_us', $$p_search => 'T6C2_Milk', p_limit => 100$$);
select pg_temp.adm_li('b_e_bs', $$p_search => 'T6C2\', p_limit => 100$$);
select pg_temp.adm_li('b_e_all', $$p_search => '%', p_limit => 100$$);
select pg_temp.ok(
  (pg_temp.j('b_e_pct') ->> 'total')::integer = 0
  and (pg_temp.j('b_e_us') ->> 'total')::integer = 0
  and (pg_temp.j('b_e_bs') ->> 'total')::integer = 0
  and not exists (select 1 from jsonb_array_elements(pg_temp.j('b_e_all') -> 'inventory') e
                  where e ->> 'product_id' in (pg_temp.p(1)::text, pg_temp.p(2)::text, pg_temp.p(4)::text)),
  'SEARCH ESCAPING: "%" , "_" and a backslash are matched literally (T6C2% / T6C2_Milk / T6C2\ match nothing; a bare % does not match the fixtures that lack a percent sign)');
select pg_temp.adm_li('b_e_lit', $$p_search => '100%_Pure', p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_e_lit') -> 'inventory') = array[pg_temp.p(3)::text, pg_temp.v(3)::text],
  'SEARCH ESCAPING: the literal text "100%_Pure" finds exactly the juice product unit and its variant');
select pg_temp.adm_li('b_e_inj', $$p_search => $q$x' or 1=1 --$q$, p_limit => 100$$);
select pg_temp.ok((pg_temp.j('b_e_inj') ->> 'total')::integer = 0,
  'SEARCH SAFETY: a SQL-injection-looking search is only ever a bound literal and matches nothing');

-- Filters
select pg_temp.adm_li('b_f_on', $$p_search => 'T6C2', p_is_active => true, p_limit => 100$$);
select pg_temp.adm_li('b_f_off', $$p_search => 'T6C2', p_is_active => false, p_limit => 100$$);
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_f_on') -> 'inventory')
    = array[pg_temp.p(3)::text, pg_temp.v(3)::text, pg_temp.p(1)::text, pg_temp.v(1)::text, pg_temp.v(4)::text]
  and (pg_temp.j('b_f_on') ->> 'total')::integer = 5,
  'FILTER is_active = true: units whose OWN is_active is true (includes the active variant of the inactive tea product)');
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_f_off') -> 'inventory')
    = array[pg_temp.v(2)::text, pg_temp.p(2)::text, pg_temp.p(4)::text]
  and (pg_temp.j('b_f_off') ->> 'total')::integer = 3,
  'FILTER is_active = false: units whose OWN is_active is false (inactive variant, inactive products)');
select pg_temp.ok((pg_temp.j('b_f_on') ->> 'total')::integer + (pg_temp.j('b_f_off') ->> 'total')::integer = (pg_temp.j('b_all') ->> 'total')::integer,
  'FILTER: active + inactive totals add up to the unfiltered total');
select pg_temp.adm_li('b_p1', format($$p_product_id => %L, p_limit => 100$$, pg_temp.p(1)));
select pg_temp.ok(
  pg_temp.ids(pg_temp.j('b_p1') -> 'inventory') = array[pg_temp.p(1)::text, pg_temp.v(1)::text, pg_temp.v(2)::text]
  and (pg_temp.j('b_p1') ->> 'total')::integer = 3,
  'FILTER p_product_id: the product unit and its variants only, in order');
select pg_temp.adm_li('b_p1a', format($$p_product_id => %L, p_is_active => false, p_limit => 100$$, pg_temp.p(1)));
select pg_temp.ok(pg_temp.ids(pg_temp.j('b_p1a') -> 'inventory') = array[pg_temp.v(2)::text],
  'FILTER: p_product_id and p_is_active combine with AND');
select pg_temp.adm_li('b_p1s', format($$p_product_id => %L, p_search => 'rice', p_limit => 100$$, pg_temp.p(1)));
select pg_temp.ok((pg_temp.j('b_p1s') ->> 'total')::integer = 0,
  'FILTER: p_product_id and p_search combine with AND (rice is not in the milk product)');
select pg_temp.adm_li('b_pu', $$p_product_id => '00000000-0000-4000-8000-6d9fffffffff'$$);
select pg_temp.ok((pg_temp.j('b_pu') ->> 'total')::integer = 0 and pg_temp.j('b_pu') -> 'inventory' = '[]'::jsonb,
  'FILTER: an unknown product id matches nothing');
select pg_temp.adm_li('b_p2', format($$p_product_id => %L$$, pg_temp.p(2)));
select pg_temp.ok(pg_temp.ids(pg_temp.j('b_p2') -> 'inventory') = array[pg_temp.p(2)::text],
  'FILTER: a product without variants has exactly its own product unit');

-- ===========================================================================
-- C. admin_get_inventory
-- ===========================================================================
select pg_temp.gi('c_p1', 'authenticated', pg_temp.u(3), pg_temp.p(1), null);
select pg_temp.ok(
  pg_temp.haskeys(pg_temp.j('c_p1'), array['inventory', 'product'])
  and pg_temp.inv('c_p1') = pg_temp.inv_p(pg_temp.p(1))
  and pg_temp.inv('c_p1') ->> 'kind' = 'product'
  and (pg_temp.inv('c_p1') ->> 'stock_quantity')::integer = 20
  and (pg_temp.inv('c_p1') ->> 'in_stock')::boolean
  and (pg_temp.inv('c_p1') ->> 'variant_count')::integer = 2,
  'DETAIL product unit: { inventory, product }; the inventory equals the stored product row (stock 20, in_stock, 2 variants)');
select pg_temp.ok(
  pg_temp.haskeys(pg_temp.j('c_p1') -> 'product', array['id', 'slug', 'name', 'brand', 'unit_label', 'category_id', 'is_active'])
  and pg_temp.j('c_p1') -> 'product' ->> 'id' = pg_temp.p(1)::text
  and pg_temp.j('c_p1') -> 'product' ->> 'brand' = 'T6C2Brand'
  and pg_temp.j('c_p1') -> 'product' ->> 'unit_label' = '1 L'
  and pg_temp.j('c_p1') -> 'product' -> 'category_id' = 'null'::jsonb
  and (pg_temp.j('c_p1') -> 'product' ->> 'is_active')::boolean,
  'DETAIL: the product block has exactly id, slug, name, brand, unit_label, category_id, is_active');
select pg_temp.gi('c_v1', 'authenticated', pg_temp.u(3), pg_temp.p(1), pg_temp.v(1));
select pg_temp.ok(
  pg_temp.inv('c_v1') = pg_temp.inv_v(pg_temp.v(1))
  and pg_temp.inv('c_v1') ->> 'kind' = 'variant'
  and (pg_temp.inv('c_v1') ->> 'stock_quantity')::integer = 7
  and pg_temp.inv('c_v1') -> 'in_stock' = 'null'::jsonb
  and pg_temp.inv('c_v1') -> 'variant_count' = 'null'::jsonb
  and pg_temp.j('c_v1') -> 'product' ->> 'id' = pg_temp.p(1)::text,
  'DETAIL variant unit: the inventory equals the stored variant (stock 7, in_stock null) and the product block is the parent');
select pg_temp.gi('c_v2', 'authenticated', pg_temp.u(3), pg_temp.p(1), pg_temp.v(2));
select pg_temp.ok(
  pg_temp.inv('c_v2') = pg_temp.inv_v(pg_temp.v(2))
  and (pg_temp.inv('c_v2') ->> 'stock_quantity')::integer = 0
  and not (pg_temp.inv('c_v2') ->> 'is_active')::boolean,
  'DETAIL: an inactive zero-stock variant is visible');
select pg_temp.gi('c_p2', 'authenticated', pg_temp.u(3), pg_temp.p(2), null);
select pg_temp.ok(
  pg_temp.inv('c_p2') = pg_temp.inv_p(pg_temp.p(2))
  and not (pg_temp.inv('c_p2') ->> 'is_active')::boolean and not (pg_temp.inv('c_p2') ->> 'in_stock')::boolean
  and (pg_temp.inv('c_p2') ->> 'variant_count')::integer = 0,
  'DETAIL: an inactive, out-of-stock product with no variants is visible');
select pg_temp.gi('c_v4', 'authenticated', pg_temp.u(3), pg_temp.p(4), pg_temp.v(4));
select pg_temp.ok(
  pg_temp.inv('c_v4') = pg_temp.inv_v(pg_temp.v(4))
  and (pg_temp.inv('c_v4') ->> 'is_active')::boolean and not (pg_temp.inv('c_v4') ->> 'product_is_active')::boolean,
  'DETAIL: an active variant of an inactive product reports is_active true and product_is_active false');
select pg_temp.run('c_dflt', 'authenticated', pg_temp.u(3), format($$select public.admin_get_inventory(p_product_id => %L)::text$$, pg_temp.p(1)));
select pg_temp.ok(pg_temp.inv('c_dflt') = pg_temp.inv_p(pg_temp.p(1)),
  'DETAIL: p_variant_id defaults to null (the product unit)');
-- The detail row is identical to the list row, for every fixture unit (each detail call is made
-- as the admin through the real role switch; the list rows are those of b_all).
create or replace function pg_temp.detail_equals_list() returns boolean language plpgsql as $$
declare
  e jsonb;
  n integer := 0;
  v_k text;
begin
  for e in select x from jsonb_array_elements(pg_temp.j('b_all') -> 'inventory') x loop
    n := n + 1;
    v_k := 'dl_' || n;
    perform pg_temp.gi(v_k, 'authenticated', pg_temp.u(3), (e ->> 'product_id')::uuid, (e ->> 'variant_id')::uuid);
    if (select err from t_res where k = v_k) is not null
       or pg_temp.inv(v_k) is distinct from e then
      return false;
    end if;
  end loop;
  return n = 8;
end;
$$;
select pg_temp.ok(pg_temp.detail_equals_list(),
  'DETAIL = LIST: for each of the 8 fixture units the detail inventory is identical to the list row (same shape, same values)');
-- Errors (only after the gate)
select pg_temp.gi('c_e1', 'authenticated', pg_temp.u(3), null, null);
select pg_temp.expect_err('c_e1', 'P0001', 'invalid_arguments', 'DETAIL: a NULL product id is rejected (P0001 / invalid_arguments)');
select pg_temp.gi('c_e2', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6d9fffffffff', null);
select pg_temp.expect_err('c_e2', 'P0001', 'product_not_found', 'DETAIL: an unknown product id is rejected (P0001 / product_not_found)');
select pg_temp.gi('c_e3', 'authenticated', pg_temp.u(3), pg_temp.p(1), '00000000-0000-4000-8000-6dafffffffff');
select pg_temp.expect_err('c_e3', 'P0001', 'variant_not_found', 'DETAIL: an unknown variant id is rejected (P0001 / variant_not_found)');
select pg_temp.gi('c_e4', 'authenticated', pg_temp.u(3), pg_temp.p(2), pg_temp.v(1));
select pg_temp.expect_err('c_e4', 'P0001', 'variant_not_found', 'DETAIL: a variant that belongs to a DIFFERENT product is rejected (variant_not_found)');
select pg_temp.gi('c_e5', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6d9fffffffff', pg_temp.v(1));
select pg_temp.expect_err('c_e5', 'P0001', 'product_not_found', 'DETAIL: an unknown product with a real variant id reports product_not_found');

-- ===========================================================================
-- D. FUNCTION SECURITY
-- ===========================================================================
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_list_inventory') = 1
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_get_inventory') = 1,
  'FUNCS: each inventory function exists exactly once (no overloads)');
select pg_temp.ok(
  (select bool_and(prosecdef) from pg_proc
   where oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                 'public.admin_get_inventory(uuid,uuid)'::regprocedure)),
  'SECURITY: both inventory functions are SECURITY DEFINER');
select pg_temp.ok(
  (select bool_and(coalesce(proconfig::text, '') like '%search_path=public, pg_temp%') from pg_proc
   where oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                 'public.admin_get_inventory(uuid,uuid)'::regprocedure)),
  'SECURITY: both inventory functions pin search_path = public, pg_temp');
select pg_temp.ok(
  (select bool_and(provolatile = 's') from pg_proc
   where oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                 'public.admin_get_inventory(uuid,uuid)'::regprocedure)),
  'READ ONLY: both inventory functions are STABLE (PostgreSQL itself refuses a write inside a STABLE function)');
select pg_temp.ok(
  (select bool_and(position('public.require_admin()' in prosrc) > 0
                   and position('from public.' in prosrc) > 0
                   and position('public.require_admin()' in prosrc) < position('from public.' in prosrc))
   from pg_proc
   where oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                 'public.admin_get_inventory(uuid,uuid)'::regprocedure)),
  'SECURITY: both inventory functions call public.require_admin() BEFORE the first table read');
select pg_temp.ok(
  (select bool_and(prosrc !~* '(insert\s+into|update\s+\S+\s+set|delete\s+from|truncate)') from pg_proc
   where oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                 'public.admin_get_inventory(uuid,uuid)'::regprocedure)),
  'READ ONLY: neither function body contains an INSERT / UPDATE / DELETE / TRUNCATE statement');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_list_inventory(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_inventory(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_inventory(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_get_inventory(uuid,uuid)', 'EXECUTE'),
  'ACL: anon cannot execute either function; authenticated can (the require_admin() gate does the rest)');
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid in ('public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure,
                    'public.admin_get_inventory(uuid,uuid)'::regprocedure)
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'ACL: the PUBLIC pseudo-role holds no EXECUTE on either function');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'ACL: browser roles still cannot execute require_admin() directly');

-- No table privileges were introduced or broadened.
select pg_temp.ok(
  not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'NO TABLE GRANTS: anon / authenticated hold no write privilege on products or product_variants (admin reads happen inside the functions)');
select pg_temp.ok(
  (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, ''), '|' order by c.relname), ''))
       from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
         and c.relname in ('products', 'product_variants', 'orders', 'order_items', 'user_roles'))
      = (select h from t_h where k = 'acl0'),
  'NO TABLE GRANTS: the ACLs of products, product_variants, orders, order_items and user_roles are exactly as before the inventory calls');
select pg_temp.ok(
  (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''), '|'
                                  order by tablename, policyname), ''))
   from pg_policies where schemaname = 'public' and tablename in ('products', 'product_variants'))
    = (select h from t_h where k = 'pol0')
  and not exists (select 1 from pg_policies where schemaname = 'public'
                  and tablename in ('products', 'product_variants') and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL'))
  and (select count(*) from pg_class where oid in ('public.products'::regclass, 'public.product_variants'::regclass) and relrowsecurity) = 2,
  'RLS: the policies on products / product_variants are unchanged, there is no write policy, and row level security is still on');
select pg_temp.ok(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT'
     and policyname in ('Products: public read active', 'Variants: public read active',
                        'Products: admin read all', 'Variants: admin read all')) = 4,
  'RLS: the public read-active and admin read-all policies on products / variants all still exist');
select pg_temp.ok(
  (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))
    = (select h from t_h where k = 'rel0')
  and not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
                  and c.relname ~* '(inventor|stock)' and c.relname <> 'inventory_adjustments'),
  'NO NEW TABLE: no table was created, and no inventory / stock table exists other than the 6C.2.2A.1 audit table inventory_adjustments (the existing product / variant stock columns are still the only stock source)');
select pg_temp.ok(
  (select array_agg(proname::text order by proname::text) from pg_proc
   where pronamespace = 'public'::regnamespace and proname ilike '%inventor%')
  = array['admin_adjust_inventory', 'admin_get_inventory', 'admin_list_inventory', 'admin_list_inventory_adjustments',
          'inventory_adjustments_guard', 'inventory_log_stock_change', 'inventory_order_ctx_clear', 'inventory_order_ctx_set'],
  'FUNCS: the only inventory-named functions in public are the two readers, (6C.2.2A.2) admin_adjust_inventory, (6C.2.2B.1) the read-only admin_list_inventory_adjustments and (9B) the four inventory_* trigger functions (no set-stock / reserve function exists)');
select pg_temp.ok(
  not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
              and proname ~* '^admin.*(adjust|stock|reserve|receive|movement)'
              and proname not in ('admin_adjust_inventory', 'admin_list_inventory_adjustments')),
  'FUNCS: no admin stock function exists other than the 6C.2.2A.2 admin_adjust_inventory and the read-only 6C.2.2B.1 admin_list_inventory_adjustments');
select pg_temp.ok(
  (select array_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable order by table_name)
   from information_schema.columns
   where table_schema = 'public' and table_name in ('products', 'product_variants')
     and column_name ~* '(threshold|reorder|low_stock|min_stock|safety)')
  = array['product_variants.low_stock_threshold:integer:YES', 'products.low_stock_threshold:integer:YES'],
  'NO THRESHOLD: the only low-stock / reorder columns are the nullable integer low_stock_threshold added by Phase 9B (none other was invented)');
select pg_temp.ok(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'product_variants' and column_name = 'in_stock') = 0,
  'SCHEMA: product_variants still has no in_stock column (which is why variant rows report in_stock null)');

-- Browser table access is exactly what it was: RLS still hides inactive rows from customers and anon.
select pg_temp.run('d_cust_var', 'authenticated', pg_temp.u(1),
  $$select string_agg(sku, ',' order by sku) from public.product_variants where sku like 'T6C2-%'$$);
select pg_temp.ok(pg_temp.res('d_cust_var') = 'T6C2-JUICE-P,T6C2-MILK-1L',
  'EXISTING SECURITY: a customer still sees only active variants of active products through the table (RLS unchanged)');
select pg_temp.run('d_anon_prod', 'anon', null,
  $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c2-%'$$);
select pg_temp.ok(pg_temp.res('d_anon_prod') = 't6c2-juice,t6c2-milk',
  'EXISTING SECURITY: anon still sees only active products through the table (RLS unchanged)');
select pg_temp.run('d_cust_upd', 'authenticated', pg_temp.u(1),
  format($$update public.product_variants set stock_quantity = 999 where id = %L$$, pg_temp.v(1)));
select pg_temp.write_denied('d_cust_upd', 'EXISTING SECURITY: a customer still cannot UPDATE variant stock directly');
select pg_temp.run('d_adm_upd', 'authenticated', pg_temp.u(3),
  format($$update public.products set stock_quantity = 999 where id = %L$$, pg_temp.p(1)));
select pg_temp.write_denied('d_adm_upd', 'EXISTING SECURITY: even an admin cannot UPDATE product stock directly (no inventory write path)');

-- ===========================================================================
-- E. READS MODIFY NOTHING
--    Every list / detail call above (admin, refused, invalid) ran against the fixtures. Compare.
-- ===========================================================================
select pg_temp.ok(
  pg_temp.stock_hash() = (select h from t_h where k = 'stock0'),
  'READS: stock_quantity, in_stock and is_active of every fixture product and variant are unchanged after all inventory reads');
select pg_temp.ok(
  pg_temp.prod_hash() = (select h from t_h where k = 'prod0')
  and pg_temp.var_hash() = (select h from t_h where k = 'var0'),
  'READS: a hash of every product row and every variant row (all columns, including updated_at) is unchanged');
select pg_temp.ok(
  pg_temp.ord_hash() = (select h from t_h where k = 'ord0'),
  'READS: a hash of every order and order item (status, payment, delivery and totals live on these rows) is unchanged');

-- ===========================================================================
-- F. THE READS SEE WHAT THE EARLIER ADMIN WRITE RPCs CHANGE (integration)
-- ===========================================================================
select pg_temp.run('f_deact', 'authenticated', pg_temp.u(3), format($$select public.admin_set_product_active(%L::uuid, false)::text$$, pg_temp.p(3)));
select pg_temp.succeeded('f_deact', 'INTEGRATION: admin deactivates the juice product through admin_set_product_active');
select pg_temp.gi('f_g1', 'authenticated', pg_temp.u(3), pg_temp.p(3), pg_temp.v(3));
select pg_temp.gi('f_g2', 'authenticated', pg_temp.u(3), pg_temp.p(3), null);
select pg_temp.ok(
  not (pg_temp.inv('f_g1') ->> 'product_is_active')::boolean and (pg_temp.inv('f_g1') ->> 'is_active')::boolean
  and not (pg_temp.inv('f_g2') ->> 'is_active')::boolean
  and (pg_temp.inv('f_g1') ->> 'stock_quantity')::integer = 4 and (pg_temp.inv('f_g2') ->> 'stock_quantity')::integer = 5
  and (pg_temp.inv('f_g2') ->> 'in_stock')::boolean,
  'INTEGRATION: the inventory reads show the deactivation (product inactive, its variant still active) and the stock is untouched (4 / 5)');
select pg_temp.run('f_react', 'authenticated', pg_temp.u(3), format($$select public.admin_set_product_active(%L::uuid, true)::text$$, pg_temp.p(3)));
select pg_temp.succeeded('f_react', 'INTEGRATION: admin reactivates the juice product');
select pg_temp.run('f_vupd', 'authenticated', pg_temp.u(3),
  format($$select public.admin_update_product_variant(%L::uuid, '{"name":"T6C2 Milk 1 Litre","price_cents":550}'::jsonb)::text$$, pg_temp.v(1)));
select pg_temp.succeeded('f_vupd', 'INTEGRATION: admin renames / reprices a variant through admin_update_product_variant');
select pg_temp.gi('f_g3', 'authenticated', pg_temp.u(3), pg_temp.p(1), pg_temp.v(1));
select pg_temp.ok(
  pg_temp.inv('f_g3') = pg_temp.inv_v(pg_temp.v(1))
  and pg_temp.inv('f_g3') ->> 'variant_name' = 'T6C2 Milk 1 Litre'
  and (pg_temp.inv('f_g3') ->> 'price_cents')::integer = 550
  and (pg_temp.inv('f_g3') ->> 'stock_quantity')::integer = 7,
  'INTEGRATION: the detail shows the new variant name and price, and the stock (7) did not change');
select pg_temp.run('f_vnew', 'authenticated', pg_temp.u(3),
  format($$select public.admin_create_product_variant(p_product_id => %L, p_name => 'T6C2 Milk Half', p_price_cents => 300, p_sku => 'T6C2-MILK-H')::text$$, pg_temp.p(1)));
select pg_temp.succeeded('f_vnew', 'INTEGRATION: admin creates a variant through admin_create_product_variant');
select pg_temp.adm_li('f_l1', format($$p_product_id => %L, p_limit => 100$$, pg_temp.p(1)));
select pg_temp.ok(
  (pg_temp.j('f_l1') ->> 'total')::integer = 4
  and exists (select 1 from jsonb_array_elements(pg_temp.j('f_l1') -> 'inventory') e
              where e ->> 'sku' = 'T6C2-MILK-H' and (e ->> 'stock_quantity')::integer = 0 and (e ->> 'is_active')::boolean)
  and (select (e ->> 'variant_count')::integer from jsonb_array_elements(pg_temp.j('f_l1') -> 'inventory') e where e ->> 'kind' = 'product') = 3,
  'INTEGRATION: the list shows the new variant with the table-default stock 0 and the product unit now reports 3 variants');

-- ===========================================================================
-- G. REGRESSION - earlier phases still behave
-- ===========================================================================
-- 6C.1B.2 / 6C.1B.1: writers still refuse non-admins and still cannot touch stock
select pg_temp.run('g_set_c', 'authenticated', pg_temp.u(1), format($$select public.admin_set_product_active(%L::uuid, false)::text$$, pg_temp.p(1)));
select pg_temp.gated('g_set_c', 'REGRESSION 6C.1B.2: admin_set_product_active still refuses a customer');
select pg_temp.run('g_set_a', 'anon', null, format($$select public.admin_set_product_active(%L::uuid, false)::text$$, pg_temp.p(1)));
select pg_temp.no_execute('g_set_a', 'REGRESSION 6C.1B.2: admin_set_product_active still refuses anon');
select pg_temp.run('g_vu_s', 'authenticated', pg_temp.u(2), format($$select public.admin_update_product_variant(%L::uuid, '{"name":"x"}'::jsonb)::text$$, pg_temp.v(1)));
select pg_temp.gated('g_vu_s', 'REGRESSION 6C.1B.2: admin_update_product_variant still refuses staff');
select pg_temp.run('g_vu_st', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product_variant(%L::uuid, '{"stock_quantity":99}'::jsonb)::text$$, pg_temp.v(1)));
select pg_temp.expect_err('g_vu_st', 'P0001', 'unsupported_field', 'REGRESSION 6C.1B.2: admin_update_product_variant still rejects stock_quantity (stock stays read only)');
select pg_temp.run('g_pu_st', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product(%L::uuid, '{"stock_quantity":99}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('g_pu_st', 'P0001', 'unsupported_field', 'REGRESSION 6C.1B.1: admin_update_product still rejects stock_quantity');
select pg_temp.run('g_pc_g', 'authenticated', pg_temp.u(2), $$select public.admin_create_product(p_name => 'T6C2 Staff', p_slug => 't6c2-staff', p_price_cents => 1)::text$$);
select pg_temp.gated('g_pc_g', 'REGRESSION 6C.1B.1: admin_create_product still refuses staff');
select pg_temp.ok((select stock_quantity from public.product_variants where id = pg_temp.v(1)) = 7
  and (select stock_quantity from public.products where id = pg_temp.p(1)) = 20,
  'REGRESSION 6C.1B: no writer changed any fixture stock (variant 7, product 20)');

-- 6C.1A.1 / 6C.1A.2: product reads
select pg_temp.run('g_lp', 'authenticated', pg_temp.u(3), $$select public.admin_list_products(p_search => 't6c2-rice', p_limit => 10)::text$$);
select pg_temp.ok((pg_temp.j('g_lp') ->> 'total')::integer = 1 and pg_temp.keys(pg_temp.j('g_lp')) = 'limit,offset,products,total',
  'REGRESSION 6C.1A: admin_list_products still works and keeps its result shape');
select pg_temp.run('g_gp', 'authenticated', pg_temp.u(3), format($$select public.admin_get_product(%L)::text$$, pg_temp.p(1)));
select pg_temp.ok(pg_temp.keys(pg_temp.j('g_gp')) = 'category,product,variants',
  'REGRESSION 6C.1A.2: admin_get_product still returns { product, category, variants }');
select pg_temp.run('g_lp_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_products()::text');
select pg_temp.gated('g_lp_s', 'REGRESSION 6C.1A.1: admin_list_products still refuses staff');
select pg_temp.run('g_gp_c', 'authenticated', pg_temp.u(1), format($$select public.admin_get_product(%L)::text$$, pg_temp.p(1)));
select pg_temp.gated('g_gp_c', 'REGRESSION 6C.1A.2: admin_get_product still refuses a customer');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_product(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_get_product(uuid)', 'EXECUTE'),
  'REGRESSION 6C.1A: the product read functions keep their ACL');
select pg_temp.run('s_anon', 'anon', null, $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c2-%'$$);
select pg_temp.ok(pg_temp.res('s_anon') not like '%t6c2-rice%' and pg_temp.res('s_anon') not like '%t6c2-tea%'
  and pg_temp.res('s_anon') like '%t6c2-milk%',
  'REGRESSION: anon still sees exactly the ACTIVE fixture products (existing public RLS unchanged)');
select pg_temp.run('s_admin', 'authenticated', pg_temp.u(3), $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c2-%'$$);
select pg_temp.ok(pg_temp.res('s_admin') like '%t6c2-rice%' and pg_temp.res('s_admin') like '%t6c2-tea%',
  'REGRESSION 6A: the admin read-all policy still shows inactive products directly');

-- 6B.2: the admin API is exactly the fourteen known functions; one status writer
select pg_temp.ok(
  -- Later phases added admin functions (6G.4A payment readers; 6I.1 audit-log reader + 2 trigger functions);
  -- 6G.3 payment writers update only orders.payment_status. Compared bytewise (collate "C").
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
    = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[]
  and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                  and (proname ~* '(mark|set).*(paid|refund)' or proname ~* 'admin.*(payment|refund)')
                  and proname !~ '^admin_(get|list)_(payment|refund)'),  -- read-only 6G.4A readers are allowed; any writer is not
  'REGRESSION 6B.2: the admin API is exactly the fifteen known functions (admin_list_inventory_adjustments from 6C.2.2B.1 + admin_adjust_inventory from 6C.2.2A.2 + the eleven of 6A-6C.1B.2 + the two inventory readers of this phase); no payment or refund writer exists');
select pg_temp.ok(
  (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'update\s+(public\.)?orders(\s+[a-z_]+)?\s+set\s+status\M') = array['set_order_status']
  and (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'set_order_status\s*\(') = array['admin_set_order_status'],
  'REGRESSION 6B.2: structurally ONE status writer - only set_order_status() updates orders, and only admin_set_order_status() calls it');
select pg_temp.run('r_sos_c', 'authenticated', pg_temp.u(1), $$select public.admin_set_order_status('00000000-0000-4000-8000-6d4fffffffff', 'pending', null, false)::text$$);
select pg_temp.gated('r_sos_c', 'REGRESSION 6B.2: admin_set_order_status still refuses a customer');
select pg_temp.run('r_sos_s', 'authenticated', pg_temp.u(2), $$select public.admin_set_order_status('00000000-0000-4000-8000-6d4fffffffff', 'pending', null, false)::text$$);
select pg_temp.gated('r_sos_s', 'REGRESSION 6B.2: admin_set_order_status still refuses staff (staff is not admin)');
select pg_temp.run('r_sos_a', 'authenticated', pg_temp.u(3), $$select public.admin_set_order_status('00000000-0000-4000-8000-6d4fffffffff', 'pending', null, false)::text$$);
select pg_temp.ok((select state from t_res where k = 'r_sos_a') is distinct from '42501',
  'REGRESSION 6B.2: an admin passes the gate of admin_set_order_status (any error is about the unknown order, not authorization)');

-- 6B.1: admin orders read
select pg_temp.run('r_ord', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('r_ord', 'REGRESSION 6B.1: admin_list_orders still works for an admin');
select pg_temp.run('r_ord_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_orders()::text');
select pg_temp.gated('r_ord_s', 'REGRESSION 6B.1: admin_list_orders still refuses staff');
select pg_temp.run('r_ord_a', 'anon', null, 'select public.admin_list_orders()::text');
select pg_temp.no_execute('r_ord_a', 'REGRESSION 6B.1: admin_list_orders still refuses anon');
select pg_temp.run('r_go', 'authenticated', pg_temp.u(3), $$select public.admin_get_order('00000000-0000-4000-8000-6d4fffffffff')::text$$);
select pg_temp.expect_err('r_go', 'P0001', 'order_not_found', 'REGRESSION 6B.1: admin_get_order still reports order_not_found for an admin');
select pg_temp.run('r_go_c', 'authenticated', pg_temp.u(1), $$select public.admin_get_order('00000000-0000-4000-8000-6d4fffffffff')::text$$);
select pg_temp.gated('r_go_c', 'REGRESSION 6B.1: admin_get_order still refuses a customer');

-- 6A: dashboard + gate (the dashboard's own low-stock figures still work; its threshold is an argument, not a column)
select pg_temp.run('r_dash', 'authenticated', pg_temp.u(3), 'select public.admin_dashboard_summary()::text');
select pg_temp.succeeded('r_dash', 'REGRESSION 6A: admin_dashboard_summary still works for an admin');
select pg_temp.run('r_dash_c', 'authenticated', pg_temp.u(1), 'select public.admin_dashboard_summary()::text');
select pg_temp.gated('r_dash_c', 'REGRESSION 6A: admin_dashboard_summary still refuses a customer');
select pg_temp.run('r_dash_n', 'anon', null, 'select public.admin_dashboard_summary()::text');
select pg_temp.no_execute('r_dash_n', 'REGRESSION 6A: admin_dashboard_summary still refuses anon');
select pg_temp.ok(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT'
     and policyname in ('Products: admin read all','Variants: admin read all','Categories: admin read all','Profiles: admin read all')) = 4,
  'REGRESSION 6A: the four admin read-all policies still exist');

-- 5B.2: role helpers and SECURITY DEFINER hygiene
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'REGRESSION 5B.2: every SECURITY DEFINER function in public (including the two new ones) pins search_path = public, pg_temp');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_order') = 1
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('is_admin', 'is_staff', 'has_role')) = 3,
  'REGRESSION 5B.2: create_order() and the role helpers are unchanged in number (no overloads added)');
select pg_temp.run('r_anon_staff', 'anon', null, $q$select public.is_staff('00000000-0000-4000-8000-6d5000000003')::text$q$);
select pg_temp.expect_err('r_anon_staff', '42501', null, 'REGRESSION 5B.2: anon still cannot call is_staff()');
select pg_temp.run('r_anon_role', 'anon', null, $q$select public.has_role('00000000-0000-4000-8000-6d5000000003','admin')::text$q$);
select pg_temp.expect_err('r_anon_role', '42501', null, 'REGRESSION 5B.2: anon still cannot call has_role()');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.orders', 'SELECT')
  and not has_table_privilege('anon', 'public.order_items', 'SELECT')
  and not has_table_privilege('anon', 'public.user_roles', 'SELECT')
  and not has_table_privilege('anon', 'public.addresses', 'SELECT')
  and not has_table_privilege('anon', 'public.profiles', 'SELECT')
  and not has_table_privilege('authenticated', 'public.orders', 'INSERT')
  and not has_table_privilege('authenticated', 'public.orders', 'DELETE')
  and not has_table_privilege('authenticated', 'public.order_items', 'INSERT')
  and not has_table_privilege('authenticated', 'public.user_roles', 'INSERT')
  and not has_any_column_privilege('authenticated', 'public.user_roles', 'UPDATE')
  and not has_any_column_privilege('authenticated', 'public.orders', 'UPDATE'),
  'REGRESSION 5B.2: anon has no access to orders, items, roles, addresses or profiles; authenticated cannot write orders, items or roles');

-- 5A.2: no broad table privileges for browser roles anywhere in public
select pg_temp.ok(not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated')) r(role)
    cross join (values ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege(r.role, c.oid, pv.priv)),
  'REGRESSION 5A.2: anon / authenticated hold no TRUNCATE / REFERENCES / TRIGGER on any public table');
do $$ begin raise notice 'ALL PHASE 6C.2.1 TESTS PASSED'; end $$;

rollback;
