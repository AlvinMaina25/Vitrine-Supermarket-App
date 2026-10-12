-- =============================================================================
-- Delivery system foundation (PHASE 4A).
--
-- Apply AFTER 20260930020000_order_integrity_hardening.sql (SQL editor, or
-- `supabase db push`). Safe to re-run: every object is created idempotently.
--
-- What already existed and is EXTENDED here (not duplicated):
--   * public.delivery_methods         - code, base fee, free-over, min order, is_active
--   * public.delivery_slot_templates  - slot windows, capacity (unused until now), is_active
--   * public.orders                   - delivery_method FK, delivery_fee_cents and the
--                                       slot date/start/end/label snapshot columns
--   * public.is_staff() / has_role()  - the one authorisation system (staff or admin)
--
-- What this migration adds:
--   1. Staff-only write access to methods and slot templates (RLS + column grants).
--   2. public.delivery_zones           - areas that can be served, with is_active.
--   3. public.delivery_zone_fees       - per zone x method fee rule (fee, free-over, min order).
--   4. public.delivery_slot_overrides  - per-date capacity override / closure of a slot.
--   5. Additive snapshot + relationship columns on public.orders.
--   6. public.resolve_delivery_fee()   - the single place fee rules are evaluated.
--   7. public.get_delivery_slot_availability() - capacity-aware slot listing.
--
-- Authorisation:
--   Every write policy calls public.is_staff(auth.uid()). Customers and anonymous
--   visitors can only read ACTIVE configuration rows. Nobody but the service role
--   has DELETE: configuration is deactivated, never removed, so history is safe.
--
-- Historical orders:
--   Orders keep their own snapshot (method label, zone code/name, slot window,
--   fee amount and the fee rule that produced it). The foreign keys from orders to
--   zones and slot templates are ON DELETE SET NULL and the method FK has no
--   cascade, so deactivating, editing or even deleting configuration can never
--   rewrite or orphan a placed order.
--
-- NOT in this migration (later phases): create_order() still ignores zones, zone
-- fees and capacity, so checkout behaviour is unchanged until it is wired up.
-- =============================================================================

-- =============================================================================
-- 1. DELIVERY METHODS: validation + staff write access
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_methods_code_format') then
    alter table public.delivery_methods add constraint delivery_methods_code_format
      check (code ~ '^[a-z][a-z0-9_]{1,31}$') not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'delivery_methods_label_length') then
    alter table public.delivery_methods add constraint delivery_methods_label_length
      check (char_length(label) between 1 and 80) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'delivery_methods_description_length') then
    alter table public.delivery_methods add constraint delivery_methods_description_length
      check (description is null or char_length(description) <= 500) not valid;
  end if;
end $$;

-- `code` is the primary key that orders reference, so it is insert-only.
grant insert (
  code, label, description, base_fee_cents, free_over_cents, min_order_cents,
  requires_slot, requires_address, eta_label, position, is_active
) on public.delivery_methods to authenticated;
grant update (
  label, description, base_fee_cents, free_over_cents, min_order_cents,
  requires_slot, requires_address, eta_label, position, is_active
) on public.delivery_methods to authenticated;

drop policy if exists "Delivery methods: staff insert" on public.delivery_methods;
create policy "Delivery methods: staff insert"
  on public.delivery_methods for insert to authenticated
  with check (public.is_staff(auth.uid()));

drop policy if exists "Delivery methods: staff update" on public.delivery_methods;
create policy "Delivery methods: staff update"
  on public.delivery_methods for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

-- =============================================================================
-- 2. DELIVERY ZONES
-- =============================================================================
create table if not exists public.delivery_zones (
  id uuid primary key default gen_random_uuid(),
  -- Stable, human-readable key (also snapshotted onto orders). Insert-only.
  code text not null,
  name text not null,
  description text,
  county text,
  -- Free-form list of towns / estates / neighbourhoods the zone covers.
  towns text[] not null default '{}',
  position integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_zones_code_format check (code ~ '^[a-z][a-z0-9_-]{1,39}$'),
  constraint delivery_zones_name_length check (char_length(name) between 1 and 120),
  constraint delivery_zones_description_length
    check (description is null or char_length(description) <= 500),
  constraint delivery_zones_county_length check (county is null or char_length(county) <= 80)
);

create unique index if not exists delivery_zones_code_key on public.delivery_zones (code);
create index if not exists delivery_zones_active_position_idx
  on public.delivery_zones (is_active, position);

grant select on public.delivery_zones to anon, authenticated;
grant insert (code, name, description, county, towns, position, is_active)
  on public.delivery_zones to authenticated;
