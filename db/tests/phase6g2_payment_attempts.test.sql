-- Phase 6G.2 test: get_order_for_payment / create_payment_attempt / mark_payment_processing. NOT RUN.
-- Needs migrations up to 20261005050000 applied, and the seeded delivery method 'standard'.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6G2' (provider 't6g2'); existing rows are never assumed absent.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

-- run q as database role r with JWT subject uid; q returns one text value. Result or error stored under k.
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

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a020000' || lpad(n::text, 4, '0'))::uuid $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

-- service_role helpers
create or replace function pg_temp.cpa(k text, ord uuid, prov text, meth text, idem text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format(
    'select public.create_payment_attempt(%L::uuid, %L, %L::public.payment_method, %L)::text', ord, prov, meth, idem));
end $$;

create or replace function pg_temp.mpp(k text, txn uuid, ref text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format('select public.mark_payment_processing(%L::uuid, %L)::text', txn, ref));
end $$;

-- Fixtures: 1 customer, 2 staff, 3 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g2-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6G2 Customer"}'),
  (pg_temp.u(2), 't6g2-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G2 Staff"}'),
  (pg_temp.u(3), 't6g2-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G2 Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

-- Orders (money in cents; total = subtotal as no fee/discount)
insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(101), pg_temp.u(1), 'T6G2-OK',        'mpesa', 'standard', 12345, 12345, 'awaiting_payment', 'pending'),
  (pg_temp.u(102), pg_temp.u(1), 'T6G2-OTHER',     'mpesa', 'standard',   777,   777, 'awaiting_payment', 'pending'),
  (pg_temp.u(103), pg_temp.u(1), 'T6G2-CANCELLED', 'mpesa', 'standard',  5000,  5000, 'cancelled',        'pending'),
  (pg_temp.u(104), pg_temp.u(1), 'T6G2-REFUNDED',  'mpesa', 'standard',  5000,  5000, 'refunded',         'refunded'),
  (pg_temp.u(105), pg_temp.u(1), 'T6G2-PAID',      'mpesa', 'standard',  5000,  5000, 'processing',       'paid'),
  (pg_temp.u(106), pg_temp.u(1), 'T6G2-STATPAID',  'mpesa', 'standard',  5000,  5000, 'paid',             'pending');

-- Baseline of the order rows, to prove the functions never touch orders
create temp table t_orders_before as
  select id, status, payment_status, total_cents, updated_at from public.orders where order_number like 'T6G2-%';

-- ------------------------------------------------------------ get_order_for_payment
select pg_temp.run('go_ok', 'service_role', null, format('select public.get_order_for_payment(%L::uuid)::text', pg_temp.u(101)));
select pg_temp.run('go_nf', 'service_role', null, format('select public.get_order_for_payment(%L::uuid)::text', pg_temp.u(999)));
select pg_temp.run('go_nul', 'service_role', null, 'select public.get_order_for_payment(null::uuid)::text');

select pg_temp.ok(pg_temp.j('go_ok') = jsonb_build_object('id', pg_temp.u(101), 'total_cents', 12345, 'currency', 'KES',
                                                         'status', 'awaiting_payment', 'payment_status', 'pending'),
                  'get_order_for_payment returns id, total_cents, currency, status, payment_status');
select pg_temp.ok(pg_temp.err('go_nf')  = 'P0001/order_not_found',    'get_order_for_payment: unknown order refused');
select pg_temp.ok(pg_temp.err('go_nul') = 'P0001/invalid_arguments',  'get_order_for_payment: null order refused');

