import type {
  AdminDeliveryMethod,
  AdminDeliveryZone,
} from "./delivery-config-result.ts";
import type { AdminDeliveryZoneFee } from "./delivery-config-result.ts";
import { AdminAccessError } from "./dashboard-result.ts";
import {
  isAdminDeliveryError,
  type DeliveryFieldErrors,
} from "./delivery-error.ts";
import { centsToShillingsText, shillingsToCents } from "./delivery-money.ts";
import {
  MAX_CAPACITY,
  MAX_POSITION,
  MAX_SLOT_RANGE_DAYS,
  isIsoDate,
  normaliseTime,
} from "./delivery-parse.ts";
import {
  buildSaveDeliverySlotOverrideArgs,
  type DeliverySlotOverrideBuild,
} from "./delivery-slot-override-result.ts";
import {
  buildSaveDeliverySlotTemplateArgs,
  type DeliverySlotTemplateBuild,
} from "./delivery-slot-template-result.ts";
import {
  daysBetween,
  type AdminDeliverySlot,
  type AdminDeliverySlotOverride,
  type AdminDeliverySlotTemplate,
  type AdminListDeliverySlotsArgs,
} from "./delivery-slots-result.ts";
import {
  buildUpdateDeliveryMethodArgs,
  type DeliveryMethodBuild,
} from "./delivery-method-result.ts";
import {
  buildSaveDeliveryZoneFeeArgs,
  type DeliveryZoneFeeBuild,
} from "./delivery-zone-fee-result.ts";
import {
  buildSaveDeliveryZoneArgs,
  type DeliveryZoneBuild,
} from "./delivery-zone-result.ts";

/**
 * Pure UI-state helpers for the admin delivery screens (Phase 6F.2): the selected tab, the
 * selected week or date range, form drafts and the validation of whole-number cents, capacities,
 * positions, weekdays and times. No runtime imports beyond sibling pure modules, so they run
 * under `node --test`.
 *
 * Nothing here decides who may manage delivery (the database does, via require_admin()) and
 * nothing here computes money: cents are typed in as whole numbers and sent exactly as entered.
 */

// ---------------------------------------------------------------------------------------------
// Tabs and date range (the URL is the single source of truth for what is on screen)
// ---------------------------------------------------------------------------------------------

export type DeliveryTab = "methods" | "zones" | "fees" | "slots";

export const DELIVERY_TABS: readonly DeliveryTab[] = [
  "methods",
  "zones",
  "fees",
  "slots",
];

export const DEFAULT_DELIVERY_TAB: DeliveryTab = "methods";

export const DELIVERY_TAB_LABELS: Record<DeliveryTab, string> = {
  methods: "Methods",
  zones: "Zones",
  fees: "Fees",
  slots: "Slots",
};

export interface DeliveryDateRange {
  /** YYYY-MM-DD, inclusive. */
  from: string;
  /** YYYY-MM-DD, inclusive. */
  to: string;
}

export interface DeliveryParams {
  /** Omitted means the default tab. */
  tab?: DeliveryTab;
  /** Both or neither; omitted means the current week. */
  from?: string;
  to?: string;
}

/** True when `from`..`to` is a real range the slots RPC accepts (at most 31 days apart). */
export function isValidSlotRange(from: unknown, to: unknown): boolean {
  return (
    isIsoDate(from) &&
    isIsoDate(to) &&
    to >= from &&
    daysBetween(from, to) <= MAX_SLOT_RANGE_DAYS
  );
}

/** Unknown or malformed values are dropped rather than sent to the database. */
export function parseDeliveryParams(
  search: Record<string, unknown>,
): DeliveryParams {
  const params: DeliveryParams = {};
  const tab = search["tab"];
  if (tab === "zones" || tab === "fees" || tab === "slots") params.tab = tab;

  const from = search["from"];
  const to = search["to"];
  if (isIsoDate(from) && isIsoDate(to) && isValidSlotRange(from, to)) {
    params.from = from;
    params.to = to;
  }
  return params;
}

export function activeDeliveryTab(params: DeliveryParams): DeliveryTab {
  return params.tab ?? DEFAULT_DELIVERY_TAB;
}

