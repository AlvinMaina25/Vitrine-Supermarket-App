-- =============================================================================
-- PHASE 4C.1 database tests: create_order() delivery integration.
--
-- STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
--
-- HOW TO RUN (a Supabase/Postgres DEV or branch database with ALL migrations through
-- 20260930060000_create_order_delivery_integration.sql applied):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/create_order_delivery.test.sql
--
-- Everything runs in ONE transaction that is rolled back at the end. A failed check raises
-- "FAIL: <name>" and aborts; each pass prints "PASS: <name>". Reaching the final
-- "ALL CREATE_ORDER DELIVERY TESTS PASSED" notice means every check passed.
--
-- If you paste this into the Supabase SQL Editor instead, paste the WHOLE file (it starts with
-- BEGIN and ends with ROLLBACK). The SQL Editor may hide NOTICE lines; a run that ends without an
-- error and shows the final result is a pass, a run that stops with "FAIL: ..." is not.
--
-- One session cannot prove the lock holds against a real race (see
-- db/tests/create_order_concurrency.sh for that, also not executed). This file proves: the
-- rules, the stored snapshot, rollback of failed orders, and that create_order() really takes
-- the slot's advisory lock inside its own transaction (checked in pg_locks).
-- Dates are relative to "today" in Africa/Nairobi. d(n) = today + n.
-- =============================================================================
begin;

create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_name;
  end if;
  raise notice 'PASS: %', p_name;
end;
$$;

create or replace function pg_temp.d(p_days integer)
returns date language sql stable as $$
  select ((now() at time zone 'Africa/Nairobi')::date + p_days);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000c201', 'co-customer@example.test', 'authenticated', 'authenticated');

insert into public.addresses
  (id, user_id, full_name, phone, address_line_1, city, county)
values
  ('00000000-0000-4000-8000-0000000000ad', '00000000-0000-4000-8000-00000000c201',
   'CO Customer', '0700000000', '1 Test Road', 'Nairobi', 'Nairobi');

insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active) values
  ('00000000-0000-4000-8000-0000000000b1', 'co-p1', 'CO product', 10000, 50, true, true);

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values
  ('co_addr',    'CO address delivery', 30000, null, 0,     true,  true,  true),
  ('co_pick',    'CO pickup',           0,     null, 0,     false, false, true),
  ('co_pickslot','CO pickup with slot', 5000,  null, 0,     true,  false, true),
  ('co_min',     'CO minimum',          0,     null, 50000, false, false, true),
  ('co_off',     'CO inactive',         0,     null, 0,     false, false, false);

insert into public.delivery_zones (id, code, name, is_active) values
  ('00000000-0000-4000-8000-0000000000a1', 'co-zone-a',   'CO Zone A (rule)',    true),
  ('00000000-0000-4000-8000-0000000000a2', 'co-zone-b',   'CO Zone B (no rule)', true),
  ('00000000-0000-4000-8000-0000000000a3', 'co-zone-off', 'CO Zone inactive',    false);

-- Zone A + co_addr: cheaper fee than the method, and a minimum order of its own.
insert into public.delivery_zone_fees
  (id, zone_id, method_code, fee_cents, free_over_cents, min_order_cents, is_active)
values
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000a1',
   'co_addr', 15000, null, 20000, true);

insert into public.delivery_slot_templates
  (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
values
  ('00000000-0000-4000-8000-0000000000e1', 'CO cap1',     '22:00', '22:30', null, 1,    100, true),
  ('00000000-0000-4000-8000-0000000000e2', 'CO cap3',     '22:30', '23:00', null, 3,    100, true),
  ('00000000-0000-4000-8000-0000000000e3', 'CO inactive', '23:00', '23:30', null, 5,    100, false),
  ('00000000-0000-4000-8000-0000000000e4', 'CO cap1 b',   '21:00', '21:30', null, 1,    100, true),
  ('00000000-0000-4000-8000-0000000000e5', 'CO cap1 c',   '21:30', '22:00', null, 1,    100, true);

-- Sign in as the customer for every create_order() call (as the migration owner; the
-- function is SECURITY DEFINER and reads auth.uid() from these settings).
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-8000-00000000c201', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000c201', true);

