# Phase 18 final UI audit report

**`npm ci` failed (registry unreachable, ENOTFOUND). Everything below is code-reviewed only.** Run: greps and file reading; a syntax-only parse of the 6 changed .ts/.tsx files (all parse). NOT run: tsc, eslint, prettier, npm test, vite build, any browser, any contrast tool. Nothing here is "tested", "verified" or "accessible".

## Findings and fixes (S1 = blocks purchase/admin work, S2 = wrong or confusing state, S3 = polish)

| Step / screen | Finding | Sev | Fix | Checked |
|---|---|---|---|---|
| Checkout, coupon | No pending feedback while the coupon preview loads (promo-apply carry-over) | S2 | `role="status"` "Checking your coupon…" in `coupon-input.tsx` | unverified |
| Checkout, coupon | Apply/Remove swaps the focused control, so keyboard focus drops to the page top | S2 | Focus moves to Remove after apply, to the input after remove | unverified |
| Checkout, coupon | Rejection text used `text-destructive`; that token is not defined in `styles.css`, so the text is not red | S2 | `text-danger` (the token used 47 times elsewhere) | unverified |
| Account, addresses | Delete/set-default failures showed raw database error text in a toast | S2 | Plain wording plus offline wording (same pattern as profile save); raw error to console | unverified |
| Confirmation / list / detail | Same status worded "Awaiting payment" (badge) and "Waiting for payment" (timeline) | S2 | Badge label now "Waiting for payment" (`status.ts`; admin shows the same wording) | unverified |
| Phone, all pages | Toast lifted 5.5rem on every page, but only the product page has a fixed buy bar | S3 | Lift applied only on `/product/*` (`__root.tsx`, `sonner.tsx`) | unverified |
| Account security | Factor date used browser locale `toLocaleDateString()` | S3 | `formatDateTime` | unverified |
| All pages | Heading focus ring after route change (carry-over) | S3 | No ring on script-focused `h1/h2/main[tabindex=-1]`; Tab-reachable controls keep it | unverified |

Read and found fine by code only: one `<h1>` per page (home, search, category, product, cart, checkout, auth, account, confirmation, all admin pages via `AdminPageHeader`); double-submit guard and idempotency key on Place order; confirm-button variants (danger when deactivating, primary when activating) consistent across admin dialogs; every admin list route renders `AdminQueryError`; image `alt`/size attributes present; no `TODO`, `href="#"` or `onClick` on non-buttons.

## Not fixed (and why)
- `viewport-fit=cover` (S3): needs side/header padding and an iPhone to check; unsafe to change blind.
- `overflow-x: clip` on html/body (S3): may hide real overflow; finding it needs a browser at 360 px.
- Other badge vs timeline wording (S3): "Processing" vs "Being prepared", "Paid" vs "Payment received", "Payment failed" vs "Payment didn't go through". Labels are shared with admin and tests assert timeline text; needs a wording decision.
- Admin dashboard has its own short payment labels ("Pending") unlike `PAYMENT_STATUS_LABELS` (S3).
- Raw hex in `lib/error-page.ts` (standalone fallback HTML) left as is.

## Needs follow-up
- Run the Release checklist in HANDOFF.md; then a browser pass at 360/768/1280 px, reduced motion, keyboard only.
- Contrast never measured (badges, disabled states, muted text).
- Not opened: card and M-Pesa payment panels, card-return route, checkout internals beyond greps, admin delivery forms, audit-log filters, order-detail actions, customer notes, variants card, skeleton heights, offline variants of admin lists, 45 `[Npx]` one-offs.
- Two Button systems (`ui/button` shadcn, `ui-kit/button`); shadcn `destructive` token is undefined and `ui/form`, `ui/alert`, `ui/badge` use it but are not imported anywhere. Define the token or delete the dead files.

## Verdicts
- **Customer: ready with caveats.** No S1 found by reading, but nothing was run and the payment screens were not reviewed in depth.
- **Admin: ready with caveats.** Error/heading/dialog patterns read consistent, but most screens were not opened and nothing was run.

Commits: `570d89d` (A), `debe387` (A/C/D combined; areas B had no changes).
