import type { ProductRow } from "../../lib/supabase/types.ts";
import { AdminAccessError } from "./dashboard-result.ts";
import {
  AdminProductActionError,
  AdminProductNotFoundError,
  type AdminProductListQuery,
} from "./products-result.ts";

/**
 * Pure helpers for the admin product list screen (Phase 6D-3A). No runtime imports beyond the
 * Phase 6A/6D error classes, so they run under `node --test`.
 *
 * The URL is the single source of truth for the list state; the database does the searching,
 * filtering and paging (admin_list_products). Nothing here decides who may see products.
 */

export const PRODUCTS_PAGE_SIZE = 25;

/** Same limit as the database (100 characters); longer input is trimmed, not refused. */
const MAX_SEARCH_LENGTH = 100;

export type ProductStatusFilter = "active" | "inactive";

export const PRODUCT_STATUS_FILTERS: readonly ProductStatusFilter[] = [
  "active",
  "inactive",
];

export const PRODUCT_STATUS_LABELS: Record<ProductStatusFilter, string> = {
  active: "Active",
  inactive: "Inactive",
};

export interface ProductListParams {
  q?: string;
  status?: ProductStatusFilter;
  /** A category id (uuid). Sub-categories are not included, as in the database. */
  category?: string;
  /** 1-based; omitted means page 1. */
  page?: number;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** Unknown or malformed values are dropped rather than sent to the database. */
export function parseProductListParams(
  search: Record<string, unknown>,
): ProductListParams {
  const params: ProductListParams = {};

  const q = search["q"];
  if (typeof q === "string" && q.trim() !== "")
    params.q = q.trim().slice(0, MAX_SEARCH_LENGTH);

  const status = PRODUCT_STATUS_FILTERS.find((s) => s === search["status"]);
  if (status) params.status = status;

  const category = search["category"];
  if (isUuid(category)) params.category = category;

  const page = Number(search["page"]);
  if (Number.isInteger(page) && page > 1 && page <= 100_000) params.page = page;

  return params;
}

export function toProductListQuery(
  params: ProductListParams,
  pageSize: number = PRODUCTS_PAGE_SIZE,
): AdminProductListQuery {
  return {
    search: params.q ?? null,
    isActive: params.status === undefined ? null : params.status === "active",
    categoryId: params.category ?? null,
    limit: pageSize,
    offset: ((params.page ?? 1) - 1) * pageSize,
  };
}

/** Stock as it is stored: the in_stock flag and the quantity are independent columns. */
export function describeProductStock(
  product: Pick<ProductRow, "in_stock" | "stock_quantity">,
): {
  label: string;
  inStock: boolean;
  quantity: number;
} {
  return {
    label: product.in_stock ? "In stock" : "Out of stock",
    inStock: product.in_stock,
    quantity: product.stock_quantity,
  };
}

// ---------------------------------------------------------------------------
// What the UI may say about a failure. Raw database text is never shown.
// ---------------------------------------------------------------------------

const FIELD_LABELS: Record<string, string> = {
  name: "name",
  slug: "URL slug",
  category: "category",
  description: "description",
  brand: "brand",
  sku: "SKU",
  price: "price",
  compareAt: "compare-at price",
  unitLabel: "unit label",
  position: "position",
};

/** A short, safe sentence for a failed save, built from the error's class and reason only. */
export function describeProductSaveError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to change products.";
  }
  if (error instanceof AdminProductNotFoundError) {
    return "This product no longer exists. Go back to the product list and refresh it.";
  }
  if (error instanceof AdminProductActionError) {
    switch (error.reason) {
      case "slug_taken":
        return "Another product already uses that URL slug. Choose a different one.";
      case "sku_taken":
        return "Another product or variant already uses that SKU. Choose a different one.";
      case "category_not_found":
        return "That category no longer exists. Pick another category and try again.";
      case "variant_not_found":
        return "This variant no longer exists. Refresh the page to see the current variants.";
      case "invalid_arguments": {
        const label = error.field ? FIELD_LABELS[error.field] : undefined;
        return label
          ? `The ${label} was not accepted. Check it and try again.`
          : "Some values were not accepted. Check the form and try again.";
      }
      default:
        return "That change could not be saved. Please try again.";
    }
  }
  return "We couldn't save your changes. Please try again in a moment.";
}

/** Which form field (if any) a failed save should be attached to. */
export function saveErrorField(error: unknown): string | null {
  return error instanceof AdminProductActionError ? error.field : null;
}

/** A short, safe sentence for a failed activation / deactivation. */
export function describeProductActivationError(
  error: unknown,
  activating: boolean,
): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to change products.";
  }
  if (error instanceof AdminProductNotFoundError) {
    return "This product no longer exists. Go back to the product list and refresh it.";
  }
  return activating
    ? "We couldn't activate this product. Please try again in a moment."
    : "We couldn't deactivate this product. Please try again in a moment.";
}
