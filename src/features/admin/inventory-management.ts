import { AdminAccessError } from "./dashboard-result.ts";
import type { InventoryMovementKind } from "../../lib/supabase/types.ts";
import {
  AdminInventoryActionError,
  type AdjustmentFieldKey,
  type AdminInventoryListQuery,
  type StockState,
} from "./inventory-result.ts";
import { isUuid } from "./product-management.ts";

/**
 * Pure helpers for the admin inventory screen (Phase 6D-4). No runtime imports beyond sibling
 * pure modules, so they run under `node --test`.
 *
 * The URL is the single source of truth for what is on screen. Nothing here decides who may see
 * or change stock: the database does (require_admin() inside every inventory function).
 */

export const INVENTORY_PAGE_SIZE = 25;
export const HISTORY_PAGE_SIZE = 25;

/** admin_list_inventory() allows at most 100 rows per call. */
export const INVENTORY_FETCH_PAGE_SIZE = 100;
/** Safety cap for the views that classify rows on the client (see inventory.ts). */
export const INVENTORY_CLASSIFY_MAX_ROWS = 2000;

/** Same limit as the database (100 characters); longer input is trimmed, not refused. */
const MAX_SEARCH_LENGTH = 100;

export type InventoryTab = "stock" | "history";
export type InventoryView = "all" | "low" | "out";

export const INVENTORY_VIEWS: readonly InventoryView[] = ["all", "low", "out"];

export const INVENTORY_VIEW_LABELS: Record<InventoryView, string> = {
  all: "All inventory",
  low: "Low stock",
  out: "Out of stock",
};

/** The stock state each filtered view shows. "all" is not a state filter. */
export const INVENTORY_VIEW_STATE: Record<
  Exclude<InventoryView, "all">,
  StockState
> = {
  low: "low_stock",
  out: "out_of_stock",
};

export const STOCK_STATE_LABELS: Record<StockState, string> = {
  out_of_stock: "Out of stock",
  low_stock: "Low stock",
  in_stock: "In stock",
  inactive: "Inactive",
};

export interface InventoryParams {
  /** Search text (stock tab only). */
  q?: string;
  /** Stock filter (stock tab only); omitted means all inventory. */
  view?: Exclude<InventoryView, "all">;
  /** Omitted means the stock tab. */
  tab?: "history";
  /** History filter: one product, and optionally one of its variants. */
  product?: string;
  variant?: string;
  /** 1-based; omitted means page 1. */
  page?: number;
}

/** Unknown or malformed values are dropped rather than sent to the database. */
export function parseInventoryParams(
  search: Record<string, unknown>,
): InventoryParams {
  const params: InventoryParams = {};

  const q = search["q"];
  if (typeof q === "string" && q.trim() !== "")
    params.q = q.trim().slice(0, MAX_SEARCH_LENGTH);

  if (search["view"] === "low" || search["view"] === "out")
    params.view = search["view"];
  if (search["tab"] === "history") params.tab = "history";

  const product = search["product"];
  if (isUuid(product)) {
    params.product = product;
    // A variant filter only makes sense together with its product.
    const variant = search["variant"];
    if (isUuid(variant)) params.variant = variant;
  }

  const page = Number(search["page"]);
  if (Number.isInteger(page) && page > 1 && page <= 100_000) params.page = page;

  return params;
}

export function activeView(params: InventoryParams): InventoryView {
  return params.view ?? "all";
}

/** Server-paged list query for the "all inventory" view. */
export function toInventoryListQuery(
  params: InventoryParams,
  pageSize: number = INVENTORY_PAGE_SIZE,
): AdminInventoryListQuery {
  return {
    search: params.q ?? null,
    limit: pageSize,
    offset: ((params.page ?? 1) - 1) * pageSize,
  };
}

