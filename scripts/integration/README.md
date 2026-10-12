# Phase 6M - full Supabase integration test

Three layers, run in this order against a **dev** Supabase project (never production):

| #   | What                    | Command                    | Proves                                                                                       |
| --- | ----------------------- | -------------------------- | -------------------------------------------------------------------------------------------- |
| 1   | Unit tests (no network) | `npm test`                 | parsers, error mappers, gate/idle logic, the test helpers themselves                         |
| 2   | SQL suite (36 files)    | `npm run test:sql`         | every migration's rules, inside the database, as the right roles                             |
| 3   | Live API run            | `npm run test:integration` | the same rules as the **browser/API sees them**: PostgREST, RLS, grants, Auth, MFA, webhooks |

Layers 2 and 3 overlap on purpose: SQL tests prove the logic with simulated JWT claims; the live run
proves the real Supabase stack (PostgREST roles, real tokens, real TOTP) agrees.

> Written but **not executed** by the author (no network or keys in the build sandbox). Treat the
> first run as part of the test: a FAIL is either a real finding or a wrong assumption in the test.
> The note next to every FAIL says exactly which, and the checks are small enough to adjust.

## 0. Prerequisites

- A **dev** project with every migration applied, through `20261005150000_phase6l2_admin_role_management.sql`.
- Authentication -> Providers -> **Email** on; **MFA (TOTP)** enabled. Email confirmation may stay on
  (the runner creates pre-confirmed users with the service key).
- `require_mfa` is `false` for step 3a (the default after 6L.1).
- Node 22+, `npm ci` done (uses the repo's `@supabase/supabase-js`; no new dependency).
- Optional: `psql` for layer 2; the deployed/preview app URL for the webhook checks.

## 1. Environment

```bash
export SUPABASE_URL='https://<ref>.supabase.co'
export SUPABASE_ANON_KEY='<anon / publishable key>'
export SUPABASE_SERVICE_ROLE_KEY='<service_role key>'   # creates/deletes throwaway users. Never commit it.
export IT_ALLOW_PROJECT_REF='<ref>'                      # must equal the ref in SUPABASE_URL, or the run refuses to start
export APP_URL='https://<your app>'                      # optional: enables the public-route checks
export DATABASE_URL='postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres'   # for layer 2 only
```

## 2. Layer 2 - SQL suite

```bash
npm run test:sql                       # all db/tests/*.test.sql, in migration order
bash scripts/integration/run-sql-tests.sh --with-concurrency   # + the 4 concurrency scripts (they commit and then clean up rows)
```

Expect `TOTAL: 36 passed, 0 failed` (40 with the concurrency scripts). Failing files print their `FAIL`/`ERROR` lines.
You can also paste any single file into the Supabase SQL Editor as one query.

## 3. Layer 3 - live run

### 3a. Enforcement OFF (default)

```bash
npm run test:integration
```

Creates 5 users (admin, staff, 2 customers, 1 plain), one product `zz-it-<runid>`, places a COD and a
card order, and walks every section below. Writes `integration-report-<runid>.json` and exits 1 on any FAIL.

### 3b. Enforcement ON

Turn it on (SQL Editor, as owner), run, then **turn it off again**:

```sql
update public.admin_security_settings set require_mfa = true;
```

```bash
npm run test:integration:enforced
```

```sql
update public.admin_security_settings set require_mfa = false;   -- when done
```

### What the live run covers

| Section           | Checks                                                                                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1 Anonymous       | 9 private tables unreadable; every admin RPC (27) refused; create_order, payment-engine and audit-prune functions refused; public helpers work                                                                                                         |
| 2 Admin catalog   | create product, duplicate slug, update, inventory +50, zero/over-draw refused, history, variants, list/get, dashboard, inactive product hidden from anon                                                                                               |
| 3 Customers       | own profile only; cannot self-suspend; no roles/notes/audit/ledger access; address isolation; all 27 admin RPCs `not_authorised`; create_order + idempotent replay; stock reduced once; order isolation; cannot mark own order paid; cannot record COD |
| 4 Staff           | can read orders; refused every admin RPC; cannot read audit/ledger/settings                                                                                                                                                                            |
| 5 Order lifecycle | list/get, jump refused without override, COD too early refused, override to delivered, record COD + replay, ledger and owner views                                                                                                                     |
| 6 Payment engine  | service-role-only functions: attempt + replay, processing, wrong amount refused, correct amount marks paid, replay, stock, audit append-only                                                                                                           |
| 7 Customers admin | list/get/notes, suspend blocks ordering, reactivate                                                                                                                                                                                                    |
| 8 Delivery        | admin reads; **no API role can write the 5 delivery tables**                                                                                                                                                                                           |
| 9 Roles + audit   | holders list (no emails), grant/no-op/revoke/no-op = exactly 2 audit rows, self-change, bad role, short reason, unknown user, audit readable only through the RPC, prune not callable                                                                  |
| 10 MFA (off)      | real TOTP enrolment, wrong code refused, aal2, fresh aal1 still allowed (flag off), unenroll needs aal2                                                                                                                                                |
| 11 Routes         | card webhook / M-Pesa callback / reconcile with bad credentials -> 4xx; card return unknown order -> no 5xx                                                                                                                                            |
| E (enforced)      | aal1 admin `mfa_required`; customers/anon unchanged; settings table sealed; aal1 loses direct admin reads; enrolment works while enforced; aal2 restores access                                                                                        |

### Not covered here (and why)

- **Real M-Pesa / card provider round-trips** need provider sandbox credentials and a public callback URL;
  the live run proves the server functions and the 4xx rejection of forged callbacks, not the provider.
- **Browser rendering** (QR code image, idle sign-out, OTP input) - manual, see checklist below.
- **Dashboard-only settings** (JWT expiry, session time-box/inactivity, refresh-token rotation) - set by hand.
- **Delivery admin writers** (zones, fees, slot templates/overrides) are covered by `phase6f1a/6f1b` SQL tests.

## 4. Manual checklist (5 minutes)

1. Sign in as an admin without a factor -> `/admin` shows "Set up two-factor sign-in" -> enrol with a real authenticator app -> `/admin` opens.
2. Sign out, sign in again -> 6-digit challenge screen -> wrong code rejected, right code opens `/admin`.
3. `/account/security` lists the factor; removing it asks for a fresh code first.
4. Temporarily set `ADMIN_IDLE_TIMEOUT_MS` to 60 000 in `src/features/auth/admin-idle.ts`, wait a minute in `/admin` -> signed out to `/auth` with the idle message. **Restore 30 minutes.**
5. Customer shop: no idle sign-out, no admin links.

## 5. Reading a result

- `PASS` - behaviour matches the design.
- `FAIL  ... -> <reason>` - read the reason. `expected SQLSTATE 42501, got none` means a door that should be shut is open (**real bug**). `... failed: 42883 function ... does not exist` or an argument error means the test's assumption is wrong - fix the call, not the database.
- `SKIP` - precondition missing (for example `APP_URL` not set).
- Exit code: 0 all pass, 1 at least one FAIL, 2 the run aborted (the message says why; cleanup is still attempted).

## 6. Cleanup

The run deletes its users and deactivates its product. Left behind by design: audit rows (append-only) and the
`zz-it-<runid>` product with its two orders. The product is inactive and invisible to customers, so the safe
choice is to **leave them**. If you really want them gone, do it by hand in the SQL Editor as owner, selecting
only rows whose product slug starts with `zz-it-`, and check the row counts before you delete anything.
