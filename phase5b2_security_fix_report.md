# Phase 5B.2 — Security Fix Report

**Status: written, NOT applied to the dedicated Phase-5 development Supabase database.**
**The fixes are therefore not verified against that database.** The migration and test were run only on a throwaway local PostgreSQL 16 on the build machine (details in section 13). That is useful evidence, not the verification you asked for.

---

## 1. Executive Summary

One new migration and one new test fix all six Phase 5B.1 findings. No old migration or application file was edited.

- **Order status** now changes only through a new database function, `set_order_status()`. Browser roles have no UPDATE on `orders` at all. Nobody in the browser, admin included, can set `paid` or `refunded`.
- **Restocking** is idempotent. A new `orders.restocked_at` column records when stock came back. Cancel/reactivate cycles leave stock unchanged.
- **Staff vs admin** is real: a new `is_admin()` helper. Delivery fees, zones, methods, slot templates and overrides are admin-write only. Staff keep read access and order fulfilment.
- **Delivery zone** is now validated against the customer's address (county and town), or derived from it. Nothing was invented: the schema already had the fields.
- **Function privileges** are stated explicitly for every function. `has_role()`/`is_staff()` no longer work for anon and only answer about the caller.
- **Inactive data** no longer leaks from `validate_cart()` or `validate_delivery_selection()`.
- No payment-provider, webhook or payments table was built. That is still future work.

Six decisions need your approval before applying (section 15 / "Design decisions"). The most important: online-payment orders (M-Pesa/card) cannot be moved into fulfilment by anyone in the browser until payment verification exists.

---

## 2. Vulnerability → Fix mapping

| #   | Finding (5B.1)                                   | Fix                                                                                                                                        | Where in the migration |
| --- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- |
| V1  | Staff could set `status` to `paid`/`refunded`    | `UPDATE` revoked on `orders` (table and columns), update policies dropped, new `set_order_status()` rejects `paid`/`refunded` for everyone | sections 4             |
| V2  | Stock inflation by cancel → pending → cancel     | `orders.restocked_at`; BEFORE trigger restocks once and re-reserves on reactivation                                                        | sections 1, 5          |
| V3  | Staff ≈ admin                                    | `is_admin()`; five config tables get admin-only INSERT/UPDATE policies; override path admin-only                                           | sections 2, 3, 4       |
| V4  | Customer picks any zone                          | `create_order()` loads the address first, derives or validates the zone against it                                                         | sections 6, 7          |
| V5  | `has_role()`/`is_staff()` public, probe any user | PUBLIC/anon revoked; functions answer only about the caller                                                                                | sections 2, 9          |
| V6  | Validators return inactive data                  | Inactive products return no row; inactive variant/method/zone return no data                                                               | section 8              |

---

## 3. Order status authorization

**Before:** `grant update (status)` plus policy `Orders: staff update` let any staff session write any enum value directly through the API.

**After:**

- `revoke update` on `public.orders` from `authenticated` and `anon`, at table and column level (`status`, `restocked_at`). All `UPDATE`/`ALL` policies on `orders` are dropped. A self-check at the end of the migration aborts if any browser role can still update any column.
- The only browser path is `public.set_order_status(order_id, new_status, note)`. `SECURITY DEFINER`, `authenticated` only. It requires `is_staff(auth.uid())`, locks the order row, and validates the transition.
- The existing triggers (capacity guard, restock, history log, `updated_at`) still fire.

**Standard transitions (staff or admin):**

| From                           | To                                                                |
| ------------------------------ | ----------------------------------------------------------------- |
| pending                        | processing, cancelled                                             |
| awaiting_payment               | cancelled                                                         |
| paid                           | processing, cancelled (only reachable by a future server process) |
| processing                     | picking, cancelled                                                |
| picking                        | packed, cancelled                                                 |
| packed                         | dispatched, cancelled                                             |
| dispatched                     | out_for_delivery, delivered, cancelled                            |
| out_for_delivery               | delivered, cancelled                                              |
| delivered, cancelled, refunded | none                                                              |

**Admin behaviour (explicit):**

- Admin can do everything staff can.
- Admin has a **manual administrative override**: from any status except `refunded` to any status except `paid`/`refunded`. A reason of at least 3 characters is required. It is logged in `order_status_history` as `Admin override: <reason>` with the admin's id. It is a correction tool, **not payment verification**.
- The override is how a cancelled order is reactivated (see section 4).

