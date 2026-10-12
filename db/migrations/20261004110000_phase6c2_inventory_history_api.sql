-- =============================================================================
-- PHASE 6C.2.2B.1 - Admin inventory adjustment HISTORY API (one read-only function, nothing else).
--
-- STATUS: written, NOT APPLIED to any database. Review it, then apply it ONCE to the dedicated
-- Phase-5 development database only.
--
-- Apply ONCE, after 20261004100000_phase6c2_admin_inventory_adjustment.sql. Do not edit or re-run
-- any older migration. One transaction: if any statement or the final self-check fails, nothing
-- is applied. Section 0 refuses to run a second time.
--
-- WHAT THIS DOES
--   Creates ONE function, the controlled admin READ path over public.inventory_adjustments:
--
--     public.admin_list_inventory_adjustments(
--       p_limit      integer     default 50,    -- 1..100
--       p_offset     integer     default 0,     -- >= 0
--       p_product_id uuid        default null,  -- exact product
--       p_variant_id uuid        default null,  -- exact variant
--       p_reason     text        default null,  -- exact reason (case-sensitive, trimmed)
--       p_changed_by uuid        default null,  -- exact actor
--       p_from       timestamptz default null,  -- created_at >= p_from
--       p_to         timestamptz default null   -- created_at <  p_to
--     ) returns jsonb
--
--   Result: { "total": n, "limit": n, "offset": n, "adjustments": [ ... ] }
--   Each adjustment: id, product_id, variant_id, previous_quantity, adjustment_quantity,
--   new_quantity, reason, note, changed_by, created_at, product_name, product_sku,
--   variant_name, variant_sku. variant_id / variant_name / variant_sku are null for a
--   product-level adjustment. Positive and negative adjustments are both returned as stored.
--
-- BEHAVIOUR
--   * Gate: public.require_admin() is the first statement, before any argument is examined.
--   * NULL filter = no filter. All filters are ANDed. Unknown product / variant / actor ids simply
--     match nothing (empty page, total 0); they are not an error.
--   * p_reason is trimmed (history stores trimmed reasons) and compared EXACTLY (no wildcards, no
--     case folding). A blank or > 120 character reason is invalid_arguments.
--   * p_from / p_to form the half-open range [p_from, p_to). p_from >= p_to (both supplied) is
--     invalid_arguments: it can only ever be empty and is almost certainly a caller bug.
--   * Invalid limit / offset (NULL, limit outside 1..100, negative offset) -> P0001,
--     DETAIL invalid_arguments.
--   * Order is FIXED: created_at DESC, id DESC. There is no order / sort parameter and no dynamic
--     SQL anywhere in the function.
--   * Count and page come from ONE filtered set, so total and the rows cannot disagree.
--   * No free-text search (not requested, no clear need; structured filters only).
--
-- SECURITY
--   SECURITY DEFINER, SET search_path = public, pg_temp, STABLE. EXECUTE revoked from PUBLIC, anon
--   and authenticated, then granted to authenticated ONLY (same ACL as every admin_* function; a
--   non-admin authenticated caller is refused by require_admin()). The function only SELECTs from
--   inventory_adjustments, products and product_variants. It performs no insert / update / delete,
--   changes no stock and adds NO privilege, policy or grant: inventory_adjustments stays at
--   RLS-on / no policy / no browser privilege, and this function is its only read path.
--
-- PERFORMANCE (reasoned from the existing indexes; NOT measured: no database was available)
--   inventory_adjustments_product_idx (product_id, created_at desc) serves a product filter and
--   its newest-first order. inventory_adjustments_variant_idx (variant_id, created_at desc)
--   where variant_id is not null serves a variant filter the same way. The other filters
--   (reason, actor, date range, or none) have no dedicated index and are served by a scan of
--   the audit table plus a sort. For a manual-adjustment audit log that is expected to stay small
--   this is acceptable, so NO index is added here. If production volume ever makes the unfiltered
--   or date-range listing slow, EXPLAIN it then and add (created_at desc, id desc) in a later
--   migration; that is not demonstrated today, so it is not done today.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No change to admin_adjust_inventory(), any stock logic, table, column, index, trigger,
--     policy or grant. No UI, no types, no search, no export.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
             and proname = 'admin_list_inventory_adjustments') then
    raise exception 'Phase 6C.2.2B.1 appears to be applied already (admin_list_inventory_adjustments exists). Not running it twice.';
  end if;

  if to_regclass('public.inventory_adjustments') is null
     or to_regprocedure('public.admin_adjust_inventory(uuid,integer,text,uuid,text)') is null
     or to_regprocedure('public.require_admin()') is null then
    raise exception 'Phase 6C.2.2B.1 precondition failed: Phase 6C.2.2A.1 / 6C.2.2A.2 are not applied (inventory_adjustments / admin_adjust_inventory() / require_admin() missing).';
  end if;

  -- The columns the function reads must be exactly what 6C.2.2A.1 created.
  if (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
      from pg_attribute a
      where a.attrelid = 'public.inventory_adjustments'::regclass and a.attnum > 0 and not a.attisdropped)
     is distinct from 'id:uuid,product_id:uuid,variant_id:uuid,previous_quantity:integer,adjustment_quantity:integer,new_quantity:integer,reason:text,note:text,changed_by:uuid,created_at:timestamp with time zone' then
    raise exception 'Phase 6C.2.2B.1 precondition failed: public.inventory_adjustments does not have the 6C.2.2A.1 columns.';
  end if;

  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products' and column_name in ('id', 'name', 'sku')) <> 3
     or (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'product_variants'
           and column_name in ('id', 'product_id', 'name', 'sku')) <> 4 then
    raise exception 'Phase 6C.2.2B.1 precondition failed: products / product_variants do not have the id, name, sku columns this function joins.';
  end if;

  -- The history table must still be closed to the browser roles (this migration must not be the
  -- thing that finds out, and must never widen it).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'INSERT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'UPDATE')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'REFERENCES')
  ) or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
    or not (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass) then
    raise exception 'Phase 6C.2.2B.1 precondition failed: the history table is not closed to browser roles (RLS on, no policy, no grant expected).';
  end if;

  -- Snapshots the self-check compares against.
  perform set_config('p6c2b1.stock_hash',
    (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                            '|' order by p.id) from public.products p), '')
             || '#' ||
             coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                         '|' order by v.id) from public.product_variants v), ''))),
    true);
  perform set_config('p6c2b1.hist_hash',
    (select md5(coalesce(string_agg(a::text, '|' order by a.id), '')) from public.inventory_adjustments a),
    true);
  perform set_config('p6c2b1.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text,
    true);
  perform set_config('p6c2b1.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text, true);
  perform set_config('p6c2b1.fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p where p.pronamespace = 'public'::regnamespace),
    true);
  perform set_config('p6c2b1.acl_hash',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')),
    true);
  perform set_config('p6c2b1.policy_hash',
    (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                    '|' order by tablename, policyname), ''))
     from pg_policies where schemaname = 'public'),
    true);
  perform set_config('p6c2b1.trigger_hash',
    (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                    '|' order by t.tgrelid::regclass::text, t.tgname), ''))
     from pg_trigger t
     where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace)),
    true);
  perform set_config('p6c2b1.index_hash',
    (select md5(coalesce(string_agg(indexdef, '|' order by indexname), ''))
     from pg_indexes where schemaname = 'public'),
    true);
