-- =============================================================================
-- PHASE 6E.3 - customer hardening (backend only). NOT APPLIED / NOT RUN on any Supabase project.
-- Apply once, after 20261004160000. One transaction. Corrective: no earlier migration is edited.
--
-- 1. SUSPENDED CUSTOMERS CANNOT ORDER. create_order() (same 12-argument signature, grants and
--    return type; CREATE OR REPLACE, no overload) now reads profiles.status right after the
--    signed-in check and, if it is 'suspended', raises P0001 with DETAIL 'account_suspended'.
--    The check runs BEFORE the idempotency lookup (replay of an earlier checkout is refused too)
--    and before any stock is reserved: no stock moves and no order row is written. Only the
--    suspended customer is affected; reactivation (admin_set_customer_status -> 'active') works
--    at once. The body is otherwise byte-identical to the 20261003010000 definition: two edits,
--    marked "Phase 6E.3" below (one variable, one check).
--    The checkout UI does not know 'account_suspended' yet and will show the database message;
--    mapping it in the front end is a separate follow-up (no frontend change here).
-- 2. NOTES AND AUDIT ARE ADMIN-ONLY TO READ. The SELECT policies on admin_audit_log and
--    customer_notes used is_staff(); they now use is_admin(). Staff (non-admin) see 0 rows through
--    the API. Admins still read through the API; the admin_* functions are unchanged.
-- 3. profiles.status CANNOT BE INSERTED BY BROWSER ROLES. authenticated held a table-level INSERT
--    on profiles (the 6E.1B-1 self-check covered UPDATE only). That table-level INSERT is revoked
--    and re-granted on every column EXCEPT status, so a browser insert can only get the default
--    'active'. The "Profiles: insert own" policy, the signup trigger and service_role are untouched.
--
-- DOES NOT: add features, change the front end, change admin_* functions, or touch any other grant.
-- Refuses to run twice (see the precondition).
-- =============================================================================
begin;

do $pre$
declare
  v_co constant text := 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)';
  v_count integer;
begin
  -- 20261004160000 (and everything before it) must be applied.
  if to_regprocedure('public.admin_list_customers(text,integer,integer,text)') is null
     or to_regprocedure('public.admin_list_customers(text,integer,integer)') is not null
     or to_regprocedure('public.admin_get_customer(uuid)') is null
     or to_regprocedure('public.admin_set_customer_status(uuid,text,text)') is null
     or to_regprocedure('public.admin_update_customer_notes(uuid,text)') is null
     or to_regprocedure('public.is_admin(uuid)') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regclass('public.customer_notes') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'profiles' and column_name = 'status')
     or not exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.admin_get_customer(uuid)')
                    and p.prosrc like '%notes_updated_at%') then
    raise exception 'Phase 6E.3 precondition failed: apply every migration up to 20261004160000 first.';
  end if;

  -- Refuse to run twice.
  if exists (select 1 from pg_policies where schemaname = 'public'
             and policyname in ('Audit log: admin read', 'Customer notes: admin read'))
     or exists (select 1 from pg_proc p where p.oid = to_regprocedure(v_co) and p.prosrc like '%account_suspended%') then
    raise exception 'Phase 6E.3 appears to be applied already. Not running it twice.';
  end if;

  -- The policies this migration replaces must be the 6E.1B ones.
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'admin_audit_log'
        and policyname = 'Audit log: staff read') <> 1
     or (select count(*) from pg_policies where schemaname = 'public' and tablename = 'customer_notes'
           and policyname = 'Customer notes: staff read') <> 1 then
    raise exception 'Phase 6E.3 precondition failed: the 6E.1B staff-read policies are not as expected.';
  end if;

  -- create_order() is replaced below: it must be the single 12-argument function exactly as
  -- defined in 20261003010000 (body md5 0e4c6ce8d44e2a4490f45b1ce9f428a6). Anything else was changed by hand
  -- or by a later migration; compare before continuing.
  select count(*) into v_count from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace;
  if v_count <> 1 or to_regprocedure(v_co) is null then
    raise exception 'Phase 6E.3 precondition failed: expected exactly one 12-argument create_order(), found % overload(s).', v_count;
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(v_co)) <> '0e4c6ce8d44e2a4490f45b1ce9f428a6' then
    raise exception 'Phase 6E.3 precondition failed: create_order() in this database differs from migration 20261003010000. This migration replaces it, so compare the two before continuing.';
  end if;
