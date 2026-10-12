-- =============================================================================
-- PHASE 6C.1B.1 - Admin product creation + update foundation.
--
-- STATUS: written, NOT applied to any Supabase database (see the report). The SQL test
-- db/tests/phase6c1b1_admin_product_create_update.test.sql has not been run against a real
-- PostgreSQL unless the report says so.
--
-- Apply ONCE, after 20261004050000_phase6c1a2_admin_product_search_details.sql. Do not edit or
-- re-run any older migration. One transaction: if any statement or the final self-check fails,
-- nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   public.admin_create_product(...)   Admin-only. Inserts ONE product.
--   public.admin_update_product(...)   Admin-only. Updates ONLY the catalogue fields listed below.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No table privilege, policy, trigger, index, column or constraint is added or changed.
--     Browser roles still have NO INSERT / UPDATE / DELETE on public.products (checked below).
--   * No stock, in_stock, is_active or image_url handling, no variants, no categories CRUD,
--     no deletion, no inventory history. Those belong to later phases.
--
-- PRODUCT FIELDS IN THE CONTRACT (public.products columns, nothing invented)
--   name, slug, category_id, description, brand, sku, price_cents, compare_at_price_cents,
--   unit_label.
-- COLUMNS THAT ARE NOT WRITABLE THROUGH THESE FUNCTIONS
--   stock_quantity, in_stock, is_active  -> inventory / activation (later phases)
--   image_url                           -> image handling (later phase)
--   id, created_at, updated_at          -> system columns
--   On CREATE the excluded columns are simply not mentioned in the INSERT, so the table's own
--   column defaults apply (stock_quantity 0, in_stock true, is_active true, image_url null).
--   On UPDATE they are never touched. admin_update_product() REJECTS any key it does not know.
--
-- admin_create_product(p_name, p_slug, p_price_cents, p_category_id, p_description, p_brand,
--                      p_sku, p_unit_label, p_compare_at_price_cents)  ->  { "product": {...} }
--   Required: p_name, p_slug, p_price_cents. Everything else defaults to null.
--
-- admin_update_product(p_product_id uuid, p_changes jsonb)            ->  { "product": {...} }
--   p_changes is a PATCH object. A key that is ABSENT leaves that column exactly as it is. A key
--   present with a value sets it. A key present with JSON null CLEARS it, but only for the
--   nullable columns (category_id, description, brand, sku, unit_label, compare_at_price_cents);
--   name, slug and price_cents cannot be null. This is how "not supplied" and "set to null" are
--   told apart. Allowed keys: name, slug, category_id, description, brand, sku, price_cents,
--   compare_at_price_cents, unit_label. Any other key (stock_quantity, in_stock, is_active,
--   image_url, id, ...) -> P0001 / unsupported_field, and nothing is written. `{}` is rejected.
--
-- VALIDATION (after the admin gate, so a non-admin learns nothing about the rules)
--   name         required, trimmed, 1-200 chars, no control characters
--   slug         required, trimmed, 1-120 chars, lower-case kebab: ^[a-z0-9]+(-[a-z0-9]+)*$
--                (NOT silently lower-cased: an invalid slug is rejected)
--   price_cents  required, whole number 0 .. 2147483647 (the column is integer, check >= 0)
--   compare_at   null, or a whole number >= the (new) price (products_compare_at_valid)
--   category_id  null, or the id of an existing category (inactive categories are accepted)
--   description  <= 4000 chars;  brand <= 100;  unit_label <= 40  (brand / unit_label: no control chars)
--   sku          1-64 chars, ^[A-Za-z0-9][A-Za-z0-9._/-]*$
--   Optional text that is blank after trimming is stored as NULL.
--   Bad input -> P0001 / DETAIL invalid_arguments (message names the field).
--   Unknown category -> P0001 / category_not_found.   Unknown product -> P0001 / product_not_found.
--   Duplicate slug / sku -> 23505 / DETAIL slug_taken / sku_taken (the existing unique indexes
--   products_slug_key / products_sku_key decide; nothing is pre-empted or bypassed).
--
-- ACCESS MODEL
--   anon          : EXECUTE revoked (permission denied, 42501).
--   authenticated : EXECUTE granted, but require_admin() runs FIRST and raises
--                   42501 / not_authorised for anyone who is not an admin (staff, customers,
--                   users with forged claims, signed-out callers).
--   service_role  : unchanged; it does not pass require_admin() (no auth.uid()).
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null
     or to_regprocedure('public.admin_get_order(uuid)') is null then
    raise exception 'Phase 6C.1B.1 precondition failed: Phase 6A / 6B.1 functions are missing (require_admin(), is_admin(), admin_get_order()).';
  end if;

  if to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)') is null then
    raise exception 'Phase 6C.1B.1 precondition failed: Phase 6B.2 is not applied (admin_set_order_status() missing).';
  end if;

  if to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is null
     or to_regprocedure('public.admin_get_product(uuid)') is null then
    raise exception 'Phase 6C.1B.1 precondition failed: Phase 6C.1A.1 / 6C.1A.2 are not applied (admin_list_products() / admin_get_product() missing).';
  end if;

  if to_regclass('public.products') is null or to_regclass('public.categories') is null then
    raise exception 'Phase 6C.1B.1 precondition failed: public.products / public.categories are missing.';
  end if;

  -- Columns this migration reads or writes. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'slug', 'name', 'category_id', 'description', 'brand', 'sku',
                            'image_url', 'price_cents', 'compare_at_price_cents', 'unit_label',
                            'stock_quantity', 'in_stock', 'is_active', 'created_at', 'updated_at')) <> 16 then
    raise exception 'Phase 6C.1B.1 precondition failed: public.products does not have the expected 16 columns.';
  end if;

  -- The duplicate handling below recognises the violation by these index names.
  if to_regclass('public.products_slug_key') is null or to_regclass('public.products_sku_key') is null then
    raise exception 'Phase 6C.1B.1 precondition failed: the unique indexes products_slug_key / products_sku_key are missing.';
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and conname = 'products_price_nonnegative')
     or not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and conname = 'products_compare_at_valid') then
    raise exception 'Phase 6C.1B.1 precondition failed: the products price constraints are missing.';
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
    raise exception 'Phase 6C.1B.1 precondition failed: a browser role can already write public.products.';
  end if;

  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('admin_create_product', 'admin_update_product')) then
    raise exception 'Phase 6C.1B.1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_create_product()
