-- =============================================================================
-- PHASE 4C.2B database tests: reactivation capacity guard, status/capacity definition,
-- duplicate slot templates, authorisation.
--
-- HOW TO RUN (a Postgres/Supabase DEV database with ALL migrations through
-- 20260930070000_order_reactivation_capacity.sql applied):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/order_reactivation_capacity.test.sql
--
-- One transaction, rolled back at the end. A failed check raises "FAIL: <name>"; every pass
-- prints "PASS: <name>". Reaching "ALL ORDER REACTIVATION TESTS PASSED" means all passed.
-- One session cannot prove the lock holds under a real race: that is
-- db/tests/order_reactivation_concurrency.sh.
--
-- Fixture windows 03:00-04:00 .. 06:00-07:00 do not collide with seeded 08-20 templates or the
-- 4B.2 test's 01:00-02:00 / 12:30-13:30. d(n) = today + n in Africa/Nairobi.
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

-- Runs a statement and returns the P0001 DETAIL code it raised, or 'none'.
create or replace function pg_temp.detail_of(p_sql text)
returns text language plpgsql as $$
declare v_detail text;
begin
  execute p_sql;
  return 'none';
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return coalesce(v_detail, 'error:' || sqlerrm);
end;
$$;

insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('ra_m', 'RA method', 0, null, 0, true, false, true);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000d101', 'ra-customer@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000d102', 'ra-staff@example.test',    'authenticated', 'authenticated');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-00000000d102', 'staff');

