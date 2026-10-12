# Phase 11 — manual QA checklist (owner, in a real browser)

Use your real Supabase project. Test on a real phone if you can (Chrome Android), plus a desktop browser.
Tick each box; note anything odd with the page, the screen width and what you did.

## Mobile (360–390 px wide; or Chrome DevTools device mode)

- [ ] Home: header shows menu, store name, search, basket. No sideways scrolling anywhere.
- [ ] Menu button opens a drawer with all categories, Basket and Sign in/Account. Tapping a link closes it.
- [ ] Category chips scroll sideways with a swipe; the current category is highlighted.
- [ ] Hero has one button ("Start shopping") that jumps to "All products".
- [ ] Category tiles, "On offer" (only if some products have a compare-at price) and "Recently added" swipe sideways.
- [ ] Search: type a word, pause. The address updates to `?q=...` and results show. Press the keyboard's Search key. Tap the X to clear.
- [ ] Search for nonsense: "Nothing matches" appears with Clear search and category suggestions.
- [ ] Product card: image doesn't jump as it loads; sold-out and "Only N left" badges look right; tap Add, it turns into a − / + stepper and the header count rises.
- [ ] A product with no image (or a broken image URL) shows a calm placeholder, not a broken icon.
- [ ] Product page: breadcrumb, price (and struck-through compare-at price when set), stock text, quantity stepper stops at stock, "Add to basket", "View basket" link.
- [ ] A sold-out product: the button is disabled and says Sold out.
- [ ] Open `/product/does-not-exist` and `/category/does-not-exist`: a clear "couldn't find" page with a way back.
- [ ] Basket: items readable, stepper and Remove work, subtotal matches. Empty basket offers "Browse the shelves".
- [ ] Turn on airplane mode while on a page: a calm "You're offline" banner appears; reloading a list shows "You seem to be offline" with Try again; turning the network back on and tapping Try again loads the data.
- [ ] Every button/link is easy to tap with a thumb (nothing tiny or crowded).

## Desktop (1280 px)

- [ ] Header: search bar in the middle, Sign in/Account and basket on the right, sticky when scrolling.
- [ ] Product grid shows 4–5 columns. Sort (name, price, newest) and "In stock only" work and appear in the address bar.
- [ ] "Show more" on a large category loads the next 20.
- [ ] Product page is two columns (image left, details right). "More from <category>" shelf appears if the category has other products.
- [ ] Basket is two columns with a sticky Order summary. If signed in and an automatic promotion applies, a discount line shows.
- [ ] Keyboard only: first Tab reveals "Skip to main content"; Tab/Shift+Tab reach every control with a visible outline; Esc clears the search box and closes the drawer.

## Things to confirm against your own data (could not be checked here)

- [ ] Real product photos look right in the square crop.
- [ ] Low-stock badges appear only for products that have a low-stock threshold set.
- [ ] Slow connection (DevTools → Network → Slow 3G): skeletons show, then a "taking longer than usual" note after ~6 s.
- [ ] Checkout still looks and behaves as before (not changed). M-Pesa still shows "Not connected yet" (known, out of scope).
