#!/usr/bin/env bash
# =============================================================================
# PHASE 8 concurrency test: do parallel create_order() calls exceed a coupon's usage limit?
#
# STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
#
# Needs a DEV database with ALL migrations through 20261009010000_phase8_discounts_promotions.sql
# and `psql` on the PATH. It COMMITS real rows (a lock only means something between separate
# sessions) named p8cc-*, and removes them on exit, including on failure. Never point it at production.
#
# PHASE 9B: create_order() now writes inventory_adjustments rows (append-only ledger), which pin the
# fixture product. The product is therefore RETAINED (deactivated) instead of deleted and re-used by
# the next run; everything else is deleted. Cleanup failures are reported and fail the run. See
# db/tests/lib/concurrency_cleanup.sh.
#
#   DATABASE_URL=postgres://... db/tests/phase8_coupon_concurrency.sh [SESSIONS] [LIMIT]
#   defaults: 8 sessions, usage limit 2
#
# Each session is one real create_order() call (own transaction, READ COMMITTED, signed in as the
# fixture customer through the JWT settings) using the same coupon. EXPECT exactly LIMIT orders and
# LIMIT active redemptions afterwards, every other session rejected with coupon_limit_reached, and
# the rejected sessions' stock returned.
#
# Automatic promotions are not touched here (any active automatic promotion would add a discount to
# the fixture orders but cannot change the counts checked).
# Exit codes: 0 pass, 1 a check failed.
# =============================================================================
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a DEV database}"
SESSIONS="${1:-8}"
LIMIT="${2:-2}"
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

USER_ID='00000000-0000-4000-8000-0000000cc801'
PRODUCT_ID='00000000-0000-4000-8000-0000000cc8b1'
PROMO_ID='00000000-0000-4000-8000-0000000cc8c1'
STOCK=100
WORK="$(mktemp -d)"

# shellcheck source=lib/concurrency_cleanup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/concurrency_cleanup.sh"

purge_fixtures() {
  CLEANUP_FAILED=0
  # ONE transaction: the guard trigger is disabled only for these deletes and, because ALTER TABLE
  # ... DISABLE TRIGGER is transactional, a failing delete rolls the disable back with it. (The old
  # cleanup ran this in a session that stopped at the first error and could leave the trigger OFF.)
  cleanup_step "orders, items, redemptions (guard trigger disabled inside the transaction only)" "
    begin;
    alter table public.orders disable trigger orders_guard_discount_snapshot;
    delete from public.promotion_redemptions where promotion_id = '${PROMO_ID}';
    delete from public.order_items where order_id in (select id from public.orders where user_id = '${USER_ID}');
    delete from public.orders where user_id = '${USER_ID}';
    alter table public.orders enable trigger orders_guard_discount_snapshot;
    commit;"
  cleanup_step "fixture promotion and delivery method" "
    delete from public.promotions where id = '${PROMO_ID}';
    delete from public.delivery_methods where code = 'p8cc_m';"
  # Phase 9B: the ledger pins a product whose stock moved (append-only, FK RESTRICT). Delete the
  # product only when nothing references it; otherwise deactivate it and keep it for the next run.
  cleanup_step "fixture product" "
    do \$\$ begin
      if exists (select 1 from public.inventory_adjustments where product_id = '${PRODUCT_ID}') then
        update public.products set is_active = false where id = '${PRODUCT_ID}';
        raise notice 'RETAINED product p8cc-p (the append-only inventory ledger references it): deactivated, re-used by the next run';
      else
        delete from public.products where id = '${PRODUCT_ID}';
      end if;
    end \$\$;"
  cleanup_step "fixture user" "delete from auth.users where id = '${USER_ID}';"
  cleanup_expect_none "fixture orders / promotion / method / user" "select
    (select count(*) from public.orders where user_id = '${USER_ID}')
  + (select count(*) from public.promotions where id = '${PROMO_ID}')
  + (select count(*) from public.delivery_methods where code = 'p8cc_m')
  + (select count(*) from auth.users where id = '${USER_ID}')"
  # The guard trigger must be back ON whatever happened above.
  cleanup_expect_none "orders_guard_discount_snapshot enabled" "select count(*) from pg_trigger
    where tgrelid = 'public.orders'::regclass and tgname = 'orders_guard_discount_snapshot' and tgenabled <> 'O'"
  [ "$CLEANUP_FAILED" -eq 0 ]
}
cleanup() {
  local rc=$?
  purge_fixtures || true
  rm -rf "$WORK"
  finish_cleanup "$rc"
  exit $?
}
trap cleanup EXIT