end
$pre$;

-- =============================================================================
-- 1. create_order(): refuse suspended customers (same signature, return type and grants)
-- =============================================================================
create or replace function public.create_order(
  p_items jsonb,
  p_delivery_method text,
  p_payment_method public.payment_method,
  p_address_id uuid default null,
  p_slot_date date default null,
  p_slot_start time default null,
  p_slot_end time default null,
  -- Accepted for backwards compatibility and ignored: the stored label always
  -- comes from the matching slot template.
  p_slot_label text default null,
  p_notes text default null,
  p_idempotency_key text default null,
  p_expected_total_cents integer default null,
  -- The delivery zone. Required when the method requires an address. The caller chooses
  -- it; there is no address -> zone mapping yet (Phase 4C.2).
  p_zone_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_account_status text;  -- Phase 6E.3
  v_existing uuid;
  v_delivery record;
  v_slot record;
  v_address public.addresses%rowtype;
  v_address_snapshot jsonb := null;
  v_slot_date date := null;
  v_slot_start time := null;
  v_slot_end time := null;
  v_slot_label text := null;
  v_slot_template_id uuid := null;
  v_item record;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_unit_price integer;
  v_available integer;
  v_subtotal integer := 0;
  v_delivery_fee integer := 0;
  v_discount integer := 0;
  v_total integer;
  v_order_id uuid;
  v_item_count integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_status public.order_status;
  v_requires_address boolean;
  v_zone_id uuid := null;
  v_covering_zones uuid[] := '{}';
  v_zone_active boolean;
begin
  if v_user is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
  end if;

  -- Phase 6E.3: a suspended customer cannot order. Checked BEFORE the idempotency lookup (so a
  -- replay of an earlier checkout is refused too) and before any stock is touched, so a refusal
  -- reserves nothing and writes no order row. FOR SHARE makes it serial with
  -- admin_set_customer_status() (FOR UPDATE on the same row): once a suspension has committed, no
  -- checkout can slip past it. A signed-in user with no profile row is not blocked.
  select p.status into v_account_status from public.profiles p where p.id = v_user for share;
  if v_account_status = 'suspended' then
    raise exception 'Your account is suspended, so you cannot place orders. Please contact support.'
      using errcode = 'P0001', detail = 'account_suspended';
  end if;

  -- Idempotency: replaying the same checkout returns the original order.
  -- The advisory lock makes a concurrent duplicate WAIT for the first submission to
  -- commit instead of racing it for the same stock (which could otherwise fail the
  -- duplicate with "Only 0 left" although its twin already succeeded).
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_user::text || ':' || p_idempotency_key, 0));
    select id into v_existing
    from public.orders
    where user_id = v_user and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- ---- Basket shape ---------------------------------------------------------
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your basket is empty.' using errcode = 'P0001';
  end if;

  if jsonb_array_length(p_items) > 100 then
    raise exception 'Your basket has too many lines. Remove some items and try again.'
      using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
    where x.product_id is null or x.quantity is null or x.quantity < 1 or x.quantity > 99
  ) then
    raise exception 'One of the basket items is invalid. Refresh your basket.' using errcode = 'P0001';
  end if;

  -- ---- Lines: authoritative price, availability and stock -------------------
  -- Merge duplicate lines and lock rows in a stable order (no deadlocks between
  -- concurrent checkouts that share products).
  for v_item in
    select x.product_id, x.variant_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(product_id uuid, variant_id uuid, quantity integer)
    group by x.product_id, x.variant_id
    order by x.product_id, x.variant_id
  loop
    if v_item.quantity > 99 then
      raise exception 'Quantities must be between 1 and 99.' using errcode = 'P0001';
    end if;

    select * into v_product from public.products where id = v_item.product_id for update;
    if not found or not v_product.is_active then
      raise exception 'A product in your basket is no longer available. Update your basket and try again.'
        using errcode = 'P0001';
    end if;

    if v_item.variant_id is not null then
      select * into v_variant
      from public.product_variants
      where id = v_item.variant_id and product_id = v_product.id
      for update;
      if not found or not v_variant.is_active then
        raise exception 'A product option in your basket is no longer available: %', v_product.name
          using errcode = 'P0001';
      end if;
      v_unit_price := v_variant.price_cents;
      v_available := v_variant.stock_quantity;
    else
      v_variant := null;
      v_unit_price := v_product.price_cents;
      v_available := v_product.stock_quantity;
      if not v_product.in_stock then
        raise exception 'Out of stock: %. Remove it from your basket to continue.', v_product.name
          using errcode = 'P0001';
      end if;
    end if;

    if v_available < v_item.quantity then
      raise exception 'Only % left of %. Reduce the quantity and try again.', greatest(v_available, 0), v_product.name
        using errcode = 'P0001';
    end if;

    -- Reserve the stock now. The row is locked, so no concurrent checkout can
    -- read the old quantity; the whole function rolls back if anything below fails.
    if v_item.variant_id is not null then
      update public.product_variants
        set stock_quantity = stock_quantity - v_item.quantity
        where id = v_variant.id;
    else
      update public.products
        set stock_quantity = stock_quantity - v_item.quantity
        where id = v_product.id;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id,
      'variant_id', v_item.variant_id,
      'product_name', v_product.name,
      'product_slug', v_product.slug,
      'sku', coalesce(v_variant.sku, v_product.sku),
      'variant_name', v_variant.name,
      'variant_attributes', v_variant.attributes,
      'unit_label', v_product.unit_label,
      'image_url', v_product.image_url,
      'unit_price_cents', v_unit_price,
      'quantity', v_item.quantity,
      'line_total_cents', v_unit_price * v_item.quantity
    );

    v_subtotal := v_subtotal + (v_unit_price * v_item.quantity);
    v_item_count := v_item_count + 1;
  end loop;

  if v_item_count = 0 then
    raise exception 'Your basket is empty.' using errcode = 'P0001';
  end if;

  -- ---- Delivery method, address and zone (Phase 4B.1, hardened in Phase 5B.2) ----
  -- For address delivery the customer's own address is loaded FIRST, and the delivery zone is
  -- derived from / validated against it. The client can no longer simply pick the cheapest
  -- zone: a zone that does not cover the address is rejected. For methods without an address
  -- any p_zone_id is ignored.
  select m.requires_address into v_requires_address
  from public.delivery_methods m
  where m.code = p_delivery_method and m.is_active;
  -- Not found (unknown / inactive method): v_requires_address stays NULL and the call to
  -- validate_delivery_selection() below rejects it with the proper error code.

  if v_requires_address is true then
    if p_address_id is null then
      raise exception 'Choose a delivery address.' using errcode = 'P0001';
    end if;
    select * into v_address
    from public.addresses
    where id = p_address_id and user_id = v_user;
    if not found then
      raise exception 'That delivery address could not be found.' using errcode = 'P0001';
    end if;
    v_address_snapshot := jsonb_build_object(
      'full_name', v_address.full_name,
      'phone', v_address.phone,
      'label', v_address.label,
      'address_line_1', v_address.address_line_1,
      'address_line_2', v_address.address_line_2,
      'city', v_address.city,
      'county', v_address.county,
      'postal_code', v_address.postal_code,
      'delivery_instructions', v_address.delivery_instructions
    );

    select coalesce(array_agg(z.id order by z.position, z.id), '{}')
      into v_covering_zones
    from public.delivery_zones z
    where z.is_active
      and public.delivery_zone_covers_address(z.id, v_address.county, v_address.city);

    if p_zone_id is not null then
      -- Existence / activity of this zone is checked by validate_delivery_selection() below;
      -- whether it matches the address is checked right after it.
      v_zone_id := p_zone_id;
    elsif cardinality(v_covering_zones) = 1 then
      v_zone_id := v_covering_zones[1];
    elsif cardinality(v_covering_zones) = 0 then
      raise exception 'We do not deliver to that address yet. Choose another address or collect in store.'
        using errcode = 'P0001', detail = 'zone_unserviceable';
    else
      raise exception 'Choose the delivery area that covers your address.'
        using errcode = 'P0001', detail = 'zone_required';
    end if;
  end if;

  -- v_subtotal was computed above from locked, authoritative prices. The fee and the
  -- minimum order come ONLY from this call (-> resolve_delivery_fee()), using the zone
  -- validated above (NULL for methods without an address).
  select * into v_delivery
  from public.validate_delivery_selection(p_delivery_method, v_zone_id, v_subtotal);

  if not found or v_delivery.is_valid is not true then
    raise exception '%', coalesce(v_delivery.error_message, 'That delivery option is not available.')
      using errcode = 'P0001', detail = coalesce(v_delivery.error_code, 'unavailable');
  end if;

  -- A "valid" row without a fee must never be read as free delivery.
  if v_delivery.fee_cents is null or v_delivery.fee_cents < 0 or v_delivery.fee_rule is null then
    raise exception 'That delivery option is not available right now.'
      using errcode = 'P0001', detail = 'unavailable';
  end if;

  -- The method's address requirement must still be what was read above.
  if v_delivery.requires_address is distinct from coalesce(v_requires_address, false) then
    raise exception 'That delivery option is not available right now.'
      using errcode = 'P0001', detail = 'unavailable';
  end if;

  -- The zone must cover the address (a zone from the client, or one derived above).
  if v_delivery.requires_address and not (v_delivery.zone_id = any (v_covering_zones)) then
    raise exception 'That delivery area does not match your delivery address.'
      using errcode = 'P0001', detail = 'zone_address_mismatch';
  end if;

  -- A zone sent with a method that has no address is never used for pricing or stored, but a
  -- zone that does not exist or is inactive is still rejected, as before.
  if not v_delivery.requires_address and p_zone_id is not null then
    select z.is_active into v_zone_active from public.delivery_zones z where z.id = p_zone_id;
    if not found then
      raise exception 'That delivery area does not exist.'
        using errcode = 'P0001', detail = 'zone_unknown';
    elsif not v_zone_active then
      raise exception 'We do not currently deliver to that area.'
        using errcode = 'P0001', detail = 'zone_inactive';
    end if;
  end if;

  v_delivery_fee := v_delivery.fee_cents;

  -- ---- Delivery slot: lock, THEN validate, in THIS transaction (Phase 4B.2) -
  -- lock_delivery_slot() takes the transaction-scoped advisory lock for this exact
  -- date/start/end and re-counts usage after the lock is granted, so the capacity decision
  -- is made on the row returned here, never on an earlier preview. The lock is released at
  -- COMMIT or ROLLBACK, i.e. when the order below is visible to the next checkout (or
  -- never created). A method that does not require a slot skips this entirely.
  if v_delivery.requires_slot then
    select * into v_slot
    from public.lock_delivery_slot(p_slot_date, p_slot_start, p_slot_end);

    if not found or v_slot.is_valid is not true then
      raise exception '%', coalesce(v_slot.error_message, 'That delivery slot is not available. Pick another slot.')
        using errcode = 'P0001', detail = coalesce(v_slot.error_code, 'slot_unknown');
    end if;

    v_slot_date := v_slot.slot_date;
    v_slot_start := v_slot.slot_start;
    v_slot_end := v_slot.slot_end;
    v_slot_label := v_slot.label;
    v_slot_template_id := v_slot.template_id;
  end if;

  -- Promotions are a later phase; discounts stay authoritative at zero.
  v_discount := 0;

  v_total := v_subtotal + v_delivery_fee - v_discount;

  -- The client's expected total can only veto an order, never change an amount.
  if p_expected_total_cents is not null and p_expected_total_cents <> v_total then
    raise exception 'Prices or delivery fees have changed since you last looked. Review your total and try again.'
      using errcode = 'P0001';
  end if;

  -- Payment is never confirmed here. Cash on delivery still owes money, so it
  -- starts pending too; it simply does not wait on a gateway.
  v_status := (
    case when p_payment_method = 'cash_on_delivery' then 'pending' else 'awaiting_payment' end
  )::public.order_status;

  insert into public.orders (
    user_id, order_number, status, payment_status, payment_method,
    subtotal_cents, delivery_fee_cents, discount_cents, total_cents,
    delivery_method, delivery_address, delivery_address_id,
    delivery_slot_date, delivery_slot_start, delivery_slot_end, delivery_slot_label,
    delivery_zone_id, delivery_zone_code, delivery_zone_name, delivery_method_label,
    delivery_slot_template_id, delivery_fee_rule,
    customer_notes, idempotency_key
  ) values (
    v_user, public.next_order_number(), v_status, 'pending', p_payment_method,
    v_subtotal, v_delivery_fee, v_discount, v_total,
    v_delivery.method_code, v_address_snapshot,
    case when v_delivery.requires_address then p_address_id else null end,
    v_slot_date, v_slot_start, v_slot_end, v_slot_label,
    v_delivery.zone_id, v_delivery.zone_code, v_delivery.zone_name, v_delivery.method_label,
    v_slot_template_id, v_delivery.fee_rule,
    nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_idempotency_key, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, product_slug, sku,
    variant_name, variant_attributes, unit_label, image_url,
    unit_price_cents, quantity, line_total_cents
  )
  select
    v_order_id, l.product_id, l.variant_id, l.product_name, l.product_slug, l.sku,
    l.variant_name, l.variant_attributes, l.unit_label, l.image_url,
    l.unit_price_cents, l.quantity, l.line_total_cents
  from jsonb_to_recordset(v_lines) as l(
    product_id uuid,
    variant_id uuid,
    product_name text,
    product_slug text,
    sku text,
    variant_name text,
    variant_attributes jsonb,
    unit_label text,
    image_url text,
    unit_price_cents integer,
    quantity integer,
    line_total_cents integer
  );

  return v_order_id;
