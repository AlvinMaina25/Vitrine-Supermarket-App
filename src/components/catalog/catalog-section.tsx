import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useMemo, useRef, useState, type ReactNode } from "react";

import { ActiveFilters } from "@/components/catalog/active-filters";
import { FiltersSheet, SortSelect } from "@/components/catalog/catalog-toolbar";
import {
  FilterControls,
  type SearchPatch,
} from "@/components/catalog/filter-controls";
import {
  ProductGrid,
  ProductGridSkeleton,
} from "@/components/catalog/product-card";
import {
  BrowseCta,
  ConfigNotice,
  EmptyState,
  SlowNetworkHint,
  StorefrontErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  initialVisibleCount,
  nextVisibleCount,
  normalizeSearchTerm,
  stockState,
} from "@/features/catalog/browse";
import { childCategories } from "@/features/catalog/category-tree";
import {
  CLEAR_FILTERS_PATCH,
  activeFilterChips,
  countActiveFilters,
  defaultSortFor,
  describeResults,
  discover,
  filtersFromSearch,
  removeFilterPatch,
  sortFromSearch,
  type DiscoverySearch,
} from "@/features/catalog/discovery";
import {
  categoriesQuery,
  productsQuery,
  variantSummaryQuery,
} from "@/features/catalog/queries";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";
import type { ProductRow } from "@/lib/supabase/types";

