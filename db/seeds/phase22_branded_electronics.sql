-- Phase 22: branded electronics seed (5 categories, 29 products, variants). A DATA SEED, not a migration.
-- Run by hand in the Supabase SQL editor, ONCE. Safe to run twice: rows whose slug (or variant) already
-- exists are skipped and nothing is overwritten.
--
-- WHAT YOU STILL DO (in /admin, per product):
--   1. Upload a photo (Edit product -> picture).
--   2. Set the REAL stock (Inventory -> adjust; variants have their own stock).
--   3. Check the price, then switch the product to Active.
--
-- SAFE DEFAULTS: every product is created INACTIVE with stock 0 and no image, so nothing appears
-- in the shop (and nothing can be bought) until you have done the three steps above.
-- Prices are ESTIMATES in whole Kenya shillings, stored as cents (x 100). Replace them with your
-- supplier prices. Products with variants: the storefront uses each variant's own price and stock.
-- Money is integer cents; this script does not touch orders, payments or inventory history.

begin;

insert into public.categories (slug, name, tagline, description, image_url, position, is_active)
select v.slug, v.name, v.tagline, v.description, null,
       coalesce((select max(position) from public.categories where parent_id is null), 0) + v.ord,
       true
from (values
  ('phones-accessories', 'Phones & Accessories', 'Phones, earbuds, chargers and power banks', 'Smartphones and the everyday accessories that go with them.', 1),
  ('tv-audio', 'TV & Audio', 'Televisions, speakers and headphones', 'Smart TVs, Bluetooth speakers and headphones.', 2),
  ('kitchen-appliances', 'Kitchen Appliances', 'Kettles, air fryers, microwaves and more', 'Small kitchen appliances for everyday cooking.', 3),
  ('computing', 'Computing', 'Laptops, routers and accessories', 'Laptops, networking gear, storage and computer accessories.', 4),
  ('home-lighting', 'Home & Lighting', 'Bulbs, sockets and solar lights', 'Lighting and power essentials for the home.', 5)
) as v(slug, name, tagline, description, ord)
where not exists (select 1 from public.categories c where c.slug = v.slug);

