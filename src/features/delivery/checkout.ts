import type {
  DeliverySelectionErrorCode,
  DeliverySlotAvailabilityRow,
  DeliverySlotErrorCode,
} from "@/lib/supabase/types";

import type {
  DeliverySelectionResult,
  ValidDeliverySelection,
} from "./validation";

/**
 * Pure helpers for the delivery part of checkout. Nothing here prices, validates or reserves
 * anything: the fee comes from validate_delivery_selection() (-> resolve_delivery_fee()), slot
 * capacity comes from get_delivery_slot_availability(), and create_order() re-checks both under
 * lock_delivery_slot(). These helpers only decide what to ask the database and how to present
 * and select from what it answered, so they can be unit tested without a browser or database.
 *
 * Runtime imports are deliberately avoided (types only) so the node test runner can load this
 * file directly.
 */

// ---------------------------------------------------------------------------------------------
// Delivery error codes -> customer-facing messages
// ---------------------------------------------------------------------------------------------

/** Every machine-readable code the delivery functions can put in an exception DETAIL. */
export type DeliveryErrorCode =
  DeliverySelectionErrorCode | DeliverySlotErrorCode;

export interface DeliveryErrorContext {
  /** Already formatted minimum order (e.g. "KES 1,500.00"), used by below_minimum_order. */
  minOrderLabel?: string | null | undefined;
}

/**
 * Typed as a Record so adding a code to the database types without a message here is a
 * compile error. These strings are shown to customers: no SQL, no identifiers.
 */
const DELIVERY_ERROR_MESSAGES: Record<DeliveryErrorCode, string> = {
  invalid_subtotal:
    "We couldn't price your basket. Refresh the page and try again.",
  method_required: "Choose a delivery method to continue.",
  method_unknown: "That delivery method isn't available. Choose another one.",
  method_inactive:
    "That delivery method isn't available right now. Choose another one.",
  zone_required: "Choose your delivery area to continue.",
  zone_unknown: "We couldn't find that delivery area. Choose another one.",
  zone_inactive:
    "We don't deliver to that area right now. Choose another area.",
  below_minimum_order:
    "Your basket is below the minimum order for this delivery option.",
  unavailable:
    "That delivery option isn't available right now. Try another option or area.",
  slot_required: "Choose a delivery slot to continue.",
  invalid_window: "That delivery slot isn't valid. Choose another slot.",
  slot_in_past: "That delivery slot is too soon to book. Choose a later slot.",
  slot_too_far:
    "That delivery slot is too far ahead to book. Choose an earlier day.",
  slot_unknown: "That delivery slot doesn't exist. Choose another slot.",
  slot_inactive:
    "That delivery slot is no longer offered. Choose another slot.",
  slot_closed: "That delivery slot is closed. Choose another slot.",
  slot_full: "That delivery slot has just filled up. Choose another slot.",
};

export function isDeliveryErrorCode(
  value: unknown,
): value is DeliveryErrorCode {
  return (
    typeof value === "string" && Object.hasOwn(DELIVERY_ERROR_MESSAGES, value)
  );
}

/** The customer-facing message for a delivery error code. */
export function deliveryErrorMessage(
  code: DeliveryErrorCode,
  context: DeliveryErrorContext = {},
): string {
  if (code === "below_minimum_order" && context.minOrderLabel) {
    return `Delivery needs an order of at least ${context.minOrderLabel}. Add more items to continue.`;
  }
  return DELIVERY_ERROR_MESSAGES[code];
}

export type DeliveryErrorScope = "method" | "zone" | "slot" | "order";

/** Which part of checkout a delivery error is about, so that part can be reset. */
export function deliveryErrorScope(
  code: DeliveryErrorCode,
): DeliveryErrorScope {
  switch (code) {
    case "method_required":
    case "method_unknown":
    case "method_inactive":
      return "method";
    case "zone_required":
    case "zone_unknown":
    case "zone_inactive":
      return "zone";
    case "slot_required":
    case "invalid_window":
    case "slot_in_past":
    case "slot_too_far":
    case "slot_unknown":
    case "slot_inactive":
    case "slot_closed":
    case "slot_full":
      return "slot";
    case "invalid_subtotal":
    case "below_minimum_order":
    case "unavailable":
      return "order";
  }
}

// ---------------------------------------------------------------------------------------------
// Delivery zones (explicit customer selection; no address -> zone mapping)
// ---------------------------------------------------------------------------------------------

