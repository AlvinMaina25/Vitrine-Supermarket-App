-- =============================================================================
-- PHASE 9C - Label every inventory history row: movement_kind + order_id in the admin history reader.
--
-- STATUS: written, NOT APPLIED to any database by the author. Apply after
-- 20261009040000_phase9b_inventory_movements.sql (which is already live on the owner's project and
-- is NOT edited or re-run). One transaction: any failing statement or the final self-check rolls
-- everything back. Safe to run twice (CREATE OR REPLACE of one function; the second run changes
-- nothing and passes the same self-check).
--
-- WHY
--   Since 9B every stock change writes a ledger row, not only admin adjustments. The history panel
--   showed those rows with the stored reason "Stock changed outside the admin tool (...)" and the
--   customer's short id as the actor ("Admin <id>"), because admin_list_inventory_adjustments()
--   returned neither the kind of movement nor the order it belongs to.
--
-- WHAT THIS CHANGES  (exactly one function; nothing else)
--   public.admin_list_inventory_adjustments(...) keeps its signature, return type (jsonb), volatility
--   (STABLE), SECURITY DEFINER, pinned search_path, the require_admin() gate as its first statement,
--   its filters, its fixed order (created_at desc, id desc), its paging and its EXECUTE ACL
--   (authenticated only). It now ALSO returns, per adjustment:
--     movement_kind  text   admin_adjustment | order_restock | order_reactivation | stock_change
--     order_id       uuid   the order whose cancellation / reactivation moved the stock; NULL for
--                           every other kind (the 9B CHECK guarantees it is never set otherwise)
--   Existing keys are unchanged (same names, same types, same values) EXCEPT changed_by, see below.
--
-- PRIVACY: changed_by IS NOW MASKED FOR NON-STAFF ACTORS
--   On a stock_change row written by order placement, changed_by is the CUSTOMER's user id (it is
--   auth.uid() of the placing session). The history reader used to hand that id to the admin UI,
--   which printed it as an admin. changed_by is now returned only when
--     * the row is an admin_adjustment (its actor is the admin who made it: unchanged behaviour), or
--     * the actor currently holds a 'staff' or 'admin' role in public.user_roles
--       (for example the admin who cancelled an order);
--   otherwise it is returned as NULL. The p_changed_by filter compares against the SAME masked value,
--   so a customer id can neither be read from nor probed through this function.
--   order_id is the only order data returned: no order number, customer, address or amount. The
--   function does not read the orders, profiles, addresses or auth.users tables (the self-check
--   refuses a body that mentions them); it reads user_roles only to decide the masking above.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No change to the ledger, its columns, triggers, constraints, indexes, grants or RLS.
--   * No change to admin_adjust_inventory(), create_order(), restock_cancelled_order() or any
--     trigger: stock tracking and stock adjustment behave exactly as before.
--   * No change to stored rows: the stored reason text of old rows ("Stock changed outside the
--     admin tool ...") stays as written; the panel labels rows from movement_kind.
--   * Order placement is still logged as 'stock_change' with order_id NULL (9B: create_order() is
--     pinned and cannot supply the order). The label for that kind says exactly that: it is not
--     distinguishable from a direct change.
--   * No new function, table, column, policy, trigger or index. (A new filter parameter would change
--     the function's signature and so its identity; it is not needed by the panel.)
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
declare
  v_fn regprocedure;
begin
  -- 9B applied (the columns this function now reads, and the movement trigger).
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'inventory_adjustments'
        and column_name in ('movement_kind', 'order_id')) <> 2
     or to_regprocedure('public.inventory_log_stock_change()') is null then
    raise exception 'Phase 9C precondition failed: Phase 9B (20261009040000) is not applied.';
  end if;

  -- The function being replaced exists with exactly the 6C.2.2B.1 signature.
  v_fn := to_regprocedure('public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)');
  if v_fn is null
     or (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
         and proname = 'admin_list_inventory_adjustments') <> 1 then
    raise exception 'Phase 9C precondition failed: admin_list_inventory_adjustments (6C.2.2B.1) is missing or has an unexpected overload.';
  end if;
  if pg_get_function_arguments(v_fn) is distinct from
     'p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid, p_variant_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone'
     or pg_get_function_result(v_fn) is distinct from 'jsonb' then
    raise exception 'Phase 9C precondition failed: the function signature is not the 6C.2.2B.1 one.';
  end if;

  if to_regprocedure('public.require_admin()') is null
     or to_regclass('public.user_roles') is null
     or (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'user_roles' and column_name in ('user_id', 'role')) <> 2 then
    raise exception 'Phase 9C precondition failed: require_admin() / public.user_roles(user_id, role) is missing.';
  end if;

  -- The ledger must still be closed to browser roles (this migration must never be what widens it).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
  ) or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
    or not (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass) then
    raise exception 'Phase 9C precondition failed: the ledger is not closed to browser roles (RLS on, no policy, no grant expected).';
  end if;

  -- Snapshots the self-check compares against.
  perform set_config('p9c.stock_hash',
    (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                            '|' order by p.id) from public.products p), '')
             || '#' ||
             coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                         '|' order by v.id) from public.product_variants v), ''))), true);
  perform set_config('p9c.ledger_hash',
    (select md5(coalesce(string_agg(a::text, '|' order by a.id), '')) from public.inventory_adjustments a), true);
  perform set_config('p9c.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text, true);
  perform set_config('p9c.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p9c.other_fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc) || '/' || coalesce(p.proacl::text, ''),
                                    '|' order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.oid <> v_fn), true);
  perform set_config('p9c.acl_hash',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')), true);
  perform set_config('p9c.column_hash',
    (select md5(coalesce(string_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' ||
                                    coalesce(column_default, ''), '|' order by table_name, ordinal_position), ''))
     from information_schema.columns where table_schema = 'public'), true);
  perform set_config('p9c.policy_hash',
    (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                    '|' order by tablename, policyname), ''))
     from pg_policies where schemaname = 'public'), true);
  perform set_config('p9c.trigger_hash',
    (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                    '|' order by t.tgrelid::regclass::text, t.tgname), ''))
     from pg_trigger t
     where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)), true);
  perform set_config('p9c.index_hash',
    (select md5(coalesce(string_agg(indexdef, '|' order by indexname), ''))
     from pg_indexes where schemaname = 'public'), true);