**Rules that apply to everyone, admin included:**

- `paid` and `refunded` are rejected (`payment_state_reserved`).
- **Payment gate:** an M-Pesa/card order whose `payment_status` is not `paid` can only be `awaiting_payment` or `cancelled`. `pending` is reserved for cash on delivery.
- Customers fail at `is_staff()` (`not_authorised`, SQLSTATE 42501).

Error codes (exception DETAIL): `not_authorised`, `payment_state_reserved`, `transition_not_allowed`, `admin_note_required`, `payment_not_confirmed`, `payment_method_mismatch`, `order_not_found`, `note_too_long`, `invalid_arguments`.

---

## 4. Restocking / idempotency

- New column `orders.restocked_at timestamptz` (NULL = order currently holds its stock). Only the trigger, the service role or the SQL editor can write it.
- `restock_cancelled_order()` is now a **BEFORE** trigger so it can stamp the row in the same update.
  - Entering `cancelled` from a stock-holding status (not cancelled/refunded/delivered): restock **only if `restocked_at` is NULL**, then set it.
  - Leaving `cancelled`/`refunded` for an active status while `restocked_at` is set: **re-reserve** the stock (error `reactivation_insufficient_stock` and full rollback if there is not enough), then clear `restocked_at`.
  - Net effect: any cancel/reactivate cycle leaves stock unchanged. Cancelled → refunded → cancelled does not restock twice.
- **Concurrency:** the UPDATE holds the order row lock, and `set_order_status()` also takes `FOR UPDATE`. A second simultaneous attempt waits, then sees the committed row (status already cancelled, `restocked_at` set). The reasoning is sound under READ COMMITTED; a two-session run on the local scratch database confirmed it (section 13).
- **Backfill:** orders that are cancelled/refunded now and whose history shows a cancellation out of a stock-holding state get `restocked_at` set to that time, so the new trigger does not restock them again. This relies on `order_status_history` being complete. Orders cancelled before that history existed would be treated as not restocked. Check with the query in "Before you apply".
- Existing capacity safeguards are intact: the slot capacity guard on reactivation still runs first (tested), and `create_order()` stock reservation is unchanged (tested).

---

## 5. Staff vs admin

|                                                                          | Customer | Staff                        | Admin                               |
| ------------------------------------------------------------------------ | -------- | ---------------------------- | ----------------------------------- |
| Read own orders                                                          | yes      | yes                          | yes                                 |
| Read all orders/items/history                                            | no       | yes                          | yes                                 |
| Move an order along the workflow, or cancel it                           | no       | **yes** (`set_order_status`) | yes                                 |
| Manual status override with a reason, reactivate a cancelled order       | no       | no                           | **yes**                             |
| Mark paid / refunded                                                     | no       | no                           | **no**                              |
| Read inactive delivery configuration                                     | no       | yes                          | yes                                 |
| Write delivery methods, zones, zone fees, slot templates, slot overrides | no       | **no**                       | **yes**                             |
| Read all `user_roles`                                                    | no       | no                           | yes (unchanged)                     |
| Grant roles                                                              | no       | no                           | no (service role / SQL editor only) |

- `is_staff()` is true for staff **and** admin. `is_admin()` is new and true for admin only.
- Every write policy on the five configuration tables was replaced by an admin-only INSERT and UPDATE policy (any other write policy on those tables is dropped, whatever its name). Staff keep their "read all" policies.
- Staff workflows preserved: reading all orders, fulfilment status changes, cancelling, reading configuration. The app has no staff screen that writes configuration (`src/features/delivery/admin.ts` has no route), so nothing in use is removed. Slot overrides are admin-only because they change availability; if staff need to close a slot day-to-day, that is a decision for you (below).

---

## 6. Delivery-zone validation

**What the schema has:** `addresses.county` and `addresses.city` (both NOT NULL, customer-typed) and `delivery_zones.county` (nullable) and `delivery_zones.towns` (text array, admin-maintained). That is enough to validate a zone by name, so **no schema change was made for this fix**.

**Rule (`delivery_zone_covers_address`):** an active zone covers an address when the zone states at least one place, **and** if it names a county it equals the address county, **and** if it lists towns the address city is one of them. Comparison ignores case and extra whitespace. A zone with neither county nor towns covers nothing (fail closed).

