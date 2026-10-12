#!/usr/bin/env bash
# =============================================================================
# PHASE 6M - run EVERY db/tests/*.test.sql against a Supabase/Postgres DEV database, in migration
# order, and print one pass/fail table. Needs `psql`. Each test file rolls itself back, so it leaves
# nothing behind. Run it AFTER all migrations are applied (through 20261005150000).
#
#   DATABASE_URL='postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres' \
#     scripts/integration/run-sql-tests.sh [--with-concurrency]
#
# --with-concurrency also runs the three db/tests/*_concurrency*.sh scripts. They COMMIT real
# rows (and clean up after themselves), so use a dev database only.
#
# Exit code: 0 = every file passed, 1 = at least one failed.
# =============================================================================
set -uo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to the DEV database connection string}"
command -v psql >/dev/null || { echo "psql not found on PATH" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Migration order. A file missing from this list is reported, not silently skipped.
ORDER=(
  create_order_delivery delivery_validation delivery_slot_validation order_reactivation_capacity
  phase5b2_security_authorization_hardening
  phase6a_admin_operations_foundation phase6b1_admin_orders_backend phase6b2_admin_order_actions
  phase6c1a1_admin_product_read_foundation phase6c1a2_admin_product_search_details
  phase6c1b1_admin_product_create_update phase6c1b2_admin_product_activation_variants
  phase6c2_inventory_read_foundation phase6c2_inventory_adjustment_history
  phase6c2_admin_inventory_adjustment phase6c2_inventory_history_api phase6c2_inventory_concurrency_final
  customer_list customer_detail customer_status customer_notes customer_status_notes_read
  phase6e3_customer_hardening
  phase6f1a_delivery_admin_methods_zones phase6f1b_delivery_admin_slots phase6f4_delivery_lockdown
  phase6g1_payment_ledger phase6g2_payment_attempts phase6g3_payment_outcome
  phase6g4a_payment_read_functions phase6g4b_payment_read_lockdown
  phase6i1_audit_log_foundation phase6i2_audit_gap_writers phase6i3_audit_log_retention
  phase6l1_admin_mfa phase6l2_admin_role_management
  phase8_discounts_promotions phase8_validate_coupon_total
  phase9a_catalog_integrity phase9b_inventory_movements phase9c_inventory_history_movement_labels
  phase20a_admin_categories phase20b_catalog_images
)

pass=0; fail=0; rows=()
declare -A seen

run_one () {
  local name="$1" file="db/tests/$1.test.sql"
  if [[ ! -f "$file" ]]; then
    rows+=("MISSING  $name (listed here but not in db/tests/)"); fail=$((fail+1)); return
  fi
  seen["$name"]=1
  local out rc npass
  out="$(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$file" 2>&1)"; rc=$?
  npass=$(printf '%s\n' "$out" | grep -c 'PASS')
  if [[ $rc -eq 0 ]] && ! printf '%s\n' "$out" | grep -q 'FAIL'; then
    rows+=("PASS     $name  ($npass PASS lines)"); pass=$((pass+1))
  else
    rows+=("FAIL     $name  (psql exit $rc)")
    fail=$((fail+1))
    printf '\n----- %s -----\n%s\n' "$file" "$(printf '%s\n' "$out" | grep -E 'FAIL|ERROR|DETAIL|CONTEXT' | head -12)" >&2
  fi
}

for name in "${ORDER[@]}"; do run_one "$name"; done

# Any test file that is not in ORDER still runs (so new tests are never skipped).
for f in db/tests/*.test.sql; do
  n="$(basename "$f" .test.sql)"
  [[ -n "${seen[$n]:-}" ]] || { rows+=("NOTE     $n was not in the ordered list; running it now"); run_one "$n"; }
done

if [[ "${1:-}" == "--with-concurrency" ]]; then
  for s in create_order_concurrency delivery_slot_concurrency order_reactivation_concurrency phase6c2_inventory_concurrency_final phase8_coupon_concurrency; do
    if [[ -f "db/tests/$s.sh" ]]; then
      if bash "db/tests/$s.sh" >/tmp/it-$s.log 2>&1; then rows+=("PASS     $s.sh"); pass=$((pass+1))
      else rows+=("FAIL     $s.sh (see /tmp/it-$s.log)"); fail=$((fail+1)); fi
    fi
  done
fi

printf '\n== SQL test files\n'
printf '%s\n' "${rows[@]}"
printf '\nTOTAL: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
