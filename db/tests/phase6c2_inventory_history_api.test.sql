-- =============================================================================
-- PHASE 6C.2.2B.1 database test: admin inventory adjustment HISTORY API
-- (public.admin_list_inventory_adjustments).
--
-- STATUS: written for migration 20261004110000_phase6c2_inventory_history_api.sql.
-- NOT RUN against any database by the author (no PostgreSQL was available); run it on the
-- dedicated Phase-5 DEV database AFTER that migration has been applied there.
--
-- HOW TO RUN (as the postgres/owner role):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c2_inventory_history_api.test.sql
-- (Supabase SQL Editor: paste the whole file and Run.)
--
-- One transaction, rolled back at the end: no fixture, stock change or history row survives.
-- Each pass prints "PASS: <name>"; a failure raises "FAIL: <name>".
-- "ALL PHASE 6C.2.2B.1 TESTS PASSED" = everything passed.
--
-- FIXTURE RULE: no existing history row is assumed. Every history row the tests read is created
-- here through the verified admin_adjust_inventory() as a real admin identity. Their created_at is
-- then moved (as the table owner, inside this rolled-back transaction only) to fixed dates in
-- 2001, because inside one transaction now() is constant and dates / ordering could not otherwise
-- be exercised. No constraint, grant or function is touched to do this. All fixture rows are named
-- 't6c2b1' / 'T6C2B1'; real products and real history rows are never modified (they may still
-- appear in UNFILTERED reads, so assertions on unfiltered reads only look at fixture rows).
--
-- COVERS
--   A  function attributes: signature, SECURITY DEFINER, search_path, STABLE, ACL, require_admin first
--   B  authorization: admin ok; customer / staff / anon / signed-out / forged claim / service_role refused
--   C  content: positive + negative rows, product / variant metadata, note, actor, no variant on product rows
--   D  filters: product, variant, reason, changed_by, from / to (half-open), combinations
--   E  pagination, total, deterministic ordering (including a created_at tie)
--   F  validation (invalid_arguments)
--   G  read-only: no stock / history / order mutation; table still closed to direct access;
--      no new grants; admin_adjust_inventory() unchanged
--   H  regression of earlier phases (admin API allow-list now has fifteen functions)
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
  select ('00000000-0000-4000-8000-6f1' || lpad(n::text, 9, '0'))::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f2000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f3000000' || lpad(n::text, 3, '0'))::uuid $$;

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
              from public.products p where p.slug like 't6c2b1-%'), '')
    || '#' ||
    coalesce((select string_agg(v.id::text || ':' || v.stock_quantity, '|' order by v.id)
              from public.product_variants v where v.sku like 'T6C2B1-%'), '')
    || '#' ||
    (select count(*) from public.inventory_adjustments a
     where a.product_id in (select id from public.products where slug like 't6c2b1-%'))::text) $$;
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
-- Phase-specific helpers for the history API
-- ---------------------------------------------------------------------------
create temp table t_fx (label text primary key, id uuid not null);

create or replace function pg_temp.fx(p_label text) returns uuid language sql as $$
  select id from t_fx where label = p_label $$;

-- Create ONE history row through the verified admin_adjust_inventory(), as a real admin identity.
create or replace function pg_temp.mk(p_label text, p_uid uuid, p_prod uuid, p_delta text, p_reason text,
                                      p_var uuid default null, p_note text default null)
returns void language plpgsql as $$
declare r t_res;
begin
  perform pg_temp.adj('mk_' || p_label, 'authenticated', p_uid, p_prod, p_delta, p_reason, p_var, p_note);
  select * into r from t_res where k = 'mk_' || p_label;
  perform pg_temp.ok(r.err is null and r.res is not null,
    'FIXTURE ' || p_label || ' created through admin_adjust_inventory [' || coalesce(r.err, 'ok') || ']');
  insert into t_fx (label, id) values (p_label, (r.res::jsonb ->> 'adjustment_id')::uuid);
end;
$$;

-- admin_list_inventory_adjustments(<named args>) as a role / JWT user.
create or replace function pg_temp.hl(p_k text, p_role text, p_uid uuid, p_args text default '')
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid,
    'select public.admin_list_inventory_adjustments(' || p_args || ')::text');
end;
$$;
create or replace function pg_temp.ha(p_k text, p_args text default '')
returns void language sql as $$
  select pg_temp.hl(p_k, 'authenticated', pg_temp.u(3), p_args) $$;

-- FIXTURE labels of the returned rows, in returned order (rows that are not fixture rows are ignored).
create or replace function pg_temp.lbl(p_k text) returns text[] language sql as $$
  select coalesce(array_agg(f.label order by e.ord), '{}'::text[])
  from t_res r
  cross join lateral jsonb_array_elements(r.res::jsonb -> 'adjustments') with ordinality as e(el, ord)
  join t_fx f on f.id = (e.el ->> 'id')::uuid
  where r.k = p_k $$;
create or replace function pg_temp.row_of(p_k text, p_label text) returns jsonb language sql as $$
  select e.el
  from t_res r
  cross join lateral jsonb_array_elements(r.res::jsonb -> 'adjustments') as e(el)
  where r.k = p_k and (e.el ->> 'id')::uuid = (select id from t_fx where label = p_label) $$;
create or replace function pg_temp.tot(p_k text) returns integer language sql as $$
  select (res::jsonb ->> 'total')::integer from t_res where k = p_k $$;
create or replace function pg_temp.lim(p_k text) returns integer language sql as $$
  select (res::jsonb ->> 'limit')::integer from t_res where k = p_k $$;
create or replace function pg_temp.off(p_k text) returns integer language sql as $$
  select (res::jsonb ->> 'offset')::integer from t_res where k = p_k $$;
create or replace function pg_temp.nrows(p_k text) returns integer language sql as $$
  select jsonb_array_length(res::jsonb -> 'adjustments') from t_res where k = p_k $$;

-- Every stock value / every history row (whole tables, real data included).
create or replace function pg_temp.stock_all() returns text language sql as $$
  select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity || ':' || p.in_stock, '|' order by p.id)
                       from public.products p), '')
          || '#' ||
          coalesce((select string_agg(v.id::text || ':' || v.stock_quantity, '|' order by v.id)
                    from public.product_variants v), '')) $$;
create or replace function pg_temp.hist_all() returns text language sql as $$
  select md5(coalesce(string_agg(a::text, '|' order by a.id), '')) from public.inventory_adjustments a $$;

