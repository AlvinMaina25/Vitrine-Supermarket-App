import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
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
import {
  getPageInfo,
  ORDER_STATUSES,
  ORDERS_PAGE_SIZE,
  parseOrderListParams,
  PAYMENT_STATUSES,
  toOrderListFilters,
  type OrderListParams,
} from "@/features/admin/order-management";
import { adminOrdersQuery } from "@/features/admin/orders";
import { getOrderDeliveryDisplay } from "@/features/orders/delivery-display";
import {
  OrderStatusBadge,
  PaymentStatusBadge,
} from "@/features/orders/components/status-badge";
import {
  ORDER_STATUS_LABELS,
  PAYMENT_METHOD_LABELS,
  PAYMENT_STATUS_LABELS,
} from "@/features/orders/status";
import { formatCalendarDate, formatDateTime, formatMoney } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { AdminOrderListItem } from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/admin/orders/")({
  validateSearch: (search: Record<string, unknown>): OrderListParams =>
    parseOrderListParams(search),
  head: () => ({
    meta: [{ title: "Orders — Admin" }, { name: "robots", content: "noindex" }],
  }),
  component: OrdersPage,
});

const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background min-h-11 px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

function OrdersPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  const orders = useQuery({
    ...adminOrdersQuery(toOrderListFilters(params)),
    // Keep the previous page on screen while the next one loads, so filtering doesn't flash.
    placeholderData: keepPreviousData,
  });

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

  function setFilter(key: "status" | "payment", value: string) {
    void navigate({
      search: (prev) => {
        const { [key]: _old, page: _page, ...rest } = prev;
        if (!value) return rest;
        // Values come from the closed option lists below; the route re-validates them anyway.
        return { ...rest, [key]: value } as OrderListParams;
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

  const hasFilters = Boolean(params.q || params.status || params.payment);

  return (
    <>
      <AdminPageHeader
        title="Orders"
        description="Search, filter and open any order."
      />

      <div className="glass-panel mb-4 grid grid-cols-1 gap-3 rounded-(--radius-panel) p-4 md:grid-cols-[2fr_1fr_1fr_auto] md:items-end">
        <div className="space-y-1.5">
          <label
            htmlFor="order-search"
            className="eyebrow block text-muted-foreground"
          >
            Search
          </label>
          <TextInput
            id="order-search"
            type="search"
            value={term}
            maxLength={100}
            onChange={(event) => setTerm(event.target.value)}
            placeholder="Order number, customer name, email or phone"
          />
        </div>
        <div className="space-y-1.5">
          <label
            htmlFor="order-status"
            className="eyebrow block text-muted-foreground"
          >
            Order status
          </label>
          <select
            id="order-status"
            className={SELECT_CLASS}
            value={params.status ?? ""}
            onChange={(event) => setFilter("status", event.target.value)}
          >
            <option value="">All statuses</option>
            {ORDER_STATUSES.map((status) => (
              <option key={status} value={status}>
                {ORDER_STATUS_LABELS[status]}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1.5">
          <label
            htmlFor="order-payment"
            className="eyebrow block text-muted-foreground"
          >
            Payment status
          </label>
          <select
            id="order-payment"
            className={SELECT_CLASS}
            value={params.payment ?? ""}
            onChange={(event) => setFilter("payment", event.target.value)}
          >
            <option value="">All payment statuses</option>
            {PAYMENT_STATUSES.map((status) => (
              <option key={status} value={status}>
                {PAYMENT_STATUS_LABELS[status]}
              </option>
            ))}
          </select>
        </div>
        <Button
          variant="outline"
          disabled={!hasFilters && term === ""}
          onClick={() => {
            setTerm("");
            void navigate({ search: {} });
          }}
        >
          Clear
        </Button>
      </div>

      {orders.isPending ? (
        <OrdersSkeleton />
      ) : orders.isError ? (
        <OrdersError
          error={orders.error}
          onRetry={() => void orders.refetch()}
        />
      ) : orders.data.orders.length === 0 ? (
        <EmptyState
          eyebrow="No orders"
          title={hasFilters ? "No orders match" : "No orders yet"}
          message={
            hasFilters
              ? orders.data.total > 0
                ? "That page is past the last result."
                : "Try a different search or clear the filters."
              : "Orders will appear here as customers place them."
          }
          action={
            hasFilters ? (
              <Button
                variant="outline"
                onClick={() => {
                  setTerm("");
                  void navigate({ search: {} });
                }}
              >
                Clear search and filters
              </Button>
            ) : undefined
          }
        />
      ) : (
        <div
          className={`glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4 ${
            orders.isPlaceholderData ? "opacity-60" : ""
          }`}
          aria-busy={orders.isPlaceholderData}
        >
          <OrdersTable orders={orders.data.orders} />
          <Pagination
            total={orders.data.total}
            limit={orders.data.limit}
            offset={orders.data.offset}
            rows={orders.data.orders.length}
            disabled={orders.isPlaceholderData}
            onPage={goToPage}
          />
        </div>
      )}
    </>
  );
}

function OrdersSkeleton() {
  return (
    <div className="space-y-2" role="status" aria-label="Loading orders">
      {Array.from({ length: 8 }, (_, i) => (
        <div key={i} className="skeleton h-12 rounded-lg" />
      ))}
    </div>
  );
}

function OrdersError({
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
      noun="orders"
      action="view orders"
      onRetry={onRetry}
    />
  );
}

function deliveryLabel(order: AdminOrderListItem): string {
  return getOrderDeliveryDisplay({
    delivery_method: order.delivery_method,
    delivery_method_label: order.delivery_method_label,
    delivery_fee_cents: order.delivery_fee_cents,
    delivery_slot_date: order.delivery_slot_date,
    delivery_slot_start: null,
    delivery_slot_end: null,
    delivery_slot_label: null,
  }).methodLabel;
}

function OrdersTable({ orders }: { orders: AdminOrderListItem[] }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Order</TableHead>
          <TableHead>Customer</TableHead>
          <TableHead>Placed</TableHead>
          <TableHead>Delivery</TableHead>
          <TableHead>Payment</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right">Total</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {orders.map((order) => (
          <TableRow key={order.id}>
            <TableCell>
              <Link
                to="/admin/orders/$orderId"
                params={{ orderId: order.id }}
                className="font-mono text-xs font-medium text-primary underline-offset-2 hover:underline"
              >
                {order.order_number}
              </Link>
            </TableCell>
            <TableCell>
              <div className="text-sm">
                {order.customer.full_name ?? order.customer.email ?? "—"}
              </div>
              {order.customer.full_name && order.customer.email ? (
                <div className="text-xs text-muted-foreground">
                  {order.customer.email}
                </div>
              ) : null}
            </TableCell>
            <TableCell className="text-xs whitespace-nowrap text-muted-foreground">
              {formatDateTime(order.placed_at)}
            </TableCell>
            <TableCell className="text-sm">
              {deliveryLabel(order)}
              {order.delivery_slot_date ? (
                <div className="text-xs text-muted-foreground">
                  {formatCalendarDate(order.delivery_slot_date)}
                </div>
              ) : null}
            </TableCell>
            <TableCell>
              <PaymentStatusBadge status={order.payment_status} />
              <div className="mt-1 text-xs text-muted-foreground">
                {PAYMENT_METHOD_LABELS[order.payment_method]}
              </div>
            </TableCell>
            <TableCell>
              <OrderStatusBadge status={order.status} />
            </TableCell>
            <TableCell className="text-right font-mono text-xs whitespace-nowrap">
              {formatMoney(order.total_cents, order.currency)}
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
  const info = getPageInfo(total, limit || ORDERS_PAGE_SIZE, offset, rows);
  return (
    <nav
      aria-label="Orders pagination"
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
