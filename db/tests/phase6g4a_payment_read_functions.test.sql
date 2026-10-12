-- Phase 6G.4-A test: the three payment read functions. NOT RUN unless the report says so.
-- Needs migrations up to 20261005070000 applied (Supabase-style auth schema: auth.users, auth.uid(),
-- roles anon/authenticated) and the seeded delivery method 'standard'.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures: providers 't6g4a-x'/'t6g4a-y'/'t6g4a-bulk'; fixture rows are dated 2020/2021 and every
-- list query is bounded to those dates or to the fixture provider, so existing rows are ignored.
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

-- run q as database role r with JWT subject uid; q returns one text value. Result or error is stored under k.
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
  select ('00000000-0000-4000-8000-6a040000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.res(k text) returns text language sql as $$ select res from t_res where t_res.k = res.k $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$ select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.state(k text) returns text language sql as $$ select state from t_res where t_res.k = state.k $$;
create or replace function pg_temp.det(k text) returns text language sql as $$ select det from t_res where t_res.k = det.k $$;
create or replace function pg_temp.msg(k text) returns text language sql as $$ select err from t_res where t_res.k = msg.k $$;
create or replace function pg_temp.ids(k text) returns text[] language sql as $$
  select coalesce(array_agg(e->>'id' order by o), '{}') from t_res, jsonb_array_elements(t_res.res::jsonb->'transactions') with ordinality as x(e, o)
  where t_res.k = ids.k $$;
create or replace function pg_temp.keys(v jsonb) returns text[] language sql as $$
  select array_agg(key order by key) from jsonb_object_keys(v) as key $$;

-- Fixtures: 1 customer A, 2 customer B, 3 staff, 4 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g4a-a@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G4A A"}'),
  (pg_temp.u(2), 't6g4a-b@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G4A B"}'),
  (pg_temp.u(3), 't6g4a-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G4A Staff"}'),
  (pg_temp.u(4), 't6g4a-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G4A Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin');

insert into public.orders (id, user_id, order_number, payment_method, delivery_method) values
  (pg_temp.u(101), pg_temp.u(1), 'T6G4A-A',    'mpesa', 'standard'),
  (pg_temp.u(102), pg_temp.u(2), 'T6G4A-B',    'mpesa', 'standard'),
  (pg_temp.u(103), pg_temp.u(1), 'T6G4A-BULK', 'mpesa', 'standard');

-- Order A (101): 201 pending x, 202 succeeded x, 203 failed y, 205+206 pending x (same created_at -> id desc tiebreak)
-- Order B (102): 204 failed x
insert into public.payment_transactions
  (id, order_id, provider, method, amount_cents, status, provider_reference, idempotency_key, failure_code, failure_message, created_at, completed_at) values
  (pg_temp.u(201), pg_temp.u(101), 't6g4a-x', 'mpesa', 1000, 'pending',   'T6G4A-ref-1', 'T6G4A-idem-201', null, null, '2020-01-01 10:00+00', null),
  (pg_temp.u(202), pg_temp.u(101), 't6g4a-x', 'mpesa', 2000, 'succeeded', 'T6G4A-ref-2', 'T6G4A-idem-202', null, null, '2020-01-02 10:00+00', '2020-01-02 10:05+00'),
  (pg_temp.u(203), pg_temp.u(101), 't6g4a-y', 'mpesa', 3000, 'failed',    'T6G4A-ref-3', 'T6G4A-idem-203', 'F1', 'declined', '2020-01-03 10:00+00', '2020-01-03 10:01+00'),
  (pg_temp.u(204), pg_temp.u(102), 't6g4a-x', 'mpesa', 4000, 'failed',    null,          'T6G4A-idem-204', 'F2', 'timeout',  '2020-01-04 10:00+00', '2020-01-04 10:01+00'),
  (pg_temp.u(205), pg_temp.u(101), 't6g4a-x', 'mpesa', 5000, 'pending',   null,          'T6G4A-idem-205', null, null, '2020-01-05 10:00+00', null),
  (pg_temp.u(206), pg_temp.u(101), 't6g4a-x', 'mpesa', 6000, 'pending',   null,          'T6G4A-idem-206', null, null, '2020-01-05 10:00+00', null);
-- 120 bulk rows on order 103, one per minute, Feb 2021
insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key, created_at)
select pg_temp.u(103), 't6g4a-bulk', 'mpesa', 100 + i, 'T6G4A-bulk-' || i, timestamptz '2021-02-01 00:00+00' + (i || ' minutes')::interval
from generate_series(1, 120) i;

