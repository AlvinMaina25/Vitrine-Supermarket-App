import type {
  AdminAdjustInventoryArgs,
  AdminAdjustInventoryResult,
  AdminInventoryAdjustmentList,
  AdminInventoryList,
  AdminInventoryRow,
} from "../../lib/supabase/types.ts";
import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Pure helpers for the admin inventory screens (Phase 6D-4). No runtime imports beyond the Phase
 * 6A error class, so they run under `node --test`.
 *
 * Nothing here decides authorisation or what stock becomes. The database does:
 *   admin_list_inventory()              read (Phase 6C.2.1)
 *   admin_adjust_inventory()            the ONLY stock write; delta based, row-locked (6C.2.2A.2)
 *   admin_list_inventory_adjustments()  history read (6C.2.2B.1)
 * all behind require_admin(). The validation below exists only so the form can say "that is not a
 * whole number" before a round trip; whatever the server refuses, the UI reports.
 */

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type AdminInventoryActionReason =
  | "invalid_arguments"
  | "zero_adjustment_not_allowed"
  | "product_not_found"
  | "variant_not_found"
  | "variant_product_mismatch"
  | "negative_stock_not_allowed"
  | "stock_overflow"
  | "actor_unavailable";

const ACTION_REASONS: readonly AdminInventoryActionReason[] = [
  "invalid_arguments",
  "zero_adjustment_not_allowed",
  "product_not_found",
  "variant_not_found",
  "variant_product_mismatch",
  "negative_stock_not_allowed",
  "stock_overflow",
  "actor_unavailable",
];

/** Form fields a refusal can be attached to. */
export type AdjustmentFieldKey = "quantity" | "reason" | "note";

/**
 * A rule refused an adjustment. `reason` is the database's own DETAIL code; the message is NOT
 * the raw database text (the UI words it from `reason`).
 */
export class AdminInventoryActionError extends Error {
  override readonly name = "AdminInventoryActionError";
  readonly reason: AdminInventoryActionReason;
  readonly field: AdjustmentFieldKey | null;

  constructor(
    reason: AdminInventoryActionReason,
    field: AdjustmentFieldKey | null = null,
  ) {
    super(`Inventory adjustment refused: ${reason}`);
    this.reason = reason;
    this.field = field;
  }
}

/** Reads: not-an-admin -> AdminAccessError; anything else keeps its own (unshown) message. */
export function toAdminInventoryError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to view inventory.",
    );
  }
  return new Error(error.message);
}

/**
 * Which form field an `invalid_arguments` message is about. The database messages name it
 * ("A reason of 1 to 120 characters is required.", "A note, when given, ...").
 */
export function fieldFromInvalidAdjustmentMessage(
  message: string,
): AdjustmentFieldKey | null {
  const m = message.toLowerCase();
  if (m.includes("reason")) return "reason";
  if (m.includes("note")) return "note";
  if (m.includes("adjustment quantity")) return "quantity";
  return null;
}

/** Writes: also maps the rule refusals. Anything unrecognised becomes a plain Error. */
export function toAdminInventoryActionError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to adjust inventory.",
    );
  }
  const reason = ACTION_REASONS.find((r) => r === error.details);
  if (!reason) return new Error(error.message);
  switch (reason) {
    case "invalid_arguments":
      return new AdminInventoryActionError(
        reason,
        fieldFromInvalidAdjustmentMessage(error.message),
      );
    case "zero_adjustment_not_allowed":
    case "negative_stock_not_allowed":
    case "stock_overflow":
      return new AdminInventoryActionError(reason, "quantity");
    default:
      return new AdminInventoryActionError(reason);
  }
}

// ---------------------------------------------------------------------------
// Response shapes (the types are hand-maintained, so check the top level instead of trusting a cast)
// ---------------------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function toAdminInventoryList(data: unknown): AdminInventoryList {
  if (
    !isRecord(data) ||
    !Array.isArray(data["inventory"]) ||
    typeof data["total"] !== "number" ||
    typeof data["limit"] !== "number" ||
    typeof data["offset"] !== "number"
  ) {
    throw new Error(
      "The admin inventory list returned an unexpected response.",
    );
  }
  return data as unknown as AdminInventoryList;
}

