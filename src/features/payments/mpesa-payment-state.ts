import type { OrderStatus, PaymentStatus } from "../../lib/supabase/types.ts";
import {
  POLL_INTERVAL_MS,
  POLL_MAX_MS,
  pollTimeRemaining,
  startErrorMessage,
} from "./card-payment-state.ts";
import type { MyOrderPayment, MyOrderPayments } from "./payment-read-result.ts";
import type { StartPaymentResult } from "./start-payment.ts";

/**
 * Phase 13: pure decision logic and wording for the M-Pesa payment panel. No React, no network.
 *
 * "Paid" is derived ONLY from what the server reports: a succeeded attempt in
 * get_my_order_payments, or the order's own payment_status. Starting a payment sends a phone
 * number, never an amount (the amount comes from the database). The customer is never shown a
 * failure code: the server does not give one to the browser, and nothing here guesses a reason.
 */

export { POLL_INTERVAL_MS, POLL_MAX_MS, pollTimeRemaining, startErrorMessage };

export const MPESA_CONTACT_LINE =
  "If M-Pesa took your money but this still shows unpaid, contact us with your order number.";

export interface MpesaOrderFacts {
  payment_method: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
}

export type MpesaPanelState =
  | { kind: "not_mpesa" }
  /** Cancelled or refunded: payment can no longer be taken. */
  | { kind: "closed" }
  | { kind: "paid" }
  /** The latest attempt is pending or processing: keep reading the status, never call it failed. */
  | { kind: "in_progress"; status: "pending" | "processing" }
  | { kind: "retry"; reason: "failed" | "cancelled" | "expired" }
  | { kind: "start" };

export function isMpesaOrder(order: Pick<MpesaOrderFacts, "payment_method">) {
  return order.payment_method === "mpesa";
}

function latestMpesaAttempt(payments: MyOrderPayments): MyOrderPayment | null {
  let latest: MyOrderPayment | null = null;
  for (const txn of payments.transactions) {
    if (txn.method !== "mpesa") continue;
    if (
      latest === null ||
      txn.created_at > latest.created_at ||
      (txn.created_at === latest.created_at && txn.id > latest.id)
    ) {
      latest = txn;
    }
  }
  return latest;
}

export function deriveMpesaPanelState(
  order: MpesaOrderFacts,
  payments: MyOrderPayments,
): MpesaPanelState {
  if (!isMpesaOrder(order)) return { kind: "not_mpesa" };

  if (
    order.status === "cancelled" ||
    order.status === "refunded" ||
    order.payment_status === "refunded" ||
    order.payment_status === "partially_refunded" ||
    order.payment_status === "cancelled"
  ) {
    return { kind: "closed" };
  }

  if (
    order.payment_status === "paid" ||
    payments.transactions.some(
      (txn) => txn.method === "mpesa" && txn.status === "succeeded",
    )
  ) {
    return { kind: "paid" };
  }

  const latest = latestMpesaAttempt(payments);
  if (latest === null) return { kind: "start" };

  switch (latest.status) {
    case "pending":
    case "processing":
      return { kind: "in_progress", status: latest.status };
    case "failed":
    case "cancelled":
    case "expired":
      return { kind: "retry", reason: latest.status };
    case "succeeded":
      return { kind: "paid" };
  }
}

/** Milliseconds until the next status read, or false to stop. */
export function mpesaNextPollInterval(
  state: MpesaPanelState | null,
  elapsedMs: number,
): number | false {
  if (state === null || state.kind !== "in_progress") return false;
  return elapsedMs < POLL_MAX_MS ? POLL_INTERVAL_MS : false;
}

