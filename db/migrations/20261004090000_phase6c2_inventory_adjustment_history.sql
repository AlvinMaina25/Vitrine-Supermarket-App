-- =============================================================================
-- PHASE 6C.2.2A.1 - Inventory adjustment HISTORY foundation (one audit table, nothing else).
--
-- STATUS: written, NOT APPLIED to any database. Review it, then apply it ONCE to the dedicated
-- Phase-5 development database only.
--
-- Apply ONCE, after 20261004080000_phase6c2_inventory_read_foundation.sql. Do not edit or re-run
-- any older migration. One transaction: if any statement or the final self-check fails, nothing
-- is applied. Section 0 refuses to run a second time.
--
-- WHAT THE SCHEMA ACTUALLY HAS (inspected, nothing assumed)
--   public.products          stock_quantity integer not null (>= 0), in_stock boolean not null.
--   public.product_variants  stock_quantity integer not null (>= 0). It has NO in_stock column.
--   Orders consume stock from ONE of those two places (a line with a variant uses the variant's
--   stock_quantity, a line without one uses the product's). There is NO inventory table and NO
--   low-stock threshold. Those two stock_quantity columns are, and remain, the ONLY stock authority.
--
-- WHAT THIS DOES
--   Creates ONE table, public.inventory_adjustments: a durable, append-only-by-design record of
--   manual stock adjustments that a LATER phase will write. It is an AUDIT / HISTORY table.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * It does not change stock. It does not touch products or product_variants at all (rows,
--     columns, grants, policies, indexes, triggers). The self-check proves no stock value moved.
--   * It creates no function, no trigger and no view. No adjustment function, no history reader,
--     no concurrency logic, no API and no application type: those are later phases.
--   * It adds no current_quantity / balance column. previous_quantity and new_quantity are
--     SNAPSHOTS belonging to one adjustment, not a second copy of the stock.
--   * It gives the browser roles no access of any kind (see ACCESS MODEL).
--
-- COLUMNS (all on public.inventory_adjustments)
--   id                   uuid primary key, default gen_random_uuid()
--   product_id           uuid NOT NULL -> products(id)  ON DELETE RESTRICT
--   variant_id           uuid NULL     -> product_variants(id) ON DELETE RESTRICT
--                        NULL  = the adjustment was to the PRODUCT's own stock_quantity
--                        set   = the adjustment was to that VARIANT's stock_quantity
--                        (the same product-unit / variant-unit split Phase 6C.2.1 reads)
--   previous_quantity    integer NOT NULL, >= 0   stock BEFORE this adjustment (snapshot)
--   adjustment_quantity  integer NOT NULL, <> 0   the signed change (the delta)
--   new_quantity         integer NOT NULL, >= 0   stock AFTER this adjustment (snapshot)
--   reason               text NOT NULL            trimmed, 1-120 characters
--   note                 text NULL                trimmed, 1-500 characters when present
--   changed_by           uuid NULL -> auth.users(id) ON DELETE SET NULL   (same as order_status_history)
--   created_at           timestamptz NOT NULL default now()
--   CHECK  new_quantity = previous_quantity + adjustment_quantity   (evaluated in bigint, so a
--          pair of large integers cannot overflow into a false pass)
--   Neither quantity can be negative, matching products_stock_nonnegative and
--   product_variants_stock_nonnegative: a history row can never describe a state the stock
--   tables themselves would reject.
--
-- DESIGN DECISIONS
--   * ON DELETE RESTRICT on product_id / variant_id: audit history must not vanish because a
--     catalogue row was deleted. The catalogue is retired with is_active, not deleted, so this
--     blocks nothing in normal use; a product or variant that has history simply cannot be hard
--     deleted. (order_status_history cascades because it is owned by its order; an adjustment
--     is evidence ABOUT a product, not owned by it.)
--   * changed_by is nullable with ON DELETE SET NULL, exactly like order_status_history.changed_by,
--     so deleting an auth user never deletes or blocks history. The future writer must set it from
--     auth.uid().
--   * No composite foreign key (variant must belong to product) because that needs a new unique
--     index on product_variants, and this phase must not alter that table. THE FUTURE ADJUSTMENT
--     FUNCTION MUST VERIFY variant.product_id = product_id before inserting a row.
--   * No trigger / function is added to make the table immutable: none is needed while no role can
--     write it, and a new function would be new surface for this phase. Immutability is by
--     privilege, not by trigger (see ACCESS MODEL).
--   * reason is free text with a length and trim rule, not an enum or a CHECK list: the reason
--     vocabulary is a product decision for the phase that writes the rows.
--
-- ACCESS MODEL
--   Supabase hands new tables to anon / authenticated through default privileges, so this
--   migration REVOKES ALL from public, anon and authenticated explicitly. Row level security is
--   ENABLED and there are NO policies, so even a stray future grant would still return no rows
--   (default deny). The browser therefore has no way to read or write this table.
--   service_role gets ALL, as on every other table in this project. The table is meant to be
--   written (later) ONLY from SECURITY DEFINER admin functions, which run as the function owner
--   and need no browser privilege. A history reader will likewise be a SECURITY DEFINER function
--   behind public.require_admin() - not a policy.
--
-- INDEXES
--   inventory_adjustments_product_idx  (product_id, created_at desc)  history of one product, and
--                                      the lookup the product foreign key needs.
--   inventory_adjustments_variant_idx  (variant_id, created_at desc) where variant_id is not null
--                                      history of one variant, and the variant foreign key lookup.
-- =============================================================================

begin;

-- =============================================================================
-- 0. PRECONDITIONS
-- =============================================================================
do $pre$
begin
  if to_regclass('public.inventory_adjustments') is not null then
    raise exception 'Phase 6C.2.2A.1 appears to be applied already (public.inventory_adjustments exists). Not running it twice.';
  end if;

  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_list_inventory(integer,integer,text,boolean,uuid)') is null
     or to_regprocedure('public.admin_get_inventory(uuid,uuid)') is null then
    raise exception 'Phase 6C.2.2A.1 precondition failed: Phase 6A / 6C.2.1 are not applied (require_admin() / admin_list_inventory() / admin_get_inventory() missing).';
  end if;

  if to_regclass('public.products') is null or to_regclass('public.product_variants') is null
     or to_regclass('auth.users') is null then
    raise exception 'Phase 6C.2.2A.1 precondition failed: products, product_variants or auth.users is missing.';
  end if;

  -- The stock authority this table must never duplicate: confirm it is what we think it is.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'products'
        and column_name in ('id', 'stock_quantity', 'in_stock')) <> 3
     or (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'product_variants'
           and column_name in ('id', 'product_id', 'stock_quantity')) <> 3 then
    raise exception 'Phase 6C.2.2A.1 precondition failed: the products / product_variants stock columns are not as expected.';
  end if;

  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'product_variants' and column_name = 'in_stock') then
    raise exception 'Phase 6C.2.2A.1 precondition failed: product_variants now has an in_stock column; review this design before applying.';
  end if;

  -- Browser roles must not be able to write the stock tables already (this migration must not
  -- be the thing that finds out, and must never widen it).
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.2A.1 precondition failed: a browser role can already write a stock table.';
  end if;

  -- Snapshots the self-check compares against: every stock value, and what the schema held.
  perform set_config('p6c2a1.stock_hash',
    (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                            '|' order by p.id) from public.products p), '')
             || '#' ||
             coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                         '|' order by v.id) from public.product_variants v), ''))),
    true);
  perform set_config('p6c2a1.rel_count',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text,
    true);
  perform set_config('p6c2a1.fn_count',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text,
    true);
  perform set_config('p6c2a1.prod_acl',
    (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                    '|' order by c.relname), ''))
     from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
       and c.relname in ('products', 'product_variants', 'orders', 'order_items', 'order_status_history', 'user_roles')),
    true);
  perform set_config('p6c2a1.policy_hash',
    (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                    '|' order by tablename, policyname), ''))
     from pg_policies where schemaname = 'public'),
    true);
