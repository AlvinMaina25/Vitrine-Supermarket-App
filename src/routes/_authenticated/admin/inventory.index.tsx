import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { InventoryAdjustDialog } from "@/components/admin/inventory-adjust-dialog";
import { InventoryHistoryPanel } from "@/components/admin/inventory-history-panel";
import { InventoryPagination } from "@/components/admin/inventory-pagination";
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
import {
  adminInventoryAllQuery,
  adminInventoryQuery,
} from "@/features/admin/inventory";
import {
  activeView,
  INVENTORY_CLASSIFY_MAX_ROWS,
  INVENTORY_PAGE_SIZE,
  INVENTORY_VIEW_LABELS,
  INVENTORY_VIEW_STATE,
  INVENTORY_VIEWS,
  pageSlice,
  parseInventoryParams,
  STOCK_STATE_LABELS,
  toInventoryListQuery,
  type InventoryParams,
} from "@/features/admin/inventory-management";
import {
  classifyStock,
  inventoryRowKey,
  LOW_STOCK_THRESHOLD,
  type StockState,
} from "@/features/admin/inventory-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { AdminInventoryRow } from "@/lib/supabase/types";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_authenticated/admin/inventory/")({
  validateSearch: (search: Record<string, unknown>): InventoryParams =>
    parseInventoryParams(search),
  head: () => ({
    meta: [
      { title: "Inventory — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: InventoryPage,
});

const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background min-h-11 px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

/**
 * /admin/inventory. Nested under the /admin layout, so signed-out visitors go to /auth and
 * non-admins see "Admin access required" and none of this UI. That only decides what to render:
 * every inventory function re-checks require_admin() in the database, so a customer who reaches
 * the URL or calls the functions directly still gets no stock data and cannot change stock.
 */
function InventoryPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const onHistory = params.tab === "history";

  function goToPage(page: number) {
    void navigate({
      search: (prev) => {
        const { page: _page, ...rest } = prev;
        return page > 1 ? { ...rest, page } : rest;
      },
    });
  }

  return (
    <>
      <AdminPageHeader
        title="Inventory"
        description="Stock for every product and variant, and every adjustment made to it."
      />

      <nav aria-label="Inventory sections" className="mb-4 flex gap-2">
        <Button asChild size="sm" variant={onHistory ? "outline" : "primary"}>
          <Link
            to="/admin/inventory"
            search={{}}
            aria-current={onHistory ? undefined : "page"}
          >
            Stock
          </Link>
        </Button>
        <Button asChild size="sm" variant={onHistory ? "primary" : "outline"}>
          <Link
            to="/admin/inventory"
            search={{ tab: "history" }}
            aria-current={onHistory ? "page" : undefined}
          >
            History
          </Link>
        </Button>
      </nav>

      {onHistory ? (
        <InventoryHistoryPanel
          productId={params.product}
          variantId={params.variant}
          page={params.page ?? 1}
          onPage={goToPage}
          onClearFilter={() => void navigate({ search: { tab: "history" } })}
        />
      ) : (
        <StockTab params={params} onPage={goToPage} />
      )}
    </>
  );
}

function StockTab({
  params,
  onPage,
}: {
  params: InventoryParams;
  onPage: (page: number) => void;
}) {
  const navigate = useNavigate({ from: Route.fullPath });
  const view = activeView(params);
  const page = params.page ?? 1;

  // "All inventory": search and paging happen in the database (admin_list_inventory).
  const serverList = useQuery({
    ...adminInventoryQuery(toInventoryListQuery(params)),
    enabled: view === "all",
    // Keep the previous page on screen while the next one loads, so filtering doesn't flash.
    placeholderData: keepPreviousData,
  });
  // Low / out of stock: the database has no such filter, so every unit is read (search still
  // runs in the database) and classified with the Phase 6A dashboard rule (see classifyStock).
  const fullList = useQuery({
    ...adminInventoryAllQuery(params.q ?? null),
    enabled: view !== "all",
    placeholderData: keepPreviousData,
  });
  const active = view === "all" ? serverList : fullList;

  const listing = useMemo(() => {
    if (view === "all") {
      const data = serverList.data;
      if (!data) return null;
      return {
        rows: data.inventory,
        known: data.inventory,
        total: data.total,
        limit: data.limit,
        offset: data.offset,
        truncated: false,
      };
    }
    const data = fullList.data;
    if (!data) return null;
    const state = INVENTORY_VIEW_STATE[view];
    const matches = data.rows.filter((row) => classifyStock(row) === state);
    return {
      rows: pageSlice(matches, page, INVENTORY_PAGE_SIZE),
      known: data.rows,
      total: matches.length,
      limit: INVENTORY_PAGE_SIZE,
      offset: (page - 1) * INVENTORY_PAGE_SIZE,
      truncated: data.truncated,
    };
  }, [view, page, serverList.data, fullList.data]);

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

  function setView(next: string) {
    void navigate({
      search: (prev) => {
        const { view: _view, page: _page, ...rest } = prev;
        // Values come from the closed option list below; the route re-validates them anyway.
        return next === "low" || next === "out"
          ? { ...rest, view: next }
          : rest;
      },
    });
  }

  function clearAll() {
    setTerm("");
    void navigate({ search: {} });
  }

  // The unit being adjusted. It is re-read from the list after every refresh so the dialog shows
  // current stock; if the unit has left the filtered view, the row as first opened is kept.
  const [selected, setSelected] = useState<AdminInventoryRow | null>(null);
  const dialogUnit = useMemo(() => {
    if (!selected) return null;
    const key = inventoryRowKey(selected);
    return (
      listing?.known.find((row) => inventoryRowKey(row) === key) ?? selected
    );
  }, [selected, listing]);

  const hasFilters = Boolean(params.q || params.view);
  const refreshing = active.isPlaceholderData;

  return (
    <>
      <div className="glass-panel mb-4 grid grid-cols-1 gap-3 rounded-(--radius-panel) p-4 md:grid-cols-[2fr_1fr_auto] md:items-end">
        <div className="space-y-1.5">
          <label
            htmlFor="inventory-search"
            className="eyebrow block text-muted-foreground"
          >
            Search
          </label>
          <TextInput
            id="inventory-search"
            type="search"
            value={term}
            maxLength={100}
            onChange={(event) => setTerm(event.target.value)}
            placeholder="Name, SKU, brand, slug or variant"
          />
        </div>
        <div className="space-y-1.5">
          <label
            htmlFor="inventory-view"
            className="eyebrow block text-muted-foreground"
          >
            Show
          </label>
          <select
            id="inventory-view"
            className={SELECT_CLASS}
            value={view}
            onChange={(event) => setView(event.target.value)}
          >
            {INVENTORY_VIEWS.map((option) => (
              <option key={option} value={option}>
                {INVENTORY_VIEW_LABELS[option]}
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

      {view !== "all" ? (
        <p className="mb-3 text-xs text-muted-foreground">
          Same rule as the dashboard: active items only; low stock is 1 to{" "}
          {LOW_STOCK_THRESHOLD} units, out of stock is none left (or a product
          marked not in stock).
        </p>
      ) : null}

      {active.isError ? (
        <InventoryError
          error={active.error}
          onRetry={() => void active.refetch()}
        />
      ) : !listing ? (
        <InventorySkeleton />
      ) : listing.rows.length === 0 ? (
        <EmptyState
          eyebrow="No inventory"
          title={
            view !== "all"
              ? `No ${INVENTORY_VIEW_LABELS[view].toLowerCase()} items`
              : hasFilters
                ? "No inventory matches"
                : "No inventory yet"
          }
          message={
            listing.total > 0
              ? "That page is past the last result."
              : view !== "all"
                ? params.q
                  ? "Nothing matches that search in this view. Try a different search."
                  : "Nothing is in this state right now."
                : hasFilters
                  ? "Try a different search or clear the filters."
                  : "Stock will appear here once products exist in the catalogue."
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
          className={cn(
            "glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4",
            refreshing && "opacity-60",
          )}
          aria-busy={refreshing}
        >
          {view !== "all" ? (
            <p className="mb-3 rounded-lg border border-border px-3 py-2 text-xs text-muted-foreground">
              Low and out-of-stock are worked out on this screen from each
              item&apos;s stock quantity (low means 1 to {LOW_STOCK_THRESHOLD}{" "}
              units, the same cut-off as the dashboard). The database does not
              store a stock status; the quantity shown is what it holds.
            </p>
          ) : null}
          {listing.truncated ? (
            <p
              role="status"
              className="mb-3 rounded-lg border border-border px-3 py-2 text-xs"
            >
              Only the first{" "}
              {INVENTORY_CLASSIFY_MAX_ROWS.toLocaleString("en-US")} items were
              checked, so this view may be incomplete. Narrow the search to see
              the rest.
            </p>
          ) : null}
          <InventoryTable rows={listing.rows} onAdjust={setSelected} />
          <InventoryPagination
            label="Inventory pagination"
            total={listing.total}
            limit={listing.limit || INVENTORY_PAGE_SIZE}
            offset={listing.offset}
            rows={listing.rows.length}
            disabled={refreshing}
            onPage={onPage}
          />
        </div>
      )}

      {dialogUnit ? (
        <InventoryAdjustDialog
          key={inventoryRowKey(dialogUnit)}
          unit={dialogUnit}
          onClose={() => setSelected(null)}
        />
      ) : null}
    </>
  );
}

function InventorySkeleton() {
  return (
    <div className="space-y-2" role="status" aria-label="Loading inventory">
      {Array.from({ length: 8 }, (_, i) => (
        <div key={i} className="skeleton h-12 rounded-lg" />
      ))}
    </div>
  );
}

function InventoryError({
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
      noun="inventory"
      action="view inventory"
      onRetry={onRetry}
    />
  );
}

const BADGE_BASE =
  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap";

const BADGE_TONE: Record<StockState, string> = {
  out_of_stock: "bg-danger/10 text-danger",
  low_stock: "bg-accent/20 text-foreground",
  in_stock: "bg-primary/10 text-primary",
  inactive: "bg-surface-strong text-muted-foreground",
};

function StockStateBadge({ state }: { state: StockState }) {
  return (
    <span className={cn(BADGE_BASE, BADGE_TONE[state])}>
      {STOCK_STATE_LABELS[state]}
    </span>
  );
}

function InventoryTable({
  rows,
  onAdjust,
}: {
  rows: AdminInventoryRow[];
  onAdjust: (row: AdminInventoryRow) => void;
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Product</TableHead>
          <TableHead>Variant</TableHead>
          <TableHead>SKU</TableHead>
          <TableHead className="text-right">Stock</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right">Actions</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((row) => (
          <TableRow key={inventoryRowKey(row)}>
            <TableCell>
              <Link
                to="/admin/products/$productId"
                params={{ productId: row.product_id }}
                className="font-medium text-primary underline-offset-2 hover:underline"
              >
                {row.product_name}
              </Link>
              {!row.product_is_active ? (
                <div className="text-xs text-muted-foreground">
                  Product inactive
                </div>
              ) : null}
            </TableCell>
            <TableCell className="text-sm">
              {row.kind === "variant" ? (
                row.variant_name
              ) : row.variant_count ? (
                <span className="text-muted-foreground">
                  Product-level stock ({row.variant_count} variant
                  {row.variant_count === 1 ? "" : "s"})
                </span>
              ) : (
                "—"
              )}
            </TableCell>
            <TableCell className="font-mono text-xs">
              {row.sku ?? "—"}
            </TableCell>
            <TableCell className="text-right font-mono text-sm whitespace-nowrap">
              {row.stock_quantity}
            </TableCell>
            <TableCell>
              <StockStateBadge state={classifyStock(row)} />
            </TableCell>
            <TableCell className="text-right whitespace-nowrap">
              <div className="flex justify-end gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => onAdjust(row)}
                >
                  Adjust
                </Button>
                <Button asChild size="sm" variant="ghost">
                  <Link
                    to="/admin/inventory"
                    search={{
                      tab: "history",
                      product: row.product_id,
                      ...(row.variant_id ? { variant: row.variant_id } : {}),
                    }}
                  >
                    History
                  </Link>
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
