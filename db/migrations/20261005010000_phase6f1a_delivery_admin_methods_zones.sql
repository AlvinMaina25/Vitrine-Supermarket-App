-- =============================================================================
-- PHASE 6F.1A - delivery admin backend, part 1: methods, zones, zone fees.
-- NOT APPLIED / NOT RUN anywhere. Apply once, after 20261004170000. One transaction.
--
-- ADDS six admin-only functions (gate: require_admin(), run FIRST, before any argument is
-- examined; staff are NOT admins, customers and anon are denied):
--   admin_list_delivery_config()                  methods + zones + zone fees in one read
--   admin_save_delivery_zone(...)                 create (p_zone_id null) or update a zone
--   admin_set_delivery_zone_active(...)           activate / deactivate a zone (reason required)
--   admin_save_delivery_zone_fee(...)             create (p_fee_id null) or update a zone fee rule
--   admin_set_delivery_zone_fee_active(...)       activate / deactivate a fee rule (reason required)
--   admin_update_delivery_method(...)             base fee, free-over, minimum order, active
--
-- DOES NOT: change any table, column, policy, RLS or table grant; revoke the existing direct
--   write grants (that is 6F.1B, after the frontend exists); touch create_order(),
--   validate_delivery_selection(), resolve_delivery_fee() or any slot function; edit any
--   earlier migration; delete anything (configuration is deactivated, never removed).
--
-- MONEY: integer cents only. Money arguments are NUMERIC so that 12.5 or -1 is rejected with a
--   clear error instead of being silently rounded or failing as a type error. Accepted range
--   0 .. 2147483647 (the integer column limit). free_over NULL = fee never waived.
--
-- AUDIT: every change that actually changes something writes ONE admin_audit_log row
--   (actor_id, action, target_id, reason). That table has no details column and this migration
--   does not alter it, so:
--     * zones / zone fees: target_id = the zone / fee row id.
--     * methods: the primary key is TEXT (code), target_id is uuid, so target_id is NULL and
--       the method code is the first word of `reason` ("standard: base_fee_cents 25000 -> ...").
--     * `reason` carries the admin's reason for activate/deactivate, and a change summary
--       (field, old -> new; towns are summarised by count) for saves, truncated to 500 chars.
--   A call that changes nothing returns changed=false and writes NO audit row.
--
-- ERRORS (after the gate): SQLSTATE P0001 with DETAIL: invalid_arguments, invalid_code,
--   code_immutable, code_taken, name_required, name_too_long, county_too_long,
--   description_too_long, invalid_towns, invalid_position, invalid_fee, invalid_free_over,
--   invalid_min_order, immutable_fields, zone_not_found, zone_fee_not_found, method_not_found,
--   zone_fee_exists, reason_required, reason_too_long, status_unchanged.
--   Gate failure: 42501 / not_authorised.
--
-- SEMANTICS (full-record saves, so a form can send the whole record):
--   zone save:  name, county, description, towns, position are REPLACED by the arguments
--     (blank county/description -> NULL; towns trimmed, blanks and case-insensitive duplicates
--     dropped, at most 100 towns of at most 80 chars); p_position NULL = keep (0 on create).
--     code is create-only (NULL or the same code is accepted on update). New zones are ACTIVE
--     (the table default), so a new zone is offered at checkout immediately, at the method's
--     default fee until a zone fee rule is added.
--   zone fee save: fee_cents, free_over_cents, min_order_cents are REPLACED (min NULL -> 0).
--     zone and method are fixed once created (NULL or the same value accepted on update).
--     One rule per zone x method: creating a second one fails with zone_fee_exists.
--   method update: base_fee_cents, free_over_cents, min_order_cents, is_active are REPLACED; no
--     other method column is touched. A reason is REQUIRED when is_active changes.
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regclass('public.delivery_methods') is null
     or to_regclass('public.delivery_zones') is null
     or to_regclass('public.delivery_zone_fees') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.validate_delivery_selection(text,uuid,integer)') is null then
    raise exception 'Phase 6F.1A precondition failed: apply 6A, the delivery migrations and 20261004170000 first.';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname in ('admin_list_delivery_config', 'admin_save_delivery_zone',
                                 'admin_set_delivery_zone_active', 'admin_save_delivery_zone_fee',
                                 'admin_set_delivery_zone_fee_active', 'admin_update_delivery_method')) then
    raise exception 'Phase 6F.1A appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_list_delivery_config() - everything the delivery settings screen needs, one read.
