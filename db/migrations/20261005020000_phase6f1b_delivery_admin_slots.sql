-- =============================================================================
-- PHASE 6F.1B - delivery admin backend, part 2: slot templates and per-date overrides.
-- NOT APPLIED / NOT RUN anywhere. Apply once, after 20261005010000. One transaction.
--
-- ADDS five admin-only functions (gate: require_admin(), run FIRST, before any argument is
-- examined; staff are NOT admins, customers and anon are denied):
--   admin_list_delivery_slots(from, to)           templates + per-date overrides + booked counts
--   admin_save_delivery_slot_template(...)        create (p_template_id null) or update a template
--   admin_set_delivery_slot_template_active(...)  activate / deactivate a template (reason required)
--   admin_save_delivery_slot_override(...)        capacity or closure of one template on one date
--   admin_clear_delivery_slot_override(...)       remove the override of one template on one date
--                                                 (reason required)
--
-- DOES NOT: change any table, column, policy, RLS or table grant; revoke the existing direct
--   write grants (the 6F review does that once the UI uses these functions); touch
--   create_order(), get_delivery_slot_availability(), validate_delivery_slot(), the slot
--   helpers or any 6F.1A function; edit any earlier migration; delete anything.
--
-- SLOT MODEL (unchanged, from 20260930030000 / 20260930050000 / 20260930070000):
--   capacity NULL = unlimited, 0 = closed, n > 0 = at most n orders. An override has
--   capacity NULL = inherit the template, and is_active = false = closed that date.
--   Orders hold a slot unless cancelled/refunded (order_status_holds_delivery_slot()) and are
--   matched on (date, start, end), not on template id, so the booked count of one window is
--   shared by duplicate templates. Several active templates may share a window on purpose;
--   checkout uses the lowest (position, id). An override on a template that is shadowed by a
--   lower-position duplicate therefore has no effect on checkout (not detected here).
--
-- "NO DELETES": the overrides table has no DELETE grant for browser roles and rows are not
--   removed. "Clear" resets the row to neutral (capacity NULL, is_active true, note NULL),
--   which behaves exactly like having no override. Neutral rows are not listed.
--
-- CLOSING vs CAPACITY: capacity may never be set below the orders that currently hold the
--   slot on that date (capacity_below_booked); capacity 0 counts as "below" when anything is
--   booked. CLOSING a slot is allowed with bookings: it only stops NEW orders; existing orders
--   keep their slot and are handled in the orders screen. (Reactivating such an order later
--   is refused by the 20260930070000 trigger until the slot is re-opened.)
--   The check runs under the same per-slot advisory lock create_order() takes, so a checkout
--   cannot slip an order in between the check and the write.
--
-- AUDIT: every change that actually changes something writes ONE admin_audit_log row
--   (actor_id, action, target_id, reason); same conventions as 6F.1A: target_id is the
--   template / override row id; `reason` carries the admin's reason for activate/deactivate/
--   clear and a change summary (field, old -> new) for saves, truncated to 500 chars.
--   A call that changes nothing returns changed=false and writes NO audit row.
--   Actions: delivery_slot_template_created / _updated / _activated / _deactivated,
--   delivery_slot_override_created / _updated / _cleared.
--
-- ERRORS (after the gate): SQLSTATE P0001 with DETAIL: invalid_arguments, invalid_date_range,
--   date_range_too_large, label_required, label_too_long, invalid_window, invalid_weekday,
--   invalid_capacity, invalid_position, template_not_found, template_has_bookings,
--   template_inactive, template_not_on_date, date_in_past, date_too_far, note_too_long,
--   capacity_with_closed, override_empty, override_not_found, capacity_below_booked,
--   reason_required, reason_too_long, status_unchanged. Gate failure: 42501 / not_authorised.
--
-- SEMANTICS (full-record saves, so a form can send the whole record):
--   template save: label, start, end, weekday, capacity, position are REPLACED (p_position NULL
--     = keep, 0 on create; weekday NULL = every day; capacity NULL = unlimited). New templates
--     are ACTIVE. start/end/weekday of an existing template cannot change while upcoming
--     orders hold that window (template_has_bookings): orders are matched by window, so they
--     would silently stop being counted. Deactivate it and create a new one instead.
--     Lowering a template capacity below existing bookings is allowed (the slot just reads
--     full; nothing is cancelled).
--   override save: capacity (NULL = inherit) or closed (true), plus an optional note (<= 300).
--     Closed and a capacity together are refused. Dates: today (Africa/Nairobi) .. +365 days.
--     The template must be active and apply on that weekday.
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regclass('public.delivery_slot_templates') is null
     or to_regclass('public.delivery_slot_overrides') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regclass('public.orders') is null
     or to_regprocedure('public.admin_list_delivery_config()') is null
     or to_regprocedure('public.delivery_slot_effective_capacity(uuid,date)') is null
     or to_regprocedure('public.delivery_slot_booked_count(date,time without time zone,time without time zone)') is null
     or to_regprocedure('public.delivery_slot_acquire_lock(date,time without time zone,time without time zone)') is null
     or to_regprocedure('public.order_status_holds_delivery_slot(order_status)') is null
     or to_regprocedure('public.validate_delivery_slot(date,time without time zone,time without time zone)') is null
     or to_regprocedure('public.get_delivery_slot_availability(date,date)') is null then
    raise exception 'Phase 6F.1B precondition failed: apply the delivery/slot migrations and 20261005010000 (6F.1A) first.';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname in ('admin_list_delivery_slots', 'admin_save_delivery_slot_template',
                                 'admin_set_delivery_slot_template_active',
                                 'admin_save_delivery_slot_override', 'admin_clear_delivery_slot_override')) then
    raise exception 'Phase 6F.1B appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_list_delivery_slots(p_from, p_to)
