/**
 * Category hierarchy helpers (Phase 12). PURE. `categories.parent_id` already exists, so
 * sub-category navigation and breadcrumbs need no new data. Inactive categories are hidden from
 * the browser by RLS already; these helpers also skip them defensively. Cycles are tolerated.
 */

export interface TreeCategory {
  id: string;
  slug: string;
  name: string;
  parent_id: string | null;
  position: number;
  is_active: boolean;
}

function byPosition<T extends TreeCategory>(a: T, b: T): number {
  return (
    a.position - b.position ||
    a.name.localeCompare(b.name, "en", { sensitivity: "base" })
  );
}

export function childCategories<T extends TreeCategory>(
  categories: readonly T[],
  parentId: string,
): T[] {
  return categories
    .filter((c) => c.is_active && c.parent_id === parentId)
    .sort(byPosition);
}

/** The category plus every active descendant, as ids. Safe against parent loops. */
export function subtreeIds<T extends TreeCategory>(
  categories: readonly T[],
  rootId: string,
): string[] {
  const seen = new Set<string>([rootId]);
  const queue = [rootId];
  while (queue.length > 0) {
    const id = queue.shift() as string;
    for (const child of childCategories(categories, id)) {
      if (!seen.has(child.id)) {
        seen.add(child.id);
        queue.push(child.id);
      }
    }
  }
  return [...seen];
}

/** Root first, the category itself last. Stops if a parent is missing or loops back. */
export function categoryTrail<T extends TreeCategory>(
  categories: readonly T[],
  categoryId: string,
): T[] {
  const byId = new Map(categories.map((c) => [c.id, c] as const));
  const trail: T[] = [];
  const seen = new Set<string>();
  let current = byId.get(categoryId);
  while (current && !seen.has(current.id)) {
    seen.add(current.id);
    trail.unshift(current);
    current = current.parent_id ? byId.get(current.parent_id) : undefined;
  }
  return trail;
}
