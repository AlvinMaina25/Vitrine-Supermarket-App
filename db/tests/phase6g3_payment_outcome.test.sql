-- Phase 6G.3 test: apply_payment_outcome / record_cod_payment / create_payment_attempt COD refusal. NOT RUN.
-- Needs migrations up to 20261005060000 applied, and the seeded delivery method 'standard'.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6G3' (provider 't6g3'); existing rows are never assumed absent.
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

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a030000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.cpa(k text, ord uuid, meth text, idem text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format(
    'select public.create_payment_attempt(%L::uuid, %L, %L::public.payment_method, %L)::text', ord, 't6g3', meth, idem));
end $$;

-- apply outcome as service_role
create or replace function pg_temp.apo(k text, txn uuid, outcome text, ref text, amt integer, cur text,
                                       code text, msg text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format(
    'select public.apply_payment_outcome(%L::uuid, %L::public.payment_transaction_status, %L, %L::integer, %L, %L, %L)::text',
    txn, outcome, ref, amt, cur, code, msg));
end $$;

create or replace function pg_temp.cod(k text, r text, uid uuid, ord uuid, reason text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, format('select public.record_cod_payment(%L::uuid, %L)::text', ord, reason));
end $$;

create or replace function pg_temp.audits(ord uuid, act text) returns integer language sql as $$
  select count(*)::integer from public.admin_audit_log where target_id = ord and action = act $$;
create or replace function pg_temp.txn_of(k text) returns uuid language sql as $$
  select (pg_temp.j(k) -> 'transaction' ->> 'id')::uuid $$;
create or replace function pg_temp.ord(id uuid) returns public.orders language sql as $$
  select o from public.orders o where o.id = ord.id $$;

-- Fixtures: 1 customer, 2 staff, 3 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g3-cust@example.test',  'authenticated', 'authenticated', '{"full_name":"T6G3 Customer"}'),
  (pg_temp.u(2), 't6g3-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G3 Staff"}'),
  (pg_temp.u(3), 't6g3-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G3 Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(2), 'staff'), (pg_temp.u(3), 'admin');

insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(101), pg_temp.u(1), 'T6G3-OK',      'mpesa', 'standard', 12345, 12345, 'awaiting_payment', 'pending'),
  (pg_temp.u(102), pg_temp.u(1), 'T6G3-RETRY',   'mpesa', 'standard',  5000,  5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(103), pg_temp.u(1), 'T6G3-AMT',     'mpesa', 'standard',  5000,  5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(104), pg_temp.u(1), 'T6G3-CUR',     'mpesa', 'standard',  5000,  5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(105), pg_temp.u(1), 'T6G3-MULTI',   'mpesa', 'standard',  3000,  3000, 'awaiting_payment', 'pending'),
  (pg_temp.u(106), pg_temp.u(1), 'T6G3-CANCEL',  'mpesa', 'standard',  5000,  5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(107), pg_temp.u(1), 'T6G3-TRUNC',   'mpesa', 'standard',  5000,  5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(201), pg_temp.u(1), 'T6G3-COD-OFD', 'cash_on_delivery', 'standard', 2500, 2500, 'out_for_delivery', 'pending'),
  (pg_temp.u(202), pg_temp.u(1), 'T6G3-COD-PEND','cash_on_delivery', 'standard', 2500, 2500, 'pending',          'pending'),
  (pg_temp.u(203), pg_temp.u(1), 'T6G3-COD-CANC','cash_on_delivery', 'standard', 2500, 2500, 'cancelled',        'pending'),
  (pg_temp.u(204), pg_temp.u(1), 'T6G3-COD-PAID','cash_on_delivery', 'standard', 2500, 2500, 'delivered',        'paid'),
  (pg_temp.u(205), pg_temp.u(1), 'T6G3-NOT-COD', 'mpesa',            'standard', 2500, 2500, 'out_for_delivery', 'pending'),
  (pg_temp.u(206), pg_temp.u(1), 'T6G3-COD-DLV', 'cash_on_delivery', 'standard', 1800, 1800, 'delivered',        'pending');