**`create_order()` now, for address delivery:**

1. Loads the customer's own address first.
2. Finds the active zones that cover it.
3. No zone sent: uses the single covering zone; none → `zone_unserviceable`; several → `zone_required`.
4. Zone sent: it must be one of the covering zones, otherwise `zone_address_mismatch`. Unknown/inactive zones still give `zone_unknown`/`zone_inactive`.
5. Prices the order with that validated zone only. The expected-total veto, snapshot, slot lock and everything else are unchanged.

For a method **without** an address, a supplied zone is never used for pricing or stored (it can no longer pull a zone fee rule into a pickup order). An unknown or inactive one is still rejected, as before.

**Limits you should know:**

- The address is customer-typed text. A customer can still _type_ "Westlands" as their city to qualify for the Westlands zone. The fix stops zone and address disagreeing and makes the order record consistent and auditable. It does not prove the address is real. See Remaining risks.
- The checkout _quote_ (`validate_delivery_selection`) does not know the address, so a customer can still see a cheap quote for the wrong zone; the order is then refused at placement with `zone_address_mismatch`.

---

## 7. Function / RPC security

| Class | Meaning            | Functions                                                                                                                                                                                                                                                    | anon | authenticated |
| ----- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---- | ------------- |
| A     | client callable    | `validate_cart`, `validate_delivery_selection`, `validate_delivery_slot`, `get_delivery_slot_availability`, `resolve_delivery_fee`                                                                                                                           | yes  | yes           |
| B     | authenticated only | `create_order`, `set_order_status`, `has_role`, `is_staff`, `is_admin`                                                                                                                                                                                       | no   | yes           |
| C     | internal           | `delivery_slot_booked_count`, `delivery_slot_effective_capacity`, `delivery_slot_evaluate`, `delivery_slot_acquire_lock`, `lock_delivery_slot`, `next_order_number`, `order_status_holds_delivery_slot`, `delivery_text_key`, `delivery_zone_covers_address` | no   | no            |
| D     | trigger only       | `restock_cancelled_order`, `log_order_status_change`, `guard_order_reactivation_capacity`, `handle_new_user`, `handle_user_email_change`, `set_updated_at`, `addresses_single_default`                                                                       | no   | no            |

- Each function gets an explicit `REVOKE ALL ... FROM PUBLIC, anon, authenticated` followed by only the grants above. (Supabase default privileges grant EXECUTE to anon/authenticated directly, so naming them matters.) `service_role` is never revoked.
- **Role helpers:** `authenticated` must keep EXECUTE because RLS policy expressions run with the caller's privileges. They now return true only for the caller's own id (or any id for `service_role`). A user asking about someone else gets `false`.
  - Side effect: running `select is_staff('<some uuid>')` in the SQL editor now returns false. Query `public.user_roles` directly there.
- **search_path:** every SECURITY DEFINER function, and the invoker helpers, now use `public, pg_temp`. The migration's self-check fails if any definer function in `public` lacks it.
- Trigger functions: PostgreSQL checks EXECUTE when a trigger is created, not each time it fires, so revoking does not stop triggers. Tested (profile update, default-address change, new-user profile creation, email sync all still work).
- The migration ends with a **self-check** that aborts and rolls everything back if: any browser role can UPDATE `orders`, an UPDATE policy remains, RLS is off on a protected table, anon can execute a non-class-A function, authenticated lost a required one, or a definer function has no pinned search_path.

---

## 8. Inactive-data filtering

- `validate_cart()`:
  - inactive or unknown product → no row at all (the basket already shows "no longer sold" for a missing row; the caller learns nothing)
  - inactive variant of an active product → `available=false`, `variant_unavailable`, **NULL price and stock**; the row carries the variant id the caller sent so the basket can label the line
  - active items behave as before
  - more than 100 lines is refused (same cap as `create_order`)
- `validate_delivery_selection()`: an inactive/unknown method or zone still returns `is_valid=false` with its error code, but method label/flags and zone id/code/name come back **NULL**. No fee fields are returned for a rejected selection (as before).
- `create_order()` already rejected inactive products, variants, methods and zones; unchanged.
- Historical orders are untouched: nothing in the migration rewrites order rows except setting `restocked_at` in the backfill (with `updated_at` left alone).

---

## 9. Payment scope and remaining work