-- ------------------------------------------------------------ create_payment_attempt: happy path
select pg_temp.cpa('c_ok', pg_temp.u(101), 't6g2', 'mpesa', 'T6G2-key-1');
select pg_temp.ok((pg_temp.j('c_ok') ->> 'changed')::boolean is true, 'happy path: changed = true');
select pg_temp.ok(pg_temp.j('c_ok') -> 'transaction' ->> 'status' = 'pending'
                  and pg_temp.j('c_ok') -> 'transaction' ->> 'provider' = 't6g2'
                  and pg_temp.j('c_ok') -> 'transaction' ->> 'method' = 'mpesa'
                  and pg_temp.j('c_ok') -> 'transaction' ->> 'idempotency_key' = 'T6G2-key-1'
                  and (pg_temp.j('c_ok') -> 'transaction' ->> 'order_id')::uuid = pg_temp.u(101),
                  'happy path: pending attempt for the order');
select pg_temp.ok((pg_temp.j('c_ok') -> 'transaction' ->> 'amount_cents')::integer = 12345
                  and pg_temp.j('c_ok') -> 'transaction' ->> 'currency' = 'KES',
                  'amount and currency come from the order in the database');
select pg_temp.ok((select count(*) = 1 from public.payment_transactions where idempotency_key = 'T6G2-key-1'),
                  'happy path: exactly one row stored');

-- amount is not a parameter, and a different order yields its own amount
select pg_temp.ok(not exists (select 1 from pg_proc p
                              where p.proname = 'create_payment_attempt' and p.pronamespace = 'public'::regnamespace
                                and (select bool_or(a ilike '%amount%') from unnest(coalesce(p.proargnames, '{}')) a)),
                  'create_payment_attempt has no amount parameter');
select pg_temp.cpa('c_other', pg_temp.u(102), 't6g2', 'mpesa', 'T6G2-key-2');
select pg_temp.ok((pg_temp.j('c_other') -> 'transaction' ->> 'amount_cents')::integer = 777, 'amount follows the order total (777)');

-- ------------------------------------------------------------ replay and conflicting replay
select pg_temp.cpa('c_replay', pg_temp.u(101), 't6g2', 'mpesa', 'T6G2-key-1');
select pg_temp.ok((pg_temp.j('c_replay') ->> 'changed')::boolean is false
                  and pg_temp.j('c_replay') -> 'transaction' ->> 'id' = pg_temp.j('c_ok') -> 'transaction' ->> 'id',
                  'replay: same key returns the existing row, changed = false');
select pg_temp.ok((select count(*) = 1 from public.payment_transactions where idempotency_key = 'T6G2-key-1'),
                  'replay: no second row');

select pg_temp.cpa('c_cf_order', pg_temp.u(102), 't6g2',       'mpesa', 'T6G2-key-1');
select pg_temp.cpa('c_cf_prov',  pg_temp.u(101), 't6g2-other', 'mpesa', 'T6G2-key-1');
select pg_temp.cpa('c_cf_meth',  pg_temp.u(101), 't6g2',       'card',  'T6G2-key-1');
select pg_temp.ok(pg_temp.err('c_cf_order') = 'P0001/idempotency_key_conflict', 'same key, different order refused');
select pg_temp.ok(pg_temp.err('c_cf_prov')  = 'P0001/idempotency_key_conflict', 'same key, different provider refused');
select pg_temp.ok(pg_temp.err('c_cf_meth')  = 'P0001/idempotency_key_conflict', 'same key, different method refused');