with items (slug, name, brand, category_slug, sku, description, price_kes) as (
  values
    ('samsung-galaxy-a15', 'Samsung Galaxy A15', 'Samsung', 'phones-accessories', 'BRD-SAM-A15', 'Samsung Galaxy A15 smartphone with a large Super AMOLED display and dual SIM. Choose your storage size.', 19000),
    ('tecno-spark-20', 'Tecno Spark 20', 'Tecno', 'phones-accessories', 'BRD-TEC-SP20', 'Tecno Spark 20 smartphone with a big display and long battery life. Choose your storage size.', 16500),
    ('infinix-hot-40i', 'Infinix Hot 40i', 'Infinix', 'phones-accessories', 'BRD-INF-H40I', 'Infinix Hot 40i smartphone, a budget-friendly phone for everyday use.', 12500),
    ('xiaomi-redmi-13c', 'Xiaomi Redmi 13C', 'Xiaomi', 'phones-accessories', 'BRD-XIA-R13C', 'Xiaomi Redmi 13C smartphone with a large display and good battery. Choose your storage size.', 14500),
    ('oraimo-freepods-4', 'Oraimo FreePods 4 Wireless Earbuds', 'Oraimo', 'phones-accessories', 'BRD-ORA-FP4', 'Oraimo FreePods 4 true wireless earbuds with charging case.', 3500),
    ('anker-powercore-10000', 'Anker PowerCore 10000 Power Bank', 'Anker', 'phones-accessories', 'BRD-ANK-PC10K', 'Slim 10,000mAh portable charger from Anker.', 3500),
    ('samsung-25w-usb-c-charger', 'Samsung 25W USB-C Fast Charger', 'Samsung', 'phones-accessories', 'BRD-SAM-CH25', 'Samsung 25W super fast wall charger with a USB-C port.', 2200),
    ('oraimo-power-bank-20000', 'Oraimo 20,000mAh Power Bank', 'Oraimo', 'phones-accessories', 'BRD-ORA-PB20K', 'High-capacity 20,000mAh power bank from Oraimo for several full phone charges.', 3200),
    ('anker-usb-c-cable', 'Anker USB-C to USB-C Cable', 'Anker', 'phones-accessories', 'BRD-ANK-CBL', 'Durable USB-C to USB-C charging and data cable. Choose your length.', 1200),
    ('hisense-4k-smart-tv', 'Hisense 4K UHD Smart TV (A6 series)', 'Hisense', 'tv-audio', 'BRD-HIS-A6', 'Hisense 4K UHD smart television with built-in apps and Wi-Fi. Choose your screen size.', 32000),
    ('tcl-32-inch-hd-smart-tv', 'TCL 32-inch HD Smart TV', 'TCL', 'tv-audio', 'BRD-TCL-32', 'TCL 32-inch HD smart television with HDMI and USB ports.', 14500),
    ('jbl-flip-6', 'JBL Flip 6 Bluetooth Speaker', 'JBL', 'tv-audio', 'BRD-JBL-FLIP6', 'Portable waterproof Bluetooth speaker from JBL with powerful sound.', 13500),
    ('jbl-tune-510bt', 'JBL Tune 510BT Wireless Headphones', 'JBL', 'tv-audio', 'BRD-JBL-T510', 'On-ear Bluetooth headphones from JBL with long battery life.', 5500),
    ('soundcore-life-q30', 'Anker Soundcore Life Q30 Headphones', 'Anker', 'tv-audio', 'BRD-ANK-Q30', 'Over-ear wireless headphones with active noise cancelling.', 9500),
    ('ramtons-electric-kettle-17l', 'Ramtons 1.7L Electric Kettle', 'Ramtons', 'kitchen-appliances', 'BRD-RAM-KET17', 'Ramtons 1.7-litre electric kettle with auto shut-off.', 2200),
    ('philips-essential-airfryer-hd9252', 'Philips Essential Airfryer HD9252', 'Philips', 'kitchen-appliances', 'BRD-PHI-AF9252', 'Philips Essential Airfryer for cooking with little or no oil.', 13500),
    ('ramtons-microwave-oven', 'Ramtons Microwave Oven', 'Ramtons', 'kitchen-appliances', 'BRD-RAM-MW', 'Countertop microwave oven. Choose your capacity.', 8500),
    ('von-hotpoint-blender', 'Von Hotpoint Blender', 'Von Hotpoint', 'kitchen-appliances', 'BRD-VON-BLD', 'Countertop blender for smoothies, soups and sauces.', 4800),
    ('philips-5000-series-steam-iron', 'Philips 5000 Series Steam Iron', 'Philips', 'kitchen-appliances', 'BRD-PHI-IRN5K', 'Philips steam iron with a non-stick soleplate.', 6500),
    ('hp-15s-laptop', 'HP 15s Laptop', 'HP', 'computing', 'BRD-HP-15S', 'HP 15s laptop for work, school and everyday use. Choose your memory and storage.', 52000),
    ('lenovo-ideapad-1', 'Lenovo IdeaPad 1 Laptop', 'Lenovo', 'computing', 'BRD-LEN-IP1', 'Lenovo IdeaPad 1 15.6-inch laptop for everyday computing.', 48000),
    ('logitech-m170-wireless-mouse', 'Logitech M170 Wireless Mouse', 'Logitech', 'computing', 'BRD-LOG-M170', 'Reliable, compact wireless mouse with a USB receiver.', 1300),
    ('logitech-k380-bluetooth-keyboard', 'Logitech K380 Bluetooth Keyboard', 'Logitech', 'computing', 'BRD-LOG-K380', 'Slim multi-device Bluetooth keyboard for computers, phones and tablets.', 5200),
    ('sandisk-ultra-usb-3-flash-drive', 'SanDisk Ultra USB 3.0 Flash Drive', 'SanDisk', 'computing', 'BRD-SAN-ULT', 'Fast USB 3.0 flash drive. Choose your capacity.', 1300),
    ('tp-link-archer-c6-router', 'TP-Link Archer C6 Wi-Fi Router', 'TP-Link', 'computing', 'BRD-TPL-C6', 'Dual-band Gigabit Wi-Fi router from TP-Link.', 5500),
    ('tp-link-tl-wr840n-router', 'TP-Link TL-WR840N Wi-Fi Router', 'TP-Link', 'computing', 'BRD-TPL-840N', 'Affordable 300Mbps Wi-Fi router, easy to set up.', 2200),
    ('philips-led-bulb-9w-e27', 'Philips LED Bulb 9W E27', 'Philips', 'home-lighting', 'BRD-PHI-LED9', 'Energy-saving 9W LED bulb with an E27 screw fitting. Choose your light colour.', 450),
    ('surge-protected-extension-socket-4-way', '4-Way Surge-Protected Extension Socket', null::text, 'home-lighting', 'BRD-GEN-EXT4', 'Four-way extension socket with surge protection and an on/off switch.', 1800),
    ('usb-rechargeable-solar-lantern', 'USB Rechargeable Solar Lantern', null::text, 'home-lighting', 'BRD-GEN-SOL', 'Solar-powered LED lantern that also charges from USB, for power cuts and outdoor use.', 1500)
)
insert into public.products
  (slug, name, category_id, description, brand, sku, image_url, price_cents, compare_at_price_cents,
   unit_label, stock_quantity, in_stock, is_active)
