import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { Link } from "@tanstack/react-router";

import { InventoryPagination } from "@/components/admin/inventory-pagination";
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
import { useAuth } from "@/features/auth/auth-provider";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminInventoryAdjustmentsQuery } from "@/features/admin/inventory";
import {
  describeMovement,
  formatMovementActor,
  HISTORY_PAGE_SIZE,
  movementOrderReference,
} from "@/features/admin/inventory-management";
import { formatDelta } from "@/features/admin/inventory-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { formatDateTime } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { AdminInventoryAdjustmentRow } from "@/lib/supabase/types";

/**
 * Read-only adjustment history from admin_list_inventory_adjustments(), newest first. The
 * function is admin only (require_admin()); a refusal is shown as "Admin access required" and no
 * rows. Actors are shown as "You" or a short id: the history API returns the user id, not a name,
 * and this screen does not look up other accounts. Phase 9C: each row is labelled from
 * movement_kind, with a link to the order for cancel / reactivate rows; the API never returns a
 * customer id as the actor.
 */
export function InventoryHistoryPanel({
  productId,
  variantId,
  page,
  onPage,
  onClearFilter,
}: {
  productId: string | undefined;
  variantId: string | undefined;
  page: number;
  onPage: (page: number) => void;
  onClearFilter: () => void;
}) {
  const auth = useAuth();
  const history = useQuery({
    ...adminInventoryAdjustmentsQuery({
      productId: productId ?? null,
      variantId: variantId ?? null,
      limit: HISTORY_PAGE_SIZE,
      offset: (page - 1) * HISTORY_PAGE_SIZE,
    }),
    placeholderData: keepPreviousData,
  });

  const filtered = Boolean(productId);

  const filterNote = filtered ? (
    <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface-strong px-3 py-2 text-sm">
      <span>
        {variantId
          ? "Showing history for one variant."
          : "Showing history for one product, including its variants."}
      </span>
      <Button variant="outline" size="sm" onClick={onClearFilter}>
        Show all history
      </Button>
    </div>
  ) : null;

  if (history.isPending) {
    return (
      <>
        {filterNote}
        <div
          className="space-y-2"
          role="status"
          aria-label="Loading inventory history"
        >
          {Array.from({ length: 8 }, (_, i) => (
            <div key={i} className="skeleton h-12 rounded-lg" />
          ))}
        </div>
      </>
    );
  }

  if (history.isError) {
    return (
      <AdminQueryError
        error={history.error}
        noun="the history"
        action="view inventory history"
        onRetry={() => void history.refetch()}
      />
    );
  }

  const { adjustments, total, limit, offset } = history.data;

  if (adjustments.length === 0) {
    return (
      <>
        {filterNote}
        <EmptyState
          eyebrow="No history"
          title={
            total > 0
              ? "That page is past the last entry"
              : "No adjustments yet"
          }
          message={
            total > 0
              ? "Go back to an earlier page."
              : filtered
                ? "Nothing has been adjusted for this item."
                : "Stock adjustments will be listed here once one has been made."
          }
        />
      </>
    );
  }

  return (
    <>
      {filterNote}
      <div
        className={`glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4 ${
          history.isPlaceholderData ? "opacity-60" : ""
        }`}
        aria-busy={history.isPlaceholderData}
      >
        <HistoryTable
          rows={adjustments}
          currentUserId={auth.user?.id ?? null}
        />
        <InventoryPagination
          label="Inventory history pagination"
          total={total}
          limit={limit || HISTORY_PAGE_SIZE}
          offset={offset}
          rows={adjustments.length}
          disabled={history.isPlaceholderData}
          onPage={onPage}
        />
      </div>
    </>
  );
}

function HistoryTable({
  rows,
  currentUserId,
}: {
  rows: AdminInventoryAdjustmentRow[];
  currentUserId: string | null;
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>When</TableHead>
          <TableHead>Product</TableHead>
          <TableHead className="text-right">Change</TableHead>
          <TableHead className="text-right">Stock</TableHead>
          <TableHead>Movement</TableHead>
          <TableHead>Reason</TableHead>
          <TableHead>By</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((row) => {
          // The unit's own sku: the variant's for a variant adjustment, else the product's.
          const sku = row.variant_sku ?? row.product_sku;
          return (
            <TableRow key={row.id}>
              <TableCell className="text-xs whitespace-nowrap">
                {formatDateTime(row.created_at)}
              </TableCell>
              <TableCell>
                <div className="font-medium">{row.product_name}</div>
                {row.variant_name ? (
                  <div className="text-xs text-muted-foreground">
                    {row.variant_name}
                  </div>
                ) : null}
                {sku ? (
                  <div className="font-mono text-xs text-muted-foreground">
                    {sku}
                  </div>
                ) : null}
              </TableCell>
              <TableCell
                className={`text-right font-mono text-sm font-medium whitespace-nowrap ${
                  row.adjustment_quantity < 0 ? "text-danger" : "text-primary"
                }`}
              >
                {formatDelta(row.adjustment_quantity)}
              </TableCell>
              <TableCell className="text-right font-mono text-xs whitespace-nowrap">
                {row.previous_quantity} → {row.new_quantity}
              </TableCell>
              <TableCell className="text-xs">
                <MovementCell kind={row.movement_kind} orderId={row.order_id} />
              </TableCell>
              <TableCell className="max-w-[28ch] text-sm">
                <div>{row.reason}</div>
                {row.note ? (
                  <div className="mt-0.5 text-xs whitespace-pre-wrap text-muted-foreground">
                    {row.note}
                  </div>
                ) : null}
              </TableCell>
              <TableCell className="text-xs whitespace-nowrap">
                {formatMovementActor(
                  row.movement_kind,
                  row.changed_by,
                  currentUserId,
                )}
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}

/** The movement label, plus the order for cancel / reactivate rows. Missing data degrades quietly. */
function MovementCell({
  kind,
  orderId,
}: {
  kind: string | null;
  orderId: string | null;
}) {
  const movement = describeMovement(kind);
  if (!movement) return <span className="text-muted-foreground">-</span>;
  const orderRef = movementOrderReference(orderId);
  const isOrderKind = kind === "order_restock" || kind === "order_reactivation";
  return (
    <div>
      <div className="font-medium" title={movement.detail}>
        {movement.label}
      </div>
      {orderId && orderRef ? (
        <Link
          to="/admin/orders/$orderId"
          params={{ orderId }}
          className="font-mono text-primary underline-offset-2 hover:underline"
        >
          Order {orderRef}
        </Link>
      ) : isOrderKind ? (
        <div className="text-muted-foreground">Order not recorded</div>
      ) : null}
    </div>
  );
}