-- try_order: calls create_order() inside a sub-transaction, so a rejected call rolls back
-- exactly as a failed RPC would, and the script can inspect the error. Always one row.
create or replace function pg_temp.try_order(
  p_method text,
  p_qty integer default 1,
  p_zone uuid default null,
  p_slot_date date default null,
  p_slot_start time default null,
  p_slot_end time default null,
  p_expected integer default null,
  p_key text default null
) returns table (order_id uuid, msg text, code text)
language plpgsql as $$
declare
  v_id uuid;
  v_msg text;
  v_detail text;
begin
  begin
    v_id := public.create_order(
      jsonb_build_array(jsonb_build_object(
        'product_id', '00000000-0000-4000-8000-0000000000b1', 'variant_id', null, 'quantity', p_qty)),
      p_method,
      'cash_on_delivery',
      case when p_method = 'co_addr' then '00000000-0000-4000-8000-0000000000ad'::uuid end,
      p_slot_date, p_slot_start, p_slot_end,
      null, null, p_key, p_expected, p_zone);
    return query select v_id, null::text, null::text;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    return query select null::uuid, v_msg, v_detail;
  end;
end;
$$;

-- The 13-argument function exists (Phase 8 added p_coupon_code); no older overload remains.
do $$
begin
  perform pg_temp.ok((select count(*) from pg_proc where proname = 'create_order'
    and pronamespace = 'public'::regnamespace) = 1, 'exactly one create_order() overload exists');
  perform pg_temp.ok((select pronargs from pg_proc where proname = 'create_order'
    and pronamespace = 'public'::regnamespace) = 13, 'create_order() takes 13 arguments (p_coupon_code added in Phase 8; p_zone_id in 4C)');
  -- 10. no argument can carry a fee or a subtotal
  perform pg_temp.ok(not exists (
    select 1 from pg_proc p, unnest(p.proargnames) n
    where p.proname = 'create_order' and p.pronamespace = 'public'::regnamespace
      and (n ilike '%fee%' or n ilike '%subtotal%')),
    'create_order() has no fee or subtotal argument (a client fee cannot be sent)');
end $$;

-- ---------------------------------------------------------------------------
-- 1 / 17. Pickup: no zone, no slot needed
-- ---------------------------------------------------------------------------
do $$
declare r record; o record;
begin
  select * into r from pg_temp.try_order('co_pick', 2);
  perform pg_temp.ok(r.order_id is not null, 'pickup order succeeds without a zone or slot');
  select * into o from public.orders where id = r.order_id;
  perform pg_temp.ok(o.subtotal_cents = 20000 and o.delivery_fee_cents = 0 and o.total_cents = 20000,
    'pickup totals: subtotal + fee (0) = total');
  perform pg_temp.ok(o.delivery_zone_id is null and o.delivery_slot_template_id is null
    and o.delivery_slot_date is null, 'pickup order has no zone and no slot');
  perform pg_temp.ok(o.delivery_method = 'co_pick' and o.delivery_method_label = 'CO pickup',
    'pickup order stores the method and its label');
  perform pg_temp.ok(o.delivery_fee_rule is not null and o.delivery_fee_rule->>'source' = 'method',
    'pickup order stores the fee rule (method source)');
  -- a supplied zone is still validated for pickup
  select * into r from pg_temp.try_order('co_pick', 1, gen_random_uuid());
  perform pg_temp.ok(r.order_id is null and r.code = 'zone_unknown',
    'pickup with an unknown zone is rejected (zone_unknown)');
end $$;