export interface ZoneLike {
  id: string;
  is_active: boolean;
}

/** Only active zones can be chosen. The query and RLS already filter; this is a second guard. */
export function selectableZones<T extends ZoneLike>(
  zones: readonly T[] | undefined,
): T[] {
  return (zones ?? []).filter((zone) => zone.is_active);
}

export type ZoneRequirement = "not_required" | "no_zones" | "choose";

/**
 * not_required: the method has no address, so no zone UI and no zone is sent.
 * no_zones:     address delivery was requested but no zone is active (delivery is unavailable).
 * choose:       the customer has to pick one of the zones.
 */
export function zoneRequirement(
  requiresAddress: boolean,
  zones: readonly ZoneLike[] | undefined,
): ZoneRequirement {
  if (!requiresAddress) return "not_required";
  return selectableZones(zones).length === 0 ? "no_zones" : "choose";
}

/**
 * The zone id to send. null for methods without an address (any stale selection is ignored)
 * and for a selection that is not (or no longer) an active zone.
 */
export function resolveZoneId(input: {
  requiresAddress: boolean;
  zones: readonly ZoneLike[] | undefined;
  selectedZoneId: string | null;
}): string | null {
  if (!input.requiresAddress || input.selectedZoneId === null) return null;
  const match = selectableZones(input.zones).find(
    (zone) => zone.id === input.selectedZoneId,
  );
  return match ? match.id : null;
}

// ---------------------------------------------------------------------------------------------
// Authoritative delivery quote
// ---------------------------------------------------------------------------------------------

export interface DeliveryQuoteRequest {
  methodCode: string;
  zoneId: string | null;
  subtotalCents: number;
}

/**
 * What to ask validate_delivery_selection(), or null when a question cannot be asked yet
 * (no method, or address delivery without a zone). There is no fee here, only inputs.
 */
export function buildQuoteRequest(input: {
  method: { code: string; requires_address: boolean } | null | undefined;
  zoneId: string | null;
  subtotalCents: number;
}): DeliveryQuoteRequest | null {
  const { method } = input;
  if (!method || !Number.isSafeInteger(input.subtotalCents)) return null;
  if (method.requires_address && input.zoneId === null) return null;
  return {
    methodCode: method.code,
    zoneId: method.requires_address ? input.zoneId : null,
    subtotalCents: input.subtotalCents,
  };
}

export type DeliveryQuoteState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "error"; error: unknown }
  | {
      status: "rejected";
      code: DeliverySelectionErrorCode;
      message: string;
      minOrderCents: number | null;
    }
  | {
      status: "ready";
      quote: ValidDeliverySelection;
      /** Copied from the database quote, never computed here. */
      feeCents: number;
      /** subtotal + the database fee: what expectedTotalCents must be. */
      totalCents: number;
    };

/**
 * Turns the query state into one discriminated value. A result that was answered for a
 * different method, zone or subtotal than the one now requested is treated as still loading,
 * so a stale quote can never feed expectedTotalCents.
 */
export function deriveQuoteState(input: {
  request: DeliveryQuoteRequest | null;
  isPending: boolean;
  error: unknown;
  result: DeliverySelectionResult | undefined;
}): DeliveryQuoteState {
  const { request, result } = input;
  if (request === null) return { status: "idle" };
  if (input.error) return { status: "error", error: input.error };
  if (input.isPending || !result) return { status: "loading" };

  if (!result.ok) {
    return {
      status: "rejected",
      code: result.code,
      message: result.message,
      minOrderCents: result.minOrderCents,
    };
  }

  const matches =
    result.methodCode === request.methodCode &&
    result.zoneId === request.zoneId &&
    result.subtotalCents === request.subtotalCents;
  if (!matches) return { status: "loading" };

  return {
    status: "ready",
    quote: result,
    feeCents: result.feeCents,
    totalCents: request.subtotalCents + result.feeCents,
  };
}

/** The reason a quote blocks checkout, or null when it is ready (or not applicable yet). */
export function quoteBlockerMessage(
  state: DeliveryQuoteState,
  context: DeliveryErrorContext = {},
): string | null {
  switch (state.status) {
    case "idle":
    case "ready":
      return null;
    case "loading":
      return "Confirming your delivery fee…";
    case "error":
      return "We couldn't confirm the delivery fee. Please try again.";
    case "rejected":
      return deliveryErrorMessage(state.code, {
        minOrderLabel: context.minOrderLabel ?? null,
      });
  }
}

