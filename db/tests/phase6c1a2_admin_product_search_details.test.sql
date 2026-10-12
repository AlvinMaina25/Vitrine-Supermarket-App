-- =============================================================================
-- PHASE 6C.1A.2 database test: admin product search, filtering, pagination and details.
--
-- STATUS: written for migration 20261004050000_phase6c1a2_admin_product_search_details.sql.
-- NOT YET EXECUTED ANYWHERE: no PostgreSQL was available where it was written, so neither the
-- migration nor this test has been run. Treat the first run as the first verification.
--
-- HOW TO RUN (a DEV or branch database with ALL migrations through
-- 20261004050000_phase6c1a2_admin_product_search_details.sql applied, as the postgres/owner role):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c1a2_admin_product_search_details.test.sql
--
-- One transaction, rolled back at the end: no fixture survives. A failed check raises
-- "FAIL: <name>"; each pass prints "PASS: <name>". "ALL PHASE 6C.1A.2 TESTS PASSED" means all passed.
--
-- HOW USERS ARE SIMULATED: pg_temp.run() sets the JWT settings and `SET LOCAL ROLE`
-- anon|authenticated|service_role, runs ONE statement and records the result or the error, so
-- privileges, RLS and auth.uid() behave as they would through PostgREST.
--
-- DATABASE-DATA NOTE: the test may run on a database that already holds real products. It never
-- modifies or deletes them. Every fixture product has a slug starting 't6d-' and a name / category
-- name containing 'T6D'; list tests scope themselves with p_search => 'T6D' (or a fixture category)
-- so real rows do not matter. ASSUMPTION: no real product, brand, sku, category or variant sku
-- contains the text 'T6D'. Expected orderings are computed from the table itself, so they do
-- not depend on the database collation.
-- NOT-EMPTY PROOF: every "denied" check has a positive control in which the admin gets a result.
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

-- admin_list_products(<args>) as a role.
create or replace function pg_temp.lst(p_k text, p_role text, p_uid uuid, p_args text default '')
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, 'select public.admin_list_products(' || p_args || ')::text');
end;
$$;

-- admin_get_product(<uuid>) as a role.
create or replace function pg_temp.dget(p_k text, p_role text, p_uid uuid, p_id uuid)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format('select public.admin_get_product(%L::uuid)::text', p_id));
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

-- List-result accessors.
create or replace function pg_temp.tot(p_k text) returns bigint language sql as $$
  select (res::jsonb ->> 'total')::bigint from t_res where k = p_k $$;
create or replace function pg_temp.n(p_k text) returns integer language sql as $$
  select jsonb_array_length(res::jsonb -> 'products') from t_res where k = p_k $$;
create or replace function pg_temp.prod(p_k text, p_id uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.j(p_k) -> 'products') e where e ->> 'id' = p_id::text $$;
-- Ids of the recorded list, in returned order, comma-joined.
create or replace function pg_temp.ids(p_k text) returns text language sql as $$
  select coalesce(string_agg(e ->> 'id', ',' order by n), '')
  from jsonb_array_elements(pg_temp.j(p_k) -> 'products') with ordinality as t(e, n) $$;
-- Ids of the recorded detail's variants, in returned order.
create or replace function pg_temp.vids(p_k text) returns text language sql as $$
  select coalesce(string_agg(e ->> 'id', ',' order by n), '')
  from jsonb_array_elements(pg_temp.j(p_k) -> 'variants') with ordinality as t(e, n) $$;
-- Ids (comma-joined, sorted) of a recorded list - for "same set" checks that ignore order.
create or replace function pg_temp.idset(p_k text) returns text language sql as $$
  select coalesce(string_agg(e ->> 'id', ',' order by e ->> 'id'), '')
  from jsonb_array_elements(pg_temp.j(p_k) -> 'products') e $$;

-- The fixture products (slug t6d-%) in the documented order (name, slug, id), rows o+1 .. o+l.
create or replace function pg_temp.exp_ids(p_offset integer, p_limit integer) returns text language sql as $$
  select coalesce(string_agg(id::text, ',' order by name, slug, id), '')
  from (select id, name, slug from public.products where slug like 't6d-%'
        order by name, slug, id offset p_offset limit p_limit) s $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d100000000' || n)::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d2000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.c(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d3000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6d4000000' || lpad(n::text, 3, '0'))::uuid $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6d-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6D Customer"}'),
  (pg_temp.u(2), 't6d-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6D Staff"}'),
  (pg_temp.u(3), 't6d-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6D Admin"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin');

-- c4 is a CHILD of c1 and inactive; c3 has no products at all.
insert into public.categories (id, slug, name, parent_id, is_active) values
  (pg_temp.c(1), 't6d-fruit',  'T6D Fruit',  null,        true),
  (pg_temp.c(2), 't6d-dairy',  'T6D Dairy',  null,        true),
  (pg_temp.c(3), 't6d-empty',  'T6D Empty',  null,        true),
  (pg_temp.c(4), 't6d-citrus', 'T6D Citrus', pg_temp.c(1), false);

insert into public.products
  (id, slug, name, category_id, brand, sku, price_cents, stock_quantity, in_stock, is_active)
values
  (pg_temp.p(1),  't6d-apple',  'T6D Apple',        pg_temp.c(1), 'T6D Orchard Co',    'T6D-APL-001', 250, 40, true,  true),
  (pg_temp.p(2),  't6d-banana', 'T6D Banana',       pg_temp.c(1), null,                'T6D-BAN-001', 100,  0, false, false),
  (pg_temp.p(3),  't6d-milk',   'T6D Milk',         pg_temp.c(2), 'T6D Dairyland Ltd', 'T6D-MLK-001', 180, 12, true,  true),
  (pg_temp.p(4),  't6d-uncat',  'T6D Uncategorised', null,        null,                null,           0,  3, false, false),
  (pg_temp.p(5),  't6d-lemon',  'T6D Lemon',        pg_temp.c(4), null,                'T6D-LEM-001',  90,  7, true,  true),
  (pg_temp.p(6),  't6d-pct',    'T6D 100% Juice',   null,         null,                null,          500,  1, true,  true),
  (pg_temp.p(7),  't6d-under',  'T6D Pure_Water',   null,         null,                null,           50,  1, true,  true),
  (pg_temp.p(8),  't6d-bslash', 'T6D Back' || chr(92) || 'slash', null, null,          null,           60,  1, true,  true),
  -- identical names: slug breaks the tie, and slug order (tie-a, tie-b) is the REVERSE of id order
  (pg_temp.p(9),  't6d-tie-b',  'T6D Tie',          null,         null,                null,           10,  1, true,  true),
  (pg_temp.p(10), 't6d-tie-a',  'T6D Tie',          null,         null,                null,           20,  1, true,  true),
  -- 'T6D PureXWater' matches the pattern 'T6D Pure_Water' ONLY if '_' is (wrongly) a wildcard
  (pg_temp.p(11), 't6d-purex',  'T6D PureXWater',   null,         null,                null,           55,  1, true,  true);

-- Variants of p1 (four, inserted OUT of order; v3 and v4 tie on position AND name, so the id decides),
-- and one variant of p3 (must never appear under p1 or p2).
insert into public.product_variants
  (id, product_id, name, sku, price_cents, stock_quantity, attributes, position, is_active)
