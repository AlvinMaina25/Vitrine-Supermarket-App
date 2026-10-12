# Phase 6F.1B - Supabase SQL Editor apply guide (not yet run on the real Supabase)

Targets the dedicated Phase-5 dev project only. Requires 20261005010000 (6F.1A) already applied.
The migration runs once: it aborts if any of its five functions already exists.
Local check (stub auth, NOT real Supabase): all migrations + both SQL tests passed on PostgreSQL 16 (6F.1A 136 checks, 6F.1B 141).

## 1. Apply the migration (one query)

1. SQL Editor -> New query.
2. Paste the ENTIRE contents of `db/migrations/20261005020000_phase6f1b_delivery_admin_slots.sql` (nothing else; it has its own `begin;` / `commit;`).
3. Run. No error = applied. Any error aborts the whole transaction and nothing is applied.

## 2. Run the test (separate new query)

1. New query. Paste the ENTIRE contents of `db/tests/phase6f1b_delivery_admin_slots.test.sql`.
2. Run. It ends in `rollback;`, so it leaves nothing behind. No error = all checks passed (a failure raises `FAIL: <check name>`).
   `PASS:` / `ALL PHASE 6F.1B DELIVERY ADMIN SLOT TESTS PASSED` are NOTICEs the Editor may not show.
3. Uses its own templates (labels `T6FB...`, windows 21:00-23:45) and users; existing data is not assumed absent. Dates are relative to today (Africa/Nairobi).

## 3. Afterwards

Do NOT revoke the direct write grants on the slot tables yet; that is for the 6F review once the UI uses these functions.