export function withDeliveryTab(
  params: DeliveryParams,
  tab: DeliveryTab,
): DeliveryParams {
  return parseDeliveryParams({ ...params, tab });
}

export function withSlotRange(
  params: DeliveryParams,
  range: DeliveryDateRange,
): DeliveryParams {
  return parseDeliveryParams({ ...params, from: range.from, to: range.to });
}

/** Calendar arithmetic on YYYY-MM-DD strings (UTC, so no daylight-saving surprises). */
export function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Monday to Sunday around `date`. */
export function weekRange(date: string): DeliveryDateRange {
  const dow = new Date(`${date}T00:00:00Z`).getUTCDay(); // 0 = Sunday
  const monday = addDays(date, dow === 0 ? -6 : 1 - dow);
  return { from: monday, to: addDays(monday, 6) };
}

/** The range on screen. `today` (YYYY-MM-DD, Nairobi) is passed in so this stays pure. */
export function activeSlotRange(
  params: DeliveryParams,
  today: string,
): DeliveryDateRange {
  return params.from !== undefined && params.to !== undefined
    ? { from: params.from, to: params.to }
    : weekRange(today);
}

/** Previous / next block of the same length. */
export function shiftSlotRange(
  range: DeliveryDateRange,
  direction: -1 | 1,
): DeliveryDateRange {
  const length = daysBetween(range.from, range.to) + 1;
  return {
    from: addDays(range.from, direction * length),
    to: addDays(range.to, direction * length),
  };
}

/** Named arguments for admin_list_delivery_slots(), straight from the screen state. */
export function toSlotsListArgs(
  params: DeliveryParams,
  today: string,
): AdminListDeliverySlotsArgs {
  const range = activeSlotRange(params, today);
  return { p_from: range.from, p_to: range.to };
}

// ---------------------------------------------------------------------------------------------
// Whole-number input parsing (cents, capacity, position, weekday, time)
// ---------------------------------------------------------------------------------------------

export type NumberParse =
  { ok: true; value: number | null } | { ok: false; error: string };

/**
 * Digits only: no sign, decimal point, exponent, separator or unit. Blank is `null` when
 * `optional`, otherwise an error. The database re-checks every value.
 */
export function parseWholeNumberText(
  text: string,
  max: number,
  label: string,
  optional: boolean,
): NumberParse {
  const t = text.trim();
  if (t === "") {
    return optional
      ? { ok: true, value: null }
      : { ok: false, error: `${label} is required.` };
  }
  if (!/^\d+$/.test(t))
    return { ok: false, error: `${label} must be a whole number.` };
  const value = Number(t);
  if (!Number.isSafeInteger(value) || value > max) {
    return {
      ok: false,
      error: `${label} must be ${max.toLocaleString("en-US")} or less.`,
    };
  }
  return { ok: true, value };
}

/**
 * Money typed as shillings (250 or 250.50), returned as integer cents by the one shared helper in
 * delivery-money.ts. This is the only way an admin form turns an amount into cents.
 */
export function parseShillingsText(
  text: string,
  label: string,
  optional: boolean,
): NumberParse {
  const parsed = shillingsToCents(text, label, optional);
  return parsed.ok ? { ok: true, value: parsed.cents } : parsed;
}

/** True when the typed amount differs from the saved cents (an unparseable entry counts). */
function moneyChanged(text: string, savedCents: number | null): boolean {
  const parsed = shillingsToCents(text, "", true);
  return !parsed.ok || parsed.cents !== savedCents;
}

export function parseCapacityText(text: string): NumberParse {
  return parseWholeNumberText(text, MAX_CAPACITY, "The capacity", true);
}

export function parsePositionText(text: string): NumberParse {
  return parseWholeNumberText(text, MAX_POSITION, "The position", true);
}

/** "" = every day; "0" (Sunday) to "6" (Saturday). */
export function parseWeekdayText(text: string): NumberParse {
  const t = text.trim();
  if (t === "") return { ok: true, value: null };
  return /^[0-6]$/.test(t)
    ? { ok: true, value: Number(t) }
    : { ok: false, error: "Choose a weekday, or every day." };
}

