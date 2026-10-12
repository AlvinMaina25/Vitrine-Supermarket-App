-- =============================================================================
-- Orders, delivery foundation and role-based admin authorisation.
--
-- Apply to your Supabase project (SQL editor, or copy into
-- supabase/migrations/ and run `supabase db push`). Runs after
-- 20260930000000_foundation_schema.sql.
--
-- Design rules carried over from the foundation migration:
--   * Money is integer minor units (`*_cents`). No floating point anywhere.
--   * Customers never write totals, prices or statuses. Orders are created by
--     public.create_order(), a SECURITY DEFINER function that re-reads product
--     and delivery pricing from the database and ignores client-side amounts.
--   * Order status and payment status are separate lifecycles.
-- =============================================================================

create extension if not exists pgcrypto;

-- =============================================================================
-- ENUMS
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type public.order_status as enum (
      'pending',
      'awaiting_payment',
      'paid',
      'processing',
      'picking',
      'packed',
      'dispatched',
      'out_for_delivery',
      'delivered',
      'cancelled',
      'refunded'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_status') then
    create type public.payment_status as enum (
      'pending',
      'processing',
      'paid',
      'failed',
      'cancelled',
      'refunded',
      'partially_refunded'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_method') then
    create type public.payment_method as enum ('mpesa', 'card', 'cash_on_delivery');
  end if;

  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum ('customer', 'staff', 'admin');
  end if;
end;
$$;

-- =============================================================================
-- ROLES  (separate table — never a column on profiles)
-- =============================================================================
create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  unique (user_id, role)
);

create index if not exists user_roles_user_id_idx on public.user_roles (user_id);

grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;

alter table public.user_roles enable row level security;

drop policy if exists "User roles: read own" on public.user_roles;
create policy "User roles: read own"
  on public.user_roles for select to authenticated
  using (user_id = auth.uid());

-- Security definer so policies can call it without recursing through RLS.
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = _user_id and role = _role
  );
$$;

-- Staff-level access: admins implicitly have it.
create or replace function public.is_staff(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = _user_id and role in ('staff', 'admin')
  );
$$;

grant execute on function public.has_role(uuid, public.app_role) to authenticated;
grant execute on function public.is_staff(uuid) to authenticated;

drop policy if exists "User roles: admins read all" on public.user_roles;
create policy "User roles: admins read all"
  on public.user_roles for select to authenticated
  using (public.has_role(auth.uid(), 'admin'));

-- Grant yourself admin once, from the SQL editor:
--   insert into public.user_roles (user_id, role)
--   select id, 'admin' from auth.users where email = 'you@example.com'
--   on conflict do nothing;

-- =============================================================================
-- DELIVERY FOUNDATION
--
-- Deliberately minimal and configurable: methods carry their own fee rules so
-- later phases can add counties, towns, zones, distance pricing and capacity
-- without reshaping orders.
-- =============================================================================
create table if not exists public.delivery_methods (
  code text primary key,
  label text not null,
  description text,
  base_fee_cents integer not null default 0,
  -- Fee is waived when the subtotal reaches this value. NULL = never waived.
  free_over_cents integer,
  min_order_cents integer not null default 0,
  requires_slot boolean not null default true,
  requires_address boolean not null default true,
  eta_label text,
  position integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_methods_fee_nonnegative check (base_fee_cents >= 0),
  constraint delivery_methods_min_nonnegative check (min_order_cents >= 0),
  constraint delivery_methods_free_over_valid check (free_over_cents is null or free_over_cents >= 0)
);

grant select on public.delivery_methods to anon, authenticated;
grant all on public.delivery_methods to service_role;

alter table public.delivery_methods enable row level security;

drop policy if exists "Delivery methods: public read active" on public.delivery_methods;
create policy "Delivery methods: public read active"
  on public.delivery_methods for select to anon, authenticated
  using (is_active);

drop policy if exists "Delivery methods: staff read all" on public.delivery_methods;
create policy "Delivery methods: staff read all"
  on public.delivery_methods for select to authenticated
  using (public.is_staff(auth.uid()));

drop trigger if exists delivery_methods_set_updated_at on public.delivery_methods;
create trigger delivery_methods_set_updated_at
  before update on public.delivery_methods
  for each row execute function public.set_updated_at();

