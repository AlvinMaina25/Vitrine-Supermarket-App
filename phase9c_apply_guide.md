# Phase 9C apply guide (inventory history labels)

Nothing here has been applied to your Supabase project by the author. Verified locally only (PostgreSQL 16 + Supabase stubs).

1. **Migration.** Supabase SQL Editor: paste all of `db/migrations/20261010010000_phase9c_inventory_history_movement_labels.sql`, run once.
   It refuses to run without 9B, replaces only `admin_list_inventory_adjustments`, and rolls back if its self-check fails. Re-running is harmless.
2. **SQL test.** Paste all of `db/tests/phase9c_inventory_history_movement_labels.test.sql`, run. Success = no error
   (psql prints 33 PASS lines and `ALL PHASE 9C ... PASSED`). It rolls everything back. If it errors, run `ROLLBACK;` once.
3. **Frontend.** Deploy the changed `src/` files. Open Admin > Inventory > History: rows show a Movement column; cancelled /
   reactivated orders link to the order; order placements read "Order or direct change"; no customer id appears as an actor.
   (Until step 1 is done the new frontend simply shows no labels.)
4. **Optional, DEV database only** (these scripts COMMIT rows): `DATABASE_URL=... scripts/integration/run-sql-tests.sh --with-concurrency`.
   Expect the three fixed concurrency scripts to pass on reruns and to leave a few deactivated fixture products (the ledger is append-only).
