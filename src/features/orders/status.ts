import type {
  OrderStatus,
  PaymentMethod,
  PaymentStatus,
} from "@/lib/supabase/types";

/**
 * Presentation metadata for the two independent lifecycles. Nothing here
 * infers one from the other: an order is only "paid" when the database says
 * payment_status = 'paid'.
 */

export type StatusTone =
  "neutral" | "progress" | "success" | "warning" | "danger";

export const ORDER_STATUS_LABELS: Record<OrderStatus, string> = {
  pending: "Order placed",
  awaiting_payment: "Waiting for payment",
  paid: "Payment confirmed",
  processing: "Processing",
  picking: "Picking",
  packed: "Packed",
  dispatched: "Dispatched",
  out_for_delivery: "Out for delivery",
  delivered: "Delivered",
  cancelled: "Cancelled",
  refunded: "Refunded",
};

export const ORDER_STATUS_TONES: Record<OrderStatus, StatusTone> = {
  pending: "neutral",
  awaiting_payment: "warning",
  paid: "success",
  processing: "progress",
  picking: "progress",
  packed: "progress",
  dispatched: "progress",
  out_for_delivery: "progress",
  delivered: "success",
  cancelled: "danger",
  refunded: "danger",
};

export const PAYMENT_STATUS_LABELS: Record<PaymentStatus, string> = {
  pending: "Payment pending",
  processing: "Payment processing",
  paid: "Paid",
  failed: "Payment failed",
  cancelled: "Payment cancelled",
  refunded: "Refunded",
  partially_refunded: "Partially refunded",
};

export const PAYMENT_STATUS_TONES: Record<PaymentStatus, StatusTone> = {
  pending: "warning",
  processing: "progress",
  paid: "success",
  failed: "danger",
  cancelled: "danger",
  refunded: "neutral",
  partially_refunded: "neutral",
};

export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  mpesa: "M-Pesa",
  card: "Debit / credit card",
  cash_on_delivery: "Cash on delivery",
};

/** The happy-path fulfilment sequence, used to render the timeline. */
export const FULFILMENT_SEQUENCE: OrderStatus[] = [
  "pending",
  "awaiting_payment",
  "paid",
  "processing",
  "picking",
  "packed",
  "dispatched",
  "out_for_delivery",
  "delivered",
];

export const TERMINAL_STATUSES: OrderStatus[] = [
  "delivered",
  "cancelled",
  "refunded",
];

export function isOrderOpen(status: OrderStatus): boolean {
  return !TERMINAL_STATUSES.includes(status);
}
