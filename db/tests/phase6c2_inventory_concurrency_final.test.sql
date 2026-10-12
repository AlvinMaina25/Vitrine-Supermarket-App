-- =============================================================================
-- PHASE 6C.2.2B.2 database test: FINAL inventory consistency, function integrity and
-- security self-check of the whole Phase 6C inventory system. VERIFICATION ONLY.
--
-- STATUS: written, NOT RUN by the author (no PostgreSQL was available when it was written).
-- Run it on the dedicated Phase-5 DEV database (all Phase 6C migrations applied) as the
-- postgres / owner role:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6c2_inventory_concurrency_final.test.sql
-- One transaction, rolled back at the end: no fixture, stock change or history row survives.
-- "ALL PHASE 6C.2.2B.2 SQL TESTS PASSED" = everything in THIS file passed.
--
-- !!! WHAT THIS FILE CAN AND CANNOT PROVE !!!
-- A single .sql file runs in ONE database session, and Postgres cannot run two sessions inside
-- one transaction. Everything below is therefore SEQUENTIAL. It is labelled "sequential" and it
-- is NOT evidence of concurrency. TRUE concurrency (independent sessions racing on the same
-- product / variant, with real row locks, committed fixtures and a lost-update control) lives in
-- the companion script:
--   DATABASE_URL=postgres://... db/tests/phase6c2_inventory_concurrency_final.sh [SESSIONS]
-- Section L of this file only checks the STATIC lock design in the function source.
--
-- COVERS
--   A  function integrity: the four inventory functions (signature, DEFINER, search_path, volatility, ACL, gate-first)
--   B  sequential history consistency (replayed chain, one row per success, stock = start + sum)
--   C  refusals change nothing and write no history (negative, zero, overflow, mismatch, bad input, non-admin)
--   D  boundaries: no negative stock; exact integer maximum accepted; one past it refused
--   E  cross-function consistency: list_inventory / get_inventory / list_inventory_adjustments agree
--   F  authorization of all four functions (admin ok; staff / customer / anon / signed-out / forged / service_role refused)
--   G  table security: no direct access, RLS on, no policy, no trigger, no broad grants, service_role / postgres intact
--   H  admin_adjust_inventory is the ONLY stock-mutating admin function; no admin function exposes stock columns on write
--   I  no trigger mutates inventory; the history table is not a stock mutation mechanism
--   J  no public / anon execution of any admin_* function; require_admin() not callable by browser roles
--   K  ACL / policy / relation snapshot unchanged by everything above
--   L  static lock design in admin_adjust_inventory (NOT a concurrency proof)
-- =============================================================================
begin;

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
  insert into t_res values (p_k, v_res, v_err, v_state, nullif(v_detail, ''))
  on conflict (k) do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end;
$$;

create or replace function pg_temp.run(p_k text, p_role text, p_uid uuid, p_sql text)
returns void language plpgsql as $$
begin
  perform pg_temp.run_claims(p_k, p_role,
    case when p_uid is null then null else jsonb_build_object('sub', p_uid, 'role', p_role) end, p_sql);
end;
$$;

create or replace function pg_temp.res_of(p_k text) returns t_res language sql as $$
  select * from t_res where k = p_k $$;

create or replace function pg_temp.succeeded(p_k text, p_name text) returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is null and r.res is not null, p_name || ' [' || coalesce(r.state, 'ok') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

-- Refused with the privilege system (42501), never "0 rows" (anon / service_role / no EXECUTE or no auth.uid()).
create or replace function pg_temp.denied(p_k text, p_name text) returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

-- Refused BY THE GATE: 42501 + DETAIL not_authorised.
create or replace function pg_temp.gated(p_k text, p_name text) returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = '42501' and r.detail = 'not_authorised' and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ']');
end;
$$;

-- Refused by the function with SQLSTATE P0001 and this DETAIL.
create or replace function pg_temp.refused(p_k text, p_detail text, p_name text) returns void language plpgsql as $$
declare r t_res;
begin
  select * into r from t_res where k = p_k;
  if r.k is null then raise exception 'FAIL: % (no result recorded for %)', p_name, p_k; end if;
  perform pg_temp.ok(r.err is not null and r.state = 'P0001' and r.detail = p_detail and r.res is null,
    p_name || ' [' || coalesce(r.state, 'no error') || ' ' || coalesce(r.detail, '-') || ' ' || coalesce(r.err, '') || ']');
end;
$$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f7' || lpad(n::text, 9, '0'))::uuid $$;
create or replace function pg_temp.p(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f8000000' || lpad(n::text, 3, '0'))::uuid $$;
create or replace function pg_temp.v(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f9000000' || lpad(n::text, 3, '0'))::uuid $$;

create or replace function pg_temp.adj(p_k text, p_role text, p_uid uuid, p_prod uuid, p_delta text,
                                       p_reason text, p_var uuid default null, p_note text default null)
returns void language plpgsql as $$
begin
  perform pg_temp.run(p_k, p_role, p_uid, format(
    'select public.admin_adjust_inventory(%L::uuid, %s::integer, %L, %L::uuid, %L)::text',
    p_prod, coalesce(p_delta, 'null'), p_reason, p_var, p_note));
end;
$$;

create or replace function pg_temp.pstock(n integer) returns integer language sql as $$
  select stock_quantity from public.products where id = pg_temp.p(n) $$;
create or replace function pg_temp.vstock(n integer) returns integer language sql as $$
  select stock_quantity from public.product_variants where id = pg_temp.v(n) $$;
create or replace function pg_temp.hist(p_prod integer, p_var integer default null) returns bigint language sql as $$
  select count(*) from public.inventory_adjustments
  where product_id = pg_temp.p(p_prod) and variant_id is not distinct from (case when p_var is null then null else pg_temp.v(p_var) end) $$;

-- Whole-fixture signature: every fixture stock value, in_stock flag and the fixture history row count.
create or replace function pg_temp.sig() returns text language sql as $$
  select md5(
    coalesce((select string_agg(p.id::text || ':' || p.stock_quantity || ':' || p.in_stock, '|' order by p.id)
              from public.products p where p.slug like 'cf6c2-%'), '')
    || '#' ||
    coalesce((select string_agg(v.id::text || ':' || v.stock_quantity, '|' order by v.id)
              from public.product_variants v where v.sku like 'CF6C2-%'), '')
    || '#' ||
    (select count(*) from public.inventory_adjustments a
     where a.product_id in (select id from public.products where slug like 'cf6c2-%'))::text) $$;
create temp table t_snap (k text primary key, h text);
create or replace function pg_temp.snap() returns void language sql as $$
  insert into t_snap values ('s', pg_temp.sig()) on conflict (k) do update set h = excluded.h $$;
create or replace function pg_temp.same(p_name text) returns void language plpgsql as $$
begin
  perform pg_temp.ok(pg_temp.sig() = (select h from t_snap where k = 's'),
    'NOTHING CHANGED after refusal: ' || p_name || ' (all fixture stock, in_stock flags and the history row count are exactly as before)');
end;
$$;

-- Ledger of successful adjustments in CALL ORDER (inside one transaction now() is constant, so this
-- is the only reliable order). Used to replay the history chain.
create temp table t_seq (seq serial primary key, label text, adj_id uuid, prod uuid, var uuid,
                         prev integer, delta integer, new integer);
create or replace function pg_temp.mk(p_label text, p_uid uuid, p_prod uuid, p_delta integer, p_reason text,
                                      p_var uuid default null) returns void language plpgsql as $$
declare r t_res; j jsonb;
begin
  perform pg_temp.adj('mk_' || p_label, 'authenticated', p_uid, p_prod, p_delta::text, p_reason, p_var);
  select * into r from t_res where k = 'mk_' || p_label;
  perform pg_temp.ok(r.err is null and r.res is not null,
    'SUCCESS ' || p_label || ' [' || coalesce(r.err, 'ok') || ']');
  j := r.res::jsonb;
  insert into t_seq (label, adj_id, prod, var, prev, delta, new)
  values (p_label, (j ->> 'adjustment_id')::uuid, (j ->> 'product_id')::uuid, (j ->> 'variant_id')::uuid,
          (j ->> 'previous_quantity')::integer, (j ->> 'adjustment_quantity')::integer, (j ->> 'new_quantity')::integer);
end;
$$;

create temp table t_h (k text primary key, h text);
create or replace function pg_temp.acl_hash() returns text language sql as $$
  select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                 '|' order by c.relname), ''))
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') $$;
create or replace function pg_temp.pol_hash() returns text language sql as $$
  select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                 '|' order by tablename, policyname), ''))
  from pg_policies where schemaname = 'public' $$;

