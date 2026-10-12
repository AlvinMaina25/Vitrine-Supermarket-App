import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { ArrowRight, ImageOff } from "lucide-react";

import { ProductShelf } from "@/components/catalog/product-shelf";
import { Button } from "@/components/ui-kit/button";
import {
  hasCompareAt,
  sortProducts,
  stockState,
} from "@/features/catalog/browse";
import { categoriesQuery, productsQuery } from "@/features/catalog/queries";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";
import heroCrate from "@/assets/hero-crate.jpg";

/** One clear primary action. Copy is generic: no claims about freshness, speed or prices. */
export function HomeHero() {
  return (
    <section
      aria-labelledby="hero-title"
      className="mx-auto max-w-[1400px] px-4 pt-4 sm:px-5 sm:pt-5"
    >
      <div className="relative overflow-hidden rounded-(--radius-panel) outline-1 -outline-offset-1 outline-border">
        <img
          src={heroCrate}
          alt=""
          width={1232}
          height={544}
          fetchPriority="high"
          decoding="async"
          className="h-[260px] w-full object-cover sm:h-[320px] lg:h-[380px]"
        />
        <div className="absolute inset-0 bg-gradient-to-t from-foreground/85 via-foreground/45 to-foreground/10" />
        <div className="absolute inset-x-0 bottom-0 p-5 sm:p-8">
          <h1
            id="hero-title"
            className="max-w-[18ch] font-display text-3xl font-bold text-balance text-primary-foreground sm:text-4xl lg:text-5xl"
          >
            Groceries from {storeConfig.name}
          </h1>
          <p className="mt-2 max-w-[48ch] text-pretty text-sm text-primary-foreground/90 sm:text-base">
            Browse the shelves, fill your basket, then choose delivery or pickup
            at checkout.
          </p>
          <Button asChild variant="onImage" size="touch" className="mt-4">
            <a href="#all-products">
              Start shopping <ArrowRight aria-hidden className="size-4" />
            </a>
          </Button>
        </div>
      </div>
    </section>
  );
}

export function FeaturedCategories() {
  const { data, isPending, isError } = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  if (!isSupabaseConfigured || isError) return null;
  if (!isPending && (!data || data.length === 0)) return null;

  return (
    <section
      aria-labelledby="featured-categories-title"
      className="mx-auto max-w-[1400px] px-4 pt-8 sm:px-5"
    >
      <h2
        id="featured-categories-title"
        className="mb-3 font-display text-xl font-bold tracking-tight sm:text-2xl"
      >
        Shop by category
      </h2>
      <ul className="grid grid-cols-2 gap-3 sm:gap-4 md:grid-cols-4">
        {isPending
          ? Array.from({ length: 4 }).map((_, index) => (
              <li key={index} aria-hidden>
                <div className="skeleton aspect-[4/3] w-full rounded-(--radius-card)" />
              </li>
            ))
          : data?.slice(0, 8).map((category) => (
              <li key={category.id}>
                <Link
                  to="/category/$slug"
                  params={{ slug: category.slug }}
                  className="group block overflow-hidden rounded-(--radius-card) bg-surface outline-1 -outline-offset-1 outline-border transition-colors duration-150 hover:bg-surface-strong active:bg-surface-strong"
                >
                  <div className="relative aspect-[4/3] w-full bg-background">
                    {category.image_url ? (
                      <img
                        src={category.image_url}
                        alt=""
                        loading="lazy"
                        decoding="async"
                        width={400}
                        height={300}
                        className="absolute inset-0 size-full object-cover"
                      />
                    ) : (
                      <div className="grid size-full place-items-center text-muted-foreground">
                        <ImageOff aria-hidden className="size-6" />
                      </div>
                    )}
                  </div>
                  <div className="p-3">
                    <span className="font-display text-base font-semibold group-hover:underline">
                      {category.name}
                    </span>
                    {category.tagline ? (
                      <span className="mt-0.5 line-clamp-1 block text-sm text-muted-foreground">
                        {category.tagline}
                      </span>
                    ) : null}
                  </div>
                </Link>
              </li>
            ))}
      </ul>
    </section>
  );
}

/**
 * Two shelves from the one existing all-products query (shared cache with the catalogue below):
 *  - "On offer": products that really carry a higher compare-at price.
 *  - "Recently added": newest first by created_at.
 * There is no popularity or sales data in the catalogue read path, so there is no "Popular"
 * shelf. The shelves hide themselves when empty and stay quiet if the query fails (the
 * catalogue section below shows the error with a Retry button).
 */
export function HomeShelves() {
  const query = useQuery({
    ...productsQuery(),
    enabled: isSupabaseConfigured,
  });
  if (!isSupabaseConfigured || query.isError) return null;

  const all = query.data ?? [];
  const available = all.filter((product) => stockState(product).kind !== "out");
  const onOffer = available.filter(hasCompareAt).slice(0, 10);
  const recent = sortProducts(available, "newest").slice(0, 10);

  return (
    <>
      <ProductShelf id="on-offer" title="On offer" products={onOffer} />
      <ProductShelf
        id="recently-added"
        title="Recently added"
        products={recent}
        loading={query.isPending}
      />
    </>
  );
}
