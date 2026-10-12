-- =============================================================================
-- PHASE 6C.1B.1 database test: admin product creation + update foundation.
--
-- STATUS: written for migration 20261004060000_phase6c1b1_admin_product_create_update.sql.
-- NOT run against any database when it was written (no PostgreSQL was available); see the report.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004060000_phase6c1b1_admin_product_create_update.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c1b1_admin_product_create_update.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.1B.1 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST. Authorization is the
-- REAL public.require_admin() / public.user_roles; nothing is faked.
--
-- NOT-EMPTY PROOF: every refusal is asserted as an ERROR (42501), never as "0 rows", and is
-- followed by a positive control in which the admin succeeds with the same kind of arguments.
-- A hash of the products table proves refused calls wrote nothing.
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them: every write targets fixture rows (slug 't6c1b-*'), and the whole run
-- is rolled back. Hash checks that cover the whole table compare the table with itself within
-- this transaction, so existing rows do not matter.
--
-- COVERS (numbering follows the phase brief)
--   A  1-8   authorization: admin ok; staff / customer / anon / signed-out / forged / service_role refused
--   B  9-14  create: result shape, required fields, validation, category, uniqueness, no inventory
--   C  15-20 update: result shape, one-field patch, not found, no stock / activation / image changes
--   D  21-26 privileges: no direct INSERT/UPDATE, ACL, SECURITY DEFINER, search_path, require_admin
--   E  27-33 regression: 6C.1A.1, 6C.1A.2, 6B.2, 6B.1, 6A, 5B.2, 5A.2
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

-- The one product element of a recorded list with this id (null if absent).

