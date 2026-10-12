/**
 * Phase 8 discount logic. PURE: no framework, no network, no database client, no clock of its own
 * (time is always passed in), so every function here is unit tested without a server.
 *
 * The database is the authority. `resolve_promotion()` / `create_order()` (migration
 * 20261009010000_phase8_discounts_promotions.sql) decide and record every discount. This file:
 *   - normalises a typed coupon code the same way the database does,
 *   - turns the database's replies into typed values and SAFE customer messages,
 *   - checks that a reply is internally consistent before the UI shows it,
 *   - holds a reference implementation of the rules (`evaluatePromotion`) whose test vectors are the
 *     same cases as db/tests/phase8_discounts_promotions.test.sql, so the two cannot drift silently.
 * Nothing here ever produces an amount that is sent to the server: the client sends a code only.
 */

// ---- Rules shared with the database --------------------------------------------------------------

/**
 * Delivery is NOT discountable. The database decides this in ONE function,
 * `coupon_eligible_base_cents()`; this constant must match it (a unit test pins the behaviour).
 * Changing it here changes display logic only, never what is charged.
 */
export const DELIVERY_DISCOUNTABLE = false;

/** The only errors that ever leave the database for a coupon. Nothing else is revealed. */
export const COUPON_ERROR_CODES = [
  "invalid",
  "not_started",
  "expired",
  "min_not_met",
  "limit_reached",
  "already_used",
] as const;
export type CouponErrorCode = (typeof COUPON_ERROR_CODES)[number];

export type DiscountType = "percentage" | "fixed";

/** Same pattern as promotions_code_format (codes are stored upper-case). */
export const COUPON_CODE_PATTERN = /^[A-Z0-9][A-Z0-9_-]{2,31}$/;

export function isCouponErrorCode(value: unknown): value is CouponErrorCode {
  return (
    typeof value === "string" &&
    (COUPON_ERROR_CODES as readonly string[]).includes(value)
  );
}

/** Trim + upper-case, exactly as the database does. Empty / non-string input is "no code". */
export function normalizeCouponCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const code = raw.trim().toUpperCase();
  return code === "" ? null : code;
}

export function isWellFormedCouponCode(code: string): boolean {
  return COUPON_CODE_PATTERN.test(code);
}

/** What a discount may apply to. Mirrors coupon_eligible_base_cents(). */
export function eligibleBaseCents(
  subtotalCents: number,
  deliveryFeeCents: number,
): number {
  const base = DELIVERY_DISCOUNTABLE
    ? subtotalCents + deliveryFeeCents
    : subtotalCents;
  return Math.max(0, base);
}

export interface DiscountRule {
  discountType: DiscountType;
  /** percentage: basis points (1..10000). fixed: cents. */
  value: number;
  maxDiscountCents: number | null;
}

/** Mirrors compute_promotion_discount(): floor, optional cap, never above the base, never below 0. */
export function computeDiscountCents(
  rule: DiscountRule,
  eligibleCents: number,
): number {
  if (!Number.isInteger(eligibleCents) || eligibleCents <= 0) return 0;
  if (!Number.isInteger(rule.value) || rule.value <= 0) return 0;
  let amount: number;
  if (rule.discountType === "percentage") {
    amount = Math.floor((eligibleCents * rule.value) / 10000);
    if (rule.maxDiscountCents !== null)
      amount = Math.min(amount, rule.maxDiscountCents);
  } else if (rule.discountType === "fixed") {
    amount = rule.value;
  } else {
    return 0;
  }
  return Math.max(0, Math.min(amount, eligibleCents));
}

export interface PromotionRule extends DiscountRule {
  isActive: boolean;
  minOrderCents: number;
  startsAtMs: number | null;
  expiresAtMs: number | null;
  usageLimit: number | null;
  perCustomerLimit: number | null;
}

export interface UsageCounts {
  /** Unreleased redemptions of this promotion, all customers. */
  total: number;
  /** Unreleased redemptions of this promotion by the customer. */
  byCustomer: number;
}

export type Evaluation =
  { ok: true; discountCents: number } | { ok: false; error: CouponErrorCode };

/**
 * Reference implementation of promotion_evaluate(): same checks, same order, same codes.
 * `nowMs` is injected. An inactive promotion is reported as "invalid" so that an inactive code is
 * indistinguishable from one that does not exist.
 */
export function evaluatePromotion(
  rule: PromotionRule,
  context: {
    nowMs: number;
    subtotalCents: number;
    deliveryFeeCents: number;
    usage: UsageCounts;
  },
): Evaluation {
  const fail = (error: CouponErrorCode): Evaluation => ({ ok: false, error });
  if (!rule.isActive) return fail("invalid");
  if (rule.startsAtMs !== null && context.nowMs < rule.startsAtMs)
    return fail("not_started");
  if (rule.expiresAtMs !== null && context.nowMs >= rule.expiresAtMs)
    return fail("expired");

  const base = eligibleBaseCents(
    context.subtotalCents,
    context.deliveryFeeCents,
  );
  if (base < rule.minOrderCents) return fail("min_not_met");
  if (rule.usageLimit !== null && context.usage.total >= rule.usageLimit)
    return fail("limit_reached");
  if (
    rule.perCustomerLimit !== null &&
    context.usage.byCustomer >= rule.perCustomerLimit
  ) {
    return fail("already_used");
  }

  const discountCents = computeDiscountCents(rule, base);
  return discountCents > 0 ? { ok: true, discountCents } : fail("invalid");
}

