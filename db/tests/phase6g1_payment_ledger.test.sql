-- Phase 6G.1 test: payment_transactions table + security, in the 6G.4-B (read lockdown) state. NOT RUN unless the report says so.
-- Needs migrations up to 20261005080000 (6G.4-B) applied, and the seeded delivery method 'standard'.
-- Direct SELECT is denied to every browser role after 6G.4-B; reads go through the 6G.4-A functions.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures carry the marker 'T6G1' (provider 't6g1'); counts filter on it, so existing rows are ignored.
begin;

create temp table t_res (k text primary key, res text, err text, state text);

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', n; end if;
  raise notice 'PASS: %', n;
end $$;

-- run q as database role r with JWT subject uid; q returns one text value (select / insert..returning)
-- or nothing (truncate). Result or error is stored under k.
create or replace function pg_temp.run(k text, r text, uid uuid, q text, ret boolean) returns void language plpgsql as $$
declare v_res text; v_err text; v_state text;
begin
  perform set_config('request.jwt.claims',
    case when uid is null then '' else json_build_object('sub', uid, 'role', r)::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  perform set_config('request.jwt.claim.role', r, true);
  begin
    execute format('set local role %I', r);
    if ret then execute q into v_res; else execute q; end if;
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate;
    v_res := null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  insert into t_res values (k, v_res, v_err, v_state);
end $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6a010000' || lpad(n::text, 4, '0'))::uuid $$;

create or replace function pg_temp.state(k text) returns text language sql as $$
  select state from t_res where t_res.k = state.k $$;

create or replace function pg_temp.res(k text) returns text language sql as $$
  select res from t_res where t_res.k = res.k $$;

-- Fixtures: 1 customer A, 2 customer B, 3 staff, 4 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6g1-a@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G1 A"}'),
  (pg_temp.u(2), 't6g1-b@example.test',     'authenticated', 'authenticated', '{"full_name":"T6G1 B"}'),
  (pg_temp.u(3), 't6g1-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G1 Staff"}'),
  (pg_temp.u(4), 't6g1-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6G1 Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin');

insert into public.orders (id, user_id, order_number, payment_method, delivery_method) values
  (pg_temp.u(101), pg_temp.u(1), 'T6G1-A', 'mpesa', 'standard'),
  (pg_temp.u(102), pg_temp.u(2), 'T6G1-B', 'mpesa', 'standard');

-- Rows are created by the owner (bypasses privileges and RLS), as a server process would.
insert into public.payment_transactions (id, order_id, provider, method, amount_cents, idempotency_key, provider_reference) values
  (pg_temp.u(201), pg_temp.u(101), 't6g1', 'mpesa', 1000, 'T6G1-idem-1', 'T6G1-ref-1'),
  (pg_temp.u(202), pg_temp.u(101), 't6g1', 'mpesa', 2000, 'T6G1-idem-2', null),
  (pg_temp.u(203), pg_temp.u(102), 't6g1', 'mpesa', 3000, 'T6G1-idem-3', null);

-- ---------------------------------------------------------------- defaults
select pg_temp.ok((select status = 'pending' and currency = 'KES' and completed_at is null
                   from public.payment_transactions where id = pg_temp.u(201)), 'defaults: pending, KES, not completed');

-- ---------------------------------------------------------------- direct SELECT denied (6G.4-B)
select pg_temp.run('a_all',   'authenticated', pg_temp.u(1), $q$select count(*)::text from public.payment_transactions where provider = 't6g1' $q$, true);
select pg_temp.run('b_all',   'authenticated', pg_temp.u(2), $q$select count(*)::text from public.payment_transactions where provider = 't6g1' $q$, true);
select pg_temp.run('staff_r', 'authenticated', pg_temp.u(3), $q$select count(*)::text from public.payment_transactions where provider = 't6g1' $q$, true);
select pg_temp.run('admin_r', 'authenticated', pg_temp.u(4), $q$select count(*)::text from public.payment_transactions where provider = 't6g1' $q$, true);
select pg_temp.run('anon_r',  'anon',          null,         $q$select count(*)::text from public.payment_transactions $q$, true);

select pg_temp.ok(pg_temp.state('a_all') = '42501' and pg_temp.res('a_all') is null,     'customer A: direct SELECT denied');
select pg_temp.ok(pg_temp.state('b_all') = '42501' and pg_temp.res('b_all') is null,     'customer B: direct SELECT denied');
select pg_temp.ok(pg_temp.state('staff_r') = '42501' and pg_temp.res('staff_r') is null, 'staff: direct SELECT denied');
select pg_temp.ok(pg_temp.state('admin_r') = '42501' and pg_temp.res('admin_r') is null, 'admin: direct SELECT denied');
select pg_temp.ok(pg_temp.state('anon_r') = '42501' and pg_temp.res('anon_r') is null,   'anon: direct SELECT denied');

-- ---------------------------------------------------------------- direct writes denied (42501)
-- Each caller tries INSERT / UPDATE / DELETE / TRUNCATE. Privilege is denied before RLS is evaluated.
do $t$
declare
  c record;
  v_ins text := format($f$insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key)
                          values (%L, 't6g1', 'mpesa', 500, %L) returning id::text$f$, pg_temp.u(101), 'T6G1-denied-' || gen_random_uuid());