purge_fixtures || { echo "FAIL: leftovers of an earlier run could not be removed (see above); not starting." >&2; exit 1; }
"${PSQL[@]}" <<SQL
insert into auth.users (id, email, aud, role)
  values ('${USER_ID}', 'p8cc-customer@example.test', 'authenticated', 'authenticated');
insert into public.delivery_methods (code, label, base_fee_cents, requires_slot, requires_address, is_active)
  values ('p8cc_m', 'P8CC method', 0, false, false, true);
-- Upsert: a product retained from an earlier run (ledger rows pin it) is reset to the starting stock.
insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active)
  values ('${PRODUCT_ID}', 'p8cc-p', 'P8CC product', 1000, ${STOCK}, true, true)
  on conflict (id) do update
    set stock_quantity = excluded.stock_quantity, in_stock = true, is_active = true;
insert into public.promotions (id, code, name, discount_type, value, usage_limit, is_active)
  values ('${PROMO_ID}', 'P8CC-LIMITED', 'P8CC limited', 'fixed', 100, ${LIMIT}, true);
SQL

cat > "$WORK/worker.sql" <<'SQL'
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-8000-0000000cc801', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000cc801', true);
select public.create_order(
  '[{"product_id":"00000000-0000-4000-8000-0000000cc8b1","variant_id":null,"quantity":1}]'::jsonb,
  'p8cc_m', 'cash_on_delivery', null, null, null, null, null, null, null, null, null, 'P8CC-LIMITED') as new_order \gset
\echo ORDER_PLACED
commit;
SQL

echo "== ${SESSIONS} concurrent create_order() calls, coupon usage limit ${LIMIT}"
for i in $(seq 1 "$SESSIONS"); do
  # a rejected call aborts its own session (ON_ERROR_STOP); that is the expected outcome
  "${PSQL[@]}" -f "$WORK/worker.sql" >"$WORK/s.$i.out" 2>&1 || true &
done
wait

PLACED="$(cat "$WORK"/s.*.out | grep -c '^ORDER_PLACED$' || true)"
REJECTED="$(cat "$WORK"/s.*.out | grep -c 'That coupon cannot be applied' || true)"
ACTIVE="$("${PSQL[@]}" -At -c "select count(*) from public.promotion_redemptions where promotion_id = '${PROMO_ID}' and released_at is null")"
ORDERS="$("${PSQL[@]}" -At -c "select count(*) from public.orders where user_id = '${USER_ID}'")"
STOCK_NOW="$("${PSQL[@]}" -At -c "select stock_quantity from public.products where id = '${PRODUCT_ID}'")"
echo "   placed: ${PLACED}; rejected: ${REJECTED}; orders: ${ORDERS}; active redemptions: ${ACTIVE}; stock ${STOCK} -> ${STOCK_NOW}"

STATUS=0
if [ "$PLACED" -ne "$LIMIT" ] || [ "$ORDERS" -ne "$LIMIT" ] || [ "$ACTIVE" -ne "$LIMIT" ]; then
  echo "FAIL: expected exactly ${LIMIT} orders and redemptions (placed ${PLACED}, orders ${ORDERS}, redemptions ${ACTIVE})"; STATUS=1
else
  echo "PASS: exactly ${LIMIT} orders and redemptions were created"
fi
if [ "$((PLACED + REJECTED))" -ne "$SESSIONS" ]; then
  echo "FAIL: ${SESSIONS} sessions but ${PLACED} placed + ${REJECTED} rejected (see $WORK/s.*.out; kept until exit)"
  cat "$WORK"/s.*.out | grep -v '^ORDER_PLACED$' | sort | uniq -c | head -10
  STATUS=1
else
  echo "PASS: every other session was rejected by the coupon"
fi
if [ "$STOCK_NOW" -ne "$((STOCK - LIMIT))" ]; then
  echo "FAIL: stock is ${STOCK_NOW}, expected $((STOCK - LIMIT)) (rejected orders must not consume stock)"; STATUS=1
else
  echo "PASS: rejected orders consumed no stock"
fi
exit "$STATUS"
