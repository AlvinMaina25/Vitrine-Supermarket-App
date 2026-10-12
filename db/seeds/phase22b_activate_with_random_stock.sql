-- Phase 22b: switch the branded electronics (SKU starts with BRD-) on and give them RANDOM stock.
-- Run by hand in the Supabase SQL editor AFTER phase22_branded_electronics.sql and after you have
-- uploaded the photos. One transaction.
--
-- READ THIS FIRST
--   * The stock numbers are RANDOM and NOT real. Customers can order up to that many, so change
--     them to what you really have (Admin -> Inventory) before taking real orders.
--   * Only products that already HAVE a photo are switched on. Products without one stay hidden;
--     the last query lists them.
--   * Random ranges: items priced KES 30,000 or more get 2-6 units, everything else 10-40.
--   * Products with variants: the variants get the stock and are switched on; the product itself
--     keeps stock 0 (the shop reads the variants' stock, not the product's).
--   * Stock changes made here are written to the inventory history by the database trigger as
--     "Stock changed outside the admin tool". That is expected.
--   * Switching on in SQL does not write an audit-log entry (the Admin switch does).

begin;

-- 1. Variants of branded products that belong to a product with a photo.
update public.product_variants v
   set stock_quantity = case when v.price_cents >= 3000000
                             then 2 + floor(random() * 5)::int      -- 2 to 6
                             else 10 + floor(random() * 31)::int    -- 10 to 40
                        end,
       is_active = true
  from public.products p
 where v.product_id = p.id
   and p.sku like 'BRD-%'
   and p.image_url is not null;

-- 2. Products with NO variants: random stock. Products WITH variants keep stock 0.
update public.products p
   set stock_quantity = case when p.price_cents >= 3000000
                             then 2 + floor(random() * 5)::int
                             else 10 + floor(random() * 31)::int
                        end
 where p.sku like 'BRD-%'
   and p.image_url is not null
   and not exists (select 1 from public.product_variants v where v.product_id = p.id);

-- 3. Switch on every branded product that has a photo.
update public.products p
   set in_stock = true,
       is_active = true
 where p.sku like 'BRD-%'
   and p.image_url is not null;

-- Result: live products, live variants, and any branded product still hidden (no photo).
select (select count(*) from public.products          where sku like 'BRD-%' and is_active) as live_products,
       (select count(*) from public.product_variants  where sku like 'BRD-%' and is_active) as live_variants,
       (select count(*) from public.products          where sku like 'BRD-%' and not is_active) as still_hidden;

select sku, name from public.products
 where sku like 'BRD-%' and not is_active
 order by name;

commit;

-- To hide them all again:
--   update public.products set is_active = false where sku like 'BRD-%';
