/**
 * Product discovery helpers (Phase 12). PURE: no React, no network, no clock, no storage.
 *
 * Everything here runs on the product rows the existing catalogue queries already loaded, so
 * search, filters and sorting always act on the WHOLE loaded list and only then is a page sliced
 * off it. Nothing here changes a price or a total; prices stay integer cents and are formatted
 * through src/lib/format.ts. The one number conversion is the price-range FILTER, which the URL
 * keeps in whole currency units (`?min=100&max=500`) and compares against `price_cents` using
 * MINOR_UNITS_PER_MAJOR. It never touches a displayed or charged amount.
 */

import {
  SORT_OPTIONS,
  hasCompareAt,
  normalizeSearchTerm,
  searchProducts,
  sortProducts,
  stockState,
  type BrowseProduct,
  type SortKey,
} from "./browse.ts";

/** The catalogue stores prices in minor units (cents); the price filter is typed in whole units. */
export const MINOR_UNITS_PER_MAJOR = 100;
/** Highest price-filter value accepted from a URL (whole units). Guards absurd input only. */
export const MAX_PRICE_FILTER = 10_000_000;
export const MAX_BRAND_FILTERS = 10;
const MAX_BRAND_LENGTH = 60;

/** Fields discovery reads beyond BrowseProduct. All exist on ProductRow. */
export type DiscoveryProduct = BrowseProduct;

// ---- Tolerant search -----------------------------------------------------------------------

/** Letters and digits only, lower-cased: "Milk, 1L" -> ["milk", "1l"]. */
function splitWords(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word !== "");
}

function searchTokens(term: string): string[] {
  return splitWords(normalizeSearchTerm(term));
}

/**
 * Optimal-string-alignment distance (insert, delete, substitute, swap two neighbours), with an
 * early exit once every cell of a row is above `limit`. Returns limit + 1 when over the limit.
 */
export function editDistance(a: string, b: string, limit = 2): number {
  if (a === b) return 0;
  if (Math.abs(a.length - b.length) > limit) return limit + 1;
  const rows: number[][] = [];
  for (let i = 0; i <= a.length; i += 1) {
    rows.push(new Array<number>(b.length + 1).fill(0));
    (rows[i] as number[])[0] = i;
  }
  const first = rows[0] as number[];
  for (let j = 0; j <= b.length; j += 1) first[j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    const row = rows[i] as number[];
    const above = rows[i - 1] as number[];
    let rowMin = Infinity;
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let best = Math.min(
        (above[j] as number) + 1,
        (row[j - 1] as number) + 1,
        (above[j - 1] as number) + cost,
      );
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        best = Math.min(best, ((rows[i - 2] as number[])[j - 2] as number) + 1);
      }
      row[j] = best;
      rowMin = Math.min(rowMin, best);
    }
    if (rowMin > limit) return limit + 1;
  }
  return Math.min((rows[a.length] as number[])[b.length] as number, limit + 1);
}

/**
 * How many typing mistakes a word of this length may contain. Short words must be exact:
 * a one-letter slip in "tea" or "oil" would match unrelated products.
 */
export function allowedTypos(tokenLength: number): number {
  if (tokenLength >= 8) return 2;
  if (tokenLength >= 4) return 1;
  return 0;
}

/** Distance of one typed word to the closest word of a product, or null when too far. */
function tokenDistance(token: string, words: readonly string[]): number | null {
  const allowed = allowedTypos(token.length);
  let best: number | null = null;
  for (const word of words) {
    if (word.includes(token)) return 0;
    if (allowed === 0) continue;
    const whole = editDistance(token, word, allowed);
    // Also compare with the start of a longer word, so a slip in "yogrt" still finds "yoghurt".
    const prefix =
      word.length > token.length
        ? editDistance(token, word.slice(0, token.length), allowed)
        : allowed + 1;
    const distance = Math.min(whole, prefix);
    if (distance <= allowed && (best === null || distance < best)) {
      best = distance;
    }
  }
  return best;
}

function similarity(
  product: Pick<BrowseProduct, "name" | "brand">,
  tokens: readonly string[],
): number | null {
  const words = splitWords(`${product.name} ${product.brand ?? ""}`);
  let total = 0;
  for (const token of tokens) {
    const distance = tokenDistance(token, words);
    if (distance === null) return null;
    total += distance;
  }
  return total;
}

export interface SearchOutcome<T> {
  results: T[];
  /** true when nothing matched exactly and these are close spellings instead. */
  corrected: boolean;
}

/**
 * Exact matching first (the Phase 11 behaviour). Only when that finds NOTHING does it fall back to
 * close spellings (one slip in a 4-7 letter word, two in a longer one, never in short words), so a
 * correct search is never polluted. Word order never matters. No match at all returns [].
 */
