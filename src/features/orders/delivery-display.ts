import type {
  DeliveryFeeRule,
  OrderDeliveryColumns,
  OrderRow,
} from "@/lib/supabase/types";

/**
 * Snapshot-first delivery display for an order.
 *
 * An order keeps the delivery configuration it was placed under: the method label, the zone,
 * the slot window and the fee are all stored on the order row (create_order() writes them).
 * Everything here reads ONLY that row. It never consults the live delivery methods, zones,
 * fees or slot templates, so renaming or deactivating a method, changing a zone fee or
 * deleting a zone later cannot change how an old order reads.
 *
 * Orders placed before Phase 4 can have NULL snapshot columns. Those are shown as "not
 * recorded" (null here) rather than guessed: nothing is back-filled from today's
 * configuration, and nothing is written back to the order.
 *
 * Pure and framework-free so it can be unit tested with `node --test`. Formatting (dates,
 * money, time windows) stays with the components.
 */

/** The order fields this helper reads. Every Phase 4 snapshot column may be null on old orders. */
export type OrderDeliverySource = Pick<
  OrderRow,
  | "delivery_method"
  | "delivery_fee_cents"
  | "delivery_slot_date"
  | "delivery_slot_start"
  | "delivery_slot_end"
  | "delivery_slot_label"
> &
  Partial<OrderDeliveryColumns>;

export interface OrderDeliverySlotDisplay {
  /** "YYYY-MM-DD". */
  date: string;
  /** "HH:MM:SS"; null when the order stored a date but no complete window. */
  start: string | null;
  end: string | null;
  label: string | null;
}

export interface OrderDeliveryDisplay {
  /** The method as it was named when the order was placed. Never empty. */
  methodLabel: string;
  /** True when methodLabel is the stored method code tidied up, because no label was snapshotted. */
  methodLabelIsFallback: boolean;
  /** The zone the order was placed in; null when the order has no zone snapshot. */
  zoneName: string | null;
  /** null when the order has no delivery slot (e.g. a pickup method, or an old order). */
  slot: OrderDeliverySlotDisplay | null;
  /** The fee charged, in cents. Always the order's own stored value. */
  feeCents: number;
  isFree: boolean;
  /** Which rule priced the fee at the time, when the order recorded one. */
  feeSource: DeliveryFeeRule["source"] | null;
}

/** Trimmed text, or null when absent or blank. */
function text(value: string | null | undefined): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

/** "same_day" / "same-day" -> "Same day". Only used when no label was snapshotted. */
export function humaniseCode(code: string): string {
  const spaced = code.replace(/[_-]+/g, " ").trim();
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/** delivery_fee_rule is jsonb: accept only the known sources, ignore anything malformed. */
function feeSourceOf(rule: unknown): DeliveryFeeRule["source"] | null {
  if (typeof rule !== "object" || rule === null) return null;
  const source = (rule as { source?: unknown }).source;
  return source === "zone" || source === "method" ? source : null;
}

export function getOrderDeliveryDisplay(
  order: OrderDeliverySource,
): OrderDeliveryDisplay {
  const snapshotLabel = text(order.delivery_method_label);
  const methodCode = text(order.delivery_method);
  const methodLabel =
    snapshotLabel ?? (methodCode ? humaniseCode(methodCode) : "Delivery");

  const zoneName =
    text(order.delivery_zone_name) ?? text(order.delivery_zone_code);

  const date = text(order.delivery_slot_date);
  const start = text(order.delivery_slot_start);
  const end = text(order.delivery_slot_end);
  const slot: OrderDeliverySlotDisplay | null = date
    ? {
        date,
        // A window is only meaningful as a pair.
        start: start && end ? start : null,
        end: start && end ? end : null,
        label: text(order.delivery_slot_label),
      }
    : null;

  const feeCents = order.delivery_fee_cents;

  return {
    methodLabel,
    methodLabelIsFallback: snapshotLabel === null,
    zoneName,
    slot,
    feeCents,
    isFree: feeCents === 0,
    feeSource: feeSourceOf(order.delivery_fee_rule),
  };
}