-- ------------------------------------------------------------ success
select pg_temp.cpa('a101', pg_temp.u(101), 'mpesa', 'T6G3-k101');
select pg_temp.apo('s101', pg_temp.txn_of('a101'), 'succeeded', 'T6G3-R101', 12345, 'KES', null, null);
select pg_temp.ok((pg_temp.j('s101') ->> 'changed')::boolean is true
                  and pg_temp.j('s101') -> 'transaction' ->> 'status' = 'succeeded'
                  and pg_temp.j('s101') -> 'transaction' ->> 'provider_reference' = 'T6G3-R101'
                  and pg_temp.j('s101') -> 'transaction' ->> 'completed_at' is not null,
                  'success: transaction succeeded, reference and completed_at set');
select pg_temp.ok((pg_temp.ord(pg_temp.u(101))).payment_status = 'paid', 'success: orders.payment_status = paid');
select pg_temp.ok((pg_temp.ord(pg_temp.u(101))).status = 'awaiting_payment',
                  'success: orders.status untouched (set_order_status() allows no legal advance here)');
select pg_temp.ok(pg_temp.audits(pg_temp.u(101), 'payment_succeeded') = 1, 'success: one audit row');

-- replay
select pg_temp.apo('s101r', pg_temp.txn_of('a101'), 'succeeded', 'T6G3-R101', 12345, 'KES', null, null);
select pg_temp.ok((pg_temp.j('s101r') ->> 'changed')::boolean is false, 'replay: changed = false');
select pg_temp.ok(pg_temp.audits(pg_temp.u(101), 'payment_succeeded') = 1, 'replay: no new audit row');
select pg_temp.ok((select count(*) = 1 from public.payment_transactions where order_id = pg_temp.u(101)), 'replay: no new transaction');

-- no downgrade of a succeeded transaction
select pg_temp.apo('d101', pg_temp.txn_of('a101'), 'failed', null, null, null, 'late', 'late failure');
select pg_temp.apo('d101c', pg_temp.txn_of('a101'), 'cancelled', null, null, null, null, null);
select pg_temp.apo('d101e', pg_temp.txn_of('a101'), 'expired', null, null, null, null, null);
select pg_temp.ok(pg_temp.err('d101') = 'P0001/invalid_transition' and pg_temp.err('d101c') = 'P0001/invalid_transition'
                  and pg_temp.err('d101e') = 'P0001/invalid_transition', 'succeeded is never downgraded');
select pg_temp.ok((select status = 'succeeded' from public.payment_transactions where id = pg_temp.txn_of('a101'))
                  and (pg_temp.ord(pg_temp.u(101))).payment_status = 'paid', 'downgrade attempts changed nothing');

-- ------------------------------------------------------------ failure, new attempt, success
select pg_temp.cpa('a102', pg_temp.u(102), 'mpesa', 'T6G3-k102a');
select pg_temp.apo('f102', pg_temp.txn_of('a102'), 'failed', null, null, null, 'insufficient_funds', 'Customer had insufficient funds');
select pg_temp.ok((pg_temp.j('f102') ->> 'changed')::boolean is true
                  and pg_temp.j('f102') -> 'transaction' ->> 'status' = 'failed'
                  and pg_temp.j('f102') -> 'transaction' ->> 'failure_code' = 'insufficient_funds',
                  'failure: transaction failed with code');
select pg_temp.ok((pg_temp.ord(pg_temp.u(102))).payment_status = 'pending' and (pg_temp.ord(pg_temp.u(102))).status = 'awaiting_payment',
                  'failure: order stays recoverable (awaiting_payment, not paid)');