select i.slug, i.name, c.id, i.description, i.brand, i.sku, null,
       i.price_kes * 100, null, 'each', 0, false, false
from items i
join public.categories c on c.slug = i.category_slug
where not exists (select 1 from public.products p where p.slug = i.slug);

with variant_rows (product_slug, name, sku, price_kes, attributes, position) as (
  values
    ('samsung-galaxy-a15', '128GB', 'BRD-SAM-A15-128', 19000, '{"storage": "128GB"}', 0),
    ('samsung-galaxy-a15', '256GB', 'BRD-SAM-A15-256', 23500, '{"storage": "256GB"}', 1),
    ('tecno-spark-20', '128GB', 'BRD-TEC-SP20-128', 16500, '{"storage": "128GB"}', 0),
    ('tecno-spark-20', '256GB', 'BRD-TEC-SP20-256', 19500, '{"storage": "256GB"}', 1),
    ('xiaomi-redmi-13c', '128GB', 'BRD-XIA-R13C-128', 14500, '{"storage": "128GB"}', 0),
    ('xiaomi-redmi-13c', '256GB', 'BRD-XIA-R13C-256', 17500, '{"storage": "256GB"}', 1),
    ('anker-usb-c-cable', '1m', 'BRD-ANK-CBL-1M', 1200, '{"length": "1m"}', 0),
    ('anker-usb-c-cable', '2m', 'BRD-ANK-CBL-2M', 1800, '{"length": "2m"}', 1),
    ('hisense-4k-smart-tv', '43"', 'BRD-HIS-A6-43', 32000, '{"screen": "43 inch"}', 0),
    ('hisense-4k-smart-tv', '50"', 'BRD-HIS-A6-50', 45000, '{"screen": "50 inch"}', 1),
    ('hisense-4k-smart-tv', '55"', 'BRD-HIS-A6-55', 54000, '{"screen": "55 inch"}', 2),
    ('ramtons-microwave-oven', '20L', 'BRD-RAM-MW-20L', 8500, '{"capacity": "20L"}', 0),
    ('ramtons-microwave-oven', '25L', 'BRD-RAM-MW-25L', 11500, '{"capacity": "25L"}', 1),
    ('hp-15s-laptop', '8GB RAM / 256GB SSD', 'BRD-HP-15S-8-256', 52000, '{"ram": "8GB", "storage": "256GB SSD"}', 0),
    ('hp-15s-laptop', '16GB RAM / 512GB SSD', 'BRD-HP-15S-16-512', 68000, '{"ram": "16GB", "storage": "512GB SSD"}', 1),
    ('sandisk-ultra-usb-3-flash-drive', '64GB', 'BRD-SAN-ULT-64', 1300, '{"capacity": "64GB"}', 0),
    ('sandisk-ultra-usb-3-flash-drive', '128GB', 'BRD-SAN-ULT-128', 2000, '{"capacity": "128GB"}', 1),
    ('sandisk-ultra-usb-3-flash-drive', '256GB', 'BRD-SAN-ULT-256', 3800, '{"capacity": "256GB"}', 2),
    ('philips-led-bulb-9w-e27', 'Warm white', 'BRD-PHI-LED9-WW', 450, '{"colour": "warm white"}', 0),
    ('philips-led-bulb-9w-e27', 'Cool daylight', 'BRD-PHI-LED9-CD', 450, '{"colour": "cool daylight"}', 1)
)
insert into public.product_variants
  (product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity, attributes, position, is_active)
select p.id, v.name, v.sku, v.price_kes * 100, null, 0, v.attributes::jsonb, v.position, false
from variant_rows v
join public.products p on p.slug = v.product_slug
where not exists (select 1 from public.product_variants x where x.product_id = p.id and x.name = v.name);

-- Check: expect 5 categories, 29 products and 20 variants (fewer only if some already existed).
select (select count(*) from public.categories where slug in ('phones-accessories','tv-audio','kitchen-appliances','computing','home-lighting')) as categories,
       (select count(*) from public.products where sku like 'BRD-%') as products,
       (select count(*) from public.product_variants where sku like 'BRD-%') as variants;

commit;

-- To undo (only if nothing has been ordered yet):
--   delete from public.products where sku like 'BRD-%';        -- variants go with them
--   delete from public.categories where slug in ('phones-accessories','tv-audio','kitchen-appliances','computing','home-lighting');
