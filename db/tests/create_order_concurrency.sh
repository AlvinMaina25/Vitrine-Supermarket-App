#!/usr/bin/env bash
# =============================================================================
# PHASE 4C.1 concurrency test: do parallel create_order() calls overbook a slot?
#
# STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
#
# Needs a Supabase/Postgres DEV database with all migrations through
# 20260930060000_create_order_delivery_integration.sql applied, and `psql` on the PATH.
# It COMMITS real rows (a lock only means something between separate sessions) named co_* / cc2-*,
# and removes them on exit, including on failure. Never point it at production.
#
# PHASE 9B: create_order() now writes inventory_adjustments rows (append-only ledger), which pin the
# fixture product. The product is therefore RETAINED (deactivated) instead of deleted and re-used by
# the next run; everything else is deleted. Cleanup failures are reported and fail the run. See
# db/tests/lib/concurrency_cleanup.sh.
#
#   DATABASE_URL=postgres://... db/tests/create_order_concurrency.sh [SESSIONS] [CAPACITY]
#   defaults: 8 sessions, slot capacity 2
#
# Each session is one real create_order() call (own transaction, READ COMMITTED, signed in as the
# fixture customer through the JWT settings) for the same slot. EXPECT exactly CAPACITY orders to
# exist afterwards and every other session to be rejected with slot_full. Also checks that the
# rejected sessions did not consume stock.
#
# There is no unlocked control run here: that proof (the same race WITHOUT the lock overbooks, so
# the test can detect a failure) is in db/tests/delivery_slot_concurrency.sh. Run that one too.
#
# Exit codes: 0 pass, 1 a check failed.
# =============================================================================
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a DEV database}"
SESSIONS="${1:-8}"
CAPACITY="${2:-2}"
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

USER_ID='00000000-0000-4000-8000-0000000cc201'
PRODUCT_ID='00000000-0000-4000-8000-0000000cc2b1'
TEMPLATE_ID='00000000-0000-4000-8000-0000000cc2e1'
STOCK=100
WORK="$(mktemp -d)"

# shellcheck source=lib/concurrency_cleanup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/concurrency_cleanup.sh"

purge_fixtures() {
  CLEANUP_FAILED=0
  cleanup_step "orders, order items, slot template, delivery method" "
    delete from public.order_items where order_id in (select id from public.orders where delivery_method = 'co_cc_m');
    delete from public.orders where delivery_method = 'co_cc_m';
    delete from public.delivery_slot_templates where id = '${TEMPLATE_ID}';
    delete from public.delivery_methods where code = 'co_cc_m';"
  # Phase 9B: the ledger pins a product whose stock moved (append-only, FK RESTRICT). Delete the
  # product only when nothing references it; otherwise deactivate it and keep it for the next run.
  cleanup_step "fixture product" "
    do \$\$ begin
      if exists (select 1 from public.inventory_adjustments where product_id = '${PRODUCT_ID}') then
        update public.products set is_active = false where id = '${PRODUCT_ID}';
        raise notice 'RETAINED product co-cc2-p (the append-only inventory ledger references it): deactivated, re-used by the next run';
      else
        delete from public.products where id = '${PRODUCT_ID}';
      end if;
    end \$\$;"
  cleanup_step "fixture user" "delete from auth.users where id = '${USER_ID}';"
  cleanup_expect_none "fixture orders / method / template / user" "select
    (select count(*) from public.orders where delivery_method = 'co_cc_m')
  + (select count(*) from public.delivery_methods where code = 'co_cc_m')
  + (select count(*) from public.delivery_slot_templates where id = '${TEMPLATE_ID}')
  + (select count(*) from auth.users where id = '${USER_ID}')"
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

SLOT_DATE="$("${PSQL[@]}" -At -c "select (now() at time zone 'Africa/Nairobi')::date + 2")"

purge_fixtures || { echo "FAIL: leftovers of an earlier run could not be removed (see above); not starting." >&2; exit 1; }
"${PSQL[@]}" <<SQL
insert into auth.users (id, email, aud, role)
  values ('${USER_ID}', 'cc2-customer@example.test', 'authenticated', 'authenticated');
insert into public.delivery_methods
  (code, label, base_fee_cents, requires_slot, requires_address, is_active)
  values ('co_cc_m', 'CC2 method', 0, true, false, true);
-- Upsert: a product retained from an earlier run (ledger rows pin it) is reset to the starting stock.
insert into public.products (id, slug, name, price_cents, stock_quantity, in_stock, is_active)
  values ('${PRODUCT_ID}', 'co-cc2-p', 'CC2 product', 1000, ${STOCK}, true, true)
  on conflict (id) do update
    set stock_quantity = excluded.stock_quantity, in_stock = true, is_active = true;
insert into public.delivery_slot_templates
  (id, label, start_time, end_time, capacity, position, is_active)
  values ('${TEMPLATE_ID}', 'CC2 race', '20:00', '20:30', ${CAPACITY}, 100, true);
SQL

cat > "$WORK/worker.sql" <<'SQL'
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-8000-0000000cc201', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000cc201', true);
select public.create_order(
  '[{"product_id":"00000000-0000-4000-8000-0000000cc2b1","variant_id":null,"quantity":1}]'::jsonb,
  'co_cc_m', 'cash_on_delivery', null, :'slot_date'::date, '20:00', '20:30') as new_order \gset