export type TimeParse =
  { ok: true; value: string } | { ok: false; error: string };

/** HH:MM or HH:MM:SS (24-hour); returns HH:MM:SS. */
export function parseTimeText(text: string, label: string): TimeParse {
  const value = normaliseTime(text);
  return value === null
    ? { ok: false, error: `${label} must be a time such as 08:00 (24-hour).` }
    : { ok: true, value };
}

export const WEEKDAY_LABELS: readonly string[] = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
];

export function weekdayLabel(dayOfWeek: number | null): string {
  return dayOfWeek === null
    ? "Every day"
    : (WEEKDAY_LABELS[dayOfWeek] ?? "Every day");
}

/** HH:MM for display and for form drafts. */
export function formatTimeHm(time: string): string {
  return time.slice(0, 5);
}

/** null = unlimited, 0 = closed. Counts only, never money. */
export function describeSlotCapacity(capacity: number | null): string {
  if (capacity === null) return "Unlimited";
  return capacity === 0 ? "Closed" : String(capacity);
}

// ---------------------------------------------------------------------------------------------
// Form drafts (everything a form edits is a string until it is built into RPC arguments)
// ---------------------------------------------------------------------------------------------

function numberOrNull(parsed: NumberParse): number | null {
  return parsed.ok ? parsed.value : null;
}

/** Collects the parse failures; failed fields get a placeholder the builder then ignores. */
function collectErrors(
  parsed: Record<string, NumberParse | TimeParse>,
  keys: Record<string, keyof DeliveryFieldErrors>,
) {
  const errors: DeliveryFieldErrors = {};
  for (const [name, result] of Object.entries(parsed)) {
    const key = keys[name];
    if (!result.ok && key !== undefined) errors[key] = result.error;
  }
  return errors;
}

type Build<A> =
  { ok: true; args: A } | { ok: false; errors: DeliveryFieldErrors };

/** Parse errors win over builder errors for the same field; ok only if both are clean. */
function merge<A>(parseErrors: DeliveryFieldErrors, built: Build<A>): Build<A> {
  if (Object.keys(parseErrors).length === 0) return built;
  return {
    ok: false,
    errors: { ...(built.ok ? {} : built.errors), ...parseErrors },
  };
}

// ---- zones ----

export interface ZoneDraft {
  code: string;
  name: string;
  county: string;
  description: string;
  /** One town per line, or comma separated. */
  towns: string;
  position: string;
}

export const emptyZoneDraft = (): ZoneDraft => ({
  code: "",
  name: "",
  county: "",
  description: "",
  towns: "",
  position: "",
});

export function townsFromText(text: string): string[] {
  return text.split(/[\n,]/);
}

export function zoneDraftFromZone(zone: AdminDeliveryZone): ZoneDraft {
  return {
    code: zone.code,
    name: zone.name,
    county: zone.county ?? "",
    description: zone.description ?? "",
    towns: zone.towns.join("\n"),
    position: String(zone.position),
  };
}

/** `zoneId` null creates a zone; an id updates it (the code is then ignored). */
export function buildZoneFromDraft(
  zoneId: string | null,
  draft: ZoneDraft,
): DeliveryZoneBuild {
  const position = parsePositionText(draft.position);
  const built = buildSaveDeliveryZoneArgs({
    zoneId,
    code: draft.code,
    name: draft.name,
    county: draft.county,
    description: draft.description,
    towns: townsFromText(draft.towns),
    position: numberOrNull(position),
  });
  return merge(collectErrors({ position }, { position: "position" }), built);
}

// ---- zone fee rules ----

export interface ZoneFeeDraft {
  zoneId: string;
  methodCode: string;
  /** Shillings as typed, for example 250 or 250.50. */
  fee: string;
  /** Shillings; blank = never waived. */
  freeOver: string;
  /** Shillings; blank = 0. */
  minOrder: string;
}

export const emptyZoneFeeDraft = (
  zoneId = "",
  methodCode = "",
): ZoneFeeDraft => ({
  zoneId,
  methodCode,
  fee: "",
  freeOver: "",
  minOrder: "",
});

