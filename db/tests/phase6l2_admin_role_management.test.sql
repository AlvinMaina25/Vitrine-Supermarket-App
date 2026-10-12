-- Phase 6L.2 test: admin_set_user_role() and admin_list_role_holders().
-- WRITTEN, NOT RUN. Needs migrations up to 20261005150000 applied (Supabase-style auth schema:
-- auth.users, auth.uid(), auth.jwt(), roles anon/authenticated/service_role).
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end, including the flag flip.
-- Fixture users use ids ...6c20....  (1 = admin A, 2 = admin B, 3 = staff, 4 = customer, 5 = target).
-- Counts are relative (the database may already hold real admins), never absolute.
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
  select ('00000000-0000-4000-8000-6c200000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;
create or replace function pg_temp.det(k text) returns text language sql as $$ select det from t_res where t_res.k = det.k $$;
create or replace function pg_temp.allowed(k text) returns boolean language sql as $$
  select state is null from t_res where t_res.k = allowed.k $$;
-- true when the call was refused with P0001 and exactly this DETAIL code
create or replace function pg_temp.refused(k text, code text) returns boolean language sql as $$
  select state = 'P0001' and det = code from t_res where t_res.k = refused.k $$;
-- true when the call was refused as not authorised
create or replace function pg_temp.denied(k text) returns boolean language sql as $$
  select state = '42501' and det = 'not_authorised' from t_res where t_res.k = denied.k $$;

create or replace function pg_temp.setq(p_user uuid, p_role text, p_action text, p_reason text) returns text language sql as $$
  select format('select public.admin_set_user_role(%L::uuid, %L, %L, %L)::text', p_user, p_role, p_action, p_reason) $$;
create or replace function pg_temp.listq() returns text language sql as $$
  select 'select public.admin_list_role_holders()::text' $$;

-- Rows the fixtures wrote to the audit log (all fixtures are actors or targets of fixture calls only).
create or replace function pg_temp.audit_n() returns bigint language sql as $$
  select count(*) from public.admin_audit_log
  where action in ('role_granted', 'role_revoked')
    and (actor_id in (pg_temp.u(1), pg_temp.u(2), pg_temp.u(3), pg_temp.u(4))
         or target_id in (pg_temp.u(1), pg_temp.u(2), pg_temp.u(3), pg_temp.u(4), pg_temp.u(5))) $$;
create or replace function pg_temp.held(p_user uuid, p_role text) returns boolean language sql as $$
  select exists (select 1 from public.user_roles where user_id = p_user and role = p_role::public.app_role) $$;
create or replace function pg_temp.admin_n() returns bigint language sql as $$
  select count(*) from public.user_roles where role = 'admin' $$;

-- ---------------------------------------------------------------- fixtures
update public.admin_security_settings set require_mfa = false;

insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6l2-admin-a@example.test',   'authenticated', 'authenticated', '{"full_name":"T6L2 Admin A"}'),
  (pg_temp.u(2), 't6l2-admin-b@example.test',   'authenticated', 'authenticated', '{"full_name":"T6L2 Admin B"}'),
  (pg_temp.u(3), 't6l2-staff@example.test',     'authenticated', 'authenticated', '{"full_name":"T6L2 Staff"}'),
  (pg_temp.u(4), 't6l2-customer@example.test',  'authenticated', 'authenticated', '{"full_name":"T6L2 Customer"}'),
  (pg_temp.u(5), 't6l2-target@example.test',    'authenticated', 'authenticated', '{"full_name":"T6L2 Target"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(1), 'admin'), (pg_temp.u(2), 'admin'), (pg_temp.u(3), 'staff');
-- A 'customer' row must never show up in the holders list.
insert into public.user_roles (user_id, role) values (pg_temp.u(4), 'customer');

-- ---------------------------------------------------------------- G: grants and shape
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.admin_set_user_role(uuid,text,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.admin_list_role_holders()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_set_user_role(uuid,text,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.admin_list_role_holders()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.admin_set_user_role(uuid,text,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.admin_list_role_holders()', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid in ('public.admin_set_user_role(uuid,text,text,text)'::regprocedure,
                                  'public.admin_list_role_holders()'::regprocedure)
                    and a.privilege_type = 'EXECUTE' and a.grantee = 0),
  'G1 both functions: executable by authenticated only (not PUBLIC, anon or service_role)');
select pg_temp.ok(
  (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                   and p.prosrc like '%public.require_admin()%')
   from pg_proc p where p.oid in ('public.admin_set_user_role(uuid,text,text,text)'::regprocedure,
                                  'public.admin_list_role_holders()'::regprocedure)),
  'G2 both functions: SECURITY DEFINER, search_path = public, pg_temp, gated by require_admin()');

-- ---------------------------------------------------------------- A: non-admin denied
select pg_temp.run('set_cust',  'authenticated', pg_temp.u(4), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'valid reason'));
select pg_temp.run('set_staff', 'authenticated', pg_temp.u(3), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'valid reason'));
select pg_temp.run('set_anon',  'anon', null, null,                     pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'valid reason'));
select pg_temp.run('lst_cust',  'authenticated', pg_temp.u(4), 'aal1', pg_temp.listq());
select pg_temp.run('lst_staff', 'authenticated', pg_temp.u(3), 'aal1', pg_temp.listq());
select pg_temp.run('lst_anon',  'anon', null, null,                     pg_temp.listq());
select pg_temp.ok(pg_temp.denied('set_cust') and pg_temp.denied('set_staff'),
  'A1 admin_set_user_role: customer and staff denied, 42501 / not_authorised');