/** One 1-based page out of an already-collected list. */
export function pageSlice<T>(
  rows: readonly T[],
  page: number,
  pageSize: number,
): T[] {
  const start = (Math.max(1, page) - 1) * pageSize;
  return rows.slice(start, start + pageSize);
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

const REFUSAL_TEXT: Record<AdminInventoryActionError["reason"], string> = {
  invalid_arguments: "Check the adjustment details and try again.",
  zero_adjustment_not_allowed:
    "An adjustment of zero changes nothing. Enter a number other than 0.",
  product_not_found:
    "That product no longer exists. Refresh the inventory list.",
  variant_not_found:
    "That variant no longer exists. Refresh the inventory list.",
  variant_product_mismatch:
    "That variant does not belong to that product. Refresh the inventory list.",
  negative_stock_not_allowed:
    "That would take stock below zero. The current stock has been refreshed; enter a smaller removal.",
  stock_overflow:
    "That would exceed the largest quantity the system can store.",
  actor_unavailable:
    "Your admin account could not be identified. Sign in again and retry.",
};

/**
 * What the admin is told when an adjustment fails. Raw database text is never shown.
 * An unrecognised failure (a network drop, say) leaves the outcome unknown, so the wording points
 * at the History tab rather than inviting a blind retry that could apply the change twice.
 */
export function describeAdjustmentError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to adjust inventory.";
  }
  if (error instanceof AdminInventoryActionError)
    return REFUSAL_TEXT[error.reason];
  return "We couldn't confirm that adjustment. Check the History tab before trying again so it isn't applied twice.";
}

/** The form field a failure belongs to, if the database said which. */
export function adjustmentErrorField(
  error: unknown,
): AdjustmentFieldKey | null {
  return error instanceof AdminInventoryActionError ? error.field : null;
}

/** "You" for the signed-in admin, otherwise a short id (names are not exposed by the history API). */
export function formatActor(
  changedBy: string | null,
  currentUserId: string | null,
): string {
  if (!changedBy) return "Unknown (account removed)";
  if (currentUserId && changedBy === currentUserId) return "You";
  return `Admin ${changedBy.slice(0, 8)}`;
}

// ---------------------------------------------------------------------------
// Movement labels (Phase 9C)
// ---------------------------------------------------------------------------

export interface MovementLabel {
  label: string;
  /** One line saying exactly what is, and is not, known about this kind of row. */
  detail: string;
}

/** What each ledger movement_kind means. The wording follows what the database can actually attribute. */
export const MOVEMENT_LABELS: Record<InventoryMovementKind, MovementLabel> = {
  admin_adjustment: {
    label: "Admin adjustment",
    detail: "Made with the adjustment form.",
  },
  order_restock: {
    label: "Order cancelled",
    detail: "Stock returned because an order was cancelled.",
  },
  order_reactivation: {
    label: "Order reactivated",
    detail: "Stock taken again because a cancelled order was reactivated.",
  },
  stock_change: {
    label: "Order or direct change",
    detail:
      "Not attributed: an order being placed, or a direct change to stock. The two cannot be told apart.",
  },
};

/**
 * The label for a row, or null when the kind is unknown to the database response (an older
 * database without Phase 9C) so the screen shows nothing instead of guessing. A kind this build
 * does not know is shown generically.
 */
export function describeMovement(
  kind: string | null | undefined,
): MovementLabel | null {
  if (!kind) return null;
  const known = (Object.keys(MOVEMENT_LABELS) as InventoryMovementKind[]).find(
    (k) => k === kind,
  );
  return known
    ? MOVEMENT_LABELS[known]
    : {
        label: "Stock movement",
        detail: "A kind of movement this screen does not know.",
      };
}

/** First 8 characters of an order id, upper case: the same reference the customer screen uses. */
export function movementOrderReference(
  orderId: string | null | undefined,
): string | null {
  return orderId ? orderId.slice(0, 8).toUpperCase() : null;
}

/**
 * Who to show for a row. The history API returns the actor only for admin adjustments and for
 * staff / admin users, so a null actor on an order or stock-change row means "a customer or the
 * system", not "an account that was removed".
 */
export function formatMovementActor(
  kind: string | null | undefined,
  changedBy: string | null,
  currentUserId: string | null,
): string {
  if (!kind || kind === "admin_adjustment") {
    return formatActor(changedBy, currentUserId);
  }
  if (!changedBy) return "Customer or system";
  if (currentUserId && changedBy === currentUserId) return "You";
  return `Team member ${changedBy.slice(0, 8)}`;
}
