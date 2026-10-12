# Phase 6A — Admin Operations Foundation: Report

**Status: written and verified on a throwaway local PostgreSQL 16 only. NOT applied to the Phase-5 development Supabase database.**
Nothing here is verified against real Supabase. See "Could not be verified".

Scope kept to the foundation: no order, product, inventory, delivery or payment management was built, and no admin UI/route was added.

---

## 1. What was actually completed

**Reused unchanged from Phase 5 (inspected, then re-proved by tests, not modified):**
orders / order_items / order_status_history reads (staff + admin read all, customers own only), `set_order_status()`, closed orders write path, delivery configuration (staff read, admin-only write), `user_roles`, `is_staff()/is_admin()/has_role()`.

**Added (the only genuinely missing pieces):**

1. `public.require_admin()` — one internal admin gate. Raises the same error `set_order_status()` uses (SQLSTATE `42501`, DETAIL `not_authorised`). Not executable by any browser role; only other SECURITY DEFINER functions can call it. Future admin RPCs call this instead of repeating the check.
2. Four **SELECT-only, admin-only** RLS policies so an admin can see what the public policies hide:
   - `products`, `product_variants`, `categories` (inactive rows) → needed for admin product / inventory access
   - `profiles` (all customers) → needed for admin customer access
3. `public.admin_dashboard_summary(p_recent_orders_limit int = 10, p_low_stock_threshold int = 10) returns jsonb` — admin-only, STABLE (read-only). Aggregates existing tables only:
   - orders: total, placed today, count by every status, gross value of non-cancelled orders
   - payments: counts by every `payment_status` and `payment_method` (what `orders` already records)
   - delivery: scheduled today / upcoming, orders per method, counts of active methods / zones / slot templates
   - products & variants: total/active/inactive, out-of-stock, low-stock, plus up to 10 items needing attention (out-of-stock first)
   - customers: total and new in the last 30 days (profiles with no staff/admin role)
   - recent orders: display fields only (no email, phone, address, notes, user id)
4. TypeScript: `AdminDashboardSummary` types, `is_admin` / `admin_dashboard_summary` entries in the `Functions` type map, `isAdmin()` UI helper, a pure result/error module, and a React Query wrapper (`adminDashboardQuery`). No route or screen uses them yet.

**"Admin X access" by requirement 4:**

| Area                   | Backend foundation                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------ |
| Dashboard metrics      | new `admin_dashboard_summary()`                                                      |
| Orders                 | already in place (Phase 5 RLS); dashboard adds counts + recent orders                |
| Products               | new admin read policies (inactive products/variants/categories)                      |
| Inventory              | same policies (`stock_quantity` lives on products/variants) + low-stock in dashboard |
| Customers              | new admin read policy on `profiles` + customer counts                                |
| Delivery configuration | already in place (staff read, admin write); dashboard adds config counts             |
| Payment transactions   | **nothing exists to build on — not implemented (see §6)**                            |

---

## 2. Files changed

Created:

- `db/migrations/20261004010000_phase6a_admin_operations_foundation.sql`
- `db/tests/phase6a_admin_operations_foundation.test.sql` (116 checks)
- `src/features/admin/dashboard-result.ts`
- `src/features/admin/queries.ts`
- `tests/admin-dashboard.test.ts` (8 tests)
- `phase6a_admin_operations_foundation_report.md` (this file)

Modified:

- `src/lib/supabase/types.ts` (added types + two `Functions` entries only)
- `src/features/auth/roles.ts` (added `isAdmin()`)
- `tests/tsconfig.json` (one `include` line)

No old migration, old test, or frontend/UI file was edited.

## 3. Migration

`20261004010000_phase6a_admin_operations_foundation.sql` — one transaction, apply once, after `20261003010000_phase5b2_…`.

- Refuses to run unless Phase 5B.2 is applied (checks `orders.restocked_at`, `is_admin`, `set_order_status`, and that no browser role can UPDATE `orders`). Verified: on a DB without 5B.2 it aborts and leaves nothing behind.
- Refuses to run twice. Verified.
- Ends with a self-check that rolls everything back if its guarantees do not hold.

## 4. Database objects changed