end
$pre$;

-- =============================================================================
-- 1. admin_list_inventory_adjustments()
-- =============================================================================
create function public.admin_list_inventory_adjustments(
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

  -- 2. Validate the arguments.
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
  with matched as (
    select a.id, a.product_id, a.variant_id,
           a.previous_quantity, a.adjustment_quantity, a.new_quantity,
           a.reason, a.note, a.changed_by, a.created_at,
           p.name as product_name, p.sku as product_sku,
           v.name as variant_name, v.sku as variant_sku
    from public.inventory_adjustments a
    join public.products p on p.id = a.product_id
    left join public.product_variants v on v.id = a.variant_id
    where (p_product_id is null or a.product_id = p_product_id)
      and (p_variant_id is null or a.variant_id = p_variant_id)
      and (v_reason is null or a.reason = v_reason)
      and (p_changed_by is null or a.changed_by = p_changed_by)
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
  'Phase 6C.2.2B.1. Admin-only, read-only inventory adjustment history: filters product / variant / exact reason / actor / created_at range [from, to), limit 1-100 / offset >= 0, fixed order created_at desc, id desc, with product and variant name and sku. The only read path to inventory_adjustments. Gate: require_admin().';

revoke all on function public.admin_list_inventory_adjustments(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.admin_list_inventory_adjustments(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz)
  to authenticated;

-- =============================================================================
-- 2. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_fn regprocedure := 'public.admin_list_inventory_adjustments(integer,integer,uuid,uuid,text,uuid,timestamptz,timestamptz)'::regprocedure;
  v_src text;
begin
  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;

  -- Security attributes.
  if not (select p.prosecdef from pg_proc p where p.oid = v_fn) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the function is not SECURITY DEFINER.';
  end if;
  if coalesce((select p.proconfig::text from pg_proc p where p.oid = v_fn), '') not like '%search_path=public, pg_temp%' then
    raise exception 'Phase 6C.2.2B.1 self-check failed: search_path is not pinned to public, pg_temp.';
  end if;
  if (select p.provolatile from pg_proc p where p.oid = v_fn) <> 's' then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the function must be STABLE.';
  end if;
  if position('public.require_admin()' in v_src) = 0
     or position('public.require_admin()' in v_src) > position('public.inventory_adjustments' in v_src) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: require_admin() is not the first guard.';
  end if;

  -- Read-only body: no write statement, no dynamic SQL.
  if v_src ~* '\m(insert\s+into|update\s+public|delete\s+from|truncate)\M'
     or v_src ~* '\mexecute\M'
     or v_src ~* '\mfor\s+(update|share|no\s+key\s+update|key\s+share)\M' then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the function body writes, locks or uses dynamic SQL.';
  end if;

  -- Exact signature.
  if pg_get_function_arguments(v_fn) is distinct from
     'p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_product_id uuid DEFAULT NULL::uuid, p_variant_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone'
     or pg_get_function_result(v_fn) is distinct from 'jsonb' then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the function signature is not as designed (%).',
      pg_get_function_arguments(v_fn);
  end if;

  -- Exact EXECUTE ACL: authenticated only (plus the owner). Not PUBLIC, not anon.
  if has_function_privilege('anon', v_fn, 'EXECUTE')
     or not has_function_privilege('authenticated', v_fn, 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the EXECUTE ACL is not authenticated-only.';
  end if;
  if exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn and a.grantee <> p.proowner
      and a.grantee <> 'authenticated'::regrole
      and a.privilege_type = 'EXECUTE'
      and a.grantee <> coalesce((select oid from pg_roles where rolname = 'service_role'), 0)
  ) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: an unexpected role can execute the function.';
  end if;

  -- One function added; every existing function (admin_adjust_inventory included) is unchanged.
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from (current_setting('p6c2b1.fn_count', true)::integer + 1)::text then
    raise exception 'Phase 6C.2.2B.1 self-check failed: exactly one function must have been added.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p where pronamespace = 'public'::regnamespace and p.oid <> v_fn)
     is distinct from current_setting('p6c2b1.fn_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: an existing function changed.';
  end if;

  -- No table, grant, RLS flag, policy, trigger or index changed.
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from current_setting('p6c2b1.rel_count', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: a table was added or removed.';
  end if;
  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p'))
     is distinct from current_setting('p6c2b1.acl_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: a table grant or RLS flag changed.';
  end if;
  if (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                     '|' order by tablename, policyname), ''))
      from pg_policies where schemaname = 'public') is distinct from current_setting('p6c2b1.policy_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: a policy changed.';
  end if;
  if (select md5(coalesce(string_agg(t.tgrelid::regclass::text || '/' || t.tgname || '/' || t.tgenabled::text,
                                     '|' order by t.tgrelid::regclass::text, t.tgname), ''))
      from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select c.oid from pg_class c where c.relnamespace = 'public'::regnamespace))
     is distinct from current_setting('p6c2b1.trigger_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: a trigger changed.';
  end if;
  if (select md5(coalesce(string_agg(indexdef, '|' order by indexname), ''))
      from pg_indexes where schemaname = 'public') is distinct from current_setting('p6c2b1.index_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: an index changed.';
  end if;

  -- The history table is still closed to the browser roles (no privilege, RLS on, no policy).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, 'public.inventory_adjustments', pv.priv)
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'SELECT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'INSERT')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'UPDATE')
       or has_any_column_privilege(r.role, 'public.inventory_adjustments', 'REFERENCES')
  ) or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments')
    or not (select relrowsecurity from pg_class where oid = 'public.inventory_adjustments'::regclass) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: the history table is no longer closed to browser roles.';
  end if;

  -- Installing the function moved no stock and touched no history row.
  if (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                             '|' order by p.id) from public.products p), '')
              || '#' ||
              coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                          '|' order by v.id) from public.product_variants v), '')))
       is distinct from current_setting('p6c2b1.stock_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: a stock value changed.';
  end if;
  if (select md5(coalesce(string_agg(a::text, '|' order by a.id), '')) from public.inventory_adjustments a)
       is distinct from current_setting('p6c2b1.hist_hash', true) then
    raise exception 'Phase 6C.2.2B.1 self-check failed: history rows changed.';
  end if;
end
$check$;

commit;
