import type {
  DeliverySlotErrorCode,
  DeliverySlotValidationRow,
} from "@/lib/supabase/types";

/**
 * Result of public.validate_delivery_slot(), the database's read-only check of a slot.
 * Nothing here decides anything: it reshapes the database row into a discriminated union so
 * callers cannot read a template id or a remaining count off a rejected slot.
 *
 * A valid result is a SNAPSHOT, not a reservation. Another customer can take the last place a
 * moment later. Capacity is only decided inside create_order(), under lock_delivery_slot().
 */

export interface ValidDeliverySlot {
  ok: true;
  slotDate: string;
  slotStart: string;
  slotEnd: string;
  templateId: string;
  label: string;
  /** Effective capacity (template, or the date override). null = unlimited. */
  capacity: number | null;
  capacitySource: "template" | "override";
  bookedCount: number;
  /** Places left. null when capacity is unlimited. */
  remaining: number | null;
  isUnlimited: boolean;
}

export interface RejectedDeliverySlot {
  ok: false;
  code: DeliverySlotErrorCode;
  message: string;
  /** True when the slot exists but cannot take orders (closed by capacity 0 or an override). */
  isClosed: boolean;
  /** True when the slot exists and every place is taken. */
  isFull: boolean;
}

export type DeliverySlotResult = ValidDeliverySlot | RejectedDeliverySlot;

const UNAVAILABLE_MESSAGE =
  "That delivery slot is not available. Pick another slot.";

/**
 * Converts the single row returned by the database into a typed result. Anything that does
 * not look like a complete valid row is treated as rejected, never as an available slot.
 */
export function toDeliverySlotResult(
  row: DeliverySlotValidationRow | null | undefined,
): DeliverySlotResult {
  if (!row) {
    return {
      ok: false,
      code: "slot_unknown",
      message: UNAVAILABLE_MESSAGE,
      isClosed: false,
      isFull: false,
    };
  }

  if (
    row.is_valid &&
    row.slot_date !== null &&
    row.slot_start !== null &&
    row.slot_end !== null &&
    row.template_id !== null &&
    row.label !== null &&
    row.capacity_source !== null &&
    row.booked_count !== null &&
    row.is_unlimited !== null &&
    row.is_closed === false &&
    row.is_full === false &&
    // Unlimited slots have no capacity/remaining; capped slots must report both.
    (row.is_unlimited
      ? row.capacity === null && row.remaining === null
      : row.capacity !== null && row.remaining !== null && row.remaining > 0)
  ) {
    return {
      ok: true,
      slotDate: row.slot_date,
      slotStart: row.slot_start,
      slotEnd: row.slot_end,
      templateId: row.template_id,
      label: row.label,
      capacity: row.capacity,
      capacitySource: row.capacity_source,
      bookedCount: row.booked_count,
      remaining: row.remaining,
      isUnlimited: row.is_unlimited,
    };
  }

  return {
    ok: false,
    code: row.error_code ?? "slot_unknown",
    message: row.error_message ?? UNAVAILABLE_MESSAGE,
    isClosed: row.is_closed === true,
    isFull: row.is_full === true,
  };
}
