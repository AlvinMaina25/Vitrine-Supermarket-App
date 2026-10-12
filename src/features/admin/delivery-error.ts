import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Error mapping for every 6F.1A and 6F.1B function. The database refuses with SQLSTATE P0001 and
 * a DETAIL code (or 42501 / not_authorised from the admin gate). The code is kept as `reason`;
 * the message shown to people is ours, so it never echoes database text.
 */

export type AdminDeliveryReason =
  // 6F.1A: methods, zones, zone fees
  | "invalid_arguments"
  | "invalid_code"
  | "code_immutable"
  | "code_taken"
  | "name_required"
  | "name_too_long"
  | "county_too_long"
  | "description_too_long"
  | "invalid_towns"
  | "invalid_position"
  | "invalid_fee"
  | "invalid_free_over"
  | "invalid_min_order"
  | "immutable_fields"
  | "zone_not_found"
  | "zone_fee_not_found"
  | "method_not_found"
  | "zone_fee_exists"
  | "reason_required"
  | "reason_too_long"
  | "status_unchanged"
  // 6F.1B: slot templates and overrides
  | "invalid_date_range"
  | "date_range_too_large"
  | "label_required"
  | "label_too_long"
  | "invalid_window"
  | "invalid_weekday"
  | "invalid_capacity"
  | "template_not_found"
  | "template_has_bookings"
  | "template_inactive"
  | "template_not_on_date"
  | "date_in_past"
  | "date_too_far"
  | "note_too_long"
  | "capacity_with_closed"
  | "override_empty"
  | "override_not_found"
  | "capacity_below_booked";

/** Which form field a refusal belongs to; null means it concerns the whole action. */
export type DeliveryFieldKey =
  | "code"
  | "name"
  | "county"
  | "description"
  | "towns"
  | "position"
  | "fee"
  | "freeOver"
  | "minOrder"
  | "label"
  | "window"
  | "weekday"
  | "capacity"
  | "date"
  | "range"
  | "note"
  | "reason"
  | "form";

export type DeliveryFieldErrors = Partial<Record<DeliveryFieldKey, string>>;

const MESSAGES: Record<AdminDeliveryReason, string> = {
  invalid_arguments:
    "Some required details are missing. Check the form and try again.",
  invalid_code:
    "The code must be 2-40 characters: lowercase letters, digits, - or _, starting with a letter.",
  code_immutable: "The code cannot be changed once created.",
  code_taken: "That code is already in use.",
  name_required: "A name is required.",
  name_too_long: "The name is too long (120 characters at most).",
  county_too_long: "The county is too long (80 characters at most).",
  description_too_long: "The description is too long (500 characters at most).",
  invalid_towns:
    "A zone can list at most 100 towns of at most 80 characters each.",
  invalid_position: "The position must be a whole number from 0 to 1,000,000.",
  invalid_fee: "The fee must be a whole number of cents, zero or more.",
  invalid_free_over:
    "The free-delivery threshold must be a whole number of cents, or empty.",
  invalid_min_order:
    "The minimum order must be a whole number of cents, zero or more.",
  immutable_fields:
    "The zone and method of a fee rule cannot change. Deactivate it and create a new one.",
  zone_not_found: "That delivery zone no longer exists. Refresh and try again.",
  zone_fee_not_found: "That fee rule no longer exists. Refresh and try again.",
  method_not_found:
    "That delivery method no longer exists. Refresh and try again.",
  zone_fee_exists:
    "A fee rule for that zone and method already exists. Edit it instead.",
  reason_required: "A reason is required.",
  reason_too_long: "The reason is too long (500 characters at most).",
  status_unchanged:
    "Nothing to change: it is already in that state. Refresh and try again.",
  invalid_date_range: "Choose a valid date range.",
  date_range_too_large: "The date range can be at most 31 days.",
  label_required: "A slot label is required.",
  label_too_long: "The slot label is too long (80 characters at most).",
  invalid_window: "A slot needs a start time and an end time after it.",
  invalid_weekday: "Choose a weekday, or every day.",
  invalid_capacity:
    "The capacity must be a whole number of orders (0 to 100,000), or empty.",
  template_not_found: "That slot no longer exists. Refresh and try again.",
  template_has_bookings:
    "Upcoming orders hold this slot, so its times or weekday cannot change. Deactivate it and create a new slot instead.",
  template_inactive:
    "That slot is inactive. Activate it before setting a date override.",
  template_not_on_date: "That slot does not run on that weekday.",
  date_in_past: "The date cannot be in the past.",
  date_too_far: "The date can be at most 365 days ahead.",
  note_too_long: "The note is too long (300 characters at most).",
  capacity_with_closed:
    "A closed slot cannot also have a capacity. Close it, or set a capacity.",
  override_empty:
    "Nothing to set: give a capacity, close the slot, or add a note.",
  override_not_found: "There is no override for that slot on that date.",
  capacity_below_booked:
    "Orders already hold this slot on that date, so the capacity cannot go below them. Close the slot to stop new bookings instead.",
};

