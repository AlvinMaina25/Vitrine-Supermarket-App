# PHASE 11 — STOREFRONT, FRONTEND & UX (branch `phase-11-storefront-ux`)

**Status: code complete. Verified: 783 unit tests, tsc, eslint (0 errors; 10 pre-existing warnings), prettier, `vite build`, and a real-Chromium pass (4 widths x 10 pages + 39 interaction checks) against MOCKED Supabase responses. NOT verified: your real data/photos, Safari/iOS, screen readers, Lighthouse, checkout/account visuals.**
Full detail: `phase11_storefront_ux_report.md`; owner checklist: `phase11_manual_qa_checklist.md`.

- Storefront only. No change to db/, RLS, server functions, payments, checkout, auth, admin screens, `routeTree.gen.ts`.
- New: pure helpers `src/features/catalog/browse.ts` (+ `tests/storefront-browse.test.ts`), friendly/offline/404/skeleton states in `states.tsx` (additive), header search/drawer, category rail, breadcrumbs, product image/badges/price block, catalog browser with sort/filter/load-more, home sections, rebuilt product page and cart.
- Shared-token change in `styles.css` (muted/danger darker, focus ring, reduced motion) also affects admin/checkout text colour slightly.
- How to run/check: `npm run dev` with your VITE_SUPABASE_* env, then follow `phase11_manual_qa_checklist.md`.
- Open items (needs your decision): no public promotions read exists (homepage promo section not built); no storefront variant read path (selector not built); client-side sort/filter/paging; soft 404 status; M-Pesa "Not connected yet" in checkout unchanged.

---

# PHASE 4 (4A-4C.2) — DELIVERY SYSTEM: FINAL STATUS

**Status: IMPLEMENTED. Unit-tested. PostgreSQL verification IN PROGRESS (migrations 000000-070000 applied to the dev
database; first SQL test found a real bug, fixed by migration 080000 — see below). NOT browser-verified.**

## Real-PostgreSQL finding (delivery_validation.test.sql)

`validate_delivery_selection()` raised `record "v_res" is not assigned yet` on every REJECTED selection: `v_res record`
was only assigned by `resolve_delivery_fee()` after the early `exit checks` branches, but the final RETURN QUERY names
`v_res.<field>` on all paths. Fixed by corrective migration
`db/migrations/20260930080000_fix_validate_delivery_selection_record.sql` (initialises `v_res` to an all-NULL row of the
same six columns/types; nothing else changed; 040000 left as applied). Must be applied AFTER 070000 on any database that
already has 040000. The fix is NOT yet confirmed by a passing run until delivery_validation.test.sql completes.

Second finding (TEST bug, not production): section 5 of `db/tests/delivery_validation.test.sql` appended untyped string
literals to a `text[]` (`v_names := v_names || 'literal'`), which PostgreSQL parses as an array literal ->
`malformed array literal`. Fixed with `::text` on those 8 literals. Security checks unchanged. Section 6 already used
`format()` (typed text) and was fine. Not yet confirmed by a completed run.
The sections below this one are the per-phase history (4C.1 and earlier); where they say "Remaining for 4C.2"
or "NOTHING SQL-side executed", this section supersedes them for what was built, but the verification gap is
unchanged: **no migration or SQL/shell test has ever been executed.** Run the sequence at the bottom first.

## Delivery configuration (data model, Phase 4A)

- `delivery_methods` (standard / express / pickup seeded): base fee, free-over threshold, minimum order,
  `requires_slot`, `requires_address`, `is_active`.
- `delivery_zones`: county/towns/description, `is_active`. **A fresh database has NO zones.**
- `delivery_zone_fees`: per zone + method fee, free-over and minimum order; overrides the method default.
- `delivery_slot_templates`: GLOBAL windows (optional weekday, capacity, position). No zone/method relationship.
- `delivery_slot_overrides`: per template + date capacity / closure.
- Customers can read active zones/fees only. Staff-only writes via RLS + column grants.

## Checkout (Phase 4C.2A)

- Address-delivery methods require an explicit active zone; pickup needs none.
- The fee shown is the database quote from `validate_delivery_selection()` (method, zone, server subtotal);
  React never computes a fee.
- Slot windows and capacity come from `get_delivery_slot_availability()`; full/closed windows are not selectable.
- `placeOrder` passes `zoneId`; `create_order()` has a trailing `p_zone_id uuid default null`.
- Delivery rejections surface as `PlaceOrderError` with a customer-facing message and the machine code
  (`deliveryCode`); a rejected zone/slot is cleared so the customer re-chooses. Raw database errors are not shown.

## Server enforcement (create_order(), one transaction)

1. Product lines, stock decrement, SERVER subtotal.
2. `validate_delivery_selection()` -> fee, method label, zone snapshot, fee rule (client cannot supply a fee).
3. Address snapshot when the method requires one.
4. `lock_delivery_slot()` -> per-slot advisory lock, then capacity re-read from the returned row.
5. Total = subtotal + validated fee; insert order with snapshot columns.

Lock: `pg_advisory_xact_lock(hashtextextended('delivery_slot:'||date||':'||start||':'||end, 4202))`, via the single
helper `delivery_slot_acquire_lock()`. READ COMMITTED required (25000 otherwise).

## Historical orders (Phase 4C.2B)

- Order row stores: `delivery_method` + `delivery_method_label`, `delivery_zone_id/_code/_name`,
  `delivery_slot_date/_start/_end/_label`, `delivery_slot_template_id`, `delivery_fee_cents`, `delivery_fee_rule`.
- `getOrderDeliveryDisplay()` (src/features/orders/delivery-display.ts) reads ONLY the order row; no live joins.
  `ORDER_DETAIL_COLUMNS` selects the snapshot columns.
- Pre-Phase-4 orders may have NULL snapshots: label falls back to the humanised method code, zone/slot show as
  not recorded; nothing is back-filled and nothing crashes (covered by unit tests).

## Capacity hardening (migration 20260930070000)

- One status predicate, `order_status_holds_delivery_slot()` (not cancelled/refunded), used by the booked count and
  the guard. Cancelled/refunded orders free capacity; every other status consumes it.
- Trigger `orders_guard_reactivation_capacity` (BEFORE UPDATE OF status): only on cancelled/refunded -> active
  with a complete slot. Takes the same advisory lock, then re-reads template/capacity/booked count; blocks a full,
  closed, or no-longer-offered slot (DETAIL `reactivation_slot_full|closed|not_offered`). Other transitions untouched.
  Lead time/horizon are intentionally NOT re-checked on reactivation.
- Duplicate active templates sharing one window: no uniqueness constraint; lowest `(position, id)` wins in
  `delivery_slot_evaluate()`, `create_order()` and (now) `get_delivery_slot_availability()`, so a shadowed template
  no longer shows false availability.

## OPERATIONAL REQUIREMENT

**Staff must create at least one active delivery zone (and a zone fee, or rely on the method default) before address
delivery works.** Until then checkout shows that no delivery areas are available and only pickup can be ordered.

## Known limitations (genuine, unresolved)

- **Nothing has run against PostgreSQL/Supabase.** All migrations, 4 SQL test files and 3 concurrency scripts are
  written but unexecuted. Concurrency guarantees are by design, not by observation.
- **Browser UI not verified.** `tsc` (full app), ESLint, Prettier and `vite build` were not run here either (see below).
- No address-to-zone mapping: the customer picks the zone by hand.
- Slot templates are global (not per zone/method).
- **Stock is not re-reserved when a cancelled order is reactivated** (cancel restocks via `restock_cancelled_order()`;
  reactivation does not decrement). Pre-existing, documented in 20260930020000, outside delivery correctness;
  needs a separate inventory decision. Not changed.
- Multi-row status UPDATEs touching the same slots in opposite order can deadlock; PostgreSQL aborts one
  transaction and rolls it back (no overbooking). Not redesigned.
- Staff capacity/override edits are not serialised against checkouts.

## Verification actually performed in the final pass (offline sandbox: no Postgres, no network, no node_modules)

- RAN, passed: `node --test "tests/**/*.test.ts"` — 107 tests, 0 failed, 0 skipped.
- RAN, clean: `tsc` 6.0.3 strict over the pure Phase 4C.2 modules + all tests (only a missing `node:fs` type stub, an
  environment gap). Full-app `tsc --noEmit` and `tsc -p tests/tsconfig.json`: fail only with TS2688 (no @types/node) — not meaningful.
- FIXED: `db/tests/delivery_validation.test.sql` static argument check matched `%total%` inside `p_subtotal_cents`.
  It now matches `fee`/`total` as whole name tokens and also asserts the exact three argument names. Production
  function NOT renamed. The fixed test has NOT been executed.
- NOT RUN: all SQL tests, all concurrency scripts, ESLint, Prettier, `vite build` (`.output/` left untouched; no
  backup at /tmp/output_orig_backup existed), browser smoke test.
- Static review: no `.env`, secrets, debug code or temp shim files in the tree. Not a git repository here, so
  `git status`/diff were not possible.

## First steps with a database

1. Apply migrations 20260930000000 ... 20260930080000 in order, once.
2. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f` each of: delivery_validation, delivery_slot_validation,
   create_order_delivery, order_reactivation_capacity `.test.sql`.
3. On a DEV database: `delivery_slot_concurrency.sh`, `create_order_concurrency.sh`, `order_reactivation_concurrency.sh`.
4. `bun install && bunx tsc --noEmit && bunx tsc -p tests/tsconfig.json --noEmit && bun run lint && bun run format &&
bun run test && bun run build`; then `git status` (build rewrites `.output/`, which is gitignored).
5. Browser smoke: pickup (no zone), address delivery (zone -> quote -> slot -> place), a forced delivery error.

---

# PHASE 4C.1 — create_order() delivery integration (code complete; NOTHING SQL-side executed)

Migration: `db/migrations/20260930060000_create_order_delivery_integration.sql` (apply after 050000, ONCE).
It drops the old 11-argument create_order() and creates a 12-argument one (new trailing `p_zone_id uuid default null`).

## Flow now in create_order() (one transaction; any RAISE rolls back stock, locks and rows)

1. signed-in check, idempotency lock/replay, basket shape, product lines + stock decrement + SERVER subtotal (unchanged)
2. `validate_delivery_selection(p_delivery_method, p_zone_id, v_subtotal)` -> reject (message = error_message,
   DETAIL = error_code) or take fee, method label, zone id/code/name and `fee_rule` from it
3. address check + snapshot when the method requires an address (unchanged)
4. `lock_delivery_slot(date,start,end)` when the method requires a slot -> reject (DETAIL = slot error_code) or take
   slot date/start/end/label/template_id from the returned row
5. total = subtotal + validated fee - discount (0); expected-total veto (unchanged rule)
6. insert order incl. snapshot columns (delivery_zone_id/_code/_name, delivery_method_label,
   delivery_slot_template_id, delivery_fee_rule) + items

Removed from create_order(): method lookup, own fee CASE, own minimum-order check, inline slot template match,
60-minute lead and 14-day horizon (they live only in delivery_slot_evaluate()).
Lock order: idempotency lock -> product/variant rows -> slot lock (no wait cycle).

## IMPORTANT behaviour changes

- **Address delivery is rejected ("Choose a delivery area.") until 4C.2 supplies a zone.** The checkout page sends
  `zoneId: null` (no address->zone mapping exists). Pickup methods (requires_address = false) are unaffected.
  Do not apply this migration to a live shop before 4C.2 unless address delivery being unavailable is acceptable.
- Slot capacity is now enforced. Delivery errors now come after basket errors.
- Unknown method message changed ("does not exist"); the machine-readable code is in the exception DETAIL
  (the browser wrapper still only surfaces `error.message`).

## Files

- db/migrations/20260930060000_create_order_delivery_integration.sql (new)
- db/tests/create_order_delivery.test.sql, db/tests/create_order_concurrency.sh (new, NOT executed)
- src/features/orders/create-order-args.ts (new: PlaceOrderInput + buildCreateOrderArgs), queries.ts (uses it),
  src/lib/supabase/types.ts (`p_zone_id` in CreateOrderArgs), src/routes/checkout.tsx (`zoneId: null`)
- tests/create-order-args.test.ts (new), tests/tsconfig.json

## Verification status (real)

- RAN, passed: `node --test "tests/**/*.test.ts"` — 36 tests (31 before + 5 new).
- RAN, clean: `tsc` 6.0.3 (repo strict flags) over create-order-args.ts + types.ts only.
- Static only: SQL dollar-quote/paren balance, `bash -n` on the new script.
- NOT RUN: all migrations, both new SQL/shell tests, advisory-lock concurrency (no Postgres/psql), full `tsc`
  (queries.ts, checkout.tsx need node_modules), eslint, Prettier, build (no bun, no network).
  The advisory-lock protection is still NOT empirically verified.

## First steps with a database

1. Apply 050000 then 060000. 2. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/create_order_delivery.test.sql`
   (expect "ALL CREATE_ORDER DELIVERY TESTS PASSED"). 3. `db/tests/delivery_slot_concurrency.sh` then
   `db/tests/create_order_concurrency.sh` on a DEV database. 4. `bun install && bunx tsc --noEmit && bun run lint &&
bun run format && bun run test && bun run build`.