insert into public.delivery_slot_templates
  (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
values
  ('00000000-0000-4000-8000-0000000007a1', 'RA cap1',      '03:00', '04:00', null, 1,    100, true),
  ('00000000-0000-4000-8000-0000000007a2', 'RA unlimited', '04:00', '05:00', null, null, 100, true),
  ('00000000-0000-4000-8000-0000000007a3', 'RA zero',      '05:00', '06:00', null, 0,    100, true),
  ('00000000-0000-4000-8000-0000000007a4', 'RA cap2',      '06:00', '07:00', null, 2,    100, true);

create or replace function pg_temp.mk_order(
  p_status public.order_status, p_date date, p_start time, p_end time
) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.orders
    (user_id, order_number, status, payment_method, delivery_method,
     delivery_slot_date, delivery_slot_start, delivery_slot_end)
  values
    ('00000000-0000-4000-8000-00000000d101',
     'RA-' || substr(gen_random_uuid()::text, 1, 12),
     p_status, 'cash_on_delivery', 'ra_m', p_date, p_start, p_end)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.set_status(p_id uuid, p_status public.order_status)
returns text language plpgsql as $$
begin
  return pg_temp.detail_of(format('update public.orders set status = %L where id = %L', p_status, p_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- A. One definition of which statuses hold a slot (tests 7, 8)
-- ---------------------------------------------------------------------------
do $$
declare
  v_status public.order_status;
  v_ok boolean := true;
begin
  perform pg_temp.mk_order('cancelled', pg_temp.d(3), '03:00', '04:00');
  perform pg_temp.mk_order('refunded',  pg_temp.d(3), '03:00', '04:00');
  perform pg_temp.ok(
    public.delivery_slot_booked_count(pg_temp.d(3), '03:00', '04:00') = 0,
    'cancelled and refunded orders do not consume capacity');

  perform pg_temp.mk_order('pending', pg_temp.d(3), '03:00', '04:00');
  perform pg_temp.ok(
    public.delivery_slot_booked_count(pg_temp.d(3), '03:00', '04:00') = 1,
    'an active order consumes capacity');

  -- Every status agrees with the single predicate the count uses.
  foreach v_status in array enum_range(null::public.order_status) loop
    v_ok := v_ok and (public.order_status_holds_delivery_slot(v_status)
                      = (v_status not in ('cancelled', 'refunded')));
  end loop;
  perform pg_temp.ok(v_ok, 'order_status_holds_delivery_slot() holds for every status except cancelled/refunded');

  -- Each holding status really is counted.
  perform pg_temp.mk_order('delivered', pg_temp.d(4), '03:00', '04:00');
  perform pg_temp.mk_order('out_for_delivery', pg_temp.d(4), '03:00', '04:00');
  perform pg_temp.ok(
    public.delivery_slot_booked_count(pg_temp.d(4), '03:00', '04:00') = 2,
    'every non-cancelled/refunded status (delivered, out_for_delivery, ...) is counted');
end $$;

-- ---------------------------------------------------------------------------
-- B. Reactivation cannot overbook (test 9)
-- ---------------------------------------------------------------------------
do $$
declare
  v_active uuid; v_cancelled uuid; v_refunded uuid; v_other uuid;
begin
  -- Capacity 1, slot already taken by an active order.
  v_active    := pg_temp.mk_order('paid',      pg_temp.d(5), '03:00', '04:00');
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(5), '03:00', '04:00');
  v_refunded  := pg_temp.mk_order('refunded',  pg_temp.d(5), '03:00', '04:00');

  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'reactivation_slot_full',
    'cancelled -> active is rejected when the slot is full');
  perform pg_temp.ok(pg_temp.set_status(v_refunded, 'processing') = 'reactivation_slot_full',
    'refunded -> active is rejected when the slot is full');
  perform pg_temp.ok((select status from public.orders where id = v_cancelled) = 'cancelled',
    'a rejected reactivation leaves the order cancelled');
  perform pg_temp.ok(public.delivery_slot_booked_count(pg_temp.d(5), '03:00', '04:00') = 1,
    'a rejected reactivation does not change the booked count');

  -- Free the place: the same transition now succeeds, exactly once.
  update public.orders set status = 'cancelled' where id = v_active;
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'none',
    'cancelled -> active succeeds when there is room');
  perform pg_temp.ok(pg_temp.set_status(v_refunded, 'pending') = 'reactivation_slot_full',
    'a second reactivation is rejected once the first has taken the last place');

  -- Capacity 2 with one active: one more fits, the next does not.
  v_other := pg_temp.mk_order('pending',   pg_temp.d(5), '06:00', '07:00');
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(5), '06:00', '07:00');
  v_refunded  := pg_temp.mk_order('cancelled', pg_temp.d(5), '06:00', '07:00');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'paid') = 'none', 'capacity 2: second place can be reactivated');
  perform pg_temp.ok(pg_temp.set_status(v_refunded, 'paid') = 'reactivation_slot_full', 'capacity 2: third is rejected');

  -- Unlimited capacity: nothing to protect.
  perform pg_temp.mk_order('pending', pg_temp.d(5), '04:00', '05:00');
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(5), '04:00', '05:00');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'none', 'unlimited slot: reactivation allowed');

  -- Closed by capacity 0.
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(5), '05:00', '06:00');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'reactivation_slot_closed',
    'capacity 0 slot: reactivation rejected as closed');

  -- Closed by a date override; an override capacity REPLACES the template capacity.
  insert into public.delivery_slot_overrides (template_id, slot_date, is_active)
    values ('00000000-0000-4000-8000-0000000007a2', pg_temp.d(6), false);
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(6), '04:00', '05:00');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'reactivation_slot_closed',
    'override-closed date: reactivation rejected');

  insert into public.delivery_slot_overrides (template_id, slot_date, capacity)
    values ('00000000-0000-4000-8000-0000000007a2', pg_temp.d(7), 1);
  perform pg_temp.mk_order('pending', pg_temp.d(7), '04:00', '05:00');
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(7), '04:00', '05:00');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'reactivation_slot_full',
    'override capacity (not the template capacity) governs reactivation');
end $$;

