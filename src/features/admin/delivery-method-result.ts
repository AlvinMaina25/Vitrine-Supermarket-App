import { requireBoolean, requireRecord } from "./customer-parse.ts";
import {
  parseDeliveryMethod,
  type AdminDeliveryMethod,
} from "./delivery-config-result.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import { MAX_CENTS, checkReason, inWholeRange } from "./delivery-parse.ts";

/**
 * Pure parser and argument builder for admin_update_delivery_method() (Phase 6F.1A). Admin-only on
 * the server. Only base fee, free-over, minimum order and the active flag can change. Money is
 * integer cents passed through exactly as entered, never computed here.
 */

export interface AdminUpdateDeliveryMethodResult {
  changed: boolean;
  method: AdminDeliveryMethod;
}

export function toAdminUpdateDeliveryMethodResult(
  data: unknown,
): AdminUpdateDeliveryMethodResult {
  const what = "The delivery method update";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    method: parseDeliveryMethod(requireRecord(r["method"], what), what),
  };
}

export interface AdminUpdateDeliveryMethodArgs {
  p_code: string;
  p_base_fee_cents: number;
  p_free_over_cents: number | null;
  p_min_order_cents: number;
  p_is_active: boolean;
  p_reason: string | null;
}

export interface DeliveryMethodInput {
  code: string;
  baseFeeCents: number;
  /** null = never waived. */
  freeOverCents: number | null;
  minOrderCents: number;
  isActive: boolean;
  /** The saved value, so the builder knows whether a reason is required. */
  currentIsActive: boolean;
  reason: string;
}

export type DeliveryMethodBuild =
  | { ok: true; args: AdminUpdateDeliveryMethodArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildUpdateDeliveryMethodArgs(
  input: DeliveryMethodInput,
): DeliveryMethodBuild {
  const errors: DeliveryFieldErrors = {};
  if (input.code.trim() === "") errors.form = "Choose a delivery method.";
  if (!inWholeRange(input.baseFeeCents, MAX_CENTS)) {
    errors.fee = "The fee must be a whole number of cents, zero or more.";
  }
  if (
    input.freeOverCents !== null &&
    !inWholeRange(input.freeOverCents, MAX_CENTS)
  ) {
    errors.freeOver =
      "The free-delivery threshold must be a whole number of cents, or empty.";
  }
  if (!inWholeRange(input.minOrderCents, MAX_CENTS)) {
    errors.minOrder =
      "The minimum order must be a whole number of cents, zero or more.";
  }
  const reason = checkReason(
    input.reason,
    input.isActive !== input.currentIsActive,
  );
  if (reason.error !== null) errors.reason = reason.error;
  if (Object.keys(errors).length > 0) return { ok: false, errors };

  return {
    ok: true,
    args: {
      p_code: input.code.trim(),
      p_base_fee_cents: input.baseFeeCents,
      p_free_over_cents: input.freeOverCents,
      p_min_order_cents: input.minOrderCents,
      p_is_active: input.isActive,
      p_reason: reason.value,
    },
  };
}
