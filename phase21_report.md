# Phase 21 report: admin product variants

**`npm ci` FAILED** (npm crashed with "Exit handler never called"; this sandbox has no network). So everything not listed under "Ran" is **code-reviewed only**: no `eslint`, no `prettier`, no full `tsc`, no browser, no database.

## Step 1 findings
- **(a) Activation:** there is no dedicated function. `admin_update_product_variant` (latest body: `20261005110000`) accepts `name, sku, price_cents, compare_at_price_cents, attributes, position, is_active`; absent key = unchanged, any other key refused. So Active is included, via `{ is_active: false }`. The existing Edit dialog does not expose it.
- **(b) Storefront (read, grep level, not fixed):** product page orders active variants, selects one, takes price/stock from it; with no active variant it falls back to the product itself. Card shows "From X" when prices differ and judges sold-out by variants. Cart lines and cart validation carry `variant_id`. Admin inventory lists variants as their own units.
- **Gaps:** (1) no screen can hide or show an **existing** variant; (2) variant cards show no compare-at / Sale badge; (3) once a product has an active variant, its own price/stock are ignored by the storefront but still listed in admin inventory (the adjust dialog says so); (4) `fieldFromInvalidMessage` does not recognise "Invalid variant name", so a server-side name refusal shows as a form message, not on the field (client check catches it first); (5) checkout/`create_order` with variants was not read.

## Changed (commit `phase 21a`)
`src/components/admin/product-variants-card.tsx` (Add variant dialog; new `productId` prop), `src/features/admin/variant-create-plan.ts` (new, pure), `src/features/admin/products.ts` (`adminCreateProductVariant`), `src/features/admin/products-result.ts` (exported `checkSku`, `hasControlCharacter`), route `products.$productId.tsx` (passes `productId`), `tests/admin-variant-create-plan.test.ts` (17 tests). No migration, no new dependency or route.

## How it works
Chain: create variant, then `admin_adjust_inventory` (`p_product_id` + `p_variant_id`, reason "Opening stock") only if stock > 0, then `admin_update_product_variant({is_active:false})` only if Active is off. Reuses `parseStartingStock`, `runCreateWithExtras` from `product-create-plan.ts`. Position = highest used + 1 (0 for the first). Not atomic: a failed later step keeps the variant and shows a plain warning toast. "Save and add another" clears the form and refocuses Name. Invalidated (all existing keys): `["admin","product",id]`, `["admin","products"]`, `["admin","inventory"]`, `["admin","dashboard"]`, `["products"]`, `["product"]`, `["product-variants"]`, `["variant-summary"]`.

## Ran vs not
- **Ran:** `npm test` (1054 pass, 0 fail, includes the 17 new); `tsc --strict --noUncheckedIndexedAccess` on `variant-create-plan.ts` and its test alone (clean; Node types absent, so no assert narrowing relied on).
- **Not run:** `eslint`, `prettier` (long lines hand-wrapped), `tsc` on the `.tsx`/`products.ts`, browser, 360 px, keyboard, any database call.

## Phase 21c (commit `phase 21c: variant active switch`): gaps 1 and 4 closed in code
Edit dialog has an Active switch; `is_active` goes in the same `admin_update_product_variant` patch, only when changed (`products-result.ts`: `active` in `VariantFormValues`, `buildVariantChanges`). The table already showed each variant's status (`ProductActiveBadge`), so nothing was added there. "Invalid variant name" now maps to the Name field. Edit-dialog invalidation unchanged. Add-dialog partial message now says to use Edit. Tests: `tests/admin-variant-active.test.ts` (7). Ran again: `npm test` 1061 pass, 0 fail; standalone strict `tsc` on `products-result.ts`, `variant-create-plan.ts` and the new test (clean); `npm ci` failed again. Not run: `eslint`, `prettier`, `tsc` on the `.tsx`, browser, database.

## Needs follow-up
- Gap 2: variant cards show no compare-at / Sale badge (not fixed).
- Gap 3: product-level stock still listed in admin inventory once a product has variants (not fixed).
- Gap 5: checkout / `create_order` with variants not re-read.
- Run `npm ci`, `tsc`, `eslint`, `prettier --check` and the QA checklist on a networked machine; add "switch a variant off and on from Edit" to the walk-through.
