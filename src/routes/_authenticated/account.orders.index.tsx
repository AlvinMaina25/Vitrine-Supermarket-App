import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";

import {
  BrowseCta,
  EmptyState,
  StorefrontErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  OrderStatusBadge,
  PaymentStatusBadge,
} from "@/features/orders/components/status-badge";
import {
  filterOrders,
  ORDER_FILTERS,
  type OrderFilter,
} from "@/features/orders/order-filters";
import {
  ORDER_LIST_LIMIT,
  orderItemCountsQuery,
  ordersQuery,
} from "@/features/orders/queries";
import { storeConfig } from "@/lib/env";
import { formatDateTime, formatMoney } from "@/lib/format";

export const Route = createFileRoute("/_authenticated/account/orders/")({
  head: () => ({
    meta: [
      { title: `Your orders — ${storeConfig.name}` },
      {
        name: "description",
        content: `Your ${storeConfig.name} order history.`,
      },
      { property: "og:title", content: `Your orders — ${storeConfig.name}` },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: OrdersPage,
});

function itemCountLabel(count: number | undefined): string {
  if (count === undefined) return "—";
  return `${count} ${count === 1 ? "item" : "items"}`;
}

function OrdersPage() {
  const [filter, setFilter] = useState<OrderFilter>("all");
  const orders = useQuery(ordersQuery());
  const counts = useQuery(
    orderItemCountsQuery(orders.data?.map((order) => order.id) ?? []),
  );

  return (
    <section className="mx-auto max-w-3xl space-y-6 px-5 pt-10 pb-16">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="eyebrow text-muted-foreground">Account</div>
          <h1 className="mt-2 font-display text-3xl font-semibold">
            Your orders
          </h1>
        </div>
        <Button asChild size="touch" variant="outline">
          <Link to="/account">Back to account</Link>
        </Button>
      </div>

      {orders.isPending ? (
        <div
          aria-busy="true"
          aria-label="Loading your orders"
          role="status"
          className="space-y-3"
        >
          <div className="skeleton h-24 w-full rounded-(--radius-panel)" />
          <div className="skeleton h-24 w-full rounded-(--radius-panel)" />
        </div>
      ) : orders.isError ? (
        <StorefrontErrorState
          error={orders.error}
          onRetry={() => void orders.refetch()}
        />
      ) : orders.data.length === 0 ? (
        <EmptyState
          eyebrow="No orders"
          title="You haven't placed an order yet"
          message="When you do, it will show up here with its delivery and payment status."
          action={<BrowseCta />}
        />
      ) : (
        <>
          <div
            role="group"
            aria-label="Filter orders by status"
            className="flex flex-wrap gap-2"
          >
            {ORDER_FILTERS.map((option) => (
              <Button
                key={option.value}
                size="touch"
                variant={filter === option.value ? "primary" : "outline"}
                aria-pressed={filter === option.value}
                onClick={() => setFilter(option.value)}
              >
                {option.label}
              </Button>
            ))}
          </div>
          {(() => {
            const visible = filterOrders(orders.data, filter);
            if (visible.length === 0) {
              return (
                <EmptyState
                  eyebrow="No matches"
                  title="No orders in this view"
                  message="None of your recent orders match this filter."
                  action={
                    <Button
                      size="touch"
                      variant="outline"
                      onClick={() => setFilter("all")}
                    >
                      Show all orders
                    </Button>
                  }
                />
              );
            }
            return (
              <ul className="space-y-3">
                {visible.map((order) => (
                  <li
                    key={order.id}
                    className="glass-panel flex flex-wrap items-center justify-between gap-4 rounded-(--radius-panel) p-5"
                  >
                    <div className="min-w-0 space-y-1">
                      <div className="font-mono text-sm font-medium break-all">
                        {order.order_number}
                      </div>
                      <div className="text-xs text-muted-foreground">
                        {formatDateTime(order.placed_at)} ·{" "}
                        {itemCountLabel(counts.data?.[order.id])}
                      </div>
                      <div className="flex flex-wrap gap-2 pt-1">
                        <OrderStatusBadge status={order.status} />
                        <PaymentStatusBadge status={order.payment_status} />
                      </div>
                    </div>
                    <div className="flex items-center gap-4">
                      <span className="font-mono text-sm font-medium">
                        {formatMoney(order.total_cents, order.currency)}
                      </span>
                      <Button asChild size="touch" variant="outline">
                        <Link
                          to="/account/orders/$orderId"
                          params={{ orderId: order.id }}
                          aria-label={`View order ${order.order_number}`}
                        >
                          View
                        </Link>
                      </Button>
                    </div>
                  </li>
                ))}
              </ul>
            );
          })()}
          {orders.data.length >= ORDER_LIST_LIMIT ? (
            <p className="text-xs text-muted-foreground">
              Showing your {ORDER_LIST_LIMIT} most recent orders.
            </p>
          ) : null}
        </>
      )}
    </section>
  );
}