export function zoneFeeDraftFromFee(fee: AdminDeliveryZoneFee): ZoneFeeDraft {
  return {
    zoneId: fee.zone_id,
    methodCode: fee.method_code,
    fee: centsToShillingsText(fee.fee_cents),
    freeOver:
      fee.free_over_cents === null
        ? ""
        : centsToShillingsText(fee.free_over_cents),
    minOrder: centsToShillingsText(fee.min_order_cents),
  };
}

/** `feeId` null creates a rule; an id updates it (zone and method are then ignored). */
export function buildZoneFeeFromDraft(
  feeId: string | null,
  draft: ZoneFeeDraft,
): DeliveryZoneFeeBuild {
  const fee = parseShillingsText(draft.fee, "The fee", false);
  const freeOver = parseShillingsText(
    draft.freeOver,
    "The free-delivery threshold",
    true,
  );
  const minOrder = parseShillingsText(
    draft.minOrder,
    "The minimum order",
    true,
  );
  const built = buildSaveDeliveryZoneFeeArgs({
    feeId,
    zoneId: draft.zoneId === "" ? null : draft.zoneId,
    methodCode: draft.methodCode === "" ? null : draft.methodCode,
    feeCents: numberOrNull(fee) ?? 0,
    freeOverCents: numberOrNull(freeOver),
    minOrderCents: numberOrNull(minOrder),
  });
  return merge(
    collectErrors(
      { fee, freeOver, minOrder },
      { fee: "fee", freeOver: "freeOver", minOrder: "minOrder" },
    ),
    built,
  );
}

// ---- methods ----

export interface MethodDraft {
  /** Shillings as typed, for example 250 or 250.50. */
  baseFee: string;
  /** Shillings; blank = never waived. */
  freeOver: string;
  minOrder: string;
  isActive: boolean;
  reason: string;
}

export function methodDraftFromMethod(
  method: AdminDeliveryMethod,
): MethodDraft {
  return {
    baseFee: centsToShillingsText(method.base_fee_cents),
    freeOver:
      method.free_over_cents === null
        ? ""
        : centsToShillingsText(method.free_over_cents),
    minOrder: centsToShillingsText(method.min_order_cents),
    isActive: method.is_active,
    reason: "",
  };
}

export function buildMethodFromDraft(
  method: AdminDeliveryMethod,
  draft: MethodDraft,
): DeliveryMethodBuild {
  const baseFee = parseShillingsText(draft.baseFee, "The fee", false);
  const freeOver = parseShillingsText(
    draft.freeOver,
    "The free-delivery threshold",
    true,
  );
  const minOrder = parseShillingsText(
    draft.minOrder,
    "The minimum order",
    false,
  );
  const built = buildUpdateDeliveryMethodArgs({
    code: method.code,
    baseFeeCents: numberOrNull(baseFee) ?? 0,
    freeOverCents: numberOrNull(freeOver),
    minOrderCents: numberOrNull(minOrder) ?? 0,
    isActive: draft.isActive,
    currentIsActive: method.is_active,
    reason: draft.reason,
  });
  return merge(
    collectErrors(
      { baseFee, freeOver, minOrder },
      { baseFee: "fee", freeOver: "freeOver", minOrder: "minOrder" },
    ),
    built,
  );
}

/** True when the draft differs from the saved method (the save button's enabled state). */
export function methodDraftChanged(
  method: AdminDeliveryMethod,
  draft: MethodDraft,
): boolean {
  return (
    moneyChanged(draft.baseFee, method.base_fee_cents) ||
    moneyChanged(draft.freeOver, method.free_over_cents) ||
    moneyChanged(draft.minOrder, method.min_order_cents) ||
    draft.isActive !== method.is_active
  );
}

// ---- slot templates ----

export interface SlotTemplateDraft {
  label: string;
  startTime: string;
  endTime: string;
  /** "" = every day; "0" (Sunday) to "6". */
  dayOfWeek: string;
  /** Blank = unlimited; 0 = closed. */
  capacity: string;
  position: string;
}