--    templates: every template, INCLUDING inactive.
--    overrides: meaningful override rows in the range (capacity set, closed, or a note), with
--               the template window, is_closed and the booked count for that date.
--    slots:     one row per date x template that applies on that weekday (inactive templates
--               included, flagged template_active), with template capacity, override values,
--               effective_capacity (NULL = unlimited), is_closed and booked_count.
--    Range: p_to >= p_from, at most 31 days apart (same limit as get_delivery_slot_availability).
-- =============================================================================
create function public.admin_list_delivery_slots(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_admin();

  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.'
      using errcode = 'P0001', detail = 'invalid_date_range';
  end if;
  if p_to - p_from > 31 then
    raise exception 'The date range can be at most 31 days.'
      using errcode = 'P0001', detail = 'date_range_too_large';
  end if;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'templates', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.position, t.start_time, t.id)
      from public.delivery_slot_templates t), '[]'::jsonb),
    'overrides', coalesce((
      select jsonb_agg(
               to_jsonb(o) || jsonb_build_object(
                 'template_label', t.label,
                 'start_time', t.start_time,
                 'end_time', t.end_time,
                 'is_closed', not o.is_active,
                 'booked_count', public.delivery_slot_booked_count(o.slot_date, t.start_time, t.end_time))
               order by o.slot_date, t.position, t.start_time, o.id)
      from public.delivery_slot_overrides o
      join public.delivery_slot_templates t on t.id = o.template_id
      where o.slot_date between p_from and p_to
        and (o.capacity is not null or not o.is_active or o.note is not null)), '[]'::jsonb),
    'slots', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.slot_date, s.position, s.start_time, s.template_id)
      from (
        select d.slot_date,
               t.id as template_id,
               t.label,
               t.start_time,
               t.end_time,
               t.position,
               t.is_active as template_active,
               t.capacity as template_capacity,
               o.capacity as override_capacity,
               coalesce(not o.is_active, false) as override_closed,
               eff.eff_capacity as effective_capacity,
               (coalesce(not o.is_active, false) or coalesce(eff.eff_capacity = 0, false)) as is_closed,
               public.delivery_slot_booked_count(d.slot_date, t.start_time, t.end_time) as booked_count
        from (select gs::date as slot_date
              from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs) d
        join public.delivery_slot_templates t
          on (t.day_of_week is null or t.day_of_week = extract(dow from d.slot_date)::integer)
        left join public.delivery_slot_overrides o
          on o.template_id = t.id and o.slot_date = d.slot_date
        cross join lateral public.delivery_slot_effective_capacity(t.id, d.slot_date) eff
      ) s), '[]'::jsonb)
  );
end;
$$;

comment on function public.admin_list_delivery_slots(date, date) is
  'Phase 6F.1B. Admin-only (require_admin()). Slot templates (incl. inactive), per-date overrides and booked counts for a range of at most 31 days, as one jsonb.';

