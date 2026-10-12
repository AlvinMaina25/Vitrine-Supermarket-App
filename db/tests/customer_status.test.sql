-- Phase 6E.1B-1 test: admin_set_customer_status() + admin_audit_log. NOT RUN.
-- Needs migrations up to 20261004140000 applied, plus 20261004170000 (6E.3: staff can no longer read the audit table).
-- Run as postgres/owner. Rolled back at the end.
-- Fixtures carry the marker 'T6G'.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

create or replace function pg_temp.run(k text, r text, uid uuid, q text) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_detail text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then '' else json_build_object('sub', uid, 'role', r)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  perform set_config('request.jwt.claim.role', r, true);
  begin
    execute format('set local role %I', r);
    execute q into v_res;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_res values (k, v_res, v_err, v_state, v_detail);
end $$;

-- k, role, caller, target user number, status, reason (reason passed as a SQL literal)
create or replace function pg_temp.cs(k text, r text, uid uuid, target uuid, st text, reason text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid,
    format('select public.admin_set_customer_status(%L::uuid, %L, %s)::text', target, st,
           coalesce(quote_literal(reason), 'null')));
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f20000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Fixtures: 1 Alice, 2 Bob (customers), 3 staff, 4 admin, 5 second admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Alice"}'),
  (pg_temp.u(2), 't6g-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6G Bob"}'),
  (pg_temp.u(3), 't6g-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Staff"}'),
  (pg_temp.u(4), 't6g-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Admin"}'),
  (pg_temp.u(5), 't6g-admin2@example.test','authenticated', 'authenticated', '{"full_name":"T6G Admin2"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin'), (pg_temp.u(5), 'admin');

-- Defaults: new profiles (created by the signup trigger) are active. Existing rows are
-- covered by the NOT NULL DEFAULT in the migration (checked below via the column default).
create temp table t_pre as
  select (select count(*) from public.profiles where status <> 'active') as non_active,
         (select count(*) from public.profiles) as total;

-- Calls
select pg_temp.cs('cust',   'authenticated', pg_temp.u(1), pg_temp.u(2), 'suspended', 'abuse');
select pg_temp.cs('anon',   'anon',          null,         pg_temp.u(2), 'suspended', 'abuse');
select pg_temp.cs('staff',  'authenticated', pg_temp.u(3), pg_temp.u(2), 'suspended', 'abuse');
select pg_temp.cs('noreas', 'authenticated', pg_temp.u(4), pg_temp.u(2), 'suspended', null);
select pg_temp.cs('blank',  'authenticated', pg_temp.u(4), pg_temp.u(2), 'suspended', '   ');
select pg_temp.cs('long',   'authenticated', pg_temp.u(4), pg_temp.u(2), 'suspended', repeat('x', 501));
select pg_temp.cs('badst',  'authenticated', pg_temp.u(4), pg_temp.u(2), 'banned', 'abuse');
select pg_temp.cs('tostaff','authenticated', pg_temp.u(4), pg_temp.u(3), 'suspended', 'abuse');
select pg_temp.cs('toadmin','authenticated', pg_temp.u(4), pg_temp.u(5), 'suspended', 'abuse');
select pg_temp.cs('toself', 'authenticated', pg_temp.u(4), pg_temp.u(4), 'suspended', 'abuse');
select pg_temp.cs('unk',    'authenticated', pg_temp.u(4), '00000000-0000-4000-8000-6f2999999999', 'suspended', 'abuse');
select pg_temp.cs('same',   'authenticated', pg_temp.u(4), pg_temp.u(2), 'active', 'no change');
select pg_temp.cs('ok',     'authenticated', pg_temp.u(4), pg_temp.u(2), 'suspended', '  Repeated chargebacks  ');
select pg_temp.cs('again',  'authenticated', pg_temp.u(4), pg_temp.u(2), 'suspended', 'twice');
select pg_temp.cs('back',   'authenticated', pg_temp.u(4), pg_temp.u(2), 'active', 'Resolved');