export function searchTolerant<T extends Pick<BrowseProduct, "name" | "brand">>(
  products: readonly T[],
  term: string,
): SearchOutcome<T> {
  const tokens = searchTokens(term);
  if (tokens.length === 0) return { results: [...products], corrected: false };
  const exact = searchProducts(products, term);
  if (exact.length > 0) return { results: exact, corrected: false };

  const scored: { product: T; index: number; score: number }[] = [];
  products.forEach((product, index) => {
    const score = similarity(product, tokens);
    if (score !== null) scored.push({ product, index, score });
  });
  scored.sort((a, b) => a.score - b.score || a.index - b.index);
  return {
    results: scored.map((entry) => entry.product),
    corrected: scored.length > 0,
  };
}

/** Typeahead: the best few names for a partial term. Same rules as the results page. */
export function suggestProducts<
  T extends Pick<BrowseProduct, "name" | "brand">,
>(products: readonly T[], term: string, limit = 6): T[] {
  if (normalizeSearchTerm(term).length < 2) return [];
  return searchTolerant(products, term).results.slice(0, limit);
}

// ---- Sort ----------------------------------------------------------------------------------

export type DiscoverySortKey = SortKey | "relevance";

/** Relevance exists only while a search term does; without one the default is name. */
export function defaultSortFor(hasQuery: boolean): DiscoverySortKey {
  return hasQuery ? "relevance" : "name";
}

export function sortOptionsFor(
  hasQuery: boolean,
): { value: DiscoverySortKey; label: string }[] {
  const options: { value: DiscoverySortKey; label: string }[] = [
    ...SORT_OPTIONS,
  ];
  return hasQuery
    ? [{ value: "relevance", label: "Best match" }, ...options]
    : options;
}

export function parseDiscoverySort(
  raw: unknown,
  hasQuery: boolean,
): DiscoverySortKey {
  if (raw === "relevance") return hasQuery ? "relevance" : "name";
  const known = SORT_OPTIONS.find((option) => option.value === raw);
  return known ? known.value : defaultSortFor(hasQuery);
}

// ---- Filters -------------------------------------------------------------------------------

export interface DiscoveryFilters {
  inStockOnly: boolean;
  /** Only products with a genuine compare-at price above the price (hasCompareAt). */
  onOffer: boolean;
  /** Brand names (compared case-insensitively). Empty = any brand. */
  brands: string[];
  /** Whole currency units. null = no bound. */
  minPrice: number | null;
  maxPrice: number | null;
}

export const NO_FILTERS: DiscoveryFilters = {
  inStockOnly: false,
  onOffer: false,
  brands: [],
  minPrice: null,
  maxPrice: null,
};

export function countActiveFilters(filters: DiscoveryFilters): number {
  return (
    (filters.inStockOnly ? 1 : 0) +
    (filters.onOffer ? 1 : 0) +
    filters.brands.length +
    (filters.minPrice !== null || filters.maxPrice !== null ? 1 : 0)
  );
}

function brandKey(brand: string): string {
  return brand.trim().toLowerCase();
}

export interface FilterOptions<T> {
  /**
   * Overrides "is this sold out?" for the in-stock filter. The product page and cards use it for
   * products whose stock lives on their variants. Default: the product's own stock fields.
   */
  soldOut?: (product: T) => boolean;
}

export function applyFilters<
  T extends Pick<
    BrowseProduct,
    | "brand"
    | "price_cents"
    | "compare_at_price_cents"
    | "in_stock"
    | "stock_quantity"
    | "low_stock_threshold"
  >,
>(
  products: readonly T[],
  filters: DiscoveryFilters,
  options: FilterOptions<T> = {},
): T[] {
  const soldOut =
    options.soldOut ?? ((product: T) => stockState(product).kind === "out");
  const brands = new Set(filters.brands.map(brandKey));
  const min =
    filters.minPrice === null ? null : filters.minPrice * MINOR_UNITS_PER_MAJOR;
  const max =
    filters.maxPrice === null ? null : filters.maxPrice * MINOR_UNITS_PER_MAJOR;
  return products.filter((product) => {
    if (filters.inStockOnly && soldOut(product)) return false;
    if (filters.onOffer && !hasCompareAt(product)) return false;
    if (brands.size > 0 && !brands.has(brandKey(product.brand ?? "")))
      return false;
    if (min !== null && product.price_cents < min) return false;
    if (max !== null && product.price_cents > max) return false;
    return true;
  });
}

export interface BrandFacet {
  /** Brand exactly as stored (first spelling seen). */
  label: string;
  count: number;
}

/**
 * Brands present in `products` with how many products each has under the OTHER active filters
 * (the brand filter itself is ignored, so choosing a brand does not hide the others). Products
 * with no brand are not listed. Sorted A-Z.
 */
