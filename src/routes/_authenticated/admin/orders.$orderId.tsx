import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { OrderStatusActions } from "@/components/admin/order-status-actions";
import { RecordCashPayment } from "@/components/admin/record-cod-payment";
import { ConfigNotice, ErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { canRecordCodPayment } from "@/features/admin/cod-payment";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { adminOrderQuery } from "@/features/admin/orders";
import { AdminOrderNotFoundError } from "@/features/admin/orders-result";
import {
  OrderStatusBadge,
  PaymentStatusBadge,
} from "@/features/orders/components/status-badge";
import {
  OrderItemsCard,
  OrderPaymentCard,
  OrderSectionCard,
  OrderTotalsCard,
} from "@/features/orders/components/order-sections";
import { getOrderDeliveryDisplay } from "@/features/orders/delivery-display";
import {
  ORDER_STATUS_LABELS,
  PAYMENT_STATUS_LABELS,
} from "@/features/orders/status";
import {
  formatCalendarDate,
  formatDateTime,
  formatMoney,
  formatTimeWindow,
} from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type {
  AdminOrderDetail,
  AdminOrderHistoryEntry,
} from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/admin/orders/$orderId")({
  head: () => ({
    meta: [{ title: "Order — Admin" }, { name: "robots", content: "noindex" }],
  }),
  component: OrderDetailPage,
});

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt className="eyebrow text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-sm break-words">{children}</dd>
    </div>
  );
}

function OrderDetailPage() {
  const { orderId } = Route.useParams();
  const query = useQuery(adminOrderQuery(orderId));

  const back = (
    <Button asChild variant="outline" size="sm">
      <Link to="/admin/orders" search={{}}>
        ← All orders
      </Link>
    </Button>
  );

  if (query.isPending) {
    return (
      <>
        <AdminPageHeader title="Order" actions={back} />
        <div className="space-y-4" role="status" aria-label="Loading order">
          <div className="skeleton h-24 rounded-(--radius-panel)" />
          <div className="skeleton h-64 rounded-(--radius-panel)" />
        </div>
      </>
    );
  }

  if (query.isError) {
    return (
      <>
        <AdminPageHeader title="Order" actions={back} />
        <DetailError error={query.error} onRetry={() => void query.refetch()} />
      </>
    );
  }

  return <OrderDetail detail={query.data} back={back} />;
}

function DetailError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  if (error instanceof AdminOrderNotFoundError) {
    return (
      <ErrorState
        title="Order not found"
        message="This order doesn't exist, or the link is wrong."
        code="404"
      />
    );
  }
  return (
    <AdminQueryError
      error={error}
      noun="this order"
      action="view orders"
      onRetry={onRetry}
    />
  );
}

function OrderDetail({
  detail,
  back,
}: {
  detail: AdminOrderDetail;
  back: ReactNode;
}) {
  const { order, customer } = detail;

  return (
    <>
      <AdminPageHeader title={`Order ${order.order_number}`} actions={back} />

      <div className="space-y-4">
        <OrderSectionCard title="Summary">
          <div className="flex flex-wrap items-center gap-x-8 gap-y-3">
            <Row label="Order number">
              <span className="font-mono font-medium">
                {order.order_number}
              </span>
            </Row>
            <Row label="Placed">{formatDateTime(order.placed_at)}</Row>
            <Row label="Order status">
              <OrderStatusBadge status={order.status} />
            </Row>
            <Row label="Payment status">
              <PaymentStatusBadge status={order.payment_status} />
            </Row>
          </div>
        </OrderSectionCard>

        <OrderSectionCard title="Update status">
          <OrderStatusActions detail={detail} />
        </OrderSectionCard>

        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <OrderSectionCard title="Customer">
            {customer ? (
              <dl className="space-y-4">
                <Row label="Name">{customer.full_name ?? "—"}</Row>
                <Row label="Email">{customer.email ?? "—"}</Row>
                <Row label="Phone">{customer.phone ?? "—"}</Row>
              </dl>
            ) : (
              <p className="text-sm text-muted-foreground">
                No customer profile is on record for this order.
              </p>
            )}
          </OrderSectionCard>
          <DeliveryCard detail={detail} />
        </div>

        <OrderItemsCard items={detail.items} currency={order.currency} />

        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <OrderTotalsCard order={order} />
          <OrderPaymentCard order={order} />
        </div>

        {canRecordCodPayment(order) ? (
          <OrderSectionCard title="Cash on delivery">
            <RecordCashPayment order={order} />
          </OrderSectionCard>
        ) : null}

        <OrderSectionCard title="Status history">
          <History history={detail.history} />
        </OrderSectionCard>
      </div>
    </>
  );
}