begin
  for c in select * from (values
      ('cust',  'authenticated', pg_temp.u(1)),
      ('staff', 'authenticated', pg_temp.u(3)),
      ('admin', 'authenticated', pg_temp.u(4)),
      ('anon',  'anon',          null::uuid)) as x(tag, r, uid) loop
    perform pg_temp.run(c.tag || '_ins', c.r, c.uid, v_ins, true);
    perform pg_temp.run(c.tag || '_upd', c.r, c.uid,
      format($f$update public.payment_transactions set status = 'succeeded' where id = %L returning id::text$f$, pg_temp.u(201)), true);
    perform pg_temp.run(c.tag || '_del', c.r, c.uid,
      format($f$delete from public.payment_transactions where id = %L returning id::text$f$, pg_temp.u(201)), true);
    perform pg_temp.run(c.tag || '_trn', c.r, c.uid, 'truncate public.payment_transactions', false);
    perform pg_temp.ok(pg_temp.state(c.tag || '_ins') = '42501', c.tag || ': INSERT denied');
    perform pg_temp.ok(pg_temp.state(c.tag || '_upd') = '42501', c.tag || ': UPDATE denied');
    perform pg_temp.ok(pg_temp.state(c.tag || '_del') = '42501', c.tag || ': DELETE denied');
    perform pg_temp.ok(pg_temp.state(c.tag || '_trn') = '42501', c.tag || ': TRUNCATE denied');
  end loop;
end $t$;

-- service_role: append-only ledger, so DELETE and TRUNCATE are denied too (6G.4-B)
select pg_temp.run('svc_del', 'service_role', null, format($f$delete from public.payment_transactions where id = %L returning id::text$f$, pg_temp.u(201)), true);
select pg_temp.run('svc_trn', 'service_role', null, 'truncate public.payment_transactions', false);
select pg_temp.ok(pg_temp.state('svc_del') = '42501', 'service_role: DELETE denied');
select pg_temp.ok(pg_temp.state('svc_trn') = '42501', 'service_role: TRUNCATE denied');

-- nothing changed
select pg_temp.ok((select count(*) = 3 and bool_and(status = 'pending')
                   from public.payment_transactions where provider = 't6g1'), 'rows unchanged after denied writes');

-- ---------------------------------------------------------------- constraints (as owner)
do $t$
declare v_state text;
begin
  -- amount must be > 0
  begin
    insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key)
      values (pg_temp.u(101), 't6g1', 'mpesa', 0, 'T6G1-zero');
    v_state := null;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  perform pg_temp.ok(v_state = '23514', 'amount_cents = 0 rejected');

  begin
    insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key)
      values (pg_temp.u(101), 't6g1', 'mpesa', -5, 'T6G1-neg');
    v_state := null;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  perform pg_temp.ok(v_state = '23514', 'negative amount_cents rejected');

  -- duplicate idempotency_key
  begin
    insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key)
      values (pg_temp.u(102), 't6g1', 'mpesa', 100, 'T6G1-idem-1');
    v_state := null;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  perform pg_temp.ok(v_state = '23505', 'duplicate idempotency_key rejected');

  -- duplicate provider_reference for the same provider
  begin
    insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key, provider_reference)
      values (pg_temp.u(102), 't6g1', 'mpesa', 100, 'T6G1-idem-dupref', 'T6G1-ref-1');
    v_state := null;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  perform pg_temp.ok(v_state = '23505', 'duplicate provider_reference (same provider) rejected');

  -- same reference under another provider is allowed
  insert into public.payment_transactions (order_id, provider, method, amount_cents, idempotency_key, provider_reference)
    values (pg_temp.u(102), 't6g1-other', 'mpesa', 100, 'T6G1-idem-otherprov', 'T6G1-ref-1');
  perform pg_temp.ok(true, 'same provider_reference under a different provider allowed');

  -- several rows without provider_reference are allowed (rows 202 and 203 already prove two nulls coexist)
  perform pg_temp.ok((select count(*) = 2 from public.payment_transactions
                      where provider = 't6g1' and provider_reference is null), 'multiple NULL provider_reference allowed');

  -- orders cannot be deleted while a transaction references them (ON DELETE RESTRICT)
  begin
    delete from public.orders where id = pg_temp.u(101);
    v_state := null;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  perform pg_temp.ok(v_state = '23503', 'deleting an order with transactions is restricted');
end $t$;

-- ---------------------------------------------------------------- updated_at trigger (owner update)
update public.payment_transactions set updated_at = '2000-01-01', status = 'processing' where id = pg_temp.u(203);
select pg_temp.ok((select updated_at > '2000-01-01' and status = 'processing'
                   from public.payment_transactions where id = pg_temp.u(203)), 'updated_at trigger refreshes updated_at');

-- ---------------------------------------------------------------- privilege catalogue
select pg_temp.ok(not exists (
  select 1 from (values ('anon'), ('authenticated')) r(role),
                (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
  where has_table_privilege(r.role, 'public.payment_transactions', p.priv)),
  'anon/authenticated hold no SELECT/INSERT/UPDATE/DELETE/TRUNCATE');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.payment_transactions', 'SELECT'), 'authenticated has no SELECT');
select pg_temp.ok(has_table_privilege('service_role', 'public.payment_transactions', 'SELECT')
                  and has_table_privilege('service_role', 'public.payment_transactions', 'INSERT')
                  and has_table_privilege('service_role', 'public.payment_transactions', 'UPDATE')
                  and not has_table_privilege('service_role', 'public.payment_transactions', 'DELETE')
                  and not has_table_privilege('service_role', 'public.payment_transactions', 'TRUNCATE'), 'service_role: SELECT/INSERT/UPDATE yes, DELETE/TRUNCATE no');

rollback;
