#!/usr/bin/env bash
# =============================================================================
# PHASE 6C.2.2B.2 TRUE CONCURRENCY test of public.admin_adjust_inventory().
#
# STATUS: written, NOT RUN by the author (no PostgreSQL / psql was available).
#
# Needs the dedicated Phase-5 DEV database with ALL Phase 6C migrations applied and `psql` on the
# PATH. Like order_reactivation_concurrency.sh it COMMITS real rows (a row lock only means
# something between separate sessions), uses fixtures named cx6c2 / CX6C2, and removes them on
# exit. NEVER point it at production.
#
# PHASE 9B: inventory_adjustments is APPEND-ONLY and its foreign keys to products / variants are
# RESTRICT, so a fixture unit whose stock moved can no longer be deleted. Cleanup therefore deletes
# what it can (users, roles, units the ledger never saw) and RETAINS the rest, deactivated; the
# next run re-uses those units (fixed ids, stock reset by an upsert). Because retained units carry
# ledger rows from earlier runs, every ledger assertion below counts only THIS run's
# 'admin_adjustment' rows (created_at >= $RUN_START). Cleanup failures are reported and fail the
# run. See db/tests/lib/concurrency_cleanup.sh.
#
#   DATABASE_URL=postgres://... db/tests/phase6c2_inventory_concurrency_final.sh [SESSIONS]
#   default 8 sessions per racing group (must be even and >= 6)
#
# Every racing session is its OWN psql connection = its own READ COMMITTED transaction that
#   1. becomes the 'authenticated' role with a real admin JWT sub (so require_admin() is exercised),
#   2. waits on a shared advisory-lock BARRIER so that all sessions are released at the same instant,
#   3. calls admin_adjust_inventory(), then HOLDS its transaction open 0.3 s before COMMIT, which
#      widens the window in which a missing row lock would let a second session read stale stock.
#
# Scenarios (product group and variant group race AT THE SAME TIME in each):
#   S1  positive    N x +7 on the product, N x +3 on the variant
#   S2  negative    N x -9 on the product, N x -4 on the variant (plenty of stock)
#   S3  mixed       N/2 x +5 and N/2 x -3 on the product; N/2 x +6 and N/2 x -2 on the variant
#   S4  no negative stock 10 on both units, N x -3  -> exactly 3 succeed each, the rest are
#                   refused negative_stock_not_allowed, final stock 1, exactly 3 history rows each
#   S5  overflow    2147483640 on both units, N x +5 -> exactly 1 succeeds each (2147483645), the
#                   rest are refused stock_overflow
#   S6  mismatch    N x (product A, variant of product B) refused variant_product_mismatch while
#                   N x legitimate +1 on B's variant succeed; plus 3 non-admin callers refused
#   S7  LOCKING     (a) session A holds the lock on a product; session B (same product) is seen
#                   WAITING on a Lock in pg_stat_activity and finishes only after A commits;
#                   (b) session C on a DIFFERENT product is NOT blocked by A.
#   S8  CONTROL     a deliberately UNLOCKED read-modify-write (plain SQL, not the function) races
#                   in the same harness. EXPECT it to lose updates; if it does not, the script says
#                   INCONCLUSIVE (exit 2), because then S1-S6 proved nothing.
#
# After each scenario the script checks, per stock unit: stored stock = start + sum of the
# successful deltas; exactly one history row per success and none for a failure; previous + delta
# = new on every row; the multiset identity  {previous} + {final} = {new} + {start}  (a lost update
# makes two rows share one previous value and breaks it); no row below zero; the parent product is
# unchanged by variant adjustments and vice versa; and the history API returns the same rows.
#
# Exit codes: 0 all good, 1 a check FAILED (stop; report it, do not patch), 2 inconclusive control.
# =============================================================================
set -uo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a DEV database}"
N="${1:-8}"
if (( N < 6 || N % 2 )); then echo "SESSIONS must be even and >= 6" >&2; exit 1; fi
PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)
WORK="$(mktemp -d)"
BARRIER_KEY=62026
PASS=0; FAIL=0

