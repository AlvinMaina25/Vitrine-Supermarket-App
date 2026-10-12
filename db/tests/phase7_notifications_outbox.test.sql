-- Phase 7 test: notification outbox (triggers, dedupe, claim/complete, lockdown, reads). NOT RUN.
-- Needs migrations up to 20261005160000 applied, and the seeded delivery method 'standard'.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase7_notifications_outbox.test.sql
-- Fixtures carry the marker 'T7' (users/orders/provider 't7'). Existing rows are never assumed
-- absent: every assertion is scoped to fixture users/orders, and rows of other users are pushed
-- into the future so claim_notifications() only sees fixtures.
--
-- NEEDS admin_security_settings.require_mfa = false (the 6L.1 default), as the other admin tests do.
--
-- LIMITS: this is ONE session. "Claim is exclusive" is proven by sequential claims (a claimed row
-- is 'processing' and not due, so nothing returns it twice). FOR UPDATE SKIP LOCKED itself needs two
-- concurrent sessions, which a single-file test cannot start; run two `psql -c "select
-- claim_notifications(5)"` sessions inside open transactions against a dev database to see it.
begin;

create temp table t_res (k text primary key, res text, err text, state text, detail text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

create or replace function pg_temp.run(k text, r text, uid uuid, q text) returns void language plpgsql as $$
#variable_conflict use_variable
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
  insert into t_res values (k, v_res, v_err, v_state, v_detail)
  on conflict on constraint t_res_pkey do update set res = excluded.res, err = excluded.err,
                                state = excluded.state, detail = excluded.detail;
end $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-7e070000' || lpad(n::text, 4, '0'))::uuid $$;
create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;
create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;
-- Runs a statement as the owner and returns its SQLSTATE (or 'ok').
create or replace function pg_temp.sqlstate_of(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.detail_of(q text) returns text language plpgsql as $$
declare v_detail text;
begin
  execute q;
  return 'ok';
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return coalesce(v_detail, '-');
end $$;
create or replace function pg_temp.n(ev text, ent uuid, ch text) returns integer language sql as $$
  select count(*)::integer from public.notification_outbox o
   where o.event_type = ev and o.entity_id = ent and (ch is null or o.channel = ch) $$;
create or replace function pg_temp.fx() returns uuid[] language sql as $$
  select array[pg_temp.u(1), pg_temp.u(2), pg_temp.u(3), pg_temp.u(4), pg_temp.u(5)] $$;
create or replace function pg_temp.mine() returns integer language sql as $$
  select count(*)::integer from public.notification_outbox o where o.user_id = any (pg_temp.fx()) $$;

-- ------------------------------------------------------------ fixtures
-- 1 customer WITH a phone, 2 customer WITHOUT a phone, 3 admin, 4 staff, 5 another customer
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't7-secret-mail-1@example.test', 'authenticated', 'authenticated', '{"full_name":"T7 Phone"}'),
  (pg_temp.u(2), 't7-secret-mail-2@example.test', 'authenticated', 'authenticated', '{"full_name":"T7 NoPhone"}'),
  (pg_temp.u(3), 't7-admin@example.test',         'authenticated', 'authenticated', '{"full_name":"T7 Admin"}'),
  (pg_temp.u(4), 't7-staff@example.test',         'authenticated', 'authenticated', '{"full_name":"T7 Staff"}'),
  (pg_temp.u(5), 't7-other@example.test',         'authenticated', 'authenticated', '{"full_name":"T7 Other"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'admin'), (pg_temp.u(4), 'staff');
insert into public.profiles (id) select x from unnest(pg_temp.fx()) x on conflict (id) do nothing;
update public.profiles set phone = '0712345678', email = 't7-secret-mail-1@example.test' where id = pg_temp.u(1);
update public.profiles set phone = null,         email = 't7-secret-mail-2@example.test' where id = pg_temp.u(2);

-- Push every pre-existing outbox row out of the way so claims only see fixtures.
update public.notification_outbox set next_attempt_at = now() + interval '30 days'
 where status in ('pending', 'failed', 'processing') and user_id <> all (pg_temp.fx());

-- ============================================================ A. SCHEMA CONSTRAINTS
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key, status) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email', 'delivered')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: an unknown status is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values
  ('order_created', %L, %L, 'pigeon', 'order_created:%s:pigeon')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: an unknown channel is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values
  ('order_exploded', %L, %L, 'email', 'order_exploded:%s:email')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: an unknown event type is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values
  ('order_created', %L, %L, 'email', 'some-other-key')$q$, pg_temp.u(900), pg_temp.u(1))) = '23514',
  'schema: the dedupe key must equal event_type:entity_id:channel');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key, payload) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email', '{"email":"a@b.test"}')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: a payload with an email key is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key, payload) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email', '{"order_id":"+254712345678"}')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: a payload value that is not a uuid is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key, attempts) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email', 6)$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: more than 5 attempts is rejected');
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key, status) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email', 'sent')$q$, pg_temp.u(900), pg_temp.u(1), pg_temp.u(900))) = '23514',
  'schema: status sent without sent_at is rejected');
select pg_temp.ok(
  (select array_agg(column_name::text order by column_name) from information_schema.columns
    where table_schema = 'public' and table_name = 'notification_outbox')
  = array['attempts','channel','created_at','dedupe_key','entity_id','event_type','id','last_error',
          'next_attempt_at','payload','sent_at','status','user_id'],
  'schema: no column can hold an address, phone, name, subject or body');