end
$pre$;

-- =============================================================================
-- 1. admin_list_inventory_adjustments()  [6C.2.2B.1 body + movement_kind, order_id, masked changed_by]
-- =============================================================================
create or replace function public.admin_list_inventory_adjustments(
  p_limit integer default 50,
  p_offset integer default 0,
  p_product_id uuid default null,
  p_variant_id uuid default null,
  p_reason text default null,
  p_changed_by uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_reason text;
  v_total bigint;
  v_rows jsonb;
begin
  -- 1. The gate runs before any argument is examined and before anything is read.
  perform public.require_admin();

  -- 2. Validate the arguments (unchanged).
  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0 then
    raise exception 'Invalid adjustment history arguments (limit 1-100, offset >= 0).'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  if p_reason is not null then
    v_reason := btrim(p_reason);
    if char_length(v_reason) not between 1 and 120 then
      raise exception 'A reason filter, when given, must be 1 to 120 characters.'
        using errcode = 'P0001', detail = 'invalid_arguments';
    end if;
  end if;

  if p_from is not null and p_to is not null and p_from >= p_to then
    raise exception 'The date range is empty: p_from must be earlier than p_to.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  -- 3. One filtered set: the count and the page cannot disagree. Fixed order, no dynamic SQL.
  --    x.actor is the acting user as the caller may see it: the stored changed_by for an admin
  --    adjustment or for a user who holds a staff / admin role, otherwise NULL (for example the
  --    customer whose order placement moved the stock). The actor filter uses the same value.
  with matched as (
    select a.id, a.product_id, a.variant_id,
           a.previous_quantity, a.adjustment_quantity, a.new_quantity,
           a.reason, a.note, x.actor as changed_by, a.created_at,
           a.movement_kind, a.order_id,
           p.name as product_name, p.sku as product_sku,
           v.name as variant_name, v.sku as variant_sku
    from public.inventory_adjustments a
    join public.products p on p.id = a.product_id
    left join public.product_variants v on v.id = a.variant_id
    cross join lateral (
      select case
               when a.movement_kind = 'admin_adjustment'
                 or exists (select 1 from public.user_roles ur
                            where ur.user_id = a.changed_by and ur.role in ('staff', 'admin'))
               then a.changed_by
             end as actor
    ) x
    where (p_product_id is null or a.product_id = p_product_id)
      and (p_variant_id is null or a.variant_id = p_variant_id)
      and (v_reason is null or a.reason = v_reason)
      and (p_changed_by is null or x.actor = p_changed_by)
      and (p_from is null or a.created_at >= p_from)
      and (p_to is null or a.created_at < p_to)
  ),
  page as (
    select m.*
    from matched m
    order by m.created_at desc, m.id desc
    limit p_limit offset p_offset
  )
  select (select count(*) from matched),
         coalesce((
           select jsonb_agg(
                    jsonb_build_object(
                      'id', pg.id,
                      'product_id', pg.product_id,
                      'variant_id', pg.variant_id,
                      'previous_quantity', pg.previous_quantity,
                      'adjustment_quantity', pg.adjustment_quantity,
                      'new_quantity', pg.new_quantity,
                      'reason', pg.reason,
                      'note', pg.note,
                      'changed_by', pg.changed_by,
                      'created_at', pg.created_at,
                      'movement_kind', pg.movement_kind,
                      'order_id', pg.order_id,
                      'product_name', pg.product_name,
                      'product_sku', pg.product_sku,
                      'variant_name', pg.variant_name,
                      'variant_sku', pg.variant_sku)
                    order by pg.created_at desc, pg.id desc)
           from page pg), '[]'::jsonb)
  into v_total, v_rows;

  return jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'adjustments', v_rows
  );
