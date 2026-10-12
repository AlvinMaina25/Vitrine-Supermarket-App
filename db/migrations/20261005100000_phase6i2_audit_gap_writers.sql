-- =============================================================================
-- PHASE 6I.2 (part 1 of 2) - FILL THE AUDIT GAPS. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005090000 (Phase 6I.1). One transaction. Section 0 refuses a second run.
--
-- DOES: replaces EXACTLY these seven functions with CREATE OR REPLACE, same signature, same
--   return shape, SECURITY DEFINER, VOLATILE, search_path = public, pg_temp, same grants. The
--   only change in each is ONE added admin_audit_log row on a successful, effective mutation,
--   written in the same transaction (actor_id = auth.uid(), never an argument):
--
--   function                          action name(s)                              target_id
--   admin_set_order_status            order_status_changed                        order id
--   admin_create_product              product_created                             product id
--   admin_update_product              product_updated                             product id
--   admin_set_product_active          product_activated / product_deactivated     product id
--   admin_create_product_variant      product_variant_created                     variant id
--   admin_update_product_variant      product_variant_updated                     variant id
--   admin_adjust_inventory            inventory_adjusted                          variant id, else product id
--
-- NO AUDIT ROW FOR: a failed or rejected call (the exception rolls the transaction back, and the
--   insert sits after every check), or a no-op (order already in that status; product already
--   had that is_active value; a patch that changes no stored value).
-- AUDIT ROW CONTENT (reason, <= 500 chars): non-sensitive before/after values only, e.g.
--   'pending -> confirmed', 'price_cents 1200 -> 1500', 'is_active true -> false',
--   'delta -3; stock 10 -> 7'. For fields that are text (name, slug, sku, description, brand,
--   unit_label, category_id, attributes) ONLY THE FIELD NAME is recorded, not its value.
--   Never a note, email, phone, token, secret, card data or raw payload. The free-text
--   p_note of admin_set_order_status and admin_adjust_inventory is NOT recorded.
--   admin_adjust_inventory records the admin's short p_reason (1-120 chars, required).
--
-- DOES NOT: touch any other function, table, column, grant, policy or trigger; change any
--   validation, locking, return value or error; add UI, retention or tests. Customer status /
--   notes, delivery admin, payment outcome and COD writers are already audited and are not touched.
--   admin_update_product / admin_update_product_variant still run their UPDATE exactly as before
--   (including for a patch that changes nothing); only the audit row is skipped in that case.
-- =============================================================================
begin;

-- =============================================================================
-- 0. PRECONDITIONS + SNAPSHOTS
-- =============================================================================
do $pre$
declare
  v_sig text;
  v_targets constant text[] := array[
    'public.admin_set_order_status(uuid,public.order_status,text,boolean)',
    'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)',
    'public.admin_update_product(uuid,jsonb)',
    'public.admin_set_product_active(uuid,boolean)',
    'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)',
    'public.admin_update_product_variant(uuid,jsonb)',
    'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'
  ];
begin
  if to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)') is null then
    raise exception 'Phase 6I.2 precondition failed: apply migrations up to 20261005090000 (Phase 6I.1) first.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'admin_audit_log'
        and column_name in ('id', 'actor_id', 'action', 'target_id', 'reason', 'created_at')) <> 6 then
    raise exception 'Phase 6I.2 precondition failed: admin_audit_log does not have the expected columns.';
  end if;

  foreach v_sig in array v_targets loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6I.2 precondition failed: function % does not exist.', v_sig;
    end if;
    if exists (select 1 from pg_proc p
               where p.oid = v_sig::regprocedure
                 and (not p.prosecdef
                      or p.provolatile <> 'v'
                      or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
                      or p.prosrc not like '%public.require_admin()%')) then
      raise exception 'Phase 6I.2 precondition failed: % is not in the expected state (SECURITY DEFINER, VOLATILE, pinned search_path, admin gate).', v_sig;
    end if;
    if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure and p.prosrc like '%admin_audit_log%') then
      raise exception 'Phase 6I.2 appears to be applied already (% already writes the audit log). Not running it twice.', v_sig;
    end if;
  end loop;

  -- Snapshots for the self-check at the end.
  perform set_config('p6i2.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p6i2.other_fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.oid <> all (select t::regprocedure::oid from unnest(v_targets) t)),
    true);
  perform set_config('p6i2.target_acl_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.oid = any (select t::regprocedure::oid from unnest(v_targets) t)),
    true);
  perform set_config('p6i2.table_acl_hash',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')),
    true);
  perform set_config('p6i2.trigger_hash',
    (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                    '|' order by t.tgrelid::regclass::text, t.tgname), ''))
     from pg_trigger t
     where not t.tgisinternal
       and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)),
    true);
  perform set_config('p6i2.audit_count', (select count(*) from public.admin_audit_log)::text, true);
