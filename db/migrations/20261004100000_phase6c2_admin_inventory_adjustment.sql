-- =============================================================================
-- PHASE 6C.2.2A.2 - Admin inventory stock ADJUSTMENT engine (one mutation function, nothing else).
--
-- STATUS: written, NOT APPLIED to any database. Review it, then apply it ONCE to the dedicated
-- Phase-5 development database only.
--
-- Apply ONCE, after 20261004090000_phase6c2_inventory_adjustment_history.sql. Do not edit or re-run
-- any older migration. One transaction: if any statement or the final self-check fails, nothing
-- is applied. Section 0 refuses to run a second time.
--
-- WHAT THE SCHEMA ACTUALLY HAS (inspected, nothing assumed)
--   public.products          stock_quantity integer not null (CHECK >= 0), in_stock boolean not null.
--   public.product_variants  stock_quantity integer not null (CHECK >= 0). NO in_stock column.
--   Orders consume stock from ONE of the two places: a line with a variant uses the variant's
--   stock_quantity, a line without one uses the product's. create_order locks the PRODUCT row
--   first (FOR UPDATE) and the VARIANT row second. Cancelling an order restocks the same column
--   (restock_cancelled_order). None of those code paths ever writes in_stock.
--   public.inventory_adjustments (Phase 6C.2.2A.1) is the audit table this function writes.
--
-- WHAT THIS DOES
--   Creates ONE function:
--
--     public.admin_adjust_inventory(
--       p_product_id          uuid,
--       p_adjustment_quantity integer,          -- the signed DELTA: +10 adds 10, -3 removes 3
--       p_reason              text,             -- required, trimmed, 1-120 characters
--       p_variant_id          uuid default null,-- null = the product's own stock; set = that variant's
--       p_note                text default null -- optional, trimmed, 1-500 characters
--     ) returns jsonb
--
--   The caller can only say "change by N". There is NO parameter for a final quantity, for
--   previous_quantity, new_quantity or the actor, so a stale read in the browser can never
--   overwrite stock: the new value is computed inside the database from the LOCKED current value.
--
-- STOCK SEMANTICS
--   * variant_id NULL  -> products.stock_quantity of p_product_id is changed.
--   * variant_id set   -> product_variants.stock_quantity of that variant is changed. The parent
--                         product's stock_quantity and in_stock are NOT touched (orders treat the
--                         two levels as independent units, and so does Phase 6C.2.1).
--   * in_stock         -> is a MANUALLY CONTROLLED product flag in the existing architecture: it is
--                         not derived from stock_quantity anywhere (create_order checks it as a
--                         separate condition, restock_cancelled_order never sets it, and the 6A
--                         dashboard reads "not in_stock OR stock_quantity = 0" as two inputs).
--                         This function therefore PRESERVES it exactly. It does not flip it on a
--                         restock and does not clear it at zero. Changing the flag stays with
--                         admin_update_product's successor in a later phase; inventing a derived
--                         rule here would change how orders behave.
--   * Negative stock   -> refused (negative_stock_not_allowed). Never clamped to zero.
--   * Zero delta       -> refused (zero_adjustment_not_allowed). Nothing is written.
--   * Overflow         -> the sum is computed in bigint and refused (stock_overflow) if it would
--                         exceed the integer range, before anything is updated.
--
-- ERRORS (all SQLSTATE P0001 with DETAIL, except the gate)
--   not_authorised (42501)          require_admin() refused the caller
--   invalid_arguments               product id / delta missing, reason missing / blank / > 120,
--                                   note blank / > 500 when supplied
--   zero_adjustment_not_allowed     delta = 0
--   product_not_found               no such product
--   variant_not_found               p_variant_id given but no such variant
--   variant_product_mismatch        the variant exists but belongs to a different product
--   negative_stock_not_allowed      current + delta < 0
--   stock_overflow                  current + delta > 2147483647
--   Any error aborts the function's statement: the stock update and the history insert are one
--   atomic unit, so neither survives a failure.
--
-- ATOMICITY AND LOCKING
--   Order inside the function: require_admin() -> validate arguments -> (variant: unlocked
--   ownership check) -> lock rows -> read current stock -> compute -> validate -> UPDATE stock ->
--   INSERT exactly one history row -> return.
--   * Product adjustment: SELECT ... FROM products FOR UPDATE.
--   * Variant adjustment : SELECT ... FROM products FOR KEY SHARE, THEN SELECT ... FROM
--     product_variants FOR UPDATE. The product is locked first and the variant second, the SAME
--     order create_order uses, so the two can never deadlock each other. Without the product
--     lock, the history INSERT's foreign-key check (a KEY SHARE on the product) could wait on an
--     order that holds the product and is waiting for the variant this function holds. KEY SHARE
--     does not block ordinary product reads or other adjustments of other variants.
--   * Both locks are held until the transaction ends, i.e. through the UPDATE and the INSERT, so
--     two concurrent adjustments of the same unit serialise and neither is lost. The dedicated
--     two-session stress test belongs to Phase 6C.2.2B.2.
--   * The unlocked ownership check is repeated on the LOCKED variant row.
--
-- SECURITY
--   SECURITY DEFINER, SET search_path = public, pg_temp. require_admin() is the first statement.
--   EXECUTE revoked from PUBLIC, anon and authenticated, then granted to authenticated ONLY (the
--   same ACL as every other admin_* function; service_role has no auth.uid() so require_admin()
--   refuses it as well). The actor is auth.uid() - never a parameter; if it is unexpectedly NULL
--   after the gate, the function fails (actor_unavailable) rather than writing an unattributed
--   row. No privilege is granted on products, product_variants or inventory_adjustments.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No history reader, no UI, no change to create_order / set_order_status / restock logic /
--     order triggers, no change to any table, column, policy or grant.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regprocedure('public.admin_adjust_inventory(uuid,integer,text,uuid,text)') is not null
     or exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                and proname = 'admin_adjust_inventory') then
    raise exception 'Phase 6C.2.2A.2 appears to be applied already (admin_adjust_inventory exists). Not running it twice.';
  end if;

  if to_regclass('public.inventory_adjustments') is null then
    raise exception 'Phase 6C.2.2A.2 precondition failed: Phase 6C.2.2A.1 is not applied (public.inventory_adjustments missing).';
  end if;

  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_list_inventory(integer,integer,text,boolean,uuid)') is null
     or to_regprocedure('public.admin_get_inventory(uuid,uuid)') is null then
    raise exception 'Phase 6C.2.2A.2 precondition failed: require_admin() / the 6C.2.1 inventory readers are missing.';
  end if;

  -- The history table must be what 6C.2.2A.1 promised (the function inserts into it).
  if (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
      from pg_attribute a
      where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped)
     is distinct from 'id:uuid,product_id:uuid,variant_id:uuid,previous_quantity:integer,adjustment_quantity:integer,new_quantity:integer,reason:text,note:text,changed_by:uuid,created_at:timestamp with time zone' then
    raise exception 'Phase 6C.2.2A.2 precondition failed: public.inventory_adjustments does not have the 6C.2.2A.1 columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'stock_quantity', 'in_stock')) <> 3
     or (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'product_variants'
           and column_name in ('id', 'product_id', 'stock_quantity')) <> 3
     or exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'product_variants' and column_name = 'in_stock') then
    raise exception 'Phase 6C.2.2A.2 precondition failed: the products / product_variants stock columns are not as expected.';
  end if;

  -- Browser roles must not be able to write the stock or history tables already.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants'), ('public.inventory_adjustments')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.2A.2 precondition failed: a browser role can already write a stock or history table.';
  end if;

  -- Snapshots the self-check compares against.
  perform set_config('p6c2a2.stock_hash',
    (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                            '|' order by p.id) from public.products p), '')
             || '#' ||
             coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                         '|' order by v.id) from public.product_variants v), ''))),
    true);
  perform set_config('p6c2a2.hist_count', (select count(*) from public.inventory_adjustments)::text, true);
  perform set_config('p6c2a2.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text,
    true);
  perform set_config('p6c2a2.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p6c2a2.fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p where p.pronamespace = 'public'::regnamespace),
    true);
  perform set_config('p6c2a2.acl_hash',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')),
    true);
  perform set_config('p6c2a2.policy_hash',
    (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                    '|' order by tablename, policyname), ''))
     from pg_policies where schemaname = 'public'),
    true);
  perform set_config('p6c2a2.trigger_hash',
    (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                    '|' order by t.tgrelid::regclass::text, t.tgname), ''))
     from pg_trigger t
     where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)),
    true);