exception
  when unique_violation then
    -- Two concurrent submissions of the same checkout: the losing transaction's
    -- stock changes are rolled back with it; return the winner's order.
    if p_idempotency_key is not null then
      select id into v_existing
      from public.orders
      where user_id = v_user and idempotency_key = p_idempotency_key;
      if v_existing is not null then
        return v_existing;
      end if;
    end if;
    raise;
end;
$$;


-- =============================================================================
-- 2. Notes and audit log: SELECT is admin-only (was staff)
-- =============================================================================
drop policy "Audit log: staff read" on public.admin_audit_log;
create policy "Audit log: admin read"
  on public.admin_audit_log for select to authenticated
  using (public.is_admin(auth.uid()));

drop policy "Customer notes: staff read" on public.customer_notes;
create policy "Customer notes: admin read"
  on public.customer_notes for select to authenticated
  using (public.is_admin(auth.uid()));

-- =============================================================================
-- 3. profiles: no INSERT on the status column for browser roles
-- Table-level INSERT is revoked and re-granted on every current column except status.
-- =============================================================================
revoke insert on public.profiles from public, anon, authenticated;

do $grant$
declare v_cols text;
begin
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into v_cols
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'profiles' and c.column_name <> 'status';
  execute format('grant insert (%s) on public.profiles to authenticated', v_cols);
