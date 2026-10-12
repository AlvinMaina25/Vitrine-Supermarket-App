-- =============================================================================
-- PHASE 4B.2 database tests: slot validation, capacity, usage, lock, authorisation.
--
-- STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
--
-- HOW TO RUN (needs a Supabase/Postgres database with ALL migrations through
-- 20260930050000_delivery_slot_validation.sql applied; use a dev or branch database):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/delivery_slot_validation.test.sql
--
-- Everything runs in ONE transaction that is rolled back at the end. Any failed check raises
-- "FAIL: <name>" and aborts the run; every passing check prints "PASS: <name>". Reaching the
-- final "ALL DELIVERY SLOT TESTS PASSED" notice means every check passed.
--
-- This file proves the rules. It cannot prove the lock holds against a REAL race, because it
-- is one session. That is db/tests/delivery_slot_concurrency.sh (also not yet executed).
--
-- Dates are relative to "today" in Africa/Nairobi (the store clock create_order() uses), so the
-- script works on any day. d(n) = today + n. Fixture windows (01:00-07:30 and 12:30-13:30) do
-- not collide with the seeded 08-11 / 11-14 / 14-17 / 17-20 templates.
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
-- Fixtures (inserted as the migration owner, which bypasses RLS)
-- ---------------------------------------------------------------------------
insert into public.delivery_methods
  (code, label, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, is_active)
values ('ss_m', 'SS method', 0, null, 0, true, false, true);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000c101', 'ss-customer@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000c102', 'ss-staff@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000c103', 'ss-admin@example.test',    'authenticated', 'authenticated');

insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-00000000c102', 'staff'),
  ('00000000-0000-4000-8000-00000000c103', 'admin');

insert into public.delivery_slot_templates
  (id, label, start_time, end_time, day_of_week, capacity, position, is_active)
values
  -- a1: capped at 3
  ('00000000-0000-4000-8000-0000000005a1', 'SS cap3',     '01:00', '02:00', null, 3,    100, true),
  -- a2: unlimited
  ('00000000-0000-4000-8000-0000000005a2', 'SS unlimited','02:00', '03:00', null, null, 100, true),
  -- a3: capacity 0 = closed
  ('00000000-0000-4000-8000-0000000005a3', 'SS zero',     '03:00', '04:00', null, 0,    100, true),
  -- a4: inactive
  ('00000000-0000-4000-8000-0000000005a4', 'SS inactive', '04:00', '05:00', null, 5,    100, false),
  -- a5: only on the weekday of d(4)
  ('00000000-0000-4000-8000-0000000005a5', 'SS weekday',  '05:00', '06:00',
     extract(dow from pg_temp.d(4))::smallint, 5, 100, true),
  -- a6: capacity 5, with per-date overrides below
  ('00000000-0000-4000-8000-0000000005a6', 'SS override', '06:00', '07:00', null, 5,    100, true),
  -- a7: unlimited template that an override caps on d(3)
  ('00000000-0000-4000-8000-0000000005a7', 'SS unl+ovr',  '07:00', '07:30', null, null, 100, true),
  -- a8 / a9: two active templates sharing one window; create_order() picks the lowest position
  ('00000000-0000-4000-8000-0000000005a8', 'SS dup first','12:30', '13:30', null, 1,    100, true),
  ('00000000-0000-4000-8000-0000000005a9', 'SS dup second','12:30','13:30', null, 9,    101, true),
  -- c1 / c2: authorisation fixtures (one per role under test)
  ('00000000-0000-4000-8000-0000000005c1', 'SS auth staff','15:00', '15:30', null, 4,   100, true),
  ('00000000-0000-4000-8000-0000000005c2', 'SS auth admin','15:30', '16:00', null, 4,   100, true);

