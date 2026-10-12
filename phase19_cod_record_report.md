# Phase 19 — record cash payment for COD orders (branch `phase-19-cod-record`)

**Code-reviewed only, plus node-run unit tests.** `npm ci` failed (registry unreachable), so project `tsc`, `eslint`, `prettier`, `vite build` and a browser were NOT run. No SQL was executed; I only read it.

## What 1a and 1b found
- **1a (read from `20261005060000_phase6g3…sql`, the only definition):** `record_cod_payment(order_id, reason)` is granted to `authenticated` and calls `require_admin()` (admin plus MFA). It needs a cash-on-delivery order, status `out_for_delivery` or `delivered`, payment not `paid`, `partially_refunded` or `refunded`, total above 0, and a reason of 3-400 characters. It inserts a succeeded `cod` transaction, sets `payment_status = paid`, writes `admin_audit_log` (`cod_payment_recorded`) and returns `{changed, transaction}`; a repeat returns `changed: false`.
- **1b:** `startPaymentFn` takes `{orderId, method, phone?}` and sends the fixed reason "Cash collected on delivery", so an admin reason could not be sent. Decision (owner): add one new server function and leave shared payment logic alone.

## What changed
- `src/features/admin/cod-payment.ts` (new, pure): visibility rule, reason validator, plain-words messages.
- `src/features/payments/record-cod-payment.ts` (new, pure): input validator (2 fields only), own error mapping (`mfa_required` is distinct), use case.
- `src/features/payments/payment-server.ts`: appended `recordCodPaymentFn` (user client only, no service role); nothing existing edited.
- `src/components/admin/record-cod-payment.tsx` (new): button and confirm dialog.
- `src/routes/_authenticated/admin/orders.$orderId.tsx`: import plus one conditional "Cash on delivery" card.
- `tests/cod-payment.test.ts`, `tests/record-cod-payment.test.ts` (new, 24 tests).
- Also: commit "phase 18: apply tsc and prettier fixes" on `phase-18-final-audit` (owner's own fixes), branch taken from it.

## Behaviour
Button shows only for cash on delivery, status `delivered`, payment not paid/partially refunded/refunded (stricter than SQL on purpose). Refusals come back as a result, not a thrown error, because only `error.message` is relied on elsewhere across the server-function boundary. `changed: false` shows "Already recorded. Nothing changed." Success invalidates `["admin","order",id]` and `["admin","orders"]`.

## Checked vs not checked
- **Ran:** the 24 new tests pass; the whole suite passes (989 of 989) via `node --experimental-strip-types --test "tests/**/*.test.ts"` (the command behind `npm test`, run directly, not through npm). Global `tsc` 6.0.3, strict, on the two new pure files and what they import: no errors (my own config, not the project's).
- **Not run:** prettier (line breaks done by hand), eslint, project `tsc` on the `.tsx`, server and route files, `vite build`, any browser or database. The dialog, the server function and the real database answer are unverified.

## Needs follow-up
- Run `npm ci && npx prettier --write <changed files> && npx eslint . && npx tsc --noEmit && npm test`, then `phase19_manual_qa_checklist.md` against a dev database with an MFA admin.
- The dashboard query is not invalidated (spec said detail and list only); dashboard figures may lag until refetch.
- `out_for_delivery` cash is accepted by SQL but not offered here.
- `admin-states` was not reused: the dialog shows errors inline like `order-status-actions.tsx`.
- `zip-project.bat` and two mode-only db script changes are still uncommitted.
