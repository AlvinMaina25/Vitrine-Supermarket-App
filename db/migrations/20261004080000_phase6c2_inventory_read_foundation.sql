-- =============================================================================
-- PHASE 6C.2.1 - Admin inventory READ foundation (READ ONLY).
--
-- STATUS: written, NOT APPLIED to any database. It has not been executed anywhere yet (no
-- PostgreSQL was available where it was written). Review it, then apply it ONCE to the
-- dedicated Phase-5 development database only.
--
-- Apply ONCE, after 20261004070000_phase6c1b2_admin_product_activation_variants.sql. Do not edit
-- or re-run any older migration. One transaction: if any statement or the final self-check
-- fails, nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THE SCHEMA ACTUALLY HAS (inspected, nothing assumed)
--   public.products          stock_quantity integer not null (>= 0), in_stock boolean not null,
--                            is_active boolean not null, sku (unique when not null), price_cents.
--   public.product_variants  stock_quantity integer not null (>= 0), is_active boolean not null,
--                            sku (unique when not null), price_cents, position. It has NO in_stock.
--   Orders consume stock at ONE of two levels: a line with a variant_id uses the variant's
--   stock_quantity; a line without one uses the product's stock_quantity and in_stock. So there
--   are two independent kinds of stock-bearing unit: a PRODUCT unit and a VARIANT unit.
--   There is NO low-stock threshold / reorder level column anywhere (Phase 6A's dashboard takes a
--   caller-supplied number; it is not stored). There is NO inventory table.
--
-- WHAT THIS DOES
--   1. public.admin_list_inventory(p_limit, p_offset, p_search, p_is_active, p_product_id)
--   2. public.admin_get_inventory(p_product_id, p_variant_id)
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No write of any kind: no stock adjustment, no in_stock / is_active change, no product,
--     variant, order, delivery or payment write. Both functions are STABLE and contain only SELECTs.
--   * No new table, column, index, policy, trigger or table grant. No existing policy, grant,
--     table or function is changed. The browser still has no table access it did not have before;
--     the reads happen inside the SECURITY DEFINER functions.
--   * No low-stock threshold and no low-stock / alert logic: no such column exists, so none is
--     invented. (When the owner decides on a threshold, that is its own migration.)
--   * No derived "out of stock" / "available" state: the rows expose the stored facts only.
--
-- INVENTORY ROW (identical shape in the list and in the detail; always these 14 keys)
--   kind               'product' | 'variant'. A product unit is the product's own stock (used by
--                      order lines without a variant); a variant unit is one variant's stock.
--                      Every product has exactly one product unit, even when it has variants.
--   product_id         the product (for both kinds)
--   variant_id         the variant id, or null for a product unit
--   sku                the unit's own sku (products.sku or product_variants.sku); may be null
--   product_name, product_slug
--   variant_name       null for a product unit
--   price_cents        the unit's own price (products.price_cents or product_variants.price_cents)
--   stock_quantity     the stored quantity of this unit
--   in_stock           products.in_stock for a product unit; NULL for a variant unit (the table
--                      has no such column, so none is invented)
--   is_active          the unit's own is_active
--   product_is_active  the parent product's is_active (for a product unit: same as is_active)
--   variant_count      number of variants of the product for a product unit; null for a variant unit
--   updated_at         the unit's own updated_at
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
-- admin_list_inventory(...)  ->  { total, limit, offset, inventory: [ <row>, ... ] }
--   p_limit       1..100, default 50.        p_offset  >= 0, default 0.
--   p_search      NULL / blank = no search. Trimmed, at most 100 characters. Case-insensitive
--                 literal SUBSTRING match (ILIKE); % _ and \ in the input are escaped, and the
--                 input is only ever a bound value, never concatenated into SQL.
--                   product unit : product name, slug, sku, brand.
--                   variant unit : variant name, variant sku, and its PARENT product's name,
--                                  slug, sku, brand (searching a product name lists its variants).
--   p_is_active   NULL = all, true / false = rows whose OWN is_active equals it. (A variant can be
--                 active under an inactive product; product_is_active is returned to show that.)
--   p_product_id  NULL = all products, otherwise only that product's units (its product unit
--                 and its variant units). An unknown id simply matches nothing.
--   Filters combine with AND. `total` = number of rows matching ALL filters (not just this page).
--   ORDER: product name, product slug, product id, product unit before variant units, variant
--   position, variant name, variant id: fully deterministic. The count and the page come from
--   ONE statement over ONE predicate, so they can never disagree.
--   Invalid limit / offset / over-long search -> P0001, DETAIL invalid_arguments.
--
-- admin_get_inventory(p_product_id uuid, p_variant_id uuid default null)
--   ->  { inventory: <row>, product: { id, slug, name, brand, unit_label, category_id, is_active } }
--   p_variant_id NULL  = the product's own (product) unit.
--   p_variant_id given = that variant's unit; it must belong to p_product_id.
--   NULL product id -> P0001 / invalid_arguments; unknown product -> P0001 / product_not_found;
--   unknown variant, or a variant of a different product -> P0001 / variant_not_found
--   (all only after the admin gate). No customer, order or profile data is touched.
--
-- INDEXES (none added)
--   The list is a full pass over a supermarket catalogue (thousands of rows, admin only);
--   a leading-wildcard ILIKE cannot use a btree index and pg_trgm is not justified here.
--   Lookups by id use the primary keys; variants by product use product_variants_product_id_idx.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null then
    raise exception 'Phase 6C.2.1 precondition failed: Phase 6A functions are missing (require_admin(), is_admin()).';
  end if;

  if to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is null
     or to_regprocedure('public.admin_get_product(uuid)') is null then
    raise exception 'Phase 6C.2.1 precondition failed: Phase 6C.1A is not applied (admin_list_products / admin_get_product missing).';
  end if;

  if (select count(*) from pg_proc
      where pronamespace = 'public'::regnamespace
        and proname in ('admin_create_product', 'admin_update_product')) <> 2 then
    raise exception 'Phase 6C.2.1 precondition failed: Phase 6C.1B.1 is not applied (admin_create_product / admin_update_product missing).';
  end if;

  if (select count(*) from pg_proc
      where pronamespace = 'public'::regnamespace
        and proname in ('admin_set_product_active', 'admin_create_product_variant',
                        'admin_update_product_variant')) <> 3 then
    raise exception 'Phase 6C.2.1 precondition failed: Phase 6C.1B.2 is not applied (admin_set_product_active / admin_create_product_variant / admin_update_product_variant missing).';
  end if;

  if to_regprocedure('public.admin_list_inventory(integer,integer,text,boolean,uuid)') is not null
     or to_regprocedure('public.admin_get_inventory(uuid,uuid)') is not null then
    raise exception 'Phase 6C.2.1 appears to be applied already. Not running it twice.';
  end if;

  if to_regclass('public.products') is null or to_regclass('public.product_variants') is null then
    raise exception 'Phase 6C.2.1 precondition failed: a catalogue table is missing.';
  end if;

  -- Columns this migration reads. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'slug', 'name', 'brand', 'sku', 'unit_label', 'category_id',
                            'price_cents', 'stock_quantity', 'in_stock', 'is_active', 'updated_at')) <> 12 then
    raise exception 'Phase 6C.2.1 precondition failed: public.products does not have the expected inventory columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name in ('id', 'product_id', 'name', 'sku', 'price_cents', 'stock_quantity',
                            'position', 'is_active', 'updated_at')) <> 9 then
    raise exception 'Phase 6C.2.1 precondition failed: public.product_variants does not have the expected inventory columns.';
  end if;

  -- Assumptions the row shape relies on: variants have no in_stock column; no threshold column.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'product_variants' and column_name = 'in_stock') then
    raise exception 'Phase 6C.2.1 precondition failed: product_variants now has an in_stock column; review the inventory row shape before applying.';
  end if;

  -- Browser roles must not be able to write the catalogue already (this migration must not be
  -- the thing that finds out, and must never widen it).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.1 precondition failed: a browser role can already write a catalogue table.';
  end if;

  -- Remember how many tables exist, so the self-check can prove none was added.
  perform set_config('p6c2.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text,
    true);
