-- =============================================================================
-- PHASE 6C.1B.2 - Admin product activation + product variants (create / update).
--
-- STATUS: written, NOT applied to any Supabase database (see the report). The SQL test
-- db/tests/phase6c1b2_admin_product_activation_variants.test.sql has not been run against a real
-- PostgreSQL unless the report says so.
--
-- Apply ONCE, after 20261004060000_phase6c1b1_admin_product_create_update.sql. Do not edit or
-- re-run any older migration. One transaction: if any statement or the final self-check fails,
-- nothing is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS ADDS (and nothing else)
--   public.admin_set_product_active(p_product_id, p_is_active)   Admin-only. Flips ONE column.
--   public.admin_create_product_variant(...)                      Admin-only. Inserts ONE variant.
--   public.admin_update_product_variant(p_variant_id, p_changes)  Admin-only. Patches catalogue fields.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * admin_create_product() and admin_update_product() are NOT touched (and neither is any
--     table default): a product created by admin_create_product() is still ACTIVE immediately,
--     because products.is_active defaults to true. That is documented, not changed here; whether
--     new products should start inactive is an architectural follow-up decision.
--   * No table privilege, policy, trigger, index, column or constraint is added or changed.
--     Browser roles still have NO INSERT / UPDATE / DELETE on products or product_variants.
--   * No stock / inventory handling of any kind (Phase 6C.2): no stock parameter anywhere, no
--     stock movement or history rows, no deletion, no images, no category CRUD.
--
-- ACTIVATION  admin_set_product_active(p_product_id uuid, p_is_active boolean) -> { "product": {...} }
--   Sets products.is_active and nothing else (no stock_quantity, in_stock, price, SKU, category,
--   image, identity column, and no variant row is touched). The row is locked FOR UPDATE first.
--   If the product already has the requested value nothing is written (updated_at does not move)
--   and the unchanged row is returned. The result is the stored row (all 16 public.products columns).
--   Unknown product -> P0001 / product_not_found. NULL id or NULL flag -> P0001 / invalid_arguments.
--
-- VARIANTS (public.product_variants columns, nothing invented)
--   id, product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity, attributes,
--   position, is_active, created_at, updated_at.
--   CATALOGUE fields (writable here): name, sku, price_cents, compare_at_price_cents,
--     attributes (a JSON object), position, and - on UPDATE only - is_active.
--   NOT writable here: stock_quantity (inventory, Phase 6C.2); product_id (a variant never moves
--     to another product); id, created_at, updated_at (system columns). There is no `in_stock`
--     column on product_variants; asking for it is refused like any unknown field.
--
-- admin_create_product_variant(p_product_id, p_name, p_price_cents, p_sku, p_compare_at_price_cents,
--                              p_attributes, p_position)  ->  { "variant": {...} }
--   Required: p_product_id, p_name, p_price_cents. p_sku / p_compare_at_price_cents default null,
--   p_attributes / p_position default null = "use the table default" ('{}' / 0).
--   There is NO stock parameter: calling it with p_stock_quantity (or p_in_stock, p_is_active,
--   p_product_... anything not listed) is a PostgreSQL "function does not exist" error (42883),
--   so the contract is explicit. stock_quantity and is_active are not in the INSERT: the table
--   defaults apply (stock_quantity 0, is_active true). A new variant therefore has NO stock until
--   the inventory phase exists.
--
-- admin_update_product_variant(p_variant_id uuid, p_changes jsonb)  ->  { "variant": {...} }
--   p_changes is a PATCH object. A key that is ABSENT leaves that column exactly as it is. A key
--   present sets it. JSON null CLEARS it, but only for the nullable columns (sku,
--   compare_at_price_cents); name, price_cents, attributes, position and is_active cannot be
--   null. Allowed keys: name, sku, price_cents, compare_at_price_cents, attributes, position,
--   is_active. Any other key (stock_quantity, in_stock, product_id, id, ...) -> P0001 /
--   unsupported_field and nothing is written. `{}` is rejected. The variant row is locked FOR
--   UPDATE, and its parent product must still exist.
--   The UPDATE assigns only the seven catalogue columns above, so stock_quantity is never part
--   of the statement (a concurrent order's stock decrement is neither read nor overwritten).
--
-- VALIDATION (after the admin gate, so a non-admin learns nothing about the rules)
--   name         required, trimmed, 1-200 chars, no control characters
--   price_cents  required, whole number 0 .. 2147483647 (the column is integer, check >= 0)
--   compare_at   null, or a whole number >= the (new) price (product_variants_compare_at_valid)
--   sku          null/blank = none; else 1-64 chars, ^[A-Za-z0-9][A-Za-z0-9._/-]*$
--   attributes   a JSON object (product_variants_attributes_object), at most 4000 bytes as text
--   position     whole number 0 .. 100000
--   is_active    JSON boolean (update only)
--   Bad input -> P0001 / DETAIL invalid_arguments (message names the field).
--   Unknown parent product -> P0001 / product_not_found.  Unknown variant -> P0001 / variant_not_found.
--   Duplicate SKU -> 23505 / DETAIL sku_taken (the existing unique index product_variants_sku_key
--   decides; nothing is pre-empted or bypassed). Variant SKUs and product SKUs are separate
--   indexes today, so a variant may reuse a product's SKU; that is the existing schema, not
--   changed here. There is no unique (product_id, name): two variants of a product may share a name.
--
-- ACCESS MODEL (same as 6C.1B.1)
--   anon          : EXECUTE revoked (permission denied, 42501).
--   authenticated : EXECUTE granted, but require_admin() runs FIRST and raises
--                   42501 / not_authorised for anyone who is not an admin (staff, customers,
--                   forged claims, signed-out callers).
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
    raise exception 'Phase 6C.1B.2 precondition failed: Phase 6A / 6B.1 functions are missing (require_admin(), is_admin(), admin_get_order()).';
  end if;

  if to_regprocedure('public.admin_set_order_status(uuid,public.order_status,text,boolean)') is null then
    raise exception 'Phase 6C.1B.2 precondition failed: Phase 6B.2 is not applied (admin_set_order_status() missing).';
  end if;

  if to_regprocedure('public.admin_list_products(integer,integer,text,boolean,uuid)') is null
     or to_regprocedure('public.admin_get_product(uuid)') is null then
    raise exception 'Phase 6C.1B.2 precondition failed: Phase 6C.1A.1 / 6C.1A.2 are not applied (admin_list_products() / admin_get_product() missing).';
  end if;

  if to_regprocedure('public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)') is null
     or to_regprocedure('public.admin_update_product(uuid,jsonb)') is null then
    raise exception 'Phase 6C.1B.2 precondition failed: Phase 6C.1B.1 is not applied (admin_create_product() / admin_update_product() missing).';
  end if;

  if to_regclass('public.products') is null or to_regclass('public.product_variants') is null then
    raise exception 'Phase 6C.1B.2 precondition failed: public.products / public.product_variants are missing.';
  end if;

  -- Columns this migration reads or writes. Fail early, with a clear message, if the schema drifted.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'slug', 'name', 'category_id', 'description', 'brand', 'sku',
                            'image_url', 'price_cents', 'compare_at_price_cents', 'unit_label',
                            'stock_quantity', 'in_stock', 'is_active', 'created_at', 'updated_at')) <> 16 then
    raise exception 'Phase 6C.1B.2 precondition failed: public.products does not have the expected 16 columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name in ('id', 'product_id', 'name', 'sku', 'price_cents', 'compare_at_price_cents',
                            'stock_quantity', 'attributes', 'position', 'is_active',
                            'created_at', 'updated_at')) <> 12
     or (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'product_variants') <> 12 then
    raise exception 'Phase 6C.1B.2 precondition failed: public.product_variants does not have exactly the expected 12 columns.';
  end if;

  -- The duplicate handling below recognises the violation by this index name.
  if to_regclass('public.product_variants_sku_key') is null then
    raise exception 'Phase 6C.1B.2 precondition failed: the unique index product_variants_sku_key is missing.';
  end if;

  if (select count(*) from pg_constraint
      where conrelid = 'public.product_variants'::regclass
        and conname in ('product_variants_price_nonnegative', 'product_variants_compare_at_valid',
                        'product_variants_stock_nonnegative', 'product_variants_attributes_object')) <> 4 then
    raise exception 'Phase 6C.1B.2 precondition failed: the product_variants constraints are missing.';
  end if;

  -- Browser roles must not be able to write products or variants already (this migration must
  -- not be the thing that finds out, and must never widen it).
  if exists (
    select 1
    from (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('anon'), ('authenticated')) r(role)
    where has_table_privilege(r.role, t.tbl, 'INSERT')
       or has_table_privilege(r.role, t.tbl, 'UPDATE')
       or has_table_privilege(r.role, t.tbl, 'DELETE')
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.1B.2 precondition failed: a browser role can already write public.products / public.product_variants.';
  end if;

  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('admin_set_product_active', 'admin_create_product_variant',
                             'admin_update_product_variant')) then
    raise exception 'Phase 6C.1B.2 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_set_product_active()