-- ============================================================ B. TRIGGER: orders INSERT
insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(101), pg_temp.u(1), 'T7-A', 'mpesa',            'standard', 5000, 5000, 'awaiting_payment', 'pending'),
  (pg_temp.u(102), pg_temp.u(2), 'T7-B', 'cash_on_delivery', 'standard', 2500, 2500, 'pending',          'pending'),
  (pg_temp.u(103), pg_temp.u(1), 'T7-C', 'cash_on_delivery', 'standard', 2500, 2500, 'pending',          'pending'),
  (pg_temp.u(104), pg_temp.u(5), 'T7-D', 'cash_on_delivery', 'standard', 2500, 2500, 'pending',          'pending');

select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(101), null) = 3
                  and pg_temp.n('order_created', pg_temp.u(101), 'email') = 1
                  and pg_temp.n('order_created', pg_temp.u(101), 'sms') = 1
                  and pg_temp.n('order_created', pg_temp.u(101), 'whatsapp') = 1,
                  'order insert: customer with a phone gets email + sms + whatsapp rows');
select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(102), null) = 1
                  and pg_temp.n('order_created', pg_temp.u(102), 'email') = 1,
                  'order insert: customer without a phone gets the email row only');
select pg_temp.ok((select bool_and(status = 'pending' and attempts = 0 and sent_at is null and last_error is null
                                   and user_id = pg_temp.u(1)
                                   and payload = jsonb_build_object('order_id', pg_temp.u(101))
                                   and dedupe_key = 'order_created:' || pg_temp.u(101)::text || ':' || channel)
                     from public.notification_outbox where entity_id = pg_temp.u(101)),
                  'order insert: rows are pending, 0 attempts, ids-only payload, canonical dedupe key');

-- ============================================================ C. DEDUPE
select pg_temp.ok(pg_temp.sqlstate_of(format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values
  ('order_created', %L, %L, 'email', 'order_created:%s:email')$q$, pg_temp.u(101), pg_temp.u(1), pg_temp.u(101))) = '23505',
  'dedupe: a direct duplicate insert violates the unique key');
select public.notification_enqueue('order_created', pg_temp.u(101), pg_temp.u(1),
                                   jsonb_build_object('order_id', pg_temp.u(101)));
select public.notification_enqueue('order_created', pg_temp.u(101), pg_temp.u(1),
                                   jsonb_build_object('order_id', pg_temp.u(101)));
select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(101), null) = 3, 'dedupe: re-enqueueing the same event adds nothing');
select pg_temp.ok((select count(distinct dedupe_key) = count(*) from public.notification_outbox
                    where user_id = any (pg_temp.fx())), 'dedupe: every fixture row has its own key');

-- ============================================================ D. TRIGGER: orders status changes
update public.orders set status = 'processing' where id = pg_temp.u(103);
select pg_temp.ok((select count(*) = 3 from public.notification_outbox
                    where event_type = 'order_status_changed' and payload ->> 'order_id' = pg_temp.u(103)::text),
                  'status change: one order_status_changed event per channel');
update public.orders set status = 'picking' where id = pg_temp.u(103);
select pg_temp.ok((select count(*) = 6 and count(distinct entity_id) = 2 from public.notification_outbox
                    where event_type = 'order_status_changed' and payload ->> 'order_id' = pg_temp.u(103)::text),
                  'status change: a second transition (same transaction) is a NEW event, not a duplicate');
update public.orders set customer_notes = 'unrelated edit' where id = pg_temp.u(103);
update public.orders set status = 'picking' where id = pg_temp.u(103);
select pg_temp.ok((select count(*) = 6 from public.notification_outbox
                    where event_type = 'order_status_changed' and payload ->> 'order_id' = pg_temp.u(103)::text),
                  'status change: an unrelated update or a same-status update enqueues nothing');
update public.orders set status = 'packed' where id = pg_temp.u(103);
update public.orders set status = 'dispatched' where id = pg_temp.u(103);
update public.orders set status = 'delivered' where id = pg_temp.u(103);
select pg_temp.ok(pg_temp.n('order_delivered', pg_temp.u(103), null) = 3, 'delivered: order_delivered per channel');
select pg_temp.ok((select count(*) = 12 from public.notification_outbox
                    where event_type = 'order_status_changed' and payload ->> 'order_id' = pg_temp.u(103)::text),
                  'delivered: no extra order_status_changed row (processing, picking, packed, dispatched only)');
update public.orders set status = 'processing' where id = pg_temp.u(103);
update public.orders set status = 'delivered' where id = pg_temp.u(103);
select pg_temp.ok(pg_temp.n('order_delivered', pg_temp.u(103), null) = 3, 'delivered: reaching delivered again does not notify twice');

update public.orders set status = 'refunded' where id = pg_temp.u(103);
select pg_temp.ok(pg_temp.n('order_refunded', pg_temp.u(103), null) = 3, 'refunded: status refunded notifies once per channel');
update public.orders set payment_status = 'refunded' where id = pg_temp.u(104);
select pg_temp.ok(pg_temp.n('order_refunded', pg_temp.u(104), null) = 1, 'refunded: payment_status refunded notifies (email only, no phone on file)');
update public.orders set status = 'refunded' where id = pg_temp.u(104);
select pg_temp.ok(pg_temp.n('order_refunded', pg_temp.u(104), null) = 1, 'refunded: both signals together still give ONE event');
update public.orders set payment_status = 'paid' where id = pg_temp.u(101);
select pg_temp.ok((select count(*) = 0 from public.notification_outbox where entity_id = pg_temp.u(101)
                    and event_type not in ('order_created')), 'payment_status -> paid on the order enqueues nothing by itself');

