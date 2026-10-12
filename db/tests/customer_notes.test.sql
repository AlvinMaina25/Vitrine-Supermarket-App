-- Phase 6E.1B-2 test: admin_update_customer_notes() + customer_notes. NOT RUN.
-- Needs migrations up to 20261004150000 applied, plus 20261004170000 (6E.3: staff can no longer read customer_notes).
-- Run as postgres/owner. Rolled back at the end.
-- Fixtures carry the marker 'T6H'.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);
create temp table t_snap (k text primary key, notes text);

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

-- k, role, caller, target, notes (SQL literal or null)
create or replace function pg_temp.cn(k text, r text, uid uuid, target uuid, notes text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid,
    format('select public.admin_update_customer_notes(%L::uuid, %s)::text', target,
           coalesce(quote_literal(notes), 'null')));
end $$;

-- store the notes as the owner sees them right now
create or replace function pg_temp.snap(k text, target uuid) returns void language plpgsql as $$
begin
  insert into t_snap select k, (select n.notes from public.customer_notes n where n.customer_id = target);
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f30000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Fixtures: 1 Alice, 2 Bob, 6 Carol (customers), 3 staff, 4 admin, 5 second admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6h-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6H Alice"}'),
  (pg_temp.u(2), 't6h-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6H Bob"}'),
  (pg_temp.u(3), 't6h-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6H Staff"}'),
  (pg_temp.u(4), 't6h-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6H Admin"}'),
  (pg_temp.u(5), 't6h-admin2@example.test','authenticated', 'authenticated', '{"full_name":"T6H Admin2"}'),
  (pg_temp.u(6), 't6h-carol@example.test', 'authenticated', 'authenticated', '{"full_name":"T6H Carol"}');
