1. Admin with 2FA: Categories appears in the nav next to Products; create a category (name, slug, tagline, description, position, active) and edit it.
2. Non-admin and admin without 2FA: no Categories data, no upload, no create; plain refusal, no raw error text.
3. Deactivate a category: gone from the storefront for a signed-out visitor; still editable in admin; nothing deleted.
4. Duplicate slug and bad slug show a plain message on the slug field; focus moves to the first error.
5. Product page: upload a .jpg, .png, .webp; a .gif and a file over 2 MB are refused with a plain message and the old picture stays.
6. Replace a picture, then remove it (confirm dialog); the storefront shows the new one, then the old placeholder; old /products/*.jpg still work.
7. Category form: new category says "Save the category first"; after saving, a picture can be added.
8. New product with defaults (stock 0, Active on): created, product page opens, live in the storefront.
9. New product with stock 25 and Active off: product page shows stock 25 and inactive; Inventory history has "Opening stock"; not visible in the storefront.
10. Stock "-1", "1.5" or "abc": red message under Starting stock, focus moves there, nothing created.
11. Double-click Create: one product only. Go offline mid-way: plain message, no raw error text.
12. Keyboard only (Tab, Space on the switch, Enter) and 360 px: no sideways scroll, controls 44 px.
