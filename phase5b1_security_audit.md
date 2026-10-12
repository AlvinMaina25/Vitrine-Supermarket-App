# Phase 5B.1 — Security Audit: Functions, RPCs, Secrets & Payments

**Mode:** audit only. Nothing in the database or application was changed. No SQL was executed.
**Basis:** static review of the uploaded repository (`SUPERMARKET_WEBSITE_phase4c2_final_2.zip`): 9 migrations in `db/migrations/`, `db/tests/`, `src/`, config files and the shipped `.output/` build.
**Rating key:** **CONFIRMED** = the repository code itself proves it. **POTENTIAL** = depends on live state or future code. **SAFE** = control found and it holds on reading.

---

## Executive Summary

The core money path is well built. `create_order()` recomputes prices, stock, delivery fee and total on the server. The browser sends only product ids, quantities, a zone id and an "expected total" that can veto an order but never set an amount. Customers cannot write to `orders`, `order_items`, `user_roles` or payment columns. No real secrets were found in the repo.

The significant problems are about **staff power and missing payment plumbing**, not customers:

| #   | Finding                                                                                                                                                                          | Rating              | Severity           |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------------ |
| V1  | Any **staff** user can set `orders.status` to `paid` or `refunded` (and any other value) straight from the browser. There is no staff/admin split and no payment-provider check. | CONFIRMED           | **High**           |
| V2  | Staff can **inflate stock** by cycling an order `cancelled → pending → cancelled`. Each cancel adds stock back; reactivation never takes it again.                               | CONFIRMED           | **High** (insider) |
| V3  | **Staff = admin in practice.** The `admin` role only gates reading `user_roles`. Staff can edit delivery fees, zones, methods and slots.                                         | CONFIRMED           | Medium             |
| V4  | Customer **chooses the delivery zone**. Nothing ties it to the address, so a customer can pick the cheapest active zone for any address.                                         | CONFIRMED           | Medium             |
| V5  | `has_role()` and `is_staff()` are **not revoked from PUBLIC**, so anonymous callers can probe any user id's role. Information exposure only, not a bypass.                       | CONFIRMED (in code) | Low                |
| V6  | `validate_cart()` and `validate_delivery_selection()` (SECURITY DEFINER, anon-callable) return **inactive** product and delivery data when given the id or code.                 | CONFIRMED           | Low                |

There is **no payment integration yet** (no webhook, no server function, no payment table). So "who may mark an order paid" is currently answered by "staff, via a raw status update". That must be fixed before M-Pesa or card goes live.

No service-role key, database password, payment key or webhook secret exists anywhere in the repo. The only real-looking values are a Supabase project URL and a **publishable** key inside the `.output/` build. Those are public by design.

---

## 1. Function/RPC Inventory

"Anon/Auth Execute" is what the **migration files** grant. Supabase also applies default privileges in the live project. Where a function is not revoked from `PUBLIC`, the live state could be broader than shown. `service_role` can execute everything (it owns or bypasses grants).