-- ---------------------------------------------------------------------------
-- C. Legitimate transitions are untouched
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid; v_b uuid; v_c uuid;
begin
  -- Over capacity already (staff lowered it): forward moves and cancelling still work.
  v_a := pg_temp.mk_order('pending', pg_temp.d(8), '03:00', '04:00');
  v_b := pg_temp.mk_order('pending', pg_temp.d(8), '03:00', '04:00');   -- 2 active, capacity 1
  perform pg_temp.ok(pg_temp.set_status(v_a, 'paid') = 'none', 'active -> active is never blocked');
  perform pg_temp.ok(pg_temp.set_status(v_b, 'cancelled') = 'none', 'active -> cancelled is never blocked');
  perform pg_temp.ok(pg_temp.set_status(v_b, 'refunded') = 'none', 'cancelled -> refunded (non-holding to non-holding) is never blocked');

  -- No slot at all: nothing to protect.
  insert into public.orders (user_id, order_number, status, payment_method, delivery_method)
    values ('00000000-0000-4000-8000-00000000d101', 'RA-noslot-1', 'cancelled', 'cash_on_delivery', 'ra_m')
    returning id into v_c;
  perform pg_temp.ok(pg_temp.set_status(v_c, 'pending') = 'none', 'an order without a slot can be reactivated');

  -- A slot in the PAST has room: the 60-minute lead rule must not apply to an existing order.
  v_c := pg_temp.mk_order('cancelled', pg_temp.d(-10), '04:00', '05:00');
  perform pg_temp.ok(pg_temp.set_status(v_c, 'pending') = 'none',
    'a past slot with room can be reactivated (lead time/horizon are for new bookings)');

  -- A window no active template offers any more: rejected, not silently allowed.
  update public.delivery_slot_templates set is_active = false
    where id = '00000000-0000-4000-8000-0000000007a4';
  v_c := pg_temp.mk_order('cancelled', pg_temp.d(9), '06:00', '07:00');
  perform pg_temp.ok(pg_temp.set_status(v_c, 'pending') = 'reactivation_slot_not_offered',
    'a slot no active template offers cannot be reactivated');
  update public.delivery_slot_templates set is_active = true
    where id = '00000000-0000-4000-8000-0000000007a4';
end $$;

-- ---------------------------------------------------------------------------
-- D. Duplicate slot templates (tests 11, 12)
--    generic  A: any weekday, 07:00-08:00, position 50, capacity 5
--    specific B: only d(10)'s weekday, same window, position 5, capacity 1
-- ---------------------------------------------------------------------------
do $$
declare
  v_dow integer := extract(dow from pg_temp.d(10))::integer;
  r record;
  v_n integer;
  v_cancelled uuid;