-- =============================================================================
-- 2. admin_save_delivery_slot_template()   Returns { changed, created, template: {...row} }.
-- =============================================================================
create function public.admin_save_delivery_slot_template(
  p_template_id uuid,
  p_label text,
  p_start_time time,
  p_end_time time,
  p_day_of_week integer,
  p_capacity numeric,
  p_position integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_label text := btrim(coalesce(p_label, ''));
  v_cap integer;
  v_pos integer;
  v_old public.delivery_slot_templates%rowtype;
  v_new public.delivery_slot_templates%rowtype;
  v_changes text[] := '{}';
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
begin
  v_actor := public.require_admin();   -- gate first, before any argument is examined

  if v_label = '' then
    raise exception 'A slot label is required.'
      using errcode = 'P0001', detail = 'label_required';
  end if;
  if char_length(v_label) > 80 then
    raise exception 'The slot label must be at most 80 characters.'
      using errcode = 'P0001', detail = 'label_too_long';
  end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time then
    raise exception 'A slot needs a start time and an end time after it.'
      using errcode = 'P0001', detail = 'invalid_window';
  end if;
  if p_day_of_week is not null and (p_day_of_week < 0 or p_day_of_week > 6) then
    raise exception 'The weekday must be 0 (Sunday) to 6 (Saturday), or empty for every day.'
      using errcode = 'P0001', detail = 'invalid_weekday';
  end if;
  if p_capacity is not null
     and (p_capacity < 0 or p_capacity > 100000 or p_capacity <> trunc(p_capacity)) then
    raise exception 'The capacity must be a whole number of orders, zero or more (or empty for unlimited).'
      using errcode = 'P0001', detail = 'invalid_capacity';
  end if;
  if p_position is not null and (p_position < 0 or p_position > 1000000) then
    raise exception 'The position must be between 0 and 1000000.'
      using errcode = 'P0001', detail = 'invalid_position';
  end if;
  v_cap := p_capacity::integer;

  if p_template_id is null then
    -- ---- create ----
    insert into public.delivery_slot_templates (label, start_time, end_time, day_of_week, capacity, position)
    values (v_label, p_start_time, p_end_time, p_day_of_week, v_cap, coalesce(p_position, 0))
    returning * into v_new;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'delivery_slot_template_created', v_new.id,
            left(format('Created slot %s %s-%s; weekday %s; capacity %s; position %s',
                        v_new.label, v_new.start_time::text, v_new.end_time::text,
                        coalesce(v_new.day_of_week::text, 'every day'),
                        coalesce(v_new.capacity::text, 'unlimited'), v_new.position), 500));

    return jsonb_build_object('changed', true, 'created', true, 'template', to_jsonb(v_new));
  end if;

  -- ---- update ----
  select t.* into v_old from public.delivery_slot_templates t where t.id = p_template_id for update;
  if not found then
    raise exception 'That slot template could not be found.'
      using errcode = 'P0001', detail = 'template_not_found';
  end if;

  v_pos := coalesce(p_position, v_old.position);

  if v_label is distinct from v_old.label then
    v_changes := v_changes || format('label: %s -> %s', v_old.label, v_label);
  end if;
  if p_start_time is distinct from v_old.start_time then
    v_changes := v_changes || format('start: %s -> %s', v_old.start_time::text, p_start_time::text);
  end if;
  if p_end_time is distinct from v_old.end_time then
    v_changes := v_changes || format('end: %s -> %s', v_old.end_time::text, p_end_time::text);
  end if;
  if p_day_of_week is distinct from v_old.day_of_week then
    v_changes := v_changes || format('weekday: %s -> %s',
                                     coalesce(v_old.day_of_week::text, 'every day'),
                                     coalesce(p_day_of_week::text, 'every day'));
  end if;
  if v_cap is distinct from v_old.capacity then
    v_changes := v_changes || format('capacity: %s -> %s',
                                     coalesce(v_old.capacity::text, 'unlimited'),
                                     coalesce(v_cap::text, 'unlimited'));
  end if;
  if v_pos is distinct from v_old.position then
    v_changes := v_changes || format('position: %s -> %s', v_old.position, v_pos);
  end if;

  if cardinality(v_changes) = 0 then
    return jsonb_build_object('changed', false, 'created', false, 'template', to_jsonb(v_old));
  end if;

  -- Orders are matched on (date, start, end). Moving the window or weekday of a template that
  -- upcoming orders hold would leave them uncounted, so refuse.
  if p_start_time is distinct from v_old.start_time
     or p_end_time is distinct from v_old.end_time
     or p_day_of_week is distinct from v_old.day_of_week then
    if exists (select 1 from public.orders ord
               where ord.delivery_slot_start = v_old.start_time
                 and ord.delivery_slot_end = v_old.end_time
                 and ord.delivery_slot_date >= v_today
                 and public.order_status_holds_delivery_slot(ord.status)
                 and (v_old.day_of_week is null
                      or extract(dow from ord.delivery_slot_date)::integer = v_old.day_of_week)) then
      raise exception 'Upcoming orders hold this slot, so its times or weekday cannot change. Deactivate it and create a new slot instead.'
        using errcode = 'P0001', detail = 'template_has_bookings';
    end if;
  end if;

  update public.delivery_slot_templates
     set label = v_label, start_time = p_start_time, end_time = p_end_time,
         day_of_week = p_day_of_week, capacity = v_cap, position = v_pos
   where id = p_template_id
   returning * into v_new;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'delivery_slot_template_updated', p_template_id,
          left(format('%s: %s', v_old.label, array_to_string(v_changes, '; ')), 500));

  return jsonb_build_object('changed', true, 'created', false, 'template', to_jsonb(v_new));