insert into public.delivery_slot_overrides (template_id, slot_date, capacity, is_active) values
  ('00000000-0000-4000-8000-0000000005a6', pg_temp.d(3), null, false),  -- closed that date
  ('00000000-0000-4000-8000-0000000005a6', pg_temp.d(4), 1,    true),   -- lowered to 1
  ('00000000-0000-4000-8000-0000000005a6', pg_temp.d(5), 0,    true),   -- capacity 0 = closed
  ('00000000-0000-4000-8000-0000000005a6', pg_temp.d(6), null, true),   -- inherits the template
  ('00000000-0000-4000-8000-0000000005a6', pg_temp.d(7), 20,   true),   -- raised above the template
  ('00000000-0000-4000-8000-0000000005a7', pg_temp.d(3), 2,    true);   -- caps an unlimited template

-- Helper: place an order that holds (or does not hold) a slot, as the owner.
create or replace function pg_temp.mk(
  p_date date, p_start time, p_end time, p_status public.order_status default 'pending'
) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.orders
    (user_id, order_number, status, payment_method, delivery_method,
     delivery_slot_date, delivery_slot_start, delivery_slot_end)
  values
    ('00000000-0000-4000-8000-00000000c101',
     'SS-' || substr(gen_random_uuid()::text, 1, 12),
     p_status, 'cash_on_delivery', 'ss_m', p_date, p_start, p_end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Valid available slot, identity and numbers
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.is_valid and r.error_code is null, 'valid available slot is accepted');
  perform pg_temp.ok(r.template_id = '00000000-0000-4000-8000-0000000005a1' and r.label = 'SS cap3',
    'valid slot returns the template identity');
  perform pg_temp.ok(r.slot_date = pg_temp.d(3) and r.slot_start = '01:00' and r.slot_end = '02:00',
    'valid slot returns the requested date and window');
  perform pg_temp.ok(r.capacity = 3 and r.capacity_source = 'template' and not r.is_unlimited,
    'valid slot reports template capacity');
  perform pg_temp.ok(r.booked_count = 0 and r.remaining = 3 and not r.is_closed and not r.is_full,
    'empty slot: nothing booked, full capacity remaining');
  perform pg_temp.ok(
    (select count(*) from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00')) = 1,
    'validation always returns exactly one row');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Rejections that do not depend on usage
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '23:00', '23:30');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_unknown' and r.template_id is null,
    'unknown slot window is rejected with no template');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '05:00', '06:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_unknown',
    'template for a different weekday is unknown on this date');
  select * into r from public.validate_delivery_slot(pg_temp.d(4), '05:00', '06:00');
  perform pg_temp.ok(r.is_valid, 'the same weekday template is valid on its own weekday');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '04:00', '05:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_inactive' and r.template_id is null,
    'inactive template is rejected as inactive (not unknown)');

  select * into r from public.validate_delivery_slot(null, '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_required', 'NULL date is rejected');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), null, '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_required', 'NULL start is rejected');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', null);
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_required', 'NULL end is rejected');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '02:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'invalid_window', 'empty window is rejected');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '03:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'invalid_window', 'reversed window is rejected');

  select * into r from public.validate_delivery_slot(pg_temp.d(-1), '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_in_past', 'yesterday is rejected');
  -- 00:00 today is always earlier than now + 60 minutes
  select * into r from public.validate_delivery_slot(pg_temp.d(0), '00:00', '01:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_in_past',
    'a slot starting inside the 60-minute lead time is rejected');

  select * into r from public.validate_delivery_slot(pg_temp.d(15), '02:00', '03:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_too_far', 'beyond the 14-day horizon is rejected');
  select * into r from public.validate_delivery_slot(pg_temp.d(14), '02:00', '03:00');
  perform pg_temp.ok(r.is_valid, 'exactly 14 days ahead is accepted');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Capacity 0, overrides, unlimited (no orders involved yet)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '03:00', '04:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_closed' and r.is_closed
    and r.capacity = 0 and r.remaining = 0 and not r.is_full,
    'template capacity 0 is closed (not "full")');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '06:00', '07:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_closed' and r.is_closed,
    'date override with is_active = false closes the slot');

  select * into r from public.validate_delivery_slot(pg_temp.d(5), '06:00', '07:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_closed' and r.capacity = 0
    and r.capacity_source = 'override',
    'date override capacity 0 closes the slot');

  select * into r from public.validate_delivery_slot(pg_temp.d(4), '06:00', '07:00');
  perform pg_temp.ok(r.is_valid and r.capacity = 1 and r.capacity_source = 'override' and r.remaining = 1,
    'date override capacity replaces a larger template capacity');

  select * into r from public.validate_delivery_slot(pg_temp.d(6), '06:00', '07:00');
  perform pg_temp.ok(r.is_valid and r.capacity = 5 and r.capacity_source = 'template',
    'override with NULL capacity inherits the template capacity');

  select * into r from public.validate_delivery_slot(pg_temp.d(7), '06:00', '07:00');
  perform pg_temp.ok(r.is_valid and r.capacity = 20 and r.capacity_source = 'override',
    'a positive override replaces the template capacity even when higher');

  select * into r from public.validate_delivery_slot(pg_temp.d(8), '06:00', '07:00');
  perform pg_temp.ok(r.is_valid and r.capacity = 5 and r.capacity_source = 'template',
    'a date with no override uses the template capacity');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '02:00', '03:00');
  perform pg_temp.ok(r.is_valid and r.capacity is null and r.remaining is null and r.is_unlimited,
    'NULL capacity is unlimited (null capacity, null remaining)');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '07:00', '07:30');
  perform pg_temp.ok(r.is_valid and r.capacity = 2 and r.capacity_source = 'override' and not r.is_unlimited,
    'an override can cap an unlimited template on one date');
  select * into r from public.validate_delivery_slot(pg_temp.d(4), '07:00', '07:30');
  perform pg_temp.ok(r.is_valid and r.is_unlimited, 'the same template stays unlimited on other dates');

  -- two templates share a window: the lowest position decides, as create_order() does
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '12:30', '13:30');
  perform pg_temp.ok(r.is_valid and r.template_id = '00000000-0000-4000-8000-0000000005a8' and r.capacity = 1,
    'shared window resolves to the lowest-position template (same choice as create_order())');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Usage: which orders consume capacity
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'cancelled');
  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'refunded');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.booked_count = 0 and r.remaining = 3 and r.is_valid,
    'cancelled and refunded orders do not consume capacity');

  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.booked_count = 1 and r.remaining = 2 and r.is_valid,
    'an active order consumes capacity and remaining is capacity - booked');

  -- every status other than cancelled/refunded holds the slot (unlimited slot so it stays valid)
  perform pg_temp.mk(pg_temp.d(8), '02:00', '03:00', s)
    from unnest(enum_range(null::public.order_status)) as s
    where s not in ('cancelled', 'refunded');
  perform pg_temp.mk(pg_temp.d(8), '02:00', '03:00', 'cancelled');
  perform pg_temp.mk(pg_temp.d(8), '02:00', '03:00', 'refunded');
  select * into r from public.validate_delivery_slot(pg_temp.d(8), '02:00', '03:00');
  perform pg_temp.ok(r.booked_count = 9 and r.is_valid,
    'all nine non-cancelled/non-refunded statuses consume capacity, the two excluded ones do not');

  -- usage is per date and per window
  perform pg_temp.mk(pg_temp.d(9), '01:00', '02:00', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.booked_count = 1, 'an order on another date does not consume this date');
  perform pg_temp.mk(pg_temp.d(3), '02:00', '03:00', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.booked_count = 1, 'an order in another window does not consume this window');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Becoming full, staying full, and releasing a place