select pg_temp.ok(pg_temp.state('set_anon') = '42501',
  'A2 admin_set_user_role: anon refused (42501)');
select pg_temp.ok(pg_temp.denied('lst_cust') and pg_temp.denied('lst_staff') and pg_temp.state('lst_anon') = '42501',
  'A3 admin_list_role_holders: customer, staff and anon refused (42501)');
select pg_temp.ok(not pg_temp.held(pg_temp.u(5), 'staff') and pg_temp.audit_n() = 0,
  'A4 denied calls changed nothing and wrote no audit row');

-- ---------------------------------------------------------------- M: MFA applies (require_admin, Phase 6L.1)
update public.admin_security_settings set require_mfa = true;
select pg_temp.run('mfa_set_aal1',  'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'mfa check'));
select pg_temp.run('mfa_list_aal1', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.listq());
select pg_temp.ok(pg_temp.state('mfa_set_aal1') = '42501' and pg_temp.det('mfa_set_aal1') = 'mfa_required'
              and pg_temp.state('mfa_list_aal1') = '42501' and pg_temp.det('mfa_list_aal1') = 'mfa_required',
  'M1 enforcement on: an aal1 admin is refused with mfa_required by both functions');
select pg_temp.ok(not pg_temp.held(pg_temp.u(5), 'staff') and pg_temp.audit_n() = 0,
  'M2 the refused aal1 call changed nothing');
select pg_temp.run('mfa_list_aal2', 'authenticated', pg_temp.u(1), 'aal2', pg_temp.listq());
select pg_temp.ok(pg_temp.allowed('mfa_list_aal2'), 'M3 enforcement on: an aal2 admin may list role holders');
update public.admin_security_settings set require_mfa = false;

-- ---------------------------------------------------------------- V: invalid role, action, arguments and reason
select pg_temp.run('v_action', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'promote', 'valid reason'));
select pg_temp.run('v_role_customer', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'customer', 'grant', 'valid reason'));
select pg_temp.run('v_role_owner', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'owner', 'grant', 'valid reason'));
select pg_temp.run('v_role_case', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'Admin', 'grant', 'valid reason'));
select pg_temp.run('v_null_user', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(null, 'staff', 'grant', 'valid reason'));
select pg_temp.run('v_null_role', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), null, 'grant', 'valid reason'));
select pg_temp.run('v_null_action', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', null, 'valid reason'));
select pg_temp.ok(pg_temp.refused('v_action', 'invalid_action'), 'V1 an unknown action is rejected (invalid_action)');
select pg_temp.ok(pg_temp.refused('v_role_customer', 'invalid_role')
              and pg_temp.refused('v_role_owner', 'invalid_role')
              and pg_temp.refused('v_role_case', 'invalid_role'),
  'V2 roles other than exactly staff / admin are rejected (customer, owner, Admin)');
select pg_temp.ok(pg_temp.refused('v_null_user', 'invalid_arguments')
              and pg_temp.refused('v_null_role', 'invalid_arguments')
              and pg_temp.refused('v_null_action', 'invalid_arguments'),
  'V3 null user / role / action are rejected (invalid_arguments)');

select pg_temp.run('r_null', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', null));
select pg_temp.run('r_spaces', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', '     '));
select pg_temp.run('r_blank', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', E'   \n\t '));
select pg_temp.run('r_short', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', '  ab  '));
select pg_temp.run('r_long', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', repeat('x', 201)));
select pg_temp.ok(pg_temp.refused('r_null', 'reason_required') and pg_temp.refused('r_spaces', 'reason_required'),
  'V4 a null or spaces-only reason is rejected (reason_required)');
-- btrim() only trims spaces, so a tab/newline-only reason is still refused, but as reason_too_short.
select pg_temp.ok((select state = 'P0001' and det in ('reason_required', 'reason_too_short') from t_res where k = 'r_blank'),
  'V4b a tab/newline-only reason is rejected (reason_required or reason_too_short)');
select pg_temp.ok(pg_temp.refused('r_short', 'reason_too_short'), 'V5 a 2-character reason (after trimming) is rejected (reason_too_short)');
select pg_temp.ok(pg_temp.refused('r_long', 'reason_too_long'), 'V6 a 201-character reason is rejected (reason_too_long)');
select pg_temp.ok(not pg_temp.held(pg_temp.u(5), 'staff') and pg_temp.audit_n() = 0,
  'V7 every rejected call changed nothing and wrote no audit row');

-- Unknown user: after the argument checks, before any change.
select pg_temp.run('nf', 'authenticated', pg_temp.u(1), 'aal1',
  pg_temp.setq('00000000-0000-4000-8000-6c20ffffffff'::uuid, 'staff', 'grant', 'valid reason'));
select pg_temp.ok(pg_temp.refused('nf', 'user_not_found') and pg_temp.audit_n() = 0,
  'V8 a user that does not exist is rejected (user_not_found), no audit row');

-- ---------------------------------------------------------------- S: you cannot change your own role
select pg_temp.run('self_grant_staff', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(1), 'staff', 'grant', 'valid reason'));
select pg_temp.run('self_revoke_admin', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(1), 'admin', 'revoke', 'valid reason'));
select pg_temp.run('self_noop_grant', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(1), 'admin', 'grant', 'valid reason'));
select pg_temp.run('self_noop_revoke', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(1), 'staff', 'revoke', 'valid reason'));
select pg_temp.ok(pg_temp.refused('self_grant_staff', 'cannot_change_own_role')
              and pg_temp.refused('self_revoke_admin', 'cannot_change_own_role')
              and pg_temp.refused('self_noop_grant', 'cannot_change_own_role')
              and pg_temp.refused('self_noop_revoke', 'cannot_change_own_role'),
  'S1 an admin cannot grant or revoke their own role, not even as a would-be no-op (cannot_change_own_role)');
select pg_temp.ok(pg_temp.held(pg_temp.u(1), 'admin') and not pg_temp.held(pg_temp.u(1), 'staff') and pg_temp.audit_n() = 0,
  'S2 self-change attempts changed nothing and wrote no audit row');

-- ---------------------------------------------------------------- C: real changes (grant, revoke) and audit rows
select pg_temp.run('g1', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', '  new cashier  '));
select pg_temp.ok(pg_temp.allowed('g1')
              and (pg_temp.res('g1')::jsonb ->> 'changed') = 'true'
              and (pg_temp.res('g1')::jsonb ->> 'user_id') = pg_temp.u(5)::text
              and (pg_temp.res('g1')::jsonb ->> 'role') = 'staff'
              and (pg_temp.res('g1')::jsonb ->> 'action') = 'grant'
              and pg_temp.held(pg_temp.u(5), 'staff'),
  'C1 grant staff: changed = true and the role row exists');
select pg_temp.ok(pg_temp.audit_n() = 1
              and exists (select 1 from public.admin_audit_log
                          where action = 'role_granted' and actor_id = pg_temp.u(1) and target_id = pg_temp.u(5)
                            and reason = 'role staff; new cashier'),
  'C2 exactly one audit row: role_granted, actor = caller, target = the user, reason = role + trimmed reason');

-- Granting a role already held is a no-op.
select pg_temp.run('g2', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'again please'));
select pg_temp.ok(pg_temp.allowed('g2') and (pg_temp.res('g2')::jsonb ->> 'changed') = 'false'
              and pg_temp.audit_n() = 1
              and (select count(*) from public.user_roles where user_id = pg_temp.u(5) and role = 'staff') = 1,
  'N1 granting a role already held: changed = false, no new audit row, no duplicate role row');

-- Revoking a role the user does not hold is a no-op (staff user has no admin role).
select pg_temp.run('rv_notheld', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'admin', 'revoke', 'not held at all'));
select pg_temp.ok(pg_temp.allowed('rv_notheld') and (pg_temp.res('rv_notheld')::jsonb ->> 'changed') = 'false'
              and pg_temp.audit_n() = 1 and pg_temp.held(pg_temp.u(5), 'staff'),
  'N2 revoking a role not held: changed = false, no audit row, nothing else touched');
-- ... including a user with no role rows at all (customer fixture only has a customer row).
select pg_temp.run('rv_norole', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(4), 'staff', 'revoke', 'not held at all'));
select pg_temp.ok(pg_temp.allowed('rv_norole') and (pg_temp.res('rv_norole')::jsonb ->> 'changed') = 'false' and pg_temp.audit_n() = 1,
  'N3 revoking staff from a user who never held it: changed = false, no audit row');

