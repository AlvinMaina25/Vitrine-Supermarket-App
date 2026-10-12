-- Phase 6E.1A-2 test: admin_get_customer(). NOT RUN.
-- Needs migrations 20261004120000, 20261004130000 and 20261004160000 applied (6E.1B-3: admin-only gate). Run as postgres/owner.
-- One transaction, rolled back at the end. Fixtures carry the marker 'T6F'.
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

create or replace function pg_temp.gc(k text, r text, uid uuid, target text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, 'select public.admin_get_customer(' || target || ')::text');
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6f10000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Fixtures: 1 Alice (12 orders, 2 addresses), 2 Bob (only a cancelled order), 3 staff, 4 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6f-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F Alice Wanjiru","phone":"+254722000001"}'),
  (pg_temp.u(2), 't6f-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6F Bob Otieno","phone":"+254722000002"}'),
  (pg_temp.u(3), 't6f-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F Staff"}'),
  (pg_temp.u(4), 't6f-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6F Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(3), 'staff'), (pg_temp.u(4), 'admin');

insert into public.delivery_methods (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6f_m', 'T6F method', 0, null, 0, false, false, true);

-- Alice: orders 1..11 are 'paid' at 1000*n cents, placed one day apart in Jan 2026;
-- order 12 is 'cancelled' (99900) and the NEWEST, so it is in the last 10 but not in the stats.
insert into public.orders (user_id, order_number, status, payment_method, delivery_method, subtotal_cents, total_cents, placed_at)
select pg_temp.u(1), 'T6F-' || n, case when n = 12 then 'cancelled' else 'paid' end::public.order_status,
       'cash_on_delivery', 't6f_m',
       case when n = 12 then 99900 else 1000 * n end, case when n = 12 then 99900 else 1000 * n end,
       '2026-01-01 09:00+03'::timestamptz + (n || ' days')::interval
from generate_series(1, 12) n;
insert into public.orders (user_id, order_number, status, payment_method, delivery_method, subtotal_cents, total_cents, placed_at)
values (pg_temp.u(2), 'T6F-B1', 'cancelled', 'cash_on_delivery', 't6f_m', 5000, 5000, '2026-02-01 09:00+03');

insert into public.addresses (user_id, label, full_name, phone, address_line_1, city, county, is_default) values
  (pg_temp.u(1), 'Home', 'T6F Alice Wanjiru', '+254722000001', '1 Test Road', 'Nairobi', 'Nairobi', false),
  (pg_temp.u(1), 'Work', 'T6F Alice Wanjiru', '+254722000001', '2 Test Avenue', 'Nairobi', 'Nairobi', true);

select pg_temp.gc('cust',  'authenticated', pg_temp.u(1), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('anon',  'anon',          null,         quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('staff', 'authenticated', pg_temp.u(3), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('admin', 'authenticated', pg_temp.u(4), quote_literal(pg_temp.u(1)::text) || '::uuid');
select pg_temp.gc('bob',   'authenticated', pg_temp.u(4), quote_literal(pg_temp.u(2)::text) || '::uuid');
select pg_temp.gc('unk',   'authenticated', pg_temp.u(4), quote_literal('00000000-0000-4000-8000-6f1999999999') || '::uuid');
select pg_temp.gc('isstaff','authenticated', pg_temp.u(4), quote_literal(pg_temp.u(4)::text) || '::uuid');
select pg_temp.gc('nul',   'authenticated', pg_temp.u(4), 'null::uuid');
select pg_temp.run('list', 'authenticated', pg_temp.u(4),
  $$select public.admin_list_customers(p_search => 't6f-alice@example.test')::text$$);

do $t$
declare
  d jsonb := pg_temp.j('admin');
  l jsonb := pg_temp.j('list') -> 'customers' -> 0;
begin
  -- access
  perform pg_temp.ok(pg_temp.err('cust') = '42501/not_authorised', 'customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('anon') like '42501/%', 'anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('staff') = '42501/not_authorised', 'staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok(d -> 'profile' ->> 'name' = 'T6F Alice Wanjiru'
                 and d -> 'profile' ->> 'email' = 't6f-alice@example.test'
                 and d -> 'profile' ->> 'phone' = '+254722000001', 'admin is allowed; profile name/email/phone returned');
  perform pg_temp.ok(d -> 'profile' ->> 'id' = pg_temp.u(1)::text, 'admin gets the requested customer id');

  -- addresses (default first)
  perform pg_temp.ok(jsonb_array_length(d -> 'addresses') = 2 and d -> 'addresses' -> 0 ->> 'label' = 'Work',
                     'both addresses returned, default first');

  -- stats match the list exactly, and match the expected values (cancelled ignored)
  perform pg_temp.ok(l is not null and l ->> 'id' = pg_temp.u(1)::text, 'list row for Alice found');
  perform pg_temp.ok((d -> 'stats' ->> 'order_count')::bigint = (l ->> 'order_count')::bigint
                 and (d -> 'stats' ->> 'lifetime_spend_cents')::bigint = (l ->> 'lifetime_spend_cents')::bigint
                 and (d -> 'stats' ->> 'last_order_at')::timestamptz = (l ->> 'last_order_at')::timestamptz,
                 'detail stats equal list stats');
  perform pg_temp.ok((d -> 'stats' ->> 'order_count')::int = 11
                 and (d -> 'stats' ->> 'lifetime_spend_cents')::bigint = 66000
                 and (d -> 'stats' ->> 'last_order_at')::timestamptz = '2026-01-12 09:00+03'::timestamptz,
                 'stats ignore the cancelled order (11 orders, 66000 cents, last = 12 Jan)');

  -- last 10 orders only, newest first, cancelled shown with its status
  perform pg_temp.ok(jsonb_array_length(d -> 'recent_orders') = 10, 'exactly 10 recent orders of 12');
  perform pg_temp.ok(d -> 'recent_orders' -> 0 ->> 'status' = 'cancelled'
                 and (d -> 'recent_orders' -> 0 ->> 'total_cents')::int = 99900
                 and (d -> 'recent_orders' -> 9 ->> 'total_cents')::int = 3000,
                 'newest first: cancelled order leads, oldest shown is order 3 (orders 1-2 excluded)');
  perform pg_temp.ok(d -> 'recent_orders' -> 0 ?& array['id', 'status', 'payment_status', 'total_cents', 'created_at'],
                     'recent order has id, status, payment_status, total_cents, created_at');

  -- customer with only a cancelled order
  perform pg_temp.ok((pg_temp.j('bob') -> 'stats' ->> 'order_count')::int = 0
                 and (pg_temp.j('bob') -> 'stats' ->> 'lifetime_spend_cents')::bigint = 0
                 and pg_temp.j('bob') -> 'stats' -> 'last_order_at' = 'null'::jsonb
                 and jsonb_array_length(pg_temp.j('bob') -> 'recent_orders') = 1
                 and jsonb_array_length(pg_temp.j('bob') -> 'addresses') = 0,
                 'customer with only a cancelled order: zero stats, 1 recent order, no addresses');

  -- unknown id / staff id / null
  perform pg_temp.ok(pg_temp.err('unk') = 'P0001/customer_not_found', 'unknown id -> customer_not_found');
  perform pg_temp.ok(pg_temp.err('isstaff') = 'P0001/customer_not_found', 'staff/admin id is not a customer -> customer_not_found');
  perform pg_temp.ok(pg_temp.err('nul') = 'P0001/invalid_arguments', 'null id -> invalid_arguments');

  raise notice 'ALL CUSTOMER DETAIL TESTS PASSED';
end
$t$;

rollback;