-- ---------------------------------------------------------------------------
do $$
declare r record; v_first uuid; v_second uuid;
begin
  v_first := pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'paid');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.is_valid and r.booked_count = 2 and r.remaining = 1, 'one place left before the last order');

  v_second := pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full' and r.is_full and not r.is_closed
    and r.booked_count = 3 and r.remaining = 0 and r.capacity = 3,
    'slot becomes full exactly at capacity');

  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full', 'slot remains unavailable on a repeat check');
  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'cancelled');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full' and r.booked_count = 3,
    'a new cancelled order does not reopen a full slot');
  perform pg_temp.ok(
    (select not is_available from public.get_delivery_slot_availability(pg_temp.d(3), pg_temp.d(3))
      where template_id = '00000000-0000-4000-8000-0000000005a1'),
    'the availability listing also shows the full slot as unavailable');

  update public.orders set status = 'cancelled' where id = v_second;
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.is_valid and r.booked_count = 2 and r.remaining = 1,
    'cancelling an active order releases its place');

  update public.orders set status = 'refunded' where id = v_first;
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.is_valid and r.booked_count = 1 and r.remaining = 2,
    'refunding an active order releases its place');
end $$;

-- override-lowered capacity fills at the override, not the template
do $$
declare r record;
begin
  perform pg_temp.mk(pg_temp.d(4), '06:00', '07:00', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(4), '06:00', '07:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full' and r.capacity = 1,
    'a slot fills at the override capacity, not the larger template capacity');

  perform pg_temp.mk(pg_temp.d(3), '07:00', '07:30', 'pending');
  perform pg_temp.mk(pg_temp.d(3), '07:00', '07:30', 'pending');
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '07:00', '07:30');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full' and r.capacity = 2,
    'an override that caps an unlimited template is enforced');

  -- a closed slot stays closed even when it has room
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '06:00', '07:00');
  perform pg_temp.ok(r.error_code = 'slot_closed' and r.booked_count = 0,
    'a closed slot reports closed (with its usage), not full');