-- ---------------------------------------------------------------------------
-- Fixtures
--   u1 customer, u2 staff, u3 admin, u4 second admin
--   p1 Milk stock 20 with variants v1 (7), v2 (0);  p2 Rice stock 10;  p3 Other stock 5 with variant v3 (4)
-- History (all created through admin_adjust_inventory, then dated in 2001):
--   h1 u3 p1 product  +10  'T6C2B1 restock'          note 'first'   2001-01-01   20 -> 30
--   h2 u3 p1 product   -3  'T6C2B1 damaged'                         2001-01-02   30 -> 27
--   h3 u3 p1 v1        +5  'T6C2B1 restock'                         2001-01-03    7 -> 12
--   h4 u4 p1 v2        +2  'T6C2B1 count correction'                2001-01-04    0 -> 2   (ties with h6)
--   h5 u3 p2 product   -4  'T6C2B1 damaged'                         2001-01-05   10 -> 6
--   h6 u4 p3 v3        -1  'T6C2B1 damaged'                         2001-01-04    4 -> 3   (ties with h4)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6c2b1-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6C2B1 Customer"}'),
  (pg_temp.u(2), 't6c2b1-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2B1 Staff"}'),
  (pg_temp.u(3), 't6c2b1-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6C2B1 Admin"}'),
  (pg_temp.u(4), 't6c2b1-admin2@example.test',   'authenticated', 'authenticated', '{"full_name":"T6C2B1 Admin Two"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'),
  (pg_temp.u(3), 'admin'),
  (pg_temp.u(4), 'admin');

insert into public.products (id, slug, name, sku, price_cents, unit_label, stock_quantity, in_stock, is_active) values
  (pg_temp.p(1), 't6c2b1-milk',  'T6C2B1 Milk',  'T6C2B1-MILK',  500, '1 L',  20, true, true),
  (pg_temp.p(2), 't6c2b1-rice',  'T6C2B1 Rice',  'T6C2B1-RICE',  700, '1 kg', 10, true, true),
  (pg_temp.p(3), 't6c2b1-other', 'T6C2B1 Other', 'T6C2B1-OTHER', 100, null,    5, true, true);
insert into public.product_variants (id, product_id, name, sku, price_cents, stock_quantity, position, is_active) values
  (pg_temp.v(1), pg_temp.p(1), 'T6C2B1 Milk 1L', 'T6C2B1-MILK-1L', 500, 7, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'T6C2B1 Milk 2L', 'T6C2B1-MILK-2L', 900, 0, 2, true),
  (pg_temp.v(3), pg_temp.p(3), 'T6C2B1 Other Var', 'T6C2B1-OTHER-V', 100, 4, 1, true);

select pg_temp.ok((select count(*) from public.products where slug like 't6c2b1-%') = 3
  and (select count(*) from public.product_variants where sku like 'T6C2B1-%') = 3,
  'FIXTURE: three test products and three test variants exist');

select pg_temp.mk('h1', pg_temp.u(3), pg_temp.p(1), '10', 'T6C2B1 restock', null, 'first');
select pg_temp.mk('h2', pg_temp.u(3), pg_temp.p(1), '-3', 'T6C2B1 damaged');
select pg_temp.mk('h3', pg_temp.u(3), pg_temp.p(1), '5',  'T6C2B1 restock', pg_temp.v(1));
select pg_temp.mk('h4', pg_temp.u(4), pg_temp.p(1), '2',  'T6C2B1 count correction', pg_temp.v(2));
select pg_temp.mk('h5', pg_temp.u(3), pg_temp.p(2), '-4', 'T6C2B1 damaged');
select pg_temp.mk('h6', pg_temp.u(4), pg_temp.p(3), '-1', 'T6C2B1 damaged', pg_temp.v(3));

-- Fixed dates (as the table owner, inside this rolled-back transaction): now() is constant in one
-- transaction, so this is the only way to exercise date filters and ordering.
-- Phase 9B made the ledger append-only: switch the guard off for this one fixture statement (owner,
-- rolled-back transaction) and back on straight after. The guard itself is tested in
-- phase9b_inventory_movements.test.sql. Skipped when Phase 9B is not applied.
do $g$ begin
  if exists (select 1 from pg_trigger where tgrelid = 'public.inventory_adjustments'::regclass
             and tgname = 'inventory_adjustments_append_only') then
    execute 'alter table public.inventory_adjustments disable trigger inventory_adjustments_append_only';
  end if;
end $g$;
update public.inventory_adjustments a
set created_at = d.ts
from t_fx f
join (values ('h1', timestamptz '2001-01-01 00:00:00+00'), ('h2', timestamptz '2001-01-02 00:00:00+00'),
             ('h3', timestamptz '2001-01-03 00:00:00+00'), ('h4', timestamptz '2001-01-04 00:00:00+00'),
             ('h5', timestamptz '2001-01-05 00:00:00+00'), ('h6', timestamptz '2001-01-04 00:00:00+00')) d(label, ts)
  on d.label = f.label
where a.id = f.id;
do $g$ begin
  if exists (select 1 from pg_trigger where tgrelid = 'public.inventory_adjustments'::regclass
             and tgname = 'inventory_adjustments_append_only') then
    execute 'alter table public.inventory_adjustments enable trigger inventory_adjustments_append_only';
  end if;
end $g$;

select pg_temp.ok(
  (select count(*) from public.inventory_adjustments a join t_fx f on f.id = a.id
   where a.created_at between '2001-01-01 00:00:00+00' and '2001-01-05 00:00:00+00') = 6
  and pg_temp.pstock(1) = 27 and pg_temp.pstock(2) = 6 and pg_temp.pstock(3) = 5
  and pg_temp.vstock(1) = 12 and pg_temp.vstock(2) = 2 and pg_temp.vstock(3) = 3,
  'FIXTURE: six history rows exist (created by admin_adjust_inventory, dated 2001) and the stock equals the replayed history');

insert into t_h values
  ('ord0', pg_temp.ord_hash()),
  ('acl0', pg_temp.acl_hash()),
  ('pol0', pg_temp.pol_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))),
  ('fn0',  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace)),
  ('stock0', pg_temp.stock_all()),
  ('hist0',  pg_temp.hist_all());
select pg_temp.snap();

-- ===========================================================================
-- A. FUNCTION ATTRIBUTES
-- ===========================================================================
select pg_temp.ok(
  to_regprocedure('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)') is not null
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
       and proname = 'admin_list_inventory_adjustments') = 1
  and pg_get_function_arguments('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure)
      = 'p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid, p_variant_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone'
  and pg_get_function_result('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure) = 'jsonb',
  'A1 the function exists with the exact expected signature (one overload, eight arguments with their defaults, returns jsonb)');
select pg_temp.ok(
  (select prosecdef from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure),
  'A2 the function is SECURITY DEFINER');
select pg_temp.ok(
  (select proconfig from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure)
    = array['search_path=public, pg_temp']::text[],
  'A3 proconfig is exactly search_path=public, pg_temp (nothing else)');
select pg_temp.ok(
  (select provolatile from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure) = 's',
  'A4 the function is STABLE');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure
                    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'A5 PUBLIC and anon cannot EXECUTE; authenticated can');
