# PHASE 6D-3B — Admin Products: Create + Activation/Deactivation (+ existing image support)

**Status: IMPLEMENTED, partly statically verified. NOT runtime-tested, and `tsc` / `vite build` / `eslint` were NOT run**
(the sandbox had no `node_modules` and no network, so `bun install` was impossible). See section 5.

No database changes. No new migration, grant, policy, table or bucket.

## 1. Files created

- `src/routes/_authenticated/admin/products.new.tsx` — `/admin/products/new`
- `src/components/admin/product-create-form.tsx` — create form (double-submit guard, field-level errors, success state, navigates to the new product)
- `src/components/admin/product-form-fields.tsx` — the nine catalogue fields, shared by the create and edit forms
- `src/components/admin/product-status-card.tsx` — active/inactive badge + activate/deactivate with confirmation dialog
- `tests/admin-products-create.test.ts` — 18 tests (pure logic)
- `phase6d3b_admin_product_create_activation_report.md` — this file

## 2. Files modified

- `src/features/admin/products-result.ts` — added `emptyProductFormValues`, `slugifyName`, `buildCreateProductArgs`
- `src/features/admin/products.ts` — added `adminCreateProduct`, `adminSetProductActive` (thin RPC wrappers)
- `src/features/admin/product-management.ts` — added `describeProductActivationError`
- `src/components/admin/product-edit-form.tsx` — field markup moved into `ProductFormFields` (behaviour unchanged)
- `src/routes/_authenticated/admin/products.$productId.tsx` — new "Status" section; reference note updated
- `src/routes/_authenticated/admin/products.index.tsx` — "New product" button
- `src/components/admin/product-badges.tsx`, comment only
- `src/routeTree.gen.ts` — **hand-edited, additive only** (new `/admin/products/new` route in every table). Run `vite build`/`vite dev` once so the router plugin regenerates and verifies it; keep the generated file.

## 3. Existing backend functions reused (nothing duplicated)

`admin_create_product` (6C.1B.1), `admin_set_product_active` (6C.1B.2), `admin_get_product`, `admin_list_products`,
`require_admin()` / `is_admin()` through the existing `/admin` layout. Types (`AdminCreateProductArgs`, etc.) already existed.

## 4. Behaviour and decisions

- **Authorisation**: both new screens sit under `/_authenticated/admin`, so signed-out users go to `/auth` and non-admins see "Admin access required". Both RPCs call `require_admin()` first. Staff are NOT admitted (unchanged).
- **Create**: required = name, slug, price. Slug follows the name until edited. Sends only the nine arguments the function accepts. Duplicate slug/SKU, unknown category and invalid values are shown field-level; raw database text is never shown. Duplicate submits are blocked (ref guard + disabled + `created` flag); the unique slug index is the backstop if a request is retried after a network failure.
- **A new product is ACTIVE immediately** (table default; the 6C.1B.2 header documents this). The form says so. Changing that default is a backend decision, not made here.
- **Activate/deactivate**: confirmation dialog, controls disabled while saving, dialog cannot be dismissed mid-save, success toast, error shown in the dialog. Verified in the SQL that inactive products are hidden by RLS ("public read active") and refused by `create_order`, so the dialog's wording is accurate. No deletion exists.
- **Queries invalidated** after create / activation: `["admin","products"]`, `["admin","product",id]` (activation), `["admin","inventory"]`, `["admin","dashboard"]`, `["products"]`, `["product"]`.

## 5. Verification

| Check                                                                                                                                                         | Result                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Tests (`npm test` = `node --test`)                                                                                                                            | **251 passed, 0 failed** (233 existing + 18 new) — actually run                        |
| `tsc` on the pure modules + new test (`products-result.ts`, `product-management.ts`, `types.ts`, `admin-products-create.test.ts`, with stubbed `node:` types) | 0 errors — actually run                                                                |
| Full `tsc --noEmit` (components, routes, `products.ts`)                                                                                                       | **NOT RUN** — needs `bun install`                                                      |
| `vite build`                                                                                                                                                  | **NOT RUN**                                                                            |
| `eslint .` / Prettier                                                                                                                                         | **NOT RUN**. New files were written to the repo's style but not formatted by Prettier. |
| Baseline (4 TS4111 errors in `orders-result.ts`, 28 lint problems)                                                                                            | Untouched; not re-measured                                                             |

## 6. Runtime tests performed

**None.** Nothing was rendered, no RPC was called, no Supabase project was touched. The smoke-test checklist in the brief is still to do.

## 7. Image support — limitation (no architecture invented)

The only image support in the repo is a nullable `products.image_url text` column, displayed read-only. There is **no storage bucket, no
upload helper, no product-image table**, and `admin_create_product` / `admin_update_product` explicitly reject `image_url`
(`unsupported_field`). So no image UI was built; the detail page keeps showing the existing image and now says upload is not available.
Image upload needs a backend phase first (a bucket + a function that sets `image_url`).

## 8. Remaining work

1. `bun install`, then `tsc --noEmit`, `bun run build` (regenerates `routeTree.gen.ts`), `bun run format`, `bun run lint`; fix anything in the new files.
2. Apply migrations 6C.1A.1 → 6C.1B.2 to Supabase (see the four files given earlier), then run the runtime checklist.
3. Decide whether new products should start inactive.
4. Image upload (backend first). Unsaved-changes prompt on the forms.
