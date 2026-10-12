-- Phase 6I.1 test: admin_audit_log append-only + admin_list_audit_log. NOT RUN unless the report says so.
-- Needs migrations up to 20261005090000 applied (Supabase-style auth schema: auth.users, auth.uid(),
-- roles anon/authenticated/service_role).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixture rows use action prefix 't6i1_' and 2020/2021 dates; every list query filters on the fixture
-- actor or action, so existing audit rows are ignored.
begin;

create temp table t_res (k text primary key, res text, err text, state text, det text);

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
  select ('00000000-0000-4000-8000-6a090000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$ select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;
create or replace function pg_temp.det(k text) returns text language sql as $$ select det from t_res where t_res.k = det.k $$;
create or replace function pg_temp.keys(v jsonb) returns text[] language sql as $$
  select array_agg(key order by key) from jsonb_object_keys(v) as key $$;
create or replace function pg_temp.ids(k text) returns text[] language sql as $$
  select coalesce(array_agg(e->>'id' order by o), '{}') from t_res, jsonb_array_elements(t_res.res::jsonb->'entries') with ordinality as x(e, o)
  where t_res.k = ids.k $$;

-- Fixtures: 1 customer, 2 staff, 3 admin, 4 second actor, 5 actor that is deleted later
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6i1-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6I1 Cust"}'),
  (pg_temp.u(2), 't6i1-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I1 Staff"}'),
  (pg_temp.u(3), 't6i1-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I1 Admin"}'),
  (pg_temp.u(4), 't6i1-act2@example.test',  'authenticated', 'authenticated', '{"full_name":"T6I1 Act2"}'),
  (pg_temp.u(5), 't6i1-gone@example.test',  'authenticated', 'authenticated', '{"full_name":"T6I1 Gone"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

-- Audit fixtures (inserted by the owner, as the SECURITY DEFINER writers do).
-- 101..103 actor 4 'x' target 201 on days 1,2,3 ; 104 actor 4 'y' target 202 day 4 ;
-- 105,106 same created_at (id desc tiebreak), actor 3 'x' target 201 ; 107 system row (null actor) ;
-- 108 actor 5 (to be deleted).
insert into public.admin_audit_log (id, actor_id, action, target_id, reason, created_at) values
  (pg_temp.u(101), pg_temp.u(4), 't6i1_x', pg_temp.u(201), 'r1', '2020-01-01 10:00+00'),
  (pg_temp.u(102), pg_temp.u(4), 't6i1_x', pg_temp.u(201), 'r2', '2020-01-02 10:00+00'),
  (pg_temp.u(103), pg_temp.u(4), 't6i1_x', pg_temp.u(201), 'r3', '2020-01-03 10:00+00'),
  (pg_temp.u(104), pg_temp.u(4), 't6i1_y', pg_temp.u(202), 'r4', '2020-01-04 10:00+00'),
  (pg_temp.u(105), pg_temp.u(3), 't6i1_x', pg_temp.u(201), 'r5', '2020-01-05 10:00+00'),
  (pg_temp.u(106), pg_temp.u(3), 't6i1_x', pg_temp.u(201), 'r6', '2020-01-05 10:00+00'),
  (pg_temp.u(107), null,         't6i1_z', null,            null, '2020-01-06 10:00+00'),
  (pg_temp.u(108), pg_temp.u(5), 't6i1_w', pg_temp.u(203), 'r8', '2020-01-07 10:00+00');
-- bulk rows for pagination / cap: 120 rows, action 't6i1_bulk', actor 4
insert into public.admin_audit_log (actor_id, action, reason, created_at)
select pg_temp.u(4), 't6i1_bulk', 'bulk ' || g, timestamptz '2021-01-01 00:00+00' + (g || ' minutes')::interval
from generate_series(1, 120) g;

-- ---------------------------------------------------------------- authorisation (read function)
select pg_temp.run('n_cust',  'authenticated', pg_temp.u(1), $q$select public.admin_list_audit_log()::text$q$);
select pg_temp.run('n_staff', 'authenticated', pg_temp.u(2), $q$select public.admin_list_audit_log()::text$q$);
select pg_temp.run('n_anon',  'anon',          null,         $q$select public.admin_list_audit_log()::text$q$);
select pg_temp.run('n_nouid', 'authenticated', null,         $q$select public.admin_list_audit_log()::text$q$);
select pg_temp.run('a_ok',    'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_x')::text$q$);

select pg_temp.ok(pg_temp.state('n_cust') = '42501' and pg_temp.det('n_cust') = 'not_authorised', 'customer denied');
select pg_temp.ok(pg_temp.state('n_staff') = '42501' and pg_temp.det('n_staff') = 'not_authorised', 'staff (non-admin) denied');
select pg_temp.ok(pg_temp.state('n_anon') = '42501', 'anon denied (no EXECUTE)');
select pg_temp.ok(pg_temp.state('n_nouid') = '42501' and pg_temp.det('n_nouid') = 'not_authorised', 'no auth.uid() denied');
select pg_temp.ok(pg_temp.state('a_ok') is null and (pg_temp.j('a_ok')->>'total_count')::int = 5, 'admin allowed (5 t6i1_x rows)');
select pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
                  and has_function_privilege('authenticated', 'public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)', 'EXECUTE'),
                  'anon has no EXECUTE; authenticated has');