end;
$$;

comment on function public.admin_save_delivery_slot_template(uuid, text, time, time, integer, numeric, integer) is
  'Phase 6F.1B. Admin-only. Creates (p_template_id null) or updates a delivery slot template and writes admin_audit_log. Never deletes.';

-- =============================================================================
-- 3. admin_set_delivery_slot_template_active()
--    Returns { changed, template_id, previous_is_active, is_active, upcoming_booked_orders }.
--    Deactivating stops NEW bookings only; existing orders keep their slot snapshot.
-- =============================================================================
create function public.admin_set_delivery_slot_template_active(
  p_template_id uuid,
  p_is_active boolean,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old public.delivery_slot_templates%rowtype;
  v_upcoming integer;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
begin
  v_actor := public.require_admin();   -- gate first

  if p_template_id is null or p_is_active is null then
    raise exception 'A slot template and a state are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if v_reason = '' then
    raise exception 'A reason is required.'
      using errcode = 'P0001', detail = 'reason_required';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason must be at most 500 characters.'
      using errcode = 'P0001', detail = 'reason_too_long';
  end if;

  select t.* into v_old from public.delivery_slot_templates t where t.id = p_template_id for update;
  if not found then
    raise exception 'That slot template could not be found.'
      using errcode = 'P0001', detail = 'template_not_found';
  end if;
  if v_old.is_active = p_is_active then
    raise exception 'That slot is already %.', case when p_is_active then 'active' else 'inactive' end
      using errcode = 'P0001', detail = 'status_unchanged';
  end if;

  update public.delivery_slot_templates set is_active = p_is_active where id = p_template_id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor,
          case when p_is_active then 'delivery_slot_template_activated' else 'delivery_slot_template_deactivated' end,
          p_template_id, v_reason);

  select count(*)::integer into v_upcoming
  from public.orders ord
  where ord.delivery_slot_start = v_old.start_time
    and ord.delivery_slot_end = v_old.end_time
    and ord.delivery_slot_date >= v_today
    and public.order_status_holds_delivery_slot(ord.status)
    and (v_old.day_of_week is null
         or extract(dow from ord.delivery_slot_date)::integer = v_old.day_of_week);

  return jsonb_build_object('changed', true, 'template_id', p_template_id,
                            'previous_is_active', v_old.is_active, 'is_active', p_is_active,
                            'upcoming_booked_orders', v_upcoming);
end;
$$;

comment on function public.admin_set_delivery_slot_template_active(uuid, boolean, text) is
  'Phase 6F.1B. Admin-only. Activates/deactivates a slot template (reason required) and writes admin_audit_log. Existing orders keep their slot.';

