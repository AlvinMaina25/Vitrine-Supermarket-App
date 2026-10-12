-- Phase 6G.4-B test: payment_transactions read lockdown. NOT RUN unless the report says so.
-- Needs migrations up to 20261005080000 (6G.4-B) applied (Supabase-style auth schema, roles anon /
-- authenticated / service_role) and the seeded delivery method 'standard'.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6G4B' (provider 't6g4b'); all queries filter on it.
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

-- run q as database role r with JWT subject uid; q returns one text value (or nothing if ret is false).
create or replace function pg_temp.run(k text, r text, uid uuid, q text, ret boolean) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text; v_det text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then '' else json_build_object('sub', uid, 'role', r)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  perform set_config('request.jwt.claim.role', r, true);
  begin
    execute format('set local role %I', r);
    if ret then execute q into v_res; else execute q; end if;
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
  select ('00000000-0000-4000-8000-6a04b000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$ select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;

-- Fixtures: 1 customer A, 2 customer B, 3 staff, 4 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g4b-a@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G4B A"}'),
  (pg_temp.u(2), 't6g4b-b@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G4B B"}'),
  (pg_temp.u(3), 't6g4b-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G4B Staff"}'),
  (pg_temp.u(4), 't6g4b-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G4B Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin');

insert into public.orders (id, user_id, order_number, payment_method, delivery_method) values
  (pg_temp.u(101), pg_temp.u(1), 'T6G4B-A', 'mpesa', 'standard'),
  (pg_temp.u(102), pg_temp.u(2), 'T6G4B-B', 'mpesa', 'standard');
insert into public.payment_transactions (id, order_id, provider, method, amount_cents, idempotency_key, provider_reference) values
  (pg_temp.u(201), pg_temp.u(101), 't6g4b', 'mpesa', 1000, 'T6G4B-idem-1', 'T6G4B-ref-1'),
  (pg_temp.u(202), pg_temp.u(102), 't6g4b', 'mpesa', 2000, 'T6G4B-idem-2', null);

-- ---------------------------------------------------------------- direct SELECT denied
do $t$
declare c record;
begin
  for c in select * from (values
      ('cust',  'authenticated', pg_temp.u(1)),
      ('cust2', 'authenticated', pg_temp.u(2)),
      ('staff', 'authenticated', pg_temp.u(3)),
      ('admin', 'authenticated', pg_temp.u(4)),
      ('anon',  'anon',          null::uuid)) as x(tag, r, uid) loop
    perform pg_temp.run(c.tag || '_sel', c.r, c.uid, $q$select count(*)::text from public.payment_transactions$q$, true);
    perform pg_temp.run(c.tag || '_col', c.r, c.uid, $q$select provider_reference from public.payment_transactions limit 1$q$, true);
    perform pg_temp.run(c.tag || '_own', c.r, c.uid, format($q$select id::text from public.payment_transactions where order_id = %L$q$, pg_temp.u(101)), true);
    perform pg_temp.ok(pg_temp.state(c.tag || '_sel') = '42501' and pg_temp.res(c.tag || '_sel') is null, c.tag || ': SELECT denied (42501)');
    perform pg_temp.ok(pg_temp.state(c.tag || '_col') = '42501', c.tag || ': column SELECT denied (42501)');
    perform pg_temp.ok(pg_temp.state(c.tag || '_own') = '42501', c.tag || ': filtered SELECT denied (42501)');
  end loop;
end $t$;

-- ---------------------------------------------------------------- catalogue: no read path left
select pg_temp.ok(not exists (select 1 from (values ('anon'), ('authenticated')) r(role)
                              where has_table_privilege(r.role, 'public.payment_transactions', 'SELECT')
                                 or has_any_column_privilege(r.role, 'public.payment_transactions', 'SELECT')),
                  'anon/authenticated: no table or column SELECT');
select pg_temp.ok(not exists (select 1 from pg_class c, aclexplode(c.relacl) a
                              where c.oid = 'public.payment_transactions'::regclass and a.grantee = 0),
                  'PUBLIC holds no table privilege');
select pg_temp.ok(not exists (select 1 from pg_policy p
                              where p.polrelid = 'public.payment_transactions'::regclass and p.polcmd in ('r', '*')),
                  'no SELECT/ALL policy remains');
select pg_temp.ok((select c.relrowsecurity from pg_class c where c.oid = 'public.payment_transactions'::regclass), 'RLS still enabled');
select pg_temp.ok(not exists (select 1 from (values ('anon'), ('authenticated')) r(role),
                                (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
                              where has_table_privilege(r.role, 'public.payment_transactions', p.priv)),
                  '6G.1 write denials intact for anon/authenticated');

-- ---------------------------------------------------------------- service_role: SELECT/INSERT/UPDATE yes, DELETE/TRUNCATE no
select pg_temp.run('s_sel', 'service_role', null, $q$select count(*)::text from public.payment_transactions where provider = 't6g4b'$q$, true);
select pg_temp.run('s_ins', 'service_role', null, format($q$insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key)
                                                             values (%L, 't6g4b', 'mpesa', 500, 'T6G4B-idem-svc') returning id::text$q$, pg_temp.u(101)), true);
select pg_temp.run('s_upd', 'service_role', null, format($q$update public.payment_transactions set status = 'processing' where id = %L returning status::text$q$, pg_temp.u(201)), true);
select pg_temp.run('s_del', 'service_role', null, format($q$delete from public.payment_transactions where id = %L returning id::text$q$, pg_temp.u(201)), true);
select pg_temp.run('s_trn', 'service_role', null, 'truncate public.payment_transactions', false);

select pg_temp.ok(pg_temp.state('s_sel') is null and pg_temp.res('s_sel') = '2', 'service_role: SELECT works');
select pg_temp.ok(pg_temp.state('s_ins') is null and pg_temp.res('s_ins') is not null, 'service_role: INSERT works');
select pg_temp.ok(pg_temp.state('s_upd') is null and pg_temp.res('s_upd') = 'processing', 'service_role: UPDATE works');
select pg_temp.ok(pg_temp.state('s_del') = '42501', 'service_role: DELETE denied');
select pg_temp.ok(pg_temp.state('s_trn') = '42501', 'service_role: TRUNCATE denied');
select pg_temp.ok((select count(*) = 3 from public.payment_transactions where provider = 't6g4b'), 'ledger intact: 3 rows (2 fixtures + service insert)');

-- ---------------------------------------------------------------- read functions still work after the lockdown
select pg_temp.run('f_list', 'authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(p_order_id => %L)::text$q$, pg_temp.u(101)), true);
select pg_temp.run('f_get',  'authenticated', pg_temp.u(4), format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(201)), true);
select pg_temp.run('f_my',   'authenticated', pg_temp.u(1), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)), true);
select pg_temp.run('f_my_x', 'authenticated', pg_temp.u(2), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)), true);
select pg_temp.run('f_staff','authenticated', pg_temp.u(3), $q$select public.admin_list_payment_transactions()::text$q$, true);