-- ---------------------------------------------------------------------------
-- Fixtures: u1 customer, u2 staff, u3 admin, u4 second admin
--   p1 stock 20 with variants v1 (7) and v2 (0); p2 stock 10 (no variants);
--   p3 stock 2147483640 with variant v3 2147483640 (overflow edge); p4 stock 5 with variant v4 (3) (mismatch partner)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 'cf6c2-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"CF6C2 Customer"}'),
  (pg_temp.u(2), 'cf6c2-staff@example.test',    'authenticated', 'authenticated', '{"full_name":"CF6C2 Staff"}'),
  (pg_temp.u(3), 'cf6c2-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"CF6C2 Admin"}'),
  (pg_temp.u(4), 'cf6c2-admin2@example.test',   'authenticated', 'authenticated', '{"full_name":"CF6C2 Admin Two"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin'), (pg_temp.u(4), 'admin');

insert into public.products (id, slug, name, sku, price_cents, unit_label, stock_quantity, in_stock, is_active) values
  (pg_temp.p(1), 'cf6c2-milk',  'CF6C2 Milk',  'CF6C2-MILK',  500, '1 L',  20, true, true),
  (pg_temp.p(2), 'cf6c2-rice',  'CF6C2 Rice',  'CF6C2-RICE',  700, '1 kg', 10, true, true),
  (pg_temp.p(3), 'cf6c2-big',   'CF6C2 Big',   'CF6C2-BIG',   100, null,   2147483640, true, true),
  (pg_temp.p(4), 'cf6c2-other', 'CF6C2 Other', 'CF6C2-OTHER', 100, null,   5, true, true);
insert into public.product_variants (id, product_id, name, sku, price_cents, stock_quantity, position, is_active) values
  (pg_temp.v(1), pg_temp.p(1), 'CF6C2 Milk 1L', 'CF6C2-MILK-1L', 500, 7, 1, true),
  (pg_temp.v(2), pg_temp.p(1), 'CF6C2 Milk 2L', 'CF6C2-MILK-2L', 900, 0, 2, true),
  (pg_temp.v(3), pg_temp.p(3), 'CF6C2 Big Var', 'CF6C2-BIG-V',   100, 2147483640, 1, true),
  (pg_temp.v(4), pg_temp.p(4), 'CF6C2 Other V', 'CF6C2-OTHER-V', 100, 3, 1, true);

select pg_temp.ok((select count(*) from public.products where slug like 'cf6c2-%') = 4
  and (select count(*) from public.product_variants where sku like 'CF6C2-%') = 4,
  'FIXTURE: four test products and four test variants exist');

insert into t_h values
  ('acl0', pg_temp.acl_hash()),
  ('pol0', pg_temp.pol_hash()),
  ('rel0', (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))),
  ('fn0',  (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace));

-- ===========================================================================
-- A. FUNCTION INTEGRITY of the four inventory functions
-- ===========================================================================
create temp table t_fn (sig text primary key, args text, vol "char");
insert into t_fn values
  ('public.admin_adjust_inventory(uuid,integer,text,uuid,text)',
   'p_product_id uuid, p_adjustment_quantity integer, p_reason text, p_variant_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text', 'v'),
  ('public.admin_list_inventory(integer,integer,text,boolean,uuid)', null, 's'),
  ('public.admin_get_inventory(uuid,uuid)', null, 's'),
  ('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)', null, 's');

select pg_temp.ok(
  (select count(*) from t_fn where to_regprocedure(sig) is not null) = 4
  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
       and proname in ('admin_adjust_inventory', 'admin_list_inventory', 'admin_get_inventory', 'admin_list_inventory_adjustments')) = 4,
  'A1 all four functions exist, each with exactly ONE overload (no extra signature was introduced)');
select pg_temp.ok(
  pg_get_function_arguments('public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
    = (select args from t_fn where sig like 'public.admin_adjust_inventory%')
  and pg_get_function_result('public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure) = 'jsonb'
  and not exists (select 1 from t_fn
                  where pg_get_function_result(to_regprocedure(sig)) <> 'jsonb'),
  'A2 admin_adjust_inventory keeps its exact signature; all four return jsonb');
select pg_temp.ok(
  not exists (select 1 from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig)
              where not p.prosecdef or p.provolatile <> f.vol),
  'A3 all four are SECURITY DEFINER; the writer is VOLATILE and the three readers are STABLE');
select pg_temp.ok(
  not exists (select 1 from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig)
              where p.proconfig is distinct from array['search_path=public, pg_temp']::text[]),
  'A4 search_path is EXACTLY "public, pg_temp" (and nothing else is configured) on all four');
select pg_temp.ok(
  not exists (select 1 from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig)
              where has_function_privilege('anon', p.oid, 'EXECUTE')
                 or not has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                            where a.grantee = 0 and a.privilege_type = 'EXECUTE')),
  'A5 PUBLIC and anon cannot EXECUTE any of the four; authenticated can (the gate is require_admin())');