-- =============================================================================
create function public.admin_create_product(
  p_name text,
  p_slug text,
  p_price_cents integer,
  p_category_id uuid default null,
  p_description text default null,
  p_brand text default null,
  p_sku text default null,
  p_unit_label text default null,
  p_compare_at_price_cents integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_ws constant text := E' \t\r\n';
  v_name text;
  v_slug text;
  v_description text;
  v_brand text;
  v_sku text;
  v_unit text;
  v_row public.products;
  v_constraint text;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  v_name := btrim(coalesce(p_name, ''), c_ws);
  if char_length(v_name) not between 1 and 200 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Invalid product name (1-200 characters, no control characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_slug := btrim(coalesce(p_slug, ''), c_ws);
  if char_length(v_slug) not between 1 and 120 or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'Invalid product slug (1-120 characters, lower-case letters, digits and single hyphens).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_price_cents is null or p_price_cents < 0 then
    raise exception 'Invalid price_cents (required, a whole number of cents >= 0).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_compare_at_price_cents is not null and p_compare_at_price_cents < p_price_cents then
    raise exception 'Invalid compare_at_price_cents (must be null or >= price_cents).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_description := nullif(btrim(p_description, c_ws), '');
  if v_description is not null and char_length(v_description) > 4000 then
    raise exception 'Invalid description (max 4000 characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_brand := nullif(btrim(p_brand, c_ws), '');
  if v_brand is not null and (char_length(v_brand) > 100 or v_brand ~ '[[:cntrl:]]') then
    raise exception 'Invalid brand (max 100 characters, no control characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_unit := nullif(btrim(p_unit_label, c_ws), '');
  if v_unit is not null and (char_length(v_unit) > 40 or v_unit ~ '[[:cntrl:]]') then
    raise exception 'Invalid unit_label (max 40 characters, no control characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_sku := nullif(btrim(p_sku, c_ws), '');
  if v_sku is not null and (char_length(v_sku) > 64 or v_sku !~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$') then
    raise exception 'Invalid sku (max 64 characters: letters, digits, . _ / -).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_category_id is not null
     and not exists (select 1 from public.categories c where c.id = p_category_id) then
    raise exception 'Category not found.'
      using errcode = 'P0001', detail = 'category_not_found';
  end if;

  -- stock_quantity, in_stock, is_active and image_url are deliberately NOT listed: the table
  -- defaults apply and this function has no say in them.
  begin
    insert into public.products
      (slug, name, category_id, description, brand, sku, price_cents, compare_at_price_cents, unit_label)
    values
      (v_slug, v_name, p_category_id, v_description, v_brand, v_sku, p_price_cents,
       p_compare_at_price_cents, v_unit)
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'products_slug_key' then
      raise exception 'A product with this slug already exists.'
        using errcode = '23505', detail = 'slug_taken';
    elsif v_constraint = 'products_sku_key' then
      raise exception 'A product with this SKU already exists.'
        using errcode = '23505', detail = 'sku_taken';
    end if;
    raise;
  end;

  return jsonb_build_object('product', jsonb_build_object(
    'id', v_row.id,
    'slug', v_row.slug,
    'name', v_row.name,
    'category_id', v_row.category_id,
    'description', v_row.description,
    'brand', v_row.brand,
    'sku', v_row.sku,
    'image_url', v_row.image_url,
    'price_cents', v_row.price_cents,
    'compare_at_price_cents', v_row.compare_at_price_cents,
    'unit_label', v_row.unit_label,
    'stock_quantity', v_row.stock_quantity,
    'in_stock', v_row.in_stock,
    'is_active', v_row.is_active,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at
  ));
end;
$$;

comment on function public.admin_create_product(text, text, integer, uuid, text, text, text, text, integer) is
  'Phase 6C.1B.1. Admin-only product insert (catalogue fields only; stock / in_stock / is_active / image_url keep their table defaults). Gate: require_admin().';

revoke all on function public.admin_create_product(text, text, integer, uuid, text, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.admin_create_product(text, text, integer, uuid, text, text, text, text, integer)
  to authenticated;

-- =============================================================================
-- 2. admin_update_product()
-- =============================================================================
create function public.admin_update_product(p_product_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_ws constant text := E' \t\r\n';
  v_old public.products;
  v_row public.products;
  v_key text;
  v_num numeric;
  v_name text;
  v_slug text;
  v_category uuid;
  v_description text;
  v_brand text;
  v_sku text;
  v_unit text;
  v_price integer;
  v_compare integer;
  v_constraint text;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_product_id is null then
    raise exception 'A product id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'p_changes must be a non-empty JSON object.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Whitelist: anything that is not an explicit catalogue field is refused, so this function can
  -- never be used to touch stock_quantity / in_stock / is_active / image_url / system columns.
  select k into v_key
  from jsonb_object_keys(p_changes) k
  where k <> all (array['name', 'slug', 'category_id', 'description', 'brand', 'sku',
                        'price_cents', 'compare_at_price_cents', 'unit_label'])
  order by k
  limit 1;
  if v_key is not null then
    raise exception 'The field "%" cannot be changed through admin_update_product().', left(v_key, 60)
      using errcode = 'P0001', detail = 'unsupported_field';
  end if;

  select * into v_old from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  -- Start from the stored values; only keys present in the patch change anything.
  v_name := v_old.name;
  v_slug := v_old.slug;
  v_category := v_old.category_id;
  v_description := v_old.description;
  v_brand := v_old.brand;
  v_sku := v_old.sku;
  v_unit := v_old.unit_label;
  v_price := v_old.price_cents;
  v_compare := v_old.compare_at_price_cents;

  if p_changes ? 'name' then
    if jsonb_typeof(p_changes -> 'name') <> 'string' then
      raise exception 'Invalid product name (must be a string).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_name := btrim(p_changes ->> 'name', c_ws);
    if char_length(v_name) not between 1 and 200 or v_name ~ '[[:cntrl:]]' then
      raise exception 'Invalid product name (1-200 characters, no control characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'slug' then
    if jsonb_typeof(p_changes -> 'slug') <> 'string' then
      raise exception 'Invalid product slug (must be a string).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_slug := btrim(p_changes ->> 'slug', c_ws);
    if char_length(v_slug) not between 1 and 120 or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
      raise exception 'Invalid product slug (1-120 characters, lower-case letters, digits and single hyphens).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'price_cents' then
    if jsonb_typeof(p_changes -> 'price_cents') <> 'number' then
      raise exception 'Invalid price_cents (must be a number).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_num := (p_changes ->> 'price_cents')::numeric;
    if v_num <> trunc(v_num) or v_num < 0 or v_num > 2147483647 then
      raise exception 'Invalid price_cents (a whole number of cents, 0 to 2147483647).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_price := v_num::integer;
  end if;

  if p_changes ? 'compare_at_price_cents' then
    if jsonb_typeof(p_changes -> 'compare_at_price_cents') = 'null' then
      v_compare := null;
    elsif jsonb_typeof(p_changes -> 'compare_at_price_cents') <> 'number' then
      raise exception 'Invalid compare_at_price_cents (must be a number or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    else
      v_num := (p_changes ->> 'compare_at_price_cents')::numeric;
      if v_num <> trunc(v_num) or v_num < 0 or v_num > 2147483647 then
        raise exception 'Invalid compare_at_price_cents (a whole number of cents, 0 to 2147483647).'
          using errcode = 'P0001', detail = 'invalid_arguments';
      end if;
      v_compare := v_num::integer;
    end if;
  end if;

  -- Checked against the EFFECTIVE values, so changing only the price can also be refused.
  if v_compare is not null and v_compare < v_price then
    raise exception 'Invalid compare_at_price_cents (must be null or >= price_cents).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_changes ? 'description' then
    if jsonb_typeof(p_changes -> 'description') not in ('string', 'null') then
      raise exception 'Invalid description (must be a string or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_description := nullif(btrim(p_changes ->> 'description', c_ws), '');
    if v_description is not null and char_length(v_description) > 4000 then
      raise exception 'Invalid description (max 4000 characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'brand' then
    if jsonb_typeof(p_changes -> 'brand') not in ('string', 'null') then
      raise exception 'Invalid brand (must be a string or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_brand := nullif(btrim(p_changes ->> 'brand', c_ws), '');
    if v_brand is not null and (char_length(v_brand) > 100 or v_brand ~ '[[:cntrl:]]') then
      raise exception 'Invalid brand (max 100 characters, no control characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'unit_label' then
    if jsonb_typeof(p_changes -> 'unit_label') not in ('string', 'null') then
      raise exception 'Invalid unit_label (must be a string or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_unit := nullif(btrim(p_changes ->> 'unit_label', c_ws), '');
    if v_unit is not null and (char_length(v_unit) > 40 or v_unit ~ '[[:cntrl:]]') then
      raise exception 'Invalid unit_label (max 40 characters, no control characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'sku' then
    if jsonb_typeof(p_changes -> 'sku') not in ('string', 'null') then
      raise exception 'Invalid sku (must be a string or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_sku := nullif(btrim(p_changes ->> 'sku', c_ws), '');
    if v_sku is not null and (char_length(v_sku) > 64 or v_sku !~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$') then
      raise exception 'Invalid sku (max 64 characters: letters, digits, . _ / -).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'category_id' then
    if jsonb_typeof(p_changes -> 'category_id') = 'null' then
      v_category := null;
    elsif jsonb_typeof(p_changes -> 'category_id') <> 'string' then
      raise exception 'Invalid category_id (must be a uuid string or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    else
      begin
        v_category := (p_changes ->> 'category_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'Invalid category_id (must be a uuid string or null).'
          using errcode = 'P0001', detail = 'invalid_arguments';
      end;
      if not exists (select 1 from public.categories c where c.id = v_category) then
        raise exception 'Category not found.'
          using errcode = 'P0001', detail = 'category_not_found';
      end if;
    end if;
  end if;

  -- Only the nine catalogue columns are ever assigned. stock_quantity, in_stock, is_active and
  -- image_url are not in this statement. The existing updated_at trigger stamps the row.
  begin
    update public.products
    set slug = v_slug,
        name = v_name,
        category_id = v_category,
        description = v_description,
        brand = v_brand,
        sku = v_sku,
        price_cents = v_price,
        compare_at_price_cents = v_compare,
        unit_label = v_unit
    where id = v_old.id
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'products_slug_key' then
      raise exception 'A product with this slug already exists.'
        using errcode = '23505', detail = 'slug_taken';
    elsif v_constraint = 'products_sku_key' then
      raise exception 'A product with this SKU already exists.'
        using errcode = '23505', detail = 'sku_taken';
    end if;
    raise;
  end;

  return jsonb_build_object('product', jsonb_build_object(
    'id', v_row.id,
    'slug', v_row.slug,
    'name', v_row.name,
    'category_id', v_row.category_id,
    'description', v_row.description,
    'brand', v_row.brand,
    'sku', v_row.sku,
    'image_url', v_row.image_url,
    'price_cents', v_row.price_cents,
    'compare_at_price_cents', v_row.compare_at_price_cents,
    'unit_label', v_row.unit_label,
    'stock_quantity', v_row.stock_quantity,
    'in_stock', v_row.in_stock,
    'is_active', v_row.is_active,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at
  ));
end;
$$;

comment on function public.admin_update_product(uuid, jsonb) is
  'Phase 6C.1B.1. Admin-only product patch (nine catalogue fields; absent key = unchanged, null clears nullable fields; any other key is rejected). Gate: require_admin().';

revoke all on function public.admin_update_product(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_product(uuid, jsonb) to authenticated;

-- =============================================================================
-- 3. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)',
    'public.admin_update_product(uuid,jsonb)'
  ] loop
    if exists (
      select 1 from pg_proc p
      where p.oid = v_fn::regprocedure
        and (not p.prosecdef
             or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
             or p.prosrc not like '%public.require_admin()%')
    ) then
      raise exception 'Phase 6C.1B.1 self-check failed: % is not SECURITY DEFINER with a pinned search_path and the require_admin() gate.', v_fn;
    end if;

    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'Phase 6C.1B.1 self-check failed: % privileges are wrong.', v_fn;
    end if;

    -- PUBLIC (the pseudo-role) must not hold EXECUTE either.
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'Phase 6C.1B.1 self-check failed: PUBLIC can execute %.', v_fn;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6C.1B.1 self-check failed: a browser role can execute require_admin() directly.';
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
    raise exception 'Phase 6C.1B.1 self-check failed: a browser role can write public.products.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6C.1B.1 self-check failed: a write policy exists on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass,
                    'public.categories'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6C.1B.1 self-check failed: row level security is off on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6C.1B.1 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