end;
$fn$;

comment on function public.admin_list_inventory_adjustments(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz) is
  'Phase 6C.2.2B.1, extended by Phase 9C. Admin-only, read-only inventory history: filters product / variant / exact reason / actor / created_at range [from, to), limit 1-100 / offset >= 0, fixed order created_at desc, id desc, with product and variant name and sku. Each row also carries movement_kind (admin_adjustment | order_restock | order_reactivation | stock_change) and order_id (set only for order_restock / order_reactivation). changed_by is returned only for admin adjustments and for actors who hold a staff / admin role, otherwise NULL (never a customer id). Gate: require_admin().';

-- Same ACL as before (CREATE OR REPLACE keeps it; stated again so this file is self-explanatory).
revoke all on function public.admin_list_inventory_adjustments(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.admin_list_inventory_adjustments(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz)
  to authenticated;

-- =============================================================================
-- 2. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $chk$
declare
  v_fn regprocedure := 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure;
  v_src text;
begin
  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;

  -- Security attributes, exactly as 6C.2.2B.1 installed them.
  if not (select p.prosecdef from pg_proc p where p.oid = v_fn) then
    raise exception 'Phase 9C self-check failed: the function is not SECURITY DEFINER.';
  end if;
  if coalesce((select p.proconfig::text from pg_proc p where p.oid = v_fn), '') not like '%search_path=public, pg_temp%' then
    raise exception 'Phase 9C self-check failed: search_path is not pinned to public, pg_temp.';
  end if;
  if (select p.provolatile from pg_proc p where p.oid = v_fn) <> 's' then
    raise exception 'Phase 9C self-check failed: the function must be STABLE.';
  end if;
  if position('public.require_admin()' in v_src) = 0
     or position('public.require_admin()' in v_src) > position('public.inventory_adjustments' in v_src) then
    raise exception 'Phase 9C self-check failed: require_admin() is not the first guard.';
  end if;

  -- Read-only body: no write statement, no dynamic SQL, no row locks.
  if v_src ~* '\m(insert\s+into|update\s+public|delete\s+from|truncate)\M'
     or v_src ~* '\mexecute\M'
     or v_src ~* '\mfor\s+(update|share|no\s+key\s+update|key\s+share)\M' then
    raise exception 'Phase 9C self-check failed: the function body writes, locks or uses dynamic SQL.';
  end if;

  -- Customer data stays out: the body may read the ledger, products, variants and user_roles only.
  if v_src ~* '\m(orders|order_items|profiles|addresses|payment_transactions)\M' or v_src ~* 'auth\.users' then
    raise exception 'Phase 9C self-check failed: the function body reads customer or order tables.';
  end if;

  -- The new keys are present, and changed_by is masked (the staff / admin role test is in the body).
  if position('''movement_kind''' in v_src) = 0 or position('''order_id''' in v_src) = 0
     or position('public.user_roles' in v_src) = 0 or position('''staff'', ''admin''' in v_src) = 0 then
    raise exception 'Phase 9C self-check failed: movement_kind / order_id / the changed_by masking is missing from the function.';
  end if;

  -- Exact signature and result type (unchanged).
  if pg_get_function_arguments(v_fn) is distinct from
     'p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid, p_variant_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone'
     or pg_get_function_result(v_fn) is distinct from 'jsonb' then
    raise exception 'Phase 9C self-check failed: the function signature changed (%).', pg_get_function_arguments(v_fn);
  end if;

  -- Exact EXECUTE ACL: authenticated only (plus the owner). Not PUBLIC, not anon.
  if has_function_privilege('anon', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'Phase 9C self-check failed: the EXECUTE ACL is not authenticated-only.';
  end if;
  if exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn and a.grantee <> p.proowner
      and a.grantee <> 'authenticated'::regrole
      and a.privilege_type = 'EXECUTE'
      and a.grantee <> coalesce((select oid from pg_roles where rolname = 'service_role'), 0)
  ) then
    raise exception 'Phase 9C self-check failed: an unexpected role can execute the function.';
  end if;

  -- No function added or removed; every OTHER function (admin_adjust_inventory, create_order,
  -- restock_cancelled_order, the 9B triggers, every reader) is byte-for-byte what it was, ACL included.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from current_setting('p9c.fn_count', true) then
    raise exception 'Phase 9C self-check failed: a function was added or removed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc) || '/' || coalesce(p.proacl::text, ''),
                                     '|' order by p.oid::regprocedure::text), ''))
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.oid <> v_fn)
     is distinct from current_setting('p9c.other_fn_hash', true) then
    raise exception 'Phase 9C self-check failed: another function or its grants changed.';
  end if;

  -- No table, column, grant, RLS flag, policy, trigger or index changed.
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from current_setting('p9c.rel_count', true) then
    raise exception 'Phase 9C self-check failed: a table was added or removed.';
  end if;
  if (select md5(coalesce(string_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' ||
                                     coalesce(column_default, ''), '|' order by table_name, ordinal_position), ''))
      from information_schema.columns where table_schema = 'public')
     is distinct from current_setting('p9c.column_hash', true) then
    raise exception 'Phase 9C self-check failed: a column changed.';
  end if;
  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p'))
     is distinct from current_setting('p9c.acl_hash', true) then
    raise exception 'Phase 9C self-check failed: a table grant or RLS flag changed.';
  end if;
  if (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                     '|' order by tablename, policyname), ''))
      from pg_policies where schemaname = 'public') is distinct from current_setting('p9c.policy_hash', true) then
    raise exception 'Phase 9C self-check failed: a policy changed.';
  end if;
  if (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                     '|' order by t.tgrelid::regclass::text, t.tgname), ''))
      from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace))
     is distinct from current_setting('p9c.trigger_hash', true) then
    raise exception 'Phase 9C self-check failed: a trigger changed.';
  end if;
  if (select md5(coalesce(string_agg(indexdef, '|' order by indexname), ''))
      from pg_indexes where schemaname = 'public') is distinct from current_setting('p9c.index_hash', true) then
    raise exception 'Phase 9C self-check failed: an index changed.';
  end if;

  -- The ledger is still closed to browser roles.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
  ) or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
    or not (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass) then
    raise exception 'Phase 9C self-check failed: the ledger is no longer closed to browser roles.';
  end if;

  -- Installing the function moved no stock and touched no ledger row.
  if (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                             '|' order by p.id) from public.products p), '')
              || '#' ||
              coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                          '|' order by v.id) from public.product_variants v), '')))
       is distinct from current_setting('p9c.stock_hash', true) then
    raise exception 'Phase 9C self-check failed: a stock value changed.';
  end if;
  if (select md5(coalesce(string_agg(a::text, '|' order by a.id), '')) from public.inventory_adjustments a)
       is distinct from current_setting('p9c.ledger_hash', true) then
    raise exception 'Phase 9C self-check failed: ledger rows changed.';
  end if;
end
$chk$;

commit;
