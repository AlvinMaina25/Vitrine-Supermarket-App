import { queryOptions } from "@tanstack/react-query";

import { formatTimeWindow, STORE_TIME_ZONE } from "@/lib/format";
import { requireSupabase } from "@/lib/supabase/client";
import type {
  DeliverySelectionValidationRow,
  DeliveryFeeResolutionRow,
  DeliveryMethodRow,
  DeliverySlotAvailabilityRow,
  DeliverySlotTemplateRow,
  DeliverySlotValidationRow,
  DeliveryZoneFeeRow,
  DeliveryZoneRow,
} from "@/lib/supabase/types";

import { dedupeSlotWindows, type DeliveryQuoteRequest } from "./checkout";
import {
  toDeliverySlotResult,
  type DeliverySlotResult,
} from "./slot-validation";
import {
  toDeliverySelectionResult,
  type DeliverySelectionResult,
} from "./validation";

/**
 * Delivery foundation.
 *
 * Methods and slot windows are configuration rows, not hard-coded constants,
 * so zones, towns, distance pricing and capacity can be layered on later
 * without touching checkout or the orders schema.
 *
 * Nothing here is authoritative: create_order() re-validates the method, the
 * slot window and the fee in the database.
 */

export const METHOD_COLUMNS =
  "code, label, description, base_fee_cents, free_over_cents, min_order_cents, requires_slot, requires_address, eta_label, position, is_active, created_at, updated_at";

export const SLOT_COLUMNS =
  "id, label, start_time, end_time, day_of_week, capacity, position, is_active, created_at, updated_at";

export const deliveryMethodsQuery = () =>
  queryOptions({
    queryKey: ["delivery", "methods"],
    queryFn: async (): Promise<DeliveryMethodRow[]> => {
      const { data, error } = await requireSupabase()
        .from("delivery_methods")
        .select(METHOD_COLUMNS)
        .eq("is_active", true)
        .order("position", { ascending: true });
      if (error) throw new Error(error.message);
      return (data ?? []) as DeliveryMethodRow[];
    },
  });

export const slotTemplatesQuery = () =>
  queryOptions({
    queryKey: ["delivery", "slot-templates"],
    queryFn: async (): Promise<DeliverySlotTemplateRow[]> => {
      const { data, error } = await requireSupabase()
        .from("delivery_slot_templates")
        .select(SLOT_COLUMNS)
        .eq("is_active", true)
        .order("position", { ascending: true });
      if (error) throw new Error(error.message);
      return (data ?? []) as DeliverySlotTemplateRow[];
    },
  });

export const ZONE_COLUMNS =
  "id, code, name, description, county, towns, position, is_active, created_at, updated_at";

export const ZONE_FEE_COLUMNS =
  "id, zone_id, method_code, fee_cents, free_over_cents, min_order_cents, is_active, created_at, updated_at";

/** Active delivery zones. RLS hides inactive ones from everyone except staff. */
export const deliveryZonesQuery = () =>
  queryOptions({
    queryKey: ["delivery", "zones"],
    queryFn: async (): Promise<DeliveryZoneRow[]> => {
      const { data, error } = await requireSupabase()
        .from("delivery_zones")
        .select(ZONE_COLUMNS)
        .eq("is_active", true)
        .order("position", { ascending: true })
        .order("name", { ascending: true });
      if (error) throw new Error(error.message);
      return (data ?? []) as DeliveryZoneRow[];
    },
  });

/** Active zone fee rules (for zones and methods that are themselves active). */
export const deliveryZoneFeesQuery = () =>
  queryOptions({
    queryKey: ["delivery", "zone-fees"],
    queryFn: async (): Promise<DeliveryZoneFeeRow[]> => {
      const { data, error } = await requireSupabase()
        .from("delivery_zone_fees")
        .select(ZONE_FEE_COLUMNS)
        .eq("is_active", true);
      if (error) throw new Error(error.message);
      return (data ?? []) as DeliveryZoneFeeRow[];
    },
  });

/**
 * Slot windows for a date range (31 days at most) with their capacity and how many
 * orders already hold each one. A snapshot for display: create_order() re-checks capacity
 * under lock_delivery_slot() and is the only thing that can stop overbooking.
 */
export const slotAvailabilityQuery = (fromDate: string, toDate: string) =>
  queryOptions({
    queryKey: ["delivery", "availability", fromDate, toDate],
    queryFn: async (): Promise<DeliverySlotAvailabilityRow[]> => {
      const { data, error } = await requireSupabase().rpc(
        "get_delivery_slot_availability",
        {
          p_from: fromDate,
          p_to: toDate,
        },
      );
      if (error) throw new Error(error.message);
      return (data ?? []) as DeliverySlotAvailabilityRow[];
    },
  });

/**
 * Quotes the fee rule for a method (and optionally a zone) at a given subtotal.
 * Returns null when the method or zone is not available. A quote for display only:
 * the order itself must recompute the fee in the database.
 */
export async function quoteDeliveryFee(input: {
  methodCode: string;
  zoneId: string | null;
  subtotalCents: number;
}): Promise<DeliveryFeeResolutionRow | null> {
  const { data, error } = await requireSupabase().rpc("resolve_delivery_fee", {
    p_method_code: input.methodCode,
    p_zone_id: input.zoneId,
    p_subtotal_cents: input.subtotalCents,
  });
  if (error) throw new Error(error.message);
  return ((data ?? []) as DeliveryFeeResolutionRow[])[0] ?? null;
}

/**
 * Asks the database whether a method + zone + subtotal is an acceptable delivery choice
 * and, if so, what it costs. This is the same function create_order() will call, so a
 * "valid" answer here is what the order will use. There is deliberately no argument for a
 * fee: whatever the client thinks the fee is plays no part.
 *
 * Throws only on transport/database errors. A rejected selection is a normal result.
 */