--    Includes INACTIVE rows. Methods by (position, code); zones by (position, name, id); zone
--    fees by zone then method, each with zone_code, zone_name and method_label for display.
-- =============================================================================
create function public.admin_list_delivery_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'methods', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.position, m.code)
      from public.delivery_methods m), '[]'::jsonb),
    'zones', coalesce((
      select jsonb_agg(to_jsonb(z) order by z.position, z.name, z.id)
      from public.delivery_zones z), '[]'::jsonb),
    'zone_fees', coalesce((
      select jsonb_agg(
               to_jsonb(f) || jsonb_build_object('zone_code', z.code, 'zone_name', z.name,
                                                 'method_label', m.label)
               order by z.position, z.name, m.position, m.code, f.id)
      from public.delivery_zone_fees f
      join public.delivery_zones z on z.id = f.zone_id
      join public.delivery_methods m on m.code = f.method_code), '[]'::jsonb)
  );
end;
$$;

comment on function public.admin_list_delivery_config() is
  'Phase 6F.1A. Admin-only (require_admin()). Methods, zones and zone fees including inactive rows, as one jsonb.';

-- =============================================================================
-- 2. admin_save_delivery_zone()
-- Returns { changed, created, zone: {...row} }.
-- =============================================================================
create function public.admin_save_delivery_zone(
  p_zone_id uuid,
  p_code text,
  p_name text,
  p_county text,
  p_towns text[],
  p_description text,
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
  v_code text := btrim(coalesce(p_code, ''));
  v_name text := btrim(coalesce(p_name, ''));
  v_county text := nullif(btrim(coalesce(p_county, '')), '');
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
  v_towns text[];
  v_old public.delivery_zones%rowtype;
  v_new public.delivery_zones%rowtype;
  v_pos integer;
  v_changes text[] := '{}';
begin
  v_actor := public.require_admin();   -- gate first, before any argument is examined

  if v_name = '' then
    raise exception 'A zone name is required.'
      using errcode = 'P0001', detail = 'name_required';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'The zone name must be at most 120 characters.'
      using errcode = 'P0001', detail = 'name_too_long';
  end if;
  if v_county is not null and char_length(v_county) > 80 then
    raise exception 'The county must be at most 80 characters.'
      using errcode = 'P0001', detail = 'county_too_long';
  end if;
  if v_desc is not null and char_length(v_desc) > 500 then
    raise exception 'The description must be at most 500 characters.'
      using errcode = 'P0001', detail = 'description_too_long';
  end if;

  -- Towns: trimmed, blanks dropped, case-insensitive duplicates dropped (first spelling kept).
  select coalesce(array_agg(s.t order by s.ord), '{}'::text[])
    into v_towns
  from (
    select distinct on (lower(btrim(u.x))) btrim(u.x) as t, u.ord
    from unnest(coalesce(p_towns, '{}'::text[])) with ordinality as u(x, ord)
    where btrim(u.x) <> ''
    order by lower(btrim(u.x)), u.ord
  ) s;
  if cardinality(v_towns) > 100
     or exists (select 1 from unnest(v_towns) t where char_length(t) > 80) then
    raise exception 'A zone can list at most 100 towns of at most 80 characters each.'
      using errcode = 'P0001', detail = 'invalid_towns';
  end if;

  if p_position is not null and (p_position < 0 or p_position > 1000000) then
    raise exception 'The position must be between 0 and 1000000.'
      using errcode = 'P0001', detail = 'invalid_position';
  end if;

  if p_zone_id is null then
    -- ---- create ----
    if v_code !~ '^[a-z][a-z0-9_-]{1,39}$' then
      raise exception 'The zone code must be 2-40 characters: lowercase letters, digits, - or _, starting with a letter.'
        using errcode = 'P0001', detail = 'invalid_code';
    end if;
    if exists (select 1 from public.delivery_zones z where z.code = v_code) then
      raise exception 'A zone with that code already exists.'
        using errcode = 'P0001', detail = 'code_taken';
    end if;

    begin
      insert into public.delivery_zones (code, name, description, county, towns, position)
      values (v_code, v_name, v_desc, v_county, v_towns, coalesce(p_position, 0))
      returning * into v_new;
    exception when unique_violation then
      raise exception 'A zone with that code already exists.'
        using errcode = 'P0001', detail = 'code_taken';
    end;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'delivery_zone_created', v_new.id,
            left(format('Created zone %s (%s)', v_new.code, v_new.name), 500));

    return jsonb_build_object('changed', true, 'created', true, 'zone', to_jsonb(v_new));
  end if;

  -- ---- update ----
  select z.* into v_old from public.delivery_zones z where z.id = p_zone_id for update;
  if not found then
    raise exception 'That delivery zone could not be found.'
      using errcode = 'P0001', detail = 'zone_not_found';
  end if;
  if v_code <> '' and v_code <> v_old.code then
    raise exception 'The zone code cannot be changed.'
      using errcode = 'P0001', detail = 'code_immutable';
  end if;

  v_pos := coalesce(p_position, v_old.position);

  if v_name is distinct from v_old.name then
    v_changes := v_changes || format('name: %s -> %s', v_old.name, v_name);
  end if;
  if v_county is distinct from v_old.county then
    v_changes := v_changes || format('county: %s -> %s', coalesce(v_old.county, 'none'), coalesce(v_county, 'none'));
  end if;
  if v_desc is distinct from v_old.description then
    v_changes := v_changes || 'description changed'::text;
  end if;
  if v_towns is distinct from v_old.towns then
    v_changes := v_changes || format('towns: %s -> %s entries', cardinality(v_old.towns), cardinality(v_towns));
  end if;
  if v_pos is distinct from v_old.position then
    v_changes := v_changes || format('position: %s -> %s', v_old.position, v_pos);
  end if;

  if cardinality(v_changes) = 0 then
    return jsonb_build_object('changed', false, 'created', false, 'zone', to_jsonb(v_old));
  end if;

  update public.delivery_zones
     set name = v_name, county = v_county, description = v_desc, towns = v_towns, position = v_pos
   where id = p_zone_id
   returning * into v_new;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'delivery_zone_updated', p_zone_id,
          left(format('%s: %s', v_old.code, array_to_string(v_changes, '; ')), 500));

  return jsonb_build_object('changed', true, 'created', false, 'zone', to_jsonb(v_new));
