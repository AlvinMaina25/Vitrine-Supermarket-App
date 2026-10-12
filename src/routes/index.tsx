import { createFileRoute } from "@tanstack/react-router";

import { CatalogSection } from "@/components/catalog/catalog-section";
import {
  FeaturedCategories,
  HomeHero,
  HomeShelves,
} from "@/components/catalog/home-sections";
import { CategoryRail } from "@/components/layout/category-rail";
import { TrustStrip } from "@/components/layout/trust-strip";
import { RecentlyViewedShelf } from "@/components/catalog/recently-viewed-shelf";
import type { SearchPatch } from "@/components/catalog/filter-controls";
import {
  parseDiscoverySearch,
  patchSearch,
  type DiscoverySearch,
} from "@/features/catalog/discovery";
import { useDocumentTitle } from "@/features/catalog/use-document-title";
import { storeConfig } from "@/lib/env";

export const Route = createFileRoute("/")({
  validateSearch: (search: Record<string, unknown>): DiscoverySearch =>
    parseDiscoverySearch(search),
  head: () => ({
    meta: [
      { title: `${storeConfig.name} — online groceries` },
      {
        name: "description",
        content: `Shop groceries online at ${storeConfig.name}. Choose delivery or pickup at checkout.`,
      },
      {
        property: "og:title",
        content: `${storeConfig.name} — online groceries`,
      },
      {
        property: "og:description",
        content: `Shop groceries online at ${storeConfig.name}.`,
      },
    ],
  }),
  component: Home,
});

function Home() {
  const search = Route.useSearch();
  const navigate = Route.useNavigate();
  const q = search.q;

  useDocumentTitle(q ? `Search: ${q}` : null);

  const onPatch = (patch: SearchPatch) =>
    void navigate({
      replace: true,
      search: (previous) =>
        parseDiscoverySearch(
          patchSearch(previous as Record<string, unknown>, patch),
        ),
    });

  if (q) {
    return (
      <>
        <CategoryRail allActive />
        <CatalogSection
          title={`Results for “${q}”`}
          headingAs="h1"
          search={search}
          onPatch={onPatch}
        />
        <RecentlyViewedShelf />
      </>
    );
  }

  return (
    <>
      <CategoryRail allActive />
      <HomeHero />
      <TrustStrip />
      <FeaturedCategories />
      <HomeShelves />
      <RecentlyViewedShelf />
      <CatalogSection
        id="all-products"
        title="All products"
        search={search}
        onPatch={onPatch}
      />
    </>
  );
}
