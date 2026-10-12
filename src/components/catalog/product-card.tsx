import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Check } from "lucide-react";
import { memo, useEffect, useState } from "react";
import { toast } from "sonner";

import { PriceBlock } from "@/components/catalog/price-block";
import { ProductImage } from "@/components/catalog/product-image";
import { SaleBadge, StockBadge } from "@/components/catalog/stock-badge";
import { Button } from "@/components/ui-kit/button";
import { QuantityStepper } from "@/components/ui-kit/quantity-stepper";
import { useCart } from "@/features/cart/cart-provider";
import {
  hasCompareAt,
  maxOrderQuantity,
  stockState,
} from "@/features/catalog/browse";
import { variantSummaryQuery } from "@/features/catalog/queries";
import { isSupabaseConfigured } from "@/lib/env";
import { formatPrice } from "@/lib/format";
import type { ProductRow } from "@/lib/supabase/types";

const GRID =
  "grid grid-cols-2 gap-3 sm:gap-4 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5";

function ProductCardBase({ product }: { product: ProductRow }) {
  const { lines, add, setQuantity } = useCart();
  const [justAdded, setJustAdded] = useState(false);
  const { data: options, isSuccess: optionsKnown } = useQuery({
    ...variantSummaryQuery(),
    enabled: isSupabaseConfigured,
    select: (map) => map.get(product.id),
  });
  // A product with options is bought by choosing one; sold out means every option is.
  // Until the options read has succeeded we cannot tell a plain product from one with options, so
  // the card makes no stock claim and offers a link to the product page instead of quick-add.
  const state = options
    ? options.anyAvailable
      ? ({ kind: "in" } as const)
      : ({ kind: "out" } as const)
    : optionsKnown
      ? stockState(product)
      : ({ kind: "in" } as const);
  const soldOut = state.kind === "out";
  const max = maxOrderQuantity(product);
  const inBasket =
    lines.find((line) => line.productId === product.id && !line.variantId)
      ?.quantity ?? 0;

  useEffect(() => {
    if (!justAdded) return;
    const timer = setTimeout(() => setJustAdded(false), 1800);
    return () => clearTimeout(timer);
  }, [justAdded]);

  return (
    <article className="group relative flex w-full flex-col overflow-hidden rounded-(--radius-card) bg-surface outline-1 -outline-offset-1 outline-border transition duration-150 hover:bg-surface-strong">
      <div className="relative">
        <Link
          to="/product/$slug"
          params={{ slug: product.slug }}
          tabIndex={-1}
          aria-hidden="true"
          className="block"
        >
          <ProductImage
            src={product.image_url}
            alt={product.name}
            sizes="(min-width:1280px) 20vw, (min-width:1024px) 25vw, (min-width:768px) 33vw, 50vw"
            className={soldOut ? "opacity-60" : ""}
          />
        </Link>
        <div className="pointer-events-none absolute top-2 left-2 z-10 flex flex-col items-start gap-1">
          <StockBadge state={state} />
          {!soldOut && !options && hasCompareAt(product) ? <SaleBadge /> : null}
        </div>
      </div>

      <div className="flex flex-1 flex-col p-3">
        <Link
          to="/product/$slug"
          params={{ slug: product.slug }}
          className="font-display text-[15px] leading-tight font-semibold text-balance [overflow-wrap:anywhere] after:absolute after:inset-0 after:z-0 after:content-[''] hover:underline"
        >
          {product.name}
        </Link>
        <div className="mt-0.5 font-mono text-xs text-muted-foreground">
          {product.unit_label ?? "each"}
        </div>
        {options ? (
          <p className="mt-2 text-base font-semibold tabular-nums">
            {options.minPriceCents === options.maxPriceCents ? "" : "From "}
            {formatPrice(options.minPriceCents)}
          </p>
        ) : (
          <PriceBlock
            priceCents={product.price_cents}
            compareAtCents={product.compare_at_price_cents}
            className="mt-2"
          />
        )}

        <div className="relative z-10 mt-auto pt-3">
          {!optionsKnown ? (
            <Button asChild size="touchBlock" variant="outline">
              <Link
                to="/product/$slug"
                params={{ slug: product.slug }}
                aria-label={`View ${product.name}`}
              >
                View product
              </Link>
            </Button>
          ) : soldOut ? (
            <Button size="touchBlock" variant="outline" disabled>
              Sold out
            </Button>
          ) : options ? (
            <Button asChild size="touchBlock" variant="outline">
              <Link
                to="/product/$slug"
                params={{ slug: product.slug }}
                aria-label={`Choose options for ${product.name}`}
              >
                Choose options
              </Link>
            </Button>
          ) : inBasket > 0 ? (
            <QuantityStepper
              size="sm"
              min={0}
              max={max}
              value={inBasket}
              label={product.name}
              className="w-full justify-between"
              onChange={(next) => setQuantity(product.id, next, null)}
            />
          ) : (
            <Button
              size="touchBlock"
              aria-label={`Add ${product.name} to basket`}
              onClick={() => {
                add(product, 1);
                setJustAdded(true);
                toast.success(`${product.name} added to your basket`);
              }}
            >
              {justAdded ? (
                <>
                  <Check aria-hidden className="size-4" /> Added
                </>
              ) : (
                "Add"
              )}
            </Button>
          )}
        </div>
      </div>
    </article>
  );
}

/** Memoised: the grid re-renders only the cards whose product object changed. */
export const ProductCard = memo(ProductCardBase);

export function ProductCardSkeleton() {
  return (
    <div className="overflow-hidden rounded-(--radius-card) bg-surface outline-1 -outline-offset-1 outline-border">
      <div className="skeleton aspect-square w-full" />
      <div className="p-3">
        <div className="skeleton h-4 w-3/4 rounded" />
        <div className="skeleton mt-2 h-3 w-1/2 rounded" />
        <div className="skeleton mt-3 h-4 w-16 rounded" />
        <div className="skeleton mt-3 h-11 w-full rounded-full" />
      </div>
    </div>
  );
}

export function ProductGrid({ products }: { products: ProductRow[] }) {
  return (
    <ul className={GRID}>
      {products.map((product) => (
        <li key={product.id} className="flex">
          <ProductCard product={product} />
        </li>
      ))}
    </ul>
  );
}

export function ProductGridSkeleton({ count = 10 }: { count?: number }) {
  return (
    <div aria-busy="true" aria-label="Loading products" className={GRID}>
      {Array.from({ length: count }).map((_, index) => (
        <ProductCardSkeleton key={index} />
      ))}
    </div>
  );
}
