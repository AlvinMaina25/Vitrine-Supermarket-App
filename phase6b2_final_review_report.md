# Phase 6B.2 — Final pre-application review and fix

Nothing was applied. Supabase and the production database were not touched. No PostgreSQL was available, so no SQL has been executed.

## 1. Exact issue found

1. **6B.1 compatibility.** The verified 6B.1 test has an assertion (`STATUS: no admin status/payment/refund writer function was added`) that fails if any public function name matches `(admin).*(status|payment|refund)` (other than `admin_dashboard_summary`) or `(mark|set).*(paid|refund)`. Its purpose was to prove 6B.1, a read-only phase, added no status/payment writer. `admin_set_order_status` matches the pattern, so re-running the 6B.1 test after applying 6B.2 would have failed.
2. **Override receipt ambiguity (found while reviewing).** The wrapper recognises an override by the history note prefix `Admin override: `, which `set_order_status()` writes. A caller-supplied note starting with that text could mislabel a standard move as an override in the audit trail, or make a standard move fail with a false `override_not_requested`.
3. **Test gaps.** No structural proof of "one status writer"; override-matrix, no-stock reactivation and 5B.2/6A/6B.1 regression checks were thin.

## 2. Exact files changed

- `db/migrations/20261004030000_phase6b2_admin_order_actions.sql` (6B.2 migration, not yet applied anywhere)
- `db/tests/phase6b2_admin_order_actions.test.sql`
- `db/tests/phase6b1_admin_orders_backend.test.sql` (**test only**, one assertion, see 4)
- `src/features/admin/orders-result.ts`, `src/lib/supabase/types.ts`, `tests/admin-order-actions.test.ts`
- `phase6b2_final_review_report.md` (this file)

Byte-identical to the uploaded zip (md5 checked): the 5B.2, 6A and 6B.1 migrations.

## 3. Function name and signature (unchanged)

`public.admin_set_order_status(p_order_id uuid, p_status public.order_status, p_note text default null, p_override boolean default false) returns jsonb`

I kept the name rather than renaming: it is the clearest name, and a rename to dodge a name-pattern check would hide the function from a check whose intent is to catch exactly this kind of function.

## 4. Why it is compatible with 6B.1

The 6B.1 assertion now exempts the function **only** if all of these hold: its oid equals the exact signature above, it is SECURITY DEFINER, and its body contains `public.require_admin()` and `public.set_order_status(`. Any other matching function, a second overload, or a look-alike with a different body still fails. Before 6B.2 is applied the exemption matches nothing, so the assertion is unchanged for 6B.1. No other 6A/6B.1 assertion is affected (checked: no function-count or admin-name-list checks elsewhere). The diff against the original test is that one assertion plus a comment.

Added the invariant the old name check only approximated:

- **Migration self-check and test F12:** the only public function that `UPDATE`s `orders` is `set_order_status`, and the only one that calls `set_order_status(` is `admin_set_order_status`.
- **Static emulation over all migration function bodies:** this gives exactly those two sets. It was run in Python, not in PostgreSQL.
- **Risk to know about:** if your dev database holds hand-made functions that update orders, the migration's self-check will abort and roll back, naming the invariant.

## 5. Exact override behavior

Read from `set_order_status()` (not guessed):

- **Standard move** (its own table, e.g. pending→processing): succeeds with `p_override` true or false. The flag permits an override; it never forces one. A note on a standard move is stored as given, unlabelled.
- **Non-standard move, `p_override=false`:** the delegate either refuses (non-admin, or out of `refunded`: `transition_not_allowed`; no reason: `admin_note_required`) or performs the override, and this function then rolls the call back with `override_not_requested`.
- **Non-standard move, `p_override=true`:** needs a reason of 3+ characters, else `admin_note_required`. It is stored as `Admin override: <reason>`.
- **Reserved prefix (new):** a note starting with `Admin override:` (case-insensitive, leading spaces ignored) is refused with `note_reserved_prefix`, whatever `p_override` is.
- **Impossible even with `p_override=true`** (all inside `set_order_status()` or the triggers, none reimplemented here):
  - target `paid` or `refunded`: `payment_state_reserved`
  - any move out of `refunded`: `transition_not_allowed`
  - an online-payment order not confirmed paid entering processing/picking/packed/dispatched/out_for_delivery/delivered: `payment_not_confirmed`
  - `pending` for a non-COD order, or `awaiting_payment` for a COD order: `payment_method_mismatch`
  - reactivation into a full, closed or not-offered slot: `reactivation_slot_*`
  - reactivation without enough stock: `reactivation_insufficient_stock`
  - note over 400 characters: `note_too_long`