-- Real revoke.
select pg_temp.run('rv1', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'revoke', 'left the company'));
select pg_temp.ok(pg_temp.allowed('rv1') and (pg_temp.res('rv1')::jsonb ->> 'changed') = 'true'
              and not pg_temp.held(pg_temp.u(5), 'staff'),
  'C3 revoke staff: changed = true and the role row is gone');
select pg_temp.ok(pg_temp.audit_n() = 2
              and exists (select 1 from public.admin_audit_log
                          where action = 'role_revoked' and actor_id = pg_temp.u(1) and target_id = pg_temp.u(5)
                            and reason = 'role staff; left the company'),
  'C4 exactly one more audit row: role_revoked with the reason');

-- Revoking again is now a no-op.
select pg_temp.run('rv2', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'revoke', 'already gone'));
select pg_temp.ok(pg_temp.allowed('rv2') and (pg_temp.res('rv2')::jsonb ->> 'changed') = 'false' and pg_temp.audit_n() = 2,
  'N4 revoking a role that was just revoked: changed = false, no new audit row');

-- Reason edges that must be accepted: exactly 3 and exactly 200 characters.
select pg_temp.run('edge3', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'grant', 'abc'));
select pg_temp.run('edge3r', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'staff', 'revoke', repeat('y', 200)));
select pg_temp.ok(pg_temp.allowed('edge3') and pg_temp.allowed('edge3r')
              and (pg_temp.res('edge3')::jsonb ->> 'changed') = 'true' and (pg_temp.res('edge3r')::jsonb ->> 'changed') = 'true'
              and pg_temp.audit_n() = 4,
  'C5 reasons of exactly 3 and exactly 200 characters are accepted and audited');