-- =============================================================================
-- 4. admin_save_delivery_slot_override()   Returns { changed, created, override: {...row}, booked_count }.
-- =============================================================================
create function public.admin_save_delivery_slot_override(
  p_template_id uuid,
  p_slot_date date,
  p_capacity numeric,
  p_is_closed boolean,
  p_note text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_cap integer;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_tpl public.delivery_slot_templates%rowtype;
  v_old public.delivery_slot_overrides%rowtype;
  v_new public.delivery_slot_overrides%rowtype;
  v_had_old boolean;
  v_old_meaningful boolean;
  v_booked integer;
  v_changes text[] := '{}';
  v_head text;
begin
  v_actor := public.require_admin();   -- gate first

  if p_template_id is null or p_slot_date is null or p_is_closed is null then
    raise exception 'A slot template, a date and a closed flag are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if p_capacity is not null
     and (p_capacity < 0 or p_capacity > 100000 or p_capacity <> trunc(p_capacity)) then
    raise exception 'The capacity must be a whole number of orders, zero or more (or empty to inherit the template).'
      using errcode = 'P0001', detail = 'invalid_capacity';
  end if;
  if p_is_closed and p_capacity is not null then
    raise exception 'A closed slot cannot also have a capacity. Close it, or set a capacity.'
      using errcode = 'P0001', detail = 'capacity_with_closed';
  end if;
  if v_note is not null and char_length(v_note) > 300 then
    raise exception 'The note must be at most 300 characters.'
      using errcode = 'P0001', detail = 'note_too_long';
  end if;
  if p_capacity is null and not p_is_closed and v_note is null then
    raise exception 'Nothing to set: give a capacity, close the slot, or add a note. To remove an override use clear.'
      using errcode = 'P0001', detail = 'override_empty';
  end if;
  if p_slot_date < v_today then
    raise exception 'The date cannot be in the past.'
      using errcode = 'P0001', detail = 'date_in_past';
  end if;
  if p_slot_date > v_today + 365 then
    raise exception 'The date can be at most 365 days ahead.'
      using errcode = 'P0001', detail = 'date_too_far';
  end if;
  v_cap := p_capacity::integer;

  select t.* into v_tpl from public.delivery_slot_templates t where t.id = p_template_id for share;
  if not found then
    raise exception 'That slot template could not be found.'
      using errcode = 'P0001', detail = 'template_not_found';
  end if;
  if not v_tpl.is_active then
    raise exception 'That slot is inactive. Activate it before setting a date override.'
      using errcode = 'P0001', detail = 'template_inactive';
  end if;
  if v_tpl.day_of_week is not null and v_tpl.day_of_week <> extract(dow from p_slot_date)::integer then
    raise exception 'That slot does not run on that weekday.'
      using errcode = 'P0001', detail = 'template_not_on_date';
  end if;

  -- Same per-slot lock create_order() takes: no checkout can add an order between the
  -- booked-count check below and the write.
  perform public.delivery_slot_acquire_lock(p_slot_date, v_tpl.start_time, v_tpl.end_time);

  v_booked := public.delivery_slot_booked_count(p_slot_date, v_tpl.start_time, v_tpl.end_time);

  if v_cap is not null and v_cap < v_booked then
    raise exception '% order(s) already hold this slot on %, so its capacity cannot be set below %. To stop new bookings, close the slot instead.',
      v_booked, p_slot_date::text, v_booked
      using errcode = 'P0001', detail = 'capacity_below_booked';
  end if;

  select o.* into v_old from public.delivery_slot_overrides o
   where o.template_id = p_template_id and o.slot_date = p_slot_date for update;
  v_had_old := found;
  v_old_meaningful := v_had_old and (v_old.capacity is not null or not v_old.is_active or v_old.note is not null);
  v_head := format('%s %s-%s on %s', v_tpl.label, v_tpl.start_time::text, v_tpl.end_time::text, p_slot_date::text);

  if v_had_old then
    if v_cap is distinct from v_old.capacity then
      v_changes := v_changes || format('capacity: %s -> %s',
                                       coalesce(v_old.capacity::text, 'inherit'), coalesce(v_cap::text, 'inherit'));
    end if;
    if p_is_closed is distinct from (not v_old.is_active) then
      v_changes := v_changes || format('closed: %s -> %s', (not v_old.is_active)::text, p_is_closed::text);
    end if;
    if v_note is distinct from v_old.note then
      v_changes := v_changes || 'note changed'::text;
    end if;
    if cardinality(v_changes) = 0 then
      return jsonb_build_object('changed', false, 'created', false,
                                'override', to_jsonb(v_old), 'booked_count', v_booked);
    end if;

    update public.delivery_slot_overrides
       set capacity = v_cap, is_active = not p_is_closed, note = v_note
     where id = v_old.id
     returning * into v_new;
  else
    insert into public.delivery_slot_overrides (template_id, slot_date, capacity, is_active, note)
    values (p_template_id, p_slot_date, v_cap, not p_is_closed, v_note)
    returning * into v_new;
  end if;

  if v_old_meaningful then
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'delivery_slot_override_updated', v_new.id,
            left(format('%s: %s', v_head, array_to_string(v_changes, '; ')), 500));
  else
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'delivery_slot_override_created', v_new.id,
            left(format('%s: capacity %s; closed %s; %s booked',
                        v_head, coalesce(v_cap::text, 'inherit'), p_is_closed::text, v_booked), 500));
  end if;

  return jsonb_build_object('changed', true, 'created', not v_old_meaningful,
                            'override', to_jsonb(v_new), 'booked_count', v_booked);
