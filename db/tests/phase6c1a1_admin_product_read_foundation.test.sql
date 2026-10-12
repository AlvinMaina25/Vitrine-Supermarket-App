-- =============================================================================
-- PHASE 6C.1A.1 database test: admin product read foundation.
--
-- 6C.1A.2 COMPATIBILITY NOTE: migration 20261004050000_phase6c1a2_admin_product_search_details.sql
-- replaces admin_list_products(integer) with the 5-argument version and adds admin_get_product(uuid).
-- The signature, the result key set (now incl. `offset`), the function-name check and the
-- regprocedure references in this file were updated for that; every other assertion (data, order,
-- limit bounds, authorization, privileges) is unchanged and still applies. Run it AFTER 6C.1A.2.
-- STATUS: written for migration 20261004040000_phase6c1a1_admin_product_read_foundation.sql.
-- Run only against a throwaway local PostgreSQL 16 with a Supabase-style shim (see the report).
-- NOT run against the dedicated Phase-5 development Supabase database.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004040000_phase6c1a1_admin_product_read_foundation.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c1a1_admin_product_read_foundation.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.1A.1 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST.
--
-- NOT-EMPTY PROOF: every "denied" check has a positive control in which the admin gets the
-- SAME fixture rows back. Denial is asserted as an ERROR (42501), never as "0 rows".
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them. Order checks compare the function with the table itself, so they do
-- not depend on collation. Fixture rows are named 'AAA T6C ...' so they sort first; if the
-- database holds enough real products that a fixture falls outside the first 100 rows, the
-- fixture-presence checks fail with a message saying so (it is a test limitation, not a bug).
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
  insert into t_res values (p_k, v_res, v_err, v_state, v_detail)
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
create or replace function pg_temp.list(p_k text, p_role text, p_uid uuid, p_args text default '')
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_list_products(' || p_args || ')::text');
end;
$$;

create or replace function pg_temp.list_claims(p_k text, p_role text, p_claims jsonb, p_args text default '')
returns void language plpgsql as $$
begin
  perform pg_temp.run_claims(p_k, p_role, p_claims, 'select public.admin_list_products(' || p_args || ')::text');
end;
$$;

-- Refused by the admin gate specifically (42501 + DETAIL not_authorised, no result).
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

-- The one product element of a recorded list with this id (null if absent).
create or replace function pg_temp.prod(p_k text, p_id uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.j(p_k) -> 'products') e where e ->> 'id' = p_id::text $$;

-- Ids of the recorded list, in returned order, comma-joined.
create or replace function pg_temp.returned_ids(p_k text) returns text language sql as $$
  select coalesce(string_agg(e ->> 'id', ',' order by n), '')
  from jsonb_array_elements(pg_temp.j(p_k) -> 'products') with ordinality as t(e, n) $$;

-- The first p_n products of the table itself in the documented order (name, slug, id).
create or replace function pg_temp.expected_ids(p_n integer) returns text language sql as $$
  select coalesce(string_agg(id::text, ',' order by name, slug, id), '')
  from (select id, name, slug from public.products order by name, slug, id limit p_n) s $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c100000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c2000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.c(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c3000000' || lpad(n::text, 3, '0'))::uuid $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C Customer"}'),
  (pg_temp.u(2), 't6c-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C Staff"}'),
  (pg_temp.u(3), 't6c-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

insert into public.categories (id, slug, name) values (pg_temp.c(1), 't6c-cat', 'T6C Category');

insert into public.products
  (id, slug, name, category_id, description, brand, sku, image_url, price_cents,
   compare_at_price_cents, unit_label, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1), 't6c-full',     'AAA T6C C-Full',     pg_temp.c(1), 'T6C full description', 'T6C Brand', 'T6C-FULL',
   'https://example.test/t6c.png', 1500, 1800, '1 kg', 12, true, true),
  (pg_temp.p(2), 't6c-inactive', 'AAA T6C A-Inactive', null, null, null, 'T6C-INACT',
   null, 700, null, null, 0, false, false),
  (pg_temp.p(3), 't6c-sparse',   'AAA T6C B-Sparse',   null, null, null, null,
   null, 0, null, null, 3, true, true),
  -- identical names: the slug breaks the tie, and slug order (tie-a, tie-b) is the REVERSE of id order
  (pg_temp.p(4), 't6c-tie-b',    'AAA T6C Tie',      null, null, null, null,
   null, 10, null, null, 1, true, true),
  (pg_temp.p(5), 't6c-tie-a',    'AAA T6C Tie',      null, null, null, null,
   null, 20, null, null, 1, true, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c-%') = 5,
  'FIXTURE: five test products (active full, inactive, active sparse, two same-name ties) exist');