-- ---------------------------------------------------------------- L: last admin / lockout protection
-- (a) Granting admin works, listing shows it, and the list never contains the customer-role row.
select pg_temp.run('ga', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(5), 'admin', 'grant', 'second pair of hands'));
select pg_temp.ok(pg_temp.allowed('ga') and (pg_temp.res('ga')::jsonb ->> 'changed') = 'true' and pg_temp.held(pg_temp.u(5), 'admin'),
  'L1 grant admin to another user works');

-- (b) The sole-admin case: nobody can revoke their own admin role, so an admin cannot remove themselves.
--     (admin A trying to revoke A was refused in S1; the admin count is unchanged.)
-- (c) Two admins cannot lock each other out: A revokes B, then B (no longer an admin) cannot revoke A.
create temp table t_before as select pg_temp.admin_n() as n;
select pg_temp.run('lk_a_revokes_b', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(2), 'admin', 'revoke', 'rotating admins'));
select pg_temp.ok(pg_temp.allowed('lk_a_revokes_b') and (pg_temp.res('lk_a_revokes_b')::jsonb ->> 'changed') = 'true'
              and not pg_temp.held(pg_temp.u(2), 'admin')
              and pg_temp.admin_n() = (select n from t_before) - 1,
  'L2 one admin revokes another: exactly one admin role is removed');
select pg_temp.run('lk_b_revokes_a', 'authenticated', pg_temp.u(2), 'aal1', pg_temp.setq(pg_temp.u(1), 'admin', 'revoke', 'trying to lock out'));
select pg_temp.ok(pg_temp.denied('lk_b_revokes_a') and pg_temp.held(pg_temp.u(1), 'admin'),
  'L3 the revoked admin can no longer revoke anyone: denied, admin A keeps the role');
select pg_temp.run('lk_a_self', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.setq(pg_temp.u(1), 'admin', 'revoke', 'stepping down'));
select pg_temp.ok(pg_temp.refused('lk_a_self', 'cannot_change_own_role') and pg_temp.admin_n() >= 1,
  'L4 an admin cannot step down alone either; at least one admin remains');
