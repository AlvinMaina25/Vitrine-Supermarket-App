-- Phase 6E.3 test: customer hardening (suspended customers cannot order; audit/notes SELECT is
-- admin-only; browser roles cannot INSERT profiles.status). NOT RUN on Supabase.
-- Needs migrations up to 20261004170000 applied. Run as postgres/owner (SQL Editor or psql).
-- One transaction, rolled back at the end. Fixtures carry the marker 'T6I'.
begin;

do $pre$
begin
  -- Since 6I.1 the 'Audit log: admin read' policy is gone; the audit log is read via admin_list_audit_log().
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_notes'
                 and policyname = 'Customer notes: admin read')
     or to_regprocedure('public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)') is null then
    raise exception 'Phase 6E.3 test: apply 20261004170000 (6E.3) and 20261005090000 (6I.1) first.';
  end if;
end
$pre$;

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

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.msg(k text) returns text language sql as $$
  select err from t_res where t_res.k = msg.k $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f40000000' || lpad(n::text, 2, '0'))::uuid $$;

-- create_order() as a customer: pickup method without slot or address, cash on delivery
-- k, caller, idempotency key (or null), items json (SQL literal text)
create or replace function pg_temp.co(k text, uid uuid, idem text, items text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'authenticated', uid,
    format('select public.create_order(p_items => %L::jsonb, p_delivery_method => ''e3_pick'', p_payment_method => ''cash_on_delivery'', p_idempotency_key => %s)::text',
           items, coalesce(quote_literal(idem), 'null')));
end $$;

create or replace function pg_temp.stock() returns integer language sql as $$
  select stock_quantity from public.products where slug = 'e3-t6i-p1' $$;

create or replace function pg_temp.orders_of(uid uuid) returns bigint language sql as $$
  select count(*) from public.orders where user_id = uid $$;

-- Fixtures: 1 Alice (will be suspended), 2 Bob (other customer), 3 staff, 4 admin,
--           5 Eve (customer whose profile row is removed to test inserts)
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6i-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I Alice"}'),
  (pg_temp.u(2), 't6i-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6I Bob"}'),
  (pg_temp.u(3), 't6i-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I Staff"}'),
  (pg_temp.u(4), 't6i-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6I Admin"}'),
  (pg_temp.u(5), 't6i-eve@example.test',   'authenticated', 'authenticated', '{"full_name":"T6I Eve"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-6f400000b001', 'e3-t6i-p1', 'T6I product', 1000, 10, true, true);
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('e3_pick', 'T6I pickup', 0, null, 0, false, false, true);

-- ---------------------------------------------------------------------------------------------
-- A. Orders. Alice orders while active, gets suspended, is refused (new key, replayed key, no key,
--    empty basket), Bob is unaffected, Alice is reactivated and can order / replay again.
-- ---------------------------------------------------------------------------------------------
create temp table t_snap (k text primary key, stock integer, alice_orders bigint, all_orders bigint);