| Function                                             | Security Mode       | Anon Execute                 | Auth Execute    | Ownership Check                                                     | Role Check                | Writes Data                                     | Risk                  |
| ---------------------------------------------------- | ------------------- | ---------------------------- | --------------- | ------------------------------------------------------------------- | ------------------------- | ----------------------------------------------- | --------------------- |
| `create_order(...12 args)`                           | DEFINER             | No (revoked)                 | Yes             | Yes: `auth.uid()`, address `user_id = v_user`, idempotency per user | No (not needed)           | Yes: orders, order_items, product/variant stock | Low                   |
| `validate_cart(jsonb)`                               | DEFINER, stable     | **Yes**                      | Yes             | No                                                                  | No                        | No                                              | Low (V6)              |
| `has_role(uuid, app_role)`                           | DEFINER, stable     | **Yes (PUBLIC not revoked)** | Yes (explicit)  | No: accepts any `_user_id`                                          | n/a (is the check)        | No                                              | Low (V5)              |
| `is_staff(uuid)`                                     | DEFINER, stable     | **Yes (PUBLIC not revoked)** | Yes (explicit)  | No: accepts any `_user_id`                                          | n/a                       | No                                              | Low (V5)              |
| `resolve_delivery_fee(text, uuid, int)`              | **INVOKER**, stable | Yes                          | Yes             | No                                                                  | No                        | No                                              | Low                   |
| `validate_delivery_selection(text, uuid, int)`       | DEFINER, stable     | **Yes**                      | Yes             | No                                                                  | No                        | No                                              | Low (V6)              |
| `validate_delivery_slot(date, time, time)`           | DEFINER, stable     | Yes                          | Yes             | No                                                                  | No                        | No                                              | Low                   |
| `get_delivery_slot_availability(date, date)`         | DEFINER, stable     | Yes                          | Yes             | No                                                                  | No                        | No                                              | Low (aggregates only) |
| `lock_delivery_slot(date, time, time)`               | DEFINER, volatile   | No (revoked)                 | No (revoked)    | n/a                                                                 | n/a                       | No (advisory lock only)                         | Low                   |
| `delivery_slot_acquire_lock(...)`                    | DEFINER, volatile   | No                           | No              | n/a                                                                 | n/a                       | No (advisory lock)                              | Low                   |
| `delivery_slot_evaluate(...)`                        | DEFINER, stable     | No                           | No              | n/a                                                                 | n/a                       | No                                              | Low                   |
| `delivery_slot_effective_capacity(uuid, date)`       | DEFINER, stable     | No                           | No              | n/a                                                                 | n/a                       | No                                              | Low                   |
| `delivery_slot_booked_count(...)`                    | DEFINER, stable     | No                           | No              | n/a                                                                 | n/a                       | No                                              | Low                   |
| `order_status_holds_delivery_slot(status)`           | INVOKER, immutable  | No                           | No              | n/a                                                                 | n/a                       | No                                              | Low                   |
| `next_order_number()`                                | INVOKER, volatile   | No                           | No              | n/a                                                                 | n/a                       | Yes: advances a sequence                        | Low                   |
| `restock_cancelled_order()` (trigger)                | DEFINER             | No                           | No              | n/a                                                                 | Runs on any status change | Yes: product/variant stock                      | **Medium (V2)**       |
| `log_order_status_change()` (trigger)                | DEFINER             | **Not revoked**              | **Not revoked** | n/a                                                                 | n/a                       | Yes: `order_status_history`                     | Low                   |
| `guard_order_reactivation_capacity()` (trigger)      | DEFINER             | No                           | No              | n/a                                                                 | n/a                       | No                                              | Low                   |
| `handle_new_user()` (trigger on auth.users)          | DEFINER             | No                           | No              | n/a                                                                 | n/a                       | Yes: `profiles` insert                          | Low                   |
| `handle_user_email_change()` (trigger on auth.users) | DEFINER             | No                           | No              | n/a                                                                 | n/a                       | Yes: `profiles.email`                           | Low                   |
| `set_updated_at()` (trigger)                         | INVOKER             | Not revoked                  | Not revoked     | n/a                                                                 | n/a                       | Sets `updated_at` only                          | Low                   |
| `addresses_single_default()` (trigger)               | INVOKER             | Not revoked                  | Not revoked     | Via RLS                                                             | n/a                       | Yes: clears other defaults                      | Low                   |

**No additional custom functions** were found beyond the 14 you listed plus these helpers: `handle_user_email_change`, `delivery_slot_booked_count`, `delivery_slot_effective_capacity`, `delivery_slot_evaluate`, `delivery_slot_acquire_lock`, `lock_delivery_slot`, `validate_delivery_slot`, `order_status_holds_delivery_slot`.

**Dynamic SQL:** none. A search for `EXECUTE` and `format()` found only trigger declarations and one `format()` that builds an error message string. There is no SQL injection surface in the functions.

**Parameter abuse notes**

- `create_order`: basket is capped at 100 lines and 1–99 per line. Quantities are merged, rows are locked in a stable order, prices are read from locked rows. Notes are limited to 1000 characters by a table constraint. SAFE.
- `get_delivery_slot_availability`: range capped at 31 days. SAFE against scanning.
- `validate_cart`: no cap on `p_items` length, so an anonymous caller can send a very large array. POTENTIAL resource abuse (low).
- Trigger functions cannot be called through the RPC endpoint (PostgreSQL rejects direct calls). The missing revokes on `log_order_status_change`, `set_updated_at` and `addresses_single_default` are hygiene, not an exposure.

---

## 2. SECURITY DEFINER Audit