-- ---------------------------------------------------------------------------
-- Phase-specific helpers
-- ---------------------------------------------------------------------------
create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c500000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c6000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.c(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c7000000' || lpad(n::text, 3, '0'))::uuid $$;

-- The 16 public.products columns of one row, as the RPCs return them (owner view, no role switch).
create or replace function pg_temp.row_json(p_id uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p.id, 'slug', p.slug, 'name', p.name, 'category_id', p.category_id,
    'description', p.description, 'brand', p.brand, 'sku', p.sku, 'image_url', p.image_url,
    'price_cents', p.price_cents, 'compare_at_price_cents', p.compare_at_price_cents,
    'unit_label', p.unit_label, 'stock_quantity', p.stock_quantity, 'in_stock', p.in_stock,
    'is_active', p.is_active, 'created_at', p.created_at, 'updated_at', p.updated_at)
  from public.products p where p.id = p_id $$;

-- Hash of the whole products table / of one row (to prove "nothing was written").
create or replace function pg_temp.tbl_hash() returns text language sql as $$
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p $$;
create or replace function pg_temp.row_hash(p_id uuid) returns text language sql as $$
  select md5(p::text) from public.products p where p.id = p_id $$;
create temp table t_h (k text primary key, h text);

-- Call admin_create_product(<named args>) as a role.
create or replace function pg_temp.mk(p_k text, p_role text, p_uid uuid, p_args text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_create_product(' || p_args || ')::text');
end;
$$;

-- Call admin_update_product(id, patch) as a role.
create or replace function pg_temp.up(p_k text, p_role text, p_uid uuid, p_id uuid, p_patch text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    format('select public.admin_update_product(%L::uuid, %L::jsonb)::text', p_id, p_patch));
end;
$$;

-- Admin call that must fail with a given SQLSTATE / DETAIL.
create or replace function pg_temp.mkx(p_k text, p_args text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.mk(p_k, 'authenticated', pg_temp.u(3), p_args);
  perform pg_temp.expect_err(p_k, p_state, p_detail, p_name);
end;
$$;
create or replace function pg_temp.upx(p_k text, p_id uuid, p_patch text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.up(p_k, 'authenticated', pg_temp.u(3), p_id, p_patch);
  perform pg_temp.expect_err(p_k, p_state, p_detail, p_name);
end;
$$;
create or replace function pg_temp.mkbad(p_k text, p_args text, p_name text) returns void language sql as $$
  select pg_temp.mkx(p_k, p_args, 'P0001', 'invalid_arguments', p_name) $$;
create or replace function pg_temp.upbad(p_k text, p_id uuid, p_patch text, p_name text) returns void language sql as $$
  select pg_temp.upx(p_k, p_id, p_patch, 'P0001', 'invalid_arguments', p_name) $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c1b-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C1B Customer"}'),
  (pg_temp.u(2), 't6c1b-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C1B Staff"}'),
  (pg_temp.u(3), 't6c1b-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C1B Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

insert into public.categories (id, slug, name, is_active) values
  (pg_temp.c(1), 't6c1b-cat',        'T6C1B Category',          true),
  (pg_temp.c(2), 't6c1b-cat-hidden', 'T6C1B Hidden Category',   false);

insert into public.products
  (id, slug, name, category_id, description, brand, sku, image_url, price_cents,
   compare_at_price_cents, unit_label, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1), 't6c1b-full', 'T6C1B Full', pg_temp.c(1), 'Full description', 'Brand A', 'T6C1B-FULL',
   'https://example.test/full.png', 1500, 1800, '1 kg', 12, true, true),
  (pg_temp.p(2), 't6c1b-inactive', 'T6C1B Inactive', null, null, null, 'T6C1B-INACT',
   null, 700, null, null, 0, false, false),
  (pg_temp.p(3), 't6c1b-other', 'T6C1B Other', null, null, null, 'T6C1B-OTHER',
   null, 100, null, null, 5, true, true),
  (pg_temp.p(4), 't6c1b-clear', 'T6C1B Clear', pg_temp.c(1), 'To be cleared', 'Brand Z', 'T6C1B-CLEAR',
   'https://example.test/clear.png', 900, 1000, '2 pcs', 7, true, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c1b-%') = 4,
  'FIXTURE: four test products (full, inactive, other, clear) exist');

insert into t_h values ('h0', pg_temp.tbl_hash());

-- ===========================================================================
-- A. AUTHORIZATION - refused callers (denial is an ERROR 42501, never "0 rows"; nothing is written)
-- ===========================================================================
-- All refused calls use VALID arguments: without the gate they would succeed.
select pg_temp.mk('a_staff', 'authenticated', pg_temp.u(2), $$p_name => 'T6C1B Staff Try', p_slug => 't6c1b-staff-try', p_price_cents => 100$$);
select pg_temp.gated('a_staff', 'STAFF cannot create: refused by the admin gate (42501 / not_authorised)');
select pg_temp.up('a_staff_u', 'authenticated', pg_temp.u(2), pg_temp.p(1), '{"name":"T6C1B Staff Rename"}');
select pg_temp.gated('a_staff_u', 'STAFF cannot update: refused by the admin gate (42501 / not_authorised)');

select pg_temp.mk('a_cust', 'authenticated', pg_temp.u(1), $$p_name => 'T6C1B Cust Try', p_slug => 't6c1b-cust-try', p_price_cents => 100$$);
select pg_temp.gated('a_cust', 'CUSTOMER cannot create: refused by the admin gate (42501 / not_authorised)');
select pg_temp.up('a_cust_u', 'authenticated', pg_temp.u(1), pg_temp.p(1), '{"name":"T6C1B Cust Rename"}');
select pg_temp.gated('a_cust_u', 'CUSTOMER cannot update: refused by the admin gate (42501 / not_authorised)');

select pg_temp.mk('a_anon', 'anon', pg_temp.u(3), $$p_name => 'T6C1B Anon Try', p_slug => 't6c1b-anon-try', p_price_cents => 100$$);
select pg_temp.no_execute('a_anon', 'ANON cannot execute admin_create_product (even carrying the admin user id in its claims)');
select pg_temp.up('a_anon_u', 'anon', pg_temp.u(3), pg_temp.p(1), '{"name":"T6C1B Anon Rename"}');
select pg_temp.no_execute('a_anon_u', 'ANON cannot execute admin_update_product (even carrying the admin user id in its claims)');

select pg_temp.mk('a_out', 'anon', null, $$p_name => 'T6C1B Out Try', p_slug => 't6c1b-out-try', p_price_cents => 100$$);
select pg_temp.no_execute('a_out', 'SIGNED OUT (anon, no JWT) cannot execute admin_create_product');
select pg_temp.up('a_out_u', 'anon', null, pg_temp.p(1), '{"name":"T6C1B Out Rename"}');
select pg_temp.no_execute('a_out_u', 'SIGNED OUT (anon, no JWT) cannot execute admin_update_product');

select pg_temp.mk('a_nouid', 'authenticated', null, $$p_name => 'T6C1B NoUid Try', p_slug => 't6c1b-nouid-try', p_price_cents => 100$$);
select pg_temp.gated('a_nouid', 'SIGNED OUT (authenticated role, auth.uid() null): create refused by the admin gate');
select pg_temp.up('a_nouid_u', 'authenticated', null, pg_temp.p(1), '{"name":"T6C1B NoUid Rename"}');
select pg_temp.gated('a_nouid_u', 'SIGNED OUT (authenticated role, auth.uid() null): update refused by the admin gate');

select pg_temp.run_claims('a_nosub', 'authenticated', '{"role":"authenticated"}'::jsonb,
  $$select public.admin_create_product(p_name => 'T6C1B NoSub', p_slug => 't6c1b-nosub', p_price_cents => 1)::text$$);
select pg_temp.gated('a_nosub', 'JWT WITHOUT a subject: create refused by the admin gate');

select pg_temp.run_claims('a_f1', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin'), 'is_admin', true),
  $$select public.admin_create_product(p_name => 'T6C1B Forged', p_slug => 't6c1b-forged', p_price_cents => 1)::text$$);
select pg_temp.gated('a_f1', 'FORGED: customer JWT with admin claims in every claim location is refused (create)');
select pg_temp.run_claims('a_f2', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(2), 'role', 'service_role', 'admin', true),
  format($$select public.admin_update_product(%L::uuid, '{"name":"T6C1B Forged"}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.gated('a_f2', 'FORGED: staff JWT claiming role=service_role / admin=true is refused (update)');
select pg_temp.run_claims('a_f3', 'authenticated',
  jsonb_build_object('sub', '00000000-0000-4000-8000-6c5fffffffff', 'role', 'authenticated'),
  $$select public.admin_create_product(p_name => 'T6C1B Ghost', p_slug => 't6c1b-ghost', p_price_cents => 1)::text$$);
select pg_temp.gated('a_f3', 'FORGED: a well-formed JWT for a user id that does not exist is refused');

select pg_temp.mk('a_svc', 'service_role', null, $$p_name => 'T6C1B Svc Try', p_slug => 't6c1b-svc-try', p_price_cents => 100$$);
select pg_temp.gated('a_svc', 'SERVICE ROLE without an admin user is refused by the gate (create; no auth.uid())');
select pg_temp.up('a_svc_u', 'service_role', null, pg_temp.p(1), '{"name":"T6C1B Svc Rename"}');
select pg_temp.gated('a_svc_u', 'SERVICE ROLE without an admin user is refused by the gate (update; no auth.uid())');

-- The gate runs BEFORE argument validation and BEFORE the existence check: a refused caller learns
-- nothing about the rules or about which products exist.
select pg_temp.mk('a_g1', 'authenticated', pg_temp.u(1), $$p_name => null, p_slug => 'Not A Slug', p_price_cents => -5$$);
select pg_temp.gated('a_g1', 'GATE ORDER: customer with invalid create arguments gets not_authorised, not invalid_arguments');
select pg_temp.up('a_g2', 'authenticated', pg_temp.u(2), pg_temp.p(1), '{}');
select pg_temp.gated('a_g2', 'GATE ORDER: staff with an empty patch gets not_authorised, not invalid_arguments');
select pg_temp.up('a_g3', 'authenticated', pg_temp.u(1), '00000000-0000-4000-8000-6c6fffffffff', '{"is_active":false}');
select pg_temp.gated('a_g3', 'GATE ORDER: customer with an unknown product id and a forbidden key gets not_authorised (no existence leak)');
select pg_temp.up('a_g4', 'authenticated', pg_temp.u(2), null, '{"name":"x"}');
select pg_temp.gated('a_g4', 'GATE ORDER: staff with a NULL product id gets not_authorised');

select pg_temp.ok(pg_temp.tbl_hash() = (select h from t_h where k = 'h0'),
  'REFUSED CALLS WROTE NOTHING: a hash of every product row is unchanged after all refused create / update attempts');

-- Positive controls: the admin succeeds with the SAME kind of arguments that were refused above.
select pg_temp.mk('a_adm', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Admin Created', p_slug => 't6c1b-admin-created', p_price_cents => 100$$);
select pg_temp.succeeded('a_adm', 'ADMIN can create a product (positive control for every refusal above)');
select pg_temp.up('a_adm_u', 'authenticated', pg_temp.u(3), pg_temp.p(3), '{"name":"T6C1B Other"}');
select pg_temp.succeeded('a_adm_u', 'ADMIN can update a product (positive control for every refusal above)');

-- ===========================================================================
-- B. CREATE
-- ===========================================================================
select pg_temp.mk('b1', 'authenticated', pg_temp.u(3), format(
  $$p_name => '  T6C1B Created  ', p_slug => 't6c1b-created', p_price_cents => 2500, p_category_id => %L,
    p_description => '  A description  ', p_brand => 'Brand C', p_sku => 'T6C1B-NEW', p_unit_label => '500 g',
    p_compare_at_price_cents => 3000$$, pg_temp.c(1)));
select pg_temp.succeeded('b1', 'CREATE: a valid product is created');
select pg_temp.ok(pg_temp.keys(pg_temp.j('b1')) = 'product',
  'CREATE: the result has exactly one key, "product"');
select pg_temp.ok(
  pg_temp.keys(pg_temp.j('b1') -> 'product') =
    'brand,category_id,compare_at_price_cents,created_at,description,id,image_url,in_stock,is_active,name,price_cents,sku,slug,stock_quantity,unit_label,updated_at'
  and (select count(*) from jsonb_object_keys(pg_temp.j('b1') -> 'product')) = 16,
  'CREATE: the product carries exactly the 16 public.products columns (no extras, none missing)');
select pg_temp.ok(
  (pg_temp.j('b1') -> 'product' ->> 'slug') = 't6c1b-created'
  and (pg_temp.j('b1') -> 'product' ->> 'name') = 'T6C1B Created'
  and (pg_temp.j('b1') -> 'product' ->> 'category_id') = pg_temp.c(1)::text
  and (pg_temp.j('b1') -> 'product' ->> 'description') = 'A description'
  and (pg_temp.j('b1') -> 'product' ->> 'brand') = 'Brand C'
  and (pg_temp.j('b1') -> 'product' ->> 'sku') = 'T6C1B-NEW'
  and (pg_temp.j('b1') -> 'product' ->> 'unit_label') = '500 g'
  and (pg_temp.j('b1') -> 'product' ->> 'price_cents')::integer = 2500
  and (pg_temp.j('b1') -> 'product' ->> 'compare_at_price_cents')::integer = 3000,
  'CREATE: the returned values are what was supplied (text trimmed, money stays integer cents)');
select pg_temp.ok(
  (select count(*) from public.products where id = (pg_temp.j('b1') -> 'product' ->> 'id')::uuid) = 1
  and pg_temp.j('b1') -> 'product' = pg_temp.row_json((pg_temp.j('b1') -> 'product' ->> 'id')::uuid),
  'CREATE: the returned JSONB is exactly the stored row (one row exists and every one of the 16 values matches)');
select pg_temp.ok(
  (pg_temp.j('b1') -> 'product' ->> 'id') is not null
  and (pg_temp.j('b1') -> 'product' ->> 'created_at') is not null
  and (pg_temp.j('b1') -> 'product' ->> 'updated_at') is not null,
  'CREATE: id, created_at and updated_at are filled in by the database');

-- Inventory / activation / image are NOT set by the function: table defaults apply.
select pg_temp.ok(
  (pg_temp.j('b1') -> 'product' ->> 'stock_quantity')::integer = 0
  and (pg_temp.j('b1') -> 'product' ->> 'in_stock')::boolean is true
  and (pg_temp.j('b1') -> 'product' ->> 'is_active')::boolean is true
  and jsonb_typeof(pg_temp.j('b1') -> 'product' -> 'image_url') = 'null',
  'CREATE: stock_quantity / in_stock / is_active / image_url keep their TABLE DEFAULTS (0 / true / true / null) - the function sets none of them');
select pg_temp.mk('b_inv1', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Inv', p_slug => 't6c1b-inv', p_price_cents => 1, p_stock_quantity => 50$$);
select pg_temp.expect_err('b_inv1', '42883', null, 'CREATE: there is no p_stock_quantity parameter (a stock value cannot be passed in)');
select pg_temp.mk('b_inv2', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Inv', p_slug => 't6c1b-inv', p_price_cents => 1, p_is_active => false$$);
select pg_temp.expect_err('b_inv2', '42883', null, 'CREATE: there is no p_is_active parameter (activation cannot be passed in)');
select pg_temp.mk('b_inv3', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Inv', p_slug => 't6c1b-inv', p_price_cents => 1, p_in_stock => false$$);
select pg_temp.expect_err('b_inv3', '42883', null, 'CREATE: there is no p_in_stock parameter');
select pg_temp.mk('b_inv4', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Inv', p_slug => 't6c1b-inv', p_price_cents => 1, p_image_url => 'https://example.test/x.png'$$);
select pg_temp.expect_err('b_inv4', '42883', null, 'CREATE: there is no p_image_url parameter (image handling is a later phase)');
select pg_temp.ok((select count(*) from public.products where slug in ('t6c1b-inv')) = 0,
  'CREATE: none of the rejected inventory / activation / image attempts created a row');

-- Minimal create: only the three required arguments.
select pg_temp.mk('b2', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Minimal', p_slug => 't6c1b-min', p_price_cents => 0$$);
select pg_temp.succeeded('b2', 'CREATE: only name, slug and price are required (price 0 is allowed, as the table allows it)');
select pg_temp.ok(
  jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'category_id') = 'null'
  and jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'description') = 'null'
  and jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'brand') = 'null'
  and jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'sku') = 'null'
  and jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'unit_label') = 'null'
  and jsonb_typeof(pg_temp.j('b2') -> 'product' -> 'compare_at_price_cents') = 'null'
  and (pg_temp.j('b2') -> 'product' ->> 'price_cents')::integer = 0,
  'CREATE: omitted optional fields come back as JSON null');

-- Optional text that is blank becomes NULL (so a blank SKU never collides with another blank SKU).
select pg_temp.mk('b3', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Blanks 1', p_slug => 't6c1b-blank-1', p_price_cents => 1, p_sku => '   ', p_brand => '', p_description => E' \n ', p_unit_label => ' '$$);
select pg_temp.mk('b3b', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Blanks 2', p_slug => 't6c1b-blank-2', p_price_cents => 1, p_sku => ''$$);
select pg_temp.ok(pg_temp.j('b3') -> 'product' -> 'sku' = 'null'::jsonb
  and pg_temp.j('b3') -> 'product' -> 'brand' = 'null'::jsonb
  and pg_temp.j('b3') -> 'product' -> 'description' = 'null'::jsonb
  and pg_temp.j('b3') -> 'product' -> 'unit_label' = 'null'::jsonb
  and pg_temp.j('b3b') -> 'product' -> 'sku' = 'null'::jsonb,
  'CREATE: blank optional text is stored as NULL; two products with a blank SKU do not collide');
select pg_temp.mk('b3c', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B NoSku', p_slug => 't6c1b-nosku', p_price_cents => 1$$);
select pg_temp.succeeded('b3c', 'CREATE: several products without a SKU coexist (the SKU index is partial: sku is not null)');

-- Equal compare-at price is allowed (constraint is >=).
select pg_temp.mk('b4', 'authenticated', pg_temp.u(3), $$p_name => 'T6C1B Equal', p_slug => 't6c1b-equal', p_price_cents => 500, p_compare_at_price_cents => 500$$);
select pg_temp.succeeded('b4', 'CREATE: compare_at_price_cents equal to the price is accepted (products_compare_at_valid is >=)');

-- Required fields and basic validation (admin caller)
select pg_temp.mkbad('b_r1', $$p_name => null, p_slug => 't6c1b-r1', p_price_cents => 1$$, 'REQUIRED: NULL name is rejected');
select pg_temp.mkbad('b_r2', $$p_name => '   ', p_slug => 't6c1b-r2', p_price_cents => 1$$, 'REQUIRED: whitespace-only name is rejected');
select pg_temp.mkbad('b_r3', $$p_name => '', p_slug => 't6c1b-r3', p_price_cents => 1$$, 'REQUIRED: empty name is rejected');
select pg_temp.mkbad('b_r4', $$p_name => 'T6C1B R4', p_slug => null, p_price_cents => 1$$, 'REQUIRED: NULL slug is rejected');
select pg_temp.mkbad('b_r5', $$p_name => 'T6C1B R5', p_slug => '   ', p_price_cents => 1$$, 'REQUIRED: blank slug is rejected');
select pg_temp.mkbad('b_r6', $$p_name => 'T6C1B R6', p_slug => 't6c1b-r6', p_price_cents => null$$, 'REQUIRED: NULL price is rejected');
select pg_temp.mkbad('b_r7', $$p_name => 'T6C1B R7', p_slug => 't6c1b-r7', p_price_cents => -1$$, 'VALIDATION: negative price is rejected (products_price_nonnegative)');
select pg_temp.mkx('b_r8', $$p_slug => 't6c1b-r8', p_price_cents => 1$$, '42883', null, 'REQUIRED: omitting p_name altogether is not a valid call (no default)');
select pg_temp.mkx('b_r9', $$p_name => 'T6C1B R9', p_price_cents => 1$$, '42883', null, 'REQUIRED: omitting p_slug altogether is not a valid call (no default)');
select pg_temp.mkx('b_r10', $$p_name => 'T6C1B R10', p_slug => 't6c1b-r10'$$, '42883', null, 'REQUIRED: omitting p_price_cents altogether is not a valid call (no default)');

select pg_temp.mkbad('b_s1', $$p_name => 'T6C1B S', p_slug => 'Bad Slug', p_price_cents => 1$$, 'SLUG: a slug with a space and capitals is rejected');
select pg_temp.mkbad('b_s2', $$p_name => 'T6C1B S', p_slug => 'UPPER', p_price_cents => 1$$, 'SLUG: upper case is rejected, not silently lower-cased');
select pg_temp.mkbad('b_s3', $$p_name => 'T6C1B S', p_slug => 'a--b', p_price_cents => 1$$, 'SLUG: a double hyphen is rejected');
select pg_temp.mkbad('b_s4', $$p_name => 'T6C1B S', p_slug => '-ab', p_price_cents => 1$$, 'SLUG: a leading hyphen is rejected');
select pg_temp.mkbad('b_s5', $$p_name => 'T6C1B S', p_slug => 'ab-', p_price_cents => 1$$, 'SLUG: a trailing hyphen is rejected');
select pg_temp.mkbad('b_s6', $$p_name => 'T6C1B S', p_slug => 'a_b', p_price_cents => 1$$, 'SLUG: an underscore is rejected');
select pg_temp.mkbad('b_s7', $$p_name => 'T6C1B S', p_slug => 'a/b', p_price_cents => 1$$, 'SLUG: a slash is rejected');
select pg_temp.mkbad('b_s8', format($$p_name => 'T6C1B S', p_slug => %L, p_price_cents => 1$$, repeat('a', 121)), 'SLUG: 121 characters is rejected');
select pg_temp.mk('b_s9', 'authenticated', pg_temp.u(3), format($$p_name => 'T6C1B S9', p_slug => %L, p_price_cents => 1$$, repeat('a', 120)));
select pg_temp.succeeded('b_s9', 'SLUG: exactly 120 characters is accepted');

select pg_temp.mkbad('b_l1', format($$p_name => %L, p_slug => 't6c1b-l1', p_price_cents => 1$$, repeat('n', 201)), 'LENGTH: a 201-character name is rejected');
select pg_temp.mk('b_l2', 'authenticated', pg_temp.u(3), format($$p_name => %L, p_slug => 't6c1b-l2', p_price_cents => 1$$, repeat('n', 200)));
select pg_temp.succeeded('b_l2', 'LENGTH: a 200-character name is accepted');
select pg_temp.mkbad('b_l3', format($$p_name => 'T6C1B L', p_slug => 't6c1b-l3', p_price_cents => 1, p_description => %L$$, repeat('d', 4001)), 'LENGTH: a 4001-character description is rejected');
select pg_temp.mkbad('b_l4', format($$p_name => 'T6C1B L', p_slug => 't6c1b-l4', p_price_cents => 1, p_brand => %L$$, repeat('b', 101)), 'LENGTH: a 101-character brand is rejected');
select pg_temp.mkbad('b_l5', format($$p_name => 'T6C1B L', p_slug => 't6c1b-l5', p_price_cents => 1, p_unit_label => %L$$, repeat('u', 41)), 'LENGTH: a 41-character unit_label is rejected');
select pg_temp.mkbad('b_l6', format($$p_name => 'T6C1B L', p_slug => 't6c1b-l6', p_price_cents => 1, p_sku => %L$$, repeat('s', 65)), 'LENGTH: a 65-character SKU is rejected');
select pg_temp.mkbad('b_l7', $$p_name => E'T6C1B\nNewline', p_slug => 't6c1b-l7', p_price_cents => 1$$, 'FORMAT: a control character (newline) in the name is rejected');
select pg_temp.mkbad('b_l8', $$p_name => 'T6C1B L', p_slug => 't6c1b-l8', p_price_cents => 1, p_sku => 'BAD SKU'$$, 'FORMAT: a SKU containing a space is rejected');
select pg_temp.mkbad('b_l9', $$p_name => 'T6C1B L', p_slug => 't6c1b-l9', p_price_cents => 1, p_sku => '-LEADING'$$, 'FORMAT: a SKU starting with a hyphen is rejected');
select pg_temp.mkbad('b_l10', $$p_name => 'T6C1B L', p_slug => 't6c1b-l10', p_price_cents => 1, p_brand => E'Br\tand'$$, 'FORMAT: a control character (tab) in the brand is rejected');
select pg_temp.mkbad('b_c1', $$p_name => 'T6C1B C', p_slug => 't6c1b-c1', p_price_cents => 1000, p_compare_at_price_cents => 999$$, 'PRICE: compare_at_price_cents below the price is rejected with a clear error (not a raw check violation)');

-- Category
select pg_temp.mkx('b_k1', format($$p_name => 'T6C1B K', p_slug => 't6c1b-k1', p_price_cents => 1, p_category_id => %L$$, '00000000-0000-4000-8000-6c7fffffffff'::uuid),
  'P0001', 'category_not_found', 'CATEGORY: an unknown category_id is rejected (category_not_found)');
select pg_temp.ok((select count(*) from public.products where slug = 't6c1b-k1') = 0, 'CATEGORY: no product is created for an unknown category');
select pg_temp.mk('b_k2', 'authenticated', pg_temp.u(3), format($$p_name => 'T6C1B K2', p_slug => 't6c1b-k2', p_price_cents => 1, p_category_id => %L$$, pg_temp.c(2)));
select pg_temp.succeeded('b_k2', 'CATEGORY: an existing but INACTIVE category is accepted (the admin can stage products in it)');
select pg_temp.ok(pg_temp.j('b_k2') -> 'product' ->> 'category_id' = pg_temp.c(2)::text, 'CATEGORY: the inactive category id is stored');

-- Uniqueness: the existing unique indexes decide; nothing is bypassed.
insert into t_h values ('h_dup', pg_temp.tbl_hash());
select pg_temp.mkx('b_d1', $$p_name => 'T6C1B Dup', p_slug => 't6c1b-full', p_price_cents => 1$$,
  '23505', 'slug_taken', 'UNIQUE: a duplicate slug is rejected (23505 / slug_taken)');
select pg_temp.mkx('b_d2', $$p_name => 'T6C1B Dup', p_slug => 't6c1b-dup-2', p_price_cents => 1, p_sku => 'T6C1B-FULL'$$,
  '23505', 'sku_taken', 'UNIQUE: a duplicate SKU is rejected (23505 / sku_taken)');
select pg_temp.mkx('b_d3', $$p_name => 'T6C1B Dup', p_slug => ' t6c1b-created ', p_price_cents => 1$$,
  '23505', 'slug_taken', 'UNIQUE: a duplicate slug is detected after trimming');
select pg_temp.ok(pg_temp.tbl_hash() = (select h from t_h where k = 'h_dup'),
  'UNIQUE: the rejected duplicates changed nothing (no partial row, no side effect)');

-- ===========================================================================
-- C. UPDATE
-- ===========================================================================
insert into t_h values ('p2_before', pg_temp.row_hash(pg_temp.p(2)));

select pg_temp.up('u1', 'authenticated', pg_temp.u(3), pg_temp.p(1),
  '{"name":"  T6C1B Renamed  ","price_cents":1600,"compare_at_price_cents":2000}');
select pg_temp.succeeded('u1', 'UPDATE: an existing product is updated');
select pg_temp.ok(pg_temp.keys(pg_temp.j('u1')) = 'product'
  and (select count(*) from jsonb_object_keys(pg_temp.j('u1') -> 'product')) = 16,
  'UPDATE: the result is { "product": { 16 columns } }');
select pg_temp.ok(
  pg_temp.j('u1') -> 'product' ->> 'name' = 'T6C1B Renamed'
  and (pg_temp.j('u1') -> 'product' ->> 'price_cents')::integer = 1600
  and (pg_temp.j('u1') -> 'product' ->> 'compare_at_price_cents')::integer = 2000
  and pg_temp.j('u1') -> 'product' ->> 'id' = pg_temp.p(1)::text,
  'UPDATE: the returned JSONB shows the new values (name trimmed) for the same product id');
select pg_temp.ok(pg_temp.j('u1') -> 'product' = pg_temp.row_json(pg_temp.p(1)),
  'UPDATE: the returned JSONB is exactly the stored row after the update');

-- Updating ONE field leaves every other column exactly as it was.
create temp table t_snap as select to_jsonb(p) as j from public.products p where p.id = pg_temp.p(1);
select pg_temp.up('u2', 'authenticated', pg_temp.u(3), pg_temp.p(1), '{"brand":"Brand B"}');
select pg_temp.succeeded('u2', 'UPDATE: a one-field patch succeeds');
select pg_temp.ok(
  (select to_jsonb(p) - 'brand' - 'updated_at' = s.j - 'brand' - 'updated_at'
          and to_jsonb(p) ->> 'brand' = 'Brand B'
   from public.products p, t_snap s where p.id = pg_temp.p(1)),
  'UPDATE: changing only brand leaves all other columns identical (name, slug, category, description, sku, image, prices, unit, stock, in_stock, is_active, created_at)');

-- Absent key = unchanged; null = cleared (nullable columns only).
select pg_temp.up('u3', 'authenticated', pg_temp.u(3), pg_temp.p(4),
  '{"description":null,"brand":null,"sku":null,"unit_label":null,"category_id":null,"compare_at_price_cents":null}');
select pg_temp.succeeded('u3', 'UPDATE: JSON null clears the nullable catalogue fields');
select pg_temp.ok(
  (select p.description is null and p.brand is null and p.sku is null and p.unit_label is null
          and p.category_id is null and p.compare_at_price_cents is null
          and p.name = 'T6C1B Clear' and p.slug = 't6c1b-clear' and p.price_cents = 900
          and p.image_url = 'https://example.test/clear.png'
          and p.stock_quantity = 7 and p.in_stock and p.is_active
   from public.products p where p.id = pg_temp.p(4)),
  'UPDATE: the six cleared fields are null; name, slug, price, image_url, stock, in_stock and is_active are untouched (absent key = unchanged)');

select pg_temp.up('u4', 'authenticated', pg_temp.u(3), pg_temp.p(3), '{"name":"  Trim Me  ","brand":"   ","description":"New text"}');
select pg_temp.ok(pg_temp.j('u4') -> 'product' ->> 'name' = 'Trim Me'
  and pg_temp.j('u4') -> 'product' -> 'brand' = 'null'::jsonb
  and pg_temp.j('u4') -> 'product' ->> 'description' = 'New text',
  'UPDATE: text is trimmed and a blank optional value is stored as NULL');
-- Updating a product to its own slug / sku is not a duplicate.
select pg_temp.up('u5', 'authenticated', pg_temp.u(3), pg_temp.p(3), '{"slug":"t6c1b-other","sku":"T6C1B-OTHER"}');
select pg_temp.succeeded('u5', 'UPDATE: re-submitting the product''s own slug and SKU is not a duplicate');
-- Category set / inactive category
select pg_temp.up('u6', 'authenticated', pg_temp.u(3), pg_temp.p(3), format('{"category_id":"%s"}', pg_temp.c(2)));
select pg_temp.ok(pg_temp.j('u6') -> 'product' ->> 'category_id' = pg_temp.c(2)::text,
  'UPDATE: category_id can be set to an existing (even inactive) category');
-- Slug change
select pg_temp.up('u7', 'authenticated', pg_temp.u(3), pg_temp.p(3), '{"slug":"t6c1b-other-renamed"}');
select pg_temp.ok(pg_temp.j('u7') -> 'product' ->> 'slug' = 't6c1b-other-renamed', 'UPDATE: the slug can be changed');
select pg_temp.up('u7b', 'authenticated', pg_temp.u(3), pg_temp.p(3), '{"slug":"t6c1b-other"}');

-- The update did not touch an unrelated product.
select pg_temp.ok(pg_temp.row_hash(pg_temp.p(2)) = (select h from t_h where k = 'p2_before'),
  'UPDATE: an unrelated product (p2) is byte-for-byte unchanged by updates of other products');

-- Not found / bad shapes
select pg_temp.upx('u_nf', '00000000-0000-4000-8000-6c6fffffffff', '{"name":"Nope"}', 'P0001', 'product_not_found',
  'UPDATE: a nonexistent product is rejected (P0001 / product_not_found)');
select pg_temp.upbad('u_nid', null, '{"name":"Nope"}', 'UPDATE: a NULL product id is rejected for an admin');
select pg_temp.upbad('u_e1', pg_temp.p(1), '{}', 'UPDATE: an empty patch is rejected');
select pg_temp.upbad('u_e2', pg_temp.p(1), '[]', 'UPDATE: a JSON array patch is rejected');
select pg_temp.upbad('u_e3', pg_temp.p(1), '"name"', 'UPDATE: a JSON string patch is rejected');
select pg_temp.upbad('u_e4', pg_temp.p(1), 'null', 'UPDATE: a JSON null patch is rejected');
select pg_temp.run('u_e5', 'authenticated', pg_temp.u(3), format('select public.admin_update_product(%L::uuid, null)::text', pg_temp.p(1)));
select pg_temp.expect_err('u_e5', 'P0001', 'invalid_arguments', 'UPDATE: a SQL NULL patch is rejected');

-- Stock / inventory / activation / image / system columns can NOT be changed through this RPC.
insert into t_h values ('p1_before_forbidden', pg_temp.row_hash(pg_temp.p(1)));
insert into t_h values ('all_before_forbidden', pg_temp.tbl_hash());
select pg_temp.upx('f1', pg_temp.p(1), '{"stock_quantity":999}', 'P0001', 'unsupported_field', 'FORBIDDEN: stock_quantity cannot be changed (unsupported_field)');
select pg_temp.upx('f2', pg_temp.p(1), '{"in_stock":false}', 'P0001', 'unsupported_field', 'FORBIDDEN: in_stock cannot be changed (unsupported_field)');
select pg_temp.upx('f3', pg_temp.p(1), '{"is_active":false}', 'P0001', 'unsupported_field', 'FORBIDDEN: DEACTIVATION is refused (is_active -> unsupported_field)');
select pg_temp.upx('f4', pg_temp.p(2), '{"is_active":true}', 'P0001', 'unsupported_field', 'FORBIDDEN: ACTIVATION is refused (is_active -> unsupported_field)');
select pg_temp.upx('f5', pg_temp.p(1), '{"image_url":"https://example.test/evil.png"}', 'P0001', 'unsupported_field', 'FORBIDDEN: image_url cannot be changed (image handling is a later phase)');
select pg_temp.upx('f6', pg_temp.p(1), '{"id":"00000000-0000-4000-8000-6c6000000999"}', 'P0001', 'unsupported_field', 'FORBIDDEN: id cannot be changed');
select pg_temp.upx('f7', pg_temp.p(1), '{"created_at":"2000-01-01T00:00:00Z"}', 'P0001', 'unsupported_field', 'FORBIDDEN: created_at cannot be changed');
select pg_temp.upx('f8', pg_temp.p(1), '{"updated_at":"2000-01-01T00:00:00Z"}', 'P0001', 'unsupported_field', 'FORBIDDEN: updated_at cannot be changed');
select pg_temp.upx('f9', pg_temp.p(1), '{"Name":"Case Trick"}', 'P0001', 'unsupported_field', 'FORBIDDEN: key matching is exact (a different-case key is not accepted)');
select pg_temp.upx('f10', pg_temp.p(1), '{"unknown_column":1}', 'P0001', 'unsupported_field', 'FORBIDDEN: an unknown key is refused');
select pg_temp.upx('f11', pg_temp.p(1), '{"name":"Should Not Stick","is_active":false,"stock_quantity":0}', 'P0001', 'unsupported_field',
  'FORBIDDEN: a patch mixing valid fields with forbidden ones is refused as a whole');
select pg_temp.upx('f12', pg_temp.p(1), '{"price_cents":1,"stock_quantity":1}', 'P0001', 'unsupported_field',
  'FORBIDDEN: valid price plus forbidden stock is refused as a whole');
select pg_temp.upx('f13', pg_temp.p(1), '{"variants":[{"sku":"X"}]}', 'P0001', 'unsupported_field', 'FORBIDDEN: variant data cannot be passed (no variant manipulation)');
select pg_temp.ok(pg_temp.row_hash(pg_temp.p(1)) = (select h from t_h where k = 'p1_before_forbidden')
  and pg_temp.tbl_hash() = (select h from t_h where k = 'all_before_forbidden'),
  'FORBIDDEN: after every refused patch the product (and the whole products table) is byte-for-byte unchanged');
select pg_temp.ok(
  (select p.stock_quantity = 12 and p.in_stock and p.is_active and p.image_url = 'https://example.test/full.png'
   from public.products p where p.id = pg_temp.p(1)),
  'FORBIDDEN: p1 still has stock 12, in_stock, is_active and its image_url after all updates so far');

-- Legitimate updates never change stock / activation / image, even on an inactive, out-of-stock product.
select pg_temp.up('u8', 'authenticated', pg_temp.u(3), pg_temp.p(2), '{"name":"T6C1B Inactive Renamed","price_cents":701,"description":"still hidden"}');
select pg_temp.succeeded('u8', 'UPDATE: an inactive product can have its catalogue fields edited');
select pg_temp.ok(
  (select not p.is_active and not p.in_stock and p.stock_quantity = 0 and p.image_url is null and p.sku = 'T6C1B-INACT'
          and p.name = 'T6C1B Inactive Renamed' and p.price_cents = 701
   from public.products p where p.id = pg_temp.p(2))
  and (pg_temp.j('u8') -> 'product' ->> 'is_active')::boolean is false
  and (pg_temp.j('u8') -> 'product' ->> 'stock_quantity')::integer = 0,
  'UPDATE: the product stays INACTIVE, out of stock with stock 0 (the RPC cannot activate or restock)');
select pg_temp.ok(
  (select p.stock_quantity = 12 and p.in_stock and p.is_active and p.image_url = 'https://example.test/full.png'
   from public.products p where p.id = pg_temp.p(1)),
  'UPDATE: p1 stock / in_stock / is_active / image_url are unchanged by its (several) legitimate updates');

-- Value validation (admin caller; each must leave the product untouched)
insert into t_h values ('p1_before_bad', pg_temp.row_hash(pg_temp.p(1)));
select pg_temp.upbad('v_' || n, pg_temp.p(1), patch, 'VALIDATION: ' || label)
from (values
  (1,  '{"name":5}',                       'name as a number is rejected'),
  (2,  '{"name":null}',                    'name cannot be cleared (null)'),
  (3,  '{"name":"   "}',                   'a blank name is rejected'),
  (4,  '{"slug":null}',                    'slug cannot be cleared (null)'),
  (5,  '{"slug":"Bad Slug"}',              'an invalid slug is rejected'),
  (6,  '{"slug":7}',                       'slug as a number is rejected'),
  (7,  '{"price_cents":"12"}',             'price as a string is rejected'),
  (8,  '{"price_cents":12.5}',             'a fractional price is rejected'),
  (9,  '{"price_cents":-1}',               'a negative price is rejected'),
  (10, '{"price_cents":3000000000}',       'a price beyond the integer range is rejected'),
  (11, '{"price_cents":null}',             'price cannot be cleared (null)'),
  (12, '{"compare_at_price_cents":"x"}',   'compare-at as a string is rejected'),
  (13, '{"compare_at_price_cents":-1}',    'a negative compare-at is rejected'),
  (14, '{"compare_at_price_cents":12.5}',  'a fractional compare-at is rejected'),
  (15, '{"category_id":5}',                'category_id as a number is rejected'),
  (16, '{"category_id":"not-a-uuid"}',     'a malformed category_id is rejected'),
  (17, '{"description":5}',                'description as a number is rejected'),
  (18, '{"brand":true}',                   'brand as a boolean is rejected'),
  (19, '{"sku":5}',                        'sku as a number is rejected'),
  (20, '{"unit_label":[]}',                'unit_label as an array is rejected'),
  (21, '{"sku":"bad sku"}',                'a SKU with a space is rejected'),
  (22, '{"price_cents":2500}',             'raising the price above the stored compare-at price is rejected (cross-field check on the effective values)'),
  (23, '{"compare_at_price_cents":1000}',  'a compare-at below the stored price is rejected'),
  (24, '{"price_cents":3000,"compare_at_price_cents":2999}', 'new price above new compare-at is rejected')
) as v(n, patch, label);
select pg_temp.upbad('v_25', pg_temp.p(1), format('{"name":%s}', to_json(repeat('n', 201))), 'VALIDATION: a 201-character name is rejected');
select pg_temp.upbad('v_26', pg_temp.p(1), format('{"description":%s}', to_json(repeat('d', 4001))), 'VALIDATION: a 4001-character description is rejected');
select pg_temp.upx('v_27', pg_temp.p(1), format('{"category_id":"%s"}', '00000000-0000-4000-8000-6c7fffffffff'), 'P0001', 'category_not_found',
  'VALIDATION: an unknown category_id is rejected (category_not_found)');
select pg_temp.ok(pg_temp.row_hash(pg_temp.p(1)) = (select h from t_h where k = 'p1_before_bad'),
  'VALIDATION: after all the rejected patches p1 is byte-for-byte unchanged');

-- Cross-field acceptance on the effective values
select pg_temp.up('x1', 'authenticated', pg_temp.u(3), pg_temp.p(1), '{"price_cents":2500,"compare_at_price_cents":2500}');
select pg_temp.succeeded('x1', 'VALIDATION: raising the price together with the compare-at price is accepted');
select pg_temp.up('x2', 'authenticated', pg_temp.u(3), pg_temp.p(1), '{"compare_at_price_cents":null}');
select pg_temp.ok(pg_temp.j('x2') -> 'product' -> 'compare_at_price_cents' = 'null'::jsonb
  and (pg_temp.j('x2') -> 'product' ->> 'price_cents')::integer = 2500,
  'VALIDATION: compare-at can be cleared on its own; the price stays');

-- Duplicates on update; atomic
insert into t_h values ('p3_before_dup', pg_temp.row_hash(pg_temp.p(3)));
select pg_temp.upx('d1', pg_temp.p(3), '{"slug":"t6c1b-full"}', '23505', 'slug_taken', 'UNIQUE: updating to another product''s slug is rejected (slug_taken)');
select pg_temp.upx('d2', pg_temp.p(3), '{"sku":"T6C1B-FULL"}', '23505', 'sku_taken', 'UNIQUE: updating to another product''s SKU is rejected (sku_taken)');
select pg_temp.upx('d3', pg_temp.p(3), '{"name":"Should Not Stick","slug":"t6c1b-full"}', '23505', 'slug_taken', 'UNIQUE: a patch that includes a duplicate slug is rejected as a whole');
select pg_temp.ok(pg_temp.row_hash(pg_temp.p(3)) = (select h from t_h where k = 'p3_before_dup'),
  'UNIQUE: the product is unchanged after the rejected duplicate updates (nothing partially applied)');

-- ===========================================================================
-- D. FUNCTION METADATA, ACL, SECURITY DEFINER, search_path, gate placement
-- ===========================================================================
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_create_product') = 1
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_update_product') = 1,
  'META: exactly one admin_create_product and one admin_update_product exist (no overloads)');
select pg_temp.ok(
  (select bool_and(prosecdef) from pg_proc
   where oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                 'public.admin_update_product(uuid,jsonb)'::regprocedure)),
  'META: both functions are SECURITY DEFINER');
select pg_temp.ok(
  (select bool_and(provolatile = 'v') from pg_proc
   where oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                 'public.admin_update_product(uuid,jsonb)'::regprocedure)),
  'META: both functions are VOLATILE (they write)');
select pg_temp.ok(
  (select bool_and(proconfig::text like '%search_path=public, pg_temp%' and array_length(proconfig, 1) = 1) from pg_proc
   where oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                 'public.admin_update_product(uuid,jsonb)'::regprocedure)),
  'META: search_path is pinned to exactly "public, pg_temp" on both (and nothing else is set)');
select pg_temp.ok(
  pg_get_function_result('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure) = 'jsonb'
  and pg_get_function_result('public.admin_update_product(uuid,jsonb)'::regprocedure) = 'jsonb'
  and (select proargnames::text from pg_proc where oid = 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure)
        = '{p_name,p_slug,p_price_cents,p_category_id,p_description,p_brand,p_sku,p_unit_label,p_compare_at_price_cents}'
  and (select pronargdefaults from pg_proc where oid = 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure) = 6
  and (select proargnames::text from pg_proc where oid = 'public.admin_update_product(uuid,jsonb)'::regprocedure) = '{p_product_id,p_changes}'
  and (select pronargdefaults from pg_proc where oid = 'public.admin_update_product(uuid,jsonb)'::regprocedure) = 0,
  'META: signatures are admin_create_product(p_name, p_slug, p_price_cents + 6 optional) and admin_update_product(p_product_id, p_changes), both returning jsonb');

-- require_admin() is in both bodies, and runs before any argument is examined
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('p_price_cents is null' in prosrc)
      and position('public.require_admin()' in prosrc) < position('btrim(' in prosrc)
   from pg_proc where oid = 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure),
  'GATE: admin_create_product calls public.require_admin() before it validates anything');
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('p_product_id is null' in prosrc)
      and position('public.require_admin()' in prosrc) < position('for update' in prosrc)
   from pg_proc where oid = 'public.admin_update_product(uuid,jsonb)'::regprocedure),
  'GATE: admin_update_product calls public.require_admin() before it validates or locks anything');
select pg_temp.ok(
  (select prosrc !~* '(is_admin|is_staff|has_role|user_roles|auth\.jwt|auth\.role)'
   from pg_proc where oid = 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure)
  and (select prosrc !~* '(is_admin|is_staff|has_role|user_roles|auth\.jwt|auth\.role)'
   from pg_proc where oid = 'public.admin_update_product(uuid,jsonb)'::regprocedure),
  'GATE: no second authorization mechanism - neither body checks roles or JWT claims itself');
select pg_temp.ok(
  (select prosrc ~* 'for\s+update' from pg_proc where oid = 'public.admin_update_product(uuid,jsonb)'::regprocedure),
  'LOCK: admin_update_product locks the product row (SELECT ... FOR UPDATE) before changing it');

-- Structural proof that no future-phase column or table is touched by the bodies
select pg_temp.ok(
  (select bool_and(
     prosrc !~* 'insert\s+into\s+(public\.)?products\s*\([^)]*(stock_quantity|in_stock|is_active|image_url)'
     and prosrc !~* '(set|,)\s*(stock_quantity|in_stock|is_active|image_url|created_at|updated_at)\s*='
     and prosrc !~* '(insert\s+into|update|delete\s+from)\s+(public\.)?(product_variants|categories|orders|order_items|user_roles|profiles)\M'
     and prosrc !~* '(delete\s+from|truncate)')
   from pg_proc where oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                              'public.admin_update_product(uuid,jsonb)'::regprocedure)),
  'STRUCTURE: neither body assigns stock_quantity / in_stock / is_active / image_url, touches variants, categories, orders or roles, or deletes anything');
select pg_temp.ok(
  (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('admin_create_product', 'admin_update_product')
     and p.prosrc ~* '(insert\s+into|update)\s+(public\.)?products\M') = 2,
  'STRUCTURE: both new functions write public.products (and only it)');

-- EXECUTE ACL
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_update_product(uuid,jsonb)', 'EXECUTE'),
  'ACL: anon has no EXECUTE on either function');
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_update_product(uuid,jsonb)', 'EXECUTE'),
  'ACL: authenticated has EXECUTE on both (the gate then restricts them to admins)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                    'public.admin_update_product(uuid,jsonb)'::regprocedure)
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'ACL: PUBLIC has no EXECUTE on either function');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(p.proacl) a
    where p.oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                    'public.admin_update_product(uuid,jsonb)'::regprocedure)
      and a.grantee not in (p.proowner, (select oid from pg_roles where rolname = 'authenticated'),
                            coalesce((select oid from pg_roles where rolname = 'service_role'), -1))),
  'ACL: EXECUTE is held only by the owner, authenticated and (Supabase default) service_role');
