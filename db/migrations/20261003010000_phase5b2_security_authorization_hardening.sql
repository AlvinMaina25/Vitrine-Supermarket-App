-- =============================================================================
-- PHASE 5B.2 - Security authorization hardening.
--
-- STATUS: written, NOT yet executed against the Phase-5 development database.
--
-- Apply ONCE, after 20260930080000_fix_validate_delivery_selection_record.sql and after
-- Phase 5A.2. Do not edit or re-run any older migration. The whole file is one transaction:
-- if any statement or the final self-check fails, nothing is applied. Section 0 refuses to
-- run a second time (it looks for the orders.restocked_at column this migration adds).
--
-- WHAT THIS FIXES (Phase 5B.1 findings)
--   V1  Staff could set orders.status to ANY value, including 'paid' and 'refunded'.
--   V2  Staff could inflate stock by cycling cancelled -> pending -> cancelled.
--   V3  Staff and admin were equivalent for price/availability configuration.
--   V4  A customer could pick any delivery zone, unrelated to the delivery address.
--   V5  has_role()/is_staff() were executable by anon and could probe any user's role.
--   V6  validate_cart()/validate_delivery_selection() returned inactive products,
--       variants, delivery methods and zones when given their identifiers.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No payment provider, webhook, payments table or payment_status writer. 'paid' and
--     'refunded' are not settable by customers, staff OR admin from the browser. Payment
--     state stays a future, server-only (service_role) responsibility.
--   * No change to products, categories, profiles, addresses or old migration files.
--   * No new broad grants. Every EXECUTE grant below is explicit and minimal.
--
-- ROLE MODEL (public.user_roles, public.app_role)
--   customer : any signed-in user. Own data only. Places orders through create_order().
--   staff    : fulfilment. Reads all orders/items/history/config. Moves an order along the
--              fulfilment workflow, or cancels it, through set_order_status(). Nothing else.
--   admin    : everything staff can do, PLUS: write delivery methods, zones, zone fees, slot
--              templates and slot overrides (anything that changes prices or availability),
--              and the documented manual status override in set_order_status().
--   is_staff() is true for staff AND admin. is_admin() is true for admin only.
--
-- ORDER STATUS (set_order_status) - see section 4
--   Standard transitions (staff or admin):
--     pending          -> processing | cancelled
--     awaiting_payment -> cancelled                (cannot be fulfilled until payment is confirmed)
--     paid             -> processing | cancelled   (only reachable by a future server process)
--     processing       -> picking | cancelled
--     picking          -> packed | cancelled
--     packed           -> dispatched | cancelled
--     dispatched       -> out_for_delivery | delivered | cancelled
--     out_for_delivery -> delivered | cancelled
--     delivered / cancelled / refunded -> (none)
--   Manual administrative override (admin only, reason of at least 3 characters required,
--   recorded in order_status_history as "Admin override: <reason>"):
--     any status except 'refunded' -> any status except 'paid' / 'refunded'.
--     This is a manual correction tool. It is NOT payment verification.
--   Payment gate (applies to everyone, including admin): an order paid by M-Pesa or card whose
--   payment_status is not 'paid' can only be awaiting_payment or cancelled. Cash on delivery
--   orders use pending and never awaiting_payment.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS - fail early, and fail clearly, if the database is not in the state
--    this migration was written against. Nothing has been changed yet when these run.
-- =============================================================================
do $pre$
declare
  v_def text;
  v_count integer;
  v_sig text;
