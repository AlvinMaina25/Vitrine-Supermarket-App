-- Phase 6I.3 test: audit log retention (prune_admin_audit_log + trigger). NOT RUN unless the report says so.
-- Needs migrations up to 20261005130000 applied (Supabase-style auth schema: auth.users, auth.uid(),
-- roles anon/authenticated/service_role).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Precondition (checked first): the audit log holds NO row older than 2 years, so the empty-run and
-- exact-count checks are deterministic. Fixture rows use action prefix 't6i3_' and user ids ...6a0a....
-- Bulk fixtures are dated year 2000, i.e. older than any real row, so they are pruned first.
begin;

create temp table t_res (k text primary key, res text, err text, state text, det text);
create temp table t_base as
  select (select count(*) from public.admin_audit_log where action = 'audit_log_pruned') as summaries,
         (select count(*) from public.admin_audit_log) as total;

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: % || stored results: %', n,
      (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'res', left(res, 300), 'err', err, 'state', state, 'detail', det)), '[]'::jsonb) from t_res);
  end if;
  raise notice 'PASS: %', n;
end $$;

create or replace function pg_temp.run(k text, r text, uid uuid, q text) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_det text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then '' else json_build_object('sub', uid, 'role', r)::text end, true);
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
  insert into t_res values (k, v_res, v_err, v_state, v_det);
end $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a0a0000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;
create or replace function pg_temp.det(k text) returns text language sql as $$ select det from t_res where t_res.k = det.k $$;
create or replace function pg_temp.summaries() returns bigint language sql as $$
  select count(*) from public.admin_audit_log where action = 'audit_log_pruned' $$;
create or replace function pg_temp.fx(p_id integer) returns boolean language sql as $$
  select exists (select 1 from public.admin_audit_log where id = pg_temp.u(p_id)) $$;

-- ---------------------------------------------------------------- precondition
select pg_temp.ok(not exists (select 1 from public.admin_audit_log where created_at < now() - interval '2 years'),
  'PRECONDITION: no audit row older than 2 years exists yet (empty-run and exact-count checks need that)');

-- ---------------------------------------------------------------- structure and grants
select pg_temp.ok(
  (select p.pronargs = 0 and p.prosecdef and p.provolatile = 'v' and p.prorettype = 'integer'::regtype
          and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
   from pg_proc p where p.oid = to_regprocedure('public.prune_admin_audit_log()')),
  'S1 prune_admin_audit_log() has no arguments, is SECURITY DEFINER, VOLATILE, search_path = public, pg_temp, returns integer');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.prune_admin_audit_log()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.prune_admin_audit_log()', 'EXECUTE')
  and has_function_privilege('service_role', 'public.prune_admin_audit_log()', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = 'public.prune_admin_audit_log()'::regprocedure and a.privilege_type = 'EXECUTE'
                    and a.grantee not in (p.proowner, (select oid from pg_roles where rolname = 'service_role'))),
  'S2 EXECUTE on prune: owner and service_role only (not PUBLIC, anon, authenticated)');
select pg_temp.ok(
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname ~* 'audit' and proname !~ '^admin_audit_log_block_'
     and proname ~* '(prune|purge|retention|cleanup|delete|remove|clear|truncate)') = 1
  and not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                    and p.proname <> 'prune_admin_audit_log'
                    and p.prosrc ~* 'delete\s+from\s+(only\s+)?(public\.)?admin_audit_log\M'),
  'S3 prune_admin_audit_log is the only prune/purge function and the only code that deletes from admin_audit_log; none takes a period');
select pg_temp.ok(
  (select count(*) from pg_trigger t where t.tgrelid = 'public.admin_audit_log'::regclass and not t.tgisinternal and t.tgenabled = 'O'
     and ((t.tgname = 'admin_audit_log_no_change' and t.tgtype = 27) or (t.tgname = 'admin_audit_log_no_truncate' and t.tgtype = 34))) = 2
  and not has_function_privilege('anon', 'public.admin_audit_log_block_change()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.admin_audit_log_block_change()', 'EXECUTE'),
  'S4 both 6I.1 triggers still exist, enabled, same shape; the trigger function is still not executable by API roles');
