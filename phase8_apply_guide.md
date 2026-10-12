# Phase 8 - Discounts & Promotions: apply and test guide

Nothing in Phase 8 has been applied to or run against any database. No PostgreSQL was available when it was written.

## Apply and test order

1. Back up / use a DEV or branch database with migrations through `20261005160000` applied.
2. Apply `db/migrations/20261009010000_phase8_discounts_promotions.sql` (one transaction; its self-check aborts on any bad grant, RLS, body or rule). Its precondition refuses to run if `create_order()` is not the 6E.3 body (md5 `1f087e8de9c1abd28fd5b0361588e96d`, computed from the migration file, not read from a database).
3. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase8_discounts_promotions.test.sql`
   3a. Apply `db/migrations/20261009020000_phase8_validate_coupon_total.sql` (one transaction, self-check, precondition pins the body of the `validate_coupon()` it replaces). It replaces `validate_coupon(jsonb,text)` with a 4-argument version that also returns `delivery_fee_cents` and `total_cents` (the server's final payable total) when a valid delivery selection is supplied. Checkout shows and sends that total; it no longer computes one. Then: `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/phase8_validate_coupon_total.test.sql`
4. `DATABASE_URL=... scripts/integration/run-sql-tests.sh` (older create_order tests were updated to the 13-argument signature).
5. `DATABASE_URL=... db/tests/phase8_coupon_concurrency.sh` (commits fixtures, cleans up; DEV only).
6. `npm ci && npm run typecheck-equivalent (tsc -p .) && npm test && npm run build`, then click through checkout.

## Design decisions to confirm

- One table covers coupons (code set) and automatic promotions (code NULL). percentage `value` = basis points, fixed = cents.
- Delivery is not discountable; decided only in `coupon_eligible_base_cents()`. Minimum order uses the same base.
- One promotion per order, no stacking. A supplied code must be valid or the order fails (`coupon_<code>`); with no code the best valid automatic promotion applies.
- A redemption is released when the order becomes cancelled or refunded; reactivating re-takes it or is refused (`coupon_reactivation_limit_reached`). A failed payment does not cancel an order, so it keeps its use until staff cancel it.
- `create_order()` gained a trailing `p_coupon_code`; the 12-argument overload is dropped.
- Admin functions need `require_admin()` (so MFA applies if enabled); service_role cannot call them.
