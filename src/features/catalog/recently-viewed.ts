/**
 * Recently viewed products (Phase 12). Device-only: product ids in localStorage, nothing is sent
 * to the server. List handling is pure; the storage functions take any Storage-like object and
 * never throw (private mode, quota and disabled storage all just mean "empty").
 */

export const RECENTLY_VIEWED_KEY = "storefront.recently-viewed.v1";
export const MAX_RECENTLY_VIEWED = 12;

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/** Newest first, unique, capped. Stored data is untrusted: anything odd is dropped. */
export function parseRecentlyViewed(
  raw: string | null,
  cap = MAX_RECENTLY_VIEWED,
): string[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const seen = new Set<string>();
    const ids: string[] = [];
    for (const value of parsed) {
      if (typeof value !== "string" || !ID_PATTERN.test(value)) continue;
      if (seen.has(value)) continue;
      seen.add(value);
      ids.push(value);
      if (ids.length >= cap) break;
    }
    return ids;
  } catch {
    return [];
  }
}

/** Puts `id` first, removes any older copy, trims to `cap`. Returns a new array. */
export function addRecentlyViewed(
  current: readonly string[],
  id: string,
  cap = MAX_RECENTLY_VIEWED,
): string[] {
  if (!ID_PATTERN.test(id)) return [...current].slice(0, cap);
  return [id, ...current.filter((entry) => entry !== id)].slice(0, cap);
}

export function readRecentlyViewed(storage: StorageLike | null): string[] {
  if (!storage) return [];
  try {
    return parseRecentlyViewed(storage.getItem(RECENTLY_VIEWED_KEY));
  } catch {
    return [];
  }
}

/** Returns the list that is now stored (or would have been, if storage refused). */
export function recordRecentlyViewed(
  storage: StorageLike | null,
  id: string,
): string[] {
  const next = addRecentlyViewed(readRecentlyViewed(storage), id);
  try {
    storage?.setItem(RECENTLY_VIEWED_KEY, JSON.stringify(next));
  } catch {
    /* storage full or blocked: the list simply is not remembered */
  }
  return next;
}

export function clearRecentlyViewed(storage: StorageLike | null): void {
  try {
    storage?.removeItem(RECENTLY_VIEWED_KEY);
  } catch {
    /* nothing to do */
  }
}

/**
 * Turns remembered ids into products using LIVE catalogue data, in remembered order. Ids with no
 * live product (deleted, deactivated, hidden by RLS) are dropped. Sold-out products are kept (the
 * card says "Sold out" and cannot be added). `excludeId` hides the page being viewed.
 */
export function resolveRecentlyViewed<T extends { id: string }>(
  ids: readonly string[],
  products: readonly T[],
  options: { excludeId?: string; limit?: number } = {},
): T[] {
  const byId = new Map(
    products.map((product) => [product.id, product] as const),
  );
  const out: T[] = [];
  for (const id of ids) {
    if (id === options.excludeId) continue;
    const product = byId.get(id);
    if (product) out.push(product);
    if (out.length >= (options.limit ?? MAX_RECENTLY_VIEWED)) break;
  }
  return out;
}
