-- =============================================================================
-- Order integrity hardening.
--
-- Apply AFTER 20260930010000_orders_delivery_admin.sql (SQL editor, or
-- `supabase db push`). This migration only changes objects created there.
--
-- Gaps in the previous create_order() that this closes:
--   1. Stock was verified but never decremented, so two orders could both pass
--      the check and oversell the same units. Stock is now decremented in the
--      same transaction, under the row locks the function already takes.
--   2. Repeated lines for the same product/variant were checked one by one.
--      They are now merged before checking, in a stable lock order.
--   3. The delivery slot times were trusted from the client. The slot must now
--      match an active delivery_slot_templates row for that weekday, respect a
--      lead time and a booking horizon, and its label is read from the template.
--      "Today" is evaluated in Africa/Nairobi, not UTC.
--   4. The customer could be charged a total they never saw if a price or fee
--      changed between page load and submit. The client may now send the total
--      it displayed (p_expected_total_cents); the database still computes the
--      real total and rejects the order when the two differ. The client value is
--      only ever used to REFUSE an order, never to set an amount.
--   5. Cancelling an order now returns its units to stock.
--   6. Staff could update any column of an order from the browser. Update is now
--      limited to the fulfilment `status` column, so money, snapshots and
--      payment_status are immutable from the browser. payment_status changes only
--      through the service role (verified webhooks), as AGENTS.md requires.
--
-- Review fixes applied before first execution:
--   * replays of one idempotency key are serialised with an advisory lock;
--   * restock no longer credits a product for a line whose variant was deleted;
--   * order status is cast to the enum explicitly.
--
-- Slot capacity (delivery_slot_templates.capacity) is still NOT enforced.
-- =============================================================================

-- The signature changes (new trailing parameter), so drop the old overload to
-- avoid leaving two callable versions behind.
drop function if exists public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text
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
  p_expected_total_cents integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_slot_lead interval := interval '60 minutes';
  c_slot_horizon_days integer := 14;

  v_user uuid := auth.uid();
  v_local_now timestamp := (now() at time zone 'Africa/Nairobi');
  v_existing uuid;
  v_method public.delivery_methods%rowtype;
  v_address public.addresses%rowtype;
  v_address_snapshot jsonb := null;
  v_slot public.delivery_slot_templates%rowtype;
  v_slot_date date := null;
  v_slot_start time := null;
  v_slot_end time := null;
  v_slot_label text := null;
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

  -- ---- Delivery method ------------------------------------------------------
  select * into v_method
  from public.delivery_methods
  where code = p_delivery_method and is_active;
  if not found then
    raise exception 'That delivery method is not available.' using errcode = 'P0001';
  end if;

  -- ---- Address (snapshotted so later edits never rewrite the order) ---------
  if v_method.requires_address then
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

  -- ---- Delivery slot --------------------------------------------------------
  if v_method.requires_slot then
    if p_slot_date is null or p_slot_start is null or p_slot_end is null then
      raise exception 'Choose a delivery slot.' using errcode = 'P0001';
    end if;

    select t.* into v_slot
    from public.delivery_slot_templates t
    where t.is_active
      and t.start_time = p_slot_start
      and t.end_time = p_slot_end
      and (t.day_of_week is null or t.day_of_week = extract(dow from p_slot_date)::integer)
    order by t.position
    limit 1;
    if not found then
      raise exception 'That delivery slot is not available. Pick another slot.' using errcode = 'P0001';
    end if;

    if (p_slot_date + p_slot_start) < (v_local_now + c_slot_lead) then
      raise exception 'That delivery slot is no longer available. Pick another slot.'
        using errcode = 'P0001';
    end if;

    if p_slot_date > (v_local_now::date + c_slot_horizon_days) then
      raise exception 'Delivery slots can only be booked up to % days ahead.', c_slot_horizon_days
        using errcode = 'P0001';
    end if;

    v_slot_date := p_slot_date;
    v_slot_start := v_slot.start_time;
    v_slot_end := v_slot.end_time;
    v_slot_label := v_slot.label;
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

  if v_subtotal < v_method.min_order_cents then
    raise exception 'This delivery method needs a larger order.' using errcode = 'P0001';
  end if;

  v_delivery_fee := case
    when v_method.free_over_cents is not null and v_subtotal >= v_method.free_over_cents then 0
    else v_method.base_fee_cents
  end;

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
    customer_notes, idempotency_key
  ) values (
    v_user, public.next_order_number(), v_status, 'pending', p_payment_method,
    v_subtotal, v_delivery_fee, v_discount, v_total,
    v_method.code, v_address_snapshot, case when v_method.requires_address then p_address_id else null end,
    v_slot_date, v_slot_start, v_slot_end, v_slot_label,
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
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer
) from public, anon;
grant execute on function public.create_order(
  jsonb, text, public.payment_method, uuid, date, time, time, text, text, text, integer
) to authenticated;

-- =============================================================================
-- RESTOCK ON CANCELLATION
--
-- create_order() now reserves stock, so a cancelled order must give it back.
-- Only orders that had not yet been delivered or refunded are restocked, and
-- only on the transition INTO 'cancelled', so it cannot run twice for one order.
-- (Moving an order back OUT of 'cancelled' does not re-reserve stock.)
-- =============================================================================
create or replace function public.restock_cancelled_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'cancelled' and old.status not in ('cancelled', 'refunded', 'delivered') then
    update public.products p
      set stock_quantity = p.stock_quantity + i.qty
      from (
        select product_id, sum(quantity)::integer as qty
        from public.order_items
        where order_id = new.id
          and product_id is not null
          and variant_id is null
          and variant_name is null
        group by product_id
      ) i
      where p.id = i.product_id;

    update public.product_variants v
      set stock_quantity = v.stock_quantity + i.qty
      from (
        select variant_id, sum(quantity)::integer as qty
        from public.order_items
        where order_id = new.id and variant_id is not null
        group by variant_id
      ) i
      where v.id = i.variant_id;
  end if;
  return new;
end;
$$;

revoke execute on function public.restock_cancelled_order() from public, anon, authenticated;

drop trigger if exists orders_restock_on_cancel on public.orders;
create trigger orders_restock_on_cancel
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.restock_cancelled_order();

-- =============================================================================
-- ORDERS: staff may change the fulfilment status only
--
-- The "Orders: staff update" policy is row-level. Without a column limit a
-- staff session could rewrite totals or the address snapshot. Money, snapshot
-- and payment_status columns are now immutable from the browser under every
-- role; only the service role (server code / webhooks) keeps full access.
-- NOTE: `status` still contains 'paid' and 'refunded'. Decide before building an
-- admin UI whether staff may set those from the browser.
-- =============================================================================
revoke update on public.orders from authenticated;
grant update (status) on public.orders to authenticated;
