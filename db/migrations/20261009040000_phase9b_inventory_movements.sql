-- =============================================================================
-- PHASE 9B - Inventory movements and low-stock (extends public.inventory_adjustments; no new table).
--
-- STATUS: written, NOT APPLIED to any database. Apply ONCE, after
-- 20261009030000_phase9a_catalog_integrity.sql. One transaction: any failing statement or the final
-- self-check rolls everything back. Section 0 refuses to run a second time. No older migration is edited.
--
-- WHAT EXISTED
--   public.inventory_adjustments  the ledger (6C.2.2A.1). Only admin_adjust_inventory() wrote it.
--   products / product_variants   stock_quantity integer not null with CHECK >= 0 (the stock authority).
--   create_order() deducts stock; restock_cancelled_order() (BEFORE UPDATE OF status on orders) returns
--   it on cancel and takes it again on reactivation. Neither wrote the ledger. They are NOT edited here
--   (their source is hash-checked by the self-check).
--
-- WHAT THIS ADDS
--   1. inventory_adjustments.order_id uuid NULL -> orders(id) ON DELETE RESTRICT, and
--      inventory_adjustments.movement_kind text NOT NULL default 'admin_adjustment' with a CHECK:
--        admin_adjustment   written by admin_adjust_inventory() (every pre-existing row)
--        order_restock      stock returned by cancelling an order        (order_id set)
--        order_reactivation stock taken again by reactivating an order   (order_id set)
--        stock_change       any other change of stock_quantity (see ORDER DEDUCTIONS below)
--      CHECK: order_id is only ever set on order_restock / order_reactivation rows.
--   2. ONE row per stock change, written by an AFTER trigger on products and on product_variants:
--        AFTER UPDATE OF stock_quantity ... WHEN (old.stock_quantity IS DISTINCT FROM new.stock_quantity)
--      INSERT with stock > 0 (DECIDED): it is NOT logged. A new row is an opening balance, not a
--      movement: the ledger records changes, so the ledger sum is (current stock - opening balance).
--      Why: (a) admin_create_product() cannot set stock (the column default 0 applies), so in the
--      application every stock above 0 arrives through admin_adjust_inventory(), which IS logged; only
--      a hand-written SQL seed / import can insert stock > 0. (b) Logging it would add a ledger row to
--      every existing fixture that seeds stock, rewriting the row-count assertions of six older test
--      files. To log an opening balance deliberately, add a stock-0 row and run admin_adjust_inventory().
--      A DELETE writes nothing (the FK is RESTRICT: a product or variant with ledger rows cannot be
--      deleted anyway).
--   3. DOUBLE-WRITE TRAP - approach chosen: admin_adjust_inventory() is REDEFINED minimally; the ledger
--      insert, the audit insert, arguments, return value, locking order, errors and grants are byte
--      for byte what 6I.2 installed, plus exactly two set_config() calls around its stock UPDATE.
--      The first sets the transaction-local flag app.inventory_ledger_skip to '<table>:<unit id>', the
--      second clears it. The movement trigger skips a change only when the flag names exactly that
--      unit, so the function keeps its own richer row (reason, note, actor) and no second row appears.
--      Why not "the trigger skips rows already written": the function UPDATEs first and INSERTs after,
--      so at trigger time there is no row yet to find. Why not let the trigger write the function's
--      row: it would have to be fed reason / note / actor through settings, a bigger change to a
--      pinned, audited function. The flag cannot be set by a browser role (no privilege on the stock
--      tables, set_config only affects its own transaction) and a stale flag is impossible: it is
--      cleared right after the update and is rolled back with any aborted (sub)transaction.
--   4. low_stock_threshold integer NULL on products and product_variants, CHECK (null or 0..1000).
--      NULL = today's behaviour (the caller-supplied threshold, default 10). Partial index per table
--      for "at or below its own threshold". No dashboard / inventory function is changed.
--   5. APPEND-ONLY ledger: BEFORE UPDATE OR DELETE row trigger + BEFORE TRUNCATE statement trigger,
--      and UPDATE / DELETE / TRUNCATE are revoked from service_role as well (browser roles hold
--      nothing already). The one transition allowed is changed_by <old uuid> -> NULL with every other
--      column unchanged: that is what ON DELETE SET NULL on auth.users does when a user is deleted,
--      and it must not block deleting the user.
--
-- ORDER DEDUCTIONS AND order_id - THE HONEST LIMIT
--   create_order() is pinned and unchanged. It deducts stock BEFORE it inserts the orders row, and the
--   stock trigger has no way to learn which order is coming. So an order deduction is logged as
--   movement_kind 'stock_change', order_id NULL, reason 'Stock changed outside the admin tool (order
--   placement, or a direct change)'. It is NOT distinguishable from a direct SQL change of stock.
--   Nothing is guessed. Closing that gap needs create_order() to set a context (a later, deliberate
--   change to the pinned function).
--   The restock path IS attributed: a new BEFORE UPDATE OF status trigger on orders
--   (orders_inventory_ctx_set, named to fire just before orders_restock_on_cancel) publishes the order
--   id in a transaction-local setting, and an AFTER trigger clears it. Stock changes in that window
--   belong to that order: positive = order_restock, negative = order_reactivation.
--
-- EXTENSION POINT (NOT built): location_id / supplier_id. No warehouse or supplier table exists, so a
-- bare uuid would have no foreign key. When those tables are introduced, add the nullable columns
-- WITH their foreign keys in that migration; the movement trigger is the one place that fills them.
--
-- LIMITS TO KNOW
--   * The append-only guard is a trigger plus privileges. A superuser / table owner can still disable
--     triggers or run with session_replication_role = replica; that is outside what SQL can prevent.
--   * Tests / scripts that TRUNCATE ... CASCADE through products will now fail on the ledger. Delete
--     fixtures in a transaction that is rolled back instead.
--   * products / product_variants already grant SELECT on the whole table to anon / authenticated (the
--     public catalogue, stock_quantity included), so low_stock_threshold is readable the same way. It
--     reveals nothing stock_quantity does not. Browser roles can NOT write it (self-check proves it).
--   * changed_by on trigger-written rows is auth.uid() when that user exists (the customer for an
--     order deduction, the admin for a cancel); NULL for service_role / SQL-editor changes.
--
-- Money stays integer cents. No new table. Frontend untouched.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
declare
  v_neg_p integer;
  v_neg_v integer;
  v_bad_reason integer;
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'inventory_adjustments' and column_name = 'movement_kind')
     or exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'products' and column_name = 'low_stock_threshold')
     or to_regprocedure('public.inventory_log_stock_change()') is not null then
    raise exception 'Phase 9B appears to be applied already. Not running it twice.';
  end if;

  -- 9A applied.
  if to_regclass('public.products_sku_key') is null
     or to_regclass('public.product_variants_sku_key') is null
     or to_regclass('public.order_items_product_id_idx') is null
     or to_regclass('public.order_items_variant_id_idx') is null then
    raise exception 'Phase 9B precondition failed: Phase 9A (20261009030000) is not applied.';
  end if;

  -- Ledger exists with exactly the 6C.2.2A.1 columns.
  if to_regclass('public.inventory_adjustments') is null then
    raise exception 'Phase 9B precondition failed: public.inventory_adjustments is missing.';
  end if;
  if (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
      from pg_attribute a
      where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped)
     is distinct from 'id:uuid,product_id:uuid,variant_id:uuid,previous_quantity:integer,adjustment_quantity:integer,new_quantity:integer,reason:text,note:text,changed_by:uuid,created_at:timestamp with time zone' then
    raise exception 'Phase 9B precondition failed: public.inventory_adjustments does not have the expected columns.';
  end if;

  if to_regprocedure('public.admin_adjust_inventory(uuid,integer,text,uuid,text)') is null
     or not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_order')
     or to_regprocedure('public.restock_cancelled_order()') is null
     or to_regprocedure('public.require_admin()') is null then
    raise exception 'Phase 9B precondition failed: admin_adjust_inventory / create_order / restock_cancelled_order / require_admin is missing.';
  end if;

  -- admin_adjust_inventory must be the 6I.2 version (audit write present, no flag yet).
  if (select p.prosrc from pg_proc p where p.oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
       not like '%insert into public.admin_audit_log%'
     or (select p.prosrc from pg_proc p where p.oid = 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure)
       like '%app.inventory_ledger_skip%' then
    raise exception 'Phase 9B precondition failed: admin_adjust_inventory is not the Phase 6I.2 version this migration replaces.';
  end if;

  if not exists (select 1 from pg_trigger where tgrelid = 'public.orders'::regclass and tgname = 'orders_restock_on_cancel') then
    raise exception 'Phase 9B precondition failed: trigger orders_restock_on_cancel is missing.';
  end if;

  -- Counts that would break a constraint or the ledger invariant. Listed, so a failure is actionable.
  select count(*) into v_neg_p from public.products where stock_quantity < 0;
  select count(*) into v_neg_v from public.product_variants where stock_quantity < 0;
  select count(*) into v_bad_reason from public.inventory_adjustments
   where reason <> btrim(reason) or char_length(reason) not between 1 and 120;
  if v_neg_p > 0 or v_neg_v > 0 or v_bad_reason > 0 then
    raise exception 'Phase 9B precondition failed: products with negative stock = %, variants with negative stock = %, ledger rows with an invalid reason = %. Fix these first.',
      v_neg_p, v_neg_v, v_bad_reason;
  end if;

  -- Browser roles must not hold anything on the ledger or write the stock tables already.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.inventory_adjustments')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 9B precondition failed: a browser role can already write a stock or ledger table.';
  end if;

  -- Snapshots the self-check compares against.
  perform set_config('p9b.stock_hash',
    (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                            '|' order by p.id) from public.products p), '')
             || '#' ||
             coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                         '|' order by v.id) from public.product_variants v), ''))), true);
  perform set_config('p9b.ledger_hash',
    (select md5(coalesce(string_agg(row(a.id, a.product_id, a.variant_id, a.previous_quantity, a.adjustment_quantity,
                                        a.new_quantity, a.reason, a.note, a.changed_by, a.created_at)::text,
                                    '|' order by a.id), ''))
     from public.inventory_adjustments a), true);
  perform set_config('p9b.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text, true);
  perform set_config('p9b.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p9b.other_fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.oid <> 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure), true);
  perform set_config('p9b.policy_hash',
    (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                    '|' order by tablename, policyname), ''))
     from pg_policies where schemaname = 'public'), true);
  perform set_config('p9b.other_trigger_hash',
    (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                    '|' order by t.tgrelid::regclass::text, t.tgname), ''))
     from pg_trigger t
     where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)), true);
  perform set_config('p9b.other_acl_hash',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
       and c.relname not in ('inventory_adjustments', 'products', 'product_variants')), true);