export function brandFacets<
  T extends Pick<
    BrowseProduct,
    | "brand"
    | "price_cents"
    | "compare_at_price_cents"
    | "in_stock"
    | "stock_quantity"
    | "low_stock_threshold"
  >,
>(
  products: readonly T[],
  filters: DiscoveryFilters,
  options: FilterOptions<T> = {},
): BrandFacet[] {
  const pool = applyFilters(products, { ...filters, brands: [] }, options);
  const counts = new Map<string, BrandFacet>();
  for (const product of pool) {
    const brand = product.brand?.trim();
    if (!brand) continue;
    const key = brandKey(brand);
    const entry = counts.get(key);
    if (entry) entry.count += 1;
    else counts.set(key, { label: brand, count: 1 });
  }
  // Selected brands that the other filters hide still need a row, so they can be unticked.
  for (const selected of filters.brands) {
    const key = brandKey(selected);
    if (!counts.has(key)) counts.set(key, { label: selected, count: 0 });
  }
  return [...counts.values()].sort((a, b) =>
    a.label.localeCompare(b.label, "en", { sensitivity: "base" }),
  );
}

// ---- The whole pipeline --------------------------------------------------------------------

export interface DiscoveryQuery {
  term: string;
  filters: DiscoveryFilters;
  sort: DiscoverySortKey;
}

export interface DiscoveryResult<T> {
  /** Everything that matches, sorted. Page slicing happens AFTER this, never before. */
  results: T[];
  /** Products that matched the search term (before filters) - the filters' "of N". */
  searchedCount: number;
  corrected: boolean;
  facets: BrandFacet[];
}

export function discover<T extends BrowseProduct>(
  products: readonly T[],
  query: DiscoveryQuery,
  options: FilterOptions<T> = {},
): DiscoveryResult<T> {
  const term = normalizeSearchTerm(query.term);
  const { results: searched, corrected } = searchTolerant(products, term);
  const filtered = applyFilters(searched, query.filters, options);
  const sort = query.sort === "relevance" && term === "" ? "name" : query.sort;
  const results =
    sort === "relevance" ? filtered : sortProducts(filtered, sort);
  return {
    results,
    searchedCount: searched.length,
    corrected,
    facets: brandFacets(searched, query.filters, options),
  };
}

// ---- URL state -----------------------------------------------------------------------------

export interface DiscoverySearch {
  q?: string;
  sort?: DiscoverySortKey;
  /** Present (true) only when sold-out products are hidden. */
  instock?: true;
  offer?: true;
  /** Brand names joined with "|". Kept as one string so the URL stays readable. */
  brand?: string;
  min?: number;
  max?: number;
}

function parseWholeNumber(raw: unknown): number | null {
  const value =
    typeof raw === "number"
      ? raw
      : typeof raw === "string" && /^\s*\d{1,9}\s*$/.test(raw)
        ? Number(raw)
        : NaN;
  if (!Number.isFinite(value) || value < 0) return null;
  return Math.min(Math.floor(value), MAX_PRICE_FILTER);
}

function parseFlag(raw: unknown): boolean {
  return raw === true || raw === "1" || raw === "true" || raw === 1;
}

export function parseBrandList(raw: unknown): string[] {
  const text =
    typeof raw === "number" && Number.isFinite(raw)
      ? String(raw)
      : typeof raw === "string"
        ? raw
        : "";
  const seen = new Set<string>();
  const brands: string[] = [];
  for (const part of text.split("|")) {
    const brand = part.replace(/\s+/g, " ").trim().slice(0, MAX_BRAND_LENGTH);
    if (!brand || seen.has(brandKey(brand))) continue;
    seen.add(brandKey(brand));
    brands.push(brand);
    if (brands.length >= MAX_BRAND_FILTERS) break;
  }
  return brands;
}

/**
 * Reads an untrusted URL search object. Unknown keys are dropped and defaults are omitted, so a
 * clean URL stays clean. `allowQuery: false` is for pages without a search box (category pages).
 * If min is above max the two are swapped rather than silently returning nothing.
 */
export function parseDiscoverySearch(
  search: Record<string, unknown>,
  options: { allowQuery?: boolean } = {},
): DiscoverySearch {
  const allowQuery = options.allowQuery ?? true;
  const result: DiscoverySearch = {};
  const q = allowQuery ? normalizeSearchTerm(search["q"]) : "";
  if (q) result.q = q;

  const sort = parseDiscoverySort(search["sort"], q !== "");
  if (sort !== defaultSortFor(q !== "")) result.sort = sort;

  if (parseFlag(search["instock"])) result.instock = true;
  if (parseFlag(search["offer"])) result.offer = true;

  const brands = parseBrandList(search["brand"]);
  if (brands.length > 0) result.brand = brands.join("|");

  let min = parseWholeNumber(search["min"]);
  let max = parseWholeNumber(search["max"]);
  if (min !== null && max !== null && min > max) [min, max] = [max, min];
  if (min !== null && min > 0) result.min = min;
  if (max !== null) result.max = max;
  return result;
}