-- ---------------------------------------------------------------- admin list: filters
select pg_temp.run('l_order',  'authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(p_order_id => %L)::text$q$, pg_temp.u(101)));
select pg_temp.run('l_status', 'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_status => 'failed', p_from => '2020-01-01+00', p_to => '2021-01-01+00')::text$q$);
select pg_temp.run('l_prov',   'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-x', p_from => '2020-01-01+00', p_to => '2021-01-01+00')::text$q$);
select pg_temp.run('l_range',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_from => '2020-01-02 10:00+00', p_to => '2020-01-03 10:00+00')::text$q$);
select pg_temp.run('l_comb',   'authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(%L, 'pending', 't6g4a-x', '2020-01-01+00', '2020-01-06+00')::text$q$, pg_temp.u(101)));
select pg_temp.run('l_none',   'authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(%L, 'succeeded', 't6g4a-y')::text$q$, pg_temp.u(101)));

select pg_temp.ok((pg_temp.j('l_order')->>'total_count')::int = 5, 'filter order: total_count 5');
select pg_temp.ok(pg_temp.ids('l_order') = array[pg_temp.u(206), pg_temp.u(205), pg_temp.u(203), pg_temp.u(202), pg_temp.u(201)]::text[],
                  'newest first: created_at desc, id desc breaks the 205/206 tie');
select pg_temp.ok((pg_temp.j('l_status')->>'total_count')::int = 2 and pg_temp.ids('l_status') = array[pg_temp.u(204), pg_temp.u(203)]::text[], 'filter status=failed');
select pg_temp.ok((pg_temp.j('l_prov')->>'total_count')::int = 5, 'filter provider=t6g4a-x');
select pg_temp.ok(pg_temp.ids('l_range') = array[pg_temp.u(202)]::text[], 'date range: from inclusive, to exclusive');
select pg_temp.ok(pg_temp.ids('l_comb') = array[pg_temp.u(206), pg_temp.u(205), pg_temp.u(201)]::text[], 'combined filters');
select pg_temp.ok((pg_temp.j('l_none')->>'total_count')::int = 0 and pg_temp.j('l_none')->'transactions' = '[]'::jsonb, 'no match: total_count 0, empty array');
select pg_temp.ok(pg_temp.keys(pg_temp.j('l_order')) = array['limit','offset','total_count','transactions'], 'list top-level keys');
select pg_temp.ok(pg_temp.keys(pg_temp.j('l_order')->'transactions'->0) = array['amount_cents','completed_at','created_at','currency','failure_code','failure_message','id','method','order_id','provider','provider_reference','status','updated_at'],
                  'list row key set (no idempotency_key)');

-- ---------------------------------------------------------------- pagination + cap
select pg_temp.run('p_cap',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk', p_limit => 1000)::text$q$);
select pg_temp.run('p_pg1',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk', p_limit => 10, p_offset => 0)::text$q$);
select pg_temp.run('p_pg2',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk', p_limit => 10, p_offset => 10)::text$q$);
select pg_temp.run('p_tail', 'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk', p_limit => 50, p_offset => 100)::text$q$);
select pg_temp.run('p_past', 'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk', p_limit => 10, p_offset => 500)::text$q$);
select pg_temp.run('p_def',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_provider => 't6g4a-bulk')::text$q$);

select pg_temp.ok((pg_temp.j('p_cap')->>'limit')::int = 100 and jsonb_array_length(pg_temp.j('p_cap')->'transactions') = 100
                  and (pg_temp.j('p_cap')->>'total_count')::int = 120, 'limit 1000 capped to 100 rows, total_count 120');
select pg_temp.ok(pg_temp.ids('p_cap') = (select array_agg(id::text order by created_at desc, id desc) from
                    (select id, created_at from public.payment_transactions where provider = 't6g4a-bulk' order by created_at desc, id desc limit 100) s),
                  'bulk rows come back newest first');
select pg_temp.ok(jsonb_array_length(pg_temp.j('p_pg1')->'transactions') = 10 and (pg_temp.j('p_pg1')->>'total_count')::int = 120, 'page 1: 10 rows, total 120');
select pg_temp.ok(not (pg_temp.ids('p_pg1') && pg_temp.ids('p_pg2')) and (pg_temp.ids('p_pg2'))[1] is not null, 'page 2 does not overlap page 1');
select pg_temp.ok(pg_temp.ids('p_pg1') || pg_temp.ids('p_pg2') = (pg_temp.ids('p_cap'))[1:20], 'pages 1+2 equal first 20 of the full order');
select pg_temp.ok(jsonb_array_length(pg_temp.j('p_tail')->'transactions') = 20 and (pg_temp.j('p_tail')->>'offset')::int = 100, 'offset 100 limit 50: 20 rows left');
select pg_temp.ok(jsonb_array_length(pg_temp.j('p_past')->'transactions') = 0 and (pg_temp.j('p_past')->>'total_count')::int = 120, 'offset past end: empty page, total still 120');
select pg_temp.ok((pg_temp.j('p_def')->>'limit')::int = 25 and (pg_temp.j('p_def')->>'offset')::int = 0
                  and jsonb_array_length(pg_temp.j('p_def')->'transactions') = 25, 'defaults: limit 25, offset 0');

-- ---------------------------------------------------------------- invalid arguments
select pg_temp.run('i_lim0',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_limit => 0)::text$q$);
select pg_temp.run('i_limn',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_limit => null)::text$q$);
select pg_temp.run('i_off',   'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_offset => -1)::text$q$);
select pg_temp.run('i_offn',  'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_offset => null)::text$q$);
select pg_temp.run('i_range', 'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_from => '2020-01-02+00', p_to => '2020-01-01+00')::text$q$);
select pg_temp.run('i_equal', 'authenticated', pg_temp.u(4), $q$select public.admin_list_payment_transactions(p_from => '2020-01-02+00', p_to => '2020-01-02+00')::text$q$);
select pg_temp.run('i_prov',  'authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(p_provider => %L)::text$q$, repeat('p', 41)));
select pg_temp.run('i_prov40','authenticated', pg_temp.u(4), format($q$select public.admin_list_payment_transactions(p_provider => %L)::text$q$, repeat('p', 40)));

select pg_temp.ok(pg_temp.state('i_lim0') = 'P0001' and pg_temp.det('i_lim0') = 'invalid_arguments', 'invalid: limit 0');
select pg_temp.ok(pg_temp.state('i_limn') = 'P0001' and pg_temp.det('i_limn') = 'invalid_arguments', 'invalid: limit null');
select pg_temp.ok(pg_temp.state('i_off') = 'P0001' and pg_temp.det('i_off') = 'invalid_arguments', 'invalid: offset -1');
select pg_temp.ok(pg_temp.state('i_offn') = 'P0001' and pg_temp.det('i_offn') = 'invalid_arguments', 'invalid: offset null');
select pg_temp.ok(pg_temp.state('i_range') = 'P0001' and pg_temp.det('i_range') = 'invalid_arguments', 'invalid: from > to');
select pg_temp.ok(pg_temp.state('i_equal') = 'P0001' and pg_temp.det('i_equal') = 'invalid_arguments', 'invalid: from = to');
select pg_temp.ok(pg_temp.state('i_prov') = 'P0001' and pg_temp.det('i_prov') = 'invalid_arguments', 'invalid: provider 41 chars');
select pg_temp.ok(pg_temp.state('i_prov40') is null and (pg_temp.j('i_prov40')->>'total_count')::int = 0, 'provider of exactly 40 chars is accepted');

-- ---------------------------------------------------------------- authorisation
select pg_temp.run('n_cust_l',  'authenticated', pg_temp.u(1), $q$select public.admin_list_payment_transactions()::text$q$);
select pg_temp.run('n_staff_l', 'authenticated', pg_temp.u(3), $q$select public.admin_list_payment_transactions()::text$q$);
select pg_temp.run('n_anon_l',  'anon',          null,         $q$select public.admin_list_payment_transactions()::text$q$);
select pg_temp.run('n_nouid_l', 'authenticated', null,         $q$select public.admin_list_payment_transactions()::text$q$);
select pg_temp.run('n_cust_g',  'authenticated', pg_temp.u(1), format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(201)));
select pg_temp.run('n_staff_g', 'authenticated', pg_temp.u(3), format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(201)));
select pg_temp.run('n_anon_g',  'anon',          null,         format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(201)));
select pg_temp.run('n_anon_m',  'anon',          null,         format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)));
select pg_temp.run('n_nouid_m', 'authenticated', null,         format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)));