select pg_temp.ok(
  (select count(*) from pg_proc p where p.oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                                                  'public.admin_update_product(uuid,jsonb)'::regprocedure)
     and p.proacl is not null) = 2,
  'ACL: both functions carry an explicit ACL (not the implicit default)');
select pg_temp.ok(
  (select bool_and(r.rolname not in ('anon', 'authenticated', 'service_role'))
   from pg_proc p join pg_roles r on r.oid = p.proowner
   where p.oid in ('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)'::regprocedure,
                   'public.admin_update_product(uuid,jsonb)'::regprocedure)),
  'ACL: both functions are owned by a privileged owner role, not by a browser role');
select pg_temp.ok(not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'ACL: require_admin() is still not callable directly by anon or authenticated');
select pg_temp.run('g_ra1', 'authenticated', pg_temp.u(3), 'select public.require_admin()::text');
select pg_temp.no_execute('g_ra1', 'ACL: even an admin cannot call require_admin() directly');

-- No browser write privilege on the catalogue (the RPCs are the only write path)
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)),
  'PRIV: anon/authenticated hold no INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER on products, product_variants, categories (no direct INSERT or UPDATE was introduced)');
select pg_temp.ok(not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl)
    where has_any_column_privilege(r.role, t.tbl, 'INSERT') or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'PRIV: no column-level INSERT/UPDATE privilege for anon/authenticated on any catalogue table');
