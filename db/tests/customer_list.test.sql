-- Phase 6E.1A-1 test: admin_list_customers(). NOT RUN.
-- Needs migrations 20261004120000 and 20261004160000 applied (6E.1B-3: admin-only gate, 4-arg function). Run as postgres/owner (SQL Editor or psql).
-- One transaction, rolled back at the end. Fixtures carry the marker 'T6E'.
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

-- call admin_list_customers(<named args>) as a role, record under key k
create or replace function pg_temp.lc(k text, r text, uid uuid, args text) returns void language plpgsql as $$
begin
  perform pg_temp.run(k, r, uid, 'select public.admin_list_customers(' || args || ')::text');
end $$;

create or replace function pg_temp.j(k text) returns jsonb language sql as $$
  select res::jsonb from t_res where t_res.k = j.k $$;

create or replace function pg_temp.err(k text) returns text language sql as $$
  select state || '/' || coalesce(detail, '-') from t_res where t_res.k = err.k and t_res.err is not null $$;

create or replace function pg_temp.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-6e10000000' || lpad(n::text, 2, '0'))::uuid $$;

-- Fixtures: 1 Alice (orders), 2 Bob (only a cancelled order), 3 Carol (no orders), 4 staff, 5 admin
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  (pg_temp.u(1), 't6e-alice@example.test', 'authenticated', 'authenticated', '{"full_name":"T6E Alice Wanjiru","phone":"+254711000001"}'),
  (pg_temp.u(2), 't6e-bob@example.test',   'authenticated', 'authenticated', '{"full_name":"T6E Bob Otieno","phone":"+254711000002"}'),
  (pg_temp.u(3), 't6e-carol@example.test', 'authenticated', 'authenticated', '{"full_name":"T6E Carol Mutua","phone":"+254711000003"}'),
  (pg_temp.u(4), 't6e-staff@example.test', 'authenticated', 'authenticated', '{"full_name":"T6E Staff"}'),
  (pg_temp.u(5), 't6e-admin@example.test', 'authenticated', 'authenticated', '{"full_name":"T6E Admin"}');
insert into public.user_roles (user_id, role) values (pg_temp.u(4), 'staff'), (pg_temp.u(5), 'admin');

-- 105 bulk customers for the page_size cap
insert into auth.users (id, email, aud, role, raw_user_meta_data)
select gen_random_uuid(), 't6e-bulk' || g || '@example.test', 'authenticated', 'authenticated',
       jsonb_build_object('full_name', 'T6E Bulk ' || g)
from generate_series(1, 105) g;

