import type {
  AdminOrderDetail,
  AdminOrderList,
  AdminOrderListFilters,
  AdminSetOrderStatusInput,
  AdminSetOrderStatusResult,
} from "../../lib/supabase/types.ts";
import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Pure helpers for public.admin_list_orders() / public.admin_get_order() (Phase 6B.1). No
 * runtime imports beyond the Phase 6A error class, so they run under `node --test`.
 *
 * Authorisation is NOT decided here: the database refuses non-admins (SQLSTATE 42501,
 * DETAIL `not_authorised`). This only maps that refusal, and the "order not found" case,
 * to errors the UI can recognise, and checks payload shapes.
 */

export class AdminOrderNotFoundError extends Error {
  override readonly name = "AdminOrderNotFoundError";

  constructor(message = "That order could not be found.") {
    super(message);
  }
}

export function toAdminOrdersError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to view admin orders.",
    );
  }
  if (error.details === "order_not_found") return new AdminOrderNotFoundError();
  return new Error(error.message);
}

/** Named arguments for admin_list_orders(). Blank strings become null; defaults are explicit. */
export function toAdminListOrdersArgs(filters: AdminOrderListFilters = {}) {
  const text = (value: string | null | undefined) => {
    const trimmed = value?.trim();
    return trimmed ? trimmed : null;
  };
  return {
    p_search: text(filters.search),
    p_status: filters.status ?? null,
    p_payment_status: filters.paymentStatus ?? null,
    p_payment_method: filters.paymentMethod ?? null,
    p_placed_from: text(filters.placedFrom),
    p_placed_to: text(filters.placedTo),
    p_limit: filters.limit ?? 25,
    p_offset: filters.offset ?? 0,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function toAdminOrderList(data: unknown): AdminOrderList {
  if (
    !isRecord(data) ||
    !Array.isArray(data["orders"]) ||
    typeof data["total"] !== "number"
  ) {
    throw new Error("The admin order list returned an unexpected response.");
  }
  return data as unknown as AdminOrderList;
}

const DETAIL_KEYS = [
  "order",
  "customer",
  "delivery",
  "payment",
  "items",
  "history",
] as const;

export function toAdminOrderDetail(data: unknown): AdminOrderDetail {
  if (!isRecord(data))
    throw new Error("The admin order returned an unexpected response.");
  for (const key of DETAIL_KEYS) {
    if (!(key in data))
      throw new Error(`The admin order response is missing "${key}".`);
  }
  if (!Array.isArray(data["items"]) || !Array.isArray(data["history"])) {
    throw new Error("The admin order response has malformed items or history.");
  }
  return data as unknown as AdminOrderDetail;
}

// ---------------------------------------------------------------------------
// Admin order actions (Phase 6B.2): public.admin_set_order_status()
// ---------------------------------------------------------------------------

/**
 * Why the database refused a status action. These are the exception DETAIL codes raised by
 * admin_set_order_status() and by the Phase 5B.2 set_order_status() it delegates to, plus the
 * Phase 6B.1 `order_not_found`. The database is the only judge of validity: this class just
 * carries its answer to the UI.
 */
export type AdminOrderActionReason =
  | "transition_not_allowed"
  | "admin_note_required"
  | "override_not_requested"
  | "payment_state_reserved"
  | "payment_not_confirmed"
  | "payment_method_mismatch"
  | "note_too_long"
  | "invalid_arguments"
  | "note_reserved_prefix"
  | "reactivation_slot_full"
  | "reactivation_slot_closed"
  | "reactivation_slot_not_offered"
  | "reactivation_insufficient_stock"
  | "unknown";

const ACTION_REASONS: readonly AdminOrderActionReason[] = [
  "transition_not_allowed",
  "admin_note_required",
  "override_not_requested",
  "payment_state_reserved",
  "payment_not_confirmed",
  "payment_method_mismatch",
  "note_too_long",
  "invalid_arguments",
  "note_reserved_prefix",
  "reactivation_slot_full",
  "reactivation_slot_closed",
  "reactivation_slot_not_offered",
  "reactivation_insufficient_stock",
];

export class AdminOrderActionError extends Error {
  override readonly name = "AdminOrderActionError";
  readonly reason: AdminOrderActionReason;

  constructor(message: string, reason: AdminOrderActionReason) {
    super(message);
    this.reason = reason;
  }
}

/**
 * Maps a refused admin_set_order_status() call to an error the UI can recognise:
 * not-an-admin -> AdminAccessError, unknown order -> AdminOrderNotFoundError, a rule refusal ->
 * AdminOrderActionError (with the database's own message and reason code). Anything else keeps
 * its message.
 */
export function toAdminOrderActionError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError("You do not have permission to change orders.");
  }
  if (error.details === "order_not_found") return new AdminOrderNotFoundError();
  const reason = ACTION_REASONS.find((r) => r === error.details);
  if (reason) return new AdminOrderActionError(error.message, reason);
  return new Error(error.message);
}

/** Named arguments for admin_set_order_status(). A blank note becomes null; override defaults to false. */
export function toAdminSetOrderStatusArgs(input: AdminSetOrderStatusInput) {
  const note = input.note?.trim();
  return {
    p_order_id: input.orderId,
    p_status: input.status,
    p_note: note ? note : null,
    p_override: input.override === true,
  };
}

export function toAdminSetOrderStatusResult(
  data: unknown,
): AdminSetOrderStatusResult {
  if (!isRecord(data))
    throw new Error("The order action returned an unexpected response.");
  const result = data as Partial<AdminSetOrderStatusResult>;
  if (typeof result.changed !== "boolean") {
    throw new Error("The order action returned an unexpected response.");
  }
  if (typeof result.order?.status !== "string") {
    throw new Error("The order action response is missing the updated order.");
  }
  if (result.changed && !isRecord(result.history_entry)) {
    throw new Error("The order action response is missing its history entry.");
  }
  return data as unknown as AdminSetOrderStatusResult;
}