select pg_temp.ok(pg_temp.audits(pg_temp.u(102), 'payment_failed') = 1, 'failure: one audit row');
select pg_temp.apo('f102r', pg_temp.txn_of('a102'), 'failed', null, null, null, 'insufficient_funds', 'Customer had insufficient funds');
select pg_temp.ok((pg_temp.j('f102r') ->> 'changed')::boolean is false and pg_temp.audits(pg_temp.u(102), 'payment_failed') = 1,
                  'failure replay: changed = false, no audit row');
select pg_temp.apo('f102x', pg_temp.txn_of('a102'), 'succeeded', null, 5000, 'KES', null, null);
select pg_temp.ok(pg_temp.err('f102x') = 'P0001/invalid_transition', 'a failed transaction cannot later succeed');
select pg_temp.cpa('a102b', pg_temp.u(102), 'mpesa', 'T6G3-k102b');
select pg_temp.ok((pg_temp.j('a102b') ->> 'changed')::boolean is true, 'new attempt allowed after a failure');
select pg_temp.apo('s102', pg_temp.txn_of('a102b'), 'succeeded', 'T6G3-R102', 5000, 'KES', null, null);
select pg_temp.ok((pg_temp.ord(pg_temp.u(102))).payment_status = 'paid' and pg_temp.audits(pg_temp.u(102), 'payment_succeeded') = 1,
                  'second attempt succeeds: order paid, audit row written');

-- cancelled / expired leave the order recoverable
select pg_temp.cpa('a107c', pg_temp.u(107), 'mpesa', 'T6G3-k107c');
select pg_temp.apo('c107', pg_temp.txn_of('a107c'), 'cancelled', null, null, null, null, null);
select pg_temp.cpa('a107e', pg_temp.u(107), 'mpesa', 'T6G3-k107e');
select pg_temp.apo('e107', pg_temp.txn_of('a107e'), 'expired', null, null, null, null, null);
select pg_temp.ok(pg_temp.j('c107') -> 'transaction' ->> 'status' = 'cancelled' and pg_temp.j('e107') -> 'transaction' ->> 'status' = 'expired'
                  and (pg_temp.ord(pg_temp.u(107))).payment_status = 'pending' and (pg_temp.ord(pg_temp.u(107))).status = 'awaiting_payment',
                  'cancelled/expired: order untouched and still payable');

-- ------------------------------------------------------------ amount / currency mismatch
select pg_temp.cpa('a103', pg_temp.u(103), 'mpesa', 'T6G3-k103');
select pg_temp.apo('m103', pg_temp.txn_of('a103'), 'succeeded', 'T6G3-R103', 4999, 'KES', null, null);
select pg_temp.ok((pg_temp.j('m103') ->> 'changed')::boolean is true and pg_temp.j('m103') ->> 'rejected' = 'amount_mismatch'
                  and pg_temp.j('m103') -> 'transaction' ->> 'status' = 'failed'
                  and pg_temp.j('m103') -> 'transaction' ->> 'failure_code' = 'amount_mismatch',
                  'amount mismatch: transaction stored as failed / amount_mismatch');
select pg_temp.ok((pg_temp.ord(pg_temp.u(103))).payment_status = 'pending' and (pg_temp.ord(pg_temp.u(103))).status = 'awaiting_payment',
                  'amount mismatch: order not paid');
select pg_temp.ok(pg_temp.audits(pg_temp.u(103), 'payment_amount_mismatch') = 1, 'amount mismatch: one audit row');
select pg_temp.apo('m103r', pg_temp.txn_of('a103'), 'succeeded', 'T6G3-R103', 4999, 'KES', null, null);
select pg_temp.ok(pg_temp.err('m103r') = 'P0001/invalid_transition', 'amount mismatch: the rejected transaction cannot be resurrected');

select pg_temp.cpa('a104', pg_temp.u(104), 'mpesa', 'T6G3-k104');
select pg_temp.apo('m104', pg_temp.txn_of('a104'), 'succeeded', 'T6G3-R104', 5000, 'USD', null, null);
select pg_temp.ok(pg_temp.j('m104') ->> 'rejected' = 'currency_mismatch'
                  and pg_temp.j('m104') -> 'transaction' ->> 'status' = 'failed'
                  and pg_temp.j('m104') -> 'transaction' ->> 'failure_code' = 'currency_mismatch'
                  and (pg_temp.ord(pg_temp.u(104))).payment_status = 'pending'
                  and pg_temp.audits(pg_temp.u(104), 'payment_currency_mismatch') = 1,
                  'currency mismatch: failed / currency_mismatch, order not paid, audit row');