begin
  if to_regclass('public.orders') is null
     or to_regclass('public.user_roles') is null
     or to_regclass('public.delivery_zones') is null
     or to_regclass('public.delivery_methods') is null
     or to_regclass('public.addresses') is null then
    raise exception 'Phase 5B.2 precondition failed: expected tables are missing. Apply migrations through 20260930080000 first.';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'restocked_at'
  ) then
    raise exception 'Phase 5B.2 appears to be applied already (orders.restocked_at exists). Not running it twice.';
  end if;

  -- create_order must be the single 12-argument version from 20260930060000.
  select count(*) into v_count
  from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace;
  if v_count <> 1 then
    raise exception 'Phase 5B.2 precondition failed: expected exactly one create_order() overload, found %.', v_count;
  end if;

  if to_regprocedure(
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)'
  ) is null then
    raise exception 'Phase 5B.2 precondition failed: create_order() does not have the 12-argument signature.';
  end if;

  select pg_get_functiondef(
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)'::regprocedure
  ) into v_def;
  if v_def not like '%validate_delivery_selection%' or v_def not like '%lock_delivery_slot%' then
    raise exception 'Phase 5B.2 precondition failed: create_order() in this database differs from migration 20260930060000. This migration replaces it, so compare the two before continuing.';
  end if;

  foreach v_sig in array array[
    'public.has_role(uuid,public.app_role)',
    'public.is_staff(uuid)',
    'public.restock_cancelled_order()',
    'public.log_order_status_change()',
    'public.guard_order_reactivation_capacity()',
    'public.validate_cart(jsonb)',
    'public.validate_delivery_selection(text,uuid,integer)',
    'public.resolve_delivery_fee(text,uuid,integer)',
    'public.delivery_slot_booked_count(date,time,time)',
    'public.delivery_slot_effective_capacity(uuid,date)',
    'public.delivery_slot_evaluate(date,time,time)',
    'public.delivery_slot_acquire_lock(date,time,time)',
    'public.lock_delivery_slot(date,time,time)',
    'public.validate_delivery_slot(date,time,time)',
    'public.get_delivery_slot_availability(date,date)',
    'public.next_order_number()',
    'public.order_status_holds_delivery_slot(public.order_status)',
    'public.handle_new_user()',
    'public.handle_user_email_change()',
    'public.set_updated_at()',
    'public.addresses_single_default()'
  ] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 5B.2 precondition failed: function % does not exist.', v_sig;
    end if;
  end loop;
end
$pre$;

-- =============================================================================
-- 1. ORDERS.RESTOCKED_AT  (V2 - idempotent restocking)
--
-- The moment an order's stock was returned to inventory. NULL = this order currently holds
-- its stock reservation. The restock trigger (section 5) restocks only while it is NULL and
-- sets it in the same row update, so a cancellation can restore stock at most once, and a
-- reactivation (which re-reserves stock) clears it. Browser roles have no UPDATE on orders
-- (section 4), so only the trigger, the service role or the SQL editor can write it.
-- =============================================================================
alter table public.orders add column restocked_at timestamptz;

comment on column public.orders.restocked_at is
  'When this order''s reserved stock was returned to inventory (NULL = stock currently reserved). Written only by restock_cancelled_order().';

-- Backfill: orders that are cancelled/refunded NOW and whose history shows a cancellation out of
-- a stock-holding state were restocked by the old trigger. Mark them, so the new trigger will
-- not restock them again (and will re-reserve stock if an admin ever reactivates them).
-- updated_at is left alone, as migration 20260930030000 does for its backfill.
alter table public.orders disable trigger orders_set_updated_at;

update public.orders o
set restocked_at = h.cancelled_at
from (
  select order_id, max(created_at) as cancelled_at
  from public.order_status_history
  where new_status = 'cancelled'
    and previous_status is not null
    and previous_status not in ('cancelled', 'refunded', 'delivered')
  group by order_id
) h
where h.order_id = o.id
  and o.status in ('cancelled', 'refunded')
  and o.restocked_at is null;

alter table public.orders enable trigger orders_set_updated_at;

-- =============================================================================
-- 2. ROLE HELPERS  (V3, V5)
--
-- RLS policies call these with auth.uid(), and a policy expression is evaluated with the
-- CALLER's privileges, so `authenticated` must keep EXECUTE. What changes:
--   * anon/PUBLIC lose EXECUTE (section 9 states the whole privilege matrix).
--   * They only answer about the CALLER (or any user for service_role). Asking about someone
--     else returns false, so a signed-in user can no longer probe another user's role.
--   * is_admin() is new.
-- NOTE: from the SQL editor (no JWT) these now return false for an explicit user id. To check a
-- role there, query public.user_roles directly.
-- =============================================================================
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
           _user_id is not null
           and (_user_id = auth.uid() or coalesce(auth.role(), '') = 'service_role')
           and exists (
             select 1 from public.user_roles ur
             where ur.user_id = _user_id and ur.role = _role
           ),
           false);
$$;