const FIELDS: Record<AdminDeliveryReason, DeliveryFieldKey | null> = {
  invalid_arguments: null,
  invalid_code: "code",
  code_immutable: "code",
  code_taken: "code",
  name_required: "name",
  name_too_long: "name",
  county_too_long: "county",
  description_too_long: "description",
  invalid_towns: "towns",
  invalid_position: "position",
  invalid_fee: "fee",
  invalid_free_over: "freeOver",
  invalid_min_order: "minOrder",
  immutable_fields: null,
  zone_not_found: null,
  zone_fee_not_found: null,
  method_not_found: null,
  zone_fee_exists: null,
  reason_required: "reason",
  reason_too_long: "reason",
  status_unchanged: null,
  invalid_date_range: "range",
  date_range_too_large: "range",
  label_required: "label",
  label_too_long: "label",
  invalid_window: "window",
  invalid_weekday: "weekday",
  invalid_capacity: "capacity",
  template_not_found: null,
  template_has_bookings: "window",
  template_inactive: null,
  template_not_on_date: "date",
  date_in_past: "date",
  date_too_far: "date",
  note_too_long: "note",
  capacity_with_closed: "capacity",
  override_empty: null,
  override_not_found: null,
  capacity_below_booked: "capacity",
};

export const ADMIN_DELIVERY_REASONS = Object.keys(
  MESSAGES,
) as AdminDeliveryReason[];

export function isAdminDeliveryReason(
  value: unknown,
): value is AdminDeliveryReason {
  return ADMIN_DELIVERY_REASONS.some((reason) => reason === value);
}

/** The friendly message for a database refusal code. */
export function deliveryReasonMessage(reason: AdminDeliveryReason): string {
  return MESSAGES[reason];
}

/** A rule refused the change. `reason` is the database's own DETAIL code, not its message. */
export class AdminDeliveryError extends Error {
  override readonly name = "AdminDeliveryError";
  readonly reason: AdminDeliveryReason;
  readonly field: DeliveryFieldKey | null;

  constructor(reason: AdminDeliveryReason) {
    super(MESSAGES[reason]);
    this.reason = reason;
    this.field = FIELDS[reason];
  }
}

export function isAdminDeliveryError(
  error: unknown,
): error is AdminDeliveryError {
  return error instanceof AdminDeliveryError;
}

/**
 * Maps a PostgREST error from any delivery admin function. 42501 / not_authorised becomes an
 * AdminAccessError; a known DETAIL code becomes an AdminDeliveryError; anything else keeps the
 * database's own message.
 */
export function toAdminDeliveryError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to manage delivery settings.",
    );
  }
  const details = error.details ?? undefined;
  return isAdminDeliveryReason(details)
    ? new AdminDeliveryError(details)
    : new Error(error.message);
}