-- ---------------------------------------------------------------------------
-- 3-8. Method / zone / minimum rejections (each must create no order)
-- ---------------------------------------------------------------------------
do $$
declare r record; v_before integer; v_stock_before integer;
begin
  select count(*) into v_before from public.orders where user_id = '00000000-0000-4000-8000-00000000c201';
  select stock_quantity into v_stock_before from public.products where id = '00000000-0000-4000-8000-0000000000b1';

  select * into r from pg_temp.try_order('co_nope');
  perform pg_temp.ok(r.order_id is null and r.code = 'method_unknown', '3. unknown method rejected');

  select * into r from pg_temp.try_order('co_off');
  perform pg_temp.ok(r.order_id is null and r.code = 'method_inactive', '4. inactive method rejected');

  select * into r from pg_temp.try_order('co_addr', 3, null, pg_temp.d(2), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'zone_required',
    '5. address method without a zone rejected (zone_required)');

  select * into r from pg_temp.try_order('co_addr', 3, gen_random_uuid(), pg_temp.d(2), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'zone_unknown', '6. unknown zone rejected');

  select * into r from pg_temp.try_order('co_addr', 3, '00000000-0000-4000-8000-0000000000a3',
    pg_temp.d(2), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'zone_inactive', '7. inactive zone rejected');

  -- zone A minimum is 20000; 1 unit = 10000
  select * into r from pg_temp.try_order('co_addr', 1, '00000000-0000-4000-8000-0000000000a1',
    pg_temp.d(2), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'below_minimum_order',
    '8. below the zone minimum order rejected');

  -- method minimum is 50000; 4 units = 40000
  select * into r from pg_temp.try_order('co_min', 4);
  perform pg_temp.ok(r.order_id is null and r.code = 'below_minimum_order',
    '8. below the method minimum order rejected');

  perform pg_temp.ok((select count(*) from public.orders
    where user_id = '00000000-0000-4000-8000-00000000c201') = v_before,
    'no rejected delivery selection created an order');
  perform pg_temp.ok((select stock_quantity from public.products
    where id = '00000000-0000-4000-8000-0000000000b1') = v_stock_before,
    'no rejected delivery selection consumed stock');
end $$;

