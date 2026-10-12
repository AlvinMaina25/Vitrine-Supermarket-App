-- =============================================================================
-- PHASE 6C.1A.2 - Admin product search, filtering, pagination and details (READ ONLY).
--
-- STATUS: written, NOT APPLIED to any database. It has not been executed anywhere yet (no
-- PostgreSQL was available where it was written). Review it, then apply it ONCE to the
-- dedicated Phase-5 development database only.
--
-- Apply ONCE, after 20261004040000_phase6c1a1_admin_product_read_foundation.sql. Do not edit or
-- re-run any older migration. One transaction: if any statement or the final self-check fails,
-- nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS DOES
--   1. Replaces public.admin_list_products(integer) with
--        public.admin_list_products(p_limit integer default 50, p_offset integer default 0,
--                                   p_search text default null, p_is_active boolean default null,
--                                   p_category_id uuid default null)
--      (drop + create: PostgreSQL cannot add parameters to a function in place, and keeping the
--      old one next to the new one would make `admin_list_products(p_limit => 10)` ambiguous.)
--      Backwards compatible for callers: p_limit is still the FIRST parameter and keeps its
--      name and default, so `admin_list_products()`, `admin_list_products(50)` and
--      `admin_list_products(p_limit => 50)` behave as before. The result gains an `offset`
--      key; `total`, `limit` and `products` keep their meaning; each product element is still
--      exactly the same 16 public.products columns.
--   2. Adds public.admin_get_product(p_product_id uuid): one product, its category and its
--      variants.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No product, variant, category or inventory write path of any kind. No new table, column,
--     index, policy or table grant. No existing policy, grant, table or other function is
--     changed. Both functions are STABLE and contain only SELECTs.
--   * No index: see "INDEXES" below.
--
-- ACCESS MODEL (both functions)
--   SECURITY DEFINER, search_path = public, pg_temp, STABLE.
--   public/anon : EXECUTE revoked (permission denied, 42501).
--   authenticated: EXECUTE granted, but public.require_admin() runs FIRST and raises
--                  42501 / DETAIL not_authorised for anyone who is not an admin (staff,
--                  customers, forged claims, unknown users). service_role is unchanged; it has
--                  no auth.uid(), so it does not pass the gate. Arguments are examined only
--                  AFTER the gate, so a non-admin learns nothing about them.
--
-- admin_list_products(...)  ->  { total, limit, offset, products: [ ... ] }
--   p_limit        1..100, default 50.                p_offset  >= 0, default 0.
--   p_search       NULL / blank = no search. Trimmed, at most 100 characters. Case-insensitive
--                  literal SUBSTRING match (ILIKE) against: product name, slug, sku, brand,
--                  the category NAME, and the SKU of any of the product's variants.
--                  The % _ and \ characters in the input are escaped, so they match literally.
--                  The input is only ever used as a bound value, never concatenated into SQL.
--   p_is_active    NULL = all products, true = active only, false = inactive only.
--                  (products.is_active is NOT NULL, so there is no third state.)
--   p_category_id  NULL = any category (including uncategorised), otherwise products whose
--                  category_id equals it exactly. Sub-categories are NOT included. An unknown
--                  category id simply matches nothing.
--   Filters combine with AND; the search terms combine with OR.
--   `total` = number of products matching ALL filters (not just this page).
--   ORDER: name, slug, id (slug is unique, so fully deterministic). Count and page come from
--   ONE statement over ONE predicate, so they can never disagree.
--   Invalid limit / offset / over-long search -> P0001, DETAIL invalid_arguments.
--
-- admin_get_product(p_product_id)  ->  { product, category, variants: [ ... ] }
--   product   the same 16 public.products columns as the list.
--   category  { id, slug, name, parent_id, is_active } or JSON null when category_id is null.
--   variants  every row of public.product_variants WHERE product_id = p_product_id (inactive
--             ones included), ordered by position, name, id. Existing columns only: id,
--             product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity,
--             attributes, position, is_active, created_at, updated_at.
--   NULL id -> P0001 / invalid_arguments; unknown id -> P0001 / product_not_found
--   (both only after the admin gate).
--   No customer, order or profile data is touched.
--
-- INDEXES (none added)
--   The only query pattern that could want an index is `ilike '%term%'` over name / slug / sku /
--   brand / category name / variant sku. A leading-wildcard ILIKE cannot use a btree index; it
--   would need pg_trgm GIN indexes, i.e. a new extension plus several indexes. For a
--   supermarket catalogue (thousands of rows, admin-only, one call per keystroke-debounce) a
--   sequential scan is fast, so that is NOT justified now. The is_active and category filters
--   are already served by products_active_category_name_idx and products_category_id_idx, and
--   the variant lookup by product_variants_product_id_idx (product_id, position). Revisit only
--   if the catalogue grows to the tens of thousands.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null then
    raise exception 'Phase 6C.1A.2 precondition failed: Phase 6A functions are missing (require_admin(), is_admin()).';
  end if;

  if to_regprocedure('public.admin_list_products(integer)') is null then
    raise exception 'Phase 6C.1A.2 precondition failed: Phase 6C.1A.1 is not applied (admin_list_products(integer) missing).';
  end if;

  if to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is not null
     or to_regprocedure('public.admin_get_product(uuid)') is not null then
    raise exception 'Phase 6C.1A.2 appears to be applied already. Not running it twice.';
  end if;

  if (select count(*) from pg_proc
      where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') <> 1 then
    raise exception 'Phase 6C.1A.2 precondition failed: expected exactly one admin_list_products() overload (the 6C.1A.1 one).';
  end if;

  if to_regclass('public.products') is null
     or to_regclass('public.product_variants') is null
     or to_regclass('public.categories') is null then
    raise exception 'Phase 6C.1A.2 precondition failed: a catalogue table is missing.';
  end if;

  -- Columns this migration reads. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'slug', 'name', 'category_id', 'description', 'brand', 'sku',
                            'image_url', 'price_cents', 'compare_at_price_cents', 'unit_label',
                            'stock_quantity', 'in_stock', 'is_active', 'created_at', 'updated_at')) <> 16 then
    raise exception 'Phase 6C.1A.2 precondition failed: public.products does not have the expected 16 columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name in ('id', 'product_id', 'name', 'sku', 'price_cents', 'compare_at_price_cents',
                            'stock_quantity', 'attributes', 'position', 'is_active',
                            'created_at', 'updated_at')) <> 12 then
    raise exception 'Phase 6C.1A.2 precondition failed: public.product_variants does not have the expected 12 columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'categories'
        and column_name in ('id', 'slug', 'name', 'parent_id', 'is_active')) <> 5 then
    raise exception 'Phase 6C.1A.2 precondition failed: public.categories does not have the expected columns.';
  end if;

  -- Browser roles must not be able to write the catalogue already (this migration must not be
  -- the thing that finds out, and must never widen it).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.1A.2 precondition failed: a browser role can already write a catalogue table.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_list_products()  (replaces the 6C.1A.1 one-argument version)