insert into public.delivery_methods (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('t6e_m', 'T6E method', 0, null, 0, false, false, true);

insert into public.orders (user_id, order_number, status, payment_method, delivery_method, subtotal_cents, total_cents, placed_at) values
  (pg_temp.u(1), 'T6E-1', 'paid',      'cash_on_delivery', 't6e_m', 10000, 10000, '2026-01-10 09:00+03'),
  (pg_temp.u(1), 'T6E-2', 'delivered', 'cash_on_delivery', 't6e_m',  5000,  5000, '2026-02-10 09:00+03'),
  (pg_temp.u(1), 'T6E-3', 'cancelled', 'cash_on_delivery', 't6e_m', 99900, 99900, '2026-03-10 09:00+03'),
  (pg_temp.u(2), 'T6E-4', 'cancelled', 'cash_on_delivery', 't6e_m', 77700, 77700, '2026-03-11 09:00+03');

select pg_temp.lc('cust',  'authenticated', pg_temp.u(1), $$p_search => 'T6E'$$);
select pg_temp.lc('anon',  'anon',          null,         $$p_search => 'T6E'$$);
select pg_temp.lc('staff', 'authenticated', pg_temp.u(4), $$p_search => 'T6E Alice'$$);
select pg_temp.lc('admin', 'authenticated', pg_temp.u(5), $$p_search => 'T6E Alice'$$);
select pg_temp.lc('s_name',  'authenticated', pg_temp.u(5), $$p_search => 'otieno'$$);
select pg_temp.lc('s_email', 'authenticated', pg_temp.u(5), $$p_search => 'T6E-CAROL@example'$$);
select pg_temp.lc('s_phone', 'authenticated', pg_temp.u(5), $$p_search => '254711000002'$$);
select pg_temp.lc('s_wild',  'authenticated', pg_temp.u(5), $$p_search => '%'$$);
select pg_temp.lc('cap',     'authenticated', pg_temp.u(5), $$p_search => 'T6E', p_page_size => 1000$$);
select pg_temp.lc('p2',      'authenticated', pg_temp.u(5), $$p_search => 'T6E', p_page => 2, p_page_size => 100$$);
select pg_temp.lc('bad_pg',  'authenticated', pg_temp.u(5), $$p_page => 0$$);
select pg_temp.lc('bad_sz',  'authenticated', pg_temp.u(5), $$p_page_size => 0$$);
select pg_temp.lc('alice',   'authenticated', pg_temp.u(5), $$p_search => 't6e-alice@example.test'$$);
select pg_temp.lc('bob',     'authenticated', pg_temp.u(5), $$p_search => 't6e-bob@example.test'$$);
select pg_temp.lc('carol',   'authenticated', pg_temp.u(5), $$p_search => 't6e-carol@example.test'$$);

do $t$
begin
  -- access
  perform pg_temp.ok(pg_temp.err('cust') = '42501/not_authorised', 'customer is denied (42501 not_authorised)');
  perform pg_temp.ok(pg_temp.err('anon') like '42501/%', 'anon is denied (42501)');
  perform pg_temp.ok(pg_temp.err('staff') = '42501/not_authorised', 'staff (non-admin) is denied (42501 not_authorised)');
  perform pg_temp.ok((pg_temp.j('admin') ->> 'total')::int = 1 and pg_temp.j('admin') -> 'customers' -> 0 ->> 'name' = 'T6E Alice Wanjiru', 'admin is allowed');

  -- search: name (case-insensitive), email (case-insensitive), phone, wildcard literal
  perform pg_temp.ok((pg_temp.j('s_name') ->> 'total')::int = 1 and pg_temp.j('s_name') -> 'customers' -> 0 ->> 'email' = 't6e-bob@example.test', 'search by name');
  perform pg_temp.ok((pg_temp.j('s_email') ->> 'total')::int = 1 and pg_temp.j('s_email') -> 'customers' -> 0 ->> 'name' = 'T6E Carol Mutua', 'search by email');
  perform pg_temp.ok((pg_temp.j('s_phone') ->> 'total')::int = 1 and pg_temp.j('s_phone') -> 'customers' -> 0 ->> 'name' = 'T6E Bob Otieno', 'search by phone');
  perform pg_temp.ok((pg_temp.j('s_wild') ->> 'total')::int = 0, '% in search is literal, not a wildcard');

  -- staff/admin profiles never listed; page_size cap
  perform pg_temp.ok((pg_temp.j('cap') ->> 'total')::int = 108, 'total = 108 customers (staff and admin excluded)');
  perform pg_temp.ok((pg_temp.j('cap') ->> 'page_size')::int = 100 and jsonb_array_length(pg_temp.j('cap') -> 'customers') = 100, 'page_size 1000 is capped to 100');
  perform pg_temp.ok((pg_temp.j('p2') ->> 'total')::int = 108 and jsonb_array_length(pg_temp.j('p2') -> 'customers') = 8, 'page 2 returns the remaining 8, total unchanged');
  perform pg_temp.ok(pg_temp.err('bad_pg') = 'P0001/invalid_arguments', 'page 0 rejected');
  perform pg_temp.ok(pg_temp.err('bad_sz') = 'P0001/invalid_arguments', 'page_size 0 rejected');

  -- cancelled orders ignored
  perform pg_temp.ok((pg_temp.j('alice') -> 'customers' -> 0 ->> 'order_count')::int = 2
                 and (pg_temp.j('alice') -> 'customers' -> 0 ->> 'lifetime_spend_cents')::bigint = 15000
                 and (pg_temp.j('alice') -> 'customers' -> 0 ->> 'last_order_at')::timestamptz = '2026-02-10 09:00+03'::timestamptz,
                 'cancelled order ignored in count, spend and last_order_at');
  perform pg_temp.ok((pg_temp.j('bob') -> 'customers' -> 0 ->> 'order_count')::int = 0
                 and (pg_temp.j('bob') -> 'customers' -> 0 ->> 'lifetime_spend_cents')::bigint = 0
                 and pg_temp.j('bob') -> 'customers' -> 0 -> 'last_order_at' = 'null'::jsonb,
                 'customer with only a cancelled order: 0 orders, 0 spend, no last order');
  perform pg_temp.ok((pg_temp.j('carol') -> 'customers' -> 0 ->> 'order_count')::int = 0, 'customer with no orders: 0 orders');

  raise notice 'ALL CUSTOMER LIST TESTS PASSED';
end
$t$;

rollback;
