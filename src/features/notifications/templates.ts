import type { Channel, EventType, OutboundMessage } from "./types.ts";

/**
 * Phase 7 template builder. Pure: the same input always gives the same text.
 *
 * Deliberately minimal. A message carries the order number and, for status updates, the order's
 * current status label. It carries NO name, address, amount, payment method, card or phone data,
 * and no link (there is no public base URL configured yet). Final copy is a content task (see
 * docs/NOTIFICATIONS.md); these strings are neutral placeholders.
 */

export interface TemplateContext {
  /** Human order number, e.g. "ORD-1042". Read by the worker at send time. */
  orderNumber: string;
  /** The order's current status code, only used by order_status_changed. */
  orderStatus: string | null;
}

const STATUS_LABELS: Readonly<Record<string, string>> = {
  pending: "received",
  awaiting_payment: "awaiting payment",
  paid: "paid",
  processing: "being processed",
  picking: "being picked",
  packed: "packed",
  dispatched: "dispatched",
  out_for_delivery: "out for delivery",
  delivered: "delivered",
  cancelled: "cancelled",
  refunded: "refunded",
};

/** Control characters out, length capped: an order number is never trusted to be tidy. */
function safeOrderNumber(value: string): string {
  return value
    .replace(/[^\p{L}\p{N}\-_/# ]/gu, "")
    .trim()
    .slice(0, 40);
}

function statusLabel(status: string | null): string {
  return (status !== null ? STATUS_LABELS[status] : undefined) ?? "updated";
}

function sentence(
  event: EventType,
  order: string,
  status: string | null,
): { subject: string; text: string } {
  switch (event) {
    case "order_created":
      return {
        subject: `We received your order ${order}`,
        text: `We received your order ${order}.`,
      };
    case "payment_succeeded":
      return {
        subject: `Payment received for order ${order}`,
        text: `We received your payment for order ${order}.`,
      };
    case "payment_failed":
      return {
        subject: `Payment problem with order ${order}`,
        text: `Your payment for order ${order} did not go through. You can try again from your account.`,
      };
    case "order_status_changed":
      return {
        subject: `Update on order ${order}`,
        text: `Your order ${order} is now ${statusLabel(status)}.`,
      };
    case "order_delivered":
      return {
        subject: `Order ${order} delivered`,
        text: `Your order ${order} has been delivered.`,
      };
    case "order_refunded":
      return {
        subject: `Order ${order} refunded`,
        text: `Your order ${order} has been refunded.`,
      };
  }
}

export function buildMessage(
  event: EventType,
  channel: Channel,
  context: TemplateContext,
  to: string,
): OutboundMessage {
  const order = safeOrderNumber(context.orderNumber);
  const { subject, text } = sentence(event, order, context.orderStatus);
  if (channel === "email") {
    return {
      to,
      subject,
      body: `Hello,\n\n${text}\n\nThank you for shopping with us.`,
    };
  }
  return { to, subject: null, body: text };
}