-- Snapshot of the catalogue, to prove the function writes nothing.
create temp table t_snap as
select (select count(*) from public.products) as n,
       (select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p) as h;

-- ===========================================================================
-- A. ADMIN CAN READ PRODUCTS
-- ===========================================================================
select pg_temp.list('a1', 'authenticated', pg_temp.u(3), 'p_limit => 100');
select pg_temp.succeeded('a1', 'ADMIN: calls admin_list_products successfully');
select pg_temp.ok(pg_temp.keys(pg_temp.j('a1')) = 'limit,offset,products,total',
  'ADMIN: result has exactly total / limit / offset / products (offset added by 6C.1A.2)');
select pg_temp.ok((pg_temp.j('a1') ->> 'limit')::integer = 100
  and (pg_temp.j('a1') ->> 'total')::bigint = (select count(*) from public.products),
  'ADMIN: total equals the number of products in the table; limit is echoed');
select pg_temp.ok(jsonb_typeof(pg_temp.j('a1') -> 'products') = 'array'
  and jsonb_array_length(pg_temp.j('a1') -> 'products') = least(100, (select count(*) from public.products)),
  'ADMIN: products is an array of min(limit, total) rows');

-- Fixture presence (positive control for every denial below: the SAME rows exist and are readable)
select pg_temp.ok(
  pg_temp.prod('a1', pg_temp.p(1)) is not null
  and pg_temp.prod('a1', pg_temp.p(2)) is not null
  and pg_temp.prod('a1', pg_temp.p(3)) is not null
  and pg_temp.prod('a1', pg_temp.p(4)) is not null
  and pg_temp.prod('a1', pg_temp.p(5)) is not null,
  'ADMIN: all five fixture products are returned (if this fails on a big database, the fixtures fell outside the first 100 rows)');

select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.prod('a1', pg_temp.p(1)))) = 16
  and pg_temp.keys(pg_temp.prod('a1', pg_temp.p(1))) =
      'brand,category_id,compare_at_price_cents,created_at,description,id,image_url,in_stock,is_active,name,price_cents,sku,slug,stock_quantity,unit_label,updated_at',
  'ADMIN: each product carries exactly the 16 public.products columns (no extras, none missing)');

select pg_temp.ok(
  pg_temp.prod('a1', pg_temp.p(1)) ->> 'slug' = 't6c-full'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'name' = 'AAA T6C C-Full'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'category_id' = pg_temp.c(1)::text
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'description' = 'T6C full description'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'brand' = 'T6C Brand'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'sku' = 'T6C-FULL'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'image_url' = 'https://example.test/t6c.png'
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'price_cents')::integer = 1500
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'compare_at_price_cents')::integer = 1800
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'unit_label' = '1 kg'
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'stock_quantity')::integer = 12
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'in_stock')::boolean is true
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'is_active')::boolean is true,
  'ADMIN: the full fixture product comes back with every stored value (money stays integer cents)');

select pg_temp.ok(
  (pg_temp.prod('a1', pg_temp.p(2)) ->> 'is_active')::boolean is false
  and (pg_temp.prod('a1', pg_temp.p(2)) ->> 'in_stock')::boolean is false
  and (pg_temp.prod('a1', pg_temp.p(2)) ->> 'stock_quantity')::integer = 0
  and pg_temp.prod('a1', pg_temp.p(2)) ->> 'sku' = 'T6C-INACT',
  'ADMIN: INACTIVE products are returned (the storefront policy would hide them)');