end
$pre$;

-- =============================================================================
-- 1. admin_list_inventory()
-- =============================================================================
create function public.admin_list_inventory(
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null,
  p_is_active boolean default null,
  p_product_id uuid default null
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
    raise exception 'Invalid inventory list arguments (limit 1-100, offset >= 0, search up to 100 characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Literal substring pattern: escape the escape character first, then the two wildcards.
  if v_search is not null then
    v_pattern := '%'
      || replace(replace(replace(v_search, v_bs, v_bs || v_bs), '%', v_bs || '%'), '_', v_bs || '_')
      || '%';
  end if;

  -- One statement, one predicate: the count and the page cannot disagree.
  with units as (
    select 'product'::text as kind, 0 as kind_rank,
           p.id as product_id, null::uuid as variant_id,
           p.sku as sku, p.name as product_name, p.slug as product_slug,
           null::text as variant_name, 0 as var_position,
           p.price_cents as price_cents, p.stock_quantity as stock_quantity,
           p.in_stock as in_stock, p.is_active as is_active,
           p.is_active as product_is_active, p.updated_at as updated_at,
           (v_pattern is null
            or p.name ilike v_pattern or p.slug ilike v_pattern
            or p.sku ilike v_pattern or p.brand ilike v_pattern) as hit
    from public.products p
    union all
    select 'variant'::text, 1,
           p.id, v.id,
           v.sku, p.name, p.slug,
           v.name, v.position,
           v.price_cents, v.stock_quantity,
           null::boolean, v.is_active,
           p.is_active, v.updated_at,
           (v_pattern is null
            or v.name ilike v_pattern or v.sku ilike v_pattern
            or p.name ilike v_pattern or p.slug ilike v_pattern
            or p.sku ilike v_pattern or p.brand ilike v_pattern)
    from public.product_variants v
    join public.products p on p.id = v.product_id
  ),
  matched as (
    select u.*
    from units u
    where u.hit
      and (p_is_active is null or u.is_active = p_is_active)
      and (p_product_id is null or u.product_id = p_product_id)
  ),
  ranked as (
    select m.*,
           row_number() over (
             order by m.product_name, m.product_slug, m.product_id, m.kind_rank,
                      m.var_position, coalesce(m.variant_name, ''),
                      coalesce(m.variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
           ) as rn
    from matched m
  ),
  page as (
    select r.*
    from ranked r
    where r.rn > p_offset::bigint
      and r.rn <= p_offset::bigint + p_limit::bigint
  )
  select (select count(*) from matched),
         coalesce((
           select jsonb_agg(
                    jsonb_build_object(
                      'kind', pg.kind,
                      'product_id', pg.product_id,
                      'variant_id', pg.variant_id,
                      'sku', pg.sku,
                      'product_name', pg.product_name,
                      'product_slug', pg.product_slug,
                      'variant_name', pg.variant_name,
                      'price_cents', pg.price_cents,
                      'stock_quantity', pg.stock_quantity,
                      'in_stock', pg.in_stock,
                      'is_active', pg.is_active,
                      'product_is_active', pg.product_is_active,
                      'variant_count', case when pg.kind = 'product'
                                            then (select count(*) from public.product_variants x
                                                  where x.product_id = pg.product_id)
                                       end,
                      'updated_at', pg.updated_at)
                    order by pg.rn)
           from page pg), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'inventory', v_rows
  );
end;
$$;

comment on function public.admin_list_inventory(integer, integer, text, boolean, uuid) is
  'Phase 6C.2.1. Admin-only, read-only inventory list: one row per product (own stock) and per variant; search, is_active and product filters, limit 1-100 / offset >= 0, deterministic order. Gate: require_admin().';

revoke all on function public.admin_list_inventory(integer, integer, text, boolean, uuid)
  from public, anon, authenticated;
grant execute on function public.admin_list_inventory(integer, integer, text, boolean, uuid)
  to authenticated;

-- =============================================================================
-- 2. admin_get_inventory()
-- =============================================================================
create function public.admin_get_inventory(
  p_product_id uuid,
  p_variant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_prod public.products%rowtype;
  v_var public.product_variants%rowtype;
  v_inventory jsonb;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_product_id is null then
    raise exception 'Invalid inventory argument.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_prod from public.products p where p.id = p_product_id;
  if not found then
    raise exception 'That product could not be found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  if p_variant_id is null then
    v_inventory := jsonb_build_object(
      'kind', 'product',
      'product_id', v_prod.id,
      'variant_id', null,
      'sku', v_prod.sku,
      'product_name', v_prod.name,
      'product_slug', v_prod.slug,
      'variant_name', null,
      'price_cents', v_prod.price_cents,
      'stock_quantity', v_prod.stock_quantity,
      'in_stock', v_prod.in_stock,
      'is_active', v_prod.is_active,
      'product_is_active', v_prod.is_active,
      'variant_count', (select count(*) from public.product_variants x where x.product_id = v_prod.id),
      'updated_at', v_prod.updated_at);
  else
    select * into v_var
    from public.product_variants v
    where v.id = p_variant_id and v.product_id = v_prod.id;
    if not found then
      raise exception 'That variant could not be found for this product.'
        using errcode = 'P0001', detail = 'variant_not_found';
    end if;

    v_inventory := jsonb_build_object(
      'kind', 'variant',
      'product_id', v_prod.id,
      'variant_id', v_var.id,
      'sku', v_var.sku,
      'product_name', v_prod.name,
      'product_slug', v_prod.slug,
      'variant_name', v_var.name,
      'price_cents', v_var.price_cents,
      'stock_quantity', v_var.stock_quantity,
      'in_stock', null,                    -- product_variants has no in_stock column
      'is_active', v_var.is_active,
      'product_is_active', v_prod.is_active,
      'variant_count', null,
      'updated_at', v_var.updated_at);
  end if;

  return jsonb_build_object(
    'inventory', v_inventory,
    'product', jsonb_build_object(
      'id', v_prod.id,
      'slug', v_prod.slug,
      'name', v_prod.name,
      'brand', v_prod.brand,
      'unit_label', v_prod.unit_label,
      'category_id', v_prod.category_id,
      'is_active', v_prod.is_active)
  );
end;
$$;

comment on function public.admin_get_inventory(uuid, uuid) is
  'Phase 6C.2.1. Admin-only, read-only inventory detail of one stock unit: the product itself (variant id null) or one of its variants. Gate: require_admin().';

revoke all on function public.admin_get_inventory(uuid, uuid) from public, anon, authenticated;
grant execute on function public.admin_get_inventory(uuid, uuid) to authenticated;

-- =============================================================================
-- 3. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn text;
begin
  foreach v_fn in array array['public.admin_list_inventory(integer,integer,text,boolean,uuid)',
                              'public.admin_get_inventory(uuid,uuid)'] loop
    if exists (
      select 1 from pg_proc p
      where p.oid = v_fn::regprocedure
        and (not p.prosecdef or p.provolatile <> 's'
             or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
    ) then
      raise exception 'Phase 6C.2.1 self-check failed: % is not STABLE SECURITY DEFINER with a pinned search_path.', v_fn;
    end if;

    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'Phase 6C.2.1 self-check failed: % privileges are wrong.', v_fn;
    end if;

    -- PUBLIC (the pseudo-role) must not hold EXECUTE either.
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'Phase 6C.2.1 self-check failed: PUBLIC can execute %.', v_fn;
    end if;

    if position('public.require_admin()' in
                (select prosrc from pg_proc where oid = v_fn::regprocedure)) = 0 then
      raise exception 'Phase 6C.2.1 self-check failed: % does not call require_admin().', v_fn;
    end if;

    -- Read-only: the body contains no write statement.
    if (select prosrc from pg_proc where oid = v_fn::regprocedure)
         ~* '(insert\s+into|update\s+\S+\s+set|delete\s+from|truncate)' then
      raise exception 'Phase 6C.2.1 self-check failed: % contains a write statement.', v_fn;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6C.2.1 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- Exactly one overload of each.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
        and proname = 'admin_list_inventory') <> 1
     or (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
           and proname = 'admin_get_inventory') <> 1 then
    raise exception 'Phase 6C.2.1 self-check failed: each inventory function must exist exactly once.';
  end if;

  -- No table was added; no catalogue write privilege or policy exists (and none was introduced).
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from current_setting('p6c2.rel_count', true) then
    raise exception 'Phase 6C.2.1 self-check failed: the number of public tables changed.';
  end if;

  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.1 self-check failed: a browser role can write a catalogue table.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6C.2.1 self-check failed: a write policy exists on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6C.2.1 self-check failed: row level security is off on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6C.2.1 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
