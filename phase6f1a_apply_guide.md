# Phase 6F.1A - Supabase SQL Editor apply guide (SQL NOT RUN by the author)

Targets the dedicated Phase-5 dev project only. Requires 20261004170000 (6E.3) already applied.
The migration is written to run once: it aborts if any of its six functions already exists.

## 1. Apply the migration (one query)

1. Open SQL Editor -> New query.
2. Paste the ENTIRE contents of `db/migrations/20261005010000_phase6f1a_delivery_admin_methods_zones.sql`
   (nothing else; it contains its own `begin;` / `commit;`).
3. Run. Success = no error. Any error aborts the whole transaction and nothing is applied.
   Its built-in self-check verifies SECURITY DEFINER, pinned search_path, anon denied, authenticated granted.

## 2. Run the test (separate new query)

1. New query. Paste the ENTIRE contents of `db/tests/phase6f1a_delivery_admin_methods_zones.test.sql`.
2. Run. It ends in `rollback;`, so it leaves nothing behind. Success = no error.
   A failed check raises `FAIL: <check name>` and stops. `PASS:` / the final
   `ALL PHASE 6F.1A DELIVERY ADMIN TESTS PASSED` appear as NOTICE messages, which the Editor may not display;
   no error is the signal.
3. Needs the seeded methods standard, express, pickup (active standard and express). The test uses its own
   zones t6f-a / t6f-b and its own users; existing data is not assumed absent.

## 3. Afterwards

Do NOT revoke the direct write grants yet (6F.1B does that, after the frontend exists).
