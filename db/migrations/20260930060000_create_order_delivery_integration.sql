-- =============================================================================
-- create_order() delivery integration (PHASE 4C.1).
--
-- STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
--
-- Apply AFTER 20260930050000_delivery_slot_validation.sql (SQL editor, or
-- `supabase db push`). Apply it ONCE: it drops the previous 11-argument create_order()
-- overload and creates a 12-argument one. Do not re-run migration 020000 afterwards (it
-- would recreate the old overload next to this one and make calls ambiguous).
--
-- What changes (only create_order(); no table, policy or other function is touched):
--   * New trailing parameter p_zone_id uuid default null. Nothing else about the argument
--     list changes. p_slot_label is still accepted and ignored.
--   * The inline delivery code is REMOVED and replaced by the Phase 4B functions:
--       - method lookup, zone validation, delivery fee and minimum order
--           -> validate_delivery_selection(method, zone, SERVER-computed subtotal)
--       - slot template match, 60 min lead time, 14 day horizon, capacity
--           -> lock_delivery_slot(date, start, end), inside this same transaction,
--              BEFORE the order is inserted
--   * The fee is read from validate_delivery_selection(); the old
--     "free_over / base_fee" CASE in this function is gone. Nothing the client sends can
--     set a fee.
--   * The order row now stores the historical delivery snapshot columns added in 4A:
--     delivery_zone_id / _code / _name, delivery_method_label, delivery_slot_template_id,
--     delivery_fee_rule.
--
-- Order of operations (everything is one transaction; any RAISE rolls all of it back,
-- including the stock decrements and the advisory locks):
--   1. signed-in check, idempotency lock + replay                       (unchanged)
--   2. basket shape                                                     (unchanged)
--   3. lines: lock products/variants, authoritative prices, stock decrement,
--      subtotal                                                         (unchanged)
--   4. validate_delivery_selection(method, zone, subtotal)  -> reject, or fee + snapshot
--   5. address check + snapshot (only when the method requires an address)  (unchanged)
--   6. lock_delivery_slot(date, start, end) (only when the method requires a slot)
--      -> reject, or the slot identity actually reserved
--   7. total = subtotal + validated fee - discount; expected-total veto (unchanged rule)
--   8. insert order + items; return
--
-- Lock order is always: idempotency lock -> product/variant rows -> slot lock. A checkout
-- that holds the slot lock never waits for a product row afterwards (it only inserts), so
-- two checkouts cannot wait on each other in a cycle.
--
-- Behaviour changes to be aware of:
--   * Delivery errors are now raised AFTER basket errors (the method used to be checked
--     before the lines). The rejected message is unchanged for an unavailable method
--     ("That delivery method is not available." is now "That delivery method does not
--     exist." for an unknown code, and the same inactive message for an inactive one).
--     The machine-readable validation code is returned in the exception DETAIL.
--   * Address delivery now REQUIRES p_zone_id (validate_delivery_selection() rule:
--     zone_required). The current checkout page does not send one, so address delivery is
--     rejected with "Choose a delivery area." until Phase 4C.2 adds zone selection.
--     Pickup (requires_address = false) does not need a zone.
--   * Slot capacity is now enforced (it was not before).
--
-- Not changed: idempotency, stock, price, expected-total, status rules, restock trigger,
-- grants model (authenticated only).
-- =============================================================================

drop function if exists public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer
);

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
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
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
begin
  if v_user is null then
    raise exception 'You must be signed in to place an order.' using errcode = '42501';
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

  -- ---- Delivery method + zone + fee + minimum order (Phase 4B.1) -----------
  -- v_subtotal was computed above from locked, authoritative prices. The fee and the
  -- minimum order come ONLY from this call (-> resolve_delivery_fee()).
  select * into v_delivery
  from public.validate_delivery_selection(p_delivery_method, p_zone_id, v_subtotal);

  if not found or v_delivery.is_valid is not true then
    raise exception '%', coalesce(v_delivery.error_message, 'That delivery option is not available.')
      using errcode = 'P0001', detail = coalesce(v_delivery.error_code, 'unavailable');
  end if;

  -- A "valid" row without a fee must never be read as free delivery.
  if v_delivery.fee_cents is null or v_delivery.fee_cents < 0 or v_delivery.fee_rule is null then
    raise exception 'That delivery option is not available right now.'
      using errcode = 'P0001', detail = 'unavailable';
  end if;

  v_delivery_fee := v_delivery.fee_cents;

  -- ---- Address (snapshotted so later edits never rewrite the order) ---------
  if v_delivery.requires_address then
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
  end if;

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

revoke execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer, uuid
) from public, anon;
grant execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer, uuid
) to authenticated;