end
$pre$;

-- =============================================================================
-- 1. LEDGER COLUMNS (existing rows stay valid: they all become 'admin_adjustment', order_id NULL)
-- =============================================================================
alter table public.inventory_adjustments
  add column order_id uuid references public.orders (id) on delete restrict,
  add column movement_kind text not null default 'admin_adjustment';

alter table public.inventory_adjustments
  add constraint inventory_adjustments_movement_kind_valid
    check (movement_kind in ('admin_adjustment', 'order_restock', 'order_reactivation', 'stock_change')),
  add constraint inventory_adjustments_order_id_kind
    check (order_id is null or movement_kind in ('order_restock', 'order_reactivation'));

-- Needed by the ON DELETE RESTRICT foreign key and for "movements of this order".
create index inventory_adjustments_order_idx
  on public.inventory_adjustments (order_id) where order_id is not null;

comment on column public.inventory_adjustments.order_id is
  'Phase 9B. The order whose cancellation / reactivation moved this stock. NULL for everything else, INCLUDING order placement (create_order is pinned and cannot supply it).';
comment on column public.inventory_adjustments.movement_kind is
  'Phase 9B. admin_adjustment | order_restock | order_reactivation | stock_change (unattributed: includes order placement).';

-- =============================================================================
-- 2. LOW-STOCK THRESHOLD COLUMNS (NULL = keep today's behaviour: the caller-supplied threshold)
-- =============================================================================
alter table public.products
  add column low_stock_threshold integer,
  add constraint products_low_stock_threshold_valid
    check (low_stock_threshold is null or low_stock_threshold between 0 and 1000);
alter table public.product_variants
  add column low_stock_threshold integer,
  add constraint product_variants_low_stock_threshold_valid
    check (low_stock_threshold is null or low_stock_threshold between 0 and 1000);

create index products_low_stock_idx
  on public.products (stock_quantity)
  where low_stock_threshold is not null and stock_quantity <= low_stock_threshold;
create index product_variants_low_stock_idx
  on public.product_variants (stock_quantity)
  where low_stock_threshold is not null and stock_quantity <= low_stock_threshold;

comment on column public.products.low_stock_threshold is
  'Phase 9B. Per-product low-stock level, 0-1000. NULL = use the threshold the reader is given (default 10). Not yet read by any function.';
comment on column public.product_variants.low_stock_threshold is
  'Phase 9B. Per-variant low-stock level, 0-1000. NULL = use the threshold the reader is given (default 10). Not yet read by any function.';

-- =============================================================================
-- 3. TRIGGER FUNCTIONS (SECURITY DEFINER, pinned search_path, no EXECUTE for browser roles)
-- =============================================================================

-- 3a. One ledger row per stock change.
create function public.inventory_log_stock_change()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_product uuid;
  v_variant uuid;
  v_prev integer;
  v_unit text;
  v_order_text text;
  v_order uuid;
  v_actor uuid;
  v_delta integer;
  v_kind text;
  v_reason text;
begin
  if tg_table_name = 'products' then
    v_product := new.id;
    v_variant := null;
  else
    v_product := new.product_id;
    v_variant := new.id;
  end if;
  v_unit := tg_table_name || ':' || new.id::text;

  -- admin_adjust_inventory() writes its own (richer) row for exactly this unit: do not double-write.
  if current_setting('app.inventory_ledger_skip', true) is not distinct from v_unit then
    return null;
  end if;

  v_prev := old.stock_quantity;
  v_delta := new.stock_quantity - v_prev;
  if v_delta = 0 then
    return null;
  end if;

  -- Order context published by orders_inventory_ctx_set while an order's status change runs.
  v_order_text := nullif(current_setting('app.inventory_order_id', true), '');
  if v_order_text is not null then
    v_order := v_order_text::uuid;
  end if;

  if v_order is not null and v_delta > 0 then
    v_kind := 'order_restock';
    v_reason := 'Order cancelled: stock returned';
  elsif v_order is not null then
    v_kind := 'order_reactivation';
    v_reason := 'Order reactivated: stock reserved again';
  else
    v_kind := 'stock_change';
    v_reason := 'Stock changed outside the admin tool (order placement, or a direct change)';
    v_order := null;
  end if;

  -- The acting user, only if it is a real auth user (a service-role / SQL-editor change has none).
  select u.id into v_actor from auth.users u where u.id = auth.uid();

  insert into public.inventory_adjustments
    (product_id, variant_id, previous_quantity, adjustment_quantity, new_quantity,
     reason, note, changed_by, order_id, movement_kind)
  values
    (v_product, v_variant, v_prev, v_delta, new.stock_quantity,
     v_reason, null, v_actor, v_order, v_kind);

  return null;
end;
$fn$;

comment on function public.inventory_log_stock_change() is
  'Phase 9B. AFTER UPDATE OF stock_quantity trigger function on products / product_variants: writes exactly one inventory_adjustments row per stock change (an INSERT is an opening balance and is not logged). Skips the unit named in app.inventory_ledger_skip (admin_adjust_inventory writes its own row).';

-- 3b. Publish / clear the order id while an order's status change moves stock.
create function public.inventory_order_ctx_set()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  perform set_config('app.inventory_order_id', new.id::text, true);
  return new;
end;
$fn$;

create function public.inventory_order_ctx_clear()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  perform set_config('app.inventory_order_id', '', true);
  return null;
end;
$fn$;

comment on function public.inventory_order_ctx_set() is
  'Phase 9B. BEFORE UPDATE OF status trigger function on orders: publishes the order id (transaction-local) just before orders_restock_on_cancel moves stock, so the movement can carry order_id.';
comment on function public.inventory_order_ctx_clear() is
  'Phase 9B. AFTER UPDATE OF status trigger function on orders: clears the order id published by inventory_order_ctx_set().';

-- 3c. Append-only guard.
create function public.inventory_adjustments_guard()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  -- The ONLY permitted change: changed_by uuid -> NULL, every other column untouched. This is what
  -- ON DELETE SET NULL on auth.users does when a user is deleted.
  if tg_op = 'UPDATE'
     and old.changed_by is not null
     and new.changed_by is null
     and (to_jsonb(new) - 'changed_by') = (to_jsonb(old) - 'changed_by') then
    return new;
  end if;

  raise exception 'inventory_adjustments is append-only: % is not allowed.', tg_op
    using errcode = 'P0001', detail = 'inventory_ledger_append_only';
end;
$fn$;

comment on function public.inventory_adjustments_guard() is
  'Phase 9B. Makes inventory_adjustments append-only: refuses UPDATE, DELETE and TRUNCATE, except changed_by -> NULL with all else unchanged (the auth.users ON DELETE SET NULL action).';

revoke all on function public.inventory_log_stock_change() from public, anon, authenticated;
revoke all on function public.inventory_order_ctx_set() from public, anon, authenticated;
revoke all on function public.inventory_order_ctx_clear() from public, anon, authenticated;
revoke all on function public.inventory_adjustments_guard() from public, anon, authenticated;

-- =============================================================================
-- 4. TRIGGERS
-- =============================================================================
create trigger products_inventory_log_update
  after update of stock_quantity on public.products
  for each row
  when (old.stock_quantity is distinct from new.stock_quantity)
  execute function public.inventory_log_stock_change();

create trigger product_variants_inventory_log_update
  after update of stock_quantity on public.product_variants
  for each row
  when (old.stock_quantity is distinct from new.stock_quantity)
  execute function public.inventory_log_stock_change();

-- Fires before orders_restock_on_cancel (triggers of one event run in name order).
create trigger orders_inventory_ctx_set
  before update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.inventory_order_ctx_set();
create trigger orders_inventory_ctx_clear
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.inventory_order_ctx_clear();

create trigger inventory_adjustments_append_only
  before update or delete on public.inventory_adjustments
  for each row
  execute function public.inventory_adjustments_guard();
create trigger inventory_adjustments_no_truncate
  before truncate on public.inventory_adjustments
  for each statement
  execute function public.inventory_adjustments_guard();

-- Ledger privileges: browser roles hold nothing (unchanged); service_role may only read and append.
revoke all on table public.inventory_adjustments from public, anon, authenticated, service_role;
grant select, insert on table public.inventory_adjustments to service_role;

-- =============================================================================
-- 5. admin_adjust_inventory()  [6I.2 version + the two set_config() calls marked "Phase 9B"]
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
  -- Phase 9B: tell the stock-movement trigger that THIS function writes the ledger row for this
  -- unit (below), so the trigger must not write a second one. The flag is transaction-local, names
  -- exactly one unit, and is cleared immediately after the update.
  perform set_config('app.inventory_ledger_skip',
                     case when p_variant_id is null then 'products:' || p_product_id::text
                          else 'product_variants:' || p_variant_id::text end,
                     true);
  if p_variant_id is null then
    update public.products set stock_quantity = v_new where id = p_product_id;
  else
    update public.product_variants set stock_quantity = v_new where id = p_variant_id;
  end if;
  perform set_config('app.inventory_ledger_skip', '', true);

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
-- 6. SELF-CHECK - abort (and roll everything back) unless exactly as designed.
-- =============================================================================
do $chk$
declare
  v_led oid := 'public.inventory_adjustments'::regclass;
  v_adm regprocedure := 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure;
  v_new_fns constant text[] := array[
    'public.inventory_log_stock_change()', 'public.inventory_order_ctx_set()',
    'public.inventory_order_ctx_clear()', 'public.inventory_adjustments_guard()'];
  v_new_trg constant text[] := array[
    'products_inventory_log_update', 'product_variants_inventory_log_update',
    'orders_inventory_ctx_set', 'orders_inventory_ctx_clear',
    'inventory_adjustments_append_only', 'inventory_adjustments_no_truncate'];
  v_sig text;
  v_t text;
begin
  -- Ledger columns.
  if (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
      from pg_attribute a where a.attrelid = v_led and a.attnum > 0 and not a.attisdropped)
     is distinct from 'id:uuid,product_id:uuid,variant_id:uuid,previous_quantity:integer,adjustment_quantity:integer,new_quantity:integer,reason:text,note:text,changed_by:uuid,created_at:timestamp with time zone,order_id:uuid,movement_kind:text' then
    raise exception 'Phase 9B self-check failed: the ledger columns are not as designed.';
  end if;
  if exists (select 1 from public.inventory_adjustments where movement_kind <> 'admin_adjustment' or order_id is not null) then
    raise exception 'Phase 9B self-check failed: a pre-existing ledger row was reclassified.';
  end if;
  if (select count(*) from pg_constraint where conrelid = v_led and contype = 'f') <> 4
     or not exists (select 1 from pg_constraint where conrelid = v_led and contype = 'f'
                      and confrelid = 'public.orders'::regclass and confdeltype = 'r') then
    raise exception 'Phase 9B self-check failed: the ledger foreign keys are not as designed (order_id must be ON DELETE RESTRICT).';
  end if;
  foreach v_t in array array['inventory_adjustments_movement_kind_valid', 'inventory_adjustments_order_id_kind',
                             'inventory_adjustments_quantities_consistent', 'inventory_adjustments_new_nonnegative'] loop
    if not exists (select 1 from pg_constraint where conrelid = v_led and conname = v_t and contype = 'c') then
      raise exception 'Phase 9B self-check failed: constraint % is missing.', v_t;
    end if;
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass
                   and conname = 'products_low_stock_threshold_valid' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.product_variants'::regclass
                      and conname = 'product_variants_low_stock_threshold_valid' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass
                      and conname = 'products_stock_nonnegative')
     or not exists (select 1 from pg_constraint where conrelid = 'public.product_variants'::regclass
                      and conname = 'product_variants_stock_nonnegative') then
    raise exception 'Phase 9B self-check failed: a low-stock / non-negative stock CHECK is missing.';
  end if;

  -- Indexes: the three new ones, and the two old ledger ones still there exactly once.
  if to_regclass('public.inventory_adjustments_order_idx') is null
     or to_regclass('public.products_low_stock_idx') is null
     or to_regclass('public.product_variants_low_stock_idx') is null
     or to_regclass('public.inventory_adjustments_product_idx') is null
     or to_regclass('public.inventory_adjustments_variant_idx') is null
     or (select count(*) from pg_index where indrelid = v_led) <> 4 then
    raise exception 'Phase 9B self-check failed: the ledger / low-stock indexes are not as designed.';
  end if;

  -- Triggers: exactly the six new ones, enabled, plus nothing else changed.
  foreach v_t in array v_new_trg loop
    if (select count(*) from pg_trigger t where not t.tgisinternal and t.tgname = v_t and t.tgenabled = 'O') <> 1 then
      raise exception 'Phase 9B self-check failed: trigger % is missing or disabled.', v_t;
    end if;
  end loop;
  if (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                     '|' order by t.tgrelid::regclass::text, t.tgname), ''))
      from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)
        and t.tgname <> all (v_new_trg))
     is distinct from current_setting('p9b.other_trigger_hash', true) then
    raise exception 'Phase 9B self-check failed: an existing trigger changed.';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgname = 'orders_inventory_ctx_set'
                   and t.tgname < 'orders_restock_on_cancel') then
    raise exception 'Phase 9B self-check failed: the order context trigger would not fire before orders_restock_on_cancel.';
  end if;
  if (select count(*) from pg_trigger t where t.tgrelid = v_led and not t.tgisinternal and t.tgtype & 32 = 32) <> 1 then
    raise exception 'Phase 9B self-check failed: the ledger TRUNCATE guard is missing.';
  end if;

  -- The four new functions: SECURITY DEFINER, pinned search_path, no EXECUTE for browser roles / PUBLIC.
  foreach v_sig in array v_new_fns loop
    if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
               and (not p.prosecdef or p.provolatile <> 'v'
                    or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
      raise exception 'Phase 9B self-check failed: % is not SECURITY DEFINER / VOLATILE / search_path pinned.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'EXECUTE') or has_function_privilege('authenticated', v_sig, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = v_sig::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'Phase 9B self-check failed: % is executable by a browser role or PUBLIC.', v_sig;
    end if;
  end loop;

  -- admin_adjust_inventory: same attributes and grants as before, now with the skip flag.
  if exists (select 1 from pg_proc p
             where p.oid = v_adm
               and (not p.prosecdef or p.provolatile <> 'v' or p.prorettype <> 'jsonb'::regtype
                    or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%'
                    or p.prosrc not like '%public.require_admin()%'
                    or p.prosrc not like '%insert into public.inventory_adjustments%'
                    or p.prosrc not like '%insert into public.admin_audit_log%'
                    or p.prosrc not like '%app.inventory_ledger_skip%'
                    or p.prosrc not like '%auth.uid()%')) then
    raise exception 'Phase 9B self-check failed: admin_adjust_inventory is not as designed.';
  end if;
  if (select length(p.prosrc) - length(replace(p.prosrc, 'insert into public.inventory_adjustments', ''))
      from pg_proc p where p.oid = v_adm) <> length('insert into public.inventory_adjustments') then
    raise exception 'Phase 9B self-check failed: admin_adjust_inventory must contain exactly one ledger insert.';
  end if;
  if has_function_privilege('anon', v_adm, 'EXECUTE') or not has_function_privilege('authenticated', v_adm, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_adm and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'Phase 9B self-check failed: the admin_adjust_inventory EXECUTE ACL is not authenticated-only.';
  end if;

  -- Nothing else in the function set changed: create_order, restock_cancelled_order, every reader.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from (current_setting('p9b.fn_count', true)::integer + 4)::text then
    raise exception 'Phase 9B self-check failed: exactly four functions must have been added.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.oid <> v_adm
        and p.oid <> all (select f::regprocedure::oid from unnest(v_new_fns) f))
     is distinct from current_setting('p9b.other_fn_hash', true) then
    raise exception 'Phase 9B self-check failed: an existing function changed (create_order / restock must be untouched).';
  end if;

  -- No new table; no policy change; no grant change on any other table.
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from current_setting('p9b.rel_count', true) then
    raise exception 'Phase 9B self-check failed: a table was added or removed.';
  end if;
  if (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                     '|' order by tablename, policyname), ''))
      from pg_policies where schemaname = 'public') is distinct from current_setting('p9b.policy_hash', true) then
    raise exception 'Phase 9B self-check failed: a policy changed.';
  end if;
  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c
      where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
        and c.relname not in ('inventory_adjustments', 'products', 'product_variants'))
     is distinct from current_setting('p9b.other_acl_hash', true) then
    raise exception 'Phase 9B self-check failed: the grants / RLS flag of another table changed.';
  end if;
  -- Browser roles cannot write the new low_stock_threshold columns (they are readable like the rest of the table).
  if has_column_privilege('anon', 'public.products', 'low_stock_threshold', 'INSERT')
     or has_column_privilege('anon', 'public.products', 'low_stock_threshold', 'UPDATE')
     or has_column_privilege('authenticated', 'public.products', 'low_stock_threshold', 'INSERT')
     or has_column_privilege('authenticated', 'public.products', 'low_stock_threshold', 'UPDATE')
     or has_column_privilege('anon', 'public.product_variants', 'low_stock_threshold', 'INSERT')
     or has_column_privilege('anon', 'public.product_variants', 'low_stock_threshold', 'UPDATE')
     or has_column_privilege('authenticated', 'public.product_variants', 'low_stock_threshold', 'INSERT')
     or has_column_privilege('authenticated', 'public.product_variants', 'low_stock_threshold', 'UPDATE') then
    raise exception 'Phase 9B self-check failed: a browser role can write low_stock_threshold.';
  end if;
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 9B self-check failed: a browser role can write a stock table.';
  end if;

  -- Ledger privileges: browser roles nothing; service_role SELECT + INSERT only; PUBLIC nothing.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, v_led, pv.priv)
       or has_any_column_privilege(r.role, v_led, 'SELECT')
       or has_any_column_privilege(r.role, v_led, 'INSERT')
       or has_any_column_privilege(r.role, v_led, 'UPDATE')
       or has_any_column_privilege(r.role, v_led, 'REFERENCES')
  ) or exists (
    select 1 from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
    where c.oid = v_led and a.grantee = 0
  ) then
    raise exception 'Phase 9B self-check failed: a browser role or PUBLIC holds a privilege on the ledger.';
  end if;
  if not has_table_privilege('service_role', v_led, 'SELECT') or not has_table_privilege('service_role', v_led, 'INSERT')
     or has_table_privilege('service_role', v_led, 'UPDATE') or has_table_privilege('service_role', v_led, 'DELETE')
     or has_table_privilege('service_role', v_led, 'TRUNCATE') then
    raise exception 'Phase 9B self-check failed: service_role must hold exactly SELECT + INSERT on the ledger.';
  end if;
  if not (select relrowsecurity from pg_class where oid = v_led)
     or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments') then
    raise exception 'Phase 9B self-check failed: the ledger must keep RLS on with no policy.';
  end if;

  -- THE CENTRAL PROMISES: no stock value moved, and the migration wrote no ledger row.
  if (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                             '|' order by p.id) from public.products p), '')
              || '#' ||
              coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                          '|' order by v.id) from public.product_variants v), '')))
       is distinct from current_setting('p9b.stock_hash', true) then
    raise exception 'Phase 9B self-check failed: a stock value changed.';
  end if;
  if (select md5(coalesce(string_agg(row(a.id, a.product_id, a.variant_id, a.previous_quantity, a.adjustment_quantity,
                                         a.new_quantity, a.reason, a.note, a.changed_by, a.created_at)::text,
                                     '|' order by a.id), ''))
      from public.inventory_adjustments a) is distinct from current_setting('p9b.ledger_hash', true) then
    raise exception 'Phase 9B self-check failed: the existing ledger rows changed or new rows appeared.';
  end if;
  if exists (select 1 from public.products where low_stock_threshold is not null)
     or exists (select 1 from public.product_variants where low_stock_threshold is not null) then
    raise exception 'Phase 9B self-check failed: a low_stock_threshold was set by the migration (all must be NULL).';
  end if;
end
$chk$;

commit;