Implemented: only what stops anyone in the browser from creating payment state.

- Customers cannot change an order at all.
- Staff and admin cannot set `paid` or `refunded`, and cannot fulfil an unpaid online order.
- `payment_status` has no browser writer (as before).
- `set_order_status` and the history note are not payment events.

**Still future work (not implemented):** a payments/transactions table; a server-only payment provider integration (M-Pesa STK push, card gateway); a verified webhook that checks signature, amount, currency and order id; the single server path (service role) that sets `payment_status = 'paid'` and then `status = 'paid'`; refunds; recording cash-on-delivery payment; unpaid-order expiry (unpaid orders still hold stock and slots indefinitely); server-only secrets. Until then, an online-payment order stays `awaiting_payment` and can only be cancelled from the browser.

---

## 10. Files changed

Created:

- `db/migrations/20261003010000_phase5b2_security_authorization_hardening.sql` (1,417 lines)
- `db/tests/phase5b2_security_authorization_hardening.test.sql` (822 lines)
- `phase5b2_security_fix_report.md` (this file)

Changed: **none.** No old migration, old test or application source file was edited.

## 11. Migration name

`20261003010000_phase5b2_security_authorization_hardening.sql` — one transaction (`begin` … `commit`), apply once. It refuses to run twice (it looks for `orders.restocked_at`) and refuses to run if `create_order()` in the target database is not the 12-argument version from migration 060000.

## 12. Test name

`db/tests/phase5b2_security_authorization_hardening.test.sql` — 166 checks, one transaction, ends with `ROLLBACK`. Covers every item in your list: customer, staff, admin, restocking, delivery, functions and regression. Users are simulated by setting the JWT settings and `SET LOCAL ROLE`, so privileges, RLS and `auth.uid()` behave as in PostgREST.

---

## 13. Verification results

**Against the dedicated Phase-5 development Supabase database: not run. Nothing is verified there.**

What I did run, on a throwaway local PostgreSQL 16 with a small Supabase-style shim (roles `anon`/`authenticated`/`service_role`, an `auth` schema with `auth.uid()`/`auth.role()`, default EXECUTE privileges on functions). It was built from migrations 000000 → 080000 plus the new one. It is **not** Supabase and does not contain Phase 5A.2.

| Check                                                                                                                             | Result                                                              |
| --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Migration applies cleanly on top of 000000–080000                                                                                 | pass                                                                |
| Re-running the migration                                                                                                          | refused by its precondition, as designed                            |
| New test on the migrated database                                                                                                 | **pass, 166 checks, 0 failures**                                    |
| New test on a database with only the old migrations                                                                               | fails (the new function does not exist), as it should               |
| Mutation checks: grant UPDATE(status) back to `authenticated` / grant `is_staff` to anon / disable the restock trigger            | each makes the test fail                                            |
| Test leaves no fixtures behind                                                                                                    | confirmed (rolled back)                                             |
| Two real sessions cancelling the same order at once (committed fixtures, row-lock wait observed)                                  | stock restored once: 6 → 10 for a 4-unit order                      |
| Older tests (create_order_delivery, delivery_validation, delivery_slot_validation, order_reactivation_capacity) on the old schema | all four pass, so the scratch setup reproduces your earlier results |
| The same four older tests after the new migration                                                                                 | **all four now fail, for expected reasons** (below)                 |

**Older tests that need their fixtures updated (I did not edit them):**

- `create_order_delivery.test.sql` — its zones have no county/towns, so address delivery with no zone now returns `zone_unserviceable` instead of `zone_required`, and mismatch rules apply. Give its zones a county/towns and addresses to match.
- `delivery_validation.test.sql`, `delivery_slot_validation.test.sql` — a "staff edit" step writes delivery configuration; that is now admin-only. Run those steps as an admin.
- `order_reactivation_capacity.test.sql` — staff change `orders.status` with a direct UPDATE; that no longer exists. Use `set_order_status()` or run as the table owner.

Not run: the app's TypeScript tests, any front-end check, the repo's `.sh` concurrency scripts, Postgres 15 / real Supabase behaviour (JWT claim handling, Supabase default privileges, Phase 5A.2).

**To verify properly:** apply the migration to the Phase-5 dev database, run the new test with `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase5b2_security_authorization_hardening.test.sql`, and expect `ALL PHASE 5B.2 TESTS PASSED`. Then fix and re-run the four older tests above.

