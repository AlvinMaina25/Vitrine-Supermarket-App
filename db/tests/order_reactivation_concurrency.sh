#!/usr/bin/env bash
# =============================================================================
# PHASE 4C.2B concurrency test: can checkout and reactivation overbook a slot?
#
# Needs a Postgres/Supabase DEV database with ALL migrations through
# 20260930070000_order_reactivation_capacity.sql applied, and `psql` on the PATH.
# Like delivery_slot_concurrency.sh it COMMITS real rows (a lock only means something between
# separate sessions), uses fixtures named rc_* / RC-*, and removes them on exit. Never point it
# at production.
#
#   DATABASE_URL=postgres://... db/tests/order_reactivation_concurrency.sh [SESSIONS]
#   default: 6 sessions per racing group
#
# Scenarios (every session = one READ COMMITTED transaction that holds its change open 0.4 s
# before COMMIT, to widen the window in which a missing lock would let two sessions both pass):
#   1. TWO REACTIVATIONS   capacity 2, 1 active order, SESSIONS cancelled orders all moved to
#                          'pending' at once.            EXPECT exactly 1 reactivation commits
#                          and the slot ends with exactly 2 active orders.
#   2. CHECKOUT vs REACTIVATION  capacity 1, nothing active. SESSIONS checkouts (the same
#                          lock_delivery_slot() -> insert steps create_order() runs) race
#                          SESSIONS reactivations.       EXPECT exactly 1 active order.
#   3. CONTROL             scenario 1 again with the guard trigger DISABLED. EXPECT it to
#                          overbook; if it does not the script says INCONCLUSIVE (exit 2),
#                          because then scenarios 1-2 proved nothing.
#
# Exit codes: 0 all good, 1 a protection check failed, 2 inconclusive control.
# =============================================================================
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a DEV database}"
SESSIONS="${1:-6}"
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

USER_ID='00000000-0000-4000-8000-00000000dd01'
T1='00000000-0000-4000-8000-00000000dd11'   # capacity 2  (scenarios 1, 3)
T2='00000000-0000-4000-8000-00000000dd12'   # capacity 1  (scenario 2)
WORK="$(mktemp -d)"

purge_fixtures() {
  "${PSQL[@]}" >/dev/null 2>&1 <<SQL || true
alter table public.orders enable trigger orders_guard_reactivation_capacity;
delete from public.orders where delivery_method = 'rc_m';
delete from public.delivery_slot_templates where id in ('${T1}', '${T2}');
delete from public.delivery_methods where code = 'rc_m';
delete from auth.users where id = '${USER_ID}';
SQL
}
cleanup() { purge_fixtures; rm -rf "$WORK"; }
trap cleanup EXIT