-- ============================================================ E. TRIGGER: payment_transactions
insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(111), pg_temp.u(1), 'T7-PAY', 'mpesa', 'standard', 7000, 7000, 'awaiting_payment', 'pending'),
  (pg_temp.u(112), pg_temp.u(1), 'T7-FAIL','mpesa', 'standard', 7000, 7000, 'awaiting_payment', 'pending'),
  (pg_temp.u(113), pg_temp.u(2), 'T7-COD', 'cash_on_delivery', 'standard', 1800, 1800, 'delivered', 'pending');
insert into public.payment_transactions (id, order_id, provider, method, amount_cents, currency, idempotency_key) values
  (pg_temp.u(211), pg_temp.u(111), 't7', 'mpesa', 7000, 'KES', 'T7-k211'),
  (pg_temp.u(212), pg_temp.u(112), 't7', 'mpesa', 7000, 'KES', 'T7-k212');

select pg_temp.ok((select count(*) = 0 from public.notification_outbox
                    where event_type like 'payment_%' and payload ->> 'transaction_id' in (pg_temp.u(211)::text, pg_temp.u(212)::text)),
                  'payment: a pending transaction enqueues nothing');
update public.payment_transactions set status = 'succeeded', completed_at = now() where id = pg_temp.u(211);
select pg_temp.ok(pg_temp.n('payment_succeeded', pg_temp.u(211), null) = 3
                  and (select bool_and(payload = jsonb_build_object('order_id', pg_temp.u(111), 'transaction_id', pg_temp.u(211))
                                       and user_id = pg_temp.u(1))
                         from public.notification_outbox where entity_id = pg_temp.u(211)),
                  'payment: succeeded enqueues per channel, entity = transaction, ids-only payload, order owner');
update public.payment_transactions set provider_reference = 'T7-REF' where id = pg_temp.u(211);
select pg_temp.ok(pg_temp.n('payment_succeeded', pg_temp.u(211), null) = 3, 'payment: a later non-status update adds nothing');
update public.payment_transactions set status = 'failed', failure_code = 'x', completed_at = now() where id = pg_temp.u(212);
select pg_temp.ok(pg_temp.n('payment_failed', pg_temp.u(212), null) = 3, 'payment: failed enqueues per channel');
insert into public.payment_transactions (id, order_id, provider, method, amount_cents, currency, status, idempotency_key, completed_at)
values (pg_temp.u(213), pg_temp.u(113), 'cod', 'cash_on_delivery', 1800, 'KES', 'succeeded', 'T7-k213', now());
select pg_temp.ok(pg_temp.n('payment_succeeded', pg_temp.u(213), null) = 1
                  and pg_temp.n('payment_succeeded', pg_temp.u(213), 'email') = 1,
                  'payment: a transaction INSERTED as succeeded (cash on delivery) enqueues too');
update public.payment_transactions set status = 'succeeded' where id = pg_temp.u(213);
select pg_temp.ok(pg_temp.n('payment_succeeded', pg_temp.u(213), null) = 1, 'payment: replaying succeeded adds nothing');

-- end to end through the real service-role path
insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(114), pg_temp.u(5), 'T7-E2E', 'mpesa', 'standard', 3000, 3000, 'awaiting_payment', 'pending');
select pg_temp.run('e2e_attempt', 'service_role', null, format(
  $q$select public.create_payment_attempt(%L::uuid, 't7', 'mpesa'::public.payment_method, 'T7-k114')::text$q$, pg_temp.u(114)));
select pg_temp.run('e2e_apply', 'service_role', null, format(
  $q$select public.apply_payment_outcome(%L::uuid, 'succeeded'::public.payment_transaction_status, 'T7-R114', 3000, 'KES', null, null)::text$q$,
  (pg_temp.j('e2e_attempt') -> 'transaction' ->> 'id')::uuid));
select pg_temp.ok(pg_temp.err('e2e_apply') is null
                  and pg_temp.n('payment_succeeded', (pg_temp.j('e2e_attempt') -> 'transaction' ->> 'id')::uuid, 'email') = 1,
                  'payment: apply_payment_outcome (service role) enqueues payment_succeeded');

-- ============================================================ F. A FAILING ENQUEUE NEVER BLOCKS
alter table public.notification_outbox add constraint t7_force_fail check (false) not valid;

select pg_temp.ok(s = 'ok', 'failing enqueue: the order insert itself failed with SQLSTATE ' || s)
  from (select pg_temp.sqlstate_of(format($q$insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
    subtotal_cents, total_cents, status, payment_status) values (%L, %L, 'T7-BLOCK', 'cash_on_delivery', 'standard', 900, 900, 'pending', 'pending')$q$,
    pg_temp.u(121), pg_temp.u(1))) as s) q;
select pg_temp.ok(exists (select 1 from public.orders where id = pg_temp.u(121)),
  'failing enqueue: the order row exists after the insert');
select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(121), null) = 0,
  'failing enqueue: no outbox row was written (found ' || pg_temp.n('order_created', pg_temp.u(121), null) || ')');
