# Phase 6F.4 - delivery management review and lockdown

Scope: 6F.1A/6F.1B backend, 6F.2 data layer, 6F.3A/6F.3B UI, legacy `src/features/delivery/admin.ts`, checkout reads.
Method: static review of the code and SQL (no database was available), then fixes. No new features, no redesign.

## Environment (what was and was not possible)

- **No PostgreSQL and no network** in the review sandbox (`psql`, `postgres`, `initdb` absent; apt and npm registries return 403).
  Therefore **no migration, no SQL test and no concurrency script was executed.** Everything SQL below is reviewed by reading only.
- **bun is not installed; `npm install` fails with 403**, so no dependencies exist. `bun install`, `bun run build`, `bunx tsc --noEmit`,
  `bun run format` and `bun run lint` were **NOT RUN**. A syntax-only pass with a global `tsc` (no TS1xxx syntax errors in the project)
  is NOT a type check.
- `npm test` **was run** (Node 22, pure TypeScript tests, no dependencies needed): 452 / 452 pass.

## Findings

| #   | Issue                                                                                                                                                                                                                               | Severity                          | File                                      | Status                                                                                                                                                     |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Direct INSERT/UPDATE (column grants + admin write policies) bypass the audit log and the capacity / immutability / below-booked rules the admin functions enforce                                                                   | High                              | 20260930030000, 20261003010000            | Fixed in `20261005030000` (not applied yet)                                                                                                                |
| 2   | Supabase default privileges can give anon/authenticated DELETE and TRUNCATE on these tables; RLS does not restrict TRUNCATE. Whether they were actually granted on the real DB is NOT verified                                      | High (conditional)                | same                                      | Fixed: migration revokes INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER from public/anon/authenticated; SELECT untouched                            |
| 3   | `src/features/delivery/admin.ts` (337 lines): unused (no importer found), kept a second, unaudited write path in the bundle                                                                                                         | Medium                            | src/features/delivery/admin.ts            | Fixed: deleted; dead `SLOT_OVERRIDE_COLUMNS` export and a re-export in `queries.ts` removed                                                                |
| 4   | Fee-rule "Minimum order" hint said "leave blank for no minimum", but `resolve_delivery_fee` uses `greatest(method min, rule min)`, so a rule can only raise the minimum; table showed "None"                                        | Medium (misleading money setting) | delivery-fees-panel.tsx                   | Fixed (wording only)                                                                                                                                       |
| 5   | Slots range buttons "Previous / Next 14 days / Next": "Next 14 days" actually reset to today                                                                                                                                        | Low                               | delivery-slots-panel.tsx                  | Fixed (label "Today")                                                                                                                                      |
| 6   | Stale test assertions: 7 files assert exactly 15 `admin_*` functions; 6F.1A/6F.1B tests assert direct grants remain; 5B.2 test asserts admin direct writes succeed                                                                  | Low                               | db/tests/*                                | Fixed (assert the final state). NOT RUN                                                                                                                    |
| 7   | Template window/weekday guard (`template_has_bookings`) runs without the per-slot advisory lock; a checkout committing in the gap between the check and the UPDATE could leave an order on a moved window. Admin-only, rare, narrow | Low                               | 20261005020000                            | NOT fixed (needs `create_order` or per-template locking; applied migrations are not edited). Mitigation: deactivate and recreate instead of moving windows |
| 8   | Duplicate templates with the same window share one booked count; an override on the shadowed (higher position) duplicate has no effect on checkout. UI does not warn                                                                | Low                               | 20261005020000 (documented in its header) | NOT fixed                                                                                                                                                  |
| 9   | Audit text for method updates and override clears is `left(...,500)`; a very long admin reason can be truncated in the audit row (method update stores the summary first, then the reason)                                          | Low                               | 20261005010000 / 020000                   | NOT fixed (function replace; out of scope)                                                                                                                 |
| 10  | Data layer still has a "default to current week" range (`weekRange`/`activeSlotRange`); the UI always passes an explicit 14-day range, so that default is unused and the 14-day default lives in `delivery-slots-view.ts`           | Low (duplicated logic)            | delivery-management.ts                    | NOT fixed (tested module; no behaviour impact)                                                                                                             |
| 11  | Slots tab "today" is read once on mount; after midnight Nairobi it is stale until reload (the DB still rejects past dates)                                                                                                          | Low                               | delivery-slots-panel / route              | NOT fixed                                                                                                                                                  |
| 12  | Method update audit rows have `target_id` NULL (method PK is text)                                                                                                                                                                  | Info                              | 20261005010000                            | By design, documented                                                                                                                                      |

### Checked, no issue found (static reading only)

- All 11 admin functions: `require_admin()` first, `SECURITY DEFINER`, `search_path = public, pg_temp`, `revoke all ... from public, anon, authenticated` then `grant execute ... to authenticated`; each has a self-check in its migration.
- Every real change writes one `admin_audit_log` row; no-op saves return `changed=false` and write none.
- Every `DETAIL` code raised by 6F.1A/6F.1B exists in `delivery-error.ts` (message + field); no mapper change needed.
- Money: only `delivery-money.ts` turns shillings into cents (no `*100`, `/100`, `toFixed`, `parseFloat` in the admin delivery code); DB re-validates whole non-negative cents <= 2147483647; display uses `formatPrice`.
- Checkout reads delivery config only through SELECT and the customer RPCs; nothing there writes the tables.
- Orders keep snapshot columns; FKs from orders are SET NULL / RESTRICT and nothing in 6F deletes a row; deactivation is a flag.
- Double submit: `useDeliveryAction` ref guard + disabled buttons; every write invalidates `["admin","delivery"]`; stale toggles surface as `status_unchanged`.
- No secret in `src`: only `VITE_SUPABASE_URL` and the publishable key are read. The built bundle was NOT inspected (build NOT RUN).

## Lockdown (what the new migration does)

`db/migrations/20261005030000_phase6f4_delivery_lockdown.sql`, one transaction:

1. Preconditions: the 11 admin functions, `validate_delivery_selection` and `get_delivery_slot_availability` exist; RLS is on for all five tables; no `ALL` policy exists (dropping one would change reads).
2. Refuse-to-run-twice: aborts if no write privilege or write policy is left on any of the five tables.
3. Snapshots SELECT privileges, SELECT policies and EXECUTE privileges of the customer and admin functions, drops INSERT/UPDATE/DELETE policies, revokes the write privileges.
4. Self-check: no write privilege/policy remains for anon or authenticated, RLS still on, the snapshot is identical, and the admin writer functions are `SECURITY DEFINER` owned by a role that can still write (so they keep working).

SQL test `db/tests/phase6f4_delivery_lockdown.test.sql` (rolls back): admin RPCs still work (zone, fee, method, template, override, clear, lists) and write audit rows; customer, staff, admin and anon get 42501 on INSERT/UPDATE/DELETE of all five tables and TRUNCATE; no row changed; privileges and policies on the catalog; customer/visitor reads of active config; staff still read inactive; `validate_delivery_selection`, `resolve_delivery_fee`, `validate_delivery_slot`, `get_delivery_slot_availability` work; `create_order` is `SECURITY DEFINER` and executable; the admin gate still refuses customer/staff/anon. Full `create_order` behaviour is covered by the existing `create_order_delivery.test.sql`, which must be re-run after the migration.

## Verification results

| Check                                                         | Result                                                                          |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| All migrations + ALL SQL tests on local Postgres (stub auth)  | **NOT RUN** (no Postgres)                                                       |
| `delivery_slot_concurrency.sh`, `create_order_concurrency.sh` | **NOT RUN** (no `psql`/Postgres)                                                |
| `bun install`                                                 | **FAILED**: `bun` not installed; `npm install` also 403 from the registry       |
| `bun run build` (and `routeTree.gen.ts` regeneration)         | **NOT RUN** (no dependencies). No route was added; `routeTree.gen.ts` untouched |
| `bunx tsc --noEmit`                                           | **NOT RUN** (global `tsc` syntax-only scan: no syntax errors; not a type check) |
| `bun run format`                                              | **NOT RUN** (long lines were wrapped by hand; run it once)                      |
| `bun run lint`                                                | **NOT RUN**                                                                     |
| `npm test`                                                    | **PASS** 452 / 452                                                              |

## Still NOT verified

- Every SQL object in 6F.1B and 6F.4 and every edited SQL test (never executed); whether anon/authenticated actually held DELETE/TRUNCATE on the real project.
- Type correctness, lint and build of the 6F.3A/6F.3B/6F.4 frontend; the production bundle contents.
- Concurrency of checkout vs. override/capacity changes (scripts not run).
- 6F.1B is not applied on the real Supabase; 6F.4 is not applied either.
- Browser behaviour of all four tabs.

## Manual smoke checklist (after applying 6F.1B, then 6F.4, and deploying)

1. Sign in as admin -> `/admin/delivery`. **Methods:** edit a fee, save; turn one off (reason required) and on again. **Zones:** create, edit towns, deactivate/activate with a reason. **Fees:** create a rule, edit it, check the minimum-order hint, deactivate. **Slots:** create a window, edit its capacity, close one date, set a capacity above/below the booked count (below must be refused with the friendly message), clear the override with a reason.
2. Check `admin_audit_log` has one row per change above.
3. As a customer: checkout still lists delivery options, zones, fees and slots; a slot you closed is not offered; place a test order for a delivery slot and a pickup; its totals and slot are unchanged after you later change the fee/slot config.
4. As a customer (non-admin account): `/admin/delivery` shows "Admin access required"; in the browser console `supabase.from('delivery_zones').update({is_active:false}).eq('code','...')` returns a permission error (42501), as do inserts and deletes on the other four tables.
5. As staff: same denial on `/admin/delivery` and on direct writes; staff can still read inactive config where they could before.
6. Anonymous visitor: the shop and checkout delivery lookups still work.
