# Phase 6E.3 (Run A) - apply guide (Supabase SQL Editor)

Backend only. One new migration, one new test, two old tests updated. No frontend change.
Prerequisite: every migration up to `20261004160000` is already applied (the migration checks this itself).

## 1. Apply the migration

1. Supabase dashboard -> SQL Editor -> New query.
2. Paste the **entire contents** of `db/migrations/20261004170000_phase6e3_customer_hardening.sql` and nothing else. Run.
3. Expected: "Success. No rows returned". It runs in one transaction: if any check fails, nothing is changed.
4. Errors you may see (all safe, nothing applied):
   - `precondition failed: apply every migration up to 20261004160000 first` - an earlier migration is missing.
   - `create_order() ... differs from migration 20261003010000` - create_order was changed by hand or by another migration; compare before continuing.
   - `appears to be applied already. Not running it twice.` - already applied; do not re-run.

## 2. Run the test (separately, after the migration)

1. New query. Paste the **entire contents** of `db/tests/phase6e3_customer_hardening.test.sql`. Run as the default `postgres` role.
2. It creates fixtures (marker `T6I`), checks, then **rolls back**. No error = every check passed (individual `PASS:` lines are NOTICEs; the editor may not show them). An error starts with `FAIL:` and names the check.
3. Prefer a staging project for the test, as with the earlier SQL tests.

## 3. Updated old tests (run after the migration, same way)

- `db/tests/customer_status.test.sql` - staff now sees 0 audit rows.
- `db/tests/customer_notes.test.sql` - staff now sees 0 notes rows.
  Both now REQUIRE this migration; run against a database without it they fail on that line.

## 4. After applying

- A suspended customer's `create_order()` fails with `P0001`, DETAIL `account_suspended`. The checkout UI does not map this code yet and will show the database message (frontend follow-up, not part of this run).
- Staff (non-admin) no longer read `admin_audit_log` / `customer_notes` through the API. Admins still do.
- Browser roles can no longer INSERT `profiles.status`; the own-profile insert still works without it.