create or replace function public.is_staff(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
           _user_id is not null
           and (_user_id = auth.uid() or coalesce(auth.role(), '') = 'service_role')
           and exists (
             select 1 from public.user_roles ur
             where ur.user_id = _user_id and ur.role in ('staff', 'admin')
           ),
           false);
$$;

create or replace function public.is_admin(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
           _user_id is not null
           and (_user_id = auth.uid() or coalesce(auth.role(), '') = 'service_role')
           and exists (
             select 1 from public.user_roles ur
             where ur.user_id = _user_id and ur.role = 'admin'
           ),
           false);
$$;

-- =============================================================================
-- 3. CONFIGURATION WRITES REQUIRE ADMIN  (V3)
--
-- Every write policy on these five tables is replaced by an admin-only INSERT and UPDATE
-- policy. Staff keep their existing "staff read all" SELECT policies (they need to see
-- inactive configuration to fulfil orders). Nobody but the service role can DELETE.
-- Column grants from migration 030000 are unchanged: RLS is what narrows them to admins.
-- Why these tables: they set delivery fees, minimum orders, free-delivery thresholds, which
-- areas are served and how many deliveries a slot takes, i.e. they change prices/availability.
-- The app has no staff-only configuration screen today (src/features/delivery/admin.ts has no
-- route), so no legitimate staff workflow is removed.
-- =============================================================================
do $cfg$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'delivery_methods', 'delivery_zones', 'delivery_zone_fees',
        'delivery_slot_templates', 'delivery_slot_overrides'
      )
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end
$cfg$;

create policy "Delivery methods: admin insert"
  on public.delivery_methods for insert to authenticated
  with check (public.is_admin(auth.uid()));
create policy "Delivery methods: admin update"
  on public.delivery_methods for update to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "Delivery zones: admin insert"
  on public.delivery_zones for insert to authenticated
  with check (public.is_admin(auth.uid()));
create policy "Delivery zones: admin update"
  on public.delivery_zones for update to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "Delivery zone fees: admin insert"
  on public.delivery_zone_fees for insert to authenticated
  with check (public.is_admin(auth.uid()));
create policy "Delivery zone fees: admin update"
  on public.delivery_zone_fees for update to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "Delivery slots: admin insert"
  on public.delivery_slot_templates for insert to authenticated
  with check (public.is_admin(auth.uid()));
create policy "Delivery slots: admin update"
  on public.delivery_slot_templates for update to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy "Slot overrides: admin insert"
  on public.delivery_slot_overrides for insert to authenticated
  with check (public.is_admin(auth.uid()));
create policy "Slot overrides: admin update"
  on public.delivery_slot_overrides for update to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- =============================================================================
-- 4. ORDER STATUS: ONE CONTROLLED PATH  (V1)
--
-- Before: `grant update (status)` + policy "Orders: staff update" let any staff session set
-- status to any enum value. After: browser roles have NO UPDATE on orders at all (table or
-- column), the update policies are gone, and the only way to change a status from the
-- browser is public.set_order_status(), which enforces the rules documented at the top.
-- The BEFORE/AFTER triggers (reactivation capacity guard, restock, history log, updated_at)
-- still fire for that UPDATE, and for any service_role / SQL editor update.
-- =============================================================================
do $ord$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'orders' and cmd in ('UPDATE', 'ALL')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end
$ord$;

revoke update on public.orders from authenticated, anon;
revoke update (status, restocked_at) on public.orders from authenticated, anon;

-- History log: identical to migration 010000 except (a) the note now carries the reason
-- passed to set_order_status() (read from a transaction-local setting that only that
-- function sets), and (b) search_path ends with pg_temp.
create or replace function public.log_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_status_history
      (order_id, previous_status, new_status, payment_status, changed_by, note)
    values (new.id, null, new.status, new.payment_status, new.user_id, 'Order placed');
    return new;
  end if;

  if new.status is distinct from old.status
     or new.payment_status is distinct from old.payment_status then
    insert into public.order_status_history
      (order_id, previous_status, new_status, payment_status, changed_by, note)
    values (
      new.id,
      old.status,
      new.status,
      new.payment_status,
      auth.uid(),
      case
        when new.status is distinct from old.status
          then nullif(current_setting('app.order_status_note', true), '')
        else 'Payment status updated to ' || new.payment_status::text
      end
    );
  end if;

  return new;
end;
$$;