select pg_temp.ok(
  not exists (select 1 from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig)
              where position('public.require_admin()' in p.prosrc) = 0),
  'A6 every one of the four calls public.require_admin()');
-- A7 is evaluated on EXECUTABLE text only: the DECLARE section (type declarations such as
-- "v_prod public.products%rowtype", which read no data) is skipped by starting at the first
-- "begin" line, and "--" line comments are stripped. The gate must still textually precede the
-- first reference to products / product_variants / inventory_adjustments in that executable text.
create temp table t_exec as
  select f.sig,
         p.prosrc as src,
         substring(p.prosrc from '(?i)\nbegin\s[\s\S]*$') as body_raw,
         regexp_replace(substring(p.prosrc from '(?i)\nbegin\s[\s\S]*$'), '--[^\n]*', '', 'g') as x
  from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig);
select pg_temp.ok(
  (select count(*) from t_exec where body_raw is not null) = 4
  and not exists (
    select 1 from t_exec
    where position('public.require_admin()' in x) = 0
       or position('public.require_admin()' in x) >
          least(nullif(position('public.products' in x), 0),
                nullif(position('public.product_variants' in x), 0),
                nullif(position('public.inventory_adjustments' in x), 0), 2147483647)),
  'A7 in every function the gate textually precedes the first reference to products / product_variants / inventory_adjustments (evaluated on executable text: DECLARE section skipped, -- comments stripped)');
-- A7b keeps A7 from being weakened: the skipped DECLARE section must contain no data access at all,
-- and the gate must be the first statement after BEGIN (nothing but whitespace / comments before it).
select pg_temp.ok(
  not exists (
    select 1 from t_exec
    where substring(src from '^[\s\S]*?(?=\nbegin\s)') ~* '\m(select|from|insert|update|delete|perform|execute)\M')
  and not exists (
    select 1 from t_exec
    where x !~* '^\s*begin\s+(perform\s+public\.require_admin\(\)|v_actor\s*:=\s*public\.require_admin\(\))'),
  'A7b the DECLARE section of every one of the four contains no select / from / insert / update / delete / perform / execute, and require_admin() is the FIRST executable statement after BEGIN');
select pg_temp.ok(
  not exists (select 1 from t_fn f join pg_proc p on p.oid = to_regprocedure(f.sig)
              where p.proowner <> (select oid from pg_roles where rolname = 'postgres')),
  'A8 all four are owned by postgres (so SECURITY DEFINER runs with the owner''s rights, not a browser role''s)');

-- ===========================================================================
-- B. SEQUENTIAL HISTORY CONSISTENCY (NOT concurrency; see the header)
-- ===========================================================================
select pg_temp.snap();
select pg_temp.mk('b1',  pg_temp.u(3), pg_temp.p(1),  10, 'CF6C2 restock');                         -- p1 20 -> 30
select pg_temp.mk('b2',  pg_temp.u(3), pg_temp.p(1),  -7, 'CF6C2 damaged');                         -- p1 30 -> 23
select pg_temp.mk('b3',  pg_temp.u(4), pg_temp.p(1),   5, 'CF6C2 restock', pg_temp.v(1));           -- v1  7 -> 12
select pg_temp.mk('b4',  pg_temp.u(3), pg_temp.p(1),  -2, 'CF6C2 damaged', pg_temp.v(1));           -- v1 12 -> 10
select pg_temp.mk('b5',  pg_temp.u(4), pg_temp.p(1),   4, 'CF6C2 count',   pg_temp.v(2));           -- v2  0 -> 4
select pg_temp.mk('b6',  pg_temp.u(3), pg_temp.p(1),   3, 'CF6C2 restock');                         -- p1 23 -> 26
select pg_temp.mk('b7',  pg_temp.u(3), pg_temp.p(2),  -4, 'CF6C2 damaged');                         -- p2 10 -> 6
select pg_temp.mk('b8',  pg_temp.u(3), pg_temp.p(2),   4, 'CF6C2 restock');                         -- p2  6 -> 10
select pg_temp.mk('b9',  pg_temp.u(3), pg_temp.p(2),  -10, 'CF6C2 to zero');                        -- p2 10 -> 0

select pg_temp.ok(pg_temp.pstock(1) = 20 + 10 - 7 + 3 and pg_temp.pstock(2) = 0,
  'B1 final PRODUCT stock = starting stock + the sum of all successful product-level adjustments (p1 20+6=26, p2 10+(-4+4-10)=0)');
select pg_temp.ok(pg_temp.vstock(1) = 7 + 5 - 2 and pg_temp.vstock(2) = 0 + 4,
  'B2 final VARIANT stock = starting stock + the sum of all successful variant-level adjustments (v1 7+3=10, v2 0+4=4)');
select pg_temp.ok(pg_temp.vstock(3) = 2147483640 and pg_temp.vstock(4) = 3 and pg_temp.pstock(3) = 2147483640 and pg_temp.pstock(4) = 5,
  'B3 units that were never adjusted are untouched');
select pg_temp.ok(
  (select count(*) from t_seq) = 9
  and (select count(*) from public.inventory_adjustments a join t_seq s on s.adj_id = a.id) = 9
  and not exists (select 1 from t_seq s where (select count(*) from public.inventory_adjustments a where a.id = s.adj_id) <> 1),
  'B4 every one of the nine successful adjustments created EXACTLY ONE history row (matched by the returned adjustment_id)');
select pg_temp.ok(
  (select count(*) from public.inventory_adjustments where product_id in (select id from public.products where slug like 'cf6c2-%')) = 9,
  'B5 no extra history rows exist for the fixture products (no orphan / duplicate row)');
select pg_temp.ok(
  not exists (select 1 from public.inventory_adjustments a join t_seq s on s.adj_id = a.id
              where a.previous_quantity + a.adjustment_quantity <> a.new_quantity
                 or a.previous_quantity <> s.prev or a.adjustment_quantity <> s.delta or a.new_quantity <> s.new
                 or a.new_quantity < 0),
  'B6 previous_quantity + adjustment_quantity = new_quantity on every row, the row equals what the function returned, and no row is negative');
-- Replay: for each stock unit, the rows in call order form one unbroken chain from the starting stock to the final stock.
select pg_temp.ok(
  not exists (
    select 1 from t_seq s
    where s.prev is distinct from coalesce(
            (select s2.new from t_seq s2 where s2.prod = s.prod and s2.var is not distinct from s.var and s2.seq < s.seq
             order by s2.seq desc limit 1),
            case when s.var is null then (select case s.prod when pg_temp.p(1) then 20 when pg_temp.p(2) then 10 end)
                 else (select case s.var when pg_temp.v(1) then 7 when pg_temp.v(2) then 0 end) end)),
  'B7 REPLAY: in call order each row''s previous_quantity equals the unit''s starting stock (first row) or the previous row''s new_quantity (no gap, no lost update)');