-- ------------------------------------------------------------ first success wins
select pg_temp.cpa('a105a', pg_temp.u(105), 'mpesa', 'T6G3-k105a');
select pg_temp.cpa('a105b', pg_temp.u(105), 'card',  'T6G3-k105b');
select pg_temp.apo('w105a', pg_temp.txn_of('a105a'), 'succeeded', 'T6G3-R105A', 3000, 'KES', null, null);
select pg_temp.apo('w105b', pg_temp.txn_of('a105b'), 'succeeded', 'T6G3-R105B', 3000, 'KES', null, null);
select pg_temp.ok((pg_temp.j('w105a') ->> 'changed')::boolean is true, 'first success wins');
select pg_temp.ok(pg_temp.err('w105b') = 'P0001/order_already_paid', 'second success on an already-paid order refused');
select pg_temp.ok((select status = 'pending' and provider_reference is null from public.payment_transactions where id = pg_temp.txn_of('a105b'))
                  and pg_temp.audits(pg_temp.u(105), 'payment_succeeded') = 1,
                  'refused second success changed nothing');

-- ------------------------------------------------------------ cancelled order
select pg_temp.cpa('a106', pg_temp.u(106), 'mpesa', 'T6G3-k106');
update public.orders set status = 'cancelled' where id = pg_temp.u(106);
select pg_temp.apo('x106', pg_temp.txn_of('a106'), 'succeeded', 'T6G3-R106', 5000, 'KES', null, null);
select pg_temp.ok(pg_temp.err('x106') = 'P0001/order_not_payable', 'cancelled order: success refused');
select pg_temp.ok((select status = 'pending' from public.payment_transactions where id = pg_temp.txn_of('a106'))
                  and (pg_temp.ord(pg_temp.u(106))).payment_status = 'pending', 'cancelled order: nothing changed');

-- ------------------------------------------------------------ sanitising, arguments
select pg_temp.cpa('a107t', pg_temp.u(107), 'mpesa', 'T6G3-k107t');
select pg_temp.apo('t107', pg_temp.txn_of('a107t'), 'failed', null, null, null, repeat('c', 200),
                   repeat('x', 1000) || E'\n' || 'tail');
select pg_temp.ok(char_length(pg_temp.j('t107') -> 'transaction' ->> 'failure_message') = 300
                  and char_length(pg_temp.j('t107') -> 'transaction' ->> 'failure_code') = 80,
                  'failure_message capped at 300 and failure_code at 80');
select pg_temp.ok((select char_length(reason) <= 500 from public.admin_audit_log
                    where target_id = pg_temp.u(107) and action = 'payment_failed'), 'audit reason within its 500 limit');
select pg_temp.apo('i_pend', pg_temp.txn_of('a107t'), 'pending', null, null, null, null, null);
select pg_temp.apo('i_proc', pg_temp.txn_of('a107t'), 'processing', null, null, null, null, null);
select pg_temp.apo('i_null', null, 'failed', null, null, null, null, null);
select pg_temp.apo('i_nf',   pg_temp.u(999), 'failed', null, null, null, null, null);
select pg_temp.cpa('a107n', pg_temp.u(107), 'mpesa', 'T6G3-k107n');
select pg_temp.apo('i_noamt', pg_temp.txn_of('a107n'), 'succeeded', null, null, 'KES', null, null);
select pg_temp.apo('i_nocur', pg_temp.txn_of('a107n'), 'succeeded', null, 5000, null, null, null);
select pg_temp.apo('i_ref',   pg_temp.txn_of('a107n'), 'failed', repeat('r', 201), null, null, null, null);
select pg_temp.ok(pg_temp.err('i_pend') = 'P0001/invalid_arguments' and pg_temp.err('i_proc') = 'P0001/invalid_arguments'
                  and pg_temp.err('i_null') = 'P0001/invalid_arguments' and pg_temp.err('i_noamt') = 'P0001/invalid_arguments'
                  and pg_temp.err('i_nocur') = 'P0001/invalid_arguments', 'invalid outcome / missing arguments refused');
