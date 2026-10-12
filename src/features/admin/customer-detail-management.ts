import type { OrderStatus, PaymentStatus } from "../../lib/supabase/types.ts";
import {
  ORDER_STATUS_LABELS,
  PAYMENT_STATUS_LABELS,
} from "../orders/status.ts";
import { AdminAccessError } from "./dashboard-result.ts";
import { AdminCustomerNotesError } from "./customer-notes-result.ts";
import { AdminCustomerStatusError } from "./customer-status-result.ts";
import type { CustomerStatus } from "./customers-result.ts";

/**
 * Pure helpers for the admin customer detail screen (Phase 6E.2). No runtime imports beyond
 * sibling pure modules, so they run under `node --test`.
 *
 * Nothing here decides who may see or change a customer, or what a status becomes: the database
 * does (require_admin() inside every customer function). The wording below only reports what the
 * database refused.
 */

/** The status a one-click change would set. The database still validates it. */
export function oppositeStatus(status: CustomerStatus): CustomerStatus {
  return status === "active" ? "suspended" : "active";
}

export function statusActionLabel(target: CustomerStatus): string {
  return target === "suspended" ? "Suspend customer" : "Reactivate customer";
}

export function statusConfirmLabel(target: CustomerStatus): string {
  return target === "suspended" ? "Suspend" : "Reactivate";
}

const STATUS_REFUSAL_TEXT: Record<AdminCustomerStatusError["reason"], string> =
  {
    invalid_arguments: "Check the details and try again.",
    invalid_status: "That status is not valid.",
    reason_required: "A reason is required.",
    reason_too_long:
      "That reason is too long. Keep it to 500 characters or fewer.",
    cannot_target_self: "You can't change the status of your own account.",
    customer_not_found:
      "This customer no longer exists. Go back to the customer list.",
    cannot_target_staff: "Staff and admin accounts can't be changed here.",
    status_unchanged:
      "This customer already has that status. The page has been refreshed.",
  };

/**
 * What the admin is told when a status change fails. Raw database text is never shown. An
 * unrecognised failure (a network drop, say) leaves the outcome unknown, so the wording points at
 * the refreshed status rather than inviting a blind retry.
 */
export function describeStatusChangeError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to change customer status.";
  }
  if (error instanceof AdminCustomerStatusError)
    return STATUS_REFUSAL_TEXT[error.reason];
  return "We couldn't confirm that change. Check the status shown on this page before trying again.";
}

const NOTES_REFUSAL_TEXT: Record<AdminCustomerNotesError["reason"], string> = {
  invalid_arguments: "Check the notes and try again.",
  notes_too_long:
    "Those notes are too long. Keep them to 2,000 characters or fewer.",
  customer_not_found:
    "This customer no longer exists. Go back to the customer list.",
  cannot_target_staff: "Staff and admin accounts can't be changed here.",
};

export function describeNotesError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to edit customer notes.";
  }
  if (error instanceof AdminCustomerNotesError)
    return NOTES_REFUSAL_TEXT[error.reason];
  return "We couldn't confirm that the notes were saved. Check the notes shown before trying again.";
}

/** True when the draft differs from what is stored (both compared as the database stores them). */
export function notesChanged(saved: string | null, draft: string): boolean {
  return (saved ?? "").trim() !== draft.trim();
}

/** A short, stable reference for an order the list API identifies only by id. */
export function orderReference(orderId: string): string {
  return orderId.slice(0, 8).toUpperCase();
}

/** The parsers keep order statuses as plain strings; narrow to a known one, or null. */
export function asOrderStatus(value: string): OrderStatus | null {
  return (
    (Object.keys(ORDER_STATUS_LABELS) as OrderStatus[]).find(
      (s) => s === value,
    ) ?? null
  );
}

export function asPaymentStatus(value: string): PaymentStatus | null {
  return (
    (Object.keys(PAYMENT_STATUS_LABELS) as PaymentStatus[]).find(
      (s) => s === value,
    ) ?? null
  );
}

/** One line for an address, skipping blank parts. */
export function formatAddressLines(address: {
  address_line_1: string | null;
  address_line_2: string | null;
  city: string | null;
  county: string | null;
  postal_code: string | null;
}): string[] {
  const cityLine = [address.city, address.county, address.postal_code]
    .map((part) => part?.trim() ?? "")
    .filter((part) => part !== "")
    .join(", ");
  return [address.address_line_1, address.address_line_2, cityLine]
    .map((line) => line?.trim() ?? "")
    .filter((line) => line !== "");
}
