-- =============================================================================
-- Foundation schema: profiles, categories, products, product_variants, addresses
--
-- Apply to your Supabase project (SQL editor, or copy into
-- supabase/migrations/ and run `supabase db push`).
--
-- Compatibility notes (existing storefront code is the source of truth):
--   * Money is stored as integer minor units (`price_cents`), as the catalog
--     code already expects. `compare_at_price_cents` follows the same rule.
--   * Existing column names are preserved: categories.tagline / position
--     (= sort order), products.unit_label (= unit) / in_stock / price_cents.
--   * Tables use CREATE TABLE IF NOT EXISTS and ADD COLUMN IF NOT EXISTS so this
--     runs against a project that already has the original categories/products
--     tables. A type conflict on an existing column still raises an error.
-- =============================================================================

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- PROFILES
-- =============================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  phone text,
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_length check (full_name is null or char_length(full_name) <= 120),
  constraint profiles_phone_length check (phone is null or char_length(phone) <= 20)
);

create index if not exists profiles_email_idx on public.profiles (lower(email));

grant select, insert on public.profiles to authenticated;
-- Customers may only edit presentation fields; email mirrors auth.users.
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
grant all on public.profiles to service_role;

alter table public.profiles enable row level security;

drop policy if exists "Profiles: read own" on public.profiles;
create policy "Profiles: read own"
  on public.profiles for select to authenticated
  using (id = auth.uid());

drop policy if exists "Profiles: insert own" on public.profiles;
create policy "Profiles: insert own"
  on public.profiles for insert to authenticated
  with check (id = auth.uid());

drop policy if exists "Profiles: update own" on public.profiles;
create policy "Profiles: update own"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-create a profile for every new auth user. Only safe, non-secret
-- metadata is copied; values are trimmed and length-limited.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_full_name text := nullif(left(btrim(coalesce(meta ->> 'full_name', '')), 120), '');
  v_phone text := nullif(left(btrim(coalesce(meta ->> 'phone', '')), 20), '');
begin
  insert into public.profiles (id, email, full_name, phone)
  values (new.id, new.email, v_full_name, v_phone)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep profiles.email in sync when the auth email changes.
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end;
$$;

revoke execute on function public.handle_user_email_change() from public, anon, authenticated;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- Backfill profiles for users that signed up before this migration.
insert into public.profiles (id, email)
select u.id, u.email from auth.users u
on conflict (id) do nothing;

-- =============================================================================
-- CATEGORIES
-- =============================================================================
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null,
  name text not null
);

alter table public.categories
  add column if not exists tagline text,
  add column if not exists description text,
  add column if not exists image_url text,
  add column if not exists parent_id uuid references public.categories (id) on delete set null,
  add column if not exists position integer not null default 0,
  add column if not exists is_active boolean not null default true,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists categories_slug_key on public.categories (slug);
create index if not exists categories_parent_id_idx on public.categories (parent_id);
create index if not exists categories_active_position_idx on public.categories (is_active, position);

grant select on public.categories to anon, authenticated;
grant all on public.categories to service_role;

alter table public.categories enable row level security;

drop policy if exists "Categories: public read active" on public.categories;
create policy "Categories: public read active"
  on public.categories for select to anon, authenticated
  using (is_active);

drop trigger if exists categories_set_updated_at on public.categories;
create trigger categories_set_updated_at
  before update on public.categories
  for each row execute function public.set_updated_at();

-- =============================================================================
-- PRODUCTS
-- =============================================================================
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null,
  name text not null,
  price_cents integer not null default 0
);

alter table public.products
  add column if not exists category_id uuid references public.categories (id) on delete set null,
  add column if not exists description text,
  add column if not exists brand text,
  add column if not exists sku text,
  add column if not exists image_url text,
  add column if not exists compare_at_price_cents integer,
  add column if not exists unit_label text,
  add column if not exists stock_quantity integer not null default 0,
  add column if not exists in_stock boolean not null default true,
  add column if not exists is_active boolean not null default true,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'products_price_nonnegative') then
    alter table public.products add constraint products_price_nonnegative check (price_cents >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'products_compare_at_valid') then
    alter table public.products add constraint products_compare_at_valid
      check (compare_at_price_cents is null or compare_at_price_cents >= price_cents);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'products_stock_nonnegative') then
    alter table public.products add constraint products_stock_nonnegative check (stock_quantity >= 0);
  end if;
end $$;

