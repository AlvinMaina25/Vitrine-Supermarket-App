-- =============================================================================
-- Order reactivation capacity guard (PHASE 4C.2B).
--
-- STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
--
-- Apply AFTER 20260930060000_create_order_delivery_integration.sql.
-- Idempotent (create or replace / drop trigger if exists). No table, column, policy or
-- grant changes; no data is rewritten.
--
-- THE PROBLEM
--   A slot's capacity is consumed by every order whose status is not cancelled/refunded
--   (delivery_slot_booked_count(), 20260930050000). The "Orders: staff update" policy plus
--   `grant update (status)` let staff set orders.status to ANY value, including moving a
--   cancelled/refunded order back to an active status. That UPDATE inserts nothing, takes no
--   slot lock and checks no capacity, so it could push a slot past its effective capacity
--   (migration 20260930050000 invariant "d" flagged exactly this path as unprotected).
--   There is no order-status RPC and no application code that updates status today: the only
--   write path is a direct UPDATE, so the guard lives in a trigger and covers every caller
--   (browser staff session, service role, SQL editor).
--
-- THE FIX
--   BEFORE UPDATE OF status trigger on public.orders. It acts ONLY when an order moves from a
--   non-holding status (cancelled/refunded) to a holding one AND the order has a complete
--   slot (date + start + end). Every other transition returns immediately and is untouched:
--   forward fulfilment moves, cancelling, and anything on an order without a slot.
--   For a guarded transition it
--     1. takes the SAME per-slot advisory lock create_order() takes (shared helper below),
--     2. THEN, in later statements, re-reads the effective capacity and the booked count,
--     3. raises (rolling the UPDATE back) when the slot is closed, full or no longer offered.
--
-- WHAT IT DELIBERATELY DOES NOT CHECK
--   The 60-minute lead time and 14-day horizon are rules for NEW bookings. The order already
--   holds that date; reactivating it must not fail merely because the slot is now in the
--   past or because the horizon has moved. Only capacity (and closure) matters here.
--
-- ONE DEFINITION OF EACH THING
--   * Which statuses hold a slot: order_status_holds_delivery_slot() below. The booked count
--     now calls it, and so does the trigger. Same predicate as before (not in
--     ('cancelled','refunded')); it is just no longer written inline in two places.
--   * The lock key: delivery_slot_acquire_lock() below. lock_delivery_slot() now calls it, so
--     checkout and reactivation cannot drift apart. The key text is unchanged.
--   * Capacity and usage: delivery_slot_effective_capacity() and delivery_slot_booked_count(),
--     unchanged.
--   * Template choice: lowest position, then id, among ACTIVE templates with this exact
--     start/end and a weekday of NULL or the date's weekday (same rule as
--     delivery_slot_evaluate() and create_order()).
--
-- CONCURRENCY (see db/tests/order_reactivation_capacity.test.sql and
-- db/tests/order_reactivation_concurrency.sh)
--   * checkout vs reactivation: both take the same advisory lock, then count. The second one
--     waits, then counts the first one's committed row. READ COMMITTED gives each later
--     statement a fresh snapshot, so the post-lock count sees it. A stricter isolation level
--     is refused (same as lock_delivery_slot()).
--   * two reactivations: same lock, serialised; the second sees the first.
--   * the row being reactivated is NOT counted while the check runs (it still has its old,
--     non-holding status in the table), so `booked >= capacity` is the right test.
--   * lock order: UPDATE locks the order row, then this trigger takes the slot lock.
--     Checkout takes the slot lock and only inserts a NEW row, so it never waits on an
--     existing order row: no lock cycle with checkout. Two multi-row UPDATEs touching the
--     same slots in opposite order could still deadlock; PostgreSQL aborts one of them, and
--     nothing is overbooked.
--
-- DUPLICATE SLOT TEMPLATES (section 4)
--   Several ACTIVE templates may share a weekday/start/end on purpose (a generic template plus
--   a lower-position weekday-specific one with a different capacity); NO uniqueness constraint
--   is added. Checkout always uses the lowest (position, id) match. get_delivery_slot_availability()
--   used to list EVERY matching template, so a shadowed template showed its own, possibly larger,
--   capacity as available while create_order() would reject the window as full. Section 4 lists
--   only the winning template per date and window. Same signature, columns and grants.
--
-- STOCK IS OUT OF SCOPE. Cancelling restocks (restock_cancelled_order()); moving the order
-- back to an active status does NOT re-reserve stock (documented in 20260930020000). This
-- migration does not change that.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The single definition of "this status holds its delivery slot"
-- ---------------------------------------------------------------------------
create or replace function public.order_status_holds_delivery_slot(p_status public.order_status)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  select p_status not in ('cancelled', 'refunded');
$$;