create or replace function public.set_order_status(
  p_order_id uuid,
  p_new_status public.order_status,
  p_note text default null
)
returns public.order_status
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_is_admin boolean;
  v_order public.orders%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_standard boolean;
  v_override boolean := false;
  c_fulfilment constant public.order_status[] := array[
    'processing', 'picking', 'packed', 'dispatched', 'out_for_delivery', 'delivered'
  ]::public.order_status[];
begin
  -- Authorisation: database-side, from the caller's own JWT. Customers stop here.
  if v_user is null or not public.is_staff(v_user) then
    raise exception 'You are not allowed to change order status.'
      using errcode = '42501', detail = 'not_authorised';
  end if;
  v_is_admin := public.is_admin(v_user);

  if p_order_id is null or p_new_status is null then
    raise exception 'An order and a new status are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- 'paid' and 'refunded' are payment outcomes. No verified payment source exists yet, so no
  -- browser role (staff or admin) may set them. A future webhook will use the service role.
  if p_new_status in ('paid', 'refunded') then
    raise exception 'Orders cannot be marked paid or refunded here. Payment state is set only by verified payment events, which are not implemented yet.'
      using errcode = 'P0001', detail = 'payment_state_reserved';
  end if;

  if v_note is not null and char_length(v_note) > 400 then
    raise exception 'The note is too long (400 characters at most).'
      using errcode = 'P0001', detail = 'note_too_long';
  end if;

  -- Lock the row: concurrent changes to one order are serialised, and the triggers below
  -- (restock, capacity guard) see the committed result of the previous change.
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'That order could not be found.'
      using errcode = 'P0001', detail = 'order_not_found';
  end if;

  if v_order.status = p_new_status then
    return v_order.status;
  end if;

  v_standard := case v_order.status
    when 'pending'          then p_new_status in ('processing', 'cancelled')
    when 'awaiting_payment' then p_new_status = 'cancelled'
    when 'paid'             then p_new_status in ('processing', 'cancelled')
    when 'processing'       then p_new_status in ('picking', 'cancelled')
    when 'picking'          then p_new_status in ('packed', 'cancelled')
    when 'packed'           then p_new_status in ('dispatched', 'cancelled')
    when 'dispatched'       then p_new_status in ('out_for_delivery', 'delivered', 'cancelled')
    when 'out_for_delivery' then p_new_status in ('delivered', 'cancelled')
    else false
  end;

  if not v_standard then
    -- Manual administrative override. Admin only, reason required, never paid/refunded
    -- (rejected above) and never out of 'refunded'.
    if not v_is_admin or v_order.status = 'refunded' then
      raise exception 'That status change is not allowed.'
        using errcode = 'P0001', detail = 'transition_not_allowed';
    end if;
    if v_note is null or char_length(v_note) < 3 then
      raise exception 'A reason is required for an administrative override.'
        using errcode = 'P0001', detail = 'admin_note_required';
    end if;
    v_override := true;
  end if;

  -- Payment gate (everyone, admin included): an online-payment order that is not confirmed
  -- paid cannot enter fulfilment, and the pending/awaiting_payment labels follow the method.
  if p_new_status = any (c_fulfilment)
     and v_order.payment_method <> 'cash_on_delivery'
     and v_order.payment_status <> 'paid' then
    raise exception 'This order has not been paid, so it cannot be fulfilled yet.'
      using errcode = 'P0001', detail = 'payment_not_confirmed';
  end if;

  if (p_new_status = 'pending' and v_order.payment_method <> 'cash_on_delivery')
     or (p_new_status = 'awaiting_payment' and v_order.payment_method = 'cash_on_delivery') then
    raise exception 'That status does not match the order''s payment method.'
      using errcode = 'P0001', detail = 'payment_method_mismatch';
  end if;

  perform set_config(
    'app.order_status_note',
    case when v_override then 'Admin override: ' else '' end || coalesce(v_note, ''),
    true
  );

  update public.orders set status = p_new_status where id = p_order_id;

  perform set_config('app.order_status_note', '', true);
  return p_new_status;
end;
$$;