ADMIN='00000000-0000-4000-8000-6fb000000001'
ADMIN2='00000000-0000-4000-8000-6fb000000002'
CUST='00000000-0000-4000-8000-6fb000000003'
pid() { printf '00000000-0000-4000-8000-6fc%09d' "$1"; }   # products 1..9
vid() { printf '00000000-0000-4000-8000-6fd%09d' "$1"; }   # variants 1..9

sql()  { "${PSQL[@]}" -At -c "$1"; }
sqlf() { "${PSQL[@]}" "$@"; }

# shellcheck source=lib/concurrency_cleanup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/concurrency_cleanup.sh"

# Only ledger rows written by THIS run count (retained units keep rows from earlier runs).
RUN_START="$(sql "select clock_timestamp()")"
RUN_ROWS="a.movement_kind = 'admin_adjustment' and a.created_at >= '${RUN_START}'::timestamptz"

purge() {
  CLEANUP_FAILED=0
  cleanup_step "fixture roles and users" "
    delete from public.user_roles where user_id in ('${ADMIN}', '${ADMIN2}');
    delete from auth.users where id in ('${ADMIN}', '${ADMIN2}', '${CUST}');"
  # Phase 9B: units the append-only ledger references cannot be deleted (FK RESTRICT). Delete the
  # others; deactivate and keep the rest. The ledger itself is never touched.
  cleanup_step "fixture variants and products" "
    do \$\$ declare v_v integer; v_p integer; begin
      delete from public.product_variants v
       where v.sku like 'CX6C2-%'
         and not exists (select 1 from public.inventory_adjustments a where a.variant_id = v.id);
      update public.product_variants set is_active = false where sku like 'CX6C2-%' and is_active;
      delete from public.products p
       where p.slug like 'cx6c2-%'
         and not exists (select 1 from public.inventory_adjustments a where a.product_id = p.id)
         and not exists (select 1 from public.product_variants v where v.product_id = p.id);
      update public.products set is_active = false where slug like 'cx6c2-%' and is_active;
      select count(*) into v_v from public.product_variants where sku like 'CX6C2-%';
      select count(*) into v_p from public.products where slug like 'cx6c2-%';
      if v_v + v_p > 0 then
        raise notice 'RETAINED % cx6c2 product(s) and % variant(s) (the append-only inventory ledger references them): deactivated, re-used by the next run', v_p, v_v;
      end if;
    end \$\$;"
  cleanup_expect_none "fixture users / roles / active fixture units" "select
    (select count(*) from auth.users where id in ('${ADMIN}', '${ADMIN2}', '${CUST}'))
  + (select count(*) from public.user_roles where user_id in ('${ADMIN}', '${ADMIN2}'))
  + (select count(*) from public.products where slug like 'cx6c2-%' and is_active)
  + (select count(*) from public.product_variants where sku like 'CX6C2-%' and is_active)"
  [ "$CLEANUP_FAILED" -eq 0 ]
}
cleanup() {
  local rc=$?
  [[ -n "${BARRIER_PID:-}" ]] && kill "$BARRIER_PID" 2>/dev/null
  jobs -p | xargs -r kill 2>/dev/null
  purge || true
  rm -rf "$WORK"
  finish_cleanup "$rc"
  exit $?
}
trap cleanup EXIT

check() {  # check <name> <sql returning t|f>
  local r; r="$(sql "$2" 2>&1)"
  if [[ "$r" == "t" ]]; then PASS=$((PASS+1)); echo "PASS: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1   (got: $r)"; echo "STOP: concurrency / consistency failure. Do NOT patch automatically; report it."; exit 1; fi
}

