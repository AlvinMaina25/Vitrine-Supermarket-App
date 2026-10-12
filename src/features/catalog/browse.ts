/**
 * Storefront browsing helpers (Phase 11). PURE: no React, no network, no clock.
 *
 * Presentation only. Nothing here changes a price or a total: prices stay integer cents and are
 * formatted through src/lib/format.ts. These helpers only decide what to SHOW (stock badges,
 * sort order, search matching, page slices) from rows the existing catalog queries already load.
 */

export interface BrowseProduct {
  name: string;
  brand: string | null;
  price_cents: number;
  compare_at_price_cents: number | null;
  stock_quantity: number;
  low_stock_threshold?: number | null | undefined;
  in_stock: boolean;
  created_at: string;
}

// ---- Search ----------------------------------------------------------------------------------

export const MAX_SEARCH_LENGTH = 80;

/** Trim, collapse inner whitespace and cap the length. Non-strings become "". */
export function normalizeSearchTerm(raw: unknown): string {
  // The router parses a bare number in the URL (?q=500) into a number; accept it as text.
  const text =
    typeof raw === "number" && Number.isFinite(raw) ? String(raw) : raw;
  if (typeof text !== "string") return "";
  return text.replace(/\s+/g, " ").trim().slice(0, MAX_SEARCH_LENGTH);
}

function searchTokens(term: string): string[] {
  return normalizeSearchTerm(term)
    .toLowerCase()
    .split(" ")
    .filter((token) => token !== "");
}

/** Every word typed must appear in the product's name or brand (any order, any case). */
export function matchesSearch(
  product: Pick<BrowseProduct, "name" | "brand">,
  term: string,
): boolean {
  const tokens = searchTokens(term);
  if (tokens.length === 0) return true;
  const haystack = `${product.name} ${product.brand ?? ""}`.toLowerCase();
  return tokens.every((token) => haystack.includes(token));
}

/**
 * Filters and ranks: names starting with the term first, then names where a word starts with it,
 * then everything else that matched. Stable within a rank, so the catalogue's own order is kept.
 */
export function searchProducts<T extends Pick<BrowseProduct, "name" | "brand">>(
  products: readonly T[],
  term: string,
): T[] {
  const tokens = searchTokens(term);
  if (tokens.length === 0) return [...products];
  const phrase = tokens.join(" ");
  const scored = products
    .filter((product) => matchesSearch(product, term))
    .map((product, index) => {
      const name = product.name.toLowerCase();
      const rank = name.startsWith(phrase)
        ? 0
        : name.split(/\s+/).some((word) => word.startsWith(tokens[0] ?? ""))
          ? 1
          : 2;
      return { product, index, rank };
    });
  scored.sort((a, b) => a.rank - b.rank || a.index - b.index);
  return scored.map((entry) => entry.product);
}

// ---- Sort & filter -----------------------------------------------------------------------------

export const SORT_OPTIONS = [
  { value: "name", label: "Name (A–Z)" },
  { value: "price-asc", label: "Price: low to high" },
  { value: "price-desc", label: "Price: high to low" },
  { value: "newest", label: "Newest first" },
] as const;

export type SortKey = (typeof SORT_OPTIONS)[number]["value"];
export const DEFAULT_SORT: SortKey = "name";

export function parseSortKey(raw: unknown): SortKey {
  return SORT_OPTIONS.some((option) => option.value === raw)
    ? (raw as SortKey)
    : DEFAULT_SORT;
}

/** Returns a new array; never mutates the (cached) query data. Ties fall back to name. */
export function sortProducts<
  T extends Pick<BrowseProduct, "name" | "price_cents" | "created_at">,
>(products: readonly T[], sort: SortKey): T[] {
  const byName = (a: T, b: T) =>
    a.name.localeCompare(b.name, "en", { sensitivity: "base" });
  const copy = [...products];
  switch (sort) {
    case "price-asc":
      return copy.sort((a, b) => a.price_cents - b.price_cents || byName(a, b));
    case "price-desc":
      return copy.sort((a, b) => b.price_cents - a.price_cents || byName(a, b));
    case "newest":
      return copy.sort(
        (a, b) =>
          Date.parse(b.created_at) - Date.parse(a.created_at) || byName(a, b),
      );
    default:
      return copy.sort(byName);
  }
}

/** "1" / "true" in the URL means: hide sold-out products. */
export function parseInStockOnly(raw: unknown): boolean {
  return raw === true || raw === "1" || raw === "true" || raw === 1;
}

