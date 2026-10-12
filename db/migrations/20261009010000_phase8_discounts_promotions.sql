-- =============================================================================
-- PHASE 8 - DISCOUNTS & PROMOTIONS. NOT APPLIED / NOT RUN anywhere (no PostgreSQL was available
-- when this was written). Apply once, after 20261005160000 (Phase 7). One transaction.
-- Section 0 refuses a second run and refuses to run if create_order() is not the Phase 6E.3 one.
--
-- ADDS
--   public.promotions               coupons (code set) and automatic promotions (code NULL), one table.
--   public.promotion_redemptions    one row per order that used a promotion; released_at frees it.
--   orders.discount_* columns       immutable snapshot of the discount an order received.
--   create_order(...)               REPLACED: 13th trailing argument p_coupon_code text default null.
--                                   The 12-argument function is dropped (same precedent as Phase 4C's p_zone_id).
--   validate_coupon(p_items, p_code)  authenticated. Preview only; the real decision is re-made in create_order().
--   admin_create_promotion / admin_update_promotion / admin_set_promotion_active / admin_list_promotions
--                                   authenticated, require_admin() inside, audited.
--   internal (no API role can call): coupon_eligible_base_cents, compute_promotion_discount,
--                                   promotion_evaluate, resolve_promotion, three guard/sync triggers.
--
-- RULES (the single source of truth is this file; the TypeScript in src/features/promotions mirrors it)
--   * MONEY: integer cents. percentage promotions store BASIS POINTS in `value` (1..10000 = 0.01%..100%);
--     fixed promotions store cents. Percentage amount = floor(eligible * bps / 10000), then the optional
--     max_discount_cents cap, then never more than the eligible base, never below 0.
--   * DELIVERY IS NOT DISCOUNTABLE. One place decides: coupon_eligible_base_cents(). The minimum order
--     (min_order_cents) is compared with the same base. The total can therefore never go below the fee.
--   * ONE promotion per order, no stacking. A supplied code wins and must be valid, otherwise create_order()
--     fails with DETAIL coupon_<code>. With no code, the single best valid AUTOMATIC promotion applies
--     (largest amount; ties -> oldest). An automatic promotion that does not qualify is silently skipped.
--   * ERROR CODES (the only ones that ever leave the database): invalid, not_started, expired, min_not_met,
--     limit_reached, already_used. A code that does not exist, is inactive or is malformed is 'invalid'
--     (indistinguishable). create_order() raises P0001 with DETAIL 'coupon_<code>'.
--   * RACE SAFETY: a promotion with a usage_limit or per_customer_limit is locked FOR UPDATE inside
--     create_order() until COMMIT, and limits are counted from promotion_redemptions (released_at IS NULL)
--     AFTER the lock is granted, so two concurrent orders cannot both take the last use. UNIQUE (order_id)
--     makes a second redemption on the same order impossible. Requires READ COMMITTED (the default).
--     Lock order: products -> delivery slot -> promotion rows (id order). Nothing locks promotions first.
--   * RELEASE: a rolled-back create_order() never wrote a redemption. Moving an order to cancelled or
--     refunded sets released_at (trigger); moving it back re-takes the use if the limits still allow it,
--     else the status change is refused (DETAIL coupon_reactivation_limit_reached).
--     A payment that FAILS does not cancel the order (Phase 6G), so it keeps its use until staff cancel it.
--   * SNAPSHOT: orders.discount_code / name / type / value / applied_at + discount_cents are copied at order
--     time and a trigger refuses any later change. Editing or deactivating a promotion never touches orders.
--   * ACCESS: both new tables have RLS on, no policy and NO privilege for any API role. Customers reach
--     promotions only through validate_coupon() and create_order(); admins only through admin_*().
--
-- DOES NOT: add UI, change any other function, touch an earlier migration, or send anything.
-- =============================================================================
begin;

-- 0. Preconditions ------------------------------------------------------------------------------
do $pre$
declare
  v_co constant text := 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)';
  v_count integer;
begin
  if to_regclass('public.orders') is null
     or to_regclass('public.order_items') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.products') is null
     or to_regclass('public.product_variants') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regclass('public.notification_outbox') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.set_updated_at()') is null then
    raise exception 'Phase 8 precondition failed: apply migrations up to 20261005160000 first.';
  end if;

  if to_regclass('public.promotions') is not null
     or to_regclass('public.promotion_redemptions') is not null
     or to_regprocedure('public.validate_coupon(jsonb,text)') is not null
     or exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'orders' and column_name = 'discount_code') then
    raise exception 'Phase 8 appears to be applied already. Not running it twice.';
  end if;

  -- create_order() must be the single 12-argument Phase 6E.3 function (body md5 pinned from the file
  -- 20261004170000_phase6e3_customer_hardening.sql, computed the same way that migration pinned 5B.2's).
  select count(*) into v_count from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace;
  if v_count <> 1 or to_regprocedure(v_co) is null then
    raise exception 'Phase 8 precondition failed: expected exactly one 12-argument create_order(), found % overload(s).', v_count;
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(v_co))
       <> '1f087e8de9c1abd28fd5b0361588e96d' then
    raise exception 'Phase 8 precondition failed: create_order() in this database differs from migration 20261004170000. This migration replaces it, so compare the two before continuing.';
  end if;

  -- The orders table already has discount_cents (always 0 so far). Anything else would break the new CHECKs.
  if exists (select 1 from public.orders where discount_cents <> 0) then
    raise exception 'Phase 8 precondition failed: existing orders carry a non-zero discount_cents. Inspect before continuing.';
  end if;
end
$pre$;