# ---------------------------------------------------------------- fixtures
purge || { echo "FAIL: leftovers of an earlier run could not be removed (see above); not starting." >&2; exit 1; }
sqlf >/dev/null <<SQL
insert into auth.users (id, email, aud, role) values
  ('${ADMIN}',  'cx6c2-admin@example.test',  'authenticated', 'authenticated'),
  ('${ADMIN2}', 'cx6c2-admin2@example.test', 'authenticated', 'authenticated'),
  ('${CUST}',   'cx6c2-cust@example.test',   'authenticated', 'authenticated');
insert into public.user_roles (user_id, role) values ('${ADMIN}', 'admin'), ('${ADMIN2}', 'admin');
SQL

mk_unit() {  # mk_unit <n> <product stock> <variant stock>   -> product n with variant n
  # Upserts: a unit retained from an earlier run (its ledger rows pin it) is reset to the start stock.
  # The reset is a stock_change row, which RUN_ROWS (admin_adjustment only) does not count.
  sql "insert into public.products (id, slug, name, sku, price_cents, stock_quantity, in_stock, is_active)
         values ('$(pid "$1")', 'cx6c2-$1', 'CX6C2 P$1', 'CX6C2-P$1', 100, $2, true, true)
         on conflict (id) do update set stock_quantity = excluded.stock_quantity, in_stock = true, is_active = true;
       insert into public.product_variants (id, product_id, name, sku, price_cents, stock_quantity, position, is_active)
         values ('$(vid "$1")', '$(pid "$1")', 'CX6C2 V$1', 'CX6C2-V$1', 100, $3, 1, true)
         on conflict (id) do update set stock_quantity = excluded.stock_quantity, is_active = true;" >/dev/null
}

# ---------------------------------------------------------------- session templates
# Racing session: barrier -> adjust -> hold -> commit. Output markers: OK | ERR <detail> | ERR <sqlstate-text>.
cat > "$WORK/adjust.sql" <<'SQL'
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', :'uid', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select pg_advisory_xact_lock_shared(:barrier);
select public.admin_adjust_inventory(:'prod'::uuid, :delta, :'reason', nullif(:'var', '')::uuid, null) is not null as ok \gset r_
select pg_sleep(0.3);
commit;
\echo OK
SQL

barrier_hold() {  # start the exclusive barrier holder, wait until it holds the lock
  PGAPPNAME=cx6c2_barrier "${PSQL[@]}" -c "select pg_advisory_lock($BARRIER_KEY); select pg_sleep(120);" >/dev/null 2>&1 &
  BARRIER_PID=$!
  local i
  for i in $(seq 1 100); do
    [[ "$(sql "select count(*) from pg_locks where locktype='advisory' and objid=$BARRIER_KEY and granted")" == "1" ]] && return 0
    sleep 0.1
  done
  echo "could not take the barrier lock" >&2; exit 1
}
barrier_release() {  # wait until $1 sessions wait on the barrier, then release them all at once
  local want="$1" i
  for i in $(seq 1 300); do
    [[ "$(sql "select count(*) from pg_locks where locktype='advisory' and objid=$BARRIER_KEY and not granted")" -ge "$want" ]] && break
    sleep 0.1
  done
  kill "$BARRIER_PID" 2>/dev/null; wait "$BARRIER_PID" 2>/dev/null; BARRIER_PID=""
  sql "select pg_terminate_backend(pid) from pg_stat_activity where application_name='cx6c2_barrier'" >/dev/null
}
launch() {  # launch <tag> <uid> <product> <variant-or-empty> <delta> [reason]
  PGAPPNAME=cx6c2_worker "${PSQL[@]}" -v uid="$2" -v prod="$3" -v var="$4" -v delta="$5" -v reason="${6:-CX6C2 race}" \
       -v barrier="$BARRIER_KEY" -f "$WORK/adjust.sql" >"$WORK/$1.out" 2>&1 &
}
count_ok()  { cat "$WORK/$1".*.out 2>/dev/null | grep -c '^OK$' || true; }
count_err() { cat "$WORK/$1".*.out 2>/dev/null | grep -c "DETAIL:.*$2" || true; }

