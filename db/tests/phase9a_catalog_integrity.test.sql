-- Phase 9A test: catalog integrity (case-insensitive SKU uniqueness, order_items FK indexes).
-- NOT RUN unless the report says so. Needs migrations up to 20261009030000 applied.
-- Run as postgres/owner, as ONE query. Everything is rolled back at the end.
-- Fixtures use slugs / SKUs starting with t9a- / T9A-.
begin;

create or replace function pg_temp.ok(c boolean, n text) returns void language plpgsql as $$
begin
  if c is not true then
    raise exception 'FAIL: %', n;
  end if;
  raise notice 'PASS: %', n;
end $$;

-- Runs a statement; returns its SQLSTATE and constraint name ('00000' / null when it succeeds).
-- Each call is a sub-transaction, so a refused insert leaves no trace.
create or replace function pg_temp.try(q text, out state text, out cons text) language plpgsql as $$
begin
  state := '00000';
  cons := null;
  begin
    execute q;
  exception when others then
    get stacked diagnostics state = returned_sqlstate, cons = constraint_name;
  end;
end $$;

-- ---------------------------------------------------------------- S: structure
select pg_temp.ok(
  (select i.indisunique from pg_index i where i.indexrelid = 'public.products_sku_key'::regclass)
  and pg_get_indexdef('public.products_sku_key'::regclass) ilike '%(lower(sku))%'
  and pg_get_indexdef('public.products_sku_key'::regclass) ilike '%where (sku is not null)%',
  'S1 products_sku_key is a partial unique index on lower(sku)');
select pg_temp.ok(
  (select i.indisunique from pg_index i where i.indexrelid = 'public.product_variants_sku_key'::regclass)
  and pg_get_indexdef('public.product_variants_sku_key'::regclass) ilike '%(lower(sku))%'
  and pg_get_indexdef('public.product_variants_sku_key'::regclass) ilike '%where (sku is not null)%',
  'S2 product_variants_sku_key is a partial unique index on lower(sku)');
select pg_temp.ok(
  to_regclass('public.order_items_product_id_idx') is not null
  and to_regclass('public.order_items_variant_id_idx') is not null,
  'S3 order_items product_id / variant_id indexes exist');

-- Existing integrity that this phase must not have weakened.
select pg_temp.ok(
  (select count(*) from pg_constraint
    where conname in ('products_price_nonnegative', 'products_compare_at_valid',
                      'product_variants_price_nonnegative', 'product_variants_compare_at_valid',
                      'order_items_price_nonnegative')) = 5,
  'S4 the existing price and compare_at CHECK constraints are still in place');

-- ---------------------------------------------------------------- P: product SKU
insert into public.products (slug, name, price_cents, sku) values ('t9a-p1', 'T9A P1', 100, 'T9A-ABC-1');

select pg_temp.ok(
  (select state = '23505' and cons = 'products_sku_key'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents, sku)
                         values ('t9a-p2', 'T9A P2', 100, 't9a-abc-1')$q$)),
  'P1 a product SKU differing only in case is refused (23505 / products_sku_key)');
select pg_temp.ok(
  (select state = '23505' and cons = 'products_sku_key'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents, sku)
                         values ('t9a-p3', 'T9A P3', 100, 'T9A-abc-1')$q$)),
  'P2 a mixed-case duplicate is refused too');
select pg_temp.ok(
  (select state = '00000'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents, sku)
                         values ('t9a-p4', 'T9A P4', 100, 'T9A-ABC-2')$q$)),
  'P3 a different SKU is accepted');
select pg_temp.ok(
  (select state = '00000'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents)
                         values ('t9a-p5', 'T9A P5', 100), ('t9a-p6', 'T9A P6', 100)$q$)),
  'P4 several products without a SKU are still allowed (partial index)');
select pg_temp.ok(
  (select state = '23505' and cons = 'products_sku_key'
     from pg_temp.try($q$update public.products set sku = 't9a-abc-1' where slug = 't9a-p4'$q$)),
  'P5 updating a SKU to a case-variant of another product SKU is refused');

-- ---------------------------------------------------------------- V: variant SKU
insert into public.product_variants (product_id, name, price_cents, sku)
  select id, 'V1', 100, 'T9A-VAR-1' from public.products where slug = 't9a-p1';

select pg_temp.ok(
  (select state = '23505' and cons = 'product_variants_sku_key'
     from pg_temp.try($q$insert into public.product_variants (product_id, name, price_cents, sku)
                         select id, 'V2', 100, 't9a-var-1' from public.products where slug = 't9a-p4'$q$)),
  'V1 a variant SKU differing only in case is refused, even under another product (23505 / product_variants_sku_key)');
select pg_temp.ok(
  (select state = '00000'
     from pg_temp.try($q$insert into public.product_variants (product_id, name, price_cents, sku)
                         select id, 'V3', 100, 'T9A-VAR-2' from public.products where slug = 't9a-p4'$q$)),
  'V2 a different variant SKU is accepted');
select pg_temp.ok(
  (select state = '00000'
     from pg_temp.try($q$insert into public.product_variants (product_id, name, price_cents)
                         select id, x, 100 from public.products, (values ('N1'), ('N2')) v(x)
                          where slug = 't9a-p4'$q$)),
  'V3 several variants without a SKU are still allowed');
select pg_temp.ok(
  (select state = '00000'
     from pg_temp.try($q$insert into public.product_variants (product_id, name, price_cents, sku)
                         select id, 'V4', 100, 'T9A-ABC-1' from public.products where slug = 't9a-p1'$q$)),
  'V4 a variant SKU may equal a product SKU (uniqueness is per level, as before)');

-- ---------------------------------------------------------------- K: existing CHECKs still bite
select pg_temp.ok(
  (select state = '23514'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents) values ('t9a-k1', 'T9A K1', -1)$q$)),
  'K1 a negative product price is still refused');
select pg_temp.ok(
  (select state = '23514'
     from pg_temp.try($q$insert into public.products (slug, name, price_cents, compare_at_price_cents)
                         values ('t9a-k2', 'T9A K2', 500, 499)$q$)),
  'K2 compare_at below the price is still refused');
select pg_temp.ok(
  (select state = '23514'
     from pg_temp.try($q$insert into public.product_variants (product_id, name, price_cents, compare_at_price_cents)
                         select id, 'K3', 500, 499 from public.products where slug = 't9a-p1'$q$)),
  'K3 variant compare_at below the price is still refused');

rollback;
