-- =============================================================================
-- Delivery validation (PHASE 4B.1).
--
-- Apply AFTER 20260930030000_delivery_system_foundation.sql (SQL editor, or
-- `supabase db push`). Safe to re-run: the function is created with
-- CREATE OR REPLACE and nothing else is touched.
--
-- Adds ONE function, public.validate_delivery_selection(), the reusable gate that
-- create_order() (PHASE 4C) will call. It does not change any table, policy or grant
-- from PHASE 4A, and it does not change create_order(): checkout behaves exactly as
-- before until 4C wires this in.
--
-- What it validates, in this order (first failure wins):
--   invalid_subtotal       subtotal is NULL or negative
--   method_required        no method code supplied
--   method_unknown         no delivery_methods row with that code
--   method_inactive        the method exists but is_active = false
--   zone_required          the method needs an address (requires_address) and no zone was given
--   zone_unknown           no delivery_zones row with that id
--   zone_inactive          the zone exists but is_active = false
--   unavailable            the active method/zone could not be resolved (e.g. deactivated a
--                          moment ago); treat as "not available, refresh"
--   below_minimum_order    subtotal < the effective minimum order
--
-- Fee and minimum order are NOT computed here. They come from the existing
-- public.resolve_delivery_fee(), the single fee calculation:
--   * zone fee rule for (zone, method) when an active one exists, else the method's own fee
--   * free-over threshold from the same source
--   * minimum order = greatest(method minimum, zone-rule minimum)
--
-- There is deliberately NO parameter for a client-supplied fee. The caller passes a
-- method code, a zone id and a subtotal; everything else is read from configuration.
-- (Phase 4C must pass the subtotal it computed itself from locked prices, never a
-- client-sent number.)
--
-- Design decisions worth knowing:
--   * It never raises for a rejected selection: it returns one row with is_valid = false and
--     an error_code, so the same call serves a checkout quote and create_order(). The caller
--     in create_order() should do:
--         select * into v_delivery from public.validate_delivery_selection(...);
--         if not v_delivery.is_valid then raise exception '%', v_delivery.error_message
--           using errcode = 'P0001'; end if;
--   * SECURITY DEFINER so unknown and inactive can be told apart (a customer's RLS hides
--     inactive rows, which would make both look like "unknown"). It only ever returns error
--     codes, the resolved fee and the same fields customers can already read on ACTIVE rows;
--     it exposes no other table data. search_path is pinned.
--   * A zone is required when the method requires an address. Otherwise a client could omit
--     the zone and be charged the cheaper method default instead of the zone fee. A method
--     with no address (store pickup) does not need a zone; if one is supplied it is still
--     validated and any matching zone fee rule is used.
--   * Which zone an address belongs to is NOT modelled in the schema (addresses carry no zone),
--     so the zone id still comes from the caller. See the remaining-work notes in HANDOFF.md.
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

-- Same exposure as resolve_delivery_fee(): checkout previews before sign-in are allowed,
-- and create_order() (SECURITY DEFINER) does not need an extra grant to call it.
revoke execute on function public.validate_delivery_selection(text, uuid, integer) from public;
grant execute on function public.validate_delivery_selection(text, uuid, integer)
  to anon, authenticated;
