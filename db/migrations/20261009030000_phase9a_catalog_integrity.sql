-- =============================================================================
-- PHASE 9A: catalog integrity (audit-driven; ONLY what was missing).
--
-- AUDIT RESULT (from migrations 20260930000000 .. 20261009020000):
--   already there, NOT touched here:
--     price_cents >= 0 CHECKs (products, product_variants, order_items), stock_quantity >= 0 CHECKs,
--     compare_at CHECKs (null or >= price_cents; equality is deliberately accepted and tested by the
--     6C.1B.1 / 6C.1B.2 SQL tests), products.category_id FK (on delete set null) + indexes,
--     product_variants.product_id FK + index, products.lower(brand) index, inventory_adjustments ledger,
--     order_items snapshot columns.
--   MISSING, added here:
--     1. SKU uniqueness was case-SENSITIVE ('ABC-1' and 'abc-1' were both allowed) at product level
--        and at variant level.
--     2. order_items.product_id / order_items.variant_id are foreign keys (on delete set null) with no
--        index, so every product / variant delete scans order_items.
--
-- WHAT CHANGES:
--   products_sku_key          unique on (sku) where sku is not null      -> unique on (lower(sku)) where sku is not null
--   product_variants_sku_key  same, for variants
--   The index NAMES are kept on purpose: the admin writers map a duplicate to 23505 / DETAIL sku_taken by
--   the violated index name, and later migrations check that these two indexes exist. Nothing else in
--   the database or the frontend needs to change. SKUs stay unique per level (a product SKU may equal a
--   variant SKU, as before).
--   New: order_items_product_id_idx, order_items_variant_id_idx (partial: where not null).
--
-- NOT DONE (needs a decision or a new table; see the report): a brands table + brand FK (brand is free
--   text and no new tables are allowed), a product_images table, a per-product low-stock threshold.
--
-- NO functions are created or changed (create_order() is untouched), so there is no SECURITY DEFINER /
-- search_path / grant question. No table privileges or policies change.
--
-- PRECONDITION: fails with a list when existing rows would violate the new SKU uniqueness.
-- TAKES a short ACCESS EXCLUSIVE lock on products / product_variants while the two indexes are rebuilt.
--
-- STATUS: written, NOT applied to any database, NOT executed. Test with
-- db/tests/phase9a_catalog_integrity.test.sql.
-- =============================================================================
begin;

-- 0. Preconditions ------------------------------------------------------------------------------
do $pre$
declare
  v_prod_dups bigint;
  v_var_dups bigint;
  v_prod_list text;
  v_var_list text;
begin
  if to_regclass('public.products') is null
     or to_regclass('public.product_variants') is null
     or to_regclass('public.order_items') is null then
    raise exception 'Phase 9A precondition failed: products / product_variants / order_items are missing.';
  end if;

  if to_regclass('public.products_sku_key') is null
     or to_regclass('public.product_variants_sku_key') is null then
    raise exception 'Phase 9A precondition failed: the unique indexes products_sku_key / product_variants_sku_key are missing.';
  end if;

  if to_regclass('public.inventory_adjustments') is null
     or to_regprocedure('public.validate_coupon(jsonb,text,text,uuid)') is null then
    raise exception 'Phase 9A precondition failed: apply every migration through 20261009020000 first.';
  end if;

  if pg_get_indexdef('public.products_sku_key'::regclass) ilike '%lower(%'
     or pg_get_indexdef('public.product_variants_sku_key'::regclass) ilike '%lower(%' then
    raise exception 'Phase 9A appears to be applied already (SKU indexes are already case-insensitive). Not running it twice.';
  end if;

  select count(*), string_agg(k, ', ' order by k)
    into v_prod_dups, v_prod_list
    from (select lower(sku) as k from public.products where sku is not null
           group by lower(sku) having count(*) > 1 order by lower(sku) limit 20) d;

  select count(*), string_agg(k, ', ' order by k)
    into v_var_dups, v_var_list
    from (select lower(sku) as k from public.product_variants where sku is not null
           group by lower(sku) having count(*) > 1 order by lower(sku) limit 20) d;

  if v_prod_dups > 0 or v_var_dups > 0 then
    raise exception
      'Phase 9A precondition failed: SKUs that differ only by letter case. products: % duplicate SKU group(s) [%]; product_variants: % duplicate SKU group(s) [%] (each list shows at most 20). Fix or change these SKUs, then run again.',
      v_prod_dups, coalesce(v_prod_list, '-'), v_var_dups, coalesce(v_var_list, '-');
  end if;