-- 1. promotions ---------------------------------------------------------------------------------
create table public.promotions (
  id                 uuid primary key default gen_random_uuid(),
  -- Canonical (upper-case) coupon code. NULL = AUTOMATIC promotion (applies without a code).
  code               text,
  name               text not null,
  discount_type      text not null,
  -- percentage: basis points (1..10000). fixed: cents.
  value              integer not null,
  -- Optional cap in cents (percentage promotions only).
  max_discount_cents integer,
  -- Minimum merchandise subtotal in cents (delivery excluded - see coupon_eligible_base_cents()).
  min_order_cents    integer not null default 0,
  starts_at          timestamptz,
  expires_at         timestamptz,
  usage_limit        integer,
  per_customer_limit integer,
  is_active          boolean not null default true,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint promotions_code_format check (code is null or code ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'),
  constraint promotions_name_length check (char_length(btrim(name)) between 1 and 120),
  constraint promotions_type_check check (discount_type in ('percentage', 'fixed')),
  constraint promotions_value_range check (
    (discount_type = 'percentage' and value between 1 and 10000)
    or (discount_type = 'fixed' and value between 1 and 100000000)),
  constraint promotions_max_discount_check check (
    max_discount_cents is null or (discount_type = 'percentage' and max_discount_cents > 0)),
  constraint promotions_min_order_check check (min_order_cents >= 0),
  constraint promotions_window_check check (starts_at is null or expires_at is null or expires_at > starts_at),
  constraint promotions_usage_limit_check check (usage_limit is null or usage_limit >= 1),
  constraint promotions_per_customer_limit_check check (per_customer_limit is null or per_customer_limit >= 1)
);

create unique index promotions_code_key on public.promotions (code) where code is not null;
create index promotions_automatic_idx on public.promotions (created_at, id) where code is null and is_active;

comment on table public.promotions is
  'Coupons (code set) and automatic promotions (code NULL). Read/written only by SECURITY DEFINER functions: no API role has any privilege. percentage value = basis points, fixed value = cents.';

create trigger promotions_set_updated_at
  before update on public.promotions
  for each row execute function public.set_updated_at();

-- 2. promotion_redemptions ------------------------------------------------------------------------
create table public.promotion_redemptions (
  id            uuid primary key default gen_random_uuid(),
  promotion_id  uuid not null references public.promotions (id),
  order_id      uuid not null references public.orders (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  amount_cents  integer not null,
  redeemed_at   timestamptz not null default now(),
  released_at   timestamptz,
  release_reason text,

  -- One promotion per order, and the same order can never redeem twice (idempotent by construction).
  constraint promotion_redemptions_order_id_key unique (order_id),
  constraint promotion_redemptions_amount_check check (amount_cents > 0),
  constraint promotion_redemptions_release_check check (
    (released_at is null and release_reason is null)
    or (released_at is not null and release_reason is not null
        and release_reason in ('order_cancelled', 'order_refunded')))
);

create index promotion_redemptions_active_idx
  on public.promotion_redemptions (promotion_id) where released_at is null;
create index promotion_redemptions_customer_idx
  on public.promotion_redemptions (promotion_id, user_id) where released_at is null;

comment on table public.promotion_redemptions is
  'One row per order that used a promotion. released_at IS NULL = the use counts toward the limits. No API role has any privilege.';

-- 3. Lockdown: no API role touches either table --------------------------------------------------
revoke all on public.promotions from public, anon, authenticated, service_role;
revoke all on public.promotion_redemptions from public, anon, authenticated, service_role;
alter table public.promotions enable row level security;              -- no policy: deny by default
alter table public.promotion_redemptions enable row level security;   -- no policy: deny by default

-- 4. Immutable discount snapshot on orders -----------------------------------------------------------
alter table public.orders
  add column discount_promotion_id uuid references public.promotions (id),
  add column discount_code         text,
  add column discount_name         text,
  add column discount_type         text,
  add column discount_value        integer,
  add column discount_applied_at   timestamptz;

comment on column public.orders.discount_cents is
  'Discount in cents. Written once by create_order(); the snapshot columns below describe it and are immutable (trigger).';
comment on column public.orders.discount_code is
  'Coupon code at order time (NULL for an automatic promotion). Snapshot: later promotion edits never change it.';

alter table public.orders
  add constraint orders_discount_within_subtotal check (discount_cents <= subtotal_cents),
  add constraint orders_discount_snapshot_consistent check (
    (discount_promotion_id is null and discount_code is null and discount_name is null
       and discount_type is null and discount_value is null and discount_applied_at is null
       and discount_cents = 0)
    or
    -- Explicit IS NOT NULL: a CHECK that evaluates to NULL passes, so `discount_value > 0` alone would let a NULL through.
    (discount_promotion_id is not null and discount_name is not null
       and discount_type is not null and discount_type in ('percentage', 'fixed')
       and discount_value is not null and discount_value > 0
       and discount_applied_at is not null and discount_cents > 0));

-- 5. Guards ---------------------------------------------------------------------------------------------
-- 5a. The discount an order received can never change.
create function public.orders_guard_discount_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (new.discount_cents, new.discount_promotion_id, new.discount_code, new.discount_name,
      new.discount_type, new.discount_value, new.discount_applied_at)
     is distinct from
     (old.discount_cents, old.discount_promotion_id, old.discount_code, old.discount_name,
      old.discount_type, old.discount_value, old.discount_applied_at) then
    raise exception 'The discount on an order cannot be changed.'
      using errcode = 'P0001', detail = 'discount_snapshot_immutable';
  end if;
  return new;
end;
$$;

create trigger orders_guard_discount_snapshot
  before update of discount_cents, discount_promotion_id, discount_code, discount_name,
                   discount_type, discount_value, discount_applied_at
  on public.orders
  for each row execute function public.orders_guard_discount_snapshot();

-- 5b. A redemption's identity is immutable; only the release columns move.
create function public.promotion_redemptions_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (new.id, new.promotion_id, new.order_id, new.user_id, new.amount_cents, new.redeemed_at)
     is distinct from
     (old.id, old.promotion_id, old.order_id, old.user_id, old.amount_cents, old.redeemed_at) then
    raise exception 'A promotion redemption cannot be changed, only released.'
      using errcode = 'P0001', detail = 'redemption_immutable';
  end if;
  return new;
end;
$$;

create trigger promotion_redemptions_guard
  before update on public.promotion_redemptions
  for each row execute function public.promotion_redemptions_guard();

-- 6. Pure rule helpers (internal) ----------------------------------------------------------------------
-- 6a. THE one place that decides what a discount may apply to. Delivery is NOT discountable.
--     To make delivery discountable, change ONLY this function (and DELIVERY_DISCOUNTABLE in
--     src/features/promotions/logic.ts, which a unit test pins to this behaviour).
create function public.coupon_eligible_base_cents(p_subtotal_cents integer, p_delivery_fee_cents integer)
returns integer
language sql
immutable
security definer
set search_path = public, pg_temp
as $$
  select greatest(coalesce(p_subtotal_cents, 0), 0);
$$;

-- 6b. The amount. Never more than the eligible base, never below zero.
create function public.compute_promotion_discount(
  p_type text, p_value integer, p_max_discount_cents integer, p_eligible_cents integer)
returns integer
language plpgsql
immutable
security definer
set search_path = public, pg_temp
as $$
declare
  v_amount bigint;
begin
  if p_eligible_cents is null or p_eligible_cents <= 0 or p_value is null or p_value <= 0 then
    return 0;
  end if;
  if p_type = 'percentage' then
    v_amount := (p_eligible_cents::bigint * p_value::bigint) / 10000;   -- floor: rounds in the shop's favour
    if p_max_discount_cents is not null then
      v_amount := least(v_amount, p_max_discount_cents::bigint);
    end if;
  elsif p_type = 'fixed' then
    v_amount := p_value::bigint;
  else
    return 0;
  end if;
  return greatest(least(v_amount, p_eligible_cents::bigint), 0)::integer;
end;
$$;

-- 6c. Decide whether ONE promotion applies. Returns exactly one row: (error_code, discount_cents).
--     error_code is NULL when it applies. Counts come from promotion_redemptions (released_at IS NULL);
--     the caller holds the promotion row lock when the answer must be race-safe.
create function public.promotion_evaluate(
  p public.promotions,
  p_user uuid,
  p_subtotal_cents integer,
  p_delivery_fee_cents integer,
  p_now timestamptz)
returns table (error_code text, discount_cents integer)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_base integer := public.coupon_eligible_base_cents(p_subtotal_cents, p_delivery_fee_cents);
  v_amount integer;
begin
  if p.id is null or not p.is_active then
    return query select 'invalid'::text, 0;  return;
  end if;
  if p.starts_at is not null and p_now < p.starts_at then
    return query select 'not_started'::text, 0;  return;
  end if;
  if p.expires_at is not null and p_now >= p.expires_at then
    return query select 'expired'::text, 0;  return;
  end if;
  if v_base < p.min_order_cents then
    return query select 'min_not_met'::text, 0;  return;
  end if;
  if p.usage_limit is not null
     and (select count(*) from public.promotion_redemptions r
           where r.promotion_id = p.id and r.released_at is null) >= p.usage_limit then
    return query select 'limit_reached'::text, 0;  return;
  end if;
  if p.per_customer_limit is not null and p_user is not null
     and (select count(*) from public.promotion_redemptions r
           where r.promotion_id = p.id and r.user_id = p_user and r.released_at is null) >= p.per_customer_limit then
    return query select 'already_used'::text, 0;  return;
  end if;

  v_amount := public.compute_promotion_discount(p.discount_type, p.value, p.max_discount_cents, v_base);
  if v_amount <= 0 then
    return query select 'invalid'::text, 0;  return;
  end if;
  return query select null::text, v_amount;
end;
$$;

-- 6d. Pick the promotion for an order. Always returns EXACTLY ONE row.
--       p_code given   -> that coupon or an error_code (never falls back to an automatic promotion).
--       p_code NULL    -> the best valid automatic promotion, or an all-NULL row (nothing applies, no error).
--     p_lock = true (create_order only) locks the LIMITED candidate rows FOR UPDATE, in id order, BEFORE the
--     limits are counted. Unlimited promotions have no counter to protect and are not locked, so a popular
--     unlimited code does not serialise checkouts.
create function public.resolve_promotion(
  p_code text,
  p_user uuid,
  p_subtotal_cents integer,
  p_delivery_fee_cents integer,
  p_lock boolean default false,
  p_now timestamptz default now())
returns table (
  promotion_id uuid, error_code text, discount_cents integer,
  promo_code text, promo_name text, promo_type text, promo_value integer)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_p public.promotions;
  v_best public.promotions;
  v_best_amount integer := 0;
  v_err text;
  v_amount integer;
begin
  if v_code is not null then
    if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,31}$' then
      return query select null::uuid, 'invalid'::text, 0, null::text, null::text, null::text, null::integer;
      return;
    end if;
    select * into v_p from public.promotions pr where pr.code = v_code;
    if not found then
      return query select null::uuid, 'invalid'::text, 0, null::text, null::text, null::text, null::integer;
      return;
    end if;
    if p_lock and (v_p.usage_limit is not null or v_p.per_customer_limit is not null) then
      -- Lock, then RE-READ: READ COMMITTED returns the latest committed version of the locked row.
      select * into v_p from public.promotions pr where pr.id = v_p.id for update;
    end if;
    select e.error_code, e.discount_cents into v_err, v_amount
      from public.promotion_evaluate(v_p, p_user, p_subtotal_cents, p_delivery_fee_cents, p_now) e;
    if v_err is not null then
      return query select null::uuid, v_err, 0, null::text, null::text, null::text, null::integer;
      return;
    end if;
    return query select v_p.id, null::text, v_amount, v_p.code, v_p.name, v_p.discount_type, v_p.value;
    return;
  end if;

  -- Automatic promotions.
  if p_lock then
    perform 1 from public.promotions pr
     where pr.code is null and pr.is_active
       and (pr.usage_limit is not null or pr.per_customer_limit is not null)
     order by pr.id
       for update;
  end if;

  for v_p in
    select * from public.promotions pr
     where pr.code is null and pr.is_active
     order by pr.created_at, pr.id
  loop
    select e.error_code, e.discount_cents into v_err, v_amount
      from public.promotion_evaluate(v_p, p_user, p_subtotal_cents, p_delivery_fee_cents, p_now) e;
    if v_err is null and v_amount > v_best_amount then   -- strict >: ties keep the oldest
      v_best := v_p;
      v_best_amount := v_amount;
    end if;
  end loop;

  if v_best.id is null then
    return query select null::uuid, null::text, 0, null::text, null::text, null::text, null::integer;
  else
    return query select v_best.id, null::text, v_best_amount, v_best.code, v_best.name, v_best.discount_type, v_best.value;
  end if;
end;
$$;

-- 7. Customer preview: validate_coupon ------------------------------------------------------------------
-- Preview ONLY. It prices the basket from the database (never from the client), asks resolve_promotion()
-- WITHOUT locks, and returns a safe jsonb. The binding decision is made again inside create_order().
-- p_code NULL previews the automatic promotion. The delivery fee is passed as 0 on purpose: delivery is not
-- discountable (coupon_eligible_base_cents). If that rule ever changes, this function needs the fee too.
create function public.validate_coupon(p_items jsonb, p_code text default null)
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

  select * into v_r
    from public.resolve_promotion(p_code, v_user, v_subtotal::integer, 0, false, now());

  if v_r.error_code is not null then
    return jsonb_build_object('ok', false, 'error', v_r.error_code);
  end if;
  if v_r.promotion_id is null then
    return jsonb_build_object('ok', true, 'applied', false, 'subtotal_cents', v_subtotal, 'discount_cents', 0);
  end if;
  return jsonb_build_object(
    'ok', true, 'applied', true,
    'code', v_r.promo_code, 'name', v_r.promo_name,
    'discount_type', v_r.promo_type, 'discount_value', v_r.promo_value,
    'discount_cents', v_r.discount_cents,
    'subtotal_cents', v_subtotal,
    'eligible_cents', public.coupon_eligible_base_cents(v_subtotal::integer, 0));
end;
$$;

-- 8. Release / re-take a redemption when the order is cancelled / refunded / reactivated -----------------
-- AFTER trigger: it runs after every BEFORE trigger on orders, including the stock restock/re-reserve one,
-- so locks are always taken products -> slot -> promotion (the same order create_order() uses).
create function public.orders_sync_promotion_redemption()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.promotion_redemptions;
  v_p public.promotions;
begin
  select * into v_r from public.promotion_redemptions r where r.order_id = new.id;
  if not found then
    return new;
  end if;

  if new.status in ('cancelled', 'refunded') and old.status not in ('cancelled', 'refunded') then
    update public.promotion_redemptions r
       set released_at = now(),
           release_reason = case when new.status = 'cancelled' then 'order_cancelled' else 'order_refunded' end
     where r.id = v_r.id and r.released_at is null;

  elsif old.status in ('cancelled', 'refunded') and new.status not in ('cancelled', 'refunded')
        and v_r.released_at is not null then
    -- Take the use back. Only the limits are re-checked (the order was valid when it was placed;
    -- the window and the minimum are deliberately not re-applied). Locked, then counted.
    select * into v_p from public.promotions pr where pr.id = v_r.promotion_id for update;
    if v_p.usage_limit is not null
       and (select count(*) from public.promotion_redemptions r
             where r.promotion_id = v_p.id and r.released_at is null) >= v_p.usage_limit then
      raise exception 'This order''s coupon has reached its usage limit, so the order cannot be reactivated.'
        using errcode = 'P0001', detail = 'coupon_reactivation_limit_reached';
    end if;
    if v_p.per_customer_limit is not null
       and (select count(*) from public.promotion_redemptions r
             where r.promotion_id = v_p.id and r.user_id = v_r.user_id and r.released_at is null) >= v_p.per_customer_limit then
      raise exception 'This order''s coupon has reached the per-customer limit, so the order cannot be reactivated.'
        using errcode = 'P0001', detail = 'coupon_reactivation_limit_reached';
    end if;
    update public.promotion_redemptions r
       set released_at = null, release_reason = null
     where r.id = v_r.id;
  end if;
  return new;
end;
$$;

create trigger orders_sync_promotion_redemption
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.orders_sync_promotion_redemption();

-- 9. Admin functions (require_admin() first, audited, no hard delete) ----------------------------------------
create function public.admin_create_promotion(p_input jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_allowed constant text[] := array['code', 'name', 'discount_type', 'value', 'max_discount_cents',
    'min_order_cents', 'starts_at', 'expires_at', 'usage_limit', 'per_customer_limit', 'is_active'];
  v_actor uuid;
  v_key text;
  v_row public.promotions;
begin
  perform public.require_admin();   -- the gate runs before any argument is examined
  v_actor := auth.uid();

  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise exception 'Promotion details are required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  for v_key in select jsonb_object_keys(p_input) loop
    if not (v_key = any (c_allowed)) then
      raise exception 'Unknown promotion field.' using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end loop;

  begin
    insert into public.promotions (
      code, name, discount_type, value, max_discount_cents, min_order_cents,
      starts_at, expires_at, usage_limit, per_customer_limit, is_active, created_by)
    values (
      nullif(upper(btrim(coalesce(p_input ->> 'code', ''))), ''),
      btrim(coalesce(p_input ->> 'name', '')),
      p_input ->> 'discount_type',
      (p_input ->> 'value')::integer,
      (p_input ->> 'max_discount_cents')::integer,
      coalesce((p_input ->> 'min_order_cents')::integer, 0),
      (p_input ->> 'starts_at')::timestamptz,
      (p_input ->> 'expires_at')::timestamptz,
      (p_input ->> 'usage_limit')::integer,
      (p_input ->> 'per_customer_limit')::integer,
      coalesce((p_input ->> 'is_active')::boolean, true),
      v_actor)
    returning * into v_row;
  exception
    when unique_violation then
      raise exception 'That coupon code is already in use.' using errcode = 'P0001', detail = 'code_taken';
    when check_violation or not_null_violation or invalid_text_representation
         or numeric_value_out_of_range or invalid_datetime_format or datetime_field_overflow then
      raise exception 'The promotion details are not valid.' using errcode = 'P0001', detail = 'invalid_promotion';
  end;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'promotion_created', v_row.id,
          left(format('code=%s type=%s value=%s', coalesce(v_row.code, '(automatic)'),
                      v_row.discount_type, v_row.value), 500));

  return jsonb_build_object('promotion', to_jsonb(v_row));
end;
$$;

create function public.admin_update_promotion(p_promotion_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_allowed constant text[] := array['code', 'name', 'discount_type', 'value', 'max_discount_cents',
    'min_order_cents', 'starts_at', 'expires_at', 'usage_limit', 'per_customer_limit'];
  v_actor uuid;
  v_key text;
  v_old public.promotions;
  v_row public.promotions;
  v_changed text[];
begin
  perform public.require_admin();
  v_actor := auth.uid();

  if p_promotion_id is null or p_changes is null or jsonb_typeof(p_changes) <> 'object'
     or p_changes = '{}'::jsonb then
    raise exception 'A promotion and at least one change are required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if not (v_key = any (c_allowed)) then
      raise exception 'Unknown promotion field.' using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end loop;

  select * into v_old from public.promotions pr where pr.id = p_promotion_id for update;
  if not found then
    raise exception 'Promotion not found.' using errcode = 'P0001', detail = 'promotion_not_found';
  end if;
  v_row := v_old;

  begin
    if p_changes ? 'code' then
      v_row.code := nullif(upper(btrim(coalesce(p_changes ->> 'code', ''))), '');
    end if;
    if p_changes ? 'name' then v_row.name := btrim(coalesce(p_changes ->> 'name', '')); end if;
    if p_changes ? 'discount_type' then v_row.discount_type := p_changes ->> 'discount_type'; end if;
    if p_changes ? 'value' then v_row.value := (p_changes ->> 'value')::integer; end if;
    if p_changes ? 'max_discount_cents' then v_row.max_discount_cents := (p_changes ->> 'max_discount_cents')::integer; end if;
    if p_changes ? 'min_order_cents' then v_row.min_order_cents := coalesce((p_changes ->> 'min_order_cents')::integer, 0); end if;
    if p_changes ? 'starts_at' then v_row.starts_at := (p_changes ->> 'starts_at')::timestamptz; end if;
    if p_changes ? 'expires_at' then v_row.expires_at := (p_changes ->> 'expires_at')::timestamptz; end if;
    if p_changes ? 'usage_limit' then v_row.usage_limit := (p_changes ->> 'usage_limit')::integer; end if;
    if p_changes ? 'per_customer_limit' then v_row.per_customer_limit := (p_changes ->> 'per_customer_limit')::integer; end if;

    v_changed := array_remove(array[
      case when v_row.code is distinct from v_old.code then 'code' end,
      case when v_row.name is distinct from v_old.name then 'name' end,
      case when v_row.discount_type is distinct from v_old.discount_type then 'discount_type' end,
      case when v_row.value is distinct from v_old.value then 'value' end,
      case when v_row.max_discount_cents is distinct from v_old.max_discount_cents then 'max_discount_cents' end,
      case when v_row.min_order_cents is distinct from v_old.min_order_cents then 'min_order_cents' end,
      case when v_row.starts_at is distinct from v_old.starts_at then 'starts_at' end,
      case when v_row.expires_at is distinct from v_old.expires_at then 'expires_at' end,
      case when v_row.usage_limit is distinct from v_old.usage_limit then 'usage_limit' end,
      case when v_row.per_customer_limit is distinct from v_old.per_customer_limit then 'per_customer_limit' end
    ], null);

    if cardinality(v_changed) > 0 then
      update public.promotions pr
         set code = v_row.code, name = v_row.name, discount_type = v_row.discount_type, value = v_row.value,
             max_discount_cents = v_row.max_discount_cents, min_order_cents = v_row.min_order_cents,
             starts_at = v_row.starts_at, expires_at = v_row.expires_at,
             usage_limit = v_row.usage_limit, per_customer_limit = v_row.per_customer_limit
       where pr.id = v_old.id
      returning * into v_row;
    end if;
  exception
    when unique_violation then
      raise exception 'That coupon code is already in use.' using errcode = 'P0001', detail = 'code_taken';
    when check_violation or not_null_violation or invalid_text_representation
         or numeric_value_out_of_range or invalid_datetime_format or datetime_field_overflow then
      raise exception 'The promotion details are not valid.' using errcode = 'P0001', detail = 'invalid_promotion';
  end;

  -- An unchanged call writes nothing and is not audited. Past orders are never touched: they hold a snapshot.
  if cardinality(v_changed) > 0 then
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'promotion_updated', v_row.id, left('changed: ' || array_to_string(v_changed, ', '), 500));
  end if;

  return jsonb_build_object('promotion', to_jsonb(v_row));
end;
$$;

create function public.admin_set_promotion_active(p_promotion_id uuid, p_is_active boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_row public.promotions;
  v_prev boolean;
begin
  perform public.require_admin();
  v_actor := auth.uid();

  if p_promotion_id is null or p_is_active is null then
    raise exception 'A promotion and a true / false value are required.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_row from public.promotions pr where pr.id = p_promotion_id for update;
  if not found then
    raise exception 'Promotion not found.' using errcode = 'P0001', detail = 'promotion_not_found';
  end if;

  if v_row.is_active is distinct from p_is_active then
    v_prev := v_row.is_active;
    update public.promotions pr set is_active = p_is_active where pr.id = v_row.id returning * into v_row;
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor,
            case when p_is_active then 'promotion_activated' else 'promotion_deactivated' end,
            v_row.id,
            format('is_active %s -> %s', v_prev::text, p_is_active::text));
  end if;

  return jsonb_build_object('promotion', to_jsonb(v_row));
end;
$$;

create function public.admin_list_promotions(p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_admin();

  if p_limit is null or p_limit < 1 or p_offset is null or p_offset < 0 then
    raise exception 'Invalid promotion list arguments.' using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select count(*) into v_total from public.promotions;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id), '[]'::jsonb) into v_rows
    from (
      select pr.*,
             (select count(*) from public.promotion_redemptions x
               where x.promotion_id = pr.id and x.released_at is null) as active_redemptions,
             (select coalesce(sum(x.amount_cents), 0) from public.promotion_redemptions x
               where x.promotion_id = pr.id and x.released_at is null) as active_discount_cents
        from public.promotions pr
       order by pr.created_at desc, pr.id
       limit least(p_limit, 100) offset p_offset
    ) r;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end;