- Restock/re-reserve and the history row are written by the existing triggers on every path, override included. `require_admin()` runs first and is never bypassed. No direct table UPDATE exists.

## 6. Security guarantees

SECURITY DEFINER; `search_path = public, pg_temp`; VOLATILE. EXECUTE: authenticated yes, anon no, PUBLIC no (migration self-check and test F4 read the ACL, not just `has_function_privilege`). `require_admin()` first. Customers, staff, forged admin claims, forged `role: service_role` claim, and service_role without a user are refused. No UPDATE/INSERT/DELETE on `orders` for any browser role (table or column level), no write policies, RLS on, triggers enabled. No new table privileges.

## 7. Test coverage (`phase6b2_admin_order_actions.test.sql`, about 140 checks, one rolled-back transaction, fixtures via real `create_order()`)

- **Positive:** the full fulfilment chain, history rows and `changed_by`, cancellation, restock once, repeated terminal actions, valid override, cancel/reactivate/cancel idempotency, variant restock.
- **Negative:** invalid jumps, bad enum/NULL/unknown order/long note, the payment gate, paid/refunded, reserved prefix, override with no/short reason, no-stock reactivation, full-slot reactivation.
- **Authorization:** anon, signed-out, customer on own order, staff, forged JWTs (customer subject, staff subject, `service_role` claim), service_role without user. Each refusal asserts the order is untouched and is followed by an admin positive control.
- **Security:** direct UPDATE/DELETE refused, ACL, search_path, SECURITY DEFINER, RLS, triggers (F8), one writer (F12), not a trigger (F13), admin API is exactly four functions.
- **Regression (section H):** 5B.2 set_order_status() authorization, RLS own-orders, roles not browser-writable; 6A dashboard and role helpers; 6B.1 list/detail still admin-only and reflecting 6B.2 changes.
- **Not covered:** a true two-session race (one session cannot prove it); the function does take `FOR UPDATE` on the order first (asserted by source check).

## 8. Local test results

- `node --test "tests/**/*.test.ts"`: 135 tests, 135 pass, 0 fail.
- Strict typecheck of the pure TS files: no errors in new code; the 4 `TS4111` errors in the existing 6B.1 code of `orders-result.ts` remain (not touched).
- SQL: dollar-quote and parenthesis balance OK; every test helper called is defined; every result key asserted is recorded.
- Not run: full `tsc`, `build`, `lint` (no `node_modules`).

## 9. PostgreSQL / Supabase status

None run, none applied. The SQL test is unproven. The most likely places for a first-run failure are the slot fixture (04:10–04:40, two days ahead, capacity 1) and expectations about exact error codes in section H.

## 10. Commands to run manually (dedicated Phase-5 dev/testing database ONLY)

```bash
export DATABASE_URL='<dedicated Phase-5 dev/testing connection string>'
# 1) apply the 6B.2 migration (once)
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/migrations/20261004030000_phase6b2_admin_order_actions.sql
# 2) the 6B.2 test
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b2_admin_order_actions.test.sql
# 3) re-run the earlier tests to confirm no regression (includes the amended 6B.1 assertion)
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase5b2_security_authorization_hardening.test.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6a_admin_operations_foundation.test.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase6b1_admin_orders_backend.test.sql
```

Each test ends with a row `ok` / `ALL PHASE ... TESTS PASSED`; a failure raises `FAIL: <name>`. Send me the exact message if anything fails.