read -r D1 D2 D3 < <("${PSQL[@]}" -At -F ' ' -c \
  "select (now() at time zone 'Africa/Nairobi')::date + 2,
          (now() at time zone 'Africa/Nairobi')::date + 3,
          (now() at time zone 'Africa/Nairobi')::date + 4")

purge_fixtures
"${PSQL[@]}" <<SQL
insert into auth.users (id, email, aud, role)
  values ('${USER_ID}', 'rc-customer@example.test', 'authenticated', 'authenticated');
insert into public.delivery_methods
  (code, label, base_fee_cents, requires_slot, requires_address, is_active)
  values ('rc_m', 'RC method', 0, true, false, true);
insert into public.delivery_slot_templates
  (id, label, start_time, end_time, capacity, position, is_active) values
  ('${T1}', 'RC cap2', '22:00', '22:30', 2, 100, true),
  ('${T2}', 'RC cap1', '22:30', '23:00', 1, 100, true);
SQL

mk_order() {  # mk_order <status> <date> <start> <end>  -> prints the new id
  "${PSQL[@]}" -At -c "insert into public.orders
    (user_id, order_number, status, payment_method, delivery_method,
     delivery_slot_date, delivery_slot_start, delivery_slot_end)
    values ('${USER_ID}', 'RC-' || substr(gen_random_uuid()::text, 1, 12), '$1',
            'cash_on_delivery', 'rc_m', '$2', '$3', '$4') returning id"
}

cat > "$WORK/reactivate.sql" <<'SQL'
begin;
update public.orders set status = 'pending' where id = :'order_id';
select pg_sleep(0.4);
commit;
\echo REACTIVATED
SQL

cat > "$WORK/checkout.sql" <<'SQL'
-- The steps create_order() runs: lock -> check -> insert -> commit.
begin;
select * from public.lock_delivery_slot(:'slot_date'::date, :'slot_start'::time, :'slot_end'::time) \gset r_
\if :r_is_valid
  select pg_sleep(0.4);
  insert into public.orders
    (user_id, order_number, payment_method, delivery_method,
     delivery_slot_date, delivery_slot_start, delivery_slot_end)
  values ('00000000-0000-4000-8000-00000000dd01',
          'RC-' || substr(gen_random_uuid()::text, 1, 12),
          'cash_on_delivery', 'rc_m', :'slot_date'::date, :'slot_start'::time, :'slot_end'::time);
  \echo ORDER_PLACED
\else
  \echo REJECTED :r_error_code
\endif
commit;
SQL

active_count() {  # active_count <date> <start> <end>
  "${PSQL[@]}" -At -c "select count(*) from public.orders
    where delivery_method = 'rc_m' and delivery_slot_date = '$1'
      and delivery_slot_start = '$2' and delivery_slot_end = '$3'
      and status not in ('cancelled','refunded')"
}

count_out() { cat "$WORK"/"$1".*.out 2>/dev/null | grep -c "^$2\$" || true; }

# --- scenario 1 & 3 helper: reactivation race on the capacity-2 slot ------------------------
reactivation_race() {  # reactivation_race <date> <label>
  local date="$1" label="$2" i id
  mk_order pending "$date" 22:00 22:30 >/dev/null
  for i in $(seq 1 "$SESSIONS"); do
    id="$(mk_order cancelled "$date" 22:00 22:30)"
    "${PSQL[@]}" -v order_id="$id" -f "$WORK/reactivate.sql" >"$WORK/$label.$i.out" 2>&1 &
  done
  wait
}

echo "== 1. TWO REACTIVATIONS: ${SESSIONS} sessions, capacity 2, 1 already active"
reactivation_race "$D1" r1
OK1="$(count_out r1 REACTIVATED)"; DB1="$(active_count "$D1" 22:00 22:30)"
echo "   reactivations committed: ${OK1}; active orders in database: ${DB1}"

echo "== 2. CHECKOUT vs REACTIVATION: ${SESSIONS} + ${SESSIONS} sessions, capacity 1, 0 active"
for i in $(seq 1 "$SESSIONS"); do
  id="$(mk_order cancelled "$D2" 22:30 23:00)"
  "${PSQL[@]}" -v order_id="$id" -f "$WORK/reactivate.sql" >"$WORK/r2.$i.out" 2>&1 &
  "${PSQL[@]}" -v slot_date="$D2" -v slot_start=22:30 -v slot_end=23:00 \
    -f "$WORK/checkout.sql" >"$WORK/c2.$i.out" 2>&1 &
done
wait
OKR="$(count_out r2 REACTIVATED)"; OKC="$(count_out c2 ORDER_PLACED)"; DB2="$(active_count "$D2" 22:30 23:00)"
echo "   reactivations committed: ${OKR}; checkouts placed: ${OKC}; active orders in database: ${DB2}"

echo "== 3. CONTROL: scenario 1 with the guard trigger DISABLED"
"${PSQL[@]}" -c "alter table public.orders disable trigger orders_guard_reactivation_capacity"
reactivation_race "$D3" r3
"${PSQL[@]}" -c "alter table public.orders enable trigger orders_guard_reactivation_capacity"
DB3="$(active_count "$D3" 22:00 22:30)"
echo "   active orders in database: ${DB3}"

STATUS=0
if [ "$DB1" -ne 2 ] || [ "$OK1" -ne 1 ]; then
  echo "FAIL: scenario 1 expected 1 reactivation and 2 active orders (got ${OK1} / ${DB1})"; STATUS=1
else
  echo "PASS: two racing reactivations took exactly the one remaining place"
fi
if [ "$DB2" -ne 1 ] || [ $((OKR + OKC)) -ne 1 ]; then
  echo "FAIL: scenario 2 expected exactly 1 active order (got ${DB2}; ${OKR} reactivated + ${OKC} checked out)"; STATUS=1
else
  echo "PASS: checkout racing reactivation never exceeded capacity 1"
fi
if [ "$DB3" -le 2 ]; then
  echo "INCONCLUSIVE: the unguarded control did not overbook (${DB3} <= 2); try more sessions: $0 12"
  [ "$STATUS" -eq 0 ] && STATUS=2
else
  echo "PASS: control overbooked (${DB3} > 2), so this test can detect the race"
fi
exit "$STATUS"
