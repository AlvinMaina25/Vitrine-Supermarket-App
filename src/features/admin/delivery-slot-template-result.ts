import {
  characterCount,
  requireBoolean,
  requireRecord,
  requireString,
} from "./customer-parse.ts";
import { requireWholeNumber, unexpected } from "./customer-parse.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import {
  MAX_CAPACITY,
  MAX_POSITION,
  MAX_SLOT_LABEL_LENGTH,
  checkReason,
  inWholeRange,
  normaliseTime,
} from "./delivery-parse.ts";
import {
  parseDeliverySlotTemplate,
  type AdminDeliverySlotTemplate,
} from "./delivery-slots-result.ts";

/**
 * Pure parsers and argument builders for admin_save_delivery_slot_template() and
 * admin_set_delivery_slot_template_active() (Phase 6F.1B). Admin-only on the server.
 */

export interface AdminSaveDeliverySlotTemplateResult {
  changed: boolean;
  created: boolean;
  template: AdminDeliverySlotTemplate;
}

export function toAdminSaveDeliverySlotTemplateResult(
  data: unknown,
): AdminSaveDeliverySlotTemplateResult {
  const what = "The delivery slot save";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    created: requireBoolean(r, "created", what),
    template: parseDeliverySlotTemplate(
      requireRecord(r["template"], what),
      what,
    ),
  };
}

export interface AdminSaveDeliverySlotTemplateArgs {
  p_template_id: string | null;
  p_label: string;
  p_start_time: string;
  p_end_time: string;
  p_day_of_week: number | null;
  p_capacity: number | null;
  p_position: number | null;
}

export interface DeliverySlotTemplateInput {
  /** null creates a template; an id updates it. */
  templateId: string | null;
  label: string;
  /** HH:MM or HH:MM:SS. */
  startTime: string;
  endTime: string;
  /** 0 (Sunday) to 6 (Saturday); null = every day. */
  dayOfWeek: number | null;
  /** null = unlimited; 0 = closed. */
  capacity: number | null;
  /** null keeps the current position (0 on create). */
  position: number | null;
}

export type DeliverySlotTemplateBuild =
  | { ok: true; args: AdminSaveDeliverySlotTemplateArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSaveDeliverySlotTemplateArgs(
  input: DeliverySlotTemplateInput,
): DeliverySlotTemplateBuild {
  const errors: DeliveryFieldErrors = {};
  const label = input.label.trim();
  const start = normaliseTime(input.startTime);
  const end = normaliseTime(input.endTime);

  if (label === "") errors.label = "A slot label is required.";
  else if (characterCount(label) > MAX_SLOT_LABEL_LENGTH) {
    errors.label = `Keep the label to ${MAX_SLOT_LABEL_LENGTH} characters or fewer.`;
  }
  if (start === null || end === null) {
    errors.window = "Enter the start and end times as HH:MM (24-hour).";
  } else if (end <= start) {
    errors.window = "A slot needs an end time after its start time.";
  }
  if (
    input.dayOfWeek !== null &&
    !(
      Number.isInteger(input.dayOfWeek) &&
      input.dayOfWeek >= 0 &&
      input.dayOfWeek <= 6
    )
  ) {
    errors.weekday = "Choose a weekday, or every day.";
  }
  if (input.capacity !== null && !inWholeRange(input.capacity, MAX_CAPACITY)) {
    errors.capacity =
      "The capacity must be a whole number of orders (0 to 100,000), or empty.";
  }
  if (input.position !== null && !inWholeRange(input.position, MAX_POSITION)) {
    errors.position =
      "The position must be a whole number from 0 to 1,000,000.";
  }
  if (Object.keys(errors).length > 0 || start === null || end === null) {
    return { ok: false, errors };
  }

  return {
    ok: true,
    args: {
      p_template_id: input.templateId,
      p_label: label,
      p_start_time: start,
      p_end_time: end,
      p_day_of_week: input.dayOfWeek,
      p_capacity: input.capacity,
      p_position: input.position,
    },
  };
}

export interface AdminSetDeliverySlotTemplateActiveResult {
  changed: true;
  template_id: string;
  previous_is_active: boolean;
  is_active: boolean;
  /** Upcoming orders that hold this window; they keep their slot either way. */
  upcoming_booked_orders: number;
}

export function toAdminSetDeliverySlotTemplateActiveResult(
  data: unknown,
): AdminSetDeliverySlotTemplateActiveResult {
  const what = "The delivery slot status change";
  const r = requireRecord(data, what);
  if (!requireBoolean(r, "changed", what)) unexpected(what);
  return {
    changed: true,
    template_id: requireString(r, "template_id", what),
    previous_is_active: requireBoolean(r, "previous_is_active", what),
    is_active: requireBoolean(r, "is_active", what),
    upcoming_booked_orders: requireWholeNumber(
      r,
      "upcoming_booked_orders",
      what,
    ),
  };
}

export interface AdminSetDeliverySlotTemplateActiveArgs {
  p_template_id: string;
  p_is_active: boolean;
  p_reason: string;
}

export type DeliverySlotTemplateActiveBuild =
  | { ok: true; args: AdminSetDeliverySlotTemplateActiveArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSetDeliverySlotTemplateActiveArgs(
  templateId: string,
  isActive: boolean,
  rawReason: string,
): DeliverySlotTemplateActiveBuild {
  const reason = checkReason(rawReason, true);
  if (reason.value === null)
    return { ok: false, errors: { reason: reason.error ?? "" } };
  return {
    ok: true,
    args: {
      p_template_id: templateId,
      p_is_active: isActive,
      p_reason: reason.value,
    },
  };
}
