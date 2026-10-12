import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  characterCount,
  requireRecord,
  requireString,
  requireWholeNumber,
} from "./customer-parse.ts";

/**
 * Pure parser, error mapper and argument builder for admin_update_customer_notes() (Phase
 * 6E.1B-2). Admin-only on the server. An empty (or whitespace-only) note clears the notes, so
 * unlike most forms a blank value is valid here.
 */

export const MAX_CUSTOMER_NOTES_LENGTH = 2000;

export type AdminCustomerNotesReason =
  | "invalid_arguments"
  | "notes_too_long"
  | "customer_not_found"
  | "cannot_target_staff";

const NOTES_REASONS: readonly AdminCustomerNotesReason[] = [
  "invalid_arguments",
  "notes_too_long",
  "customer_not_found",
  "cannot_target_staff",
];

/** A rule refused the update. `reason` is the database's own DETAIL code, not its message. */
export class AdminCustomerNotesError extends Error {
  override readonly name = "AdminCustomerNotesError";
  readonly reason: AdminCustomerNotesReason;
  readonly field: "notes" | null;

  constructor(reason: AdminCustomerNotesReason) {
    super(`Customer notes update refused: ${reason}`);
    this.reason = reason;
    this.field = reason === "notes_too_long" ? "notes" : null;
  }
}

export function toAdminCustomerNotesError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to edit customer notes.",
    );
  }
  const reason = NOTES_REASONS.find((r) => r === error.details);
  return reason
    ? new AdminCustomerNotesError(reason)
    : new Error(error.message);
}

export interface AdminUpdateCustomerNotesResult {
  customer_id: string;
  /** Length of the trimmed text now stored; 0 means the notes were cleared. */
  length: number;
}

export function toAdminUpdateCustomerNotesResult(
  data: unknown,
): AdminUpdateCustomerNotesResult {
  const what = "The customer notes update";
  const r = requireRecord(data, what);
  return {
    customer_id: requireString(r, "customer_id", what),
    length: requireWholeNumber(r, "length", what),
  };
}

export interface AdminUpdateCustomerNotesArgs {
  p_customer_id: string;
  p_notes: string;
}

export type CustomerNotesBuild =
  | { ok: true; args: AdminUpdateCustomerNotesArgs; clearing: boolean }
  | { ok: false; errors: { notes: string } };

export function buildUpdateCustomerNotesArgs(
  customerId: string,
  rawNotes: string,
): CustomerNotesBuild {
  const notes = rawNotes.trim();
  if (characterCount(notes) > MAX_CUSTOMER_NOTES_LENGTH) {
    return {
      ok: false,
      errors: {
        notes: `Keep the notes to ${MAX_CUSTOMER_NOTES_LENGTH} characters or fewer.`,
      },
    };
  }
  return {
    ok: true,
    clearing: notes === "",
    args: { p_customer_id: customerId, p_notes: notes },
  };
}
