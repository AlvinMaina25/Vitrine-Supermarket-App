import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

import {
  categoryTrail,
  childCategories,
} from "@/features/catalog/category-tree";
import { categoriesQuery } from "@/features/catalog/queries";
import { isSupabaseConfigured } from "@/lib/env";
import { cn } from "@/lib/utils";

const CHIP =
  "inline-flex min-h-11 shrink-0 snap-start items-center rounded-full border px-4 text-sm whitespace-nowrap transition duration-150 active:scale-[0.98]";
const IDLE =
  "border-border bg-surface-strong text-foreground/80 hover:text-foreground";
const ACTIVE = "border-primary bg-primary font-medium text-primary-foreground";

/**
 * Horizontally scrolling category navigation. Real links (touch, keyboard and screen readers
 * all work), the current page is marked with aria-current, and the active chip is scrolled into
 * view on small screens.
 */
export function CategoryRail({
  activeSlug,
  allActive = false,
}: {
  activeSlug?: string;
  /** Highlight the "All" chip (home page). */
  allActive?: boolean;
}) {
  const { data, isPending, isError } = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  const listRef = useRef<HTMLUListElement>(null);

  useEffect(() => {
    // Set scrollLeft directly. scrollIntoView() would also move the browser's keyboard
    // starting point, so the first Tab key press would skip the header and land mid-page.
    const list = listRef.current;
    const active = list?.querySelector<HTMLElement>('[aria-current="page"]');
    if (list && active) {
      list.scrollLeft = Math.max(
        0,
        active.offsetLeft - (list.clientWidth - active.offsetWidth) / 2,
      );
    }
  }, [activeSlug, allActive, data]);

  if (!isSupabaseConfigured || isError) return null;

  // Top-level categories, plus the sub-categories of the branch being viewed (so a flat row never
  // mixes parents and children of unrelated branches).
  const all = data ?? [];
  const activeCategory = all.find((entry) => entry.slug === activeSlug);
  const topId = activeCategory
    ? categoryTrail(all, activeCategory.id)[0]?.id
    : undefined;
  const ids = new Set(all.map((entry) => entry.id));
  const visible = all.flatMap((entry) =>
    !entry.parent_id || !ids.has(entry.parent_id)
      ? [entry, ...(entry.id === topId ? childCategories(all, entry.id) : [])]
      : [],
  );

  return (
    <nav
      aria-label="Categories"
      className="border-b border-border bg-background/60"
    >
      <ul
        ref={listRef}
        className="no-scrollbar relative mx-auto flex max-w-[1400px] scroll-pl-4 snap-x sm:scroll-pl-5 gap-2 overflow-x-auto px-4 py-2 sm:px-5"
      >
        {isPending ? (
          Array.from({ length: 6 }).map((_, index) => (
            <li key={index} aria-hidden>
              <span className="skeleton block h-11 w-24 shrink-0 rounded-full" />
            </li>
          ))
        ) : (
          <>
            <li>
              <Link
                to="/"
                search={{}}
                aria-current={allActive ? "page" : undefined}
                className={cn(CHIP, allActive ? ACTIVE : IDLE)}
              >
                All
              </Link>
            </li>
            {visible.map((category) => {
              const active = category.slug === activeSlug;
              return (
                <li key={category.id}>
                  <Link
                    to="/category/$slug"
                    params={{ slug: category.slug }}
                    aria-current={active ? "page" : undefined}
                    className={cn(CHIP, active ? ACTIVE : IDLE)}
                  >
                    {category.name}
                  </Link>
                </li>
              );
            })}
          </>
        )}
      </ul>
    </nav>
  );
}
