# Phase 12 — manual QA checklist (real browser, real Supabase)

Nothing here has been seen in a browser by the developer. Test on a phone (360–390 px) and a desktop (1280 px). Note page, width and what you did for anything odd.

## Variants and stock (check first)
- [ ] A product with variants: the card says "Choose options" (not "Add") and shows "From KES …" if prices differ.
- [ ] That product with the product's own stock at 0 but a variant available: NOT shown as Sold out.
- [ ] All variants at 0 stock: the card and page say Sold out and cannot be added.
- [ ] Product page: pick each variant; price, SKU and stock text change; `?variant=` is in the address; reload keeps the choice.
- [ ] A sold-out variant: button disabled, "Try another option".
- [ ] "Only N left" appears only where an admin set a low-stock threshold; never otherwise.
- [ ] Slow or offline: cards show "View product" (no Add) until options load; the product page shows an error with Retry, not a buy button.

## Search, filters, sort (mobile)
- [ ] `/?q=milk`, then a typo (`mlk`): still finds milk, says results were corrected.
- [ ] Search box suggestions: keyboard up/down/Enter works; Escape clears the box and closes the list.
- [ ] Filters button opens a sheet; In stock only, On offer, brands, price range apply; the chips show and each removes its filter; Clear all works.
- [ ] Brand counts match the results after "In stock only".
- [ ] Sort changes order; Best match only appears with a search term.
- [ ] Filter state is in the address bar; Back/Forward and reload keep it.

## Categories
- [ ] A parent category lists products from its sub-categories; breadcrumb and child chips work.
- [ ] Category rail shows top-level plus the open branch.

## Product page and cart
- [ ] Quantity box accepts typing, clamps to stock and 99; "Maximum in basket" when full.
- [ ] Sticky buy bar appears on mobile once the main Add button scrolls off, and hides again.
- [ ] Recently viewed shelf appears after visiting two or more products; nothing sensitive stored.
- [ ] Basket: the quantity box can be typed in; subtotal and checkout totals are unchanged.

## Look and feel (both sizes)
- [ ] No sideways scrolling; no overlapping or clipped text.
- [ ] Every button and link is at least 44 px; focus ring visible with the keyboard; text readable.