select pg_temp.ok(pg_temp.err('i_nf') = 'P0001/transaction_not_found' and pg_temp.err('i_ref') = 'P0001/invalid_reference',
                  'unknown transaction and over-long reference refused');

-- ------------------------------------------------------------ create_payment_attempt refuses COD
select pg_temp.cpa('cpa_cod', pg_temp.u(202), 'cash_on_delivery', 'T6G3-kcod');
select pg_temp.ok(pg_temp.err('cpa_cod') = 'P0001/method_not_supported', 'create_payment_attempt refuses cash_on_delivery');
select pg_temp.ok((select count(*) = 0 from public.payment_transactions where idempotency_key = 'T6G3-kcod'), 'COD attempt created nothing');

-- ------------------------------------------------------------ record_cod_payment
select pg_temp.cod('cod1', 'authenticated', pg_temp.u(3), pg_temp.u(201), 'Cash collected by rider');
select pg_temp.ok((pg_temp.j('cod1') ->> 'changed')::boolean is true
                  and pg_temp.j('cod1') -> 'transaction' ->> 'provider' = 'cod'
                  and pg_temp.j('cod1') -> 'transaction' ->> 'method' = 'cash_on_delivery'
                  and pg_temp.j('cod1') -> 'transaction' ->> 'status' = 'succeeded'
                  and (pg_temp.j('cod1') -> 'transaction' ->> 'amount_cents')::integer = 2500
                  and pg_temp.j('cod1') -> 'transaction' ->> 'currency' = 'KES',
                  'COD: settled cod / cash_on_delivery transaction, amount from the order');
select pg_temp.ok((pg_temp.ord(pg_temp.u(201))).payment_status = 'paid' and (pg_temp.ord(pg_temp.u(201))).status = 'out_for_delivery',
                  'COD: payment_status paid, order status unchanged');
select pg_temp.ok((select count(*) = 1 from public.admin_audit_log
                    where target_id = pg_temp.u(201) and action = 'cod_payment_recorded' and actor_id = pg_temp.u(3)),
                  'COD: one audit row naming the admin');
select pg_temp.cod('cod1r', 'authenticated', pg_temp.u(3), pg_temp.u(201), 'Cash collected by rider');
select pg_temp.ok((pg_temp.j('cod1r') ->> 'changed')::boolean is false
                  and (select count(*) = 1 from public.payment_transactions where order_id = pg_temp.u(201))
                  and pg_temp.audits(pg_temp.u(201), 'cod_payment_recorded') = 1, 'COD replay: changed = false, nothing written');
select pg_temp.cod('cod6', 'authenticated', pg_temp.u(3), pg_temp.u(206), 'Cash collected at the door');
select pg_temp.ok((pg_temp.j('cod6') ->> 'changed')::boolean is true and (pg_temp.ord(pg_temp.u(206))).status = 'delivered',
                  'COD: delivered order accepted');