create unique index if not exists products_slug_key on public.products (slug);
create unique index if not exists products_sku_key on public.products (sku) where sku is not null;
create index if not exists products_category_id_idx on public.products (category_id);
create index if not exists products_active_category_name_idx on public.products (is_active, category_id, name);
create index if not exists products_price_idx on public.products (price_cents);
create index if not exists products_brand_idx on public.products (lower(brand));
create index if not exists products_search_idx on public.products using gin (
  to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(brand, '') || ' ' || coalesce(description, ''))
);

grant select on public.products to anon, authenticated;
grant all on public.products to service_role;

alter table public.products enable row level security;

drop policy if exists "Products: public read active" on public.products;
create policy "Products: public read active"
  on public.products for select to anon, authenticated
  using (is_active);

drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

-- =============================================================================
-- PRODUCT VARIANTS
-- =============================================================================
create table if not exists public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  name text not null,
  sku text,
  price_cents integer not null,
  compare_at_price_cents integer,
  stock_quantity integer not null default 0,
  attributes jsonb not null default '{}'::jsonb,
  position integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_variants_price_nonnegative check (price_cents >= 0),
  constraint product_variants_compare_at_valid
    check (compare_at_price_cents is null or compare_at_price_cents >= price_cents),
  constraint product_variants_stock_nonnegative check (stock_quantity >= 0),
  constraint product_variants_attributes_object check (jsonb_typeof(attributes) = 'object')
);

create unique index if not exists product_variants_sku_key on public.product_variants (sku) where sku is not null;
create index if not exists product_variants_product_id_idx on public.product_variants (product_id, position);

grant select on public.product_variants to anon, authenticated;
grant all on public.product_variants to service_role;

alter table public.product_variants enable row level security;

drop policy if exists "Variants: public read active" on public.product_variants;
create policy "Variants: public read active"
  on public.product_variants for select to anon, authenticated
  using (
    is_active
    and exists (select 1 from public.products p where p.id = product_id and p.is_active)
  );

drop trigger if exists product_variants_set_updated_at on public.product_variants;
create trigger product_variants_set_updated_at
  before update on public.product_variants
  for each row execute function public.set_updated_at();

-- =============================================================================
-- ADDRESSES (Kenyan delivery)
-- =============================================================================
create table if not exists public.addresses (
  id uuid primary key default gen_random_uuid(),
  -- Defaults to the caller; RLS rejects any other value.
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  label text,
  full_name text not null,
  phone text not null,
  address_line_1 text not null,
  address_line_2 text,
  city text not null,
  county text not null,
  postal_code text,
  delivery_instructions text,
  latitude double precision,
  longitude double precision,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint addresses_label_length check (label is null or char_length(label) <= 40),
  constraint addresses_full_name_length check (char_length(full_name) between 1 and 120),
  constraint addresses_phone_length check (char_length(phone) between 7 and 20),
  constraint addresses_line1_length check (char_length(address_line_1) between 1 and 200),
  constraint addresses_instructions_length
    check (delivery_instructions is null or char_length(delivery_instructions) <= 500),
  constraint addresses_latitude_range check (latitude is null or latitude between -90 and 90),
  constraint addresses_longitude_range check (longitude is null or longitude between -180 and 180)
);

create index if not exists addresses_user_id_idx on public.addresses (user_id, created_at);
-- At most one default address per customer.
create unique index if not exists addresses_one_default_per_user
  on public.addresses (user_id) where is_default;

grant select, insert, update, delete on public.addresses to authenticated;
grant all on public.addresses to service_role;

alter table public.addresses enable row level security;

drop policy if exists "Addresses: read own" on public.addresses;
create policy "Addresses: read own"
  on public.addresses for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Addresses: insert own" on public.addresses;
create policy "Addresses: insert own"
  on public.addresses for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Addresses: update own" on public.addresses;
create policy "Addresses: update own"
  on public.addresses for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "Addresses: delete own" on public.addresses;
create policy "Addresses: delete own"
  on public.addresses for delete to authenticated
  using (user_id = auth.uid());

drop trigger if exists addresses_set_updated_at on public.addresses;
create trigger addresses_set_updated_at
  before update on public.addresses
  for each row execute function public.set_updated_at();

-- When an address becomes default, clear the flag on the owner's others.
-- Runs as the caller, so RLS still scopes the update to their own rows.
create or replace function public.addresses_single_default()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_default then
    update public.addresses
      set is_default = false
      where user_id = new.user_id and id <> new.id and is_default;
  end if;
  return new;
end;
$$;

drop trigger if exists addresses_single_default on public.addresses;
create trigger addresses_single_default
  before insert or update of is_default on public.addresses
  for each row execute function public.addresses_single_default();
