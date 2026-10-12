import type { ReactNode } from "react";

import {
  formatCalendarDate,
  formatDateTime,
  formatMoney,
  formatTimeWindow,
} from "@/lib/format";
import type {
  OrderDiscountColumns,
  OrderItemRow,
  OrderRow,
  OrderWithDelivery,
} from "@/lib/supabase/types";
import { discountLabel } from "@/features/promotions/logic";

import { getOrderDeliveryDisplay } from "../delivery-display";
import { PAYMENT_METHOD_LABELS } from "../status";
import { OrderItemsList } from "./order-items-list";
import { OrderStatusBadge, PaymentStatusBadge } from "./status-badge";

/**
 * Display sections shared by the confirmation page and the order detail page.
 *
 * Everything here renders the order's own stored snapshot (items, address,
 * delivery method/zone/slot/fee, amounts, currency). Nothing is re-read from live
 * product, address or delivery-configuration rows, and order status and payment status are always shown as two separate
 * things.
 */

export function OrderSectionCard({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
      <h2 className="font-display text-lg font-semibold">{title}</h2>
      <div className="mt-4">{children}</div>
    </div>
  );
}

/** Order number, placement time and the two independent statuses. */
export function OrderStatusSummary({ order }: { order: OrderRow }) {
  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-3">
      <div>
        <div className="eyebrow text-muted-foreground">Order number</div>
        <div className="mt-1 font-mono text-sm font-medium">
          {order.order_number}
        </div>
      </div>
      <div>
        <div className="eyebrow text-muted-foreground">Placed</div>
        <div className="mt-1 text-sm">{formatDateTime(order.placed_at)}</div>
      </div>
      <div>
        <div className="eyebrow text-muted-foreground">Order status</div>
        <div className="mt-1">
          <OrderStatusBadge status={order.status} />
        </div>
      </div>
      <div>
        <div className="eyebrow text-muted-foreground">Payment status</div>
        <div className="mt-1">
          <PaymentStatusBadge status={order.payment_status} />
        </div>
      </div>
    </div>
  );
}

export function OrderItemsCard({
  items,
  currency,
}: {
  items: OrderItemRow[];
  currency: string;
}) {
  return (
    <OrderSectionCard title="Items">
      {items.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No items are recorded for this order.
        </p>
      ) : (
        <OrderItemsList items={items} currency={currency} />
      )}
    </OrderSectionCard>
  );
}

export function OrderTotalsCard({
  order,
}: {
  order: OrderRow & Partial<OrderDiscountColumns>;
}) {
  const money = (cents: number) => formatMoney(cents, order.currency);
  return (
    <OrderSectionCard title="Totals">
      <dl className="space-y-1.5 text-sm">
        <div className="flex justify-between gap-3">
          <dt className="text-muted-foreground">Subtotal</dt>
          <dd className="font-mono">{money(order.subtotal_cents)}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-muted-foreground">Delivery</dt>
          <dd className="font-mono">
            {order.delivery_fee_cents === 0
              ? "Free"
              : money(order.delivery_fee_cents)}
          </dd>
        </div>
        {order.discount_cents > 0 ? (
          <div className="flex justify-between gap-3">
            <dt className="text-muted-foreground">
              {discountLabel({
                code: order.discount_code ?? null,
                name: order.discount_name ?? null,
              })}
            </dt>
            <dd className="font-mono">−{money(order.discount_cents)}</dd>
          </div>
        ) : null}
        <div className="flex justify-between gap-3 border-t border-border pt-2 font-medium">
          <dt>Total</dt>
          <dd className="font-mono">{money(order.total_cents)}</dd>
        </div>
      </dl>
    </OrderSectionCard>
  );
}

/**
 * Delivery details exactly as recorded when the order was placed. The method name, zone, slot
 * and fee all come from the order's own snapshot via getOrderDeliveryDisplay(); the live
 * delivery configuration is deliberately not consulted, so renaming or deactivating a method
 * later does not change an old order. Fields an old order never recorded are simply omitted.
 */
export function OrderDeliveryCard({ order }: { order: OrderWithDelivery }) {
  const delivery = getOrderDeliveryDisplay(order);
  const address = order.delivery_address;

  const slot = delivery.slot;
  const slotWindow =
    slot && slot.start !== null && slot.end !== null
      ? formatTimeWindow(slot.start, slot.end)
      : null;

  return (
    <OrderSectionCard title="Delivery">
      <dl className="space-y-4 text-sm">
        <div>
          <dt className="eyebrow text-muted-foreground">Method</dt>
          <dd className="mt-1">{delivery.methodLabel}</dd>
        </div>

        {delivery.zoneName ? (
          <div>
            <dt className="eyebrow text-muted-foreground">Delivery zone</dt>
            <dd className="mt-1">{delivery.zoneName}</dd>
          </div>
        ) : null}

        {slot ? (
          <div>
            <dt className="eyebrow text-muted-foreground">Delivery window</dt>
            <dd className="mt-1">
              {formatCalendarDate(slot.date)}
              {slotWindow ? (
                <span className="font-mono"> · {slotWindow}</span>
              ) : null}
              {slot.label ? (
                <span className="text-muted-foreground"> ({slot.label})</span>
              ) : null}
            </dd>
          </div>
        ) : null}

        <div>
          <dt className="eyebrow text-muted-foreground">Delivery fee</dt>
          <dd className="mt-1 font-mono">
            {delivery.isFree
              ? "Free"
              : formatMoney(delivery.feeCents, order.currency)}
          </dd>
        </div>

        <div>
          <dt className="eyebrow text-muted-foreground">Address</dt>
          <dd className="mt-1">
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
                    Note: {address.delivery_instructions}
                  </span>
                ) : null}
              </address>
            ) : (
              <span className="text-muted-foreground">
                No delivery address for this order.
              </span>
            )}
          </dd>
        </div>

        {order.customer_notes ? (
          <div>
            <dt className="eyebrow text-muted-foreground">Your notes</dt>
            <dd className="mt-1 break-words whitespace-pre-line">
              {order.customer_notes}
            </dd>
          </div>
        ) : null}
      </dl>
    </OrderSectionCard>
  );
}

/**
 * Payment method and payment status. `pendingNote` is copy for a payment that
 * has not happened yet; it is shown only while payment_status is 'pending'.
 */
export function OrderPaymentCard({
  order,
  pendingNote,
}: {
  order: OrderRow;
  pendingNote?: string | undefined;
}) {
  return (
    <OrderSectionCard title="Payment">
      <dl className="space-y-4 text-sm">
        <div>
          <dt className="eyebrow text-muted-foreground">Method</dt>
          <dd className="mt-1">
            {PAYMENT_METHOD_LABELS[order.payment_method]}
          </dd>
        </div>
        <div>
          <dt className="eyebrow text-muted-foreground">Status</dt>
          <dd className="mt-1">
            <PaymentStatusBadge status={order.payment_status} />
          </dd>
        </div>
      </dl>
      {pendingNote && order.payment_status === "pending" ? (
        <p className="mt-4 rounded-lg border border-border bg-surface px-3 py-2 text-xs text-muted-foreground">
          {pendingNote}
        </p>
      ) : null}
    </OrderSectionCard>
  );
}