select pg_temp.co('a_unauth', null, null, '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
select pg_temp.co('a1', pg_temp.u(1), 'T6I-key-1', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');

-- admin suspends Alice (through the real admin function)
select pg_temp.run('susp', 'authenticated', pg_temp.u(4),
  format('select public.admin_set_customer_status(%L::uuid, ''suspended'', ''T6I abuse'')::text', pg_temp.u(1)));

insert into t_snap select 'before_refusals', pg_temp.stock(), pg_temp.orders_of(pg_temp.u(1)), (select count(*) from public.orders);

select pg_temp.co('a_new',    pg_temp.u(1), 'T6I-key-2', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
select pg_temp.co('a_replay', pg_temp.u(1), 'T6I-key-1', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
select pg_temp.co('a_nokey',  pg_temp.u(1), null,        '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
select pg_temp.co('a_empty',  pg_temp.u(1), 'T6I-key-3', '[]');
select pg_temp.co('a_big',    pg_temp.u(1), null,        '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":9}]');

insert into t_snap select 'after_refusals', pg_temp.stock(), pg_temp.orders_of(pg_temp.u(1)), (select count(*) from public.orders);

-- another customer is unaffected while Alice is suspended
select pg_temp.co('b1', pg_temp.u(2), 'T6I-key-b1', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
insert into t_snap select 'after_bob', pg_temp.stock(), pg_temp.orders_of(pg_temp.u(1)), (select count(*) from public.orders);

-- reactivation: orders work again, and the old key replays to the ORIGINAL order
select pg_temp.run('react', 'authenticated', pg_temp.u(4),
  format('select public.admin_set_customer_status(%L::uuid, ''active'', ''T6I resolved'')::text', pg_temp.u(1)));
select pg_temp.co('a_back',   pg_temp.u(1), 'T6I-key-4', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
select pg_temp.co('a_replay2', pg_temp.u(1), 'T6I-key-1', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');
insert into t_snap select 'after_react', pg_temp.stock(), pg_temp.orders_of(pg_temp.u(1)), (select count(*) from public.orders);

-- a signed-in user with no profile row is not blocked (the check blocks only status = 'suspended')
delete from public.profiles where id = pg_temp.u(5);
select pg_temp.co('e1', pg_temp.u(5), 'T6I-key-e1', '[{"product_id":"00000000-0000-4000-8000-6f400000b001","quantity":1}]');

-- ---------------------------------------------------------------------------------------------
-- B. Audit log and notes: SELECT is admin-only
-- ---------------------------------------------------------------------------------------------
select pg_temp.run('note', 'authenticated', pg_temp.u(4),
  format('select public.admin_update_customer_notes(%L::uuid, ''T6I-SECRET note'')::text', pg_temp.u(2)));

select pg_temp.run('aud_admin',  'authenticated', pg_temp.u(4), $q$select (public.admin_list_audit_log(null, null, null, null, null, 100, 0) ->> 'total_count')$q$);
select pg_temp.run('aud_staff',  'authenticated', pg_temp.u(3), $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
select pg_temp.run('aud_cust',   'authenticated', pg_temp.u(1), $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
select pg_temp.run('aud_anon',   'anon',          null,         $q$select public.admin_list_audit_log(null, null, null, null, null, 100, 0)::text$q$);
select pg_temp.run('not_admin',  'authenticated', pg_temp.u(4),
  format('select count(*)::text from public.customer_notes where customer_id = %L', pg_temp.u(2)));
select pg_temp.run('not_staff',  'authenticated', pg_temp.u(3), 'select count(*)::text from public.customer_notes');
select pg_temp.run('not_cust',   'authenticated', pg_temp.u(2), 'select count(*)::text from public.customer_notes');
select pg_temp.run('not_anon',   'anon',          null,         'select count(*)::text from public.customer_notes');
-- admin API unchanged: admin reads the notes through admin_get_customer, staff is refused
select pg_temp.run('get_admin', 'authenticated', pg_temp.u(4), format('select public.admin_get_customer(%L::uuid)::text', pg_temp.u(2)));
select pg_temp.run('get_staff', 'authenticated', pg_temp.u(3), format('select public.admin_get_customer(%L::uuid)::text', pg_temp.u(2)));
-- direct writes are still impossible, even for admin
select pg_temp.run('w_aud', 'authenticated', pg_temp.u(4),
  format('insert into public.admin_audit_log (actor_id, action) values (%L, ''x'') returning id::text', pg_temp.u(4)));
select pg_temp.run('w_not', 'authenticated', pg_temp.u(4),
  format('insert into public.customer_notes (customer_id, notes) values (%L, ''x'') returning customer_id::text', pg_temp.u(1)));

-- ---------------------------------------------------------------------------------------------
-- C. profiles.status: no INSERT for browser roles
-- ---------------------------------------------------------------------------------------------
-- Eve has no profile row now (deleted above, then re-created by nothing). Insert as Eve:
select pg_temp.run('p_ins_susp', 'authenticated', pg_temp.u(5),
  format('insert into public.profiles (id, email, status) values (%L, ''t6i-eve@example.test'', ''suspended'') returning id::text', pg_temp.u(5)));
select pg_temp.run('p_ins_active', 'authenticated', pg_temp.u(5),
  format('insert into public.profiles (id, email, status) values (%L, ''t6i-eve@example.test'', ''active'') returning id::text', pg_temp.u(5)));
select pg_temp.run('p_ins_other', 'authenticated', pg_temp.u(5),
  format('insert into public.profiles (id, email) values (%L, ''t6i-other@example.test'') returning id::text', pg_temp.u(2)));
select pg_temp.run('p_ins_ok', 'authenticated', pg_temp.u(5),
  format('insert into public.profiles (id, email, full_name) values (%L, ''t6i-eve@example.test'', ''T6I Eve'') returning id::text', pg_temp.u(5)));
select pg_temp.run('p_upd', 'authenticated', pg_temp.u(1),
  format('update public.profiles set status = ''suspended'' where id = %L returning id::text', pg_temp.u(1)));
select pg_temp.run('p_upd_name', 'authenticated', pg_temp.u(1),
  format('update public.profiles set full_name = ''T6I Alice 2'' where id = %L returning id::text', pg_temp.u(1)));
select pg_temp.run('p_anon_ins', 'anon', null,
  format('insert into public.profiles (id, email) values (%L, ''x@example.test'') returning id::text', pg_temp.u(2)));

do $t$
declare
  v_s_before t_snap%rowtype; v_s_ref t_snap%rowtype; v_s_bob t_snap%rowtype; v_s_react t_snap%rowtype;
  v_a1 uuid; v_prof public.profiles%rowtype;
begin
  select * into v_s_before from t_snap where k = 'before_refusals';
  select * into v_s_ref    from t_snap where k = 'after_refusals';
  select * into v_s_bob    from t_snap where k = 'after_bob';
  select * into v_s_react  from t_snap where k = 'after_react';

  -- A. orders
  perform pg_temp.ok(pg_temp.err('a_unauth') like '42501/%', 'no signed-in user is still refused first (42501)');
  perform pg_temp.ok(pg_temp.err('a1') is null and (select res from t_res where k = 'a1') is not null,
                     'active customer can order (control)');
  v_a1 := (select res::uuid from t_res where k = 'a1');
  perform pg_temp.ok(v_a1 is not null and v_s_before.stock = 9 and v_s_before.alice_orders = 1,
                     'control order created one order and reserved 1 unit (stock 10 -> 9)');
  perform pg_temp.ok(pg_temp.j('susp') ->> 'status' = 'suspended', 'admin suspended the customer (real admin function)');

  perform pg_temp.ok(pg_temp.err('a_new') = 'P0001/account_suspended', 'suspended: new order refused with account_suspended');
  perform pg_temp.ok(pg_temp.msg('a_new') ilike '%suspended%', 'the error message says the account is suspended');
  perform pg_temp.ok(pg_temp.err('a_replay') = 'P0001/account_suspended',
                     'suspended: idempotency replay of an earlier order is refused too');
  perform pg_temp.ok(pg_temp.err('a_nokey') = 'P0001/account_suspended', 'suspended: order without an idempotency key refused');
  perform pg_temp.ok(pg_temp.err('a_empty') = 'P0001/account_suspended',
                     'suspended: refused before the basket is even validated (empty basket -> account_suspended)');
  perform pg_temp.ok(pg_temp.err('a_big') = 'P0001/account_suspended', 'suspended: larger quantity refused as well');
  perform pg_temp.ok(v_s_ref.stock = v_s_before.stock, 'refusals reserved NO stock');
  perform pg_temp.ok(v_s_ref.alice_orders = v_s_before.alice_orders and v_s_ref.all_orders = v_s_before.all_orders,
                     'refusals created NO order row');

  perform pg_temp.ok((select res from t_res where k = 'b1') is not null and pg_temp.err('b1') is null,
                     'other customer can still order while Alice is suspended');
  perform pg_temp.ok(v_s_bob.stock = v_s_ref.stock - 1 and v_s_bob.all_orders = v_s_ref.all_orders + 1
                     and v_s_bob.alice_orders = v_s_ref.alice_orders,
                     'other customer''s order reserved stock and touched only their own order');

  perform pg_temp.ok(pg_temp.j('react') ->> 'status' = 'active', 'admin reactivated the customer');
  perform pg_temp.ok(pg_temp.err('a_back') is null and (select res::uuid from t_res where k = 'a_back') is not null,
                     'reactivation: the customer can order again');
  perform pg_temp.ok(pg_temp.err('a_replay2') is null and (select res::uuid from t_res where k = 'a_replay2') = v_a1,
                     'reactivation: replay of the original key returns the original order (no duplicate)');
  perform pg_temp.ok(v_s_react.stock = v_s_bob.stock - 1 and v_s_react.alice_orders = v_s_bob.alice_orders + 1,
                     'after reactivation exactly one new order and one unit reserved (replay added none)');
  perform pg_temp.ok(pg_temp.err('e1') is null and (select res from t_res where k = 'e1') is not null,
                     'a signed-in user without a profile row is not blocked by the new check');
  perform pg_temp.ok((select p.status from public.profiles p where p.id = pg_temp.u(1)) = 'active'
                     and (select p.status from public.profiles p where p.id = pg_temp.u(2)) = 'active',
                     'Alice and Bob end up active');

  -- create_order() shape
  perform pg_temp.ok((select count(*) from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace) = 1,
                     'still exactly one create_order() overload');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)', 'EXECUTE')
                     and not has_function_privilege('anon', 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)', 'EXECUTE'),
                     'create_order() grants unchanged (authenticated yes, anon no)');

  -- B. audit and notes
  perform pg_temp.ok((select res::bigint from t_res where k = 'aud_admin') >= 3, 'admin reads the audit log via admin_list_audit_log (suspend, reactivate, notes)');
  perform pg_temp.ok(pg_temp.err('aud_staff') = '42501/not_authorised', 'staff (non-admin) cannot read the audit log (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('aud_cust') = '42501/not_authorised', 'customer cannot read the audit log (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('aud_anon') like '42501/%', 'anon cannot read the audit log');
  perform pg_temp.ok((select res from t_res where k = 'not_admin') = '1', 'admin reads customer_notes directly');
  perform pg_temp.ok((select res from t_res where k = 'not_staff') = '0', 'staff (non-admin) sees 0 notes rows');
  perform pg_temp.ok((select res from t_res where k = 'not_cust') = '0', 'customer sees 0 notes rows (even for their own row)');
  perform pg_temp.ok(pg_temp.err('not_anon') like '42501/%', 'anon cannot read customer_notes');
  perform pg_temp.ok(pg_temp.j('get_admin') ->> 'notes' = 'T6I-SECRET note', 'admin_get_customer still returns the notes to an admin');
  perform pg_temp.ok(pg_temp.err('get_staff') = '42501/not_authorised', 'admin_get_customer still refuses staff');
  perform pg_temp.ok(pg_temp.err('w_aud') like '42501/%' and pg_temp.err('w_not') like '42501/%',
                     'no direct INSERT on the audit log or notes, even for admin');
  perform pg_temp.ok((select count(*) from pg_policies where schemaname = 'public' and tablename = 'admin_audit_log') = 0
                     and not has_table_privilege('authenticated', 'public.admin_audit_log', 'SELECT')
                     and not has_table_privilege('anon', 'public.admin_audit_log', 'SELECT')
                     and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'customer_notes') = 1
                     and not exists (select 1 from pg_policies where schemaname = 'public'
                                     and tablename = 'customer_notes'
                                     and (cmd <> 'SELECT' or qual not like '%is_admin%' or qual like '%is_staff%')),
                     'audit log: no policy and no browser SELECT (6I.1); customer_notes: exactly one admin-only SELECT policy');

  -- C. profiles.status
  perform pg_temp.ok(pg_temp.err('p_ins_susp') like '42501/%', 'authenticated cannot INSERT a profile with status = suspended');
  perform pg_temp.ok(pg_temp.err('p_ins_active') like '42501/%', 'authenticated cannot INSERT the status column at all (even ''active'')');
  perform pg_temp.ok(pg_temp.err('p_ins_other') like '42501/%', 'authenticated still cannot INSERT a profile for someone else (RLS)');
  perform pg_temp.ok(pg_temp.err('p_ins_ok') is null and (select res from t_res where k = 'p_ins_ok') = pg_temp.u(5)::text,
                     'authenticated can still INSERT their own profile without status');
  select * into v_prof from public.profiles where id = pg_temp.u(5);
  perform pg_temp.ok(v_prof.status = 'active' and v_prof.full_name = 'T6I Eve', 'that profile took the default status active');
  perform pg_temp.ok(pg_temp.err('p_upd') like '42501/%', 'authenticated still cannot UPDATE profiles.status');
  perform pg_temp.ok(pg_temp.err('p_upd_name') is null, 'authenticated can still UPDATE their own full_name');
  perform pg_temp.ok(pg_temp.err('p_anon_ins') like '42501/%', 'anon cannot INSERT into profiles');
  perform pg_temp.ok(not has_column_privilege('authenticated', 'public.profiles', 'status', 'INSERT')
                     and not has_column_privilege('anon', 'public.profiles', 'status', 'INSERT')
                     and not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
                     'catalog: no INSERT on profiles.status (or table-level INSERT) for browser roles');
  perform pg_temp.ok(has_column_privilege('service_role', 'public.profiles', 'status', 'INSERT')
                     and has_column_privilege('service_role', 'public.profiles', 'status', 'UPDATE'),
                     'service_role keeps full access to profiles.status');
  -- the signup trigger (security definer) still creates active profiles
  perform pg_temp.ok((select status from public.profiles where id = pg_temp.u(3)) = 'active', 'signup trigger still creates an active profile');
end
$t$;

rollback;
