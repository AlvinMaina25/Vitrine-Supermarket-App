import type {
  AdminOrderListFilters,
  OrderStatus,
  PaymentMethod,
  PaymentStatus,
} from "../../lib/supabase/types.ts";
import { AdminAccessError } from "./dashboard-result.ts";
import {
  AdminOrderActionError,
  AdminOrderNotFoundError,
} from "./orders-result.ts";

/**
 * Pure helpers for the admin orders screens (Phase 6D-2). No runtime imports beyond the Phase
 * 6A/6B error classes, so they run under `node --test`.
 *
 * Nothing here decides authorisation or whether a status move is valid: the database does
 * (admin_list_orders / admin_get_order / admin_set_order_status -> set_order_status). The
 * transition table below only decides which buttons to OFFER, and mirrors the standard moves in
 * set_order_status(). If the two ever disagree the database wins and the UI shows its refusal.
 */

export const ORDERS_PAGE_SIZE = 25;

export const ORDER_STATUSES: readonly OrderStatus[] = [
  "pending",
  "awaiting_payment",
  "paid",
  "processing",
  "picking",
  "packed",
  "dispatched",
  "out_for_delivery",
  "delivered",
  "cancelled",
  "refunded",
];

export const PAYMENT_STATUSES: readonly PaymentStatus[] = [
  "pending",
  "processing",
  "paid",
  "failed",
  "cancelled",
  "refunded",
  "partially_refunded",
];

// ---------------------------------------------------------------------------
// List search params (the URL is the single source of truth for the list state)
// ---------------------------------------------------------------------------

export interface OrderListParams {
  q?: string;
  status?: OrderStatus;
  payment?: PaymentStatus;
  /** 1-based; omitted means page 1. */
  page?: number;
}

/** Same limit as the database (100 characters); longer input is trimmed, not refused. */
const MAX_SEARCH_LENGTH = 100;

/** Unknown or malformed values are dropped rather than sent to the database. */
export function parseOrderListParams(
  search: Record<string, unknown>,
): OrderListParams {
  const params: OrderListParams = {};

  const q = search["q"];
  if (typeof q === "string" && q.trim() !== "")
    params.q = q.trim().slice(0, MAX_SEARCH_LENGTH);

  const status = ORDER_STATUSES.find((s) => s === search["status"]);
  if (status) params.status = status;

  const payment = PAYMENT_STATUSES.find((s) => s === search["payment"]);
  if (payment) params.payment = payment;

  const page = Number(search["page"]);
  if (Number.isInteger(page) && page > 1 && page <= 100_000) params.page = page;

  return params;
}

export function toOrderListFilters(
  params: OrderListParams,
  pageSize: number = ORDERS_PAGE_SIZE,
): AdminOrderListFilters {
  return {
    search: params.q ?? null,
    status: params.status ?? null,
    paymentStatus: params.payment ?? null,
    limit: pageSize,
    offset: ((params.page ?? 1) - 1) * pageSize,
  };
}

export interface PageInfo {
  page: number;
  pageCount: number;
  /** 1-based position of the first/last row on this page; 0 when the page is empty. */
  from: number;
  to: number;
  hasPrevious: boolean;
  hasNext: boolean;
}

export function getPageInfo(
  total: number,
  limit: number,
  offset: number,
  rows: number,
): PageInfo {
  const safeLimit = Math.max(1, limit);
  const pageCount = Math.max(1, Math.ceil(total / safeLimit));
  return {
    page: Math.floor(offset / safeLimit) + 1,
    pageCount,
    from: rows === 0 ? 0 : offset + 1,
    to: rows === 0 ? 0 : offset + rows,
    hasPrevious: offset > 0,
    hasNext: offset + rows < total,
  };
}

// ---------------------------------------------------------------------------
// Status actions
// ---------------------------------------------------------------------------

/** Standard moves, as in set_order_status(). Anything else would be an override (not offered). */
const STANDARD_TRANSITIONS: Partial<
  Record<OrderStatus, readonly OrderStatus[]>
> = {
  pending: ["processing", "cancelled"],
  awaiting_payment: ["cancelled"],
  paid: ["processing", "cancelled"],
  processing: ["picking", "cancelled"],
  picking: ["packed", "cancelled"],
  packed: ["dispatched", "cancelled"],
  dispatched: ["out_for_delivery", "delivered", "cancelled"],
  out_for_delivery: ["delivered", "cancelled"],
};

const FULFILMENT: readonly OrderStatus[] = [
  "processing",
  "picking",
  "packed",
  "dispatched",
  "out_for_delivery",
  "delivered",
];

export interface StatusOption {
  status: OrderStatus;
  /** Why this move cannot be made right now, or null when it can. */
  blockedReason: string | null;
}

export interface TransitionSource {
  status: OrderStatus;
  payment_status: PaymentStatus;
  payment_method: PaymentMethod;
}

/**
 * The moves to offer for an order. An online-payment order that is not confirmed paid cannot
 * enter fulfilment (the database enforces this too); it is shown disabled with the reason
 * rather than hidden. 'paid' and 'refunded' are never offered: payment outcomes are not set here.
 */
export function getStatusOptions(order: TransitionSource): StatusOption[] {
  const targets = STANDARD_TRANSITIONS[order.status] ?? [];
  const unpaidOnline =
    order.payment_method !== "cash_on_delivery" &&
    order.payment_status !== "paid";
  return targets.map((status) => ({
    status,
    blockedReason:
      unpaidOnline && FULFILMENT.includes(status)
        ? "This order has not been paid yet, so it cannot be fulfilled."
        : null,
  }));
}

/** Moves that return stock or are final get a warning in the confirmation dialog. */
export function isConsequentialStatus(status: OrderStatus): boolean {
  return status === "cancelled" || status === "delivered";
}

export const MAX_STATUS_NOTE_LENGTH = 400;

const REASON_MESSAGES: Record<string, string> = {
  transition_not_allowed:
    "That status change is not allowed from the order's current status. The order may have been updated elsewhere; it has been refreshed.",
  payment_not_confirmed:
    "This order has not been paid, so it cannot be fulfilled yet.",
  payment_state_reserved:
    "Paid and refunded are set by payment events, not from this screen.",
  payment_method_mismatch:
    "That status does not match the order's payment method.",
  note_too_long: `The note is too long (${MAX_STATUS_NOTE_LENGTH} characters at most).`,
  note_reserved_prefix: "The note cannot start with “Admin override:”.",
  reactivation_slot_full: "The delivery slot for this order is full.",
  reactivation_slot_closed: "The delivery slot for this order is closed.",
  reactivation_slot_not_offered:
    "The delivery slot for this order is no longer offered.",
  reactivation_insufficient_stock:
    "There is not enough stock to reactivate this order.",
};

/** What the person is told when a status change fails. Never a raw database message. */
export function describeStatusChangeError(error: unknown): string {
  if (error instanceof AdminAccessError)
    return "You do not have permission to change orders.";
  if (error instanceof AdminOrderNotFoundError)
    return "That order could not be found.";
  if (error instanceof AdminOrderActionError) {
    return (
      REASON_MESSAGES[error.reason] ??
      "The database refused that status change. Please review it."
    );
  }
  return "We couldn't update the order. Please try again.";
}
