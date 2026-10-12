import {
  characterCount,
  requireBoolean,
  requireRecord,
  requireString,
  requireWholeNumber,
  unexpected,
} from "./customer-parse.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import {
  MAX_CAPACITY,
  MAX_OVERRIDE_NOTE_LENGTH,
  checkReason,
  inWholeRange,
  isIsoDate,
  nullableWholeNumber,
  requireIsoDate,
} from "./delivery-parse.ts";
import {
  parseDeliverySlotOverrideRow,
  type AdminDeliverySlotOverrideRow,
} from "./delivery-slots-result.ts";

/**
 * Pure parsers and argument builders for admin_save_delivery_slot_override() and
 * admin_clear_delivery_slot_override() (Phase 6F.1B). Admin-only on the server. Whether the date
 * is in the past, too far ahead, or the capacity is below the orders already booked is decided by
 * the database (it holds the slot lock); those refusals arrive as AdminDeliveryError.
 */

export interface AdminSaveDeliverySlotOverrideResult {
  changed: boolean;
  created: boolean;
  override: AdminDeliverySlotOverrideRow;
  booked_count: number;
}

export function toAdminSaveDeliverySlotOverrideResult(
  data: unknown,
): AdminSaveDeliverySlotOverrideResult {
  const what = "The delivery slot override save";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    created: requireBoolean(r, "created", what),
    override: parseDeliverySlotOverrideRow(
      requireRecord(r["override"], what),
      what,
    ),
    booked_count: requireWholeNumber(r, "booked_count", what),
  };
}

export interface AdminSaveDeliverySlotOverrideArgs {
  p_template_id: string;
  p_slot_date: string;
  p_capacity: number | null;
  p_is_closed: boolean;
  p_note: string | null;
}

export interface DeliverySlotOverrideInput {
  templateId: string;
  /** YYYY-MM-DD. */
  slotDate: string;
  /** null = inherit the template. */
  capacity: number | null;
  closed: boolean;
  note: string;
}

export type DeliverySlotOverrideBuild =
  | { ok: true; args: AdminSaveDeliverySlotOverrideArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSaveDeliverySlotOverrideArgs(
  input: DeliverySlotOverrideInput,
): DeliverySlotOverrideBuild {
  const errors: DeliveryFieldErrors = {};
  const note = input.note.trim();

  if (input.templateId.trim() === "") errors.form = "Choose a slot.";
  if (!isIsoDate(input.slotDate)) errors.date = "Choose a valid date.";
  if (input.capacity !== null && !inWholeRange(input.capacity, MAX_CAPACITY)) {
    errors.capacity =
      "The capacity must be a whole number of orders (0 to 100,000), or empty.";
  } else if (input.closed && input.capacity !== null) {
    errors.capacity =
      "A closed slot cannot also have a capacity. Close it, or set a capacity.";
  }
  if (characterCount(note) > MAX_OVERRIDE_NOTE_LENGTH) {
    errors.note = `Keep the note to ${MAX_OVERRIDE_NOTE_LENGTH} characters or fewer.`;
  }
  if (
    errors.form === undefined &&
    input.capacity === null &&
    !input.closed &&
    note === ""
  ) {
    errors.form =
      "Nothing to set: give a capacity, close the slot, or add a note.";
  }
  if (Object.keys(errors).length > 0) return { ok: false, errors };

  return {
    ok: true,
    args: {
      p_template_id: input.templateId,
      p_slot_date: input.slotDate,
      p_capacity: input.capacity,
      p_is_closed: input.closed,
      p_note: note === "" ? null : note,
    },
  };
}

export interface AdminClearDeliverySlotOverrideResult {
  changed: true;
  override_id: string;
  template_id: string;
  slot_date: string;
  previous_capacity: number | null;
  previous_is_closed: boolean;
}

export function toAdminClearDeliverySlotOverrideResult(
  data: unknown,
): AdminClearDeliverySlotOverrideResult {
  const what = "The delivery slot override clear";
  const r = requireRecord(data, what);
  if (!requireBoolean(r, "changed", what)) unexpected(what);
  return {
    changed: true,
    override_id: requireString(r, "override_id", what),
    template_id: requireString(r, "template_id", what),
    slot_date: requireIsoDate(r, "slot_date", what),
    previous_capacity: nullableWholeNumber(r, "previous_capacity", what),
    previous_is_closed: requireBoolean(r, "previous_is_closed", what),
  };
}

export interface AdminClearDeliverySlotOverrideArgs {
  p_template_id: string;
  p_slot_date: string;
  p_reason: string;
}

export type DeliverySlotOverrideClearBuild =
  | { ok: true; args: AdminClearDeliverySlotOverrideArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildClearDeliverySlotOverrideArgs(
  templateId: string,
  slotDate: string,
  rawReason: string,
): DeliverySlotOverrideClearBuild {
  const errors: DeliveryFieldErrors = {};
  if (templateId.trim() === "") errors.form = "Choose a slot.";
  if (!isIsoDate(slotDate)) errors.date = "Choose a valid date.";
  const reason = checkReason(rawReason, true);
  if (reason.error !== null) errors.reason = reason.error;
  if (Object.keys(errors).length > 0 || reason.value === null)
    return { ok: false, errors };
  return {
    ok: true,
    args: {
      p_template_id: templateId,
      p_slot_date: slotDate,
      p_reason: reason.value,
    },
  };
}