export const emptySlotTemplateDraft = (): SlotTemplateDraft => ({
  label: "",
  startTime: "",
  endTime: "",
  dayOfWeek: "",
  capacity: "",
  position: "",
});

export function slotTemplateDraftFromTemplate(
  t: AdminDeliverySlotTemplate,
): SlotTemplateDraft {
  return {
    label: t.label,
    startTime: formatTimeHm(t.start_time),
    endTime: formatTimeHm(t.end_time),
    dayOfWeek: t.day_of_week === null ? "" : String(t.day_of_week),
    capacity: t.capacity === null ? "" : String(t.capacity),
    position: String(t.position),
  };
}

/** `templateId` null creates a template; an id updates it. */
export function buildSlotTemplateFromDraft(
  templateId: string | null,
  draft: SlotTemplateDraft,
): DeliverySlotTemplateBuild {
  const weekday = parseWeekdayText(draft.dayOfWeek);
  const capacity = parseCapacityText(draft.capacity);
  const position = parsePositionText(draft.position);
  const start = parseTimeText(draft.startTime, "The start time");
  const end = parseTimeText(draft.endTime, "The end time");
  const built = buildSaveDeliverySlotTemplateArgs({
    templateId,
    label: draft.label,
    startTime: draft.startTime,
    endTime: draft.endTime,
    dayOfWeek: numberOrNull(weekday),
    capacity: numberOrNull(capacity),
    position: numberOrNull(position),
  });
  const errors = collectErrors(
    { weekday, capacity, position },
    { weekday: "weekday", capacity: "capacity", position: "position" },
  );
  if (!start.ok) errors.window = start.error;
  else if (!end.ok) errors.window = end.error;
  return merge(errors, built);
}

// ---- per-date overrides ----

export interface SlotOverrideDraft {
  /** Blank = inherit the template. */
  capacity: string;
  closed: boolean;
  note: string;
}

export const emptySlotOverrideDraft = (): SlotOverrideDraft => ({
  capacity: "",
  closed: false,
  note: "",
});

/** The override on one listed slot (if it has a meaningful one) as a form draft. */
export function slotOverrideDraftFor(
  slot: AdminDeliverySlot,
  overrides: readonly AdminDeliverySlotOverride[],
): SlotOverrideDraft {
  const found = overrides.find(
    (o) => o.template_id === slot.template_id && o.slot_date === slot.slot_date,
  );
  return {
    capacity:
      slot.override_capacity === null ? "" : String(slot.override_capacity),
    closed: slot.override_closed,
    note: found?.note ?? "",
  };
}

export function buildSlotOverrideFromDraft(
  templateId: string,
  slotDate: string,
  draft: SlotOverrideDraft,
): DeliverySlotOverrideBuild {
  const capacity = parseCapacityText(draft.capacity);
  const built = buildSaveDeliverySlotOverrideArgs({
    templateId,
    slotDate,
    capacity: numberOrNull(capacity),
    closed: draft.closed,
    note: draft.note,
  });
  return merge(collectErrors({ capacity }, { capacity: "capacity" }), built);
}

// ---------------------------------------------------------------------------------------------
// Screen helpers (Phase 6F.3A): the no-zone warning and friendly action errors
// ---------------------------------------------------------------------------------------------

/**
 * The warning shown while no zone can take an address order, or null when one can. Customers can
 * only pick delivery to an address if at least one zone is active.
 */
export function noActiveZonesWarning(
  zones: readonly AdminDeliveryZone[],
): string | null {
  if (zones.some((zone) => zone.is_active)) return null;
  return zones.length === 0
    ? "Address delivery cannot be ordered until a zone exists."
    : "Address delivery cannot be ordered until a zone is active.";
}

export const DELIVERY_SAVE_FAILED =
  "That could not be saved. Please try again in a moment.";

/**
 * What to tell the admin when a delivery action fails. Database refusals and the access check
 * have their own friendly text; anything else is a generic message, never raw database text.
 */
export function describeDeliveryActionError(cause: unknown): string {
  if (cause instanceof AdminAccessError || isAdminDeliveryError(cause))
    return cause.message;
  return DELIVERY_SAVE_FAILED;
}
