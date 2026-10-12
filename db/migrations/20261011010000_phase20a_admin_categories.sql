-- =============================================================================
-- PHASE 20A - Admin category create + update.
--
-- STATUS: written, NOT applied to any database. db/tests/phase20a_admin_categories.test.sql has
-- not been run against a real PostgreSQL unless the Phase 20 report says so.
--
-- Apply ONCE, after 20261010010000_phase9c_inventory_history_movement_labels.sql. No existing
-- migration or function is edited. One transaction: any failure rolls everything back.
--
-- ADDS (new functions only)
--   public.admin_create_category(p_name, p_slug, p_tagline, p_description, p_position, p_is_active)
--   public.admin_update_category(p_category_id, p_changes jsonb)     -- PATCH, like admin_update_product
--
-- NOT ADDED: delete (deactivate with is_active = false instead), image handling (Phase 20B),
-- parent_id handling, any table grant / policy / trigger / index change. Browser roles still have
-- no INSERT / UPDATE / DELETE on public.categories.
--
-- VALIDATION (after require_admin(), so a non-admin learns nothing about the rules)
--   name 2-80 chars, trimmed, no control chars    slug 1-80 chars, ^[a-z0-9]+(-[a-z0-9]+)*$
--   tagline null or <= 120 chars (blank -> null)  description null or <= 500 chars (blank -> null)
--   position whole number 0 .. 2147483647         is_active true / false (never null)
--   Bad input -> P0001 / DETAIL invalid_arguments (message "Invalid category <field> ...").
--   Unknown category -> P0001 / category_not_found.  Duplicate slug -> 23505 / slug_taken.
-- PATCH RULES (update): absent key = untouched; tagline / description may be JSON null (clears);
--   name, slug, position, is_active cannot be null. Any other key (image_url, parent_id, id, ...)
--   -> P0001 / unsupported_field. `{}` is rejected. A patch that changes nothing writes nothing
--   and is not audited.
-- AUDIT: admin_audit_log rows 'category_created' / 'category_updated' (field names and the
--   is_active change only; never the description text).
-- ACCESS: anon: no EXECUTE. authenticated: EXECUTE, but require_admin() runs first.
-- =============================================================================

begin;

do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_set_product_active(uuid,boolean)') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regclass('public.categories_slug_key') is null then
    raise exception 'Phase 20A precondition failed: require_admin(), admin_set_product_active(), admin_audit_log or categories_slug_key is missing.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'categories'
        and column_name in ('id', 'slug', 'name', 'tagline', 'description', 'image_url',
                            'parent_id', 'position', 'is_active', 'created_at', 'updated_at')) <> 11 then
    raise exception 'Phase 20A precondition failed: public.categories does not have the expected 11 columns.';
  end if;

  if has_table_privilege('authenticated', 'public.categories', 'INSERT')
     or has_table_privilege('authenticated', 'public.categories', 'UPDATE')
     or has_table_privilege('authenticated', 'public.categories', 'DELETE')
     or has_table_privilege('anon', 'public.categories', 'INSERT')
     or has_table_privilege('anon', 'public.categories', 'UPDATE')
     or has_table_privilege('anon', 'public.categories', 'DELETE') then
    raise exception 'Phase 20A precondition failed: a browser role can already write public.categories.';
  end if;

  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('admin_create_category', 'admin_update_category')) then
    raise exception 'Phase 20A appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. admin_create_category()