insert into public.user_roles (user_id, role) values
  (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin'), (pg_temp.u(5), 'admin');

-- Access denied (no notes written by these)
select pg_temp.cn('cust',  'authenticated', pg_temp.u(1), pg_temp.u(2), 'x');
select pg_temp.cn('anon',  'anon',          null,         pg_temp.u(2), 'x');
select pg_temp.cn('staff', 'authenticated', pg_temp.u(3), pg_temp.u(2), 'x');

-- Rejections
select pg_temp.cn('null',    'authenticated', pg_temp.u(4), pg_temp.u(2), null);
select pg_temp.cn('long',    'authenticated', pg_temp.u(4), pg_temp.u(1), repeat('x', 2001));
select pg_temp.cn('tostaff', 'authenticated', pg_temp.u(4), pg_temp.u(3), 'x');
select pg_temp.cn('toadmin', 'authenticated', pg_temp.u(4), pg_temp.u(5), 'x');
select pg_temp.cn('toself',  'authenticated', pg_temp.u(4), pg_temp.u(4), 'x');
select pg_temp.cn('unk',     'authenticated', pg_temp.u(4), '00000000-0000-4000-8000-6f3999999999', 'x');

-- Alice: save, then replace (trimmed). The note text carries a marker for the audit check.
select pg_temp.cn('a1', 'authenticated', pg_temp.u(4), pg_temp.u(1), 'first SECRET-T6H-NOTE');
select pg_temp.snap('a1', pg_temp.u(1));
select pg_temp.cn('a2', 'authenticated', pg_temp.u(4), pg_temp.u(1), '  second SECRET-T6H-NOTE  ');
select pg_temp.snap('a2', pg_temp.u(1));
-- Bob: save, then clear with whitespace-only text
select pg_temp.cn('b1', 'authenticated', pg_temp.u(4), pg_temp.u(2), 'bob SECRET-T6H-NOTE');
select pg_temp.snap('b1', pg_temp.u(2));
select pg_temp.cn('b2', 'authenticated', pg_temp.u(4), pg_temp.u(2), '   ');
select pg_temp.snap('b2', pg_temp.u(2));
-- Carol: exactly 2000 characters is accepted
select pg_temp.cn('c1', 'authenticated', pg_temp.u(4), pg_temp.u(6), repeat('c', 2000));

-- Direct reads/writes by browser roles
select pg_temp.run('r_cust_all',   'authenticated', pg_temp.u(1), 'select count(*)::text from public.customer_notes');
select pg_temp.run('r_cust_own',   'authenticated', pg_temp.u(1),
  format('select count(*)::text from public.customer_notes where customer_id = %L', pg_temp.u(1)));
select pg_temp.run('r_cust_other', 'authenticated', pg_temp.u(6),
  format('select count(*)::text from public.customer_notes where customer_id = %L', pg_temp.u(1)));
select pg_temp.run('r_anon',  'anon',          null,         'select count(*)::text from public.customer_notes');
select pg_temp.run('r_staff', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.customer_notes');
select pg_temp.run('w_ins', 'authenticated', pg_temp.u(4),
  format('insert into public.customer_notes (customer_id, notes) values (%L, ''x'')', pg_temp.u(3)));
select pg_temp.run('w_upd', 'authenticated', pg_temp.u(4), $$update public.customer_notes set notes = 'x'$$);
select pg_temp.run('w_del', 'authenticated', pg_temp.u(4), $$delete from public.customer_notes$$);
select pg_temp.run('w_cust_ins', 'authenticated', pg_temp.u(1),
  format('insert into public.customer_notes (customer_id, notes) values (%L, ''x'')', pg_temp.u(1)));

do $t$
begin
  -- access
  perform pg_temp.ok(pg_temp.err('cust') = '42501/not_authorised', 'customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('anon') like '42501/%', 'anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('staff') = '42501/not_authorised', 'staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok((pg_temp.j('a1') ->> 'length')::int = length('first SECRET-T6H-NOTE'), 'admin is allowed');

  -- save / replace / clear
  perform pg_temp.ok((select notes from t_snap where k = 'a1') = 'first SECRET-T6H-NOTE', 'notes saved');
  perform pg_temp.ok((select notes from t_snap where k = 'a2') = 'second SECRET-T6H-NOTE', 'notes replaced and trimmed');
  perform pg_temp.ok((select notes from t_snap where k = 'b1') = 'bob SECRET-T6H-NOTE', 'second customer''s notes saved');
  perform pg_temp.ok((select notes from t_snap where k = 'b2') = '' and (pg_temp.j('b2') ->> 'length')::int = 0,
                     'whitespace-only text clears the notes');
  perform pg_temp.ok((select updated_by from public.customer_notes where customer_id = pg_temp.u(2)) = pg_temp.u(4),
                     'updated_by is the admin');
  perform pg_temp.ok((select count(*) from public.customer_notes) = 3, 'exactly 3 notes rows (Alice, Bob, Carol); failed calls wrote none');
  perform pg_temp.ok((select char_length(notes) from public.customer_notes where customer_id = pg_temp.u(6)) = 2000,
                     'exactly 2000 characters accepted');

  -- rejections
  perform pg_temp.ok(pg_temp.err('null') = 'P0001/invalid_arguments', 'null notes rejected');
  perform pg_temp.ok(pg_temp.err('long') = 'P0001/notes_too_long', 'notes over 2000 chars rejected');
  perform pg_temp.ok(pg_temp.err('tostaff') = 'P0001/cannot_target_staff', 'cannot target a staff account');
  perform pg_temp.ok(pg_temp.err('toadmin') = 'P0001/cannot_target_staff', 'cannot target another admin account');
  perform pg_temp.ok(pg_temp.err('toself') = 'P0001/cannot_target_staff', 'cannot target self (admin account)');
  perform pg_temp.ok(pg_temp.err('unk') = 'P0001/customer_not_found', 'unknown customer rejected');
  perform pg_temp.ok((select count(*) from public.customer_notes
                      where customer_id in (pg_temp.u(3), pg_temp.u(4), pg_temp.u(5))) = 0,
                     'no notes rows for staff/admin');

  -- audit
  perform pg_temp.ok((select count(*) from public.admin_audit_log
                      where action = 'customer_notes_updated' and target_id in (pg_temp.u(1), pg_temp.u(2), pg_temp.u(6))) = 5
                 and (select count(*) from public.admin_audit_log
                      where action = 'customer_notes_updated'
                        and target_id in (pg_temp.u(3), pg_temp.u(4), pg_temp.u(5))) = 0,
                     '5 audit rows for the 5 successful calls, none for failed ones');
  -- rows written in one transaction share created_at, so match by exact content, not "latest"
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where action = 'customer_notes_updated' and target_id = pg_temp.u(1)
                               and actor_id = pg_temp.u(4)
                               and reason = 'length=' || length('first SECRET-T6H-NOTE'))
                 and exists (select 1 from public.admin_audit_log
                             where action = 'customer_notes_updated' and target_id = pg_temp.u(1)
                               and actor_id = pg_temp.u(4)
                               and reason = 'length=' || length('second SECRET-T6H-NOTE')),
                     'audit rows have actor and length only (one per save)');
  perform pg_temp.ok(not exists (select 1 from public.admin_audit_log a where a::text like '%SECRET-T6H%'),
                     'no audit row contains the note text');
  perform pg_temp.ok(exists (select 1 from public.admin_audit_log
                             where target_id = pg_temp.u(2) and reason = 'length=0'), 'clearing is audited as length=0');

  -- direct access
  perform pg_temp.ok((select res from t_res where k = 'r_cust_all') = '0', 'customer sees 0 rows in customer_notes');
  perform pg_temp.ok((select res from t_res where k = 'r_cust_own') = '0', 'customer cannot read their own notes row');
  perform pg_temp.ok((select res from t_res where k = 'r_cust_other') = '0', 'customer cannot read another customer''s notes');
  perform pg_temp.ok(pg_temp.err('r_anon') like '42501/%', 'anon cannot SELECT customer_notes');
  perform pg_temp.ok((select res from t_res where k = 'r_staff') = '0', 'staff (non-admin) sees 0 notes rows (admin-only SELECT since 6E.3)');
  perform pg_temp.ok(pg_temp.err('w_ins') like '42501/%' and pg_temp.err('w_upd') like '42501/%'
                 and pg_temp.err('w_del') like '42501/%' and pg_temp.err('w_cust_ins') like '42501/%',
                 'no direct INSERT/UPDATE/DELETE for browser roles (even admin)');
end
$t$;

rollback;
