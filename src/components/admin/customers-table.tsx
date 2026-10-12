import { Link } from "@tanstack/react-router";

import { CustomerStatusBadge } from "@/components/admin/customer-status-badge";
import { InventoryPagination } from "@/components/admin/inventory-pagination";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { AdminCustomerListRow } from "@/features/admin/customers-result";
import { formatDateTime, formatPrice } from "@/lib/format";
import { cn } from "@/lib/utils";

/**
 * One page of customers with paging controls. Props only: the caller fetches, owns the page
 * number and decides what to show when there are no rows. Lifetime spend is integer cents from
 * the database, formatted for display and never added up here.
 */
export function CustomersTable({
  rows,
  total,
  page,
  pageSize,
  refreshing = false,
  onPage,
}: {
  rows: readonly AdminCustomerListRow[];
  /** The database's own count of matching customers. */
  total: number;
  /** 1-based, as the list reported it. */
  page: number;
  pageSize: number;
  /** A newer page is loading; the current rows stay visible but paging is paused. */
  refreshing?: boolean;
  onPage: (page: number) => void;
}) {
  return (
    <div
      className={cn(
        "glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4",
        refreshing && "opacity-60",
      )}
      aria-busy={refreshing}
    >
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead>Email</TableHead>
            <TableHead>Phone</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="text-right">Orders</TableHead>
            <TableHead className="text-right">Lifetime spend</TableHead>
            <TableHead>Last order</TableHead>
            <TableHead className="text-right">Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id}>
              <TableCell className="font-medium">
                {row.name ?? (
                  <span className="text-muted-foreground">No name</span>
                )}
              </TableCell>
              <TableCell className="text-sm break-all">
                {row.email ?? "—"}
              </TableCell>
              <TableCell className="text-sm whitespace-nowrap">
                {row.phone ?? "—"}
              </TableCell>
              <TableCell>
                <CustomerStatusBadge status={row.status} />
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {row.order_count}
              </TableCell>
              <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                {formatPrice(row.lifetime_spend_cents)}
              </TableCell>
              <TableCell className="text-sm whitespace-nowrap">
                {row.last_order_at ? formatDateTime(row.last_order_at) : "—"}
              </TableCell>
              <TableCell className="text-right">
                <Link
                  to="/admin/customers/$customerId"
                  params={{ customerId: row.id }}
                  className="font-medium text-primary underline-offset-2 hover:underline"
                >
                  View
                </Link>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <InventoryPagination
        label="Customers pagination"
        total={total}
        limit={pageSize}
        offset={(page - 1) * pageSize}
        rows={rows.length}
        disabled={refreshing}
        onPage={onPage}
      />
    </div>
  );
}
