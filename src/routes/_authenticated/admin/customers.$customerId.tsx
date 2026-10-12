import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { CustomerNotesCard } from "@/components/admin/customer-notes-card";
import { CustomerStatusBadge } from "@/components/admin/customer-status-badge";
import { CustomerStatusCard } from "@/components/admin/customer-status-card";
import { ConfigNotice, ErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { adminCustomerQuery } from "@/features/admin/customers";
import {
  asOrderStatus,
  asPaymentStatus,
  formatAddressLines,
  orderReference,
} from "@/features/admin/customer-detail-management";
import {
  AdminCustomerDetailError,
  type AdminCustomerDetail,
} from "@/features/admin/customer-detail-result";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { isUuid } from "@/features/admin/product-management";
import {
  OrderStatusBadge,
  PaymentStatusBadge,
} from "@/features/orders/components/status-badge";
import { formatDateTime, formatPrice } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";

export const Route = createFileRoute(
  "/_authenticated/admin/customers/$customerId",
)({
  head: () => ({
    meta: [
      { title: "Customer — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: CustomerDetailPage,
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

function CustomerNotFound() {
  return (
    <ErrorState
      title="Customer not found"
      message="This customer doesn't exist, or the link is wrong."
      code="404"
    />
  );
}

/**
 * /admin/customers/$customerId. Nested under the /admin layout, so signed-out visitors go to
 * /auth and non-admins see "Admin access required" and none of this UI. That only decides what
 * to render: every customer function re-checks require_admin() in the database. Every figure
 * shown, including money in integer cents, is the database's answer; nothing is computed here.
 */
function CustomerDetailPage() {
  const { customerId } = Route.useParams();
  const validId = isUuid(customerId);
  // A malformed id is answered here; it is never sent to the database.
  const query = useQuery({
    ...adminCustomerQuery(customerId),
    enabled: validId,
  });

  const back = (
    <Button asChild variant="outline" size="sm">
      <Link to="/admin/customers" search={{}}>
        ← All customers
      </Link>
    </Button>
  );

  if (!validId) {
    return (
      <>
        <AdminPageHeader title="Customer" actions={back} />
        <CustomerNotFound />
      </>
    );
  }

  if (query.isPending) {
    return (
      <>
        <AdminPageHeader title="Customer" actions={back} />
        <div className="space-y-4" role="status" aria-label="Loading customer">
          <div className="skeleton h-24 rounded-(--radius-panel)" />
          <div className="skeleton h-96 rounded-(--radius-panel)" />
        </div>
      </>
    );
  }

  if (query.isError) {
    return (
      <>
        <AdminPageHeader title="Customer" actions={back} />
        <DetailError error={query.error} onRetry={() => void query.refetch()} />
      </>
    );
  }

  return <CustomerDetail detail={query.data} back={back} />;
}

function DetailError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  if (
    error instanceof AdminCustomerDetailError &&
    error.reason === "customer_not_found"
  ) {
    return <CustomerNotFound />;
  }
  return (
    <AdminQueryError
      error={error}
      noun="this customer"
      action="view customers"
      onRetry={onRetry}
    />
  );
}

function CustomerDetail({
  detail,
  back,
}: {
  detail: AdminCustomerDetail;
  back: ReactNode;
}) {
  const { profile, addresses, stats, recent_orders } = detail;

  return (
    <>
      <AdminPageHeader
        title={profile.name ?? "Customer"}
        description={profile.email ?? "No email on file"}
        actions={back}
      />

      <div className="space-y-4">
        <SectionCard title="Profile">
          <dl className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Row label="Name">{profile.name ?? "—"}</Row>
            <Row label="Email">{profile.email ?? "—"}</Row>
            <Row label="Phone">{profile.phone ?? "—"}</Row>
            <Row label="Joined">{formatDateTime(profile.created_at)}</Row>
            <Row label="Status">
              <CustomerStatusBadge status={profile.status} />
            </Row>
          </dl>
        </SectionCard>

        <SectionCard title="Account status">
          <CustomerStatusCard customerId={profile.id} status={profile.status} />
        </SectionCard>

        <SectionCard title="Order summary">
          <dl className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <Row label="Orders">{stats.order_count}</Row>
            <Row label="Lifetime spend">
              {formatPrice(stats.lifetime_spend_cents)}
            </Row>
            <Row label="Last order">
              {stats.last_order_at ? formatDateTime(stats.last_order_at) : "—"}
            </Row>
          </dl>
          <p className="mt-3 text-xs text-muted-foreground">
            Orders, spend and last order exclude cancelled orders.
          </p>
        </SectionCard>

        <SectionCard title="Addresses">
          {addresses.length === 0 ? (
            <p className="text-sm text-muted-foreground">No saved addresses.</p>
          ) : (
            <ul className="grid grid-cols-1 gap-4 md:grid-cols-2">
              {addresses.map((address) => {
                const lines = formatAddressLines(address);
                return (
                  <li
                    key={address.id}
                    className="rounded-lg border border-border p-4 text-sm"
                  >
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">
                        {address.label ?? "Address"}
                      </span>
                      {address.is_default ? (
                        <span className="inline-flex rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-medium text-primary">
                          Default
                        </span>
                      ) : null}
                    </div>
                    {address.full_name ? (
                      <div className="mt-1">{address.full_name}</div>
                    ) : null}
                    {address.phone ? <div>{address.phone}</div> : null}
                    {lines.map((line) => (
                      <div key={line} className="text-muted-foreground">
                        {line}
                      </div>
                    ))}
                    {address.delivery_instructions ? (
                      <p className="mt-2 text-xs text-muted-foreground">
                        Delivery instructions: {address.delivery_instructions}
                      </p>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          )}
        </SectionCard>

        <SectionCard title="Recent orders">
          {recent_orders.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              This customer has no orders yet.
            </p>
          ) : (
            <ul className="divide-y divide-border">
              {recent_orders.map((order) => {
                const orderStatus = asOrderStatus(order.status);
                const paymentStatus = asPaymentStatus(order.payment_status);
                return (
                  <li
                    key={order.id}
                    className="flex flex-wrap items-center justify-between gap-3 py-3 text-sm"
                  >
                    <div>
                      <Link
                        to="/admin/orders/$orderId"
                        params={{ orderId: order.id }}
                        className="font-medium text-primary underline-offset-2 hover:underline"
                      >
                        Order {orderReference(order.id)}
                      </Link>
                      <div className="text-xs text-muted-foreground">
                        {formatDateTime(order.created_at)}
                      </div>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      {orderStatus ? (
                        <OrderStatusBadge status={orderStatus} />
                      ) : (
                        <span className="text-xs">{order.status}</span>
                      )}
                      {paymentStatus ? (
                        <PaymentStatusBadge status={paymentStatus} />
                      ) : (
                        <span className="text-xs">{order.payment_status}</span>
                      )}
                      <span className="font-mono">
                        {formatPrice(order.total_cents)}
                      </span>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
          <p className="mt-3 text-xs text-muted-foreground">
            The 10 most recent orders, including cancelled ones.
          </p>
        </SectionCard>

        <SectionCard title="Internal notes">
          {/* Known limitation (6E.3): notes are last-write-wins, and a remote change to notes_updated_at
              remounts the card below, discarding an unsaved draft. The API has no version check by design. */}
          <CustomerNotesCard
            key={detail.notes_updated_at ?? "no-notes"}
            customerId={profile.id}
            savedNotes={detail.notes}
            updatedAt={detail.notes_updated_at}
          />
        </SectionCard>
      </div>
    </>
  );
}