insert into public.delivery_methods
  (code, label, description, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, eta_label, position)
values
  ('standard', 'Standard delivery', 'Delivered in the slot you choose.', 25000, 500000, 0, true, true, 'Next available slot', 1),
  ('express', 'Express delivery', 'Fastest available slot today.', 45000, null, 0, true, true, 'Within 3 hours', 2),
  ('pickup', 'Store pickup', 'Collect from the store yourself.', 0, null, 0, true, false, 'Ready in 2 hours', 3)
on conflict (code) do nothing;

-- Slot windows. Capacity and per-zone availability arrive in a later phase;
-- the shape already allows both.
create table if not exists public.delivery_slot_templates (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  start_time time not null,
  end_time time not null,
  -- NULL = available every day of the week.
  day_of_week smallint,
  capacity integer,
  position integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_slot_window_valid check (end_time > start_time),
  constraint delivery_slot_day_valid check (day_of_week is null or day_of_week between 0 and 6)
);

grant select on public.delivery_slot_templates to anon, authenticated;
grant all on public.delivery_slot_templates to service_role;

alter table public.delivery_slot_templates enable row level security;

drop policy if exists "Delivery slots: public read active" on public.delivery_slot_templates;
create policy "Delivery slots: public read active"
  on public.delivery_slot_templates for select to anon, authenticated
  using (is_active);

drop trigger if exists delivery_slot_templates_set_updated_at on public.delivery_slot_templates;
create trigger delivery_slot_templates_set_updated_at
  before update on public.delivery_slot_templates
  for each row execute function public.set_updated_at();

insert into public.delivery_slot_templates (label, start_time, end_time, position)
select v.label, v.start_time::time, v.end_time::time, v.position
from (values
  ('Morning', '08:00', '11:00', 1),
  ('Midday', '11:00', '14:00', 2),
  ('Afternoon', '14:00', '17:00', 3),
  ('Evening', '17:00', '20:00', 4)
) as v(label, start_time, end_time, position)
where not exists (select 1 from public.delivery_slot_templates);

-- =============================================================================
-- ORDER NUMBER
-- =============================================================================
create sequence if not exists public.order_number_seq;

create or replace function public.next_order_number()
returns text
language sql
volatile
set search_path = public
as $$
  select 'KS-' || to_char(now() at time zone 'UTC', 'YYYY') || '-' ||
         lpad(nextval('public.order_number_seq')::text, 6, '0');
$$;

revoke execute on function public.next_order_number() from public, anon, authenticated;

-- =============================================================================
-- ORDERS
-- =============================================================================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete restrict,
  order_number text not null unique,
  status public.order_status not null default 'pending',
  payment_status public.payment_status not null default 'pending',
  payment_method public.payment_method not null,
  currency text not null default 'KES',

  subtotal_cents integer not null default 0,
  delivery_fee_cents integer not null default 0,
  discount_cents integer not null default 0,
  total_cents integer not null default 0,

  delivery_method text not null references public.delivery_methods (code),
  -- Snapshot, so the order is unaffected by later address edits or deletions.
  delivery_address jsonb,
  delivery_address_id uuid references public.addresses (id) on delete set null,
  delivery_slot_date date,
  delivery_slot_start time,
  delivery_slot_end time,
  delivery_slot_label text,

  customer_notes text,
  -- Guards against double submission of the same checkout.
  idempotency_key text,

  placed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint orders_amounts_nonnegative check (
    subtotal_cents >= 0 and delivery_fee_cents >= 0 and discount_cents >= 0 and total_cents >= 0
  ),
  constraint orders_total_consistent check (
    total_cents = subtotal_cents + delivery_fee_cents - discount_cents
  ),
  constraint orders_notes_length check (customer_notes is null or char_length(customer_notes) <= 1000)
);

create unique index if not exists orders_user_idempotency_key
  on public.orders (user_id, idempotency_key)
  where idempotency_key is not null;
create index if not exists orders_user_created_idx on public.orders (user_id, created_at desc);
create index if not exists orders_status_idx on public.orders (status);
create index if not exists orders_payment_status_idx on public.orders (payment_status);

-- Customers read only. Inserts happen exclusively through create_order();
-- staff updates are allowed but gated by the policies below.
grant select on public.orders to authenticated;
grant update on public.orders to authenticated;
grant all on public.orders to service_role;

