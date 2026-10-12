-- =============================================================================
-- PHASE 8 follow-up: validate_coupon() also returns the SERVER's final payable total.
--
-- WHY: checkout used to compute "quote total - discount" in the browser. Totals must not be computed on
-- the client, so the database now answers with the amount to display AND to send as the expected-total
-- veto (create_order()'s p_expected_total_cents).
--
-- WHAT CHANGES (one function; nothing else, and migration 20261009010000 is NOT edited):
--   validate_coupon(p_items jsonb, p_code text default null)
--     -> validate_coupon(p_items jsonb, p_code text default null,
--                        p_delivery_method text default null, p_zone_id uuid default null)
--   The old 2-argument function is dropped (an overload would make 2-argument calls ambiguous). Existing
--   2-argument callers keep working through the defaults and get EXACTLY the old reply.
--
-- REPLY: unchanged keys, plus -- only when a delivery method was supplied AND validate_delivery_selection()
--   accepts it for the server-priced basket:
--     delivery_fee_cents  the fee from validate_delivery_selection() (the same call create_order() makes)
--     total_cents         subtotal + delivery fee - discount   (the same arithmetic as create_order())
--   Without a (valid) delivery selection the two keys are ABSENT: the total is unknown, never guessed.
--   A rejected coupon still answers {ok:false, error} with no amounts.
--
-- STILL A PREVIEW: no locks, nothing recorded. create_order() re-decides everything and refuses an order
-- whose p_expected_total_cents differs. It also does checks this preview does not (address <-> zone match,
-- slot, stock, suspension), so a total here is "what create_order() would charge if those pass".
-- The delivery fee is now passed to resolve_promotion() as create_order() passes it; delivery is still
-- not discountable (coupon_eligible_base_cents), so the discount is unchanged.
--
-- PRIVILEGES: SECURITY DEFINER, search_path = public, pg_temp, authenticated only (not anon, not
-- service_role, not PUBLIC) -- the same as before.
--
-- STATUS: written, NOT applied to any database, NOT executed. Test with
-- db/tests/phase8_validate_coupon_total.test.sql.
-- =============================================================================
begin;

-- 0. Preconditions ------------------------------------------------------------------------------
do $pre$
begin
  if to_regclass('public.promotions') is null
     or to_regprocedure('public.resolve_promotion(text,uuid,integer,integer,boolean,timestamptz)') is null
     or to_regprocedure('public.coupon_eligible_base_cents(integer,integer)') is null
     or to_regprocedure('public.validate_delivery_selection(text,uuid,integer)') is null then
    raise exception 'Phase 8 follow-up precondition failed: apply 20261009010000_phase8_discounts_promotions.sql first.';
  end if;

  if to_regprocedure('public.validate_coupon(jsonb,text,text,uuid)') is not null then
    raise exception 'Phase 8 follow-up appears to be applied already. Not running it twice.';
  end if;

  if (select count(*) from pg_proc where proname = 'validate_coupon' and pronamespace = 'public'::regnamespace) <> 1
     or to_regprocedure('public.validate_coupon(jsonb,text)') is null then
    raise exception 'Phase 8 follow-up precondition failed: expected exactly the 2-argument validate_coupon().';
  end if;

  -- The function being replaced must be the one 20261009010000 created (md5 of its body, computed from
  -- that migration file with carriage returns removed, not read from a database).
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.validate_coupon(jsonb,text)'::regprocedure)
       <> 'aaa674cbb9ba24178a1a9b909f0d301f' then
    raise exception 'Phase 8 follow-up precondition failed: validate_coupon() differs from migration 20261009010000. Compare before continuing.';
  end if;
end
$pre$;

-- 1. Replace validate_coupon ----------------------------------------------------------------------
drop function public.validate_coupon(jsonb, text);

create function public.validate_coupon(
  p_items jsonb,
  p_code text default null,
  p_delivery_method text default null,
  p_zone_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_subtotal bigint;
  v_bad integer;
  v_r record;
  v_d record;
  v_fee integer := 0;
  v_has_delivery boolean := false;
  v_total bigint;
  v_totals jsonb := '{}'::jsonb;
begin
  if v_user is null then
    raise exception 'You must be signed in.' using errcode = '42501', detail = 'not_authorised';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'Your basket is empty or invalid.' using errcode = 'P0001', detail = 'invalid_cart';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
     where x.product_id is null or x.quantity is null or x.quantity < 1 or x.quantity > 99
  ) then
    raise exception 'Your basket is empty or invalid.' using errcode = 'P0001', detail = 'invalid_cart';
  end if;

  with merged as (
    select x.product_id, x.variant_id, sum(x.quantity)::integer as qty
      from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
     group by x.product_id, x.variant_id
  ), priced as (
    select m.qty,
           case when m.variant_id is null then pr.price_cents else v.price_cents end as unit_cents,
           (pr.id is not null and (m.variant_id is null or v.id is not null) and m.qty <= 99) as ok
      from merged m
      left join public.products pr on pr.id = m.product_id and pr.is_active
      left join public.product_variants v
             on v.id = m.variant_id and v.product_id = m.product_id and v.is_active
  )
  select coalesce(sum(unit_cents::bigint * qty) filter (where ok), 0),
         count(*) filter (where not ok)
    into v_subtotal, v_bad
    from priced;

  if v_bad > 0 or v_subtotal > 2147483647 then
    raise exception 'A product in your basket is no longer available.' using errcode = 'P0001', detail = 'invalid_cart';
  end if;

  -- Delivery fee: the same call, on the same server-priced subtotal, that create_order() makes. Only a
  -- selection it accepts (valid, with a non-negative fee and a fee rule) yields a total.
  if p_delivery_method is not null then
    select * into v_d
      from public.validate_delivery_selection(p_delivery_method, p_zone_id, v_subtotal::integer);
    if found then   -- nested on purpose: plpgsql does not promise AND short-circuits, and v_d is unassigned otherwise
      if v_d.is_valid is true
         and v_d.fee_cents is not null and v_d.fee_cents >= 0 and v_d.fee_rule is not null then
        v_fee := v_d.fee_cents;
        v_has_delivery := true;
      end if;
    end if;
  end if;

  select * into v_r
    from public.resolve_promotion(p_code, v_user, v_subtotal::integer, v_fee, false, now());

  if v_r.error_code is not null then
    return jsonb_build_object('ok', false, 'error', v_r.error_code);
  end if;

  if v_has_delivery then
    v_total := v_subtotal + v_fee - case when v_r.promotion_id is null then 0 else v_r.discount_cents end;
    if v_total < 0 or v_total > 2147483647 then
      raise exception 'A product in your basket is no longer available.' using errcode = 'P0001', detail = 'invalid_cart';
    end if;
    v_totals := jsonb_build_object('delivery_fee_cents', v_fee, 'total_cents', v_total);
  end if;

  if v_r.promotion_id is null then
    return jsonb_build_object('ok', true, 'applied', false, 'subtotal_cents', v_subtotal, 'discount_cents', 0)
           || v_totals;
  end if;
  return jsonb_build_object(
    'ok', true, 'applied', true,
    'code', v_r.promo_code, 'name', v_r.promo_name,
    'discount_type', v_r.promo_type, 'discount_value', v_r.promo_value,
    'discount_cents', v_r.discount_cents,
    'subtotal_cents', v_subtotal,
    'eligible_cents', public.coupon_eligible_base_cents(v_subtotal::integer, v_fee))
    || v_totals;
end;
$$;

-- 2. Privileges: signed-in customers only (preview) ---------------------------------------------------
revoke all on function public.validate_coupon(jsonb, text, text, uuid) from public, anon, service_role;
grant execute on function public.validate_coupon(jsonb, text, text, uuid) to authenticated;

-- 3. Self-check: any failure aborts and rolls the whole migration back ----------------------------------
do $chk$
declare
  v_fn constant regprocedure := 'public.validate_coupon(jsonb,text,text,uuid)'::regprocedure;
  v_src text;
begin
  if (select count(*) from pg_proc where proname = 'validate_coupon' and pronamespace = 'public'::regnamespace) <> 1
     or to_regprocedure('public.validate_coupon(jsonb,text)') is not null then
    raise exception 'Phase 8 follow-up self-check failed: validate_coupon() must have exactly one overload.';
  end if;

  if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('service_role', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_fn and a.grantee = 0) then
    raise exception 'Phase 8 follow-up self-check failed: validate_coupon() must be executable by authenticated only.';
  end if;

  if not exists (select 1 from pg_proc p
                 where p.oid = v_fn and p.prosecdef
                   and exists (select 1 from unnest(p.proconfig) c where c = 'search_path=public, pg_temp')) then
    raise exception 'Phase 8 follow-up self-check failed: validate_coupon() is not SECURITY DEFINER with search_path = public, pg_temp.';
  end if;

  -- No argument can carry an amount; the preview takes no lock; it asks the same delivery function
  -- create_order() asks and the same promotion resolver, and does not trust anything for the total.
  if exists (select 1 from unnest((select p.proargnames from pg_proc p where p.oid = v_fn)) n
              where n ilike '%discount%' or n ilike '%fee%' or n ilike '%subtotal%' or n ilike '%total%') then
    raise exception 'Phase 8 follow-up self-check failed: validate_coupon() has an argument that could carry an amount.';
  end if;
  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;
  if v_src ilike '%for update%'
     or strpos(v_src, 'public.validate_delivery_selection(p_delivery_method, p_zone_id, v_subtotal::integer)') = 0
     or strpos(v_src, 'public.resolve_promotion(p_code, v_user, v_subtotal::integer, v_fee, false, now())') = 0
     or strpos(v_src, 'total_cents') = 0
     or strpos(v_src, 'auth.uid()') = 0 then
    raise exception 'Phase 8 follow-up self-check failed: validate_coupon() body is not as expected.';
  end if;
end
$chk$;

commit;
