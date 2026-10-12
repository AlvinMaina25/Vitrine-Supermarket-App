1. Admin with 2FA, product page: "Add variant" opens a dialog; add 3 variants (e.g. 500 ml, 1 L, 2 L) with "Save and add another" (form clears, focus returns to Name).
2. Positions follow the order added; the card list shows all 3 with price, SKU, stock, status.
3. Reuse a SKU: plain "already uses that SKU" message on the SKU field, focus moves there, nothing created.
4. Bad input (empty price, compare-at below price, stock -1 / 1.5, name over 200): message under the field, nothing created.
5. Starting stock 12 on one variant: Inventory shows 12 on that variant only; history says "Opening stock".
6. Add a variant with Active off: listed as inactive in admin, absent on the storefront product page and card price range.
7. Storefront (signed out): product shows a selector; picking a size changes price and stock; "From X" on the card.
8. As a customer pick a size, add to cart, place an order; the order line names the size and that variant's stock drops.
9. Double-click Add variant: one variant only. Non-admin / admin without 2FA: refused with plain text, no raw error.
10. Keyboard only (Tab, Space on the switch, Enter submits "Add variant") and 360 px: no sideways scroll.
