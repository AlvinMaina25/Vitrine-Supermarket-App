import type {
  OrderStatus,
  OrderStatusHistoryRow,
  PaymentStatus,
} from "../../lib/supabase/types.ts";

/**
 * Phase 14: the customer-facing order timeline.
 *
 * A pure re-wording of the order's own recorded history (order_status_history). It does not
 * decide, infer or add a status: every entry is one stored row, in stored order, with the
 * stored timestamp. There are no "upcoming" steps, no estimated times, no rider or location.
 *
 * - "cancelled" and "refunded" are END states, not steps in a sequence (kind "end").
 * - A row where the order status did not move but the payment status did is a PAYMENT entry;
 *   order status and payment status stay two separate things.
 */

export interface StatusWording {
  title: string;
  description: string;
}

/** Plain customer wording per order status. Makes no promise about timing. */
export const CUSTOMER_ORDER_STATUS_WORDING: Record<OrderStatus, StatusWording> =
  {
    pending: {
      title: "Order placed",
      description: "We've received your order.",
    },
    awaiting_payment: {
      title: "Waiting for payment",
      description: "The order is waiting for your payment to be confirmed.",
    },
    paid: {
      title: "Payment confirmed",
      description: "We've confirmed your payment.",
    },
    processing: {
      title: "Being prepared",
      description: "We're getting your order ready.",
    },
    picking: {
      title: "Picking your items",
      description: "Our team is collecting your items.",
    },
    packed: {
      title: "Packed",
      description: "Your items are packed and ready for delivery.",
    },
    dispatched: {
      title: "Dispatched",
      description: "Your order has left the store.",
    },
    out_for_delivery: {
      title: "Out for delivery",
      description: "Your order is on its way to you.",
    },
    delivered: {
      title: "Delivered",
      description: "The order is marked as delivered.",
    },
    cancelled: { title: "Cancelled", description: "This order was cancelled." },
    refunded: { title: "Refunded", description: "This order was refunded." },
  };

/** Plain customer wording per payment status (shown on payment-change rows). */
export const CUSTOMER_PAYMENT_STATUS_WORDING: Record<
  PaymentStatus,
  StatusWording
> = {
  pending: {
    title: "Payment pending",
    description: "We haven't received your payment yet.",
  },
  processing: {
    title: "Payment being processed",
    description: "Your payment is being processed.",
  },
  paid: {
    title: "Payment received",
    description: "Your payment is confirmed.",
  },
  failed: {
    title: "Payment didn't go through",
    description: "The payment was not completed.",
  },
  cancelled: {
    title: "Payment cancelled",
    description: "The payment was cancelled.",
  },
  refunded: {
    title: "Payment refunded",
    description: "The payment was refunded.",
  },
  partially_refunded: {
    title: "Payment partly refunded",
    description: "Part of the payment was refunded.",
  },
};

/** Order statuses that end the order's journey. Shown as end states, never as steps. */
export const END_STATES: readonly OrderStatus[] = ["cancelled", "refunded"];

export type TimelineEntryKind = "status" | "payment" | "end";

export interface TimelineEntry {
  id: string;
  kind: TimelineEntryKind;
  title: string;
  description: string;
  /** The stored created_at of the history row, untouched (ISO). */
  at: string;
  /** A recorded note worth showing; null when absent or when it only repeats the status. */
  note: string | null;
  isLatest: boolean;
}

/** The database writes "Payment status updated to <enum value>"; the entry already says it. */
function visibleNote(note: string | null): string | null {
  if (!note) return null;
  const trimmed = note.trim();
  if (trimmed === "") return null;
  if (trimmed.startsWith("Payment status updated to ")) return null;
  return trimmed;
}

/** True when the row records a payment-status change rather than an order-status change. */
export function isPaymentChangeRow(row: OrderStatusHistoryRow): boolean {
  return row.previous_status === row.new_status && row.payment_status !== null;
}

/**
 * Maps recorded history rows to timeline entries, oldest first. The input order is kept (the
 * query already orders by created_at); a copy is sorted only to be safe against an unordered
 * caller, with the row id as a stable tie-break.
 */
export function buildTimeline(
  history: readonly OrderStatusHistoryRow[],
): TimelineEntry[] {
  const rows = [...history].sort((a, b) => {
    if (a.created_at < b.created_at) return -1;
    if (a.created_at > b.created_at) return 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  return rows.map((row, index): TimelineEntry => {
    const isLatest = index === rows.length - 1;
    const note = visibleNote(row.note);

    if (isPaymentChangeRow(row) && row.payment_status) {
      const wording = CUSTOMER_PAYMENT_STATUS_WORDING[row.payment_status];
      return {
        id: row.id,
        kind: "payment",
        ...wording,
        at: row.created_at,
        note,
        isLatest,
      };
    }

    const wording = CUSTOMER_ORDER_STATUS_WORDING[row.new_status];
    return {
      id: row.id,
      kind: END_STATES.includes(row.new_status) ? "end" : "status",
      ...wording,
      at: row.created_at,
      note,
      isLatest,
    };
  });
}
