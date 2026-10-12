import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  AdminAdjustInventoryArgs,
  AdminAdjustInventoryResult,
  AdminInventoryRow,
} from "@/lib/supabase/types";

import {
  INVENTORY_CLASSIFY_MAX_ROWS,
  INVENTORY_FETCH_PAGE_SIZE,
} from "./inventory-management";
import {
  collectAllPages,
  toAdminAdjustmentList,
  toAdminAdjustResult,
  toAdminInventoryActionError,
  toAdminInventoryError,
  toAdminInventoryList,
  toAdminListAdjustmentsArgs,
  toAdminListInventoryArgs,
  type AdminAdjustmentHistoryQuery,
  type AdminInventoryListQuery,
} from "./inventory-result";

/**
 * Admin inventory (Phase 6C backend, consumed by Phase 6D-4).
 *
 * Every call goes through the signed-in session to an admin-only database function; none of them
 * touches a table directly, and the browser has no stock-writing privilege at all. The database
 * refuses customers, staff and anonymous visitors (AdminAccessError); hiding a link or a button is
 * a UI convenience only.
 *
 *   admin_list_inventory()              one row per stock unit (a product's own stock, or one
 *                                       variant); search and paging happen in the database
 *   admin_adjust_inventory()            the ONLY way stock changes: a signed delta, applied under a
 *                                       row lock, with one history row written in the same
 *                                       transaction. The caller cannot send a final quantity.
 *   admin_list_inventory_adjustments()  read-only history, newest first
 *
 * All query keys start with ["admin", "inventory"], so one invalidation refreshes every view.
 */

/** Server-paged list: the "all inventory" view. */
export const adminInventoryQuery = (query: AdminInventoryListQuery = {}) =>
  queryOptions({
    queryKey: ["admin", "inventory", "list", toAdminListInventoryArgs(query)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_inventory",
        toAdminListInventoryArgs(query),
      );
      if (error) throw toAdminInventoryError(error);
      return toAdminInventoryList(data);
    },
  });

/**
 * Every matching unit, read page by page (100 per call, capped). Used by the Low stock and Out of
 * stock views: the database has no low-stock filter, so those rows are classified on the client
 * with the same rule as the Phase 6A dashboard (see classifyStock). A server page cannot be
 * filtered afterwards without hiding matches that sit on other pages, hence the full read.
 */
export const adminInventoryAllQuery = (search: string | null) =>
  queryOptions({
    queryKey: ["admin", "inventory", "all", search ?? ""],
    staleTime: 15_000,
    retry: false,
    queryFn: async () =>
      collectAllPages<AdminInventoryRow>(
        async (offset) => {
          const { data, error } = await requireSupabase().rpc(
            "admin_list_inventory",
            toAdminListInventoryArgs({
              search,
              limit: INVENTORY_FETCH_PAGE_SIZE,
              offset,
            }),
          );
          if (error) throw toAdminInventoryError(error);
          const list = toAdminInventoryList(data);
          return { total: list.total, rows: list.inventory };
        },
        {
          pageSize: INVENTORY_FETCH_PAGE_SIZE,
          maxRows: INVENTORY_CLASSIFY_MAX_ROWS,
        },
      ),
  });

export const adminInventoryAdjustmentsQuery = (
  query: AdminAdjustmentHistoryQuery = {},
) =>
  queryOptions({
    queryKey: [
      "admin",
      "inventory",
      "history",
      toAdminListAdjustmentsArgs(query),
    ],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_inventory_adjustments",
        toAdminListAdjustmentsArgs(query),
      );
      if (error) throw toAdminInventoryError(error);
      return toAdminAdjustmentList(data);
    },
  });

/**
 * Adjust one stock unit by a signed, non-zero delta. The database locks the row, refuses a result
 * below zero or above the integer range, updates the stock and records the history row in one
 * transaction, then returns the stored outcome. This function never writes a table itself.
 */
export async function adminAdjustInventory(
  args: AdminAdjustInventoryArgs,
): Promise<AdminAdjustInventoryResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_adjust_inventory",
    args,
  );
  if (error) throw toAdminInventoryActionError(error);
  return toAdminAdjustResult(data);
}