$$;

-- 10. create_order(): the same function plus a trailing p_coupon_code ----------------------------------------
-- Same precedent as Phase 4C (p_zone_id): the 12-argument function is dropped and the 13-argument one created,
-- so there is exactly one overload and every existing caller that names its arguments keeps working (the new
-- argument defaults to NULL). The body is the 20261004170000 body with the Phase 8 edits only; each one is
-- marked "Phase 8". Nothing else in it changed.
drop function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer, uuid);

create function public.create_order(
  p_items jsonb,
  p_delivery_method text,
  p_payment_method public.payment_method,
  p_address_id uuid default null,
  p_slot_date date default null,
  p_slot_start time default null,
  p_slot_end time default null,
  -- Accepted for backwards compatibility and ignored: the stored label always
  -- comes from the matching slot template.
  p_slot_label text default null,
  p_notes text default null,
  p_idempotency_key text default null,
  p_expected_total_cents integer default null,
  -- The delivery zone. Required when the method requires an address. The caller chooses
  -- it; there is no address -> zone mapping yet (Phase 4C.2).
  p_zone_id uuid default null,
  -- Phase 8: an optional coupon CODE. The client never sends an amount; the discount is computed below.
  p_coupon_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_account_status text;  -- Phase 6E.3
  v_existing uuid;
  v_delivery record;
  v_slot record;
  v_address public.addresses%rowtype;
  v_address_snapshot jsonb := null;
  v_slot_date date := null;
  v_slot_start time := null;
  v_slot_end time := null;
  v_slot_label text := null;
  v_slot_template_id uuid := null;
  v_item record;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_unit_price integer;
  v_available integer;
  v_subtotal integer := 0;
  v_delivery_fee integer := 0;
  v_discount integer := 0;
  v_total integer;
  v_order_id uuid;
  v_item_count integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_status public.order_status;
  v_requires_address boolean;
  v_zone_id uuid := null;
  v_covering_zones uuid[] := '{}';
  v_zone_active boolean;
  v_coupon_code text;            -- Phase 8
  v_promo record;                -- Phase 8
  v_applied_at timestamptz := null;  -- Phase 8
begin
  if v_user is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
  end if;

  -- Phase 6E.3: a suspended customer cannot order. Checked BEFORE the idempotency lookup (so a
  -- replay of an earlier checkout is refused too) and before any stock is touched, so a refusal
  -- reserves nothing and writes no order row. FOR SHARE makes it serial with
  -- admin_set_customer_status() (FOR UPDATE on the same row): once a suspension has committed, no
  -- checkout can slip past it. A signed-in user with no profile row is not blocked.
  select p.status into v_account_status from public.profiles p where p.id = v_user for share;
  if v_account_status = 'suspended' then
    raise exception 'Your account is suspended, so you cannot place orders. Please contact support.'
      using errcode = 'P0001', detail = 'account_suspended';
  end if;

  -- Idempotency: replaying the same checkout returns the original order.
  -- The advisory lock makes a concurrent duplicate WAIT for the first submission to
  -- commit instead of racing it for the same stock (which could otherwise fail the
  -- duplicate with "Only 0 left" although its twin already succeeded).
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_user::text || ':' || p_idempotency_key, 0));
    select id into v_existing
    from public.orders
    where user_id = v_user and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- ---- Basket shape ---------------------------------------------------------
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your basket is empty.' using errcode = 'P0001';
  end if;

  if jsonb_array_length(p_items) > 100 then
    raise exception 'Your basket has too many lines. Remove some items and try again.'
      using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
    where x.product_id is null or x.quantity is null or x.quantity < 1 or x.quantity > 99
  ) then
    raise exception 'One of the basket items is invalid. Refresh your basket.' using errcode = 'P0001';
  end if;

  -- ---- Lines: authoritative price, availability and stock -------------------
  -- Merge duplicate lines and lock rows in a stable order (no deadlocks between
  -- concurrent checkouts that share products).
  for v_item in
    select x.product_id, x.variant_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
    group by x.product_id, x.variant_id
    order by x.product_id, x.variant_id
  loop
    if v_item.quantity > 99 then
      raise exception 'Quantities must be between 1 and 99.' using errcode = 'P0001';
    end if;

    select * into v_product from public.products where id = v_item.product_id for update;
    if not found or not v_product.is_active then
      raise exception 'A product in your basket is no longer available. Update your basket and try again.'
        using errcode = 'P0001';
    end if;

    if v_item.variant_id is not null then
      select * into v_variant
      from public.product_variants
      where id = v_item.variant_id and product_id = v_product.id
      for update;
      if not found or not v_variant.is_active then
        raise exception 'A product option in your basket is no longer available: %', v_product.name
          using errcode = 'P0001';
      end if;
      v_unit_price := v_variant.price_cents;
      v_available := v_variant.stock_quantity;
    else
      v_variant := null;
      v_unit_price := v_product.price_cents;
      v_available := v_product.stock_quantity;
      if not v_product.in_stock then
        raise exception 'Out of stock: %. Remove it from your basket to continue.', v_product.name
          using errcode = 'P0001';
      end if;
    end if;

    if v_available < v_item.quantity then
      raise exception 'Only % left of %. Reduce the quantity and try again.', greatest(v_available, 0), v_product.name
        using errcode = 'P0001';
    end if;

    -- Reserve the stock now. The row is locked, so no concurrent checkout can
    -- read the old quantity; the whole function rolls back if anything below fails.
    if v_item.variant_id is not null then
      update public.product_variants
        set stock_quantity = stock_quantity - v_item.quantity
        where id = v_variant.id;
    else
      update public.products
        set stock_quantity = stock_quantity - v_item.quantity
        where id = v_product.id;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id,
      'variant_id', v_item.variant_id,
      'product_name', v_product.name,
      'product_slug', v_product.slug,
      'sku', coalesce(v_variant.sku, v_product.sku),
      'variant_name', v_variant.name,
      'variant_attributes', v_variant.attributes,
      'unit_label', v_product.unit_label,
      'image_url', v_product.image_url,
      'unit_price_cents', v_unit_price,
      'quantity', v_item.quantity,
      'line_total_cents', v_unit_price * v_item.quantity
    );

    v_subtotal := v_subtotal + (v_unit_price * v_item.quantity);
    v_item_count := v_item_count + 1;
  end loop;

  if v_item_count = 0 then
    raise exception 'Your basket is empty.' using errcode = 'P0001';
  end if;

  -- ---- Delivery method, address and zone (Phase 4B.1, hardened in Phase 5B.2) ----
  -- For address delivery the customer's own address is loaded FIRST, and the delivery zone is
  -- derived from / validated against it. The client can no longer simply pick the cheapest
  -- zone: a zone that does not cover the address is rejected. For methods without an address
  -- any p_zone_id is ignored.
  select m.requires_address into v_requires_address
  from public.delivery_methods m
  where m.code = p_delivery_method and m.is_active;
  -- Not found (unknown / inactive method): v_requires_address stays NULL and the call to
  -- validate_delivery_selection() below rejects it with the proper error code.

  if v_requires_address is true then
    if p_address_id is null then
      raise exception 'Choose a delivery address.' using errcode = 'P0001';
    end if;
    select * into v_address
    from public.addresses
    where id = p_address_id and user_id = v_user;
    if not found then
      raise exception 'That delivery address could not be found.' using errcode = 'P0001';
    end if;
    v_address_snapshot := jsonb_build_object(
      'full_name', v_address.full_name,
      'phone', v_address.phone,
      'label', v_address.label,
      'address_line_1', v_address.address_line_1,
      'address_line_2', v_address.address_line_2,
      'city', v_address.city,
      'county', v_address.county,
      'postal_code', v_address.postal_code,
      'delivery_instructions', v_address.delivery_instructions
    );

    select coalesce(array_agg(z.id order by z.position, z.id), '{}')
      into v_covering_zones
    from public.delivery_zones z
    where z.is_active
      and public.delivery_zone_covers_address(z.id, v_address.county, v_address.city);

    if p_zone_id is not null then
      -- Existence / activity of this zone is checked by validate_delivery_selection() below;
      -- whether it matches the address is checked right after it.
      v_zone_id := p_zone_id;
    elsif cardinality(v_covering_zones) = 1 then
      v_zone_id := v_covering_zones[1];
    elsif cardinality(v_covering_zones) = 0 then
      raise exception 'We do not deliver to that address yet. Choose another address or collect in store.'
        using errcode = 'P0001', detail = 'zone_unserviceable';
    else
      raise exception 'Choose the delivery area that covers your address.'
        using errcode = 'P0001', detail = 'zone_required';
    end if;
  end if;

  -- v_subtotal was computed above from locked, authoritative prices. The fee and the
  -- minimum order come ONLY from this call (-> resolve_delivery_fee()), using the zone
  -- validated above (NULL for methods without an address).
  select * into v_delivery
  from public.validate_delivery_selection(p_delivery_method, v_zone_id, v_subtotal);

  if not found or v_delivery.is_valid is not true then
    raise exception '%', coalesce(v_delivery.error_message, 'That delivery option is not available.')
      using errcode = 'P0001', detail = coalesce(v_delivery.error_code, 'unavailable');
  end if;

  -- A "valid" row without a fee must never be read as free delivery.
  if v_delivery.fee_cents is null or v_delivery.fee_cents < 0 or v_delivery.fee_rule is null then
    raise exception 'That delivery option is not available right now.'
      using errcode = 'P0001', detail = 'unavailable';
  end if;

  -- The method's address requirement must still be what was read above.
  if v_delivery.requires_address is distinct from coalesce(v_requires_address, false) then
    raise exception 'That delivery option is not available right now.'
      using errcode = 'P0001', detail = 'unavailable';
  end if;

  -- The zone must cover the address (a zone from the client, or one derived above).
  if v_delivery.requires_address and not (v_delivery.zone_id = any (v_covering_zones)) then
    raise exception 'That delivery area does not match your delivery address.'
      using errcode = 'P0001', detail = 'zone_address_mismatch';
  end if;

  -- A zone sent with a method that has no address is never used for pricing or stored, but a
  -- zone that does not exist or is inactive is still rejected, as before.
  if not v_delivery.requires_address and p_zone_id is not null then
    select z.is_active into v_zone_active from public.delivery_zones z where z.id = p_zone_id;
    if not found then
      raise exception 'That delivery area does not exist.'
        using errcode = 'P0001', detail = 'zone_unknown';
    elsif not v_zone_active then
      raise exception 'We do not currently deliver to that area.'
        using errcode = 'P0001', detail = 'zone_inactive';
    end if;
  end if;

  v_delivery_fee := v_delivery.fee_cents;

  -- ---- Delivery slot: lock, THEN validate, in THIS transaction (Phase 4B.2) -
  -- lock_delivery_slot() takes the transaction-scoped advisory lock for this exact
  -- date/start/end and re-counts usage after the lock is granted, so the capacity decision
  -- is made on the row returned here, never on an earlier preview. The lock is released at
  -- COMMIT or ROLLBACK, i.e. when the order below is visible to the next checkout (or
  -- never created). A method that does not require a slot skips this entirely.
  if v_delivery.requires_slot then
    select * into v_slot
    from public.lock_delivery_slot(p_slot_date, p_slot_start, p_slot_end);

    if not found or v_slot.is_valid is not true then
      raise exception '%', coalesce(v_slot.error_message, 'That delivery slot is not available. Pick another slot.')
        using errcode = 'P0001', detail = coalesce(v_slot.error_code, 'slot_unknown');
    end if;

    v_slot_date := v_slot.slot_date;
    v_slot_start := v_slot.slot_start;
    v_slot_end := v_slot.slot_end;
    v_slot_label := v_slot.label;
    v_slot_template_id := v_slot.template_id;
  end if;

  -- ---- Discount (Phase 8) ------------------------------------------------------------------
  -- Server-side only. The client may send a coupon CODE and nothing else about discounts. The amount
  -- comes from resolve_promotion() over the locked subtotal above; delivery is not discountable
  -- (coupon_eligible_base_cents). With p_lock = true the limited promotion row(s) are locked FOR UPDATE
  -- until COMMIT and the limits are counted afterwards, so concurrent orders cannot exceed them.
  -- A supplied code that does not apply fails the order (nothing is silently dropped); with no code the
  -- best valid automatic promotion, if any, applies.
  v_coupon_code := nullif(btrim(coalesce(p_coupon_code, '')), '');
  select * into v_promo
    from public.resolve_promotion(v_coupon_code, v_user, v_subtotal, v_delivery_fee, true, now());

  if v_coupon_code is not null and v_promo.error_code is not null then
    raise exception 'That coupon cannot be applied.'
      using errcode = 'P0001', detail = 'coupon_' || v_promo.error_code;
  end if;

  if v_promo.promotion_id is not null and v_promo.discount_cents > 0 then
    v_discount := least(greatest(v_promo.discount_cents, 0), v_subtotal);   -- belt and braces: never above the subtotal
    v_applied_at := now();
  else
    v_discount := 0;
  end if;

  v_total := v_subtotal + v_delivery_fee - v_discount;

  -- The client's expected total can only veto an order, never change an amount.
  if p_expected_total_cents is not null and p_expected_total_cents <> v_total then
    raise exception 'Prices or delivery fees have changed since you last looked. Review your total and try again.'
      using errcode = 'P0001';
  end if;

  -- Payment is never confirmed here. Cash on delivery still owes money, so it
  -- starts pending too; it simply does not wait on a gateway.
  v_status := (
    case when p_payment_method = 'cash_on_delivery' then 'pending' else 'awaiting_payment' end
  )::public.order_status;

  insert into public.orders (
    user_id, order_number, status, payment_status, payment_method,
    subtotal_cents, delivery_fee_cents, discount_cents, total_cents,
    delivery_method, delivery_address, delivery_address_id,
    delivery_slot_date, delivery_slot_start, delivery_slot_end, delivery_slot_label,
    delivery_zone_id, delivery_zone_code, delivery_zone_name, delivery_method_label,
    delivery_slot_template_id, delivery_fee_rule,
    discount_promotion_id, discount_code, discount_name, discount_type, discount_value, discount_applied_at,
    customer_notes, idempotency_key
  ) values (
    v_user, public.next_order_number(), v_status, 'pending', p_payment_method,
    v_subtotal, v_delivery_fee, v_discount, v_total,
    v_delivery.method_code, v_address_snapshot,
    case when v_delivery.requires_address then p_address_id else null end,
    v_slot_date, v_slot_start, v_slot_end, v_slot_label,
    v_delivery.zone_id, v_delivery.zone_code, v_delivery.zone_name, v_delivery.method_label,
    v_slot_template_id, v_delivery.fee_rule,
    case when v_discount > 0 then v_promo.promotion_id end,
    case when v_discount > 0 then v_promo.promo_code end,
    case when v_discount > 0 then v_promo.promo_name end,
    case when v_discount > 0 then v_promo.promo_type end,
    case when v_discount > 0 then v_promo.promo_value end,
    case when v_discount > 0 then v_applied_at end,
    nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_idempotency_key, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, product_slug, sku,
    variant_name, variant_attributes, unit_label, image_url,
    unit_price_cents, quantity, line_total_cents
  )
  select
    v_order_id, l.product_id, l.variant_id, l.product_name, l.product_slug, l.sku,
    l.variant_name, l.variant_attributes, l.unit_label, l.image_url,
    l.unit_price_cents, l.quantity, l.line_total_cents
  from jsonb_to_recordset(v_lines) as l(
    product_id uuid,
    variant_id uuid,
    product_name text,
    product_slug text,
    sku text,
    variant_name text,
    variant_attributes jsonb,
    unit_label text,
    image_url text,
    unit_price_cents integer,
    quantity integer,
    line_total_cents integer
  );

  -- Phase 8: the redemption, in the SAME transaction as the order (UNIQUE (order_id): one per order).
  if v_discount > 0 then
    insert into public.promotion_redemptions (promotion_id, order_id, user_id, amount_cents)
    values (v_promo.promotion_id, v_order_id, v_user, v_discount);
  end if;

  return v_order_id;