-- ---------------------------------------------------------------------------
-- 2 / 9 / 11 / 15. Address order with a zone: fee, slot, snapshot
-- ---------------------------------------------------------------------------
do $$
declare r record; o record; v_key bigint;
begin
  -- 3 units = 30000 >= zone minimum 20000; zone fee rule says 15000 (method default is 30000)
  select * into r from pg_temp.try_order('co_addr', 3, '00000000-0000-4000-8000-0000000000a1',
    pg_temp.d(2), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is not null, '2. address order with a valid zone succeeds');
  select * into o from public.orders where id = r.order_id;

  perform pg_temp.ok(o.delivery_fee_cents = 15000, '9. stored delivery fee is the zone rule fee, not the method default');
  perform pg_temp.ok(o.subtotal_cents = 30000 and o.total_cents = 45000,
    'total = server subtotal + authoritative fee');
  perform pg_temp.ok(o.delivery_address is not null and o.delivery_address_id is not null,
    'address snapshot stored');

  -- 15. snapshot
  perform pg_temp.ok(o.delivery_zone_id = '00000000-0000-4000-8000-0000000000a1'
    and o.delivery_zone_code = 'co-zone-a' and o.delivery_zone_name = 'CO Zone A (rule)',
    '15. zone id/code/name snapshot populated');
  perform pg_temp.ok(o.delivery_method_label = 'CO address delivery', '15. method label snapshot populated');
  perform pg_temp.ok(o.delivery_fee_rule->>'source' = 'zone'
    and (o.delivery_fee_rule->>'base_fee_cents')::integer = 15000
    and o.delivery_fee_rule->>'zone_fee_id' = '00000000-0000-4000-8000-0000000000f1',
    '15. fee rule snapshot records the zone rule that produced the fee');

  -- 11. valid slot
  perform pg_temp.ok(o.delivery_slot_date = pg_temp.d(2) and o.delivery_slot_start = '22:30'
    and o.delivery_slot_end = '23:00' and o.delivery_slot_label = 'CO cap3'
    and o.delivery_slot_template_id = '00000000-0000-4000-8000-0000000000e2',
    '11. valid slot stored with template id, label and window');

  -- 15. later configuration changes must not rewrite the order
  update public.delivery_zones set name = 'Renamed', code = code where id = '00000000-0000-4000-8000-0000000000a1';
  update public.delivery_methods set label = 'Renamed method' where code = 'co_addr';
  update public.delivery_slot_templates set label = 'Renamed slot' where id = '00000000-0000-4000-8000-0000000000e2';
  update public.delivery_zone_fees set fee_cents = 99999 where id = '00000000-0000-4000-8000-0000000000f1';
  select * into o from public.orders where id = r.order_id;
  perform pg_temp.ok(o.delivery_zone_name = 'CO Zone A (rule)' and o.delivery_method_label = 'CO address delivery'
    and o.delivery_slot_label = 'CO cap3' and o.delivery_fee_cents = 15000
    and (o.delivery_fee_rule->>'base_fee_cents')::integer = 15000,
    '15. snapshot is unchanged after the live configuration is edited');
  update public.delivery_zone_fees set fee_cents = 15000 where id = '00000000-0000-4000-8000-0000000000f1';

  -- 9. zone without a rule falls back to the method fee
  select * into r from pg_temp.try_order('co_addr', 3, '00000000-0000-4000-8000-0000000000a2',
    pg_temp.d(2), '22:30', '23:00');
  select * into o from public.orders where id = r.order_id;
  perform pg_temp.ok(o.delivery_fee_cents = 30000 and o.delivery_fee_rule->>'source' = 'method',
    '9. zone with no rule uses the method fee from resolve_delivery_fee()');
end $$;

-- ---------------------------------------------------------------------------
-- 10. The client's expected total can veto an order but never lower the fee
-- ---------------------------------------------------------------------------
do $$
declare r record; v_before integer;
begin
  select count(*) into v_before from public.orders where delivery_method = 'co_addr';
  -- a client that "calculated" a cheaper fee (zone A, 3 units: real total 45000)
  select * into r from pg_temp.try_order('co_addr', 3, '00000000-0000-4000-8000-0000000000a1',
    pg_temp.d(2), '22:30', '23:00', 30000);
  perform pg_temp.ok(r.order_id is null and r.msg like 'Prices or delivery fees have changed%',
    '10. a lower client total is refused, not honoured');
  perform pg_temp.ok((select count(*) from public.orders where delivery_method = 'co_addr') = v_before,
    '10. no order was created for the refused total');
  select * into r from pg_temp.try_order('co_addr', 3, '00000000-0000-4000-8000-0000000000a1',
    pg_temp.d(2), '22:30', '23:00', 45000);
  perform pg_temp.ok(r.order_id is not null
    and (select delivery_fee_cents from public.orders where id = r.order_id) = 15000,
    '10. the matching total is accepted and the stored fee is the server fee');
end $$;

-- ---------------------------------------------------------------------------
-- 12. Invalid slots (pickup-with-slot method, so only the slot rules are in play)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from pg_temp.try_order('co_pickslot', 1);
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_required', '12. missing slot rejected');

  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(2), '23:00', '23:30');
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_inactive', '12. inactive slot rejected');

  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(2), '03:10', '03:20');
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_unknown', '12. unknown slot rejected');

  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(-1), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_in_past', '12. slot in the past rejected');

  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(30), '22:30', '23:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_too_far', '12. slot beyond the horizon rejected');

  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(2), '23:00', '22:00');
  perform pg_temp.ok(r.order_id is null and r.code = 'invalid_window', '12. backwards window rejected');
end $$;

