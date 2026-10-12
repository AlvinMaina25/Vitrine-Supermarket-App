import { type DiscountType } from "./logic.ts";

/**
 * Pure admin helpers for promotions (Phase 8): input/row types, safe error messages and result
 * parsing. No client import, so it is unit tested under Node. admin-api.ts wires the RPC calls.
 */

export interface PromotionInput {
  /** NULL / empty = automatic promotion. */
  code?: string | null;
  name: string;
  discount_type: DiscountType;
  /** percentage: basis points (1..10000). fixed: cents. */
  value: number;
  max_discount_cents?: number | null;
  min_order_cents?: number;
  starts_at?: string | null;
  expires_at?: string | null;
  usage_limit?: number | null;
  per_customer_limit?: number | null;
  is_active?: boolean;
}

export type PromotionChanges = Partial<Omit<PromotionInput, "is_active">>;

export interface PromotionAdminRow {
  id: string;
  code: string | null;
  name: string;
  discount_type: DiscountType;
  value: number;
  max_discount_cents: number | null;
  min_order_cents: number;
  starts_at: string | null;
  expires_at: string | null;
  usage_limit: number | null;
  per_customer_limit: number | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  /** Present on list rows only. */
  active_redemptions?: number;
  active_discount_cents?: number;
}

export interface PromotionErrorLike {
  message?: string | null;
  details?: string | null;
}

const ADMIN_MESSAGES: Record<string, string> = {
  code_taken: "That coupon code is already in use.",
  invalid_promotion:
    "The promotion details are not valid. Check the values and dates.",
  promotion_not_found: "That promotion no longer exists.",
  invalid_arguments: "The promotion request was incomplete.",
  not_authorised: "You are not allowed to manage promotions.",
  mfa_required: "Two-factor sign-in is required for this action.",
};

/** A safe admin message from a PostgREST error. Unknown errors get a generic line, never raw SQL text. */
export function promotionAdminErrorMessage(error: PromotionErrorLike): string {
  const detail = typeof error.details === "string" ? error.details.trim() : "";
  return (
    ADMIN_MESSAGES[detail] ??
    "The promotion could not be saved. Please try again."
  );
}

function isPromotionRow(value: unknown): value is PromotionAdminRow {
  if (typeof value !== "object" || value === null) return false;
  const row = value as Record<string, unknown>;
  return (
    typeof row["id"] === "string" &&
    typeof row["name"] === "string" &&
    (row["discount_type"] === "percentage" ||
      row["discount_type"] === "fixed") &&
    typeof row["value"] === "number" &&
    typeof row["is_active"] === "boolean"
  );
}

/** Reads `{ promotion: {...} }` from create / update / set-active. */
export function parsePromotionResult(data: unknown): PromotionAdminRow {
  const promotion =
    typeof data === "object" && data !== null
      ? (data as Record<string, unknown>)["promotion"]
      : undefined;
  if (!isPromotionRow(promotion))
    throw new Error("Unexpected promotion response.");
  return promotion;
}

/** Reads `{ total, rows }` from admin_list_promotions(). */
export function parsePromotionList(data: unknown): {
  total: number;
  rows: PromotionAdminRow[];
} {
  const record =
    typeof data === "object" && data !== null
      ? (data as Record<string, unknown>)
      : null;
  const rows = record?.["rows"];
  const total = record?.["total"];
  if (
    record === null ||
    typeof total !== "number" ||
    !Array.isArray(rows) ||
    !rows.every(isPromotionRow)
  ) {
    throw new Error("Unexpected promotion list response.");
  }
  return { total, rows };
}
