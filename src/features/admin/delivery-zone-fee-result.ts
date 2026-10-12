import {
  requireBoolean,
  requireRecord,
  requireString,
  unexpected,
} from "./customer-parse.ts";
import {
  parseDeliveryZoneFeeRow,
  type AdminDeliveryZoneFeeRow,
} from "./delivery-config-result.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import { MAX_CENTS, checkReason, inWholeRange } from "./delivery-parse.ts";

/**
 * Pure parsers and argument builders for admin_save_delivery_zone_fee() and
 * admin_set_delivery_zone_fee_active() (Phase 6F.1A). Admin-only on the server. Money is integer
 * cents passed through exactly as entered: the database validates, stores and applies it, and
 * nothing here converts or computes it.
 */

export interface AdminSaveDeliveryZoneFeeResult {
  changed: boolean;
  created: boolean;
  zone_fee: AdminDeliveryZoneFeeRow;
}

export function toAdminSaveDeliveryZoneFeeResult(
  data: unknown,
): AdminSaveDeliveryZoneFeeResult {
  const what = "The delivery fee rule save";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    created: requireBoolean(r, "created", what),
    zone_fee: parseDeliveryZoneFeeRow(requireRecord(r["zone_fee"], what), what),
  };
}

export interface AdminSaveDeliveryZoneFeeArgs {
  p_fee_id: string | null;
  p_zone_id: string | null;
  p_method_code: string | null;
  p_fee_cents: number;
  p_free_over_cents: number | null;
  p_min_order_cents: number | null;
}

export interface DeliveryZoneFeeInput {
  /** null creates a rule; an id updates it. */
  feeId: string | null;
  /** Required on create; ignored (sent as null) on update because the pair is fixed. */
  zoneId: string | null;
  methodCode: string | null;
  feeCents: number;
  /** null = never waived. */
  freeOverCents: number | null;
  /** null = 0. */
  minOrderCents: number | null;
}

export type DeliveryZoneFeeBuild =
  | { ok: true; args: AdminSaveDeliveryZoneFeeArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSaveDeliveryZoneFeeArgs(
  input: DeliveryZoneFeeInput,
): DeliveryZoneFeeBuild {
  const errors: DeliveryFieldErrors = {};
  const creating = input.feeId === null;
  const method = input.methodCode?.trim() ?? "";

  if (creating && (input.zoneId === null || input.zoneId === "")) {
    errors.form = "Choose a zone.";
  } else if (creating && method === "") {
    errors.form = "Choose a delivery method.";
  }
  if (!inWholeRange(input.feeCents, MAX_CENTS)) {
    errors.fee = "The fee must be a whole number of cents, zero or more.";
  }
  if (
    input.freeOverCents !== null &&
    !inWholeRange(input.freeOverCents, MAX_CENTS)
  ) {
    errors.freeOver =
      "The free-delivery threshold must be a whole number of cents, or empty.";
  }
  if (
    input.minOrderCents !== null &&
    !inWholeRange(input.minOrderCents, MAX_CENTS)
  ) {
    errors.minOrder =
      "The minimum order must be a whole number of cents, zero or more.";
  }
  if (Object.keys(errors).length > 0) return { ok: false, errors };

  return {
    ok: true,
    args: {
      p_fee_id: input.feeId,
      p_zone_id: creating ? input.zoneId : null,
      p_method_code: creating ? method : null,
      p_fee_cents: input.feeCents,
      p_free_over_cents: input.freeOverCents,
      p_min_order_cents: input.minOrderCents,
    },
  };
}

export interface AdminSetDeliveryZoneFeeActiveResult {
  changed: true;
  zone_fee_id: string;
  previous_is_active: boolean;
  is_active: boolean;
}

export function toAdminSetDeliveryZoneFeeActiveResult(
  data: unknown,
): AdminSetDeliveryZoneFeeActiveResult {
  const what = "The delivery fee rule status change";
  const r = requireRecord(data, what);
  if (!requireBoolean(r, "changed", what)) unexpected(what);
  return {
    changed: true,
    zone_fee_id: requireString(r, "zone_fee_id", what),
    previous_is_active: requireBoolean(r, "previous_is_active", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

export interface AdminSetDeliveryZoneFeeActiveArgs {
  p_fee_id: string;
  p_is_active: boolean;
  p_reason: string;
}

export type DeliveryZoneFeeActiveBuild =
  | { ok: true; args: AdminSetDeliveryZoneFeeActiveArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSetDeliveryZoneFeeActiveArgs(
  feeId: string,
  isActive: boolean,
  rawReason: string,
): DeliveryZoneFeeActiveBuild {
  const reason = checkReason(rawReason, true);
  if (reason.value === null)
    return { ok: false, errors: { reason: reason.error ?? "" } };
  return {
    ok: true,
    args: { p_fee_id: feeId, p_is_active: isActive, p_reason: reason.value },
  };
}
