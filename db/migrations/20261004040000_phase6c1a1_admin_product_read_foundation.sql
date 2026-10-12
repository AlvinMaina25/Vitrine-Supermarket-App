-- =============================================================================
-- PHASE 6C.1A.1 - Admin product read foundation.
--
-- STATUS: written and run only against a throwaway local PostgreSQL 16 with a Supabase-style
-- shim (see the report). NOT applied to the Phase-5 development Supabase database.
--
-- Apply ONCE, after 20261004030000_phase6b2_admin_order_actions.sql. Do not edit or re-run any
-- older migration. One transaction: if any statement or the final self-check fails, nothing is
-- applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   public.admin_list_products(p_limit integer default 50)
--     Admin-only, read-only. Returns rows of public.products, in the order described below, as one
--     jsonb document: { total, limit, products: [ ... ] }.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No search, filter, offset/paging, variants, categories join or inventory logic.
--   * No product, variant, category or SKU write path of any kind. No new table, column,
--     index, policy or table grant. No existing policy, grant or function is changed.
--     (Phase 6A already lets admins SELECT every product, including inactive ones, through
--     the "Products: admin read all" policy; this function does not rely on that policy
--     because it is SECURITY DEFINER, and it is gated by require_admin() instead.)
--
-- RETURNED COLUMNS (the actual public.products columns, listed explicitly so a column added
-- later is never exposed by accident): id, slug, name, category_id, description, brand, sku,
-- image_url, price_cents, compare_at_price_cents, unit_label, stock_quantity, in_stock,
-- is_active, created_at, updated_at.
--
-- ORDERING: name (case-sensitive text order of the database collation), then slug, then id.
-- slug is unique, so the order is fully deterministic.
--
-- p_limit: 1..100, default 50. NULL or out of range raises P0001 / invalid_arguments, but only
-- AFTER the admin gate, so a non-admin learns nothing about the arguments.
-- `total` is the number of ALL products, so a caller can tell the list was truncated.
--
-- ACCESS MODEL
--   anon          : EXECUTE revoked (permission denied, 42501).
--   authenticated : EXECUTE granted, but require_admin() runs FIRST and raises
--                   42501 / not_authorised for anyone who is not an admin (staff, customers,
--                   users with forged claims).
--   service_role  : unchanged; it does not pass require_admin() (no auth.uid()).
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_get_order(uuid)') is null
     or to_regprocedure('public.is_admin(uuid)') is null then
    raise exception 'Phase 6C.1A.1 precondition failed: Phase 6A / 6B.1 functions are missing (require_admin(), admin_get_order(), is_admin()).';
  end if;

  if to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)') is null then
    raise exception 'Phase 6C.1A.1 precondition failed: Phase 6B.2 is not applied (admin_set_order_status() missing).';
  end if;

  if to_regclass('public.products') is null then
    raise exception 'Phase 6C.1A.1 precondition failed: public.products is missing.';
  end if;

  -- Columns this migration reads. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'slug', 'name', 'category_id', 'description', 'brand', 'sku',
                            'image_url', 'price_cents', 'compare_at_price_cents', 'unit_label',
                            'stock_quantity', 'in_stock', 'is_active', 'created_at', 'updated_at')) <> 16 then
    raise exception 'Phase 6C.1A.1 precondition failed: public.products does not have the expected 16 columns.';
  end if;

  -- Browser roles must not be able to write products already (this migration must not be the
  -- thing that finds out, and must never widen it).
  if has_table_privilege('authenticated', 'public.products', 'INSERT')
     or has_table_privilege('authenticated', 'public.products', 'UPDATE')
     or has_table_privilege('authenticated', 'public.products', 'DELETE')
     or has_any_column_privilege('authenticated', 'public.products', 'INSERT')
     or has_any_column_privilege('authenticated', 'public.products', 'UPDATE')
     or has_table_privilege('anon', 'public.products', 'INSERT')
     or has_table_privilege('anon', 'public.products', 'UPDATE')
     or has_table_privilege('anon', 'public.products', 'DELETE')
     or has_any_column_privilege('anon', 'public.products', 'INSERT')
     or has_any_column_privilege('anon', 'public.products', 'UPDATE') then
    raise exception 'Phase 6C.1A.1 precondition failed: a browser role can already write public.products.';
  end if;

  if to_regprocedure('public.admin_list_products(integer)') is not null then
    raise exception 'Phase 6C.1A.1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_list_products()
-- =============================================================================
create or replace function public.admin_list_products(p_limit integer default 50)
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
  -- The gate runs before the argument is examined.
  perform public.require_admin();

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Invalid product list arguments (limit 1-100).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select count(*) into v_total from public.products;

  select coalesce(jsonb_agg(r.j order by r.name, r.slug, r.id), '[]'::jsonb)
  into v_rows
  from (
    select
      p.id, p.slug, p.name,
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
    from public.products p
    order by p.name, p.slug, p.id
    limit p_limit
  ) r;

  return jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'products', v_rows
  );
end;
$$;

comment on function public.admin_list_products(integer) is
  'Phase 6C.1A.1. Admin-only, read-only product list (name, slug, id order; limit 1-100). Gate: require_admin().';

revoke all on function public.admin_list_products(integer) from public, anon, authenticated;
grant execute on function public.admin_list_products(integer) to authenticated;

-- =============================================================================
-- 2. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn constant text := 'public.admin_list_products(integer)';
begin
  if exists (
    select 1 from pg_proc p
    where p.oid = v_fn::regprocedure
      and (not p.prosecdef or p.provolatile <> 's'
           or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')
  ) then
    raise exception 'Phase 6C.1A.1 self-check failed: admin_list_products is not STABLE SECURITY DEFINER with a pinned search_path.';
  end if;

  if has_function_privilege('anon', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
    raise exception 'Phase 6C.1A.1 self-check failed: admin_list_products privileges are wrong.';
  end if;

  -- PUBLIC (the pseudo-role) must not hold EXECUTE either.
  if exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'Phase 6C.1A.1 self-check failed: PUBLIC can execute admin_list_products.';
  end if;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6C.1A.1 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- No broad product mutation privilege was introduced.
  if has_table_privilege('authenticated', 'public.products', 'INSERT')
     or has_table_privilege('authenticated', 'public.products', 'UPDATE')
     or has_table_privilege('authenticated', 'public.products', 'DELETE')
     or has_any_column_privilege('authenticated', 'public.products', 'INSERT')
     or has_any_column_privilege('authenticated', 'public.products', 'UPDATE')
     or has_table_privilege('anon', 'public.products', 'INSERT')
     or has_table_privilege('anon', 'public.products', 'UPDATE')
     or has_table_privilege('anon', 'public.products', 'DELETE')
     or has_any_column_privilege('anon', 'public.products', 'INSERT')
     or has_any_column_privilege('anon', 'public.products', 'UPDATE') then
    raise exception 'Phase 6C.1A.1 self-check failed: a browser role can write public.products.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6C.1A.1 self-check failed: a write policy exists on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass,
                    'public.categories'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6C.1A.1 self-check failed: row level security is off on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6C.1A.1 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