grant update (name, description, county, towns, position, is_active)
  on public.delivery_zones to authenticated;
grant all on public.delivery_zones to service_role;

alter table public.delivery_zones enable row level security;

drop policy if exists "Delivery zones: public read active" on public.delivery_zones;
create policy "Delivery zones: public read active"
  on public.delivery_zones for select to anon, authenticated
  using (is_active);

drop policy if exists "Delivery zones: staff read all" on public.delivery_zones;
create policy "Delivery zones: staff read all"
  on public.delivery_zones for select to authenticated
  using (public.is_staff(auth.uid()));

drop policy if exists "Delivery zones: staff insert" on public.delivery_zones;
create policy "Delivery zones: staff insert"
  on public.delivery_zones for insert to authenticated
  with check (public.is_staff(auth.uid()));

drop policy if exists "Delivery zones: staff update" on public.delivery_zones;
create policy "Delivery zones: staff update"
  on public.delivery_zones for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

drop trigger if exists delivery_zones_set_updated_at on public.delivery_zones;
create trigger delivery_zones_set_updated_at
  before update on public.delivery_zones
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 3. DELIVERY ZONE FEES  (one fee rule per zone x method)
--
-- A row is a COMPLETE fee rule for that zone and method:
--   fee_cents        replaces the method's base fee
--   free_over_cents  replaces the method's free-over threshold (NULL = never waived)
--   min_order_cents  can only RAISE the method's minimum order (greatest() is used)
-- With no active row the method's own fee settings apply.
-- =============================================================================
create table if not exists public.delivery_zone_fees (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.delivery_zones (id) on delete restrict,
  method_code text not null references public.delivery_methods (code) on delete restrict,
  fee_cents integer not null,
  free_over_cents integer,
  min_order_cents integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_zone_fees_fee_nonnegative check (fee_cents >= 0),
  constraint delivery_zone_fees_free_over_valid
    check (free_over_cents is null or free_over_cents >= 0),
  constraint delivery_zone_fees_min_nonnegative check (min_order_cents >= 0),
  constraint delivery_zone_fees_zone_method_key unique (zone_id, method_code)
);

create index if not exists delivery_zone_fees_method_idx on public.delivery_zone_fees (method_code);

grant select on public.delivery_zone_fees to anon, authenticated;
grant insert (zone_id, method_code, fee_cents, free_over_cents, min_order_cents, is_active)
  on public.delivery_zone_fees to authenticated;
-- zone_id / method_code are fixed after creation: re-pointing a rule would silently
-- change what a zone charges. Deactivate and create a new rule instead.
grant update (fee_cents, free_over_cents, min_order_cents, is_active)
  on public.delivery_zone_fees to authenticated;
grant all on public.delivery_zone_fees to service_role;

alter table public.delivery_zone_fees enable row level security;

drop policy if exists "Delivery zone fees: public read active" on public.delivery_zone_fees;
create policy "Delivery zone fees: public read active"
  on public.delivery_zone_fees for select to anon, authenticated
  using (
    is_active
    and exists (select 1 from public.delivery_zones z where z.id = zone_id and z.is_active)
    and exists (select 1 from public.delivery_methods m where m.code = method_code and m.is_active)
  );

drop policy if exists "Delivery zone fees: staff read all" on public.delivery_zone_fees;
create policy "Delivery zone fees: staff read all"
  on public.delivery_zone_fees for select to authenticated
  using (public.is_staff(auth.uid()));

drop policy if exists "Delivery zone fees: staff insert" on public.delivery_zone_fees;
create policy "Delivery zone fees: staff insert"
  on public.delivery_zone_fees for insert to authenticated
  with check (public.is_staff(auth.uid()));

drop policy if exists "Delivery zone fees: staff update" on public.delivery_zone_fees;
create policy "Delivery zone fees: staff update"
  on public.delivery_zone_fees for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

drop trigger if exists delivery_zone_fees_set_updated_at on public.delivery_zone_fees;
create trigger delivery_zone_fees_set_updated_at
  before update on public.delivery_zone_fees
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 4. DELIVERY SLOT TEMPLATES: validation + staff write access
--
-- capacity semantics (template and override):  NULL = unlimited,
--   0 = closed (accepts no orders), n > 0 = at most n orders for that window.
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_slot_capacity_valid') then
    alter table public.delivery_slot_templates add constraint delivery_slot_capacity_valid
      check (capacity is null or capacity >= 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'delivery_slot_label_length') then
    alter table public.delivery_slot_templates add constraint delivery_slot_label_length
      check (char_length(label) between 1 and 80) not valid;
  end if;