select pg_temp.ok(
  (select s.new from t_seq s where s.prod = pg_temp.p(1) and s.var is null order by seq desc limit 1) = pg_temp.pstock(1)
  and (select s.new from t_seq s where s.prod = pg_temp.p(2) and s.var is null order by seq desc limit 1) = pg_temp.pstock(2)
  and (select s.new from t_seq s where s.var = pg_temp.v(1) order by seq desc limit 1) = pg_temp.vstock(1)
  and (select s.new from t_seq s where s.var = pg_temp.v(2) order by seq desc limit 1) = pg_temp.vstock(2),
  'B8 the LAST new_quantity of each unit''s chain equals the stock actually stored (history and stock agree)');
select pg_temp.ok(
  not exists (select 1 from public.inventory_adjustments a join t_seq s on s.adj_id = a.id
              where a.changed_by not in (pg_temp.u(3), pg_temp.u(4)) or a.changed_by is null)
  and (select count(*) from public.inventory_adjustments a join t_seq s on s.adj_id = a.id where a.changed_by = pg_temp.u(4)) = 2,
  'B9 the actor is auth.uid() of the caller on every row (never a parameter, never null): 7 by admin one, 2 by admin two');
select pg_temp.ok(
  not exists (select 1 from public.inventory_adjustments a
              left join public.products p on p.id = a.product_id
              left join public.product_variants v on v.id = a.variant_id
              where a.product_id in (select id from public.products where slug like 'cf6c2-%')
                and (p.id is null or (a.variant_id is not null and (v.id is null or v.product_id <> a.product_id)))),
  'B10 no orphan: every history row points at an existing product, and every variant_id belongs to that row''s product_id');
select pg_temp.ok(
  (select count(*) from public.inventory_adjustments where product_id = pg_temp.p(1) and variant_id is null) = 3
  and (select count(*) from public.inventory_adjustments where variant_id = pg_temp.v(1)) = 2
  and (select count(*) from public.inventory_adjustments where variant_id = pg_temp.v(2)) = 1,
  'B11 product-level and variant-level history are kept apart (p1 product 3 rows, v1 2 rows, v2 1 row)');
select pg_temp.ok(
  (select in_stock from public.products where id = pg_temp.p(2)) is true
  and not exists (select 1 from public.products where slug like 'cf6c2-%' and in_stock is not true),
  'B12 in_stock is PRESERVED: p2 reached stock 0 and the flag was not flipped (it is manual by design)');
-- Independence of the two levels: re-assert with a dedicated pair of calls.
select pg_temp.mk('b13', pg_temp.u(3), pg_temp.p(1), 100, 'CF6C2 independence');                    -- p1 26 -> 126
select pg_temp.ok(pg_temp.vstock(1) = 10 and pg_temp.vstock(2) = 4 and pg_temp.pstock(1) = 126,
  'B13 a PRODUCT-level adjustment does not modify variant stock (v1 stays 10, v2 stays 4)');
select pg_temp.mk('b14', pg_temp.u(3), pg_temp.p(1), 50, 'CF6C2 independence', pg_temp.v(1));       -- v1 10 -> 60
select pg_temp.ok(pg_temp.pstock(1) = 126 and pg_temp.vstock(1) = 60 and pg_temp.vstock(2) = 4,
  'B14 a VARIANT-level adjustment does not modify the parent product stock (p1 stays 126) or a sibling variant');