create or replace function pg_temp.state_msg(q text) returns text language plpgsql as $$
declare v_msg text;
begin
  execute q;
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return sqlstate || ': ' || v_msg;
end $$;
select pg_temp.ok(s = 'ok', 'failing enqueue: the status update raised ' || s)
  from (select pg_temp.state_msg(format($q$update public.orders set status = 'processing' where id = %L$q$, pg_temp.u(121))) as s) q;
select pg_temp.ok((select status = 'processing' from public.orders where id = pg_temp.u(121)),
  'failing enqueue: the status after the update is ' || (select status::text from public.orders where id = pg_temp.u(121)));

insert into public.orders (id, user_id, order_number, payment_method, delivery_method,
                           subtotal_cents, total_cents, status, payment_status) values
  (pg_temp.u(122), pg_temp.u(1), 'T7-BLOCKPAY', 'mpesa', 'standard', 4000, 4000, 'awaiting_payment', 'pending');
select pg_temp.run('blk_attempt', 'service_role', null, format(
  $q$select public.create_payment_attempt(%L::uuid, 't7', 'mpesa'::public.payment_method, 'T7-k122')::text$q$, pg_temp.u(122)));
select pg_temp.run('blk_apply', 'service_role', null, format(
  $q$select public.apply_payment_outcome(%L::uuid, 'succeeded'::public.payment_transaction_status, 'T7-R122', 4000, 'KES', null, null)::text$q$,
  (pg_temp.j('blk_attempt') -> 'transaction' ->> 'id')::uuid));
select pg_temp.ok(pg_temp.err('blk_apply') is null
                  and (pg_temp.j('blk_apply') ->> 'changed')::boolean is true
                  and (select payment_status = 'paid' from public.orders where id = pg_temp.u(122))
                  and (select status = 'succeeded' from public.payment_transactions
                        where id = (pg_temp.j('blk_attempt') -> 'transaction' ->> 'id')::uuid),
                  'failing enqueue: the payment is recorded and the order marked paid anyway');

alter table public.notification_outbox drop constraint t7_force_fail;
select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(121), null) = 0,
                  'failing enqueue: nothing was queued retroactively (the event is lost by design, see docs)');

-- ============================================================ G. CLAIM IS EXCLUSIVE
-- Only fixtures are due now. Park a couple of rows to prove "not due" rows are not claimed.
update public.notification_outbox set next_attempt_at = now() + interval '1 hour'
 where entity_id = pg_temp.u(104) and event_type = 'order_created';
create temp table t_due as
  select id from public.notification_outbox
   where user_id = any (pg_temp.fx()) and status in ('pending', 'failed') and next_attempt_at <= now();
select pg_temp.ok((select count(*) >= 15 from t_due), 'claim setup: fixtures produced enough due rows');

select pg_temp.run('c1', 'service_role', null, $q$select public.claim_notifications(4)::text$q$);
select pg_temp.run('c2', 'service_role', null, $q$select public.claim_notifications(4)::text$q$);
select pg_temp.ok(jsonb_array_length(pg_temp.j('c1')) = 4 and jsonb_array_length(pg_temp.j('c2')) = 4,
                  'claim: honours the limit');
select pg_temp.ok((select count(distinct v ->> 'id') = 8
                     from (select jsonb_array_elements(pg_temp.j('c1')) v union all
                           select jsonb_array_elements(pg_temp.j('c2'))) x),
                  'claim: two claims never return the same row');
select pg_temp.ok((select bool_and(status = 'processing' and attempts = 1 and next_attempt_at = now() + interval '10 minutes')
                     from public.notification_outbox
                    where id in (select (v ->> 'id')::uuid from jsonb_array_elements(pg_temp.j('c1')) v)),
                  'claim: claimed rows are processing, attempts = 1, leased for 10 minutes');
select pg_temp.ok((select bool_and(v ?& array['id','event_type','entity_id','user_id','channel','payload','attempts']
                                   and (select count(*) = 7 from jsonb_object_keys(v)))
                     from jsonb_array_elements(pg_temp.j('c1')) v),
                  'claim: returns exactly ids/event/channel/payload/attempts, no address');
select pg_temp.run('c3', 'service_role', null, $q$select public.claim_notifications(500)::text$q$);
select pg_temp.run('c4', 'service_role', null, $q$select public.claim_notifications(500)::text$q$);
select pg_temp.ok(jsonb_array_length(pg_temp.j('c3')) = least(50, (select count(*) - 8 from t_due))
                  and jsonb_array_length(pg_temp.j('c4')) = 0,
                  'claim: the rest is claimed once; a further claim returns nothing');
select pg_temp.ok((select count(*) = 0 from public.notification_outbox where entity_id = pg_temp.u(104)
                    and event_type = 'order_created' and status <> 'pending'),
                  'claim: a row that is not yet due is not claimed');
select pg_temp.run('c_bad', 'service_role', null, $q$select public.claim_notifications(0)::text$q$);
select pg_temp.ok(pg_temp.err('c_bad') = 'P0001/invalid_arguments', 'claim: a limit below 1 is refused');

-- ============================================================ H. COMPLETE, BACKOFF, DEAD AFTER 5
-- Everything is now 'processing'. Pick one fixture row and drive it.
create temp table t_target as
  select id from public.notification_outbox where user_id = pg_temp.u(1) and channel = 'email' and status = 'processing'
   order by created_at, id limit 1;
