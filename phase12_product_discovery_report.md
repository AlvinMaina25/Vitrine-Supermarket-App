# Phase 12 — Product discovery: report

Branch `phase-12-product-discovery`. Built on the Phase 11 storefront. Storefront files only.

**Read this first.** This sandbox had no network and an empty npm cache, so `npm ci` could not install dependencies. `tsc` (app), `tsc -p tests`, `eslint`, `prettier`, `vite build`, the dev server and any browser were **not run**. Only `npm test` (Node's own runner on pure helpers), git checks and a strict type-check of the four pure helper files were run. Everything about components, routes and visuals below is "written and reviewed by reading", not run.

## 1. Data-support map

| Feature | Status | Notes |
|---|---|---|
| Typo-tolerant search | SUPPORTED | Client-side over the full list; tolerance grows with word length |
| Search suggestions | SUPPORTED | Client-side. Stock label uses the product row only (see issue 6) |
| Sort (best match, name, price, newest) | PARTLY | Price sort uses the product's own price, not a variant's |
| In-stock-only filter | SUPPORTED | Variant-aware when the variant summary loaded; falls back to the product row when it did not |
| Brand filter and counts | SUPPORTED | Counts use the same variant-aware sold-out rule |
| Price-range filter | PARTLY | Whole currency units; compares the product's own price, not a variant's |
| "On offer" filter | PARTLY | Product's own compare-at price only |
| Category tree and parent-category listings | SUPPORTED | Uses `parent_id`; a parent lists its whole subtree |
| Variants on the product page | SUPPORTED | Active variants only, existing RLS |
| "Choose options" on cards | SUPPORTED | Needs the variant summary to have loaded |
| Low-stock "Only N left" | SUPPORTED | Only when the product or variant has its own `low_stock_threshold` |
| Related products | SUPPORTED | Same category/brand, in-stock first (judged by the product row, issue 6) |
| Recently viewed | SUPPORTED | Device-only (localStorage ids), nothing sent to a server |
| Wishlist | NOT SUPPORTED | Approved: deferred to a later account-linked backend phase |
| Popular shelf, image gallery, unit filter | NOT SUPPORTED | Approved limits |
| Promotions shown on cards | NOT SUPPORTED | No public promotions read |
| Server-side search/sort/paging, soft-404 status codes | NOT SUPPORTED | See section 8 |

## 2. Baseline audit findings (before Phase 12)

- A typo search ("mlk") returned nothing.
- A product with variants showed "Sold out" when its own row had 0 stock, even though variants were available.
- A parent category listed only its direct products.
- The category rail was flat.
- Filters were limited to in-stock and sort.

## 3. What changed per page

- **Home** (`index.tsx`): search, filters, sort and active-filter chips through the new catalog section; recently viewed shelf.
- **Category** (`category.$slug.tsx`): lists the whole subtree; breadcrumb trail; child categories; same filters and sort.
- **Product** (`product.$slug.tsx`): variant selector (`?variant=`), price, stock and SKU follow the chosen variant, editable quantity, sticky mobile buy bar, document title, related shelf, records recently viewed.
- **Cart** (`cart.tsx`): the quantity stepper is now editable (one line). No cart logic changed.
- **Header**: search box is a suggestions combobox; category rail shows top-level plus the active branch.

## 4. New components and helpers

Pure helpers (unit-tested): `discovery.ts`, `product-detail.ts`, `category-tree.ts`, `recently-viewed.ts`.
Hooks: `use-recently-viewed.ts`, `use-document-title.ts`.
Components: `active-filters`, `filter-controls`, `recently-viewed-shelf`, `sticky-buy-bar`, `variant-selector`; reworked `catalog-section`, `catalog-toolbar`, `product-card`, `product-shelf`, `category-rail`, `search-box`, `quantity-stepper`.
Queries: `productVariantsQuery`, `variantSummaryQuery` (now paged, see section 6).

## 5. What is client-side and why

Search, filter, sort, facets and category subtrees run in the browser over the full list the existing `productsQuery` already loads, **before** pagination. This is an approved decision: no new endpoint, RPC or schema change. Prices stay integer cents and are formatted only through `src/lib/format.ts`; the price filter converts whole units to cents for comparison only and never touches a displayed or charged amount.

## 6. Inventory-availability check (the most important one)

**create_order() rule** (`20261009010000_phase8_discounts_promotions.sql`): a plain product line needs `in_stock` and `stock_quantity` at least the quantity; a variant line needs an active variant with `stock_quantity` at least the quantity. Variants have no `in_stock`.

Result of reading the code against that rule:

- **Product page judges stock the same way: PASS.** Plain product uses `in_stock` and `stock_quantity > 0`; variant uses `stock_quantity > 0`.
- **A product with variants cannot be added without a variant on the product page: PASS.** The purchase controls are not rendered while variants load or if the variants read fails, and once variants exist one is always selected.
- **Base stock does not wrongly mark a variants product "Sold out" on the product page: PASS.** The chosen variant decides.
- **A sold-out variant cannot be added: PASS.** The sold-out branch renders a disabled button and `addToBasket` also returns early.
- **In-stock filter and brand counts use the variant-aware rule: PASS** when the variant summary loaded (the `soldOut` rule is injected into both).
- **FAIL (fixed): the card's quick "Add".** If the variant summary was still loading, failed, or came back partial, a variants product looked like a plain product and showed a plain "Add" that adds the base product with no variant. The database does not forbid that.
  - Fix: a card offers quick-add only after the summary read succeeded. Until then it shows "View product", a link to the product page, and makes no stock claim.
- **FAIL (fixed): the 1000-row cap.** `variantSummaryQuery` had no order and no paging, so a server row cap would have silently dropped variants. It now pages with an exact count and a stable order, and **throws** rather than return a partial list (`collectAllPages`, 7 unit tests).

**What the customer sees if `variantSummaryQuery` fails or cannot be read completely:**
- Cards show "View product" instead of Add/Choose options/Sold out, and no stock badge. They can still buy from the product page.
- "In stock only" and brand counts fall back to the product row's own stock, so a variants product whose own row is at 0 stock is wrongly treated as sold out in the filter. There is no on-screen notice of this fallback (open item).
- The product page is unaffected: it reads its own variants.

**Fixture warning.** The exact count needs the server to return a `Content-Range` header. Real PostgREST does. A fake fixture server that omits it makes the summary throw, so cards would stay on "View product". Any scripted fixture check must return that header.

## 7. Tests added

`tests/storefront-discovery.test.ts` and `tests/storefront-product-detail.test.ts` (Phase 12 helpers, earlier commit) plus 7 new `collectAllPages` tests in this pass. No existing test was changed or weakened.

## 8. Commands run, with real results

| Command | Result |
|---|---|
| `npm ci` | FAILED: no network (`ENOTFOUND registry.npmjs.org`); crash left `node_modules` hollow. `--offline` failed too (empty cache) |
| `npm test` | 859 tests, 859 pass, 0 fail (852 before this pass: 783 baseline + 69 Phase 12; +7 new) |
| `git diff --stat ee1d3cd` and path greps | No changes in `db/`, server functions, payments, checkout, auth, admin, notifications, `package*.json`. `routeTree.gen.ts` unchanged |
| strict `tsc` (TypeScript 6.0.3 global) on `product-detail.ts`, `discovery.ts`, `category-tree.ts`, `recently-viewed.ts` | Clean |
| `npx tsc --noEmit`, `npx tsc -p tests/tsconfig.json`, `npx eslint .`, prettier | NOT RUN (dependencies unavailable) |
| `npm run dev`, build, browser screenshots at 360/768/1280 | NOT RUN |

## 9. Verification status

**Verified by running:** `npm test` (859/859); git diff and path checks.

**Type-check or unit test only:** the four pure helper files (strict tsc plus unit tests); `collectAllPages` paging, truncation and throw behaviour (unit tests).

**Not checked:** app-wide type-check; test-project type-check (the 2 known `admin-products.test.ts` errors); eslint (expected 0 errors, 10 warnings); prettier on touched files (edits were written by hand in the repo's style, so formatting may need `prettier --write`); production build; every `.tsx` change including the card, cart and routes; any browser rendering, focus ring, contrast, 44 px targets, 360/768/1280 layouts, mobile filters sheet; real-database behaviour including PostgREST's actual row cap and the `Content-Range` header; the earlier 109 fixture checks were not re-run after the card/query change. `src/routeTree.gen.ts` was not regenerated; it is unchanged, and whether `?variant=` needs a regeneration is unconfirmed without the dev server.

## 10. Needs backend work (not done, by rule)

Server-side search/sort/paging; a public promotions read; variant availability in the list read (would replace the summary query); soft-404 status codes; an account-linked wishlist.

## 11. Approved decisions (not reopened)

Wishlist deferred. Variants read from the existing public `product_variants` table through the browser client, active only. "Only N left" only with the row's own threshold. Search/filter/sort in the browser before pagination. Accepted limits: whole-unit price filter, no unit filter, no gallery, no popular shelf.

## 12. Unresolved issues

1. **Price filter, price sort and "On offer" use the product's own price and compare-at**, while cards for variants products display "From <cheapest variant>". A price range can include or exclude a product against a price the card does not show. Correctness/UX, not a charging issue (checkout is untouched).
2. **Filter fallback is silent** when the variant summary fails (section 6).
3. **Cart stepper** is now editable, but it has no stock `max` (as before); typed values clamp to 1–99 and the existing cart validation and `create_order()` still decide. Layout at 360 px not viewed.
4. **Search suggestions** label stock from the product row, so a variants product can show "Sold out" or "Only N left" there. Display only; no purchase path.
5. **Related/recently viewed ordering** ranks by the product row's stock, so a variants product with base stock 0 sorts as sold out. Ordering only.
6. **`variantSummaryQuery` reads every active variant** (paged). Fine for a small shop; it is the reason a list-read change is listed above.
7. No security issue found: no new endpoint, grant, policy, secret or dependency; localStorage holds only product ids.