end
$pre$;

-- =============================================================================
-- 1. admin_set_order_status()   [from 20261004030000_phase6b2_admin_order_actions.sql]
--    Added: v_actor, and one audit row inside the v_changed branch, after every receipt.
-- =============================================================================
create or replace function public.admin_set_order_status(
  p_order_id uuid,
  p_status public.order_status,
  p_note text default null,
  p_override boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_before public.orders%rowtype;
  v_after public.orders%rowtype;
  v_prev_ids uuid[];
  v_entry public.order_status_history%rowtype;
  v_changed boolean;
  v_actor uuid;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

  if p_order_id is null or p_status is null then
    raise exception 'An order and a new status are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- 'Admin override:' is the marker set_order_status() writes for an override. A caller-supplied
  -- note may not start with it: otherwise a standard move could be mislabelled as an override in
  -- the audit trail, and the override receipt below could not tell the two apart.
  if btrim(coalesce(p_note, '')) ilike 'admin override:%' then
    raise exception 'A note may not start with "Admin override:". That prefix is added automatically to overrides.'
      using errcode = 'P0001', detail = 'note_reserved_prefix';
  end if;

  -- Serialise concurrent admin actions on this order and read its state as of the lock.
  select * into v_before from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'That order could not be found.'
      using errcode = 'P0001', detail = 'order_not_found';
  end if;

  select coalesce(array_agg(h.id), '{}'::uuid[]) into v_prev_ids
  from public.order_status_history h
  where h.order_id = p_order_id;

  -- THE state machine. Validation, payment gate, restock / re-reserve, slot capacity guard and
  -- the history row all happen inside this call and its triggers. Its errors propagate as-is.
  perform public.set_order_status(p_order_id, p_status, p_note);

  select * into v_after from public.orders where id = p_order_id;
  v_changed := v_after.status is distinct from v_before.status;

  -- Receipt 1: this layer never moves payment state.
  if v_after.payment_status is distinct from v_before.payment_status then
    raise exception 'An order status action must not change the payment status.'
      using errcode = 'P0001', detail = 'payment_status_changed';
  end if;

  if v_changed then
    -- Receipt 2: a status change always leaves its history row (found by id, not by timestamp,
    -- because rows written in one transaction share now()).
    select h.* into v_entry
    from public.order_status_history h
    where h.order_id = p_order_id
      and h.id <> all (v_prev_ids)
      and h.new_status = v_after.status
    order by h.created_at desc, h.id desc
    limit 1;

    if not found then
      raise exception 'The status change was not recorded in the order history.'
        using errcode = 'P0001', detail = 'history_missing';
    end if;

    -- Receipt 3: an override only stands when the caller asked for one. The marker is the note
    -- set_order_status() writes for an override; raising here rolls the whole call back.
    if coalesce(p_override, false) is not true and v_entry.note like 'Admin override: %' then
      raise exception 'That status change is not a standard transition. Confirm the administrative override to proceed.'
        using errcode = 'P0001', detail = 'override_not_requested';
    end if;

    -- Phase 6I.2 audit row: only for a real status change that passed every receipt.
    -- Old/new status only; the note is never copied.
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'order_status_changed', p_order_id,
            left(format('%s -> %s%s', v_before.status::text, v_after.status::text,
                        case when v_entry.note like 'Admin override: %' then '; override' else '' end), 500));
  end if;

  return jsonb_build_object(
    'changed', v_changed,
    'previous_status', v_before.status,
    'order', jsonb_build_object(
      'id', v_after.id,
      'order_number', v_after.order_number,
      'status', v_after.status,
      'payment_status', v_after.payment_status,
      'payment_method', v_after.payment_method,
      'delivery_method', v_after.delivery_method,
      'delivery_slot_date', v_after.delivery_slot_date,
      'total_cents', v_after.total_cents,
      'currency', v_after.currency,
      'placed_at', v_after.placed_at,
      'updated_at', v_after.updated_at,
      'restocked_at', v_after.restocked_at),
    'history_entry', case when v_changed then jsonb_build_object(
      'id', v_entry.id,
      'previous_status', v_entry.previous_status,
      'new_status', v_entry.new_status,
      'payment_status', v_entry.payment_status,
      'changed_by', v_entry.changed_by,
      'note', v_entry.note,
      'created_at', v_entry.created_at) end
  );