All DEFINER functions set `search_path = public` (SAFE against the classic search-path hijack). None adds `pg_temp` last, which is a hardening recommendation. The function **owner** is not stated in any migration, so it will be whoever ran the migration in the SQL editor (normally `postgres`). That cannot be confirmed from the repo.

| Function                                                                             | search_path | Privileges (per files)                                      | Authorization                                                                          | Inputs                                                                                                 | Data access                                                       | Risk                                                                                    |
| ------------------------------------------------------------------------------------ | ----------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `create_order`                                                                       | `public`    | revoked from public/anon; granted to authenticated          | `auth.uid()` required (errcode 42501 if null). Address filtered by `user_id = v_user`. | items jsonb, method, payment method, address id, slot, notes, idempotency key, expected total, zone id | Reads and updates products and variants; inserts orders and items | Low. The `exception when unique_violation` handler only returns the caller's own order. |
| `validate_cart`                                                                      | `public`    | revoked from public; granted to anon, authenticated         | none                                                                                   | items jsonb                                                                                            | Reads products and variants **without an `is_active` filter**     | Low. Leaks inactive items by id (V6).                                                   |
| `has_role` / `is_staff`                                                              | `public`    | **no revoke from PUBLIC**; explicit grant to authenticated  | none; caller supplies the user id                                                      | any uuid                                                                                               | Reads `user_roles`                                                | Low (V5)                                                                                |
| `validate_delivery_selection`                                                        | `public`    | revoked from public; granted to anon, authenticated         | none                                                                                   | method code, zone id, subtotal                                                                         | Reads methods and zones regardless of `is_active`                 | Low. Returns label/name of inactive rows (V6).                                          |
| `validate_delivery_slot`, `delivery_slot_evaluate`, `get_delivery_slot_availability` | `public`    | first and last granted to anon/auth; `evaluate` is internal | none                                                                                   | dates/times                                                                                            | Reads templates, overrides and counts orders                      | Low. Only aggregates (capacity, booked, remaining).                                     |
| `lock_delivery_slot`, `delivery_slot_acquire_lock`                                   | `public`    | internal only                                               | none                                                                                   | slot identity                                                                                          | advisory lock                                                     | Low                                                                                     |
| `delivery_slot_booked_count`, `delivery_slot_effective_capacity`                     | `public`    | internal only                                               | none                                                                                   | slot identity                                                                                          | counts orders / reads capacity                                    | Low                                                                                     |
| `restock_cancelled_order`                                                            | `public`    | trigger only                                                | none: fires on any status change by anyone who can update `orders`                     | row                                                                                                    | updates product and variant stock                                 | **Medium (V2)**                                                                         |
| `log_order_status_change`                                                            | `public`    | not revoked                                                 | uses `auth.uid()` for `changed_by`                                                     | row                                                                                                    | inserts history                                                   | Low. Uses `auth.uid()` so a service-role change is logged with a null actor.            |
| `guard_order_reactivation_capacity`                                                  | `public`    | trigger only                                                | none                                                                                   | row                                                                                                    | reads templates, overrides, counts                                | Low. Correct capacity protection; does not check stock or payment.                      |
| `handle_new_user`, `handle_user_email_change`                                        | `public`    | trigger only                                                | n/a                                                                                    | `raw_user_meta_data` (name, phone, trimmed and length-limited)                                         | writes `profiles`                                                 | Low. No role or privileged field is copied from metadata.                               |

---

## 3. Staff/Admin Authorization

**Roles exist:** enum `app_role = customer | staff | admin`, stored in `public.user_roles`, separate from `profiles`. SAFE design.

**How roles are protected**

- `user_roles`: browser has `SELECT` only; RLS allows reading own rows, and admins reading all. There is **no INSERT/UPDATE/DELETE grant or policy** for `authenticated`. A user cannot grant themselves a role. SAFE.
- Roles are assigned only through the SQL editor / service role (documented in the migration comment).

**Where authorization is enforced:** in the database. Every staff policy calls `is_staff(auth.uid())`. The front end only uses `isStaff()` to show or hide controls, and says so in `roles.ts`. There are **no admin or staff routes** in `src/routes/`, and no code anywhere updates `orders`. `src/features/delivery/admin.ts` contains the delivery-config writers but nothing renders them yet.

**Customer vs staff vs admin today**

