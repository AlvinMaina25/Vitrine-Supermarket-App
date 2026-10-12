# Phase 6B.2 — Admin Order Actions Backend: Report

**Status: written and statically checked only. The migration has NOT been applied to any database and the SQL test has NOT been run (no PostgreSQL or Supabase was available in this session).**

## 1. Phase implemented

One admin-only database function, `admin_set_order_status(p_order_id, p_status, p_note default null, p_override default false)`, returning jsonb. Every admin order action (confirm/process, pick, pack, dispatch, deliver, cancel) is a status change, so one function covers all of them. It is a gate and a receipt around the Phase 5B.2 `set_order_status()`, not a second state machine.

## 2. Files created

- `db/migrations/20261004030000_phase6b2_admin_order_actions.sql`
- `db/tests/phase6b2_admin_order_actions.test.sql`
- `tests/admin-order-actions.test.ts`
- `phase6b2_admin_order_actions_report.md`

## 3. Files modified

- `src/lib/supabase/types.ts` (additive: `AdminOrderHistoryRow`, `AdminSetOrderStatusResult`, `AdminSetOrderStatusInput`, one `Functions` entry)
- `src/features/admin/orders-result.ts` (additive: `AdminOrderActionError`, `toAdminOrderActionError`, `toAdminSetOrderStatusArgs`, `toAdminSetOrderStatusResult`)
- `src/features/admin/orders.ts` (additive: `adminSetOrderStatus()`, `adminCancelOrder()`)

Not touched: every earlier migration (the 6B.1 migration is byte-identical to the uploaded one), every earlier test, all UI.

## 4. Database changes

One function and nothing else: no table, column, type, policy, index or table grant. `create_order()`, `set_order_status()`, the triggers and RLS are unchanged. The migration refuses to run without 5B.2 / 6A / 6B.1 (or if a browser role can UPDATE `orders`), refuses to run twice, and ends with a self-check that rolls everything back unless the guarantees in section 10 hold.

## 5. Admin authorization design

- `require_admin()` (Phase 6A) is the first statement, before any argument is read: 42501 / `not_authorised` for anon-without-EXECUTE, signed-out, customers, staff, forged claims and service_role without a user.
- `SECURITY DEFINER`, `search_path = public, pg_temp`, VOLATILE. `REVOKE ALL ... FROM public, anon, authenticated`, then `GRANT EXECUTE ... TO authenticated`. The role is read live from `user_roles` on every call, so revoking admin takes effect immediately.
- Identity comes from the JWT subject (`auth.uid()`), which stays the caller inside the definer function, so `set_order_status()` and the history trigger record the real admin as `changed_by`.
- Staff stay staff: they keep `set_order_status()` for the standard workflow and are refused by this function.

## 6. Status-transition design

1. `require_admin()`.
2. `SELECT ... FOR UPDATE` on the order; remember the previous status and the ids of existing history rows.
3. `PERFORM public.set_order_status(...)` — unchanged. It alone validates the transition, applies the payment gate and `paid`/`refunded` ban, and updates the row; the existing triggers restock / re-reserve, guard slot capacity and write history.
4. Receipt checks (any failure raises, so the whole call rolls back): `payment_status` did not move; if the status moved, exactly one new history row exists (found by id, not timestamp).
5. Return `{changed, previous_status, order{...12 fields}, history_entry}`. No address, notes, items or customer contact data (use `admin_get_order()`).

**Override is opt-in.** `set_order_status()` already lets an admin make a non-standard move with a reason of 3+ characters ("Admin override: <reason>"). I did not widen that, but a note alone must not turn a routine action into an arbitrary jump, so this function requires `p_override => true` for it. If the delegate performed an override and `p_override` is false, the call is rolled back with `override_not_requested`. No transition table is copied: the override is recognised by the history note `set_order_status()` itself writes. Consequence: arbitrary jumps fail unless an admin gives a reason AND confirms the override; moves out of `refunded` fail even then.

## 7. Stock / restocking safety