-- ------------------------------------------------------------ order states and arguments
select pg_temp.cpa('c_cancel', pg_temp.u(103), 't6g2', 'mpesa', 'T6G2-key-cancel');
select pg_temp.cpa('c_refund', pg_temp.u(104), 't6g2', 'mpesa', 'T6G2-key-refund');
select pg_temp.cpa('c_paid',   pg_temp.u(105), 't6g2', 'mpesa', 'T6G2-key-paid');
select pg_temp.cpa('c_spaid',  pg_temp.u(106), 't6g2', 'mpesa', 'T6G2-key-statpaid');
select pg_temp.cpa('c_nf',     pg_temp.u(999), 't6g2', 'mpesa', 'T6G2-key-nf');
select pg_temp.cpa('c_noprov', pg_temp.u(101), '   ',  'mpesa', 'T6G2-key-noprov');
select pg_temp.cpa('c_nokey',  pg_temp.u(101), 't6g2', 'mpesa', '');
select pg_temp.ok(pg_temp.err('c_cancel') = 'P0001/order_not_payable',   'cancelled order refused');
select pg_temp.ok(pg_temp.err('c_refund') = 'P0001/order_not_payable',   'refunded order refused');
select pg_temp.ok(pg_temp.err('c_paid')   = 'P0001/order_already_paid',  'order with payment_status paid refused');
select pg_temp.ok(pg_temp.err('c_spaid')  = 'P0001/order_already_paid',  'order with status paid refused');
select pg_temp.ok(pg_temp.err('c_nf')     = 'P0001/order_not_found',     'unknown order refused');
select pg_temp.ok(pg_temp.err('c_noprov') = 'P0001/invalid_arguments',   'blank provider refused');
select pg_temp.ok(pg_temp.err('c_nokey')  = 'P0001/invalid_arguments',   'blank idempotency key refused');
select pg_temp.ok((select count(*) = 0 from public.payment_transactions
                   where idempotency_key in ('T6G2-key-cancel','T6G2-key-refund','T6G2-key-paid','T6G2-key-statpaid',
                                             'T6G2-key-nf','T6G2-key-noprov')),
                  'refused requests stored nothing');

-- ------------------------------------------------------------ mark_payment_processing
create temp table t_ids as select (pg_temp.j('c_ok') -> 'transaction' ->> 'id')::uuid as txn,
                                  (pg_temp.j('c_other') -> 'transaction' ->> 'id')::uuid as txn2;

select pg_temp.mpp('m_ok', (select txn from t_ids), 'T6G2-REF-1');
select pg_temp.ok((pg_temp.j('m_ok') ->> 'changed')::boolean is true
                  and pg_temp.j('m_ok') -> 'transaction' ->> 'status' = 'processing'
                  and pg_temp.j('m_ok') -> 'transaction' ->> 'provider_reference' = 'T6G2-REF-1',
                  'pending -> processing, reference stored, changed = true');
select pg_temp.mpp('m_replay', (select txn from t_ids), 'T6G2-REF-1');
select pg_temp.ok((pg_temp.j('m_replay') ->> 'changed')::boolean is false
                  and pg_temp.j('m_replay') -> 'transaction' ->> 'status' = 'processing',
                  'same reference again: idempotent, changed = false');
select pg_temp.mpp('m_diffref', (select txn from t_ids), 'T6G2-REF-OTHER');
select pg_temp.ok(pg_temp.err('m_diffref') = 'P0001/reference_conflict', 'processing with a different reference refused');
select pg_temp.mpp('m_inuse', (select txn2 from t_ids), 'T6G2-REF-1');
select pg_temp.ok(pg_temp.err('m_inuse') = 'P0001/provider_reference_in_use', 'reference already used by another transaction refused');
select pg_temp.ok((select status = 'pending' and provider_reference is null from public.payment_transactions
                   where id = (select txn2 from t_ids)), 'failed attempt left the other transaction unchanged');
select pg_temp.mpp('m_nf', pg_temp.u(998), 'T6G2-REF-X');
select pg_temp.ok(pg_temp.err('m_nf') = 'P0001/transaction_not_found', 'unknown transaction refused');
select pg_temp.mpp('m_blank', (select txn2 from t_ids), '  ');
select pg_temp.ok(pg_temp.err('m_blank') = 'P0001/invalid_reference', 'blank reference refused');

-- illegal transitions: every state other than pending/processing is refused (rows set up by the owner)
insert into public.payment_transactions (id, order_id, provider, method, amount_cents, idempotency_key, status) values
  (pg_temp.u(301), pg_temp.u(101), 't6g2', 'mpesa', 100, 'T6G2-st-succeeded', 'succeeded'),
  (pg_temp.u(302), pg_temp.u(101), 't6g2', 'mpesa', 100, 'T6G2-st-failed',    'failed'),
  (pg_temp.u(303), pg_temp.u(101), 't6g2', 'mpesa', 100, 'T6G2-st-cancelled', 'cancelled'),
  (pg_temp.u(304), pg_temp.u(101), 't6g2', 'mpesa', 100, 'T6G2-st-expired',   'expired');