export function filtersFromSearch(search: DiscoverySearch): DiscoveryFilters {
  return {
    inStockOnly: search.instock === true,
    onOffer: search.offer === true,
    brands: parseBrandList(search.brand),
    minPrice: search.min ?? null,
    maxPrice: search.max ?? null,
  };
}

export function sortFromSearch(search: DiscoverySearch): DiscoverySortKey {
  return search.sort ?? defaultSortFor(Boolean(search.q));
}

/** Returns a copy of `previous` with the given keys replaced; null/""/false removes a key. */
export function patchSearch(
  previous: Record<string, unknown>,
  patch: Record<string, string | number | true | null | undefined>,
): Record<string, unknown> {
  const next = { ...previous };
  for (const [key, value] of Object.entries(patch)) {
    if (value === null || value === undefined || value === "") delete next[key];
    else next[key] = value;
  }
  return next;
}

export type FilterKey = "instock" | "offer" | "brand" | "price";

export interface FilterChip {
  /** Stable key for React lists and tests. */
  id: string;
  label: string;
  key: FilterKey;
  /** The brand a brand chip stands for. */
  value?: string;
}

/** One removable chip per active filter (one per brand; one for the whole price range). */
export function activeFilterChips(
  search: DiscoverySearch,
  currency: string,
): FilterChip[] {
  const chips: FilterChip[] = [];
  if (search.instock) {
    chips.push({ id: "instock", key: "instock", label: "In stock only" });
  }
  if (search.offer) {
    chips.push({ id: "offer", key: "offer", label: "On offer" });
  }
  for (const brand of parseBrandList(search.brand)) {
    chips.push({
      id: `brand:${brandKey(brand)}`,
      key: "brand",
      label: brand,
      value: brand,
    });
  }
  const { min, max } = search;
  if (min !== undefined || max !== undefined) {
    const label =
      min !== undefined && max !== undefined
        ? `${currency} ${min}–${max}`
        : min !== undefined
          ? `From ${currency} ${min}`
          : `Up to ${currency} ${max}`;
    chips.push({ id: "price", key: "price", label });
  }
  return chips;
}

/** The URL patch that removes one chip. */
export function removeFilterPatch(
  search: DiscoverySearch,
  chip: Pick<FilterChip, "key" | "value">,
): Record<string, string | number | true | null> {
  switch (chip.key) {
    case "instock":
      return { instock: null };
    case "offer":
      return { offer: null };
    case "price":
      return { min: null, max: null };
    case "brand": {
      const remaining = parseBrandList(search.brand).filter(
        (brand) => brandKey(brand) !== brandKey(chip.value ?? ""),
      );
      return { brand: remaining.length > 0 ? remaining.join("|") : null };
    }
  }
}

/** The URL patch for "Clear all": filters go, the search term and sort stay. */
export const CLEAR_FILTERS_PATCH = {
  instock: null,
  offer: null,
  brand: null,
  min: null,
  max: null,
} as const;

/** Toggle one brand in/out of the URL's brand list. */
export function toggleBrandPatch(
  search: DiscoverySearch,
  brand: string,
): Record<string, string | null> {
  const current = parseBrandList(search.brand);
  const key = brandKey(brand);
  const next = current.some((entry) => brandKey(entry) === key)
    ? current.filter((entry) => brandKey(entry) !== key)
    : [...current, brand].slice(0, MAX_BRAND_FILTERS);
  return { brand: next.length > 0 ? next.join("|") : null };
}

/**
 * Typed price inputs -> URL patch. Blank or invalid text clears that bound. A reversed pair is
 * swapped. Whole units only (decimals are dropped), matching what the URL accepts.
 */
export function priceRangePatch(
  minText: string,
  maxText: string,
): { min: number | null; max: number | null } {
  let min = parseWholeNumber(minText.replace(/[,\s]/g, ""));
  let max = parseWholeNumber(maxText.replace(/[,\s]/g, ""));
  if (min !== null && max !== null && min > max) [min, max] = [max, min];
  return { min: min !== null && min > 0 ? min : null, max };
}

// ---- Result announcements ------------------------------------------------------------------

/** The sentence a screen reader hears (and sighted users read) after the list changes. */
export function describeResults(input: {
  shown: number;
  searchedCount: number;
  filtersActive: boolean;
  corrected: boolean;
}): string {
  const noun = input.shown === 1 ? "product" : "products";
  const base =
    input.filtersActive && input.shown !== input.searchedCount
      ? `${input.shown} ${noun} of ${input.searchedCount}`
      : `${input.shown} ${noun}`;
  return input.corrected ? `${base}, showing similar spellings` : base;
}