alter table public.orders enable row level security;

drop policy if exists "Orders: read own" on public.orders;
create policy "Orders: read own"
  on public.orders for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Orders: staff read all" on public.orders;
create policy "Orders: staff read all"
  on public.orders for select to authenticated
  using (public.is_staff(auth.uid()));

drop policy if exists "Orders: staff update" on public.orders;
create policy "Orders: staff update"
  on public.orders for update to authenticated
  using (public.is_staff(auth.uid()))
  with check (public.is_staff(auth.uid()));

-- Note: no customer INSERT/UPDATE/DELETE policy exists. A customer cannot set
-- totals, change a status, or mark an order paid under any circumstance.

drop trigger if exists orders_set_updated_at on public.orders;
create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- =============================================================================
-- ORDER ITEMS  (full snapshot — historical orders never re-read live prices)
-- =============================================================================
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  variant_id uuid references public.product_variants (id) on delete set null,

  product_name text not null,
  product_slug text,
  sku text,
  variant_name text,
  variant_attributes jsonb,
  unit_label text,
  image_url text,

  unit_price_cents integer not null,
  quantity integer not null,
  line_total_cents integer not null,
  created_at timestamptz not null default now(),

  constraint order_items_quantity_valid check (quantity > 0 and quantity <= 99),
  constraint order_items_price_nonnegative check (unit_price_cents >= 0),
  constraint order_items_line_total_consistent check (line_total_cents = unit_price_cents * quantity)
);

create index if not exists order_items_order_id_idx on public.order_items (order_id);

grant select on public.order_items to authenticated;
grant all on public.order_items to service_role;

alter table public.order_items enable row level security;

drop policy if exists "Order items: read own" on public.order_items;
create policy "Order items: read own"
  on public.order_items for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_items.order_id and o.user_id = auth.uid()
  ));

drop policy if exists "Order items: staff read all" on public.order_items;
create policy "Order items: staff read all"
  on public.order_items for select to authenticated
  using (public.is_staff(auth.uid()));

-- =============================================================================
-- ORDER STATUS HISTORY
-- =============================================================================
create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  previous_status public.order_status,
  new_status public.order_status not null,
  payment_status public.payment_status,
  changed_by uuid references auth.users (id) on delete set null,
  note text,
  created_at timestamptz not null default now(),
  constraint order_status_history_note_length check (note is null or char_length(note) <= 500)
);

create index if not exists order_status_history_order_idx
  on public.order_status_history (order_id, created_at);

grant select on public.order_status_history to authenticated;
grant all on public.order_status_history to service_role;

alter table public.order_status_history enable row level security;

drop policy if exists "Order history: read own" on public.order_status_history;
create policy "Order history: read own"
  on public.order_status_history for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_status_history.order_id and o.user_id = auth.uid()
  ));

drop policy if exists "Order history: staff read all" on public.order_status_history;
create policy "Order history: staff read all"
  on public.order_status_history for select to authenticated
  using (public.is_staff(auth.uid()));

-- History is written by triggers only; customers have no INSERT policy.
create or replace function public.log_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
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
        when new.status is distinct from old.status then null
        else 'Payment status updated to ' || new.payment_status::text
      end
    );
  end if;

  return new;
end;
$$;

drop trigger if exists orders_log_status_insert on public.orders;
create trigger orders_log_status_insert
  after insert on public.orders
  for each row execute function public.log_order_status_change();

drop trigger if exists orders_log_status_update on public.orders;
create trigger orders_log_status_update
  after update on public.orders
  for each row execute function public.log_order_status_change();