create or replace function pg_temp.complete(k text, outcome text, err text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format(
    'select public.complete_notification(%L::uuid, %L, %L)::text', (select id from t_target), outcome, err));
end $$;
create or replace function pg_temp.row_(col text) returns text language plpgsql as $$
declare v text;
begin
  execute format('select %I::text from public.notification_outbox where id = (select id from t_target)', col) into v;
  return v;
end $$;
-- Make only the target due and everything else not due.
update public.notification_outbox set next_attempt_at = now() + interval '1 day'
 where user_id = any (pg_temp.fx()) and id <> (select id from t_target) and status in ('pending', 'failed', 'processing');

-- attempt 1 (claimed above) fails -> failed, backoff 30s
select pg_temp.complete('h1', 'failed', 'http_503');
select pg_temp.ok(pg_temp.row_('status') = 'failed' and pg_temp.row_('attempts') = '1'
                  and pg_temp.row_('last_error') = 'http_503'
                  and (select next_attempt_at = now() + interval '30 seconds' from public.notification_outbox where id = (select id from t_target)),
                  'backoff: attempt 1 failed -> status failed, retry in 30s, error kept');
select pg_temp.run('h_notdue', 'service_role', null, $q$select public.claim_notifications(50)::text$q$);
select pg_temp.ok(jsonb_array_length(pg_temp.j('h_notdue')) = 0, 'backoff: a failed row is not claimed before it is due');

do $do$
declare
  v_expected interval[] := array[interval '60 seconds', interval '120 seconds', interval '240 seconds'];
  i integer;
begin
  for i in 2..4 loop
    update public.notification_outbox set next_attempt_at = now() where id = (select id from t_target);
    perform pg_temp.run('hc' || i, 'service_role', null, 'select public.claim_notifications(50)::text');
    perform pg_temp.ok(jsonb_array_length(pg_temp.j('hc' || i)) = 1 and pg_temp.row_('attempts') = i::text and pg_temp.row_('status') = 'processing',
                       format('backoff: attempt %s is claimed once it is due', i));
    perform pg_temp.complete('hf' || i, 'failed', 'http_503');
    perform pg_temp.ok(pg_temp.row_('status') = 'failed'
                       and (select next_attempt_at = now() + v_expected[i - 1] from public.notification_outbox where id = (select id from t_target)),
                       format('backoff: attempt %s failed -> exponential delay %s', i, v_expected[i - 1]));
  end loop;
end
$do$;

update public.notification_outbox set next_attempt_at = now() where id = (select id from t_target);
select pg_temp.run('hc5', 'service_role', null, $q$select public.claim_notifications(50)::text$q$);
select pg_temp.ok(pg_temp.row_('attempts') = '5' and pg_temp.row_('status') = 'processing', 'dead: the 5th attempt is claimed');
select pg_temp.complete('hf5', 'failed', 'http_503');
select pg_temp.ok(pg_temp.row_('status') = 'dead' and pg_temp.row_('attempts') = '5' and pg_temp.row_('last_error') = 'http_503',
                  'dead: the 5th failure makes the row dead, attempts stay 5, error kept');
select pg_temp.complete('hf5r', 'failed', 'http_503');
select pg_temp.ok((pg_temp.j('hf5r') ->> 'changed')::boolean is false and pg_temp.row_('status') = 'dead', 'dead: replaying the failure is a no-op');
update public.notification_outbox set next_attempt_at = now() where id = (select id from t_target);
select pg_temp.run('h_dead_claim', 'service_role', null, $q$select public.claim_notifications(50)::text$q$);
select pg_temp.ok(jsonb_array_length(pg_temp.j('h_dead_claim')) = 0, 'dead: a dead row is never claimed again');
select pg_temp.complete('h_dead_sent', 'sent', null);
select pg_temp.ok(pg_temp.err('h_dead_sent') = 'P0001/invalid_transition' and pg_temp.row_('status') = 'dead',
                  'dead: it cannot jump to sent through complete_notification');

-- a lease that expired with all 5 attempts spent is dead; with attempts left it is retried
create temp table t_lease as
  select id, row_number() over (order by created_at, id) rn from public.notification_outbox
   where user_id = pg_temp.u(1) and channel = 'whatsapp' and status = 'processing' and id <> (select id from t_target)
   order by created_at, id limit 2;
update public.notification_outbox set status = 'processing', attempts = 5, next_attempt_at = now() - interval '1 minute'
 where id = (select id from t_lease where rn = 1);
update public.notification_outbox set status = 'processing', attempts = 2, next_attempt_at = now() - interval '1 minute'
 where id = (select id from t_lease where rn = 2);
select pg_temp.run('lease', 'service_role', null, $q$select public.claim_notifications(50)::text$q$);
select pg_temp.ok((select status = 'dead' and last_error = 'lease_expired' and attempts = 5 from public.notification_outbox where id = (select id from t_lease where rn = 1))
                  and (select (v ->> 'attempts')::int = 3 from jsonb_array_elements(pg_temp.j('lease')) v
                        where (v ->> 'id')::uuid = (select id from t_lease where rn = 2)),
                  'lease: expired with 5 attempts used -> dead; expired with attempts left -> reclaimed as attempt 3');

-- sent / skipped / dead outcomes, and the final-state guard
create temp table t_out as
  select id, row_number() over (order by created_at, id) rn from public.notification_outbox
   where user_id = pg_temp.u(2) and status = 'processing' order by created_at, id limit 1;