export function toAdminAdjustmentList(
  data: unknown,
): AdminInventoryAdjustmentList {
  if (
    !isRecord(data) ||
    !Array.isArray(data["adjustments"]) ||
    typeof data["total"] !== "number" ||
    typeof data["limit"] !== "number" ||
    typeof data["offset"] !== "number"
  ) {
    throw new Error("The inventory history returned an unexpected response.");
  }
  // Phase 9C added movement_kind / order_id. A response from a database that has not applied 9C
  // lacks them: read that as "unknown" (null), never as a guessed kind.
  const adjustments = (data["adjustments"] as unknown[]).map((row) => {
    if (!isRecord(row)) return row;
    return {
      ...row,
      movement_kind:
        typeof row["movement_kind"] === "string" ? row["movement_kind"] : null,
      order_id: typeof row["order_id"] === "string" ? row["order_id"] : null,
    };
  });
  return { ...data, adjustments } as unknown as AdminInventoryAdjustmentList;
}

export function toAdminAdjustResult(data: unknown): AdminAdjustInventoryResult {
  if (
    !isRecord(data) ||
    typeof data["adjustment_id"] !== "string" ||
    typeof data["previous_quantity"] !== "number" ||
    typeof data["adjustment_quantity"] !== "number" ||
    typeof data["new_quantity"] !== "number"
  ) {
    throw new Error(
      "The inventory adjustment returned an unexpected response.",
    );
  }
  return data as unknown as AdminAdjustInventoryResult;
}

// ---------------------------------------------------------------------------
// Request arguments
// ---------------------------------------------------------------------------

export interface AdminInventoryListQuery {
  search?: string | null;
  isActive?: boolean | null;
  productId?: string | null;
  limit?: number;
  offset?: number;
}

/** Named arguments for admin_list_inventory(). Blank strings become null; defaults are explicit. */
export function toAdminListInventoryArgs(query: AdminInventoryListQuery = {}) {
  const search = query.search?.trim();
  return {
    p_search: search ? search : null,
    p_is_active: query.isActive ?? null,
    p_product_id: query.productId ?? null,
    p_limit: query.limit ?? 25,
    p_offset: query.offset ?? 0,
  };
}

export interface AdminAdjustmentHistoryQuery {
  productId?: string | null;
  variantId?: string | null;
  limit?: number;
  offset?: number;
}

/** Named arguments for admin_list_inventory_adjustments(). Unused filters are sent as null. */
export function toAdminListAdjustmentsArgs(
  query: AdminAdjustmentHistoryQuery = {},
) {
  return {
    p_limit: query.limit ?? 25,
    p_offset: query.offset ?? 0,
    p_product_id: query.productId ?? null,
    p_variant_id: query.variantId ?? null,
  };
}

// ---------------------------------------------------------------------------
// Stock state (mirrors the Phase 6A dashboard definitions; see below)
// ---------------------------------------------------------------------------

/**
 * The schema has NO per-product reorder level, and admin_list_inventory() has no low-stock
 * filter. The only backend definition of "low stock" is public.admin_dashboard_summary()
 * (Phase 6A), whose p_low_stock_threshold defaults to 10. This constant is that same default and
 * classifyStock() below is that same rule, so the inventory screen and the dashboard agree.
 * tests/admin-inventory.test.ts reads the migration and fails if the two ever drift apart.
 */
export const LOW_STOCK_THRESHOLD = 10;

export type StockState = "out_of_stock" | "low_stock" | "in_stock" | "inactive";

/**
 * Phase 6A definitions, active products / variants only:
 *   product out_of_stock : not in_stock flag, or stock_quantity = 0
 *   product low_stock    : in_stock and 1 <= stock_quantity <= threshold
 *   variant out_of_stock : stock_quantity = 0 (variants have no in_stock flag)
 *   variant low_stock    : 1 <= stock_quantity <= threshold, and the parent product is active
 * An inactive unit (or a variant of an inactive product) is reported as "inactive": the
 * dashboard does not count it, so neither does this.
 */
export function classifyStock(
  row: Pick<
    AdminInventoryRow,
    "kind" | "stock_quantity" | "in_stock" | "is_active" | "product_is_active"
  >,
  threshold: number = LOW_STOCK_THRESHOLD,
): StockState {
  if (!row.is_active || !row.product_is_active) return "inactive";
  const quantity = row.stock_quantity;
  if (row.kind === "product") {
    if (row.in_stock === false || quantity === 0) return "out_of_stock";
  } else if (quantity === 0) {
    return "out_of_stock";
  }
  return quantity >= 1 && quantity <= threshold ? "low_stock" : "in_stock";
}

/** Stable identity of a stock unit: a product's own stock, or one variant. */
export function inventoryRowKey(
  row: Pick<AdminInventoryRow, "product_id" | "variant_id">,
): string {
  return `${row.product_id}:${row.variant_id ?? "product"}`;
}

// ---------------------------------------------------------------------------
// Collecting every page (used only for the client-classified views)
// ---------------------------------------------------------------------------