select pg_temp.ok(has_table_privilege('authenticated', 'public.products', 'SELECT')
  and has_table_privilege('anon', 'public.products', 'SELECT'),
  'PRIV: storefront SELECT on products is unchanged (anon and authenticated)');
select pg_temp.ok((select count(*) from pg_class
                   where oid in ('public.products'::regclass, 'public.product_variants'::regclass, 'public.categories'::regclass)
                     and relrowsecurity) = 3,
  'RLS: row level security is still enabled on products, product_variants and categories');
select pg_temp.ok(
  (select array_agg(tablename || ':' || policyname order by tablename, policyname)
   from pg_policies where schemaname = 'public' and tablename in ('products', 'product_variants', 'categories'))
  = array['categories:Categories: admin read all', 'categories:Categories: public read active',
          'product_variants:Variants: admin read all', 'product_variants:Variants: public read active',
          'products:Products: admin read all', 'products:Products: public read active'],
  'RLS: the catalogue policy set is exactly the six existing read policies (this phase added none)');

-- Actual direct write attempts by every browser role are still blocked
select pg_temp.run('w_a1', 'authenticated', pg_temp.u(3), $$with u as (update public.products set name = 'T6C1B hacked' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_a2', 'authenticated', pg_temp.u(3), $$with i as (insert into public.products (slug, name) values ('t6c1b-direct', 'T6C1B direct') returning 1) select count(*)::text from i$$);
select pg_temp.run('w_a3', 'authenticated', pg_temp.u(3), $$with d as (delete from public.products returning 1) select count(*)::text from d$$);
select pg_temp.run('w_s1', 'authenticated', pg_temp.u(2), $$with u as (update public.products set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_s2', 'authenticated', pg_temp.u(2), $$with i as (insert into public.products (slug, name) values ('t6c1b-direct-s', 'x') returning 1) select count(*)::text from i$$);
select pg_temp.run('w_c1', 'authenticated', pg_temp.u(1), $$with u as (update public.products set is_active = false returning 1) select count(*)::text from u$$);
select pg_temp.run('w_c2', 'authenticated', pg_temp.u(1), $$with i as (insert into public.products (slug, name) values ('t6c1b-direct-c', 'x') returning 1) select count(*)::text from i$$);
select pg_temp.run('w_n1', 'anon', null, $$with u as (update public.products set name = 'x' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_n2', 'anon', null, $$with i as (insert into public.products (slug, name) values ('t6c1b-direct-n', 'x') returning 1) select count(*)::text from i$$);
select pg_temp.write_denied('w_a1', 'WRITE: admin cannot UPDATE products directly (the RPC is the only path)');
select pg_temp.write_denied('w_a2', 'WRITE: admin cannot INSERT products directly (the RPC is the only path)');
select pg_temp.write_denied('w_a3', 'WRITE: admin cannot DELETE products');
select pg_temp.write_denied('w_s1', 'WRITE: staff cannot UPDATE products directly');
select pg_temp.write_denied('w_s2', 'WRITE: staff cannot INSERT products directly');
select pg_temp.write_denied('w_c1', 'WRITE: customer cannot UPDATE products directly');
select pg_temp.write_denied('w_c2', 'WRITE: customer cannot INSERT products directly');
select pg_temp.write_denied('w_n1', 'WRITE: anon cannot UPDATE products');
select pg_temp.write_denied('w_n2', 'WRITE: anon cannot INSERT products');

-- Triggers on the catalogue: still only the existing updated_at one; no inventory tables
select pg_temp.ok(not exists (
    select 1 from pg_trigger t
    where not t.tgisinternal and t.tgrelid in ('public.products'::regclass, 'public.product_variants'::regclass, 'public.categories'::regclass)
      and t.tgfoid::regproc::text not in ('set_updated_at', 'public.set_updated_at', 'inventory_log_stock_change', 'public.inventory_log_stock_change')),
  'TRIGGERS: the catalogue tables carry no trigger other than the existing updated_at one (this phase added none)');
select pg_temp.ok(not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
                              and c.relname ~* '(inventor|stock)' and c.relname <> 'inventory_adjustments'),
  'INVENTORY: no inventory / stock-movement / history table exists except the 6C.2.2A.1 audit table inventory_adjustments (which is not a stock source; see phase6c2_inventory_adjustment_history.test.sql)');

-- The only product-named functions in public: the two readers + the two writers of THIS phase
select pg_temp.ok((select array_agg(proname::text order by proname::text) from pg_proc
                   where pronamespace = 'public'::regnamespace
                     and (proname ilike '%product%' or proname ilike '%variant%' or proname ilike '%categor%'
                          or proname ilike '%sku%' or proname ilike '%inventor%'))
  = array['admin_adjust_inventory', 'admin_create_category', 'admin_create_product', 'admin_create_product_variant', 'admin_get_inventory', 'admin_get_product',
                'admin_list_inventory', 'admin_list_inventory_adjustments', 'admin_list_products',
                'admin_set_category_image', 'admin_set_product_active', 'admin_set_product_image', 'admin_update_category', 'admin_update_product', 'admin_update_product_variant',
                'inventory_adjustments_guard', 'inventory_log_stock_change', 'inventory_order_ctx_clear', 'inventory_order_ctx_set'],
  'FUNCS: the only product / variant / category / SKU / inventory-named functions in public are the two readers, the two functions of this phase, the three of 6C.1B.2 and the two read functions of 6C.2.1 and the 6C.2.2A.2 admin_adjust_inventory and the 6C.2.2B.1 admin_list_inventory_adjustments reader and the four Phase 9B inventory_* trigger functions (no other stock, category or delete function exists)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('admin_list_products', 'admin_get_product')
      and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(public\.)?(products|product_variants|categories)\M'),
  'FUNCS: the two readers from 6C.1A still write nothing');

-- ===========================================================================
-- E. REGRESSION - earlier phases still behave
-- ===========================================================================
-- 6C.1A.1 / 6C.1A.2: reads (and they see what the new functions wrote)
select pg_temp.run('r_list', 'authenticated', pg_temp.u(3), $$select public.admin_list_products(p_search => 't6c1b-created', p_limit => 10)::text$$);
select pg_temp.ok(
  (pg_temp.j('r_list') ->> 'total')::integer = 1
  and pg_temp.keys(pg_temp.j('r_list')) = 'limit,offset,products,total'
  and pg_temp.j('r_list') -> 'products' -> 0 ->> 'slug' = 't6c1b-created'
  and pg_temp.j('r_list') -> 'products' -> 0 = pg_temp.row_json((pg_temp.j('b1') -> 'product' ->> 'id')::uuid),
  'REGRESSION 6C.1A.1/2: admin_list_products still works, keeps its result shape and finds the product created by admin_create_product');
select pg_temp.run('r_list_in', 'authenticated', pg_temp.u(3), $$select public.admin_list_products(p_search => 't6c1b-inactive', p_is_active => false, p_limit => 10)::text$$);
select pg_temp.ok((pg_temp.j('r_list_in') ->> 'total')::integer = 1
  and pg_temp.j('r_list_in') -> 'products' -> 0 ->> 'id' = pg_temp.p(2)::text,
  'REGRESSION 6C.1A.2: the search + is_active filter still finds the inactive fixture');
select pg_temp.run('r_cat', 'authenticated', pg_temp.u(3), format($$select public.admin_list_products(p_category_id => %L, p_limit => 100)::text$$, pg_temp.c(1)));
select pg_temp.ok((pg_temp.j('r_cat') ->> 'total')::integer >= 1
  and exists (select 1 from jsonb_array_elements(pg_temp.j('r_cat') -> 'products') e where e ->> 'id' = (pg_temp.j('b1') -> 'product' ->> 'id')),
  'REGRESSION 6C.1A.2: the category filter finds the product created in that category');
select pg_temp.run('r_get', 'authenticated', pg_temp.u(3), format($$select public.admin_get_product(%L)::text$$, (pg_temp.j('b1') -> 'product' ->> 'id')::uuid));
select pg_temp.ok(pg_temp.keys(pg_temp.j('r_get')) = 'category,product,variants'
  and pg_temp.j('r_get') -> 'product' = pg_temp.row_json((pg_temp.j('b1') -> 'product' ->> 'id')::uuid)
  and pg_temp.j('r_get') -> 'category' ->> 'id' = pg_temp.c(1)::text
  and jsonb_array_length(pg_temp.j('r_get') -> 'variants') = 0,
  'REGRESSION 6C.1A.2: admin_get_product still returns { product, category, variants } for a product created by admin_create_product');
select pg_temp.run('r_get_nf', 'authenticated', pg_temp.u(3), $$select public.admin_get_product('00000000-0000-4000-8000-6c6fffffffff')::text$$);
select pg_temp.expect_err('r_get_nf', 'P0001', 'product_not_found', 'REGRESSION 6C.1A.2: admin_get_product still reports product_not_found');
select pg_temp.run('r_list_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_products()::text');
select pg_temp.gated('r_list_s', 'REGRESSION 6C.1A.1: admin_list_products still refuses staff');
select pg_temp.run('r_list_a', 'anon', null, 'select public.admin_list_products()::text');
select pg_temp.no_execute('r_list_a', 'REGRESSION 6C.1A.1: admin_list_products still refuses anon');
select pg_temp.run('r_get_c', 'authenticated', pg_temp.u(1), format($$select public.admin_get_product(%L)::text$$, pg_temp.p(1)));
select pg_temp.gated('r_get_c', 'REGRESSION 6C.1A.2: admin_get_product still refuses a customer');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_product(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_get_product(uuid)', 'EXECUTE')
  and (select bool_and(prosecdef and provolatile = 's' and proconfig::text like '%search_path=public, pg_temp%') from pg_proc
       where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure, 'public.admin_get_product(uuid)'::regprocedure)),
  'REGRESSION 6C.1A: the read functions keep their STABLE SECURITY DEFINER, pinned search_path and ACL');

-- Storefront visibility is still RLS-driven
select pg_temp.run('s_anon', 'anon', null, $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b-%'$$);
select pg_temp.ok(
  pg_temp.res('s_anon') = (select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b-%' and is_active)
  and pg_temp.res('s_anon') not like '%t6c1b-inactive%',
  'REGRESSION: anon still sees exactly the ACTIVE fixture products (existing public RLS unchanged; the inactive one stays hidden)');
select pg_temp.run('s_admin', 'authenticated', pg_temp.u(3), $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b-%'$$);
select pg_temp.ok(pg_temp.res('s_admin') = (select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b-%')
  and pg_temp.res('s_admin') like '%t6c1b-inactive%',
  'REGRESSION 6A: the admin read-all policy still shows inactive products directly');

-- 6B.2: the admin order action invariants
select pg_temp.ok(
  -- Later phases added admin functions (6G.4A payment readers; 6I.1 audit-log reader + 2 trigger functions);
  -- 6G.3 payment writers update only orders.payment_status. Compared bytewise (collate "C").
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
    = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[]
  and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                  and (proname ~* '(mark|set).*(paid|refund)' or proname ~* 'admin.*(payment|refund)')
                  and proname !~ '^admin_(get|list)_(payment|refund)'),  -- read-only 6G.4A readers are allowed; any writer is not
  'REGRESSION 6B.2: the admin API is exactly the fifteen known functions (admin_list_inventory_adjustments from 6C.2.2B.1 + admin_adjust_inventory from 6C.2.2A.2 + six from 6A-6C.1A + the two of this phase + the three of 6C.1B.2 + the two inventory readers of 6C.2.1); no payment or refund writer exists');
select pg_temp.ok(
  (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'update\s+(public\.)?orders(\s+[a-z_]+)?\s+set\s+status\M') = array['set_order_status']
  and (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* 'set_order_status\s*\(') = array['admin_set_order_status'],
  'REGRESSION 6B.2: structurally ONE status writer - only set_order_status() updates orders, and only admin_set_order_status() calls it');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_set_order_status') = 1
  and (select position('public.require_admin()' in prosrc) > 0 from pg_proc
       where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure)
  and not has_function_privilege('anon', 'public.admin_set_order_status(uuid,public.order_status,text,boolean)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_set_order_status(uuid,public.order_status,text,boolean)', 'EXECUTE')
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'set_order_status') = 1
  and not has_function_privilege('anon', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE'),
  'REGRESSION 6B.2: admin_set_order_status still gates with require_admin(), keeps its ACL, and set_order_status() is still the single engine');
select pg_temp.run('r_sos_c', 'authenticated', pg_temp.u(1), $$select public.admin_set_order_status('00000000-0000-4000-8000-6c4fffffffff', 'pending', null, false)::text$$);
select pg_temp.gated('r_sos_c', 'REGRESSION 6B.2: admin_set_order_status still refuses a customer');
select pg_temp.run('r_sos_s', 'authenticated', pg_temp.u(2), $$select public.admin_set_order_status('00000000-0000-4000-8000-6c4fffffffff', 'pending', null, false)::text$$);
select pg_temp.gated('r_sos_s', 'REGRESSION 6B.2: admin_set_order_status still refuses staff (staff is not admin)');
select pg_temp.run('r_sos_a', 'authenticated', pg_temp.u(3), $$select public.admin_set_order_status('00000000-0000-4000-8000-6c4fffffffff', 'pending', null, false)::text$$);
select pg_temp.ok((select state from t_res where k = 'r_sos_a') is distinct from '42501',
  'REGRESSION 6B.2: an admin passes the gate of admin_set_order_status (any error is about the unknown order, not authorization)');

-- 6B.1: admin orders read
select pg_temp.run('r_ord', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('r_ord', 'REGRESSION 6B.1: admin_list_orders still works for an admin');
select pg_temp.run('r_ord_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_orders()::text');
select pg_temp.gated('r_ord_s', 'REGRESSION 6B.1: admin_list_orders still refuses staff');
select pg_temp.run('r_ord_a', 'anon', null, 'select public.admin_list_orders()::text');
select pg_temp.no_execute('r_ord_a', 'REGRESSION 6B.1: admin_list_orders still refuses anon');
select pg_temp.run('r_go', 'authenticated', pg_temp.u(3), $$select public.admin_get_order('00000000-0000-4000-8000-6c4fffffffff')::text$$);
select pg_temp.expect_err('r_go', 'P0001', 'order_not_found', 'REGRESSION 6B.1: admin_get_order still reports order_not_found for an admin');
select pg_temp.run('r_go_c', 'authenticated', pg_temp.u(1), $$select public.admin_get_order('00000000-0000-4000-8000-6c4fffffffff')::text$$);
select pg_temp.gated('r_go_c', 'REGRESSION 6B.1: admin_get_order still refuses a customer');

-- 6A: dashboard + gate
select pg_temp.run('r_dash', 'authenticated', pg_temp.u(3), 'select public.admin_dashboard_summary()::text');
select pg_temp.succeeded('r_dash', 'REGRESSION 6A: admin_dashboard_summary still works for an admin');
select pg_temp.run('r_dash_c', 'authenticated', pg_temp.u(1), 'select public.admin_dashboard_summary()::text');
select pg_temp.gated('r_dash_c', 'REGRESSION 6A: admin_dashboard_summary still refuses a customer');
select pg_temp.run('r_dash_n', 'anon', null, 'select public.admin_dashboard_summary()::text');
select pg_temp.no_execute('r_dash_n', 'REGRESSION 6A: admin_dashboard_summary still refuses anon');
select pg_temp.ok(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT'
     and policyname in ('Products: admin read all','Variants: admin read all','Categories: admin read all','Profiles: admin read all')) = 4
  ,
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
select pg_temp.run('r_anon_staff', 'anon', null, $q$select public.is_staff('00000000-0000-4000-8000-6c5000000003')::text$q$);
select pg_temp.expect_err('r_anon_staff', '42501', null, 'REGRESSION 5B.2: anon still cannot call is_staff()');
select pg_temp.run('r_anon_role', 'anon', null, $q$select public.has_role('00000000-0000-4000-8000-6c5000000003','admin')::text$q$);
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
do $$ begin raise notice 'ALL PHASE 6C.1B.1 TESTS PASSED'; end $$;

rollback;
