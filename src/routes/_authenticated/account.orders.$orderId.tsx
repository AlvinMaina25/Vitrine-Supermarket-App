import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";

import { EmptyState, StorefrontErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { paymentProvider } from "@/features/checkout/payment-providers";
import {
  OrderDeliveryCard,
  OrderItemsCard,
  OrderPaymentCard,
  OrderSectionCard,
  OrderStatusSummary,
  OrderTotalsCard,
} from "@/features/orders/components/order-sections";
import { OrderTimeline } from "@/features/orders/components/order-timeline";
import { ReorderPanel } from "@/features/orders/components/reorder-panel";
import { orderNextStep } from "@/features/orders/next-step";
import { orderQuery } from "@/features/orders/queries";
import { CardPaymentPanel } from "@/features/payments/components/card-payment-panel";
import { MpesaPaymentPanel } from "@/features/payments/components/mpesa-payment-panel";
import { storeConfig } from "@/lib/env";

export const Route = createFileRoute("/_authenticated/account/orders/$orderId")(
  {
    head: () => ({
      meta: [
        { title: `Order details — ${storeConfig.name}` },
        {
          name: "description",
          content: `Details and status of your ${storeConfig.name} order.`,
        },
        {
          property: "og:title",
          content: `Order details — ${storeConfig.name}`,
        },
        { property: "og:type", content: "website" },
        { name: "twitter:card", content: "summary" },
      ],
    }),
    component: OrderDetailPage,
  },
);

function OrderDetailPage() {
  const { orderId } = Route.useParams();
  const query = useQuery(orderQuery(orderId));

  return (
    <section className="mx-auto max-w-3xl space-y-6 px-5 pt-10 pb-16">
      <Link
        to="/account/orders"
        className="inline-flex min-h-11 items-center text-sm text-primary"
      >
        ← All orders
      </Link>

      {query.isPending ? (
        <div
          aria-busy="true"
          aria-label="Loading your order"
          role="status"
          className="space-y-4"
        >
          <div className="skeleton h-8 w-64 rounded" />
          <div className="skeleton h-24 w-full rounded-(--radius-panel)" />
          <div className="skeleton h-48 w-full rounded-(--radius-panel)" />
        </div>
      ) : query.isError ? (
        <StorefrontErrorState
          error={query.error}
          onRetry={() => void query.refetch()}
        />
      ) : !query.data ? (
        <EmptyState
          eyebrow="Not found"
          title="We couldn't find that order"
          message="It may belong to a different account, or the link may be wrong."
          action={
            <Button asChild>
              <Link to="/account/orders">Your orders</Link>
            </Button>
          }
        />
      ) : (
        <>
          <div>
            <div className="eyebrow text-muted-foreground">Order</div>
            <h1 className="mt-2 font-display text-3xl font-semibold break-words">
              Order {query.data.order.order_number}
            </h1>
          </div>

          <div className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
            <OrderStatusSummary order={query.data.order} />
          </div>

          <p
            role="status"
            className="rounded-lg border border-border bg-surface px-4 py-3 text-sm"
          >
            <span className="font-medium">What happens next: </span>
            {orderNextStep(query.data.order)}
          </p>

          <OrderItemsCard
            items={query.data.items}
            currency={query.data.order.currency}
          />
          <ReorderPanel
            items={query.data.items}
            currency={query.data.order.currency}
          />
          <OrderTotalsCard order={query.data.order} />

          <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
            <OrderDeliveryCard order={query.data.order} />
            <OrderPaymentCard
              order={query.data.order}
              pendingNote={
                paymentProvider(query.data.order.payment_method).pendingNote
              }
            />
          </div>

          <CardPaymentPanel order={query.data.order} />
          <MpesaPaymentPanel order={query.data.order} />

          <OrderSectionCard title="Status history">
            <OrderTimeline history={query.data.history} />
          </OrderSectionCard>
        </>
      )}
    </section>
  );
}
