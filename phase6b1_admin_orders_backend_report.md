# Phase 6B.1 — Admin Orders Backend: Report

**Status: written and statically checked only. The migration has NOT been applied anywhere and the SQL test has NOT been run (no PostgreSQL or Supabase was available in this session).**

## 1. Implemented

Two admin-only, read-only database functions, both gated by the Phase 6A `require_admin()` (SQLSTATE 42501 / DETAIL `not_authorised`), plus one index.

- `admin_list_orders(p_search, p_status, p_payment_status, p_payment_method, p_placed_from, p_placed_to, p_limit=25, p_offset=0)` returns `{total, limit, offset, orders[]}`, newest first.
  - Search is a case-insensitive substring over order number, profile name/email/phone and the address-snapshot name/phone. `%` and `_` are escaped, so they are literal.
  - Dates are inclusive Africa/Nairobi days. Limit is 1–100, search at most 100 characters, and from must be <= to; violations raise `P0001 invalid_arguments`.
- `admin_get_order(p_order_id)` returns `{order, customer, delivery, payment, items, history}`.
  - Customer data comes from `profiles` only, never `auth.users`.
  - Delivery covers method, zone, slot, fee rule and the address snapshot.
  - Payment is only what `orders` already stores.
  - History is oldest first, with the author's name.
  - An unknown id gives `P0001 order_not_found`, raised after the admin gate.
- `orders_placed_at_idx` on `orders (placed_at desc, id desc)`.

**Reused unchanged:** `require_admin()`, `is_admin()`, the "staff read all" policies, and `set_order_status()` as the only status write path. No new table, column, policy or table grant. No UPDATE privilege or policy was added to `orders`. No second status or payment mechanism. No payment table, provider or webhook.

**Why a migration was needed:** staff and admin could already read orders through RLS. An admin could not search by customer, because profiles are admin-only since 6A. There was also no single authorised customer + items + history fetch.

## 2. Files

Created:

- `db/migrations/20261004020000_phase6b1_admin_orders_backend.sql`
- `db/tests/phase6b1_admin_orders_backend.test.sql`
- `src/features/admin/orders-result.ts` (pure error mapping, argument building, payload checks)
- `src/features/admin/orders.ts` (React Query `adminOrdersQuery` / `adminOrderQuery`; no screen uses them)
- `tests/admin-orders.test.ts`
- `phase6b1_admin_orders_backend_report.md`

Modified:

- `src/lib/supabase/types.ts` (admin order types and two `Functions` entries; additive)
- `tests/tsconfig.json` (one `include` line)

No old migration, old test or UI file was touched.

## 3. Migration

`20261004020000_phase6b1_admin_orders_backend.sql` is one transaction, applied once, after Phase 6A.

- It refuses to run without 6A and 5B.2, or if a browser role can UPDATE `orders`.
- It refuses to run twice.
- Its self-check rolls everything back unless these hold:
  - the new functions are STABLE, SECURITY DEFINER, with a pinned search_path;
  - anon cannot execute them;
  - no browser role can execute `require_admin()`;
  - `orders` has no browser write privileges and no write policies exist on the order tables;
  - RLS is still on for the order tables and `profiles`.

## 4. Tests

`db/tests/phase6b1_admin_orders_backend.test.sql` (about 120 checks, rolled back at the end, real fixtures created through `create_order()` and `set_order_status()`).
It covers:

- listing, ordering and shape;
- search by order number, name, email, phone, snapshot name and phone, with literal wildcards;
- filters by status, payment status, payment method and date, combined filters, and paging;
- argument validation;
- detail: customer, items, delivery, payment and history, with a privacy check for password/token strings;
- denial for customer (including their own order), staff, signed-out JWT, service_role without a user, anon and forged JWT claims. Denial is asserted as an error, with admin positive controls, and revocation is checked live;
- 5B.2 intact: customer and anon refused, nobody can set paid/refunded, an unpaid online order cannot enter fulfilment, non-standard transitions need an admin and a reason, and legitimate moves appear in the admin history;
- direct payment_status/status/total/history/delete writes blocked for customer, staff, admin and anon, with the rows re-read as owner;
- 5A.2 hardening and RLS intact: no browser write grants, anon has no table privileges, no write policies, and there is still exactly one `set_order_status()`.

`tests/admin-orders.test.ts` covers the pure helpers.

## 5. Run so far

- `node --test "tests/**/*.test.ts"`: **123 passed, 0 failed** (includes the new admin-orders tests).
- Not run: `tsc`/`eslint`/`vite build` (no `node_modules` here), the SQL migration and the SQL test. Static checks only: balanced dollar-quoting and one transaction each.

## 6. Still to verify against the Phase-5 dev Supabase database

1. Apply `20261004020000_…` after 6A. Confirm the precondition block passes and the self-check does not abort.
2. Run `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b1_admin_orders_backend.test.sql`. Expect `ALL PHASE 6B.1 TESTS PASSED`. The test was written against the 6A test's helpers but never executed, so expect it may need small fixes.
3. Confirm the real Supabase behaviour of `service_role` and anon calling the functions (both are expected to be refused with 42501).
4. Call the RPCs from the real client with a real admin, staff and customer session, and run `bun run build`, `tsc` and `eslint`.
5. Check PostgREST accepts named-argument enum filters (`p_status`, etc.) and that the schema cache picks up the new functions.