select pg_temp.cod('cod_notcod', 'authenticated', pg_temp.u(3), pg_temp.u(205), 'Cash collected');
select pg_temp.cod('cod_pend',   'authenticated', pg_temp.u(3), pg_temp.u(202), 'Cash collected');
select pg_temp.cod('cod_canc',   'authenticated', pg_temp.u(3), pg_temp.u(203), 'Cash collected');
select pg_temp.cod('cod_paid',   'authenticated', pg_temp.u(3), pg_temp.u(204), 'Cash collected');
select pg_temp.cod('cod_nf',     'authenticated', pg_temp.u(3), pg_temp.u(999), 'Cash collected');
select pg_temp.cod('cod_reason', 'authenticated', pg_temp.u(3), pg_temp.u(202), ' x ');
select pg_temp.ok(pg_temp.err('cod_notcod') = 'P0001/not_cash_on_delivery', 'COD: non-COD order refused (wrong method)');
select pg_temp.ok(pg_temp.err('cod_pend')   = 'P0001/order_status_not_allowed', 'COD: order not out for delivery/delivered refused');
select pg_temp.ok(pg_temp.err('cod_canc')   = 'P0001/order_not_payable', 'COD: cancelled order refused');
select pg_temp.ok(pg_temp.err('cod_paid')   = 'P0001/order_already_paid', 'COD: already-paid order refused');
select pg_temp.ok(pg_temp.err('cod_nf')     = 'P0001/order_not_found', 'COD: unknown order refused');
select pg_temp.ok(pg_temp.err('cod_reason') = 'P0001/invalid_arguments', 'COD: reason too short refused');
select pg_temp.ok((select count(*) = 0 from public.payment_transactions where order_id in (pg_temp.u(202), pg_temp.u(203), pg_temp.u(204), pg_temp.u(205))),
                  'COD refusals created no transaction');

-- ------------------------------------------------------------ privileges
do $t$
declare c record;
begin
  for c in select * from (values
      ('anon', 'anon', null::uuid), ('cust', 'authenticated', pg_temp.u(1)),
      ('staff', 'authenticated', pg_temp.u(2)), ('admin', 'authenticated', pg_temp.u(3))) as x(tag, r, uid) loop
    perform pg_temp.run('d_apo_' || c.tag, c.r, c.uid, format(
      'select public.apply_payment_outcome(%L::uuid, ''failed''::public.payment_transaction_status, null, null, null, null, null)::text',
      pg_temp.u(999)));
    perform pg_temp.ok(exists (select 1 from t_res where k = 'd_apo_' || c.tag and state = '42501'),
                       c.tag || ': EXECUTE denied on apply_payment_outcome');
  end loop;
end $t$;

select pg_temp.cod('d_cod_anon',  'anon',          null,         pg_temp.u(202), 'Cash collected');
select pg_temp.cod('d_cod_cust',  'authenticated', pg_temp.u(1), pg_temp.u(202), 'Cash collected');
select pg_temp.cod('d_cod_staff', 'authenticated', pg_temp.u(2), pg_temp.u(202), 'Cash collected');
select pg_temp.cod('d_cod_svc',   'service_role',  null,         pg_temp.u(202), 'Cash collected');
select pg_temp.ok((select state = '42501' from t_res where k = 'd_cod_anon'), 'anon: record_cod_payment denied');
select pg_temp.ok(pg_temp.err('d_cod_cust')  = '42501/not_authorised', 'customer: record_cod_payment denied (not admin)');
select pg_temp.ok(pg_temp.err('d_cod_staff') = '42501/not_authorised', 'staff: record_cod_payment denied (not admin)');
select pg_temp.ok((select state = '42501' from t_res where k = 'd_cod_svc'), 'service_role: record_cod_payment denied');
select pg_temp.ok((select count(*) = 0 from public.payment_transactions where order_id = pg_temp.u(202)),
                  'denied callers created nothing');

select pg_temp.ok(
  not exists (select 1 from (values ('anon'), ('authenticated')) r(role),
              (values ('public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)'),
                      ('public.create_payment_attempt(uuid,text,public.payment_method,text)')) f(sig)
              where has_function_privilege(r.role, f.sig, 'EXECUTE'))
  and has_function_privilege('service_role', 'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.create_payment_attempt(uuid,text,public.payment_method,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.record_cod_payment(uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.record_cod_payment(uuid,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.record_cod_payment(uuid,text)', 'EXECUTE'),
  'catalogue: apply_payment_outcome and create_payment_attempt service_role only; record_cod_payment authenticated only');

rollback;