end $$;

-- ---------------------------------------------------------------------------
-- 6. The listing and the validator agree (one definition of capacity and usage)
-- ---------------------------------------------------------------------------
do $$
declare r record; v_diff integer;
begin
  select count(*) into v_diff
  from public.get_delivery_slot_availability(pg_temp.d(3), pg_temp.d(4)) a
  cross join lateral public.validate_delivery_slot(a.slot_date, a.start_time, a.end_time) v
  where a.template_id::text like '00000000-0000-4000-8000-0000000005%'
    -- a9 shares a window with a8; the listing shows both rows, but validation (like
    -- create_order()) resolves that window to the lowest-position template, a8.
    and a.template_id <> '00000000-0000-4000-8000-0000000005a9'
    and (a.is_available is distinct from v.is_valid
      or a.capacity is distinct from v.capacity
      or a.booked_count is distinct from v.booked_count
      or a.remaining is distinct from v.remaining);
  perform pg_temp.ok(v_diff = 0, 'listing and validator agree on availability, capacity, usage and remaining');

  perform pg_temp.ok(not exists (
    select 1 from public.get_delivery_slot_availability(pg_temp.d(3), pg_temp.d(3))
    where template_id = '00000000-0000-4000-8000-0000000005a6'),
    'the listing omits a slot closed by a date override');

  select * into r from public.get_delivery_slot_availability(pg_temp.d(3), pg_temp.d(3))
  where template_id = '00000000-0000-4000-8000-0000000005a3';
  perform pg_temp.ok(r.capacity = 0 and r.remaining = 0 and not r.is_available,
    'the listing shows a capacity-0 slot as unavailable');

  perform pg_temp.ok(not exists (
    select 1 from public.get_delivery_slot_availability(pg_temp.d(3), pg_temp.d(3))
    where template_id = '00000000-0000-4000-8000-0000000005a4'),
    'the listing omits inactive templates');
end $$;

-- ---------------------------------------------------------------------------
-- 7. The lock: taken, keyed on the slot, reentrant, and it validates after locking
--    (Single-session checks only. Whether it blocks a REAL second session is the job of
--    delivery_slot_concurrency.sh.)
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_before integer;
  v_key bigint;