select pg_temp.ok(
  (select array_agg(a.grantee::regrole::text || ':' || a.privilege_type order by a.grantee::regrole::text, a.privilege_type)
   from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure and a.grantee <> 0)
  = (select array_agg(a.grantee::regrole::text || ':' || a.privilege_type order by a.grantee::regrole::text, a.privilege_type)
     from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where p.oid = 'public.admin_list_inventory(integer,integer,text,boolean,uuid)'::regprocedure and a.grantee <> 0),
  'A6 the EXECUTE ACL is identical to the other admin_* readers (admin_list_inventory)');
select pg_temp.ok(
  (select position('public.require_admin()' in prosrc) > 0
      and position('public.require_admin()' in prosrc) < position('public.inventory_adjustments' in prosrc)
      and position('public.require_admin()' in prosrc) < position('invalid_arguments' in prosrc)
   from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure),
  'A7 require_admin() appears before argument validation and before the history table is read');
select pg_temp.ok(
  (select prosrc !~* '\m(insert\s+into|update\s+public|delete\s+from|truncate)\M'
      and prosrc !~* '\mexecute\M'
      and prosrc !~* '\mfor\s+(update|share|no\s+key\s+update|key\s+share)\M'
      and position('order by m.created_at desc, m.id desc' in prosrc) > 0
   from pg_proc where oid = 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure),
  'A8 the body contains no write, no row lock and no dynamic SQL, and uses the fixed order created_at desc, id desc');

-- ===========================================================================
-- B. AUTHORIZATION (everything refused here must change nothing)
-- ===========================================================================
select pg_temp.ha('b_admin', format('p_changed_by => %L::uuid', pg_temp.u(3)));
select pg_temp.succeeded('b_admin', 'B1 an admin can call the function');
select pg_temp.ok(pg_temp.lbl('b_admin') = array['h5', 'h3', 'h2', 'h1'] and pg_temp.tot('b_admin') = 4,
  'B2 the admin receives the history (the four rows made by the first admin, newest first, total 4)');

select pg_temp.hl('b_cust', 'authenticated', pg_temp.u(1));
select pg_temp.gated('b_cust', 'B3 a customer is rejected by require_admin() (42501 not_authorised)');
select pg_temp.hl('b_staff', 'authenticated', pg_temp.u(2));
select pg_temp.gated('b_staff', 'B4 staff is rejected (admin only)');
select pg_temp.hl('b_anon', 'anon', null);
select pg_temp.no_execute('b_anon', 'B5 anon cannot execute the function (permission denied, EXECUTE revoked)');
select pg_temp.hl('b_anon_adm', 'anon', pg_temp.u(3));
select pg_temp.no_execute('b_anon_adm', 'B6 anon carrying the admin user id still cannot execute it');
select pg_temp.hl('b_out', 'authenticated', null);
select pg_temp.gated('b_out', 'B7 an authenticated role with no JWT subject is rejected by require_admin()');
select pg_temp.run_claims('b_forged', 'authenticated',
  jsonb_build_object('sub', pg_temp.u(1), 'role', 'authenticated', 'user_role', 'admin',
                     'app_metadata', jsonb_build_object('role', 'admin'),
                     'user_metadata', jsonb_build_object('role', 'admin', 'is_admin', true)),
  'select public.admin_list_inventory_adjustments()::text');
select pg_temp.gated('b_forged', 'B8 a customer JWT that CLAIMS admin in app_metadata / user_metadata / user_role is still rejected');
select pg_temp.hl('b_sr', 'service_role', null);
select pg_temp.denied('b_sr', 'B9 service_role without a user is refused (no auth.uid())');
-- The gate runs BEFORE argument validation: a non-admin with an invalid argument is told "not authorised".
select pg_temp.hl('b_cust_bad', 'authenticated', pg_temp.u(1), 'p_limit => 0');
select pg_temp.gated('b_cust_bad', 'B10 a customer with an INVALID limit gets not_authorised, not invalid_arguments (the gate is first)');
select pg_temp.hl('b_staff_bad', 'authenticated', pg_temp.u(2), 'p_limit => 1000, p_offset => -5');
select pg_temp.gated('b_staff_bad', 'B11 staff with invalid arguments also gets not_authorised');
select pg_temp.same('every authorization refusal');

-- ===========================================================================
-- C. CONTENT: positive / negative rows, metadata
-- ===========================================================================
select pg_temp.ha('c_u3', format('p_changed_by => %L::uuid, p_limit => 100', pg_temp.u(3)));
select pg_temp.ha('c_u4', format('p_changed_by => %L::uuid, p_limit => 100', pg_temp.u(4)));

select pg_temp.ok(
  (select array_agg(k order by k collate "C") from jsonb_object_keys((select res::jsonb from t_res where k = 'c_u3')) k)
    = array['adjustments', 'limit', 'offset', 'total']
  and (select array_agg(k order by k collate "C")
       from jsonb_object_keys(pg_temp.row_of('c_u3', 'h1')) k)
    = array['adjustment_quantity', 'changed_by', 'created_at', 'id', 'new_quantity', 'note', 'previous_quantity',
            'product_id', 'product_name', 'product_sku', 'reason', 'variant_id', 'variant_name', 'variant_sku'],
  'C1 the result has exactly total / limit / offset / adjustments and each adjustment has exactly the fourteen requested fields');
select pg_temp.ok(
  (pg_temp.row_of('c_u3', 'h1') ->> 'adjustment_quantity')::integer = 10
  and (pg_temp.row_of('c_u3', 'h1') ->> 'previous_quantity')::integer = 20
  and (pg_temp.row_of('c_u3', 'h1') ->> 'new_quantity')::integer = 30
  and pg_temp.row_of('c_u3', 'h1') ->> 'reason' = 'T6C2B1 restock'
  and pg_temp.row_of('c_u3', 'h1') ->> 'note' = 'first'
  and (pg_temp.row_of('c_u3', 'h1') ->> 'changed_by')::uuid = pg_temp.u(3)
  and (pg_temp.row_of('c_u3', 'h1') ->> 'created_at')::timestamptz = timestamptz '2001-01-01 00:00:00+00'
  and (pg_temp.row_of('c_u3', 'h1') ->> 'product_id')::uuid = pg_temp.p(1),
  'C2 POSITIVE adjustment: +10, previous 20, new 30, reason, note, actor and created_at are returned as stored');
select pg_temp.ok(
  (pg_temp.row_of('c_u3', 'h2') ->> 'adjustment_quantity')::integer = -3
  and (pg_temp.row_of('c_u3', 'h2') ->> 'previous_quantity')::integer = 30
  and (pg_temp.row_of('c_u3', 'h2') ->> 'new_quantity')::integer = 27
  and pg_temp.row_of('c_u3', 'h2') -> 'note' = 'null'::jsonb,
  'C3 NEGATIVE adjustment: -3, previous 30, new 27, and a missing note is returned as null');
