#!/usr/bin/env bash
# =============================================================================
# Shared cleanup helpers for the committing concurrency scripts in db/tests/*.sh
# (create_order_concurrency, phase8_coupon_concurrency, phase6c2_inventory_concurrency_final).
# SOURCE it; do not run it. The caller defines PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1).
#
# WHY THIS EXISTS (Phase 9B)
#   public.inventory_adjustments is APPEND-ONLY and its foreign keys to products / product_variants
#   are RESTRICT. Any fixture product whose stock moved while the script ran (create_order() deducts
#   stock, admin_adjust_inventory() adjusts it) now has ledger rows that can never be deleted, so the
#   product cannot be deleted either. The old cleanup ran every DELETE in ONE psql session with
#   ON_ERROR_STOP and threw the output away, so the first refused DELETE silently skipped everything
#   after it: fixtures were left behind and the next run failed on a duplicate key.
#
# WHAT THE SCRIPTS DO NOW
#   * Every cleanup step is its own psql call; a failing step is REPORTED (CLEANUP FAILED: ...) and
#     the remaining steps still run. Nothing is hidden behind `|| true` or /dev/null.
#   * A fixture product / variant the ledger references is RETAINED: deactivated, never deleted,
#     and the setup of the next run re-uses it (INSERT ... ON CONFLICT (id) DO UPDATE). So repeated
#     runs leave the SAME few inert rows behind, not new ones. Everything else is deleted.
#   * The ledger itself is never touched: no DELETE, no TRUNCATE, no trigger disabled, no
#     session_replication_role. Deleting the fixture auth user is allowed by the guard
#     (changed_by -> NULL is the one permitted change).
#   * If any step fails, the script exits non-zero even when every check passed.
# =============================================================================

CLEANUP_FAILED=0

# cleanup_step "<what it removes>" "<sql>"   one psql call; failure is reported, never swallowed.
cleanup_step() {
  local what="$1" sql="$2" out
  if out="$("${PSQL[@]}" -c "$sql" 2>&1)"; then
    # NOTICEs (for example "RETAINED ...") are the cleanup's own report: show them.
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/   cleanup: /' >&2
  else
    CLEANUP_FAILED=1
    { echo "CLEANUP FAILED: ${what}"; printf '%s\n' "$out" | sed 's/^/    /'; } >&2
  fi
}

# cleanup_expect_none "<what>" "<sql returning a number of leftover rows>"
cleanup_expect_none() {
  local what="$1" sql="$2" n
  if ! n="$("${PSQL[@]}" -At -c "$sql" 2>&1)" || [ "$n" != "0" ]; then
    CLEANUP_FAILED=1
    echo "CLEANUP FAILED: ${what} still present after cleanup (${n})" >&2
  fi
}

# finish_cleanup <exit status of the script body>: call at the end of the EXIT trap. A cleanup that
# did not finish turns a passing run into a failing one (exit 1); a failing run keeps its own code.
finish_cleanup() {
  local rc="$1"
  if [ "$CLEANUP_FAILED" -ne 0 ]; then
    echo "FAIL: cleanup did not complete; fixtures may be left behind (see CLEANUP FAILED above)." >&2
    [ "$rc" -eq 0 ] && rc=1
  fi
  return "$rc"
}
