import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  AdminOrderListFilters,
  AdminSetOrderStatusInput,
  AdminSetOrderStatusResult,
} from "@/lib/supabase/types";

import {
  toAdminListOrdersArgs,
  toAdminOrderActionError,
  toAdminOrderDetail,
  toAdminOrderList,
  toAdminOrdersError,
  toAdminSetOrderStatusArgs,
  toAdminSetOrderStatusResult,
} from "./orders-result";

/**
 * Admin orders (Phase 6B.1 reads, Phase 6B.2 status action).
 *
 * Both calls go through the signed-in session to admin-only database functions. The database
 * refuses customers, staff and anonymous visitors (AdminAccessError); hiding a link is a UI
 * convenience only.
 *
 * Status changes (Phase 6B.2, bottom of this file) go through public.admin_set_order_status(),
 * which delegates to the one Phase 5B.2 mechanism, public.set_order_status().
 */

export const adminOrdersQuery = (filters: AdminOrderListFilters = {}) =>
  queryOptions({
    queryKey: ["admin", "orders", toAdminListOrdersArgs(filters)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_orders",
        toAdminListOrdersArgs(filters),
      );
      if (error) throw toAdminOrdersError(error);
      return toAdminOrderList(data);
    },
  });

export const adminOrderQuery = (orderId: string) =>
  queryOptions({
    queryKey: ["admin", "order", orderId],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc("admin_get_order", {
        p_order_id: orderId,
      });
      if (error) throw toAdminOrdersError(error);
      return toAdminOrderDetail(data);
    },
  });

/**
 * Change an order's status as an admin (Phase 6B.2). One call covers every order action:
 * confirm/process, pick, pack, dispatch, deliver, cancel.
 *
 * Goes through public.admin_set_order_status(), which checks the caller is an admin and then
 * delegates to the Phase 5B.2 set_order_status() unchanged. The database alone decides whether
 * the move is valid, restocks, guards delivery-slot capacity and writes the history row; this
 * function never writes the orders table, and cannot mark an order paid or refunded.
 *
 * Throws AdminAccessError (not an admin), AdminOrderNotFoundError, AdminOrderActionError
 * (a rule refused the move; `reason` says which) or a plain Error.
 */
export async function adminSetOrderStatus(
  input: AdminSetOrderStatusInput,
): Promise<AdminSetOrderStatusResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_order_status",
    toAdminSetOrderStatusArgs(input),
  );
  if (error) throw toAdminOrderActionError(error);
  return toAdminSetOrderStatusResult(data);
}

/** Cancel an order. The reason is stored as the history note (400 characters at most). */
export function adminCancelOrder(orderId: string, reason?: string | null) {
  return adminSetOrderStatus({
    orderId,
    status: "cancelled",
    note: reason ?? null,
  });
}