### Before you apply (read-only checks on the dev database)

1. Phase 5A.2 files were **not** in the zip I received. Compare the live `create_order` with migration 060000: `select pg_get_functiondef('public.create_order(jsonb,text,public.payment_method,uuid,date,time,time,text,text,text,integer,uuid)'::regprocedure);`. If 5A.2 changed it, tell me before applying, because this migration replaces it.
2. Zones that would become unusable for address delivery: `select code, name from public.delivery_zones where is_active and coalesce(btrim(county),'') = '' and not exists (select 1 from unnest(towns) t where btrim(t) <> '');`. Give each a county and/or towns first.
3. Orders the backfill will mark as already restocked: `select count(*) from public.orders o where o.status in ('cancelled','refunded') and exists (select 1 from public.order_status_history h where h.order_id = o.id and h.new_status='cancelled' and h.previous_status not in ('cancelled','refunded','delivered'));`
4. Any code outside this repo (Edge Functions, scripts, dashboards) that updates `orders` directly will stop working. None exists in the repo.

---

## 14. Remaining risks

- **Typed addresses (V4 residual).** A customer can type a city and county that match a cheap zone. Fixing that needs a verified source: zone chosen by map pin/geocode, an admin-verified address, or dispatch checking. Needs your decision.
- **Quote vs order.** Checkout can still _show_ a fee for a zone that the order will then reject. A front-end change (pass the address to the quote, or derive the zone in the UI) would remove the surprise.
- **Online payment orders cannot be fulfilled** until payment verification exists (by design).
- **Unpaid orders hold stock and slots indefinitely** (no expiry job).
- **Cash-on-delivery payment is never recorded**; `payment_status` stays `pending` after delivery.
- **Admin is powerful and unaudited beyond status history.** Configuration changes are not logged. An admin can still override fulfilment status with a reason. Consider MFA for staff/admin.
- **Service role / SQL editor are unrestricted** (by design), but the triggers still guard capacity and stock for them.
- **New error codes** `zone_unserviceable`, `zone_address_mismatch` (and the status codes above) are not in the front-end's code list. Checkout will show the database message for the two zone codes; add proper copy in `src/features/delivery/checkout.ts`. `src/lib/supabase/types.ts` also needs `set_order_status`, `is_admin` and `orders.restocked_at`.
- **Phase 5A.2 baseline** is only approximated by generic privilege checks in the test; add 5A.2's own assertions once its files are available.
- Residual from 5B.1 not in scope here: rate limiting/sign-up controls, `profiles` insert column list, `.output/` shipped in zips.

---

## 15. Explicitly NOT implemented

- No payment provider, M-Pesa, card, PayPal or Stripe integration.
- No webhook route, payments table, refund flow or `payment_status` writer.
- No unpaid-order expiry, COD payment recording, or payment secrets/configuration.
- No front-end changes (no checkout copy for new error codes, no admin UI, no `types.ts` update).
- No geocoding or address verification; no change to the `addresses` or `delivery_zones` schema.
- No edits to old migrations or old tests; no rerun of old migrations or Phase 5A.1/5A.2.
- No live SQL against the Phase-5 dev database; no secrets touched.

### Design decisions that need your approval

1. **`paid`/`refunded` are not settable by anyone in the browser, admin included.** If you want an admin-only manual "mark paid" for the interim (e.g. you confirm M-Pesa on the till statement), say so; I would add it as a separate, loudly logged override, not as payment verification.
2. **Online orders can only be cancelled until payment is built.** The checkout already defaults to cash on delivery because M-Pesa/card are marked not connected.
3. **Cancelled orders can be reactivated by admin only** (with stock re-reserved and a reason). Staff cannot undo a cancellation.
4. **Slot overrides and slot templates are admin-only.** If staff should be able to close a slot for a day, tell me and I will allow staff to write overrides only.
5. **Zones with no county and no towns can no longer be used for address delivery** (fail closed). Alternative: add an explicit "covers everywhere" flag to zones (a small schema change).
6. **`has_role`/`is_staff` answer only about the caller**, so SQL-editor calls with an explicit user id return false.

### Could not safely be fixed with the existing schema

- Proving a customer's typed address is real (needs geocoding, a verified address source or dispatch-time checks).
- Anything involving payment verification (no payment infrastructure exists).
