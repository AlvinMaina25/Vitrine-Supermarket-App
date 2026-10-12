import type {
  DeliveryDateRange,
  DeliveryParams,
} from "./delivery-management.ts";
import { addDays } from "./delivery-management.ts";
import type {
  AdminDeliverySlot,
  AdminDeliverySlotOverride,
} from "./delivery-slots-result.ts";

/**
 * Pure helpers for the Slots tab (Phase 6F.3B): the default range, the day grouping and the
 * wording that explains the database's capacity rules. Nothing here decides what is allowed;
 * the database re-checks every value under its slot lock.
 */

/** Calendar days shown when no range is in the URL. */
export const DEFAULT_SLOT_RANGE_DAYS = 14;

const STORE_ZONE = "Africa/Nairobi";

/** Today's date in store time (YYYY-MM-DD). */
export function storeToday(now: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: STORE_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

/** Today plus the next 13 days. */
export function defaultSlotRange(today: string): DeliveryDateRange {
  return { from: today, to: addDays(today, DEFAULT_SLOT_RANGE_DAYS - 1) };
}

/** The range from the URL, else the default 14 days. */
export function resolveSlotRange(
  params: DeliveryParams,
  today: string,
): DeliveryDateRange {
  return params.from !== undefined && params.to !== undefined
    ? { from: params.from, to: params.to }
    : defaultSlotRange(today);
}

export interface SlotDay {
  date: string;
  slots: AdminDeliverySlot[];
}

/** Groups the flat slot rows by date, in date then position order. */
export function groupSlotsByDate(
  slots: readonly AdminDeliverySlot[],
): SlotDay[] {
  const days = new Map<string, AdminDeliverySlot[]>();
  for (const slot of slots) {
    const list = days.get(slot.slot_date) ?? [];
    list.push(slot);
    days.set(slot.slot_date, list);
  }
  return [...days.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([date, list]) => ({
      date,
      slots: [...list].sort(
        (a, b) =>
          a.position - b.position || a.start_time.localeCompare(b.start_time),
      ),
    }));
}

export function findSlotOverride(
  slot: AdminDeliverySlot,
  overrides: readonly AdminDeliverySlotOverride[],
): AdminDeliverySlotOverride | undefined {
  return overrides.find(
    (o) => o.template_id === slot.template_id && o.slot_date === slot.slot_date,
  );
}

/** True when the slot has a capacity, a closure or a note set for this date. */
export function slotHasOverride(
  slot: AdminDeliverySlot,
  overrides: readonly AdminDeliverySlotOverride[],
): boolean {
  if (slot.override_capacity !== null || slot.override_closed) return true;
  const found = findSlotOverride(slot, overrides);
  return found !== undefined && (found.note ?? "") !== "";
}

/** Why the override button is off, or null when the slot can be edited on that date. */
export function overrideBlockedReason(
  slot: AdminDeliverySlot,
  today: string,
): string | null {
  if (slot.slot_date < today) return "Past dates cannot be changed.";
  if (!slot.template_active)
    return "Activate this slot before changing a date.";
  return null;
}

/** "3 of 10 booked", "3 booked (unlimited)", or "Closed · 3 booked". */
export function describeBooked(slot: AdminDeliverySlot): string {
  const booked = `${slot.booked_count} booked`;
  if (slot.is_closed) return `Closed · ${booked}`;
  if (slot.effective_capacity === null) return `${booked} (unlimited)`;
  return `${slot.booked_count} of ${slot.effective_capacity} booked`;
}

/**
 * Early warning for the override dialog: the database refuses a capacity below the orders
 * already holding the slot on that date. Closing is always allowed. Null when fine.
 */
export function capacityBelowBookedWarning(
  capacity: number | null,
  closed: boolean,
  booked: number,
): string | null {
  if (closed || capacity === null || capacity >= booked) return null;
  return `${booked} order${booked === 1 ? "" : "s"} already hold this slot on this date, so the capacity cannot go below ${booked}. Close the slot to stop new bookings instead.`;
}