begin
  insert into public.delivery_slot_templates
    (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
  values
    ('00000000-0000-4000-8000-0000000007b1', 'RA generic',  '07:00', '07:30', null,  5, 50, true),
    ('00000000-0000-4000-8000-0000000007b2', 'RA specific', '07:00', '07:30', v_dow, 1, 5,  true);

  -- Checkout's rule: lowest position wins.
  select * into r from public.delivery_slot_evaluate(pg_temp.d(10), '07:00', '07:30');
  perform pg_temp.ok(r.template_id = '00000000-0000-4000-8000-0000000007b2' and r.capacity = 1,
    'duplicate windows: the lowest-position template governs on its weekday');
  select * into r from public.delivery_slot_evaluate(pg_temp.d(11), '07:00', '07:30');
  perform pg_temp.ok(r.template_id = '00000000-0000-4000-8000-0000000007b1' and r.capacity = 5,
    'duplicate windows: the generic template governs on other weekdays');

  -- Availability lists the window ONCE, with the winner's capacity.
  select count(*) into v_n from public.get_delivery_slot_availability(pg_temp.d(10), pg_temp.d(10))
    where start_time = '07:00' and end_time = '07:30';
  perform pg_temp.ok(v_n = 1, 'availability lists a duplicated window once');
  select * into r from public.get_delivery_slot_availability(pg_temp.d(10), pg_temp.d(10))
    where start_time = '07:00' and end_time = '07:30';
  perform pg_temp.ok(r.template_id = '00000000-0000-4000-8000-0000000007b2' and r.capacity = 1,
    'availability advertises the winning template, not the shadowed one');

  -- Fill the winner (capacity 1). The shadowed template has room (5) but must not be advertised.
  perform pg_temp.mk_order('pending', pg_temp.d(10), '07:00', '07:30');
  select * into r from public.get_delivery_slot_availability(pg_temp.d(10), pg_temp.d(10))
    where start_time = '07:00' and end_time = '07:30';
  perform pg_temp.ok(r.is_available is false and r.remaining = 0,
    'a full winning template is not advertised as usable because a shadowed one has room');
  select * into r from public.delivery_slot_evaluate(pg_temp.d(10), '07:00', '07:30');
  perform pg_temp.ok(r.error_code = 'slot_full', 'checkout validation agrees: the window is full');

  -- Reactivation uses the same winner.
  v_cancelled := pg_temp.mk_order('cancelled', pg_temp.d(10), '07:00', '07:30');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'reactivation_slot_full',
    'reactivation uses the winning template''s capacity too');

  -- Deactivate the winner: the generic template takes over everywhere, consistently.
  update public.delivery_slot_templates set is_active = false
    where id = '00000000-0000-4000-8000-0000000007b2';
  select * into r from public.get_delivery_slot_availability(pg_temp.d(10), pg_temp.d(10))
    where start_time = '07:00' and end_time = '07:30';
  perform pg_temp.ok(r.template_id = '00000000-0000-4000-8000-0000000007b1' and r.is_available is true,
    'with the winner inactive the next template is advertised');
  perform pg_temp.ok(pg_temp.set_status(v_cancelled, 'pending') = 'none',
    'and reactivation then uses that template''s capacity');

  -- No uniqueness constraint was added: both rows exist side by side.
  perform pg_temp.ok(
    (select count(*) from public.delivery_slot_templates
      where start_time = '07:00' and end_time = '07:30') = 2,
    'duplicate windows remain allowed (no uniqueness constraint)');
end $$;

-- ---------------------------------------------------------------------------
-- E. Authorisation
-- ---------------------------------------------------------------------------
do $$
declare
  v_order uuid;
  v_n integer;
  v_threw boolean;
begin
  update public.delivery_slot_templates set capacity = 1 where id = '00000000-0000-4000-8000-0000000007a1';
  perform pg_temp.mk_order('pending', pg_temp.d(12), '03:00', '04:00');
  v_order := pg_temp.mk_order('cancelled', pg_temp.d(12), '03:00', '04:00');

  -- Staff session: the guard applies through the real RLS path.
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000d102","role":"authenticated"}', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000d102', true);
  set local role authenticated;
  v_threw := false;
  begin
    update public.orders set status = 'pending' where id = v_order;
  exception when others then v_threw := true;
  end;
  reset role;
  perform pg_temp.ok(v_threw, 'a staff session cannot reactivate into a full slot');

  -- Customer session: cannot change any order (RLS), so cannot reactivate their own.
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000d101","role":"authenticated"}', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000d101', true);
  set local role authenticated;
  update public.orders set status = 'pending' where id = v_order;
  get diagnostics v_n = row_count;
  reset role;
  perform pg_temp.ok(v_n = 0, 'a customer cannot update an order status at all');

  -- The internal helpers are not callable by clients.
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000d101","role":"authenticated"}', true);
  set local role authenticated;
  v_threw := false;
  begin
    perform public.delivery_slot_acquire_lock(pg_temp.d(12), '03:00', '04:00');
  exception when insufficient_privilege then v_threw := true;
  end;
  reset role;
  perform pg_temp.ok(v_threw, 'delivery_slot_acquire_lock() is not executable by clients');

  -- Customers still cannot touch templates, overrides, methods, zones.
  set local role authenticated;
  v_threw := false;
  begin
    update public.delivery_slot_templates set capacity = 999;
    get diagnostics v_n = row_count;
    v_threw := (v_n = 0);
  exception when insufficient_privilege then v_threw := true;
  end;
  reset role;
  perform pg_temp.ok(v_threw, 'a customer cannot change slot templates');
end $$;

do $$ begin raise notice 'ALL ORDER REACTIVATION TESTS PASSED'; end $$;

rollback;
