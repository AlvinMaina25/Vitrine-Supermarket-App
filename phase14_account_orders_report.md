# Phase 14 — Account & orders polish: report

Branch `phase-14-account-orders`, cut from `phase-13-cart-checkout` (head `9505cdd`). Storefront UI only. This session had no network for npm, so most tooling and every browser check did **not** run. Read the three verification lists before trusting anything here.

## 1. Commands and real results

| Command | Result |
|---|---|
| `npm ci` | **Failed.** The egress proxy answered 403 to `registry.npmjs.org` (policy denial, not a typo). `npm ci --offline` failed `ENOTCACHED`. I did not work around it. No `node_modules`. |
| `npm test` (same runner: `node --experimental-strip-types --test "tests/**/*.test.ts"`, needs no installed packages) | Baseline **899 pass, 0 fail** (matches Phase 13). After my work **933 pass, 0 fail** (899 + 34 new). |
| `npx tsc --noEmit` (app) | **Not run.** `react`, `@tanstack/*`, `vite/client` types are not installed. |
| `npx tsc -p tests/tsconfig.json` | **Not run.** Global tsc 6.0.3 stops with TS2688 (no `@types/node`). |
| `npx eslint .` | **Not run.** The config imports plugins that are not installed. |
| `prettier --check` (global 3.8.1; project pins `^3.7.3`) on Phase 12–13 files | 8 files flagged. 5 reformatted (formatting only, commit 1). 3 are payment-area files and were left alone on purpose (hard rule 4): `src/features/payments/components/mpesa-payment-panel.tsx`, `src/features/payments/mpesa-payment-state.ts`, `tests/mpesa-payment-state.test.ts`. |
| `prettier --check` on every file I changed or added | Clean. |
| tsc 6.0.3, strict flags copied from `tsconfig.json`, on the 4 new pure files | 0 errors in those files. (Errors in unrelated files from missing React types were ignored.) |
| TypeScript parse of the 7 edited/added `.tsx` files | 0 syntax errors. This is a syntax check only, not a type check. |
| `git diff --stat 9505cdd HEAD` on `db/`, `src/features/payments`, `src/features/auth`, `src/features/admin`, `src/features/notifications`, `src/routes/api.public.*`, `account.security.tsx`, `orders/queries.ts`, `orders/create-order-args.ts`, `cart/validation.ts` | **Empty.** None changed. No payment line in the order-detail route changed either. |

## 2. Findings from the short check

**(a) What exists today**
- Reads: `profileQuery`, `addressesQuery` (account); `ordersQuery` (50 newest), `orderItemCountsQuery`, `orderQuery` = order + items + status history (orders).
- Already existed: profile edit (name, phone; email read-only), address add / edit / delete / set default, a basic history list, payment panels on detail, a "not found" state for a bad or foreign order id (the query filters by `user_id` and returns null).
- Did not exist: order filters, reorder, tracking data, inline field errors, a custom delete confirmation (it used `window.confirm`), friendly error wording (account and order pages showed raw `error.message`).

**(b) Client-side computing of amounts, status or stock:** none found in the account or order UI. Totals, fee, discount, slot, both statuses come from the stored order. The only arithmetic is the list's unit count (sum of stored item quantities), which is a display count. Nothing needed fixing. The one real defect was raw backend error text in the customer area; switched to the existing `StorefrontErrorState`.

**(c) Can the customer read history and delivery details?** Yes. Migration `20260930010000_orders_delivery_admin.sql` grants `select` on `order_status_history` to `authenticated` with policy "Order history: read own". Delivery method, zone, slot and fee are snapshot columns on the order row. So the timeline is built from real rows. **Tracking:** nothing live exists (no rider, location or ETA is stored or read). "Delivery tracking" is therefore the order status, delivery method and slot already shown. I did not fake anything.

## 3. What changed, per page

- **Orders list** (`account.orders.index.tsx`): filter buttons All / In progress / Delivered / Cancelled or refunded (display filter over the 50 rows the existing read returns; state is local, not in the URL, so the route contract is unchanged); "no orders in this view" state; friendly error + offline state; 44 px buttons; long order numbers wrap.
- **Order detail** (`account.orders.$orderId.tsx`): heading shows the order number; the existing "What happens next" sentence (`orderNextStep`); **Buy again**; new timeline; 44 px back link. Items, address snapshot, delivery, totals and payment panels are untouched.
- **Timeline** (`order-timeline.tsx` + `timeline.ts`): one entry per recorded history row, stored timestamp, plain customer wording. Payment-change rows are labelled "Payment" and use payment wording. Cancelled and refunded are marked "Final status" with a distinct marker and are not steps. No future steps, no estimates.
- **Buy again** (`reorder-panel.tsx` + `reorder.ts`): builds basket lines from the order's snapshot items, asks the database through the existing `cartValidationQuery` (fresh, `staleTime: 0`), then adds only what it says is available, at the price it returns. Reports added / fewer than ordered (limited stock) / price changed (was → now) / not available. Items with no product link are skipped and listed. Nothing added → "Nothing was added to your basket." (never a success tone). Uses `cart.restore`, `setQuantity`, `repriceLine`; never places an order. Failure to check shows an error and adds nothing.
- **Profile and addresses** (`account.index.tsx`, `address-form.tsx`, `field.tsx`, `form-validation.ts`): inline error under each field (`aria-invalid`, `aria-describedby`), focus to the first error, `noValidate` so our messages show instead of browser bubbles, double-submit guard, inline "Yes, delete / Keep it" confirmation (replaces `window.confirm`), one address action at a time, 44 px controls. Same validation rules as before (phone shape, required parts, length limits). `Field` gained an optional `error` prop; existing callers are unaffected.