select pg_temp.ok(
  not has_table_privilege('anon', 'public.admin_audit_log', 'DELETE') and not has_table_privilege('authenticated', 'public.admin_audit_log', 'DELETE')
  and not has_table_privilege('service_role', 'public.admin_audit_log', 'DELETE')
  and not has_table_privilege('service_role', 'public.admin_audit_log', 'UPDATE')
  and not has_table_privilege('service_role', 'public.admin_audit_log', 'TRUNCATE')
  and has_table_privilege('service_role', 'public.admin_audit_log', 'INSERT')
  and has_table_privilege('service_role', 'public.admin_audit_log', 'SELECT')
  and not has_table_privilege('anon', 'public.admin_audit_log', 'SELECT') and not has_table_privilege('authenticated', 'public.admin_audit_log', 'SELECT'),
  'S5 table grants unchanged: no API role can DELETE/UPDATE/TRUNCATE; service_role keeps SELECT and INSERT; anon/authenticated cannot read directly');

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6i3-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6I3 Cust"}'),
  (pg_temp.u(3), 't6i3-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I3 Admin"}'),
  (pg_temp.u(5), 't6i3-gone@example.test',  'authenticated', 'authenticated', '{"full_name":"T6I3 Gone"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'admin');

-- Expired: 101 (3 years), 104 (2 years + 1 day), 106 (3 years, actor to be deleted).
-- Kept:    102 (1 year), 103 (2 years - 1 day), 105 (exactly 2 years: the rule is strictly older), 107 (1 day, actor to be deleted).
insert into public.admin_audit_log (id, actor_id, action, target_id, reason, created_at) values
  (pg_temp.u(101), pg_temp.u(3), 't6i3_3y',        pg_temp.u(201), 'r101', now() - interval '3 years'),
  (pg_temp.u(102), pg_temp.u(3), 't6i3_1y',        pg_temp.u(201), 'r102', now() - interval '1 year'),
  (pg_temp.u(103), pg_temp.u(3), 't6i3_2y_minus1', pg_temp.u(201), 'r103', now() - interval '2 years' + interval '1 day'),
  (pg_temp.u(104), pg_temp.u(3), 't6i3_2y_plus1',  pg_temp.u(201), 'r104', now() - interval '2 years' - interval '1 day'),
  (pg_temp.u(105), pg_temp.u(3), 't6i3_2y_exact',  pg_temp.u(201), 'r105', now() - interval '2 years'),
  (pg_temp.u(106), pg_temp.u(5), 't6i3_gone_old',  pg_temp.u(202), 'r106', now() - interval '3 years'),
  (pg_temp.u(107), pg_temp.u(5), 't6i3_gone_new',  pg_temp.u(202), 'r107', now() - interval '1 day');

-- ---------------------------------------------------------------- the prune function is not callable by API roles
select pg_temp.run('p_anon',  'anon',          null,         $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.run('p_cust',  'authenticated', pg_temp.u(1), $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.run('p_admin', 'authenticated', pg_temp.u(3), $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.state('p_anon') = '42501' and pg_temp.state('p_cust') = '42501' and pg_temp.state('p_admin') = '42501',
  'P1 prune is not callable by anon, a customer or an admin (42501)');
select pg_temp.ok(pg_temp.fx(101) and pg_temp.fx(104) and pg_temp.fx(106), 'P2 the refused calls deleted nothing');

-- ---------------------------------------------------------------- direct DELETE / UPDATE / TRUNCATE still blocked
select pg_temp.run('x_anon',  'anon',          null,         $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_cust',  'authenticated', pg_temp.u(1), $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_admin', 'authenticated', pg_temp.u(3), $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_svc',   'service_role',  null,         $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('xo_old',  'postgres',      null,         format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(101)));
select pg_temp.run('xo_new',  'postgres',      null,         format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(102)));
select pg_temp.run('u_anon',  'anon',          null,         $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_cust',  'authenticated', pg_temp.u(1), $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_admin', 'authenticated', pg_temp.u(3), $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_svc',   'service_role',  null,         $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('uo_old',  'postgres',      null,         format($q$with r as (update public.admin_audit_log set reason = 'x' where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(101)));
select pg_temp.run('uo_act',  'postgres',      null,         format($q$with r as (update public.admin_audit_log set actor_id = null where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(101)));
select pg_temp.run('t_anon',  'anon',          null,         $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_cust',  'authenticated', pg_temp.u(1), $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_admin', 'authenticated', pg_temp.u(3), $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_svc',   'service_role',  null,         $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_own',   'postgres',      null,         $q$truncate public.admin_audit_log$q$);

select pg_temp.ok(pg_temp.state('x_anon') = '42501' and pg_temp.state('x_cust') = '42501'
                  and pg_temp.state('x_admin') = '42501' and pg_temp.state('x_svc') = '42501',
  'D1 direct DELETE denied: anon, customer, admin, service_role (no privilege)');
select pg_temp.ok(pg_temp.state('xo_old') = 'P0001' and pg_temp.det('xo_old') = 'audit_log_append_only'
                  and pg_temp.state('xo_new') = 'P0001' and pg_temp.det('xo_new') = 'audit_log_append_only',
  'D2 the owner cannot DELETE directly either, even a 3-year-old row (the flag is off)');
select pg_temp.ok(pg_temp.state('u_anon') = '42501' and pg_temp.state('u_cust') = '42501'
                  and pg_temp.state('u_admin') = '42501' and pg_temp.state('u_svc') = '42501',
  'D3 UPDATE denied: anon, customer, admin, service_role');
select pg_temp.ok(pg_temp.state('uo_old') = 'P0001' and pg_temp.det('uo_old') = 'audit_log_append_only'
                  and pg_temp.state('uo_act') = 'P0001' and pg_temp.det('uo_act') = 'audit_log_append_only',
  'D4 owner UPDATE blocked, including a direct (non-nested) actor_id update');
select pg_temp.ok(pg_temp.state('t_anon') = '42501' and pg_temp.state('t_cust') = '42501'
                  and pg_temp.state('t_admin') = '42501' and pg_temp.state('t_svc') = '42501'
                  and pg_temp.state('t_own') = 'P0001' and pg_temp.det('t_own') = 'audit_log_append_only',
  'D5 TRUNCATE denied to API roles; the owner is stopped by the trigger');

-- Even with the flag forged on, the trigger refuses young rows and any UPDATE.
select set_config('app.audit_log_prune_active', 'on', true);
select pg_temp.run('f_young', 'postgres', null, format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(102)));
select pg_temp.run('f_edge',  'postgres', null, format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(103)));
select pg_temp.run('f_exact', 'postgres', null, format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(105)));
select pg_temp.run('f_upd',   'postgres', null, format($q$with r as (update public.admin_audit_log set reason = 'x' where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(101)));
select pg_temp.run('f_trunc', 'postgres', null, $q$truncate public.admin_audit_log$q$);
select set_config('app.audit_log_prune_active', 'off', true);
select pg_temp.ok(pg_temp.state('f_young') = 'P0001' and pg_temp.state('f_edge') = 'P0001' and pg_temp.state('f_exact') = 'P0001',
  'D6 with the flag forced on, rows of 1 year, 2 years - 1 day and exactly 2 years are still refused (age rule)');
select pg_temp.ok(pg_temp.state('f_upd') = 'P0001' and pg_temp.state('f_trunc') = 'P0001',
  'D7 with the flag forced on, UPDATE and TRUNCATE are still refused');
select pg_temp.ok((select count(*) from public.admin_audit_log where action like 't6i3\_%') = 7
                  and (select reason from public.admin_audit_log where id = pg_temp.u(101)) = 'r101',
  'D8 no fixture row was changed or removed by any refused statement (7 present, r101 intact)');

-- ---------------------------------------------------------------- the actor_id SET NULL exception still works
delete from auth.users where id = pg_temp.u(5);
select pg_temp.ok((select actor_id is null and action = 't6i3_gone_old' and reason = 'r106' and target_id = pg_temp.u(202)
                          and created_at = now() - interval '3 years'
                   from public.admin_audit_log where id = pg_temp.u(106))
                  and (select actor_id is null and action = 't6i3_gone_new' and reason = 'r107' and target_id = pg_temp.u(202)
                       from public.admin_audit_log where id = pg_temp.u(107)),
  'E1 deleting an auth user still nulls actor_id only (old and new row); every other column intact');

-- ---------------------------------------------------------------- pruning
-- Empty-run check happens in the batch section too; the first real run is below.
select pg_temp.run('r1', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.state('r1') is null and pg_temp.res('r1') = '3', 'R1 service_role can call prune; it deleted exactly 3 rows (101, 104, 106)');
select pg_temp.ok(not pg_temp.fx(101) and not pg_temp.fx(104) and not pg_temp.fx(106),
  'R2 the 3-year-old rows and the 2 years + 1 day row are pruned (also the one whose actor was set to NULL)');
select pg_temp.ok(pg_temp.fx(102) and pg_temp.fx(103) and pg_temp.fx(105) and pg_temp.fx(107),
  'R3 the 1-year-old row, the 2 years - 1 day row, the exactly-2-years row and the 1-day row are NOT pruned');
select pg_temp.ok(pg_temp.summaries() = (select summaries from t_base) + 1, 'R4 exactly one summary row was written for the run');
select pg_temp.ok((select count(*) = 1 and bool_and(actor_id is null and target_id is null and created_at = now()
                          and reason = format('deleted_rows=3; cutoff=%s', to_char((now() - interval '2 years') at time zone 'UTC', 'YYYY-MM-DD'))
                          and reason ~ '^deleted_rows=[0-9]+; cutoff=[0-9]{4}-[0-9]{2}-[0-9]{2}$')
                   from public.admin_audit_log
                   where action = 'audit_log_pruned' and created_at = now() and reason like 'deleted_rows=3;%'),
  'R5 the summary row has a null actor, no target, and a reason with only the row count and the cutoff date');
select pg_temp.ok(coalesce(current_setting('app.audit_log_prune_active', true), '') <> 'on',
  'R6 the delete window is closed again when the function ends');
select pg_temp.ok(not exists (select 1 from public.admin_audit_log where created_at < now() - interval '2 years'),
  'R7 nothing older than 2 years is left after the run');
select pg_temp.run('r1_direct', 'postgres', null, format($q$with r as (delete from public.admin_audit_log where id = %L returning 1) select count(*)::text from r$q$, pg_temp.u(102)));
select pg_temp.ok(pg_temp.state('r1_direct') = 'P0001' and pg_temp.det('r1_direct') = 'audit_log_append_only',
  'R8 after the run a direct DELETE is blocked again for the owner');

-- Empty run: nothing expired -> returns 0 and writes no row.
select pg_temp.run('r_empty', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.state('r_empty') is null and pg_temp.res('r_empty') = '0'
                  and pg_temp.summaries() = (select summaries from t_base) + 1
                  and (select count(*) from public.admin_audit_log) = (select total from t_base) + 7 - 3 + 1,
  'R9 an empty run deletes nothing and writes no summary row');

-- The summary row is only prunable after 2 years: young summary rows stay, an old one goes.
select pg_temp.ok((select count(*) from public.admin_audit_log where action = 'audit_log_pruned' and created_at = now() and reason like 'deleted_rows=3;%') = 1,
  'R10 the young summary row survived the empty run');
insert into public.admin_audit_log (id, actor_id, action, target_id, reason, created_at)
values (pg_temp.u(110), null, 'audit_log_pruned', null, 'deleted_rows=1; cutoff=2000-01-01', now() - interval '2 years' - interval '1 day');
select pg_temp.run('r_sum', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.res('r_sum') = '1' and not pg_temp.fx(110)
                  and pg_temp.summaries() = (select summaries from t_base) + 2
                  and exists (select 1 from public.admin_audit_log where action = 'audit_log_pruned' and created_at = now() and reason like 'deleted_rows=3;%'),
  'R11 an audit_log_pruned row older than 2 years is itself pruned (and logged); younger summary rows stay');

-- ---------------------------------------------------------------- batch limit (5000 per run)
insert into public.admin_audit_log (actor_id, action, reason, created_at)
select null, 't6i3_bulk', 'bulk ' || g, timestamptz '2000-01-01 00:00+00' + (g || ' seconds')::interval
from generate_series(1, 5100) g;
select pg_temp.run('b1', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.res('b1') = '5000'
                  and (select count(*) from public.admin_audit_log where action = 't6i3_bulk') = 100
                  and (select min(created_at) from public.admin_audit_log where action = 't6i3_bulk') = timestamptz '2000-01-01 00:00+00' + interval '5001 seconds',
  'B1 5100 expired rows: one run deletes exactly 5000 (the oldest), 100 remain');
select pg_temp.ok(pg_temp.summaries() = (select summaries from t_base) + 3
                  and exists (select 1 from public.admin_audit_log where action = 'audit_log_pruned' and created_at = now() and reason like 'deleted_rows=5000; cutoff=%'),
  'B2 that run wrote one summary row with deleted_rows=5000');
select pg_temp.run('b2', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.res('b2') = '100'
                  and not exists (select 1 from public.admin_audit_log where action = 't6i3_bulk')
                  and pg_temp.summaries() = (select summaries from t_base) + 4
                  and exists (select 1 from public.admin_audit_log where action = 'audit_log_pruned' and created_at = now() and reason like 'deleted_rows=100; cutoff=%'),
  'B3 the next run deletes the remaining 100 and writes a summary row with deleted_rows=100');
select pg_temp.run('b3', 'service_role', null, $q$select public.prune_admin_audit_log()::text$q$);
select pg_temp.ok(pg_temp.res('b3') = '0' and pg_temp.summaries() = (select summaries from t_base) + 4,
  'B4 a further run is empty: returns 0 and writes no row');

-- ---------------------------------------------------------------- reader still works and shows the summary row
select pg_temp.run('l_admin', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 'audit_log_pruned')::text$q$);
select pg_temp.ok(pg_temp.state('l_admin') is null
                  and (pg_temp.res('l_admin')::jsonb ->> 'total_count')::bigint = pg_temp.summaries()
                  and exists (select 1 from jsonb_array_elements(pg_temp.res('l_admin')::jsonb -> 'entries') e
                              where e ->> 'actor_id' is null and e ->> 'reason' like 'deleted_rows=5000; cutoff=%'),
  'L1 admin_list_audit_log still works and lists the summary rows with a null actor');

-- ---------------------------------------------------------------- scheduling (only meaningful when pg_cron is installed)
do $cron$
declare v_jobs bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute format('select count(*) from cron.job where jobname = %L and command like %L',
                   'prune-admin-audit-log', '%prune_admin_audit_log()%') into v_jobs;
    if v_jobs <> 1 then
      raise exception 'FAIL: C1 pg_cron is installed but the prune job is not scheduled exactly once (found %)', v_jobs;
    end if;
    raise notice 'PASS: C1 pg_cron job prune-admin-audit-log is scheduled exactly once';
  else
    raise notice 'SKIP: C1 pg_cron is not installed; no job expected (function installed, not scheduled)';
  end if;
end
$cron$;

rollback;