end;
$$;

comment on function public.admin_save_delivery_zone(uuid, text, text, text, text[], text, integer) is
  'Phase 6F.1A. Admin-only. Creates (p_zone_id null) or updates a delivery zone and writes admin_audit_log. Never deletes.';

-- =============================================================================
-- 3. admin_set_delivery_zone_active()   Returns { changed, zone_id, previous_is_active, is_active }.
-- =============================================================================
create function public.admin_set_delivery_zone_active(
  p_zone_id uuid,
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
  v_prev boolean;
begin
  v_actor := public.require_admin();   -- gate first

  if p_zone_id is null or p_is_active is null then
    raise exception 'A zone and a state are required.'
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

  select z.is_active into v_prev from public.delivery_zones z where z.id = p_zone_id for update;
  if not found then
    raise exception 'That delivery zone could not be found.'
      using errcode = 'P0001', detail = 'zone_not_found';
  end if;
  if v_prev = p_is_active then
    raise exception 'That zone is already %.', case when p_is_active then 'active' else 'inactive' end
      using errcode = 'P0001', detail = 'status_unchanged';
  end if;

  update public.delivery_zones set is_active = p_is_active where id = p_zone_id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor,
          case when p_is_active then 'delivery_zone_activated' else 'delivery_zone_deactivated' end,
          p_zone_id, v_reason);

  return jsonb_build_object('changed', true, 'zone_id', p_zone_id,
                            'previous_is_active', v_prev, 'is_active', p_is_active);
end;
$$;

comment on function public.admin_set_delivery_zone_active(uuid, boolean, text) is
  'Phase 6F.1A. Admin-only. Activates/deactivates a zone (reason required) and writes admin_audit_log. Orders keep their snapshots.';