-- =============================================================================
create function public.admin_set_product_active(p_product_id uuid, p_is_active boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.products;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_product_id is null or p_is_active is null then
    raise exception 'A product id and a true / false activation value are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select * into v_row from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  -- Only is_active is assigned. Nothing else on the product, and no variant, is touched.
  -- An unchanged value writes nothing (so updated_at does not move).
  if v_row.is_active is distinct from p_is_active then
    update public.products
    set is_active = p_is_active
    where id = v_row.id
    returning * into v_row;
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

comment on function public.admin_set_product_active(uuid, boolean) is
  'Phase 6C.1B.2. Admin-only product activation / deactivation: sets products.is_active and nothing else. Gate: require_admin().';

revoke all on function public.admin_set_product_active(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_product_active(uuid, boolean) to authenticated;

-- =============================================================================
-- 2. admin_create_product_variant()
-- =============================================================================
create function public.admin_create_product_variant(
  p_product_id uuid,
  p_name text,
  p_price_cents integer,
  p_sku text default null,
  p_compare_at_price_cents integer default null,
  p_attributes jsonb default null,
  p_position integer default null
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
  v_sku text;
  v_row public.product_variants;
  v_constraint text;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

  if p_product_id is null then
    raise exception 'A product id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_name := btrim(coalesce(p_name, ''), c_ws);
  if char_length(v_name) not between 1 and 200 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Invalid variant name (1-200 characters, no control characters).'
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

  v_sku := nullif(btrim(p_sku, c_ws), '');
  if v_sku is not null and (char_length(v_sku) > 64 or v_sku !~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$') then
    raise exception 'Invalid sku (max 64 characters: letters, digits, . _ / -).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_attributes is not null
     and (jsonb_typeof(p_attributes) <> 'object' or octet_length(p_attributes::text) > 4000) then
    raise exception 'Invalid attributes (must be a JSON object of at most 4000 bytes).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_position is not null and p_position not between 0 and 100000 then
    raise exception 'Invalid position (a whole number 0 to 100000).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- The parent must exist. A share lock keeps it from being deleted before the insert.
  perform 1 from public.products where id = p_product_id for key share;
  if not found then
    raise exception 'Product not found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  -- stock_quantity and is_active are deliberately NOT listed: the table defaults apply
  -- (stock_quantity 0, is_active true) and this function has no say in them.
  begin
    insert into public.product_variants
      (product_id, name, sku, price_cents, compare_at_price_cents, attributes, position)
    values
      (p_product_id, v_name, v_sku, p_price_cents, p_compare_at_price_cents,
       coalesce(p_attributes, '{}'::jsonb), coalesce(p_position, 0))
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'product_variants_sku_key' then
      raise exception 'A variant with this SKU already exists.'
        using errcode = '23505', detail = 'sku_taken';
    end if;
    raise;
  end;

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

comment on function public.admin_create_product_variant(uuid, text, integer, text, integer, jsonb, integer) is
  'Phase 6C.1B.2. Admin-only variant insert (catalogue fields only; stock_quantity / is_active keep their table defaults). Gate: require_admin().';

revoke all on function public.admin_create_product_variant(uuid, text, integer, text, integer, jsonb, integer)
  from public, anon, authenticated;
grant execute on function public.admin_create_product_variant(uuid, text, integer, text, integer, jsonb, integer)
  to authenticated;

-- =============================================================================
-- 3. admin_update_product_variant()
-- =============================================================================
create function public.admin_update_product_variant(p_variant_id uuid, p_changes jsonb)
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
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();

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

comment on function public.admin_update_product_variant(uuid, jsonb) is
  'Phase 6C.1B.2. Admin-only variant patch (name, sku, price_cents, compare_at_price_cents, attributes, position, is_active; absent key = unchanged, null clears sku / compare_at; any other key is rejected). Gate: require_admin().';

revoke all on function public.admin_update_product_variant(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_product_variant(uuid, jsonb) to authenticated;

-- =============================================================================
-- 4. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.admin_set_product_active(uuid,boolean)',
    'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)',
    'public.admin_update_product_variant(uuid,jsonb)'
  ] loop
    if exists (
      select 1 from pg_proc p
      where p.oid = v_fn::regprocedure
        and (not p.prosecdef
             or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
             or p.prosrc not like '%public.require_admin()%')
    ) then
      raise exception 'Phase 6C.1B.2 self-check failed: % is not SECURITY DEFINER with a pinned search_path and the require_admin() gate.', v_fn;
    end if;

    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'Phase 6C.1B.2 self-check failed: % privileges are wrong.', v_fn;
    end if;

    -- PUBLIC (the pseudo-role) must not hold EXECUTE either.
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'Phase 6C.1B.2 self-check failed: PUBLIC can execute %.', v_fn;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6C.1B.2 self-check failed: a browser role can execute require_admin() directly.';
  end if;

  -- No broad product / variant mutation privilege was introduced.
  if exists (
    select 1
    from (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('anon'), ('authenticated')) r(role)
    where has_table_privilege(r.role, t.tbl, 'INSERT')
       or has_table_privilege(r.role, t.tbl, 'UPDATE')
       or has_table_privilege(r.role, t.tbl, 'DELETE')
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.1B.2 self-check failed: a browser role can write public.products / public.product_variants.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('products', 'product_variants', 'categories')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'Phase 6C.1B.2 self-check failed: a write policy exists on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_class c
    where c.oid in ('public.products'::regclass, 'public.product_variants'::regclass,
                    'public.categories'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Phase 6C.1B.2 self-check failed: row level security is off on a catalogue table.';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
  ) then
    raise exception 'Phase 6C.1B.2 self-check failed: a SECURITY DEFINER function has no pinned search_path.';
  end if;
end
$check$;

commit;