values
  (pg_temp.v(1), pg_temp.p(1), 'T6D V-A', 'T6D-VAR-A',     250, 5, '{"size":"1kg"}'::jsonb, 3, true),
  (pg_temp.v(4), pg_temp.p(1), 'T6D V-M', 'T6D-VAR-D',     120, 2, '{}'::jsonb,             2, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6D V-Z', null,            100, 0, '{}'::jsonb,             1, false),
  (pg_temp.v(3), pg_temp.p(1), 'T6D V-M', 'T6D-VAR-SKU-3', 110, 9, '{"size":"2kg"}'::jsonb, 2, true),
  (pg_temp.v(5), pg_temp.p(3), 'T6D Milk 1L', 'T6D-MLK-1L', 180, 4, '{}'::jsonb,            1, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6d-%') = 11
  and (select count(*) from public.product_variants where sku like 'T6D-%' or product_id in (pg_temp.p(1), pg_temp.p(3))) = 5,
  'FIXTURE: eleven test products and five variants exist');
select pg_temp.ok(not exists (select 1 from public.products p where p.slug not like 't6d-%'
    and (p.name ilike '%T6D%' or p.sku ilike '%T6D%' or p.brand ilike '%T6D%')),
  'FIXTURE: no real product contains "T6D" (the scoping assumption of this test holds)');

-- Snapshot of the whole catalogue, to prove the functions write nothing.
create temp table t_snap as
select (select count(*) from public.products) as np,
       (select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p) as hp,
       (select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v) as hv,
       (select md5(coalesce(string_agg(c::text, '|' order by c.id), '')) from public.categories c) as hc;

-- ===========================================================================
-- A. LIST: BASICS, BACKWARDS COMPATIBILITY, RESULT SHAPE
-- ===========================================================================
select pg_temp.lst('a1', 'authenticated', pg_temp.u(3), $$p_search => 'T6D'$$);
select pg_temp.succeeded('a1', 'ADMIN: admin_list_products with a search succeeds');
select pg_temp.ok(pg_temp.keys(pg_temp.j('a1')) = 'limit,offset,products,total',
  'SHAPE: result has exactly total / limit / offset / products');
select pg_temp.ok(pg_temp.tot('a1') = 11 and pg_temp.n('a1') = 11
  and (pg_temp.j('a1') ->> 'limit')::integer = 50 and (pg_temp.j('a1') ->> 'offset')::integer = 0,
  'SHAPE: search T6D -> total 11, 11 rows, default limit 50 and offset 0 are echoed');
select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.prod('a1', pg_temp.p(1)))) = 16
  and pg_temp.keys(pg_temp.prod('a1', pg_temp.p(1))) =
      'brand,category_id,compare_at_price_cents,created_at,description,id,image_url,in_stock,is_active,name,price_cents,sku,slug,stock_quantity,unit_label,updated_at',
  'SHAPE: each product still carries exactly the 16 public.products columns (unchanged from 6C.1A.1)');
select pg_temp.ok(
  pg_temp.prod('a1', pg_temp.p(1)) ->> 'slug' = 't6d-apple'
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'category_id' = pg_temp.c(1)::text
  and pg_temp.prod('a1', pg_temp.p(1)) ->> 'sku' = 'T6D-APL-001'
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'price_cents')::integer = 250
  and (pg_temp.prod('a1', pg_temp.p(1)) ->> 'stock_quantity')::integer = 40
  and (pg_temp.prod('a1', pg_temp.p(2)) ->> 'is_active')::boolean is false
  and jsonb_typeof(pg_temp.prod('a1', pg_temp.p(4)) -> 'category_id') = 'null',
  'SHAPE: stored values come back unchanged (inactive products included, NULL columns as JSON null)');

-- No arguments at all, and the 6C.1A.1 calling styles.
select pg_temp.lst('a_noargs', 'authenticated', pg_temp.u(3));
select pg_temp.ok((pg_temp.j('a_noargs') ->> 'limit')::integer = 50 and (pg_temp.j('a_noargs') ->> 'offset')::integer = 0
  and pg_temp.tot('a_noargs') = (select count(*) from public.products)
  and pg_temp.n('a_noargs') = least(50, (select count(*) from public.products)),
  'COMPAT: admin_list_products() with no arguments still works; total counts ALL products; default limit 50');
select pg_temp.lst('a_pos', 'authenticated', pg_temp.u(3), '5');
select pg_temp.ok((pg_temp.j('a_pos') ->> 'limit')::integer = 5
  and pg_temp.n('a_pos') = least(5, (select count(*) from public.products)),
  'COMPAT: positional admin_list_products(5) is still the limit');
select pg_temp.lst('a_named', 'authenticated', pg_temp.u(3), 'p_limit => 5');
select pg_temp.ok(pg_temp.res('a_named') = pg_temp.res('a_pos'),
  'COMPAT: admin_list_products(p_limit => 5) equals admin_list_products(5)');

-- ===========================================================================
-- B. SEARCH
-- ===========================================================================
select pg_temp.lst('s_name', 'authenticated', pg_temp.u(3), $$p_search => 'T6D Banana'$$);
select pg_temp.ok(pg_temp.tot('s_name') = 1 and pg_temp.ids('s_name') = pg_temp.p(2)::text,
  'SEARCH: by product name (finds the INACTIVE product too)');
select pg_temp.lst('s_ci1', 'authenticated', pg_temp.u(3), $$p_search => 't6d aPPle'$$);
select pg_temp.lst('s_ci2', 'authenticated', pg_temp.u(3), $$p_search => 'T6D APPLE'$$);
select pg_temp.ok(pg_temp.ids('s_ci1') = pg_temp.p(1)::text and pg_temp.ids('s_ci2') = pg_temp.p(1)::text
  and pg_temp.tot('s_ci1') = 1 and pg_temp.tot('s_ci2') = 1,
  'SEARCH: case-insensitive (mixed case, upper case)');
select pg_temp.lst('s_sub', 'authenticated', pg_temp.u(3), $$p_search => 'T6D Lemo'$$);
select pg_temp.ok(pg_temp.ids('s_sub') = pg_temp.p(5)::text and pg_temp.tot('s_sub') = 1,
  'SEARCH: substring match (T6D Lemo finds T6D Lemon)');
select pg_temp.lst('s_sku', 'authenticated', pg_temp.u(3), $$p_search => 'T6D-MLK-001'$$);
select pg_temp.lst('s_sku2', 'authenticated', pg_temp.u(3), $$p_search => 't6d-mlk'$$);
select pg_temp.ok(pg_temp.ids('s_sku') = pg_temp.p(3)::text and pg_temp.tot('s_sku') = 1
  and pg_temp.ids('s_sku2') = pg_temp.p(3)::text,
  'SEARCH: by product SKU (exact and lower-case partial)');
select pg_temp.lst('s_slug', 'authenticated', pg_temp.u(3), $$p_search => 't6d-uncat'$$);
select pg_temp.ok(pg_temp.ids('s_slug') = pg_temp.p(4)::text and pg_temp.tot('s_slug') = 1,
  'SEARCH: by slug (the product NAME does not contain "t6d-uncat", the slug does)');
select pg_temp.lst('s_brand', 'authenticated', pg_temp.u(3), $$p_search => 'Dairyland Ltd'$$);
select pg_temp.ok(pg_temp.ids('s_brand') = pg_temp.p(3)::text and pg_temp.tot('s_brand') = 1,
  'SEARCH: by brand');
select pg_temp.lst('s_cat', 'authenticated', pg_temp.u(3), $$p_search => 'T6D Dairy'$$);
select pg_temp.ok(pg_temp.ids('s_cat') = pg_temp.p(3)::text and pg_temp.tot('s_cat') = 1,
  'SEARCH: by CATEGORY name (T6D Milk is found although its own fields do not contain "T6D Dairy")');
select pg_temp.lst('s_cat2', 'authenticated', pg_temp.u(3), $$p_search => 'T6D Fruit'$$);
select pg_temp.ok(pg_temp.idset('s_cat2') = (select string_agg(x, ',' order by x)
                                              from unnest(array[pg_temp.p(1)::text, pg_temp.p(2)::text]) x)
  and pg_temp.tot('s_cat2') = 2,
  'SEARCH: category name finds every product of that category only (not the child category''s product)');
select pg_temp.lst('s_var', 'authenticated', pg_temp.u(3), $$p_search => 'VAR-SKU-3'$$);
select pg_temp.ok(pg_temp.ids('s_var') = pg_temp.p(1)::text and pg_temp.tot('s_var') = 1,
  'SEARCH: by a VARIANT sku returns the parent product (once, although it has four variants)');
select pg_temp.lst('s_var2', 'authenticated', pg_temp.u(3), $$p_search => 'T6D-MLK-1L'$$);
select pg_temp.ok(pg_temp.ids('s_var2') = pg_temp.p(3)::text and pg_temp.tot('s_var2') = 1,
  'SEARCH: a variant sku of another product finds that product only');
select pg_temp.lst('s_none', 'authenticated', pg_temp.u(3), $$p_search => 'T6D-no-such-thing-zzz'$$);
select pg_temp.ok((select err from t_res where k = 's_none') is null and pg_temp.tot('s_none') = 0 and pg_temp.n('s_none') = 0
  and pg_temp.j('s_none') -> 'products' = '[]'::jsonb,
  'SEARCH: a term that matches nothing returns total 0 and an empty array, no error');
select pg_temp.lst('s_blank', 'authenticated', pg_temp.u(3), $$p_search => '   '$$);
select pg_temp.lst('s_null', 'authenticated', pg_temp.u(3), $$p_search => null$$);
select pg_temp.ok(pg_temp.tot('s_blank') = (select count(*) from public.products)
  and pg_temp.tot('s_null') = (select count(*) from public.products),
  'SEARCH: a blank or NULL search is ignored (all products)');
