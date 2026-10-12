-- =============================================================================
-- PHASE 6I.2 FIX - audit text-array append. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005100000 (Phase 6I.2). One transaction.
--
-- BUG FIXED: in admin_update_product() and admin_update_product_variant() the 6I.2 migration
--   wrote  v_changes := v_changes || 'name';  (an untyped literal). Postgres reads that literal as
--   an ARRAY and fails with 22P02 "malformed array literal". Any edit that changed a text field
--   (product: name, slug, category_id, description, brand, sku, unit_label; variant: name, sku,
--   attributes, position) therefore failed and rolled back. Price-only edits worked.
-- FIX: the literal is cast, v_changes || 'name'::text, in all 11 places. Nothing else changes:
--   same signatures, return shape, validation, locking, grants, audit action names and reason text.
-- DOES NOT: touch any other function, table, grant, policy or trigger, or write any audit row.
-- =============================================================================
begin;

do $pre$
declare
  v_sig text;
  v_targets constant text[] := array[
    'public.admin_update_product(uuid,jsonb)',
    'public.admin_update_product_variant(uuid,jsonb)'
  ];
begin
  foreach v_sig in array v_targets loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6I.2 fix precondition failed: % does not exist.', v_sig;
    end if;
    if not exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
                   and p.prosecdef and p.provolatile = 'v'
                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                   and p.prosrc like '%insert into public.admin_audit_log%') then
      raise exception 'Phase 6I.2 fix precondition failed: % is not the 6I.2 version. Apply 20261005100000 first.', v_sig;
    end if;
    if not exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
                   and p.prosrc ~ 'v_changes := v_changes \|\| ''[a-z_]+'';') then
      raise exception 'Phase 6I.2 fix appears to be applied already (% has no untyped append). Not running it twice.', v_sig;
    end if;
  end loop;

  perform set_config('p6i2fix.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p6i2fix.other_fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.oid <> all (select t::regprocedure::oid from unnest(v_targets) t)), true);
  perform set_config('p6i2fix.acl_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p where p.pronamespace = 'public'::regnamespace), true);
  perform set_config('p6i2fix.audit_count', (select count(*) from public.admin_audit_log)::text, true);
end
$pre$;

-- 1. admin_update_product()
create or replace function public.admin_update_product(p_product_id uuid, p_changes jsonb)
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
  v_actor uuid;
  v_changes text[] := '{}'::text[];
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

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

  -- Phase 6I.2 audit row, only when a stored value actually differs. Prices: old -> new.
  -- Text fields: the field NAME only, never the value.
  if v_row.name is distinct from v_old.name then v_changes := v_changes || 'name'::text; end if;
  if v_row.slug is distinct from v_old.slug then v_changes := v_changes || 'slug'::text; end if;
  if v_row.category_id is distinct from v_old.category_id then v_changes := v_changes || 'category_id'::text; end if;
  if v_row.description is distinct from v_old.description then v_changes := v_changes || 'description'::text; end if;
  if v_row.brand is distinct from v_old.brand then v_changes := v_changes || 'brand'::text; end if;
  if v_row.sku is distinct from v_old.sku then v_changes := v_changes || 'sku'::text; end if;
  if v_row.unit_label is distinct from v_old.unit_label then v_changes := v_changes || 'unit_label'::text; end if;
  if v_row.price_cents is distinct from v_old.price_cents then
    v_changes := v_changes || format('price_cents %s -> %s', v_old.price_cents, v_row.price_cents);
  end if;
  if v_row.compare_at_price_cents is distinct from v_old.compare_at_price_cents then
    v_changes := v_changes || format('compare_at_price_cents %s -> %s',
                                     coalesce(v_old.compare_at_price_cents::text, 'none'),
                                     coalesce(v_row.compare_at_price_cents::text, 'none'));
  end if;

  if cardinality(v_changes) > 0 then
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'product_updated', v_row.id,
            left(array_to_string(v_changes, '; '), 500));
  end if;

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

revoke all on function public.admin_update_product(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_product(uuid, jsonb) to authenticated;

-- 2. admin_update_product_variant()
create or replace function public.admin_update_product_variant(p_variant_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_ws constant text := E' \t\r\n';
  v_old public.product_variants;
  v_row public.product_variants;
  v_key text;
  v_num numeric;
  v_name text;
  v_sku text;
  v_price integer;
  v_compare integer;
  v_attributes jsonb;
  v_position integer;
  v_active boolean;
  v_constraint text;
  v_actor uuid;
  v_changes text[] := '{}'::text[];
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

  if p_variant_id is null then
    raise exception 'A variant id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'p_changes must be a non-empty JSON object.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- Whitelist: anything that is not an explicit catalogue field is refused, so this function can
  -- never be used to touch stock_quantity, the owning product, or system columns.
  select k into v_key
  from jsonb_object_keys(p_changes) k
  where k <> all (array['name', 'sku', 'price_cents', 'compare_at_price_cents', 'attributes',
                        'position', 'is_active'])
  order by k
  limit 1;
  if v_key is not null then
    raise exception 'The field "%" cannot be changed through admin_update_product_variant().', left(v_key, 60)
      using errcode = 'P0001', detail = 'unsupported_field';
  end if;

  select * into v_old from public.product_variants where id = p_variant_id for update;
  if not found then
    raise exception 'Variant not found.'
      using errcode = 'P0001', detail = 'variant_not_found';
  end if;

  perform 1 from public.products where id = v_old.product_id for key share;
  if not found then
    raise exception 'The parent product of this variant was not found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  -- Start from the stored values; only keys present in the patch change anything.
  v_name := v_old.name;
  v_sku := v_old.sku;
  v_price := v_old.price_cents;
  v_compare := v_old.compare_at_price_cents;
  v_attributes := v_old.attributes;
  v_position := v_old.position;
  v_active := v_old.is_active;

  if p_changes ? 'name' then
    if jsonb_typeof(p_changes -> 'name') <> 'string' then
      raise exception 'Invalid variant name (must be a string).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_name := btrim(p_changes ->> 'name', c_ws);
    if char_length(v_name) not between 1 and 200 or v_name ~ '[[:cntrl:]]' then
      raise exception 'Invalid variant name (1-200 characters, no control characters).'
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

  if p_changes ? 'attributes' then
    if jsonb_typeof(p_changes -> 'attributes') <> 'object'
       or octet_length((p_changes -> 'attributes')::text) > 4000 then
      raise exception 'Invalid attributes (must be a JSON object of at most 4000 bytes).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_attributes := p_changes -> 'attributes';
  end if;

  if p_changes ? 'position' then
    if jsonb_typeof(p_changes -> 'position') <> 'number' then
      raise exception 'Invalid position (must be a number).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_num := (p_changes ->> 'position')::numeric;
    if v_num <> trunc(v_num) or v_num < 0 or v_num > 100000 then
      raise exception 'Invalid position (a whole number 0 to 100000).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_position := v_num::integer;
  end if;

  if p_changes ? 'is_active' then
    if jsonb_typeof(p_changes -> 'is_active') <> 'boolean' then
      raise exception 'Invalid is_active (must be true or false).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_active := (p_changes ->> 'is_active')::boolean;
  end if;

  -- Only the seven catalogue columns are ever assigned. stock_quantity, product_id and the
  -- system columns are not in this statement. The existing updated_at trigger stamps the row.
  begin
    update public.product_variants
    set name = v_name,
        sku = v_sku,
        price_cents = v_price,
        compare_at_price_cents = v_compare,
        attributes = v_attributes,
        position = v_position,
        is_active = v_active
    where id = v_old.id
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'product_variants_sku_key' then
      raise exception 'A variant with this SKU already exists.'
        using errcode = '23505', detail = 'sku_taken';
    end if;
    raise;
  end;

  -- Phase 6I.2 audit row, only when a stored value actually differs. Prices and is_active:
  -- old -> new. Text / JSON fields: the field NAME only, never the value.
  if v_row.name is distinct from v_old.name then v_changes := v_changes || 'name'::text; end if;
  if v_row.sku is distinct from v_old.sku then v_changes := v_changes || 'sku'::text; end if;
  if v_row.attributes is distinct from v_old.attributes then v_changes := v_changes || 'attributes'::text; end if;
  if v_row.position is distinct from v_old.position then v_changes := v_changes || 'position'::text; end if;
  if v_row.price_cents is distinct from v_old.price_cents then
    v_changes := v_changes || format('price_cents %s -> %s', v_old.price_cents, v_row.price_cents);
  end if;
  if v_row.compare_at_price_cents is distinct from v_old.compare_at_price_cents then
    v_changes := v_changes || format('compare_at_price_cents %s -> %s',
                                     coalesce(v_old.compare_at_price_cents::text, 'none'),
                                     coalesce(v_row.compare_at_price_cents::text, 'none'));
  end if;
  if v_row.is_active is distinct from v_old.is_active then
    v_changes := v_changes || format('is_active %s -> %s', v_old.is_active::text, v_row.is_active::text);
  end if;

  if cardinality(v_changes) > 0 then
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'product_variant_updated', v_row.id,
            left(format('product %s: %s', v_row.product_id, array_to_string(v_changes, '; ')), 500));
  end if;

  return jsonb_build_object('variant', jsonb_build_object(
    'id', v_row.id,
    'product_id', v_row.product_id,
    'name', v_row.name,
    'sku', v_row.sku,
    'price_cents', v_row.price_cents,
    'compare_at_price_cents', v_row.compare_at_price_cents,
    'stock_quantity', v_row.stock_quantity,
    'attributes', v_row.attributes,
    'position', v_row.position,
    'is_active', v_row.is_active,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at
  ));
end;
$$;

revoke all on function public.admin_update_product_variant(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_product_variant(uuid, jsonb) to authenticated;


do $chk$
declare
  v_sig text;
  v_targets constant text[] := array[
    'public.admin_update_product(uuid,jsonb)',
    'public.admin_update_product_variant(uuid,jsonb)'
  ];
begin
  foreach v_sig in array v_targets loop
    if exists (select 1 from pg_proc p
               where p.oid = v_sig::regprocedure
                 and (not p.prosecdef
                      or p.provolatile <> 'v'
                      or p.prorettype <> 'jsonb'::regtype
                      or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
                      or p.prosrc not like '%public.require_admin()%'
                      or p.prosrc not like '%insert into public.admin_audit_log%'
                      or p.prosrc ~ 'v_changes := v_changes \|\| ''[a-z_]+'';')) then
      raise exception 'Phase 6I.2 fix self-check failed: % is not as designed.', v_sig;
    end if;
  end loop;

  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from current_setting('p6i2fix.fn_count', true) then
    raise exception 'Phase 6I.2 fix self-check failed: the number of public functions changed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.oid <> all (select t::regprocedure::oid from unnest(v_targets) t))
     is distinct from current_setting('p6i2fix.other_fn_hash', true) then
    raise exception 'Phase 6I.2 fix self-check failed: a function outside the two changed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p where p.pronamespace = 'public'::regnamespace)
     is distinct from current_setting('p6i2fix.acl_hash', true) then
    raise exception 'Phase 6I.2 fix self-check failed: a function ACL changed.';
  end if;
  if (select count(*) from public.admin_audit_log)::text is distinct from current_setting('p6i2fix.audit_count', true) then
    raise exception 'Phase 6I.2 fix self-check failed: the migration itself wrote audit rows.';
  end if;
end
$chk$;

commit;