-- ===========================================================================
-- C. REFUSALS change nothing and write no history
-- ===========================================================================
select pg_temp.snap();
select pg_temp.adj('c_neg', 'authenticated', pg_temp.u(3), pg_temp.p(2), '-1', 'CF6C2 refuse');           -- p2 is 0
select pg_temp.refused('c_neg', 'negative_stock_not_allowed', 'C1 -1 on a unit at stock 0 is refused (never clamped to zero)');
select pg_temp.same('negative product stock');
select pg_temp.adj('c_negv', 'authenticated', pg_temp.u(3), pg_temp.p(1), '-61', 'CF6C2 refuse', pg_temp.v(1));  -- v1 is 60
select pg_temp.refused('c_negv', 'negative_stock_not_allowed', 'C2 -61 on a variant at stock 60 is refused');
select pg_temp.same('negative variant stock');
select pg_temp.adj('c_zero', 'authenticated', pg_temp.u(3), pg_temp.p(1), '0', 'CF6C2 refuse');
select pg_temp.refused('c_zero', 'zero_adjustment_not_allowed', 'C3 a zero delta is refused');
select pg_temp.same('zero delta');
select pg_temp.adj('c_over', 'authenticated', pg_temp.u(3), pg_temp.p(3), '8', 'CF6C2 refuse');          -- 2147483640 + 8 = max + 1
select pg_temp.refused('c_over', 'stock_overflow', 'C4 INTEGER OVERFLOW (product): 2147483640 + 8 is refused, not wrapped');
select pg_temp.same('product overflow');
select pg_temp.adj('c_overv', 'authenticated', pg_temp.u(3), pg_temp.p(3), '2147483647', 'CF6C2 refuse', pg_temp.v(3));
select pg_temp.refused('c_overv', 'stock_overflow', 'C5 INTEGER OVERFLOW (variant): +2147483647 on a unit already near the maximum is refused');
select pg_temp.same('variant overflow');
select pg_temp.adj('c_mis', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'CF6C2 refuse', pg_temp.v(4));  -- v4 belongs to p4
select pg_temp.refused('c_mis', 'variant_product_mismatch', 'C6 VARIANT / PRODUCT MISMATCH: a variant of another product is refused');
select pg_temp.same('variant/product mismatch');
select pg_temp.adj('c_nov', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', 'CF6C2 refuse', '00000000-0000-4000-8000-6fa000000999');
select pg_temp.refused('c_nov', 'variant_not_found', 'C7 an unknown variant is refused');
select pg_temp.same('unknown variant');
select pg_temp.adj('c_nop', 'authenticated', pg_temp.u(3), '00000000-0000-4000-8000-6fa000000998', '1', 'CF6C2 refuse');
select pg_temp.refused('c_nop', 'product_not_found', 'C8 an unknown product is refused');
select pg_temp.same('unknown product');
select pg_temp.adj('c_noreason', 'authenticated', pg_temp.u(3), pg_temp.p(1), '1', '   ');
select pg_temp.refused('c_noreason', 'invalid_arguments', 'C9 a blank reason is refused');
select pg_temp.adj('c_nodelta', 'authenticated', pg_temp.u(3), pg_temp.p(1), null, 'CF6C2 refuse');
select pg_temp.refused('c_nodelta', 'invalid_arguments', 'C10 a NULL delta is refused');
select pg_temp.same('invalid arguments');
select pg_temp.adj('c_cust', 'authenticated', pg_temp.u(1), pg_temp.p(1), '1', 'CF6C2 refuse');
select pg_temp.gated('c_cust', 'C11 a customer is refused by the gate');
select pg_temp.adj('c_staff', 'authenticated', pg_temp.u(2), pg_temp.p(1), '1', 'CF6C2 refuse');
select pg_temp.gated('c_staff', 'C12 staff are refused by the gate');
select pg_temp.same('non-admin callers');
select pg_temp.ok((select count(*) from public.inventory_adjustments where created_at is not null
                   and product_id in (select id from public.products where slug like 'cf6c2-%')) = 11,
  'C13 after twelve refusals the history still holds exactly the 11 rows of the successful calls (9 + b13 + b14): failed adjustments wrote nothing');

-- ===========================================================================
-- D. BOUNDARIES: no negative stock, exact integer maximum
-- ===========================================================================
select pg_temp.ok(
  exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and contype = 'c'
          and pg_get_constraintdef(oid) ilike '%stock_quantity >= 0%')
  and exists (select 1 from pg_constraint where conrelid = 'public.product_variants'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%stock_quantity >= 0%'),
  'D1 the CHECK (stock_quantity >= 0) backstop exists on BOTH stock tables (defence in depth under the function''s own check)');
select pg_temp.ok(
  not exists (select 1 from public.products where stock_quantity < 0)
  and not exists (select 1 from public.product_variants where stock_quantity < 0),
  'D2 NO unit has negative stock anywhere in the database');
select pg_temp.mk('d3', pg_temp.u(3), pg_temp.p(3), 7, 'CF6C2 to the maximum');                      -- 2147483640 + 7 = 2147483647
select pg_temp.ok(pg_temp.pstock(3) = 2147483647, 'D3 the exact integer maximum (2147483647) is ACCEPTED');
select pg_temp.snap();
select pg_temp.adj('d4', 'authenticated', pg_temp.u(3), pg_temp.p(3), '1', 'CF6C2 one past');
select pg_temp.refused('d4', 'stock_overflow', 'D4 one past the maximum is refused');
select pg_temp.same('one past the maximum');
select pg_temp.adj('d5', 'authenticated', pg_temp.u(3), pg_temp.p(3), '-2147483647', 'CF6C2 to zero');   -- allowed: 2147483647 -> 0
select pg_temp.succeeded('d5', 'D5 a delta of -2147483647 (the most negative representable in range) is handled without integer wrap');
select pg_temp.ok(pg_temp.pstock(3) = 0, 'D6 that adjustment ended at exactly 0');

-- ===========================================================================
-- E. CROSS-FUNCTION CONSISTENCY (admin reads what admin wrote)
-- ===========================================================================
select pg_temp.run('e_list', 'authenticated', pg_temp.u(3),
  $q$select public.admin_list_inventory(p_limit => 100, p_product_id => '00000000-0000-4000-8000-6f8000000001')::text$q$);
select pg_temp.succeeded('e_list', 'E1 admin_list_inventory(product p1) succeeds for an admin');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements((select res::jsonb from t_res where k = 'e_list') -> 'inventory')) = 3
  and (select (e ->> 'stock_quantity')::integer from jsonb_array_elements((select res::jsonb from t_res where k = 'e_list') -> 'inventory') e
       where e ->> 'kind' = 'product') = pg_temp.pstock(1)
  and (select (e ->> 'stock_quantity')::integer from jsonb_array_elements((select res::jsonb from t_res where k = 'e_list') -> 'inventory') e
       where (e ->> 'variant_id')::uuid = pg_temp.v(1)) = pg_temp.vstock(1)
  and (select (e ->> 'stock_quantity')::integer from jsonb_array_elements((select res::jsonb from t_res where k = 'e_list') -> 'inventory') e
       where (e ->> 'variant_id')::uuid = pg_temp.v(2)) = pg_temp.vstock(2),
  'E2 admin_list_inventory shows the product unit and both variant units with EXACTLY the stock the adjustments produced (126 / 60 / 4)');
select pg_temp.run('e_get_p', 'authenticated', pg_temp.u(3),
  $q$select public.admin_get_inventory('00000000-0000-4000-8000-6f8000000001')::text$q$);
select pg_temp.run('e_get_v', 'authenticated', pg_temp.u(3),
  $q$select public.admin_get_inventory('00000000-0000-4000-8000-6f8000000001', '00000000-0000-4000-8000-6f9000000001')::text$q$);
select pg_temp.ok(
  (select (res::jsonb -> 'inventory' ->> 'stock_quantity')::integer from t_res where k = 'e_get_p') = pg_temp.pstock(1)
  and (select res::jsonb -> 'inventory' ->> 'kind' from t_res where k = 'e_get_p') = 'product'
  and (select (res::jsonb -> 'inventory' ->> 'stock_quantity')::integer from t_res where k = 'e_get_v') = pg_temp.vstock(1)
  and (select res::jsonb -> 'inventory' ->> 'kind' from t_res where k = 'e_get_v') = 'variant'
  and (select res::jsonb -> 'inventory' -> 'in_stock' from t_res where k = 'e_get_v') = 'null'::jsonb,
  'E3 admin_get_inventory (product and variant) reports the SAME stock as admin_list_inventory; a variant unit has in_stock null');
select pg_temp.run('e_hist_p', 'authenticated', pg_temp.u(3),
  $q$select public.admin_list_inventory_adjustments(p_limit => 100, p_product_id => '00000000-0000-4000-8000-6f8000000001')::text$q$);
select pg_temp.ok(
  (select (res::jsonb ->> 'total')::integer from t_res where k = 'e_hist_p') = 8             -- p1 rows: b1 b2 b3 b4 b5 b6 b13 b14
  and (select count(*) from jsonb_array_elements((select res::jsonb from t_res where k = 'e_hist_p') -> 'adjustments')) = 8,
  'E4 admin_list_inventory_adjustments(p1) returns the 8 history rows of p1 (product-level + variant-level)');
select pg_temp.ok(
  not exists (
    select 1 from t_seq s
    where s.prod = pg_temp.p(1)
      and not exists (
        select 1 from jsonb_array_elements((select res::jsonb from t_res where k = 'e_hist_p') -> 'adjustments') e
        where (e ->> 'id')::uuid = s.adj_id
          and (e ->> 'previous_quantity')::integer = s.prev
          and (e ->> 'adjustment_quantity')::integer = s.delta
          and (e ->> 'new_quantity')::integer = s.new
          and (e ->> 'variant_id')::uuid is not distinct from s.var
          and (e ->> 'product_id')::uuid = s.prod)),
  'E5 every p1 adjustment appears in the history API with identical previous / delta / new quantities and the right product_id / variant_id');