-- =============================================================================
-- 5. IDEMPOTENT RESTOCK / RE-RESERVE  (V2)
--
-- Was: AFTER trigger that added stock back on EVERY entry into 'cancelled' and never took it
-- again on reactivation, so cancelled -> pending -> cancelled minted stock.
-- Now a BEFORE trigger (so it can stamp the row) with these rules:
--   * entering 'cancelled' from a stock-holding status (not cancelled/refunded/delivered):
--     restock only if restocked_at IS NULL, then set restocked_at. Second time: no-op.
--   * leaving 'cancelled'/'refunded' for an active status while restocked_at IS NOT NULL
--     (admin override or service role): RE-RESERVE the stock (raise if there is not enough,
--     which rolls the status change back) and clear restocked_at.
--   Net effect: any cancel/reactivate cycle leaves stock unchanged.
-- Concurrency: the UPDATE holds the order's row lock, so a second concurrent update waits and
-- then runs this trigger against the first update's committed row (restocked_at already set).
-- Trigger name is unchanged; it runs after orders_guard_reactivation_capacity (alphabetical).
-- =============================================================================
create or replace function public.restock_cancelled_order()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  v_have integer;
begin
  -- A. Cancellation: give the reserved stock back, once.
  if new.status = 'cancelled'
     and old.status not in ('cancelled', 'refunded', 'delivered') then
    if old.restocked_at is null then
      update public.products p
        set stock_quantity = p.stock_quantity + i.qty
        from (
          select product_id, sum(quantity)::integer as qty
          from public.order_items
          where order_id = new.id
            and product_id is not null
            and variant_id is null
            and variant_name is null
          group by product_id
        ) i
        where p.id = i.product_id;

      update public.product_variants v
        set stock_quantity = v.stock_quantity + i.qty
        from (
          select variant_id, sum(quantity)::integer as qty
          from public.order_items
          where order_id = new.id and variant_id is not null
          group by variant_id
        ) i
        where v.id = i.variant_id;

      new.restocked_at := now();
    else
      new.restocked_at := old.restocked_at;
    end if;
    return new;
  end if;

  -- B. Reactivation of an order whose stock was returned: take it again.
  if old.status in ('cancelled', 'refunded')
     and new.status not in ('cancelled', 'refunded')
     and old.restocked_at is not null then
    -- Product lines (no variant), locked in id order so concurrent reactivations cannot deadlock.
    for r in
      select p.id, p.name, p.stock_quantity as have, i.qty
      from (
        select product_id, sum(quantity)::integer as qty
        from public.order_items
        where order_id = new.id
          and product_id is not null
          and variant_id is null
          and variant_name is null
        group by product_id
      ) i
      join public.products p on p.id = i.product_id
      order by p.id
      for update of p
    loop
      if r.have < r.qty then
        raise exception 'Not enough stock of % to reactivate this order (% needed, % available).',
          r.name, r.qty, r.have
          using errcode = 'P0001', detail = 'reactivation_insufficient_stock';
      end if;
      update public.products set stock_quantity = stock_quantity - r.qty where id = r.id;
    end loop;

    for r in
      select v.id, v.stock_quantity as have, i.qty, v.name
      from (
        select variant_id, sum(quantity)::integer as qty
        from public.order_items
        where order_id = new.id and variant_id is not null
        group by variant_id
      ) i
      join public.product_variants v on v.id = i.variant_id
      order by v.id
      for update of v
    loop
      if r.have < r.qty then
        raise exception 'Not enough stock of % to reactivate this order (% needed, % available).',
          r.name, r.qty, r.have
          using errcode = 'P0001', detail = 'reactivation_insufficient_stock';
      end if;
      update public.product_variants set stock_quantity = stock_quantity - r.qty where id = r.id;
    end loop;

    new.restocked_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_restock_on_cancel on public.orders;
create trigger orders_restock_on_cancel
  before update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.restock_cancelled_order();