create or replace function pg_temp.complete_out(k text, outcome text, err text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, 'service_role', null, format(
    'select public.complete_notification(%L::uuid, %L, %L)::text', (select id from t_out), outcome, err));
end $$;
select pg_temp.complete_out('o_sent', 'sent', 'ignored error text');
select pg_temp.ok((select status = 'sent' and sent_at is not null and last_error is null from public.notification_outbox where id = (select id from t_out)),
                  'sent: status sent, sent_at set, no error recorded');
select pg_temp.complete_out('o_sent2', 'sent', null);
select pg_temp.ok((pg_temp.j('o_sent2') ->> 'changed')::boolean is false, 'sent: reporting sent twice is a no-op');
select pg_temp.complete_out('o_fail_after', 'failed', 'late');
select pg_temp.ok(pg_temp.err('o_fail_after') = 'P0001/invalid_transition', 'sent: a sent row cannot be failed');
select pg_temp.ok(pg_temp.detail_of(format($q$update public.notification_outbox set status = 'pending', sent_at = null where id = %L$q$, (select id from t_out)))
                  = 'notification_already_sent', 'sent: even the owner cannot reopen a sent row (no replay can send twice)');
select pg_temp.ok(pg_temp.detail_of(format($q$update public.notification_outbox set user_id = %L where id = %L$q$, pg_temp.u(5), (select id from t_target)))
                  = 'notification_identity_immutable', 'guard: identity columns cannot be changed');
select pg_temp.ok(pg_temp.detail_of(format($q$update public.notification_outbox set payload = '{}' where id = %L$q$, (select id from t_target)))
                  = 'notification_identity_immutable', 'guard: payload cannot be changed');

create temp table t_skip as
  select id from public.notification_outbox where user_id = pg_temp.u(1) and channel = 'sms' and status = 'processing'
   order by created_at, id limit 1;
select pg_temp.run('skip', 'service_role', null, format(
  $q$select public.complete_notification(%L::uuid, 'skipped_not_configured', null)::text$q$, (select id from t_skip)));
select pg_temp.ok((select status = 'skipped_not_configured' and sent_at is null from public.notification_outbox where id = (select id from t_skip)),
                  'skipped: no provider -> skipped_not_configured, never sent');
select pg_temp.run('skip_pend', 'service_role', null, format(
  $q$select public.complete_notification(%L::uuid, 'sent', null)::text$q$, (select id from t_skip)));
select pg_temp.ok(pg_temp.err('skip_pend') = 'P0001/invalid_transition', 'skipped: cannot be turned into sent by completion');

select pg_temp.run('unclaimed', 'service_role', null, format(
  $q$select public.complete_notification(%L::uuid, 'sent', null)::text$q$,
  (select id from public.notification_outbox where entity_id = pg_temp.u(104) and event_type = 'order_created')));
select pg_temp.ok(pg_temp.err('unclaimed') = 'P0001/invalid_transition', 'complete: a row that was never claimed cannot be completed');
select pg_temp.run('badout', 'service_role', null, format($q$select public.complete_notification(%L::uuid, 'processing', null)::text$q$, pg_temp.u(1)));
select pg_temp.run('badout2', 'service_role', null, $q$select public.complete_notification(null, 'sent', null)::text$q$);
select pg_temp.run('noid', 'service_role', null, format($q$select public.complete_notification(%L::uuid, 'sent', null)::text$q$, pg_temp.u(999)));
select pg_temp.ok(pg_temp.err('badout') = 'P0001/invalid_arguments' and pg_temp.err('badout2') = 'P0001/invalid_arguments'
                  and pg_temp.err('noid') = 'P0001/notification_not_found', 'complete: bad outcome / null id / unknown id are refused');

-- error text is sanitised and short
create temp table t_err as
  select id from public.notification_outbox where user_id = pg_temp.u(5) and status = 'processing'
   order by created_at, id limit 1;
select pg_temp.run('err_long', 'service_role', null, format(
  $q$select public.complete_notification(%L::uuid, 'dead', %L)::text$q$, (select id from t_err), E'line1\nline2' || repeat('x', 400)));
select pg_temp.ok((select status = 'dead' and char_length(last_error) = 200 and last_error !~ '[[:cntrl:]]'
                     from public.notification_outbox where id = (select id from t_err)),
                  'complete: the error is stripped of control characters and cut to 200 characters');

-- ============================================================ I. NO API ROLE CAN TOUCH THE TABLE
select pg_temp.run('t_anon_sel',  'anon',          null,         'select count(*)::text from public.notification_outbox');
select pg_temp.run('t_auth_sel',  'authenticated', pg_temp.u(1), 'select count(*)::text from public.notification_outbox');
select pg_temp.run('t_staff_sel', 'authenticated', pg_temp.u(4), 'select count(*)::text from public.notification_outbox');
select pg_temp.run('t_admin_sel', 'authenticated', pg_temp.u(3), 'select count(*)::text from public.notification_outbox');
select pg_temp.run('t_svc_sel',   'service_role',  null,         'select count(*)::text from public.notification_outbox');
select pg_temp.ok((select bool_and(state = '42501') from t_res where k in ('t_anon_sel','t_auth_sel','t_staff_sel','t_admin_sel','t_svc_sel')),
                  'lockdown: anon, customer, staff, admin and service_role cannot SELECT the table');
select pg_temp.run('t_auth_ins', 'authenticated', pg_temp.u(1), format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values ('order_created', %L, %L, 'email', 'order_created:%s:email') returning id::text$q$,
  pg_temp.u(901), pg_temp.u(1), pg_temp.u(901)));
