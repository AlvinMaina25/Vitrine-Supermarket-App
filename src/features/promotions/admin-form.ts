import { shillingsToCents } from "../admin/delivery-money.ts";
import type { DiscountType } from "./logic.ts";
import { isWellFormedCouponCode, normalizeCouponCode } from "./logic.ts";
import type { PromotionInput } from "./admin-parse.ts";

/**
 * Phase 15: the create-promotion form, as pure functions.
 *
 * This turns what an admin typed into the `PromotionInput` that the existing
 * admin_create_promotion() RPC already accepts. It does NOT work out any discount: the database
 * validates every value again and computes every discount at order time. Typed shillings become
 * integer cents through the same string-only converter the delivery screens use, a typed
 * percentage becomes basis points without floating point, and times are read as Africa/Nairobi
 * (UTC+3, no daylight saving) so the admin never has to think about time zones.
 */

export interface PromotionFormValues {
  name: string;
  code: string;
  discountType: DiscountType;
  /** Percentage ("10", "12.5") or shillings ("200"), depending on discountType. */
  value: string;
  /** Percentage promotions only. Shillings, optional. */
  maxDiscount: string;
  /** Shillings, optional. */
  minOrder: string;
  /** datetime-local text, "2026-10-11T08:00". Optional. */
  startsAt: string;
  expiresAt: string;
  usageLimit: string;
  perCustomerLimit: string;
  /** Create it live straight away. Off by default: a live promotion changes customer prices. */
  activateNow: boolean;
}

export type PromotionFormField = Exclude<
  keyof PromotionFormValues,
  "discountType" | "activateNow"
>;

export type PromotionFormErrors = Partial<Record<PromotionFormField, string>>;

/** Top-to-bottom order of the fields on screen, for "focus the first error". */
export const PROMOTION_FIELD_ORDER: readonly PromotionFormField[] = [
  "name",
  "code",
  "value",
  "maxDiscount",
  "minOrder",
  "startsAt",
  "expiresAt",
  "usageLimit",
  "perCustomerLimit",
];

export const EMPTY_PROMOTION_FORM: PromotionFormValues = {
  name: "",
  code: "",
  discountType: "percentage",
  value: "",
  maxDiscount: "",
  minOrder: "",
  startsAt: "",
  expiresAt: "",
  usageLimit: "",
  perCustomerLimit: "",
  activateNow: false,
};

export type PromotionFormResult =
  | { ok: true; input: PromotionInput }
  | { ok: false; errors: PromotionFormErrors };

const PERCENT = /^(\d{1,3})(?:\.(\d{1,2}))?$/;
const LOCAL_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
const WHOLE = /^\d+$/;
const MAX_INT = 2_147_483_647;

/** "12.5" -> 1250 basis points. String handling only. Null when it is not 0.01 to 100. */
export function percentToBasisPoints(text: string): number | null {
  const match = PERCENT.exec(text.trim());
  if (!match) return null;
  const whole = match[1] ?? "0";
  const fraction = (match[2] ?? "").padEnd(2, "0");
  const basisPoints = Number(whole) * 100 + Number(fraction);
  return basisPoints >= 1 && basisPoints <= 10_000 ? basisPoints : null;
}

/** Basis points back to the text an admin would type: 1250 -> "12.5", 1000 -> "10". */
export function basisPointsToPercentText(basisPoints: number): string {
  if (!Number.isInteger(basisPoints) || basisPoints < 0) return "";
  const whole = Math.floor(basisPoints / 100);
  const fraction = String(basisPoints % 100).padStart(2, "0");
  const trimmed = fraction.replace(/0+$/, "");
  return trimmed === "" ? String(whole) : `${whole}.${trimmed}`;
}

/** "2026-10-11T08:00" read as Nairobi time -> an ISO string with an explicit +03:00 offset. */
export function nairobiLocalToIso(text: string): string | null {
  const t = text.trim();
  if (!LOCAL_DATE_TIME.test(t)) return null;
  const date = new Date(`${t}:00+03:00`);
  return Number.isNaN(date.getTime()) ? null : `${t}:00+03:00`;
}