select pg_temp.ok(
  jsonb_typeof(pg_temp.prod('a1', pg_temp.p(3)) -> 'category_id') = 'null'
  and jsonb_typeof(pg_temp.prod('a1', pg_temp.p(3)) -> 'sku') = 'null'
  and jsonb_typeof(pg_temp.prod('a1', pg_temp.p(3)) -> 'compare_at_price_cents') = 'null'
  and (pg_temp.prod('a1', pg_temp.p(3)) ->> 'price_cents')::integer = 0,
  'ADMIN: nullable columns come back as JSON null, not missing');

-- Ordering and limit
select pg_temp.ok(pg_temp.returned_ids('a1') = pg_temp.expected_ids(100),
  'ORDER: returned ids equal the table ordered by name, slug, id (deterministic, collation-independent check)');
select pg_temp.ok(
  (select string_agg(e ->> 'id', ',' order by n)
   from jsonb_array_elements(pg_temp.j('a1') -> 'products') with ordinality as t(e, n)
   where e ->> 'slug' like 't6c-%')
  = pg_temp.p(2)::text || ',' || pg_temp.p(3)::text || ',' || pg_temp.p(1)::text || ',' || pg_temp.p(5)::text || ',' || pg_temp.p(4)::text,
  'ORDER: fixtures come back by name (inactive, sparse, full), then the same-name tie broken by slug (tie-a before tie-b) - NOT by id');
select pg_temp.list('a1b', 'authenticated', pg_temp.u(3), 'p_limit => 100');
select pg_temp.ok(pg_temp.res('a1') = pg_temp.res('a1b'),
  'ORDER: calling twice returns byte-identical output (deterministic)');

select pg_temp.list('l1', 'authenticated', pg_temp.u(3), 'p_limit => 1');
select pg_temp.ok(jsonb_array_length(pg_temp.j('l1') -> 'products') = 1
  and (pg_temp.j('l1') ->> 'limit')::integer = 1
  and (pg_temp.j('l1') ->> 'total')::bigint = (select count(*) from public.products)
  and pg_temp.returned_ids('l1') = pg_temp.expected_ids(1),
  'LIMIT: p_limit => 1 returns exactly the first row in order; total still counts every product');

select pg_temp.list('l3', 'authenticated', pg_temp.u(3), 'p_limit => 3');
select pg_temp.ok(jsonb_array_length(pg_temp.j('l3') -> 'products') = least(3, (select count(*) from public.products))
  and pg_temp.returned_ids('l3') = pg_temp.expected_ids(3),
  'LIMIT: p_limit => 3 returns the first three rows in order');

select pg_temp.list('ldef', 'authenticated', pg_temp.u(3));
select pg_temp.ok((pg_temp.j('ldef') ->> 'limit')::integer = 50
  and jsonb_array_length(pg_temp.j('ldef') -> 'products') = least(50, (select count(*) from public.products))
  and pg_temp.returned_ids('ldef') = pg_temp.expected_ids(50),
  'LIMIT: default limit is 50');

select pg_temp.list('l_pos', 'authenticated', pg_temp.u(3), 'p_limit => 1');
select pg_temp.succeeded('l_pos', 'LIMIT: lower bound 1 is accepted');
select pg_temp.list('l_hi', 'authenticated', pg_temp.u(3), 'p_limit => 100');
select pg_temp.succeeded('l_hi', 'LIMIT: upper bound 100 is accepted');

select pg_temp.list('l0',   'authenticated', pg_temp.u(3), 'p_limit => 0');
select pg_temp.list('l101', 'authenticated', pg_temp.u(3), 'p_limit => 101');
select pg_temp.list('lneg', 'authenticated', pg_temp.u(3), 'p_limit => -5');
select pg_temp.list('lnul', 'authenticated', pg_temp.u(3), 'p_limit => null');
select pg_temp.expect_err('l0',   'P0001', 'invalid_arguments', 'LIMIT: 0 is rejected for an admin');
select pg_temp.expect_err('l101', 'P0001', 'invalid_arguments', 'LIMIT: 101 is rejected for an admin');
select pg_temp.expect_err('lneg', 'P0001', 'invalid_arguments', 'LIMIT: a negative limit is rejected for an admin');
select pg_temp.expect_err('lnul', 'P0001', 'invalid_arguments', 'LIMIT: NULL is rejected for an admin');