-- =============================================================================
-- 6. DELIVERY ZONE vs ADDRESS  (V4)
--
-- WHAT THE SCHEMA ALREADY HAS: addresses.county and addresses.city (both NOT NULL, customer
-- typed); delivery_zones.county (nullable) and delivery_zones.towns (text[]), maintained by
-- admins. That is enough to VALIDATE a zone against an address by name, so no schema change is
-- made. It is not geocoding, and it is not enough to prove the address is real: see "Remaining
-- risks" in the report.
--
-- RULE (delivery_zone_covers_address): an ACTIVE zone covers an address when
--   * the zone states at least one place (a county and/or one or more towns), AND
--   * if it names a county, it equals the address county, AND
--   * if it lists towns, the address city is one of them.
--   Comparison ignores case and repeated/edge whitespace. A zone with NO county and NO towns
--   cannot be checked against anything, so it covers nothing (fail closed).
--
-- create_order() now (section 7): for address delivery, loads the customer's address FIRST, then
--   * no zone sent  -> uses the single covering zone; none -> 'zone_unserviceable'; several ->
--     'zone_required' (the customer must say which of the covering zones)
--   * zone sent     -> must be one of the covering zones, else 'zone_address_mismatch'
--   and prices the order with that validated zone only. A zone sent with a method that has no
--   address is ignored (it can no longer pull a zone fee rule into a pickup order).
-- =============================================================================
create or replace function public.delivery_text_key(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = public, pg_temp
as $$
  select nullif(lower(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'))), '');
$$;

create or replace function public.delivery_zone_covers_address(
  p_zone_id uuid,
  p_county text,
  p_city text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select
      -- the zone must state at least one place, otherwise there is nothing to validate
      (public.delivery_text_key(z.county) is not null
        or exists (select 1 from unnest(z.towns) t where public.delivery_text_key(t) is not null))
      -- county, when the zone names one
      and (public.delivery_text_key(z.county) is null
        or public.delivery_text_key(z.county) = public.delivery_text_key(p_county))
      -- town, when the zone lists any
      and (not exists (select 1 from unnest(z.towns) t where public.delivery_text_key(t) is not null)
        or exists (
          select 1 from unnest(z.towns) t
          where public.delivery_text_key(t) is not null
            and public.delivery_text_key(t) = public.delivery_text_key(p_city)))
    from public.delivery_zones z
    where z.id = p_zone_id and z.is_active
  ), false);
$$;
-- =============================================================================
-- 7. create_order(): delivery zone validated against the address  (V4)
--
-- Same signature, same return type, same grants as 20260930060000 (CREATE OR REPLACE; no
-- overload is created). Generated from that migration with ONE change: the "Delivery method,
-- address and zone" block, explained in section 6 above and in the block's own comments. Basket
-- validation, locking, pricing, stock reservation, idempotency, slot locking, the expected-total
-- veto, the order/line inserts and the unique_violation replay are unchanged. search_path now
-- ends with pg_temp.
--
-- New error codes (exception DETAIL): zone_unserviceable, zone_address_mismatch. The existing
-- zone_required, zone_unknown and zone_inactive are still used. The checkout UI does not know
-- the two new codes yet and will show the database message for them; adding them to
-- src/features/delivery/checkout.ts is a front-end follow-up.
-- =============================================================================
create or replace function public.create_order(
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
  p_zone_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
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
begin
  if v_user is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
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

  -- Promotions are a later phase; discounts stay authoritative at zero.
  v_discount := 0;

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
    customer_notes, idempotency_key
  ) values (
    v_user, public.next_order_number(), v_status, 'pending', p_payment_method,
    v_subtotal, v_delivery_fee, v_discount, v_total,
    v_delivery.method_code, v_address_snapshot,
    case when v_delivery.requires_address then p_address_id else null end,
    v_slot_date, v_slot_start, v_slot_end, v_slot_label,
    v_delivery.zone_id, v_delivery.zone_code, v_delivery.zone_name, v_delivery.method_label,
    v_slot_template_id, v_delivery.fee_rule,
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


-- =============================================================================
-- 8. INACTIVE DATA  (V6)
--
-- validate_cart(): was SECURITY DEFINER with no is_active filter, so anyone could learn the
-- name, price and stock of an INACTIVE product by sending its id. Now:
--   * inactive or unknown product  -> no row at all (the basket already treats a missing row as
--                                     "no longer sold"; the caller learns nothing about it)
--   * inactive variant of an active product -> a row with available = false, reason
--     'variant_unavailable', and NULL price and stock (the variant's data is not returned)
--   * everything else behaves as before (active product/variant: price, stock, reasons)
--   * the variant id in a row is the one the caller sent, so the basket can match the row to its
--     line and show "that option is no longer available" instead of "removed"
--   * at most 100 lines (the same cap create_order() enforces) so an anonymous caller cannot
--     send an unbounded array.
-- Same name, arguments, return columns and grants as before.
-- =============================================================================
create or replace function public.validate_cart(p_items jsonb)
returns table (
  product_id uuid,
  variant_id uuid,
  name text,
  available boolean,
  reason text,
  unit_price_cents integer,
  stock_quantity integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;
  if jsonb_array_length(p_items) > 100 then
    raise exception 'Your basket has too many lines. Remove some items and try again.'
      using errcode = 'P0001';
  end if;

  return query
  select
    p.id,
    i.variant_id,
    p.name,
    case
      when i.variant_id is not null and v.id is null then false
      when i.variant_id is null and not p.in_stock then false
      when coalesce(v.stock_quantity, p.stock_quantity) < i.quantity then false
      else true
    end,
    case
      when i.variant_id is not null and v.id is null then 'variant_unavailable'
      when i.variant_id is null and not p.in_stock then 'out_of_stock'
      when coalesce(v.stock_quantity, p.stock_quantity) < i.quantity then 'insufficient_stock'
      else 'ok'
    end,
    case when i.variant_id is not null and v.id is null then null
         else coalesce(v.price_cents, p.price_cents) end,
    case when i.variant_id is not null and v.id is null then null
         else coalesce(v.stock_quantity, p.stock_quantity) end
  from jsonb_to_recordset(p_items)
    as i(product_id uuid, variant_id uuid, quantity integer)
  join public.products p on p.id = i.product_id and p.is_active
  left join public.product_variants v
    on v.id = i.variant_id and v.product_id = p.id and v.is_active;
end;
$$;

-- validate_delivery_selection(): body of 20260930080000 with one addition: when the method or
-- zone is not ACTIVE (or does not exist) the label / code / name columns come back NULL. The
-- error codes are unchanged (so checkout can still say "not available"), but no inactive
-- configuration is described. An inactive method or zone never validates (it did not before
-- either: is_valid is false and every fee column is NULL).
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
set search_path = public, pg_temp
as $$
declare
  v_method public.delivery_methods%rowtype;
  v_zone public.delivery_zones%rowtype;
  v_res record;
  v_code text := null;
  v_message text := null;
  v_have_fee boolean := false;
  v_min integer := null;
  v_method_ok boolean := false;
  v_zone_ok boolean := false;
begin
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
    v_method_ok := true;

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
      v_zone_ok := true;
    end if;

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
    case when v_method_ok then v_method.code end,
    case when v_method_ok then v_method.label end,
    case when v_method_ok then v_method.requires_slot end,
    case when v_method_ok then v_method.requires_address end,
    case when v_zone_ok then v_zone.id end,
    case when v_zone_ok then v_zone.code end,
    case when v_zone_ok then v_zone.name end,
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

-- =============================================================================
-- 9. FUNCTION PRIVILEGES AND search_path  (V5)
--
-- Every custom function in public is classified and its EXECUTE privilege is stated, not
-- inherited. Supabase's default privileges hand EXECUTE on new functions to anon and
-- authenticated, and `revoke ... from public` does not remove those explicit grants, so each
-- revoke below names anon and authenticated.
--
--   A  client callable (anon + authenticated): read-only checks the storefront calls before
--      sign-in. They run as definer or invoker but return no private data.
--   B  authenticated only: create_order, set_order_status, and the three role helpers (RLS
--      policy expressions run with the caller's privileges, so they must stay callable by
--      authenticated; they answer only about the caller - section 2).
--   C  internal only: helpers called by other functions. Reachable only through them.
--   D  trigger only: executed by triggers. PostgreSQL checks EXECUTE when a trigger is created,
--      not each time it fires, so revoking it does not stop the trigger.
--
-- service_role is never revoked here (it keeps Supabase's default access).
-- Every SECURITY DEFINER function gets `search_path = public, pg_temp`.
-- =============================================================================
do $priv$
declare
  r record;
begin
  for r in
    select * from (values
      -- signature                                                              class
      ('public.validate_cart(jsonb)',                                            'A'),
      ('public.validate_delivery_selection(text,uuid,integer)',                  'A'),
      ('public.validate_delivery_slot(date,time,time)',                          'A'),
      ('public.get_delivery_slot_availability(date,date)',                       'A'),
      ('public.resolve_delivery_fee(text,uuid,integer)',                         'A'),
      ('public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)', 'B'),
      ('public.set_order_status(uuid,public.order_status,text)',                 'B'),
      ('public.has_role(uuid,public.app_role)',                                  'B'),
      ('public.is_staff(uuid)',                                                  'B'),
      ('public.is_admin(uuid)',                                                  'B'),
      ('public.delivery_slot_booked_count(date,time,time)',                      'C'),
      ('public.delivery_slot_effective_capacity(uuid,date)',                     'C'),
      ('public.delivery_slot_evaluate(date,time,time)',                          'C'),
      ('public.delivery_slot_acquire_lock(date,time,time)',                      'C'),
      ('public.lock_delivery_slot(date,time,time)',                              'C'),
      ('public.next_order_number()',                                             'C'),
      ('public.order_status_holds_delivery_slot(public.order_status)',           'C'),
      ('public.delivery_text_key(text)',                                         'C'),
      ('public.delivery_zone_covers_address(uuid,text,text)',                    'C'),
      ('public.restock_cancelled_order()',                                       'D'),
      ('public.log_order_status_change()',                                       'D'),
      ('public.guard_order_reactivation_capacity()',                             'D'),
      ('public.handle_new_user()',                                               'D'),
      ('public.handle_user_email_change()',                                      'D'),
      ('public.set_updated_at()',                                                'D'),
      ('public.addresses_single_default()',                                      'D')
    ) as t(sig, class)
  loop
    if to_regprocedure(r.sig) is null then
      raise exception 'Phase 5B.2: function % not found while setting privileges.', r.sig;
    end if;

    execute format('revoke all on function %s from public, anon, authenticated', r.sig);

    if r.class = 'A' then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    elsif r.class = 'B' then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;

    -- Pin the search_path of every function that is not already pinned to public, pg_temp.
    -- (resolve_delivery_fee and the invoker triggers were pinned to `public` only.)
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end
$priv$;

-- =============================================================================
-- 10. SELF-CHECK - the migration aborts (and rolls back) if its own guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn text;
begin
  -- Browser roles can no longer write orders in any way.
  if has_table_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.orders', 'UPDATE')
     or has_table_privilege('anon', 'public.orders', 'UPDATE')
     or has_any_column_privilege('anon', 'public.orders', 'UPDATE') then
    raise exception 'Phase 5B.2 self-check failed: a browser role can still UPDATE public.orders.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'orders' and cmd in ('UPDATE', 'ALL')
  ) then
    raise exception 'Phase 5B.2 self-check failed: an UPDATE policy remains on public.orders.';
  end if;

  -- RLS stays enabled where it was.
  if exists (
    select 1 from pg_class c
    where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass,
                    'public.order_status_history'::regclass, 'public.user_roles'::regclass,
                    'public.delivery_methods'::regclass, 'public.delivery_zones'::regclass,
                    'public.delivery_zone_fees'::regclass,
                    'public.delivery_slot_templates'::regclass,
                    'public.delivery_slot_overrides'::regclass, 'public.addresses'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 5B.2 self-check failed: row level security is off on a protected table.';
  end if;

  -- anon cannot execute anything that is not class A.
  foreach v_fn in array array[
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)',
    'public.set_order_status(uuid,public.order_status,text)',
    'public.has_role(uuid,public.app_role)', 'public.is_staff(uuid)', 'public.is_admin(uuid)',
    'public.restock_cancelled_order()', 'public.log_order_status_change()',
    'public.guard_order_reactivation_capacity()', 'public.lock_delivery_slot(date,time,time)',
    'public.delivery_zone_covers_address(uuid,text,text)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'Phase 5B.2 self-check failed: anon can execute %.', v_fn;
    end if;
  end loop;

  -- authenticated can still run what the app and RLS need.
  foreach v_fn in array array[
    'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)',
    'public.set_order_status(uuid,public.order_status,text)',
    'public.has_role(uuid,public.app_role)', 'public.is_staff(uuid)', 'public.is_admin(uuid)',
    'public.validate_cart(jsonb)', 'public.validate_delivery_selection(text,uuid,integer)'
  ] loop
    if not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'Phase 5B.2 self-check failed: authenticated cannot execute %.', v_fn;
    end if;
  end loop;

  -- Every SECURITY DEFINER function in public that this project defines pins search_path.
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 5B.2 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
