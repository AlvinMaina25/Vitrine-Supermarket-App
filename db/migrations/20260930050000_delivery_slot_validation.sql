-- =============================================================================
-- Delivery slot validation, availability and overbooking protection (PHASE 4B.2).
--
-- Apply AFTER 20260930040000_delivery_validation.sql (SQL editor, or
-- `supabase db push`). Safe to re-run: everything is CREATE OR REPLACE.
--
-- STATUS: written, NOT executed. No PostgreSQL was available when this was authored.
-- Run db/tests/delivery_slot_validation.test.sql and db/tests/delivery_slot_concurrency.sh
-- against a dev database before relying on any of it.
--
-- No table, column, policy or grant from 4A / 4B.1 changes, and create_order() is NOT
-- touched: checkout behaves exactly as before until Phase 4C wires this in.
--
-- What already existed and is REUSED, not duplicated (PHASE 4A):
--   * delivery_slot_templates.capacity     NULL = unlimited, 0 = closed, n > 0 = max orders
--   * delivery_slot_overrides              per (template, date): capacity (NULL = inherit the
--                                          template) and is_active (false = closed that date)
--   * "orders that hold a slot"            every order whose status is not cancelled/refunded
--   * slot identity on an order            (delivery_slot_date, delivery_slot_start,
--                                          delivery_slot_end), the same identity create_order()
--                                          stores and get_delivery_slot_availability() counts
--
-- What this migration adds:
--   1. delivery_slot_booked_count()          the ONE definition of slot usage
--   2. delivery_slot_effective_capacity()    the ONE definition of template + override capacity
--   3. get_delivery_slot_availability()      REPLACED with an equivalent body that calls (1) and
--                                            (2), so listing and validation can never disagree
--   4. delivery_slot_evaluate()              internal: the full validation, read-only
--   5. validate_delivery_slot()              public, read-only: quote / preview a slot
--   6. lock_delivery_slot()                  internal: take the per-slot lock, then evaluate
--
-- ---------------------------------------------------------------------------
-- OVERBOOKING PROTECTION: how it works and what it does and does not guarantee
-- ---------------------------------------------------------------------------
-- A slot's capacity is consumed by rows in public.orders, and a new order is a NEW row.
-- A row lock on an existing row cannot stop two transactions inserting two new rows, and
-- usage is counted by (date, start, end) rather than by template, so the template row
-- (shared by every date, and not unique per window if two templates share one) is the wrong
-- thing to lock. The overrides row often does not exist. So the lock target is the slot
-- identity itself: a transaction-scoped ADVISORY lock whose key is derived from
-- (slot date, start time, end time):
--
--     pg_advisory_xact_lock(hashtextextended('delivery_slot:' || date || ':' || start ||
--                                            ':' || end, 4202))
--
-- Two checkouts for the same window compute the same key, so the second WAITS until the first
-- commits or rolls back, then counts again and sees the first order. Checkouts for different
-- windows do not wait for each other (apart from a 64-bit hash collision, which only causes
-- an unnecessary wait, never a wrong answer). The lock is released automatically at
-- COMMIT/ROLLBACK, so there is no unlock step to forget and no stale lock to clean up.
--
-- The guarantee holds ONLY when ALL of these are true. Phase 4C must keep to them:
--   a. lock_delivery_slot() is called inside the SAME transaction that inserts the order,
--      and before the insert. As a stand-alone RPC the lock would be released as soon as
--      that call returned, protecting nothing. (It is therefore not granted to clients.)
--   b. The capacity decision uses the row lock_delivery_slot() returns, never an earlier
--      read such as validate_delivery_slot() or get_delivery_slot_availability().
--   c. The transaction runs at READ COMMITTED (the PostgREST/Supabase default). At
--      REPEATABLE READ or SERIALIZABLE the snapshot is fixed before the lock is taken and
--      would NOT see the order the lock holder just committed. lock_delivery_slot() raises
--      if it detects a stricter isolation level instead of silently overbooking.
--   d. Every code path that can put an order into a capacity-holding status takes the same
--      lock first. Today that path is create_order(). Moving an already cancelled/refunded
--      order back to an active status would consume capacity without this lock; no such
--      path exists today (flagged for 4C, not changed here).
-- Staff lowering a capacity, or closing a date, while a checkout is in flight is not
-- serialised against that checkout. That cannot overbook relative to the capacity the
-- customer saw, and it is deliberate: staff are never blocked by customer traffic.
--
-- ---------------------------------------------------------------------------
-- ZONE / METHOD: slot templates are still GLOBAL. A slot is not tied to a delivery zone or
-- method, and nothing here invents that. If zone- or method-specific slots are needed later
-- it is a schema change (a slot-template relationship), recorded as future work.
-- =============================================================================