-- ===========================================================================
-- B. EVERYONE ELSE IS REFUSED (denial is an ERROR 42501, never "0 rows")
-- ===========================================================================
-- staff
select pg_temp.list('b_staff', 'authenticated', pg_temp.u(2), 'p_limit => 100');
select pg_temp.gated('b_staff', 'STAFF: refused by the admin gate (42501 / not_authorised)');

-- customer
select pg_temp.list('b_cust', 'authenticated', pg_temp.u(1), 'p_limit => 100');
select pg_temp.gated('b_cust', 'CUSTOMER: refused by the admin gate (42501 / not_authorised)');

-- anon with a made-up user id in the claims, and anon signed out
select pg_temp.list('b_anon', 'anon', pg_temp.u(3), 'p_limit => 100');
select pg_temp.no_execute('b_anon', 'ANON: EXECUTE is denied (even carrying the admin user id in its claims)');
select pg_temp.list('b_out', 'anon', null, 'p_limit => 100');
select pg_temp.no_execute('b_out', 'SIGNED OUT (anon, no JWT at all): EXECUTE is denied');

-- authenticated DB role but no usable identity (signed-out-looking JWT)
select pg_temp.list('b_nouid', 'authenticated', null, 'p_limit => 100');
select pg_temp.gated('b_nouid', 'SIGNED OUT (authenticated role, no JWT subject): refused by the admin gate');
select pg_temp.list_claims('b_nosub', 'authenticated', '{"role":"authenticated"}'::jsonb, 'p_limit => 100');
select pg_temp.gated('b_nosub', 'JWT WITHOUT a subject: refused by the admin gate');

-- forged / non-admin JWTs
select pg_temp.list_claims('b_f1', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin'), 'p_limit => 100');
select pg_temp.gated('b_f1', 'FORGED: customer JWT with a top-level user_role=admin claim is refused');
select pg_temp.list_claims('b_f2', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin')), 'p_limit => 100');
select pg_temp.gated('b_f2', 'FORGED: customer JWT with app_metadata/user_metadata role=admin is refused');
select pg_temp.list_claims('b_f3', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'service_role'), 'p_limit => 100');
select pg_temp.gated('b_f3', 'FORGED: customer JWT claiming role=service_role (DB role still authenticated) is refused');
select pg_temp.list_claims('b_f4', 'authenticated',
  jsonb_build_object('sub', '00000000-0000-4000-8000-6cffffffffff', 'role', 'authenticated'), 'p_limit => 100');
select pg_temp.gated('b_f4', 'FORGED: a well-formed JWT for a user id that does not exist is refused');
select pg_temp.list_claims('b_f5', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(2), 'role', 'authenticated', 'is_admin', true, 'admin', true), 'p_limit => 100');
select pg_temp.gated('b_f5', 'FORGED: staff JWT with is_admin / admin = true claims is refused');

-- service_role carries no admin identity, so it does not pass the gate either
select pg_temp.list('b_svc', 'service_role', null, 'p_limit => 100');
select pg_temp.gated('b_svc', 'SERVICE ROLE without an admin user is refused by the gate (no auth.uid())');

-- the gate runs BEFORE argument validation: a refused caller learns nothing about the arguments
select pg_temp.list('b_gate1', 'authenticated', pg_temp.u(1), 'p_limit => 0');
select pg_temp.gated('b_gate1', 'GATE ORDER: customer with an invalid limit gets not_authorised, not invalid_arguments');
select pg_temp.list('b_gate2', 'authenticated', pg_temp.u(2), 'p_limit => null');
select pg_temp.gated('b_gate2', 'GATE ORDER: staff with a NULL limit gets not_authorised, not invalid_arguments');

-- Positive control: the admin reads the SAME fixture rows that were refused above.
select pg_temp.list('b_ctl', 'authenticated', pg_temp.u(3), 'p_limit => 100');
select pg_temp.ok(pg_temp.prod('b_ctl', pg_temp.p(1)) is not null and pg_temp.prod('b_ctl', pg_temp.p(2)) is not null,
  'CONTROL: the admin sees the same fixture rows every refused caller above was denied');