-- ---------------------------------------------------------------- direct reads closed
select pg_temp.run('d_anon',  'anon',          null,         'select count(*)::text from public.admin_audit_log');
select pg_temp.run('d_cust',  'authenticated', pg_temp.u(1), 'select count(*)::text from public.admin_audit_log');
select pg_temp.run('d_staff', 'authenticated', pg_temp.u(2), 'select count(*)::text from public.admin_audit_log');
select pg_temp.run('d_admin', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.admin_audit_log');
select pg_temp.run('d_svc',   'service_role',  null,         'select count(*)::text from public.admin_audit_log');
select pg_temp.ok(pg_temp.state('d_anon') = '42501' and pg_temp.state('d_cust') = '42501'
                  and pg_temp.state('d_staff') = '42501' and pg_temp.state('d_admin') = '42501', 'direct SELECT denied to anon and every authenticated user (incl. admin)');
select pg_temp.ok(pg_temp.state('d_svc') is null, 'service_role can still SELECT');

-- ---------------------------------------------------------------- append-only: per role
-- anon / authenticated / service_role lose the privilege -> 42501 before any trigger.
select pg_temp.run('u_anon',  'anon',          null,         $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_cust',  'authenticated', pg_temp.u(1), $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_admin', 'authenticated', pg_temp.u(3), $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('u_svc',   'service_role',  null,         $q$with r as (update public.admin_audit_log set reason = 'x' returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_anon',  'anon',          null,         $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_cust',  'authenticated', pg_temp.u(1), $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_admin', 'authenticated', pg_temp.u(3), $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('x_svc',   'service_role',  null,         $q$with r as (delete from public.admin_audit_log returning 1) select count(*)::text from r$q$);
select pg_temp.run('t_anon',  'anon',          null,         $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_cust',  'authenticated', pg_temp.u(1), $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_admin', 'authenticated', pg_temp.u(3), $q$truncate public.admin_audit_log$q$);
select pg_temp.run('t_svc',   'service_role',  null,         $q$truncate public.admin_audit_log$q$);

select pg_temp.ok(pg_temp.state('u_anon') = '42501' and pg_temp.state('u_cust') = '42501'
                  and pg_temp.state('u_admin') = '42501' and pg_temp.state('u_svc') = '42501', 'UPDATE denied: anon, customer, admin, service_role');
select pg_temp.ok(pg_temp.state('x_anon') = '42501' and pg_temp.state('x_cust') = '42501'
                  and pg_temp.state('x_admin') = '42501' and pg_temp.state('x_svc') = '42501', 'DELETE denied: anon, customer, admin, service_role');
select pg_temp.ok(pg_temp.state('t_anon') = '42501' and pg_temp.state('t_cust') = '42501'
                  and pg_temp.state('t_admin') = '42501' and pg_temp.state('t_svc') = '42501', 'TRUNCATE denied: anon, customer, admin, service_role');

-- The owner (this session) is stopped by the triggers.
select pg_temp.run('o_upd', 'postgres', null, $q$with r as (update public.admin_audit_log set reason = 'x' where id = '00000000-0000-4000-8000-6a0900000101' returning 1) select count(*)::text from r$q$);
select pg_temp.run('o_del', 'postgres', null, $q$with r as (delete from public.admin_audit_log where id = '00000000-0000-4000-8000-6a0900000101' returning 1) select count(*)::text from r$q$);
select pg_temp.run('o_tru', 'postgres', null, $q$truncate public.admin_audit_log$q$);
select pg_temp.run('o_actor', 'postgres', null, $q$with r as (update public.admin_audit_log set actor_id = null where id = '00000000-0000-4000-8000-6a0900000101' returning 1) select count(*)::text from r$q$);
select pg_temp.ok(pg_temp.state('o_upd') = 'P0001' and pg_temp.det('o_upd') = 'audit_log_append_only', 'owner UPDATE blocked by trigger');
select pg_temp.ok(pg_temp.state('o_del') = 'P0001' and pg_temp.det('o_del') = 'audit_log_append_only', 'owner DELETE blocked by trigger');
select pg_temp.ok(pg_temp.state('o_tru') = 'P0001' and pg_temp.det('o_tru') = 'audit_log_append_only', 'owner TRUNCATE blocked by trigger');
select pg_temp.ok(pg_temp.state('o_actor') = 'P0001' and pg_temp.det('o_actor') = 'audit_log_append_only', 'a direct (non-nested) actor_id update is blocked too');
select pg_temp.ok(has_table_privilege('service_role', 'public.admin_audit_log', 'INSERT')
                  and not has_table_privilege('authenticated', 'public.admin_audit_log', 'INSERT')
                  and not has_table_privilege('anon', 'public.admin_audit_log', 'INSERT'), 'INSERT: service_role yes; anon/authenticated no');
select pg_temp.ok((select count(*) from public.admin_audit_log where action like 't6i1\_%') = 128 and
                  (select reason from public.admin_audit_log where id = pg_temp.u(101)) = 'r1', 'no fixture row changed or removed (128 present, r1 intact)');

-- Deleting an auth user still works: the FK ON DELETE SET NULL is the one allowed change.
delete from auth.users where id = pg_temp.u(5);
select pg_temp.ok((select actor_id is null and action = 't6i1_w' and reason = 'r8' and target_id = pg_temp.u(203) and created_at = '2020-01-07 10:00+00'
                   from public.admin_audit_log where id = pg_temp.u(108)), 'deleting an auth user nulls actor_id only; row otherwise intact');

-- ---------------------------------------------------------------- filters
select pg_temp.run('f_actor',  'authenticated', pg_temp.u(3), format($q$select public.admin_list_audit_log(p_actor => %L, p_action => 't6i1_x')::text$q$, pg_temp.u(4)));
select pg_temp.run('f_action', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_y')::text$q$);
select pg_temp.run('f_target', 'authenticated', pg_temp.u(3), format($q$select public.admin_list_audit_log(p_target_id => %L)::text$q$, pg_temp.u(201)));
select pg_temp.run('f_range',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_x', p_from => '2020-01-02+00', p_to => '2020-01-05+00')::text$q$);
select pg_temp.run('f_edge',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_x', p_from => '2020-01-01 10:00+00', p_to => '2020-01-03 10:00+00')::text$q$);
select pg_temp.run('f_none',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_nope')::text$q$);
select pg_temp.run('f_all',    'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_x')::text$q$);
select pg_temp.run('f_sys',    'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_z')::text$q$);

select pg_temp.ok((pg_temp.j('f_actor')->>'total_count')::int = 3, 'filter by actor (+action): 3');
select pg_temp.ok((pg_temp.j('f_action')->>'total_count')::int = 1 and pg_temp.ids('f_action') = array[pg_temp.u(104)]::text[], 'filter by action: only 104');
select pg_temp.ok((pg_temp.j('f_target')->>'total_count')::int = 5, 'filter by target: 5 rows on target 201');
select pg_temp.ok(pg_temp.ids('f_range') = array[pg_temp.u(102), pg_temp.u(103)]::text[] or pg_temp.ids('f_range') = array[pg_temp.u(103), pg_temp.u(102)]::text[], 'range [Jan 2, Jan 5): rows 102 and 103');
select pg_temp.ok((pg_temp.j('f_edge')->>'total_count')::int = 2 and pg_temp.ids('f_edge') = array[pg_temp.u(102), pg_temp.u(101)]::text[], 'from inclusive, to exclusive');
select pg_temp.ok((pg_temp.j('f_none')->>'total_count')::int = 0 and jsonb_array_length(pg_temp.j('f_none')->'entries') = 0, 'no match: empty page, total 0');
select pg_temp.ok(pg_temp.ids('f_all') = array[pg_temp.u(106), pg_temp.u(105), pg_temp.u(103), pg_temp.u(102), pg_temp.u(101)]::text[], 'newest first; equal created_at ordered by id desc');
select pg_temp.ok((pg_temp.j('f_sys')->>'total_count')::int = 1 and pg_temp.j('f_sys')->'entries'->0->>'actor_id' is null, 'system row (null actor) is listed');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('f_all')->'entries') e
                              where pg_temp.keys(e) is distinct from array['action','actor_id','created_at','id','reason','target_id']),
                  'entry key set is exactly the six audit columns');
select pg_temp.ok(pg_temp.keys(pg_temp.j('f_all')) = array['entries','limit','offset','total_count'], 'top-level keys');

-- ---------------------------------------------------------------- pagination and cap
select pg_temp.run('p_def',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk')::text$q$);
select pg_temp.run('p_p1',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk', p_limit => 50, p_offset => 0)::text$q$);
select pg_temp.run('p_p2',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk', p_limit => 50, p_offset => 50)::text$q$);
select pg_temp.run('p_p3',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk', p_limit => 50, p_offset => 100)::text$q$);
select pg_temp.run('p_cap',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk', p_limit => 1000)::text$q$);
select pg_temp.run('p_past', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => 't6i1_bulk', p_offset => 500)::text$q$);

select pg_temp.ok((pg_temp.j('p_def')->>'limit')::int = 25 and (pg_temp.j('p_def')->>'offset')::int = 0
                  and jsonb_array_length(pg_temp.j('p_def')->'entries') = 25 and (pg_temp.j('p_def')->>'total_count')::int = 120, 'defaults: limit 25, offset 0, total 120');
select pg_temp.ok(jsonb_array_length(pg_temp.j('p_p1')->'entries') = 50 and jsonb_array_length(pg_temp.j('p_p2')->'entries') = 50
                  and jsonb_array_length(pg_temp.j('p_p3')->'entries') = 20, 'pages of 50/50/20');
select pg_temp.ok(pg_temp.j('p_p1')->'entries'->0->>'reason' = 'bulk 120' and pg_temp.j('p_p3')->'entries'->19->>'reason' = 'bulk 1', 'newest first across pages');
select pg_temp.ok((select count(distinct id) from (
                     select e->>'id' as id from jsonb_array_elements(pg_temp.j('p_p1')->'entries') e
                     union all select e->>'id' from jsonb_array_elements(pg_temp.j('p_p2')->'entries') e
                     union all select e->>'id' from jsonb_array_elements(pg_temp.j('p_p3')->'entries') e) s) = 120, 'pages do not overlap and cover all 120');
select pg_temp.ok((pg_temp.j('p_cap')->>'limit')::int = 100 and jsonb_array_length(pg_temp.j('p_cap')->'entries') = 100
                  and (pg_temp.j('p_cap')->>'total_count')::int = 120, 'limit capped at 100, total still 120');
select pg_temp.ok(jsonb_array_length(pg_temp.j('p_past')->'entries') = 0 and (pg_temp.j('p_past')->>'total_count')::int = 120, 'offset past end: empty page, total still 120');

-- ---------------------------------------------------------------- invalid arguments
select pg_temp.run('i_lim0',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_limit => 0)::text$q$);
select pg_temp.run('i_limn',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_limit => null)::text$q$);
select pg_temp.run('i_off',   'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_offset => -1)::text$q$);
select pg_temp.run('i_offn',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_offset => null)::text$q$);
select pg_temp.run('i_range', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_from => '2020-01-02+00', p_to => '2020-01-01+00')::text$q$);
select pg_temp.run('i_equal', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_from => '2020-01-02+00', p_to => '2020-01-02+00')::text$q$);
select pg_temp.run('i_act81', 'authenticated', pg_temp.u(3), format($q$select public.admin_list_audit_log(p_action => %L)::text$q$, repeat('a', 81)));
select pg_temp.run('i_act0',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(p_action => '')::text$q$);
select pg_temp.run('i_act80', 'authenticated', pg_temp.u(3), format($q$select public.admin_list_audit_log(p_action => %L)::text$q$, repeat('a', 80)));

select pg_temp.ok(pg_temp.state('i_lim0') = 'P0001' and pg_temp.det('i_lim0') = 'invalid_arguments', 'invalid: limit 0');
select pg_temp.ok(pg_temp.state('i_limn') = 'P0001' and pg_temp.det('i_limn') = 'invalid_arguments', 'invalid: limit null');
select pg_temp.ok(pg_temp.state('i_off') = 'P0001' and pg_temp.det('i_off') = 'invalid_arguments', 'invalid: offset -1');
select pg_temp.ok(pg_temp.state('i_offn') = 'P0001' and pg_temp.det('i_offn') = 'invalid_arguments', 'invalid: offset null');
select pg_temp.ok(pg_temp.state('i_range') = 'P0001' and pg_temp.det('i_range') = 'invalid_arguments', 'invalid: from > to');
select pg_temp.ok(pg_temp.state('i_equal') = 'P0001' and pg_temp.det('i_equal') = 'invalid_arguments', 'invalid: from = to');
select pg_temp.ok(pg_temp.state('i_act81') = 'P0001' and pg_temp.det('i_act81') = 'invalid_arguments', 'invalid: action 81 chars');
select pg_temp.ok(pg_temp.state('i_act0') = 'P0001' and pg_temp.det('i_act0') = 'invalid_arguments', 'invalid: empty action');
select pg_temp.ok(pg_temp.state('i_act80') is null and (pg_temp.j('i_act80')->>'total_count')::int = 0, 'action of exactly 80 chars is accepted');

-- ---------------------------------------------------------------- the read function wrote nothing
select pg_temp.ok((select count(*) from public.admin_audit_log where action like 't6i1\_%') = 128, 'read function wrote nothing (128 fixture rows)');

rollback;