select pg_temp.lst('s_trim', 'authenticated', pg_temp.u(3), $$p_search => '   T6D Banana   '$$);
select pg_temp.ok(pg_temp.ids('s_trim') = pg_temp.p(2)::text, 'SEARCH: surrounding whitespace is trimmed');

-- Wildcard / escape handling: % _ \ are LITERAL.
select pg_temp.lst('w_pos', 'authenticated', pg_temp.u(3), $$p_search => 'T6D 100% Juice'$$);
select pg_temp.ok(pg_temp.ids('w_pos') = pg_temp.p(6)::text and pg_temp.tot('w_pos') = 1,
  'WILDCARD: a literal % in the input finds the product that really contains "%" (escaping is not broken)');
select pg_temp.lst('w_pct', 'authenticated', pg_temp.u(3), $$p_search => 'T6D%Juice'$$);
select pg_temp.ok(pg_temp.tot('w_pct') = 0,
  'WILDCARD: % is NOT a wildcard (an unescaped T6D%Juice would have matched "T6D 100% Juice")');
select pg_temp.lst('w_us', 'authenticated', pg_temp.u(3), $$p_search => 'T6D Pure_Water'$$);
select pg_temp.ok(pg_temp.ids('w_us') = pg_temp.p(7)::text and pg_temp.tot('w_us') = 1,
  'WILDCARD: _ is literal (matches "T6D Pure_Water" only, NOT "T6D PureXWater")');
select pg_temp.lst('w_bs', 'authenticated', pg_temp.u(3), format('p_search => %L', 'T6D Back' || chr(92) || 'slash'));
select pg_temp.ok(pg_temp.ids('w_bs') = pg_temp.p(8)::text and pg_temp.tot('w_bs') = 1,
  'WILDCARD: a backslash in the input is literal');
select pg_temp.lst('w_bs2', 'authenticated', pg_temp.u(3), format('p_search => %L', 'T6D Back' || chr(92)));
select pg_temp.ok((select err from t_res where k = 'w_bs2') is null and pg_temp.ids('w_bs2') = pg_temp.p(8)::text,
  'WILDCARD: a search ending in a backslash does not raise "LIKE pattern must not end with escape character"');
select pg_temp.lst('w_only_pct', 'authenticated', pg_temp.u(3), $$p_search => '%'$$);
select pg_temp.ok((select err from t_res where k = 'w_only_pct') is null
  and pg_temp.tot('w_only_pct') = (
    select count(*) from public.products p left join public.categories c on c.id = p.category_id
    where strpos(p.name, '%') > 0 or strpos(p.slug, '%') > 0 or strpos(coalesce(p.sku, ''), '%') > 0
       or strpos(coalesce(p.brand, ''), '%') > 0 or strpos(coalesce(c.name, ''), '%') > 0
       or exists (select 1 from public.product_variants v where v.product_id = p.id and strpos(coalesce(v.sku, ''), '%') > 0))
  and pg_temp.tot('w_only_pct') >= 1 and pg_temp.tot('w_only_pct') < (select count(*) from public.products),
  'WILDCARD: searching just "%" returns exactly the products containing a literal % (not everything)');
select pg_temp.lst('w_only_us', 'authenticated', pg_temp.u(3), $$p_search => '_'$$);
select pg_temp.ok((select err from t_res where k = 'w_only_us') is null
  and pg_temp.tot('w_only_us') = (
    select count(*) from public.products p left join public.categories c on c.id = p.category_id
    where strpos(p.name, '_') > 0 or strpos(p.slug, '_') > 0 or strpos(coalesce(p.sku, ''), '_') > 0
       or strpos(coalesce(p.brand, ''), '_') > 0 or strpos(coalesce(c.name, ''), '_') > 0
       or exists (select 1 from public.product_variants v where v.product_id = p.id and strpos(coalesce(v.sku, ''), '_') > 0)),
  'WILDCARD: searching just "_" returns exactly the products containing a literal _ (not everything)');
select pg_temp.lst('w_only_bs', 'authenticated', pg_temp.u(3), format('p_search => %L', chr(92)));
select pg_temp.ok((select err from t_res where k = 'w_only_bs') is null
  and pg_temp.tot('w_only_bs') = (
    select count(*) from public.products p left join public.categories c on c.id = p.category_id
    where strpos(p.name, chr(92)) > 0 or strpos(p.slug, chr(92)) > 0 or strpos(coalesce(p.sku, ''), chr(92)) > 0
       or strpos(coalesce(p.brand, ''), chr(92)) > 0 or strpos(coalesce(c.name, ''), chr(92)) > 0
       or exists (select 1 from public.product_variants v where v.product_id = p.id and strpos(coalesce(v.sku, ''), chr(92)) > 0)),
  'WILDCARD: searching just a backslash returns exactly the products containing one');

