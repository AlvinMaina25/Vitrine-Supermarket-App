import { isNetworkFailure } from "../../components/states/error-kind.ts";
import type {
  OrderStatus,
  PaymentMethod,
  PaymentStatus,
} from "../../lib/supabase/types.ts";

/**
 * Phase 19: pure helpers for the admin "Record cash payment" action. No runtime imports from the
 * app, so they run under `node --test` as well as in the browser.
 *
 * Nothing here decides whether cash may be recorded. The database function record_cod_payment()
 * does that and its answer is final; these helpers only choose when to OFFER the button and the
 * words for each outcome.
 */

/** The database accepts a reason of 3-400 characters (after trimming). */
export const COD_REASON_MIN_LENGTH = 3;
export const COD_REASON_MAX_LENGTH = 400;

export const COD_ALREADY_RECORDED_MESSAGE = "Already recorded. Nothing changed.";

/**
 * When the button is offered. Deliberately stricter than the database, which also accepts
 * out_for_delivery: here the order must be delivered, cash on delivery, not cancelled or
 * refunded, and its payment must not already be paid or (partly) refunded.
 */
export function canRecordCodPayment(order: {
  payment_method: PaymentMethod;
  status: OrderStatus;
  payment_status: PaymentStatus;
}): boolean {
  return (
    order.payment_method === "cash_on_delivery" &&
    order.status === "delivered" &&
    order.payment_status !== "paid" &&
    order.payment_status !== "partially_refunded" &&
    order.payment_status !== "refunded"
  );
}

/** A problem with the typed reason in plain words, or null when it is acceptable. */
export function validateCodReason(raw: string): string | null {
  // Code points, like the database's char_length().
  const length = [...raw.trim()].length;
  if (length === 0) return "Enter a reason for recording this payment.";
  if (length < COD_REASON_MIN_LENGTH) {
    return `Use at least ${COD_REASON_MIN_LENGTH} characters.`;
  }
  if (length > COD_REASON_MAX_LENGTH) {
    return `Use ${COD_REASON_MAX_LENGTH} characters or fewer.`;
  }
  return null;
}

/** Why the server function refused. Each is something the person can understand and act on. */
export type CodRefusalReason =
  | "mfa_required"
  | "not_permitted"
  | "order_not_found"
  | "not_cod_order"
  | "not_delivered_yet"
  | "already_paid"
  | "order_not_payable"
  | "amount_invalid"
  | "invalid_request";

const COD_REFUSAL_MESSAGES: Record<CodRefusalReason, string> = {
  mfa_required: "Complete two-factor sign-in, then try again.",
  not_permitted: "You do not have permission to record cash payments.",
  order_not_found: "That order could not be found.",
  not_cod_order: "This is not a cash on delivery order.",
  not_delivered_yet: "This order has not been delivered yet.",
  already_paid: "This order is already paid.",
  order_not_payable:
    "This order was cancelled or refunded, so cash cannot be recorded.",
  amount_invalid: "This order has no payable amount.",
  invalid_request: `Check the reason (${COD_REASON_MIN_LENGTH} to ${COD_REASON_MAX_LENGTH} characters) and try again.`,
};

export function describeCodRefusal(reason: CodRefusalReason): string {
  return COD_REFUSAL_MESSAGES[reason];
}

/** For a call that failed outright (no answer from the server). Never a raw error message. */
export function describeCodRecordFailure(
  error: unknown,
  online: boolean | undefined,
): string {
  return isNetworkFailure(error, online)
    ? "We couldn't reach the shop. Check your connection and try again."
    : "We couldn't record the payment. Please try again.";
}