| Capability                                                                  | Customer       | Staff                              | Admin                  |
| --------------------------------------------------------------------------- | -------------- | ---------------------------------- | ---------------------- |
| Read own orders                                                             | Yes            | Yes                                | Yes                    |
| Read all orders, items, history                                             | No             | Yes                                | Yes                    |
| Update `orders.status` (any value)                                          | No (no policy) | **Yes**                            | **Yes**                |
| Update `orders.payment_status` or money columns                             | No             | No (column grant is `status` only) | No                     |
| Insert/update delivery methods, zones, zone fees, slot templates, overrides | No             | **Yes**                            | Yes                    |
| Read all `user_roles`                                                       | No             | No                                 | Yes (only difference)  |
| Change roles                                                                | No             | No                                 | No (service role only) |

**V1 — CONFIRMED VULNERABILITY: staff can set `status` to `paid` / `refunded`**

- Mechanism: policy `Orders: staff update` (010000, lines 308–312) plus `grant update (status) on public.orders to authenticated` (020000, line 425). The column `status` is the full `order_status` enum, which includes `paid` and `refunded`.
- Authorization is database-side, so a staff account can call the REST API directly, with no UI needed. A customer cannot (no update policy).
- No provider event is required. The migration itself says "Decide before building an admin UI whether staff may set those from the browser."
- Partial mitigation: `payment_status` cannot be changed from the browser, so an order set to `paid` still shows `payment_status = pending`. The UI says an order is only "paid" when `payment_status = 'paid'` (`status.ts`). But a staff member can mark an unpaid online order `paid`, release it for fulfilment, or set `refunded`, and the trigger will silently treat it as non-holding (see below).
- `refunded` also releases the delivery slot (`order_status_holds_delivery_slot`). It does **not** restock (restock excludes `refunded`).
- Staff cannot do this to a _different_ column to forge totals, since money columns are immutable from the browser.

**V2 — CONFIRMED VULNERABILITY (insider): stock inflation**

- `restock_cancelled_order` adds stock back whenever status moves into `cancelled` from anything except `cancelled`, `refunded` or `delivered`.
- Moving an order out of `cancelled` does **not** take the stock again (documented in the 020000 comments).
- So staff can repeat `cancelled → pending → cancelled` and add the order's quantities to stock each time. `guard_order_reactivation_capacity` only checks slot capacity, not stock.
- Evidence is by reading the triggers. It was not run.

**V3 — CONFIRMED: no real staff/admin separation.** `is_staff()` returns true for staff **and** admin. Only one policy uses `has_role(...,'admin')`. Staff can set `delivery_zone_fees.fee_cents` to 0, change `free_over_cents`, activate/deactivate zones, or close slots. Those changes feed straight into customer fees. This may be intended for a small team but it is not "admin only".

**SAFE:** a customer cannot read other customers' orders (`user_id = auth.uid()`), nor update anything on `orders`.

---

## 4. Payment Security

**What exists:** `orders.payment_status` (`pending | processing | paid | failed | cancelled | refunded | partially_refunded`), `orders.payment_method` (`mpesa | card | cash_on_delivery`), and `src/features/checkout/payment-providers.ts`, a registry where M-Pesa and card are `connected: false`.

**What does not exist:** no webhook route (`src/routes/api/` is absent), no server function, no payments/transactions table, no provider credentials, no signature verification, no payment record to tamper with.

| Question                                                | Current answer                                                                                                                                                                                                                                |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Where is payment status changed?                        | Only in `create_order()` (inserts `payment_status = 'pending'`). Nothing else writes it.                                                                                                                                                      |
| Who may change it?                                      | Browser roles: nobody (no column grant). Only `service_role` / SQL editor. SAFE.                                                                                                                                                              |
| Are amount, currency, order id trusted from the client? | No. Total is computed in the database. Currency defaults to `KES` in the table. The client sends only `expectedTotalCents`, which can only reject the order. SAFE.                                                                            |
| Does payment confirmation use provider verification?    | Not applicable yet: no provider is integrated. **The planned design in `AGENTS.md` ("only verified server webhooks mark paid") is not enforced by the database.** V1 shows `orders.status = 'paid'` can be set by staff with no verification. |
| Can a user mark their own order paid?                   | No. No customer update policy or grant. SAFE.                                                                                                                                                                                                 |
| Can staff mark orders paid/refunded?                    | **Yes, via `status`** (V1). Not via `payment_status`.                                                                                                                                                                                         |
| Can payment records be modified directly?               | There is no payment table. `payment_status` is protected from the browser.                                                                                                                                                                    |
| Are payment credentials server-only?                    | None exist yet. Future M-Pesa/card secrets must go in server-only env (not `VITE_*`).                                                                                                                                                         |
| Can a customer create an order and choose how they pay? | Yes: `p_payment_method` is customer-chosen. `cash_on_delivery` starts as `pending`; `mpesa` and `card` start as `awaiting_payment`. Both leave `payment_status = pending`. No money is claimed collected. SAFE.                               |

