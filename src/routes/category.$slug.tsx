import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { CatalogSection } from "@/components/catalog/catalog-section";
import { Breadcrumbs } from "@/components/layout/breadcrumbs";
import { CategoryRail } from "@/components/layout/category-rail";
import {
  ConfigNotice,
  NotFoundState,
  SlowNetworkHint,
  StorefrontErrorState,
} from "@/components/states/states";
import type { SearchPatch } from "@/components/catalog/filter-controls";
import {
  categoryTrail,
  childCategories,
  subtreeIds,
} from "@/features/catalog/category-tree";
import {
  parseDiscoverySearch,
  patchSearch,
  type DiscoverySearch,
} from "@/features/catalog/discovery";
import { categoriesQuery } from "@/features/catalog/queries";
import { useDocumentTitle } from "@/features/catalog/use-document-title";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";

export const Route = createFileRoute("/category/$slug")({
  validateSearch: (search: Record<string, unknown>): DiscoverySearch =>
    parseDiscoverySearch(search, { allowQuery: false }),
  head: ({ params }) => {
    const label = params.slug.replace(/-/g, " ");
    return {
      meta: [
        { title: `${label} — ${storeConfig.name}` },
        {
          name: "description",
          content: `Shop ${label} at ${storeConfig.name}.`,
        },
        { property: "og:title", content: `${label} — ${storeConfig.name}` },
        {
          property: "og:description",
          content: `Shop ${label} at ${storeConfig.name}.`,
        },
      ],
    };
  },
  component: CategoryPage,
});

function CategoryPage() {
  const { slug } = Route.useParams();
  const search = Route.useSearch();
  const navigate = Route.useNavigate();
  const categories = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });

  const onPatch = (patch: SearchPatch) =>
    void navigate({
      replace: true,
      search: (previous) =>
        parseDiscoverySearch(
          patchSearch(previous as Record<string, unknown>, patch),
          { allowQuery: false },
        ),
    });

  const category = categories.data?.find((entry) => entry.slug === slug);
  useDocumentTitle(category?.name ?? null);
  const trail = category
    ? categoryTrail(categories.data ?? [], category.id)
    : [];
  const ids = category
    ? subtreeIds(categories.data ?? [], category.id)
    : undefined;
  const children = category
    ? childCategories(categories.data ?? [], category.id)
    : [];

  return (
    <>
      <CategoryRail activeSlug={slug} />
      {!isSupabaseConfigured ? (
        <div className="mx-auto max-w-[1400px] px-4 pt-6 sm:px-5">
          <ConfigNotice />
        </div>
      ) : categories.isPending ? (
        <div className="mx-auto max-w-[1400px] px-4 pt-6 sm:px-5">
          <div aria-busy="true" aria-label="Loading category">
            <div className="skeleton h-4 w-40 rounded" />
            <div className="skeleton mt-4 h-8 w-56 rounded" />
          </div>
          <SlowNetworkHint loading />
        </div>
      ) : categories.isError ? (
        <div className="mx-auto max-w-[1400px] px-4 pt-6 sm:px-5">
          <StorefrontErrorState
            error={categories.error}
            onRetry={() => void categories.refetch()}
          />
        </div>
      ) : !category ? (
        <div className="mx-auto max-w-2xl px-4 pt-8 sm:px-5">
          <NotFoundState
            title="We couldn't find that category"
            message="It may have been renamed or removed. Pick another category above, or browse everything."
          />
        </div>
      ) : (
        <>
          <div className="mx-auto max-w-[1400px] px-4 pt-4 sm:px-5">
            <Breadcrumbs
              items={[
                { label: "Home", to: "home" },
                ...trail.slice(0, -1).map(
                  (entry) =>
                    ({
                      label: entry.name,
                      to: "category",
                      slug: entry.slug,
                    }) as const,
                ),
                { label: category.name },
              ]}
            />
          </div>
          <CatalogSection
            title={category.name}
            headingAs="h1"
            categoryIds={ids}
            search={search}
            onPatch={onPatch}
            intro={
              category.description || category.tagline ? (
                <p className="mt-1 max-w-[60ch] text-sm text-pretty text-muted-foreground">
                  {category.description ?? category.tagline}
                </p>
              ) : null
            }
            scopeNote={
              children.length > 0 ? (
                <p className="text-sm text-muted-foreground">
                  Includes products from{" "}
                  {children.map((c) => c.name).join(", ")}.
                </p>
              ) : null
            }
          />
        </>
      )}
    </>
  );
}