-- =============================================================================
-- 4. admin_save_delivery_zone_fee()   Returns { changed, created, zone_fee: {...row} }.
-- =============================================================================
create function public.admin_save_delivery_zone_fee(
  p_fee_id uuid,
  p_zone_id uuid,
  p_method_code text,
  p_fee_cents numeric,
  p_free_over_cents numeric,
  p_min_order_cents numeric
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_method text := btrim(coalesce(p_method_code, ''));
  v_fee integer;
  v_free integer;
  v_min integer;
  v_zone public.delivery_zones%rowtype;
  v_old public.delivery_zone_fees%rowtype;
  v_new public.delivery_zone_fees%rowtype;
  v_changes text[] := '{}';
begin
  v_actor := public.require_admin();   -- gate first

  -- Money: whole, non-negative cents that fit the integer column. NaN/Infinity fail the range test.
  if p_fee_cents is null or p_fee_cents < 0 or p_fee_cents > 2147483647
     or p_fee_cents <> trunc(p_fee_cents) then
    raise exception 'The delivery fee must be a whole number of cents, zero or more.'
      using errcode = 'P0001', detail = 'invalid_fee';
  end if;
  if p_free_over_cents is not null
     and (p_free_over_cents < 0 or p_free_over_cents > 2147483647
          or p_free_over_cents <> trunc(p_free_over_cents)) then
    raise exception 'The free-delivery threshold must be a whole number of cents, zero or more (or empty for never).'
      using errcode = 'P0001', detail = 'invalid_free_over';
  end if;
  if p_min_order_cents is not null
     and (p_min_order_cents < 0 or p_min_order_cents > 2147483647
          or p_min_order_cents <> trunc(p_min_order_cents)) then
    raise exception 'The minimum order must be a whole number of cents, zero or more.'
      using errcode = 'P0001', detail = 'invalid_min_order';
  end if;
  v_fee := p_fee_cents::integer;
  v_free := p_free_over_cents::integer;
  v_min := coalesce(p_min_order_cents, 0)::integer;

  if p_fee_id is null then
    -- ---- create ----
    if p_zone_id is null or v_method = '' then
      raise exception 'A zone and a delivery method are required.'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    select z.* into v_zone from public.delivery_zones z where z.id = p_zone_id for share;
    if not found then
      raise exception 'That delivery zone could not be found.'
        using errcode = 'P0001', detail = 'zone_not_found';
    end if;
    if not exists (select 1 from public.delivery_methods m where m.code = v_method) then
      raise exception 'That delivery method could not be found.'
        using errcode = 'P0001', detail = 'method_not_found';
    end if;
    if exists (select 1 from public.delivery_zone_fees f
               where f.zone_id = p_zone_id and f.method_code = v_method) then
      raise exception 'A fee rule for that zone and method already exists. Edit it instead.'
        using errcode = 'P0001', detail = 'zone_fee_exists';
    end if;

    begin
      insert into public.delivery_zone_fees (zone_id, method_code, fee_cents, free_over_cents, min_order_cents)
      values (p_zone_id, v_method, v_fee, v_free, v_min)
      returning * into v_new;
    exception when unique_violation then
      raise exception 'A fee rule for that zone and method already exists. Edit it instead.'
        using errcode = 'P0001', detail = 'zone_fee_exists';
    end;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'delivery_zone_fee_created', v_new.id,
            left(format('Created fee rule %s / %s: fee_cents %s; free_over_cents %s; min_order_cents %s',
                        v_zone.code, v_method, v_fee, coalesce(v_free::text, 'none'), v_min), 500));

    return jsonb_build_object('changed', true, 'created', true, 'zone_fee', to_jsonb(v_new));
  end if;

  -- ---- update ----
  select f.* into v_old from public.delivery_zone_fees f where f.id = p_fee_id for update;
  if not found then
    raise exception 'That fee rule could not be found.'
      using errcode = 'P0001', detail = 'zone_fee_not_found';
  end if;
  if (p_zone_id is not null and p_zone_id <> v_old.zone_id)
     or (v_method <> '' and v_method <> v_old.method_code) then
    raise exception 'The zone and method of a fee rule cannot be changed. Deactivate it and create a new one.'
      using errcode = 'P0001', detail = 'immutable_fields';
  end if;

  if v_fee is distinct from v_old.fee_cents then
    v_changes := v_changes || format('fee_cents %s -> %s', v_old.fee_cents, v_fee);
  end if;
  if v_free is distinct from v_old.free_over_cents then
    v_changes := v_changes || format('free_over_cents %s -> %s',
                                     coalesce(v_old.free_over_cents::text, 'none'), coalesce(v_free::text, 'none'));
  end if;
  if v_min is distinct from v_old.min_order_cents then
    v_changes := v_changes || format('min_order_cents %s -> %s', v_old.min_order_cents, v_min);
  end if;

  if cardinality(v_changes) = 0 then
    return jsonb_build_object('changed', false, 'created', false, 'zone_fee', to_jsonb(v_old));
  end if;

  update public.delivery_zone_fees
     set fee_cents = v_fee, free_over_cents = v_free, min_order_cents = v_min
   where id = p_fee_id
   returning * into v_new;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'delivery_zone_fee_updated', p_fee_id,
          left(format('%s / %s: %s',
                      (select z.code from public.delivery_zones z where z.id = v_old.zone_id),
                      v_old.method_code, array_to_string(v_changes, '; ')), 500));

  return jsonb_build_object('changed', true, 'created', false, 'zone_fee', to_jsonb(v_new));
