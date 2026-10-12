import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import {
  ConfigNotice,
  EmptyState,
  ErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
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
import { asOfLabel } from "@/features/admin/admin-ui";
import { adminDashboardQuery } from "@/features/admin/queries";
import {
  OrderStatusBadge,
  PaymentStatusBadge,
} from "@/features/orders/components/status-badge";
import { formatDateTime, formatMoney } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { AdminDashboardSummary } from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/admin/")({
  head: () => ({
    meta: [
      { title: "Dashboard — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: DashboardPage,
});

function StatCard({
  label,
  value,
  hint,
}: {
  label: string;
  value: number;
  hint?: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-5">
      <div className="eyebrow text-muted-foreground">{label}</div>
      <div className="mt-2 font-display text-3xl font-semibold tabular-nums">
        {value.toLocaleString("en-US")}
      </div>
      {hint ? (
        <div className="mt-1 text-xs text-muted-foreground">{hint}</div>
      ) : null}
    </div>
  );
}

function DashboardSkeleton() {
  return (
    <div className="space-y-6" role="status" aria-label="Loading dashboard">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="skeleton h-28 rounded-(--radius-panel)" />
        ))}
      </div>
      <div className="skeleton h-64 rounded-(--radius-panel)" />
    </div>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="glass-panel rounded-(--radius-panel) p-5">
      <h2 className="font-display text-xl font-semibold">{title}</h2>
      <div className="mt-4">{children}</div>
    </section>
  );
}