-- =============================================================================
drop function public.admin_list_products(integer);

create function public.admin_list_products(
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null,
  p_is_active boolean default null,
  p_category_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_bs constant text := chr(92);               -- one backslash; avoids string-literal escaping rules
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pattern text;
  v_total bigint;
  v_rows jsonb;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0
     or (v_search is not null and char_length(v_search) > 100) then
    raise exception 'Invalid product list arguments (limit 1-100, offset >= 0, search up to 100 characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Literal substring pattern: escape the escape character first, then the two wildcards.
  if v_search is not null then
    v_pattern := '%'
      || replace(replace(replace(v_search, v_bs, v_bs || v_bs), '%', v_bs || '%'), '_', v_bs || '_')
      || '%';
  end if;

  -- One statement, one predicate: the count and the page cannot disagree.
  with matched as (
    select p.id, p.name, p.slug
    from public.products p
    left join public.categories c on c.id = p.category_id
    where (p_is_active is null or p.is_active = p_is_active)
      and (p_category_id is null or p.category_id = p_category_id)
      and (v_pattern is null
           or p.name ilike v_pattern
           or p.slug ilike v_pattern
           or p.sku ilike v_pattern
           or p.brand ilike v_pattern
           or c.name ilike v_pattern
           or exists (select 1 from public.product_variants v
                      where v.product_id = p.id and v.sku ilike v_pattern))
  ),
  page as (
    select m.id, m.name, m.slug,
           jsonb_build_object(
             'id', p.id,
             'slug', p.slug,
             'name', p.name,
             'category_id', p.category_id,
             'description', p.description,
             'brand', p.brand,
             'sku', p.sku,
             'image_url', p.image_url,
             'price_cents', p.price_cents,
             'compare_at_price_cents', p.compare_at_price_cents,
             'unit_label', p.unit_label,
             'stock_quantity', p.stock_quantity,
             'in_stock', p.in_stock,
             'is_active', p.is_active,
             'created_at', p.created_at,
             'updated_at', p.updated_at
           ) as j
    from (select mm.id, mm.name, mm.slug
          from matched mm
          order by mm.name, mm.slug, mm.id
          limit p_limit offset p_offset) m
    join public.products p on p.id = m.id
  )
  select (select count(*) from matched),
         coalesce((select jsonb_agg(pg.j order by pg.name, pg.slug, pg.id) from page pg), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'products', v_rows
  );
end;
$$;

comment on function public.admin_list_products(integer, integer, text, boolean, uuid) is
  'Phase 6C.1A.2 (extends 6C.1A.1). Admin-only, read-only product list: search, active and category filters, limit 1-100 / offset >= 0, order name, slug, id. Gate: require_admin().';

revoke all on function public.admin_list_products(integer, integer, text, boolean, uuid)
  from public, anon, authenticated;
grant execute on function public.admin_list_products(integer, integer, text, boolean, uuid)
  to authenticated;

-- =============================================================================
-- 2. admin_get_product()
-- =============================================================================
create function public.admin_get_product(p_product_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_product jsonb;
  v_category_id uuid;
  v_category jsonb;
  v_variants jsonb;
begin
  -- The gate runs before the argument is examined.
  perform public.require_admin();

  if p_product_id is null then
    raise exception 'Invalid product argument.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select
    p.category_id,
    jsonb_build_object(
      'id', p.id,
      'slug', p.slug,
      'name', p.name,
      'category_id', p.category_id,
      'description', p.description,
      'brand', p.brand,
      'sku', p.sku,
      'image_url', p.image_url,
      'price_cents', p.price_cents,
      'compare_at_price_cents', p.compare_at_price_cents,
      'unit_label', p.unit_label,
      'stock_quantity', p.stock_quantity,
      'in_stock', p.in_stock,
      'is_active', p.is_active,
      'created_at', p.created_at,
      'updated_at', p.updated_at)
  into v_category_id, v_product
  from public.products p
  where p.id = p_product_id;

  if v_product is null then
    raise exception 'That product could not be found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  if v_category_id is not null then
    select jsonb_build_object(
             'id', c.id,
             'slug', c.slug,
             'name', c.name,
             'parent_id', c.parent_id,
             'is_active', c.is_active)
    into v_category
    from public.categories c
    where c.id = v_category_id;
  end if;

  select coalesce(jsonb_agg(r.j order by r.position, r.name, r.id), '[]'::jsonb)
  into v_variants
  from (
    select v.id, v.name, v.position,
           jsonb_build_object(
             'id', v.id,
             'product_id', v.product_id,
             'name', v.name,
             'sku', v.sku,
             'price_cents', v.price_cents,
             'compare_at_price_cents', v.compare_at_price_cents,
             'stock_quantity', v.stock_quantity,
             'attributes', v.attributes,
             'position', v.position,
             'is_active', v.is_active,
             'created_at', v.created_at,
             'updated_at', v.updated_at) as j
    from public.product_variants v
    where v.product_id = p_product_id
  ) r;

  return jsonb_build_object(
    'product', v_product,
    'category', v_category,          -- SQL NULL -> JSON null when the product has no category
    'variants', v_variants
  );
end;
$$;

comment on function public.admin_get_product(uuid) is
  'Phase 6C.1A.2. Admin-only, read-only product detail: product, category, variants (position, name, id). Gate: require_admin().';

revoke all on function public.admin_get_product(uuid) from public, anon, authenticated;
grant execute on function public.admin_get_product(uuid) to authenticated;

-- =============================================================================
-- 3. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn text;
begin
  -- The old one-argument overload is gone and exactly one admin_list_products exists.
  if to_regprocedure('public.admin_list_products(integer)') is not null
     or (select count(*) from pg_proc
         where pronamespace = 'public'::regnamespace and proname = 'admin_list_products') <> 1 then
    raise exception 'Phase 6C.1A.2 self-check failed: admin_list_products must exist exactly once, with the new signature.';
  end if;

  foreach v_fn in array array['public.admin_list_products(integer,integer,text,boolean,uuid)',
                              'public.admin_get_product(uuid)'] loop
    if exists (
      select 1 from pg_proc p
      where p.oid = v_fn::regprocedure
        and (not p.prosecdef or p.provolatile <> 's'
             or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
    ) then
      raise exception 'Phase 6C.1A.2 self-check failed: % is not STABLE SECURITY DEFINER with a pinned search_path.', v_fn;
    end if;

    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'Phase 6C.1A.2 self-check failed: % privileges are wrong.', v_fn;
    end if;

    -- PUBLIC (the pseudo-role) must not hold EXECUTE either.
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'Phase 6C.1A.2 self-check failed: PUBLIC can execute %.', v_fn;
    end if;

    if position('public.require_admin()' in
                (select prosrc from pg_proc where oid = v_fn::regprocedure)) = 0 then
      raise exception 'Phase 6C.1A.2 self-check failed: % does not call require_admin().', v_fn;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6C.1A.2 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- No catalogue write privilege or policy exists (and none was introduced).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.categories')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.1A.2 self-check failed: a browser role can write a catalogue table.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6C.1A.2 self-check failed: a write policy exists on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass,
                    'public.categories'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6C.1A.2 self-check failed: row level security is off on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6C.1A.2 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