select pg_temp.ok(pg_temp.state('f_list') is null and (pg_temp.j('f_list')->>'total_count')::int = 2, 'admin_list_payment_transactions works (order A: 2 rows)');
select pg_temp.ok(pg_temp.state('f_get') is null and pg_temp.j('f_get')->>'idempotency_key' = 'T6G4B-idem-1', 'admin_get_payment_transaction works');
select pg_temp.ok(pg_temp.state('f_my') is null and jsonb_array_length(pg_temp.j('f_my')->'transactions') = 2, 'get_my_order_payments works for the owner');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('f_my')->'transactions') e where e ? 'provider_reference' or e ? 'idempotency_key' or e ? 'provider'),
                  'customer function still hides provider data');
select pg_temp.ok(pg_temp.state('f_my_x') = 'P0001', 'get_my_order_payments still refuses another customer''s order');
select pg_temp.ok(pg_temp.state('f_staff') = '42501', 'admin list still refuses non-admin');

-- ---------------------------------------------------------------- function grants
select pg_temp.ok(has_function_privilege('service_role', 'public.get_order_for_payment(uuid)', 'EXECUTE')
                  and has_function_privilege('service_role', 'public.create_payment_attempt(uuid,text,public.payment_method,text)', 'EXECUTE')
                  and has_function_privilege('service_role', 'public.mark_payment_processing(uuid,text)', 'EXECUTE')
                  and has_function_privilege('service_role', 'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)', 'EXECUTE'),
                  'service functions executable by service_role');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.get_order_for_payment(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'public.create_payment_attempt(uuid,text,public.payment_method,text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'public.mark_payment_processing(uuid,text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)', 'EXECUTE'),
                  'service functions not executable by authenticated');
select pg_temp.ok(has_function_privilege('authenticated', 'public.record_cod_payment(uuid,text)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.record_cod_payment(uuid,text)', 'EXECUTE'), 'record_cod_payment: authenticated yes, anon no');
select pg_temp.ok(has_function_privilege('authenticated', 'public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
                  and has_function_privilege('authenticated', 'public.admin_get_payment_transaction(uuid)', 'EXECUTE')
                  and has_function_privilege('authenticated', 'public.get_my_order_payments(uuid)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.admin_get_payment_transaction(uuid)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.get_my_order_payments(uuid)', 'EXECUTE'),
                  'read functions: authenticated yes, anon no');

rollback;