| Object                                            | Change                                                                                                 |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `public.require_admin()`                          | new; SECURITY DEFINER, `search_path = public, pg_temp`; EXECUTE revoked from public/anon/authenticated |
| `public.admin_dashboard_summary(integer,integer)` | new; SECURITY DEFINER, STABLE, `search_path = public, pg_temp`; EXECUTE: authenticated only            |
| Policy `Products: admin read all`                 | new, SELECT, authenticated, `is_admin(auth.uid())`                                                     |
| Policy `Variants: admin read all`                 | new, same                                                                                              |
| Policy `Categories: admin read all`               | new, same                                                                                              |
| Policy `Profiles: admin read all`                 | new, same                                                                                              |

No new table, column, type, grant or trigger. No existing policy, grant or function changed.

---

## 5. Verification performed and exact results

**Environment:** PostgreSQL 16.15 installed locally (apt), Supabase-style shim (roles `anon`/`authenticated`/`service_role`, `auth.uid()`/`auth.role()` read from JWT settings, default privileges). Built from migrations `000000 → 080000 → 5B.2 → 6A`. The shim is **not** Supabase.

| Check                                                                                                                                                                                                                                                                                                                                                    | Result                                                                                                                                                            |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 6A migration applies on top of 5B.2                                                                                                                                                                                                                                                                                                                      | pass                                                                                                                                                              |
| 6A migration re-run                                                                                                                                                                                                                                                                                                                                      | refused by its own precondition                                                                                                                                   |
| 6A migration on a DB without 5B.2                                                                                                                                                                                                                                                                                                                        | refused; no objects created                                                                                                                                       |
| **6A test** (`phase6a_…test.sql`), function-defaults shim                                                                                                                                                                                                                                                                                                | **116 checks, 0 failures**, `ALL PHASE 6A TESTS PASSED`                                                                                                           |
| 6A test, full-default-grants shim (tables + functions)                                                                                                                                                                                                                                                                                                   | **116 checks, 0 failures**                                                                                                                                        |
| 6A test leaves fixtures behind                                                                                                                                                                                                                                                                                                                           | no (rolled back; 0 users / products / methods remain)                                                                                                             |
| **Existing 5B.2 test** with 6A applied                                                                                                                                                                                                                                                                                                                   | **166 checks, 0 failures** (also 166/166 without 6A)                                                                                                              |
| Mutation checks: 10 deliberate security regressions (gate removed; staff allowed through gate; profiles policy opened to all; product policy widened to staff; admin profile policy dropped; `require_admin` made callable; anon granted dashboard; UPDATE on `orders` re-granted; admin write policy on products; staff write policy on delivery zones) | **each one made the 6A test fail**, on the intended assertion                                                                                                     |
| An additional mutation (sort order reverted)                                                                                                                                                                                                                                                                                                             | caught                                                                                                                                                            |
| `tsc --noEmit` (app)                                                                                                                                                                                                                                                                                                                                     | 0 errors (baseline also 0)                                                                                                                                        |
| `tsc -p tests/tsconfig.json --noEmit`                                                                                                                                                                                                                                                                                                                    | 0 errors                                                                                                                                                          |
| Unit tests (`npm test`)                                                                                                                                                                                                                                                                                                                                  | 115 pass / 0 fail (107 original + 8 new)                                                                                                                          |
| ESLint                                                                                                                                                                                                                                                                                                                                                   | output **identical to the original repo's** (1 pre-existing prettier error in `tests/create-order-args.test.ts` + 10 pre-existing warnings; none from this phase) |
| `vite build`                                                                                                                                                                                                                                                                                                                                             | succeeds (baseline also succeeds)                                                                                                                                 |

**What the 6A test proves (by role):**

