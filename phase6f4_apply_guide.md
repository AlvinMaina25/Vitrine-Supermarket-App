# Phase 6F.4 apply guide (delivery lockdown)

Migration: `db/migrations/20261005030000_phase6f4_delivery_lockdown.sql`
Test: `db/tests/phase6f4_delivery_lockdown.test.sql`

**Order matters.** 6F.1A (`20261005010000`) and 6F.1B (`20261005020000`) must already be applied. 6F.1B was
NOT applied to the real Supabase when this was written; apply it first, or this migration refuses to run.

## Before you start

1. Deploy the new frontend first (it no longer contains `src/features/delivery/admin.ts`). The old file was
   not imported anywhere, so the order is not critical, but there is no reason to wait.
2. Optional safety net: Supabase dashboard -> Database -> Backups (or a manual `pg_dump`).

## Apply (SQL Editor)

1. Open **Supabase dashboard -> SQL Editor -> New query**.
2. Paste the **contents of `20261005030000_phase6f4_delivery_lockdown.sql` only** (nothing else) and press **Run**.
3. Expected: "Success. No rows returned". Any error aborts the whole transaction (nothing is changed).
   - `appears to be applied already` = the lockdown is already in place; do not run it again.
   - `precondition failed: ... does not exist` = apply 6F.1A / 6F.1B first.
   - `has an ALL policy` = a policy that also covers reads exists on a delivery table; send me its definition.
   - `self-check failed` = something unexpected (a write privilege or a SELECT privilege/policy differs); nothing was committed.

## Verify (SQL Editor, SEPARATE query)

1. New query. Paste the **contents of `phase6f4_delivery_lockdown.test.sql`** and Run.
2. Expected: the Messages/Notices list ends with `ALL PHASE 6F.4 DELIVERY LOCKDOWN TESTS PASSED`. The script rolls back;
   it leaves nothing behind. Any `FAIL: ...` names the broken check.
3. Quick manual check (optional), as one query:
   ```sql
   select c.relname,
          has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE') as auth_can_write,
          has_table_privilege('anon',          c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE') as anon_can_write,
          has_table_privilege('authenticated', c.oid, 'SELECT')                           as auth_can_read
   from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relname in ('delivery_methods','delivery_zones','delivery_zone_fees',
                       'delivery_slot_templates','delivery_slot_overrides')
   order by 1;
   ```
   Expected: `auth_can_write` and `anon_can_write` are false on all five rows.

## Earlier SQL tests

`phase5b2_security_authorization_hardening`, `phase6f1a_...` and `phase6f1b_...` were edited so they assert the
locked-down state (direct writes now refused). Run them against the final state, not against a state before this migration.

## Rollback (only if you must; it re-opens the direct write path)

```sql
begin;
grant insert (code, label, description, base_fee_cents, free_over_cents, min_order_cents,
              requires_slot, requires_address, eta_label, position, is_active)
  on public.delivery_methods to authenticated;
grant update (label, description, base_fee_cents, free_over_cents, min_order_cents,
              requires_slot, requires_address, eta_label, position, is_active)
  on public.delivery_methods to authenticated;
grant insert (code, name, description, county, towns, position, is_active) on public.delivery_zones to authenticated;
grant update (name, description, county, towns, position, is_active) on public.delivery_zones to authenticated;
grant insert (zone_id, method_code, fee_cents, free_over_cents, min_order_cents, is_active)
  on public.delivery_zone_fees to authenticated;
grant update (fee_cents, free_over_cents, min_order_cents, is_active) on public.delivery_zone_fees to authenticated;
grant insert (label, start_time, end_time, day_of_week, capacity, position, is_active)
  on public.delivery_slot_templates to authenticated;
grant update (label, start_time, end_time, day_of_week, capacity, position, is_active)
  on public.delivery_slot_templates to authenticated;
grant insert (template_id, slot_date, capacity, is_active, note) on public.delivery_slot_overrides to authenticated;
grant update (capacity, is_active, note) on public.delivery_slot_overrides to authenticated;
-- plus the admin INSERT/UPDATE policies from 20261003010000 section 3 (recreate them from that file).
commit;
```