export function filterInStock<T extends BrowseProduct>(
  products: readonly T[],
  inStockOnly: boolean,
): T[] {
  return inStockOnly
    ? products.filter((product) => stockState(product).kind !== "out")
    : [...products];
}

// ---- Stock & price presentation ------------------------------------------------------------------

export type StockState =
  { kind: "in" } | { kind: "low"; left: number } | { kind: "out" };

/**
 * Mirrors what the database will accept: create_order() rejects `not in_stock` and any quantity
 * above stock_quantity, so a product with no units is shown as sold out too. "Low" appears only
 * when the product's own low_stock_threshold says so; no threshold is ever invented here.
 */
export function stockState(
  product: Pick<
    BrowseProduct,
    "in_stock" | "stock_quantity" | "low_stock_threshold"
  >,
): StockState {
  if (product.in_stock === false || product.stock_quantity <= 0) {
    return { kind: "out" };
  }
  const threshold = product.low_stock_threshold;
  if (
    typeof threshold === "number" &&
    threshold > 0 &&
    product.stock_quantity <= threshold
  ) {
    return { kind: "low", left: product.stock_quantity };
  }
  return { kind: "in" };
}

export function stockLabel(state: StockState): string | null {
  if (state.kind === "out") return "Sold out";
  if (state.kind === "low") return `Only ${state.left} left`;
  return null;
}

/** The most the customer can add in one go: never above what is on the shelf, never above 99. */
export function maxOrderQuantity(
  product: Pick<BrowseProduct, "in_stock" | "stock_quantity">,
  cap = 99,
): number {
  if (product.in_stock === false) return 0;
  return Math.max(0, Math.min(cap, Math.floor(product.stock_quantity)));
}

/** True only when a genuine, higher compare-at price exists. No discount is ever invented. */
export function hasCompareAt(
  product: Pick<BrowseProduct, "price_cents" | "compare_at_price_cents">,
): boolean {
  const compare = product.compare_at_price_cents;
  return typeof compare === "number" && compare > product.price_cents;
}

// ---- Paging ("load more") ------------------------------------------------------------------------

export const PAGE_SIZE = 20;

export function nextVisibleCount(
  current: number,
  total: number,
  pageSize = PAGE_SIZE,
): number {
  return Math.min(total, Math.max(pageSize, current) + pageSize);
}

export function initialVisibleCount(
  total: number,
  pageSize = PAGE_SIZE,
): number {
  return Math.min(total, pageSize);
}

// ---- Debounce --------------------------------------------------------------------------------------

export interface Debounced<A extends unknown[]> {
  (...args: A): void;
  cancel: () => void;
  flush: () => void;
}

/** Trailing-edge debounce. `flush()` runs a pending call now (used for Enter); `cancel()` drops it. */
export function debounce<A extends unknown[]>(
  fn: (...args: A) => void,
  waitMs: number,
): Debounced<A> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pending: A | null = null;

  const run = () => {
    timer = null;
    const args = pending;
    pending = null;
    if (args) fn(...args);
  };

  const debounced = ((...args: A) => {
    pending = args;
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(run, waitMs);
  }) as Debounced<A>;

  debounced.cancel = () => {
    if (timer !== null) clearTimeout(timer);
    timer = null;
    pending = null;
  };
  debounced.flush = () => {
    if (timer === null) return;
    clearTimeout(timer);
    run();
  };
  return debounced;
}

// ---- URL state -------------------------------------------------------------------------------------

export interface ListSearch {
  sort?: SortKey;
  /** true when sold-out products are hidden. Absent otherwise, so the default URL stays clean. */
  instock?: true;
}

/** Reads `sort` and `instock` from an untrusted search object. Defaults are omitted. */
export function parseListSearch(search: Record<string, unknown>): ListSearch {
  const sort = parseSortKey(search["sort"]);
  const result: ListSearch = {};
  if (sort !== DEFAULT_SORT) result.sort = sort;
  if (parseInStockOnly(search["instock"])) result.instock = true;
  return result;
}

/** Copy of `previous` with one key set, or removed when `value` is null/empty. Never mutates. */
export function withSearchParam(
  previous: Record<string, unknown>,
  key: string,
  value: string | true | null,
): Record<string, unknown> {
  const next = { ...previous };
  if (value === null || value === "") delete next[key];
  else next[key] = value;
  return next;
}