exception
  when unique_violation then
    -- Two concurrent submissions of the same checkout: the losing transaction's
    -- stock changes are rolled back with it; return the winner's order.
    if p_idempotency_key is not null then
      select id into v_existing
      from public.orders
      where user_id = v_user and idempotency_key = p_idempotency_key;
      if v_existing is not null then
        return v_existing;
      end if;
    end if;
    raise;
end;
$$;


-- 11. Privileges ------------------------------------------------------------------------------------------------
-- Supabase's default privileges hand EXECUTE on new functions to anon / authenticated / service_role, so every
-- revoke names them. (create_order keeps service_role's default access, exactly as Phase 5B.2 left it.)
revoke all on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer, uuid, text)
  from public, anon, authenticated;
grant execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer, uuid, text)
  to authenticated;

-- Internal: no API role can call these; only the SECURITY DEFINER functions above (same owner) do.
revoke all on function public.coupon_eligible_base_cents(integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.compute_promotion_discount(text, integer, integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.promotion_evaluate(public.promotions, uuid, integer, integer, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.resolve_promotion(text, uuid, integer, integer, boolean, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.orders_guard_discount_snapshot() from public, anon, authenticated, service_role;
revoke all on function public.promotion_redemptions_guard() from public, anon, authenticated, service_role;
revoke all on function public.orders_sync_promotion_redemption() from public, anon, authenticated, service_role;

-- Signed-in customers: preview only.
revoke all on function public.validate_coupon(jsonb, text) from public, anon, service_role;
grant execute on function public.validate_coupon(jsonb, text) to authenticated;

-- Admin (require_admin() inside every one).
revoke all on function public.admin_create_promotion(jsonb) from public, anon, service_role;
grant execute on function public.admin_create_promotion(jsonb) to authenticated;
revoke all on function public.admin_update_promotion(uuid, jsonb) from public, anon, service_role;
grant execute on function public.admin_update_promotion(uuid, jsonb) to authenticated;
revoke all on function public.admin_set_promotion_active(uuid, boolean) from public, anon, service_role;
grant execute on function public.admin_set_promotion_active(uuid, boolean) to authenticated;
revoke all on function public.admin_list_promotions(integer, integer) from public, anon, service_role;
grant execute on function public.admin_list_promotions(integer, integer) to authenticated;

-- 12. Self-check (aborts the whole transaction if anything is off) ------------------------------------------------
do $chk$
declare
  v_role text;
  v_tbl regclass;
  v_fn regprocedure;
  v_co constant regprocedure :=
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid,text)'::regprocedure;
  v_src text;
begin
  -- Tables: RLS on, no policy, no privilege for any API role, nothing for PUBLIC.
  foreach v_tbl in array array['public.promotions'::regclass, 'public.promotion_redemptions'::regclass] loop
    if not (select c.relrowsecurity from pg_class c where c.oid = v_tbl) then
      raise exception 'Phase 8 self-check failed: RLS is not enabled on %.', v_tbl;
    end if;
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
      if has_any_column_privilege(v_role, v_tbl, 'SELECT, INSERT, UPDATE, REFERENCES')
         or has_table_privilege(v_role, v_tbl, 'DELETE, TRUNCATE, TRIGGER') then
        raise exception 'Phase 8 self-check failed: % still holds a privilege on %.', v_role, v_tbl;
      end if;
    end loop;
    if exists (select 1 from pg_class c, aclexplode(c.relacl) a where c.oid = v_tbl and a.grantee = 0) then
      raise exception 'Phase 8 self-check failed: PUBLIC holds a privilege on %.', v_tbl;
    end if;
    if exists (select 1 from pg_policy p where p.polrelid = v_tbl) then
      raise exception 'Phase 8 self-check failed: % must have no RLS policy.', v_tbl;
    end if;
  end loop;

  -- orders: snapshot columns, constraints, triggers.
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'orders'
         and column_name in ('discount_promotion_id', 'discount_code', 'discount_name', 'discount_type',
                             'discount_value', 'discount_applied_at')) <> 6 then
    raise exception 'Phase 8 self-check failed: orders is missing a discount snapshot column.';
  end if;
  if (select count(*) from pg_constraint k
       where k.conrelid = 'public.orders'::regclass and k.convalidated
         and k.conname in ('orders_discount_within_subtotal', 'orders_discount_snapshot_consistent')) <> 2 then
    raise exception 'Phase 8 self-check failed: orders discount constraints are missing or not validated.';
  end if;
  if (select count(*) from pg_trigger t
       where not t.tgisinternal
         and t.tgname in ('orders_guard_discount_snapshot', 'orders_sync_promotion_redemption',
                          'promotion_redemptions_guard', 'promotions_set_updated_at')) <> 4 then
    raise exception 'Phase 8 self-check failed: expected 4 Phase 8 triggers.';
  end if;
  if (select count(*) from pg_constraint k
       where k.conrelid = 'public.promotion_redemptions'::regclass and k.contype = 'u'
         and k.conname = 'promotion_redemptions_order_id_key') <> 1 then
    raise exception 'Phase 8 self-check failed: UNIQUE (order_id) on promotion_redemptions is missing.';
  end if;

  -- Internal functions: no API role, no PUBLIC.
  foreach v_fn in array array[
    'public.coupon_eligible_base_cents(integer,integer)'::regprocedure,
    'public.compute_promotion_discount(text,integer,integer,integer)'::regprocedure,
    'public.promotion_evaluate(public.promotions,uuid,integer,integer,timestamptz)'::regprocedure,
    'public.resolve_promotion(text,uuid,integer,integer,boolean,timestamptz)'::regprocedure,
    'public.orders_guard_discount_snapshot()'::regprocedure,
    'public.promotion_redemptions_guard()'::regprocedure,
    'public.orders_sync_promotion_redemption()'::regprocedure] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or has_function_privilege('service_role', v_fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 8 self-check failed: % must not be executable by any API role.', v_fn;
    end if;
  end loop;

  -- Customer + admin functions: authenticated only (not anon, not service_role, not PUBLIC).
  foreach v_fn in array array[
    'public.validate_coupon(jsonb,text)'::regprocedure,
    'public.admin_create_promotion(jsonb)'::regprocedure,
    'public.admin_update_promotion(uuid,jsonb)'::regprocedure,
    'public.admin_set_promotion_active(uuid,boolean)'::regprocedure,
    'public.admin_list_promotions(integer,integer)'::regprocedure] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('service_role', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_fn and a.grantee = 0) then
      raise exception 'Phase 8 self-check failed: % must be executable by authenticated only.', v_fn;
    end if;
  end loop;

  -- create_order(): one overload, authenticated, not anon, not PUBLIC.
  if (select count(*) from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception 'Phase 8 self-check failed: create_order() overload count is not 1.';
  end if;
  if has_function_privilege('anon', v_co, 'EXECUTE') or not has_function_privilege('authenticated', v_co, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_co and a.grantee = 0) then
    raise exception 'Phase 8 self-check failed: create_order() privileges are wrong (authenticated, not anon, not PUBLIC).';
  end if;

  -- Every Phase 8 function is SECURITY DEFINER with a pinned search_path.
  foreach v_fn in array array[
    v_co,
    'public.coupon_eligible_base_cents(integer,integer)'::regprocedure,
    'public.compute_promotion_discount(text,integer,integer,integer)'::regprocedure,
    'public.promotion_evaluate(public.promotions,uuid,integer,integer,timestamptz)'::regprocedure,
    'public.resolve_promotion(text,uuid,integer,integer,boolean,timestamptz)'::regprocedure,
    'public.orders_guard_discount_snapshot()'::regprocedure,
    'public.promotion_redemptions_guard()'::regprocedure,
    'public.orders_sync_promotion_redemption()'::regprocedure,
    'public.validate_coupon(jsonb,text)'::regprocedure,
    'public.admin_create_promotion(jsonb)'::regprocedure,
    'public.admin_update_promotion(uuid,jsonb)'::regprocedure,
    'public.admin_set_promotion_active(uuid,boolean)'::regprocedure,
    'public.admin_list_promotions(integer,integer)'::regprocedure] loop
    if not exists (select 1 from pg_proc p
                   where p.oid = v_fn and p.prosecdef
                     and exists (select 1 from unnest(p.proconfig) c where c = 'search_path=public, pg_temp')) then
      raise exception 'Phase 8 self-check failed: % is not SECURITY DEFINER with search_path = public, pg_temp.', v_fn;
    end if;
  end loop;

  -- Admin functions gate on require_admin() first.
  foreach v_fn in array array[
    'public.admin_create_promotion(jsonb)'::regprocedure,
    'public.admin_update_promotion(uuid,jsonb)'::regprocedure,
    'public.admin_set_promotion_active(uuid,boolean)'::regprocedure,
    'public.admin_list_promotions(integer,integer)'::regprocedure] loop
    if (select p.prosrc from pg_proc p where p.oid = v_fn) not like '%perform public.require_admin()%' then
      raise exception 'Phase 8 self-check failed: % does not call require_admin().', v_fn;
    end if;
  end loop;

  -- create_order(): earlier guarantees intact AND the Phase 8 wiring present, in the right order.
  select p.prosrc into v_src from pg_proc p where p.oid = v_co;
  if strpos(v_src, 'account_suspended') = 0
     or strpos(v_src, 'account_suspended') > strpos(v_src, 'pg_advisory_xact_lock')
     or strpos(v_src, 'zone_address_mismatch') = 0
     or strpos(v_src, 'when unique_violation') = 0
     or strpos(v_src, 'lock_delivery_slot') = 0
     or strpos(v_src, 'public.resolve_promotion(v_coupon_code, v_user, v_subtotal, v_delivery_fee, true, now())') = 0
     or strpos(v_src, 'insert into public.promotion_redemptions') = 0
     or strpos(v_src, 'lock_delivery_slot') > strpos(v_src, 'public.resolve_promotion(')
     or strpos(v_src, 'public.resolve_promotion(') > strpos(v_src, 'insert into public.orders')
     or strpos(v_src, 'insert into public.orders') > strpos(v_src, 'insert into public.promotion_redemptions')
     or strpos(v_src, 'p_discount') <> 0 then
    raise exception 'Phase 8 self-check failed: create_order() body is not as expected.';
  end if;
  -- No argument can carry an amount.
  if exists (select 1 from unnest((select p.proargnames from pg_proc p where p.oid = v_co)) n
              where n ilike '%discount%' or n ilike '%fee%' or n ilike '%subtotal%') then
    raise exception 'Phase 8 self-check failed: create_order() has an argument that could carry an amount.';
  end if;
  -- The preview takes no lock (it must not serialise browsing); the binding path does.
  if (select p.prosrc from pg_proc p where p.oid = 'public.validate_coupon(jsonb,text)'::regprocedure) ilike '%for update%'
     or (select p.prosrc from pg_proc p
          where p.oid = 'public.resolve_promotion(text,uuid,integer,integer,boolean,timestamptz)'::regprocedure)
        not ilike '%for update%' then
    raise exception 'Phase 8 self-check failed: locking is not where it must be.';
  end if;

  -- The pure rules compute what the header says they do.
  if public.compute_promotion_discount('percentage', 1000, null, 10000) <> 1000
     or public.compute_promotion_discount('percentage', 3333, null, 100) <> 33
     or public.compute_promotion_discount('percentage', 5000, 1500, 10000) <> 1500
     or public.compute_promotion_discount('percentage', 10000, null, 777) <> 777
     or public.compute_promotion_discount('fixed', 50000, null, 10000) <> 10000
     or public.compute_promotion_discount('fixed', 300, null, 10000) <> 300
     or public.compute_promotion_discount('fixed', 300, null, 0) <> 0
     or public.coupon_eligible_base_cents(10000, 5000) <> 10000 then
    raise exception 'Phase 8 self-check failed: the discount rules do not compute as documented.';
  end if;
end
$chk$;

commit;