# unit_check <name> <product> <variant-or-empty> <start> <expected successes> <expected final>
unit_check() {
  local name="$1" p="$2" v="$3" start="$4" nsucc="$5" final="$6" vf
  if [[ -z "$v" ]]; then vf="a.variant_id is null"; stock="(select stock_quantity from public.products where id='$p')"
  else vf="a.variant_id='$v'"; stock="(select stock_quantity from public.product_variants where id='$v')"; fi
  local H="(select * from public.inventory_adjustments a where a.product_id='$p' and $vf and $RUN_ROWS)"
  check "$name stored stock = $final (start $start + sum of the $nsucc successful deltas)" "select $stock = $final"
  check "$name exactly $nsucc history rows (one per success, none for a failure)" "select (select count(*) from $H h) = $nsucc"
  check "$name sum of history deltas = final - start" "select coalesce((select sum(adjustment_quantity) from $H h),0) = $final - $start"
  check "$name previous + delta = new on every row, no negative row" \
    "select not exists (select 1 from $H h where previous_quantity + adjustment_quantity <> new_quantity or new_quantity < 0 or previous_quantity < 0)"
  check "$name NO LOST UPDATE: {previous}+{final} = {new}+{start} as multisets" \
    "select (select array_agg(q order by q) from (select previous_quantity q from $H h union all select $final) x)
          = (select array_agg(q order by q) from (select new_quantity q from $H h union all select $start) y)"
  check "$name every previous_quantity is produced exactly once (no two rows read the same stock)" \
    "select not exists (select 1 from $H h where (select count(*) from $H h2 where h2.previous_quantity = h.previous_quantity)
                          > (select count(*) from $H h3 where h3.new_quantity = h.previous_quantity) + (case when h.previous_quantity = $start then 1 else 0 end))"
}

# race <tag> <specs...>   spec = "uid|product|variant|delta"; runs them all behind the barrier
race() {
  local tag="$1"; shift; local i=0 s
  barrier_hold
  for s in "$@"; do i=$((i+1)); IFS='|' read -r u p v d <<<"$s"; launch "$tag.$i" "$u" "$p" "$v" "$d"; done
  barrier_release "$#"
  wait
}
none_stuck() { check "$1 no session is left running / waiting" "select count(*) = 0 from pg_stat_activity where application_name in ('cx6c2_worker','cx6c2_barrier')"; }

echo "== true concurrency: $N independent psql sessions per group =="
echo "== S1 positive adjustments (product +7 x$N and variant +3 x$N, simultaneously) =="
mk_unit 1 100 50
specs=(); for i in $(seq 1 $N); do specs+=("$ADMIN|$(pid 1)||7" "$ADMIN2|$(pid 1)|$(vid 1)|3"); done
race s1 "${specs[@]}"
check "S1 all $((2*N)) sessions succeeded" "select $(count_ok s1) = $((2*N))"
unit_check "S1 product" "$(pid 1)" "" 100 "$N" $((100+7*N))
unit_check "S1 variant" "$(pid 1)" "$(vid 1)" 50 "$N" $((50+3*N))
check "S1 product adjustments did not touch variant stock, variant adjustments did not touch product stock (both asserted via exact finals above; in_stock preserved)" \
  "select (select in_stock from public.products where id='$(pid 1)')"
none_stuck S1

echo "== S2 negative adjustments (product -9 x$N, variant -4 x$N) =="
mk_unit 2 1000 500
specs=(); for i in $(seq 1 $N); do specs+=("$ADMIN|$(pid 2)||-9" "$ADMIN2|$(pid 2)|$(vid 2)|-4"); done
race s2 "${specs[@]}"
check "S2 all sessions succeeded" "select $(count_ok s2) = $((2*N))"
unit_check "S2 product" "$(pid 2)" "" 1000 "$N" $((1000-9*N))
unit_check "S2 variant" "$(pid 2)" "$(vid 2)" 500 "$N" $((500-4*N))
none_stuck S2