end
$pre$;

-- =============================================================================
-- 1. admin_adjust_inventory()
-- =============================================================================
create function public.admin_adjust_inventory(
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

comment on function public.admin_adjust_inventory(uuid, integer, text, uuid, text) is
  'Phase 6C.2.2A.2. Admin-only, DELTA-based stock adjustment of a product (p_variant_id null) or one of its variants. Locks the row (product, then variant - the create_order order), refuses negative / overflowing / zero changes, updates only stock_quantity (in_stock is manual and preserved), and records exactly one inventory_adjustments row with changed_by = auth.uid(), atomically. Gate: require_admin().';

revoke all on function public.admin_adjust_inventory(uuid, integer, text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_adjust_inventory(uuid, integer, text, uuid, text) to authenticated;

-- =============================================================================
-- 2. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn regprocedure := 'public.admin_adjust_inventory(uuid,integer,text,uuid,text)'::regprocedure;
  v_src text;
begin
  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;

  -- Security attributes.
  if not (select p.prosecdef from pg_proc p where p.oid = v_fn) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: the function is not SECURITY DEFINER.';
  end if;
  if coalesce((select p.proconfig::text from pg_proc p where p.oid = v_fn), '') not like '%search_path=public, pg_temp%' then
    raise exception 'Phase 6C.2.2A.2 self-check failed: search_path is not pinned to public, pg_temp.';
  end if;
  if (select p.provolatile from pg_proc p where p.oid = v_fn) <> 'v' then
    raise exception 'Phase 6C.2.2A.2 self-check failed: the function must be VOLATILE.';
  end if;
  if position('public.require_admin()' in v_src) = 0
     or position('public.require_admin()' in v_src) > position('insert into' in v_src)
     or position('public.require_admin()' in v_src) > position('for update' in v_src) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: require_admin() is not the first guard.';
  end if;

  -- Exact EXECUTE ACL: authenticated only (plus the owner). Not PUBLIC, not anon.
  if has_function_privilege('anon', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'Phase 6C.2.2A.2 self-check failed: the EXECUTE ACL is not authenticated-only.';
  end if;
  if exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn and a.grantee <> p.proowner
      and a.grantee <> 'authenticated'::regrole
      and a.privilege_type = 'EXECUTE'
      and a.grantee <> coalesce((select oid from pg_roles where rolname = 'service_role'), 0)
  ) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: an unexpected role can execute the function.';
  end if;

  -- The caller cannot supply a final quantity, snapshots or the actor.
  if (select pg_get_function_arguments(v_fn)) !~ '^p_product_id uuid, p_adjustment_quantity integer, p_reason text, p_variant_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text$' then
    raise exception 'Phase 6C.2.2A.2 self-check failed: the function arguments are not as designed (%).',
      pg_get_function_arguments(v_fn);
  end if;

  -- Atomic body: locks, one insert, stock written only via stock_quantity.
  if v_src !~* 'for update' or v_src !~* 'for key share'
     or v_src !~* 'insert into public\.inventory_adjustments'
     or v_src ~* 'in_stock\s*=' or v_src ~* 'set\s+in_stock' then
    raise exception 'Phase 6C.2.2A.2 self-check failed: the function body does not lock / record / preserve in_stock as designed.';
  end if;

  -- One function added; nothing else in the schema changed.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from (current_setting('p6c2a2.fn_count', true)::integer + 1)::text then
    raise exception 'Phase 6C.2.2A.2 self-check failed: exactly one function must have been added.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.oid <> v_fn)
     is distinct from current_setting('p6c2a2.fn_hash', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: an existing function changed (order stock logic must be untouched).';
  end if;
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from current_setting('p6c2a2.rel_count', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a table was added or removed.';
  end if;
  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p'))
     is distinct from current_setting('p6c2a2.acl_hash', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a table grant or RLS flag changed.';
  end if;
  if (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                     '|' order by tablename, policyname), ''))
      from pg_policies where schemaname = 'public') is distinct from current_setting('p6c2a2.policy_hash', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a policy changed.';
  end if;
  if (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                     '|' order by t.tgrelid::regclass::text, t.tgname), ''))
      from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace))
     is distinct from current_setting('p6c2a2.trigger_hash', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a trigger changed.';
  end if;

  -- Browser roles still cannot write the stock tables, and hold nothing at all on the history table.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) or exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'INSERT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a browser role holds a write privilege on a stock table or any privilege on the history table.';
  end if;

  -- Creating the function moved no stock and wrote no history.
  if (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                             '|' order by p.id) from public.products p), '')
              || '#' ||
              coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                          '|' order by v.id) from public.product_variants v), '')))
       is distinct from current_setting('p6c2a2.stock_hash', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: a stock value changed. Installing the function must not change stock.';
  end if;
  if (select count(*) from public.inventory_adjustments)::text is distinct from current_setting('p6c2a2.hist_count', true) then
    raise exception 'Phase 6C.2.2A.2 self-check failed: history rows were added by the migration.';
  end if;
end
$check$;

commit;
