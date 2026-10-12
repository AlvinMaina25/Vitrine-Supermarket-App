-- Phase 6E.1B-3 test: status + notes in admin_list_customers() / admin_get_customer(). NOT RUN.
-- Needs migrations 20261004120000 .. 20261004160000 applied. Run as postgres/owner (SQL Editor or psql).
-- One transaction, rolled back at the end. Fixtures carry the marker 'T6G'.
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

-- call admin_list_customers(<args>) as a role, record under key k
create or replace function pg_temp.lc(k text, r text, uid uuid, args text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, 'select public.admin_list_customers(' || args || ')::text');
end $$;

-- call admin_get_customer(<target>) as a role, record under key k
create or replace function pg_temp.gc(k text, r text, uid uuid, target text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, 'select public.admin_get_customer(' || target || ')::text');
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

-- status of the listed customer with this email, from list result k
create or replace function pg_temp.st(k text, em text) returns text language sql as $$
  select c ->> 'status' from jsonb_array_elements(pg_temp.j(k) -> 'customers') c where c ->> 'email' = em $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-7010000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Fixtures: 1 Alice (active, notes), 2 Bob (suspended, no notes row), 3 Carol (active, notes cleared),
--           4 staff, 5 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Alice Wanjiru","phone":"+254733000001"}'),
  (pg_temp.u(2), 't6g-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6G Bob Otieno","phone":"+254733000002"}'),
  (pg_temp.u(3), 't6g-carol@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Carol Mutua","phone":"+254733000003"}'),
  (pg_temp.u(4), 't6g-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Staff"}'),
  (pg_temp.u(5), 't6g-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(4), 'staff'), (pg_temp.u(5), 'admin');

update public.profiles set status = 'suspended' where id = pg_temp.u(2);

insert into public.customer_notes (customer_id, notes, updated_by, updated_at) values
  (pg_temp.u(1), 'T6G SECRET-NOTE prefers morning delivery', pg_temp.u(5), '2026-03-01 10:00+03'),
  (pg_temp.u(3), '',                                         pg_temp.u(5), '2026-03-02 10:00+03');

-- list
select pg_temp.lc('l_cust',  'authenticated', pg_temp.u(1), $$p_search => 'T6G'$$);
select pg_temp.lc('l_anon',  'anon',          null,         $$p_search => 'T6G'$$);
select pg_temp.lc('l_staff', 'authenticated', pg_temp.u(4), $$p_search => 'T6G'$$);
select pg_temp.lc('l_admin', 'authenticated', pg_temp.u(5), $$p_search => 'T6G'$$);
select pg_temp.lc('l_pos',   'authenticated', pg_temp.u(5), $$'T6G', 1, 25$$);
select pg_temp.lc('f_susp',  'authenticated', pg_temp.u(5), $$p_search => 'T6G', p_status => 'suspended'$$);
select pg_temp.lc('f_act',   'authenticated', pg_temp.u(5), $$p_search => 'T6G', p_status => 'active'$$);
select pg_temp.lc('f_null',  'authenticated', pg_temp.u(5), $$p_search => 'T6G', p_status => null$$);
select pg_temp.lc('f_page',  'authenticated', pg_temp.u(5), $$p_search => 'T6G', p_status => 'active', p_page_size => 1$$);
select pg_temp.lc('f_bad',   'authenticated', pg_temp.u(5), $$p_status => 'banned'$$);
select pg_temp.lc('f_empty', 'authenticated', pg_temp.u(5), $$p_status => ''$$);
select pg_temp.lc('f_case',  'authenticated', pg_temp.u(5), $$p_status => 'Active'$$);
select pg_temp.lc('f_staff', 'authenticated', pg_temp.u(4), $$p_status => 'active'$$);

-- detail
select pg_temp.gc('d_cust',  'authenticated', pg_temp.u(1), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('d_anon',  'anon',          null,         quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('d_staff', 'authenticated', pg_temp.u(4), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('d_alice', 'authenticated', pg_temp.u(5), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('d_bob',   'authenticated', pg_temp.u(5), quote_literal(pg_temp.u(2)::text) || '::uuid');
select pg_temp.gc('d_carol', 'authenticated', pg_temp.u(5), quote_literal(pg_temp.u(3)::text) || '::uuid');

do $t$
begin
  -- access: list
  perform pg_temp.ok(pg_temp.err('l_cust') = '42501/not_authorised', 'list: customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('l_anon') like '42501/%', 'list: anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('l_staff') = '42501/not_authorised', 'list: staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('f_staff') = '42501/not_authorised', 'list: staff is denied before the status argument is examined');
  perform pg_temp.ok((pg_temp.j('l_admin') ->> 'total')::int = 3, 'list: admin is allowed (3 T6G customers, staff/admin excluded)');
  perform pg_temp.ok((pg_temp.j('l_pos') ->> 'total')::int = 3, 'list: old 3-argument positional call still works');
  perform pg_temp.ok(to_regprocedure('public.admin_list_customers(text,integer,integer)') is null, 'list: old 3-argument overload is gone (no ambiguity)');

  -- access: detail
  perform pg_temp.ok(pg_temp.err('d_cust') = '42501/not_authorised', 'detail: customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('d_anon') like '42501/%', 'detail: anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('d_staff') = '42501/not_authorised', 'detail: staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.j('d_alice') -> 'profile' ->> 'id' = pg_temp.u(1)::text, 'detail: admin is allowed');

  -- list returns status; existing fields still present
  perform pg_temp.ok(pg_temp.st('l_admin', 't6g-alice@example.test') = 'active'
                 and pg_temp.st('l_admin', 't6g-bob@example.test') = 'suspended'
                 and pg_temp.st('l_admin', 't6g-carol@example.test') = 'active', 'list: each customer carries its status');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('l_admin') -> 'customers') c
                                 where not (c ?& array['id','name','email','phone','status','created_at','order_count','lifetime_spend_cents','last_order_at'])),
                     'list: all existing fields still present, plus status');

  -- status filter + total
  perform pg_temp.ok((pg_temp.j('f_susp') ->> 'total')::int = 1 and jsonb_array_length(pg_temp.j('f_susp') -> 'customers') = 1
                 and pg_temp.j('f_susp') -> 'customers' -> 0 ->> 'name' = 'T6G Bob Otieno', 'filter suspended: only Bob, total 1');
  perform pg_temp.ok((pg_temp.j('f_act') ->> 'total')::int = 2 and jsonb_array_length(pg_temp.j('f_act') -> 'customers') = 2
                 and not exists (select 1 from jsonb_array_elements(pg_temp.j('f_act') -> 'customers') c where c ->> 'status' <> 'active'),
                 'filter active: Alice and Carol, total 2');
  perform pg_temp.ok((pg_temp.j('f_null') ->> 'total')::int = 3, 'filter null = all (total 3)');
  perform pg_temp.ok((pg_temp.j('f_page') ->> 'total')::int = 2 and jsonb_array_length(pg_temp.j('f_page') -> 'customers') = 1,
                     'filter + paging: total counts all 2 active, page holds 1');

  -- invalid status
  perform pg_temp.ok(pg_temp.err('f_bad') = 'P0001/invalid_arguments', 'invalid status "banned" rejected');
  perform pg_temp.ok(pg_temp.err('f_empty') = 'P0001/invalid_arguments', 'empty status rejected');
  perform pg_temp.ok(pg_temp.err('f_case') = 'P0001/invalid_arguments', 'wrong-case status "Active" rejected');

  -- detail: status, notes, notes_updated_at
  perform pg_temp.ok(pg_temp.j('d_alice') -> 'profile' ->> 'status' = 'active'
                 and pg_temp.j('d_alice') -> 'profile' ?& array['id','name','email','phone','status','created_at']
                 and pg_temp.j('d_alice') ?& array['addresses','stats','recent_orders','notes','notes_updated_at'],
                 'detail: profile has status; all existing top-level keys plus notes/notes_updated_at present');
  perform pg_temp.ok(pg_temp.j('d_alice') ->> 'notes' = 'T6G SECRET-NOTE prefers morning delivery'
                 and (pg_temp.j('d_alice') ->> 'notes_updated_at')::timestamptz = '2026-03-01 10:00+03'::timestamptz,
                 'detail: notes and notes_updated_at returned');
  perform pg_temp.ok(pg_temp.j('d_bob') -> 'profile' ->> 'status' = 'suspended'
                 and pg_temp.j('d_bob') -> 'notes' = 'null'::jsonb
                 and pg_temp.j('d_bob') -> 'notes_updated_at' = 'null'::jsonb,
                 'detail: suspended customer with no notes row -> notes and notes_updated_at null');
  perform pg_temp.ok(pg_temp.j('d_carol') -> 'notes' = 'null'::jsonb
                 and (pg_temp.j('d_carol') ->> 'notes_updated_at')::timestamptz = '2026-03-02 10:00+03'::timestamptz,
                 'detail: cleared notes -> notes null, notes_updated_at kept');

  -- notes never in the list
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('l_admin') -> 'customers') c
                                 where c ? 'notes' or c ? 'notes_updated_at')
                 and not (pg_temp.j('l_admin') ? 'notes')
                 and position('SECRET-NOTE' in (select res from t_res where k = 'l_admin')) = 0,
                 'list: no notes keys and no note text anywhere in the output');

  raise notice 'ALL CUSTOMER STATUS/NOTES READ TESTS PASSED';
end
$t$;

rollback;