function RecentOrders({
  orders,
}: {
  orders: AdminDashboardSummary["recent_orders"];
}) {
  if (orders.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No orders have been placed yet.
      </p>
    );
  }
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Order</TableHead>
          <TableHead>Customer</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Payment</TableHead>
          <TableHead className="text-right">Total</TableHead>
          <TableHead>Placed</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {orders.map((order) => (
          <TableRow key={order.id}>
            <TableCell className="font-mono text-xs font-medium">
              <Link
                to="/admin/orders/$orderId"
                params={{ orderId: order.id }}
                className="text-primary underline-offset-2 hover:underline"
              >
                {order.order_number}
              </Link>
            </TableCell>
            <TableCell>{order.customer_name ?? "—"}</TableCell>
            <TableCell>
              <OrderStatusBadge status={order.status} />
            </TableCell>
            <TableCell>
              <PaymentStatusBadge status={order.payment_status} />
            </TableCell>
            <TableCell className="text-right font-mono text-xs">
              {formatMoney(order.total_cents, order.currency)}
            </TableCell>
            <TableCell className="text-xs whitespace-nowrap text-muted-foreground">
              {formatDateTime(order.placed_at)}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function LowStock({
  items,
  threshold,
}: {
  items: AdminDashboardSummary["low_stock_items"];
  threshold: number;
}) {
  if (items.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        Nothing is out of stock or at {threshold} or fewer units.
      </p>
    );
  }
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Item</TableHead>
          <TableHead>SKU</TableHead>
          <TableHead className="text-right">In stock</TableHead>
          <TableHead>State</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.map((item) => (
          <TableRow key={`${item.product_id}:${item.variant_id ?? ""}`}>
            <TableCell>
              {item.name}
              {item.variant_name ? (
                <span className="text-muted-foreground">
                  {" "}
                  · {item.variant_name}
                </span>
              ) : null}
            </TableCell>
            <TableCell className="font-mono text-xs">
              {item.sku ?? "—"}
            </TableCell>
            <TableCell className="text-right font-mono text-xs">
              {item.stock_quantity}
            </TableCell>
            <TableCell>
              <span
                className={
                  item.state === "out_of_stock"
                    ? "rounded-full bg-danger/10 px-2.5 py-0.5 text-xs font-medium text-danger"
                    : "rounded-full bg-accent/15 px-2.5 py-0.5 text-xs font-medium text-accent-foreground"
                }
              >
                {item.state === "out_of_stock" ? "Out of stock" : "Low stock"}
              </span>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function DashboardPage() {
  const dashboard = useQuery(adminDashboardQuery());

  return (
    <>
      <AdminPageHeader
        title="Dashboard"
        description={
          (dashboard.data
            ? asOfLabel(dashboard.data.generated_at, dashboard.data.time_zone)
            : null) ?? "A snapshot of orders, customers and stock."
        }
        actions={
          <Button
            variant="outline"
            size="touch"
            disabled={dashboard.isFetching}
            onClick={() => void dashboard.refetch()}
          >
            {dashboard.isFetching ? "Refreshing…" : "Refresh"}
          </Button>
        }
      />

      {dashboard.isPending ? (
        <DashboardSkeleton />
      ) : dashboard.isError ? (
        <DashboardError
          error={dashboard.error}
          onRetry={() => void dashboard.refetch()}
        />
      ) : (
        <DashboardBody data={dashboard.data} />
      )}
    </>
  );
}

function DashboardError({
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
      noun="the dashboard"
      action="view the dashboard"
      onRetry={onRetry}
    />
  );
}

const PAYMENT_STATUS_LABEL: Record<string, string> = {
  pending: "Pending",
  processing: "Processing",
  paid: "Paid",
  failed: "Failed",
  cancelled: "Cancelled",
  refunded: "Refunded",
  partially_refunded: "Partially refunded",
};

const PAYMENT_METHOD_LABEL: Record<string, string> = {
  mpesa: "M-Pesa",
  card: "Card",
  cash_on_delivery: "Cash on delivery",
};

/** Counts exactly as the database returned them. The key order is the database's. */
function CountList({
  label,
  counts,
  labels,
}: {
  label: string;
  counts: Record<string, number>;
  labels: Record<string, string>;
}) {
  return (
    <div>
      <h3 className="eyebrow text-muted-foreground">{label}</h3>
      <dl className="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:grid-cols-4">
        {Object.entries(counts).map(([key, count]) => (
          <Fact key={key} term={labels[key] ?? key} value={count} />
        ))}
      </dl>
    </div>
  );
}

function Fact({ term, value }: { term: string; value: number }) {
  return (
    <div className="rounded-lg border border-border px-3 py-2">
      <dt className="text-xs text-muted-foreground">{term}</dt>
      <dd className="text-lg font-semibold tabular-nums">
        {value.toLocaleString("en-US")}
      </dd>
    </div>
  );
}

function DashboardBody({ data }: { data: AdminDashboardSummary }) {
  const { orders, customers, products, variants } = data;
  const noOrdersYet = orders.total === 0;

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <StatCard
          label="Total orders"
          value={orders.total}
          hint={`${orders.placed_today} placed today`}
        />
        <StatCard
          label="Pending orders"
          value={orders.by_status.pending}
          hint="Status “Order placed”"
        />
        <StatCard
          label="Completed orders"
          value={orders.by_status.delivered}
          hint="Delivered"
        />
        <StatCard label="Cancelled orders" value={orders.by_status.cancelled} />
        <StatCard
          label="Customers"
          value={customers.total}
          hint={`${customers.new_last_30_days} new in the last 30 days`}
        />
        <StatCard
          label="Low-stock products"
          value={products.low_stock}
          hint={`${products.out_of_stock} out of stock · ${variants.low_stock} low-stock variants · threshold ${data.low_stock_threshold}`}
        />
      </div>

      <Section title="Order value">
        <p className="text-3xl font-semibold tabular-nums">
          {formatMoney(orders.gross_value_cents)}
        </p>
        <p className="mt-1 max-w-[60ch] text-xs text-muted-foreground">
          Not revenue. This is the total of all orders that are not cancelled or
          refunded, including orders not yet paid and cash on delivery. “Today”
          means today in {data.time_zone}.
        </p>
      </Section>

      <Section title="Payments">
        <CountList
          label="Orders by payment status"
          counts={data.payments.by_status}
          labels={PAYMENT_STATUS_LABEL}
        />
        <div className="mt-4">
          <CountList
            label="Orders by payment method"
            counts={data.payments.by_method}
            labels={PAYMENT_METHOD_LABEL}
          />
        </div>
      </Section>

      <Section title="Delivery">
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <Fact term="Scheduled today" value={data.delivery.scheduled_today} />
          <Fact
            term="Scheduled later"
            value={data.delivery.scheduled_upcoming}
          />
          <Fact
            term="Active delivery methods"
            value={data.delivery.configuration.active_methods}
          />
          <Fact
            term="Active zones"
            value={data.delivery.configuration.active_zones}
          />
          <Fact
            term="Active slot templates"
            value={data.delivery.configuration.active_slot_templates}
          />
        </dl>
      </Section>

      <Section title="Catalogue">
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <Fact term="Products" value={products.total} />
          <Fact term="Active products" value={products.active} />
          <Fact term="Inactive products" value={products.inactive} />
          <Fact term="Variants" value={variants.total} />
          <Fact term="Active variants" value={variants.active} />
        </dl>
      </Section>

      <Section title="Recent orders">
        {noOrdersYet ? (
          <EmptyState
            eyebrow="No orders"
            title="No orders yet"
            message="Orders will appear here as customers place them."
          />
        ) : (
          <RecentOrders orders={data.recent_orders} />
        )}
      </Section>

      <Section title="Low-stock and out-of-stock items">
        <LowStock
          items={data.low_stock_items}
          threshold={data.low_stock_threshold}
        />
      </Section>
    </div>
  );
}