end
$pre$;

-- =============================================================================
-- 1. THE HISTORY TABLE
-- =============================================================================
create table public.inventory_adjustments (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete restrict,
  variant_id uuid references public.product_variants (id) on delete restrict,
  previous_quantity integer not null,
  adjustment_quantity integer not null,
  new_quantity integer not null,
  reason text not null,
  note text,
  changed_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint inventory_adjustments_previous_nonnegative check (previous_quantity >= 0),
  constraint inventory_adjustments_new_nonnegative check (new_quantity >= 0),
  constraint inventory_adjustments_delta_nonzero check (adjustment_quantity <> 0),
  constraint inventory_adjustments_quantities_consistent
    check (new_quantity::bigint = previous_quantity::bigint + adjustment_quantity::bigint),
  constraint inventory_adjustments_reason_valid
    check (reason = btrim(reason) and char_length(reason) between 1 and 120),
  constraint inventory_adjustments_note_valid
    check (note is null or (note = btrim(note) and char_length(note) between 1 and 500))
);

create index inventory_adjustments_product_idx
  on public.inventory_adjustments (product_id, created_at desc);
create index inventory_adjustments_variant_idx
  on public.inventory_adjustments (variant_id, created_at desc)
  where variant_id is not null;

comment on table public.inventory_adjustments is
  'Phase 6C.2.2A.1. AUDIT / HISTORY of manual stock adjustments. NOT a stock source: products.stock_quantity and product_variants.stock_quantity remain the only authority. previous_quantity / new_quantity are snapshots of one adjustment. No browser access; written only by future SECURITY DEFINER admin functions.';