**POTENTIAL RISKS**

- **Unpaid-order stock hold.** `awaiting_payment` orders reserve stock and delivery slots indefinitely. There is no expiry job. A signed-in user could place many M-Pesa/card orders and hold inventory or slots. Whether anyone can sign up depends on Supabase Auth settings, which this audit could not see.
- Status and payment status are separate lifecycles with no consistency rule (e.g. nothing forbids `status = delivered` with `payment_status = failed`).

---

## 5. Secret/Credential Audit

Search covered: `service_role`, `SERVICE_ROLE`, anon/publishable keys, Supabase URLs, `DATABASE_URL`, `postgres://`, JWT-shaped strings, `sb_secret_`, M-Pesa/consumer key/passkey, PayPal, Stripe, webhook, bearer tokens, private keys. Scanned: source, tests, migrations, docs, config, `public/`, and the `.output/` build. Values are not printed.

| File / location                                                                | Type                                                                                                                  | Real or placeholder                                                           | Client-exposed? | Verdict / action                                                                                                         |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `.env.example` lines 2–3                                                       | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`                                                                  | **Placeholder** (key begins `your-…`; URL does not match the build's project) | n/a             | SAFE                                                                                                                     |
| `.output/public/assets/client-DkE0Xxca.js` (4 occurrences each of URL and key) | Supabase project URL `[REDACTED].supabase.co`; publishable key `sb_publishable_[REDACTED]`                            | **Real values baked into the build**                                          | Yes, by design  | SAFE in principle: publishable keys are meant to be public and are protected by RLS. Note the project ref is in the zip. |
| `.output/server/_ssr/client-D0lBQ3JP.mjs`                                      | Same URL and publishable key                                                                                          | Real                                                                          | Server bundle   | Same as above                                                                                                            |
| `.output/server/_libs/supabase__auth-js+tslib.mjs`                             | Reads `process.env.SUPABASE_SECRET_KEY`                                                                               | Library code, no value                                                        | No              | SAFE. The app never sets it.                                                                                             |
| `db/tests/*.sh`, `HANDOFF.md`, `db/tests/*.sql`                                | `DATABASE_URL` / `postgres://...`                                                                                     | Placeholders in usage comments (`postgres://...`)                             | No              | SAFE. Tests require the variable and say "DEV database".                                                                 |
| Anywhere                                                                       | `service_role` key, DB password, JWT secret, M-Pesa/PayPal/Stripe credentials, webhook secrets, access/refresh tokens | **Not found**                                                                 | —               | None                                                                                                                     |
| `.gitignore`                                                                   | ignores `.env`, `.env.*` (except example), `.output`, `.wrangler/`, `.dev.vars`                                       | —                                                                             | —               | SAFE                                                                                                                     |

Other observations

- **No `.env` file** is in the zip. The only `import.meta.env` / `process.env` reads in `src/` are the four `VITE_*` values in `src/lib/env.ts`. No secret is read through a `VITE_` name.
- `.output/` and `.wrangler/` are gitignored but **are in the zip**. If this zip is shared publicly they reveal the project URL. That is low risk, but do not distribute build output unnecessarily.
- `.wrangler/deploy/config.json` and `.output/server/wrangler.json` contain a Windows path and a worker name. No credentials.
- Git history could not be checked (the zip is not a git repository), so **committed-then-removed secrets cannot be ruled out**. See Section 12.
- The publishable key's safety depends entirely on RLS and function grants, which is what the rest of this report examines.

---

## 6. Delivery Security

**What the client submits:** `deliveryMethod` (code), `zoneId`, `addressId`, slot date/start/end, `expectedTotalCents`, plus items. Source: `create-order-args.ts`, `checkout.tsx`.

**What the server does with it**

- Method: looked up in `delivery_methods`; unknown or inactive is rejected. SAFE.
- Zone: must exist and be active; required when the method requires an address. SAFE for _existence/activity_.
- Fee and minimum order: read only from `validate_delivery_selection()` → `resolve_delivery_fee()`. The subtotal passed in is the server-computed one. The client cannot supply a fee. SAFE.
- Slot: validated and locked inside the order transaction (lead time, horizon, capacity). SAFE.
- Address: must belong to the caller. SAFE.

**V4 — CONFIRMED: the zone is chosen by the customer and never checked against the address.**

- `addresses` has no zone column, and `create_order()` does not compare `v_address.county/city` with the zone. The function comments and `create-order-args.ts` both state "There is no address → zone mapping".
- Effect: a customer with an address in a far-away area can select the cheapest active zone and pay that zone's fee. The expected-total check does not help, since the customer's expected total comes from the same selection.
- It also means a zone can be supplied with a pickup method (no address). The code validates it and uses any matching zone-fee rule, so a pickup order could pick up a zone-specific rule if one exists for `pickup`. POTENTIAL, depends on the data.
- Impact is revenue leakage and rider cost, not data exposure. Staff would need to catch it at dispatch time, using the order's address snapshot versus the stored zone.

**Inactive configuration selection:** blocked. Inactive methods and zones are rejected by `validate_delivery_selection()` (`method_inactive`, `zone_inactive`). SAFE.

**V6 — Exposure through the validators (CONFIRMED, low).**
`validate_delivery_selection()` is SECURITY DEFINER and anon-callable. For an _inactive_ method or zone it still returns the method label/flags or the zone id, code and name alongside the rejection. `validate_cart()` returns name, price and stock quantity for **inactive** products given a product id. Both need a known id or code. Method codes are guessable (e.g. `pickup`), zone and product ids are UUIDs. RLS is deliberately bypassed here, so this is a small leak of data the policies hide.

**Also observed:** `get_delivery_slot_availability` and `validate_delivery_slot` give anonymous callers slot capacity and booked counts. That is aggregate business information, not personal data.

---

## 7. Confirmed Vulnerabilities

Only items supported by repository evidence.

1. **V1 — Staff can set `orders.status` to `paid` or `refunded` from the browser, with no payment verification.** Evidence: `010000` lines 308–312 (policy), `020000` lines 421–425 (column grant and the author's own NOTE), `010000` enum lines 24–36. Authorization is database-side. Affects: any staff or admin account (or a stolen staff session). Severity: High.
2. **V2 — Stock inflation by status cycling.** Evidence: `020000` lines 370–412 (restock on every entry to `cancelled`), comment lines 366–368 and `070000` lines 71–73 (reactivation does not re-reserve stock). Severity: High for an insider, nothing for customers.
3. **V3 — No staff/admin distinction on commercially sensitive writes.** Evidence: `030000` policies for methods, zones, zone fees, templates and overrides all use `is_staff()`. Severity: Medium.
4. **V4 — Customer-selected delivery zone not validated against the address.** Evidence: `060000` lines 78–79 and 248–270; `create-order-args.ts`. Severity: Medium.
5. **V5 — `has_role()` / `is_staff()` executable by anon (PUBLIC not revoked).** Evidence: `010000` lines 84–113 (explicit grant to `authenticated` only, no `revoke ... from public`). Anyone can ask whether a given user id is staff or admin. This is **information exposure, not an authorization bypass**: policies call these with `auth.uid()`, which a caller cannot forge, and `user_roles` is not writable. Severity: Low. Live exposure also depends on Supabase default privileges.
6. **V6 — Inactive products and delivery config leak through `validate_cart()` and `validate_delivery_selection()`.** Severity: Low.

---

## 8. Potential Risks

(Not proven by the repo, or dependent on live settings/future code.)

- **P1 — Unpaid orders hold stock and slots with no expiry.** Needs a timeout/cancel job before real payments.
- **P2 — Future payment integration.** Nothing yet enforces that `payment_status` changes only from a verified provider event, or that `status` can't move to `paid` without `payment_status = 'paid'`.
- **P3 — Order status has no state machine.** Any status can go to any other (e.g. `delivered → pending`). Only the slot-capacity guard exists.
- **P4 — `validate_cart()` accepts unbounded input** for anonymous callers (resource abuse).
- **P5 — No rate limiting or abuse controls** visible for order creation, address creation or sign-ups. Depends on Supabase Auth settings (email confirmation, CAPTCHA), which were not visible.
- **P6 — SECURITY DEFINER search_path lacks `pg_temp`.** Hardening only.
- **P7 — `profiles` INSERT is granted on all columns** with only `id = auth.uid()` in the policy. The trigger normally creates the row first, so a customer-written profile `email` is unlikely, but it is not column-restricted.
- **P8 — Function ownership and live grants unverified.** Supabase default privileges can grant EXECUTE to `anon`/`authenticated` on new functions. Files that `revoke ... from public` only (not from `anon`/`authenticated` by name) could remain callable in the live project. Compare against the live `pg_proc` / `information_schema.routine_privileges` before relying on this report.
- **P9 — Staff accounts are a high-value target.** No MFA or role-expiry logic is visible. V1/V2/V3 make a compromised staff session costly.
- **P10 — Audit trail:** `changed_by` is `auth.uid()`, which is null for service-role changes, so provider-driven changes would show no actor.
- **P11 — Build output in the zip** reveals the project ref.

---

## 9. Safe Areas

- Prices, stock, subtotal, delivery fee and total are all computed in `create_order()` from locked rows; the client cannot set them. Check constraints enforce `total = subtotal + fee − discount`.
- Customers have **no** UPDATE/DELETE/INSERT on `orders`, `order_items` or `order_status_history`.
- Browser update on `orders` is limited to the `status` column. Money, snapshot and `payment_status` columns are immutable from the browser.
- `user_roles` cannot be written from the browser. Role lookup for the logged-in user is read-only.
- Customer data (profiles, addresses, orders, items, history) is scoped to `auth.uid()` by RLS; `user_id` is never sent by the client.
- Internal helper functions and triggers are revoked from `public`, `anon` and `authenticated` by name.
- All SECURITY DEFINER functions pin `search_path`, use schema-qualified tables, and use no dynamic SQL.
- `create_order()` requires `auth.uid()`; anonymous is revoked.
- Idempotency per user with an advisory lock; slot capacity enforced under a per-slot lock; reactivation capacity guard.
- Inactive categories, products, variants, methods, zones and fees are hidden from the public by RLS.
- Delivery configuration has no DELETE for the browser (deactivate only). Order rows snapshot method, zone, fee rule and address.
- Error messages shown to customers map to fixed strings (no SQL leaks). `handle_new_user` copies only name and phone, trimmed and length-limited.
- No service-role key or payment secret in the client bundle; Vite exposes only `VITE_*` values and there are only four.
- CSRF middleware is explicitly enabled for server functions in `start.ts`.

---

## 10. Recommended Phase 5B.2 Fixes (not implemented)

Priority order.

1. **Close V1.** Replace the direct `status` update with a `SECURITY DEFINER` RPC (e.g. `staff_set_order_status(order_id, new_status)`), and revoke the browser `UPDATE` on `orders`. Inside the RPC:
   - require `is_staff(auth.uid())`;
   - forbid staff from setting `paid` and `refunded` at all;
   - allow only forward fulfilment transitions plus `cancelled` (an explicit transition table);
   - allow `paid`/`refunded` only from `service_role` (webhook/server) or an `admin`-only path with a required note;
   - keep `status` and `payment_status` consistent (e.g. `paid` requires `payment_status = 'paid'`).
2. **Close V2.** Make restock idempotent: record a `restocked_at` flag on the order (service-written), or restock only once per order, and either forbid leaving `cancelled`/`refunded` or re-reserve stock (and fail if stock is short) on reactivation.
3. **Split staff and admin (V3).** Introduce `is_admin()`; restrict fee/zone/method/slot-config writes and any `paid`/`refunded` override to admins. Keep staff to fulfilment status and read access. Add an audit table for config changes.
4. **Zone/address binding (V4).** Add `zone_id` to `addresses` (or a county/town → zone lookup), have `create_order()` derive the zone from the address server-side, and stop accepting `p_zone_id` from the client (or require it to equal the derived zone). Reject zones for no-address methods.
5. **Lock down function grants (V5/V6, P8).** Add explicit `revoke execute ... from public, anon, authenticated` on `has_role`/`is_staff` (keep `authenticated` only if policies need it; policies run as the caller). Prefer `has_role` that ignores the argument and uses `auth.uid()`, or add a check that the argument equals `auth.uid()` for non-service callers. Revoke trigger functions the same way. Make `validate_cart()` and `validate_delivery_selection()` filter `is_active` (return a generic "unavailable" without name/label/price/stock for inactive rows) and cap `p_items` length.
6. **Prepare the payment trust boundary before integrating M-Pesa/card:** server-only secrets (never `VITE_*`); webhook route that verifies signature/callback origin and amount/currency/order id against the stored order; a `payments` table written only by `service_role`; idempotent processing by provider reference; and a DB rule that only `service_role` can set `payment_status = 'paid'`.
7. **Expire unpaid orders:** scheduled job cancelling `awaiting_payment` orders after N minutes (restocking once, per fix 2).
8. **Hardening:** `set search_path = public, pg_temp`; restrict `profiles` insert columns; add MFA for staff; consider rate limits / CAPTCHA on sign-up; stop shipping `.output/` and `.wrangler/` in handoff zips.
9. **Verify live state** (read-only SQL): list EXECUTE privileges per function, function owners, `pg_policies`, table/column grants, and the `user_roles` contents, then compare with Sections 1–3.

---

## 11. Files Inspected

- `db/migrations/20260930000000_foundation_schema.sql`
- `db/migrations/20260930010000_orders_delivery_admin.sql`
- `db/migrations/20260930020000_order_integrity_hardening.sql` (grants/triggers read in full; `create_order` here is superseded)
- `db/migrations/20260930030000_delivery_system_foundation.sql`
- `db/migrations/20260930040000_delivery_validation.sql` (header and grants)
- `db/migrations/20260930050000_delivery_slot_validation.sql`
- `db/migrations/20260930060000_create_order_delivery_integration.sql` (current `create_order`)
- `db/migrations/20260930070000_order_reactivation_capacity.sql`
- `db/migrations/20260930080000_fix_validate_delivery_selection_record.sql` (current `validate_delivery_selection`)
- `db/tests/*` (grep for credentials and role seeding only)
- `src/lib/env.ts`, `src/lib/supabase/client.ts`, `src/features/auth/roles.ts`, `src/features/checkout/payment-providers.ts`
- `src/features/orders/create-order-args.ts`, `src/features/orders/queries.ts`, `src/routes/checkout.tsx` (grep), `src/features/delivery/{admin,checkout,queries}.ts`, `src/server.ts`, `src/start.ts`, `src/lib/lovable-error-reporting.ts`
- Whole-tree pattern searches over `src/`, `tests/`, `public/`, config files, `HANDOFF*.md`, `AGENTS.md`
- `.env.example`, `.gitignore`, `.lovable/project.json`, `.wrangler/deploy/config.json`, `.output/server/wrangler.json`, `.output/public/_headers`, and the `.output/` bundles (secret and key-pattern search only)

Not read line by line: UI component files under `src/components/ui/`, generated `routeTree.gen.ts`, `bun.lock`, and the bulk of `.output/` library bundles.

---

## 12. Verification Limitations

- **No live database was accessed.** Everything about grants, owners, policies and data comes from the migration files and assumes they were applied as written. Migrations 060000 and 070000 state in their own headers that they were "written, NOT executed" at authoring time. This audit did not confirm they were later applied. I took your statement that Phase 5A.2 was verified, but I did not see its results.
- **No SQL was executed**, no tests were run (database or application), and nothing was built or started.
- **Function owners and Supabase default privileges are not knowable from the repo.** "Anon Execute" values are derived from the `GRANT`/`REVOKE` statements only.
- **Secrets could not be checked against the Supabase or any payment-provider dashboard.** I can say no secret is in the uploaded files; I cannot say the keys in the live project have not leaked elsewhere, or whether the real publishable key is correctly scoped.
- **Git history is unavailable** (the archive is not a repository), so earlier commits could contain secrets.
- **Supabase Auth settings** (sign-up open/closed, email confirmation, MFA, rate limits) and **Storage/Realtime/Edge Function** settings were not visible.
- **No payment code exists**, so payment findings describe the absence of controls and what the schema allows, not an implementation.

**Modified by this audit:** nothing in the application or database. The only file created is this report.