select pg_temp.ok(
  pg_temp.row_of('c_u3', 'h1') ->> 'product_name' = 'T6C2B1 Milk'
  and pg_temp.row_of('c_u3', 'h1') ->> 'product_sku' = 'T6C2B1-MILK'
  and pg_temp.row_of('c_u3', 'h1') -> 'variant_id' = 'null'::jsonb
  and pg_temp.row_of('c_u3', 'h1') -> 'variant_name' = 'null'::jsonb
  and pg_temp.row_of('c_u3', 'h1') -> 'variant_sku' = 'null'::jsonb,
  'C4 PRODUCT-level row: product name and sku are returned; variant id / name / sku are null');
select pg_temp.ok(
  (pg_temp.row_of('c_u3', 'h3') ->> 'variant_id')::uuid = pg_temp.v(1)
  and pg_temp.row_of('c_u3', 'h3') ->> 'variant_name' = 'T6C2B1 Milk 1L'
  and pg_temp.row_of('c_u3', 'h3') ->> 'variant_sku' = 'T6C2B1-MILK-1L'
  and pg_temp.row_of('c_u3', 'h3') ->> 'product_name' = 'T6C2B1 Milk'
  and pg_temp.row_of('c_u3', 'h3') ->> 'product_sku' = 'T6C2B1-MILK'
  and (pg_temp.row_of('c_u3', 'h3') ->> 'previous_quantity')::integer = 7
  and (pg_temp.row_of('c_u3', 'h3') ->> 'new_quantity')::integer = 12,
  'C5 VARIANT-level row: variant id / name / sku AND the parent product name / sku are returned (7 -> 12)');
select pg_temp.ok(
  (pg_temp.row_of('c_u4', 'h6') ->> 'adjustment_quantity')::integer = -1
  and (pg_temp.row_of('c_u4', 'h6') ->> 'previous_quantity')::integer = 4
  and (pg_temp.row_of('c_u4', 'h6') ->> 'new_quantity')::integer = 3
  and pg_temp.row_of('c_u4', 'h6') ->> 'variant_sku' = 'T6C2B1-OTHER-V'
  and pg_temp.row_of('c_u4', 'h6') ->> 'product_sku' = 'T6C2B1-OTHER'
  and (pg_temp.row_of('c_u4', 'h6') ->> 'changed_by')::uuid = pg_temp.u(4),
  'C6 a NEGATIVE variant adjustment of another product, made by the second admin, is returned correctly (4 -> 3)');
select pg_temp.ok(
  (select bool_and((e.el ->> 'new_quantity')::bigint = (e.el ->> 'previous_quantity')::bigint + (e.el ->> 'adjustment_quantity')::bigint)
   from t_res r cross join lateral jsonb_array_elements(r.res::jsonb -> 'adjustments') e(el)
   where r.k in ('c_u3', 'c_u4')),
  'C7 every returned row satisfies new = previous + adjustment (nothing is recomputed or distorted)');

-- ===========================================================================
-- D. FILTERS
-- ===========================================================================
select pg_temp.ha('d_p1', format('p_product_id => %L::uuid, p_limit => 100', pg_temp.p(1)));
select pg_temp.ok(pg_temp.lbl('d_p1') = array['h4', 'h3', 'h2', 'h1'] and pg_temp.tot('d_p1') = 4 and pg_temp.nrows('d_p1') = 4,
  'D1 PRODUCT filter p1: its product-level AND variant-level rows (h4,h3,h2,h1), total 4, nothing else');
select pg_temp.ha('d_p2', format('p_product_id => %L::uuid', pg_temp.p(2)));
select pg_temp.ok(pg_temp.lbl('d_p2') = array['h5'] and pg_temp.tot('d_p2') = 1 and pg_temp.nrows('d_p2') = 1,
  'D2 PRODUCT filter p2: only h5');
select pg_temp.ha('d_p3', format('p_product_id => %L::uuid', pg_temp.p(3)));
select pg_temp.ok(pg_temp.lbl('d_p3') = array['h6'] and pg_temp.tot('d_p3') = 1,
  'D3 PRODUCT filter p3: only h6');
select pg_temp.ha('d_pnone', format('p_product_id => %L::uuid', pg_temp.p(99)));
select pg_temp.ok(pg_temp.tot('d_pnone') = 0 and pg_temp.nrows('d_pnone') = 0
                  and (select res::jsonb -> 'adjustments' from t_res where k = 'd_pnone') = '[]'::jsonb,
  'D4 an unknown product matches nothing: total 0 and an empty array (not null, not an error)');

select pg_temp.ha('d_v1', format('p_variant_id => %L::uuid', pg_temp.v(1)));
select pg_temp.ok(pg_temp.lbl('d_v1') = array['h3'] and pg_temp.tot('d_v1') = 1 and pg_temp.nrows('d_v1') = 1,
  'D5 VARIANT filter v1: only h3 (the product-level rows of the same product are NOT included)');
select pg_temp.ha('d_v2', format('p_variant_id => %L::uuid', pg_temp.v(2)));
select pg_temp.ok(pg_temp.lbl('d_v2') = array['h4'] and pg_temp.tot('d_v2') = 1, 'D6 VARIANT filter v2: only h4');
select pg_temp.ha('d_v3', format('p_variant_id => %L::uuid', pg_temp.v(3)));
select pg_temp.ok(pg_temp.lbl('d_v3') = array['h6'] and pg_temp.tot('d_v3') = 1, 'D7 VARIANT filter v3: only h6');

select pg_temp.ha('d_r1', $$p_reason => 'T6C2B1 restock'$$);
select pg_temp.ok(pg_temp.lbl('d_r1') = array['h3', 'h1'] and pg_temp.tot('d_r1') = 2 and pg_temp.nrows('d_r1') = 2,
  'D8 REASON filter "T6C2B1 restock": h3 and h1 (exact match), total 2');
select pg_temp.ha('d_r2', $$p_reason => 'T6C2B1 damaged'$$);
select pg_temp.ok(pg_temp.lbl('d_r2') = array['h5', 'h6', 'h2'] and pg_temp.tot('d_r2') = 3,
  'D9 REASON filter "T6C2B1 damaged": h5 (Jan 5), h6 (Jan 4), h2 (Jan 2), total 3, newest first');
select pg_temp.ha('d_r3', $$p_reason => '   T6C2B1 restock   '$$);
select pg_temp.ok(pg_temp.lbl('d_r3') = array['h3', 'h1'] and pg_temp.tot('d_r3') = 2,
  'D10 REASON filter ignores surrounding blanks (history stores trimmed reasons)');
select pg_temp.ha('d_r4', $$p_reason => 'T6C2B1 RESTOCK'$$);
select pg_temp.ha('d_r5', $$p_reason => 'T6C2B1 %'$$);
select pg_temp.ha('d_r6', $$p_reason => 'T6C2B1 restock%'$$);
select pg_temp.ha('d_r7', $$p_reason => 'T6C2B1'$$);
select pg_temp.ok(pg_temp.tot('d_r4') = 0 and pg_temp.tot('d_r5') = 0 and pg_temp.tot('d_r6') = 0 and pg_temp.tot('d_r7') = 0,
  'D11 REASON is an EXACT match: different case, a % wildcard, a trailing wildcard and a mere prefix match nothing');