-- ---------------------------------------------------------------------------
-- 13 / 14 / 16. Capacity: full slot, the lock, and failed orders not consuming a place
-- ---------------------------------------------------------------------------
do $$
declare r record; v_key bigint; v_stock integer;
begin
  -- 16a. a failure AFTER the lock (expected-total veto) must not consume the single place
  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(3), '22:00', '22:30', 1);
  perform pg_temp.ok(r.order_id is null, '16. order refused after the slot lock was taken');
  perform pg_temp.ok(public.delivery_slot_booked_count(pg_temp.d(3), '22:00', '22:30') = 0,
    '16. the refused order did not consume slot capacity');

  select stock_quantity into v_stock from public.products where id = '00000000-0000-4000-8000-0000000000b1';

  -- 14. the first valid order takes the only place and the slot's advisory lock is held
  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(3), '22:00', '22:30');
  perform pg_temp.ok(r.order_id is not null, '14. first order for a capacity-1 slot succeeds');
  v_key := hashtextextended(
    'delivery_slot:' || pg_temp.d(3)::text || ':' || '22:00'::time::text || ':' || '22:30'::time::text, 4202);
  perform pg_temp.ok(exists (
    select 1 from pg_locks
    where locktype = 'advisory' and pid = pg_backend_pid() and granted and objsubid = 1
      and classid::bigint = ((v_key >> 32) & 4294967295)
      and objid::bigint = (v_key & 4294967295)),
    '14. create_order() took the slot advisory lock inside its own transaction');

  -- 13. full slot rejected, and the rejected order consumed neither a place nor stock
  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(3), '22:00', '22:30');
  perform pg_temp.ok(r.order_id is null and r.code = 'slot_full', '13. full slot rejected (slot_full)');
  perform pg_temp.ok(public.delivery_slot_booked_count(pg_temp.d(3), '22:00', '22:30') = 1,
    '16. the rejected order did not add to the slot usage');
  perform pg_temp.ok((select stock_quantity from public.products
    where id = '00000000-0000-4000-8000-0000000000b1') = v_stock - 1,
    '16. the rejected order did not consume stock (only the one placed order did)');

  -- a cancelled order frees its place (usage definition from 4B.2)
  update public.orders set status = 'cancelled'
    where delivery_method = 'co_pickslot' and delivery_slot_date = pg_temp.d(3)
      and delivery_slot_start = '22:00';
  select * into r from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(3), '22:00', '22:30');
  perform pg_temp.ok(r.order_id is not null, '13. a cancelled order frees its place for a new order');
end $$;

-- ---------------------------------------------------------------------------
-- Idempotent replay must not take a second place
-- ---------------------------------------------------------------------------
do $$
declare a record; b record;
begin
  select * into a from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(4), '21:00', '21:30', null, 'co-key-1');
  select * into b from pg_temp.try_order('co_pickslot', 1, null, pg_temp.d(4), '21:00', '21:30', null, 'co-key-1');
  perform pg_temp.ok(a.order_id is not null and a.order_id = b.order_id,
    'replaying one idempotency key returns the same order');
  perform pg_temp.ok(public.delivery_slot_booked_count(pg_temp.d(4), '21:00', '21:30') = 1,
    'a replayed key does not consume a second place');
end $$;

-- ---------------------------------------------------------------------------
-- Grants: customers can call create_order(); they cannot call the lock directly
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok(has_function_privilege('authenticated',
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)',
    'execute'), 'authenticated may execute create_order()');
  perform pg_temp.ok(not has_function_privilege('anon',
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)',
    'execute'), 'anon may not execute create_order()');
  perform pg_temp.ok(not has_function_privilege('authenticated',
    'public.lock_delivery_slot(date,time,time)', 'execute'),
    'authenticated may not call lock_delivery_slot() directly');
end $$;

do $$ begin raise notice 'ALL CREATE_ORDER DELIVERY TESTS PASSED'; end $$;

rollback;
