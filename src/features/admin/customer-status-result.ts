import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  characterCount,
  requireBoolean,
  requireRecord,
  requireString,
  requireStatus,
  unexpected,
  type CustomerStatus,
} from "./customer-parse.ts";

/**
 * Pure parser, error mapper and argument builder for admin_set_customer_status() (Phase 6E.1B-1).
 * Admin-only on the server. Since Phase 6E.3 create_order() refuses a suspended customer
 * (P0001, DETAIL account_suspended); the status is no longer only a label.
 */

export const MAX_STATUS_REASON_LENGTH = 500;

export type AdminCustomerStatusReason =
  | "invalid_arguments"
  | "invalid_status"
  | "reason_required"
  | "reason_too_long"
  | "cannot_target_self"
  | "customer_not_found"
  | "cannot_target_staff"
  | "status_unchanged";

const STATUS_REASONS: readonly AdminCustomerStatusReason[] = [
  "invalid_arguments",
  "invalid_status",
  "reason_required",
  "reason_too_long",
  "cannot_target_self",
  "customer_not_found",
  "cannot_target_staff",
  "status_unchanged",
];

export type CustomerStatusFieldKey = "reason";

/** A rule refused the change. `reason` is the database's own DETAIL code, not its message. */
export class AdminCustomerStatusError extends Error {
  override readonly name = "AdminCustomerStatusError";
  readonly reason: AdminCustomerStatusReason;
  readonly field: CustomerStatusFieldKey | null;

  constructor(reason: AdminCustomerStatusReason) {
    super(`Customer status change refused: ${reason}`);
    this.reason = reason;
    this.field =
      reason === "reason_required" || reason === "reason_too_long"
        ? "reason"
        : null;
  }
}

export function toAdminCustomerStatusError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to change customer status.",
    );
  }
  const reason = STATUS_REASONS.find((r) => r === error.details);
  return reason
    ? new AdminCustomerStatusError(reason)
    : new Error(error.message);
}

export interface AdminSetCustomerStatusResult {
  changed: true;
  customer_id: string;
  previous_status: CustomerStatus;
  status: CustomerStatus;
}

export function toAdminSetCustomerStatusResult(
  data: unknown,
): AdminSetCustomerStatusResult {
  const what = "The customer status change";
  const r = requireRecord(data, what);
  if (!requireBoolean(r, "changed", what)) unexpected(what);
  return {
    changed: true,
    customer_id: requireString(r, "customer_id", what),
    previous_status: requireStatus(r, "previous_status", what),
    status: requireStatus(r, "status", what),
  };
}

export interface AdminSetCustomerStatusArgs {
  p_customer_id: string;
  p_status: CustomerStatus;
  p_reason: string;
}

export type CustomerStatusBuild =
  | { ok: true; args: AdminSetCustomerStatusArgs }
  | { ok: false; errors: Partial<Record<CustomerStatusFieldKey, string>> };

/** Turns the form into admin_set_customer_status() arguments; the database still decides. */
export function buildSetCustomerStatusArgs(
  customerId: string,
  status: CustomerStatus,
  rawReason: string,
): CustomerStatusBuild {
  const reason = rawReason.trim();
  if (reason === "")
    return { ok: false, errors: { reason: "A reason is required." } };
  if (characterCount(reason) > MAX_STATUS_REASON_LENGTH) {
    return {
      ok: false,
      errors: {
        reason: `Keep the reason to ${MAX_STATUS_REASON_LENGTH} characters or fewer.`,
      },
    };
  }
  return {
    ok: true,
    args: { p_customer_id: customerId, p_status: status, p_reason: reason },
  };
}