-- NOTE: the database also refuses (DETAIL last_admin) a revoke that would remove the only admin
-- row. That branch is defence in depth: through one sequential call it cannot be reached, because
-- the caller must themselves be an admin other than the target. It guards the concurrent case, where
-- the advisory lock plus the re-check of the caller's admin role decide.
select pg_temp.ok(
  (select p.prosrc like '%last_admin%' and p.prosrc like '%pg_advisory_xact_lock%'
   from pg_proc p where p.oid = 'public.admin_set_user_role(uuid,text,text,text)'::regprocedure),
  'L5 the last_admin rule and the serialising advisory lock are present in the function body');

-- ---------------------------------------------------------------- H: admin_list_role_holders
select pg_temp.run('list', 'authenticated', pg_temp.u(1), 'aal1', pg_temp.listq());
select pg_temp.ok(pg_temp.allowed('list'), 'H1 an admin may list role holders');
select pg_temp.ok(
  (select jsonb_typeof(pg_temp.res('list')::jsonb -> 'holders') = 'array'
          and (select array_agg(k order by k) from jsonb_object_keys(pg_temp.res('list')::jsonb) k) = array['holders']),
  'H2 the result is exactly {"holders": [...]}');
select pg_temp.ok(
  not exists (
    select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
    where (select array_agg(k order by k) from jsonb_object_keys(h) k) is distinct from array['granted_at', 'role', 'user_id']),
  'H3 every holder has exactly user_id, role and granted_at');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
   where h ->> 'role' not in ('staff', 'admin')) = 0
  and not exists (select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
                  where (h ->> 'user_id') = pg_temp.u(4)::text),
  'H4 only staff and admin rows are listed (the customer-role row is not)');
select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
          where (h ->> 'user_id') = pg_temp.u(1)::text and h ->> 'role' = 'admin')
  and exists (select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
              where (h ->> 'user_id') = pg_temp.u(3)::text and h ->> 'role' = 'staff')
  and exists (select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
              where (h ->> 'user_id') = pg_temp.u(5)::text and h ->> 'role' = 'admin')
  and not exists (select 1 from jsonb_array_elements(pg_temp.res('list')::jsonb -> 'holders') h
                  where (h ->> 'user_id') = pg_temp.u(2)::text),
  'H5 the list reflects the current roles (A admin, staff user, target admin; revoked B absent)');
select pg_temp.ok(pg_temp.res('list') !~* '(@|example\.test|t6l2-|full_name)',
  'H6 the list contains no email or name');

-- ---------------------------------------------------------------- D: no sensitive data in results or audit rows
select pg_temp.ok(
  (select count(*) from public.admin_audit_log
   where action in ('role_granted', 'role_revoked')
     and (actor_id in (pg_temp.u(1), pg_temp.u(2)) ) ) >= 1
  and not exists (
    select 1 from public.admin_audit_log a
    where a.action in ('role_granted', 'role_revoked')
      and (a.actor_id in (pg_temp.u(1), pg_temp.u(2), pg_temp.u(3), pg_temp.u(4))
           or a.target_id in (pg_temp.u(1), pg_temp.u(2), pg_temp.u(3), pg_temp.u(4), pg_temp.u(5)))
      and (coalesce(a.reason, '') ~* '(@|example\.test|t6l2-|full_name)'
           or a.reason !~ '^role (staff|admin); ')),
  'D1 role audit rows hold only "role <role>; <reason>": no email, no name');
select pg_temp.ok(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'admin_audit_log'
     and column_name in ('id', 'actor_id', 'action', 'target_id', 'reason', 'created_at')) = 6
  and (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'admin_audit_log') = 6,
  'D2 admin_audit_log still has exactly its six columns (this phase added none)');
select pg_temp.ok(
  pg_temp.res('g1') !~* '(@|example\.test|t6l2-|full_name)'
  and pg_temp.res('rv1') !~* '(@|example\.test|t6l2-|full_name)'
  and (select array_agg(k order by k) from jsonb_object_keys(pg_temp.res('g1')::jsonb) k)
        = array['action', 'changed', 'role', 'user_id'],
  'D3 admin_set_user_role results hold only changed, user_id, role and action');
select pg_temp.ok(
  (select count(*) from public.admin_audit_log
   where action in ('role_granted', 'role_revoked') and target_id = pg_temp.u(5)) = 5,
  'D4 target u5 has one audit row per real change (grant, revoke, grant 3-char, revoke 200-char, grant admin) and none for no-ops');

rollback;