function wholeLimit(text: string, label: string): number | null | string {
  const t = text.trim();
  if (t === "") return null;
  if (!WHOLE.test(t)) return `${label} must be a whole number.`;
  const n = Number(t);
  if (n < 1) return `${label} must be at least 1.`;
  if (n > MAX_INT) return `${label} is too large.`;
  return n;
}

export function validatePromotionForm(
  values: PromotionFormValues,
): PromotionFormResult {
  const errors: PromotionFormErrors = {};
  const input: PromotionInput = {
    name: "",
    discount_type: values.discountType,
    value: 0,
    is_active: values.activateNow,
  };

  const name = values.name.trim();
  if (name === "") errors.name = "Enter a name for this promotion.";
  else input.name = name;

  const code = normalizeCouponCode(values.code);
  if (code !== null) {
    if (!isWellFormedCouponCode(code)) {
      errors.code =
        "Use 3 to 32 letters, numbers, dashes or underscores, starting with a letter or number. Leave blank for an automatic promotion.";
    } else {
      input.code = code;
    }
  }

  if (values.discountType === "percentage") {
    const basisPoints = percentToBasisPoints(values.value);
    if (basisPoints === null) {
      errors.value = "Enter a percentage from 0.01 to 100, such as 10 or 12.5.";
    } else {
      input.value = basisPoints;
    }
    const max = shillingsToCents(values.maxDiscount, "The maximum", true);
    if (!max.ok) errors.maxDiscount = max.error;
    else if (max.cents !== null) {
      if (max.cents < 1) errors.maxDiscount = "The maximum must be above zero.";
      else input.max_discount_cents = max.cents;
    }
  } else {
    const fixed = shillingsToCents(values.value, "The discount", false);
    if (!fixed.ok) errors.value = fixed.error;
    else if (fixed.cents === null || fixed.cents < 1)
      errors.value = "The discount must be above zero.";
    else input.value = fixed.cents;
  }

  const min = shillingsToCents(values.minOrder, "The minimum order", true);
  if (!min.ok) errors.minOrder = min.error;
  else if (min.cents !== null && min.cents > 0)
    input.min_order_cents = min.cents;

  let startsIso: string | null = null;
  if (values.startsAt.trim() !== "") {
    startsIso = nairobiLocalToIso(values.startsAt);
    if (startsIso === null)
      errors.startsAt = "Enter a valid start date and time.";
    else input.starts_at = startsIso;
  }
  let expiresIso: string | null = null;
  if (values.expiresAt.trim() !== "") {
    expiresIso = nairobiLocalToIso(values.expiresAt);
    if (expiresIso === null)
      errors.expiresAt = "Enter a valid end date and time.";
    else input.expires_at = expiresIso;
  }
  if (
    startsIso !== null &&
    expiresIso !== null &&
    Date.parse(expiresIso) <= Date.parse(startsIso)
  ) {
    errors.expiresAt = "The end must be after the start.";
  }

  const usage = wholeLimit(values.usageLimit, "The usage limit");
  if (typeof usage === "string") errors.usageLimit = usage;
  else if (usage !== null) input.usage_limit = usage;

  const perCustomer = wholeLimit(
    values.perCustomerLimit,
    "The per-customer limit",
  );
  if (typeof perCustomer === "string") errors.perCustomerLimit = perCustomer;
  else if (perCustomer !== null) input.per_customer_limit = perCustomer;

  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return { ok: true, input };
}

/**
 * How a promotion's value reads in a list: "10%" or the fixed amount. The caller passes the
 * money formatter, so this file stays free of app imports. A display of the stored value, not a
 * calculation.
 */
export function describePromotionValue(
  row: { discount_type: DiscountType; value: number },
  formatMoney: (cents: number) => string,
): string {
  return row.discount_type === "percentage"
    ? `${basisPointsToPercentText(row.value)}%`
    : formatMoney(row.value);
}