/** "1:30", "0:07": the visible countdown while waiting. */
export function formatCountdown(remainingMs: number): string {
  const seconds = Math.ceil(Math.max(0, remainingMs) / 1000);
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes}:${rest.toString().padStart(2, "0")}`;
}

export interface MpesaPanelCopy {
  title: string;
  message: string;
  /** Label of the main button, or null when there is none. */
  action: string | null;
  /** True when the phone number box belongs with the button. */
  needsPhone: boolean;
}

export function mpesaPanelCopy(
  state: MpesaPanelState,
  timedOut: boolean,
): MpesaPanelCopy | null {
  switch (state.kind) {
    case "not_mpesa":
      return null;
    case "closed":
      return {
        title: "M-Pesa payment unavailable",
        message: "This order can no longer be paid for with M-Pesa.",
        action: null,
        needsPhone: false,
      };
    case "paid":
      return {
        title: "Payment received",
        message: "Your M-Pesa payment has been confirmed.",
        action: null,
        needsPhone: false,
      };
    case "in_progress":
      return timedOut
        ? {
            title: "Still waiting for confirmation",
            message:
              "We haven't had confirmation yet. If you entered your M-PESA PIN, it can take a little while to arrive: check again in a moment. We won't send a second prompt while this one is still open.",
            action: null,
            needsPhone: false,
          }
        : {
            title: "Check your phone",
            message:
              "An M-PESA prompt has been sent to your phone. Enter your M-PESA PIN to pay. This page updates by itself.",
            action: null,
            needsPhone: false,
          };
    case "retry": {
      const what =
        state.reason === "failed"
          ? "The M-Pesa payment didn't go through."
          : state.reason === "cancelled"
            ? "The M-Pesa request was cancelled."
            : "The M-Pesa request timed out before it was approved.";
      return {
        title: "Payment not completed",
        message: `${what} Your order is still waiting for payment.`,
        action: "Try again",
        needsPhone: true,
      };
    }
    case "start":
      return {
        title: "Pay with M-Pesa",
        message:
          "Enter the Safaricom number to send the M-PESA prompt to. You'll enter your M-PESA PIN on that phone.",
        action: "Send M-Pesa prompt",
        needsPhone: true,
      };
  }
}

// ---------------------------------------------------------------- phone entry

export const PHONE_REQUIRED_MESSAGE =
  "Enter the Safaricom number to send the prompt to.";
export const PHONE_INVALID_MESSAGE =
  "Enter a valid Safaricom number, like 0712345678 or 254712345678.";

export type PhoneCheck = { ok: true } | { ok: false; message: string };

/**
 * A format hint for the input box only. The server checks the number again and decides; this just
 * saves a round trip. Same shapes the server accepts: 07/01 local, 254 or +254, then 8 digits.
 */
export function checkMpesaPhone(input: string): PhoneCheck {
  const compact = input.replace(/[\s-]/g, "");
  if (compact === "") return { ok: false, message: PHONE_REQUIRED_MESSAGE };
  const hasPlus = compact.startsWith("+");
  const digits = hasPlus ? compact.slice(1) : compact;
  if (!/^\d+$/.test(digits))
    return { ok: false, message: PHONE_INVALID_MESSAGE };
  let international: string;
  if (digits.startsWith("254")) international = digits;
  else if (!hasPlus && digits.startsWith("0"))
    international = `254${digits.slice(1)}`;
  else return { ok: false, message: PHONE_INVALID_MESSAGE };
  return /^254[71]\d{8}$/.test(international)
    ? { ok: true }
    : { ok: false, message: PHONE_INVALID_MESSAGE };
}

// ---------------------------------------------------------------- starting

export type MpesaStartOutcome =
  /** A prompt was sent, or one is already open: read the status and wait. */
  { type: "waiting" } | { type: "error"; message: string };

export function interpretMpesaStart(
  result: StartPaymentResult,
): MpesaStartOutcome {
  if (result.kind === "initiated" && result.next.type === "redirect") {
    // M-Pesa never redirects. Treat it as a failure to start rather than follow a URL.
    return {
      type: "error",
      message: "That payment method cannot be started this way.",
    };
  }
  if (result.kind === "cod_recorded") {
    return {
      type: "error",
      message: "That payment method cannot be started this way.",
    };
  }
  return { type: "waiting" };
}
