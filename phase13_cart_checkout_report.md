# Phase 13 — Cart & Checkout polish: report

Branch `phase-13-cart-checkout`, cut from `phase-12-product-discovery` (head `98baa41`). Storefront UI only. The sandbox had no network, so `npm ci` failed; only what could run was run. Nothing here was seen in a browser.

## Verification lists

**Verified by running**
- `npm test`: 899 pass, 0 fail (baseline 859 + 40 new). Same command before my changes: 859 pass.
- `git diff --stat 98baa41 HEAD`: 14 files, none in `db/`, server functions, payment server code, auth, admin or notifications (see "Forbidden-path check").

**Type-check or unit test only**
- Global `tsc --noEmit` (6.0.3, partial `node_modules`): exactly 1 error before and after, `TS2688 Cannot find type definition file for 'vite/client'` (missing package, not code). No other error.
- All new behaviour: pure helpers are unit-tested (`tests/cart-line-state.test.ts`, `tests/mpesa-payment-state.test.ts`, `tests/order-next-step.test.ts`). The `.tsx` changes (cart, checkout summary, M-Pesa panel, confirmation) are type-checked only.

**Not checked**
- `npm ci` (failed: "Exit handler never called", no network), so `eslint`, `prettier`, `vite build`, dev server: not run.
- `tsc -p tests/tsconfig.json`: blocked by missing `@types/node` (1 environmental error); the 2 known errors in `tests/admin-products.test.ts` could not be confirmed or ruled out.
- Any browser, any screenshot at 360/768/1280 px, focus order, contrast, touch targets as rendered.
- Real Supabase, real Daraja, whether M-Pesa is configured on the server, the whole start-to-paid M-Pesa flow, a failed and a timed-out payment.
- Wording against the official Daraja documentation (no network). I used only "M-PESA prompt", "M-PESA PIN" and status-based sentences; no result codes or reasons.
- Address add/edit, delivery methods and slots, and coupon entry in `checkout.tsx` were read, not changed and not re-tested.

## Findings from the short check

**(a) Is "start M-Pesa" wired?** Server side yes, UI side no. `startPaymentFn` accepts `method: "mpesa"` plus a phone, and `card-server.ts` documents that M-Pesa is in the usable gateway list "when configured" (read, not run). The checkout only ever started card payments, and `payment-providers.ts` says M-Pesa is `connected: false`. The browser cannot tell whether M-Pesa is configured. So I built the phone, waiting and outcome UI on the order pages (confirmation and order detail), which calls the existing `startPaymentFn`. If the server has no M-Pesa gateway it answers "That payment method is not available yet." and the panel shows that.

**(b) Places that computed an amount, stock decision or payment status in the UI**
1. `cart.tsx` line total `priceCents × quantity`: removed; the line shows the unit price.
2. `cart.tsx` subtotal summed from the basket's saved prices: now the database subtotal (`validate_coupon`) for signed-in customers; otherwise labelled "Estimated subtotal" with a note. Guests have no database subtotal (backend gap, below).
3. `checkout.tsx` summary: per-line `price × quantity` replaced by "KSh X each"; subtotal and delivery fee now come from the same `validate_coupon` answer as the total (the fee was from the delivery quote).
4. **Not fixed, reported:** `buildQuoteRequest({ subtotalCents })` sends the basket's locally summed subtotal to `validate_delivery_selection`. It drives the method text ("free over…", minimum-order message) and quote gating. Charges are not affected (`validate_coupon` and `create_order` re-price from items). Removing it needs a quote function that takes items. Rule 6, so I stopped there.
5. `eligibleBaseCents` in `promotions/logic.ts` mirrors a SQL function; no UI code imports it.
- No stock decision is made in the UI: stock text maps the `validate_cart` reason. No payment status is computed in the UI: the panel and next-step text map server status only.

**(c) Cart stepper at 360 px.** By arithmetic only: stepper about 138 px, "Remove" about 100 px, content width about 212 px, so Remove wraps to its own row (the row is `flex-wrap`). No overflow expected. Not seen in a browser.

## What changed per page