export interface CollectedPages<T> {
  rows: T[];
  /** The database's own count of matching rows. */
  total: number;
  /** True when `total` is larger than what was collected (the safety cap was reached). */
  truncated: boolean;
}

/**
 * Reads page after page until `total` rows are in hand or `maxRows` is reached. Stops on an empty
 * page, so a database that misreports `total` cannot loop forever.
 */
export async function collectAllPages<T>(
  fetchPage: (offset: number) => Promise<{ total: number; rows: T[] }>,
  options: { pageSize: number; maxRows: number },
): Promise<CollectedPages<T>> {
  const rows: T[] = [];
  let total = 0;
  while (rows.length < options.maxRows) {
    const page = await fetchPage(rows.length);
    total = page.total;
    if (page.rows.length === 0) break;
    rows.push(...page.rows);
    if (rows.length >= total || page.rows.length < options.pageSize) break;
  }
  if (rows.length > options.maxRows) rows.length = options.maxRows;
  return { rows, total, truncated: rows.length < total };
}

// ---------------------------------------------------------------------------
// Adjustment form
// ---------------------------------------------------------------------------

/** products / product_variants.stock_quantity is `integer`. */
export const MAX_STOCK_QUANTITY = 2_147_483_647;
export const MAX_REASON_LENGTH = 120;
export const MAX_NOTE_LENGTH = 500;

export interface AdjustmentFormValues {
  quantity: string;
  reason: string;
  note: string;
}

export type AdjustmentFormErrors = Partial<Record<AdjustmentFieldKey, string>>;

export function emptyAdjustmentValues(): AdjustmentFormValues {
  return { quantity: "", reason: "", note: "" };
}

export type QuantityParse =
  { ok: true; value: number } | { ok: false; message: string };

/** A signed, non-zero whole number: "10", "+10" and "-3" are accepted; "1.5", "1e3" and "0" are not. */
export function parseAdjustmentQuantity(text: string): QuantityParse {
  const trimmed = text.trim();
  if (trimmed === "")
    return { ok: false, message: "Enter how much to add (+) or remove (-)." };
  if (!/^[+-]?\d+$/.test(trimmed)) {
    return { ok: false, message: "Enter a whole number such as 10 or -3." };
  }
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value) || Math.abs(value) > MAX_STOCK_QUANTITY) {
    return { ok: false, message: "That number is too large." };
  }
  if (value === 0)
    return { ok: false, message: "An adjustment of zero changes nothing." };
  // Normalise "-0" style input away: Number("-0") is -0, but zero was refused above.
  return { ok: true, value };
}

/** Characters as the database counts them (code points, not UTF-16 units). */
function characterCount(text: string): number {
  return Array.from(text).length;
}

export type AdjustmentBuild =
  | { ok: true; args: AdminAdjustInventoryArgs; delta: number }
  | { ok: false; errors: AdjustmentFormErrors };

/**
 * Turns the form into the arguments admin_adjust_inventory() takes. The unit identifies WHAT to
 * adjust; there is no way to send a final quantity, a previous quantity or an actor, so the
 * database always computes the result from the locked current stock.
 */
export function buildAdjustmentArgs(
  unit: Pick<AdminInventoryRow, "product_id" | "variant_id">,
  values: AdjustmentFormValues,
): AdjustmentBuild {
  const errors: AdjustmentFormErrors = {};

  const quantity = parseAdjustmentQuantity(values.quantity);
  if (!quantity.ok) errors.quantity = quantity.message;

  const reason = values.reason.trim();
  if (reason === "") errors.reason = "A reason is required.";
  else if (characterCount(reason) > MAX_REASON_LENGTH) {
    errors.reason = `Keep the reason to ${MAX_REASON_LENGTH} characters or fewer.`;
  }

  const note = values.note.trim();
  if (characterCount(note) > MAX_NOTE_LENGTH) {
    errors.note = `Keep the note to ${MAX_NOTE_LENGTH} characters or fewer.`;
  }

  if (!quantity.ok || errors.reason || errors.note)
    return { ok: false, errors };

  return {
    ok: true,
    delta: quantity.value,
    args: {
      p_product_id: unit.product_id,
      p_adjustment_quantity: quantity.value,
      p_reason: reason,
      p_variant_id: unit.variant_id,
      // A blank note is refused by the database, so an empty box means "no note".
      p_note: note === "" ? null : note,
    },
  };
}

/** What the stock would be, from the quantity the screen holds. A preview only: the database decides. */
export function projectStock(current: number, delta: number): number {
  return current + delta;
}

/** "+10" / "-3". */
export function formatDelta(delta: number): string {
  return delta > 0 ? `+${delta}` : `${delta}`;
}