select pg_temp.ha('d_a3', format('p_changed_by => %L::uuid, p_limit => 100', pg_temp.u(3)));
select pg_temp.ok(pg_temp.lbl('d_a3') = array['h5', 'h3', 'h2', 'h1'] and pg_temp.tot('d_a3') = 4,
  'D12 CHANGED_BY filter, first admin: h5,h3,h2,h1, total 4');
select pg_temp.ha('d_a4', format('p_changed_by => %L::uuid, p_limit => 100', pg_temp.u(4)));
select pg_temp.ok(pg_temp.lbl('d_a4') = case when pg_temp.fx('h4') > pg_temp.fx('h6') then array['h4', 'h6'] else array['h6', 'h4'] end
                  and pg_temp.tot('d_a4') = 2,
  'D13 CHANGED_BY filter, second admin: h4 and h6, total 2');
select pg_temp.ha('d_a9', format('p_changed_by => %L::uuid', pg_temp.u(9)));
select pg_temp.ok(pg_temp.tot('d_a9') = 0 and pg_temp.nrows('d_a9') = 0, 'D14 an unknown actor matches nothing');
select pg_temp.ha('d_acust', format('p_changed_by => %L::uuid', pg_temp.u(1)));
select pg_temp.ok(pg_temp.tot('d_acust') = 0, 'D15 a user who never adjusted stock matches nothing');

-- from / to: created_at >= p_from AND created_at < p_to (all fixture rows are dated 2001, real rows are not)
select pg_temp.ha('d_dt1', $$p_from => '2001-01-03 00:00:00+00'::timestamptz, p_to => '2001-01-04 00:00:00+00'::timestamptz, p_limit => 100$$);
select pg_temp.ok(pg_temp.lbl('d_dt1') = array['h3'] and pg_temp.tot('d_dt1') = 1 and pg_temp.nrows('d_dt1') = 1,
  'D16 [Jan 3, Jan 4): h3 only - p_from is INCLUSIVE (h3 sits exactly on it) and p_to is EXCLUSIVE (h4 / h6 sit exactly on it)');
select pg_temp.ha('d_dt2', $$p_from => '2001-01-04 00:00:00+00'::timestamptz, p_to => '2001-01-05 00:00:00+00'::timestamptz, p_limit => 100$$);
select pg_temp.ok(pg_temp.lbl('d_dt2') = case when pg_temp.fx('h4') > pg_temp.fx('h6') then array['h4', 'h6'] else array['h6', 'h4'] end
                  and pg_temp.tot('d_dt2') = 2,
  'D17 [Jan 4, Jan 5): the two rows dated exactly Jan 4 (h4, h6), not h5 (Jan 5 is excluded)');
select pg_temp.ha('d_dt3', $$p_from => '2001-01-04 00:00:00+00'::timestamptz, p_to => '2002-01-01 00:00:00+00'::timestamptz, p_limit => 100$$);
select pg_temp.ok(pg_temp.lbl('d_dt3') = case when pg_temp.fx('h4') > pg_temp.fx('h6') then array['h5', 'h4', 'h6'] else array['h5', 'h6', 'h4'] end
                  and pg_temp.tot('d_dt3') = 3,
  'D18 p_from alone as the lower bound (with a far upper bound): h5, then the Jan 4 pair, total 3');
select pg_temp.ha('d_dt4', $$p_to => '2001-01-03 00:00:00+00'::timestamptz, p_limit => 100$$);
select pg_temp.ok(pg_temp.lbl('d_dt4') = array['h2', 'h1'] and pg_temp.tot('d_dt4') = 2,
  'D19 p_to alone: everything strictly before Jan 3 - h2, h1');
select pg_temp.ha('d_dt5', $$p_from => '2001-01-05 00:00:00+00'::timestamptz, p_to => '2001-01-05 00:00:01+00'::timestamptz$$);
select pg_temp.ok(pg_temp.lbl('d_dt5') = array['h5'] and pg_temp.tot('d_dt5') = 1,
  'D20 a one-second range holding exactly h5');
select pg_temp.ha('d_dt6', $$p_from => '1990-01-01 00:00:00+00'::timestamptz, p_to => '2000-01-01 00:00:00+00'::timestamptz$$);
select pg_temp.ok(pg_temp.tot('d_dt6') = 0 and pg_temp.nrows('d_dt6') = 0, 'D21 a range before every row matches nothing');

-- combinations (ANDed)
select pg_temp.ha('d_c1', format($$p_product_id => %L::uuid, p_reason => 'T6C2B1 restock', p_changed_by => %L::uuid$$, pg_temp.p(1), pg_temp.u(3)));
select pg_temp.ok(pg_temp.lbl('d_c1') = array['h3', 'h1'] and pg_temp.tot('d_c1') = 2, 'D22 product + reason + actor: h3, h1');
select pg_temp.ha('d_c2', format('p_product_id => %L::uuid, p_changed_by => %L::uuid', pg_temp.p(1), pg_temp.u(4)));
select pg_temp.ok(pg_temp.lbl('d_c2') = array['h4'] and pg_temp.tot('d_c2') = 1,
  'D23 product p1 + second admin: h4 only (h6 belongs to p3)');
select pg_temp.ha('d_c3', format('p_product_id => %L::uuid, p_variant_id => %L::uuid', pg_temp.p(2), pg_temp.v(1)));
select pg_temp.ok(pg_temp.tot('d_c3') = 0, 'D24 a variant that does not belong to the filtered product matches nothing');
select pg_temp.ha('d_c4', format($$p_product_id => %L::uuid, p_from => '2001-01-03 00:00:00+00'::timestamptz$$, pg_temp.p(1)));
select pg_temp.ok(pg_temp.lbl('d_c4') = array['h4', 'h3'] and pg_temp.tot('d_c4') = 2, 'D25 product + date lower bound: h4, h3');
select pg_temp.ha('d_c5', format($$p_variant_id => %L::uuid, p_reason => 'T6C2B1 damaged'$$, pg_temp.v(1)));
select pg_temp.ok(pg_temp.tot('d_c5') = 0, 'D26 variant v1 + reason "damaged": nothing (h3 was a restock)');
select pg_temp.ha('d_null', 'p_product_id => null, p_variant_id => null, p_reason => null, p_changed_by => null, p_from => null, p_to => null');
select pg_temp.ok(pg_temp.tot('d_null') >= 6 and pg_temp.lim('d_null') = 50 and pg_temp.off('d_null') = 0,
  'D27 explicit NULL for every filter = no filter (total includes at least the six fixture rows; defaults limit 50, offset 0)');

