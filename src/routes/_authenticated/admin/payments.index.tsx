import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";

import { AdminQueryError } from "@/components/admin/admin-states";
import { AdminPageHeader } from "@/components/admin/admin-shell";
import { InventoryPagination } from "@/components/admin/inventory-pagination";
import { EmptyState } from "@/components/states/states";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  ADMIN_PAYMENTS_PAGE_SIZE,
  adminPaymentsQuery,
} from "@/features/admin/payments";
import { formatDateTime, formatMoney } from "@/lib/format";
import type {
  PaymentMethod,
  PaymentTransactionStatus,
} from "@/lib/supabase/types";

const STATUSES: readonly PaymentTransactionStatus[] = [
  "pending",
  "processing",
  "succeeded",
  "failed",
  "cancelled",
  "expired",
];

const STATUS_LABEL: Record<PaymentTransactionStatus, string> = {
  pending: "Pending",
  processing: "Processing",
  succeeded: "Succeeded",
  failed: "Failed",
  cancelled: "Cancelled",
  expired: "Expired",
};

const STATUS_STYLE: Record<PaymentTransactionStatus, string> = {
  pending: "bg-surface-strong text-foreground",
  processing: "bg-accent/20 text-foreground",
  succeeded: "bg-primary/10 text-primary",
  failed: "bg-danger/10 text-danger",
  cancelled: "bg-surface-strong text-muted-foreground",
  expired: "bg-surface-strong text-muted-foreground",
};

const METHOD_LABEL: Record<PaymentMethod, string> = {
  mpesa: "M-Pesa",
  card: "Card",
  cash_on_delivery: "Cash on delivery",
};

interface PaymentsParams {
  page?: number;
  status?: PaymentTransactionStatus;
}

export const Route = createFileRoute("/_authenticated/admin/payments/")({
  validateSearch: (search: Record<string, unknown>): PaymentsParams => {
    const page = Number(search["page"]);
    const status = STATUSES.find((s) => s === search["status"]);
    return {
      ...(Number.isInteger(page) && page > 1 ? { page } : {}),
      ...(status ? { status } : {}),
    };
  },
  head: () => ({
    meta: [
      { title: "Payments — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: PaymentsPage,
});

/**
 * /admin/payments. READ ONLY. It lists payment attempts as the database holds them; there is no
 * control here that changes a payment or an order. The database refuses non-admins
 * (admin_list_payment_transactions runs require_admin() first) and that refusal is shown as the
 * shared no-access state.
 */
function PaymentsPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const page = params.page ?? 1;

  const query = useQuery({
    ...adminPaymentsQuery({
      status: params.status ?? null,
      offset: (page - 1) * ADMIN_PAYMENTS_PAGE_SIZE,
    }),
    placeholderData: keepPreviousData,
  });

  return (
    <>
      <AdminPageHeader
        title="Payments"
        description="Payment attempts as recorded by the database. Read only: payment status is set by the payment providers and the server, never from this screen."
      />

      <div className="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label
            htmlFor="payments-status"
            className="eyebrow block text-muted-foreground"
          >
            Status
          </label>
          <select
            id="payments-status"
            value={params.status ?? ""}
            onChange={(event) => {
              const value = STATUSES.find((s) => s === event.target.value);
              void navigate({
                search: value ? { status: value } : {},
                replace: true,
              });
            }}
            className="mt-1.5 min-h-11 rounded-lg border border-border bg-background px-3 py-2 text-base md:pointer-fine:text-sm"
          >
            <option value="">All statuses</option>
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_LABEL[s]}
              </option>
            ))}
          </select>
        </div>
      </div>

      {query.isPending ? (
        <div className="space-y-2" role="status" aria-label="Loading payments">
          {Array.from({ length: 6 }, (_, i) => (
            <div key={i} className="skeleton h-12 rounded-lg" />
          ))}
        </div>
      ) : query.isError ? (
        <AdminQueryError
          error={query.error}
          noun="payments"
          action="view payments"
          onRetry={() => void query.refetch()}
        />
      ) : query.data.transactions.length === 0 ? (
        <EmptyState
          eyebrow="No payments"
          title={
            params.status ? "No payments with that status" : "No payments yet"
          }
          message={
            params.status
              ? "Try another status, or clear the filter."
              : "Payment attempts will appear here once customers start paying."
          }
        />
      ) : (
        <div
          className="glass-panel rounded-(--radius-panel) p-2 sm:p-4"
          aria-busy={query.isFetching}
        >
          <ul className="space-y-3 md:hidden" aria-label="Payment attempts">
            {query.data.transactions.map((t) => (
              <li
                key={t.id}
                className="rounded-lg border border-border bg-background p-3"
              >
                <div className="flex items-start justify-between gap-2">
                  <p className="text-lg font-semibold tabular-nums">
                    {formatMoney(t.amount_cents, t.currency)}
                  </p>
                  <span
                    className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[t.status]}`}
                  >
                    {STATUS_LABEL[t.status]}
                  </span>
                </div>
                <p className="mt-1 text-sm">
                  {METHOD_LABEL[t.method]} · {t.provider}
                </p>
                <p className="text-xs text-muted-foreground">
                  {formatDateTime(t.created_at)}
                </p>
                {t.provider_reference ? (
                  <p className="mt-1 break-all font-mono text-xs">
                    {t.provider_reference}
                  </p>
                ) : null}
                {t.failure_code || t.failure_message ? (
                  <p className="mt-1 text-xs text-danger">
                    {[t.failure_code, t.failure_message]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>
                ) : null}
                <Link
                  to="/admin/orders/$orderId"
                  params={{ orderId: t.order_id }}
                  className="mt-2 inline-flex min-h-11 items-center text-sm text-primary underline-offset-2 hover:underline"
                >
                  View order
                </Link>
              </li>
            ))}
          </ul>
          <div className="hidden md:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Created</TableHead>
                  <TableHead>Order</TableHead>
                  <TableHead>Method</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                  <TableHead>Reference</TableHead>
                  <TableHead>Failure</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {query.data.transactions.map((t) => (
                  <TableRow key={t.id}>
                    <TableCell className="whitespace-nowrap text-xs">
                      {formatDateTime(t.created_at)}
                    </TableCell>
                    <TableCell>
                      <Link
                        to="/admin/orders/$orderId"
                        params={{ orderId: t.order_id }}
                        className="font-mono text-xs text-primary underline-offset-2 hover:underline"
                      >
                        View order
                      </Link>
                    </TableCell>
                    <TableCell className="text-sm">
                      {METHOD_LABEL[t.method]}
                      <span className="block text-xs text-muted-foreground">
                        {t.provider}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span
                        className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[t.status]}`}
                      >
                        {STATUS_LABEL[t.status]}
                      </span>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatMoney(t.amount_cents, t.currency)}
                    </TableCell>
                    <TableCell className="font-mono text-xs">
                      {t.provider_reference ?? "—"}
                    </TableCell>
                    <TableCell className="max-w-[18rem] text-xs text-muted-foreground">
                      {t.failure_code || t.failure_message
                        ? [t.failure_code, t.failure_message]
                            .filter(Boolean)
                            .join(" · ")
                        : "—"}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          <InventoryPagination
            label="Payments pagination"
            total={query.data.total_count}
            limit={query.data.limit}
            offset={query.data.offset}
            rows={query.data.transactions.length}
            disabled={query.isFetching}
            onPage={(next) =>
              void navigate({
                search: (prev) => ({
                  ...(prev.status ? { status: prev.status } : {}),
                  ...(next > 1 ? { page: next } : {}),
                }),
              })
            }
          />
        </div>
      )}
    </>
  );
}
