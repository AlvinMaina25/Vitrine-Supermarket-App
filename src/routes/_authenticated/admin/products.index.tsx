import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import {
  ProductActiveBadge,
  ProductStockBadge,
} from "@/components/admin/product-badges";
import {
  ConfigNotice,
  EmptyState,
  ErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { TextInput } from "@/components/ui-kit/field";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { getPageInfo } from "@/features/admin/order-management";
import {
  parseProductListParams,
  PRODUCT_STATUS_FILTERS,
  PRODUCT_STATUS_LABELS,
  PRODUCTS_PAGE_SIZE,
  toProductListQuery,
  type ProductListParams,
} from "@/features/admin/product-management";
import { adminProductsQuery } from "@/features/admin/products";
import { categoriesQuery } from "@/features/catalog/queries";
import { formatPrice } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { ProductRow } from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/admin/products/")({
  validateSearch: (search: Record<string, unknown>): ProductListParams =>
    parseProductListParams(search),
  head: () => ({
    meta: [
      { title: "Products — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: ProductsPage,
});

const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background min-h-11 px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

function ProductsPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  // Searching, filtering and paging all happen in the database (admin_list_products).
  const products = useQuery({
    ...adminProductsQuery(toProductListQuery(params)),
    // Keep the previous page on screen while the next one loads, so filtering doesn't flash.
    placeholderData: keepPreviousData,
  });
  const categories = useQuery(categoriesQuery());
  const categoryNames = useMemo(
    () =>
      new Map(
        (categories.data ?? []).map((category) => [category.id, category.name]),
      ),
    [categories.data],
  );

  // The URL holds the committed search; the box holds what is being typed.
  const [term, setTerm] = useState(params.q ?? "");
  useEffect(() => setTerm(params.q ?? ""), [params.q]);

  // Search runs on the server, after a short pause so each keystroke is not a request.
  useEffect(() => {
    const next = term.trim();
    if (next === (params.q ?? "")) return;
    const timer = setTimeout(() => {
      void navigate({
        search: (prev) => {
          const { q: _q, page: _page, ...rest } = prev;
          return next ? { ...rest, q: next } : rest;
        },
        replace: true,
      });
    }, 350);
    return () => clearTimeout(timer);
  }, [term, params.q, navigate]);

  function setFilter(key: "status" | "category", value: string) {
    void navigate({
      search: (prev) => {
        const { [key]: _old, page: _page, ...rest } = prev;
        if (!value) return rest;
        // Values come from the closed option lists below; the route re-validates them anyway.
        return { ...rest, [key]: value } as ProductListParams;
      },
    });
  }

  function goToPage(page: number) {
    void navigate({
      search: (prev) => {
        const { page: _page, ...rest } = prev;
        return page > 1 ? { ...rest, page } : rest;
      },
    });
  }

  const hasFilters = Boolean(params.q || params.status || params.category);

  function clearAll() {
    setTerm("");
    void navigate({ search: {} });
  }

  return (
    <>
      <AdminPageHeader
        title="Products"
        description="Search, filter and open any product."
        actions={
          <Button asChild size="sm">
            <Link to="/admin/products/new">New product</Link>
          </Button>
        }
      />

      <div className="glass-panel mb-4 grid grid-cols-1 gap-3 rounded-(--radius-panel) p-4 md:grid-cols-[2fr_1fr_1fr_auto] md:items-end">
        <div className="space-y-1.5">
          <label
            htmlFor="product-search"
            className="eyebrow block text-muted-foreground"
          >
            Search
          </label>
          <TextInput
            id="product-search"
            type="search"
            value={term}
            maxLength={100}
            onChange={(event) => setTerm(event.target.value)}
            placeholder="Name, SKU, brand, slug or category"
          />
        </div>
        <div className="space-y-1.5">
          <label
            htmlFor="product-status"
            className="eyebrow block text-muted-foreground"
          >
            Status
          </label>
          <select
            id="product-status"
            className={SELECT_CLASS}
            value={params.status ?? ""}
            onChange={(event) => setFilter("status", event.target.value)}
          >
            <option value="">All products</option>
            {PRODUCT_STATUS_FILTERS.map((status) => (
              <option key={status} value={status}>
                {PRODUCT_STATUS_LABELS[status]}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5">
          <label
            htmlFor="product-category-filter"
            className="eyebrow block text-muted-foreground"
          >
            Category
          </label>
          <select
            id="product-category-filter"
            className={SELECT_CLASS}
            value={params.category ?? ""}
            disabled={categories.isPending || categories.isError}
            onChange={(event) => setFilter("category", event.target.value)}
          >
            <option value="">All categories</option>
            {/* A category in the URL stays selected even before the list has loaded. */}
            {params.category && !categoryNames.has(params.category) ? (
              <option value={params.category}>Selected category</option>
            ) : null}
            {(categories.data ?? []).map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
                {category.is_active ? "" : " (inactive)"}
              </option>
            ))}
          </select>
        </div>
        <Button
          variant="outline"
          disabled={!hasFilters && term === ""}
          onClick={clearAll}
        >
          Clear
        </Button>
      </div>

      {products.isPending ? (
        <ProductsSkeleton />
      ) : products.isError ? (
        <ProductsError
          error={products.error}
          onRetry={() => void products.refetch()}
        />
      ) : products.data.products.length === 0 ? (
        <EmptyState
          eyebrow="No products"
          title={hasFilters ? "No products match" : "No products yet"}
          message={
            hasFilters
              ? products.data.total > 0
                ? "That page is past the last result."
                : "Try a different search or clear the filters."
              : "Products will appear here once they exist in the catalogue."
          }
          action={
            hasFilters ? (
              <Button variant="outline" onClick={clearAll}>
                Clear search and filters
              </Button>
            ) : undefined
          }
        />
      ) : (
        <div
          className={`glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4 ${
            products.isPlaceholderData ? "opacity-60" : ""
          }`}
          aria-busy={products.isPlaceholderData}
        >
          <ProductsTable
            products={products.data.products}
            categoryNames={categoryNames}
          />
          <Pagination
            total={products.data.total}
            limit={products.data.limit}
            offset={products.data.offset}
            rows={products.data.products.length}
            disabled={products.isPlaceholderData}
            onPage={goToPage}
          />
        </div>
      )}
    </>
  );
}

function ProductsSkeleton() {
  return (
    <div className="space-y-2" role="status" aria-label="Loading products">
      {Array.from({ length: 8 }, (_, i) => (
        <div key={i} className="skeleton h-12 rounded-lg" />
      ))}
    </div>
  );
}

function ProductsError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  return (
    <AdminQueryError
      error={error}
      noun="products"
      action="view products"
      onRetry={onRetry}
    />
  );
}

function ProductsTable({
  products,
  categoryNames,
}: {
  products: ProductRow[];
  categoryNames: Map<string, string>;
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Product</TableHead>
          <TableHead>SKU</TableHead>
          <TableHead>Category</TableHead>
          <TableHead className="text-right">Price</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Stock</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {products.map((product) => (
          <TableRow key={product.id}>
            <TableCell>
              <Link
                to="/admin/products/$productId"
                params={{ productId: product.id }}
                className="font-medium text-primary underline-offset-2 hover:underline"
              >
                {product.name}
              </Link>
              {product.brand ? (
                <div className="text-xs text-muted-foreground">
                  {product.brand}
                </div>
              ) : null}
            </TableCell>
            <TableCell className="font-mono text-xs">
              {product.sku ?? "—"}
            </TableCell>
            <TableCell className="text-sm">
              {product.category_id
                ? (categoryNames.get(product.category_id) ?? "—")
                : "—"}
            </TableCell>
            <TableCell className="text-right font-mono text-xs whitespace-nowrap">
              {formatPrice(product.price_cents)}
              {product.unit_label ? (
                <div className="font-sans text-muted-foreground">
                  {product.unit_label}
                </div>
              ) : null}
            </TableCell>
            <TableCell>
              <ProductActiveBadge active={product.is_active} />
            </TableCell>
            <TableCell>
              <ProductStockBadge inStock={product.in_stock} />
              <div className="mt-1 font-mono text-xs text-muted-foreground">
                {product.stock_quantity} units
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function Pagination({
  total,
  limit,
  offset,
  rows,
  disabled,
  onPage,
}: {
  total: number;
  limit: number;
  offset: number;
  rows: number;
  disabled: boolean;
  onPage: (page: number) => void;
}) {
  const info = getPageInfo(total, limit || PRODUCTS_PAGE_SIZE, offset, rows);
  return (
    <nav
      aria-label="Products pagination"
      className="mt-3 flex flex-wrap items-center justify-between gap-3 border-t border-border px-2 pt-3"
    >
      <p className="text-xs text-muted-foreground">
        Showing {info.from}–{info.to} of {total.toLocaleString("en-US")} · Page{" "}
        {info.page} of {info.pageCount}
      </p>
      <div className="flex gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={disabled || !info.hasPrevious}
          onClick={() => onPage(info.page - 1)}
        >
          Previous
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={disabled || !info.hasNext}
          onClick={() => onPage(info.page + 1)}
        >
          Next
        </Button>
      </div>
    </nav>
  );
}