-- ===========================================================================
-- C. FUNCTION METADATA: SECURITY DEFINER, pinned search_path, privileges
-- ===========================================================================
select pg_temp.ok((select count(*) from pg_proc
                   where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') = 1,
  'META: exactly one admin_list_products function exists (no overloads)');
select pg_temp.ok((select prosecdef from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure),
  'META: admin_list_products is SECURITY DEFINER');
select pg_temp.ok((select provolatile = 's' from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure),
  'META: admin_list_products is STABLE (read-only by declaration)');
select pg_temp.ok(
  (select proconfig::text from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure)
    like '%search_path=public, pg_temp%'
  and (select array_length(proconfig, 1) from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) = 1,
  'META: search_path is pinned to exactly "public, pg_temp" (and nothing else is set)');
select pg_temp.ok(pg_get_function_result('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) = 'jsonb'
  and (select proargnames::text from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure)
        = '{p_limit,p_offset,p_search,p_is_active,p_category_id}'
  and (select pronargdefaults from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) = 5,
  'META: signature is admin_list_products(p_limit, p_offset, p_search, p_is_active, p_category_id), all defaulted (extended by 6C.1A.2; p_limit stays first)');
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('p_limit is null' in prosrc)
   from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure),
  'META: the body calls public.require_admin() before it looks at any argument');
select pg_temp.ok(
  (select prosrc !~* '(^|[^a-z_])(insert\s+into|update\s+public\.|delete\s+from|truncate\s|merge\s+into)'
   from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure),
  'META: the body contains no INSERT INTO / UPDATE public. / DELETE FROM / TRUNCATE / MERGE INTO');

select pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE'),
  'GRANTS: anon has no EXECUTE on admin_list_products');
select pg_temp.ok(has_function_privilege('authenticated', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE'),
  'GRANTS: authenticated has EXECUTE (the gate then restricts it to admins)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'GRANTS: PUBLIC has no EXECUTE on admin_list_products');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(p.proacl) a
    where p.oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure
      and a.grantee not in (p.proowner, (select oid from pg_roles where rolname = 'authenticated'),
                            coalesce((select oid from pg_roles where rolname = 'service_role'), -1))),
  'GRANTS: EXECUTE is held only by the owner, authenticated and (Supabase default) service_role');
select pg_temp.ok(not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'GRANTS: require_admin() is still not callable directly by anon or authenticated');
select pg_temp.ok(
  (select r.rolname from pg_proc p join pg_roles r on r.oid = p.proowner
   where p.oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) not in ('anon', 'authenticated', 'service_role'),
  'GRANTS: the function is owned by a privileged owner role, not by a browser role');

-- direct calls to the gate by browser roles still fail outright
select pg_temp.run('g_ra1', 'authenticated', pg_temp.u(3), 'select public.require_admin()::text');
select pg_temp.no_execute('g_ra1', 'GATE: even an admin cannot call require_admin() directly');

-- ===========================================================================
-- D. NO PRODUCT MUTATION PRIVILEGE WAS INTRODUCED; RLS STILL ENABLED
-- ===========================================================================
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)),
  'PRIV: anon/authenticated hold no INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER on products, product_variants, categories');
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl)
    where has_any_column_privilege(r.role, t.tbl, 'INSERT') or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'PRIV: no column-level INSERT/UPDATE privilege for anon/authenticated on any catalogue table');
select pg_temp.ok(
  has_table_privilege('authenticated', 'public.products', 'SELECT')
  and has_table_privilege('anon', 'public.products', 'SELECT'),
  'PRIV: storefront SELECT on products is unchanged (anon and authenticated)');

select pg_temp.ok((select count(*) from pg_class
                   where oid in ('public.products'::regclass, 'public.product_variants'::regclass, 'public.categories'::regclass)
                     and relrowsecurity) = 3,
  'RLS: row level security is still enabled on products, product_variants and categories');
select pg_temp.ok(not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  'RLS: no INSERT/UPDATE/DELETE/ALL policy exists on any catalogue table');
select pg_temp.ok(
  (select array_agg(tablename || ':' || policyname order by tablename, policyname)
   from pg_policies where schemaname = 'public' and tablename in ('products', 'product_variants', 'categories'))
  = array['categories:Categories: admin read all', 'categories:Categories: public read active',
          'product_variants:Variants: admin read all', 'product_variants:Variants: public read active',
          'products:Products: admin read all', 'products:Products: public read active'],
  'RLS: the catalogue policy set is exactly the six existing read policies (this phase added none)');