\echo ORDER_PLACED
commit;
SQL

echo "== ${SESSIONS} concurrent create_order() calls, slot capacity ${CAPACITY}"
for i in $(seq 1 "$SESSIONS"); do
  # a rejected call aborts its own session (ON_ERROR_STOP); that is the expected outcome
  "${PSQL[@]}" -v slot_date="$SLOT_DATE" -f "$WORK/worker.sql" >"$WORK/s.$i.out" 2>&1 || true &
done
wait

PLACED="$(cat "$WORK"/s.*.out | grep -c '^ORDER_PLACED$' || true)"
FULL="$(cat "$WORK"/s.*.out | grep -c 'That delivery slot is full' || true)"
DB_ORDERS="$("${PSQL[@]}" -At -c "select count(*) from public.orders
  where delivery_method = 'co_cc_m' and delivery_slot_date = '${SLOT_DATE}' and status not in ('cancelled','refunded')")"
STOCK_NOW="$("${PSQL[@]}" -At -c "select stock_quantity from public.products where id = '${PRODUCT_ID}'")"
echo "   sessions reporting ORDER_PLACED: ${PLACED}; rejected as full: ${FULL}; orders in database: ${DB_ORDERS}; stock ${STOCK} -> ${STOCK_NOW}"

STATUS=0
if [ "$PLACED" -ne "$CAPACITY" ] || [ "$DB_ORDERS" -ne "$CAPACITY" ]; then
  echo "FAIL: expected exactly ${CAPACITY} orders (placed ${PLACED}, database ${DB_ORDERS})"; STATUS=1
else
  echo "PASS: exactly ${CAPACITY} orders were created"
fi
if [ "$((PLACED + FULL))" -ne "$SESSIONS" ]; then
  echo "FAIL: ${SESSIONS} sessions but ${PLACED} placed + ${FULL} 'slot is full' (see $WORK/s.*.out; kept until exit)"
  cat "$WORK"/s.*.out | grep -v '^ORDER_PLACED$' | sort | uniq -c | head -10
  STATUS=1
else
  echo "PASS: every other session was rejected as full"
fi
if [ "$STOCK_NOW" -ne "$((STOCK - CAPACITY))" ]; then
  echo "FAIL: stock is ${STOCK_NOW}, expected $((STOCK - CAPACITY)) (rejected orders must not consume stock)"; STATUS=1
else
  echo "PASS: rejected orders consumed no stock"
fi
exit "$STATUS"
