-- =============================================================================
-- Corrective migration: validate_delivery_selection() "record v_res is not assigned yet".
--
-- Apply AFTER 20260930070000_order_reactivation_capacity.sql (or any time after 040000).
-- Idempotent: CREATE OR REPLACE of the one function; grants are restated. No table, policy,
-- column or other function changes. 20260930040000 is intentionally left as applied.
--
-- ROOT CAUSE
--   `v_res record` was only assigned by `select * into v_res from resolve_delivery_fee(...)`,
--   which runs after several early `exit checks` branches (zone_required, zone_unknown,
--   zone_inactive, method_*, invalid_subtotal). The final RETURN QUERY references
--   v_res.fee_cents etc. on every path, so PL/pgSQL failed on any rejected selection:
--     ERROR: record "v_res" is not assigned yet
--     DETAIL: The tuple structure of a not-yet-assigned record is indeterminate.
--   (Valid selections worked because v_res had been assigned by then.)
--
-- FIX (only change vs 20260930040000)
--   v_res is initialised to an all-NULL row with the same six columns and types that
--   resolve_delivery_fee() returns, before any early exit. Return shape, error codes, order of
--   checks, and resolve_delivery_fee() as the single fee calculation are unchanged. Real
--   assignment from resolve_delivery_fee() still replaces it; `v_have_fee` still gates every
--   fee column, so rejected rows still return NULL fee fields (and min_order_cents = v_min
--   for below_minimum_order).
-- =============================================================================

create or replace function public.validate_delivery_selection(
  p_method_code text,
  p_zone_id uuid default null,
  p_subtotal_cents integer default 0
)
returns table (
  is_valid boolean,
  error_code text,
  error_message text,
  method_code text,
  method_label text,
  requires_slot boolean,
  requires_address boolean,
  zone_id uuid,
  zone_code text,
  zone_name text,
  subtotal_cents integer,
  fee_cents integer,
  base_fee_cents integer,
  free_over_cents integer,
  min_order_cents integer,
  fee_source text,
  zone_fee_id uuid,
  fee_rule jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_method public.delivery_methods%rowtype;
  v_zone public.delivery_zones%rowtype;
  v_res record;
  v_code text := null;
  v_message text := null;
  v_have_fee boolean := false;
  v_min integer := null;
begin
  -- Give v_res its shape up front (same six columns/types as resolve_delivery_fee()).
  -- A bare, never-assigned record has no fields, and the RETURN QUERY below names
  -- v_res.<field> even on rejection paths that exit before resolve_delivery_fee() runs.
  select
    null::integer as fee_cents,
    null::integer as base_fee_cents,
    null::integer as free_over_cents,
    null::integer as min_order_cents,
    null::text as fee_source,
    null::uuid as zone_fee_id
  into v_res;

  <<checks>>
  begin
    if p_subtotal_cents is null or p_subtotal_cents < 0 then
      v_code := 'invalid_subtotal';
      v_message := 'The order subtotal is not valid.';
      exit checks;
    end if;

    if p_method_code is null or btrim(p_method_code) = '' then
      v_code := 'method_required';
      v_message := 'Choose a delivery method.';
      exit checks;
    end if;

    select m.* into v_method
    from public.delivery_methods m
    where m.code = p_method_code;
    if not found then
      v_code := 'method_unknown';
      v_message := 'That delivery method does not exist.';
      exit checks;
    end if;
    if not v_method.is_active then
      v_code := 'method_inactive';
      v_message := 'That delivery method is not available.';
      exit checks;
    end if;

    if p_zone_id is null then
      if v_method.requires_address then
        v_code := 'zone_required';
        v_message := 'Choose a delivery area.';
        exit checks;
      end if;
    else
      select z.* into v_zone
      from public.delivery_zones z
      where z.id = p_zone_id;
      if not found then
        v_code := 'zone_unknown';
        v_message := 'That delivery area does not exist.';
        exit checks;
      end if;
      if not v_zone.is_active then
        v_code := 'zone_inactive';
        v_message := 'We do not currently deliver to that area.';
        exit checks;
      end if;
    end if;

    -- The one fee calculation. Zero rows means the method or zone is not active.
    select * into v_res
    from public.resolve_delivery_fee(v_method.code, p_zone_id, p_subtotal_cents);
    if not found then
      v_code := 'unavailable';
      v_message := 'That delivery option is not available right now.';
      exit checks;
    end if;

    if p_subtotal_cents < v_res.min_order_cents then
      v_code := 'below_minimum_order';
      v_message := 'Your order is below the minimum for this delivery option.';
      v_min := v_res.min_order_cents;
      exit checks;
    end if;

    v_have_fee := true;
  end checks;

  return query
  select
    v_code is null,
    v_code,
    v_message,
    v_method.code,
    v_method.label,
    v_method.requires_slot,
    v_method.requires_address,
    v_zone.id,
    v_zone.code,
    v_zone.name,
    p_subtotal_cents,
    case when v_have_fee then v_res.fee_cents end,
    case when v_have_fee then v_res.base_fee_cents end,
    case when v_have_fee then v_res.free_over_cents end,
    case when v_have_fee then v_res.min_order_cents else v_min end,
    case when v_have_fee then v_res.fee_source end,
    case when v_have_fee then v_res.zone_fee_id end,
    case
      when v_have_fee then jsonb_build_object(
        'source', v_res.fee_source,
        'base_fee_cents', v_res.base_fee_cents,
        'free_over_cents', v_res.free_over_cents,
        'min_order_cents', v_res.min_order_cents,
        'zone_fee_id', v_res.zone_fee_id
      )
    end;
end;
$$;

revoke execute on function public.validate_delivery_selection(text, uuid, integer) from public;
grant execute on function public.validate_delivery_selection(text, uuid, integer)
  to anon, authenticated;