end $$;

grant insert (label, start_time, end_time, day_of_week, capacity, position, is_active)
  on public.delivery_slot_templates to authenticated;
grant update (label, start_time, end_time, day_of_week, capacity, position, is_active)
  on public.delivery_slot_templates to authenticated;

drop policy if exists "Delivery slots: staff read all" on public.delivery_slot_templates;
create policy "Delivery slots: staff read all"
  on public.delivery_slot_templates for select to authenticated
  using (public.is_staff(auth.uid()));

drop policy if exists "Delivery slots: staff insert" on public.delivery_slot_templates;
create policy "Delivery slots: staff insert"
  on public.delivery_slot_templates for insert to authenticated
  with check (public.is_staff(auth.uid()));

drop policy if exists "Delivery slots: staff update" on public.delivery_slot_templates;
create policy "Delivery slots: staff update"
  on public.delivery_slot_templates for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

-- =============================================================================
-- 5. DELIVERY SLOT OVERRIDES  (capacity change or closure of one slot on one date)
-- =============================================================================
create table if not exists public.delivery_slot_overrides (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.delivery_slot_templates (id) on delete restrict,
  slot_date date not null,
  -- NULL = inherit the template's capacity.
  capacity integer,
  -- false closes this slot on this date regardless of the template.
  is_active boolean not null default true,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_slot_overrides_capacity_valid check (capacity is null or capacity >= 0),
  constraint delivery_slot_overrides_note_length check (note is null or char_length(note) <= 300),
  constraint delivery_slot_overrides_template_date_key unique (template_id, slot_date)
);

create index if not exists delivery_slot_overrides_date_idx
  on public.delivery_slot_overrides (slot_date);

-- Staff only. Customers see the effect through get_delivery_slot_availability().
grant select on public.delivery_slot_overrides to authenticated;
grant insert (template_id, slot_date, capacity, is_active, note)
  on public.delivery_slot_overrides to authenticated;
grant update (capacity, is_active, note) on public.delivery_slot_overrides to authenticated;
grant all on public.delivery_slot_overrides to service_role;

alter table public.delivery_slot_overrides enable row level security;

drop policy if exists "Slot overrides: staff read" on public.delivery_slot_overrides;
create policy "Slot overrides: staff read"
  on public.delivery_slot_overrides for select to authenticated
  using (public.is_staff(auth.uid()));

drop policy if exists "Slot overrides: staff insert" on public.delivery_slot_overrides;
create policy "Slot overrides: staff insert"
  on public.delivery_slot_overrides for insert to authenticated
  with check (public.is_staff(auth.uid()));

drop policy if exists "Slot overrides: staff update" on public.delivery_slot_overrides;
create policy "Slot overrides: staff update"
  on public.delivery_slot_overrides for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

drop trigger if exists delivery_slot_overrides_set_updated_at on public.delivery_slot_overrides;
create trigger delivery_slot_overrides_set_updated_at
  before update on public.delivery_slot_overrides
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 6. ORDERS: relationships + historical snapshot columns
--
-- All additive and nullable. Browser grants on orders are unchanged (UPDATE is
-- limited to `status`), so these can only be written by create_order() or the
-- service role. create_order() does not populate them yet (later phase).
-- =============================================================================
alter table public.orders
  add column if not exists delivery_zone_id uuid
    references public.delivery_zones (id) on delete set null,
  add column if not exists delivery_zone_code text,
  add column if not exists delivery_zone_name text,
  add column if not exists delivery_method_label text,
  add column if not exists delivery_slot_template_id uuid
    references public.delivery_slot_templates (id) on delete set null,
  -- The rule that produced delivery_fee_cents, e.g.
  --   {"source":"zone","base_fee_cents":25000,"free_over_cents":500000,
  --    "min_order_cents":0,"zone_fee_id":"..."}
  add column if not exists delivery_fee_rule jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_delivery_fee_rule_object') then
    alter table public.orders add constraint orders_delivery_fee_rule_object
      check (delivery_fee_rule is null or jsonb_typeof(delivery_fee_rule) = 'object');
  end if;
end $$;

create index if not exists orders_delivery_zone_idx
  on public.orders (delivery_zone_id) where delivery_zone_id is not null;
create index if not exists orders_delivery_slot_idx
  on public.orders (delivery_slot_date, delivery_slot_start, delivery_slot_end)
  where delivery_slot_date is not null;

