import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import {
  ProductActiveBadge,
  ProductStockBadge,
} from "@/components/admin/product-badges";
import { ProductEditForm } from "@/components/admin/product-edit-form";
import { ProductStatusCard } from "@/components/admin/product-status-card";
import { ProductVariantsCard } from "@/components/admin/product-variants-card";
import { ConfigNotice, ErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { isUuid } from "@/features/admin/product-management";
import { adminProductQuery } from "@/features/admin/products";
import { AdminProductNotFoundError } from "@/features/admin/products-result";
import { formatDateTime, formatPrice } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { AdminProductDetail } from "@/lib/supabase/types";

export const Route = createFileRoute(
  "/_authenticated/admin/products/$productId",
)({
  head: () => ({
    meta: [
      { title: "Product — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: ProductDetailPage,
});

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt className="eyebrow text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-sm break-words">{children}</dd>
    </div>
  );
}

function SectionCard({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
      <h2 className="font-display text-lg font-semibold">{title}</h2>
      <div className="mt-4">{children}</div>
    </section>
  );
}

function ProductNotFound() {
  return (
    <ErrorState
      title="Product not found"
      message="This product doesn't exist, or the link is wrong."
      code="404"
    />
  );
}

function ProductDetailPage() {
  const { productId } = Route.useParams();
  const validId = isUuid(productId);
  // A malformed id is answered here; it is never sent to the database.
  const query = useQuery({ ...adminProductQuery(productId), enabled: validId });

  const back = (
    <Button asChild variant="outline" size="sm">
      <Link to="/admin/products" search={{}}>
        ← All products
      </Link>
    </Button>
  );

  if (!validId) {
    return (
      <>
        <AdminPageHeader title="Product" actions={back} />
        <ProductNotFound />
      </>
    );
  }

  if (query.isPending) {
    return (
      <>
        <AdminPageHeader title="Product" actions={back} />
        <div className="space-y-4" role="status" aria-label="Loading product">
          <div className="skeleton h-24 rounded-(--radius-panel)" />
          <div className="skeleton h-96 rounded-(--radius-panel)" />
        </div>
      </>
    );
  }

  if (query.isError) {
    return (
      <>
        <AdminPageHeader title="Product" actions={back} />
        <DetailError error={query.error} onRetry={() => void query.refetch()} />
      </>
    );
  }

  return <ProductDetail detail={query.data} back={back} />;
}

function DetailError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  if (error instanceof AdminProductNotFoundError) return <ProductNotFound />;
  return (
    <AdminQueryError
      error={error}
      noun="this product"
      action="view products"
      onRetry={onRetry}
    />
  );
}

function ProductDetail({
  detail,
  back,
}: {
  detail: AdminProductDetail;
  back: ReactNode;
}) {
  const { product, category, variants } = detail;

  return (
    <>
      <AdminPageHeader
        title={product.name}
        description={product.sku ? `SKU ${product.sku}` : "No SKU set"}
        actions={back}
      />

      <div className="space-y-4">
        <SectionCard title="Overview">
          <div className="grid grid-cols-1 gap-6 md:grid-cols-[auto_1fr]">
            <div className="h-32 w-32 overflow-hidden rounded-lg border border-border bg-surface-strong">
              {product.image_url ? (
                <img
                  src={product.image_url}
                  alt={product.name}
                  loading="lazy"
                  decoding="async"
                  className="h-full w-full object-cover"
                />
              ) : (
                <div className="flex h-full w-full items-center justify-center p-2 text-center text-xs text-muted-foreground">
                  No image
                </div>
              )}
            </div>
            <dl className="grid grid-cols-1 gap-x-8 gap-y-4 sm:grid-cols-2 lg:grid-cols-3">
              <Row label="Status">
                <ProductActiveBadge active={product.is_active} />
              </Row>
              <Row label="Stock">
                <ProductStockBadge inStock={product.in_stock} />
                <span className="ml-2 font-mono text-xs text-muted-foreground">
                  {product.stock_quantity} units
                </span>
              </Row>
              <Row label="Category">
                {category ? (
                  <>
                    {category.name}
                    {category.is_active ? null : (
                      <span className="text-muted-foreground"> (inactive)</span>
                    )}
                  </>
                ) : (
                  "—"
                )}
              </Row>
              <Row label="Price">
                <span className="font-mono">
                  {formatPrice(product.price_cents)}
                </span>
                {product.compare_at_price_cents !== null ? (
                  <span className="ml-2 font-mono text-xs text-muted-foreground line-through">
                    {formatPrice(product.compare_at_price_cents)}
                  </span>
                ) : null}
              </Row>
              <Row label="Created">{formatDateTime(product.created_at)}</Row>
              <Row label="Last updated">
                {formatDateTime(product.updated_at)}
              </Row>
            </dl>
          </div>
          <p className="mt-4 text-xs text-muted-foreground">
            Stock and the product image are shown for reference. They can't be
            changed from this screen: the backend has no stock or image-upload
            function for products yet.
            {product.is_active ? (
              <>
                {" "}
                <Link
                  to="/product/$slug"
                  params={{ slug: product.slug }}
                  className="text-primary underline-offset-2 hover:underline"
                >
                  View in the storefront
                </Link>
                .
              </>
            ) : null}
          </p>
        </SectionCard>

        <SectionCard title="Status">
          <ProductStatusCard product={product} />
        </SectionCard>

        <SectionCard title="Edit product">
          {/* Keyed by id only: a background refetch must never wipe edits in progress. */}
          <ProductEditForm key={product.id} product={product} />
        </SectionCard>

        <SectionCard title={`Variants (${variants.length})`}>
          <ProductVariantsCard productId={product.id} variants={variants} />
        </SectionCard>
      </div>
    </>
  );
}