select pg_temp.ok(pg_temp.state('n_cust_l') = '42501' and pg_temp.det('n_cust_l') = 'not_authorised', 'list: customer denied');
select pg_temp.ok(pg_temp.state('n_staff_l') = '42501' and pg_temp.det('n_staff_l') = 'not_authorised', 'list: staff (non-admin) denied');
select pg_temp.ok(pg_temp.state('n_anon_l') = '42501', 'list: anon denied (no EXECUTE)');
select pg_temp.ok(pg_temp.state('n_nouid_l') = '42501' and pg_temp.det('n_nouid_l') = 'not_authorised', 'list: no auth.uid() denied');
select pg_temp.ok(pg_temp.state('n_cust_g') = '42501' and pg_temp.det('n_cust_g') = 'not_authorised', 'get: customer denied');
select pg_temp.ok(pg_temp.state('n_staff_g') = '42501' and pg_temp.det('n_staff_g') = 'not_authorised', 'get: staff (non-admin) denied');
select pg_temp.ok(pg_temp.state('n_anon_g') = '42501', 'get: anon denied (no EXECUTE)');
select pg_temp.ok(pg_temp.state('n_anon_m') = '42501', 'my payments: anon denied (no EXECUTE)');
select pg_temp.ok(pg_temp.state('n_nouid_m') = '42501' and pg_temp.det('n_nouid_m') = 'not_authorised', 'my payments: no auth.uid() -> not_authorised');
select pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.admin_get_payment_transaction(uuid)', 'EXECUTE')
                  and not has_function_privilege('anon', 'public.get_my_order_payments(uuid)', 'EXECUTE')
                  and has_function_privilege('authenticated', 'public.get_my_order_payments(uuid)', 'EXECUTE'), 'anon has no EXECUTE; authenticated has');