## 4. What the UI shows vs what the backend decides

| Thing | Who decides | UI does |
|---|---|---|
| Subtotal, delivery fee, discount, total | `create_order()` stored on the order | formats via `formatMoney` ("Free" when stored fee is 0) |
| Order status, payment status | database (two separate columns) | two separate badges / labels |
| Delivery method, zone, slot, address, items | order snapshot | renders snapshot; never re-reads live rows |
| Status history, timestamps | `order_status_history` (written by triggers) | wording and layout only |
| Item count on the list | stored `order_items` | sums stored quantities for display |
| Order visible to this customer | RLS + `user_id` filter | "not found" if not theirs or bad id |
| Reorder: available, stock, current price | `validate_cart()` | arranges the answer, adds to basket |
| Reorder: order placed | `create_order()` (not called here) | never |
| Payment becoming paid | server only | panels unchanged; browser never marks paid |

## 5. Verification lists

**Verified by running**
- `npm test`: 933 pass, 0 fail (34 new tests for timeline wording and mapping, reorder planning and summary, order filters, form validation).
- `prettier --check` on all files I changed or added.
- `git diff --stat` proof that forbidden areas are unchanged.

**Type-check or unit test only**
- The 4 new pure helper files: strict tsc 6.0.3, 0 errors in them (not the project's pinned TypeScript).
- `.tsx` files: parsed for syntax only. **Not type-checked.**

**Not checked**
- `npm ci`, app `tsc --noEmit`, `tsc -p tests/tsconfig.json`, eslint (react-hooks rules included), build, dev server.
- Any browser: no screenshots at 360 / 768 / 1280 px, no focus order, contrast, touch-target, offline or keyboard check. 44 px is set in classes only.
- Reorder against a real database; the real `validate_cart` answers; history RLS (read from the migration only, not tested live).
- Address deletion / default behaviour against the real database.

## 6. Open items

1. Run `npm ci`, `tsc`, `eslint`, `build` and `dev` somewhere with network and fix what they report in the `.tsx` files. Highest risk: types in `reorder-panel.tsx` (the `fetchQuery` spread) and the spread props in `address-form.tsx`.
2. Look at every page at 360 / 768 / 1280 px (`phase14_manual_qa_checklist.md`).
3. The timeline shows `order_status_history.note` as recorded (as before). I cannot tell whether staff type internal remarks there. If they do, customers see them. Needs your decision (hide notes, or add a customer-safe note field).
4. Reorder validates the order's quantity, not "basket + order" quantity. The basket page flags any over-stock afterwards. `validate_cart()` returns no current price for an under-stocked line, so that line is added at the old price until the basket re-validates and shows "price changed". Placing an order still re-prices everything in the database.
5. Orders list is the 50 newest; the filter only sees those rows. No server-side filter or paging.
6. Three payment-area Phase 12–13 files still fail `prettier --check` (listed above); left untouched by rule.
7. Profile and address save errors still show the backend's message text (unchanged wording from before).
8. Buy again is on order detail only, not on the confirmation page or the list (the list has no items).

## 7. Missing backend (not built)

- Live delivery tracking (rider, location, ETA) — nothing stored.
- A customer-safe note on status history.
- Server-side order filter / search / paging.
- `validate_cart()` returning the current price for under-stocked lines.

## 8. Files changed or added

Added: `src/features/orders/timeline.ts`, `src/features/orders/reorder.ts`, `src/features/orders/order-filters.ts`, `src/features/orders/components/reorder-panel.tsx`, `src/features/account/form-validation.ts`, `tests/order-timeline.test.ts`, `tests/order-reorder.test.ts`, `tests/order-filters.test.ts`, `tests/account-form-validation.test.ts`, `phase14_account_orders_report.md`, `phase14_manual_qa_checklist.md`.

Changed: `src/features/orders/components/order-timeline.tsx`, `src/routes/_authenticated/account.index.tsx`, `src/routes/_authenticated/account.orders.index.tsx`, `src/routes/_authenticated/account.orders.$orderId.tsx`, `src/features/account/address-form.tsx`, `src/components/ui-kit/field.tsx`, `HANDOFF.md`.

Formatting only (prettier): `src/components/ui-kit/quantity-stepper.tsx`, `src/features/cart/cart-provider.tsx`, `src/features/cart/line-state.ts`, `tests/cart-line-state.test.ts`, `tests/order-next-step.test.ts`.