end;
$$;

comment on function public.admin_save_delivery_zone_fee(uuid, uuid, text, numeric, numeric, numeric) is
  'Phase 6F.1A. Admin-only. Creates (p_fee_id null) or updates a zone fee rule (integer cents) and writes admin_audit_log. Never deletes.';

-- =============================================================================
-- 5. admin_set_delivery_zone_fee_active()  Returns { changed, zone_fee_id, previous_is_active, is_active }.
--    Deactivating a rule makes the zone fall back to the method's own fee settings.
-- =============================================================================
create function public.admin_set_delivery_zone_fee_active(
  p_fee_id uuid,
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
  v_prev boolean;
begin
  v_actor := public.require_admin();   -- gate first

  if p_fee_id is null or p_is_active is null then
    raise exception 'A fee rule and a state are required.'
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

  select f.is_active into v_prev from public.delivery_zone_fees f where f.id = p_fee_id for update;
  if not found then
    raise exception 'That fee rule could not be found.'
      using errcode = 'P0001', detail = 'zone_fee_not_found';
  end if;
  if v_prev = p_is_active then
    raise exception 'That fee rule is already %.', case when p_is_active then 'active' else 'inactive' end
      using errcode = 'P0001', detail = 'status_unchanged';
  end if;

  update public.delivery_zone_fees set is_active = p_is_active where id = p_fee_id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor,
          case when p_is_active then 'delivery_zone_fee_activated' else 'delivery_zone_fee_deactivated' end,
          p_fee_id, v_reason);

  return jsonb_build_object('changed', true, 'zone_fee_id', p_fee_id,
                            'previous_is_active', v_prev, 'is_active', p_is_active);
end;
$$;

comment on function public.admin_set_delivery_zone_fee_active(uuid, boolean, text) is
  'Phase 6F.1A. Admin-only. Activates/deactivates a zone fee rule (reason required) and writes admin_audit_log.';

