import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import {
  toAdminDashboardError,
  toAdminDashboardSummary,
} from "./dashboard-result";

/**
 * Admin dashboard (Phase 6A backend foundation).
 *
 * Calls public.admin_dashboard_summary() through the signed-in session. The database decides
 * who may call it: a customer, staff member or anonymous visitor is refused with an
 * AdminAccessError. Hiding a link with isAdmin() (../auth/roles) is a UI convenience only.
 *
 * The /admin shell (Phase 6D-1) consumes this; later admin screens reuse the same pattern.
 */

export interface AdminDashboardOptions {
  /** 1-50, default 10. */
  recentOrders?: number;
  /** 0-1000, default 10. A caller-supplied cut-off: the schema has no stored reorder level. */
  lowStockThreshold?: number;
}

export const adminDashboardQuery = (options: AdminDashboardOptions = {}) =>
  queryOptions({
    queryKey: [
      "admin",
      "dashboard",
      options.recentOrders ?? 10,
      options.lowStockThreshold ?? 10,
    ],
    staleTime: 30_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_dashboard_summary",
        {
          p_recent_orders_limit: options.recentOrders ?? 10,
          p_low_stock_threshold: options.lowStockThreshold ?? 10,
        },
      );
      if (error) throw toAdminDashboardError(error);
      return toAdminDashboardSummary(data);
    },
  });

/**
 * Whether the signed-in user is an admin, asked of the database (public.is_admin(auth.uid())),
 * not inferred from client state. Used by the /admin shell to decide what to render. It is a UI
 * gate only: every admin RPC re-checks is_admin() itself, so a wrong answer here can never
 * expose data. is_admin() only answers for the caller's own id, so this cannot probe others.
 *
 * Staff are deliberately not admitted: the Phase 6A-6C admin RPCs are admin-only.
 */
export const adminAccessQuery = () =>
  queryOptions({
    queryKey: ["admin", "access"],
    staleTime: 60_000,
    retry: false,
    queryFn: async (): Promise<boolean> => {
      const client = requireSupabase();
      const { data: auth, error: authError } = await client.auth.getUser();
      if (authError || !auth.user) return false;
      const { data, error } = await client.rpc("is_admin", {
        _user_id: auth.user.id,
      });
      if (error) throw new Error(error.message);
      return data === true;
    },
  });
