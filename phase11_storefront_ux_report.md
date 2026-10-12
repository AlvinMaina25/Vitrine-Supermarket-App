# Phase 11 — Storefront, frontend & UX report

Branch: `phase-11-storefront-ux` (on top of a baseline commit of the uploaded `phase9c-full` zip, which was not a git repo).
Nothing in `db/`, server functions, payments, checkout, auth/MFA, admin screens, notifications or `routeTree.gen.ts` was changed (verified with `git diff`; no new route was added, so the generator output is unchanged).

## 1. Audit (before any edit)

Method: read AGENTS.md / HANDOFF.md / README.md and every storefront file; computed WCAG contrast from the real tokens; then ran the app in Chromium at 360, 390, 768 and 1280 px (see §6 for what that does and doesn't prove).

| Area          | Good                                                       | Broken or rough                                                                                                                                                                                                                             |
| ------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Whole site    | Semantic design tokens; TanStack Query; ui-kit components. | Muted text ≈3.6:1 and search placeholder ≈2.4:1 (fail AA). Danger text 4.4:1. No `<main>`, no skip link. Footer shown to customers read "catalogue served from your Supabase project". Controls ~28–36 px tall. No reduced-motion handling. |
| Header        | Sticky; basket count.                                      | Search input **hidden below 768 px** (no mobile search at all); no mobile menu; search not debounced, no Esc, not 44 px.                                                                                                                    |
| Category rail | Real links.                                                | Active chip was a `<span>` (no aria-current), 24 px tall, no "All".                                                                                                                                                                         |
| Home          | Hero image.                                                | Hard-coded slugs `produce/bakery/drinks` (404 if they don't exist); marketing claims ("picked this morning", "Baked 6am", "delivery before dinner") that nothing in the data supports; no real offers/new sections; no trust cues.          |
| Search        | `?q=` existed (name-only substring filter on home).        | No ranking, no brand match, no suggestions on empty, numeric queries (`?q=500`) would be dropped by the router.                                                                                                                             |
| Category      | Works.                                                     | Slug-derived title, unknown slug looked like an empty shelf (no 404), no sort/filter/count control, all products rendered at once.                                                                                                          |
| Cards         | Lazy images.                                               | Fixed-less image box (layout shift), no stock/low-stock/sale badges, compare-at price never shown, `low_stock_threshold` never fetched, add button with no feedback.                                                                        |
| Product page  | Works.                                                     | Image overlaid by gradient text, no breadcrumb, no stock-aware quantity, "not found" shown as empty state, raw DB error text on failure.                                                                                                    |
| Cart          | Works.                                                     | Showed "empty" flash before localStorage hydrated, no validation warnings, tiny controls, no summary panel.                                                                                                                                 |
| States        | Good building blocks.                                      | `QueryErrorState` prints raw `error.message` (kept for admin; storefront now uses a new friendly state). No offline state, no 404 state.                                                                                                    |
| Retries       | —                                                          | React Query's 3 retries stacked on Supabase's own network retries: ~25 s+ of skeleton on a dead connection.                                                                                                                                 |

## 2. What changed, per page

- **Header / navigation**: sticky, skip link, `<main>` landmark, mobile drawer (Radix Sheet) with categories/basket/account, search on every screen size (second row on phones), basket icon with count badge, category rail with "All", `aria-current`, 44 px chips, scroll-snap with correct padding, real footer.
- **Search**: URL-backed `?q=`, 350 ms debounce (history replaced while typing), Enter searches now, Esc clears, clear button, word-order-independent name+brand match with prefix ranking, no-results state with Clear search + category suggestions. Away from home, auto-navigation needs ≥2 characters.
- **Home**: single-action hero ("Start shopping" → #all-products) with generic true copy; static trust strip; "Shop by category" tiles from `categoriesQuery`; "On offer" shelf (products with a real higher compare-at price, hidden if none); "Recently added" shelf (newest `created_at`); "All products" browser with sort, in-stock filter and Show more.
- **Category**: category looked up from `categoriesQuery` (unknown slug → proper 404 view), breadcrumb, real name/description, count, sort + in-stock filter in the URL, Show more (20 at a time).
- **Cards**: fixed ratio box, lazy/async images with `onError` placeholder, Sold out / Only N left (from the product's own threshold) / On offer badges, struck-through compare-at, Add → inline stepper (capped at stock), "Added" feedback + toast, whole card tappable.
- **Product page**: two-column layout, breadcrumb, brand, price block, stock text, stock-capped stepper that accounts for what is already in the basket, "Maximum in basket", sold-out state, "View basket", related shelf from the same category.
- **Cart**: skeleton until hydrated (no empty flash), line items with image/unit price/stepper/Remove (with toast), `validate_cart` warnings with the same fixes checkout offers (Accept new price / Reduce to N / Remove), order summary (basket subtotal; automatic-promotion discount line for signed-in customers via the existing `validate_coupon` preview), clear checkout / sign-in / continue-shopping actions.
- **Global**: contrast tokens fixed, one focus ring, reduced motion, no horizontal scroll.

## 3. New components / files

`components/catalog/`: product-image, stock-badge (StockBadge, SaleBadge), price-block, catalog-toolbar, product-shelf, home-sections. `components/layout/`: search-box, breadcrumbs, trust-strip, store-footer. `components/states/`: error-kind.ts, use-online-status.ts, use-slow-flag.ts. `features/catalog/browse.ts` (pure helpers). `ui-kit/button` gained sizes `touch`, `touchBlock`, `touchIcon` (existing sizes untouched because admin uses them).

## 4. States added (`states.tsx`, additive — existing exports unchanged)

`StorefrontErrorState` (friendly, logs to console only, Try again; offline wording), `NotFoundState`, `ConnectionBanner`, `SlowNetworkHint`, `ProductPageSkeleton`, `CartSkeleton`; grid skeleton upgraded. Loading skeletons match the final layouts.

## 5. Accessibility & performance notes

- Contrast (computed): muted text 3.67→≈6:1; danger 4.4→≥5:1; primary-on-white 4.8–5.1 already OK. Placeholder now uses muted.
- 44 px: header controls, chips, buttons, stepper, search, footer/breadcrumb links, cart links. Remaining sub-44 elements are native 20 px checkboxes inside 44 px label rows and card name links whose hit area is the whole card (stretched link).
- Landmarks/headings: one `<h1>` and one `<main>` on all 10 checked pages; labelled `nav`s; `role=search`; live regions for counts and basket status; alt text (decorative hero/category images use empty alt).
- Perf: lazy + async images with `sizes`, eager+`fetchpriority=high` only for hero/product image, memoised card, no new dependencies, no animation beyond existing CSS, load-more instead of rendering everything. Bundle size not measured.
- Bugs found by testing and fixed: page-wide horizontal overflow from `sr-only` text in scrollers; first Tab skipping the header (`scrollIntoView` moved the focus origin); quoted `instock="1"` in URLs; numeric search terms dropped; long skeleton before errors (retry cap).

## 6. Verification — separated honestly

**Ran and passed (real output):**

- `npm test`: 783 pass, 0 fail (761 existing + 22 new).
- `npx tsc --noEmit`: clean. `npx eslint .`: 0 errors, 10 warnings (identical to baseline). Prettier check on all touched files: clean. `npm run build`: succeeds.
- Real Chromium 141 against the real dev server, with Supabase REST calls **intercepted and answered by fixtures I wrote** (27 fake products, 6 categories, SVG images; test harness in /tmp, not in the repo): 10 pages × 360/390/768/1280 px = 40 checks, no horizontal overflow, 1 h1 + 1 main each. 39 scripted interaction checks pass (debounce/Enter/Esc/URL, drawer, active chip, breadcrumb, load more, sort, filter, add/stepper/remove, stock cap, sold out, 404s, empty cart, price-changed warning + Remove, forced network failure → friendly error → Retry recovers, offline banner on/off, skip link + focus outline).

**Type-checked/built only:** nothing else is claimed.

**NOT verified:** against your real Supabase data or real photos; Safari/iOS/Firefox or any real phone; screen readers; Google Fonts (blocked in the sandbox, fallback fonts were used); Lighthouse/Core Web Vitals/bundle size; real slow-network behaviour (simulated only by failing requests); checkout, auth and account pages visually after the token changes (code untouched); `routeTree.gen.ts` regeneration (no route added).

## 7. Decisions needed / open items

1. **Promotions on the homepage — not built.** The `promotions` table has RLS with no policy and `validate_coupon` is granted to `authenticated` only, so there is no existing public read of promotions. Building one would need a new RPC/policy (forbidden here). The "On offer" shelf uses real compare-at prices instead, and the basket shows the automatic-promotion discount for signed-in customers. Decide whether you want a public promotions read in a later phase.
2. **Coupon input stays in checkout** (calculation and totals are out of scope). Cart text points customers to checkout; I did not audit checkout's coupon messages (they come from `promotions/logic.ts`, which has its own tests).
3. **Variant selector — not built.** There is no storefront variant read function under `src/features/catalog`, and rules forbid new read paths. Cart `add()` already supports variants once one exists.
4. **Gallery**: `ProductRow` has one `image_url`, so it is a single image.
5. **No "Popular" shelf**: no popularity/sales data in the catalogue read path.
6. **Sort/filter/paging are client-side** on the full list the existing `productsQuery` returns (no server parameters exist). Fine for hundreds of products; will need server-side paging at scale.
7. **Soft 404s**: unknown product/category pages render a proper 404 view but the HTTP status is 200 (data is fetched client-side). A route loader with `notFound()` would fix this.
8. **Shared-token side effects**: `--muted` and `--danger` are darker and a global focus ring/reduced-motion rule were added in `styles.css`, so admin/checkout text gets slightly darker too (contrast improvement only). `BrowseCta` is now 44 px tall. Please glance at admin once.
9. Small read-path tweaks in `features/catalog/queries.ts`: added the existing `low_stock_threshold` column to the select (table-wide anon grant exists) and `retry: 1`.
10. Page `<title>`s on category/product still derive from the slug; unused assets `category-bakery.jpg` / `category-drinks.jpg` remain in `src/assets`.
11. Pre-existing: `tsc -p tests/tsconfig.json` reports 2 errors in `tests/admin-products.test.ts` (same on the baseline; my files add none).
12. **Known item, untouched:** checkout's M-Pesa "Not connected yet" label (flag hard-coded false; no STK push). Trust copy therefore says only that cash on delivery is available and other options appear at checkout when enabled.

## 8. Files changed or added

Modified: `src/components/states/states.tsx`, `src/components/ui-kit/button.tsx`, `src/components/ui-kit/quantity-stepper.tsx`, `src/components/catalog/catalog-section.tsx`, `src/components/catalog/product-card.tsx`, `src/components/layout/store-header.tsx`, `src/components/layout/category-rail.tsx`, `src/features/catalog/queries.ts`, `src/routes/__root.tsx`, `src/routes/index.tsx`, `src/routes/category.$slug.tsx`, `src/routes/product.$slug.tsx`, `src/routes/cart.tsx`, `src/styles.css`, `tests/tsconfig.json`, `HANDOFF.md`.
Added: `src/components/catalog/{product-image,stock-badge,price-block,catalog-toolbar,product-shelf,home-sections}.tsx`, `src/components/layout/{search-box,breadcrumbs,trust-strip,store-footer}.tsx`, `src/components/states/{error-kind.ts,use-online-status.ts,use-slow-flag.ts}`, `src/features/catalog/browse.ts`, `tests/storefront-browse.test.ts`, `phase11_storefront_ux_report.md`, `phase11_manual_qa_checklist.md`.

## 9. Tests added (22, all pure logic)

Search normalisation (incl. numeric URL values) and ranking; sort keys/ties/immutability; stock state mirroring `create_order()` rules and the product's own low-stock threshold; max quantity; compare-at; load-more arithmetic; debounce (trailing, flush, cancel); URL parsing/`withSearchParam`; error classification and "never leaks raw error text".
