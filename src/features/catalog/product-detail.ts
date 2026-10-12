/**
 * Product-page helpers (Phase 12). PURE: no React, no network, no storage.
 *
 * Rules mirrored from the database (create_order): a plain product line needs `in_stock` and
 * stock_quantity >= quantity; a variant line needs an active variant and variant.stock_quantity
 * >= quantity (variants have no in_stock flag). Quantities are 1-99. The page only decides what
 * to SHOW and what to ENABLE; checkout still re-checks everything in the database.
 */

import {
  maxOrderQuantity,
  stockState,
  type BrowseProduct,
  type StockState,
} from "./browse.ts";

export const MAX_LINE_QUANTITY = 99;

// ---- Variants ------------------------------------------------------------------------------

export interface VariantLike {
  id: string;
  name: string;
  sku: string | null;
  price_cents: number;
  compare_at_price_cents: number | null;
  stock_quantity: number;
  low_stock_threshold: number | null;
  position: number;
  is_active: boolean;
}

/** Active variants only, in the order the shop set (position, then name). Never mutates. */
export function orderedVariants<T extends VariantLike>(
  variants: readonly T[],
): T[] {
  return variants
    .filter((variant) => variant.is_active)
    .sort(
      (a, b) =>
        a.position - b.position ||
        a.name.localeCompare(b.name, "en", { sensitivity: "base" }),
    );
}

/** Same shape stockState() reads. A variant has no in_stock flag, so units alone decide. */
export function variantStockState(
  variant: Pick<VariantLike, "stock_quantity" | "low_stock_threshold">,
): StockState {
  return stockState({
    in_stock: true,
    stock_quantity: variant.stock_quantity,
    low_stock_threshold: variant.low_stock_threshold,
  });
}

export function isVariantAvailable(
  variant: Pick<VariantLike, "stock_quantity">,
): boolean {
  return variant.stock_quantity > 0;
}

/**
 * Which variant starts selected: the one named in the URL if it exists and is active (even if
 * sold out, so a shared link shows what was shared, with Add disabled), otherwise the first
 * variant that is in stock, otherwise the first one. null when there are no active variants.
 */
export function initialVariantId<T extends VariantLike>(
  variants: readonly T[],
  requestedId: unknown,
): string | null {
  const list = orderedVariants(variants);
  if (list.length === 0) return null;
  if (typeof requestedId === "string") {
    const requested = list.find((variant) => variant.id === requestedId);
    if (requested) return requested.id;
  }
  return (list.find(isVariantAvailable) ?? list[0])?.id ?? null;
}

/** Cheapest and dearest active variant price, for a "From KES x" hint. null if none. */
export function variantPriceRange(
  variants: readonly Pick<VariantLike, "price_cents" | "is_active">[],
): { minCents: number; maxCents: number } | null {
  const prices = variants
    .filter((variant) => variant.is_active)
    .map((variant) => variant.price_cents);
  if (prices.length === 0) return null;
  return { minCents: Math.min(...prices), maxCents: Math.max(...prices) };
}

// ---- What can be bought --------------------------------------------------------------------

export interface Purchasable {
  state: StockState;
  /** Units on the shelf the customer may be told about, capped at 99. 0 = cannot buy. */
  maxUnits: number;
  priceCents: number;
  compareAtCents: number | null;
  sku: string | null;
}

export function purchasableForProduct(
  product: Pick<
    BrowseProduct,
    | "in_stock"
    | "stock_quantity"
    | "low_stock_threshold"
    | "price_cents"
    | "compare_at_price_cents"
  > & { sku?: string | null },
): Purchasable {
  return {
    state: stockState(product),
    maxUnits: maxOrderQuantity(product),
    priceCents: product.price_cents,
    compareAtCents: product.compare_at_price_cents,
    sku: product.sku ?? null,
  };
}

export function purchasableForVariant(
  variant: VariantLike,
  fallbackSku: string | null = null,
): Purchasable {
  return {
    state: variantStockState(variant),
    maxUnits: Math.max(
      0,
      Math.min(MAX_LINE_QUANTITY, Math.floor(variant.stock_quantity)),
    ),
    priceCents: variant.price_cents,
    compareAtCents: variant.compare_at_price_cents,
    sku: variant.sku ?? fallbackSku,
  };
}

// ---- Quantity ------------------------------------------------------------------------------

export interface QuantityLimit {
  /** Highest quantity the customer can still ADD right now (0 = none). */
  room: number;
  /** The stepper's maximum (never below 1 so the control stays valid). */
  stepperMax: number;
  /** Why the ceiling is where it is. */
  reason: "stock" | "line-limit" | null;
}

/**
 * How many more can go in the basket: shelf units (or 99) minus what is already there.
 * Never invents stock: when `maxUnits` is 0 the room is 0.
 */
export function quantityLimit(
  maxUnits: number,
  inBasket: number,
): QuantityLimit {
  const ceiling = Math.max(
    0,
    Math.min(MAX_LINE_QUANTITY, Math.floor(maxUnits)),
  );
  const room = Math.max(0, ceiling - Math.max(0, Math.floor(inBasket)));
  const reason: QuantityLimit["reason"] =
    maxUnits < MAX_LINE_QUANTITY ? "stock" : "line-limit";
  return { room, stepperMax: Math.max(room, 1), reason };
}