// ---- Customer-facing messages -----------------------------------------------------------------------

const COUPON_MESSAGES: Record<CouponErrorCode, string> = {
  invalid: "That coupon code isn't valid.",
  not_started: "This coupon isn't active yet.",
  expired: "This coupon has expired.",
  min_not_met: "Your basket doesn't reach the minimum spend for this coupon.",
  limit_reached: "This coupon is no longer available.",
  already_used: "You've already used this coupon.",
};

/** One safe, specific sentence per code. Never includes a code, a limit or an amount. */
export function couponErrorMessage(code: CouponErrorCode): string {
  return COUPON_MESSAGES[code];
}

/**
 * Reads the coupon error code out of a create_order() exception DETAIL (`coupon_expired` ->
 * `expired`). Anything else (including `coupon_reactivation_limit_reached`, which is an admin path)
 * is not a customer coupon error and returns null.
 */
export function couponErrorFromDetail(detail: unknown): CouponErrorCode | null {
  if (typeof detail !== "string") return null;
  const match = /^coupon_([a-z_]+)$/.exec(detail.trim());
  const candidate = match?.[1];
  return candidate !== undefined && isCouponErrorCode(candidate)
    ? candidate
    : null;
}

// ---- Parsing validate_coupon() --------------------------------------------------------------------------

export type CouponPreview =
  | { status: "none"; subtotalCents: number; totals: PayableTotals }
  | {
      status: "applied";
      /** NULL for an automatic promotion. */
      code: string | null;
      name: string;
      discountType: DiscountType;
      discountValue: number;
      discountCents: number;
      subtotalCents: number;
      eligibleCents: number;
      totals: PayableTotals;
    }
  | { status: "rejected"; error: CouponErrorCode };

/**
 * The database's own delivery fee and final payable total (subtotal + delivery - discount), exactly
 * as create_order() will charge them. BOTH are null when the preview was asked without a delivery
 * selection, or the selection was not accepted: the total is then unknown, never guessed here.
 */
export interface PayableTotals {
  deliveryFeeCents: number | null;
  totalCents: number | null;
}

const NO_TOTALS: PayableTotals = { deliveryFeeCents: null, totalCents: null };

function parsePayableTotals(data: Record<string, unknown>): PayableTotals {
  const fee = data["delivery_fee_cents"];
  const total = data["total_cents"];
  if (fee === undefined && total === undefined) return NO_TOTALS;
  if (!isCents(fee) || !isCents(total)) {
    throw new Error("Unexpected coupon response.");
  }
  return { deliveryFeeCents: fee, totalCents: total };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isCents(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

/**
 * Parses and sanity-checks the jsonb validate_coupon() returns. A reply that breaks an invariant
 * (discount above the eligible base, eligible above the subtotal, unknown type) throws: the UI must
 * never show an amount the rules say is impossible. An unknown error string becomes "invalid" so
 * nothing the server did not mean to say is ever shown.
 */
export function parseCouponPreview(data: unknown): CouponPreview {
  if (!isRecord(data) || typeof data["ok"] !== "boolean") {
    throw new Error("Unexpected coupon response.");
  }
  if (data["ok"] === false) {
    return {
      status: "rejected",
      error: isCouponErrorCode(data["error"]) ? data["error"] : "invalid",
    };
  }

  const subtotalCents = data["subtotal_cents"];
  if (!isCents(subtotalCents)) throw new Error("Unexpected coupon response.");
  const totals = parsePayableTotals(data);
  if (data["applied"] !== true) {
    return { status: "none", subtotalCents, totals };
  }

  const type = data["discount_type"];
  const code = data["code"];
  const name = data["name"];
  const value = data["discount_value"];
  const discountCents = data["discount_cents"];
  const eligibleCents = data["eligible_cents"];
  if (
    (type !== "percentage" && type !== "fixed") ||
    (code !== null && typeof code !== "string") ||
    typeof name !== "string" ||
    !isCents(value) ||
    !isCents(discountCents) ||
    !isCents(eligibleCents) ||
    discountCents <= 0 ||
    eligibleCents > subtotalCents ||
    discountCents > eligibleCents
  ) {
    throw new Error("Unexpected coupon response.");
  }
  return {
    status: "applied",
    code,
    name,
    discountType: type,
    discountValue: value,
    discountCents,
    subtotalCents,
    eligibleCents,
    totals,
  };
}

// ---- Display helpers -------------------------------------------------------------------------------------

/** The label for a discount line: the code if there is one, otherwise the promotion's name. */
export function discountLabel(snapshot: {
  code: string | null;
  name: string | null;
}): string {
  const label = snapshot.code ?? snapshot.name;
  return label ? `Discount (${label})` : "Discount";
}

/** Human description of a discount's rule, from a snapshot. Basis points -> a percentage. */
export function describeDiscount(type: DiscountType, value: number): string {
  if (type === "fixed") return `${(value / 100).toFixed(2)} off`;
  const percent = value / 100;
  return `${Number.isInteger(percent) ? percent : percent.toFixed(2)}% off`;
}