select pg_temp.run('t_svc_ins', 'service_role', null, format($q$insert into public.notification_outbox
  (event_type, entity_id, user_id, channel, dedupe_key) values ('order_created', %L, %L, 'email', 'order_created:%s:email') returning id::text$q$,
  pg_temp.u(902), pg_temp.u(1), pg_temp.u(902)));
select pg_temp.run('t_auth_upd', 'authenticated', pg_temp.u(1), $q$update public.notification_outbox set status = 'sent' returning id::text$q$);
select pg_temp.run('t_svc_upd',  'service_role',  null,         $q$update public.notification_outbox set status = 'pending' returning id::text$q$);
select pg_temp.run('t_auth_del', 'authenticated', pg_temp.u(1), $q$delete from public.notification_outbox returning id::text$q$);
select pg_temp.run('t_svc_del',  'service_role',  null,         $q$delete from public.notification_outbox returning id::text$q$);
select pg_temp.run('t_svc_trunc','service_role',  null,         $q$truncate public.notification_outbox$q$);
select pg_temp.ok((select bool_and(state = '42501') from t_res where k in
                    ('t_auth_ins','t_svc_ins','t_auth_upd','t_svc_upd','t_auth_del','t_svc_del','t_svc_trunc')),
                  'lockdown: no API role can INSERT, UPDATE, DELETE or TRUNCATE');
select pg_temp.ok(pg_temp.n('order_created', pg_temp.u(901), null) = 0 and pg_temp.n('order_created', pg_temp.u(902), null) = 0,
                  'lockdown: the refused inserts left nothing behind');
select pg_temp.ok(
  not exists (select 1 from (values ('anon'), ('authenticated'), ('service_role')) r(role)
              where has_any_column_privilege(r.role, 'public.notification_outbox'::regclass, 'SELECT, INSERT, UPDATE, REFERENCES')
                 or has_table_privilege(r.role, 'public.notification_outbox'::regclass, 'DELETE, TRUNCATE, TRIGGER'))
  and (select relrowsecurity from pg_class where oid = 'public.notification_outbox'::regclass)
  and not exists (select 1 from pg_policy where polrelid = 'public.notification_outbox'::regclass),
  'lockdown (catalogue): no table/column privilege for any API role; RLS on; no policy');
select pg_temp.ok(
  not exists (select 1 from (values ('anon'), ('authenticated'), ('service_role')) r(role),
              (values ('public.notification_enqueue(text,uuid,uuid,jsonb)'), ('public.notify_on_order_change()'),
                      ('public.notify_on_payment_change()'), ('public.notification_outbox_guard()')) f(sig)
              where has_function_privilege(r.role, f.sig, 'EXECUTE')),
  'lockdown (catalogue): enqueue and trigger functions are executable by no API role');
select pg_temp.run('f_auth_claim', 'authenticated', pg_temp.u(3), $q$select public.claim_notifications(5)::text$q$);
select pg_temp.run('f_anon_claim', 'anon',          null,         $q$select public.claim_notifications(5)::text$q$);
select pg_temp.run('f_auth_comp',  'authenticated', pg_temp.u(3), format($q$select public.complete_notification(%L::uuid, 'sent', null)::text$q$, pg_temp.u(1)));
select pg_temp.run('f_anon_comp',  'anon',          null,         format($q$select public.complete_notification(%L::uuid, 'sent', null)::text$q$, pg_temp.u(1)));
select pg_temp.ok((select bool_and(state = '42501') from t_res where k in ('f_auth_claim','f_anon_claim','f_auth_comp','f_anon_comp')),
                  'lockdown: claim/complete are refused to anon and to signed-in users, even an admin');
select pg_temp.ok(
  has_function_privilege('service_role', 'public.claim_notifications(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.complete_notification(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_notifications(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.complete_notification(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.claim_notifications(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.complete_notification(uuid,text,text)', 'EXECUTE'),
  'catalogue: claim/complete are service_role only');

-- ============================================================ J. CUSTOMER SEES ONLY OWN HISTORY
select pg_temp.run('m1', 'authenticated', pg_temp.u(1), $q$select public.get_my_notifications(100)::text$q$);
select pg_temp.run('m2', 'authenticated', pg_temp.u(2), $q$select public.get_my_notifications(100)::text$q$);
select pg_temp.run('m5', 'authenticated', pg_temp.u(5), $q$select public.get_my_notifications(100)::text$q$);
select pg_temp.run('m_anon', 'anon', null, $q$select public.get_my_notifications(10)::text$q$);
select pg_temp.run('m_nouid', 'authenticated', null, $q$select public.get_my_notifications(10)::text$q$);
select pg_temp.run('m_svc', 'service_role', null, $q$select public.get_my_notifications(10)::text$q$);
select pg_temp.ok(jsonb_array_length(pg_temp.j('m1')) = (select count(*) from public.notification_outbox where user_id = pg_temp.u(1))
                  and jsonb_array_length(pg_temp.j('m1')) > 0,
                  'customer: sees exactly their own rows');
