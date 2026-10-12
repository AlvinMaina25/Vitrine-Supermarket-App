You are taking over a supermarket e-commerce repo (React, TypeScript, TanStack Start/Router/Query, Tailwind,
Supabase). Do NOT rebuild or redesign. Supabase is authoritative. Money is integer cents. Never fake payment
success; no M-Pesa/card integration.

Read HANDOFF.md, then AGENTS.md and the three files in db/migrations/. All planned code is written but was
NEVER installed, typechecked, built, linted or run (the previous environment had no package access), and the
SQL was never executed. routeTree.gen.ts was hand-edited.

Do, in order:

1. `bun install`.
2. `bunx tsc --noEmit`; fix all errors properly (no `any`, no @ts-ignore). Review my new/changed files first
   (checkout.tsx, order-sections.tsx, account.orders.*.tsx, order-confirmation.$orderId.tsx, queries.ts).
3. `bun run build` so the router plugin regenerates src/routeTree.gen.ts. Confirm it has /order-confirmation/$orderId,
   /account/orders and /account/orders/$orderId. Keep the generated file.
4. Run `bun run format` (Prettier width 100; many pre-existing files are unformatted), review the diff, then `bun run lint` until clean.
5. Re-review db/migrations/20260930020000_order_integrity_hardening.sql and, if a Supabase project is available,
   apply all three migrations in order and test: concurrent orders for the last unit, replayed and concurrent
   idempotency key, past slot, wrong p_expected_total_cents, cancel -> restock.
6. Decide/handle the "Known issues" list in HANDOFF.md (unpaid stock reservation expiry, staff payment_status
   writes, validate_cart exposure, sign-out redirect).
   Requirements: customers see only their own orders; order items/address are snapshots; order status and payment
   status stay separate; create_order() is the only write path and frontend totals are never trusted; do not claim
   slot capacity (not enforced). Finish with an updated HANDOFF.md listing files changed, what is done/remaining,
   migrations to apply, and the REAL tsc/build/lint output.