-- =============================================================================
-- 6. admin_update_delivery_method()   Returns { changed, method: {...row} }.
--    Touches ONLY base_fee_cents, free_over_cents, min_order_cents, is_active.
--    A reason is optional, EXCEPT when is_active changes (then required).
-- =============================================================================
create function public.admin_update_delivery_method(
  p_code text,
  p_base_fee_cents numeric,
  p_free_over_cents numeric,
  p_min_order_cents numeric,
  p_is_active boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_code text := btrim(coalesce(p_code, ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_fee integer;
  v_free integer;
  v_min integer;
  v_old public.delivery_methods%rowtype;
  v_new public.delivery_methods%rowtype;
  v_changes text[] := '{}';
  v_summary text;
begin
  v_actor := public.require_admin();   -- gate first

  if v_code = '' or p_is_active is null then
    raise exception 'A delivery method and an active state are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if p_base_fee_cents is null or p_base_fee_cents < 0 or p_base_fee_cents > 2147483647
     or p_base_fee_cents <> trunc(p_base_fee_cents) then
    raise exception 'The delivery fee must be a whole number of cents, zero or more.'
      using errcode = 'P0001', detail = 'invalid_fee';
  end if;
  if p_free_over_cents is not null
     and (p_free_over_cents < 0 or p_free_over_cents > 2147483647
          or p_free_over_cents <> trunc(p_free_over_cents)) then
    raise exception 'The free-delivery threshold must be a whole number of cents, zero or more (or empty for never).'
      using errcode = 'P0001', detail = 'invalid_free_over';
  end if;
  if p_min_order_cents is null or p_min_order_cents < 0 or p_min_order_cents > 2147483647
     or p_min_order_cents <> trunc(p_min_order_cents) then
    raise exception 'The minimum order must be a whole number of cents, zero or more.'
      using errcode = 'P0001', detail = 'invalid_min_order';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason must be at most 500 characters.'
      using errcode = 'P0001', detail = 'reason_too_long';
  end if;
  v_fee := p_base_fee_cents::integer;
  v_free := p_free_over_cents::integer;
  v_min := p_min_order_cents::integer;

  select m.* into v_old from public.delivery_methods m where m.code = v_code for update;
  if not found then
    raise exception 'That delivery method could not be found.'
      using errcode = 'P0001', detail = 'method_not_found';
  end if;

  if v_fee is distinct from v_old.base_fee_cents then
    v_changes := v_changes || format('base_fee_cents %s -> %s', v_old.base_fee_cents, v_fee);
  end if;
  if v_free is distinct from v_old.free_over_cents then
    v_changes := v_changes || format('free_over_cents %s -> %s',
                                     coalesce(v_old.free_over_cents::text, 'none'), coalesce(v_free::text, 'none'));
  end if;
  if v_min is distinct from v_old.min_order_cents then
    v_changes := v_changes || format('min_order_cents %s -> %s', v_old.min_order_cents, v_min);
  end if;
  if p_is_active is distinct from v_old.is_active then
    if v_reason = '' then
      raise exception 'A reason is required to activate or deactivate a delivery method.'
        using errcode = 'P0001', detail = 'reason_required';
    end if;
    v_changes := v_changes || format('is_active %s -> %s', v_old.is_active::text, p_is_active::text);
  end if;

  if cardinality(v_changes) = 0 then
    return jsonb_build_object('changed', false, 'method', to_jsonb(v_old));
  end if;

  update public.delivery_methods
     set base_fee_cents = v_fee, free_over_cents = v_free,
         min_order_cents = v_min, is_active = p_is_active
   where code = v_code
   returning * into v_new;

  v_summary := format('%s: %s', v_code, array_to_string(v_changes, '; '));
  if v_reason <> '' then
    v_summary := v_summary || ' | reason: ' || v_reason;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'delivery_method_updated', null, left(v_summary, 500));

  return jsonb_build_object('changed', true, 'method', to_jsonb(v_new));
end;
$$;

comment on function public.admin_update_delivery_method(text, numeric, numeric, numeric, boolean, text) is
  'Phase 6F.1A. Admin-only. Updates a method''s fee, free-over, minimum order and active flag (integer cents) and writes admin_audit_log.';

-- =============================================================================
-- 7. Privileges: nothing for public/anon; EXECUTE for authenticated only (the gate is the door).
-- =============================================================================
revoke all on function public.admin_list_delivery_config() from public, anon, authenticated;
revoke all on function public.admin_save_delivery_zone(uuid, text, text, text, text[], text, integer) from public, anon, authenticated;
revoke all on function public.admin_set_delivery_zone_active(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_save_delivery_zone_fee(uuid, uuid, text, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.admin_set_delivery_zone_fee_active(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_update_delivery_method(text, numeric, numeric, numeric, boolean, text) from public, anon, authenticated;

grant execute on function public.admin_list_delivery_config() to authenticated;
grant execute on function public.admin_save_delivery_zone(uuid, text, text, text, text[], text, integer) to authenticated;
grant execute on function public.admin_set_delivery_zone_active(uuid, boolean, text) to authenticated;
grant execute on function public.admin_save_delivery_zone_fee(uuid, uuid, text, numeric, numeric, numeric) to authenticated;
grant execute on function public.admin_set_delivery_zone_fee_active(uuid, boolean, text) to authenticated;
grant execute on function public.admin_update_delivery_method(text, numeric, numeric, numeric, boolean, text) to authenticated;

-- =============================================================================
-- 8. Self-check (aborts the whole transaction if anything is off)
-- =============================================================================
do $check$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.admin_list_delivery_config()',
    'public.admin_save_delivery_zone(uuid,text,text,text,text[],text,integer)',
    'public.admin_set_delivery_zone_active(uuid,boolean,text)',
    'public.admin_save_delivery_zone_fee(uuid,uuid,text,numeric,numeric,numeric)',
    'public.admin_set_delivery_zone_fee_active(uuid,boolean,text)',
    'public.admin_update_delivery_method(text,numeric,numeric,numeric,boolean,text)'
  ] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_sig::regprocedure and p.prosecdef
                     and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%') then
      raise exception 'Phase 6F.1A self-check failed: % is not SECURITY DEFINER with a pinned search_path.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
      raise exception 'Phase 6F.1A self-check failed: function privileges are wrong on %.', v_sig;
    end if;
  end loop;
end
$check$;

commit;
