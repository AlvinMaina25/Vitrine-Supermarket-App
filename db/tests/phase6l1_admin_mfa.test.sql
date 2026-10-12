-- Phase 6L.1 test: admin MFA gate (admin_security_settings, admin_mfa_satisfied, require_admin, admin policies).
-- NOT RUN unless the report says so. Needs migrations up to 20261005140000 applied (Supabase-style auth
-- schema: auth.users, auth.uid(), auth.jwt(), roles anon/authenticated/service_role).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end, including the flag flips.
-- Fixture users use ids ...6c01....  (1 = admin, 2 = customer).
begin;

create temp table t_res (k text primary key, res text, err text, state text, det text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: % || stored results: %', n,
      (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'res', left(res, 200), 'err', err, 'state', state, 'detail', det)), '[]'::jsonb) from t_res);
  end if;
  raise notice 'PASS: %', n;
end $$;

-- run(key, role, user id or null, aal claim or null, sql returning one text value)
create or replace function pg_temp.run(k text, r text, uid uuid, aal text, q text) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_det text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then ''
         else json_build_object('sub', uid, 'role', r, 'aal', aal)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  perform set_config('request.jwt.claim.role', r, true);
  begin
    execute format('set local role %I', r);
    execute q into v_res;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_det = pg_exception_detail;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  delete from t_res where t_res.k = run.k;
  insert into t_res values (k, v_res, v_err, v_state, v_det);
end $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6c010000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;
create or replace function pg_temp.det(k text) returns text language sql as $$ select det from t_res where t_res.k = det.k $$;
create or replace function pg_temp.allowed(k text) returns boolean language sql as $$
  select state is null from t_res where t_res.k = allowed.k $$;

