import {
  nullableString,
  requireBoolean,
  requireRecord,
  requireString,
  requireWholeNumber,
  type JsonRecord,
} from "./customer-parse.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import {
  MAX_SLOT_RANGE_DAYS,
  isIsoDate,
  nullableWholeNumber,
  parseList,
  requireIsoDate,
  requireTime,
} from "./delivery-parse.ts";

/**
 * Pure parser and argument builder for admin_list_delivery_slots() (Phase 6F.1B). Admin-only on
 * the server. One read returns every template (inactive included), the meaningful per-date
 * overrides in the range and one row per date x template with its effective capacity (null =
 * unlimited) and booked count. Counts come from the database; nothing is computed here.
 */

export interface AdminDeliverySlotTemplate {
  id: string;
  label: string;
  start_time: string;
  end_time: string;
  /** 0 (Sunday) to 6 (Saturday); null = every day. */
  day_of_week: number | null;
  /** null = unlimited; 0 = closed. */
  capacity: number | null;
  position: number;
  is_active: boolean;
}

export interface AdminDeliverySlotOverrideRow {
  id: string;
  template_id: string;
  slot_date: string;
  /** null = inherit the template. */
  capacity: number | null;
  is_active: boolean;
  note: string | null;
}

export interface AdminDeliverySlotOverride extends AdminDeliverySlotOverrideRow {
  template_label: string;
  start_time: string;
  end_time: string;
  is_closed: boolean;
  booked_count: number;
}

export interface AdminDeliverySlot {
  slot_date: string;
  template_id: string;
  label: string;
  start_time: string;
  end_time: string;
  position: number;
  template_active: boolean;
  template_capacity: number | null;
  override_capacity: number | null;
  override_closed: boolean;
  /** null = unlimited. */
  effective_capacity: number | null;
  is_closed: boolean;
  booked_count: number;
}

export interface AdminDeliverySlotList {
  from: string;
  to: string;
  templates: AdminDeliverySlotTemplate[];
  overrides: AdminDeliverySlotOverride[];
  slots: AdminDeliverySlot[];
}

const WHAT = "The delivery slot list";

function requireWeekday(r: JsonRecord, what: string): number | null {
  const value = nullableWholeNumber(r, "day_of_week", what);
  if (value !== null && value > 6)
    throw new Error(`${what} returned an unexpected response.`);
  return value;
}

export function parseDeliverySlotTemplate(
  r: JsonRecord,
  what: string = WHAT,
): AdminDeliverySlotTemplate {
  return {
    id: requireString(r, "id", what),
    label: requireString(r, "label", what),
    start_time: requireTime(r, "start_time", what),
    end_time: requireTime(r, "end_time", what),
    day_of_week: requireWeekday(r, what),
    capacity: nullableWholeNumber(r, "capacity", what),
    position: requireWholeNumber(r, "position", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

export function parseDeliverySlotOverrideRow(
  r: JsonRecord,
  what: string = WHAT,
): AdminDeliverySlotOverrideRow {
  return {
    id: requireString(r, "id", what),
    template_id: requireString(r, "template_id", what),
    slot_date: requireIsoDate(r, "slot_date", what),
    capacity: nullableWholeNumber(r, "capacity", what),
    is_active: requireBoolean(r, "is_active", what),
    note: nullableString(r, "note", what),
  };
}

export function toAdminDeliverySlotList(data: unknown): AdminDeliverySlotList {
  const r = requireRecord(data, WHAT);
  return {
    from: requireIsoDate(r, "from", WHAT),
    to: requireIsoDate(r, "to", WHAT),
    templates: parseList(r["templates"], WHAT, (row) =>
      parseDeliverySlotTemplate(row),
    ),
    overrides: parseList(r["overrides"], WHAT, (row) => ({
      ...parseDeliverySlotOverrideRow(row),
      template_label: requireString(row, "template_label", WHAT),
      start_time: requireTime(row, "start_time", WHAT),
      end_time: requireTime(row, "end_time", WHAT),
      is_closed: requireBoolean(row, "is_closed", WHAT),
      booked_count: requireWholeNumber(row, "booked_count", WHAT),
    })),
    slots: parseList(r["slots"], WHAT, (row) => ({
      slot_date: requireIsoDate(row, "slot_date", WHAT),
      template_id: requireString(row, "template_id", WHAT),
      label: requireString(row, "label", WHAT),
      start_time: requireTime(row, "start_time", WHAT),
      end_time: requireTime(row, "end_time", WHAT),
      position: requireWholeNumber(row, "position", WHAT),
      template_active: requireBoolean(row, "template_active", WHAT),
      template_capacity: nullableWholeNumber(row, "template_capacity", WHAT),
      override_capacity: nullableWholeNumber(row, "override_capacity", WHAT),
      override_closed: requireBoolean(row, "override_closed", WHAT),
      effective_capacity: nullableWholeNumber(row, "effective_capacity", WHAT),
      is_closed: requireBoolean(row, "is_closed", WHAT),
      booked_count: requireWholeNumber(row, "booked_count", WHAT),
    })),
  };
}

export interface AdminListDeliverySlotsArgs {
  p_from: string;
  p_to: string;
}

export type DeliverySlotsRangeBuild =
  | { ok: true; args: AdminListDeliverySlotsArgs }
  | { ok: false; errors: DeliveryFieldErrors };

/** Whole days from `from` to `to` (both YYYY-MM-DD); calendar arithmetic only, no time zones. */
export function daysBetween(from: string, to: string): number {
  return Math.round(
    (new Date(`${to}T00:00:00Z`).getTime() -
      new Date(`${from}T00:00:00Z`).getTime()) /
      86_400_000,
  );
}

export function buildListDeliverySlotsArgs(
  from: string,
  to: string,
): DeliverySlotsRangeBuild {
  if (!isIsoDate(from) || !isIsoDate(to) || to < from) {
    return { ok: false, errors: { range: "Choose a valid date range." } };
  }
  if (daysBetween(from, to) > MAX_SLOT_RANGE_DAYS) {
    return {
      ok: false,
      errors: {
        range: `The date range can be at most ${MAX_SLOT_RANGE_DAYS} days.`,
      },
    };
  }
  return { ok: true, args: { p_from: from, p_to: to } };
}