## Remaining for 4C.2 (SUPERSEDED — implemented in 4C.2A/4C.2B; see top section)

- Zone selection / address->zone mapping and checkout wiring (until then address delivery cannot complete).
- Checkout still shows a client-side display fee from the method default; show the validated fee/slot errors
  (use `validateDeliverySelection()` / `validateDeliverySlot()` previews, and DETAIL codes if wanted).
- Decide the cancelled/refunded -> active status path (would consume capacity without the lock; 4B.2 rule 4).
- Orders select list (`ORDER_COLUMNS`) / `OrderRow` do not read the new snapshot columns yet.
- Duplicate active templates sharing one window (lowest position wins) — uniqueness rule undecided.

---

# PHASE 4B.2 — Delivery slot validation & overbooking protection (code complete; NOTHING SQL-side executed)

create_order() is untouched: checkout behaves as before until Phase 4C. Slots stay GLOBAL (no zone/method
relationship invented). Migration: `db/migrations/20260930050000_delivery_slot_validation.sql` (apply after 040000).

## What was added

- `delivery_slot_booked_count(date,start,end)` — the one definition of usage (status not cancelled/refunded).
- `delivery_slot_effective_capacity(template_id,date)` — the one definition of template + override capacity
  (override capacity replaces the template's; override NULL inherits it; override is_active=false closes the date).
- `get_delivery_slot_availability()` REPLACED (same signature/output) so it calls the two helpers instead of
  re-deriving them. Intended behaviour change: none. Unverified until the SQL tests run.
- `delivery_slot_evaluate()` (internal) -> `validate_delivery_slot(date,start,end)` (public, read-only, NO lock) and
  `lock_delivery_slot(date,start,end)` (internal, volatile, NOT granted to clients). One row each: is_valid,
  error_code (slot_required, invalid_window, slot_in_past, slot_too_far, slot_unknown, slot_inactive, slot_closed,
  slot_full), slot identity, template_id, label, capacity (NULL = unlimited), capacity_source, booked_count,
  remaining, is_unlimited, is_closed, is_full.
- TS: `src/features/delivery/slot-validation.ts` (`toDeliverySlotResult`), `validateDeliverySlot()` in queries.ts,
  types in `src/lib/supabase/types.ts`, `tests/delivery-slot-validation.test.ts`.
- SQL tests: `db/tests/delivery_slot_validation.test.sql` (rolled back), `db/tests/delivery_slot_concurrency.sh`
  (commits dev fixtures, cleans up).

## Locking mechanism

Transaction-scoped advisory lock `pg_advisory_xact_lock(hashtextextended('delivery_slot:'||date||':'||start||':'||end, 4202))`.
Not a row lock: a new order is a new row (nothing to lock), usage is counted per (date,start,end) not per template,
and the override row often does not exist. Same window -> same key -> second checkout waits, then re-counts and sees the
first order. Hash collisions only cause extra waiting. Released at COMMIT/ROLLBACK.

The guarantee holds only if 4C follows these rules:

1. Call `lock_delivery_slot()` INSIDE create_order()'s transaction, BEFORE inserting the order.
2. Decide capacity from the row it returns, never from an earlier validate/availability read.
3. READ COMMITTED only (function raises 25000 otherwise).
4. Any other path that moves an order from cancelled/refunded back to an active status would consume capacity
   without the lock. None exists today (staff can set `status` freely, so one could; decide in 4C).
   Staff capacity/override edits are deliberately not serialised against checkouts.

## Verification status (real)

- RAN, passed: `node --test "tests/**/*.test.ts"` — 31 tests (14 existing + 17 new slot mapper tests).
- RAN, clean: `tsc` (v6.0.3, repo strict flags) over slot-validation.ts, validation.ts, types.ts.
- Static only: SQL dollar-quote/paren balance, `bash -n` on the shell script. No SQL parser or Postgres was available.
- NOT RUN: the migration, both SQL test files, the concurrency test (no Postgres/psql), `tsc` on queries.ts and the test
  file (no node_modules / @types/node), eslint, Prettier, `bun run build` (no bun, network blocked).

## First steps with a database

1. Apply 050000 after 040000. 2. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/delivery_slot_validation.test.sql`
   (expect "ALL DELIVERY SLOT TESTS PASSED"). 3. `db/tests/delivery_slot_concurrency.sh` on a DEV database (expect PASS for the
   locked run, PASS for the control overbooking, PASS for the guard; exit 2 = control inconclusive, retry with more sessions).
2. `bun install && bunx tsc --noEmit && bun run lint && bun run format && bun run test && bun run build`.

## Remaining for 4C

- In create_order(): replace the inline slot block (template match, 60-min lead, 14-day horizon) with
  `lock_delivery_slot()`; the same constants now live in `delivery_slot_evaluate()`. Store `template_id` on
  `orders.delivery_slot_template_id` and the label/window from the returned row.
- Edge case to decide: two ACTIVE templates sharing one window resolve to the lowest position (as create_order() always
  has); the availability listing shows both rows. Consider a uniqueness rule on (window, weekday) for active templates.
- An override cannot make a capped template unlimited (override NULL = inherit). Schema semantics unchanged.
- Everything listed under "Remaining for 4B.2 / 4C" below that is not slot-related (zone mapping, fee wiring).

---

# PHASE 4B.1 — Delivery validation & fee authority (code complete; DB tests NOT executed)

## What was added (nothing from 4A rebuilt; create_order() untouched)

- `db/migrations/20260930040000_delivery_validation.sql` — one function,
  `public.validate_delivery_selection(p_method_code, p_zone_id, p_subtotal_cents)`. Always returns one
  row: `is_valid`, `error_code`, `error_message`, method/zone identity, the authoritative fee fields and
  `fee_rule` (the exact jsonb for `orders.delivery_fee_rule`). Fee and minimum order come ONLY from the
  existing `resolve_delivery_fee()`; there is no fee/total argument. Error codes: invalid_subtotal,
  method_required, method_unknown, method_inactive, zone_required, zone_unknown, zone_inactive,
  unavailable, below_minimum_order. SECURITY DEFINER (so unknown vs inactive can be told apart),
  returns no other table data; granted to anon + authenticated like resolve_delivery_fee().
- `src/features/delivery/validation.ts` — `toDeliverySelectionResult()` (row -> discriminated union; an
  incomplete "valid" row is rejected, never read as free delivery).
- `src/features/delivery/queries.ts` — `validateDeliverySelection()` (rpc wrapper).
- `src/lib/supabase/types.ts` — `DeliverySelectionErrorCode`, `DeliverySelectionValidationRow`, and the
  function in `Database.public.Functions`.
- `db/tests/delivery_validation.test.sql` — rolled-back SQL test script (see below).
- `tests/delivery-validation.test.ts`, `tests/tsconfig.json`, `package.json` script `test`.

## Decisions to review

- A zone is REQUIRED when the method has `requires_address = true`; otherwise a client could omit the
  zone and get the cheaper method-default fee. Pickup (no address) needs no zone; if one is sent it is
  validated and its fee rule applies.
- Zone minimum order = `delivery_zone_fees.min_order_cents`, combined with the method minimum via
  `greatest()` inside resolve_delivery_fee() (a zone can only raise it). `delivery_zones` has no
  minimum column and none was added.
- Slots: still global (not per zone/method). No slot validation was added; that needs a schema decision.

## Verification status (real)

- RAN and passed: `node --test "tests/**/*.test.ts"` — 14 tests of validation.ts (TS mapper only).
- RAN: `tsc` (v6.0.3, repo strict flags) on validation.ts + types.ts: clean. The test file's only
  errors were missing `@types/node` (not installed here).
- NOT RUN: SQL migration, `db/tests/delivery_validation.test.sql` (no Postgres here), full
  `tsc --noEmit`, `bun run lint`, `bun run format`/Prettier, `bun run build` (no bun, no node_modules,
  network blocked). The SQL was reviewed by reading only.

## First steps with a database / network

1. Apply migration 040000 after 030000. 2. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f
db/tests/delivery_validation.test.sql` (expect "ALL DELIVERY VALIDATION TESTS PASSED"; it rolls back).
2. `bun install && bunx tsc --noEmit && bun run lint && bun run format && bun run test && bun run build`.
   (The test script relies on Node >= 22.18 running .ts directly; `tests/tsconfig.json` needs @types/node.)

## Remaining for 4B.2 / 4C

- 4C: call validate_delivery_selection() from create_order() with the SERVER-computed subtotal, raise
  `error_message` when `is_valid` is false, store zone/method label/fee/`fee_rule` snapshot, pass
  `p_expected_total_cents` against the validated fee, replace create_order()'s own fee/min-order block.
- Address -> zone mapping does not exist (addresses have no zone); decide how the zone is chosen.
- Zone/method-specific slots and capacity enforcement under a per-slot lock (4A note; not invented here).
- Checkout still estimates the fee client-side with the method default (display only) and ignores zones.

---

# Handoff — customer/order architecture phase (CODE COMPLETE, STILL NOT VERIFIED)

## Verification status (read first)

This session ALSO had no package access. `bun` is not installed and the npm registry returns
`403 x-deny-reason: host_not_allowed`, so none of the required checks could run. Real output:

```
$ bun install            -> /bin/sh: 1: bun: not found
$ bunx tsc --noEmit      -> /bin/sh: 1: bunx: not found
$ bun run build          -> /bin/sh: 1: bun: not found
$ bun run lint           -> /bin/sh: 1: bun: not found
$ npm view typescript    -> npm error 403 Forbidden - GET https://registry.npmjs.org/typescript
```

- tsc: NOT RUN. build: NOT RUN. lint: NOT RUN. Prettier: NOT RUN. SQL: NOT EXECUTED.
- `src/routeTree.gen.ts` is STILL the hand-written file. It was read and is internally consistent
  (all three new routes present), but it must be regenerated by the generator, not trusted.
- The only mechanical check done: every new/changed .ts/.tsx file parses (syntax only, TypeScript
  compiler API). That says nothing about types.
- The brief described checkout.tsx as broken and the routes as missing. The repo already contained the
  full checkout rewrite, the three routes, the shared components and the account link from the previous
  session, so this session reviewed them instead of rewriting them.

## First thing to do on a machine with network access

1. `bun install`
2. `bunx tsc --noEmit` — fix everything properly (no `any`, no @ts-ignore).
3. `bun run build` — regenerates `src/routeTree.gen.ts`; confirm it lists `/order-confirmation/$orderId`,
   `/account/orders/` and `/account/orders/$orderId`, then commit the generated file untouched.
4. `bun run format`, review the diff, then `bun run lint` until clean (Prettier width 100).

## Files created (previous session)

- src/lib/idempotency.ts
- src/features/orders/components/order-sections.tsx
- src/routes/_authenticated/order-confirmation.$orderId.tsx
- src/routes/_authenticated/account.orders.index.tsx
- src/routes/_authenticated/account.orders.$orderId.tsx

## Files modified

Previous session: db/migrations/20260930020000_order_integrity_hardening.sql, src/routes/checkout.tsx
(full rewrite), src/routes/_authenticated/account.index.tsx ("Your orders" link), src/routes/cart.tsx,
src/features/auth/auth-provider.tsx (queryClient.clear() on SIGNED_OUT and on user change),
src/features/orders/queries.ts, order-items-list.tsx, order-timeline.tsx, src/features/cart/validation.ts,
src/components/ui-kit/field.tsx (TextArea), src/routeTree.gen.ts (hand-edited).

This session (small, reviewed edits only):

- db/migrations/20260930020000_order_integrity_hardening.sql — browser UPDATE on orders is now limited to
  `status` (was `status, payment_status`); header/comments updated.
- src/lib/supabase/types.ts — orders `Update` is now `Partial<Pick<OrderRow, "status">>`; added missing `;`
  after type aliases; wrapped the long `AddressInsert` alias.
- src/features/cart/cart-provider.tsx, src/lib/env.ts, src/routes/auth.tsx, src/routes/index.tsx —
  bracket access uses double quotes (Prettier); `sameLine` signature wrapped.
- src/features/delivery/queries.ts — long `if` wrapped.
- HANDOFF.md (this file).

## Routes

/checkout (ssr:false, client-side auth guard), /order-confirmation/$orderId, /account/orders,
/account/orders/$orderId (last three under the existing `_authenticated` layout; no new layout, no
duplicate account page).

## Database changes

Apply ALL THREE migrations, once each, in order:

1. 20260930000000_foundation_schema.sql
2. 20260930010000_orders_delivery_admin.sql
3. 20260930020000_order_integrity_hardening.sql

Re-running file 2 after file 3 recreates the old 10-argument create_order() overload next to the new one.

What 020000 does: create_order() gains `p_expected_total_cents` (can only veto, never set an amount),
an advisory lock per (user, idempotency key), merged duplicate lines in stable lock order, stock
decrement under row locks, slot validated against active templates with 60 min lead and 14 day horizon
in Africa/Nairobi, restock trigger on transition into 'cancelled', and column-limited UPDATE on orders.
SQL review (by reading, against the foundation schema column names): no syntax or column-name defects
found. Not executed.

## Complete (written and reviewed by reading, unverified by tools)

Checkout (DB-driven methods/slots/addresses/payment, blockers, fee display-only, idempotency key per
order signature, clear cart only after navigating to confirmation, payment never shown as successful,
slot copy says capacity is not tracked); confirmation, list and detail routes; shared order components;
account link; cache clear on sign-out. Customers only read their own orders (RLS plus `user_id` filter);
items and address are snapshots; order status and payment status are displayed separately.

## Remaining

1. Everything in "First thing to do" above. Type risks to look at first: supabase-js `.select(<long
string>)` results cast with `as OrderRow[]` against the hand-written Database type; `search={{}}` on
   Link to "/"; exactOptionalPropertyTypes on optional props; TanStack Link/navigate typing of new routes.
2. Prettier: many pre-existing files were not formatted. Only clear-cut cases were fixed by hand; over-long
   JSX class strings were left because Prettier cannot break them.
3. Run the SQL in a Supabase project and test: two concurrent orders for the last unit, replayed and
   concurrent idempotency key, past slot, wrong expected total, cancel -> restock, deleted-variant restock.
4. Optional: show validate_cart issues on /cart.

## Known issues / decisions (not fixed)

- Staff can still set order `status` to 'paid' or 'refunded' from the browser. payment_status can no
  longer be set from the browser. Decide before building an admin UI.
- Unpaid awaiting_payment orders never expire; their stock stays reserved until cancelled.
- Orders created before 020000 never decremented stock; cancelling them adds stock. Fine on a fresh DB.
- validate_cart is SECURITY DEFINER and granted to anon; it reveals name/price/stock for inactive
  products by UUID.
- Signing out from the header on a protected page clears the cache but does not redirect.
- Order list is capped at 50 (no pagination). Slot capacity is NOT enforced (UI says so).
- product.in_stock is not updated when stock hits 0; create_order checks stock_quantity, so it is safe.
- Checkout money preview uses VITE_STORE_CURRENCY; orders store currency 'KES'. Keep aligned.

## Rules

Supabase is authoritative. Money is integer cents. Never fake payment success. No M-Pesa/card work.
No redesign. Don't rebuild. Admin UI is out of scope unless asked.

Phase 6E.2 (1A-1C) customer data layer EXISTS, with no UI or routes: parsers in src/features/admin/customers-result.ts, customer-detail-result.ts, customer-status-result.ts, customer-notes-result.ts and customer-parse.ts, list state in customers-management.ts, and query/mutation functions in customers.ts (money stays integer cents, never computed on the frontend).
RPCs used: admin_list_customers(p_search, p_page, p_page_size, p_status), admin_get_customer(p_customer_id), admin_set_customer_status(p_customer_id, p_status, p_reason), admin_update_customer_notes(p_customer_id, p_notes); all admin-only via require_admin() since 6E.1B-3.
SUPERSEDED by 6E.3: create_order() now refuses suspended customers (P0001, DETAIL `account_suspended`); the checkout maps it to a fixed message. (Earlier text: 6E.1 did not block them.)
Phase 6E.2 run 2 (frontend): the /admin/customers list page is wired (debounced search, status filter, URL-held page, loading/empty/error/403 states) from src/routes/_authenticated/admin/customers.index.tsx using customers.ts, customers-management.ts and the components customer-filters.tsx, customer-status-badge.tsx and customers-table.tsx; "Customers" is a live admin nav item.
Routes added: /admin/customers and /admin/customers/$customerId (generated into src/routeTree.gen.ts by the build, never hand-edited).
SUPERSEDED: the detail page is complete (see run 3 below). Suspension is enforced at checkout since 6E.3.
Phase 6E.2 run 3: /admin/customers/$customerId is now the full detail page (profile, addresses, stats, recent orders linking to /admin/orders/$orderId, status control with required-reason confirm dialog, internal notes editor) using customer-detail-management.ts, customer-status-card.tsx and customer-notes-card.tsx; the earlier "placeholder" line is superseded.
The 6E.2 "label only" note was removed in 6E.3 (suspension is enforced). See phase6e2_customer_frontend_report.md (history) and phase6e3_customer_review_report.md (current).

## Phase 6E.3 (customer hardening + review) — STATUS: code complete; browser smoke NOT done

Backend (migration 20261004170000, applied and tested on the real Supabase by the owner): create_order() refuses suspended
customers (P0001, DETAIL `account_suspended`); staff SELECT on customer_notes and admin_audit_log is admin-only; profiles.status
INSERT revoked.
Frontend (Run B): `account_suspended` mapped in place-order-error.ts (`accountSuspended`, fixed message) and shown by checkout.tsx;
"label only" notes removed; notes card says "Only admins can see these"; `status` added to ProfileRow (not insertable) and to the
account profile select; customers.index.tsx search no longer loses typed characters (own-navigation echo is skipped); search
truncation is by code point (`truncateCodePoints`).
Known limitation (by decision, API unchanged): customer notes are last-write-wins, and a remote change to notes_updated_at remounts
the notes card and drops an unsaved draft.
Pre-existing, out of scope (owner-reported): 12 SQL test files fail on a local stub database; unrelated to Phase 6E.
Open: the fixed migration file was not in the Run B upload, so db/migrations/ still holds the Run A copy (replace it with the
owner's applied version). Remaining: browser smoke checklist, and tsc/build/format/lint on a machine that can install packages.
Report: phase6e3_customer_review_report.md.

## Phase 6F.1A (delivery admin backend, methods/zones/zone fees)

- Migration 20261005010000_phase6f1a_delivery_admin_methods_zones.sql: admin-only functions admin_list_delivery_config, admin_save_delivery_zone, admin_set_delivery_zone_active, admin_save_delivery_zone_fee, admin_set_delivery_zone_fee_active, admin_update_delivery_method; every real change writes admin_audit_log; nothing is deleted.
- Applied and tested in the real Supabase SQL Editor. Local stub run: 136 checks passed after fixing the boolean audit text (t/f -> true/false).
- SUPERSEDED by 6F.4: the direct write grants/policies are revoked by 20261005030000 and src/features/delivery/admin.ts is deleted.

## Phase 6F.1B (delivery admin backend, slot templates + per-date overrides)

- Migration 20261005020000_phase6f1b_delivery_admin_slots.sql: admin-only admin_list_delivery_slots, admin_save_delivery_slot_template, admin_set_delivery_slot_template_active, admin_save_delivery_slot_override, admin_clear_delivery_slot_override; every real change writes admin_audit_log; nothing deleted (clear resets the override row to neutral). Override capacity can never go below orders holding that slot/date (capacity_below_booked, checked under the create_order slot lock); closing with bookings is allowed (stops new orders only); template times/weekday are locked while upcoming orders hold the window.
- NOT yet applied to the real Supabase. Local stub-auth run (not real Supabase): all migrations + 6F.1A (136 checks) and 6F.1B (141 checks) tests passed. Guide: phase6f1b_apply_guide.md.
- SUPERSEDED by 6F.4: direct write grants are revoked by 20261005030000; the frontend exists (6F.3).

Phase 6F.2 (delivery admin data layer, frontend only; no UI, routes or migrations): parsers/arg builders delivery-{parse,error,config-result,zone-result,zone-fee-result,method-result,slots-result,slot-template-result,slot-override-result}.ts, UI state in delivery-management.ts and RPC wrappers in delivery.ts (all under src/features/admin/); RPC signatures added to src/lib/supabase/types.ts; tests delivery-_.test.ts and admin-delivery.test.ts (static: delivery.ts calls only the 11 admin___delivery_* RPCs, never a table).
Uses the 6F.1A functions (admin_list_delivery_config, admin_save_delivery_zone, admin_set_delivery_zone_active, admin_save_delivery_zone_fee, admin_set_delivery_zone_fee_active, admin_update_delivery_method) and 6F.1B functions (admin_list_delivery_slots, admin_save_delivery_slot_template, admin_set_delivery_slot_template_active, admin_save_delivery_slot_override, admin_clear_delivery_slot_override); money is whole cents typed digits-only and never computed; 6F.1B is still not applied to the real Supabase, and src/features/delivery/admin.ts plus the direct write grants were removed in 6F.4.
Checks: tsc (src and tests projects), prettier, eslint and npm test pass; bun install FAILED (lockfile points at a private registry, 403), so checks ran on an npm install of the same package.json; build and browser smoke NOT RUN.

Phase 6F.3A (/admin/delivery page part 1, frontend only; no migrations or backend changes): the "Delivery" nav item is live (Operations group) and /admin/delivery has Methods, Zones, Fees and an intentionally empty Slots tab (6F.3B); lists, edit dialogs, and on/off with a required reason (methods, zones, fee rules) call only the 6F.2 wrappers, with a no-active-zones warning, loading/empty/error/403 states and double-submit guards. Shillings typed by the admin become integer cents only in src/features/admin/delivery-money.ts (tests/delivery-money.test.ts); display uses formatMoney; the 6F.2 draft fields (feeCents etc.) were renamed fee/freeOver/minOrder/baseFee and tabs are now methods|zones|fees|slots.
New files: delivery-money.ts, src/hooks/use-delivery-action.ts, components delivery-{form-parts,methods-panel,zones-panel,fees-panel}.tsx and route delivery.index.tsx; routeTree.gen.ts regenerated by the build, never hand-edited.
Checks: bun install FAILED (403 from the private registry in bun.lock; npm install of the same package.json used instead), tsc (src and tests), bun run build, prettier, eslint (0 errors; 10 existing warnings) and npm test (444) pass; browser smoke NOT RUN; 6F.1B is still not applied to the real Supabase.

Phase 6F.3B (/admin/delivery Slots tab, frontend only; no migrations or backend changes): the Slots tab now has the template list (create, edit, activate/deactivate with reason), a date-range view (default next 14 days, Previous / Today / Next, range kept in the URL) from admin_list_delivery_slots with capacity, booked count, closed flag and overrides, a per-date override dialog (capacity or close, booked count and below-booked rule shown) and "Clear" with a required reason; loading/empty/error/retry/403 states and the double-submit guard come from the 6F.3A hook; no error code was missing from the mapper, so it is unchanged.
New files: delivery-slots-view.ts (pure helpers, tests/delivery-slots-view.test.ts), components delivery-slots-panel.tsx, delivery-slot-templates.tsx, delivery-slot-override-dialog.tsx; delivery.index.tsx wires the tab. Past dates and inactive slots cannot be overridden from the UI (the database also refuses); 6F.1B is still not applied to the real Supabase.
Checks: see the 6F.3B reply for exactly what was run; browser smoke NOT RUN.

## Phase 6F.4 (delivery review + lockdown) - STATUS: code complete, NOT applied, SQL NOT RUN

New migration 20261005030000_phase6f4_delivery_lockdown.sql (one transaction, preconditions, refuse-to-run-twice, self-check): drops INSERT/UPDATE/DELETE policies and revokes INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER (table and column) from public/anon/authenticated on delivery_methods, delivery_zones, delivery_zone_fees, delivery_slot_templates, delivery_slot_overrides; SELECT behaviour is snapshot-compared and unchanged. SQL test db/tests/phase6f4_delivery_lockdown.test.sql; apply guide phase6f4_apply_guide.md; report and findings table phase6f4_delivery_review_report.md. src/features/delivery/admin.ts deleted (no importer); earlier tests (5B.2, 6F.1A, 6F.1B, and the seven "exactly fifteen admin functions" files) edited to match the final state; fee-rule minimum-order hint corrected (the zone minimum can only raise the method minimum).
Phase 6F is NOT fully complete. Remaining: apply 6F.1B, then 6F.4, to the real Supabase (guides phase6f1b_apply_guide.md, phase6f4_apply_guide.md) and run their SQL tests; run ALL SQL tests and the two concurrency scripts on a real or local Postgres; on a machine that can install packages run bun install, bun run build, bunx tsc --noEmit, bun run format, bun run lint (the last four were NOT RUN in 6F.3B and 6F.4); browser smoke checklist in the 6F.4 report. Known unfixed low items: template window-change check is not under the slot lock (report #7), duplicate-window templates share bookings (#8), long reasons can be truncated in audit text (#9).
Checks in 6F.4: npm test 452/452 pass; everything else NOT RUN (no Postgres, no package registry access).

## Verification pass 2026-10-09 (real output, npm instead of bun; no Postgres/Supabase in this environment)

Ran with `npm ci` (lockfile: package-lock.json; bun was not installed).

- `npx tsc --noEmit`: exit 0, 0 errors. `npx tsc -p tests/tsconfig.json --noEmit`: exit 0.
- `npm test`: 727 tests, 727 pass, 0 fail, 0 skipped (196 suites).
- `npm run build`: exit 0 (client, SSR and nitro builds all succeeded).
  `src/routeTree.gen.ts` was regenerated by the router plugin and kept. It contains
  `/order-confirmation/$orderId`, `/account/orders/` and `/account/orders/$orderId`.
- `npx prettier --write .`: reformatted 181 files in src, 46 in tests, 3 in scripts; db/ untouched
  (SQL is not formatted by Prettier). Added `.prettierignore` (generated route tree, build output,
  lockfiles) so `prettier --check .` passes after every build.
- `npx eslint .`: exit 0, 0 errors, 10 warnings (all `react-refresh/only-export-components` in
  shadcn ui files and the auth/cart providers; pre-existing pattern, left as is).

Not done (needs a database or a decision):

- No migration or SQL/concurrency test was executed (no PostgreSQL available). Phase 8 migration
  `20261009010000_phase8_discounts_promotions.sql` is still unapplied; follow phase8_apply_guide.md.
- "Known issues" above (unpaid reservation expiry, staff status writes, validate_cart exposure,
  sign-out redirect) were not changed.
- No browser smoke test.

## Phase 8 close-out (2026-10-09)

- New migration `db/migrations/20261009020000_phase8_validate_coupon_total.sql` (20261009010000 untouched): `validate_coupon()` gains
  `p_delivery_method` / `p_zone_id` and returns `delivery_fee_cents` + `total_cents` (subtotal + fee - discount, priced in the database)
  when the delivery selection is valid; otherwise those keys are absent. Not applied anywhere.
- Checkout no longer computes a total: it shows and sends `totals.totalCents` from the preview (`totalAfterDiscountCents` was removed).
  Submit is blocked while that total is unknown. Remaining client arithmetic: `quote.totalCents` in `src/features/delivery/checkout.ts`
  (cart subtotal + quoted fee) is no longer used by checkout but still exists; the cart subtotal itself is still client-priced for display.
- New SQL test `db/tests/phase8_validate_coupon_total.test.sql` (rolled back); added to `scripts/integration/run-sql-tests.sh`.
  Neither the migration nor the SQL test has been executed.
- Removed sandbox junk from the upload (`.config/uv`, `.local/bin/uv*`). There was no `.npmrc`.

## Phase 9A (catalog integrity) - STATUS: applied and tested by the owner

Migration `db/migrations/20261009030000_phase9a_catalog_integrity.sql` (SQL test `db/tests/phase9a_catalog_integrity.test.sql`, static test
`tests/phase9a-catalog-integrity-migration.test.ts`). There is no separate 9A report; this entry is it.

- `products_sku_key` and `product_variants_sku_key` were rebuilt under the SAME names as unique indexes on `lower(sku)` (where sku is not null), so
  `ABC-1` and `abc-1` can no longer both exist. Names kept on purpose: the admin writers map a duplicate to 23505 / `sku_taken` by index name.
- Added `order_items_product_id_idx` and `order_items_variant_id_idx` (partial, where not null) for the two `on delete set null` foreign keys.
- Not touched, owner decision: `compare_at_price_cents` stays `>= price_cents` (equality accepted).
- Not done (needs a decision or a table): a brands table, a product_images table. The per-product low-stock threshold was left for 9B.
- The 9A static test now asserts "last phase9a migration" instead of "newest migration", so later phases do not break it.

## Phase 9B (inventory movements + low-stock) - STATUS: APPLIED to the owner's Supabase project; its SQL test passed there (as reported by the owner)

Status update (2026-10-10): the owner applied `20261009040000_phase9b_inventory_movements.sql` to the project and ran `phase9b_inventory_movements.test.sql` there, which passed. That is the
owner's report; it was not re-verified from here. The migration refuses a second run, so it must NOT be applied again. The SQL test is a single script with no psql-only features, so it runs in the
Supabase SQL Editor (paste and run; success = no error, the editor shows no notices) and in psql (`psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f db/tests/phase9b_inventory_movements.test.sql`);
it rolls everything back. Live effect: every real order now writes a ledger row (kind `stock_change`, see "honest limit" below). Phase 9C (below) labels those rows in the admin history.

Migration `db/migrations/20261009040000_phase9b_inventory_movements.sql` (one transaction; precondition; refuses to run twice; self-check). SQL test
`db/tests/phase9b_inventory_movements.test.sql` (rolled back, fixtures `t9b-`, 61 PASS lines). Static test `tests/phase9b-inventory-movements-migration.test.ts`.
Runner: `phase9b_inventory_movements` added to `scripts/integration/run-sql-tests.sh`. No new table; `create_order()` and `restock_cancelled_order()` untouched
(the self-check hashes every other function).

What it does

- `public.inventory_adjustments` (the existing ledger) gains `order_id uuid null -> orders(id) ON DELETE RESTRICT` and `movement_kind text not null default 'admin_adjustment'`
  with a CHECK (`admin_adjustment | order_restock | order_reactivation | stock_change`; `order_id` only on the two order kinds). Every pre-existing row stays valid as `admin_adjustment`.
- ONE ledger row per stock change, from AFTER UPDATE OF stock_quantity triggers (WHEN old is distinct from new) on `products` and `product_variants`
  (`inventory_log_stock_change()`). Rows carry previous / delta / new, the actor (`auth.uid()` if it is a real auth user, else NULL) and a kind.
- INSERT with stock > 0 is NOT logged (decision): a new row is an opening balance, not a movement, so ledger sum = current stock - opening balance. In the app every stock above 0
  arrives through `admin_adjust_inventory()` (new products start at 0), which IS logged. To record an opening balance on purpose, insert the row with stock 0 and adjust it.
- Double-write trap: `admin_adjust_inventory()` is redefined with EXACTLY two added statements (a transaction-local `set_config('app.inventory_ledger_skip', '<table>:<id>', true)` before its stock UPDATE
  and a clear right after). The trigger skips only the unit named in the flag, so the function keeps its own richer row (reason, note, actor) and no second row appears. Chosen over
  "trigger skips rows already written" because the function UPDATEs first and INSERTs after (no row exists yet at trigger time). Its ledger insert, audit insert, arguments, return value,
  lock order, errors and grants are unchanged; `phase6c2_inventory_history_api.test.sql` G18 pins the new md5 AND proves the body equals the 6I.2 body once the two additions are stripped.
- `low_stock_threshold integer null` (CHECK null or 0..1000) on `products` and `product_variants`, plus a partial index on each (`where low_stock_threshold is not null and stock_quantity <= low_stock_threshold`).
  NULL = today's behaviour (the caller-supplied threshold, default 10). NO dashboard / inventory function reads the column yet; wiring one is a later, separate step.
- Append-only ledger: BEFORE UPDATE OR DELETE row trigger + BEFORE TRUNCATE trigger (`inventory_adjustments_guard()`), and UPDATE / DELETE / TRUNCATE revoked from `service_role` too
  (browser roles already held nothing). The ONE allowed UPDATE is `changed_by <uuid> -> NULL` with every other column unchanged: that is what `ON DELETE SET NULL` on `auth.users` does, so deleting
  an auth user still works (tested).

The honest limit on `order_id` (`create_order()` is pinned)

- Order PLACEMENT deducts stock before the order row exists, and the trigger cannot learn the id without changing `create_order()`. Those rows are `movement_kind = 'stock_change'`,
  `order_id NULL`, reason "Stock changed outside the admin tool (order placement, or a direct change)". They are NOT distinguishable from a direct SQL change of stock. Nothing is guessed.
- Cancel / reactivation IS attributed: `orders_inventory_ctx_set` (BEFORE UPDATE OF status, sorts before `orders_restock_on_cancel`) publishes the order id in a transaction-local setting and
  `orders_inventory_ctx_clear` (AFTER UPDATE OF status) clears it. Positive = `order_restock`, negative = `order_reactivation`. Closing the placement gap later needs `create_order()` to set the
  same context, a deliberate change to the pinned function. If an orders UPDATE were ever cancelled by another BEFORE trigger returning NULL, the context would stay until the transaction ends.

Consequences to know

- An order that has ledger rows with an `order_id` can no longer be hard-deleted (RESTRICT). A product or variant with ledger rows could not be deleted before either.
- Scripts that `TRUNCATE ... CASCADE` through `products` now fail on the ledger. Delete fixtures inside a rolled-back transaction instead.
- The append-only guard is a trigger plus privileges; a superuser / table owner can still disable triggers or use `session_replication_role = replica`.
- `low_stock_threshold` is readable wherever `products` / `product_variants` are (the public catalogue already exposes `stock_quantity`); browser roles cannot write it (self-check proves it).

Extension point (NOT built): `location_id` / `supplier_id`. There is no warehouse or supplier table, so a bare uuid would have no foreign key. When those tables exist, add the nullable columns
WITH their foreign keys in that migration; `inventory_log_stock_change()` is the one place that fills them.

Older tests updated for the new state (exact allow-lists only; no assertion weakened): `phase6c1a2`, `phase6c1b1`, `phase6c1b2` (FUNCS + TRIGGERS lists), `phase6c2_inventory_read_foundation`
(FUNCS; "no threshold column" now expects exactly the two `low_stock_threshold` columns), `phase6c2_inventory_adjustment_history` (A2 A4 A5 A6 E1 E2 E3), `phase6c2_admin_inventory_adjustment` (F12 F13),
`phase6c2_inventory_concurrency_final` (G12 H4 I1 I2; G12 now asserts service_role has NO UPDATE / DELETE / TRUNCATE), `phase6c2_inventory_history_api` (G12 G15 G18; its fixture back-dates ledger rows with an
UPDATE, so it switches the guard off for that one statement as table owner inside its rolled-back transaction and back on).

Verification (2026-10-10, local PostgreSQL 16 built from migrations 20260930000000..20261009030000 with minimal Supabase stubs: roles anon / authenticated / service_role, an `auth.users` table, `auth.uid()`)

- 9B migration applied cleanly; running it a second time is refused ("appears to be applied already").
- `phase9b_inventory_movements.test.sql`: 61 PASS, 0 FAIL. A mutation check (skip flag removed) makes A1 fail, so the double-write test is real.
- Whole SQL suite compared on a 9A database vs a 9A+9B database with failures downgraded to notices: no failing assertion exists only on the 9B database.
- 14 older SQL test files still fail in that local setup on BOTH databases (identical failures before 9B). Observed: "exactly the fifteen known admin functions" assertions (H1, G1 and the like), and
  `permission denied` errors in delivery / order tests. The causes were NOT investigated. They are not caused by 9B and were not changed. Whether they also fail on the owner's real Supabase is
  unknown; the local stubs may differ from it.
- At that point NOT RUN: the concurrency scripts, any browser smoke, anything against the owner's real Supabase. Since then see "Phase 9C" below (concurrency scripts fixed and run locally).

## Phase 9C (inventory history labels) + concurrency script cleanup - STATUS: written and verified LOCALLY ONLY; migration NOT applied to the owner's project

Verified on a local PostgreSQL 16 built from all 51 migrations (through 9B, then 9C) with minimal Supabase stubs (roles, `auth.users`, `auth.uid()`). NOT run against the owner's real Supabase,
and no browser smoke was done.

1. Concurrency script cleanup (9B made the ledger append-only and its FKs RESTRICT, so `delete from products` / `delete from inventory_adjustments` are refused, and the old purge ran every delete in ONE
   `ON_ERROR_STOP` psql session with output discarded: the first refusal silently skipped the rest, leaving fixtures and breaking the next run on a duplicate key; reproduced).
   Fixed: `create_order_concurrency.sh`, `phase8_coupon_concurrency.sh`, `phase6c2_inventory_concurrency_final.sh`, sharing `db/tests/lib/concurrency_cleanup.sh`.
   - Each cleanup step is its own psql call; failures print `CLEANUP FAILED: ...` and make the script exit non-zero even if every check passed. An unremovable leftover from an earlier run aborts the start.
   - A fixture product / variant the ledger references is RETAINED (deactivated) and re-used by the next run (upsert with a stock reset). The ledger is never touched (no delete, no trigger disabled,
     no `session_replication_role`). Repeated runs leave the SAME inert rows (create_order: 1 product `co-cc2-p`; coupon: 1 product `p8cc-p`; inventory: about 9 products / 6 variants named `cx6c2-*`),
     plus ledger rows that can never be removed. Deleting the fixture auth users is still fine (`changed_by -> NULL` is the one allowed ledger change).
   - The inventory script's ledger assertions now count only THIS run's `admin_adjustment` rows (`created_at >= run start`), because retained units carry rows from earlier runs.
   - The coupon script's purge disabled `orders_guard_discount_snapshot` and could have left it OFF if a delete failed; it now runs in one transaction (the disable rolls back with it) and the script
     checks the trigger is enabled afterwards.
   - `delivery_slot_concurrency.sh` and `order_reactivation_concurrency.sh` were NOT changed: they create no stock movement, still use the old silent purge, and pass twice in a row under 9B.
   - Local result: `run-sql-tests.sh --with-concurrency`: all five concurrency scripts PASS, each of the three fixed ones twice in a row (reruns work), no fixture left apart from the retained inert units.

2. Phase 9C migration `db/migrations/20261010010000_phase9c_inventory_history_movement_labels.sql` (new file; 9B is untouched): replaces ONLY `admin_list_inventory_adjustments(...)` (same signature,
   STABLE, SECURITY DEFINER, pinned search_path, `require_admin()` first, EXECUTE for `authenticated` only). It now also returns `movement_kind` and `order_id` per row.
   - Privacy: `changed_by` is returned only for `admin_adjustment` rows and for actors who hold a staff / admin role in `user_roles`; otherwise NULL, so a customer's id (stored on order-placement rows) is
     never returned. The `p_changed_by` filter uses the same masked value. Only `order_id` is returned about orders; the body must not read orders / profiles / addresses / auth.users (self-check).
   - No ledger, trigger, constraint, index, grant, policy or other function change; stored reason text of old rows is not rewritten. Self-check hashes everything else and the stock / ledger data.
   - Re-runnable (CREATE OR REPLACE); refuses to run without 9B.
   - SQL test `db/tests/phase9c_inventory_history_movement_labels.test.sql` (33 checks, rolled back, fixtures `t9c-`, runs in the Editor and psql like the 9B test); added to `run-sql-tests.sh`. Locally: passes
     on a 9B+9C database, FAILS on a 9B-only database (K2) and fails when the masking is removed (L5), so it can detect what it claims.
   - Frontend: `types.ts` (`InventoryMovementKind`, `movement_kind` / `order_id` on the row), `inventory-result.ts` (rows from a database without 9C parse as kind null, never guessed),
     `inventory-management.ts` (`describeMovement`, `formatMovementActor`, `movementOrderReference`), `inventory-history-panel.tsx` (new Movement column: label, plus a link `Order XXXXXXXX` to the
     admin order page for cancel / reactivate rows, "Order not recorded" if an order kind has no id, nothing if the kind is unknown). Order placement shows as "Order or direct change" because the
     database cannot tell them apart. A null actor on a non-admin row shows "Customer or system" (not "Unknown (account removed)"); a staff / admin actor on an order row shows "Team member xxxxxxxx".
     Unit tests added to `tests/admin-inventory.test.ts`; `npm test` 761 pass, `tsc --noEmit` and eslint clean on the touched files. The new frontend works before the migration is applied (no labels yet).

How to apply 9C (owner): (a) Supabase SQL Editor: paste the whole 9C migration file and run it once (a failed self-check rolls everything back); (b) paste `phase9c_inventory_history_movement_labels.test.sql`
and run it (success = no error); (c) deploy the frontend and open Admin > Inventory > History; (d) optional on a DEV database only: `DATABASE_URL=... scripts/integration/run-sql-tests.sh --with-concurrency`.

Open items

- 9C migration not yet applied to the owner's project; apply, run its test, and look at the History tab (not done by me).
- Concurrency scripts only run locally; run `--with-concurrency` once on the owner's dev database. They COMMIT rows, so never on production.
- 14 older SQL test files fail in the local stub setup, identically before and after 9B / 9C (stale exact "known admin functions" lists, and `permission denied` from the stub's missing table grants).
  Causes not investigated here; unknown whether they fail on the real Supabase.
- Order PLACEMENT is still logged as `stock_change` with no order id (needs a deliberate change to the pinned `create_order()`); the label says so rather than guessing.
- `low_stock_threshold` (9B) is still read by no function or screen.
- Old ledger rows keep their stored reason text ("Stock changed outside the admin tool ..."); only the new Movement column interprets them.
- Retained inert fixture products from the concurrency scripts will show in the admin product list of a dev database (inactive).
- No browser smoke of the History tab; an `order_id` link was typed against the route tree but not clicked.

# PHASE 12 — PRODUCT DISCOVERY (branch `phase-12-product-discovery`, based on Phase 11)

Status: code written, 859/859 unit tests pass. NOT verified: app type-check, eslint, prettier, build, dev server, any browser, real database (sandbox had no network and an empty npm cache). Full detail: `phase12_product_discovery_report.md`.

What it does: client-side tolerant search with suggestions, filters (in stock, offer, brand, price in whole units) with chips, sort, category tree with subtree listings, variants on the product page (`?variant=`), "Choose options" on cards, sticky mobile buy bar, recently viewed (device-only), editable quantity (product page and cart).

Files: new `src/features/catalog/{discovery,product-detail,category-tree,recently-viewed,use-recently-viewed,use-document-title}.ts`; new components `active-filters`, `filter-controls`, `recently-viewed-shelf`, `sticky-buy-bar`, `variant-selector`; changed `catalog-section`, `catalog-toolbar`, `product-card`, `product-shelf`, `category-rail`, `search-box`, `quantity-stepper`, `queries.ts`, routes `index`, `category.$slug`, `product.$slug`, `cart` (one line); tests `storefront-discovery`, `storefront-product-detail`. Nothing in `db/`, server functions, payments, checkout, auth, admin or notifications changed; no dependency, table, RPC or secret added.

Inventory rule (mirrors `create_order()`): plain product needs `in_stock` and stock > 0; variant needs `is_active` and stock > 0 (no `in_stock` flag). A card offers quick-add only after `variantSummaryQuery` succeeded; otherwise "View product". That query is paged with an exact count and throws rather than return a partial list. A fake fixture server must return `Content-Range` for it.

How to run and check: `npm ci && npm test && npx tsc --noEmit && npx tsc -p tests/tsconfig.json && npx eslint . && npx prettier --write <touched files>`; then `npm run dev` and walk `phase12_manual_qa_checklist.md`. If `?variant=` changed route types, let the dev server regenerate `src/routeTree.gen.ts`; do not hand-edit it.

Open items
- Run the commands above on a machine with network; fix whatever tsc/eslint/prettier report in the `.tsx` files.
- Look at the UI at 360/768/1280 px (never seen by the developer), including the filters sheet and the cart's editable stepper.
- Price filter/sort and "On offer" use the product's own price, while variants cards show "From <cheapest>".
- When the variant summary fails, filters fall back to product-row stock with no notice.
- Search suggestions and related/recently-viewed ordering judge stock from the product row only.
- Wishlist deferred to an account-linked backend phase. Backend work listed in the report (server-side search/sort/paging, public promotions read, variant availability in the list read, soft-404 status codes).

# PHASE 13 — CART & CHECKOUT POLISH (branch `phase-13-cart-checkout`, based on Phase 12)

Status: code written, 899/899 unit tests pass (859 + 40 new). NOT verified: eslint, prettier, build, dev server, any browser, real database, real M-Pesa. `npm ci` failed (no network); the global `tsc --noEmit` shows one environmental error only (missing `vite/client` types). Full detail: `phase13_cart_checkout_report.md`.

What it does: cart line badges from `validate_cart`, stock-aware quantity with an explanation, undo on remove, labelled subtotal; checkout summary shows the `validate_coupon` subtotal, fee and total (no client multiplication); an M-Pesa panel (phone, waiting with visible timeout, failed / cancelled / expired retry, paid only from server status) on the confirmation and order pages; confirmation "What happens next" and orders link.

Files: new `src/features/cart/line-state.ts`, `src/features/payments/mpesa-payment-state.ts`, `src/features/payments/components/mpesa-payment-panel.tsx`, `src/features/orders/next-step.ts`, tests `cart-line-state`, `mpesa-payment-state`, `order-next-step`. Changed `cart.tsx`, `checkout.tsx`, both order routes (mount panel), `cart-provider.tsx` (`restore`), `quantity-stepper.tsx` (`onClamp`), `payment-providers.ts` (one M-Pesa note). Nothing in `db/`, server functions, payment server code, auth, admin or notifications; no dependency, table, RPC or secret added.

How to run and check: `npm ci && npm test && npx tsc --noEmit && npx tsc -p tests/tsconfig.json && npx eslint . && npx prettier --write <touched files>`; then `npm run dev` and walk `phase13_manual_qa_checklist.md` (includes a failed and a timed-out M-Pesa payment).

Open items
- Run the commands above on a machine with network; fix what tsc/eslint/prettier report in the `.tsx` files.
- Look at cart, checkout and the M-Pesa panel at 360/768/1280 px (never seen).
- No public flag for "M-Pesa is configured" (needs a new env, your decision); the checkout badge still says "Not connected yet".
- No function to change the payment method of an existing order; the panel offers only "Try again".
- Checkout still sends the basket's local subtotal to the delivery quote (method text and gating only; charges are re-priced by the database). Needs a quote that takes items.
- Backend gaps: per-line totals and a guest subtotal from `validate_cart`.
- Wording not checked against the Daraja documentation (no network).


# PHASE 14 — ACCOUNT & ORDERS POLISH (branch `phase-14-account-orders`, based on Phase 13)

Status: code written, 933/933 unit tests pass (899 + 34 new). NOT verified: app tsc, eslint, build, dev server, any browser, real database. `npm ci` failed (egress proxy 403 for registry.npmjs.org), so `.tsx` files were only syntax-parsed. Full detail: `phase14_account_orders_report.md`.

What it does: orders list filter (display only), order detail with next-step sentence, a timeline built only from recorded `order_status_history` rows (customer wording, cancelled/refunded as end states, payment changes marked separately, no ETA/rider/location), **Buy again** (re-checks each snapshot item with `validate_cart` via `cartValidationQuery`, adds only what the database says is available at the database price, reports added / fewer / price changed / unavailable / skipped, never places an order), inline field errors with focus on the first error and a double-submit guard on profile and address forms, inline delete confirmation, friendly error states, 44 px targets.

Files: new `src/features/orders/{timeline,reorder,order-filters}.ts`, `src/features/orders/components/reorder-panel.tsx`, `src/features/account/form-validation.ts`, tests `order-timeline`, `order-reorder`, `order-filters`, `account-form-validation`. Changed `order-timeline.tsx`, routes `account.index`, `account.orders.index`, `account.orders.$orderId`, `address-form.tsx`, `ui-kit/field.tsx` (optional `error` prop). Formatting-only: `quantity-stepper.tsx`, `cart-provider.tsx`, `line-state.ts`, two tests. Nothing in `db/`, server functions, payments, auth/MFA, admin or notifications; no dependency, table, column, RPC or env var added (`git diff --stat` proof in the report).

How to run and check: `npm ci && npm test && npx tsc --noEmit && npx tsc -p tests/tsconfig.json && npx eslint . && npx prettier --check .`; then `npm run dev` and walk `phase14_manual_qa_checklist.md` (includes Buy again with an unavailable item and another customer's order link).

Open items
- Run the commands above with network; fix what tsc/eslint report in the new/edited `.tsx` files (most likely spots: `fetchQuery` spread in `reorder-panel.tsx`, spread props in `address-form.tsx`).
- Look at list, detail, timeline, Buy again result and addresses at 360/768/1280 px (never seen).
- Decide whether customers should see `order_status_history.note` (shown as recorded, as before).
- Reorder checks the order's quantity, not basket + order; under-stocked lines carry the old price until the basket re-validates.
- The list filter only sees the 50 newest orders.
- Three payment-area Phase 12–13 files still fail prettier (`mpesa-payment-panel.tsx`, `mpesa-payment-state.ts`, `tests/mpesa-payment-state.test.ts`); left untouched by rule.
- Backend gaps: live delivery tracking, a customer-safe history note, server-side order filter/paging, current price from `validate_cart` for under-stocked lines.


# PHASE 15 — ADMIN UI POLISH (branch `phase-15-admin-ui`, based on Phase 14)

Status: code written and committed; 965/965 unit tests pass (933 + 32 new); app `tsc` 0 errors; `eslint` unchanged from baseline (42 prettier errors in payment files + 10 old warnings); `vite build` passes. Seen in a real browser (Chromium, 360/768/1280 px) **only against a mock backend I wrote in /tmp** (not in the repo). NOT verified: anything against a real Supabase project (RLS, real RPCs, real MFA, real data). `npm ci` worked this time. Full detail: `phase15_admin_ui_report.md`.

What it does: one shared admin error component (config / no-access / offline / failed) replaces 12 copies; shell gets skip link, offline banner, 44 px targets, staff-aware denial with sign-out; new read-only **Payments** list, **Promotions** (list, create inactive by default, activate/deactivate with confirmation) and **Reports** ("not available yet") screens; dashboard now shows the as-of time, order value (labelled *not revenue*), payments, delivery and catalogue figures straight from the summary; focus to first error on product, stock-adjust and promotion forms; admin-only fail-fast network mode (offline reads show an offline state, actions never queue); note on the Inventory Low/Out views that the status is a screen-side rule.

Files: new `src/features/admin/{admin-ui,payments}.ts`, `src/features/promotions/{admin-form,admin-queries}.ts`, `src/components/admin/{admin-states.tsx,focus-first-error.ts,use-admin-network-mode.ts,promotion-create-form.tsx}`, routes `admin/{payments,promotions,reports}.index.tsx`, tests `admin-ui`, `promotion-form`. Changed: `admin-shell.tsx`, `nav.ts`, `tests/admin-nav.test.ts` (expected lists updated, still exact), `styles.css` (one rule scoped to `body.admin-active`), 10 admin routes + 2 panels (error branch only), product create/edit and stock-adjust forms (focus only), dashboard and inventory routes, `routeTree.gen.ts` (regenerated by the build). Nothing in `db/`, payment code, auth/MFA, notifications or storefront routes (`git diff --stat 9df7999 HEAD` on those paths is empty); no dependency, table, column, RPC or env var added.

How to run and check: `npm ci && npm test && npx tsc --noEmit && npx eslint . && npx vite build`; then `npm run dev` against a real project and walk `phase15_manual_qa_checklist.md` (non-staff URL, staff without permission, refused action, double-click on each action).

Open items
- First real-database pass: customer, staff, MFA admin.
- Offline *navigation* sends the user to /auth (the `_authenticated` guard treats a failed `getUser()` as signed out). Auth logic, not touched.
- `tests/admin-nav.test.ts` expectations were updated for the new routes; please confirm.
- Promotions are created inactive unless "Make it live now" is ticked; confirm the default.
- Not built though the backend exists: promotion edit, payment detail, payments filters by provider/date/order.
- Focus-to-first-error not added to delivery forms, customer notes, variants card.
- Contrast not measured; 768/1280 screenshots measured but not viewed; several screens never looked at (orders, products, inventory, customers, delivery, audit log).
- Missing backend: report read; per-row stock status / low-stock filter; `mfa_required` distinguishable from `not_authorised`; dashboard date range.
- Three payment-area files and several older Markdown docs still fail `prettier --check`; left untouched by rule.



# PHASE 16 — MOBILE & RESPONSIVE PASS (branch `phase-16-responsive`, based on Phase 15)

Status: code written and committed; **code-reviewed only, never seen in a browser** (none available in the sandbox). 965/965 unit tests pass (no new tests; CSS/markup only); app `tsc` 0 errors; `eslint` clean on touched files (2 old `react-refresh` warnings in the two `button.tsx` files); `prettier` clean on touched files; `vite build` passes and the new Tailwind variants appear in the built CSS. Full detail: `phase16_responsive_report.md`.

What it does: class-only fixes, mostly in shared components so they reach every page. 44px targets on phones and touch devices for both button kits, shadcn Select/Tabs, checkbox/radio/switch (invisible hit area), dialog and sheet close buttons; 16px text in inputs, textareas and native selects (no iOS zoom; 14px only for a mouse at 768px+); dialogs and sheets capped at the visible viewport and scrolling inside; `grid-cols-1` base on 23 files' responsive grids so one wide child cannot widen the column; `minmax(0,1fr)` on two definition-list grids; long product names wrap; `dvh` in place of `vh` in the admin shell, MFA screens and root.

Files: 45 changed, listed in `git diff --name-only phase-15-admin-ui..phase-16-responsive`. New: `phase16_responsive_report.md`, `phase16_manual_qa_checklist.md`. Nothing in `db/`, server functions, payments, auth/MFA, checkout totals, queries, routes or dependencies; `routeTree.gen.ts` untouched.

How to run and check: `npm ci && npm test && npx tsc --noEmit && npx eslint . && npx vite build`; then `npm run dev` and walk `phase16_manual_qa_checklist.md` at 360, 390, 768 and 1280 px.

Open items
- First real look at every screen; several were never opened (admin delivery forms, order-detail actions, customer notes, variants card, audit-log filters, most of checkout, account address list).
- `viewport-fit=cover` not set, so safe-area insets are 0 in iPhone browsers; adding it needs header/side padding.
- `overflow-x: clip` on `html, body` masks sideways overflow; look for cut-off content.
- Inline ghost/link buttons grow to 44px on phones; check dense admin rows by eye.
- Pre-existing and untouched: three payment files and older Markdown docs still fail `prettier --check`.


# PHASE 17 — UX POLISH PASS (branch `phase-17-ux-polish`, based on Phase 16)

Status: code written and committed; **code-reviewed only**. The sandbox had no network, so dependencies could not be installed: `tsc`, `eslint`, `prettier`, `npm test`, `vite build` and a browser were NOT run. Only a syntax-only parse of the changed files was done. Full detail: `phase17_ux_polish_report.md`; QA: `phase17_manual_qa_checklist.md`.

What it does (class and small logic changes, shared components first): static skeletons under reduced motion; press feedback and 150 ms colour/transform transitions on buttons, chips, cards and nav links; toasts capped at 3 and lifted above the sticky buy bar on phones; plain-words error states (no raw error text, no codes, `role="alert"`) including address and profile save; `aria-busy` on customer skeletons; image attributes; focus-to-first-invalid on all admin delivery forms, the variants card and customer notes (closes the Phase 15/16 open item); focus to the page heading after each route change.

Nothing in `db/`, server functions, payments, auth/MFA, checkout totals, queries or keys, routes or dependencies; `routeTree.gen.ts` untouched.

Open items
- Run `npm ci && npx prettier --write <changed files> && npx eslint . && npx tsc --noEmit && npm test && npx vite build`.
- Browser pass per `phase17_manual_qa_checklist.md`; check the heading focus ring after navigation and the phone toast offset.
- Not reviewed: skeleton heights vs final layouts, offline variants on every admin list, promo-apply pending state, checkout internals.


# PHASE 18 — FINAL UI AUDIT (branch `phase-18-final-audit`, based on Phase 17)

Status: **code-reviewed only.** `npm ci` failed (registry unreachable), so `tsc`, `eslint`, `prettier`, `npm test`, `vite build` and a browser were NOT run. Only a syntax-only parse of the 6 changed files was done (all parse). Detail: `phase18_final_audit_report.md`; QA: `phase18_manual_qa_checklist.md`.

Changed (8 small fixes): coupon box pending status, focus handoff and `text-danger` (`coupon-input.tsx`); plain address-action errors (`account.index.tsx`); "Waiting for payment" badge label (`status.ts`); toast lift only on product pages (`__root.tsx`, `sonner.tsx`); MFA factor date via `formatDateTime`; no focus ring on script-focused headings (`styles.css`). Nothing in `db/`, server functions, payments, auth/MFA, checkout totals, queries or keys, routes or dependencies; `routeTree.gen.ts` untouched.

Open items: see "Not fixed" and "Needs follow-up" in the report (viewport-fit=cover, overflow-x clip, contrast, payment panels, admin forms never opened, two Button systems and an undefined `destructive` token).

Release checklist (none of this has been done)
- `npm ci && npx prettier --write <changed files> && npx eslint . && npx tsc --noEmit && npm test`
- `npx vite build` (detached, with a log file; can take 5+ minutes)
- Confirm the "Waiting for payment" label change is acceptable for admin screens and any email/notification text
- Walk `phase18_manual_qa_checklist.md` at 360, 768 and 1280 px; reduced motion on and off; keyboard only
- Measure contrast with a tool (badges, disabled, muted text); check offline on each admin list
- Owner: apply status of Phase 8 migrations, 6F.1B and 6F.4 is still "unknown, ask owner"


# PHASE 19 — RECORD CASH PAYMENT FOR COD ORDERS (branch `phase-19-cod-record`, based on Phase 18 plus its tsc/prettier fix commit)

Status: **code-reviewed, plus node-run unit tests.** `npm ci` failed (registry unreachable), so project `tsc`, `eslint`, `prettier`, `vite build` and a browser were NOT run. Run directly with node: all 989 tests pass (24 new) and a strict `tsc` on the two new pure files is clean. No SQL was run. Detail: `phase19_cod_record_report.md`; QA: `phase19_manual_qa_checklist.md`.

What it does: an admin can record that cash was received for a delivered cash-on-delivery order from the admin order detail page ("Cash on delivery" card, confirm dialog, required reason 3-400 characters). It calls the existing `record_cod_payment` through ONE new server function, `recordCodPaymentFn({orderId, reason})` (user client only, no service role). Expected refusals are returned as a result (`mfa_required` is its own code); `changed: false` shows "Already recorded. Nothing changed." After success the admin order detail and orders list queries are invalidated.

Button rule: cash_on_delivery, status delivered (stricter than SQL, which also allows out_for_delivery), payment_status not paid / partially_refunded / refunded.

Nothing in `db/`, migrations, RLS, SQL, `startPaymentFn`/`startPayment`, card or M-Pesa logic, checkout totals, auth/MFA, query shapes or keys, routes or dependencies; `routeTree.gen.ts` untouched.

Release checklist (none of this has been done)
- `npm ci && npx prettier --write <changed files> && npx eslint . && npx tsc --noEmit && npm test`
- `npx vite build` (detached, with a log file)
- Walk `phase19_manual_qa_checklist.md` on a dev database with an admin who has completed two-factor sign-in; confirm the audit log gets one `cod_payment_recorded` row and the order shows Paid
- Confirm the `record_cod_payment` migration (6G.3) is applied on the target project
- Decide whether `out_for_delivery` cash should be offered, and whether the dashboard query should also refresh


# PHASE 19B — CATEGORY IMAGES (branch `phase-19b-category-images`, based on Phase 19)

Six images (1200x900 JPEG, each under 200 KB, no text or logos) added in `public/categories/`: produce, bakery, drinks, pantry, dairy-and-eggs, household. No code change. Nothing is shown until the owner sets `categories.image_url` in Supabase, AFTER the images are deployed:

```sql
update categories set image_url = '/categories/produce.jpg'        where slug = 'produce';
update categories set image_url = '/categories/bakery.jpg'         where slug = 'bakery';
update categories set image_url = '/categories/drinks.jpg'         where slug = 'drinks';
update categories set image_url = '/categories/pantry.jpg'         where slug = 'pantry';
update categories set image_url = '/categories/dairy-and-eggs.jpg' where slug = 'dairy-and-eggs';
update categories set image_url = '/categories/household.jpg'      where slug = 'household';
```

Not done: the home page still shows a large empty tile for any category without an image (compact empty tile is an open suggestion).


# PHASE 19C — ELECTRONICS CATEGORY AND 20 PRODUCTS (branch `phase-19c-electronics`, based on Phase 19B)

Data only, no code change: `db/seeds/phase19c_electronics.sql` (a hand-run seed in a new `db/seeds/` folder, NOT a migration). It adds the category `electronics` and 20 products (TVs, fridges, freezer, washing machine, kitchen appliances, audio, phone, laptop). Prices are ESTIMATES in KES (stored x 100), 4 items have an "on offer" old price; descriptions and stock are placeholders. Safe to run twice (existing slugs are skipped). The SQL has NOT been run against any database; it was read and its rows checked by script only.

Images: `public/categories/electronics.jpg` (1200x900) and the 20 `public/products/<slug>.jpg` files (800x800, each under 125 KB) are now in the repo (generated in Lovable, no text or logos). They must be deployed before the SQL is run. Note: the earbuds picture closely resembles a well-known brand's earbuds design; replace it if you sell different earbuds.

Release checklist (none done)
- Deploy (the 21 images are in the repo), open one image URL to confirm it loads
- Run the seed once in the Supabase SQL editor; confirm the result shows 1 category and 20 products
- Open the home page and the Electronics category; check images, prices and the "on offer" badges
- Replace the estimated prices, stock and descriptions with real ones (admin products screen)
- Check Safaricom's current M-Pesa per-payment limit for items over about KES 100,000


# PHASE 20 — ADMIN CATALOG (branch `phase-20-admin-catalog`, based on `phase-19c-electronics-images`)

Three admin features, one commit each: 20A categories, 20B pictures, 20C starting stock and active on create. Rules held throughout: no existing migration or SQL function edited, every new writer is security definer + `set search_path` + `require_admin()` first + validated + audited + granted to `authenticated` only, no new npm dependency.

## Phase 20A (admin categories) - STATUS: code committed (`phase 20a: admin categories`); migration NOT applied; SQL test NOT run

What was added
- Migration `db/migrations/20261011010000_phase20a_admin_categories.sql`: `admin_create_category(p_name, p_slug, p_tagline, p_description, p_position, p_is_active)` and `admin_update_category(p_category_id, p_changes jsonb)` (PATCH; keys name, slug, tagline, description, position, is_active; anything else -> `unsupported_field`). Limits: name 2-80, slug 1-80 `^[a-z0-9]+(-[a-z0-9]+)*$`, tagline <= 120, description <= 500, position integer >= 0. Duplicate slug -> `slug_taken`. Audit actions `category_created` / `category_updated` (field names and the is_active change only, never text). No delete: deactivate with `is_active = false`. Image is NOT writable here (Phase 20B).
- Admin screen `/admin/categories` (`src/routes/_authenticated/admin/categories.index.tsx`): list + create/edit form (`src/components/admin/category-form.tsx`), nav link "Categories" next to Products. Deactivating asks for confirmation.
- Pure helpers `src/features/admin/categories-result.ts` (validators, patch builder, error map, `CATEGORY_REASON_MESSAGES`); data layer `src/features/admin/categories.ts`; types added to `src/lib/supabase/types.ts`.
- Tests: `tests/admin-categories.test.ts`, `tests/admin-nav.test.ts` (updated), `db/tests/phase20a_admin_categories.test.sql` (written, not run).
- Eight older SQL tests had exact `admin_*` / `*categor*` function allow-lists; the two new names were added (test-only edit): phase6b2, 6c1a2, 6c1b1, 6c1b2, 6c2_admin_inventory_adjustment, 6c2_inventory_concurrency_final, 6c2_inventory_history_api, 6c2_inventory_read_foundation.
- `src/routeTree.gen.ts` was regenerated with the `@tanstack/router-generator` API (not hand-edited); the TanStack Start `Register` block it omits was re-appended verbatim. Diff = 23 added lines. A `vite dev` run should reproduce it.

Behaviour notes
- Admin list is a plain SELECT under the existing policy "Categories: admin read all" (admin + 2FA), query key `["admin","categories"]` (new, for the new screen). Forms invalidate only that key.
- A deactivated category disappears from the storefront through the existing RLS policy "public read active". A signed-in admin still sees inactive categories on the storefront (admin read policy); `categoriesQuery` was not changed. The product form dropdown still lists an inactive category as "(inactive)" for admins.
- Pre-existing uncommitted changes NOT from Phase 20 (left alone): `db/tests/phase8_coupon_concurrency.sh`, `scripts/integration/run-sql-tests.sh`, `zip-project.bat`.

Verified by running (local): `npm ci`, `tsc --noEmit` (no errors), `eslint` on touched files (clean), `prettier --write`, `node --test` on the two test files above (22 pass).
Not run: see "Unchecked" in `phase20_report.md` (written at the end of Phase 20).

Release checklist so far (20A only; none done)
- Apply `20261011010000_phase20a_admin_categories.sql` in the Supabase SQL editor (after all earlier migrations).
- Run `db/tests/phase20a_admin_categories.test.sql` and the eight updated older SQL tests on a dev database.
- Deploy; as an admin with 2FA create, edit and deactivate a category; confirm it vanishes from the storefront for a signed-out visitor.

## Phase 20B (admin picture upload) - STATUS: code committed (`phase 20b: admin picture upload`); migration NOT applied; SQL test NOT run; bucket NOT created

What was added
- Migration `db/migrations/20261011020000_phase20b_catalog_images.sql` (apply after 20A): public Storage bucket `catalog-images` (2 MB, jpeg/png/webp); four `storage.objects` policies ("Catalog images: admin insert / update / delete / read", admin + 2FA only, insert/update names must match `products|categories/<uuid>.<jpg|png|webp>`); new functions `admin_set_product_image(p_product_id, p_image_url)` and `admin_set_category_image(p_category_id, p_image_url)`. They accept NULL (remove) or exactly `https://<host>/storage/v1/object/public/catalog-images/{products|categories}/<uuid>.<ext>` AND the file must already exist in `storage.objects`. Refusals: `invalid_image_url`, `image_not_found`, `invalid_arguments`, `product_not_found`, `category_not_found`. Audit: `product_image_set/removed`, `category_image_set/removed` (object name only). Unchanged value = no write, no audit.
- Existing `/products/*.jpg` and `/categories/*` paths are untouched and keep rendering: every screen already renders `image_url` as a plain `<img src>`, so a full https Supabase URL works. No CSP / image-host allowlist exists in the repo (no `_headers`, no meta, no vite setting). Storage had not been used before this phase.
- Client: `src/components/admin/image-picker.tsx` (choose, check type/size, preview, "Use this picture", replace, remove with confirmation, pending state, plain-words errors, raw errors to console only); `src/features/admin/catalog-images.ts` (pure: limits, `validateImageFile`, `buildImagePath`, error map); `src/features/admin/catalog-images-api.ts` (upload + the two RPCs); types for the two RPCs in `src/lib/supabase/types.ts`. Used in `product-edit-form.tsx` (product edit page) and `category-form.tsx` (edit mode only; a new category shows "Save the category first").
- The picture saves on its own, not through the text-field PATCH. Order: upload under a random `uuid.ext` name, then call the set function, then invalidate. A failed upload or link leaves the old picture. Invalidated keys: product `["admin","product",id]` + `["admin","products"]`; category `["admin","categories"]`. No new query keys.
- Old files are never deleted (orders keep a copy of `image_url`), so replacing or removing leaves the old file in the bucket. Clean-up, if wanted, is a separate manual job.
- Tests: `tests/admin-catalog-images.test.ts` (file validation, path building incl. a check that the SQL policy pattern matches, error map); `db/tests/phase20b_catalog_images.test.sql` (written, NOT run). The eight older SQL tests with exact `admin_*` / `*categor*` / `*product*` function allow-lists got the two new names (test-only edit; same eight files as 20A). `tests/phase8-migration.test.ts` now also exempts `phase20` migrations from its "sorts before Phase 8" check (20A had left it failing).

Verified by running (local): `node --test` on the whole `tests/` folder (1018 pass, 0 fail), `prettier --write` on the new .ts files, `tsc` on `catalog-images.ts` alone with the project's strict flags (clean).
NOT run: `npm ci` (registry unreachable here: DNS lookup failed), so no full `tsc`, no `eslint`, no type-check of the .tsx files or `catalog-images-api.ts`, no browser run. Migration, storage policies and SQL tests were never applied/run on a database.

Release checklist additions (20B; none done)
- Apply `20261011020000_phase20b_catalog_images.sql` in the Supabase SQL editor after the 20A one. It creates the bucket itself; confirm in Storage that `catalog-images` is Public, 2 MB, image/jpeg + image/png + image/webp. Watch for a `WARNING ... is not limited to a bucket` line: it means another storage policy could let non-admins write this bucket.
- Run `db/tests/phase20b_catalog_images.test.sql` on a dev database (and the eight updated older SQL tests). If the storage-insert checks (B1-B7) error on a Storage trigger rather than on RLS, read the message before trusting the result.
- Run `npx tsc --noEmit` and `npx eslint` on a machine with network (they were not run for 20B).
- Deploy; as an admin with 2FA upload a picture to a product and to a category, replace it, remove it; try a .gif and a file over 2 MB (both must be refused with a plain message).

## Phase 20C (starting stock and active on create) - STATUS: code committed (`phase 20c: starting stock and active on create`); no migration; not type-checked; not run in a browser

What was added
- Two fields on the product CREATE form only: **Starting stock** (whole number >= 0, blank = 0, max 2147483647) and **Active** switch (default on). `admin_create_product` is unchanged and `ProductFormValues` is unchanged (its test asserts all-blank); the two values are local state in `product-create-form.tsx`.
- Chain of EXISTING functions: `admin_create_product`, then `admin_adjust_inventory` (`p_reason` "Opening stock", only when stock > 0, because a zero adjustment is refused), then `admin_set_product_active(false)` only when Active is off. Not atomic: each call is its own transaction. If stock fails, deactivation is still tried (a product meant to be hidden should not stay visible). A failed follow-up keeps the product, stays on the form, shows a plain message (stock: "The product was created, but starting stock was not saved. Set it on the product page.") and a link to the product; raw errors go to the console. A failed create behaves as before (field or form message).
- Pure logic and message map: `src/features/admin/product-create-plan.ts`. Tests: `tests/admin-product-create-plan.test.ts` (19 tests: parsing, step plan, runner order and failures, messages). Invalidated keys unchanged: `["admin","products"]`, `["admin","inventory"]`, `["admin","dashboard"]`, `["products"]`.
- Known risk: if the product should be inactive and the deactivate call fails, it stays live (with its stock) until fixed on the product page. If that is not acceptable, replace the chain with one new atomic function in a new migration.

Verified by running: `node --test` on all of `tests/` (1037 pass, 0 fail). NOT run: `npm ci` (registry unreachable), so no `tsc`, `eslint`, `prettier` for 20C; no browser; no database.

## Phase 20 Release checklist (none of this has been done)
1. Apply migrations in the Supabase SQL editor, in this order, once each, after `20261010010000_phase9c_...`: (a) `db/migrations/20261011010000_phase20a_admin_categories.sql`, (b) `db/migrations/20261011020000_phase20b_catalog_images.sql`. 20C needs no migration.
2. Storage: 20B creates the bucket. In Storage confirm `catalog-images` exists, is Public, 2 MB limit, image/jpeg + image/png + image/webp only. Watch for a `WARNING ... is not limited to a bucket` line from the migration.
3. On a dev database run `scripts/integration/run-sql-tests.sh` (now lists `phase20a_admin_categories` and `phase20b_catalog_images`; the eight older SQL tests with updated function allow-lists run too). Read any Storage trigger error before trusting a result.
4. On a machine with network: `npm ci`, `npx tsc --noEmit`, `npx eslint .`, `npx prettier --check .`, `npm test`. Run `vite dev` once so `routeTree.gen.ts` regenerates; the diff should be empty.
5. Deploy, then walk `phase20_manual_qa_checklist.md` as an admin with 2FA, as a non-admin, and at 360 px.
6. Roll-back note: nothing deletes data. Deactivate a category instead of deleting; old picture files stay in the bucket.

## Phase 21 (admin product variants) - STATUS: code committed on `phase-21-admin-variants` (`phase 21a: add variants (admin)`); no migration; `npm ci` failed here, so NOT type-checked, linted or run in a browser

What was added
- "Add variant" dialog on the admin product page (`product-variants-card.tsx`, new `productId` prop): Name, Price, Compare-at, SKU, Starting stock, Active; buttons "Add variant" and "Save and add another". Position = highest used + 1.
- Chain of EXISTING functions, each its own transaction: `admin_create_product_variant` (stock 0, active), then `admin_adjust_inventory` with `p_variant_id` and reason "Opening stock" only if stock > 0, then `admin_update_product_variant({is_active:false})` only if Active is off. Activation uses the existing `is_active` key; there is no separate function. A failed later step keeps the variant and shows a plain warning toast (raw error to the console).
- Pure logic `src/features/admin/variant-create-plan.ts` reuses `product-create-plan.ts`. Tests: `tests/admin-variant-create-plan.test.ts`. Invalidated keys are existing ones only (see `phase21_report.md`).

Known gaps (also in `phase21_report.md`): no UI to hide/show an existing variant (a failed hide cannot be undone from the UI); no Sale badge for variant cards; product's own stock still listed in admin inventory; server-side "Invalid variant name" is not mapped to the field; checkout with variants not re-read.

Verified by running: `npm test` (1054 pass, 0 fail); `tsc` on the new pure file alone. NOT run: `npm ci`, full `tsc`, `eslint`, `prettier`, browser, any database call. Checklist: `phase21_manual_qa_checklist.md`.

### Phase 21c note (variant active switch) - STATUS: code committed on `phase-21c-variant-active`; not type-checked, linted or run in a browser
- Edit variant dialog now has an Active switch; `is_active` is sent in the same `admin_update_product_variant` patch, only when changed. Server "Invalid variant name" now lands on the Name field. No migration, no new key or route. Tests: `tests/admin-variant-active.test.ts`; `npm test` 1061 pass (run); `npm ci`, `eslint`, `prettier`, full `tsc`, browser NOT run.
- Still open (not fixed on purpose): no Sale badge on variant cards; product-level stock still listed in admin inventory when variants exist.