-- ===========================================================================
-- E. PAGINATION and DETERMINISTIC ORDERING
-- ===========================================================================
select pg_temp.ha('e_pg1', format('p_changed_by => %L::uuid, p_limit => 2, p_offset => 0', pg_temp.u(3)));
select pg_temp.ha('e_pg2', format('p_changed_by => %L::uuid, p_limit => 2, p_offset => 2', pg_temp.u(3)));
select pg_temp.ha('e_pg3', format('p_changed_by => %L::uuid, p_limit => 2, p_offset => 4', pg_temp.u(3)));
select pg_temp.ha('e_pg4', format('p_changed_by => %L::uuid, p_limit => 1, p_offset => 1', pg_temp.u(3)));
select pg_temp.ha('e_pg5', format('p_changed_by => %L::uuid, p_limit => 3, p_offset => 3', pg_temp.u(3)));
select pg_temp.ha('e_pg6', format('p_changed_by => %L::uuid', pg_temp.u(3)));
select pg_temp.ok(pg_temp.lbl('e_pg1') = array['h5', 'h3'] and pg_temp.nrows('e_pg1') = 2 and pg_temp.tot('e_pg1') = 4
                  and pg_temp.lim('e_pg1') = 2 and pg_temp.off('e_pg1') = 0,
  'E1 page 1 (limit 2, offset 0): h5, h3; total stays 4; limit and offset are echoed');
select pg_temp.ok(pg_temp.lbl('e_pg2') = array['h2', 'h1'] and pg_temp.nrows('e_pg2') = 2 and pg_temp.tot('e_pg2') = 4
                  and pg_temp.off('e_pg2') = 2,
  'E2 page 2 (limit 2, offset 2): h2, h1; total still 4');
select pg_temp.ok(pg_temp.nrows('e_pg3') = 0 and pg_temp.tot('e_pg3') = 4
                  and (select res::jsonb -> 'adjustments' from t_res where k = 'e_pg3') = '[]'::jsonb,
  'E3 an offset past the end returns an empty array but the true total (4)');
select pg_temp.ok(pg_temp.lbl('e_pg4') = array['h3'] and pg_temp.nrows('e_pg4') = 1 and pg_temp.tot('e_pg4') = 4,
  'E4 limit 1 offset 1: exactly the second newest row (h3)');
select pg_temp.ok(pg_temp.lbl('e_pg5') = array['h1'] and pg_temp.nrows('e_pg5') = 1 and pg_temp.tot('e_pg5') = 4,
  'E5 a partial last page (limit 3, offset 3): only h1');
select pg_temp.ok(pg_temp.lim('e_pg6') = 50 and pg_temp.off('e_pg6') = 0,
  'E6 the defaults are limit 50, offset 0');
select pg_temp.ok(
  pg_temp.lbl('e_pg1') || pg_temp.lbl('e_pg2') = pg_temp.lbl('d_a3')
  and (select count(distinct x) from unnest(pg_temp.lbl('e_pg1') || pg_temp.lbl('e_pg2')) x) = 4,
  'E7 consecutive pages joined equal the full list: no row is repeated or skipped');
select pg_temp.ha('e_one', format('p_changed_by => %L::uuid, p_limit => 1', pg_temp.u(3)));
select pg_temp.ha('e_max', format('p_changed_by => %L::uuid, p_limit => 100', pg_temp.u(3)));
select pg_temp.ok(pg_temp.nrows('e_one') = 1 and pg_temp.nrows('e_max') = 4 and pg_temp.lim('e_max') = 100,
  'E8 the limit bounds 1 and 100 are both accepted');

-- Ordering: created_at DESC, then id DESC (h4 and h6 share the exact same created_at)
select pg_temp.ok(pg_temp.lbl('c_u4') = case when pg_temp.fx('h4') > pg_temp.fx('h6') then array['h4', 'h6'] else array['h6', 'h4'] end,
  'E9 two rows with the SAME created_at are ordered by id DESC (the tie-break is deterministic)');
select pg_temp.ha('e_all', 'p_limit => 100');
select pg_temp.ok(
  not exists (
    with e as (
      select x.ord, (x.el ->> 'created_at')::timestamptz as ca, (x.el ->> 'id')::uuid as id
      from t_res r cross join lateral jsonb_array_elements(r.res::jsonb -> 'adjustments') with ordinality x(el, ord)
      where r.k = 'e_all'),
    d as (select ca, id, lag(ca) over (order by ord) as pca, lag(id) over (order by ord) as pid from e)
    select 1 from d where pca is not null and (pca < ca or (pca = ca and pid < id))),
  'E10 an UNFILTERED page (real rows included) is globally ordered created_at DESC, id DESC');
select pg_temp.ha('e_all2', 'p_limit => 100');
select pg_temp.ok((select res from t_res where k = 'e_all') = (select res from t_res where k = 'e_all2'),
  'E11 the same call twice returns byte-identical output (deterministic)');
select pg_temp.ok(
  pg_temp.lbl('d_p1') = array['h4', 'h3', 'h2', 'h1'] and pg_temp.lbl('d_r2') = array['h5', 'h6', 'h2'],
  'E12 filtered lists come back newest first (h4..h1 for p1; h5, h6, h2 for the damaged reason)');

-- ===========================================================================
-- F. VALIDATION (an admin; every refusal is P0001 invalid_arguments and changes nothing)
-- ===========================================================================
select pg_temp.ha('f_l0',   'p_limit => 0');
select pg_temp.ha('f_l101', 'p_limit => 101');
select pg_temp.ha('f_lneg', 'p_limit => -1');
select pg_temp.ha('f_lnull','p_limit => null');
select pg_temp.ha('f_onull','p_offset => null');
select pg_temp.ha('f_oneg', 'p_offset => -1');
select pg_temp.ha('f_rblank', $$p_reason => '   '$$);
select pg_temp.ha('f_rempty', $$p_reason => ''$$);
select pg_temp.ha('f_rlong', format('p_reason => %L', repeat('x', 121)));
select pg_temp.ha('f_range_eq', $$p_from => '2001-01-03 00:00:00+00'::timestamptz, p_to => '2001-01-03 00:00:00+00'::timestamptz$$);
select pg_temp.ha('f_range_rev', $$p_from => '2001-01-04 00:00:00+00'::timestamptz, p_to => '2001-01-03 00:00:00+00'::timestamptz$$);
select pg_temp.refused('f_l0',    'invalid_arguments', 'F1 limit 0 is refused');
select pg_temp.refused('f_l101',  'invalid_arguments', 'F2 limit 101 is refused (maximum 100)');
select pg_temp.refused('f_lneg',  'invalid_arguments', 'F3 a negative limit is refused');
select pg_temp.refused('f_lnull', 'invalid_arguments', 'F4 a NULL limit is refused');
select pg_temp.refused('f_onull', 'invalid_arguments', 'F5 a NULL offset is refused');
select pg_temp.refused('f_oneg',  'invalid_arguments', 'F6 a negative offset is refused');
select pg_temp.refused('f_rblank','invalid_arguments', 'F7 a blank reason filter is refused (use NULL for no filter)');
select pg_temp.refused('f_rempty','invalid_arguments', 'F8 an empty reason filter is refused');
select pg_temp.refused('f_rlong', 'invalid_arguments', 'F9 a reason filter longer than 120 characters is refused');
select pg_temp.refused('f_range_eq',  'invalid_arguments', 'F10 an empty range (p_from = p_to) is refused');
select pg_temp.refused('f_range_rev', 'invalid_arguments', 'F11 a reversed range (p_from > p_to) is refused');
select pg_temp.ha('f_r120', format('p_reason => %L', repeat('x', 120)));
select pg_temp.ok(pg_temp.tot('f_r120') = 0, 'F12 a reason filter of exactly 120 characters is accepted (and simply matches nothing)');
select pg_temp.ha('f_inj', $$p_reason => 'x''; drop table public.inventory_adjustments; --'$$);
select pg_temp.ok(pg_temp.tot('f_inj') = 0 and to_regclass('public.inventory_adjustments') is not null,
  'F13 an injection-style reason is just a literal that matches nothing (no dynamic SQL; the table still exists)');