/** Reads the order's own delivery snapshot, as the customer pages do. */
function DeliveryCard({ detail }: { detail: AdminOrderDetail }) {
  const { order } = detail;
  const delivery = getOrderDeliveryDisplay(order);
  const address = order.delivery_address;
  const slot = delivery.slot;
  const window =
    slot && slot.start !== null && slot.end !== null
      ? formatTimeWindow(slot.start, slot.end)
      : null;

  return (
    <OrderSectionCard title="Delivery">
      <dl className="space-y-4">
        <Row label="Method">{delivery.methodLabel}</Row>
        {delivery.zoneName ? <Row label="Zone">{delivery.zoneName}</Row> : null}
        {slot ? (
          <Row label="Delivery window">
            {formatCalendarDate(slot.date)}
            {window ? <span className="font-mono"> · {window}</span> : null}
            {slot.label ? (
              <span className="text-muted-foreground"> ({slot.label})</span>
            ) : null}
          </Row>
        ) : null}
        <Row label="Delivery fee">
          {delivery.isFree
            ? "Free"
            : formatMoney(delivery.feeCents, order.currency)}
        </Row>
        <Row label="Address">
          {address ? (
            <address className="not-italic">
              {address.full_name} ·{" "}
              <span className="font-mono">{address.phone}</span>
              <br />
              {address.address_line_1}
              {address.address_line_2 ? `, ${address.address_line_2}` : ""}
              <br />
              {address.city}, {address.county}
              {address.postal_code ? ` ${address.postal_code}` : ""}
              {address.delivery_instructions ? (
                <span className="mt-1 block text-xs text-muted-foreground">
                  Instructions: {address.delivery_instructions}
                </span>
              ) : null}
            </address>
          ) : (
            <span className="text-muted-foreground">
              No delivery address for this order.
            </span>
          )}
        </Row>
        {order.customer_notes ? (
          <Row label="Customer notes">
            <span className="whitespace-pre-line">{order.customer_notes}</span>
          </Row>
        ) : null}
      </dl>
    </OrderSectionCard>
  );
}

function entryLabel(entry: AdminOrderHistoryEntry): string {
  // A row where the order status did not move records a payment-status change.
  if (entry.previous_status === entry.new_status && entry.payment_status) {
    return `Payment: ${PAYMENT_STATUS_LABELS[entry.payment_status]}`;
  }
  return entry.previous_status
    ? `${ORDER_STATUS_LABELS[entry.previous_status]} → ${ORDER_STATUS_LABELS[entry.new_status]}`
    : ORDER_STATUS_LABELS[entry.new_status];
}

function History({ history }: { history: AdminOrderHistoryEntry[] }) {
  if (history.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No status changes are recorded yet.
      </p>
    );
  }
  return (
    <ol className="relative space-y-4 border-l border-border pl-5">
      {history.map((entry, index) => (
        <li key={entry.id} className="relative">
          <span
            aria-hidden="true"
            className={`absolute -left-[26px] top-1 size-3 rounded-full border-2 border-background ${
              index === history.length - 1
                ? "bg-primary"
                : "bg-muted-foreground/40"
            }`}
          />
          <div className="text-sm font-medium">{entryLabel(entry)}</div>
          <div className="font-mono text-[11px] text-muted-foreground">
            {formatDateTime(entry.created_at)}
            {entry.changed_by_name ? ` · ${entry.changed_by_name}` : ""}
          </div>
          {entry.note ? (
            <p className="mt-0.5 text-xs text-muted-foreground">{entry.note}</p>
          ) : null}
        </li>
      ))}
    </ol>
  );
}