export async function validateDeliverySelection(input: {
  methodCode: string;
  zoneId: string | null;
  subtotalCents: number;
}): Promise<DeliverySelectionResult> {
  const { data, error } = await requireSupabase().rpc(
    "validate_delivery_selection",
    {
      p_method_code: input.methodCode,
      p_zone_id: input.zoneId,
      p_subtotal_cents: input.subtotalCents,
    },
  );
  if (error) throw new Error(error.message);
  return toDeliverySelectionResult(
    ((data ?? []) as DeliverySelectionValidationRow[])[0],
  );
}

/**
 * The delivery quote checkout displays and sends as expectedTotalCents. It is
 * validateDeliverySelection() (-> resolve_delivery_fee()) behind a query key made of the
 * inputs, so it re-asks whenever the method, zone or subtotal changes. Disabled while a
 * question cannot be asked yet (no method, or address delivery without a zone).
 *
 * Nothing is calculated here: the fee in the result is the database's.
 */
export const deliveryQuoteQuery = (request: DeliveryQuoteRequest | null) =>
  queryOptions({
    queryKey: [
      "delivery",
      "quote",
      request?.methodCode ?? null,
      request?.zoneId ?? null,
      request?.subtotalCents ?? null,
    ],
    enabled: request !== null,
    queryFn: (): Promise<DeliverySelectionResult> => {
      if (!request) throw new Error("No delivery quote was requested.");
      return validateDeliverySelection(request);
    },
  });

/**
 * Asks the database whether a slot (date + window) can take an order right now. Read-only and
 * lock-free: a valid answer is a snapshot, NOT a reservation. create_order() re-checks under
 * lock_delivery_slot() (Phase 4C), which is the only check that can prevent overbooking.
 *
 * Throws only on transport/database errors. A rejected slot is a normal result.
 */
export async function validateDeliverySlot(input: {
  slotDate: string;
  slotStart: string;
  slotEnd: string;
}): Promise<DeliverySlotResult> {
  const { data, error } = await requireSupabase().rpc(
    "validate_delivery_slot",
    {
      p_slot_date: input.slotDate,
      p_slot_start: input.slotStart,
      p_slot_end: input.slotEnd,
    },
  );
  if (error) throw new Error(error.message);
  return toDeliverySlotResult(((data ?? []) as DeliverySlotValidationRow[])[0]);
}

/**
 * A slot must start at least this long from now. Mirrors the lead time in
 * create_order(); the database is the one that enforces it.
 */
export const SLOT_LEAD_MINUTES = 60;

/** Days after today that are offered in the picker. The database allows up to 14. */
export const SLOT_DAYS_AHEAD = 3;

export interface DeliverySlotOption {
  id: string;
  /** ISO calendar date, the value stored on the order. */
  date: string;
  /** Postgres time, e.g. "08:00:00". */
  startTime: string;
  endTime: string;
  /** Template name, e.g. "Morning". */
  templateLabel: string;
  dayLabel: string;
  windowLabel: string;
  label: string;
}

interface StoreClock {
  year: number;
  month: number;
  day: number;
  minutesIntoDay: number;
}

/** The current wall-clock date and time in the store's time zone. */
function storeClock(now: Date): StoreClock {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: STORE_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);

  const read = (type: Intl.DateTimeFormatPartTypes): number =>
    Number(parts.find((part) => part.type === type)?.value ?? "0");

  return {
    year: read("year"),
    month: read("month"),
    day: read("day"),
    minutesIntoDay: read("hour") * 60 + read("minute"),
  };
}

function minutesOf(time: string): number {
  const [hours, minutes] = time.split(":");
  return Number(hours ?? "0") * 60 + Number(minutes ?? "0");
}

const dayFormatter = new Intl.DateTimeFormat("en-KE", {
  weekday: "short",
  day: "numeric",
  month: "short",
  timeZone: "UTC",
});

/**
 * Expands slot templates over today and the next few days, in store time.
 * Windows that start sooner than the lead time are left out.
 *
 * Capacity is not consumed anywhere yet, so this never claims a window is
 * "full" or "filling up".
 */
export function buildSlotOptions(
  templates: DeliverySlotTemplateRow[],
  daysAhead = SLOT_DAYS_AHEAD,
  now = new Date(),
): DeliverySlotOption[] {
  const clock = storeClock(now);
  const options: DeliverySlotOption[] = [];
  // The database picks the lowest (position, id) template when windows are duplicated.
  const ordered = [...templates].sort(
    (a, b) =>
      a.position - b.position || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );

  for (let offset = 0; offset <= daysAhead; offset++) {
    // Date.UTC normalises overflowing days/months, and UTC avoids DST shifts.
    const day = new Date(
      Date.UTC(clock.year, clock.month - 1, clock.day + offset),
    );
    const date = day.toISOString().slice(0, 10);
    const weekday = day.getUTCDay();

    for (const template of ordered) {
      if (template.day_of_week !== null && template.day_of_week !== weekday)
        continue;
      if (
        offset === 0 &&
        minutesOf(template.start_time) <
          clock.minutesIntoDay + SLOT_LEAD_MINUTES
      ) {
        continue;
      }

      const dayLabel = dayFormatter.format(day);
      const windowLabel = formatTimeWindow(
        template.start_time,
        template.end_time,
      );
      options.push({
        id: `${date}_${template.id}`,
        date,
        startTime: template.start_time,
        endTime: template.end_time,
        templateLabel: template.label,
        dayLabel,
        windowLabel,
        label: `${dayLabel}, ${windowLabel}`,
      });
    }
  }

  return dedupeSlotWindows(options);
}