- **Cart (`/cart`)**: per-line badge from the database answer ("In stock", "Only N left", "Unavailable", "Price changed: now KSh X each"); nothing is called "in stock" until the answer arrives. Stepper max follows the database stock; typing a number that does not fit shows why ("Only 3 available, so we set the quantity to 3."). Remove has an Undo action in the toast (new `restore` in the cart provider). If the check fails: message with "Check again". Subtotal as above.
- **Checkout (`/checkout`)**: summary as in (b)3. M-Pesa note reworded (it said "isn't connected yet"). Everything else unchanged.
- **M-Pesa panel (confirmation and order detail)**: states start / waiting / timed out / retry (failed, cancelled, expired) / paid / closed, all derived from `get_my_order_payments` and the order's own status. Phone box (44 px, `type=tel`, inline message, focus returns to it on an error, disabled while sending and offline). Waiting shows a visible countdown from the 90 s limit and polls every 3 s. After the limit: "Still waiting for confirmation" with "Check again", no second prompt, no claim of failure.
- **Confirmation page**: "What happens next" sentence from the stored order status, plus a "Your orders" link. Items, totals, delivery and slot were already stored order values and are unchanged.

## UI shows vs backend decides

| UI shows | Backend decides |
|---|---|
| Subtotal, discount, delivery fee, total at checkout | `validate_coupon()` (and `create_order()` re-checks against `p_expected_total_cents`) |
| Cart subtotal (signed in) | `validate_coupon()`; guests see a labelled estimate |
| Line badge, "Only N left", max quantity | `validate_cart()` rows |
| "Price changed: now X" | `validate_cart()` unit price |
| Stored totals, items, slot on confirmation | the order row |
| "Payment received" | server only: a succeeded M-Pesa attempt or order `payment_status = paid` |
| Waiting / retry / expired | latest M-Pesa attempt status from `get_my_order_payments` |
| Phone format message | UI hint only; `startPayment` checks again and decides |

## Commands run
`npm ci` (failed, no network); `npm test` before (859 pass) and after (899 pass); `tsc --noEmit` before and after (same single environmental error); `tsc -p tests/tsconfig.json` (environmental error only); `git diff --stat`.

## Forbidden-path check
`git diff --name-only 98baa41 HEAD` against `db/`, `scripts/`, `mpesa-server`, `payment-server`, `start-payment`, `card-server`, settlements, admin, notifications, `routeTree`, `api.public`: nothing. A loose "auth" pattern also matched `src/routes/_authenticated/…` (customer order pages, route folder name only; not auth code). `payment-providers.ts` was touched for one copy string; `connected` flags are unchanged. No dependency, table, column, RPC, trigger or secret added.

## Open items and missing backend (not built)
- No public flag says whether M-Pesa is configured, so the checkout badge still says "Not connected yet" and an order can be placed before the server says M-Pesa is unavailable. A public non-secret flag (new env) needs your approval.
- No function changes the payment method of an existing order, so after a failure the panel offers only "Try again". "Change method" is possible only before placing the order.
- The phone is asked on the order page, after the order exists, so it is never sent before an order does.
- The wait limit counts from when the page opened; reopening a page on a still-processing attempt starts a fresh 90 s window.
- Backend gaps: per-line totals and a guest subtotal from `validate_cart`; a delivery quote that takes items instead of a client subtotal.
- Quality pass (task 7) is only partly done: focus-after-error, labels and 44 px targets are built into the new panel and cart line; checkout address/slot/coupon, contrast and the three widths were not checked. Run `npm run format` first; I could not run prettier and some new lines may exceed its width.

## Files
Added: `src/features/cart/line-state.ts`, `src/features/payments/mpesa-payment-state.ts`, `src/features/payments/components/mpesa-payment-panel.tsx`, `src/features/orders/next-step.ts`, `tests/cart-line-state.test.ts`, `tests/mpesa-payment-state.test.ts`, `tests/order-next-step.test.ts`, `phase13_cart_checkout_report.md`, `phase13_manual_qa_checklist.md`.
Changed: `src/routes/cart.tsx`, `src/routes/checkout.tsx`, `src/routes/_authenticated/order-confirmation.$orderId.tsx`, `src/routes/_authenticated/account.orders.$orderId.tsx`, `src/features/cart/cart-provider.tsx`, `src/components/ui-kit/quantity-stepper.tsx`, `src/features/checkout/payment-providers.ts`, `HANDOFF.md`.
