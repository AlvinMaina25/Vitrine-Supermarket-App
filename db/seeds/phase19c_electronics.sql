-- Phase 19C: Electronics category + 20 products. A DATA SEED, not a migration: run it by hand in the
-- Supabase SQL editor, ONCE, AFTER the images are deployed (see the list at the bottom).
-- Safe to run twice: rows whose slug already exists are skipped, nothing is overwritten.
--
-- All prices are ESTIMATES in Kenya shillings (KES), written in whole shillings and stored as cents
-- (x 100). Names, descriptions and stock are placeholders: edit them to match what you really sell.
-- price 0 in compare_kes means "no offer"; otherwise it is the old, higher price.
-- Stock is an opening balance (an INSERT is not logged in the inventory ledger, by design).

begin;

insert into public.categories (slug, name, tagline, description, image_url, position, is_active)
select 'electronics',
       'Electronics',
       'TVs, fridges and home appliances',
       'Televisions, fridges, freezers, kitchen appliances, audio and everyday gadgets.',
       '/categories/electronics.jpg',
       coalesce((select max(position) from public.categories where parent_id is null), 0) + 1,
       true
where not exists (select 1 from public.categories where slug = 'electronics');

with items (slug, name, sku, description, price_kes, compare_kes, stock) as (
  values
    ('tv-32-inch-led',            '32-inch LED TV',                 'ELEC-TV-32',  '32-inch LED television with HDMI and USB ports.',                    15500,     0, 12),
    ('tv-43-inch-smart',          '43-inch Smart TV',               'ELEC-TV-43',  '43-inch smart television with built-in apps and Wi-Fi.',             29900, 33900, 10),
    ('tv-55-inch-4k',             '55-inch 4K TV',                  'ELEC-TV-55',  '55-inch 4K ultra HD television.',                                    54900,     0,  6),
    ('fridge-double-door',        'Double-door Fridge',             'ELEC-FRG-DD', 'Double-door refrigerator with a separate freezer compartment.',      49900,     0,  5),
    ('fridge-mini-bar',           'Mini Bar Fridge',                'ELEC-FRG-MB', 'Compact bar fridge for a bedroom, office or small kitchen.',         17500,     0,  8),
    ('chest-freezer',             'Chest Freezer',                  'ELEC-FRZ-CH', 'Chest freezer for bulk storage of meat, fish and frozen food.',      38000,     0,  4),
    ('washing-machine-front-load','Front-load Washing Machine',     'ELEC-WSH-FL', 'Front-loading automatic washing machine.',                           52000,     0,  4),
    ('microwave-oven-25l',        'Microwave Oven 25L',             'ELEC-MIC-25', '25-litre countertop microwave oven.',                                11500,     0, 15),
    ('electric-kettle-17l',       'Electric Kettle 1.7L',           'ELEC-KET-17', 'Cordless 1.7-litre electric kettle with auto shut-off.',              1800,  2200, 40),
    ('blender',                   'Kitchen Blender',                'ELEC-BLD-01', 'Countertop blender with a glass jug.',                                4500,     0, 20),
    ('toaster-2-slice',           '2-slice Toaster',                'ELEC-TST-02', 'Two-slice toaster with adjustable browning.',                         3200,     0, 25),
    ('air-fryer',                 'Air Fryer',                      'ELEC-AFR-01', 'Basket-style air fryer for cooking with little or no oil.',           9500, 11500, 15),
    ('rice-cooker',               'Rice Cooker',                    'ELEC-RCK-01', 'Electric rice cooker with keep-warm function.',                       4800,     0, 20),
    ('electric-iron',             'Steam Iron',                     'ELEC-IRN-01', 'Steam iron with a non-stick soleplate.',                              2500,     0, 30),
    ('standing-fan',              'Standing Fan',                   'ELEC-FAN-01', 'Pedestal fan with adjustable height and three speeds.',               4200,     0, 18),
    ('smartphone',                'Smartphone',                     'ELEC-PHN-01', 'Entry-level smartphone with a large display and dual SIM.',          15900,     0, 15),
    ('wireless-earbuds',          'Wireless Earbuds',               'ELEC-EAR-01', 'Bluetooth earbuds with a charging case.',                             2800,  3500, 35),
    ('bluetooth-speaker',         'Bluetooth Speaker',              'ELEC-SPK-01', 'Portable rechargeable Bluetooth speaker.',                            3500,     0, 30),
    ('soundbar',                  'TV Soundbar',                    'ELEC-SND-01', 'Soundbar with Bluetooth and HDMI for better TV sound.',              12500,     0, 10),
    ('laptop',                    'Laptop 15.6-inch',               'ELEC-LAP-01', '15.6-inch laptop for work, school and everyday use.',                49900,     0,  6)
)
insert into public.products
  (slug, name, category_id, description, sku, image_url, price_cents, compare_at_price_cents,
   unit_label, stock_quantity, in_stock, is_active)
select i.slug,
       i.name,
       c.id,
       i.description,
       i.sku,
       '/products/' || i.slug || '.jpg',
       i.price_kes * 100,
       nullif(i.compare_kes, 0) * 100,
       'each',
       i.stock,
       i.stock > 0,
       true
from items i
cross join (select id from public.categories where slug = 'electronics') c
where not exists (select 1 from public.products p where p.slug = i.slug);

-- Result: expect category 1 row, products 20 rows (or fewer if some already existed).
select (select count(*) from public.categories where slug = 'electronics') as electronics_category,
       (select count(*) from public.products p
          join public.categories c on c.id = p.category_id
         where c.slug = 'electronics')                                      as electronics_products;

commit;

-- Before running, these files must be deployed on the site:
--   public/categories/electronics.jpg
--   public/products/<slug>.jpg for each of the 20 slugs above (e.g. tv-32-inch-led.jpg).
-- To undo (only if nothing has been ordered yet):
--   delete from public.products where category_id = (select id from public.categories where slug = 'electronics');
--   delete from public.categories where slug = 'electronics';