-- =============================================================================
-- 1. USAGE: the one definition of "orders that hold this slot"
--
-- An order holds a slot unless it is cancelled or refunded (unpaid orders hold it too,
-- matching their stock reservation). Identical to the predicate 4A used inline.
-- SECURITY DEFINER so the count covers every customer's orders; it returns only a number.
-- Internal: no client grant.
-- =============================================================================
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
    and ord.status not in ('cancelled', 'refunded');
$$;

revoke execute on function public.delivery_slot_booked_count(date, time, time)
  from public, anon, authenticated;

-- =============================================================================
-- 2. CAPACITY: the one definition of template + date override
--
--   * a date override with is_active = false closes the slot that date (override_closed)
--   * a date override capacity, when not NULL, REPLACES the template capacity
--   * a date override capacity of NULL inherits the template capacity (so an override
--     cannot make a capped template unlimited; that is the 4A schema, unchanged)
--   * eff_capacity: NULL = unlimited, 0 = closed, n > 0 = maximum active orders
--
-- Output column names are deliberately distinct from table columns. Always returns exactly
-- one row; an unknown template yields NULL capacity, so callers must check the template
-- exists first.
-- =============================================================================
create or replace function public.delivery_slot_effective_capacity(
  p_template_id uuid,
  p_slot_date date
)
returns table (
  eff_capacity integer,
  capacity_source text,
  override_closed boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(o.capacity, t.capacity),
    case when o.capacity is not null then 'override' else 'template' end,
    coalesce(not o.is_active, false)
  from (select 1) as one
  left join public.delivery_slot_templates t on t.id = p_template_id
  left join public.delivery_slot_overrides o
    on o.template_id = p_template_id and o.slot_date = p_slot_date;
$$;

revoke execute on function public.delivery_slot_effective_capacity(uuid, date)
  from public, anon, authenticated;

-- =============================================================================
-- 3. AVAILABILITY LISTING (4A function, same signature and output, body now delegates)
--
-- Behaviour is intended to be identical to 4A: ACTIVE templates expanded over the range
-- (max 32 days), closed-by-override slots omitted, capacity-0 and full slots listed with
-- is_available = false. The only change is that capacity and usage come from the two
-- helpers above instead of being re-derived inline, so there is one definition of each.
-- =============================================================================
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

-- =============================================================================
-- 4. SLOT EVALUATION (internal, read-only)
--
-- Validates one slot selection and reports everything Phase 4C needs. Always returns exactly
-- one row; it never raises for a rejected slot. First failure wins:
--
--   slot_required      date, start or end is NULL
--   invalid_window     end is not after start
--   slot_in_past       the slot starts less than 60 minutes from now (store time)
--   slot_too_far       the date is more than 14 days ahead (store time)
--   slot_unknown       no template (active or not) has that window on that weekday
--   slot_inactive      matching template(s) exist but none is active
--   slot_closed        closed for that date by an override, or effective capacity is 0
--   slot_full          effective capacity is positive and used up
--
-- The lead time, horizon and Africa/Nairobi store clock are the SAME constants create_order()
-- (20260930020000) uses inline today: 60 minutes, 14 days, 'Africa/Nairobi'. They are repeated
-- here, in one place, because create_order() is not touched in this phase. When 4C swaps
-- create_order()'s slot block for lock_delivery_slot(), it deletes its own copy.
--
-- Template choice matches create_order(): among ACTIVE templates with this exact start/end and
-- a day_of_week that is NULL or equals the weekday, the lowest position (then id) wins.
--
-- Output: is_valid, error_code/message, the slot identity (slot_date/start/end, template_id,
-- label), capacity (effective; NULL = unlimited), capacity_source, booked_count, remaining
-- (NULL when unlimited), is_unlimited, is_closed, is_full. Usage fields are filled whenever
-- the template was found, including for closed/full rejections, so callers can explain them.
--
-- Not exposed: override notes, other customers' orders, anything beyond the aggregate
-- numbers get_delivery_slot_availability() already returns to customers.
-- =============================================================================
create or replace function public.delivery_slot_evaluate(
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
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  c_slot_lead interval := interval '60 minutes';
  c_slot_horizon_days integer := 14;

  v_local_now timestamp := (now() at time zone 'Africa/Nairobi');
  v_template public.delivery_slot_templates%rowtype;
  v_found boolean := false;
  v_code text := null;
  v_message text := null;
  v_cap integer := null;
  v_source text := null;
  v_override_closed boolean := false;
  v_booked integer := null;
  v_closed boolean := false;
  v_full boolean := false;
begin
  <<checks>>
  begin
    if p_slot_date is null or p_slot_start is null or p_slot_end is null then
      v_code := 'slot_required';
      v_message := 'Choose a delivery slot.';
      exit checks;
    end if;

    if p_slot_end <= p_slot_start then
      v_code := 'invalid_window';
      v_message := 'That delivery slot is not valid.';
      exit checks;
    end if;

    if (p_slot_date + p_slot_start) < (v_local_now + c_slot_lead) then
      v_code := 'slot_in_past';
      v_message := 'That delivery slot is no longer available. Pick another slot.';
      exit checks;
    end if;

    if p_slot_date > (v_local_now::date + c_slot_horizon_days) then
      v_code := 'slot_too_far';
      v_message := format('Delivery slots can only be booked up to %s days ahead.', c_slot_horizon_days);
      exit checks;
    end if;

    -- The template, chosen exactly as create_order() chooses it.
    select t.* into v_template
    from public.delivery_slot_templates t
    where t.is_active
      and t.start_time = p_slot_start
      and t.end_time = p_slot_end
      and (t.day_of_week is null or t.day_of_week = extract(dow from p_slot_date)::integer)
    order by t.position, t.id
    limit 1;
    v_found := found;

    if not v_found then
      perform 1
      from public.delivery_slot_templates t
      where t.start_time = p_slot_start
        and t.end_time = p_slot_end
        and (t.day_of_week is null or t.day_of_week = extract(dow from p_slot_date)::integer);
      if found then
        v_code := 'slot_inactive';
        v_message := 'That delivery slot is not available. Pick another slot.';
      else
        v_code := 'slot_unknown';
        v_message := 'That delivery slot does not exist. Pick another slot.';
      end if;
      exit checks;
    end if;

    select e.eff_capacity, e.capacity_source, e.override_closed
      into v_cap, v_source, v_override_closed
    from public.delivery_slot_effective_capacity(v_template.id, p_slot_date) e;

    v_booked := public.delivery_slot_booked_count(p_slot_date, v_template.start_time, v_template.end_time);

    v_closed := v_override_closed or coalesce(v_cap = 0, false);
    if v_closed then
      v_code := 'slot_closed';
      v_message := 'That delivery slot is closed. Pick another slot.';
      exit checks;
    end if;

    v_full := v_cap is not null and v_booked >= v_cap;
    if v_full then
      v_code := 'slot_full';
      v_message := 'That delivery slot is full. Pick another slot.';
      exit checks;
    end if;
  end checks;

  return query
  select
    v_code is null,
    v_code,
    v_message,
    p_slot_date,
    p_slot_start,
    p_slot_end,
    case when v_found then v_template.id end,
    case when v_found then v_template.label end,
    v_cap,
    v_source,
    v_booked,
    case when v_found and v_cap is not null then greatest(v_cap - v_booked, 0) end,
    case when v_found then v_cap is null end,
    v_closed,
    v_full;
end;
$$;

revoke execute on function public.delivery_slot_evaluate(date, time, time)
  from public, anon, authenticated;

-- =============================================================================
-- 5. validate_delivery_slot(): public, read-only, NO lock
--
-- For a checkout preview or a pre-submit check. A "valid" answer is a snapshot: another
-- customer can take the last place a moment later. It is NOT a reservation and must never
-- be what decides capacity when an order is created; use lock_delivery_slot() for that.
-- Granted to anon + authenticated like get_delivery_slot_availability().
-- =============================================================================
create or replace function public.validate_delivery_slot(
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
language sql
stable
security definer
set search_path = public
as $$
  select * from public.delivery_slot_evaluate(p_slot_date, p_slot_start, p_slot_end);
$$;

revoke execute on function public.validate_delivery_slot(date, time, time) from public;
grant execute on function public.validate_delivery_slot(date, time, time) to anon, authenticated;

-- =============================================================================
-- 6. lock_delivery_slot(): take the per-slot lock, THEN validate (for create_order())
--
-- Intended use inside create_order(), in the transaction that inserts the order:
--
--     select * into v_slot from public.lock_delivery_slot(p_slot_date, p_slot_start, p_slot_end);
--     if not v_slot.is_valid then
--       raise exception '%', v_slot.error_message using errcode = 'P0001';
--     end if;
--     -- ... insert the order with v_slot.slot_date/slot_start/slot_end/label/template_id ...
--     -- COMMIT releases the lock; the order is then visible to the next waiting checkout.
--
-- Order of operations inside: (1) reject a non-READ-COMMITTED transaction, (2) acquire the
-- advisory lock (blocking), (3) evaluate in a LATER statement. Under READ COMMITTED that
-- statement takes a fresh snapshot after the lock is granted, so it counts the order the
-- previous lock holder committed. That ordering is what makes the re-check meaningful.
--
-- The lock is taken even when the slot later turns out to be invalid (closed, full, ...). It is
-- skipped only when the date, start or end is NULL, because there is then no key to lock on.
--
-- VOLATILE and SECURITY DEFINER; NOT granted to anon/authenticated: called stand-alone it
-- would lock and immediately unlock. create_order() is SECURITY DEFINER and does not need
-- the grant.
-- =============================================================================
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

  return query
  select * from public.delivery_slot_evaluate(p_slot_date, p_slot_start, p_slot_end);
end;
$$;

revoke execute on function public.lock_delivery_slot(date, time, time)
  from public, anon, authenticated;