-- =============================================================================
create function public.admin_create_category(
  p_name text,
  p_slug text,
  p_tagline text default null,
  p_description text default null,
  p_position integer default 0,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_ws constant text := E' \t\r\n';
  v_actor uuid;
  v_name text;
  v_slug text;
  v_tagline text;
  v_description text;
  v_row public.categories;
  v_constraint text;
begin
  v_actor := public.require_admin();

  v_name := btrim(coalesce(p_name, ''), c_ws);
  if char_length(v_name) not between 2 and 80 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Invalid category name (2-80 characters, no control characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_slug := btrim(coalesce(p_slug, ''), c_ws);
  if char_length(v_slug) not between 1 and 80 or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'Invalid category slug (1-80 characters, lower-case letters, digits and single hyphens).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_tagline := nullif(btrim(p_tagline, c_ws), '');
  if v_tagline is not null and (char_length(v_tagline) > 120 or v_tagline ~ '[[:cntrl:]]') then
    raise exception 'Invalid category tagline (max 120 characters, no control characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_description := nullif(btrim(p_description, c_ws), '');
  if v_description is not null and char_length(v_description) > 500 then
    raise exception 'Invalid category description (max 500 characters).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_position is null or p_position < 0 then
    raise exception 'Invalid category position (a whole number >= 0).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_is_active is null then
    raise exception 'Invalid category is_active (true or false).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  begin
    insert into public.categories (slug, name, tagline, description, position, is_active)
    values (v_slug, v_name, v_tagline, v_description, p_position, p_is_active)
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'categories_slug_key' then
      raise exception 'A category with this slug already exists.'
        using errcode = '23505', detail = 'slug_taken';
    end if;
    raise;
  end;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'category_created', v_row.id,
          format('position %s; is_active %s', v_row.position, v_row.is_active));

  return jsonb_build_object('category', jsonb_build_object(
    'id', v_row.id, 'slug', v_row.slug, 'name', v_row.name, 'tagline', v_row.tagline,
    'description', v_row.description, 'image_url', v_row.image_url, 'parent_id', v_row.parent_id,
    'position', v_row.position, 'is_active', v_row.is_active,
    'created_at', v_row.created_at, 'updated_at', v_row.updated_at));
end;
$$;

comment on function public.admin_create_category(text, text, text, text, integer, boolean) is
  'Phase 20A. Admin-only category insert (no image, no parent). Gate: require_admin(). Audited.';

revoke all on function public.admin_create_category(text, text, text, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_create_category(text, text, text, text, integer, boolean)
  to authenticated;

-- =============================================================================
-- 2. admin_update_category()
-- =============================================================================
create function public.admin_update_category(p_category_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_ws constant text := E' \t\r\n';
  v_actor uuid;
  v_old public.categories;
  v_row public.categories;
  v_key text;
  v_num numeric;
  v_name text;
  v_slug text;
  v_tagline text;
  v_description text;
  v_position integer;
  v_active boolean;
  v_changed text[] := '{}'::text[];
  v_constraint text;
begin
  v_actor := public.require_admin();

  if p_category_id is null then
    raise exception 'A category id is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'p_changes must be a non-empty JSON object.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  select k into v_key
  from jsonb_object_keys(p_changes) k
  where k <> all (array['name', 'slug', 'tagline', 'description', 'position', 'is_active'])
  order by k
  limit 1;
  if v_key is not null then
    raise exception 'The field "%" cannot be changed through admin_update_category().', left(v_key, 60)
      using errcode = 'P0001', detail = 'unsupported_field';
  end if;

  select * into v_old from public.categories where id = p_category_id for update;
  if not found then
    raise exception 'Category not found.'
      using errcode = 'P0001', detail = 'category_not_found';
  end if;

  v_name := v_old.name;
  v_slug := v_old.slug;
  v_tagline := v_old.tagline;
  v_description := v_old.description;
  v_position := v_old.position;
  v_active := v_old.is_active;

  if p_changes ? 'name' then
    if jsonb_typeof(p_changes -> 'name') <> 'string' then
      raise exception 'Invalid category name (2-80 characters, no control characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_name := btrim(p_changes ->> 'name', c_ws);
    if char_length(v_name) not between 2 and 80 or v_name ~ '[[:cntrl:]]' then
      raise exception 'Invalid category name (2-80 characters, no control characters).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'slug' then
    if jsonb_typeof(p_changes -> 'slug') <> 'string' then
      raise exception 'Invalid category slug (1-80 characters, lower-case letters, digits and single hyphens).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_slug := btrim(p_changes ->> 'slug', c_ws);
    if char_length(v_slug) not between 1 and 80 or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
      raise exception 'Invalid category slug (1-80 characters, lower-case letters, digits and single hyphens).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'tagline' then
    if jsonb_typeof(p_changes -> 'tagline') = 'null' then
      v_tagline := null;
    elsif jsonb_typeof(p_changes -> 'tagline') = 'string' then
      v_tagline := nullif(btrim(p_changes ->> 'tagline', c_ws), '');
      if v_tagline is not null and (char_length(v_tagline) > 120 or v_tagline ~ '[[:cntrl:]]') then
        raise exception 'Invalid category tagline (max 120 characters, no control characters).'
          using errcode = 'P0001', detail = 'invalid_arguments';
      end if;
    else
      raise exception 'Invalid category tagline (text or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'description' then
    if jsonb_typeof(p_changes -> 'description') = 'null' then
      v_description := null;
    elsif jsonb_typeof(p_changes -> 'description') = 'string' then
      v_description := nullif(btrim(p_changes ->> 'description', c_ws), '');
      if v_description is not null and char_length(v_description) > 500 then
        raise exception 'Invalid category description (max 500 characters).'
          using errcode = 'P0001', detail = 'invalid_arguments';
      end if;
    else
      raise exception 'Invalid category description (text or null).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_changes ? 'position' then
    if jsonb_typeof(p_changes -> 'position') <> 'number' then
      raise exception 'Invalid category position (a whole number >= 0).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_num := (p_changes ->> 'position')::numeric;
    if v_num < 0 or v_num > 2147483647 or v_num <> trunc(v_num) then
      raise exception 'Invalid category position (a whole number >= 0).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_position := v_num::integer;
  end if;

  if p_changes ? 'is_active' then
    if jsonb_typeof(p_changes -> 'is_active') <> 'boolean' then
      raise exception 'Invalid category is_active (true or false).'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
    v_active := (p_changes ->> 'is_active')::boolean;
  end if;

  if v_name is distinct from v_old.name then v_changed := v_changed || 'name'::text; end if;
  if v_slug is distinct from v_old.slug then v_changed := v_changed || 'slug'::text; end if;
  if v_tagline is distinct from v_old.tagline then v_changed := v_changed || 'tagline'::text; end if;
  if v_description is distinct from v_old.description then v_changed := v_changed || 'description'::text; end if;
  if v_position is distinct from v_old.position then v_changed := v_changed || 'position'::text; end if;
  if v_active is distinct from v_old.is_active then v_changed := v_changed || 'is_active'::text; end if;

  if cardinality(v_changed) = 0 then
    v_row := v_old;
  else
    begin
      update public.categories
      set name = v_name, slug = v_slug, tagline = v_tagline, description = v_description,
          position = v_position, is_active = v_active
      where id = v_old.id
      returning * into v_row;
    exception when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'categories_slug_key' then
        raise exception 'A category with this slug already exists.'
          using errcode = '23505', detail = 'slug_taken';
      end if;
      raise;
    end;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'category_updated', v_row.id,
            left(format('fields: %s%s', array_to_string(v_changed, ', '),
                        case when v_active is distinct from v_old.is_active
                             then format('; is_active %s -> %s', v_old.is_active, v_active)
                             else '' end), 500));
  end if;

  return jsonb_build_object('category', jsonb_build_object(
    'id', v_row.id, 'slug', v_row.slug, 'name', v_row.name, 'tagline', v_row.tagline,
    'description', v_row.description, 'image_url', v_row.image_url, 'parent_id', v_row.parent_id,
    'position', v_row.position, 'is_active', v_row.is_active,
    'created_at', v_row.created_at, 'updated_at', v_row.updated_at));
end;
$$;

comment on function public.admin_update_category(uuid, jsonb) is
  'Phase 20A. Admin-only category PATCH (name, slug, tagline, description, position, is_active). Gate: require_admin(). Audited when a value changes.';

revoke all on function public.admin_update_category(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_category(uuid, jsonb) to authenticated;

-- =============================================================================
-- 3. Self-check (aborts the whole transaction if anything is off)
-- =============================================================================
do $check$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.admin_create_category(text,text,text,text,integer,boolean)',
    'public.admin_update_category(uuid,jsonb)'] loop
    if not exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
                   and p.prosecdef
                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                   and p.prosrc like '%public.require_admin()%'
                   and p.prosrc like '%insert into public.admin_audit_log%') then
      raise exception 'Phase 20A self-check failed: % is not security definer / gated / audited.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig::regprocedure, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig::regprocedure, 'EXECUTE') then
      raise exception 'Phase 20A self-check failed: wrong EXECUTE grants on %.', v_sig;
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.categories', 'INSERT')
     or has_table_privilege('authenticated', 'public.categories', 'UPDATE')
     or has_table_privilege('authenticated', 'public.categories', 'DELETE') then
    raise exception 'Phase 20A self-check failed: a browser role can write public.categories.';
  end if;
end
$check$;

commit;
