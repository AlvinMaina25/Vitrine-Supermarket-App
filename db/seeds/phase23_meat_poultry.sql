-- Phase 23: meat & poultry seed (1 category, 24 products, variants for weight options).
-- A DATA SEED, not a migration. Run by hand in the Supabase SQL editor.
-- Safe to run MORE THAN ONCE: existing rows (matched by slug / variant name) are skipped and
-- nothing is overwritten, so random stock is only ever set the first time.
--
-- HOW IT WORKS
--   PART 1 (creates): the category and products are created HIDDEN (inactive) with RANDOM stock,
--           so nothing shows in the shop until it has a photo. Weight options (500g / 1kg) are
--           variants with their own random stock.
--   PART 2 (goes live): switches on every product that HAS a photo, and the category once at least
--           one product is live. Upload photos in /admin, then run this file again.
--
-- NOTES
--   * Stock numbers are RANDOM (5 to 30 per item) and NOT real. Replace them with your real
--     counts in Admin -> Inventory before taking real orders. Meat is perishable, so keep it honest.
--   * Prices are ESTIMATES in whole Kenya shillings, stored as cents (x 100). Replace them with yours.
--   * Part 2 re-activates any MEAT- product that has a photo. If you deliberately hide one later,
--     do not run this file again (hide it again in Admin if you do).
--   * Products with weight options use the variants' price and stock; the product keeps stock 0.
--   * Stock set on INSERT is an opening balance (not written to the inventory history).

begin;

-- PART 1 -------------------------------------------------------------------------------------
insert into public.categories (slug, name, tagline, description, image_url, position, is_active)
select 'meat-poultry', 'Meat & Poultry', 'Fresh beef, goat, chicken and more', 'Fresh and packed meat: beef, goat, mutton, chicken, pork and sausages.', null,
       coalesce((select max(position) from public.categories where parent_id is null), 0) + 1,
       false
where not exists (select 1 from public.categories where slug = 'meat-poultry');

with items (slug, name, brand, sku, description, price_kes, has_variants) as (
  values
    ('beef-steak', 'Beef Steak', null::text, 'MEAT-BF-STK', 'Fresh beef steak cuts, ideal for grilling or pan-frying. Choose your weight.', 450, true),
    ('beef-fillet', 'Beef Fillet', null::text, 'MEAT-BF-FIL', 'Tender premium beef fillet. Choose your weight.', 680, true),
    ('beef-mince', 'Beef Mince', null::text, 'MEAT-BF-MNC', 'Freshly minced lean beef for burgers, sauces and samosas. Choose your weight.', 370, true),
    ('beef-stew-boneless', 'Boneless Beef Stew Cubes', null::text, 'MEAT-BF-STW', 'Boneless beef cut into cubes for stews and curries. Choose your weight.', 400, true),
    ('beef-with-bones', 'Beef with Bones 1kg', null::text, 'MEAT-BF-BNE', 'Beef on the bone for soups and slow-cooked meals. About 1kg.', 600, false),
    ('beef-ribs', 'Beef Ribs 1kg', null::text, 'MEAT-BF-RIB', 'Meaty beef ribs for roasting or barbecue. About 1kg.', 700, false),
    ('ox-liver', 'Ox Liver 1kg', null::text, 'MEAT-BF-LIV', 'Fresh ox liver. About 1kg.', 550, false),
    ('beef-tripe-matumbo', 'Beef Tripe (Matumbo) 1kg', null::text, 'MEAT-BF-TRP', 'Cleaned beef tripe, a Kenyan favourite. About 1kg.', 500, false),
    ('goat-meat-bone-in', 'Goat Meat (Bone-in)', null::text, 'MEAT-GT-BNE', 'Fresh goat meat cut with bone, for nyama choma or stew. Choose your weight.', 470, true),
    ('mutton-chops', 'Mutton Chops', null::text, 'MEAT-MT-CHP', 'Fresh mutton chops for grilling or frying. Choose your weight.', 500, true),
    ('whole-broiler-chicken', 'Whole Broiler Chicken (about 1.2kg)', null::text, 'MEAT-CK-WHL', 'Fresh whole broiler chicken, cleaned and ready to cook. About 1.2kg.', 650, false),
    ('kienyeji-chicken-whole', 'Kienyeji (Free-range) Chicken, Whole', null::text, 'MEAT-CK-KNY', 'Whole free-range kienyeji chicken, cleaned. About 1.2kg.', 1100, false),
    ('chicken-breast-fillets', 'Chicken Breast Fillets', null::text, 'MEAT-CK-BRS', 'Skinless, boneless chicken breast fillets. Choose your weight.', 370, true),
    ('chicken-drumsticks', 'Chicken Drumsticks', null::text, 'MEAT-CK-DRM', 'Chicken drumsticks for frying, baking or grilling. Choose your weight.', 290, true),
    ('chicken-thighs', 'Chicken Thighs 1kg', null::text, 'MEAT-CK-THG', 'Juicy chicken thighs. About 1kg.', 520, false),
    ('chicken-wings', 'Chicken Wings 1kg', null::text, 'MEAT-CK-WNG', 'Chicken wings for frying or the oven. About 1kg.', 500, false),
    ('pork-chops', 'Pork Chops 1kg', null::text, 'MEAT-PK-CHP', 'Fresh pork chops. About 1kg.', 750, false),
    ('pork-ribs', 'Pork Ribs 1kg', null::text, 'MEAT-PK-RIB', 'Pork ribs for roasting or barbecue. About 1kg.', 700, false),
    ('streaky-bacon-200g', 'Streaky Bacon 200g', null::text, 'MEAT-PK-BAC', 'Sliced streaky bacon, 200g pack.', 380, false),
    ('pork-sausages-500g', 'Pork Sausages 500g', null::text, 'MEAT-SG-PRK', 'Pork sausages, 500g pack.', 450, false),
    ('beef-sausages-500g', 'Beef Sausages 500g', null::text, 'MEAT-SG-BEF', 'Beef sausages, 500g pack.', 420, false),
    ('chicken-sausages-500g', 'Chicken Sausages 500g', null::text, 'MEAT-SG-CKN', 'Chicken sausages, 500g pack.', 400, false),
    ('smokies-10-pack', 'Smokies, 10 Pack', null::text, 'MEAT-SG-SMK', 'Pack of 10 smoked sausages (smokies).', 300, false),
    ('ham-slices-200g', 'Ham Slices 200g', null::text, 'MEAT-HM-SLC', 'Sliced cooked ham, 200g pack.', 330, false)
)
insert into public.products
  (slug, name, category_id, description, brand, sku, image_url, price_cents, compare_at_price_cents,
   unit_label, stock_quantity, in_stock, is_active)
