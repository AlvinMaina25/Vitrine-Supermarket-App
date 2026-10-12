import type { OrderStatus, PaymentStatus } from "../../lib/supabase/types.ts";
import type { MyOrderPayment, MyOrderPayments } from "./payment-read-result.ts";
import type { StartPaymentResult } from "./start-payment.ts";

/**
 * Phase 6K: pure decision logic for the card payment UI. No React, no network, no storage.
 *
 * "Paid" is derived ONLY from database state (get_my_order_payments, read through
 * getMyOrderPaymentStatusFn). The redirect back from the card provider is never proof of payment:
 * it only means "check the status again".
 */

export const POLL_INTERVAL_MS = 3_000;
export const POLL_MAX_MS = 90_000;

export const CARD_CONTACT_LINE =
  "If you were charged but this still shows unpaid, contact us with your order number.";

export const START_FALLBACK_MESSAGE = "The payment could not be started.";
export const BAD_REDIRECT_MESSAGE =
  "We couldn't open the payment page. Please try again.";

/** The parts of an order this decision needs. */
export interface CardOrderFacts {
  payment_method: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
}

export type CardPanelState =
  /** Not a card order: show nothing. */
  | { kind: "not_card" }
  /** Payment can no longer be taken (cancelled or refunded order): no button. */
  | { kind: "closed" }
  /** The database has a succeeded card attempt. */
  | { kind: "paid" }
  /** The latest attempt is pending or processing: keep polling, never call it failed. */
  | { kind: "in_progress"; status: "pending" | "processing" }
  /** The latest attempt ended without payment: offer to pay again. */
  | { kind: "retry"; reason: "failed" | "cancelled" | "expired" }
  /** No card attempt yet: offer to pay. */
  | { kind: "start" };

function latestCardAttempt(payments: MyOrderPayments): MyOrderPayment | null {
  let latest: MyOrderPayment | null = null;
  for (const txn of payments.transactions) {
    if (txn.method !== "card") continue;
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

export function isCardOrder(
  order: Pick<CardOrderFacts, "payment_method">,
): boolean {
  return order.payment_method === "card";
}

/** `payments` comes from the database read; the caller shows a loading state until it exists. */
export function deriveCardPanelState(
  order: CardOrderFacts,
  payments: MyOrderPayments,
): CardPanelState {
  if (!isCardOrder(order)) return { kind: "not_card" };

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
    payments.transactions.some(
      (txn) => txn.method === "card" && txn.status === "succeeded",
    )
  ) {
    return { kind: "paid" };
  }

  const latest = latestCardAttempt(payments);
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

/** Milliseconds until the next status read, or false to stop polling. */
export function nextPollInterval(
  state: CardPanelState | null,
  elapsedMs: number,
): number | false {
  if (state === null || state.kind !== "in_progress") return false;
  return elapsedMs < POLL_MAX_MS ? POLL_INTERVAL_MS : false;
}

export function pollTimeRemaining(elapsedMs: number): number {
  return Math.max(0, POLL_MAX_MS - elapsedMs);
}

export interface CardPanelCopy {
  title: string;
  message: string;
  /** Label of the pay button, or null when there is no button. */
  action: string | null;
}

export function cardPanelCopy(
  state: CardPanelState,
  timedOut: boolean,
): CardPanelCopy | null {
  switch (state.kind) {
    case "not_card":
      return null;
    case "closed":
      return {
        title: "Card payment unavailable",
        message: "This order can no longer be paid for by card.",
        action: null,
      };
    case "paid":
      return {
        title: "Payment received",
        message: "Your card payment has been confirmed.",
        action: null,
      };
    case "in_progress":
      return timedOut
        ? {
            title: "Still waiting for confirmation",
            message:
              "We haven't received confirmation yet. Please refresh in a moment; this can take a little while.",
            action: null,
          }
        : {
            title: "Confirming your payment",
            message:
              "We're waiting for your card payment to be confirmed. This page updates by itself.",
            action: null,
          };
    case "retry": {
      const what =
        state.reason === "failed"
          ? "Your card payment didn't go through."
          : state.reason === "cancelled"
            ? "Your card payment was cancelled."
            : "Your card payment session expired.";
      return {
        title: "Payment not completed",
        message: `${what} Your order is still waiting for payment.`,
        action: "Pay by card",
      };
    }
    case "start":
      return {
        title: "Payment needed",
        message: "Your order is waiting for payment.",
        action: "Pay by card",
      };
  }
}

// ---------------------------------------------------------------- starting a payment

/** The URL only if it is a well-formed https URL; otherwise null. */
export function safeHttpsUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname !== ""
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

export type StartOutcome =
  /** Go to the hosted payment page. */
  | { type: "redirect"; url: string }
  /** An attempt exists and is moving: show the status page and poll; no second charge attempt. */
  | { type: "in_progress" }
  /** Anything else: go to the status page and let the database state decide what is shown. */
  | { type: "none" }
  | { type: "error"; message: string };

export function interpretStartResult(result: StartPaymentResult): StartOutcome {
  if (result.kind === "already_in_progress") return { type: "in_progress" };
  if (result.kind === "initiated" && result.next.type === "redirect") {
    const url = safeHttpsUrl(result.next.redirectUrl);
    return url === null
      ? { type: "error", message: BAD_REDIRECT_MESSAGE }
      : { type: "redirect", url };
  }
  return { type: "none" };
}

/** The server's client-safe message when there is one; otherwise a fixed fallback. */
export function startErrorMessage(error: unknown): string {
  return error instanceof Error && error.message.trim() !== ""
    ? error.message
    : START_FALLBACK_MESSAGE;
}

// ---------------------------------------------------------------- hand-off to the status page

const notices = new Map<string, string>();

/** Remembers why starting the payment failed so the order page can show it once. In memory only. */
export function rememberStartNotice(orderId: string, message: string): void {
  notices.set(orderId, message);
}

export function peekStartNotice(orderId: string): string | null {
  return notices.get(orderId) ?? null;
}

export function clearStartNotice(orderId: string): void {
  notices.delete(orderId);
}
