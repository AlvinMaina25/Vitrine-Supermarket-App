import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Check } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";

import { RecentlyViewedShelf } from "@/components/catalog/recently-viewed-shelf";
import { StickyBuyBar } from "@/components/catalog/sticky-buy-bar";
import { VariantSelector } from "@/components/catalog/variant-selector";
import { PriceBlock } from "@/components/catalog/price-block";
import { ProductImage } from "@/components/catalog/product-image";
import { ProductShelf } from "@/components/catalog/product-shelf";
import { SaleBadge, StockBadge } from "@/components/catalog/stock-badge";
import { Breadcrumbs, type Crumb } from "@/components/layout/breadcrumbs";
import {
  BrowseCta,
  ConfigNotice,
  NotFoundState,
  ProductPageSkeleton,
  SlowNetworkHint,
  StorefrontErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { QuantityStepper } from "@/components/ui-kit/quantity-stepper";
import { useCart } from "@/features/cart/cart-provider";
import { hasCompareAt } from "@/features/catalog/browse";
import { categoryTrail } from "@/features/catalog/category-tree";
import {
  initialVariantId,
  orderedVariants,
  purchasableForProduct,
  purchasableForVariant,
  quantityLimit,
  quantityMessage,
  relatedProducts,
  type Purchasable,
} from "@/features/catalog/product-detail";
import {
  categoriesQuery,
  productQuery,
  productVariantsQuery,
  productsQuery,
} from "@/features/catalog/queries";
import { useDocumentTitle } from "@/features/catalog/use-document-title";
import { useRecentlyViewed } from "@/features/catalog/use-recently-viewed";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";
import type { ProductRow, ProductVariantRow } from "@/lib/supabase/types";

export const Route = createFileRoute("/product/$slug")({
  validateSearch: (search: Record<string, unknown>): { variant?: string } =>
    typeof search["variant"] === "string" && search["variant"].length <= 64
      ? { variant: search["variant"] }
      : {},
  head: ({ params }) => {
    const label = params.slug.replace(/-/g, " ");
    return {
      meta: [
        { title: `${label} — ${storeConfig.name}` },
        {
          name: "description",
          content: `${label} available at ${storeConfig.name}.`,
        },
        { property: "og:title", content: `${label} — ${storeConfig.name}` },
        {
          property: "og:description",
          content: `${label} available at ${storeConfig.name}.`,
        },
      ],
    };
  },
  component: ProductPage,
});

function Purchase({
  product,
  variant,
  purchasable,
}: {
  product: ProductRow;
  variant: ProductVariantRow | null;
  purchasable: Purchasable;
}) {
  const { lines, add } = useCart();
  const [quantity, setQuantity] = useState(1);
  const [justAdded, setJustAdded] = useState(false);
  const blockRef = useRef<HTMLDivElement>(null);

  const variantId = variant?.id ?? null;
  const inBasket =
    lines.find(
      (line) =>
        line.productId === product.id && (line.variantId ?? null) === variantId,
    )?.quantity ?? 0;
  const { room, stepperMax } = quantityLimit(purchasable.maxUnits, inBasket);
  const chosen = Math.min(quantity, stepperMax);
  const label = variant ? `${product.name}, ${variant.name}` : product.name;
  const soldOut = purchasable.state.kind === "out";
  const note = quantityMessage({
    maxUnits: purchasable.maxUnits,
    inBasket,
    requested: chosen,
  });

  function addToBasket() {
    if (soldOut || room === 0) return;
    add(product, chosen, variant);
    setQuantity(1);
    setJustAdded(true);
    toast.success(`${label} added to your basket`);
  }

  useEffect(() => {
    if (!justAdded) return;
    const timer = setTimeout(() => setJustAdded(false), 2500);
    return () => clearTimeout(timer);
  }, [justAdded]);

  if (soldOut) {
    return (
      <div className="mt-6">
        <Button size="touchBlock" variant="outline" disabled>
          Sold out
        </Button>
        <p className="mt-2 text-sm text-muted-foreground">
          {variant
            ? "This option is unavailable right now. Try another option."
            : "This product is unavailable right now."}
        </p>
      </div>
    );
  }

  const buttonText =
    room === 0
      ? "Maximum in basket"
      : justAdded
        ? "Added to basket"
        : "Add to basket";

  return (
    <div className="mt-6">
      <div ref={blockRef} className="flex flex-wrap items-center gap-3">
        <QuantityStepper
          editable
          value={chosen}
          min={1}
          max={stepperMax}
          label={label}
          onChange={setQuantity}
        />
        <Button
          size="touch"
          className="min-w-44 flex-1"
          disabled={room === 0}
          onClick={addToBasket}
        >
          {justAdded ? <Check aria-hidden className="size-4" /> : null}
          {buttonText}
        </Button>
      </div>
      <p role="status" aria-live="polite" className="mt-3 min-h-6 text-sm">
        {note ? (
          <span className="block text-muted-foreground">{note}</span>
        ) : null}
        {inBasket > 0 ? (
          <>
            <span className="text-muted-foreground">
              {inBasket} in your basket.{" "}
            </span>
            <Link
              to="/cart"
              className="inline-flex min-h-11 items-center font-medium text-primary underline-offset-4 hover:underline"
            >
              View basket
            </Link>
          </>
        ) : null}
      </p>
      <StickyBuyBar
        targetRef={blockRef}
        label={label}
        priceCents={purchasable.priceCents}
        disabled={room === 0}
        buttonText={buttonText}
        onAdd={addToBasket}
      />
    </div>
  );
}

function ProductPage() {
  const { slug } = Route.useParams();
  const { variant: requestedVariant } = Route.useSearch();
  const navigate = Route.useNavigate();
  const query = useQuery({
    ...productQuery(slug),
    enabled: isSupabaseConfigured,
  });
  const categories = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  const product = query.data ?? null;
  const variantsQuery = useQuery({
    ...productVariantsQuery(product?.id ?? ""),
    enabled: isSupabaseConfigured && Boolean(product),
  });
  const all = useQuery({
    ...productsQuery(),
    enabled: isSupabaseConfigured && Boolean(product),
  });
  const { record } = useRecentlyViewed();
  const productId = product?.id;
  useEffect(() => {
    if (productId) record(productId);
  }, [productId, record]);
  useDocumentTitle(product?.name ?? null);

  const category =
    product?.category_id && categories.data
      ? categories.data.find((entry) => entry.id === product.category_id)
      : undefined;

  const frame = (children: React.ReactNode) => (
    <div className="mx-auto max-w-[1400px] px-4 pt-4 pb-6 sm:px-5">
      {children}
    </div>
  );

  if (!isSupabaseConfigured) return frame(<ConfigNotice />);
  if (query.isError) {
    return frame(
      <StorefrontErrorState
        error={query.error}
        onRetry={() => void query.refetch()}
      />,
    );
  }
  if (query.isPending) {
    return frame(
      <>
        <ProductPageSkeleton />
        <SlowNetworkHint loading />
      </>,
    );
  }
  if (!product) {
    return (
      <div className="mx-auto max-w-2xl px-4 pt-8 sm:px-5">
        <NotFoundState
          title="We couldn't find that product"
          message="It may have been removed or the link may be out of date."
          action={<BrowseCta />}
        />
      </div>
    );
  }

  const variants = orderedVariants(variantsQuery.data ?? []);
  const hasVariants = variants.length > 0;
  const variantsLoading = variantsQuery.isPending;
  const selectedId = initialVariantId(variants, requestedVariant);
  const variant =
    (selectedId && variants.find((entry) => entry.id === selectedId)) || null;
  const purchasable: Purchasable = variant
    ? purchasableForVariant(variant, product.sku)
    : purchasableForProduct(product);
  const state = purchasable.state;

  const trail = category
    ? categoryTrail(categories.data ?? [], category.id)
    : [];
  const crumbs: Crumb[] = [
    { label: "Home", to: "home" },
    ...trail.map(
      (entry) =>
        ({ label: entry.name, to: "category", slug: entry.slug }) as const,
    ),
    { label: product.name },
  ];
  const others = relatedProducts(product, all.data ?? [], 8);
  const facts: [string, string][] = [
    ...(product.brand
      ? ([["Brand", product.brand]] as [string, string][])
      : []),
    ["Unit", product.unit_label ?? "each"],
    ...(purchasable.sku
      ? ([["SKU", purchasable.sku]] as [string, string][])
      : []),
  ];

  return (
    <>
      {frame(
        <>
          <Breadcrumbs items={crumbs} />
          <div className="grid grid-cols-1 gap-6 md:grid-cols-2 md:gap-10">
            <div className="relative overflow-hidden rounded-(--radius-panel) outline-1 -outline-offset-1 outline-border">
              <ProductImage
                src={product.image_url}
                alt={product.name}
                priority
                sizes="(min-width:768px) 50vw, 100vw"
                className={state.kind === "out" ? "opacity-60" : ""}
              />
              <div className="absolute top-3 left-3 flex gap-1.5">
                {variantsLoading ? null : <StockBadge state={state} />}
                {!variantsLoading &&
                state.kind !== "out" &&
                hasCompareAt({
                  price_cents: purchasable.priceCents,
                  compare_at_price_cents: purchasable.compareAtCents,
                }) ? (
                  <SaleBadge />
                ) : null}
              </div>
            </div>

            <div>
              {product.brand ? (
                <p className="eyebrow text-muted-foreground">{product.brand}</p>
              ) : null}
              <h1 className="mt-1 font-display text-3xl font-bold text-balance sm:text-4xl">
                {product.name}
              </h1>
              {variantsLoading ? (
                <div aria-busy="true" aria-label="Loading price and options">
                  <div className="skeleton mt-3 h-8 w-32 rounded" />
                  <div className="skeleton mt-5 h-16 w-full max-w-sm rounded-xl" />
                </div>
              ) : variantsQuery.isError ? (
                <div className="mt-4">
                  <StorefrontErrorState
                    error={variantsQuery.error}
                    onRetry={() => void variantsQuery.refetch()}
                  />
                </div>
              ) : (
                <>
                  <PriceBlock
                    priceCents={purchasable.priceCents}
                    compareAtCents={purchasable.compareAtCents}
                    size="lg"
                    className="mt-3"
                  />
                  <p className="mt-1 font-mono text-xs text-muted-foreground">
                    {product.unit_label ?? "each"}
                  </p>
                  <p
                    role="status"
                    aria-live="polite"
                    className="mt-3 inline-flex min-h-6 items-center gap-1.5 text-sm font-medium text-primary"
                  >
                    {state.kind === "in" ? (
                      <>
                        <Check aria-hidden className="size-4" /> In stock
                      </>
                    ) : state.kind === "low" ? (
                      <span className="text-foreground">
                        Only {state.left} left
                      </span>
                    ) : (
                      <span className="text-foreground">Sold out</span>
                    )}
                  </p>
                  {hasVariants ? (
                    <VariantSelector
                      variants={variants}
                      selectedId={selectedId}
                      onSelect={(id) =>
                        void navigate({
                          replace: true,
                          search: { variant: id },
                          resetScroll: false,
                        })
                      }
                    />
                  ) : null}
                </>
              )}

              {product.description ? (
                <p className="mt-4 max-w-[60ch] text-pretty text-muted-foreground">
                  {product.description}
                </p>
              ) : null}

              {!variantsLoading && !variantsQuery.isError ? (
                <Purchase
                  key={`${product.id}:${variant?.id ?? ""}`}
                  product={product}
                  variant={variant}
                  purchasable={purchasable}
                />
              ) : null}

              <dl className="mt-6 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 border-t border-border pt-4 text-sm">
                {facts.map(([term, value]) => (
                  <div key={term} className="contents">
                    <dt className="text-muted-foreground">{term}</dt>
                    <dd className="break-words">{value}</dd>
                  </div>
                ))}
              </dl>
              <ul className="mt-4 space-y-1 text-sm text-muted-foreground">
                <li>
                  Delivery areas, fees and time slots are shown at checkout.
                </li>
                <li>Cash on delivery is available.</li>
              </ul>
            </div>
          </div>
        </>,
      )}
      <ProductShelf
        id="related"
        title="You may also like"
        subtitle={category ? `More from ${category.name}` : ""}
        products={others}
      />
      <RecentlyViewedShelf excludeId={product.id} />
      <div className="h-20 md:hidden" aria-hidden />
    </>
  );
}