-- One admin RPC that goes through require_admin() and that authenticated may execute (Phase 6A).
create or replace function pg_temp.gate_q() returns text language sql as $$
  select 'select left(public.admin_dashboard_summary()::text, 20)' $$;

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6l1-admin@example.test',    'authenticated', 'authenticated', '{"full_name":"T6L1 Admin"}'),
  (pg_temp.u(2), 't6l1-customer@example.test', 'authenticated', 'authenticated', '{"full_name":"T6L1 Customer"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(1), 'admin');

select pg_temp.ok(exists (select 1 from public.profiles where id = pg_temp.u(2))
                  and exists (select 1 from public.profiles where id = pg_temp.u(1)),
  'PRECONDITION: the new-user trigger created profile rows for both fixture users');

-- ---------------------------------------------------------------- settings table: shape and lockout safety
select pg_temp.ok((select count(*) from public.admin_security_settings) = 1, 'T0a settings table holds exactly one row');
select pg_temp.ok((select require_mfa from public.admin_security_settings) is false,
  'T0b enforcement ships OFF (require_mfa = false) - owner reads it');
select pg_temp.ok(
  (select c.relrowsecurity from pg_class c where c.oid = 'public.admin_security_settings'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'admin_security_settings'),
  'T0c RLS is on and the table has no policy');

-- A second row is impossible.
do $$ begin
  begin
    insert into public.admin_security_settings (id, require_mfa) values (false, true);
    raise exception 'second row accepted';
  exception when check_violation or unique_violation then null; end;
end $$;
select pg_temp.ok((select count(*) from public.admin_security_settings) = 1, 'T0d a second settings row is refused');

-- ---------------------------------------------------------------- flag OFF
update public.admin_security_settings set require_mfa = false;

select pg_temp.run('off_admin_aal1', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.gate_q());
select pg_temp.ok(pg_temp.allowed('off_admin_aal1'), 'T1 flag off + aal1 admin: allowed');

select pg_temp.run('off_admin_noclaim', 'authenticated', pg_temp.u(1), null, pg_temp.gate_q());
select pg_temp.ok(pg_temp.allowed('off_admin_noclaim'), 'T1b flag off + admin with no aal claim: allowed');

select pg_temp.run('off_cust', 'authenticated', pg_temp.u(2), 'aal1', pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('off_cust') = '42501' and pg_temp.det('off_cust') = 'not_authorised',
  'T4a flag off + customer: denied, detail not_authorised');

select pg_temp.run('off_anon', 'anon', null, null, pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('off_anon') = '42501' and pg_temp.det('off_anon') is distinct from 'mfa_required',
  'T4b flag off + anon: denied (42501), not mfa_required');

-- ---------------------------------------------------------------- flag ON
update public.admin_security_settings set require_mfa = true;

select pg_temp.run('on_admin_aal1', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('on_admin_aal1') = '42501' and pg_temp.det('on_admin_aal1') = 'mfa_required',
  'T2 flag on + aal1 admin: denied, SQLSTATE 42501, detail mfa_required');

select pg_temp.run('on_admin_noclaim', 'authenticated', pg_temp.u(1), null, pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('on_admin_noclaim') = '42501' and pg_temp.det('on_admin_noclaim') = 'mfa_required',
  'T2b flag on + admin with no aal claim: denied, mfa_required (fails closed)');

select pg_temp.run('on_admin_aal2', 'authenticated', pg_temp.u(1), 'aal2', pg_temp.gate_q());
select pg_temp.ok(pg_temp.allowed('on_admin_aal2'), 'T3 flag on + aal2 admin: allowed');

select pg_temp.run('on_cust_aal1', 'authenticated', pg_temp.u(2), 'aal1', pg_temp.gate_q());
select pg_temp.run('on_cust_aal2', 'authenticated', pg_temp.u(2), 'aal2', pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('on_cust_aal1') = '42501' and pg_temp.det('on_cust_aal1') = 'not_authorised'
              and pg_temp.state('on_cust_aal2') = '42501' and pg_temp.det('on_cust_aal2') = 'not_authorised',
  'T4c flag on + customer (aal1 and aal2): denied, detail not_authorised (aal2 does not make a customer an admin)');

select pg_temp.run('on_anon', 'anon', null, null, pg_temp.gate_q());
select pg_temp.ok(pg_temp.state('on_anon') = '42501' and pg_temp.det('on_anon') is distinct from 'mfa_required',
  'T4d flag on + anon: denied (42501), not mfa_required');

-- ---------------------------------------------------------------- RLS policies on flag ON
-- profiles: admin sees every row at aal2, only the own-row policy at aal1.
select pg_temp.run('pf_aal2', 'authenticated', pg_temp.u(1), 'aal2', 'select count(*)::text from public.profiles');
select pg_temp.run('pf_aal1', 'authenticated', pg_temp.u(1), 'aal1', 'select count(*)::text from public.profiles');
select pg_temp.ok(pg_temp.res('pf_aal2')::bigint = (select count(*) from public.profiles)
              and pg_temp.res('pf_aal1')::bigint = 1,
  'P1 flag on: admin reads all profiles at aal2, only their own row at aal1');

-- customer_notes: admin reads at aal2, nothing at aal1.
insert into public.customer_notes (customer_id, notes, updated_by)
  values (pg_temp.u(2), 't6l1 note', pg_temp.u(1));
select pg_temp.run('cn_aal2', 'authenticated', pg_temp.u(1), 'aal2', 'select count(*)::text from public.customer_notes');
select pg_temp.run('cn_aal1', 'authenticated', pg_temp.u(1), 'aal1', 'select count(*)::text from public.customer_notes');
select pg_temp.ok(pg_temp.res('cn_aal2')::bigint >= 1 and pg_temp.res('cn_aal1')::bigint = 0,
  'P2 flag on: customer_notes readable at aal2, empty at aal1');

-- flag OFF again: aal1 admin sees everything again.
update public.admin_security_settings set require_mfa = false;
select pg_temp.run('pf_off', 'authenticated', pg_temp.u(1), 'aal1', 'select count(*)::text from public.profiles');
select pg_temp.run('cn_off', 'authenticated', pg_temp.u(1), 'aal1', 'select count(*)::text from public.customer_notes');
select pg_temp.ok(pg_temp.res('pf_off')::bigint = (select count(*) from public.profiles)
              and pg_temp.res('cn_off')::bigint >= 1,
  'P3 flag off: aal1 admin reads all profiles and notes again');

-- products / variants / categories: the policy text carries the helper (rows depend on data).
select pg_temp.ok(
  (select count(*) from pg_policy pol
   where (pol.polrelid, pol.polname) in (
     ('public.products'::regclass,         'Products: admin read all'),
     ('public.product_variants'::regclass, 'Variants: admin read all'),
     ('public.categories'::regclass,       'Categories: admin read all'),
     ('public.profiles'::regclass,         'Profiles: admin read all'),
     ('public.customer_notes'::regclass,   'Customer notes: admin read'))
     and pg_get_expr(pol.polqual, pol.polrelid) like '%is_admin%'
     and pg_get_expr(pol.polqual, pol.polrelid) like '%admin_mfa_satisfied%') = 5,
  'P4 all five admin read policies use is_admin(auth.uid()) and admin_mfa_satisfied()');

-- ---------------------------------------------------------------- settings table: no API role can read or write
select pg_temp.run('st_sel_anon',  'anon',          null,          null,   'select count(*)::text from public.admin_security_settings');
select pg_temp.run('st_sel_auth',  'authenticated', pg_temp.u(1),  'aal2', 'select count(*)::text from public.admin_security_settings');
select pg_temp.run('st_sel_svc',   'service_role',  null,          null,   'select count(*)::text from public.admin_security_settings');
select pg_temp.run('st_upd_anon',  'anon',          null,          null,   'with u as (update public.admin_security_settings set require_mfa = false returning 1) select count(*)::text from u');
select pg_temp.run('st_upd_auth',  'authenticated', pg_temp.u(1),  'aal2', 'with u as (update public.admin_security_settings set require_mfa = false returning 1) select count(*)::text from u');
select pg_temp.run('st_upd_svc',   'service_role',  null,          null,   'with u as (update public.admin_security_settings set require_mfa = false returning 1) select count(*)::text from u');
select pg_temp.run('st_ins_auth',  'authenticated', pg_temp.u(1),  'aal2', 'with i as (insert into public.admin_security_settings (id, require_mfa) values (false, false) returning 1) select count(*)::text from i');
select pg_temp.run('st_ins_svc',   'service_role',  null,          null,   'with i as (insert into public.admin_security_settings (id, require_mfa) values (false, false) returning 1) select count(*)::text from i');
select pg_temp.run('st_del_auth',  'authenticated', pg_temp.u(1),  'aal2', 'with d as (delete from public.admin_security_settings returning 1) select count(*)::text from d');
select pg_temp.run('st_del_svc',   'service_role',  null,          null,   'with d as (delete from public.admin_security_settings returning 1) select count(*)::text from d');
select pg_temp.run('st_trunc_svc', 'service_role',  null,          null,   'truncate public.admin_security_settings');
select pg_temp.ok(
  (select bool_and(state = '42501') from t_res where k like 'st\_%' escape '\'),
  'S1 anon, authenticated and service_role: SELECT, INSERT, UPDATE, DELETE and TRUNCATE on admin_security_settings all fail with 42501');
select pg_temp.ok(
  not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r(role),
                    unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p(priv)
              where has_table_privilege(r.role, 'public.admin_security_settings', p.priv))
  and not exists (select 1 from pg_class c, aclexplode(c.relacl) a
                  where c.oid = 'public.admin_security_settings'::regclass and a.grantee = 0),
  'S2 no API role (and not PUBLIC) holds any privilege on admin_security_settings');
select pg_temp.ok((select count(*) from public.admin_security_settings) = 1, 'S3 the settings row is untouched by the failed writes');

-- ---------------------------------------------------------------- grants / definitions
select pg_temp.ok(
  not has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = 'public.require_admin()'::regprocedure and a.privilege_type = 'EXECUTE' and a.grantee = 0),
  'G1 require_admin() still not executable by PUBLIC, anon or authenticated');