select pg_temp.same('every validation refusal and read');

-- ===========================================================================
-- G. READ-ONLY, TABLE STILL CLOSED, NO NEW GRANTS, ADJUSTMENT FUNCTION UNCHANGED
-- ===========================================================================
select pg_temp.ok(
  pg_temp.stock_all() = (select h from t_h where k = 'stock0')
  and pg_temp.hist_all() = (select h from t_h where k = 'hist0')
  and pg_temp.ord_hash() = (select h from t_h where k = 'ord0'),
  'G1 after dozens of reads: EVERY stock value (products and variants, real ones too), EVERY history row and every order are byte-for-byte unchanged');
select pg_temp.ok(
  pg_temp.pstock(1) = 27 and pg_temp.pstock(2) = 6 and pg_temp.pstock(3) = 5
  and pg_temp.vstock(1) = 12 and pg_temp.vstock(2) = 2 and pg_temp.vstock(3) = 3
  and (select in_stock from public.products where id = pg_temp.p(1)),
  'G2 the fixture stock is exactly the replayed history (27, 6, 5, 12, 2, 3): the function moved no stock and no in_stock flag');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text = (select h from t_h where k = 'fn0')
  and pg_temp.acl_hash() = (select h from t_h where k = 'acl0')
  and pg_temp.pol_hash() = (select h from t_h where k = 'pol0')
  and (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')) = (select h from t_h where k = 'rel0'),
  'G3 running the function added no function, table, grant, RLS flag or policy');