-- =============================================================================
-- CHECKOUT VALIDATION + ORDER CREATION
--
-- The single write path for customer orders. The client sends only
-- product/variant ids and quantities; every price, fee and total below is read
-- from the database. A client claiming "price = 1" has no effect.
-- =============================================================================
create or replace function public.create_order(
  p_items jsonb,
  p_delivery_method text,
  p_payment_method public.payment_method,
  p_address_id uuid default null,
  p_slot_date date default null,
  p_slot_start time default null,
  p_slot_end time default null,
  p_slot_label text default null,
  p_notes text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_existing uuid;
  v_method public.delivery_methods%rowtype;
  v_address public.addresses%rowtype;
  v_address_snapshot jsonb := null;
  v_item record;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_unit_price integer;
  v_available integer;
  v_subtotal integer := 0;
  v_delivery_fee integer := 0;
  v_discount integer := 0;
  v_order_id uuid;
  v_item_count integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_status public.order_status;
begin
  if v_user is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
  end if;

  -- Idempotency: replaying the same checkout returns the original order.
  if p_idempotency_key is not null then
    select id into v_existing
    from public.orders
    where user_id = v_user and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  select * into v_method
  from public.delivery_methods
  where code = p_delivery_method and is_active;
  if not found then
    raise exception 'That delivery method is not available.' using errcode = 'P0001';
  end if;

  if v_method.requires_address then
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
  end if;

  if v_method.requires_slot and (p_slot_date is null or p_slot_start is null or p_slot_end is null) then
    raise exception 'Choose a delivery slot.' using errcode = 'P0001';
  end if;

  if p_slot_date is not null and p_slot_date < (now() at time zone 'UTC')::date then
    raise exception 'That delivery slot is in the past. Pick another slot.' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your basket is empty.' using errcode = 'P0001';
  end if;

  v_lines := '[]'::jsonb;

  for v_item in
    select *
    from jsonb_to_recordset(p_items)
      as x(product_id uuid, variant_id uuid, quantity integer)
  loop
    if v_item.product_id is null then
      raise exception 'One of the basket items is invalid. Refresh your basket.' using errcode = 'P0001';
    end if;
    if v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 99 then
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

  if v_subtotal < v_method.min_order_cents then
    raise exception 'This delivery method needs a larger order.' using errcode = 'P0001';
  end if;

  v_delivery_fee := case
    when v_method.free_over_cents is not null and v_subtotal >= v_method.free_over_cents then 0
    else v_method.base_fee_cents
  end;

  -- Promotions are a later phase; discounts stay authoritative at zero.
  v_discount := 0;

  -- Payment is never confirmed here. Cash on delivery still owes money, so it
  -- starts pending too; it simply does not wait on a gateway.
  v_status := case when p_payment_method = 'cash_on_delivery' then 'pending' else 'awaiting_payment' end;

  insert into public.orders (
    user_id, order_number, status, payment_status, payment_method,
    subtotal_cents, delivery_fee_cents, discount_cents, total_cents,
    delivery_method, delivery_address, delivery_address_id,
    delivery_slot_date, delivery_slot_start, delivery_slot_end, delivery_slot_label,
    customer_notes, idempotency_key
  ) values (
    v_user, public.next_order_number(), v_status, 'pending', p_payment_method,
    v_subtotal, v_delivery_fee, v_discount, v_subtotal + v_delivery_fee - v_discount,
    v_method.code, v_address_snapshot, case when v_method.requires_address then p_address_id else null end,
    p_slot_date, p_slot_start, p_slot_end, nullif(btrim(coalesce(p_slot_label, '')), ''),
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
    -- Two concurrent submissions of the same checkout: return the winner.
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

revoke execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text
) from public, anon;
grant execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text
) to authenticated;

-- =============================================================================
-- CART VALIDATION
--
-- Read-only mirror of the checks above so the basket can warn about price or
-- stock changes before the customer reaches the final step.
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
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    v.id,
    p.name,
    case
      when not p.is_active then false
      when i.variant_id is not null and (v.id is null or not v.is_active) then false
      when i.variant_id is null and not p.in_stock then false
      when coalesce(v.stock_quantity, p.stock_quantity) < i.quantity then false
      else true
    end,
    case
      when not p.is_active then 'unavailable'
      when i.variant_id is not null and (v.id is null or not v.is_active) then 'variant_unavailable'
      when i.variant_id is null and not p.in_stock then 'out_of_stock'
      when coalesce(v.stock_quantity, p.stock_quantity) < i.quantity then 'insufficient_stock'
      else 'ok'
    end,
    coalesce(v.price_cents, p.price_cents),
    coalesce(v.stock_quantity, p.stock_quantity)
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
    as i(product_id uuid, variant_id uuid, quantity integer)
  join public.products p on p.id = i.product_id
  left join public.product_variants v on v.id = i.variant_id and v.product_id = p.id;
$$;

revoke execute on function public.validate_cart(jsonb) from public;
grant execute on function public.validate_cart(jsonb) to anon, authenticated;