/** Typed text -> a whole number inside [min, max]. Blank or junk falls back to `min`. */
export function clampQuantity(
  raw: string | number,
  min: number,
  max: number,
): number {
  const parsed =
    typeof raw === "number"
      ? raw
      : /^\s*\d{1,4}\s*$/.test(raw)
        ? Number(raw)
        : NaN;
  if (!Number.isFinite(parsed)) return Math.max(min, 1);
  return Math.min(Math.max(Math.floor(parsed), min), Math.max(max, min));
}

/**
 * The calm sentence under the stepper. null when there is nothing to say.
 * `requested` is what the customer typed or reached with the stepper.
 */
export function quantityMessage(input: {
  maxUnits: number;
  inBasket: number;
  requested: number;
}): string | null {
  const { room, reason } = quantityLimit(input.maxUnits, input.inBasket);
  if (input.maxUnits <= 0) return null;
  if (room === 0) {
    return reason === "stock"
      ? `You already have all ${input.maxUnits} available in your basket.`
      : `You already have the most you can order (${MAX_LINE_QUANTITY}) in your basket.`;
  }
  if (input.requested >= room) {
    if (reason === "stock") {
      return input.inBasket > 0
        ? `That's all we have: ${input.maxUnits} available, ${input.inBasket} already in your basket.`
        : `That's all we have: ${input.maxUnits} available.`;
    }
    return `The most you can order at once is ${MAX_LINE_QUANTITY}.`;
  }
  return null;
}

// ---- Related products ----------------------------------------------------------------------

export interface RelatableProduct extends BrowseProduct {
  id: string;
  category_id: string | null;
}

/**
 * Rule-based "You may also like": other products from the same category, never the current one.
 * Order: in stock before sold out, then same brand first, then newest. No popularity or personal
 * data is used (none exists in the catalogue read path), so nothing here is "personalised".
 */
export function relatedProducts<T extends RelatableProduct>(
  current: Pick<T, "id" | "category_id" | "brand">,
  all: readonly T[],
  limit = 8,
): T[] {
  if (!current.category_id) return [];
  const brand = current.brand?.trim().toLowerCase() ?? "";
  return all
    .filter(
      (product) =>
        product.id !== current.id &&
        product.category_id === current.category_id,
    )
    .map((product, index) => ({
      product,
      index,
      soldOut: stockState(product).kind === "out" ? 1 : 0,
      sameBrand:
        brand !== "" && product.brand?.trim().toLowerCase() === brand ? 0 : 1,
      created: Date.parse(product.created_at) || 0,
    }))
    .sort(
      (a, b) =>
        a.soldOut - b.soldOut ||
        a.sameBrand - b.sameBrand ||
        b.created - a.created ||
        a.index - b.index,
    )
    .slice(0, limit)
    .map((entry) => entry.product);
}

// ---- Options summary for lists --------------------------------------------------------------

/** What a product card needs to know about a product's variants. */
export interface OptionsSummary {
  count: number;
  /** At least one active variant has units on the shelf. */
  anyAvailable: boolean;
  minPriceCents: number;
  maxPriceCents: number;
}

/**
 * Groups active variant rows by product. A product that has active variants is bought by choosing
 * one, so lists show "Choose options" and judge sold-out by the variants, not the base row.
 */
export function summariseVariants(
  rows: readonly {
    product_id: string;
    price_cents: number;
    stock_quantity: number;
    is_active: boolean;
  }[],
): Map<string, OptionsSummary> {
  const out = new Map<string, OptionsSummary>();
  for (const row of rows) {
    if (!row.is_active) continue;
    const entry = out.get(row.product_id);
    const available = row.stock_quantity > 0;
    if (!entry) {
      out.set(row.product_id, {
        count: 1,
        anyAvailable: available,
        minPriceCents: row.price_cents,
        maxPriceCents: row.price_cents,
      });
    } else {
      entry.count += 1;
      entry.anyAvailable = entry.anyAvailable || available;
      entry.minPriceCents = Math.min(entry.minPriceCents, row.price_cents);
      entry.maxPriceCents = Math.max(entry.maxPriceCents, row.price_cents);
    }
  }
  return out;
}

// ---- Reading a capped list completely -------------------------------------------------------

export const SUMMARY_PAGE_SIZE = 1000;
export const SUMMARY_MAX_PAGES = 50;

/**
 * PostgREST caps one response (often at 1000 rows) without saying so. `fetchPage(from, to)` returns
 * that page's rows plus the exact total the server counted. This keeps asking from where the last
 * page ended until every counted row is in hand, so a lower server cap only means more pages.
 * It THROWS rather than return a partial list: a half-read variant list would call products
 * "plain" or "sold out" wrongly, and callers treat a throw as "summary unavailable".
 */
export async function collectAllPages<T>(
  fetchPage: (
    from: number,
    to: number,
  ) => Promise<{ rows: readonly T[]; total: number | null }>,
  pageSize = SUMMARY_PAGE_SIZE,
  maxPages = SUMMARY_MAX_PAGES,
): Promise<T[]> {
  const all: T[] = [];
  for (let page = 0; page < maxPages; page += 1) {
    const from = all.length;
    const { rows, total } = await fetchPage(from, from + pageSize - 1);
    if (total === null) throw new Error("The row count was not returned.");
    all.push(...rows);
    if (all.length >= total) return all;
    if (rows.length === 0) {
      throw new Error("The list ended before the counted rows were read.");
    }
  }
  throw new Error("The list is too long to read completely.");
}