select pg_temp.mpp('i_succ', pg_temp.u(301), 'T6G2-REF-S');
select pg_temp.mpp('i_fail', pg_temp.u(302), 'T6G2-REF-F');
select pg_temp.mpp('i_canc', pg_temp.u(303), 'T6G2-REF-C');
select pg_temp.mpp('i_exp',  pg_temp.u(304), 'T6G2-REF-E');
select pg_temp.ok(pg_temp.err('i_succ') = 'P0001/invalid_transition', 'succeeded -> processing refused');
select pg_temp.ok(pg_temp.err('i_fail') = 'P0001/invalid_transition', 'failed -> processing refused');
select pg_temp.ok(pg_temp.err('i_canc') = 'P0001/invalid_transition', 'cancelled -> processing refused');
select pg_temp.ok(pg_temp.err('i_exp')  = 'P0001/invalid_transition', 'expired -> processing refused');
select pg_temp.ok((select count(*) = 4 and bool_and(provider_reference is null) from public.payment_transactions
                   where id in (pg_temp.u(301), pg_temp.u(302), pg_temp.u(303), pg_temp.u(304))),
                  'illegal transitions changed nothing');

-- ------------------------------------------------------------ orders untouched by every function above
select pg_temp.ok(not exists (
  select 1 from public.orders o join t_orders_before b on b.id = o.id
  where o.status <> b.status or o.payment_status <> b.payment_status
     or o.total_cents <> b.total_cents or o.updated_at <> b.updated_at),
  'orders (status, payment_status, total, updated_at) unchanged');

-- ------------------------------------------------------------ EXECUTE denied: anon / customer / staff / admin
do $t$
declare
  c record;
  f record;
begin
  for c in select * from (values
      ('anon',  'anon',          null::uuid),
      ('cust',  'authenticated', pg_temp.u(1)),
      ('staff', 'authenticated', pg_temp.u(2)),
      ('admin', 'authenticated', pg_temp.u(3))) as x(tag, r, uid) loop
    for f in select * from (values
        ('get',  format('select public.get_order_for_payment(%L::uuid)::text', pg_temp.u(101))),
        ('cpa',  format('select public.create_payment_attempt(%L::uuid, %L, %L::public.payment_method, %L)::text',
                        pg_temp.u(101), 't6g2', 'mpesa', 'T6G2-denied-' || c.tag)),
        ('mpp',  format('select public.mark_payment_processing(%L::uuid, %L)::text', pg_temp.u(302), 'T6G2-REF-D'))) as y(fn, q) loop
      perform pg_temp.run('d_' || c.tag || '_' || f.fn, c.r, c.uid, f.q);
      perform pg_temp.ok(exists (select 1 from t_res where k = 'd_' || c.tag || '_' || f.fn and state = '42501'),
                         c.tag || ': EXECUTE denied on ' || f.fn);
    end loop;
  end loop;
end $t$;

select pg_temp.ok((select count(*) = 0 from public.payment_transactions where idempotency_key like 'T6G2-denied-%'),
                  'denied callers created nothing');

-- catalogue view of the same fact
select pg_temp.ok(not exists (
  select 1 from (values ('anon'), ('authenticated')) r(role),
                (values ('public.get_order_for_payment(uuid)'),
                        ('public.create_payment_attempt(uuid,text,public.payment_method,text)'),
                        ('public.mark_payment_processing(uuid,text)')) f(sig)
  where has_function_privilege(r.role, f.sig, 'EXECUTE'))
  and has_function_privilege('service_role', 'public.get_order_for_payment(uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.create_payment_attempt(uuid,text,public.payment_method,text)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.mark_payment_processing(uuid,text)', 'EXECUTE'),
  'only service_role holds EXECUTE (catalogue check)');

rollback;
