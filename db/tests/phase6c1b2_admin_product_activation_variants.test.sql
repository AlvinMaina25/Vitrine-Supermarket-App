-- =============================================================================
-- PHASE 6C.1B.2 database test: admin product activation + product variants (create / update).
--
-- STATUS: written for migration 20261004070000_phase6c1b2_admin_product_activation_variants.sql.
-- NOT run against any database when it was written (no PostgreSQL was available); see the report.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004070000_phase6c1b2_admin_product_activation_variants.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c1b2_admin_product_activation_variants.test.sql
--
-- (Supabase SQL Editor: paste the whole file and Run. The editor shows only the last result, so
-- an empty "ok" row with no error means every check passed; any failure raises "FAIL: <name>".)
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.1B.2 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST. Authorization is the
-- REAL public.require_admin() / public.user_roles; nothing is faked.
--
-- NOT-EMPTY PROOF: every refusal is asserted as an ERROR (42501), never as "0 rows", and is
-- followed by a positive control in which the admin succeeds with the same kind of arguments.
-- Hashes of the products / product_variants tables prove refused calls wrote nothing.
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them: every write targets fixture rows (slug 't6c1b2-*'), and the whole run
-- is rolled back.
--
-- NOTE: the older tests db/tests/phase6b2, phase6c1a1, phase6c1a2 and phase6c1b1 contain exact
-- allow-lists of admin / product-named functions. They were updated (test-only) to include the three
-- functions of this phase, so run THEM after applying this migration, not before.
--
-- COVERS (numbering follows the phase brief)
--   A  1-10   authorization: admin ok; staff / customer / anon / signed-out / forged / service_role refused
--   B  11-17  product activation: only is_active changes; stock / in_stock / variants untouched; not found
--   C  18-25  variant create: shape, parent, required fields, uniqueness, no stock / inventory input
--   D  26-33  variant update: shape, patch semantics, unsupported fields, stock / product immutable
--   E  34-40  function security: SECURITY DEFINER, search_path, require_admin, ACL, no table privileges
--   F  41-48  regression: 6C.1B.1, 6C.1A.2, 6C.1A.1, 6B.2, 6B.1, 6A, 5B.2, 5A.2
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
  select ('00000000-0000-4000-8000-6c800000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c9000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6ca000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.c(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6cb000000' || lpad(n::text, 3, '0'))::uuid $$;

-- The 16 public.products columns of one row, as the RPCs return them (owner view, no role switch).
create or replace function pg_temp.row_json(p_id uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p.id, 'slug', p.slug, 'name', p.name, 'category_id', p.category_id,
    'description', p.description, 'brand', p.brand, 'sku', p.sku, 'image_url', p.image_url,
    'price_cents', p.price_cents, 'compare_at_price_cents', p.compare_at_price_cents,
    'unit_label', p.unit_label, 'stock_quantity', p.stock_quantity, 'in_stock', p.in_stock,
    'is_active', p.is_active, 'created_at', p.created_at, 'updated_at', p.updated_at)
  from public.products p where p.id = p_id $$;

-- The 12 public.product_variants columns of one row, as the RPCs return them.
create or replace function pg_temp.var_json(p_id uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'id', v.id, 'product_id', v.product_id, 'name', v.name, 'sku', v.sku,
    'price_cents', v.price_cents, 'compare_at_price_cents', v.compare_at_price_cents,
    'stock_quantity', v.stock_quantity, 'attributes', v.attributes, 'position', v.position,
    'is_active', v.is_active, 'created_at', v.created_at, 'updated_at', v.updated_at)
  from public.product_variants v where v.id = p_id $$;

-- Hashes (to prove "nothing was written").
create or replace function pg_temp.prod_hash() returns text language sql as $$
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p $$;
create or replace function pg_temp.var_hash() returns text language sql as $$
  select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v $$;
create or replace function pg_temp.vrow_hash(p_id uuid) returns text language sql as $$
  select md5(v::text) from public.product_variants v where v.id = p_id $$;
-- All variants of one product (to prove activation / other variants do not touch them).
create or replace function pg_temp.pvar_hash(p_id uuid) returns text language sql as $$
  select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v where v.product_id = p_id $$;
-- Every product row EXCEPT one (to prove a call touched only its own target).
create or replace function pg_temp.prod_hash_except(p_id uuid) returns text language sql as $$
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p where p.id <> p_id $$;
-- The inventory columns of the fixtures (variant stock; product stock + in_stock).
create or replace function pg_temp.stock_hash() returns text language sql as $$
  select md5(
    coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text, '|' order by v.id)
              from public.product_variants v where v.id in (pg_temp.v(1), pg_temp.v(2), pg_temp.v(3))), '')
    || '#' ||
    coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text, '|' order by p.id)
              from public.products p where p.id in (pg_temp.p(1), pg_temp.p(2), pg_temp.p(3))), '')) $$;

create temp table t_h (k text primary key, h text);
create temp table t_snap (k text primary key, j jsonb);