// ---------------------------------------------------------------------------------------------
// Delivery slots
// ---------------------------------------------------------------------------------------------

/** The part of a slot option these helpers need; callers keep their own extra fields. */
export interface SlotWindow {
  id: string;
  date: string;
  startTime: string;
  endTime: string;
}

/**
 * available: can take an order right now (a snapshot, not a reservation).
 * full:      capacity is used up. Shown, but not selectable.
 * closed:    capacity 0, closed for that date, or not offered. Not shown, not selectable.
 */
export type SlotStatus = "available" | "full" | "closed";

export type SlotChoice<T extends SlotWindow> = T & {
  status: SlotStatus;
  /** Places left; null when unlimited or when the slot is not offered. */
  remaining: number | null;
};

/** Postgres returns "08:00:00"; accept "08:00" too so the two always compare equal. */
function normalizeTime(time: string): string {
  return time.length === 5 ? `${time}:00` : time;
}

function windowKey(date: string, start: string, end: string): string {
  return `${date}|${normalizeTime(start)}|${normalizeTime(end)}`;
}

/**
 * Several active templates can share a window (a generic one plus a lower-position
 * weekday-specific one). The database always books against the lowest (position, id) match, so
 * the customer must be offered that window once. Keeps the first option per date and window;
 * callers pass options built from templates already ordered by (position, id).
 */
export function dedupeSlotWindows<T extends SlotWindow>(
  options: readonly T[],
): T[] {
  const seen = new Set<string>();
  const result: T[] = [];
  for (const option of options) {
    const key = windowKey(option.date, option.startTime, option.endTime);
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(option);
  }
  return result;
}

/**
 * Joins the slot windows the checkout expanded from templates (which already apply the lead
 * time) with the database's availability rows. Capacity is read from the rows, never worked
 * out here. A window with no row is closed (an override closed it, or it is not offered), and
 * with no rows loaded at all nothing is offered.
 */
export function buildSlotChoices<T extends SlotWindow>(
  options: readonly T[],
  rows: readonly DeliverySlotAvailabilityRow[] | undefined,
): SlotChoice<T>[] {
  if (!rows) return [];

  // The database lists the template checkout will use first (lowest position); it also no
  // longer lists shadowed duplicates, but keeping the FIRST row per window means an older
  // response could never make a shadowed template's capacity win.
  const byWindow = new Map<string, DeliverySlotAvailabilityRow>();
  for (const row of rows) {
    const key = windowKey(row.slot_date, row.start_time, row.end_time);
    if (!byWindow.has(key)) byWindow.set(key, row);
  }

  return options.map((option) => {
    const row = byWindow.get(
      windowKey(option.date, option.startTime, option.endTime),
    );
    if (!row) return { ...option, status: "closed", remaining: null };
    if (row.capacity === 0)
      return { ...option, status: "closed", remaining: 0 };
    if (!row.is_available || (row.remaining !== null && row.remaining <= 0)) {
      return { ...option, status: "full", remaining: 0 };
    }
    return { ...option, status: "available", remaining: row.remaining };
  });
}

export function isSlotSelectable(choice: { status: SlotStatus }): boolean {
  return choice.status === "available";
}

/** Closed windows are hidden; full ones stay visible so the customer sees why they are gone. */
export function visibleSlotChoices<T extends SlotWindow>(
  choices: readonly SlotChoice<T>[],
): SlotChoice<T>[] {
  return choices.filter((choice) => choice.status !== "closed");
}

/**
 * Revalidates the customer's pick against the latest choices. A pick that is gone, full or
 * closed resolves to no slot, and `invalid` says a pick existed so the UI can explain.
 */
export function resolveSelectedSlot<T extends SlotWindow>(
  choices: readonly SlotChoice<T>[],
  selectedId: string | null,
): { slot: SlotChoice<T> | null; invalid: boolean } {
  if (selectedId === null) return { slot: null, invalid: false };
  const match = choices.find((choice) => choice.id === selectedId);
  if (match && isSlotSelectable(match)) return { slot: match, invalid: false };
  return { slot: null, invalid: true };
}

/** First and last date to ask availability for (inclusive), or null when there are no windows. */
export function slotDateRange(
  options: readonly { date: string }[],
): { from: string; to: string } | null {
  const first = options[0];
  const last = options[options.length - 1];
  if (!first || !last) return null;
  return { from: first.date, to: last.date };
}
