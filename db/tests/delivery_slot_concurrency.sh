#!/usr/bin/env bash
# =============================================================================
# PHASE 4B.2 concurrency test: does lock_delivery_slot() really stop overbooking?
#
# STATUS: written, NOT executed (no PostgreSQL was available when this was authored).
#
# Needs a Supabase/Postgres DEV database with all migrations through
# 20260930050000_delivery_slot_validation.sql applied, and `psql` on the PATH.
# Unlike db/tests/delivery_slot_validation.test.sql this one COMMITS real rows (it has to:
# a lock only means something between separate sessions). It creates fixtures named cc_* /
# CC-*, and removes them on exit, including on failure. Never point it at production.
#
#   DATABASE_URL=postgres://... db/tests/delivery_slot_concurrency.sh [SESSIONS] [CAPACITY]
#   defaults: 8 sessions racing for a slot with capacity 2
#
# What it does:
#   A. LOCKED run   Each session runs, in one READ COMMITTED transaction, the same steps the
#                   Phase 4C create_order() must run: lock_delivery_slot() -> if valid, wait
#                   0.4 s (to widen the gap between the check and the insert) -> insert an
#                   order -> commit. EXPECT exactly CAPACITY orders placed.
#   B. CONTROL run  Same, but the check is the lock-free validate_delivery_slot(). EXPECT more
#                   than CAPACITY orders placed. This proves the test is able to see an
#                   overbooking; if the control does NOT overbook, the locked run proved
#                   nothing and the script says INCONCLUSIVE (exit 2).
#   C. GUARD        lock_delivery_slot() must refuse a REPEATABLE READ transaction.
#
# Exit codes: 0 all good, 1 a protection check failed, 2 inconclusive control.
# =============================================================================
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a DEV database}"
SESSIONS="${1:-8}"
CAPACITY="${2:-2}"
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

USER_ID='00000000-0000-4000-8000-00000000cc01'
TEMPLATE_ID='00000000-0000-4000-8000-00000000cc11'
WORK="$(mktemp -d)"

purge_fixtures() {
  "${PSQL[@]}" >/dev/null 2>&1 <<SQL || true
delete from public.orders where delivery_method = 'cc_m';
delete from public.delivery_slot_templates where id = '${TEMPLATE_ID}';
delete from public.delivery_methods where code = 'cc_m';
delete from auth.users where id = '${USER_ID}';
SQL
}
cleanup() {
  purge_fixtures
  rm -rf "$WORK"
}
trap cleanup EXIT

# Two dates two and three days ahead (store time): one per run, so the runs cannot interfere.
read -r DATE_LOCKED DATE_CONTROL < <("${PSQL[@]}" -At -F ' ' -c \
  "select (now() at time zone 'Africa/Nairobi')::date + 2, (now() at time zone 'Africa/Nairobi')::date + 3")

purge_fixtures   # leftovers from an interrupted earlier run
"${PSQL[@]}" <<SQL
insert into auth.users (id, email, aud, role)
  values ('${USER_ID}', 'cc-customer@example.test', 'authenticated', 'authenticated');
insert into public.delivery_methods
  (code, label, base_fee_cents, requires_slot, requires_address, is_active)
  values ('cc_m', 'CC method', 0, true, false, true);
insert into public.delivery_slot_templates
  (id, label, start_time, end_time, capacity, position, is_active)
  values ('${TEMPLATE_ID}', 'CC race', '21:00', '21:30', ${CAPACITY}, 100, true);
SQL

cat > "$WORK/worker.sql" <<'SQL'
-- One simulated checkout. :checkfn is the slot check, :slot_date the date raced for.
begin;
select * from :checkfn(:'slot_date'::date, '21:00', '21:30') \gset r_
\if :r_is_valid
  select pg_sleep(0.4);
  insert into public.orders
    (user_id, order_number, payment_method, delivery_method,
     delivery_slot_date, delivery_slot_start, delivery_slot_end)
  values
    ('00000000-0000-4000-8000-00000000cc01',
     'CC-' || substr(gen_random_uuid()::text, 1, 12),
     'cash_on_delivery', 'cc_m', :'slot_date'::date, '21:00', '21:30');
  \echo ORDER_PLACED
\else
  \echo REJECTED :r_error_code
\endif
commit;
SQL

race() {  # race <checkfn> <date> <label>
  local checkfn="$1" date="$2" label="$3" i
  for i in $(seq 1 "$SESSIONS"); do
    "${PSQL[@]}" -v checkfn="$checkfn" -v slot_date="$date" -f "$WORK/worker.sql" \
      >"$WORK/$label.$i.out" 2>&1 &
  done
  wait
  cat "$WORK"/"$label".*.out | grep -c '^ORDER_PLACED$' || true
}

db_count() {  # db_count <date>
  "${PSQL[@]}" -At -c "select count(*) from public.orders
    where delivery_method = 'cc_m' and delivery_slot_date = '$1' and status not in ('cancelled','refunded')"
}

echo "== A. LOCKED run: ${SESSIONS} sessions, capacity ${CAPACITY}"
PLACED_LOCKED="$(race public.lock_delivery_slot "$DATE_LOCKED" locked)"
DB_LOCKED="$(db_count "$DATE_LOCKED")"
echo "   sessions that reported ORDER_PLACED: ${PLACED_LOCKED}; orders in database: ${DB_LOCKED}"

echo "== B. CONTROL run (no lock, read-only check)"
PLACED_CONTROL="$(race public.validate_delivery_slot "$DATE_CONTROL" control)"
DB_CONTROL="$(db_count "$DATE_CONTROL")"
echo "   sessions that reported ORDER_PLACED: ${PLACED_CONTROL}; orders in database: ${DB_CONTROL}"

echo "== C. GUARD: REPEATABLE READ must be refused"
GUARD_OUT="$("${PSQL[@]}" -c "begin isolation level repeatable read;
  select * from public.lock_delivery_slot('${DATE_LOCKED}'::date, '21:00', '21:30');
  commit;" 2>&1 || true)"
GUARD_OK=0
if grep -q 'requires READ COMMITTED' <<<"$GUARD_OUT"; then GUARD_OK=1; fi
echo "   refused: $([ "$GUARD_OK" -eq 1 ] && echo yes || echo NO)"

STATUS=0
if [ "$PLACED_LOCKED" -ne "$CAPACITY" ] || [ "$DB_LOCKED" -ne "$CAPACITY" ]; then
  echo "FAIL: locked run placed ${PLACED_LOCKED} (database ${DB_LOCKED}), expected exactly ${CAPACITY}"
  STATUS=1
else
  echo "PASS: locked run placed exactly ${CAPACITY} orders"
fi
if [ "$GUARD_OK" -ne 1 ]; then
  echo "FAIL: lock_delivery_slot() did not refuse REPEATABLE READ"
  STATUS=1
else
  echo "PASS: REPEATABLE READ refused"
fi
if [ "$DB_CONTROL" -le "$CAPACITY" ]; then
  echo "INCONCLUSIVE: the unlocked control did not overbook (database ${DB_CONTROL} <= ${CAPACITY});"
  echo "              try more sessions, e.g. $0 16 ${CAPACITY}. The locked result proves nothing until it does."
  [ "$STATUS" -eq 0 ] && STATUS=2
else
  echo "PASS: control overbooked (${DB_CONTROL} > ${CAPACITY}), so the test can detect the race"
fi
exit "$STATUS"
