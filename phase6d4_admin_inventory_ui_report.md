# PHASE 6D-4 — Admin Inventory UI

**Status: IMPLEMENTED, statically checked in part. NOT runtime-tested. `tsc --noEmit`, `eslint`, Prettier and `vite build` were NOT run**
(the sandbox had no `node_modules` and no network, so `bun install` was impossible).

No database changes. No new migration, table, function, grant or policy.

## Completed (Implemented — code written; see Verification for what was actually run)

- `/admin/inventory` route with two tabs, **Stock** and **History** (URL-driven: `?q`, `?view`, `?tab=history`, `?product`, `?variant`, `?page`).
- Stock list: product, variant, SKU, current stock, state badge (Low stock / Out of stock / In stock / Inactive), server-side search and paging.
- Filtering: **All inventory**, **Low stock**, **Out of stock** (Out of stock added because the backend's low-stock rule excludes zero).
- Adjustment dialog: shows current stock, collects a signed change, a reason (required, 1–120) and an optional note (≤ 500), previews the estimated result, then a **review / confirm** step. Calls `admin_adjust_inventory()` only.
- Duplicate-submit guard: ref guard + disabled controls + "Applying…" state; the dialog cannot be dismissed mid-call.
- After every attempt (success or refusal) all `["admin","inventory"]` queries, the product detail/list, the dashboard and the storefront product caches are invalidated.
- Success toast reports what the database stored (previous → new). Failures are worded from the database's reason code; raw database text is never shown.
- History tab: when, product / variant / SKU, signed change, previous → new, reason, note, actor ("You" or a short id), newest first, paged, optionally filtered to one product or variant (via the row's **History** link).
- Loading skeletons, empty states, error states (403 "Admin access required", config notice, retry) on both tabs.
- Admin nav: **Inventory** is now a live link.

## Routes

- Created: `/admin/inventory` (`src/routes/_authenticated/admin/inventory.index.tsx`).
- Changed: `src/routeTree.gen.ts` — **hand-edited, additive only** (same pattern as 6D-3B). Run `vite build`/`vite dev` once so the router plugin regenerates it, and keep the generated file.

## Files

Created

- `src/routes/_authenticated/admin/inventory.index.tsx`
- `src/components/admin/inventory-adjust-dialog.tsx`
- `src/components/admin/inventory-history-panel.tsx`
- `src/components/admin/inventory-pagination.tsx`
- `src/features/admin/inventory.ts` (query options + `adminAdjustInventory`)
- `src/features/admin/inventory-result.ts` (pure: errors, shape checks, stock classification, form validation, paging collector)
- `src/features/admin/inventory-management.ts` (pure: URL params, labels, wording)
- `tests/admin-inventory.test.ts` (new, pure logic + migration drift guards)
- `phase6d4_admin_inventory_ui_report.md`

Modified

- `src/lib/supabase/types.ts` — added `AdminInventoryAdjustment*` types and the `admin_list_inventory_adjustments` function entry (types only).
- `src/features/admin/nav.ts` — Inventory gets `to: "/admin/inventory"`.
- `src/routeTree.gen.ts` — see above.
- `tests/admin-nav.test.ts` — Inventory is now a live route.
- `tests/tsconfig.json` — includes the two new pure modules.
- `tests/inventory-adjustment-history-migration.test.ts` — **one older guard changed on purpose**: Phase 6C.2.2A.1 forbade _any_ mention of `inventory_adjustments` in `src/`, which the History screen cannot satisfy (the function name contains it). The guard now forbids what it was protecting: `.from("inventory_adjustments")` and `public.inventory_adjustments` anywhere in `src/`.

## Backend reused (nothing duplicated)

- `admin_list_inventory()` (6C.2.1) — list, search, paging.
- `admin_adjust_inventory()` (6C.2.2A.2) — the only stock write; delta based, row-locked, writes one history row in the same transaction.
- `admin_list_inventory_adjustments()` (6C.2.2B.1) — history read.
- `require_admin()` inside each, plus the existing `/admin` layout gate (`is_admin`).
- Phase 6A `admin_dashboard_summary()` — its low-stock definition (see decision 1).

## Decisions you should know about

1. **Low stock.** The schema has no reorder level and `admin_list_inventory()` has no low-stock filter. The only backend definition is the Phase 6A dashboard rule (default threshold 10; product low = `in_stock` and 1..10; variant low = 1..10; out = 0 or product flag off; active only). The UI uses that exact rule (`classifyStock`, `LOW_STOCK_THRESHOLD = 10`). Because the database cannot filter by it, the Low/Out views read every unit (100 per call, capped at 2,000, with a visible notice if capped) and classify on the client; "All inventory" stays server-paged. `tests/admin-inventory.test.ts` reads the 6A migration and fails if the threshold or rule drifts. If you later want a stored threshold or a server-side filter, that is a backend phase.
2. **Admin only, not staff.** The request said "admin/staff"; the Phase 6A–6C functions admit admins only (staff are deliberately not admitted, as in earlier phases), so the screen is admin only. Making staff able to adjust stock would need a backend decision.
3. **No idempotency key exists** on `admin_adjust_inventory()`. Double clicks are blocked in the UI and concurrent callers are serialised by the row lock, but a request retried after a network failure of unknown outcome could apply twice. The failure message therefore tells the admin to check **History** before retrying.
4. The preview "Stock would become about N" is an estimate from the last refresh; the database computes the real value from the locked row. A result below zero is warned about but not blocked in the browser (the stock shown may be stale); the database refuses it.
5. Actors are shown as "You" or `Admin <short id>`: the history API returns user ids, not names, and this phase does not look up other accounts.

## Authorization

- Signed-out → redirected to `/auth` by `/_authenticated`. Signed-in non-admin → "Admin access required" from the `/admin` layout; none of the inventory UI renders.
- Not relied on: each of the three functions calls `require_admin()` first (SQLSTATE 42501 for everyone else), and the browser has no direct privilege on stock columns or on `inventory_adjustments`. A customer who calls the functions directly is refused by the database.

## Database

No database changes.

## Verification

| Check                                                                                                                                                                                     | Result                                                                               |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `npm test` (`node --test`)                                                                                                                                                                | **287 passed, 0 failed** — actually run (251 existing + 36 new/updated)              |
| `tsc` on the pure modules + new tests (`inventory-result.ts`, `inventory-management.ts`, `nav.ts`, `types.ts`, `admin-inventory.test.ts`, `admin-nav.test.ts`) with stubbed `node:` types | **0 errors** — actually run                                                          |
| Syntax parse of the new `.tsx` files, `inventory.ts` and `routeTree.gen.ts`                                                                                                               | OK — syntax only, **not** a type check                                               |
| Full `tsc --noEmit` (components, route, `inventory.ts`)                                                                                                                                   | **NOT RUN** — needs `bun install`                                                    |
| `vite build`                                                                                                                                                                              | **NOT RUN**                                                                          |
| `eslint .` / Prettier                                                                                                                                                                     | **NOT RUN** (new files were written to the repo style but not formatted by Prettier) |
| Baseline (4 TS4111 errors in `orders-result.ts`, 28 lint problems)                                                                                                                        | Untouched; not re-measured                                                           |

## Runtime tests — Not verified because environment/database unavailable

None performed: nothing was rendered, no RPC was called, no Supabase project was touched. Specifically NOT verified at runtime: inventory list loads, low-stock/out-of-stock filtering, adjustment (success, refusal, negative-stock, duplicate click), history view and its product/variant filter, customer blocked from `/admin/inventory`, customer RPC calls refused.

Prerequisite for any runtime test: the Phase 6C migrations through `20261004110000_phase6c2_inventory_history_api.sql` must be applied to the dedicated Phase-5 dev database (the earlier reports show they were written but not yet applied for 6C.1B.2 onward).

## Manual commands

```
bun install
bunx tsc --noEmit
bun run build          # regenerates src/routeTree.gen.ts — keep the generated file
bun run format && bun run lint
npm test
bun run dev            # then /admin/inventory
```

Smoke checklist (dev DB, as admin): list loads → search a SKU → Low stock view matches the dashboard's low-stock count → adjust +5 with a reason, confirm, stock and History update → adjust a negative amount larger than stock, expect the refusal wording → click Confirm twice quickly, expect one history row → History link on a row filters to that item. As a customer: `/admin/inventory` shows "Admin access required"; `supabase.rpc("admin_adjust_inventory", …)` returns 42501.

## Remaining work

1. Run the install / typecheck / build / format / lint steps above and fix anything in the new files.
2. Apply the pending Phase 6C migrations to the dev DB, then run the runtime checklist.
3. Decide on a stored low-stock threshold or server-side filter (backend phase).
4. Optional later: date / reason / actor filters on History (the function supports them), name lookup for actors, an idempotency key for adjustments.