-- Direct access to the audit table stays impossible for every browser identity, admin included.
select pg_temp.run('g_sel_a', 'anon', null, 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('g_sel_a', 'G4 anon cannot SELECT inventory_adjustments (permission denied, not 0 rows)');
select pg_temp.run('g_sel_c', 'authenticated', pg_temp.u(1), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('g_sel_c', 'G5 an authenticated customer cannot SELECT inventory_adjustments');
select pg_temp.run('g_sel_s', 'authenticated', pg_temp.u(2), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('g_sel_s', 'G6 authenticated staff cannot SELECT inventory_adjustments');
select pg_temp.run('g_sel_d', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.inventory_adjustments');
select pg_temp.denied('g_sel_d', 'G7 even an authenticated ADMIN cannot SELECT inventory_adjustments directly (the function is the only read path)');
select pg_temp.run('g_ins_d', 'authenticated', pg_temp.u(3),
  format($q$with i as (insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason)
                       values (%L::uuid, 1, 1, 2, 'T6C2B1 direct') returning 1) select count(*)::text from i$q$, pg_temp.p(1)));
select pg_temp.denied('g_ins_d', 'G8 an authenticated admin cannot INSERT into the history table directly');
select pg_temp.run('g_upd_d', 'authenticated', pg_temp.u(3),
  $q$with u as (update public.inventory_adjustments set note = 'tampered' returning 1) select count(*)::text from u$q$);
select pg_temp.denied('g_upd_d', 'G9 an authenticated admin cannot UPDATE history rows directly');
select pg_temp.run('g_del_d', 'authenticated', pg_temp.u(3),
  $q$with d as (delete from public.inventory_adjustments returning 1) select count(*)::text from d$q$);
select pg_temp.denied('g_del_d', 'G10 an authenticated admin cannot DELETE history rows directly');
select pg_temp.ok(
  not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'INSERT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'UPDATE')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'REFERENCES'))
  and not exists (select 1 from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                  where c.oid = 'public.inventory_adjustments'::regclass and a.grantee = 0),
  'G11 neither anon, authenticated nor PUBLIC holds ANY privilege (table or column level) on inventory_adjustments');
select pg_temp.ok(
  (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
  and (select coalesce(string_agg(t.tgname, ',' order by t.tgname collate "C"), '') from pg_trigger t
       where t.tgrelid = 'public.inventory_adjustments'::regclass and not t.tgisinternal)
      in ('', 'inventory_adjustments_append_only,inventory_adjustments_no_truncate'),
  'G12 the history table still has RLS on, NO policy (no browser policy) and no trigger other than (from Phase 9B) the two append-only guards');
select pg_temp.ok(
  not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.orders')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'G13 NO NEW BROAD GRANTS: anon / authenticated still cannot write the stock tables or orders (and the ACL / policy hashes in G3 are unchanged)');
select pg_temp.ok(
  not exists (select 1 from pg_policies where schemaname = 'public'
              and tablename in ('orders', 'order_items', 'order_status_history', 'products', 'product_variants',
                                'categories', 'inventory_adjustments')
              and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  'G14 still no write policy on the protected tables');
select pg_temp.ok(
  (select array_agg(proname::text order by proname::text) from pg_proc
   where pronamespace = 'public'::regnamespace and prosrc ilike '%inventory_adjustments%')
  in (array['admin_adjust_inventory', 'admin_list_inventory_adjustments'],
      array['admin_adjust_inventory', 'admin_list_inventory_adjustments', 'inventory_adjustments_guard', 'inventory_log_stock_change']),
  'G15 the functions touching the history table are the verified writer admin_adjust_inventory and this reader (plus, from Phase 9B, the append-only guard and the stock-movement trigger function)');
select pg_temp.ok(
  not exists (select 1 from pg_proc where proname in ('create_order', 'set_order_status', 'restock_cancelled_order')
              and pronamespace = 'public'::regnamespace and prosrc ilike '%inventory_adjustments%'),
  'G16 the order logic (create_order / set_order_status / restock) does not reference the history table');

-- 6C.2.2A.2 admin_adjust_inventory() is unchanged
select pg_temp.ok(
  to_regprocedure('public.admin_adjust_inventory(uuid,integer,text,uuid,text)') is not null
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_adjust_inventory') = 1
  and pg_get_function_arguments('public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
      = 'p_product_id uuid, p_adjustment_quantity integer, p_reason text, p_variant_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text'
  and (select prosecdef and provolatile = 'v' and proconfig = array['search_path=public, pg_temp']::text[]
       from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
  and not has_function_privilege('anon', 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)', 'EXECUTE'),
  'G17 admin_adjust_inventory keeps its signature, SECURITY DEFINER, VOLATILE, search_path and ACL');
-- The expected hash is of the CURRENT admin_adjust_inventory() body: the version installed by
-- 20261005100000_phase6i2_audit_gap_writers.sql (Phase 6I.2, section 7), which supersedes the
-- 6C.2.2A.2 body from 20261004100000_phase6c2_admin_inventory_adjustment.sql by adding the
-- admin_audit_log write. The hash is taken over the text between $fn$ ... $fn$ after a
-- deterministic, test-local normalization that ONLY unifies line endings (CRLF / lone CR -> LF)
-- and trims leading/trailing whitespace (space, tab, CR, LF). Internal whitespace, indentation and
-- comments are NOT touched, so any meaningful change to the body still changes the hash and fails.
-- (6I.2 body: un-normalized md5 0ba2300d5b18483a6285efabf80073cf, normalized md5
--  913d8a3ebf1c993847e08bf556215819. The old 6C.2.2A.2 normalized md5 was
--  6b8af05fe0cfc8899985bc6b1a789042; it is no longer expected once 6I.2 is applied.)
create or replace function pg_temp.norm_src(p_src text) returns text language sql immutable as $$
  select btrim(replace(replace(p_src, E'\r\n', E'\n'), E'\r', E'\n'), E' \t\r\n') $$;
-- Phase 9B redefined the function with exactly two additions (the transaction-local skip flag set
-- before and cleared after the stock UPDATE). The pin below is the 9B normalized md5; the second
-- condition proves the 9B body is the 6I.2 body plus ONLY those additions: strip them and the old
-- 6I.2 normalized md5 (913d8a3e...) comes back.
select pg_temp.ok(
  (select md5(pg_temp.norm_src(prosrc)) from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
    = '3438d97cfac568d18f47b45926de1c56'
  and (select md5(pg_temp.norm_src(
         regexp_replace(
           regexp_replace(prosrc, E'  -- Phase 9B: tell the stock-movement trigger.*?true\\);\n', '', ''),
           E'  perform set_config\\(''app.inventory_ledger_skip'', '''', true\\);\n', '', '')))
       from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
    = '913d8a3ebf1c993847e08bf556215819',
  'G18 admin_adjust_inventory() source is the verified 6I.2 body plus only the two Phase 9B skip-flag additions (normalized md5 pin, and 6I.2 md5 after stripping them)');
select pg_temp.adj('g_zero', 'authenticated', pg_temp.u(3), pg_temp.p(1), '0', 'T6C2B1 zero');
select pg_temp.refused('g_zero', 'zero_adjustment_not_allowed', 'G19 admin_adjust_inventory still refuses a zero delta');
select pg_temp.adj('g_neg', 'authenticated', pg_temp.u(3), pg_temp.p(2), '-7', 'T6C2B1 too much');
select pg_temp.refused('g_neg', 'negative_stock_not_allowed', 'G20 admin_adjust_inventory still refuses negative stock (6 on hand, -7 requested)');
select pg_temp.adj('g_cust', 'authenticated', pg_temp.u(1), pg_temp.p(1), '1', 'T6C2B1 customer');
select pg_temp.gated('g_cust', 'G21 admin_adjust_inventory still refuses a customer');
select pg_temp.same('the three admin_adjust_inventory refusals');
-- And it still writes exactly one row that the new reader shows, with the stock moved by exactly the delta.
select pg_temp.mk('h7', pg_temp.u(4), pg_temp.p(2), '3', 'T6C2B1 after reader');
select pg_temp.ha('g_h7', format('p_product_id => %L::uuid, p_limit => 100', pg_temp.p(2)));
select pg_temp.ok(pg_temp.pstock(2) = 9
  and pg_temp.tot('g_h7') = 2
  and pg_temp.lbl('g_h7') = array['h7', 'h5']
  and (pg_temp.row_of('g_h7', 'h7') ->> 'previous_quantity')::integer = 6
  and (pg_temp.row_of('g_h7', 'h7') ->> 'new_quantity')::integer = 9
  and (pg_temp.row_of('g_h7', 'h7') ->> 'changed_by')::uuid = pg_temp.u(4),
  'G22 a NEW adjustment made through the unchanged writer shows up in the reader at the top of its product (6 -> 9) and the stock moved by exactly +3');

-- ===========================================================================
-- H. REGRESSION: earlier phases
-- ===========================================================================
select pg_temp.ok(
  -- Later phases added admin functions (6G.4A payment readers; 6I.1 audit-log reader + 2 trigger functions);
  -- 6G.3 payment writers update only orders.payment_status. Compared bytewise (collate "C").
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
    = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[]
  and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                  and (proname ~* '(mark|set).*(paid|refund)' or proname ~* 'admin.*(payment|refund)')
                  and proname !~ '^admin_(get|list)_(payment|refund)'),  -- read-only 6G.4A readers are allowed; any writer is not
  'H1 the admin API is exactly the fifteen known functions (the fourteen of earlier phases + admin_list_inventory_adjustments); no payment or refund writer exists');
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
  'H2 every admin_* function is SECURITY DEFINER, pins search_path, calls require_admin(), is not executable by anon and is executable by authenticated');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'H3 a browser role still cannot execute require_admin() directly');
select pg_temp.ok(
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
              and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'H4 REGRESSION 5B.2: every SECURITY DEFINER function in public pins search_path = public, pg_temp');
select pg_temp.run('h_inv_s', 'authenticated', pg_temp.u(2), $$select public.admin_list_inventory(p_search => 'T6C2B1')::text$$);
select pg_temp.gated('h_inv_s', 'H5 REGRESSION 6C.2.1: admin_list_inventory still refuses staff');
select pg_temp.run('h_inv_a', 'authenticated', pg_temp.u(3), $$select public.admin_list_inventory(p_search => 'T6C2B1')::text$$);
select pg_temp.ok((select (res::jsonb ->> 'total')::integer from t_res where k = 'h_inv_a') = 6,
  'H6 REGRESSION 6C.2.1: admin_list_inventory (admin) still lists the six fixture stock units (p1 + its 2 variants, p2, p3 + its variant)');
select pg_temp.run('h_ord_a', 'authenticated', pg_temp.u(3), 'select public.admin_list_orders()::text');
select pg_temp.succeeded('h_ord_a', 'H7 REGRESSION 6B.1: admin_list_orders still works for an admin');
select pg_temp.run('h_prod_c', 'authenticated', pg_temp.u(1), 'select public.admin_list_products()::text');
select pg_temp.gated('h_prod_c', 'H8 REGRESSION 6C.1A: admin_list_products still refuses a customer');
select pg_temp.snap();

do $$ begin raise notice 'ALL PHASE 6C.2.2B.1 TESTS PASSED'; end $$;

rollback;