/** Category links for an empty result. Top-level categories only; no popularity data exists. */
function CategorySuggestions() {
  const { data } = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  if (!data) return null;
  const top = data.filter((category) => !category.parent_id).slice(0, 8);
  if (top.length === 0) return null;
  return (
    <div className="mt-4">
      <p className="text-sm text-muted-foreground">Or browse a category:</p>
      <ul className="mt-2 flex flex-wrap gap-2">
        {top.map((category) => (
          <li key={category.id}>
            <Link
              to="/category/$slug"
              params={{ slug: category.slug }}
              className="inline-flex min-h-11 items-center rounded-full border border-border bg-surface-strong px-4 text-sm hover:text-primary"
            >
              {category.name}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

function ProductList({ products }: { products: ProductRow[] }) {
  const [visible, setVisible] = useState(() =>
    initialVisibleCount(products.length),
  );
  const shown = products.slice(0, visible);
  return (
    <>
      <ProductGrid products={shown} />
      {visible < products.length ? (
        <div className="mt-6 flex flex-col items-center gap-2">
          <p className="text-sm text-muted-foreground">
            Showing {shown.length} of {products.length}
          </p>
          <Button
            variant="outline"
            size="touch"
            onClick={() =>
              setVisible((current) =>
                nextVisibleCount(current, products.length),
              )
            }
          >
            Show more
          </Button>
        </div>
      ) : null}
    </>
  );
}

/** Same footprint as the real sidebar, so nothing jumps when the data arrives. */
function ControlsSkeleton() {
  return (
    <div aria-hidden className="hidden space-y-4 lg:block">
      <div className="skeleton h-5 w-24 rounded" />
      <div className="skeleton h-11 w-full rounded-lg" />
      <div className="skeleton h-11 w-full rounded-lg" />
      <div className="skeleton h-5 w-24 rounded" />
      <div className="skeleton h-11 w-full rounded-lg" />
    </div>
  );
}

/**
 * The catalogue browser. Loads the whole shelf through the existing productsQuery, then searches,
 * filters, sorts and pages it on the client. The existing query has no server-side search, sort,
 * filter or paging, so this is the only place those can happen. Sorting and filtering always run
 * over the full loaded list BEFORE a page is sliced off it, so "Price: low to high" is global,
 * not just the visible page. All state is read from, and written to, the URL by the route.
 */
export function CatalogSection({
  title,
  headingAs: Heading = "h2",
  categoryIds,
  search = {},
  onPatch,
  id,
  intro,
  scopeNote,
}: {
  title: string;
  headingAs?: "h1" | "h2";
  /** Only products in these categories (a category and its sub-categories). */
  categoryIds?: readonly string[] | undefined;
  search?: DiscoverySearch;
  /** Provide to show the filter and sort controls and make chips removable. */
  onPatch?: ((patch: SearchPatch) => void) | undefined;
  id?: string;
  intro?: ReactNode;
  /** Shown under the count, e.g. "Includes products from Milk and Yoghurt". */
  scopeNote?: ReactNode;
}) {
  const query = useQuery({
    ...productsQuery(),
    enabled: isSupabaseConfigured,
  });
  const categories = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  // Optional. If this read fails the lists simply judge stock from the product row, as before.
  const optionsQuery = useQuery({
    ...variantSummaryQuery(),
    enabled: isSupabaseConfigured,
  });
  const headingRef = useRef<HTMLHeadingElement>(null);

  const term = normalizeSearchTerm(search.q);
  const hasQuery = term !== "";
  const sort = sortFromSearch(search);
  const filters = useMemo(
    () => filtersFromSearch(search),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- keyed on the URL values themselves
    [search.instock, search.offer, search.brand, search.min, search.max],
  );
  const activeCount = countActiveFilters(filters);
  const optionSummaries = optionsQuery.data;

  const scoped = useMemo(() => {
    const all = query.data ?? [];
    if (!categoryIds) return all;
    const wanted = new Set(categoryIds);
    return all.filter(
      (product) => product.category_id && wanted.has(product.category_id),
    );
  }, [query.data, categoryIds]);

  const result = useMemo(
    () =>
      discover(
        scoped,
        { term, filters, sort },
        {
          soldOut: (product) => {
            const options = optionSummaries?.get(product.id);
            return options
              ? !options.anyAvailable
              : stockState(product).kind === "out";
          },
        },
      ),
    [scoped, term, filters, sort, optionSummaries],
  );
  const products = result.results;

  const hasControls = Boolean(onPatch);
  const chips = activeFilterChips(search, storeConfig.currency);
  const resultText = describeResults({
    shown: products.length,
    searchedCount: result.searchedCount,
    filtersActive: activeCount > 0,
    corrected: result.corrected,
  });

  function patch(next: SearchPatch) {
    onPatch?.(next);
  }
  /** The chip row disappears when its last chip goes, so park focus on the results heading. */
  function patchAndFocus(next: SearchPatch) {
    patch(next);
    headingRef.current?.focus();
  }

  const controls = (
    <FilterControls
      filters={filters}
      search={search}
      facets={result.facets}
      currency={storeConfig.currency}
      onPatch={patch}
    />
  );

  const subCategories =
    categories.data && categoryIds?.[0]
      ? childCategories(categories.data, categoryIds[0])
      : [];
  const showSidebar = hasControls && query.isSuccess && scoped.length > 0;

  return (
    <section
      id={id}
      aria-labelledby={id ? `${id}-title` : undefined}
      className="mx-auto max-w-[1400px] scroll-mt-32 px-4 pt-8 sm:px-5"
    >
      <div className="mb-4 flex flex-wrap items-end justify-between gap-x-4 gap-y-2">
        <div>
          <Heading
            ref={headingRef}
            tabIndex={-1}
            id={id ? `${id}-title` : undefined}
            className="font-display text-xl font-bold tracking-tight text-balance outline-none sm:text-2xl"
          >
            {title}
          </Heading>
          {intro}
          {query.isSuccess ? (
            <p
              role="status"
              aria-live="polite"
              className="mt-1 text-sm text-muted-foreground"
            >
              {resultText}
            </p>
          ) : (
            <p aria-hidden className="mt-1 h-5" />
          )}
          {scopeNote}
        </div>
        {hasControls ? (
          showSidebar ? (
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
              <FiltersSheet activeCount={activeCount} resultText={resultText}>
                {controls}
              </FiltersSheet>
              <SortSelect
                value={sort}
                hasQuery={hasQuery}
                onChange={(next) =>
                  patch({
                    sort: next === defaultSortFor(hasQuery) ? null : next,
                  })
                }
              />
            </div>
          ) : query.isPending ? (
            <div aria-hidden className="skeleton h-11 w-48 rounded-lg" />
          ) : null
        ) : null}
      </div>

      {subCategories.length > 0 ? (
        <nav aria-label={`Sub-categories of ${title}`} className="mb-4">
          <ul className="flex flex-wrap gap-2">
            {subCategories.map((category) => (
              <li key={category.id}>
                <Link
                  to="/category/$slug"
                  params={{ slug: category.slug }}
                  className="inline-flex min-h-11 items-center rounded-full border border-border bg-surface-strong px-4 text-sm hover:text-primary"
                >
                  {category.name}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      ) : null}

      {hasControls ? (
        <ActiveFilters
          chips={chips}
          onRemove={(chip) => patchAndFocus(removeFilterPatch(search, chip))}
          onClearAll={() => patchAndFocus({ ...CLEAR_FILTERS_PATCH })}
        />
      ) : null}

      {result.corrected && term && products.length > 0 ? (
        <p className="mb-4 text-sm text-muted-foreground">
          No exact matches for “{term}”. Showing close spellings instead.
        </p>
      ) : null}

      <div
        className={
          showSidebar || (hasControls && query.isPending)
            ? "lg:grid lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-8"
            : undefined
        }
      >
        {hasControls ? (
          showSidebar ? (
            <aside
              aria-label="Filters"
              className="hidden lg:block lg:self-start"
            >
              {controls}
            </aside>
          ) : query.isPending ? (
            <ControlsSkeleton />
          ) : null
        ) : null}

        <div className="min-w-0">
          {!isSupabaseConfigured ? (
            <ConfigNotice />
          ) : query.isPending ? (
            <>
              <ProductGridSkeleton />
              <SlowNetworkHint loading />
            </>
          ) : query.isError ? (
            <StorefrontErrorState
              error={query.error}
              onRetry={() => void query.refetch()}
            />
          ) : products.length === 0 ? (
            activeCount > 0 && result.searchedCount > 0 ? (
              <EmptyState
                eyebrow="No matches"
                title="No products match these filters"
                message="Try removing a filter, or clear them all to see everything again."
                action={
                  <Button
                    size="touch"
                    onClick={() => patchAndFocus({ ...CLEAR_FILTERS_PATCH })}
                  >
                    Clear all filters
                  </Button>
                }
              />
            ) : term ? (
              <EmptyState
                eyebrow="No results"
                title={`Nothing matches “${term}”`}
                message="Check the spelling, try a shorter or different word, or browse a category."
                action={
                  <div>
                    <div className="flex flex-wrap gap-2">
                      {onPatch ? (
                        <Button
                          size="touch"
                          onClick={() => patchAndFocus({ q: null })}
                        >
                          Clear search
                        </Button>
                      ) : null}
                      <BrowseCta />
                    </div>
                    <CategorySuggestions />
                  </div>
                }
              />
            ) : (
              <EmptyState
                eyebrow="Nothing here yet"
                title="This shelf is empty"
                message="There are no products in this view right now. Try another category."
                action={
                  <div>
                    <BrowseCta />
                    <CategorySuggestions />
                  </div>
                }
              />
            )
          ) : (
            <ProductList
              key={`${categoryIds?.join(",") ?? "all"}|${term}|${sort}|${search.instock ?? ""}|${search.offer ?? ""}|${search.brand ?? ""}|${search.min ?? ""}|${search.max ?? ""}`}
              products={products}
            />
          )}
        </div>
      </div>
    </section>
  );
}