end
$grant$;

-- =============================================================================
-- 4. Self-check
-- =============================================================================
do $check$
declare
  v_co constant text := 'public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)';
  v_src text;
  v_col text;
begin
  -- create_order(): one overload, SECURITY DEFINER, pinned search_path, unchanged privileges,
  -- suspension check present and BEFORE the idempotency lock, rest of the body intact.
  if (select count(*) from pg_proc where proname = 'create_order' and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception 'Phase 6E.3 self-check failed: create_order() overload count is not 1.';
  end if;
  select p.prosrc into v_src from pg_proc p where p.oid = v_co::regprocedure
    and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%';
  if v_src is null then
    raise exception 'Phase 6E.3 self-check failed: create_order() is not SECURITY DEFINER with a pinned search_path.';
  end if;
  if strpos(v_src, 'account_suspended') = 0
     or strpos(v_src, 'account_suspended') > strpos(v_src, 'pg_advisory_xact_lock')
     or strpos(v_src, 'from public.profiles p where p.id = v_user') = 0
     or strpos(v_src, 'zone_address_mismatch') = 0 or strpos(v_src, 'when unique_violation') = 0 then
    raise exception 'Phase 6E.3 self-check failed: create_order() body is not as expected.';
  end if;
  if has_function_privilege('anon', v_co, 'EXECUTE') or not has_function_privilege('authenticated', v_co, 'EXECUTE') then
    raise exception 'Phase 6E.3 self-check failed: create_order() privileges are wrong (authenticated only).';
  end if;

  -- Policies: exactly one SELECT policy each, authenticated, admin-only.
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'admin_audit_log') <> 1
     or (select count(*) from pg_policies where schemaname = 'public' and tablename = 'customer_notes') <> 1
     or exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('admin_audit_log', 'customer_notes')
                and (cmd <> 'SELECT' or roles <> '{authenticated}'::name[]
                     or qual not like '%is_admin%' or qual like '%is_staff%')) then
    raise exception 'Phase 6E.3 self-check failed: admin_audit_log and customer_notes must each have exactly one admin-only SELECT policy.';
  end if;
  if has_table_privilege('authenticated', 'public.admin_audit_log', 'INSERT')
     or has_table_privilege('authenticated', 'public.admin_audit_log', 'UPDATE')
     or has_table_privilege('authenticated', 'public.admin_audit_log', 'DELETE')
     or has_table_privilege('authenticated', 'public.customer_notes', 'INSERT')
     or has_table_privilege('authenticated', 'public.customer_notes', 'UPDATE')
     or has_table_privilege('authenticated', 'public.customer_notes', 'DELETE')
     or has_table_privilege('anon', 'public.admin_audit_log', 'SELECT')
     or has_table_privilege('anon', 'public.customer_notes', 'SELECT')
     or not (select relrowsecurity from pg_class where oid = 'public.admin_audit_log'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.customer_notes'::regclass) then
    raise exception 'Phase 6E.3 self-check failed: audit / notes table access is wrong.';
  end if;

  -- profiles.status: no INSERT or UPDATE for any browser role, at table or column level.
  if has_column_privilege('authenticated', 'public.profiles', 'status', 'INSERT')
     or has_column_privilege('anon', 'public.profiles', 'status', 'INSERT')
     or has_column_privilege('authenticated', 'public.profiles', 'status', 'UPDATE')
     or has_column_privilege('anon', 'public.profiles', 'status', 'UPDATE')
     or has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     or has_table_privilege('anon', 'public.profiles', 'INSERT') then
    raise exception 'Phase 6E.3 self-check failed: a browser role can still INSERT or UPDATE profiles.status.';
  end if;
  -- ... and the other columns are still insertable by authenticated (own-profile insert keeps working).
  foreach v_col in array array['id', 'full_name', 'phone', 'email', 'avatar_url'] loop
    if not has_column_privilege('authenticated', 'public.profiles', v_col, 'INSERT') then
      raise exception 'Phase 6E.3 self-check failed: authenticated lost INSERT on profiles.%.', v_col;
    end if;
  end loop;
  if not has_table_privilege('authenticated', 'public.profiles', 'SELECT') then
    raise exception 'Phase 6E.3 self-check failed: authenticated lost SELECT on profiles.';
  end if;
end
$check$;

commit;