end;
$$;

revoke all on function public.admin_set_order_status(uuid, public.order_status, text, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_order_status(uuid, public.order_status, text, boolean)
  to authenticated;

-- =============================================================================
-- 2. admin_create_product()   [from 20261004060000_phase6c1b1_admin_product_create_update.sql]
--    Added: v_actor, one audit row after the INSERT succeeded.
-- =============================================================================
create or replace function public.admin_create_product(
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
  v_actor uuid;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

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

  -- Phase 6I.2 audit row: price only (no name, description, sku or other text).
  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'product_created', v_row.id,
          left(format('price_cents %s; compare_at_price_cents %s',
                      v_row.price_cents, coalesce(v_row.compare_at_price_cents::text, 'none')), 500));

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

revoke all on function public.admin_create_product(text, text, integer, uuid, text, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.admin_create_product(text, text, integer, uuid, text, text, text, text, integer)
  to authenticated;

-- =============================================================================
-- 3. admin_update_product()   [from 20261004060000_phase6c1b1_admin_product_create_update.sql]
--    Added: v_actor, v_changes, one audit row after the UPDATE succeeded AND a stored value differs.
-- =============================================================================
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
  if v_row.name is distinct from v_old.name then v_changes := v_changes || 'name'; end if;
  if v_row.slug is distinct from v_old.slug then v_changes := v_changes || 'slug'; end if;
  if v_row.category_id is distinct from v_old.category_id then v_changes := v_changes || 'category_id'; end if;
  if v_row.description is distinct from v_old.description then v_changes := v_changes || 'description'; end if;
  if v_row.brand is distinct from v_old.brand then v_changes := v_changes || 'brand'; end if;
  if v_row.sku is distinct from v_old.sku then v_changes := v_changes || 'sku'; end if;
  if v_row.unit_label is distinct from v_old.unit_label then v_changes := v_changes || 'unit_label'; end if;
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

-- =============================================================================
-- 4. admin_set_product_active()   [from 20261004070000_phase6c1b2_admin_product_activation_variants.sql]
--    Added: v_actor, v_prev, one audit row inside the "value differs" branch (no-op writes nothing).
-- =============================================================================
create or replace function public.admin_set_product_active(p_product_id uuid, p_is_active boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.products;
  v_actor uuid;
  v_prev boolean;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

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
  -- An unchanged value writes nothing (so updated_at does not move) and is not audited.
  if v_row.is_active is distinct from p_is_active then
    v_prev := v_row.is_active;

    update public.products
    set is_active = p_is_active
    where id = v_row.id
    returning * into v_row;

    -- Phase 6I.2 audit row.
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor,
            case when p_is_active then 'product_activated' else 'product_deactivated' end,
            v_row.id,
            format('is_active %s -> %s', v_prev::text, p_is_active::text));
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

revoke all on function public.admin_set_product_active(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_product_active(uuid, boolean) to authenticated;

-- =============================================================================
-- 5. admin_create_product_variant()   [from 20261004070000_phase6c1b2_admin_product_activation_variants.sql]
--    Added: v_actor, one audit row after the INSERT succeeded.
-- =============================================================================
create or replace function public.admin_create_product_variant(
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
  v_actor uuid;
begin
  -- The gate runs before any argument is examined.
  perform public.require_admin();
  v_actor := auth.uid();

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

  -- Phase 6I.2 audit row: parent product id and price only.
  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'product_variant_created', v_row.id,
          left(format('product %s; price_cents %s; compare_at_price_cents %s',
                      v_row.product_id, v_row.price_cents,
                      coalesce(v_row.compare_at_price_cents::text, 'none')), 500));

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

revoke all on function public.admin_create_product_variant(uuid, text, integer, text, integer, jsonb, integer)
  from public, anon, authenticated;
grant execute on function public.admin_create_product_variant(uuid, text, integer, text, integer, jsonb, integer)
  to authenticated;

-- =============================================================================
-- 6. admin_update_product_variant()   [from 20261004070000_phase6c1b2_admin_product_activation_variants.sql]
--    Added: v_actor, v_changes, one audit row after the UPDATE succeeded AND a stored value differs.
--    Activation / deactivation through this function is recorded as is_active old -> new.
-- =============================================================================
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
  if v_row.name is distinct from v_old.name then v_changes := v_changes || 'name'; end if;
  if v_row.sku is distinct from v_old.sku then v_changes := v_changes || 'sku'; end if;
  if v_row.attributes is distinct from v_old.attributes then v_changes := v_changes || 'attributes'; end if;
  if v_row.position is distinct from v_old.position then v_changes := v_changes || 'position'; end if;
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

-- =============================================================================
-- 7. admin_adjust_inventory()   [from 20261004100000_phase6c2_admin_inventory_adjustment.sql]
--    Added: one audit row right after the inventory_adjustments row. v_actor already existed
--    (require_admin(), verified equal to auth.uid()). The p_note is not recorded.
-- =============================================================================
create or replace function public.admin_adjust_inventory(
  p_product_id uuid,
  p_adjustment_quantity integer,
  p_reason text,
  p_variant_id uuid default null,
  p_note text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_actor uuid;
  v_reason text;
  v_note text;
  v_variant_owner uuid;
  v_previous integer;
  v_new_big bigint;
  v_new integer;
  v_adj_id uuid;
  v_created timestamptz;
begin
  -- 1. The gate runs before any argument is examined and before anything is read or locked.
  v_actor := public.require_admin();

  -- 2. The actor is auth.uid() and nothing else. require_admin() only returns for a real admin,
  --    so a NULL here is unexpected: fail rather than write an unattributed adjustment.
  if v_actor is null or auth.uid() is null or v_actor is distinct from auth.uid() then
    raise exception 'The acting admin could not be determined.'
      using errcode = 'P0001', detail = 'actor_unavailable';
  end if;

  -- 3. Validate the arguments.
  if p_product_id is null or p_adjustment_quantity is null then
    raise exception 'A product id and an adjustment quantity are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_adjustment_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing and is not recorded.'
      using errcode = 'P0001', detail = 'zero_adjustment_not_allowed';
  end if;

  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) not between 1 and 120 then
    raise exception 'A reason of 1 to 120 characters is required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_note is not null then
    v_note := btrim(p_note);
    if char_length(v_note) not between 1 and 500 then
      raise exception 'A note, when given, must be 1 to 500 characters.'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  -- 4. Variant ownership, checked WITHOUT a lock so that the lock order below stays
  --    product -> variant (the order create_order uses). Repeated on the locked row.
  if p_variant_id is not null then
    select v.product_id into v_variant_owner from public.product_variants v where v.id = p_variant_id;
    if not found then
      raise exception 'Variant not found.'
        using errcode = 'P0001', detail = 'variant_not_found';
    end if;
    if v_variant_owner is distinct from p_product_id then
      raise exception 'That variant does not belong to that product.'
        using errcode = 'P0001', detail = 'variant_product_mismatch';
    end if;
  end if;

  -- 5. Lock, read, compute, validate, write.
  if p_variant_id is null then
    -- PRODUCT-level: lock the product row, read its stock.
    select p.stock_quantity into v_previous
    from public.products p
    where p.id = p_product_id
    for update;
    if not found then
      raise exception 'Product not found.'
        using errcode = 'P0001', detail = 'product_not_found';
    end if;
  else
    -- VARIANT-level: product first (KEY SHARE: enough to pin it and to serialise with create_order's
    -- FOR UPDATE), then the variant row, which is the stock being changed.
    perform 1 from public.products p where p.id = p_product_id for key share;
    if not found then
      raise exception 'Product not found.'
        using errcode = 'P0001', detail = 'product_not_found';
    end if;

    select v.stock_quantity into v_previous
    from public.product_variants v
    where v.id = p_variant_id and v.product_id = p_product_id
    for update;
    if not found then
      raise exception 'Variant not found.'
        using errcode = 'P0001', detail = 'variant_not_found';
    end if;
  end if;

  v_new_big := v_previous::bigint + p_adjustment_quantity::bigint;

  if v_new_big < 0 then
    raise exception 'The adjustment would make stock negative (current %, change %).', v_previous, p_adjustment_quantity
      using errcode = 'P0001', detail = 'negative_stock_not_allowed';
  end if;
  if v_new_big > 2147483647 then
    raise exception 'The adjustment would exceed the largest stock quantity (current %, change %).', v_previous, p_adjustment_quantity
      using errcode = 'P0001', detail = 'stock_overflow';
  end if;
  v_new := v_new_big::integer;

  -- Only stock_quantity is assigned. in_stock, prices, flags and (for a variant) the parent
  -- product are not touched.
  if p_variant_id is null then
    update public.products set stock_quantity = v_new where id = p_product_id;
  else
    update public.product_variants set stock_quantity = v_new where id = p_variant_id;
  end if;

  -- Exactly one history row, in the same transaction, with server-computed snapshots.
  insert into public.inventory_adjustments
    (product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity, reason, note, changed_by)
  values
    (p_product_id, p_variant_id, v_previous, p_adjustment_quantity, v_new, v_reason, v_note, v_actor)
  returning id, created_at into v_adj_id, v_created;

  -- Phase 6I.2 audit row: the stock delta and old/new quantity, plus the short required reason.
  -- The optional note is never copied. target_id is the unit whose stock changed.
  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (auth.uid(), 'inventory_adjusted', coalesce(p_variant_id, p_product_id),
          left(format('%s delta %s; stock %s -> %s; %s',
                      case when p_variant_id is null then 'product' else 'variant of product ' || p_product_id::text end,
                      p_adjustment_quantity, v_previous, v_new, v_reason), 500));

  return jsonb_build_object(
    'adjustment_id', v_adj_id,
    'product_id', p_product_id,
    'variant_id', p_variant_id,
    'kind', case when p_variant_id is null then 'product' else 'variant' end,
    'previous_quantity', v_previous,
    'adjustment_quantity', p_adjustment_quantity,
    'new_quantity', v_new,
    'reason', v_reason,
    'note', v_note,
    'created_at', v_created
  );
end;
$fn$;

revoke all on function public.admin_adjust_inventory(uuid, integer, text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_adjust_inventory(uuid, integer, text, uuid, text) to authenticated;

-- =============================================================================
-- 8. SELF-CHECK - refuse to commit unless exactly as designed.
-- =============================================================================
do $chk$
declare
  v_sig text;
  v_targets constant text[] := array[
    'public.admin_set_order_status(uuid,public.order_status,text,boolean)',
    'public.admin_create_product(text,text,integer,uuid,text,text,text,text,integer)',
    'public.admin_update_product(uuid,jsonb)',
    'public.admin_set_product_active(uuid,boolean)',
    'public.admin_create_product_variant(uuid,text,integer,text,integer,jsonb,integer)',
    'public.admin_update_product_variant(uuid,jsonb)',
    'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'
  ];
begin
  foreach v_sig in array v_targets loop
    -- Same attributes as before, and now writes the audit log.
    if exists (select 1 from pg_proc p
               where p.oid = v_sig::regprocedure
                 and (not p.prosecdef
                      or p.provolatile <> 'v'
                      or p.prorettype <> 'jsonb'::regtype
                      or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
                      or p.prosrc not like '%public.require_admin()%'
                      or p.prosrc not like '%insert into public.admin_audit_log%'
                      or p.prosrc not like '%auth.uid()%')) then
      raise exception 'Phase 6I.2 self-check failed: % is not as designed.', v_sig;
    end if;

    if has_function_privilege('anon', v_sig, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_sig::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'Phase 6I.2 self-check failed: % grants are wrong.', v_sig;
    end if;
  end loop;

  -- Exactly the seven functions were replaced; nothing was added, removed or changed elsewhere.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from current_setting('p6i2.fn_count', true) then
    raise exception 'Phase 6I.2 self-check failed: the number of public functions changed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.oid <> all (select t::regprocedure::oid from unnest(v_targets) t))
     is distinct from current_setting('p6i2.other_fn_hash', true) then
    raise exception 'Phase 6I.2 self-check failed: a function outside the seven changed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.oid = any (select t::regprocedure::oid from unnest(v_targets) t))
     is distinct from current_setting('p6i2.target_acl_hash', true) then
    raise exception 'Phase 6I.2 self-check failed: a function ACL changed.';
  end if;

  -- No table grant, RLS flag or trigger changed (the audit log stays append-only, 6I.1 intact).
  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p'))
     is distinct from current_setting('p6i2.table_acl_hash', true) then
    raise exception 'Phase 6I.2 self-check failed: a table grant or RLS flag changed.';
  end if;
  if (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                     '|' order by t.tgrelid::regclass::text, t.tgname), ''))
      from pg_trigger t
      where not t.tgisinternal
        and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace))
     is distinct from current_setting('p6i2.trigger_hash', true) then
    raise exception 'Phase 6I.2 self-check failed: a trigger changed.';
  end if;

  -- Installing the functions wrote no audit rows.
  if (select count(*) from public.admin_audit_log)::text is distinct from current_setting('p6i2.audit_count', true) then
    raise exception 'Phase 6I.2 self-check failed: the migration itself wrote audit rows.';
  end if;
end
$chk$;

commit;