echo "== S3 mixed positive/negative =="
mk_unit 3 100 100
specs=(); for i in $(seq 1 $((N/2))); do specs+=("$ADMIN|$(pid 3)||5" "$ADMIN2|$(pid 3)||-3" "$ADMIN|$(pid 3)|$(vid 3)|6" "$ADMIN2|$(pid 3)|$(vid 3)|-2"); done
race s3 "${specs[@]}"
check "S3 all sessions succeeded" "select $(count_ok s3) = $((2*N))"
unit_check "S3 product" "$(pid 3)" "" 100 "$N" $((100 + (N/2)*5 - (N/2)*3))
unit_check "S3 variant" "$(pid 3)" "$(vid 3)" 100 "$N" $((100 + (N/2)*6 - (N/2)*2))
none_stuck S3

echo "== S4 no negative stock: stock 10, N x -3 on product AND variant =="
mk_unit 4 10 10
specs=(); for i in $(seq 1 $N); do specs+=("$ADMIN|$(pid 4)||-3" "$ADMIN2|$(pid 4)|$(vid 4)|-3"); done
race s4 "${specs[@]}"
check "S4 exactly 6 successes (3 per unit)" "select $(count_ok s4) = 6"
check "S4 every other session was refused negative_stock_not_allowed" "select $(count_err s4 negative_stock_not_allowed) = $((2*N-6))"
unit_check "S4 product" "$(pid 4)" "" 10 3 1
unit_check "S4 variant" "$(pid 4)" "$(vid 4)" 10 3 1
check "S4 no unit anywhere is negative" "select not exists (select 1 from public.products where stock_quantity<0) and not exists (select 1 from public.product_variants where stock_quantity<0)"
none_stuck S4

echo "== S5 integer overflow under contention =="
mk_unit 5 2147483640 2147483640
specs=(); for i in $(seq 1 $N); do specs+=("$ADMIN|$(pid 5)||5" "$ADMIN2|$(pid 5)|$(vid 5)|5"); done
race s5 "${specs[@]}"
check "S5 exactly 2 successes (1 per unit)" "select $(count_ok s5) = 2"
check "S5 every other session was refused stock_overflow" "select $(count_err s5 stock_overflow) = $((2*N-2))"
unit_check "S5 product" "$(pid 5)" "" 2147483640 1 2147483645
unit_check "S5 variant" "$(pid 5)" "$(vid 5)" 2147483640 1 2147483645
none_stuck S5

echo "== S6 variant/product mismatch + non-admin callers, racing a legitimate stream =="
mk_unit 6 20 20; mk_unit 7 20 20
specs=(); for i in $(seq 1 $N); do specs+=("$ADMIN|$(pid 6)|$(vid 7)|1" "$ADMIN2|$(pid 7)|$(vid 7)|1"); done
specs+=("$CUST|$(pid 7)||1" "$CUST|$(pid 7)|$(vid 7)|1" "$CUST|$(pid 6)||1")
race s6 "${specs[@]}"
check "S6 the N legitimate +1 sessions succeeded, nothing else" "select $(count_ok s6) = $N"
check "S6 N mismatches refused variant_product_mismatch" "select $(count_err s6 variant_product_mismatch) = $N"
check "S6 3 customer sessions refused not_authorised" "select $(count_err s6 not_authorised) = 3"
unit_check "S6 variant of product 7" "$(pid 7)" "$(vid 7)" 20 "$N" $((20+N))
check "S6 product 6 / variant 6 / product 7 / variant 6 untouched, no history for them" \
  "select (select stock_quantity from public.products where id='$(pid 6)')=20
      and (select stock_quantity from public.product_variants where id='$(vid 6)')=20
      and (select stock_quantity from public.products where id='$(pid 7)')=20
      and not exists (select 1 from public.inventory_adjustments a where $RUN_ROWS
                      and (a.product_id in ('$(pid 6)') or (a.product_id='$(pid 7)' and a.variant_id is null)))"
none_stuck S6