revoke execute on function public.order_status_holds_delivery_slot(public.order_status)
  from public, anon, authenticated;

-- Same result as before: orders not cancelled/refunded. Only the predicate's home changed.
create or replace function public.delivery_slot_booked_count(
  p_slot_date date,
  p_slot_start time,
  p_slot_end time
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.orders ord
  where ord.delivery_slot_date = p_slot_date
    and ord.delivery_slot_start = p_slot_start
    and ord.delivery_slot_end = p_slot_end
    and public.order_status_holds_delivery_slot(ord.status);
$$;

revoke execute on function public.delivery_slot_booked_count(date, time, time)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The single definition of the slot lock (key text and seed unchanged)
-- ---------------------------------------------------------------------------
-- The isolation-level error text is unchanged from lock_delivery_slot() (tests grep for it).
create or replace function public.delivery_slot_acquire_lock(
  p_slot_date date,
  p_slot_start time,
  p_slot_end time
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception
      'lock_delivery_slot() requires READ COMMITTED (found %); a stricter snapshot cannot see orders committed while waiting for the slot lock.',
      current_setting('transaction_isolation')
      using errcode = '25000';
  end if;

  if p_slot_date is not null and p_slot_start is not null and p_slot_end is not null then
    perform pg_advisory_xact_lock(
      hashtextextended(
        'delivery_slot:' || p_slot_date::text || ':' || p_slot_start::text || ':' || p_slot_end::text,
        4202
      )
    );
  end if;
end;
$$;

revoke execute on function public.delivery_slot_acquire_lock(date, time, time)
  from public, anon, authenticated;

-- lock_delivery_slot(): same signature, same behaviour, same error text for a stricter
-- isolation level is now raised by the shared helper. Still not granted to clients.
create or replace function public.lock_delivery_slot(
  p_slot_date date,
  p_slot_start time,
  p_slot_end time
)
returns table (
  is_valid boolean,
  error_code text,
  error_message text,
  slot_date date,
  slot_start time,
  slot_end time,
  template_id uuid,
  label text,
  capacity integer,
  capacity_source text,
  booked_count integer,
  remaining integer,
  is_unlimited boolean,
  is_closed boolean,
  is_full boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public.delivery_slot_acquire_lock(p_slot_date, p_slot_start, p_slot_end);

  return query
  select * from public.delivery_slot_evaluate(p_slot_date, p_slot_start, p_slot_end);
end;
$$;

revoke execute on function public.lock_delivery_slot(date, time, time)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The guard
-- ---------------------------------------------------------------------------
create or replace function public.guard_order_reactivation_capacity()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_template_id uuid;
  v_cap integer;
  v_override_closed boolean;
  v_booked integer;
begin
  -- Only non-holding -> holding.
  if public.order_status_holds_delivery_slot(old.status) is not false
     or public.order_status_holds_delivery_slot(new.status) is not true then
    return new;
  end if;

  -- An order without a complete slot (pickup, or placed before slots existed) holds nothing.
  if new.delivery_slot_date is null
     or new.delivery_slot_start is null
     or new.delivery_slot_end is null then
    return new;
  end if;

  -- 1. Same lock create_order() takes. Statements below run AFTER it is granted, so under
  --    READ COMMITTED they see everything the previous holder committed.
  perform public.delivery_slot_acquire_lock(
    new.delivery_slot_date, new.delivery_slot_start, new.delivery_slot_end
  );

  -- 2. The template that governs this window today (lowest position wins).
  select t.id into v_template_id
  from public.delivery_slot_templates t
  where t.is_active
    and t.start_time = new.delivery_slot_start
    and t.end_time = new.delivery_slot_end
    and (t.day_of_week is null or t.day_of_week = extract(dow from new.delivery_slot_date)::integer)
  order by t.position, t.id
  limit 1;

  if v_template_id is null then
    raise exception
      'This order''s delivery slot is no longer offered, so the order cannot be reactivated. Re-enable the slot first.'
      using errcode = 'P0001', detail = 'reactivation_slot_not_offered';
  end if;

  select e.eff_capacity, e.override_closed into v_cap, v_override_closed
  from public.delivery_slot_effective_capacity(v_template_id, new.delivery_slot_date) e;

  if v_override_closed or coalesce(v_cap = 0, false) then
    raise exception
      'This order''s delivery slot is closed, so the order cannot be reactivated.'
      using errcode = 'P0001', detail = 'reactivation_slot_closed';
  end if;

  -- NULL capacity = unlimited: nothing to protect.
  if v_cap is not null then
    -- The order being reactivated still has its old status in the table, so it is not
    -- counted here: reactivation fits only when there is room for one more.
    v_booked := public.delivery_slot_booked_count(
      new.delivery_slot_date, new.delivery_slot_start, new.delivery_slot_end
    );
    if v_booked >= v_cap then
      raise exception
        'This order''s delivery slot is full, so the order cannot be reactivated.'
        using errcode = 'P0001', detail = 'reactivation_slot_full';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.guard_order_reactivation_capacity()
  from public, anon, authenticated;

drop trigger if exists orders_guard_reactivation_capacity on public.orders;
create trigger orders_guard_reactivation_capacity
  before update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.guard_order_reactivation_capacity();

-- ---------------------------------------------------------------------------
-- 4. Availability: advertise only the template checkout would actually use
--
-- Identical to the 20260930050000 version except for the NOT EXISTS below: a template is
-- skipped for a date when another ACTIVE template with the same window that also applies on
-- that weekday sorts before it by (position, id) - the same ordering delivery_slot_evaluate()
-- and create_order() use. Capacity and usage still come from the two shared helpers.
-- ---------------------------------------------------------------------------
create or replace function public.get_delivery_slot_availability(p_from date, p_to date)
returns table (
  slot_date date,
  template_id uuid,
  label text,
  start_time time,
  end_time time,
  capacity integer,
  booked_count integer,
  remaining integer,
  is_available boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Invalid date range.' using errcode = 'P0001';
  end if;
  if p_to - p_from > 31 then
    raise exception 'Date range is too large (31 days at most).' using errcode = 'P0001';
  end if;

  return query
  select
    d.slot_date,
    t.id,
    t.label,
    t.start_time,
    t.end_time,
    eff.eff_capacity,
    b.booked,
    case when eff.eff_capacity is null then null else greatest(eff.eff_capacity - b.booked, 0) end,
    (eff.eff_capacity is null or b.booked < eff.eff_capacity)
  from (
    select gs::date as slot_date
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs
  ) d
  join public.delivery_slot_templates t
    on t.is_active
   and (t.day_of_week is null or t.day_of_week = extract(dow from d.slot_date)::integer)
   and not exists (
     select 1
     from public.delivery_slot_templates s
     where s.is_active
       and s.start_time = t.start_time
       and s.end_time = t.end_time
       and (s.day_of_week is null or s.day_of_week = extract(dow from d.slot_date)::integer)
       and (s.position, s.id) < (t.position, t.id)
   )
  cross join lateral public.delivery_slot_effective_capacity(t.id, d.slot_date) eff
  cross join lateral (
    select public.delivery_slot_booked_count(d.slot_date, t.start_time, t.end_time) as booked
  ) b
  where not eff.override_closed
  order by d.slot_date, t.position, t.start_time;
end;
$$;

revoke execute on function public.get_delivery_slot_availability(date, date) from public;
grant execute on function public.get_delivery_slot_availability(date, date) to anon, authenticated;