select pg_temp.ok(
  not exists (
    select 1 from jsonb_array_elements((select res::jsonb from t_res where k = 'e_hist_p') -> 'adjustments') e
    where (e ->> 'product_sku') <> 'CF6C2-MILK'
       or (e ->> 'product_name') <> 'CF6C2 Milk'
       or ((e ->> 'variant_id') is null) <> ((e ->> 'variant_sku') is null)
       or ((e ->> 'variant_id') is not null and (e ->> 'variant_sku') not like 'CF6C2-MILK-%')
       or (e ->> 'changed_by')::uuid not in (pg_temp.u(3), pg_temp.u(4))
       or (e ->> 'reason') <> btrim(e ->> 'reason')),
  'E6 history metadata is correct: product name / sku, variant sku only on variant rows, actor, trimmed reason');
select pg_temp.run('e_hist_v', 'authenticated', pg_temp.u(3),
  $q$select public.admin_list_inventory_adjustments(p_limit => 100, p_variant_id => '00000000-0000-4000-8000-6f9000000001')::text$q$);
select pg_temp.ok(
  (select (res::jsonb ->> 'total')::integer from t_res where k = 'e_hist_v') = 3
  and (select sum((e ->> 'adjustment_quantity')::integer) from jsonb_array_elements((select res::jsonb from t_res where k = 'e_hist_v') -> 'adjustments') e)
      = pg_temp.vstock(1) - 7,
  'E7 the variant filter returns exactly v1''s 3 rows and their deltas sum to (current stock - starting stock) = 53');
select pg_temp.ok(
  (select sum((e ->> 'adjustment_quantity')::integer)
   from jsonb_array_elements((select res::jsonb from t_res where k = 'e_hist_p') -> 'adjustments') e
   where e ->> 'variant_id' is null) = pg_temp.pstock(1) - 20,
  'E8 summing only the PRODUCT-level rows of p1 from the API gives (current stock - starting stock) = 106');

-- ===========================================================================
-- F. AUTHORIZATION of all four functions
-- ===========================================================================
create temp table t_calls (name text primary key, q text);
insert into t_calls values
  ('adjust', $q$select public.admin_adjust_inventory('00000000-0000-4000-8000-6f8000000004'::uuid, 1, 'CF6C2 auth')::text$q$),
  ('list',   $q$select public.admin_list_inventory(p_limit => 5)::text$q$),
  ('get',    $q$select public.admin_get_inventory('00000000-0000-4000-8000-6f8000000004'::uuid)::text$q$),
  ('hist',   $q$select public.admin_list_inventory_adjustments(p_limit => 5)::text$q$);

select pg_temp.snap();
do $f$
declare c record;
begin
  for c in select * from t_calls loop
    perform pg_temp.run('f_cust_'  || c.name, 'authenticated', pg_temp.u(1), c.q);
    perform pg_temp.run('f_staff_' || c.name, 'authenticated', pg_temp.u(2), c.q);
    perform pg_temp.run('f_anon_'  || c.name, 'anon', null, c.q);
    perform pg_temp.run('f_out_'   || c.name, 'authenticated', null, c.q);
    perform pg_temp.run_claims('f_forged_' || c.name, 'authenticated',
      jsonb_build_object('sub', '00000000-0000-4000-8000-6fa0000000f1', 'role', 'authenticated', 'is_admin', true,
                         'app_metadata', jsonb_build_object('role', 'admin')), c.q);
    perform pg_temp.run('f_sr_'    || c.name, 'service_role', null, c.q);
  end loop;
end;
$f$;
select pg_temp.ok(
  not exists (select 1 from t_calls c where not (
       (select err is not null and state = '42501' and detail = 'not_authorised' from t_res where k = 'f_cust_'   || c.name)
   and (select err is not null and state = '42501' and detail = 'not_authorised' from t_res where k = 'f_staff_'  || c.name)
   and (select err is not null and state = '42501' and detail = 'not_authorised' from t_res where k = 'f_out_'    || c.name)
   and (select err is not null and state = '42501' and detail = 'not_authorised' from t_res where k = 'f_forged_' || c.name))),
  'F1 a customer, staff, an authenticated session without a user and a forged "admin" claim are refused BY THE GATE (42501 not_authorised) on all four functions');
select pg_temp.ok(
  not exists (select 1 from t_calls c where not (
       (select err is not null and state = '42501' and res is null from t_res where k = 'f_anon_' || c.name)
   and (select err is not null and state = '42501' and res is null from t_res where k = 'f_sr_'   || c.name))),
  'F2 anon (no EXECUTE) and service_role (no auth.uid(), so the gate refuses) are refused with 42501 on all four functions');
select pg_temp.same('every non-admin call to all four functions, including the writer');
do $f$
declare c record;
begin
  for c in select * from t_calls loop
    perform pg_temp.run('f_admin_' || c.name, 'authenticated', pg_temp.u(3), c.q);
  end loop;
end;
$f$;
select pg_temp.ok(
  not exists (select 1 from t_calls c where (select err is not null or res is null from t_res where k = 'f_admin_' || c.name)),
  'F3 an admin can call all four functions');
select pg_temp.ok(pg_temp.pstock(4) = 6 and pg_temp.vstock(4) = 3 and pg_temp.hist(4) = 1 and pg_temp.hist(4, 4) = 0,
  'F4 the admin''s adjust call is the ONLY write among all those calls: p4 5 -> 6, one product-level history row, variant v4 untouched');

-- ===========================================================================
-- G. TABLE SECURITY of inventory_adjustments
-- ===========================================================================
select pg_temp.run('g_sel_a', 'anon', null, $q$select count(*)::text from public.inventory_adjustments$q$);
select pg_temp.denied('g_sel_a', 'G1 anon cannot SELECT inventory_adjustments directly');
select pg_temp.run('g_sel_u', 'authenticated', pg_temp.u(3), $q$select count(*)::text from public.inventory_adjustments$q$);
select pg_temp.denied('g_sel_u', 'G2 an authenticated ADMIN cannot SELECT inventory_adjustments directly (the API is the only reader)');
select pg_temp.run('g_ins_u', 'authenticated', pg_temp.u(3),
  format($q$with i as (insert into public.inventory_adjustments (product_id, previous_quantity, adjustment_quantity, new_quantity, reason)
            values (%L, 5, 1, 6, 'CF6C2 direct') returning 1) select count(*)::text from i$q$, pg_temp.p(4)));