-- Existing orders: capture the method label they were placed under. The slot
-- window, label and fee are already stored on the order. updated_at is left alone.
alter table public.orders disable trigger orders_set_updated_at;
update public.orders o
  set delivery_method_label = m.label
  from public.delivery_methods m
  where m.code = o.delivery_method and o.delivery_method_label is null;
alter table public.orders enable trigger orders_set_updated_at;

-- =============================================================================
-- 7. FEE RESOLUTION
--
-- The single definition of "what does this method cost in this zone for this
-- subtotal". SECURITY INVOKER on purpose: it only sees what the caller's RLS
-- allows, i.e. ACTIVE methods, zones and zone fees. Returns no rows when the
-- method is unavailable or the zone is inactive. Display/quoting only; whoever
-- creates the order must call it again server-side.
-- =============================================================================
create or replace function public.resolve_delivery_fee(
  p_method_code text,
  p_zone_id uuid default null,
  p_subtotal_cents integer default 0
)
returns table (
  fee_cents integer,
  base_fee_cents integer,
  free_over_cents integer,
  min_order_cents integer,
  fee_source text,
  zone_fee_id uuid
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_method public.delivery_methods%rowtype;
  v_rule public.delivery_zone_fees%rowtype;
  v_base integer;
  v_free_over integer;
  v_min integer;
  v_source text := 'method';
begin
  if p_subtotal_cents is null or p_subtotal_cents < 0 then
    raise exception 'Subtotal must be zero or more.' using errcode = 'P0001';
  end if;

  select m.* into v_method
  from public.delivery_methods m
  where m.code = p_method_code and m.is_active;
  if not found then
    return;
  end if;

  if p_zone_id is not null then
    perform 1 from public.delivery_zones z where z.id = p_zone_id and z.is_active;
    if not found then
      return;
    end if;

    select f.* into v_rule
    from public.delivery_zone_fees f
    where f.zone_id = p_zone_id and f.method_code = p_method_code and f.is_active;
  end if;

  if v_rule.id is not null then
    v_source := 'zone';
    v_base := v_rule.fee_cents;
    v_free_over := v_rule.free_over_cents;
    v_min := greatest(v_method.min_order_cents, v_rule.min_order_cents);
  else
    v_base := v_method.base_fee_cents;
    v_free_over := v_method.free_over_cents;
    v_min := v_method.min_order_cents;
  end if;

  return query
  select
    case when v_free_over is not null and p_subtotal_cents >= v_free_over then 0 else v_base end,
    v_base,
    v_free_over,
    v_min,
    v_source,
    v_rule.id;
end;
$$;

revoke execute on function public.resolve_delivery_fee(text, uuid, integer) from public;
grant execute on function public.resolve_delivery_fee(text, uuid, integer) to anon, authenticated;

-- =============================================================================
-- 8. SLOT AVAILABILITY
--
-- Expands ACTIVE templates over a date range (max 32 days), applies per-date
-- overrides, and counts the orders already holding each window. An order holds
-- a slot unless it is cancelled or refunded (unpaid orders hold it too, matching
-- their stock reservation). SECURITY DEFINER so the count covers every
-- customer's orders without exposing the orders themselves; only aggregates are
-- returned. Slots are matched on (date, start, end) - the same identity
-- create_order() uses - so orders placed before this migration are counted.
--
-- This reports capacity; it does not enforce it. Enforcement belongs in
-- create_order() under a per-slot lock (later phase).
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
    eff.cap,
    b.booked,
    case when eff.cap is null then null else greatest(eff.cap - b.booked, 0) end,
    (eff.cap is null or b.booked < eff.cap)
  from (
    select gs::date as slot_date
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs
  ) d
  join public.delivery_slot_templates t
    on t.is_active
   and (t.day_of_week is null or t.day_of_week = extract(dow from d.slot_date)::integer)
  left join public.delivery_slot_overrides o
    on o.template_id = t.id and o.slot_date = d.slot_date
  cross join lateral (select coalesce(o.capacity, t.capacity) as cap) eff
  cross join lateral (
    select count(*)::integer as booked
    from public.orders ord
    where ord.delivery_slot_date = d.slot_date
      and ord.delivery_slot_start = t.start_time
      and ord.delivery_slot_end = t.end_time
      and ord.status not in ('cancelled', 'refunded')
  ) b
  where coalesce(o.is_active, true)
  order by d.slot_date, t.position, t.start_time;
end;
$$;

revoke execute on function public.get_delivery_slot_availability(date, date) from public;
grant execute on function public.get_delivery_slot_availability(date, date) to anon, authenticated;