select i.slug, i.name, c.id, i.description, i.brand, i.sku, null,
       i.price_kes * 100, null, 'pack',
       case when i.has_variants then 0 else 5 + floor(random() * 26)::int end,   -- 5 to 30
       true,
       false
from items i
cross join (select id from public.categories where slug = 'meat-poultry') c
where not exists (select 1 from public.products p where p.slug = i.slug);

with variant_rows (product_slug, name, sku, price_kes, attributes, position) as (
  values
    ('beef-steak', '500g', 'MEAT-BF-STK-500G', 450, '{"weight": "500g"}', 0),
    ('beef-steak', '1kg', 'MEAT-BF-STK-1KG', 850, '{"weight": "1kg"}', 1),
    ('beef-fillet', '500g', 'MEAT-BF-FIL-500G', 680, '{"weight": "500g"}', 0),
    ('beef-fillet', '1kg', 'MEAT-BF-FIL-1KG', 1300, '{"weight": "1kg"}', 1),
    ('beef-mince', '500g', 'MEAT-BF-MNC-500G', 370, '{"weight": "500g"}', 0),
    ('beef-mince', '1kg', 'MEAT-BF-MNC-1KG', 700, '{"weight": "1kg"}', 1),
    ('beef-stew-boneless', '500g', 'MEAT-BF-STW-500G', 400, '{"weight": "500g"}', 0),
    ('beef-stew-boneless', '1kg', 'MEAT-BF-STW-1KG', 750, '{"weight": "1kg"}', 1),
    ('goat-meat-bone-in', '500g', 'MEAT-GT-BNE-500G', 470, '{"weight": "500g"}', 0),
    ('goat-meat-bone-in', '1kg', 'MEAT-GT-BNE-1KG', 900, '{"weight": "1kg"}', 1),
    ('mutton-chops', '500g', 'MEAT-MT-CHP-500G', 500, '{"weight": "500g"}', 0),
    ('mutton-chops', '1kg', 'MEAT-MT-CHP-1KG', 950, '{"weight": "1kg"}', 1),
    ('chicken-breast-fillets', '500g', 'MEAT-CK-BRS-500G', 370, '{"weight": "500g"}', 0),
    ('chicken-breast-fillets', '1kg', 'MEAT-CK-BRS-1KG', 700, '{"weight": "1kg"}', 1),
    ('chicken-drumsticks', '500g', 'MEAT-CK-DRM-500G', 290, '{"weight": "500g"}', 0),
    ('chicken-drumsticks', '1kg', 'MEAT-CK-DRM-1KG', 550, '{"weight": "1kg"}', 1)
)
insert into public.product_variants
  (product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity, attributes, position, is_active)
select p.id, v.name, v.sku, v.price_kes * 100, null,
       5 + floor(random() * 26)::int,                                            -- 5 to 30
       v.attributes::jsonb, v.position, true
from variant_rows v
join public.products p on p.slug = v.product_slug
where not exists (select 1 from public.product_variants x where x.product_id = p.id and x.name = v.name);

-- PART 2 -------------------------------------------------------------------------------------
-- Go live: only products that already have a photo.
update public.products
   set is_active = true, in_stock = true
 where sku like 'MEAT-%'
   and image_url is not null
   and not is_active;

-- The category appears once at least one meat product is live.
update public.categories c
   set is_active = true
 where c.slug = 'meat-poultry'
   and not c.is_active
   and exists (select 1 from public.products p
                where p.category_id = c.id and p.sku like 'MEAT-%' and p.is_active);

-- Result: counts, then the products still hidden because they have no photo yet.
select (select count(*) from public.products         where sku like 'MEAT-%')              as products,
       (select count(*) from public.product_variants where sku like 'MEAT-%')              as variants,
       (select count(*) from public.products         where sku like 'MEAT-%' and is_active) as live,
       (select is_active from public.categories      where slug = 'meat-poultry')          as category_live;

select sku, name from public.products
 where sku like 'MEAT-%' and not is_active
 order by name;

commit;

-- To remove everything (only if nothing has been ordered yet):
--   delete from public.products where sku like 'MEAT-%';   -- variants go with them
--   delete from public.categories where slug = 'meat-poultry';