echo "== S7 row LOCKING behaviour =="
mk_unit 8 10 10; mk_unit 9 10 10
cat > "$WORK/hold.sql" <<'SQL'
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', :'uid', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select public.admin_adjust_inventory(:'prod'::uuid, :delta, 'CX6C2 hold', null, null) is not null as ok \gset r_
\echo HELD
select pg_sleep(:hold);
commit;
\echo OK
SQL
t0=$(date +%s%N)
PGAPPNAME=cx6c2_worker "${PSQL[@]}" -v uid="$ADMIN" -v prod="$(pid 8)" -v delta=1 -v hold=20 -f "$WORK/hold.sql" >"$WORK/hold.out" 2>&1 &
PID_A=$!
for i in $(seq 1 100); do grep -q '^HELD$' "$WORK/hold.out" 2>/dev/null && break; sleep 0.1; done
check "S7 session A's uncommitted +1 is invisible to other sessions (A is mid-transaction, holding the row lock)" "select (select stock_quantity from public.products where id='$(pid 8)')=10"   # uncommitted: others still see 10
tB=$(date +%s%N)
PGAPPNAME=cx6c2_worker "${PSQL[@]}" -v uid="$ADMIN2" -v prod="$(pid 8)" -v delta=1 -v hold=0 -f "$WORK/hold.sql" >"$WORK/b.out" 2>&1 &
PID_B=$!
tC=$(date +%s%N)
PGAPPNAME=cx6c2_worker "${PSQL[@]}" -v uid="$ADMIN2" -v prod="$(pid 9)" -v delta=1 -v hold=0 -f "$WORK/hold.sql" >"$WORK/c.out" 2>&1 &
PID_C=$!
wait "$PID_C"
# Snapshot of the output markers at the instant C completed (deterministic, no timing threshold):
#   A prints HELD after its call returns and OK only after COMMIT; B prints HELD only once it got the row lock.
snap_a_held=0; snap_a_done=0; snap_b_held=0; snap_b_done=0
grep -q '^HELD$' "$WORK/hold.out" 2>/dev/null && snap_a_held=1
grep -q '^OK$'   "$WORK/hold.out" 2>/dev/null && snap_a_done=1
grep -q '^HELD$' "$WORK/b.out"    2>/dev/null && snap_b_held=1
grep -q '^OK$'   "$WORK/b.out"    2>/dev/null && snap_b_done=1
kill -0 "$PID_A" 2>/dev/null && snap_a_alive=1 || snap_a_alive=0
echo "S7 diag at C completion: a_alive=$snap_a_alive a_held=$snap_a_held a_done=$snap_a_done b_held=$snap_b_held b_done=$snap_b_done c_ok=$(grep -c '^OK$' "$WORK/c.out" 2>/dev/null)"
check "S7 session C (a DIFFERENT product) completed OK while A was still open (A alive, HELD printed, no OK/commit yet)" \
  "select $([[ $snap_a_alive == 1 && $snap_a_held == 1 && $snap_a_done == 0 ]] && grep -q '^OK$' "$WORK/c.out" && echo true || echo false)"
sleep 0.5
check "S7 session B (SAME product) was blocked behind A: B had printed neither HELD nor OK when C finished, and A was still open" \
  "select $([[ $snap_a_done == 0 && $snap_b_held == 0 && $snap_b_done == 0 ]] && ! grep -q '^HELD$' "$WORK/b.out" && kill -0 "$PID_A" 2>/dev/null && echo true || echo false)"
check "S7 B has not completed while A is open" "select not exists (select 1 from public.inventory_adjustments a where a.product_id='$(pid 8)' and a.changed_by='$ADMIN2' and $RUN_ROWS)"
wait "$PID_B"; tB_end=$(date +%s%N)
wait
check "S7 A, B and C all finished successfully (OK printed, no error)" \
  "select $(grep -q '^OK$' "$WORK/hold.out" && grep -q '^OK$' "$WORK/b.out" && grep -q '^OK$' "$WORK/c.out" && ! grep -qi 'error' "$WORK/hold.out" "$WORK/b.out" "$WORK/c.out" && echo true || echo false)"