select pg_temp.denied('g_ins_u', 'G3 an authenticated admin cannot INSERT a history row directly');
select pg_temp.run('g_upd_u', 'authenticated', pg_temp.u(3), $q$with u as (update public.inventory_adjustments set note = 'x' returning 1) select count(*)::text from u$q$);
select pg_temp.denied('g_upd_u', 'G4 an authenticated admin cannot UPDATE a history row directly');
select pg_temp.run('g_del_u', 'authenticated', pg_temp.u(3), $q$with d as (delete from public.inventory_adjustments returning 1) select count(*)::text from d$q$);
select pg_temp.denied('g_del_u', 'G5 an authenticated admin cannot DELETE a history row directly');
select pg_temp.run('g_trunc', 'authenticated', pg_temp.u(3), $q$truncate public.inventory_adjustments$q$);
select pg_temp.denied('g_trunc', 'G6 an authenticated admin cannot TRUNCATE the history table');
select pg_temp.run('g_stock_u', 'authenticated', pg_temp.u(3), format($q$update public.products set stock_quantity = 999 where id = %L$q$, pg_temp.p(4)));
select pg_temp.ok(
  (select err is not null and state = '42501' from t_res where k = 'g_stock_u') or pg_temp.pstock(4) = 6,
  'G7 an authenticated admin cannot write products.stock_quantity directly (denied, or zero rows under RLS - stock is still 6)');
select pg_temp.ok(pg_temp.pstock(4) = 6, 'G8 and p4''s stock is still 6 after that attempt');
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
  'G9 anon, authenticated and PUBLIC hold NO privilege of any kind (table or column level) on inventory_adjustments');
select pg_temp.ok(
  (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments'),
  'G10 RLS is ENABLED on inventory_adjustments and NO policy exists on it (no browser policy was added)');
select pg_temp.ok(
  not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
  and not exists (select 1 from pg_policies where schemaname = 'public'
                  and (qual ilike '%inventory_adjustments%' or with_check ilike '%inventory_adjustments%')),
  'G11 no policy on ANY table refers to inventory_adjustments either (nothing exposes it indirectly)');
select pg_temp.ok(
  has_table_privilege('service_role', 'public.inventory_adjustments', 'SELECT')
  and has_table_privilege('service_role', 'public.inventory_adjustments', 'INSERT')
  and not has_table_privilege('service_role', 'public.inventory_adjustments', 'UPDATE')
  and not has_table_privilege('service_role', 'public.inventory_adjustments', 'DELETE')
  and not has_table_privilege('service_role', 'public.inventory_adjustments', 'TRUNCATE')
  and has_table_privilege('postgres', 'public.inventory_adjustments', 'SELECT')
  and has_table_privilege('postgres', 'public.inventory_adjustments', 'INSERT')
  and (select relowner from pg_class where oid = 'public.inventory_adjustments'::regclass) = (select oid from pg_roles where rolname = 'postgres'),
  'G12 service_role keeps SELECT + INSERT only (Phase 9B revoked UPDATE / DELETE / TRUNCATE: the ledger is append-only) and postgres keeps its privileges (table still owned by postgres)');
select pg_temp.ok(
  not exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.orders'), ('public.order_items')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')),
  'G13 NO BROAD GRANTS: anon / authenticated cannot write products, product_variants, orders or order_items at table or column level');
select pg_temp.ok(
  not exists (select 1 from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S'
              where d.refobjid = 'public.inventory_adjustments'::regclass)
  and not exists (select 1 from pg_class s where s.relkind = 'S' and s.relnamespace = 'public'::regnamespace
                  and s.relname ilike '%inventory%'),
  'G14 no sequence belongs to (or is named after) the inventory history, so no sequence grant exists for it (the id is a gen_random_uuid() default)');
select pg_temp.ok(
  not exists (select 1 from pg_class s, aclexplode(coalesce(s.relacl, acldefault('S', s.relowner))) a
              where s.relkind = 'S' and s.relnamespace = 'public'::regnamespace and a.grantee = 0),
  'G15 no sequence in public is granted to PUBLIC (no broad sequence grant)');

-- ===========================================================================
-- H. admin_adjust_inventory is the ONLY stock-mutating admin function
-- ===========================================================================
select pg_temp.ok(
  (select array_agg(proname order by proname) from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%'
     and regexp_replace(prosrc, '\s+', ' ', 'g') ~* 'update public\.(products|product_variants) set [^;]*stock_quantity *=')
  = array['admin_adjust_inventory']::name[],
  'H1 among all admin_* functions ONLY admin_adjust_inventory assigns stock_quantity in an UPDATE');
select pg_temp.ok(
  not exists (select 1 from pg_proc
              where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname <> 'admin_adjust_inventory'
                and regexp_replace(prosrc, '\s+', ' ', 'g') ~* 'insert into public\.(products|product_variants) *\([^)]*(stock_quantity|in_stock)'),
  'H2 no OTHER admin_* write function can INSERT stock_quantity / in_stock (no unauthorized stock column is exposed through a new write function)');
select pg_temp.ok(
  not exists (select 1 from pg_proc
              where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname <> 'admin_adjust_inventory'
                and regexp_replace(prosrc, '\s+', ' ', 'g') ~* '(update|insert into|delete from) public\.inventory_adjustments'),
  'H3 no other admin_* function writes inventory_adjustments');
select pg_temp.ok(
  (select array_agg(proname order by proname) from pg_proc
   where pronamespace = 'public'::regnamespace and prosrc ilike '%inventory_adjustments%')
  = array['admin_adjust_inventory', 'admin_list_inventory_adjustments',
          'inventory_adjustments_guard', 'inventory_log_stock_change']::name[],
  'H4 exactly four functions reference the history table: the admin writer (admin_adjust_inventory), the reader (admin_list_inventory_adjustments) and, from Phase 9B, the append-only guard and the stock-movement trigger function');
select pg_temp.ok(
  not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('admin_list_inventory_adjustments', 'admin_list_inventory', 'admin_get_inventory')
              and regexp_replace(prosrc, '\s+', ' ', 'g') ~* '(update|insert into|delete from|truncate) public\.'),
  'H5 the three readers contain no INSERT / UPDATE / DELETE / TRUNCATE on any public table');
select pg_temp.ok(
  not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('create_order', 'set_order_status', 'restock_cancelled_order')
              and prosrc ilike '%inventory_adjustments%'),
  'H6 the order logic (create_order / set_order_status / restock_cancelled_order) does not touch the history table');

-- ===========================================================================
-- I. NO TRIGGER MUTATES INVENTORY
-- ===========================================================================
select pg_temp.ok(
  (select coalesce(string_agg(t.tgname, ',' order by t.tgname collate "C"), '') from pg_trigger t
   where t.tgrelid = 'public.inventory_adjustments'::regclass and not t.tgisinternal)
    = 'inventory_adjustments_append_only,inventory_adjustments_no_truncate',
  'I1 inventory_adjustments has exactly the two Phase 9B append-only guards and no other user trigger (nothing can silently change stock or rewrite the ledger)');