-- Actual write attempts by every browser role are blocked.
select pg_temp.run('w_a1', 'authenticated', pg_temp.u(3), $$with u as (update public.products set name = 'T6C hacked' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_a2', 'authenticated', pg_temp.u(3), $$with i as (insert into public.products (slug, name) values ('t6c-new', 'T6C new') returning 1) select count(*)::text from i$$);
select pg_temp.run('w_a3', 'authenticated', pg_temp.u(3), $$with d as (delete from public.products returning 1) select count(*)::text from d$$);
select pg_temp.run('w_s1', 'authenticated', pg_temp.u(2), $$with u as (update public.products set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_c1', 'authenticated', pg_temp.u(1), $$with u as (update public.products set is_active = false returning 1) select count(*)::text from u$$);
select pg_temp.run('w_n1', 'anon', null, $$with u as (update public.products set name = 'x' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_v1', 'authenticated', pg_temp.u(3), $$with u as (update public.product_variants set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_k1', 'authenticated', pg_temp.u(3), $$with u as (update public.categories set name = 'x' returning 1) select count(*)::text from u$$);
select pg_temp.write_denied('w_a1', 'WRITE: admin cannot UPDATE products directly (admin_list_products added no write path)');
select pg_temp.write_denied('w_a2', 'WRITE: admin cannot INSERT products directly');
select pg_temp.write_denied('w_a3', 'WRITE: admin cannot DELETE products directly');
select pg_temp.write_denied('w_s1', 'WRITE: staff cannot UPDATE products');
select pg_temp.write_denied('w_c1', 'WRITE: customer cannot UPDATE products');
select pg_temp.write_denied('w_n1', 'WRITE: anon cannot UPDATE products');
select pg_temp.write_denied('w_v1', 'WRITE: admin cannot UPDATE product_variants');
select pg_temp.write_denied('w_k1', 'WRITE: admin cannot UPDATE categories');

-- No product/variant/category/SKU mutation FUNCTION was introduced.
select pg_temp.ok(not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname ilike '%product%' or p.proname ilike '%variant%' or p.proname ilike '%categor%'
           or p.proname ilike '%sku%')
      and p.proname not in ('admin_list_products', 'admin_get_product',
                            'admin_create_product', 'admin_update_product',
                            'admin_set_product_active', 'admin_create_product_variant',
                            'admin_update_product_variant')),
  'FUNCS: the only product/variant/category/SKU-named functions in public are admin_list_products, (6C.1A.2) admin_get_product and (6C.1B.1) admin_create_product / admin_update_product and (6C.1B.2) admin_set_product_active / admin_create_product_variant / admin_update_product_variant');

-- Read-only in practice: nothing about the catalogue changed during all the calls above.
select pg_temp.ok(
  (select s.n = (select count(*) from public.products)
      and s.h = (select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p)
   from t_snap s),
  'READ-ONLY: product count and a hash of every product row are unchanged after all admin calls and blocked writes');

-- Existing storefront behaviour is untouched: anon still reads only ACTIVE fixture products.
select pg_temp.run('s_anon', 'anon', null,
  $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c-%'$$);
select pg_temp.ok(pg_temp.res('s_anon') = 't6c-full,t6c-sparse,t6c-tie-a,t6c-tie-b',
  'STOREFRONT: anon still sees only the four ACTIVE fixture products (existing public RLS unchanged)');
select pg_temp.run('s_staff', 'authenticated', pg_temp.u(2),
  $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c-%'$$);
select pg_temp.ok(pg_temp.res('s_staff') = 't6c-full,t6c-sparse,t6c-tie-a,t6c-tie-b',
  'STOREFRONT: staff still sees only active products directly (no new staff catalogue access)');
select pg_temp.run('s_admin', 'authenticated', pg_temp.u(3),
  $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c-%'$$);
select pg_temp.ok(pg_temp.res('s_admin') = 't6c-full,t6c-inactive,t6c-sparse,t6c-tie-a,t6c-tie-b',
  'STOREFRONT: admin still sees all five fixture products directly (existing 6A admin read policy unchanged)');

do $$ begin raise notice 'ALL PHASE 6C.1A.1 TESTS PASSED'; end $$;

rollback;