begin
  select count(*) into v_before from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();

  select * into r from public.lock_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(r.is_valid and r.slot_date = pg_temp.d(3),
    'lock_delivery_slot() validates and returns the same row as validation');
  perform pg_temp.ok(
    (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) = v_before + 1,
    'lock_delivery_slot() takes one advisory lock');

  v_key := hashtextextended('delivery_slot:' || pg_temp.d(3)::text || ':01:00:00:02:00:00', 4202);
  perform pg_temp.ok(exists (
    select 1 from pg_locks
    where locktype = 'advisory' and pid = pg_backend_pid() and granted
      and classid::bigint = ((v_key >> 32) & 4294967295)
      and objid::bigint = (v_key & 4294967295)),
    'the lock key is derived from the slot date, start and end');

  perform * from public.lock_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(
    (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) = v_before + 1,
    'locking the same slot again is reentrant (same key)');

  perform * from public.lock_delivery_slot(pg_temp.d(3), '02:00', '03:00');
  perform pg_temp.ok(
    (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) = v_before + 2,
    'a different window takes a different lock');

  perform * from public.lock_delivery_slot(pg_temp.d(4), '01:00', '02:00');
  perform pg_temp.ok(
    (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) = v_before + 3,
    'a different date takes a different lock');

  -- a rejected slot still locks (the caller decides what to do) and reports why
  select * into r from public.lock_delivery_slot(pg_temp.d(3), '03:00', '04:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_closed',
    'lock_delivery_slot() reports a closed slot as rejected');

  select * into r from public.lock_delivery_slot(null, '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_required',
    'lock_delivery_slot() with a NULL date rejects without a key');
  perform pg_temp.ok(
    (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()) = v_before + 4,
    'a NULL date does not take a lock (4 distinct slot locks were taken above)');

  -- the re-check sees an order created after an earlier read (what the lock exists for)
  select * into r from public.validate_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'pending');
  perform pg_temp.mk(pg_temp.d(3), '01:00', '02:00', 'pending');
  select * into r from public.lock_delivery_slot(pg_temp.d(3), '01:00', '02:00');
  perform pg_temp.ok(not r.is_valid and r.error_code = 'slot_full',
    'the locked re-check counts orders created since an earlier read');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Authorisation
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok(has_function_privilege('anon', 'public.validate_delivery_slot(date,time,time)', 'execute')
    and has_function_privilege('authenticated', 'public.validate_delivery_slot(date,time,time)', 'execute'),
    'customers and visitors can read slot validation');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.lock_delivery_slot(date,time,time)', 'execute')
    and not has_function_privilege('authenticated', 'public.lock_delivery_slot(date,time,time)', 'execute'),
    'customers and visitors cannot execute lock_delivery_slot()');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.delivery_slot_evaluate(date,time,time)', 'execute')
    and not has_function_privilege('authenticated', 'public.delivery_slot_booked_count(date,time,time)', 'execute')
    and not has_function_privilege('authenticated', 'public.delivery_slot_effective_capacity(uuid,date)', 'execute'),
    'customers cannot execute the internal slot helpers');
end $$;

do $$
declare
  v_customer text := '00000000-0000-4000-8000-00000000c101';
  r1 boolean; r2 boolean; r3 boolean; r4 boolean; r5 boolean; r6 boolean;
  n integer;
  v_valid boolean;
  v_d5 date := pg_temp.d(5);
  v_d10 date := pg_temp.d(10);
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_customer, true);
  set local role authenticated;

  begin
    update public.delivery_slot_templates set capacity = 99
      where id = '00000000-0000-4000-8000-0000000005c1';
    get diagnostics n = row_count;
    r1 := (n = 0);
  exception when insufficient_privilege then r1 := true; end;

  begin
    update public.delivery_slot_templates set is_active = false
      where id = '00000000-0000-4000-8000-0000000005c1';
    get diagnostics n = row_count;
    r2 := (n = 0);
  exception when insufficient_privilege then r2 := true; end;

  begin
    insert into public.delivery_slot_overrides (template_id, slot_date, capacity)
    values ('00000000-0000-4000-8000-0000000005c1', v_d5, 1);
    r3 := false;
  exception when insufficient_privilege then r3 := true; end;

  begin
    update public.delivery_slot_overrides set capacity = 99
      where template_id = '00000000-0000-4000-8000-0000000005a6';
    get diagnostics n = row_count;
    r4 := (n = 0);
  exception when insufficient_privilege then r4 := true; end;

  r5 := not exists (select 1 from public.delivery_slot_overrides);

  begin
    perform * from public.lock_delivery_slot(v_d10, '02:00', '03:00');
    r6 := false;
  exception when insufficient_privilege then r6 := true; end;

  select is_valid into v_valid from public.validate_delivery_slot(v_d10, '02:00', '03:00');

  reset role;

  perform pg_temp.ok(r1, 'a customer cannot change slot capacity');
  perform pg_temp.ok(r2, 'a customer cannot activate or deactivate a slot');
  perform pg_temp.ok(r3, 'a customer cannot create an override');
  perform pg_temp.ok(r4, 'a customer cannot modify an override');
  perform pg_temp.ok(r5, 'a customer cannot read overrides');
  perform pg_temp.ok(r6, 'a customer cannot call lock_delivery_slot() as an RPC');
  perform pg_temp.ok(v_valid is true, 'a customer can read slot validation');
  perform pg_temp.ok(
    (select capacity from public.delivery_slot_templates
       where id = '00000000-0000-4000-8000-0000000005c1') = 4,
    'the customer attempts left the capacity unchanged');