select pg_temp.ok(
  (select p.prosecdef and p.provolatile = 's' and p.prorettype = 'uuid'::regtype and p.pronargs = 0
          and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
   from pg_proc p where p.oid = 'public.require_admin()'::regprocedure),
  'G2 require_admin(): no arguments, returns uuid, SECURITY DEFINER, STABLE, search_path = public, pg_temp');
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_mfa_satisfied()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_mfa_satisfied()', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = 'public.admin_mfa_satisfied()'::regprocedure and a.privilege_type = 'EXECUTE' and a.grantee = 0)
  and (select p.prosecdef and p.pronargs = 0 and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
       from pg_proc p where p.oid = 'public.admin_mfa_satisfied()'::regprocedure),
  'G3 admin_mfa_satisfied(): authenticated only (not PUBLIC/anon), SECURITY DEFINER, search_path = public, pg_temp');
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.is_admin(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.is_admin(uuid)', 'EXECUTE')
  and (select p.prosrc !~* 'mfa|aal' from pg_proc p where p.oid = 'public.is_admin(uuid)'::regprocedure),
  'G4 is_admin(uuid) unchanged: authenticated may execute it, anon may not, and it does not look at aal');

-- is_admin keeps answering for an aal1 admin while enforcement is on (the browser needs this to pick enrol vs challenge).
update public.admin_security_settings set require_mfa = true;
select pg_temp.run('isadm_aal1', 'authenticated', pg_temp.u(1), 'aal1', format('select public.is_admin(%L::uuid)::text', pg_temp.u(1)));
select pg_temp.ok(pg_temp.res('isadm_aal1') = 'true', 'G5 flag on: is_admin() still true for an aal1 admin (UI can pick enrol vs challenge)');

-- ---------------------------------------------------------------- behaviour of the helper itself
select pg_temp.run('h_aal1', 'authenticated', pg_temp.u(1), 'aal1', 'select public.admin_mfa_satisfied()::text');
select pg_temp.run('h_aal2', 'authenticated', pg_temp.u(1), 'aal2', 'select public.admin_mfa_satisfied()::text');
select pg_temp.ok(pg_temp.res('h_aal1') = 'false' and pg_temp.res('h_aal2') = 'true',
  'H1 flag on: admin_mfa_satisfied() is false at aal1 and true at aal2');
update public.admin_security_settings set require_mfa = false;
select pg_temp.run('h_off', 'authenticated', pg_temp.u(1), 'aal1', 'select public.admin_mfa_satisfied()::text');
select pg_temp.ok(pg_temp.res('h_off') = 'true', 'H2 flag off: admin_mfa_satisfied() is true at aal1');

rollback;