-- ---------------------------------------------------------------- admin detail
select pg_temp.run('g_ok',   'authenticated', pg_temp.u(4), format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(203)));
select pg_temp.run('g_none', 'authenticated', pg_temp.u(4), format($q$select public.admin_get_payment_transaction(%L)::text$q$, pg_temp.u(999)));
select pg_temp.run('g_null', 'authenticated', pg_temp.u(4), $q$select public.admin_get_payment_transaction(null)::text$q$);

select pg_temp.ok(pg_temp.j('g_ok')->>'id' = pg_temp.u(203)::text and pg_temp.j('g_ok')->>'idempotency_key' = 'T6G4A-idem-203'
                  and pg_temp.j('g_ok')->>'provider_reference' = 'T6G4A-ref-3' and pg_temp.j('g_ok')->>'failure_code' = 'F1'
                  and (pg_temp.j('g_ok')->>'amount_cents')::int = 3000 and pg_temp.j('g_ok')->>'status' = 'failed', 'detail: values correct');
select pg_temp.ok(pg_temp.keys(pg_temp.j('g_ok')) = array['amount_cents','completed_at','created_at','currency','failure_code','failure_message','id','idempotency_key','method','order_id','provider','provider_reference','status','updated_at'],
                  'detail key set (list fields + idempotency_key)');