- _Admin:_ can call the dashboard; reads inactive products/variants/categories, all profiles, all orders/items, inactive delivery zones, all role rows; can still edit delivery configuration.
- _Staff:_ refused the dashboard (`42501 / not_authorised`); cannot see inactive catalogue rows or other users' profiles; cannot edit delivery config or product stock; can still move an order along the fulfilment workflow.
- _Customer:_ refused the dashboard; sees only own profile and own orders/items/history; cannot see other customers' orders/items/history/profiles.
- _Anon:_ cannot execute the dashboard, `require_admin`, `is_admin`, or `set_order_status`.
- _service_role without an admin user:_ does not pass the admin gate.
- _Forged JWT claims_ (`user_role: admin`, `app_metadata.role: admin`, `role: service_role`) on a customer: still refused.
- _Phase 5 regressions:_ no browser role can UPDATE `orders` (paid / refunded / totals all blocked, re-read confirms unchanged); `paid`/`refunded` rejected for staff and admin through `set_order_status`; unpaid M-Pesa order cannot be fulfilled even by an admin; roles cannot be granted from the browser by anyone; role helpers answer only about the caller; every SECURITY DEFINER function in `public` pins `search_path`.
- _Data correctness:_ dashboard numbers asserted as deltas from a pre-fixture snapshot and cross-checked against independent SQL.

**Other older tests:** `create_order_delivery`, `delivery_validation`, `delivery_slot_validation`, `order_reactivation_capacity` fail the same way with and without 6A (pass counts 11 / 40 / 70 / 33 in both). This is the pre-existing state described in the 5B.2 report (stale fixtures); 6A did not change it and I did not edit those files.

## 6. Could not be verified

- **Against real Supabase / the Phase-5 dev database.** Not run. JWT claim handling, Supabase default privileges, and PostgREST behaviour are simulated.
- **Phase 5B.2 has never been applied to your dev database** (per its own report), and **Phase 5A.2 files were not in the zip**. 6A depends on 5B.2; apply 5B.2 first and run its test there.
- No browser/UI check (there is no admin UI), no PostgREST call, no concurrency script (`.sh`) run.
- Postgres 15 (Supabase's version may differ from 16).

## 7. Pre-existing issues found (not changed, not caused by 6A)

1. **Default table grants.** In an environment where `anon`/`authenticated` hold default table privileges (many Supabase projects), the 5B.2 test fails at its second-to-last check ("anon has no access to orders, items, roles, addresses or profiles"): 164 pass, same check, **identically before and after 6A**. Rows are still protected by RLS, but the privileges exist. Please check on your project: `select has_table_privilege('anon','public.orders','SELECT');`. A future hardening migration could `REVOKE` explicitly. **Decision needed.**
2. `types.ts` still lacks `set_order_status` and `orders.restocked_at` (flagged in the 5B.2 report).
3. The four older SQL tests still need fixtures updated for 5B.2 rules.

## 8. Genuine remaining work

- **Payment transactions (not implemented, deliberately).** No payments table, provider, webhook or payment record exists in the schema, so nothing was invented. Required later: a transactions table (admin read-only, service-role write), server-only provider integration, verified webhook, the single server path that sets `payment_status = 'paid'`, refunds, COD recording, unpaid-order expiry. The dashboard therefore has **no revenue figure**; `gross_value_cents` is order value, not money collected.
- Admin **writes** for products, inventory, customers (none exist: admin is read-only on these today). Delivery-config writes already exist (admin-only).
- Order management beyond `set_order_status()`, delivery management UI, admin routes/screens (the wrapper is ready, nothing calls it).
- Stock movement history (no table exists; stock is a plain column), audit logging of admin/config changes, MFA for staff/admin.
- Apply 5B.2 then 6A to the dev database and run both tests there.

## 9. Decisions that need your approval

1. **Admin-only vs staff.** I made inactive-catalogue reads, all-profile reads and the dashboard **admin-only**; staff stay fulfilment-only. If staff need stock visibility for picking, say so (widen the products/variants policies to `is_staff`).
2. **Low-stock threshold.** The schema has no reorder level, so the threshold is a **caller-supplied parameter** (default 10). Alternative: add a per-product `low_stock_threshold` column in the inventory phase.
3. **"Customer" definition.** Customers = profiles of users with no staff/admin role (the `customer` role is implicit; no row exists).
4. **`gross_value_cents`.** Sum of `total_cents` for non-cancelled/refunded orders (includes unpaid and COD). Keep it, rename it, or drop it?
5. **service_role and the dashboard.** `service_role` bypasses RLS on tables as before but does not pass `require_admin()` (it is keyed to a signed-in admin). Fine unless a server job needs the dashboard.
6. **Customer addresses** are not exposed to admins (orders keep their own snapshot). Decide in the customer-management phase.
7. **Default-grants hardening** (§7.1): explicit REVOKEs on tables in a new migration?