select pg_temp.ok(
  (select coalesce(string_agg(distinct f.proname::text, ',' order by f.proname::text), '')
   from pg_trigger t join pg_proc f on f.oid = t.tgfoid
   where not t.tgisinternal and f.prosrc ilike '%inventory_adjustments%')
    = 'inventory_adjustments_guard,inventory_log_stock_change'
  and not exists (select 1 from pg_trigger t join pg_proc f on f.oid = t.tgfoid
                  where not t.tgisinternal and f.prosrc ilike '%inventory_adjustments%'
                    and regexp_replace(f.prosrc, '\s+', ' ', 'g') ~* '(update|insert into|delete from) +(public\.)?(products|product_variants)\M'),
  'I2 the only trigger functions that reference inventory_adjustments are the Phase 9B guard and stock-movement writer, and neither writes a stock table');
select pg_temp.ok(
  not exists (select 1 from pg_trigger t join pg_proc f on f.oid = t.tgfoid
              where not t.tgisinternal and t.tgrelid in ('public.products'::regclass, 'public.product_variants'::regclass)
                and regexp_replace(f.prosrc, '\s+', ' ', 'g') ~* '(new\.stock_quantity *:=|set stock_quantity *=)'),
  'I3 no trigger on products / product_variants assigns stock_quantity (nothing mutates stock behind the writer''s back). If this fails, list the trigger and decide: it is a pre-Phase-6C trigger to allow-list in THIS test only, or a defect');

-- ===========================================================================
-- J. NO public / anon execution of any admin function
-- ===========================================================================
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%'
      -- 6I.1: admin_audit_log_block_change/_truncate are trigger functions (not callable RPCs), so the RPC rules do not apply.
      and p.proname !~ '^admin_audit_log_block_'
      and (not p.prosecdef
           or has_function_privilege('anon', p.oid, 'EXECUTE')
           or not has_function_privilege('authenticated', p.oid, 'EXECUTE')
           or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                      where a.grantee = 0 and a.privilege_type = 'EXECUTE')
           or position('public.require_admin()' in p.prosrc) = 0
           or p.proconfig is distinct from array['search_path=public, pg_temp']::text[])),
  'J1 EVERY admin_* function is SECURITY DEFINER, pins search_path exactly, calls require_admin(), has no PUBLIC / anon EXECUTE and is executable by authenticated');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE'),
  'J2 a browser role still cannot execute require_admin() directly');
select pg_temp.ok(
  -- Later phases added admin functions (6G.4A payment readers; 6I.1 audit-log reader + 2 trigger functions);
  -- 6G.3 payment writers update only orders.payment_status. Compared bytewise (collate "C").
  (select array_agg(proname order by proname collate "C") from pg_proc
   where pronamespace = 'public'::regnamespace and proname like 'admin\_%' and proname !~ '(delivery|customer)')
   = array['admin_adjust_inventory','admin_audit_log_block_change','admin_audit_log_block_truncate','admin_create_category','admin_create_product','admin_create_product_variant','admin_dashboard_summary','admin_get_inventory','admin_get_order','admin_get_payment_transaction','admin_get_product','admin_list_audit_log','admin_list_inventory','admin_list_inventory_adjustments','admin_list_orders','admin_list_payment_transactions','admin_list_products','admin_set_category_image','admin_set_order_status','admin_set_product_active','admin_set_product_image','admin_update_category','admin_update_product','admin_update_product_variant']::name[],
  'J3 the admin API is exactly the fifteen known functions (an unknown extra admin_* function would be a new, unreviewed stock/admin surface)');
select pg_temp.ok(
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
              and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'),
  'J4 REGRESSION 5B.2: every SECURITY DEFINER function in public pins search_path = public, pg_temp');

-- ===========================================================================
-- K. NOTHING in the grants / policies / relations / function set changed during this test
-- ===========================================================================
select pg_temp.ok(
  pg_temp.acl_hash() = (select h from t_h where k = 'acl0')
  and pg_temp.pol_hash() = (select h from t_h where k = 'pol0')
  and (select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')) = (select h from t_h where k = 'rel0')
  and (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace) = (select h from t_h where k = 'fn0'),
  'K1 table ACLs / RLS flags, policies, relation count and function count are IDENTICAL before and after every call in this test');

-- ===========================================================================
-- L. STATIC LOCK DESIGN of admin_adjust_inventory (reads the source; this is NOT a concurrency proof)
-- ===========================================================================
create temp table t_src as
  select regexp_replace(lower(prosrc), '\s+', ' ', 'g') as s
  from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure;
select pg_temp.ok(
  (select position('from public.products p where p.id = p_product_id for update' in s) > 0 from t_src),
  'L1 the product-level path locks the product row with SELECT ... FOR UPDATE before reading its stock');
select pg_temp.ok(
  (select position('perform 1 from public.products p where p.id = p_product_id for key share' in s) > 0
      and position('from public.product_variants v where v.id = p_variant_id and v.product_id = p_product_id for update' in s) > 0
      and position('for key share' in s) <
          position('from public.product_variants v where v.id = p_variant_id and v.product_id = p_product_id for update' in s)
   from t_src),
  'L2 the variant path locks the PRODUCT first (FOR KEY SHARE) and the VARIANT second (FOR UPDATE): the same product -> variant order create_order uses (no deadlock between them)');
select pg_temp.ok(
  (select position('for update' in s) < position('update public.products set stock_quantity = v_new where id = p_product_id' in s)
      and position('for update' in s) < position('insert into public.inventory_adjustments' in s)
      and position('update public.products set stock_quantity = v_new where id = p_product_id' in s)
          < position('insert into public.inventory_adjustments' in s)
   from t_src),
  'L3 the stock is read under the lock, then updated, then the history row is inserted (lock -> compute -> UPDATE -> INSERT)');
select pg_temp.ok(
  (select position('v_new_big := v_previous::bigint + p_adjustment_quantity::bigint' in s) > 0 from t_src)
  and (select position('stock_quantity = stock_quantity +' in s) = 0 from t_src),
  'L4 the new value is computed from the LOCKED current value (bigint, so overflow is detected); there is no unlocked "stock_quantity = stock_quantity + n" shortcut and no parameter for a final quantity');
select pg_temp.ok(
  (select length(s) - length(replace(s, 'insert into public.inventory_adjustments', '')) from t_src) = length('insert into public.inventory_adjustments'),
  'L5 exactly one INSERT INTO inventory_adjustments exists in the function (one history row per successful call)');
select pg_temp.ok(
  (select position('v_actor := public.require_admin()' in s) > 0 from t_src)
  and not exists (select 1 from pg_proc where oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure
                  and pronargs <> 5),
  'L6 the actor is taken from require_admin() / auth.uid(); the function has exactly five parameters (none for actor, previous or new quantity)');

select 'ALL PHASE 6C.2.2B.2 SQL TESTS PASSED (sequential + static; TRUE concurrency is proven ONLY by phase6c2_inventory_concurrency_final.sh)' as result;
rollback;
