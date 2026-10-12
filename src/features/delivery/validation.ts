import type {
  DeliveryFeeRule,
  DeliverySelectionErrorCode,
  DeliverySelectionValidationRow,
} from "@/lib/supabase/types";

/**
 * Result of public.validate_delivery_selection(), the database's gate for a delivery
 * choice. Nothing in this file decides anything: it only reshapes the database row into
 * a discriminated union so callers cannot read a fee off a rejected selection.
 */

export interface ValidDeliverySelection {
  ok: true;
  methodCode: string;
  methodLabel: string;
  requiresSlot: boolean;
  requiresAddress: boolean;
  zoneId: string | null;
  zoneCode: string | null;
  zoneName: string | null;
  subtotalCents: number;
  /** The authoritative fee, as calculated by resolve_delivery_fee(). */
  feeCents: number;
  baseFeeCents: number;
  freeOverCents: number | null;
  minOrderCents: number;
  feeSource: "method" | "zone";
  zoneFeeId: string | null;
  /** Exactly what orders.delivery_fee_rule should store. */
  feeRule: DeliveryFeeRule;
}

export interface RejectedDeliverySelection {
  ok: false;
  code: DeliverySelectionErrorCode;
  message: string;
  /** Only set for below_minimum_order: the minimum the customer has to reach. */
  minOrderCents: number | null;
}

export type DeliverySelectionResult =
  ValidDeliverySelection | RejectedDeliverySelection;

/**
 * Converts the single row returned by the database into a typed result. Anything that
 * does not look like a complete valid row is treated as rejected, never as free delivery.
 */
export function toDeliverySelectionResult(
  row: DeliverySelectionValidationRow | null | undefined,
): DeliverySelectionResult {
  if (!row) {
    return {
      ok: false,
      code: "unavailable",
      message: "That delivery option is not available right now.",
      minOrderCents: null,
    };
  }

  if (
    row.is_valid &&
    row.method_code !== null &&
    row.method_label !== null &&
    row.requires_slot !== null &&
    row.requires_address !== null &&
    row.fee_cents !== null &&
    row.base_fee_cents !== null &&
    row.min_order_cents !== null &&
    row.fee_source !== null &&
    row.fee_rule !== null
  ) {
    return {
      ok: true,
      methodCode: row.method_code,
      methodLabel: row.method_label,
      requiresSlot: row.requires_slot,
      requiresAddress: row.requires_address,
      zoneId: row.zone_id,
      zoneCode: row.zone_code,
      zoneName: row.zone_name,
      subtotalCents: row.subtotal_cents,
      feeCents: row.fee_cents,
      baseFeeCents: row.base_fee_cents,
      freeOverCents: row.free_over_cents,
      minOrderCents: row.min_order_cents,
      feeSource: row.fee_source,
      zoneFeeId: row.zone_fee_id,
      feeRule: row.fee_rule,
    };
  }

  return {
    ok: false,
    code: row.error_code ?? "unavailable",
    message:
      row.error_message ?? "That delivery option is not available right now.",
    minOrderCents: row.min_order_cents,
  };
}