end $$;

do $$
declare
  v_user text;
  v_template uuid;
  v_start time;
  v_end time;
  v_names text[] := '{}';
  v_pass boolean[] := '{}';
  n integer;
  r record;
  i integer;
  v_d5 date := pg_temp.d(5);
  v_d6 date := pg_temp.d(6);
begin
  for i in 1 .. 2 loop
    v_user := case i when 1 then '00000000-0000-4000-8000-00000000c102'
                              else '00000000-0000-4000-8000-00000000c103' end;
    v_template := case i when 1 then '00000000-0000-4000-8000-0000000005c1'::uuid
                                else '00000000-0000-4000-8000-0000000005c2'::uuid end;
    v_start := case i when 1 then time '15:00' else time '15:30' end;
    v_end := case i when 1 then time '15:30' else time '16:00' end;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_user, true);
    set local role authenticated;

    update public.delivery_slot_templates set capacity = 2 where id = v_template;
    get diagnostics n = row_count;
    v_names := v_names || format('%s can change slot capacity', v_user); v_pass := v_pass || (n = 1);

    insert into public.delivery_slot_overrides (template_id, slot_date, capacity)
    values (v_template, v_d5, 1);
    get diagnostics n = row_count;
    v_names := v_names || format('%s can create an override', v_user); v_pass := v_pass || (n = 1);

    update public.delivery_slot_overrides set capacity = 0
      where template_id = v_template and slot_date = v_d5;
    get diagnostics n = row_count;
    v_names := v_names || format('%s can modify an override', v_user); v_pass := v_pass || (n = 1);

    v_names := v_names || format('%s can read overrides', v_user);
    v_pass := v_pass || exists (select 1 from public.delivery_slot_overrides where template_id = v_template);

    reset role;

    -- the staff edits are what validation then uses
    select * into r from public.validate_delivery_slot(v_d6, v_start, v_end);
    v_names := v_names || format('%s: validation reflects the new template capacity', v_user);
    v_pass := v_pass || (r.is_valid and r.capacity = 2);

    select * into r from public.validate_delivery_slot(v_d5, v_start, v_end);
    v_names := v_names || format('%s: validation reflects the new override', v_user);
    v_pass := v_pass || (not r.is_valid and r.error_code = 'slot_closed');

    set local role authenticated;
    update public.delivery_slot_templates set is_active = false where id = v_template;
    get diagnostics n = row_count;
    reset role;
    v_names := v_names || format('%s can deactivate a slot', v_user); v_pass := v_pass || (n = 1);

    select * into r from public.validate_delivery_slot(v_d6, v_start, v_end);
    v_names := v_names || format('%s: a deactivated slot is then rejected as inactive', v_user);
    v_pass := v_pass || (not r.is_valid and r.error_code = 'slot_inactive');
  end loop;

  for i in 1 .. coalesce(array_length(v_names, 1), 0) loop
    perform pg_temp.ok(v_pass[i], v_names[i]);
  end loop;
end $$;

do $$ begin raise notice 'ALL DELIVERY SLOT TESTS PASSED'; end $$;

rollback;