end;
$$;

comment on function public.admin_save_delivery_slot_override(uuid, date, numeric, boolean, text) is
  'Phase 6F.1B. Admin-only. Sets the capacity or closure of one slot template on one date; never below the orders already holding it; writes admin_audit_log.';

-- =============================================================================
-- 5. admin_clear_delivery_slot_override()
--    Returns { changed, override_id, template_id, slot_date, previous_capacity, previous_is_closed }.
--    Resets the row to neutral (see header); a date with no meaningful override -> override_not_found.
-- =============================================================================
create function public.admin_clear_delivery_slot_override(
  p_template_id uuid,
  p_slot_date date,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old public.delivery_slot_overrides%rowtype;
begin
  v_actor := public.require_admin();   -- gate first

  if p_template_id is null or p_slot_date is null then
    raise exception 'A slot template and a date are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if v_reason = '' then
    raise exception 'A reason is required.'
      using errcode = 'P0001', detail = 'reason_required';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason must be at most 500 characters.'
      using errcode = 'P0001', detail = 'reason_too_long';
  end if;

  select o.* into v_old from public.delivery_slot_overrides o
   where o.template_id = p_template_id and o.slot_date = p_slot_date for update;
  if not found or (v_old.capacity is null and v_old.is_active and v_old.note is null) then
    raise exception 'There is no override for that slot on that date.'
      using errcode = 'P0001', detail = 'override_not_found';
  end if;

  update public.delivery_slot_overrides
     set capacity = null, is_active = true, note = null
   where id = v_old.id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'delivery_slot_override_cleared', v_old.id,
          left(format('%s | cleared override on %s (was capacity %s; closed %s)',
                      v_reason, p_slot_date::text,
                      coalesce(v_old.capacity::text, 'inherit'), (not v_old.is_active)::text), 500));

  return jsonb_build_object('changed', true, 'override_id', v_old.id,
                            'template_id', p_template_id, 'slot_date', p_slot_date,
                            'previous_capacity', v_old.capacity,
                            'previous_is_closed', not v_old.is_active);
end;
$$;

comment on function public.admin_clear_delivery_slot_override(uuid, date, text) is
  'Phase 6F.1B. Admin-only. Clears the override of one slot on one date (reason required) and writes admin_audit_log. The row is reset, not deleted.';

-- =============================================================================
-- 6. Privileges: nothing for public/anon; EXECUTE for authenticated only (the gate is the door).
-- =============================================================================
revoke all on function public.admin_list_delivery_slots(date, date) from public, anon, authenticated;
revoke all on function public.admin_save_delivery_slot_template(uuid, text, time, time, integer, numeric, integer) from public, anon, authenticated;
revoke all on function public.admin_set_delivery_slot_template_active(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_save_delivery_slot_override(uuid, date, numeric, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_clear_delivery_slot_override(uuid, date, text) from public, anon, authenticated;

grant execute on function public.admin_list_delivery_slots(date, date) to authenticated;
grant execute on function public.admin_save_delivery_slot_template(uuid, text, time, time, integer, numeric, integer) to authenticated;
grant execute on function public.admin_set_delivery_slot_template_active(uuid, boolean, text) to authenticated;
grant execute on function public.admin_save_delivery_slot_override(uuid, date, numeric, boolean, text) to authenticated;
grant execute on function public.admin_clear_delivery_slot_override(uuid, date, text) to authenticated;

-- =============================================================================
-- 7. Self-check (aborts the whole transaction if anything is off)
-- =============================================================================
do $check$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.admin_list_delivery_slots(date,date)',
    'public.admin_save_delivery_slot_template(uuid,text,time without time zone,time without time zone,integer,numeric,integer)',
    'public.admin_set_delivery_slot_template_active(uuid,boolean,text)',
    'public.admin_save_delivery_slot_override(uuid,date,numeric,boolean,text)',
    'public.admin_clear_delivery_slot_override(uuid,date,text)'
  ] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_sig::regprocedure and p.prosecdef
                     and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%') then
      raise exception 'Phase 6F.1B self-check failed: % is not SECURITY DEFINER with a pinned search_path.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
      raise exception 'Phase 6F.1B self-check failed: function privileges are wrong on %.', v_sig;
    end if;
  end loop;
end
$check$;

commit;