No stock or slot code was added; the existing 5B.2 / 4C.2B triggers run inside the delegate. Cancel restocks once (`restocked_at`), repeated cancel is a no-op, cancel → override-reactivate → cancel nets to one restock, variant lines restock the variant, and reactivation into a full slot is refused by the existing capacity guard with the whole call rolled back. Concurrency: the order row is locked first, so two admins on one order are serialised and the second sees the first's committed state; stock rows and the slot advisory lock are taken by the existing triggers in their existing order. A true two-session race is not proven by the SQL test (one session cannot do that).

## 8. Payment safety

No payment writer, provider, webhook, secret or fake confirmation. `paid` and `refunded` are still refused (`payment_state_reserved`) even with override; an unpaid M-Pesa/card order cannot enter fulfilment even with override (`payment_not_confirmed`); `payment_status` is never written and a receipt check enforces that.

## 9. Audit / history behavior

Every successful change writes its history row through the existing trigger; a missing row aborts the call (`history_missing`). A no-op (same status) writes nothing and returns `changed: false`, per the `set_order_status()` contract. Notes: optional, at most 400 characters, stored as the history note; overrides are stored as `Admin override: <reason>`.

## 10. Security tests (in the SQL test, sections D–F)

Anon, signed-out, customer on their own order, staff, forged JWT (customer subject, staff subject, and `role: service_role` claim), service_role without a user — each asserted as an error AND the order untouched, followed by an admin positive control. Live admin revoke. Direct UPDATE of `status`/`payment_status` and DELETE of history refused for admin and staff. Static: no UPDATE/INSERT/DELETE grants or write policies on the order tables, RLS on, SECURITY DEFINER + pinned search_path, anon/PUBLIC cannot EXECUTE (ACL checked), `require_admin()` intact and unexecutable by browser roles, one `set_order_status()` with its 5B.2 rules, function source has no table writes, triggers still enabled, admin API is exactly four functions, no payment/refund writer.

## 11. Local test results

- `node --test "tests/**/*.test.ts"`: 135 tests, 135 pass, 0 fail (includes the new `tests/admin-order-actions.test.ts`).
- Strict typecheck (project tsconfig flags) of `orders-result.ts`, `dashboard-result.ts`, `types.ts` only: no errors in the new code. **Not run:** full `tsc --noEmit`, `bun run build`, `bun run lint` (no `node_modules` in the zip, no network). `orders.ts` imports React Query and the Supabase client, so it is unchecked.
- Pre-existing, not from this phase: the same strict check reports 4 × TS4111 in the Phase 6B.1 code of `orders-result.ts` (`data.orders`, `data.total`, `data.items`, `data.history` on a `Record<string, unknown>`). I left them alone; fix is bracket access or a typed cast.

## 12. SQL test status

Written (about 100 checks, one transaction, rolled back, fixtures through the real `create_order()`). **Not run.** Static checks only: dollar-quote and parenthesis balance. Unproven assumptions: the slot fixture (04:10–04:40, two days ahead, capacity 1) must pass `create_order()`'s lead-time/horizon rules; `service_role` is accepted as refused by either the gate or missing EXECUTE.

## 13. Live database status

Nothing was applied or run against any Supabase project. The production supermarket project was not touched.

## 14. Commands to run manually (dedicated Phase-5 development/testing database only)

```bash
export DATABASE_URL='<connection string of the DEDICATED Phase-5 dev/testing project>'
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/migrations/20261004030000_phase6b2_admin_order_actions.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b2_admin_order_actions.test.sql
```

SQL editor alternative: run the migration file, then the test file; the last statement returns one row (`ok` = `ALL PHASE 6B.2 TESTS PASSED`). A failure raises `FAIL: <name>`. If the migration's self-check or the test fails, send me the exact message.

## 15. Remaining work for Phase 6B.3

Admin order UI only: orders list and detail screens on the 6B.1 queries, action buttons driven by `adminSetOrderStatus()` (cancel with a reason; an explicit confirm step before `override: true`), React Query invalidation of `["admin","orders"]` and `["admin","order", id]`, and friendly messages per `AdminOrderActionError.reason`. A two-session concurrency script is optional follow-up if you want the race proven.