-- Injection attempt: the text is a bound value, never SQL.
select pg_temp.lst('s_inj', 'authenticated', pg_temp.u(3), $$p_search => '''; drop table public.products; --'$$);
select pg_temp.ok((select err from t_res where k = 's_inj') is null and pg_temp.tot('s_inj') = 0,
  'SEARCH: SQL metacharacters are inert (no error, no match)');

-- Search length bound.
select pg_temp.lst('s_100', 'authenticated', pg_temp.u(3), format('p_search => %L', repeat('x', 100)));
select pg_temp.succeeded('s_100', 'SEARCH: exactly 100 characters is accepted');
select pg_temp.lst('s_101', 'authenticated', pg_temp.u(3), format('p_search => %L', repeat('x', 101)));
select pg_temp.expect_err('s_101', 'P0001', 'invalid_arguments', 'SEARCH: 101 characters is rejected');

-- ===========================================================================
-- C. FILTERS
-- ===========================================================================
select pg_temp.lst('f_all', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_is_active => null$$);
select pg_temp.lst('f_act', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_is_active => true$$);
select pg_temp.lst('f_ina', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_is_active => false$$);
select pg_temp.ok(pg_temp.tot('f_all') = 11 and pg_temp.tot('f_act') = 9 and pg_temp.tot('f_ina') = 2,
  'FILTER: all = 11, active only = 9, inactive only = 2');
select pg_temp.ok(pg_temp.idset('f_ina') = (select string_agg(x, ',' order by x)
                                             from unnest(array[pg_temp.p(2)::text, pg_temp.p(4)::text]) x)
  and not exists (select 1 from jsonb_array_elements(pg_temp.j('f_act') -> 'products') e
                  where (e ->> 'is_active')::boolean is not true)
  and not exists (select 1 from jsonb_array_elements(pg_temp.j('f_ina') -> 'products') e
                  where (e ->> 'is_active')::boolean is not false),
  'FILTER: active-only rows are all active; inactive-only rows are exactly the two inactive fixtures');
select pg_temp.ok(pg_temp.tot('f_act') + pg_temp.tot('f_ina') = pg_temp.tot('f_all'),
  'FILTER: active + inactive = all');
select pg_temp.lst('f_ia', 'authenticated', pg_temp.u(3), 'p_is_active => false');
select pg_temp.lst('f_aa', 'authenticated', pg_temp.u(3), 'p_is_active => true');
select pg_temp.ok(pg_temp.tot('f_ia') = (select count(*) from public.products where not is_active)
  and pg_temp.tot('f_aa') = (select count(*) from public.products where is_active),
  'FILTER: without a search, active / inactive totals equal the table counts');

select pg_temp.lst('f_c1', 'authenticated', pg_temp.u(3), format('p_category_id => %L', pg_temp.c(1)));
select pg_temp.ok(pg_temp.tot('f_c1') = 2 and pg_temp.idset('f_c1') = (select string_agg(x, ',' order by x)
      from unnest(array[pg_temp.p(1)::text, pg_temp.p(2)::text]) x),
  'FILTER: category c1 returns its two products (active AND inactive); the child category''s product is NOT included');
select pg_temp.lst('f_c2', 'authenticated', pg_temp.u(3), format('p_category_id => %L', pg_temp.c(2)));
select pg_temp.ok(pg_temp.tot('f_c2') = 1 and pg_temp.ids('f_c2') = pg_temp.p(3)::text, 'FILTER: category c2 returns only T6D Milk');
select pg_temp.lst('f_c4', 'authenticated', pg_temp.u(3), format('p_category_id => %L', pg_temp.c(4)));
select pg_temp.ok(pg_temp.tot('f_c4') = 1 and pg_temp.ids('f_c4') = pg_temp.p(5)::text,
  'FILTER: the child category c4 returns only its own product (inactive category still filterable by admin)');
select pg_temp.lst('f_c3', 'authenticated', pg_temp.u(3), format('p_category_id => %L', pg_temp.c(3)));
select pg_temp.ok((select err from t_res where k = 'f_c3') is null and pg_temp.tot('f_c3') = 0 and pg_temp.n('f_c3') = 0,
  'FILTER: a category without products returns an empty list, no error');
select pg_temp.lst('f_cx', 'authenticated', pg_temp.u(3), $$p_category_id => '00000000-0000-4000-8000-6dffffffffff'$$);
select pg_temp.ok((select err from t_res where k = 'f_cx') is null and pg_temp.tot('f_cx') = 0,
  'FILTER: an unknown category id matches nothing, no error');

-- Combined
select pg_temp.lst('m1', 'authenticated', pg_temp.u(3), format('p_search => %L, p_is_active => false, p_category_id => %L', 'T6D', pg_temp.c(1)));
select pg_temp.ok(pg_temp.ids('m1') = pg_temp.p(2)::text and pg_temp.tot('m1') = 1,
  'COMBINED: search T6D + inactive + category c1 = T6D Banana only');
select pg_temp.lst('m2', 'authenticated', pg_temp.u(3), format('p_search => %L, p_is_active => true, p_category_id => %L', 'T6D', pg_temp.c(1)));
select pg_temp.ok(pg_temp.ids('m2') = pg_temp.p(1)::text and pg_temp.tot('m2') = 1,
  'COMBINED: search T6D + active + category c1 = T6D Apple only');
select pg_temp.lst('m3', 'authenticated', pg_temp.u(3), $$p_search => 'Dairyland Ltd', p_is_active => true$$);
select pg_temp.lst('m4', 'authenticated', pg_temp.u(3), $$p_search => 'Dairyland Ltd', p_is_active => false$$);
select pg_temp.ok(pg_temp.ids('m3') = pg_temp.p(3)::text and pg_temp.tot('m4') = 0,
  'COMBINED: brand search + active finds it; brand search + inactive finds nothing');
select pg_temp.lst('m5', 'authenticated', pg_temp.u(3), format('p_search => %L, p_category_id => %L', 'Apple', pg_temp.c(2)));
select pg_temp.ok(pg_temp.tot('m5') = 0, 'COMBINED: a search matching a product of another category is excluded by the category filter');
select pg_temp.lst('m6', 'authenticated', pg_temp.u(3), format('p_search => %L, p_category_id => %L', 'T6D', pg_temp.c(1)));
select pg_temp.ok(pg_temp.tot('m6') = 2, 'COMBINED: search T6D + category c1 = 2 (filters AND together; positive control for m1/m2)');

-- ===========================================================================
-- D. PAGINATION AND ORDERING   (scope: search 'T6D' = the 11 fixtures)
-- ===========================================================================
select pg_temp.lst('o_all', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 100$$);
select pg_temp.ok(pg_temp.ids('o_all') = pg_temp.exp_ids(0, 100) and pg_temp.n('o_all') = 11,
  'ORDER: returned ids equal the table ordered by name, slug, id (collation-independent check)');
select pg_temp.ok(
  position(pg_temp.p(10)::text in pg_temp.ids('o_all')) > 0
  and position(pg_temp.p(10)::text in pg_temp.ids('o_all')) < position(pg_temp.p(9)::text in pg_temp.ids('o_all')),
  'ORDER: same-name ties are broken by slug (tie-a, id p10, before tie-b, id p9) - NOT by id');
select pg_temp.lst('o_all2', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 100$$);
select pg_temp.ok(pg_temp.res('o_all') = pg_temp.res('o_all2'), 'ORDER: calling twice returns byte-identical output');

select pg_temp.lst('p_l3', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 3$$);
select pg_temp.ok(pg_temp.n('p_l3') = 3 and pg_temp.tot('p_l3') = 11 and (pg_temp.j('p_l3') ->> 'limit')::integer = 3
  and pg_temp.ids('p_l3') = pg_temp.exp_ids(0, 3),
  'PAGE: limit 3 -> first three rows in order; total still counts every match');
select pg_temp.lst('p_l3o3', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 3, p_offset => 3$$);
select pg_temp.ok(pg_temp.n('p_l3o3') = 3 and pg_temp.tot('p_l3o3') = 11 and (pg_temp.j('p_l3o3') ->> 'offset')::integer = 3
  and pg_temp.ids('p_l3o3') = pg_temp.exp_ids(3, 3),
  'PAGE: limit 3 offset 3 -> rows 4-6 (second page); offset is echoed');
select pg_temp.lst('p_l3o9', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 3, p_offset => 9$$);
select pg_temp.ok(pg_temp.n('p_l3o9') = 2 and pg_temp.ids('p_l3o9') = pg_temp.exp_ids(9, 3),
  'PAGE: last, partial page (offset 9, limit 3) -> the final 2 rows');

-- Walk the whole result in pages of 4: no row duplicated, none skipped.
select pg_temp.lst('w0', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 4, p_offset => 0$$);
select pg_temp.lst('w4', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 4, p_offset => 4$$);
select pg_temp.lst('w8', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 4, p_offset => 8$$);
select pg_temp.ok(pg_temp.n('w0') = 4 and pg_temp.n('w4') = 4 and pg_temp.n('w8') = 3
  and pg_temp.ids('w0') || ',' || pg_temp.ids('w4') || ',' || pg_temp.ids('w8') = pg_temp.exp_ids(0, 100),
  'PAGE: pages of 4 concatenate to the full ordered list (no duplicate, no skipped row)');
select pg_temp.ok((select count(distinct x) from unnest(string_to_array(
        pg_temp.ids('w0') || ',' || pg_temp.ids('w4') || ',' || pg_temp.ids('w8'), ',')) x) = 11,
  'PAGE: the 11 rows across the three pages are 11 DISTINCT products');
select pg_temp.lst('w_one', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 1, p_offset => 10$$);
select pg_temp.ok(pg_temp.n('w_one') = 1 and pg_temp.ids('w_one') = pg_temp.exp_ids(10, 1), 'PAGE: limit 1 offset 10 -> the very last row');
select pg_temp.lst('w_edge', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 10, p_offset => 11$$);
select pg_temp.ok(pg_temp.n('w_edge') = 0 and pg_temp.tot('w_edge') = 11 and pg_temp.j('w_edge') -> 'products' = '[]'::jsonb,
  'PAGE: offset == total -> empty page, total still 11');
select pg_temp.lst('w_big', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_offset => 1000000$$);
select pg_temp.ok((select err from t_res where k = 'w_big') is null and pg_temp.n('w_big') = 0 and pg_temp.tot('w_big') = 11
  and (pg_temp.j('w_big') ->> 'offset')::integer = 1000000,
  'PAGE: a very large offset is accepted: empty page, correct total, no error');
select pg_temp.lst('w_max', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_offset => 2147483647$$);
select pg_temp.ok((select err from t_res where k = 'w_max') is null and pg_temp.n('w_max') = 0 and pg_temp.tot('w_max') = 11,
  'PAGE: offset 2147483647 (integer max) is accepted: empty page, no overflow');

-- Limit boundaries
select pg_temp.lst('b_1', 'authenticated', pg_temp.u(3), 'p_limit => 1');
select pg_temp.ok(pg_temp.n('b_1') = 1 and pg_temp.ids('b_1') = (select id::text from public.products order by name, slug, id limit 1),
  'LIMIT: lower bound 1 is accepted and returns the first row in order');
select pg_temp.lst('b_100', 'authenticated', pg_temp.u(3), 'p_limit => 100');
select pg_temp.ok(pg_temp.n('b_100') = least(100, (select count(*) from public.products)) and pg_temp.ids('b_100') = (
    select coalesce(string_agg(id::text, ',' order by name, slug, id), '')
    from (select id, name, slug from public.products order by name, slug, id limit 100) s),
  'LIMIT: upper bound 100 is accepted and returns the first 100 rows in order');
select pg_temp.lst('b_11', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 11$$);
select pg_temp.lst('b_10', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 10$$);
select pg_temp.ok(pg_temp.n('b_11') = 11 and pg_temp.n('b_10') = 10 and pg_temp.tot('b_10') = 11,
  'LIMIT: limit == total returns all; limit == total-1 returns total-1 rows but total stays 11 (UI can tell it is truncated)');
select pg_temp.lst('b_0',   'authenticated', pg_temp.u(3), 'p_limit => 0');
select pg_temp.lst('b_101', 'authenticated', pg_temp.u(3), 'p_limit => 101');
select pg_temp.lst('b_neg', 'authenticated', pg_temp.u(3), 'p_limit => -5');
select pg_temp.lst('b_nul', 'authenticated', pg_temp.u(3), 'p_limit => null');
select pg_temp.expect_err('b_0',   'P0001', 'invalid_arguments', 'LIMIT: 0 is rejected for an admin');
select pg_temp.expect_err('b_101', 'P0001', 'invalid_arguments', 'LIMIT: 101 is rejected for an admin');
select pg_temp.expect_err('b_neg', 'P0001', 'invalid_arguments', 'LIMIT: a negative limit is rejected for an admin');
select pg_temp.expect_err('b_nul', 'P0001', 'invalid_arguments', 'LIMIT: NULL is rejected for an admin');
select pg_temp.lst('o_neg', 'authenticated', pg_temp.u(3), 'p_offset => -1');
select pg_temp.lst('o_nul', 'authenticated', pg_temp.u(3), 'p_offset => null');
select pg_temp.expect_err('o_neg', 'P0001', 'invalid_arguments', 'OFFSET: a negative offset is rejected for an admin');
select pg_temp.expect_err('o_nul', 'P0001', 'invalid_arguments', 'OFFSET: NULL is rejected for an admin');
select pg_temp.lst('o_zero', 'authenticated', pg_temp.u(3), 'p_offset => 0');
select pg_temp.succeeded('o_zero', 'OFFSET: 0 is accepted');

-- ===========================================================================
-- E. PRODUCT DETAILS
-- ===========================================================================
select pg_temp.dget('d1', 'authenticated', pg_temp.u(3), pg_temp.p(1));
select pg_temp.succeeded('d1', 'DETAIL: admin reads a product with variants');
select pg_temp.ok(pg_temp.keys(pg_temp.j('d1')) = 'category,product,variants',
  'DETAIL: result has exactly product / category / variants');
select pg_temp.ok(pg_temp.j('d1') -> 'product' ->> 'id' = pg_temp.p(1)::text
  and pg_temp.j('d1') -> 'product' ->> 'slug' = 't6d-apple'
  and pg_temp.j('d1') -> 'product' ->> 'name' = 'T6D Apple'
  and pg_temp.j('d1') -> 'product' ->> 'sku' = 'T6D-APL-001'
  and (pg_temp.j('d1') -> 'product' ->> 'price_cents')::integer = 250
  and (select count(*) from jsonb_object_keys(pg_temp.j('d1') -> 'product')) = 16,
  'DETAIL: the product is the requested one, with the same 16 columns as the list');
select pg_temp.lst('d_l', 'authenticated', pg_temp.u(3), $$p_search => 'T6D', p_limit => 100$$);
select pg_temp.ok(pg_temp.j('d1') -> 'product' = pg_temp.prod('d_l', pg_temp.p(1)),
  'DETAIL: product block is identical to the list element for the same product');
select pg_temp.ok(pg_temp.keys(pg_temp.j('d1') -> 'category') = 'id,is_active,name,parent_id,slug'
  and pg_temp.j('d1') -> 'category' ->> 'id' = pg_temp.c(1)::text
  and pg_temp.j('d1') -> 'category' ->> 'slug' = 't6d-fruit'
  and pg_temp.j('d1') -> 'category' ->> 'name' = 'T6D Fruit'
  and jsonb_typeof(pg_temp.j('d1') -> 'category' -> 'parent_id') = 'null'
  and (pg_temp.j('d1') -> 'category' ->> 'is_active')::boolean is true,
  'DETAIL: category is correct and exposes only id, slug, name, parent_id, is_active');

-- Variants: only this product's, deterministic order (position, name, id), inactive included.
select pg_temp.ok(jsonb_array_length(pg_temp.j('d1') -> 'variants') = 4
  and not exists (select 1 from jsonb_array_elements(pg_temp.j('d1') -> 'variants') e where e ->> 'product_id' <> pg_temp.p(1)::text)
  and position(pg_temp.v(5)::text in pg_temp.res('d1')) = 0,
  'VARIANTS: exactly the four variants of this product; every product_id matches; the other product''s variant is absent');
select pg_temp.ok(pg_temp.vids('d1') = pg_temp.v(2)::text || ',' || pg_temp.v(3)::text || ',' || pg_temp.v(4)::text || ',' || pg_temp.v(1)::text,
  'VARIANTS: ordered by position (1,2,2,3); the position+name tie is broken by id (v3 before v4)');
select pg_temp.ok(pg_temp.vids('d1') = (select string_agg(id::text, ',' order by position, name, id)
                                         from public.product_variants where product_id = pg_temp.p(1)),
  'VARIANTS: order equals the table ordered by position, name, id');
select pg_temp.dget('d1b', 'authenticated', pg_temp.u(3), pg_temp.p(1));
select pg_temp.ok(pg_temp.res('d1') = pg_temp.res('d1b'), 'VARIANTS: calling twice returns byte-identical output');
select pg_temp.ok(
  (select count(*) from jsonb_object_keys(pg_temp.j('d1') -> 'variants' -> 0)) = 12
  and pg_temp.keys(pg_temp.j('d1') -> 'variants' -> 0) =
      'attributes,compare_at_price_cents,created_at,id,is_active,name,position,price_cents,product_id,sku,stock_quantity,updated_at',
  'VARIANTS: each variant carries exactly the 12 existing product_variants columns');
select pg_temp.ok(
  (pg_temp.j('d1') -> 'variants' -> 0 ->> 'is_active')::boolean is false
  and jsonb_typeof(pg_temp.j('d1') -> 'variants' -> 0 -> 'sku') = 'null'
  and (pg_temp.j('d1') -> 'variants' -> 0 ->> 'stock_quantity')::integer = 0
  and pg_temp.j('d1') -> 'variants' -> 1 ->> 'sku' = 'T6D-VAR-SKU-3'
  and pg_temp.j('d1') -> 'variants' -> 1 -> 'attributes' ->> 'size' = '2kg'
  and (pg_temp.j('d1') -> 'variants' -> 1 ->> 'price_cents')::integer = 110
  and (pg_temp.j('d1') -> 'variants' -> 1 ->> 'stock_quantity')::integer = 9,
  'VARIANTS: stored values returned as-is (INACTIVE variant included, NULL sku as JSON null, attributes object, stock as stored)');

select pg_temp.dget('d3', 'authenticated', pg_temp.u(3), pg_temp.p(3));
select pg_temp.ok(pg_temp.vids('d3') = pg_temp.v(5)::text and jsonb_array_length(pg_temp.j('d3') -> 'variants') = 1
  and pg_temp.j('d3') -> 'category' ->> 'id' = pg_temp.c(2)::text,
  'DETAIL: a second product returns only its own single variant and its own category (no cross-product leakage)');
select pg_temp.dget('d2', 'authenticated', pg_temp.u(3), pg_temp.p(2));
select pg_temp.ok(pg_temp.j('d2') -> 'variants' = '[]'::jsonb and pg_temp.j('d2') -> 'product' ->> 'id' = pg_temp.p(2)::text
  and (pg_temp.j('d2') -> 'product' ->> 'is_active')::boolean is false,
  'DETAIL: an INACTIVE product without variants returns variants = [] (admin can read it)');
select pg_temp.dget('d4', 'authenticated', pg_temp.u(3), pg_temp.p(4));
select pg_temp.ok(jsonb_typeof(pg_temp.j('d4') -> 'category') = 'null' and pg_temp.j('d4') -> 'variants' = '[]'::jsonb,
  'DETAIL: a product without a category returns category = JSON null');
select pg_temp.dget('d5', 'authenticated', pg_temp.u(3), pg_temp.p(5));
select pg_temp.ok(pg_temp.j('d5') -> 'category' ->> 'id' = pg_temp.c(4)::text
  and pg_temp.j('d5') -> 'category' ->> 'parent_id' = pg_temp.c(1)::text
  and (pg_temp.j('d5') -> 'category' ->> 'is_active')::boolean is false,
  'DETAIL: category parent_id and an inactive category are returned correctly');

-- Unknown / invalid ids
select pg_temp.dget('d_nf', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6dffffffffff');
select pg_temp.expect_err('d_nf', 'P0001', 'product_not_found', 'DETAIL: an unknown product id raises P0001 / product_not_found');
select pg_temp.run('d_nul', 'authenticated', pg_temp.u(3), 'select public.admin_get_product(null)::text');
select pg_temp.expect_err('d_nul', 'P0001', 'invalid_arguments', 'DETAIL: a NULL product id raises P0001 / invalid_arguments');
select pg_temp.run('d_bad', 'authenticated', pg_temp.u(3), $$select public.admin_get_product('not-a-uuid')::text$$);
select pg_temp.ok((select err from t_res where k = 'd_bad') is not null and pg_temp.res('d_bad') is null
  and (select state from t_res where k = 'd_bad') = '22P02',
  'DETAIL: a malformed id is rejected by the uuid type (22P02) before any data is read');
select pg_temp.dget('d_var_id', 'authenticated', pg_temp.u(3), pg_temp.v(1));
select pg_temp.expect_err('d_var_id', 'P0001', 'product_not_found', 'DETAIL: passing a VARIANT id is not a product id -> product_not_found');
select pg_temp.dget('d_cat_id', 'authenticated', pg_temp.u(3), pg_temp.c(1));
select pg_temp.expect_err('d_cat_id', 'P0001', 'product_not_found', 'DETAIL: passing a CATEGORY id is not a product id -> product_not_found');

-- ===========================================================================
-- F. AUTHORIZATION (both functions; denial is an ERROR 42501, never "0 rows")
-- ===========================================================================
-- Runs BOTH functions as one identity; results are recorded as <tag>_l and <tag>_g.
create or replace function pg_temp.authz(p_tag text, p_role text, p_claims jsonb)
returns void language plpgsql as $$
begin
  perform pg_temp.run_claims(p_tag || '_l', p_role, p_claims,
    $q$select public.admin_list_products(p_search => 'T6D')::text$q$);
  perform pg_temp.run_claims(p_tag || '_g', p_role, p_claims,
    format('select public.admin_get_product(%L::uuid)::text', pg_temp.p(1)));
end;
$$;
create or replace function pg_temp.both_gated(p_tag text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.gated(p_tag || '_l', 'LIST: ' || p_name);
  perform pg_temp.gated(p_tag || '_g', 'DETAIL: ' || p_name);
end;
$$;
create or replace function pg_temp.both_no_execute(p_tag text, p_name text)
returns void language plpgsql as $$
begin
  perform pg_temp.no_execute(p_tag || '_l', 'LIST: ' || p_name);
  perform pg_temp.no_execute(p_tag || '_g', 'DETAIL: ' || p_name);
end;
$$;

-- admin: positive control
select pg_temp.authz('z_admin', 'authenticated', jsonb_build_object('sub', pg_temp.u(3), 'role', 'authenticated'));
select pg_temp.succeeded('z_admin_l', 'ADMIN: list succeeds');
select pg_temp.succeeded('z_admin_g', 'ADMIN: detail succeeds');
select pg_temp.ok(pg_temp.tot('z_admin_l') = 11 and pg_temp.j('z_admin_g') -> 'product' ->> 'id' = pg_temp.p(1)::text,
  'CONTROL: the admin gets the real fixture data every refused caller below is denied');

-- staff / customer
select pg_temp.authz('z_staff', 'authenticated', jsonb_build_object('sub', pg_temp.u(2), 'role', 'authenticated'));
select pg_temp.both_gated('z_staff', 'STAFF is refused by the admin gate (42501 / not_authorised)');
select pg_temp.authz('z_cust', 'authenticated', jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated'));
select pg_temp.both_gated('z_cust', 'CUSTOMER is refused by the admin gate (42501 / not_authorised)');

-- anon (even carrying the admin user id in its claims) and signed out
select pg_temp.authz('z_anon', 'anon', jsonb_build_object('sub', pg_temp.u(3), 'role', 'anon'));
select pg_temp.both_no_execute('z_anon', 'ANON: EXECUTE is denied even with the admin user id in its claims');
select pg_temp.authz('z_out', 'anon', null);
select pg_temp.both_no_execute('z_out', 'SIGNED OUT (anon, no JWT at all): EXECUTE is denied');

-- authenticated DB role but no usable identity
select pg_temp.authz('z_nouid', 'authenticated', null);
select pg_temp.both_gated('z_nouid', 'SIGNED OUT (authenticated role, no JWT subject) is refused by the gate');
select pg_temp.authz('z_nosub', 'authenticated', '{"role":"authenticated"}'::jsonb);
select pg_temp.both_gated('z_nosub', 'JWT WITHOUT a subject is refused by the gate');

-- forged / non-admin JWTs
select pg_temp.authz('z_f1', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin'));
select pg_temp.both_gated('z_f1', 'FORGED: customer JWT with a top-level user_role=admin claim is refused');
select pg_temp.authz('z_f2', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin')));
select pg_temp.both_gated('z_f2', 'FORGED: customer JWT with app_metadata/user_metadata role=admin is refused');
select pg_temp.authz('z_f3', 'authenticated', jsonb_build_object('sub', pg_temp.u(1), 'role', 'service_role'));
select pg_temp.both_gated('z_f3', 'FORGED: customer JWT claiming role=service_role (DB role still authenticated) is refused');
select pg_temp.authz('z_f4', 'authenticated',
  jsonb_build_object('sub', '00000000-0000-4000-8000-6dffffffffff', 'role', 'authenticated'));
select pg_temp.both_gated('z_f4', 'NONEXISTENT USER: a well-formed JWT for a user id that does not exist is refused');
select pg_temp.authz('z_f5', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(2), 'role', 'authenticated', 'is_admin', true, 'admin', true));
select pg_temp.both_gated('z_f5', 'FORGED: staff JWT with is_admin / admin = true claims is refused');
select pg_temp.authz('z_f6', 'authenticated', jsonb_build_object('sub', pg_temp.u(1), 'role', 'admin'));
select pg_temp.both_gated('z_f6', 'FORGED: customer JWT with role=admin is refused');
select pg_temp.authz('z_f7', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'service_role', 'app_metadata', jsonb_build_object('role', 'service_role')));
select pg_temp.both_gated('z_f7', 'FORGED: customer JWT with service_role in role and app_metadata is refused');

-- service_role carries no admin identity, so it does not pass the gate either
select pg_temp.authz('z_svc', 'service_role', null);
select pg_temp.both_gated('z_svc', 'SERVICE ROLE without an admin user is refused by the gate (no auth.uid())');
select pg_temp.authz('z_svc2', 'service_role', jsonb_build_object('sub', pg_temp.u(1), 'role', 'service_role'));
select pg_temp.both_gated('z_svc2', 'SERVICE ROLE acting for a customer id is refused by the gate');

-- the gate runs BEFORE argument validation: a refused caller learns nothing about the arguments
select pg_temp.lst('g1', 'authenticated', pg_temp.u(1), 'p_limit => 0');
select pg_temp.gated('g1', 'GATE ORDER: customer with an invalid limit gets not_authorised, not invalid_arguments');
select pg_temp.lst('g2', 'authenticated', pg_temp.u(2), 'p_offset => -1');
select pg_temp.gated('g2', 'GATE ORDER: staff with a negative offset gets not_authorised');
select pg_temp.lst('g3', 'authenticated', pg_temp.u(2), format('p_search => %L', repeat('x', 500)));
select pg_temp.gated('g3', 'GATE ORDER: staff with an over-long search gets not_authorised');
select pg_temp.run('g4', 'authenticated', pg_temp.u(1), 'select public.admin_get_product(null)::text');
select pg_temp.gated('g4', 'GATE ORDER: customer with a NULL product id gets not_authorised, not invalid_arguments');
select pg_temp.dget('g5', 'authenticated', pg_temp.u(2), '00000000-0000-4000-8000-6dffffffffff');
select pg_temp.gated('g5', 'GATE ORDER: staff asking for an unknown product gets not_authorised, not product_not_found');
select pg_temp.dget('g6', 'authenticated', pg_temp.u(1), pg_temp.p(2));
select pg_temp.gated('g6', 'GATE ORDER: a customer cannot read an INACTIVE product through admin_get_product');

-- direct calls to the gate by browser roles still fail outright
select pg_temp.run('g_ra1', 'authenticated', pg_temp.u(3), 'select public.require_admin()::text');
select pg_temp.no_execute('g_ra1', 'GATE: even an admin cannot call require_admin() directly');

-- ===========================================================================
-- G. SECURITY METADATA
-- ===========================================================================
select pg_temp.ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') = 1
  and to_regprocedure('public.admin_list_products(integer)') is null
  and to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is not null,
  'META: exactly one admin_list_products exists and it is the new 5-argument signature (the 1-argument overload is gone)');
select pg_temp.ok(
  (select proargnames::text from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure)
    = '{p_limit,p_offset,p_search,p_is_active,p_category_id}'
  and (select oidvectortypes(proargtypes) from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure)
    = 'integer, integer, text, boolean, uuid'
  and (select pronargdefaults from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) = 5
  and pg_get_function_result('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure) = 'jsonb',
  'META: admin_list_products(p_limit, p_offset, p_search, p_is_active, p_category_id) returns jsonb; p_limit stays first; all 5 have defaults');
select pg_temp.ok(
  pg_get_function_arguments('public.admin_get_product(uuid)'::regprocedure) = 'p_product_id uuid'
  and pg_get_function_result('public.admin_get_product(uuid)'::regprocedure) = 'jsonb'
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_get_product') = 1,
  'META: admin_get_product(p_product_id uuid) returns jsonb, no overloads');

select pg_temp.ok((select bool_and(prosecdef) from pg_proc
                   where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                                 'public.admin_get_product(uuid)'::regprocedure)),
  'META: both functions are SECURITY DEFINER');
select pg_temp.ok((select bool_and(provolatile = 's') from pg_proc
                   where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                                 'public.admin_get_product(uuid)'::regprocedure)),
  'META: both functions are STABLE (read-only by declaration)');
select pg_temp.ok((select bool_and(proconfig::text like '%search_path=public, pg_temp%' and array_length(proconfig, 1) = 1)
                   from pg_proc
                   where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                                 'public.admin_get_product(uuid)'::regprocedure)),
  'META: search_path is pinned to exactly "public, pg_temp" on both (and nothing else is set)');
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('p_limit is null' in prosrc)
   from pg_proc where oid = 'public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure)
  and (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('p_product_id is null' in prosrc)
   from pg_proc where oid = 'public.admin_get_product(uuid)'::regprocedure),
  'META: both bodies call public.require_admin() before they look at any argument');
select pg_temp.ok(
  (select bool_and(prosrc !~* '(^|[^a-z_])(insert\s+into|update\s+(public\.)?[a-z_]+\s+set|delete\s+from|truncate\s|merge\s+into)')
   from pg_proc where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                              'public.admin_get_product(uuid)'::regprocedure)),
  'META: neither body contains INSERT INTO / UPDATE .. SET / DELETE FROM / TRUNCATE / MERGE INTO');
select pg_temp.ok(
  (select bool_and(prosrc !~* '(execute\s|format\s*\(|quote_literal|quote_ident)')
   from pg_proc where oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                              'public.admin_get_product(uuid)'::regprocedure)),
  'META: neither body uses dynamic SQL (no EXECUTE / format / quote_*): user input can only be a bound value');

select pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_product(uuid)', 'EXECUTE'),
  'GRANTS: anon has no EXECUTE on either function');
select pg_temp.ok(has_function_privilege('authenticated', 'public.admin_list_products(integer,integer,text,boolean,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_get_product(uuid)', 'EXECUTE'),
  'GRANTS: authenticated has EXECUTE (the gate then restricts it to admins)');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                    'public.admin_get_product(uuid)'::regprocedure)
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'GRANTS: PUBLIC has no EXECUTE on either function');
select pg_temp.ok(not exists (
    select 1 from pg_proc p, aclexplode(p.proacl) a
    where p.oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                    'public.admin_get_product(uuid)'::regprocedure)
      and a.grantee not in (p.proowner, (select oid from pg_roles where rolname = 'authenticated'),
                            coalesce((select oid from pg_roles where rolname = 'service_role'), -1))),
  'GRANTS: EXECUTE is held only by the owner, authenticated and (Supabase default) service_role');
select pg_temp.ok(not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'GRANTS: require_admin() is still not callable directly by anon or authenticated');
select pg_temp.ok((select bool_and(r.rolname not in ('anon', 'authenticated', 'service_role'))
                   from pg_proc p join pg_roles r on r.oid = p.proowner
                   where p.oid in ('public.admin_list_products(integer,integer,text,boolean,uuid)'::regprocedure,
                                   'public.admin_get_product(uuid)'::regprocedure)),
  'GRANTS: both functions are owned by a privileged owner role, not by a browser role');
select pg_temp.ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef
                   and not exists (select 1 from pg_depend d where d.objid = pg_proc.oid and d.deptype = 'e')
                   and coalesce(proconfig::text, '') not like '%search_path=public, pg_temp%') = 0,
  'META: every SECURITY DEFINER function in public still has a pinned search_path');

-- ===========================================================================
-- H. NO MUTATION
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
  has_table_privilege('authenticated', 'public.products', 'SELECT') and has_table_privilege('anon', 'public.products', 'SELECT'),
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
select pg_temp.run('w_a1', 'authenticated', pg_temp.u(3), $$with u as (update public.products set name = 'T6D hacked' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_a2', 'authenticated', pg_temp.u(3), $$with i as (insert into public.products (slug, name) values ('t6d-new', 'T6D new') returning 1) select count(*)::text from i$$);
select pg_temp.run('w_a3', 'authenticated', pg_temp.u(3), $$with d as (delete from public.products returning 1) select count(*)::text from d$$);
select pg_temp.run('w_s1', 'authenticated', pg_temp.u(2), $$with u as (update public.products set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_c1', 'authenticated', pg_temp.u(1), $$with u as (update public.products set is_active = false returning 1) select count(*)::text from u$$);
select pg_temp.run('w_n1', 'anon', null, $$with u as (update public.products set name = 'x' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_v1', 'authenticated', pg_temp.u(3), $$with u as (update public.product_variants set price_cents = 1 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_v2', 'authenticated', pg_temp.u(3), $$with u as (update public.product_variants set stock_quantity = 99 returning 1) select count(*)::text from u$$);
select pg_temp.run('w_v3', 'authenticated', pg_temp.u(3), $$with i as (insert into public.product_variants (product_id, name, price_cents) select id, 'x', 1 from public.products limit 1 returning 1) select count(*)::text from i$$);
select pg_temp.run('w_v4', 'authenticated', pg_temp.u(3), $$with d as (delete from public.product_variants returning 1) select count(*)::text from d$$);
select pg_temp.run('w_k1', 'authenticated', pg_temp.u(3), $$with u as (update public.categories set name = 'x' returning 1) select count(*)::text from u$$);
select pg_temp.run('w_p1', 'authenticated', pg_temp.u(3), $$with u as (update public.products set stock_quantity = 99 returning 1) select count(*)::text from u$$);
select pg_temp.write_denied('w_a1', 'WRITE: admin cannot UPDATE products directly');
select pg_temp.write_denied('w_a2', 'WRITE: admin cannot INSERT products directly');
select pg_temp.write_denied('w_a3', 'WRITE: admin cannot DELETE products directly');
select pg_temp.write_denied('w_s1', 'WRITE: staff cannot UPDATE products');
select pg_temp.write_denied('w_c1', 'WRITE: customer cannot UPDATE products (no activation/deactivation path)');
select pg_temp.write_denied('w_n1', 'WRITE: anon cannot UPDATE products');
select pg_temp.write_denied('w_v1', 'WRITE: admin cannot UPDATE product_variants (price)');
select pg_temp.write_denied('w_v2', 'WRITE: admin cannot UPDATE product_variants (stock)');
select pg_temp.write_denied('w_v3', 'WRITE: admin cannot INSERT product_variants');
select pg_temp.write_denied('w_v4', 'WRITE: admin cannot DELETE product_variants');
select pg_temp.write_denied('w_k1', 'WRITE: admin cannot UPDATE categories');
select pg_temp.write_denied('w_p1', 'WRITE: admin cannot UPDATE product stock (no inventory write path)');

-- No product / variant / category / SKU / inventory mutation FUNCTION: the only matching names are the two readers.
select pg_temp.ok((select array_agg(proname::text order by proname::text) from pg_proc
                   where pronamespace = 'public'::regnamespace
                     and (proname ilike '%product%' or proname ilike '%variant%' or proname ilike '%categor%'
                          or proname ilike '%sku%' or proname ilike '%inventor%'))
  = array['admin_adjust_inventory', 'admin_create_category', 'admin_create_product', 'admin_create_product_variant', 'admin_get_inventory', 'admin_get_product',
                'admin_list_inventory', 'admin_list_inventory_adjustments', 'admin_list_products',
                'admin_set_category_image', 'admin_set_product_active', 'admin_set_product_image', 'admin_update_category', 'admin_update_product', 'admin_update_product_variant',
                'inventory_adjustments_guard', 'inventory_log_stock_change', 'inventory_order_ctx_clear', 'inventory_order_ctx_set'],
  'FUNCS: the only product/variant/category/SKU/inventory-named functions in public are the two readers, (6C.1B.1) admin_create_product / admin_update_product and (6C.1B.2) admin_set_product_active / admin_create_product_variant / admin_update_product_variant and (6C.2.1) admin_list_inventory / admin_get_inventory and (6C.2.2A.2) admin_adjust_inventory and (6C.2.2B.1) admin_list_inventory_adjustments and (9B) the four inventory_* trigger functions');
select pg_temp.ok(not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
                              and c.relname ~* '(inventor|stock)' and c.relname <> 'inventory_adjustments'),
  'INVENTORY: no inventory / stock-movement / history table exists except the 6C.2.2A.1 audit table inventory_adjustments (which is not a stock source; see phase6c2_inventory_adjustment_history.test.sql)');
select pg_temp.ok(not exists (
    select 1 from pg_trigger t
    where not t.tgisinternal and t.tgrelid in ('public.products'::regclass, 'public.product_variants'::regclass, 'public.categories'::regclass)
      and t.tgfoid::regproc::text not in ('set_updated_at', 'public.set_updated_at', 'inventory_log_stock_change', 'public.inventory_log_stock_change')),
  'TRIGGERS: the catalogue tables carry no trigger other than the existing updated_at one');
-- The only functions that write products/variants are the pre-existing order-lifecycle ones; this phase added none.
select pg_temp.ok(
  (select coalesce(array_agg(p.proname::text order by p.proname::text), '{}') from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('admin_list_products', 'admin_get_product')
     and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(public\.)?(products|product_variants|categories)\M') = '{}',
  'FUNCS: neither new function writes products, product_variants or categories');

-- Read-only in practice: nothing about the catalogue changed during all the calls above.
select pg_temp.ok(
  (select s.np = (select count(*) from public.products)
      and s.hp = (select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) from public.products p)
      and s.hv = (select md5(coalesce(string_agg(v::text, '|' order by v.id), '')) from public.product_variants v)
      and s.hc = (select md5(coalesce(string_agg(c::text, '|' order by c.id), '')) from public.categories c)
   from t_snap s),
  'READ-ONLY: product, variant and category tables are byte-identical after all admin calls, injection attempts and blocked writes');

-- Existing storefront behaviour is untouched.
select pg_temp.run('s_anon', 'anon', null, $$select string_agg(slug, ',' order by slug) from public.products where slug like 't6d-%'$$);
select pg_temp.ok(pg_temp.res('s_anon') not like '%t6d-banana%' and pg_temp.res('s_anon') not like '%t6d-uncat%'
  and pg_temp.res('s_anon') like '%t6d-apple%',
  'STOREFRONT: anon still sees only ACTIVE fixture products (existing public RLS unchanged)');
select pg_temp.run('s_var', 'anon', null, $$select count(*)::text from public.product_variants where product_id = '00000000-0000-4000-8000-6d2000000001'$$);
select pg_temp.ok(pg_temp.res('s_var') = '3', 'STOREFRONT: anon still sees only the 3 ACTIVE variants of the active product (not the inactive one)');
select pg_temp.run('s_staff', 'authenticated', pg_temp.u(2), $$select count(*)::text from public.products where slug like 't6d-%'$$);
select pg_temp.ok(pg_temp.res('s_staff') = '9', 'STOREFRONT: staff still sees only the 9 active products directly (no new staff catalogue access)');
select pg_temp.run('s_admin', 'authenticated', pg_temp.u(3), $$select count(*)::text from public.products where slug like 't6d-%'$$);
select pg_temp.ok(pg_temp.res('s_admin') = '11', 'STOREFRONT: admin still sees all 11 fixture products directly (existing 6A admin read policy)');

-- ===========================================================================
-- I. REGRESSION: earlier admin functions are intact
-- ===========================================================================
select pg_temp.ok(
  to_regprocedure('public.require_admin()') is not null
  and to_regprocedure('public.is_admin(uuid)') is not null
  and to_regprocedure('public.is_staff(uuid)') is not null
  and to_regprocedure('public.admin_dashboard_summary(integer,integer)') is not null
  and to_regprocedure('public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)') is not null
  and to_regprocedure('public.admin_get_order(uuid)') is not null
  and to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)') is not null
  and to_regprocedure('public.set_order_status(uuid,public.order_status,text)') is not null,
  'REGRESSION: require_admin, is_admin, is_staff, admin_dashboard_summary, admin_list_orders, admin_get_order, admin_set_order_status and set_order_status all still exist with their signatures');
select pg_temp.ok(
  (select bool_and(prosecdef and coalesce(proconfig::text, '') like '%search_path=public, pg_temp%') from pg_proc
   where oid in ('public.require_admin()'::regprocedure,
                 'public.admin_dashboard_summary(integer,integer)'::regprocedure,
                 'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)'::regprocedure,
                 'public.admin_get_order(uuid)'::regprocedure,
                 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure,
                 'public.set_order_status(uuid,public.order_status,text)'::regprocedure)),
  'REGRESSION: all of them are still SECURITY DEFINER with a pinned search_path');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_get_order(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_set_order_status(uuid,public.order_status,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.set_order_status(uuid,public.order_status,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_dashboard_summary(integer,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_get_order(uuid)', 'EXECUTE'),
  'REGRESSION: anon still cannot execute them; authenticated still can (the gate decides)');
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0 from pg_proc where oid = 'public.admin_dashboard_summary(integer,integer)'::regprocedure)
  and (select position('public.require_admin()' in prosrc) > 0 from pg_proc where oid = 'public.admin_get_order(uuid)'::regprocedure)
  and (select position('public.require_admin()' in prosrc) > 0 from pg_proc
       where oid = 'public.admin_list_orders(text,public.order_status,public.payment_status,public.payment_method,date,date,integer,integer)'::regprocedure)
  and (select position('public.require_admin()' in prosrc) > 0 from pg_proc
       where oid = 'public.admin_set_order_status(uuid,public.order_status,text,boolean)'::regprocedure),
  'REGRESSION: the earlier admin functions still gate with require_admin()');

select pg_temp.run('r_dash', 'authenticated', pg_temp.u(3), 'select public.admin_dashboard_summary()::text');
select pg_temp.succeeded('r_dash', 'REGRESSION: admin_dashboard_summary() still works for an admin');
select pg_temp.run('r_dash_c', 'authenticated', pg_temp.u(1), 'select public.admin_dashboard_summary()::text');
select pg_temp.gated('r_dash_c', 'REGRESSION: admin_dashboard_summary() still refuses a customer');
select pg_temp.run('r_ord', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('r_ord', 'REGRESSION: admin_list_orders() still works for an admin');
select pg_temp.run('r_ord_s', 'authenticated', pg_temp.u(2), 'select public.admin_list_orders()::text');
select pg_temp.gated('r_ord_s', 'REGRESSION: admin_list_orders() still refuses staff');
select pg_temp.run('r_get', 'authenticated', pg_temp.u(3), $$select public.admin_get_order('00000000-0000-4000-8000-6dffffffffff')::text$$);
select pg_temp.expect_err('r_get', 'P0001', 'order_not_found', 'REGRESSION: admin_get_order() still reports order_not_found for an admin');
select pg_temp.run('r_get_c', 'authenticated', pg_temp.u(1), $$select public.admin_get_order('00000000-0000-4000-8000-6dffffffffff')::text$$);
select pg_temp.gated('r_get_c', 'REGRESSION: admin_get_order() still refuses a customer');
select pg_temp.run('r_set_c', 'authenticated', pg_temp.u(1),
  $$select public.admin_set_order_status('00000000-0000-4000-8000-6dffffffffff', 'cancelled', null, false)::text$$);
select pg_temp.gated('r_set_c', 'REGRESSION: admin_set_order_status() still refuses a customer (nothing was executed)');
select pg_temp.run('r_set_a', 'anon', null,
  $$select public.set_order_status('00000000-0000-4000-8000-6dffffffffff', 'cancelled', null)::text$$);
select pg_temp.no_execute('r_set_a', 'REGRESSION: anon still cannot execute set_order_status()');

do $$ begin raise notice 'ALL PHASE 6C.1A.2 TESTS PASSED'; end $$;

rollback;