-- admin_set_product_active(id, flag) as a role.
create or replace function pg_temp.act(p_k text, p_role text, p_uid uuid, p_id uuid, p_flag boolean)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    format('select public.admin_set_product_active(%L::uuid, %L::boolean)::text', p_id, p_flag));
end;
$$;
create or replace function pg_temp.actx(p_k text, p_id uuid, p_flag boolean, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.act(p_k, 'authenticated', pg_temp.u(3), p_id, p_flag);
  perform pg_temp.expect_err(p_k, p_state, p_detail, p_name);
end;
$$;

-- admin_create_product_variant(<named args>) as a role. va() prepends a valid parent product id.
create or replace function pg_temp.va(p_rest text) returns text language sql as $$
  select format('p_product_id => %L, %s', pg_temp.p(1), p_rest) $$;
create or replace function pg_temp.mv(p_k text, p_role text, p_uid uuid, p_args text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_create_product_variant(' || p_args || ')::text');
end;
$$;
create or replace function pg_temp.mvx(p_k text, p_args text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.mv(p_k, 'authenticated', pg_temp.u(3), p_args);
  perform pg_temp.expect_err(p_k, p_state, p_detail, p_name);
end;
$$;
create or replace function pg_temp.mvbad(p_k text, p_args text, p_name text) returns void language sql as $$
  select pg_temp.mvx(p_k, p_args, 'P0001', 'invalid_arguments', p_name) $$;

-- admin_update_product_variant(id, patch) as a role.
create or replace function pg_temp.uv(p_k text, p_role text, p_uid uuid, p_id uuid, p_patch text)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    format('select public.admin_update_product_variant(%L::uuid, %L::jsonb)::text', p_id, p_patch));
end;
$$;
create or replace function pg_temp.uvx(p_k text, p_id uuid, p_patch text, p_state text, p_detail text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.uv(p_k, 'authenticated', pg_temp.u(3), p_id, p_patch);
  perform pg_temp.expect_err(p_k, p_state, p_detail, p_name);
end;
$$;
create or replace function pg_temp.uvbad(p_k text, p_id uuid, p_patch text, p_name text) returns void language sql as $$
  select pg_temp.uvx(p_k, p_id, p_patch, 'P0001', 'invalid_arguments', p_name) $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c1b2-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C1B2 Customer"}'),
  (pg_temp.u(2), 't6c1b2-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C1B2 Staff"}'),
  (pg_temp.u(3), 't6c1b2-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C1B2 Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

insert into public.categories (id, slug, name, is_active) values
  (pg_temp.c(1), 't6c1b2-cat', 'T6C1B2 Category', true);

insert into public.products
  (id, slug, name, category_id, description, brand, sku, image_url, price_cents,
   compare_at_price_cents, unit_label, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1), 't6c1b2-full', 'T6C1B2 Full', pg_temp.c(1), 'Full description', 'Brand A', 'T6C1B2-FULL',
   'https://example.test/full.png', 1500, 1800, '1 kg', 12, true, true),
  (pg_temp.p(2), 't6c1b2-inactive', 'T6C1B2 Inactive', null, null, null, 'T6C1B2-INACT',
   null, 700, null, null, 0, false, false),
  (pg_temp.p(3), 't6c1b2-other', 'T6C1B2 Other', null, null, null, 'T6C1B2-OTHER',
   null, 100, null, null, 5, true, true);

insert into public.product_variants
  (id, product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity, attributes, position, is_active)
values
  (pg_temp.v(1), pg_temp.p(1), 'T6C1B2 V1', 'T6C1B2-V1', 1500, 1800, 9, '{"size":"1kg"}', 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6C1B2 V2', 'T6C1B2-V2',  900, null, 3, '{}',              2, true),
  (pg_temp.v(3), pg_temp.p(3), 'T6C1B2 V3', 'T6C1B2-V3',  400, null, 4, '{"pack":"6"}',    1, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c1b2-%') = 3
  and (select count(*) from public.product_variants where id in (pg_temp.v(1), pg_temp.v(2), pg_temp.v(3))) = 3,
  'FIXTURE: three test products (full, inactive, other) and three variants exist');

insert into t_h values
  ('prod0', pg_temp.prod_hash()),
  ('var0', pg_temp.var_hash()),
  ('stock0', pg_temp.stock_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')));

-- ===========================================================================
-- A. AUTHORIZATION (checks 1-10 of the brief)
--    Every refusal is an ERROR (42501), never "0 rows", uses VALID arguments (without the gate
--    it would succeed) and is followed by a positive control in which the admin succeeds.
-- ===========================================================================
-- STAFF
select pg_temp.act('a_s_act', 'authenticated', pg_temp.u(2), pg_temp.p(1), false);
select pg_temp.gated('a_s_act', 'STAFF cannot activate / deactivate a product (42501 / not_authorised)');
select pg_temp.mv('a_s_mv', 'authenticated', pg_temp.u(2), pg_temp.va($$p_name => 'T6C1B2 Staff Try', p_price_cents => 100$$));
select pg_temp.gated('a_s_mv', 'STAFF cannot create a variant (42501 / not_authorised)');
select pg_temp.uv('a_s_uv', 'authenticated', pg_temp.u(2), pg_temp.v(1), '{"name":"T6C1B2 Staff Rename"}');
select pg_temp.gated('a_s_uv', 'STAFF cannot update a variant (42501 / not_authorised)');
-- CUSTOMER
select pg_temp.act('a_c_act', 'authenticated', pg_temp.u(1), pg_temp.p(1), false);
select pg_temp.gated('a_c_act', 'CUSTOMER cannot activate / deactivate a product (42501 / not_authorised)');
select pg_temp.mv('a_c_mv', 'authenticated', pg_temp.u(1), pg_temp.va($$p_name => 'T6C1B2 Cust Try', p_price_cents => 100$$));
select pg_temp.gated('a_c_mv', 'CUSTOMER cannot create a variant (42501 / not_authorised)');
select pg_temp.uv('a_c_uv', 'authenticated', pg_temp.u(1), pg_temp.v(1), '{"name":"T6C1B2 Cust Rename"}');
select pg_temp.gated('a_c_uv', 'CUSTOMER cannot update a variant (42501 / not_authorised)');
-- ANON (even carrying the admin user id in its claims): refused before the function body runs
select pg_temp.act('a_a_act', 'anon', pg_temp.u(3), pg_temp.p(1), false);
select pg_temp.no_execute('a_a_act', 'ANON cannot execute admin_set_product_active (even carrying the admin user id)');
select pg_temp.mv('a_a_mv', 'anon', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Anon Try', p_price_cents => 100$$));
select pg_temp.no_execute('a_a_mv', 'ANON cannot execute admin_create_product_variant (even carrying the admin user id)');
select pg_temp.uv('a_a_uv', 'anon', pg_temp.u(3), pg_temp.v(1), '{"name":"T6C1B2 Anon Rename"}');
select pg_temp.no_execute('a_a_uv', 'ANON cannot execute admin_update_product_variant (even carrying the admin user id)');
-- SIGNED OUT (anon, no JWT)
select pg_temp.act('a_o_act', 'anon', null, pg_temp.p(1), false);
select pg_temp.no_execute('a_o_act', 'SIGNED OUT (anon, no JWT) cannot execute admin_set_product_active');
select pg_temp.mv('a_o_mv', 'anon', null, pg_temp.va($$p_name => 'T6C1B2 Out Try', p_price_cents => 100$$));
select pg_temp.no_execute('a_o_mv', 'SIGNED OUT (anon, no JWT) cannot execute admin_create_product_variant');
select pg_temp.uv('a_o_uv', 'anon', null, pg_temp.v(1), '{"name":"T6C1B2 Out Rename"}');
select pg_temp.no_execute('a_o_uv', 'SIGNED OUT (anon, no JWT) cannot execute admin_update_product_variant');
-- SIGNED OUT as the authenticated role (auth.uid() is null)
select pg_temp.act('a_n_act', 'authenticated', null, pg_temp.p(1), false);
select pg_temp.gated('a_n_act', 'SIGNED OUT (authenticated role, auth.uid() null): activation refused by the admin gate');
select pg_temp.mv('a_n_mv', 'authenticated', null, pg_temp.va($$p_name => 'T6C1B2 NoUid Try', p_price_cents => 100$$));
select pg_temp.gated('a_n_mv', 'SIGNED OUT (authenticated role, auth.uid() null): variant create refused by the admin gate');
select pg_temp.uv('a_n_uv', 'authenticated', null, pg_temp.v(1), '{"name":"T6C1B2 NoUid Rename"}');
select pg_temp.gated('a_n_uv', 'SIGNED OUT (authenticated role, auth.uid() null): variant update refused by the admin gate');
-- FORGED claims
select pg_temp.run_claims('a_f_act', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin'), 'is_admin', true),
  format($$select public.admin_set_product_active(%L::uuid, false)::text$$, pg_temp.p(1)));
select pg_temp.gated('a_f_act', 'FORGED: customer JWT with admin claims in every claim location is refused (activation)');
select pg_temp.run_claims('a_f_mv', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(2), 'role', 'service_role', 'admin', true),
  format($$select public.admin_create_product_variant(p_product_id => %L, p_name => 'T6C1B2 Forged', p_price_cents => 1)::text$$, pg_temp.p(1)));
select pg_temp.gated('a_f_mv', 'FORGED: staff JWT claiming role=service_role / admin=true is refused (variant create)');
select pg_temp.run_claims('a_f_uv', 'authenticated',
  jsonb_build_object('sub', '00000000-0000-4000-8000-6c8fffffffff', 'role', 'authenticated'),
  format($$select public.admin_update_product_variant(%L::uuid, '{"name":"T6C1B2 Ghost"}'::jsonb)::text$$, pg_temp.v(1)));
select pg_temp.gated('a_f_uv', 'FORGED: a well-formed JWT for a user id that does not exist is refused (variant update)');
-- SERVICE ROLE without an admin user
select pg_temp.act('a_v_act', 'service_role', null, pg_temp.p(1), false);
select pg_temp.gated('a_v_act', 'SERVICE ROLE without an admin user is refused by the gate (activation; no auth.uid())');
select pg_temp.mv('a_v_mv', 'service_role', null, pg_temp.va($$p_name => 'T6C1B2 Svc Try', p_price_cents => 100$$));
select pg_temp.gated('a_v_mv', 'SERVICE ROLE without an admin user is refused by the gate (variant create)');
select pg_temp.uv('a_v_uv', 'service_role', null, pg_temp.v(1), '{"name":"T6C1B2 Svc Rename"}');
select pg_temp.gated('a_v_uv', 'SERVICE ROLE without an admin user is refused by the gate (variant update)');

-- The gate runs BEFORE argument validation and BEFORE the existence check: a refused caller learns
-- nothing about the rules or about which rows exist.
select pg_temp.act('a_g1', 'authenticated', pg_temp.u(1), null, null);
select pg_temp.gated('a_g1', 'GATE ORDER: customer with a NULL product id and NULL flag gets not_authorised, not invalid_arguments');
select pg_temp.act('a_g2', 'authenticated', pg_temp.u(2), '00000000-0000-4000-8000-6c9fffffffff', true);
select pg_temp.gated('a_g2', 'GATE ORDER: staff with an unknown product id gets not_authorised (no existence leak)');
select pg_temp.mv('a_g3', 'authenticated', pg_temp.u(1), $$p_product_id => '00000000-0000-4000-8000-6c9fffffffff', p_name => null, p_price_cents => -5$$);
select pg_temp.gated('a_g3', 'GATE ORDER: customer with an unknown parent and invalid arguments gets not_authorised');
select pg_temp.uv('a_g4', 'authenticated', pg_temp.u(2), pg_temp.v(1), '{}');
select pg_temp.gated('a_g4', 'GATE ORDER: staff with an empty patch gets not_authorised, not invalid_arguments');
select pg_temp.uv('a_g5', 'authenticated', pg_temp.u(1), '00000000-0000-4000-8000-6cafffffffff', '{"stock_quantity":5}');
select pg_temp.gated('a_g5', 'GATE ORDER: customer with an unknown variant id and a forbidden key gets not_authorised (no existence leak)');
select pg_temp.uv('a_g6', 'authenticated', pg_temp.u(2), null, '{"name":"x"}');
select pg_temp.gated('a_g6', 'GATE ORDER: staff with a NULL variant id gets not_authorised');

select pg_temp.ok(pg_temp.prod_hash() = (select h from t_h where k = 'prod0')
  and pg_temp.var_hash() = (select h from t_h where k = 'var0'),
  'REFUSED CALLS WROTE NOTHING: a hash of every product row and every variant row is unchanged after all refused attempts');

-- Positive controls: the admin succeeds with the SAME kind of arguments that were refused above.
select pg_temp.act('a_adm_act', 'authenticated', pg_temp.u(3), pg_temp.p(3), true);
select pg_temp.succeeded('a_adm_act', 'ADMIN can call admin_set_product_active (positive control for the activation refusals above)');
select pg_temp.mv('a_adm_mv', 'authenticated', pg_temp.u(3), format($$p_product_id => %L, p_name => 'T6C1B2 Control', p_price_cents => 100, p_sku => 'T6C1B2-CTRL'$$, pg_temp.p(3)));
select pg_temp.succeeded('a_adm_mv', 'ADMIN can create a variant (positive control for the variant-create refusals above)');
select pg_temp.uv('a_adm_uv', 'authenticated', pg_temp.u(3), pg_temp.v(3), '{"name":"T6C1B2 V3"}');
select pg_temp.succeeded('a_adm_uv', 'ADMIN can update a variant (positive control for the variant-update refusals above)');

-- ===========================================================================
-- B. PRODUCT ACTIVATION (checks 11-17)
-- ===========================================================================
insert into t_snap values ('p1', pg_temp.row_json(pg_temp.p(1)));
insert into t_h values
  ('p1_vars', pg_temp.pvar_hash(pg_temp.p(1))),
  ('p_not1', pg_temp.prod_hash_except(pg_temp.p(1))),
  ('stock1', pg_temp.stock_hash());

select pg_temp.act('b1', 'authenticated', pg_temp.u(3), pg_temp.p(1), false);
select pg_temp.succeeded('b1', 'ACTIVATION: admin deactivates an active product');
select pg_temp.ok(pg_temp.keys(pg_temp.j('b1')) = 'product'
  and pg_temp.keys(pg_temp.j('b1') -> 'product')
      = 'brand,category_id,compare_at_price_cents,created_at,description,id,image_url,in_stock,is_active,name,price_cents,sku,slug,stock_quantity,unit_label,updated_at',
  'ACTIVATION: the result has exactly one key, "product", carrying the 16 public.products columns');
select pg_temp.ok((pg_temp.j('b1') -> 'product' ->> 'is_active')::boolean = false
  and (select not is_active from public.products where id = pg_temp.p(1)),
  'ACTIVATION: is_active is now false, in the result and in the table');
select pg_temp.ok(pg_temp.j('b1') -> 'product' = pg_temp.row_json(pg_temp.p(1)),
  'ACTIVATION: the returned JSONB is exactly the stored row');
select pg_temp.ok((pg_temp.row_json(pg_temp.p(1)) - 'is_active' - 'updated_at')
                  = ((select j from t_snap where k = 'p1') - 'is_active' - 'updated_at'),
  'DEACTIVATION changes ONLY is_active: every other product column (name, slug, SKU, price, category, image, stock, in_stock, ...) is identical');
select pg_temp.ok((select stock_quantity = 12 and in_stock from public.products where id = pg_temp.p(1))
  and pg_temp.stock_hash() = (select h from t_h where k = 'stock1'),
  'DEACTIVATION leaves stock_quantity and in_stock alone (product and variants)');
select pg_temp.ok(pg_temp.pvar_hash(pg_temp.p(1)) = (select h from t_h where k = 'p1_vars'),
  'DEACTIVATION leaves every variant of the product unchanged (a variant keeps its own is_active)');
select pg_temp.ok(pg_temp.prod_hash_except(pg_temp.p(1)) = (select h from t_h where k = 'p_not1'),
  'DEACTIVATION touches no other product');
select pg_temp.run('b_anon_off', 'anon', null, $$select count(*)::text from public.products where slug = 't6c1b2-full'$$);
select pg_temp.ok(pg_temp.res('b_anon_off') = '0',
  'DEACTIVATION is enforced by the existing RLS: anon no longer sees the product (the storefront policy is unchanged)');

select pg_temp.act('b2', 'authenticated', pg_temp.u(3), pg_temp.p(1), true);
select pg_temp.succeeded('b2', 'ACTIVATION: admin reactivates the product');
select pg_temp.ok((pg_temp.j('b2') -> 'product' ->> 'is_active')::boolean = true
  and pg_temp.j('b2') -> 'product' = pg_temp.row_json(pg_temp.p(1))
  and (pg_temp.row_json(pg_temp.p(1)) - 'updated_at') = ((select j from t_snap where k = 'p1') - 'updated_at'),
  'ACTIVATION changes ONLY is_active: after deactivate + reactivate every column is back to the original; the result is the stored row');
select pg_temp.ok(pg_temp.stock_hash() = (select h from t_h where k = 'stock1')
  and pg_temp.pvar_hash(pg_temp.p(1)) = (select h from t_h where k = 'p1_vars')
  and pg_temp.prod_hash_except(pg_temp.p(1)) = (select h from t_h where k = 'p_not1'),
  'ACTIVATION leaves stock, in_stock, every variant and every other product unchanged');
select pg_temp.run('b_anon_on', 'anon', null, $$select count(*)::text from public.products where slug = 't6c1b2-full'$$);
select pg_temp.ok(pg_temp.res('b_anon_on') = '1',
  'ACTIVATION makes the product visible to anon again through the unchanged storefront RLS');

-- An INACTIVE product with stock 0 / in_stock false: activation must not "fix" the inventory flags.
select pg_temp.act('b3', 'authenticated', pg_temp.u(3), pg_temp.p(2), true);
select pg_temp.succeeded('b3', 'ACTIVATION: admin activates an inactive product');
select pg_temp.ok((select is_active and stock_quantity = 0 and not in_stock from public.products where id = pg_temp.p(2)),
  'ACTIVATION does not alter inventory: stock_quantity stays 0 and in_stock stays false');
select pg_temp.act('b3b', 'authenticated', pg_temp.u(3), pg_temp.p(2), false);
select pg_temp.succeeded('b3b', 'ACTIVATION: admin deactivates it again');
select pg_temp.ok((select not is_active and stock_quantity = 0 and not in_stock from public.products where id = pg_temp.p(2)),
  'DEACTIVATION does not alter inventory either');

-- Asking for the value a product already has is a no-op: nothing is written (the row version is unchanged).
insert into t_h values ('xmin3', (select xmin::text from public.products where id = pg_temp.p(3)));
select pg_temp.act('b4', 'authenticated', pg_temp.u(3), pg_temp.p(3), true);
select pg_temp.succeeded('b4', 'ACTIVATION: activating an already-active product succeeds');
select pg_temp.ok(pg_temp.j('b4') -> 'product' = pg_temp.row_json(pg_temp.p(3))
  and (select xmin::text from public.products where id = pg_temp.p(3)) = (select h from t_h where k = 'xmin3'),
  'ACTIVATION: the unchanged value writes nothing (same row version) and the stored row is returned');

-- Validation
select pg_temp.actx('b_nf', '00000000-0000-4000-8000-6c9fffffffff', true, 'P0001', 'product_not_found',
  'ACTIVATION: a nonexistent product is rejected (P0001 / product_not_found)');
select pg_temp.actx('b_nullid', null, true, 'P0001', 'invalid_arguments',
  'ACTIVATION: a NULL product id is rejected (P0001 / invalid_arguments)');
select pg_temp.actx('b_nullflag', pg_temp.p(1), null, 'P0001', 'invalid_arguments',
  'ACTIVATION: a NULL flag is rejected (P0001 / invalid_arguments)');
select pg_temp.run('b_three', 'authenticated', pg_temp.u(3), format($$select public.admin_set_product_active(%L::uuid)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('b_three', '42883', null, 'ACTIVATION: the flag has no default (a call without it does not exist)');
select pg_temp.run('b_extra', 'authenticated', pg_temp.u(3), format($$select public.admin_set_product_active(%L::uuid, true, 50)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('b_extra', '42883', null, 'ACTIVATION: there is no third parameter (no stock value can be passed in)');
select pg_temp.ok(pg_temp.stock_hash() = (select h from t_h where k = 'stock1')
  and (select is_active from public.products where id = pg_temp.p(1)),
  'ACTIVATION: rejected calls changed nothing');

-- ===========================================================================
-- C. VARIANT CREATION (checks 18-25)
-- ===========================================================================
select pg_temp.mv('c1', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => '  T6C1B2 Large  ', p_price_cents => 2500,
  p_sku => '  T6C1B2-NEW  ', p_compare_at_price_cents => 3000, p_attributes => '{"size":"2kg","color":"red"}'::jsonb, p_position => 3$$));
select pg_temp.succeeded('c1', 'VARIANT CREATE: a valid variant is created');
select pg_temp.ok(pg_temp.keys(pg_temp.j('c1')) = 'variant'
  and pg_temp.keys(pg_temp.j('c1') -> 'variant')
      = 'attributes,compare_at_price_cents,created_at,id,is_active,name,position,price_cents,product_id,sku,stock_quantity,updated_at',
  'VARIANT CREATE: the result has exactly one key, "variant", carrying the 12 public.product_variants columns');
select pg_temp.ok(pg_temp.j('c1') -> 'variant' = pg_temp.var_json((pg_temp.j('c1') -> 'variant' ->> 'id')::uuid)
  and (select count(*) from public.product_variants where id = (pg_temp.j('c1') -> 'variant' ->> 'id')::uuid) = 1,
  'VARIANT CREATE: the returned JSONB is exactly the stored row (one row exists and every value matches)');
select pg_temp.ok(pg_temp.j('c1') -> 'variant' ->> 'product_id' = pg_temp.p(1)::text
  and (select product_id from public.product_variants where id = (pg_temp.j('c1') -> 'variant' ->> 'id')::uuid) = pg_temp.p(1),
  'VARIANT CREATE: the variant belongs to the specified parent product');
select pg_temp.ok(pg_temp.j('c1') -> 'variant' ->> 'name' = 'T6C1B2 Large'
  and pg_temp.j('c1') -> 'variant' ->> 'sku' = 'T6C1B2-NEW'
  and (pg_temp.j('c1') -> 'variant' ->> 'price_cents')::integer = 2500
  and (pg_temp.j('c1') -> 'variant' ->> 'compare_at_price_cents')::integer = 3000
  and pg_temp.j('c1') -> 'variant' -> 'attributes' = '{"size":"2kg","color":"red"}'::jsonb
  and (pg_temp.j('c1') -> 'variant' ->> 'position')::integer = 3,
  'VARIANT CREATE: the returned values are what was supplied (text trimmed, money stays integer cents)');
select pg_temp.ok((pg_temp.j('c1') -> 'variant' ->> 'stock_quantity')::integer = 0
  and (pg_temp.j('c1') -> 'variant' ->> 'is_active')::boolean = true
  and pg_temp.j('c1') -> 'variant' ->> 'id' is not null
  and pg_temp.j('c1') -> 'variant' ->> 'created_at' is not null,
  'VARIANT CREATE: stock_quantity (0) and is_active (true) are the TABLE DEFAULTS - the function sets neither');

select pg_temp.mv('c2', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Minimal', p_price_cents => 0$$));
select pg_temp.succeeded('c2', 'VARIANT CREATE: only product, name and price are required (price 0 is allowed, as the table allows it)');
select pg_temp.ok(jsonb_typeof(pg_temp.j('c2') -> 'variant' -> 'sku') = 'null'
  and jsonb_typeof(pg_temp.j('c2') -> 'variant' -> 'compare_at_price_cents') = 'null'
  and pg_temp.j('c2') -> 'variant' -> 'attributes' = '{}'::jsonb
  and (pg_temp.j('c2') -> 'variant' ->> 'position')::integer = 0
  and (pg_temp.j('c2') -> 'variant' ->> 'stock_quantity')::integer = 0
  and (pg_temp.j('c2') -> 'variant' ->> 'is_active')::boolean,
  'VARIANT CREATE: omitted optional fields come back as null / {} / 0 / table defaults');
select pg_temp.mv('c3', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Blank Sku', p_price_cents => 10, p_sku => '   '$$));
select pg_temp.succeeded('c3', 'VARIANT CREATE: a blank SKU is stored as NULL, so several variants without a SKU coexist (the SKU index is partial)');
select pg_temp.ok(jsonb_typeof(pg_temp.j('c3') -> 'variant' -> 'sku') = 'null',
  'VARIANT CREATE: the blank SKU came back as JSON null');
select pg_temp.mv('c4', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Equal', p_price_cents => 500, p_compare_at_price_cents => 500$$));
select pg_temp.succeeded('c4', 'VARIANT CREATE: compare_at_price_cents equal to the price is accepted (the constraint is >=)');
select pg_temp.mv('c5', 'authenticated', pg_temp.u(3), format($$p_product_id => %L, p_name => 'T6C1B2 On Inactive', p_price_cents => 10$$, pg_temp.p(2)));
select pg_temp.succeeded('c5', 'VARIANT CREATE: a variant can be added to an INACTIVE product (activation is independent)');
select pg_temp.ok(pg_temp.j('c5') -> 'variant' ->> 'product_id' = pg_temp.p(2)::text
  and (select not is_active from public.products where id = pg_temp.p(2)),
  'VARIANT CREATE: it attached to that product and did not activate it');

-- Required fields and validation (all as admin: each is refused for its own reason)
select pg_temp.mvbad('c_n1', pg_temp.va($$p_name => null, p_price_cents => 100$$), 'REQUIRED: a NULL name is rejected');
select pg_temp.mvbad('c_n2', pg_temp.va($$p_name => '   ', p_price_cents => 100$$), 'REQUIRED: a blank name is rejected');
select pg_temp.mvbad('c_n3', pg_temp.va(format($$p_name => %L, p_price_cents => 100$$, repeat('x', 201))), 'VALIDATION: a 201-character name is rejected');
select pg_temp.mvbad('c_n4', pg_temp.va(format($$p_name => %L, p_price_cents => 100$$, 'a' || chr(7) || 'b')), 'VALIDATION: a name with a control character is rejected');
select pg_temp.mvbad('c_p1', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => null$$), 'REQUIRED: a NULL price is rejected');
select pg_temp.mvbad('c_p2', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => -1$$), 'VALIDATION: a negative price is rejected');
select pg_temp.mvbad('c_p3', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_compare_at_price_cents => 99$$), 'VALIDATION: compare_at below the price is rejected');
select pg_temp.mvbad('c_s1', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_sku => 'has space'$$), 'VALIDATION: a SKU with a space is rejected');
select pg_temp.mvbad('c_s2', pg_temp.va(format($$p_name => 'T6C1B2 X', p_price_cents => 100, p_sku => %L$$, repeat('A', 65))), 'VALIDATION: a 65-character SKU is rejected');
select pg_temp.mvbad('c_a1', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_attributes => '[1,2]'::jsonb$$), 'VALIDATION: attributes that are a JSON array are rejected');
select pg_temp.mvbad('c_a2', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_attributes => '"text"'::jsonb$$), 'VALIDATION: attributes that are a JSON string are rejected');
select pg_temp.mvbad('c_a3', pg_temp.va(format($$p_name => 'T6C1B2 X', p_price_cents => 100, p_attributes => %L::jsonb$$,
  jsonb_build_object('k', repeat('x', 4100))::text)), 'VALIDATION: attributes over 4000 bytes are rejected');
select pg_temp.mvbad('c_o1', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_position => -1$$), 'VALIDATION: a negative position is rejected');
select pg_temp.mvbad('c_o2', pg_temp.va($$p_name => 'T6C1B2 X', p_price_cents => 100, p_position => 100001$$), 'VALIDATION: a position over 100000 is rejected');
select pg_temp.mvbad('c_i1', $$p_product_id => null, p_name => 'T6C1B2 X', p_price_cents => 100$$, 'REQUIRED: a NULL product id is rejected');
select pg_temp.mvx('c_nf', $$p_product_id => '00000000-0000-4000-8000-6c9fffffffff', p_name => 'T6C1B2 Orphan', p_price_cents => 100$$,
  'P0001', 'product_not_found', 'PARENT: a nonexistent product id is rejected (P0001 / product_not_found)');
select pg_temp.run('c_nop', 'authenticated', pg_temp.u(3), $$select public.admin_create_product_variant(p_name => 'T6C1B2 X', p_price_cents => 100)::text$$);
select pg_temp.expect_err('c_nop', '42883', null, 'REQUIRED: omitting p_product_id altogether is not a valid call (no default)');
select pg_temp.run('c_non', 'authenticated', pg_temp.u(3), format($$select public.admin_create_product_variant(p_product_id => %L, p_price_cents => 100)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('c_non', '42883', null, 'REQUIRED: omitting p_name altogether is not a valid call (no default)');
select pg_temp.run('c_nopr', 'authenticated', pg_temp.u(3), format($$select public.admin_create_product_variant(p_product_id => %L, p_name => 'T6C1B2 X')::text$$, pg_temp.p(1)));
select pg_temp.expect_err('c_nopr', '42883', null, 'REQUIRED: omitting p_price_cents altogether is not a valid call (no default)');

-- Uniqueness: the EXISTING unique index product_variants_sku_key decides
select pg_temp.mvx('c_d1', pg_temp.va($$p_name => 'T6C1B2 Dup', p_price_cents => 100, p_sku => 'T6C1B2-V1'$$),
  '23505', 'sku_taken', 'UNIQUE: a SKU already used by a fixture variant is refused (23505 / sku_taken)');
select pg_temp.mvx('c_d2', pg_temp.va($$p_name => 'T6C1B2 Dup', p_price_cents => 100, p_sku => 'T6C1B2-NEW'$$),
  '23505', 'sku_taken', 'UNIQUE: a SKU already used by a variant created through the API is refused (23505 / sku_taken)');
select pg_temp.ok((select count(*) from public.product_variants where name = 'T6C1B2 Dup') = 0
  and (select count(*) from public.product_variants where name = 'T6C1B2 Orphan') = 0,
  'UNIQUE / PARENT: none of the refused creates left a row behind');

-- Inventory / activation / ownership values cannot be supplied: the argument does not exist (42883)
select pg_temp.mv('c_inv1', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Inv', p_price_cents => 1, p_stock_quantity => 50$$));
select pg_temp.expect_err('c_inv1', '42883', null, 'INVENTORY: there is no p_stock_quantity parameter (a stock value cannot be passed in)');
select pg_temp.mv('c_inv2', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Inv', p_price_cents => 1, p_in_stock => false$$));
select pg_temp.expect_err('c_inv2', '42883', null, 'INVENTORY: there is no p_in_stock parameter');
select pg_temp.mv('c_inv3', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Inv', p_price_cents => 1, p_is_active => false$$));
select pg_temp.expect_err('c_inv3', '42883', null, 'INVENTORY: there is no p_is_active parameter (a new variant cannot be created inactive)');
select pg_temp.mv('c_inv4', 'authenticated', pg_temp.u(3), pg_temp.va($$p_name => 'T6C1B2 Inv', p_price_cents => 1, p_id => '00000000-0000-4000-8000-6caeeeeeeeee'$$));
select pg_temp.expect_err('c_inv4', '42883', null, 'INVENTORY: there is no p_id parameter (the database chooses the id)');
select pg_temp.run('c_inv5', 'authenticated', pg_temp.u(3),
  format($$select public.admin_create_product_variant(%L, 'T6C1B2 Inv', 1, null, null, null, 0, 50)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('c_inv5', '42883', null, 'INVENTORY: there is no eighth positional parameter either (the signature has seven)');
select pg_temp.ok((select count(*) from public.product_variants where name = 'T6C1B2 Inv') = 0,
  'INVENTORY: none of the rejected stock / activation / id attempts created a row');

-- No inventory transaction / history was created, and no fixture's inventory moved
select pg_temp.ok(pg_temp.stock_hash() = (select h from t_h where k = 'stock1'),
  'NO INVENTORY EFFECT: stock_quantity / in_stock of every fixture product and variant is unchanged by all create calls');
select pg_temp.ok(not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
                              and c.relname ~* '(inventor|stock)' and c.relname <> 'inventory_adjustments')
  and (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))
      = (select h from t_h where k = 'rel0'),
  'NO INVENTORY HISTORY: no inventory / stock-movement table exists (other than the 6C.2.2A.1 audit table inventory_adjustments) and no table was added by this phase');

-- ===========================================================================
-- D. VARIANT UPDATE (checks 26-33)
-- ===========================================================================
insert into t_snap values ('v1', pg_temp.var_json(pg_temp.v(1)));
insert into t_h values ('v1_row0', pg_temp.vrow_hash(pg_temp.v(1)));

select pg_temp.uv('d1', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"name":"  T6C1B2 Renamed  "}');
select pg_temp.succeeded('d1', 'VARIANT UPDATE: a one-field patch succeeds');
select pg_temp.ok(pg_temp.keys(pg_temp.j('d1')) = 'variant'
  and pg_temp.keys(pg_temp.j('d1') -> 'variant')
      = 'attributes,compare_at_price_cents,created_at,id,is_active,name,position,price_cents,product_id,sku,stock_quantity,updated_at',
  'VARIANT UPDATE: the result has exactly one key, "variant", carrying the 12 columns');
select pg_temp.ok(pg_temp.j('d1') -> 'variant' = pg_temp.var_json(pg_temp.v(1))
  and pg_temp.j('d1') -> 'variant' ->> 'name' = 'T6C1B2 Renamed',
  'VARIANT UPDATE: the returned JSONB is exactly the stored row; the name is trimmed');
select pg_temp.ok((pg_temp.var_json(pg_temp.v(1)) - 'name' - 'updated_at') = ((select j from t_snap where k = 'v1') - 'name' - 'updated_at'),
  'PATCH SEMANTICS: only the name changed - sku, prices, attributes, position, is_active, stock_quantity, product_id and created_at are identical');

select pg_temp.uv('d2', 'authenticated', pg_temp.u(3), pg_temp.v(1),
  '{"price_cents":2000,"compare_at_price_cents":2500,"attributes":{"size":"2kg"},"position":7,"sku":"T6C1B2-V1-NEW"}');
select pg_temp.succeeded('d2', 'VARIANT UPDATE: a multi-field patch succeeds');
select pg_temp.ok(pg_temp.j('d2') -> 'variant' = pg_temp.var_json(pg_temp.v(1))
  and (select price_cents = 2000 and compare_at_price_cents = 2500 and attributes = '{"size":"2kg"}'::jsonb
              and position = 7 and sku = 'T6C1B2-V1-NEW' and name = 'T6C1B2 Renamed'
       from public.product_variants where id = pg_temp.v(1)),
  'VARIANT UPDATE: every supplied field changed (attributes replaced as a whole) and the unmentioned name was preserved');
select pg_temp.ok((select stock_quantity = 9 and product_id = pg_temp.p(1) and is_active from public.product_variants where id = pg_temp.v(1)),
  'VARIANT UPDATE: stock_quantity (9), product_id and is_active are untouched by a catalogue patch');

-- Compare-at is validated against the EFFECTIVE price
select pg_temp.uvbad('d_c1', pg_temp.v(1), '{"price_cents":5000}', 'VALIDATION: raising only the price above the stored compare_at (2500) is rejected');
select pg_temp.uvbad('d_c2', pg_temp.v(1), '{"compare_at_price_cents":1999}', 'VALIDATION: a compare_at below the stored price (2000) is rejected');
select pg_temp.uv('d_c3', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"price_cents":5000,"compare_at_price_cents":5000}');
select pg_temp.succeeded('d_c3', 'VALIDATION: raising price and compare_at together is accepted (the effective values are checked)');

select pg_temp.uv('d3', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"sku":null,"compare_at_price_cents":null}');
select pg_temp.succeeded('d3', 'VARIANT UPDATE: JSON null clears the nullable fields (sku, compare_at_price_cents)');
select pg_temp.ok((select sku is null and compare_at_price_cents is null and price_cents = 5000 and name = 'T6C1B2 Renamed' and position = 7
       from public.product_variants where id = pg_temp.v(1))
  and jsonb_typeof(pg_temp.j('d3') -> 'variant' -> 'sku') = 'null',
  'VARIANT UPDATE: only the two cleared fields changed; an ABSENT key is not a null');
select pg_temp.uv('d3b', 'authenticated', pg_temp.u(3), pg_temp.v(2), '{"sku":"   "}');
select pg_temp.ok((select sku is null from public.product_variants where id = pg_temp.v(2)),
  'VARIANT UPDATE: a blank SKU is stored as NULL');
select pg_temp.uv('d3c', 'authenticated', pg_temp.u(3), pg_temp.v(2), '{"sku":"T6C1B2-V2"}');
select pg_temp.succeeded('d3c', 'UNIQUE: setting a SKU that no other variant uses (here the one V2 had before) is accepted');
select pg_temp.uv('d3d', 'authenticated', pg_temp.u(3), pg_temp.v(2), '{"sku":"T6C1B2-V2"}');
select pg_temp.succeeded('d3d', 'UNIQUE: re-sending the variant''s OWN current SKU is accepted (no clash with itself)');

-- Variant activation (update only): independent of the product and of stock
select pg_temp.uv('d4', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"is_active":false}');
select pg_temp.succeeded('d4', 'VARIANT UPDATE: an admin can deactivate a variant');
select pg_temp.ok((select not is_active and stock_quantity = 9 from public.product_variants where id = pg_temp.v(1))
  and (select is_active from public.products where id = pg_temp.p(1)),
  'VARIANT ACTIVATION: only the variant flag changed - its stock and its product''s is_active are untouched');
select pg_temp.uv('d4b', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"is_active":true}');
select pg_temp.ok((select is_active from public.product_variants where id = pg_temp.v(1)), 'VARIANT ACTIVATION: and reactivate');

-- attributes semantics
select pg_temp.uv('d5', 'authenticated', pg_temp.u(3), pg_temp.v(1), '{"attributes":{}}');
select pg_temp.ok((select attributes = '{}'::jsonb from public.product_variants where id = pg_temp.v(1)),
  'PATCH SEMANTICS: attributes {} clears the attributes (they are replaced, never merged)');
select pg_temp.uvbad('d5b', pg_temp.v(1), '{"attributes":null}', 'VALIDATION: attributes null is rejected (the column is NOT NULL)');
select pg_temp.uvbad('d5c', pg_temp.v(1), '{"attributes":[1]}', 'VALIDATION: attributes as an array is rejected');
select pg_temp.uvbad('d5d', pg_temp.v(1), jsonb_build_object('attributes', jsonb_build_object('k', repeat('x', 4100)))::text,
  'VALIDATION: attributes over 4000 bytes are rejected');

-- Type / range validation of every field
select pg_temp.uvbad('d6a', pg_temp.v(1), '{"name":5}', 'VALIDATION: a numeric name is rejected');
select pg_temp.uvbad('d6b', pg_temp.v(1), '{"name":"   "}', 'VALIDATION: a blank name is rejected');
select pg_temp.uvbad('d6c', pg_temp.v(1), '{"name":null}', 'VALIDATION: a null name is rejected');
select pg_temp.uvbad('d6d', pg_temp.v(1), '{"price_cents":"100"}', 'VALIDATION: a string price is rejected');
select pg_temp.uvbad('d6e', pg_temp.v(1), '{"price_cents":1.5}', 'VALIDATION: a fractional price is rejected');
select pg_temp.uvbad('d6f', pg_temp.v(1), '{"price_cents":-1}', 'VALIDATION: a negative price is rejected');
select pg_temp.uvbad('d6g', pg_temp.v(1), '{"price_cents":null}', 'VALIDATION: a null price is rejected');
select pg_temp.uvbad('d6h', pg_temp.v(1), '{"position":1.5}', 'VALIDATION: a fractional position is rejected');
select pg_temp.uvbad('d6i', pg_temp.v(1), '{"position":-1}', 'VALIDATION: a negative position is rejected');
select pg_temp.uvbad('d6j', pg_temp.v(1), '{"is_active":"true"}', 'VALIDATION: is_active as a string is rejected');
select pg_temp.uvbad('d6k', pg_temp.v(1), '{"is_active":null}', 'VALIDATION: is_active null is rejected');
select pg_temp.uvbad('d6l', pg_temp.v(1), '{"sku":5}', 'VALIDATION: a numeric sku is rejected');
select pg_temp.uvbad('d6m', pg_temp.v(1), '{"sku":"bad sku"}', 'VALIDATION: a malformed sku is rejected');
select pg_temp.uvbad('d6n', pg_temp.v(1), '{}', 'VALIDATION: an empty patch is rejected');
select pg_temp.uvbad('d6o', pg_temp.v(1), '[]', 'VALIDATION: a non-object patch (array) is rejected');
select pg_temp.uvbad('d6p', pg_temp.v(1), 'null', 'VALIDATION: a JSON null patch is rejected');
select pg_temp.uv('d6q', 'authenticated', pg_temp.u(3), pg_temp.v(1), null);
select pg_temp.expect_err('d6q', 'P0001', 'invalid_arguments', 'VALIDATION: a SQL NULL patch is rejected');
select pg_temp.uvbad('d6r', null, '{"name":"x"}', 'VALIDATION: a NULL variant id is rejected');

-- Unsupported fields: rejected EXPLICITLY (never silently ignored); nothing is written
insert into t_h values ('v1_row1', pg_temp.vrow_hash(pg_temp.v(1))), ('var1', pg_temp.var_hash()), ('stock2', pg_temp.stock_hash());
select pg_temp.uvx('f1', pg_temp.v(1), '{"stock_quantity":999}', 'P0001', 'unsupported_field', 'FORBIDDEN: stock_quantity cannot be changed (unsupported_field)');
select pg_temp.uvx('f2', pg_temp.v(1), '{"stock_quantity":0}', 'P0001', 'unsupported_field', 'FORBIDDEN: even stock_quantity 0 is refused, not ignored');
select pg_temp.uvx('f3', pg_temp.v(1), '{"in_stock":false}', 'P0001', 'unsupported_field', 'FORBIDDEN: in_stock cannot be changed (unsupported_field)');
select pg_temp.uvx('f4', pg_temp.v(1), jsonb_build_object('product_id', pg_temp.p(3))::text, 'P0001', 'unsupported_field',
  'FORBIDDEN: product_id cannot be changed - a variant cannot be moved to another product (unsupported_field)');
select pg_temp.uvx('f5', pg_temp.v(1), jsonb_build_object('id', pg_temp.v(9))::text, 'P0001', 'unsupported_field', 'FORBIDDEN: id cannot be changed');
select pg_temp.uvx('f6', pg_temp.v(1), '{"created_at":"2000-01-01T00:00:00Z"}', 'P0001', 'unsupported_field', 'FORBIDDEN: created_at cannot be changed');
select pg_temp.uvx('f7', pg_temp.v(1), '{"updated_at":"2000-01-01T00:00:00Z"}', 'P0001', 'unsupported_field', 'FORBIDDEN: updated_at cannot be changed');
select pg_temp.uvx('f8', pg_temp.v(1), '{"foo":"bar"}', 'P0001', 'unsupported_field', 'FORBIDDEN: an unknown field is refused');
select pg_temp.uvx('f9', pg_temp.v(1), '{"name":"Should Not Stick","is_active":false,"stock_quantity":0}', 'P0001', 'unsupported_field',
  'FORBIDDEN: one forbidden key refuses the WHOLE patch (nothing is partially applied)');
select pg_temp.uvx('f10', pg_temp.v(1), '{"price_cents":1,"in_stock":true}', 'P0001', 'unsupported_field',
  'FORBIDDEN: valid fields next to in_stock are not applied either');
select pg_temp.uvx('f11', pg_temp.v(1), '{"product":{"is_active":false}}', 'P0001', 'unsupported_field',
  'FORBIDDEN: product activation cannot be smuggled through the variant patch');
select pg_temp.ok(pg_temp.vrow_hash(pg_temp.v(1)) = (select h from t_h where k = 'v1_row1')
  and pg_temp.var_hash() = (select h from t_h where k = 'var1')
  and pg_temp.stock_hash() = (select h from t_h where k = 'stock2'),
  'FORBIDDEN: after all rejected patches the variant row, every variant row and every stock value are byte-identical');
select pg_temp.ok((select product_id from public.product_variants where id = pg_temp.v(1)) = pg_temp.p(1),
  'RELATIONSHIP: the variant is still attached to its original product');

-- Not found, and duplicate SKU on update
select pg_temp.uvx('n1', '00000000-0000-4000-8000-6cafffffffff', '{"name":"x"}', 'P0001', 'variant_not_found',
  'NOT FOUND: a nonexistent variant is rejected (P0001 / variant_not_found)');
select pg_temp.uvx('n2', pg_temp.v(2), '{"sku":"T6C1B2-V3"}', '23505', 'sku_taken',
  'UNIQUE: changing a SKU to one another variant already uses is refused (23505 / sku_taken)');
select pg_temp.ok((select sku = 'T6C1B2-V2' from public.product_variants where id = pg_temp.v(2)),
  'UNIQUE: the refused update left the variant''s SKU as it was');
select pg_temp.uvx('n3', pg_temp.v(2), '{"sku":"T6C1B2-NEW"}', '23505', 'sku_taken',
  'UNIQUE: a SKU held by a variant created through the API is also refused');

-- Another product's variants are never touched
select pg_temp.uv('o1', 'authenticated', pg_temp.u(3), pg_temp.v(3), '{"price_cents":450,"position":4}');
select pg_temp.succeeded('o1', 'VARIANT UPDATE: a variant of another product can be updated');
select pg_temp.ok((select product_id = pg_temp.p(3) and price_cents = 450 and stock_quantity = 4 from public.product_variants where id = pg_temp.v(3)),
  'VARIANT UPDATE: it stayed attached to its own product and kept its stock');
select pg_temp.ok(pg_temp.stock_hash() = (select h from t_h where k = 'stock1'),
  'NO INVENTORY EFFECT: stock_quantity / in_stock of every fixture product and variant is unchanged by every create, update and activation call');

-- ===========================================================================
-- E. FUNCTION SECURITY / PRIVILEGES (checks 34-40)
-- ===========================================================================
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('admin_set_product_active', 'admin_create_product_variant', 'admin_update_product_variant')) = 3
  and to_regprocedure('public.admin_set_product_active(uuid,boolean)') is not null
  and to_regprocedure('public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)') is not null
  and to_regprocedure('public.admin_update_product_variant(uuid,jsonb)') is not null,
  'META: exactly one overload of each new function, with the exact expected signature');
select pg_temp.ok(
  (select bool_and(p.prosecdef and p.provolatile = 'v') from pg_proc p
   where p.oid in ('public.admin_set_product_active(uuid,boolean)'::regprocedure,
                   'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure,
                   'public.admin_update_product_variant(uuid,jsonb)'::regprocedure)),
  'SECURITY: every new function is SECURITY DEFINER and VOLATILE');
select pg_temp.ok(
  (select bool_and(coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%') from pg_proc p
   where p.oid in ('public.admin_set_product_active(uuid,boolean)'::regprocedure,
                   'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure,
                   'public.admin_update_product_variant(uuid,jsonb)'::regprocedure)),
  'SECURITY: every new function pins search_path = public, pg_temp');
select pg_temp.ok(
  (select bool_and(p.prosrc like '%public.require_admin()%') from pg_proc p
   where p.oid in ('public.admin_set_product_active(uuid,boolean)'::regprocedure,
                   'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure,
                   'public.admin_update_product_variant(uuid,jsonb)'::regprocedure)),
  'SECURITY: every new function gates with the existing public.require_admin() (no second authorization system)');
select pg_temp.ok(
  (select bool_and(not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                               where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
   from pg_proc p
   where p.oid in ('public.admin_set_product_active(uuid,boolean)'::regprocedure,
                   'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure,
                   'public.admin_update_product_variant(uuid,jsonb)'::regprocedure)),
  'ACL: PUBLIC cannot EXECUTE any new function');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_set_product_active(uuid,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_update_product_variant(uuid,jsonb)', 'EXECUTE'),
  'ACL: anon cannot EXECUTE any new function');
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_set_product_active(uuid,boolean)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_update_product_variant(uuid,jsonb)', 'EXECUTE'),
  'ACL: authenticated holds EXECUTE on every new function (the require_admin() gate does the authorizing)');
select pg_temp.ok(not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'ACL: require_admin() is still not callable directly by anon or authenticated');
select pg_temp.ok(not exists (
    select 1 from pg_proc p join pg_roles r on r.oid = p.proowner
    where p.oid in ('public.admin_set_product_active(uuid,boolean)'::regprocedure,
                    'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure,
                    'public.admin_update_product_variant(uuid,jsonb)'::regprocedure)
      and r.rolname in ('anon', 'authenticated')),
  'ACL: the new functions are owned by a privileged owner role, not by a browser role');

-- Structural proof that the bodies do exactly what the contract says and nothing else
select pg_temp.ok(
  (select prosrc ~* 'set\s+is_active\s*=\s*p_is_active\s+where'
      and (select count(*) from regexp_matches(prosrc, 'update\s+public\.', 'gi')) = 1
      and prosrc ~* 'for\s+update'
      and prosrc !~* 'product_variants'
      -- Phase 6I.2: the only insert allowed is the single admin_audit_log row.
      and regexp_replace(prosrc, 'insert\s+into\s+public\.admin_audit_log', '', 'gi') !~* '(delete\s+from|truncate|insert\s+into)'
   from pg_proc where oid = 'public.admin_set_product_active(uuid,boolean)'::regprocedure),
  'STRUCTURE: admin_set_product_active locks the row (FOR UPDATE), has exactly ONE UPDATE that assigns only is_active, and never mentions product_variants, deletes or truncates, and inserts only its admin_audit_log row (6I.2)');
select pg_temp.ok(
  (select prosrc !~* 'insert\s+into\s+(public\.)?product_variants\s*\([^)]*(stock_quantity|is_active|created_at|updated_at)'
      and prosrc ~* 'insert\s+into\s+public\.product_variants\s*\(\s*product_id,\s*name,\s*sku,\s*price_cents,\s*compare_at_price_cents,\s*attributes,\s*position\s*\)'
      and prosrc !~* '(update\s+public\.|delete\s+from|truncate)'
   from pg_proc where oid = 'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)'::regprocedure),
  'STRUCTURE: admin_create_product_variant inserts exactly (product_id, name, sku, price_cents, compare_at_price_cents, attributes, position) - never stock_quantity or is_active - and updates or deletes nothing');
select pg_temp.ok(
  (select prosrc ~* 'for\s+update'
      and prosrc !~* '(set|,)\s*(stock_quantity|product_id|created_at|updated_at)\s*='
      and prosrc !~* 'update\s+(public\.)?products\M'
      -- Phase 6I.2: the only insert allowed is the single admin_audit_log row.
      and regexp_replace(prosrc, 'insert\s+into\s+public\.admin_audit_log', '', 'gi') !~* '(insert\s+into|delete\s+from|truncate)'
      and (select count(*) from regexp_matches(prosrc, 'update\s+public\.product_variants', 'gi')) = 1
   from pg_proc where oid = 'public.admin_update_product_variant(uuid,jsonb)'::regprocedure),
  'STRUCTURE: admin_update_product_variant locks the variant (FOR UPDATE), has one UPDATE of product_variants that never assigns stock_quantity, product_id or system columns, and never touches products');

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
select pg_temp.ok(has_table_privilege('authenticated', 'public.product_variants', 'SELECT')
  and has_table_privilege('anon', 'public.product_variants', 'SELECT'),
  'PRIV: storefront SELECT on product_variants is unchanged (anon and authenticated)');
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
select pg_temp.run('w_a1', 'authenticated', pg_temp.u(3), $$with u as (update public.product_variants set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_a2', 'authenticated', pg_temp.u(3), format($$with i as (insert into public.product_variants (product_id, name, price_cents) values (%L, 'T6C1B2 direct', 1) returning 1) select count(*)::text from i$$, pg_temp.p(1)));
select pg_temp.run('w_a3', 'authenticated', pg_temp.u(3), $$with d as (delete from public.product_variants returning 1) select count(*)::text from d$$);
select pg_temp.run('w_a4', 'authenticated', pg_temp.u(3), $$with u as (update public.products set is_active = false returning 1) select count(*)::text from u$$);
select pg_temp.run('w_a5', 'authenticated', pg_temp.u(3), $$with u as (update public.product_variants set stock_quantity = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_s1', 'authenticated', pg_temp.u(2), $$with u as (update public.product_variants set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_c1', 'authenticated', pg_temp.u(1), $$with u as (update public.products set is_active = false returning 1) select count(*)::text from u$$);
select pg_temp.run('w_n1', 'anon', null, $$with u as (update public.product_variants set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.write_denied('w_a1', 'WRITE: admin cannot UPDATE product_variants directly (the RPC is the only path)');
select pg_temp.write_denied('w_a2', 'WRITE: admin cannot INSERT product_variants directly (the RPC is the only path)');
select pg_temp.write_denied('w_a3', 'WRITE: admin cannot DELETE product_variants');
select pg_temp.write_denied('w_a4', 'WRITE: admin cannot UPDATE products.is_active directly (the RPC is the only path)');
select pg_temp.write_denied('w_a5', 'WRITE: admin cannot UPDATE variant stock directly (no inventory write path exists)');
select pg_temp.write_denied('w_s1', 'WRITE: staff cannot UPDATE product_variants directly');
select pg_temp.write_denied('w_c1', 'WRITE: customer cannot UPDATE products directly');
select pg_temp.write_denied('w_n1', 'WRITE: anon cannot UPDATE product_variants');

-- Triggers on the catalogue: still only the existing updated_at one; no inventory tables
select pg_temp.ok(not exists (
    select 1 from pg_trigger t
    where not t.tgisinternal and t.tgrelid in ('public.products'::regclass, 'public.product_variants'::regclass, 'public.categories'::regclass)
      and t.tgfoid::regproc::text not in ('set_updated_at', 'public.set_updated_at', 'inventory_log_stock_change', 'public.inventory_log_stock_change')),
  'TRIGGERS: the catalogue tables carry no trigger other than the existing updated_at one (this phase added none)');

-- The product / variant / category / SKU / inventory-named functions in public are exactly the known set
select pg_temp.ok((select array_agg(proname::text order by proname::text) from pg_proc
                   where pronamespace = 'public'::regnamespace
                     and (proname ilike '%product%' or proname ilike '%variant%' or proname ilike '%categor%'
                          or proname ilike '%sku%' or proname ilike '%inventor%'))
  = array['admin_adjust_inventory', 'admin_create_category', 'admin_create_product', 'admin_create_product_variant', 'admin_get_inventory', 'admin_get_product',
          'admin_list_inventory', 'admin_list_inventory_adjustments', 'admin_list_products',
          'admin_set_category_image', 'admin_set_product_active', 'admin_set_product_image', 'admin_update_category', 'admin_update_product', 'admin_update_product_variant',
                'inventory_adjustments_guard', 'inventory_log_stock_change', 'inventory_order_ctx_clear', 'inventory_order_ctx_set'],
  'FUNCS: the only product / variant / category / SKU / inventory-named functions in public are the two readers, the two 6C.1B.1 writers, the three of this phase the two 6C.2.1 inventory readers and the 6C.2.2A.2 admin_adjust_inventory and the 6C.2.2B.1 read-only admin_list_inventory_adjustments and the four Phase 9B inventory_* trigger functions (no other stock-writing, category or delete function exists)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('admin_list_products', 'admin_get_product')
      and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(public\.)?(products|product_variants|categories)\M'),
  'FUNCS: the two readers from 6C.1A still write nothing');

-- ===========================================================================
-- F. REGRESSION - earlier phases still behave
-- ===========================================================================
-- 6C.1B.1: create / update still work and still cannot touch activation or inventory
select pg_temp.run('r_pc', 'authenticated', pg_temp.u(3),
  format($$select public.admin_create_product(p_name => 'T6C1B2 Reg Created', p_slug => 't6c1b2-reg-created', p_price_cents => 1200, p_category_id => %L)::text$$, pg_temp.c(1)));
select pg_temp.succeeded('r_pc', 'REGRESSION 6C.1B.1: admin_create_product still works');
select pg_temp.ok(pg_temp.keys(pg_temp.j('r_pc')) = 'product'
  and pg_temp.j('r_pc') -> 'product' = pg_temp.row_json((pg_temp.j('r_pc') -> 'product' ->> 'id')::uuid)
  and (pg_temp.j('r_pc') -> 'product' ->> 'is_active')::boolean
  and (pg_temp.j('r_pc') -> 'product' ->> 'stock_quantity')::integer = 0,
  'REGRESSION 6C.1B.1: a product created by admin_create_product is still ACTIVE immediately with stock 0 (table defaults; unchanged by this phase)');
select pg_temp.run('r_pc_s', 'authenticated', pg_temp.u(3),
  $$select public.admin_create_product(p_name => 'T6C1B2 Reg Stock', p_slug => 't6c1b2-reg-stock', p_price_cents => 1, p_is_active => false)::text$$);
select pg_temp.expect_err('r_pc_s', '42883', null, 'REGRESSION 6C.1B.1: admin_create_product still has no p_is_active parameter (activation only via admin_set_product_active)');
select pg_temp.run('r_pc_st', 'authenticated', pg_temp.u(3),
  $$select public.admin_create_product(p_name => 'T6C1B2 Reg Stock', p_slug => 't6c1b2-reg-stock', p_price_cents => 1, p_stock_quantity => 5)::text$$);
select pg_temp.expect_err('r_pc_st', '42883', null, 'REGRESSION 6C.1B.1: admin_create_product still has no p_stock_quantity parameter');
select pg_temp.run('r_pc_g', 'authenticated', pg_temp.u(2),
  $$select public.admin_create_product(p_name => 'T6C1B2 Reg Staff', p_slug => 't6c1b2-reg-staff', p_price_cents => 1)::text$$);
select pg_temp.gated('r_pc_g', 'REGRESSION 6C.1B.1: admin_create_product still refuses staff');
select pg_temp.run('r_pu', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product(%L::uuid, '{"name":"T6C1B2 Full Renamed"}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.succeeded('r_pu', 'REGRESSION 6C.1B.1: admin_update_product still works');
select pg_temp.run('r_pu_a', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product(%L::uuid, '{"is_active":false}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('r_pu_a', 'P0001', 'unsupported_field', 'REGRESSION 6C.1B.1: admin_update_product still rejects is_active (activation is only through admin_set_product_active)');
select pg_temp.run('r_pu_s', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product(%L::uuid, '{"stock_quantity":99}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('r_pu_s', 'P0001', 'unsupported_field', 'REGRESSION 6C.1B.1: admin_update_product still rejects stock_quantity');
select pg_temp.run('r_pu_v', 'authenticated', pg_temp.u(3), format($$select public.admin_update_product(%L::uuid, '{"variants":[{"sku":"X"}]}'::jsonb)::text$$, pg_temp.p(1)));
select pg_temp.expect_err('r_pu_v', 'P0001', 'unsupported_field', 'REGRESSION 6C.1B.1: admin_update_product still rejects variant data');
select pg_temp.ok(pg_temp.stock_hash() = (select h from t_h where k = 'stock1'),
  'REGRESSION 6C.1B.1: the product functions changed no inventory');
-- admin_get_product (6C.1A.2) sees what the new functions wrote
select pg_temp.run('r_gp', 'authenticated', pg_temp.u(3), format($$select public.admin_get_product(%L)::text$$, pg_temp.p(1)));
select pg_temp.ok(pg_temp.keys(pg_temp.j('r_gp')) = 'category,product,variants'
  and (select count(*) from jsonb_array_elements(pg_temp.j('r_gp') -> 'variants'))
      = (select count(*) from public.product_variants where product_id = pg_temp.p(1))
  and exists (select 1 from jsonb_array_elements(pg_temp.j('r_gp') -> 'variants') e
              where e ->> 'id' = (pg_temp.j('c1') -> 'variant' ->> 'id') and e ->> 'name' = 'T6C1B2 Large')
  and (select bool_and(e = pg_temp.var_json((e ->> 'id')::uuid)) from jsonb_array_elements(pg_temp.j('r_gp') -> 'variants') e),
  'REGRESSION 6C.1A.2: admin_get_product returns { product, category, variants } and each variant (including the one created through the API) equals the stored row');

-- 6C.1A.1 / 6C.1A.2: reads (and they see what the new functions wrote)
select pg_temp.run('r_list', 'authenticated', pg_temp.u(3), $$select public.admin_list_products(p_search => 't6c1b2-reg-created', p_limit => 10)::text$$);
select pg_temp.ok(
  (pg_temp.j('r_list') ->> 'total')::integer = 1
  and pg_temp.keys(pg_temp.j('r_list')) = 'limit,offset,products,total'
  and pg_temp.j('r_list') -> 'products' -> 0 ->> 'slug' = 't6c1b2-reg-created'
  and pg_temp.j('r_list') -> 'products' -> 0 = pg_temp.row_json((pg_temp.j('r_pc') -> 'product' ->> 'id')::uuid),
  'REGRESSION 6C.1A.1/2: admin_list_products still works, keeps its result shape and finds the product created by admin_create_product');
select pg_temp.run('r_list_in', 'authenticated', pg_temp.u(3), $$select public.admin_list_products(p_search => 't6c1b2-inactive', p_is_active => false, p_limit => 10)::text$$);
select pg_temp.ok((pg_temp.j('r_list_in') ->> 'total')::integer = 1
  and pg_temp.j('r_list_in') -> 'products' -> 0 ->> 'id' = pg_temp.p(2)::text,
  'REGRESSION 6C.1A.2: the search + is_active filter still finds the inactive fixture');
select pg_temp.run('r_cat', 'authenticated', pg_temp.u(3), format($$select public.admin_list_products(p_category_id => %L, p_limit => 100)::text$$, pg_temp.c(1)));
select pg_temp.ok((pg_temp.j('r_cat') ->> 'total')::integer >= 1
  and exists (select 1 from jsonb_array_elements(pg_temp.j('r_cat') -> 'products') e where e ->> 'id' = (pg_temp.j('r_pc') -> 'product' ->> 'id')),
  'REGRESSION 6C.1A.2: the category filter finds the product created in that category');
select pg_temp.run('r_get', 'authenticated', pg_temp.u(3), format($$select public.admin_get_product(%L)::text$$, (pg_temp.j('r_pc') -> 'product' ->> 'id')::uuid));
select pg_temp.ok(pg_temp.keys(pg_temp.j('r_get')) = 'category,product,variants'
  and pg_temp.j('r_get') -> 'product' = pg_temp.row_json((pg_temp.j('r_pc') -> 'product' ->> 'id')::uuid)
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
select pg_temp.run('s_anon', 'anon', null, $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b2-%'$$);
select pg_temp.ok(
  pg_temp.res('s_anon') = (select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b2-%' and is_active)
  and pg_temp.res('s_anon') not like '%t6c1b2-inactive%',
  'REGRESSION: anon still sees exactly the ACTIVE fixture products (existing public RLS unchanged; the inactive one stays hidden)');
select pg_temp.run('s_admin', 'authenticated', pg_temp.u(3), $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b2-%'$$);
select pg_temp.ok(pg_temp.res('s_admin') = (select string_agg(slug, ',' order by slug) from public.products where slug like 't6c1b2-%')
  and pg_temp.res('s_admin') like '%t6c1b2-inactive%',
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
  'REGRESSION 6B.2: the admin API is exactly the fifteen known functions (admin_list_inventory_adjustments from 6C.2.2B.1 + admin_adjust_inventory from 6C.2.2A.2 + six from 6A-6C.1A + the two of 6C.1B.1 + the three of this phase + the two inventory readers of 6C.2.1); no payment or refund writer exists');
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
  'REGRESSION 5B.2: every SECURITY DEFINER function in public (including the new ones) pins search_path = public, pg_temp');
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
do $$ begin raise notice 'ALL PHASE 6C.1B.2 TESTS PASSED'; end $$;

rollback;
