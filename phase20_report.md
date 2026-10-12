# Phase 20 report: admin catalog (branch `phase-20-admin-catalog`)

**Ran:** `node --test` on all of `tests/` (1037 pass, 0 fail; run once at the end of 20C). **Could not run:** `npm ci` (registry unreachable), so no `tsc`, `eslint` or `prettier` for 20C or 20B; no browser; no `psql`. Everything below not listed under "ran" is **code-reviewed only**.

## Step 1 findings (from the code, read before coding)
- Existing writers: `admin_create_product` (name, slug, price + optional fields, no stock/active/image), `admin_update_product` (PATCH), `admin_set_product_active`, `admin_adjust_inventory` (reason 1-120 required; product-level when no variant). `categories` had no admin writer; browser roles have no write grants.
- `image_url` is a plain `<img src>` everywhere, so a full https URL works as well as `/products/x.jpg`. No CSP or image-host allowlist in the repo. Storage was unused before 20B.

## Commits
`phase 20a: admin categories`, `phase 20a: fix SQL test`, `phase 20b: admin picture upload`, `phase 20c: starting stock and active on create`, plus the end-of-phase docs commit.

## 20C design (no new migration)
Chains existing functions: create product, then `admin_adjust_inventory` ("Opening stock", only if stock > 0), then `admin_set_product_active(false)` only if Active is off. A failed follow-up keeps the product, shows a plain message and a link to it. If the stock step fails, deactivation is still attempted, so a product meant to be hidden is not left visible. Chaining is not atomic: each call is its own transaction. Files: `product-create-form.tsx`, new `product-create-plan.ts`, new `tests/admin-product-create-plan.test.ts`. Invalidated keys are the form's existing four; none added.

## Checked vs not checked
- **Ran:** all `tests/*.test.ts`, including pure validators for 20A, 20B, 20C.
- **Not run:** all SQL (migrations 20A, 20B; `phase20a`/`phase20b` SQL tests; storage policies); no migration or storage policy has been applied to any database; the `catalog-images` bucket does not exist yet. No type-check, lint or format run for the .tsx files or `product-create-plan.ts`. No UI run (create form, picker, categories screen, 360 px, keyboard).

## Needs follow-up
1. Run `npm ci`, `npx tsc --noEmit`, `npx eslint .`, `npx prettier --check` on a machine with network. HANDOFF's 20A section says tsc/eslint ran; this session could not confirm that, so re-run.
2. Apply the migrations and run both new SQL tests plus the eight edited older ones on a dev database. The 20A SQL test was corrected in `phase 20a: fix SQL test` (helper function order, `t -> f` audit text); I did not run either version.
3. `src/routeTree.gen.ts` was regenerated with the router generator in 20A, not by `vite dev`; let `vite dev` regenerate it and check the diff is empty.
4. Chaining caveat: if the product is meant to be inactive and the deactivate call fails, it stays live with its stock until fixed on the product page (the message says so). If that is unacceptable, replace the chain with ONE new atomic function in a new migration.
5. Old picture files stay in the bucket after replace/remove (orders keep a copy of `image_url`).
6. `db/tests/phase8_coupon_concurrency.sh` and `zip-project.bat` still have uncommitted local changes, left alone. `run-sql-tests.sh` has only its ORDER edit committed (exec bit kept).
