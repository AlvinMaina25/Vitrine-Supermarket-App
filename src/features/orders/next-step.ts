import type { OrderStatus, PaymentStatus } from "../../lib/supabase/types.ts";

/**
 * Phase 13: the "what happens next" sentence on the confirmation page. A pure re-wording of the
 * order's own stored status and payment status; it does not decide either. It makes no promise
 * about timing or about what the shop does next, only what the customer can do and where to look.
 */
export function orderNextStep(order: {
  status: OrderStatus;
  payment_method: string;
  payment_status: PaymentStatus;
}): string {
  if (order.status === "cancelled") {
    return "This order was cancelled. If you think that's a mistake, contact us with your order number.";
  }
  if (
    order.status === "refunded" ||
    order.payment_status === "refunded" ||
    order.payment_status === "partially_refunded"
  ) {
    return "This order has been refunded. The details are in your orders.";
  }
  if (order.payment_status === "paid") {
    return "Your payment is confirmed. Follow the order's progress from your orders.";
  }
  if (order.payment_method === "cash_on_delivery") {
    return "Have the exact amount ready for the rider. Payment is recorded when the order is delivered.";
  }
  return "Your order is waiting for payment. Finish paying below; the payment status here updates once it is confirmed.";
}