select pg_temp.ok(pg_temp.state('g_none') = 'P0001' and pg_temp.det('g_none') = 'transaction_not_found', 'detail: unknown id -> transaction_not_found');
select pg_temp.ok(pg_temp.state('g_null') = 'P0001' and pg_temp.det('g_null') = 'invalid_arguments', 'detail: null -> invalid_arguments');

-- ---------------------------------------------------------------- customer: own order only
select pg_temp.run('m_a',     'authenticated', pg_temp.u(1), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)));
select pg_temp.run('m_a_b',   'authenticated', pg_temp.u(1), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(102)));
select pg_temp.run('m_b_a',   'authenticated', pg_temp.u(2), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)));
select pg_temp.run('m_b',     'authenticated', pg_temp.u(2), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(102)));
select pg_temp.run('m_ghost', 'authenticated', pg_temp.u(1), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(998)));
select pg_temp.run('m_null',  'authenticated', pg_temp.u(1), $q$select public.get_my_order_payments(null)::text$q$);
select pg_temp.run('m_admin', 'authenticated', pg_temp.u(4), format($q$select public.get_my_order_payments(%L)::text$q$, pg_temp.u(101)));

select pg_temp.ok(pg_temp.j('m_a')->>'order_id' = pg_temp.u(101)::text and jsonb_array_length(pg_temp.j('m_a')->'transactions') = 5
                  and pg_temp.ids('m_a') = array[pg_temp.u(206), pg_temp.u(205), pg_temp.u(203), pg_temp.u(202), pg_temp.u(201)]::text[], 'customer A sees own order rows, newest first');
select pg_temp.ok(pg_temp.keys(pg_temp.j('m_a')) = array['order_id','transactions'], 'customer result top-level keys');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('m_a')->'transactions') e
                              where pg_temp.keys(e) is distinct from array['amount_cents','completed_at','created_at','currency','id','method','order_id','status']),
                  'customer rows: exact key set (provider, provider_reference, failure_*, idempotency_key, updated_at absent)');
select pg_temp.ok(position('T6G4A-ref' in pg_temp.res('m_a')) = 0 and position('T6G4A-idem' in pg_temp.res('m_a')) = 0
                  and position('declined' in pg_temp.res('m_a')) = 0 and position('t6g4a-x' in pg_temp.res('m_a')) = 0, 'customer payload contains none of the hidden values');
select pg_temp.ok(pg_temp.state('m_a_b') = 'P0001' and pg_temp.det('m_a_b') = 'order_not_found', 'customer A asking for B''s order -> order_not_found');
select pg_temp.ok(pg_temp.state('m_b_a') = 'P0001' and pg_temp.det('m_b_a') = 'order_not_found', 'customer B asking for A''s order -> order_not_found');
select pg_temp.ok(pg_temp.state('m_ghost') = 'P0001' and pg_temp.det('m_ghost') = 'order_not_found'
                  and pg_temp.msg('m_ghost') = pg_temp.msg('m_a_b'), 'non-existent order gives the identical error as someone else''s order');
select pg_temp.ok(pg_temp.state('m_null') = 'P0001' and pg_temp.det('m_null') = 'order_not_found', 'null order id -> order_not_found');
select pg_temp.ok(jsonb_array_length(pg_temp.j('m_b')->'transactions') = 1, 'customer B sees own single row');
select pg_temp.ok(pg_temp.state('m_admin') = 'P0001' and pg_temp.det('m_admin') = 'order_not_found', 'even an admin only gets their own orders here');

-- ---------------------------------------------------------------- no writes happened
select pg_temp.ok((select count(*) from public.payment_transactions where provider like 't6g4a-%') = 126, 'read functions wrote nothing (126 fixture rows unchanged)');

rollback;
