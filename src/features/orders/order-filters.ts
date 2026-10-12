import type { OrderStatus } from "../../lib/supabase/types.ts";

/**
 * Phase 14: order-list filter. A display filter over the rows the existing orders read already
 * returned (each row carries its own stored status); it does not query, count or decide anything.
 */

export type OrderFilter = "all" | "open" | "delivered" | "closed";

export const ORDER_FILTERS: readonly { value: OrderFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "open", label: "In progress" },
  { value: "delivered", label: "Delivered" },
  { value: "closed", label: "Cancelled or refunded" },
];

export function matchesOrderFilter(
  status: OrderStatus,
  filter: OrderFilter,
): boolean {
  switch (filter) {
    case "all":
      return true;
    case "delivered":
      return status === "delivered";
    case "closed":
      return status === "cancelled" || status === "refunded";
    case "open":
      return (
        status !== "delivered" &&
        status !== "cancelled" &&
        status !== "refunded"
      );
  }
}

export function filterOrders<T extends { status: OrderStatus }>(
  orders: readonly T[],
  filter: OrderFilter,
): T[] {
  return orders.filter((order) => matchesOrderFilter(order.status, filter));
}