comment on column public.inventory_adjustments.variant_id is
  'NULL = the adjustment was to the product''s own stock_quantity; set = to that variant''s stock_quantity. The writer must verify the variant belongs to product_id.';
comment on column public.inventory_adjustments.previous_quantity is
  'Snapshot: the stock of that unit immediately before this adjustment. Not the current stock.';
comment on column public.inventory_adjustments.adjustment_quantity is
  'The signed change (delta) applied by this adjustment. Never zero.';
comment on column public.inventory_adjustments.new_quantity is
  'Snapshot: the stock of that unit immediately after this adjustment (= previous_quantity + adjustment_quantity). Not the current stock.';
comment on column public.inventory_adjustments.changed_by is
  'The admin who made the adjustment (auth.uid() in the future writer). Set to NULL if that auth user is deleted, so history survives.';

-- =============================================================================
-- 2. SECURITY: no browser access, default deny
-- =============================================================================
-- Supabase default privileges would otherwise hand this table to anon / authenticated.
revoke all on table public.inventory_adjustments from public, anon, authenticated;
grant all on table public.inventory_adjustments to service_role;

-- RLS on with NO policy = default deny, even if a grant were ever added by mistake.
alter table public.inventory_adjustments enable row level security;

-- =============================================================================
-- 3. SELF-CHECK - abort (and roll everything back) if the guarantees do not hold.
-- =============================================================================
do $check$
declare
  v_oid oid := 'public.inventory_adjustments'::regclass;