-- Audit visibility (reads as each role)
-- Since 6I.1 the table is unreadable to browser roles; the only browser read path is admin_list_audit_log().
select pg_temp.run('aud_cust',  'authenticated', pg_temp.u(1), $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
select pg_temp.run('aud_anon',  'anon',          null,         $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
select pg_temp.run('aud_staff', 'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
-- Direct write attempts
select pg_temp.run('w_ins', 'authenticated', pg_temp.u(4),
  format('insert into public.admin_audit_log (actor_id, action) values (%L, ''x'')', pg_temp.u(4)));
select pg_temp.run('w_upd', 'authenticated', pg_temp.u(4), $$update public.admin_audit_log set reason = 'x'$$);
select pg_temp.run('w_del', 'authenticated', pg_temp.u(4), $$delete from public.admin_audit_log$$);
-- Customer cannot change their own status directly
select pg_temp.run('self_upd', 'authenticated', pg_temp.u(1),
  format('update public.profiles set status = ''suspended'' where id = %L', pg_temp.u(1)));

do $t$
declare
  v_audit public.admin_audit_log%rowtype;
  v_n bigint;
begin
  -- access
  perform pg_temp.ok(pg_temp.err('cust') = '42501/not_authorised', 'customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('anon') like '42501/%', 'anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('staff') = '42501/not_authorised', 'staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.j('ok') ->> 'status' = 'suspended', 'admin is allowed');

  -- reason + status validation
  perform pg_temp.ok(pg_temp.err('noreas') = 'P0001/reason_required', 'null reason rejected');
  perform pg_temp.ok(pg_temp.err('blank') = 'P0001/reason_required', 'blank reason rejected');
  perform pg_temp.ok(pg_temp.err('long') = 'P0001/reason_too_long', 'reason over 500 chars rejected');
  perform pg_temp.ok(pg_temp.err('badst') = 'P0001/invalid_status', 'invalid status rejected');

  -- targets
  perform pg_temp.ok(pg_temp.err('tostaff') = 'P0001/cannot_target_staff', 'cannot change a staff account');
  perform pg_temp.ok(pg_temp.err('toadmin') = 'P0001/cannot_target_staff', 'cannot change another admin account');
  perform pg_temp.ok(pg_temp.err('toself') = 'P0001/cannot_target_self', 'cannot change self');
  perform pg_temp.ok(pg_temp.err('unk') = 'P0001/customer_not_found', 'unknown customer rejected');
  perform pg_temp.ok((select status from public.profiles where id = pg_temp.u(3)) = 'active'
                 and (select status from public.profiles where id = pg_temp.u(4)) = 'active'
                 and (select status from public.profiles where id = pg_temp.u(5)) = 'active',
                 'staff/admin profiles untouched');

  -- unchanged
  perform pg_temp.ok(pg_temp.err('same') = 'P0001/status_unchanged', 'unchanged status rejected (active -> active)');
  perform pg_temp.ok(pg_temp.err('again') = 'P0001/status_unchanged', 'unchanged status rejected (suspended -> suspended)');

  -- audit rows: only the two successful calls ('ok' and 'back'), reason trimmed
  select count(*) into v_n from public.admin_audit_log where target_id = pg_temp.u(2);
  perform pg_temp.ok(v_n = 2, 'exactly 2 audit rows (failed calls wrote none)');
  select * into v_audit from public.admin_audit_log
    where target_id = pg_temp.u(2) and action = 'customer_suspended';
  perform pg_temp.ok(v_audit.actor_id = pg_temp.u(4) and v_audit.reason = 'Repeated chargebacks'
                 and v_audit.created_at is not null, 'suspend audit row: actor, trimmed reason, timestamp');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where target_id = pg_temp.u(2) and action = 'customer_reactivated'
                               and reason = 'Resolved' and actor_id = pg_temp.u(4)),
                     'reactivate audit row written');
  perform pg_temp.ok((select status from public.profiles where id = pg_temp.u(2)) = 'active'
                 and pg_temp.j('back') ->> 'previous_status' = 'suspended', 'final status active, previous_status returned');

  -- audit table access
  perform pg_temp.ok(pg_temp.err('aud_cust') = '42501/not_authorised', 'customer cannot read the audit log (admin_list_audit_log refuses: 42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('aud_anon') like '42501/%', 'anon cannot read the audit log (42501)');
  perform pg_temp.ok(pg_temp.err('aud_staff') = '42501/not_authorised', 'staff (non-admin) cannot read the audit log (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('w_ins') like '42501/%' and pg_temp.err('w_upd') like '42501/%'
                 and pg_temp.err('w_del') like '42501/%', 'no direct INSERT/UPDATE/DELETE on the audit table (even for admin)');
  perform pg_temp.ok(pg_temp.err('self_upd') like '42501/%', 'customer cannot UPDATE profiles.status directly');

  -- defaults
  -- Informational only: a real database may legitimately hold suspended customers. The NOT NULL
  -- DEFAULT 'active' is asserted below; the count of pre-existing non-active profiles is not.
  raise notice 'INFO: % of % pre-existing profiles were not active before this test', (select non_active from t_pre), (select total from t_pre);
  perform pg_temp.ok((select status from public.profiles where id = pg_temp.u(1)) = 'active', 'new customer defaults to active');
  perform pg_temp.ok((select column_default from information_schema.columns
                      where table_schema = 'public' and table_name = 'profiles' and column_name = 'status') like '%active%'
                 and (select is_nullable from information_schema.columns
                      where table_schema = 'public' and table_name = 'profiles' and column_name = 'status') = 'NO',
                 'profiles.status is NOT NULL default active');
end
$t$;

rollback;