end
$pre$;

-- 1. Case-insensitive SKU uniqueness (same index names) -----------------------------------------
drop index public.products_sku_key;
create unique index products_sku_key
  on public.products (lower(sku)) where sku is not null;

drop index public.product_variants_sku_key;
create unique index product_variants_sku_key
  on public.product_variants (lower(sku)) where sku is not null;

-- 2. Indexes for the order_items foreign keys ----------------------------------------------------
create index if not exists order_items_product_id_idx
  on public.order_items (product_id) where product_id is not null;
create index if not exists order_items_variant_id_idx
  on public.order_items (variant_id) where variant_id is not null;

-- 3. Self-check ----------------------------------------------------------------------------------
do $chk$
declare
  v_dup_blocked boolean;
begin
  if not exists (select 1 from pg_index i where i.indexrelid = 'public.products_sku_key'::regclass
                    and i.indisunique and i.indrelid = 'public.products'::regclass)
     or pg_get_indexdef('public.products_sku_key'::regclass) not ilike '%lower(sku)%'
     or pg_get_indexdef('public.products_sku_key'::regclass) not ilike '%where (sku is not null)%' then
    raise exception 'Phase 9A self-check failed: products_sku_key is not a partial unique index on lower(sku).';
  end if;

  if not exists (select 1 from pg_index i where i.indexrelid = 'public.product_variants_sku_key'::regclass
                    and i.indisunique and i.indrelid = 'public.product_variants'::regclass)
     or pg_get_indexdef('public.product_variants_sku_key'::regclass) not ilike '%lower(sku)%'
     or pg_get_indexdef('public.product_variants_sku_key'::regclass) not ilike '%where (sku is not null)%' then
    raise exception 'Phase 9A self-check failed: product_variants_sku_key is not a partial unique index on lower(sku).';
  end if;

  if to_regclass('public.order_items_product_id_idx') is null
     or to_regclass('public.order_items_variant_id_idx') is null then
    raise exception 'Phase 9A self-check failed: the order_items indexes are missing.';
  end if;

  -- Behaviour, inside sub-transactions that always roll back: a SKU that differs only in case is refused.
  v_dup_blocked := false;
  begin
    insert into public.products (slug, name, price_cents, sku)
      values ('phase9a-selfcheck-a', 'Phase 9A selfcheck A', 100, 'P9A-SELFCHECK');
    insert into public.products (slug, name, price_cents, sku)
      values ('phase9a-selfcheck-b', 'Phase 9A selfcheck B', 100, 'p9a-selfcheck');
  exception when unique_violation then
    v_dup_blocked := true;
  end;
  if not v_dup_blocked then
    raise exception 'Phase 9A self-check failed: a product SKU differing only in case was accepted.';
  end if;

  v_dup_blocked := false;
  begin
    insert into public.products (slug, name, price_cents)
      values ('phase9a-selfcheck-v', 'Phase 9A selfcheck V', 100);
    insert into public.product_variants (product_id, name, price_cents, sku)
      select id, 'A', 100, 'P9A-VSELFCHECK' from public.products where slug = 'phase9a-selfcheck-v';
    insert into public.product_variants (product_id, name, price_cents, sku)
      select id, 'B', 100, 'p9a-vselfcheck' from public.products where slug = 'phase9a-selfcheck-v';
  exception when unique_violation then
    v_dup_blocked := true;
  end;
  if not v_dup_blocked then
    raise exception 'Phase 9A self-check failed: a variant SKU differing only in case was accepted.';
  end if;

  if exists (select 1 from public.products where slug like 'phase9a-selfcheck%') then
    raise exception 'Phase 9A self-check failed: a self-check row was left behind.';
  end if;
end
$chk$;

commit;
