-- =============================================================================
-- PHASE 20B - Admin picture upload: Storage bucket "catalog-images" + two image setters.
--
-- STATUS: written, NOT applied to any database. db/tests/phase20b_catalog_images.test.sql has not
-- been run against a real Supabase project unless the Phase 20 report says so.
--
-- Apply ONCE, after 20261011010000_phase20a_admin_categories.sql, in the Supabase SQL editor
-- (owner role). No existing migration or function is edited. One transaction.
--
-- ADDS
--   storage bucket  catalog-images   public read, 2 MB limit, jpeg / png / webp only
--   storage.objects policies (4)     "Catalog images: admin insert / update / delete / read"
--                                    admin = is_admin(auth.uid()) AND admin_mfa_satisfied(), and
--                                    the object name must be products|categories/<uuid>.<jpg|png|webp>
--   public.admin_set_product_image(p_product_id, p_image_url)
--   public.admin_set_category_image(p_category_id, p_image_url)
--
-- WHY THERE IS NO PUBLIC (anon) POLICY: a PUBLIC bucket serves files by URL without any policy.
-- Listing the bucket through the API stays closed to everyone except admins. The admin SELECT
-- policy exists because Storage needs row visibility for UPDATE / DELETE to work.
--
-- IMAGE SETTERS (gate: require_admin() first, then validation)
--   p_image_url is NULL (remove the picture) or exactly
--     https://<host>/storage/v1/object/public/catalog-images/products/<uuid>.<jpg|png|webp>
--   (categories/ for the category function). No query string, no other bucket, no other folder.
--   The named file must already exist in storage.objects, so a failed upload can never be linked.
--   Bad value -> P0001 / invalid_image_url.  No such file -> P0001 / image_not_found.
--   Missing id -> P0001 / invalid_arguments.  Unknown row -> product_not_found / category_not_found.
--   Same value as now: nothing written, not audited.
--   Audit: product_image_set / product_image_removed / category_image_set / category_image_removed
--   (the object name only).
-- Old files are NEVER deleted by these functions: order_items keep a copy of image_url, so an old
-- picture can still be referenced by past orders. Existing /products/*.jpg paths are untouched.
-- ACCESS: anon: no EXECUTE. authenticated: EXECUTE, but require_admin() runs first.
-- =============================================================================

begin;

do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null
     or to_regprocedure('public.admin_mfa_satisfied()') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.admin_update_category(uuid,jsonb)') is null then
    raise exception 'Phase 20B precondition failed: require_admin(), is_admin(), admin_mfa_satisfied(), admin_audit_log or Phase 20A is missing.';
  end if;

  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise exception 'Phase 20B precondition failed: the Supabase Storage schema (storage.buckets / storage.objects) is missing.';
  end if;

  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'products' and column_name = 'image_url')
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'categories' and column_name = 'image_url') then
    raise exception 'Phase 20B precondition failed: products.image_url or categories.image_url is missing.';
  end if;

  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('admin_set_product_image', 'admin_set_category_image')) then
    raise exception 'Phase 20B appears to be applied already. Not running it twice.';
  end if;

  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and policyname like 'Catalog images:%') then
    raise exception 'Phase 20B precondition failed: "Catalog images:" storage policies already exist.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. Bucket (created, or brought to these settings if it already exists)
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('catalog-images', 'catalog-images', true, 2097152,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- =============================================================================
-- 2. Storage policies: admins only (with 2FA), only for this bucket, only well-formed names
-- =============================================================================
create policy "Catalog images: admin insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'catalog-images'
    and public.is_admin(auth.uid()) and public.admin_mfa_satisfied()
    and name ~ '^(products|categories)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
  );

create policy "Catalog images: admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'catalog-images' and public.is_admin(auth.uid()) and public.admin_mfa_satisfied())
  with check (
    bucket_id = 'catalog-images'
    and public.is_admin(auth.uid()) and public.admin_mfa_satisfied()
    and name ~ '^(products|categories)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
  );

create policy "Catalog images: admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'catalog-images' and public.is_admin(auth.uid()) and public.admin_mfa_satisfied());

create policy "Catalog images: admin read"
  on storage.objects for select to authenticated
  using (bucket_id = 'catalog-images' and public.is_admin(auth.uid()) and public.admin_mfa_satisfied());

-- =============================================================================
-- 3. admin_set_product_image()
-- =============================================================================
create function public.admin_set_product_image(p_product_id uuid, p_image_url text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_row public.products;
  v_object text;
begin
  v_actor := public.require_admin();

  if p_product_id is null then
    raise exception 'A product id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_image_url is not null then
    if char_length(p_image_url) > 300
       or p_image_url !~ '^https://[^/?#[:space:]]+/storage/v1/object/public/catalog-images/products/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$' then
      raise exception 'The picture address is not a catalog-images product picture.'
        using errcode = 'P0001', detail = 'invalid_image_url';
    end if;
    v_object := substring(p_image_url from '/catalog-images/(products/[^/]+)$');
    if not exists (select 1 from storage.objects o
                   where o.bucket_id = 'catalog-images' and o.name = v_object) then
      raise exception 'That picture has not been uploaded.'
        using errcode = 'P0001', detail = 'image_not_found';
    end if;
  end if;

  select * into v_row from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.'
      using errcode = 'P0001', detail = 'product_not_found';
  end if;

  if v_row.image_url is distinct from p_image_url then
    update public.products set image_url = p_image_url where id = v_row.id
    returning * into v_row;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor,
            case when p_image_url is null then 'product_image_removed' else 'product_image_set' end,
            v_row.id,
            case when p_image_url is null then 'image removed' else format('image %s', v_object) end);
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

comment on function public.admin_set_product_image(uuid, text) is
  'Phase 20B. Admin-only: set a product picture to an uploaded catalog-images file, or NULL to remove it. Gate: require_admin(). Audited when the value changes.';

revoke all on function public.admin_set_product_image(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_set_product_image(uuid, text) to authenticated;

-- =============================================================================
-- 4. admin_set_category_image()
-- =============================================================================
create function public.admin_set_category_image(p_category_id uuid, p_image_url text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_row public.categories;
  v_object text;
begin
  v_actor := public.require_admin();

  if p_category_id is null then
    raise exception 'A category id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_image_url is not null then
    if char_length(p_image_url) > 300
       or p_image_url !~ '^https://[^/?#[:space:]]+/storage/v1/object/public/catalog-images/categories/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$' then
      raise exception 'The picture address is not a catalog-images category picture.'
        using errcode = 'P0001', detail = 'invalid_image_url';
    end if;
    v_object := substring(p_image_url from '/catalog-images/(categories/[^/]+)$');
    if not exists (select 1 from storage.objects o
                   where o.bucket_id = 'catalog-images' and o.name = v_object) then
      raise exception 'That picture has not been uploaded.'
        using errcode = 'P0001', detail = 'image_not_found';
    end if;
  end if;

  select * into v_row from public.categories where id = p_category_id for update;
  if not found then
    raise exception 'Category not found.'
      using errcode = 'P0001', detail = 'category_not_found';
  end if;

  if v_row.image_url is distinct from p_image_url then
    update public.categories set image_url = p_image_url where id = v_row.id
    returning * into v_row;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor,
            case when p_image_url is null then 'category_image_removed' else 'category_image_set' end,
            v_row.id,
            case when p_image_url is null then 'image removed' else format('image %s', v_object) end);
  end if;

  return jsonb_build_object('category', jsonb_build_object(
    'id', v_row.id, 'slug', v_row.slug, 'name', v_row.name, 'tagline', v_row.tagline,
    'description', v_row.description, 'image_url', v_row.image_url, 'parent_id', v_row.parent_id,
    'position', v_row.position, 'is_active', v_row.is_active,
    'created_at', v_row.created_at, 'updated_at', v_row.updated_at));
end;
$$;

comment on function public.admin_set_category_image(uuid, text) is
  'Phase 20B. Admin-only: set a category picture to an uploaded catalog-images file, or NULL to remove it. Gate: require_admin(). Audited when the value changes.';

revoke all on function public.admin_set_category_image(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_set_category_image(uuid, text) to authenticated;

-- =============================================================================
-- 5. Self-check (aborts the whole transaction if anything is off)
-- =============================================================================
do $check$
declare
  v_sig text;
  v_other text;
begin
  foreach v_sig in array array[
    'public.admin_set_product_image(uuid,text)',
    'public.admin_set_category_image(uuid,text)'] loop
    if not exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
                   and p.prosecdef
                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                   and p.prosrc like '%public.require_admin()%'
                   and p.prosrc like '%insert into public.admin_audit_log%') then
      raise exception 'Phase 20B self-check failed: % is not security definer / gated / audited.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig::regprocedure, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig::regprocedure, 'EXECUTE') then
      raise exception 'Phase 20B self-check failed: wrong EXECUTE grants on %.', v_sig;
    end if;
  end loop;

  if not exists (select 1 from storage.buckets b
                 where b.id = 'catalog-images' and b.public is true and b.file_size_limit = 2097152
                   and b.allowed_mime_types @> array['image/jpeg', 'image/png', 'image/webp']
                   and b.allowed_mime_types <@ array['image/jpeg', 'image/png', 'image/webp']) then
    raise exception 'Phase 20B self-check failed: bucket catalog-images is not public / 2 MB / jpeg-png-webp.';
  end if;

  if (select count(*) from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname like 'Catalog images:%') <> 4 then
    raise exception 'Phase 20B self-check failed: expected 4 "Catalog images:" storage policies.';
  end if;

  -- Not a failure: policies are OR-ed, so another policy that lets ordinary users write storage.objects
  -- without naming a bucket would also open this bucket. Tell the person running the migration.
  for v_other in
    select policyname from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname not like 'Catalog images:%'
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      and coalesce(qual, '') || ' ' || coalesce(with_check, '') not like '%bucket_id%'
  loop
    raise warning 'Phase 20B: storage policy "%" is not limited to a bucket. Check it does not let non-admins write catalog-images.', v_other;
  end loop;
end
$check$;

commit;