begin
  -- Exactly one new table, no new function / trigger / view / policy; nothing existing changed.
  if (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p'))::text
       is distinct from (current_setting('p6c2a1.rel_count', true)::integer + 1)::text then
    raise exception 'Phase 6C.2.2A.1 self-check failed: exactly one table must have been added.';
  end if;

  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)::text
       is distinct from current_setting('p6c2a1.fn_count', true) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the number of public functions changed.';
  end if;

  if exists (select 1 from pg_trigger t where t.tgrelid = v_oid and not t.tgisinternal) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the history table carries a trigger.';
  end if;

  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inventory_adjustments') then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the history table has a policy (it must have none).';
  end if;

  if not (select relrowsecurity from pg_class where oid = v_oid) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: row level security is off on the history table.';
  end if;

  if (select md5(coalesce(string_agg(tablename || '/' || policyname || '/' || cmd || '/' || coalesce(qual, ''),
                                     '|' order by tablename, policyname), ''))
      from pg_policies where schemaname = 'public') is distinct from current_setting('p6c2a1.policy_hash', true) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: an existing policy changed.';
  end if;

  if (select md5(coalesce(string_agg(c.relname || '/' || coalesce(c.relacl::text, '') || '/' || c.relrowsecurity::text,
                                     '|' order by c.relname), ''))
      from pg_class c
      where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
        and c.relname in ('products', 'product_variants', 'orders', 'order_items', 'order_status_history', 'user_roles'))
     is distinct from current_setting('p6c2a1.prod_acl', true) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the grants / RLS flag of an existing table changed.';
  end if;

  -- Browser roles hold NO privilege at all on the new table (table or column level) ...
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pv(priv)
    where has_table_privilege(r.role, v_oid, pv.priv)
       or has_any_column_privilege(r.role, v_oid, 'SELECT')
       or has_any_column_privilege(r.role, v_oid, 'INSERT')
       or has_any_column_privilege(r.role, v_oid, 'UPDATE')
       or has_any_column_privilege(r.role, v_oid, 'REFERENCES')
  ) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: a browser role holds a privilege on the history table.';
  end if;

  -- ... and neither does the PUBLIC pseudo-role.
  if exists (
    select 1
    from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
    where c.oid = v_oid and a.grantee = 0
  ) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: PUBLIC holds a privilege on the history table.';
  end if;

  -- The stock tables are still not writable from the browser.
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) r(role),
         (values ('public.products'), ('public.product_variants')) t(tbl),
         (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pv(priv)
    where has_table_privilege(r.role, t.tbl, pv.priv)
       or has_any_column_privilege(r.role, t.tbl, 'INSERT')
       or has_any_column_privilege(r.role, t.tbl, 'UPDATE')
  ) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: a browser role can write a stock table.';
  end if;

  -- The structure is what was promised: three foreign keys with the intended delete rules.
  if (select count(*) from pg_constraint
      where conrelid = v_oid and contype = 'f') <> 3
     or not exists (select 1 from pg_constraint where conrelid = v_oid and contype = 'f'
                      and confrelid = 'public.products'::regclass and confdeltype = 'r')
     or not exists (select 1 from pg_constraint where conrelid = v_oid and contype = 'f'
                      and confrelid = 'public.product_variants'::regclass and confdeltype = 'r')
     or not exists (select 1 from pg_constraint where conrelid = v_oid and contype = 'f'
                      and confrelid = 'auth.users'::regclass and confdeltype = 'n') then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the foreign keys are not as designed.';
  end if;

  -- No authoritative-looking balance column crept in.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'inventory_adjustments'
               and column_name in ('current_quantity', 'stock_quantity', 'quantity', 'balance', 'in_stock')) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the history table has a column that looks like a second stock source.';
  end if;

  -- THE PHASE'S CENTRAL PROMISE: no stock value of any product or variant moved.
  if (select md5(coalesce((select string_agg(p.id::text || ':' || p.stock_quantity::text || ':' || p.in_stock::text,
                                             '|' order by p.id) from public.products p), '')
              || '#' ||
              coalesce((select string_agg(v.id::text || ':' || v.stock_quantity::text,
                                          '|' order by v.id) from public.product_variants v), '')))
       is distinct from current_setting('p6c2a1.stock_hash', true) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: a stock value changed. This phase must not change stock.';
  end if;

  -- The new table starts empty.
  if exists (select 1 from public.inventory_adjustments) then
    raise exception 'Phase 6C.2.2A.1 self-check failed: the history table is not empty.';
  end if;
end
$check$;

commit;