unit_check "S7 product 8" "$(pid 8)" "" 10 2 12
unit_check "S7 product 9" "$(pid 9)" "" 10 1 11
none_stuck S7

echo "== S8 CONTROL: unlocked read-modify-write in the same harness MUST lose updates =="
sql "insert into public.products (id, slug, name, sku, price_cents, stock_quantity, in_stock, is_active)
     values ('00000000-0000-4000-8000-6fc0000000a0','cx6c2-ctl','CX6C2 control','CX6C2-CTL',100,0,true,true)
     on conflict (id) do update set stock_quantity = 0, in_stock = true, is_active = true" >/dev/null
cat > "$WORK/naive.sql" <<'SQL'
begin;
select pg_advisory_xact_lock_shared(:barrier);
select stock_quantity as s from public.products where id = '00000000-0000-4000-8000-6fc0000000a0' \gset r_
select pg_sleep(0.3);
update public.products set stock_quantity = :r_s + 1 where id = '00000000-0000-4000-8000-6fc0000000a0';
commit;
\echo OK
SQL
barrier_hold
for i in $(seq 1 $N); do PGAPPNAME=cx6c2_worker "${PSQL[@]}" -v barrier="$BARRIER_KEY" -f "$WORK/naive.sql" >"$WORK/ctl.$i.out" 2>&1 & done
barrier_release "$N"; wait
ctl="$(sql "select stock_quantity from public.products where id='00000000-0000-4000-8000-6fc0000000a0'")"
if (( ctl >= N )); then
  echo "INCONCLUSIVE: the unlocked control lost no update (final $ctl of $N): the harness did not interleave, so S1-S7 prove nothing."; exit 2
fi
echo "PASS: S8 control lost updates as expected (final $ctl, would be $N without the race) - the harness does interleave, so S1-S7 are meaningful"

echo "== S9 history API + list/get agree with the committed, concurrently-written data =="
for u in 1 3; do
  # Expected values are read with the connecting (owner) role: 'authenticated' has no SELECT on inventory_adjustments.
  exp_cnt="$(sql "select count(*) from public.inventory_adjustments a where a.product_id='$(pid $u)'")"
  exp_p="$(sql "select stock_quantity from public.products where id='$(pid $u)'")"
  exp_v="$(sql "select stock_quantity from public.product_variants where id='$(vid $u)'")"
  out="$("${PSQL[@]}" -At 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', json_build_object('sub','$ADMIN','role','authenticated')::text, true);
select set_config('request.jwt.claim.sub','$ADMIN',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select (public.admin_list_inventory_adjustments(p_limit=>100, p_product_id=>'$(pid $u)')->>'total')::int = $exp_cnt
   and (public.admin_get_inventory('$(pid $u)')->'inventory'->>'stock_quantity')::int = $exp_p
   and (public.admin_get_inventory('$(pid $u)','$(vid $u)')->'inventory'->>'stock_quantity')::int = $exp_v
   and (select (e->>'stock_quantity')::int
        from jsonb_array_elements(public.admin_list_inventory(p_limit=>100, p_product_id=>'$(pid $u)')->'inventory') e
        where e->>'kind'='product') = $exp_p;
rollback;
SQL
)"
  chk="$(grep -E '^(t|f)$' <<<"$out" | tail -1)"
  if [[ "$chk" == "t" ]]; then PASS=$((PASS+1)); echo "PASS: S9 scenario $u: admin_list_inventory_adjustments total / admin_get_inventory / admin_list_inventory agree with the stored data"
  else FAIL=$((FAIL+1)); echo "FAIL: S9 scenario $u (got: $chk)"; echo "--- psql output ---"; echo "$out"; echo "STOP: report, do not patch."; exit 1; fi
done

echo
echo "TRUE CONCURRENCY TESTED: $N independent sessions per group, barrier-released, committed rows, locking behavior verified, control lost updates."
echo "RESULT: $PASS checks passed, $FAIL failed"
exit 0