select pg_temp.ok((select bool_and(v ->> 'id' in (select id::text from public.notification_outbox where user_id = pg_temp.u(2)))
                     from jsonb_array_elements(pg_temp.j('m2')) v)
                  and jsonb_array_length(pg_temp.j('m2')) = (select count(*) from public.notification_outbox where user_id = pg_temp.u(2)),
                  'customer: another customer sees only their own, none of the first customer''s');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(pg_temp.j('m5')) v
                               where v ->> 'id' in (select id::text from public.notification_outbox where user_id <> pg_temp.u(5))),
                  'customer: no row of any other user leaks');
select pg_temp.ok((select bool_and(array(select jsonb_object_keys(v) order by 1) = array['channel','created_at','event_type','id','status'])
                     from jsonb_array_elements(pg_temp.j('m1')) v),
                  'customer: only id, event_type, channel, status, created_at are returned');
select pg_temp.ok(pg_temp.err('m_anon') is not null and (select state = '42501' from t_res where k = 'm_anon')
                  and pg_temp.err('m_nouid') = '42501/not_authorised'
                  and (select state = '42501' from t_res where k = 'm_svc'),
                  'customer read: anon, a JWT without a user, and service_role are refused');

-- ============================================================ K. ADMIN RPC
select pg_temp.run('a_admin', 'authenticated', pg_temp.u(3), $q$select public.admin_list_notifications()::text$q$);
select pg_temp.run('a_dead',  'authenticated', pg_temp.u(3), $q$select public.admin_list_notifications('dead', 100, 0)::text$q$);
select pg_temp.run('a_bad',   'authenticated', pg_temp.u(3), $q$select public.admin_list_notifications('exploded')::text$q$);
select pg_temp.run('a_badlim','authenticated', pg_temp.u(3), $q$select public.admin_list_notifications(null, 0, 0)::text$q$);
select pg_temp.run('a_cust',  'authenticated', pg_temp.u(1), $q$select public.admin_list_notifications()::text$q$);
select pg_temp.run('a_staff', 'authenticated', pg_temp.u(4), $q$select public.admin_list_notifications()::text$q$);
select pg_temp.run('a_nouid', 'authenticated', null,         $q$select public.admin_list_notifications()::text$q$);
select pg_temp.run('a_anon',  'anon',          null,         $q$select public.admin_list_notifications()::text$q$);
select pg_temp.run('a_svc',   'service_role',  null,         $q$select public.admin_list_notifications()::text$q$);

select pg_temp.ok(pg_temp.err('a_admin') is null
                  and (pg_temp.j('a_admin') ->> 'total')::int = (select count(*) from public.notification_outbox)
                  and jsonb_array_length(pg_temp.j('a_admin') -> 'rows') = least(50, (select count(*) from public.notification_outbox))
                  and (pg_temp.j('a_admin') -> 'counts' ->> 'dead')::int = (select count(*) from public.notification_outbox where status = 'dead'),
                  'admin: lists notifications with total and per-status counts');
select pg_temp.ok((select bool_and(array(select jsonb_object_keys(v) order by 1) = array['attempts','channel','created_at','entity_id',
                     'event_type','id','last_error','next_attempt_at','sent_at','status','user_id'])
                     from jsonb_array_elements(pg_temp.j('a_admin') -> 'rows') v),
                  'admin: rows carry ids, statuses and timing only (no payload, no address)');
select pg_temp.ok((select bool_and(v ->> 'status' = 'dead') from jsonb_array_elements(pg_temp.j('a_dead') -> 'rows') v)
                  and (pg_temp.j('a_dead') ->> 'total')::int = (select count(*) from public.notification_outbox where status = 'dead'),
                  'admin: the status filter works');
select pg_temp.ok(pg_temp.err('a_bad') = 'P0001/invalid_arguments' and pg_temp.err('a_badlim') = 'P0001/invalid_arguments',
                  'admin: a bad status or limit is refused');
select pg_temp.ok(pg_temp.err('a_cust') = '42501/not_authorised' and pg_temp.err('a_staff') = '42501/not_authorised'
                  and pg_temp.err('a_nouid') = '42501/not_authorised',
                  'admin RPC refused: customer, staff, and a JWT without a user');
select pg_temp.ok((select state = '42501' from t_res where k = 'a_anon') and (select state = '42501' from t_res where k = 'a_svc'),
                  'admin RPC refused: anon and service_role (no EXECUTE)');
select pg_temp.ok(pg_temp.err('a_admin') is null and pg_temp.j('a_admin')::text !~* '(t7-secret|0712345678|254712345678|@example)',
                  'admin: the answer contains no address');

-- ============================================================ L. NO ADDRESSES ARE EVER STORED
select pg_temp.ok(pg_temp.mine() > 20, 'addresses: fixtures produced a meaningful number of rows to inspect');
select pg_temp.ok(not exists (select 1 from public.notification_outbox o
                               where o.user_id = any (pg_temp.fx())
                                 and to_jsonb(o)::text ~* '(t7-secret|t7-admin|t7-staff|t7-other|0712345678|254712345678|@)'),
                  'addresses: no email address or phone number (any format) appears in any stored row');
select pg_temp.ok(not exists (select 1 from public.notification_outbox o
                               where o.user_id = any (pg_temp.fx())
                                 and (o.payload - 'order_id' - 'transaction_id') <> '{}'::jsonb),
                  'addresses: every payload holds only order_id / transaction_id');
select pg_temp.ok((select count(*) = 0 from public.notification_outbox o
                    where o.user_id = pg_temp.u(2) and o.channel in ('sms', 'whatsapp')),
                  'addresses: a customer without a phone never got an sms/whatsapp row');

rollback;
