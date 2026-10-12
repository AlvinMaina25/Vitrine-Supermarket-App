import { queryOptions } from "@tanstack/react-query";

import { AdminAccessError } from "@/features/admin/dashboard-result";
import { requireSupabase } from "@/lib/supabase/client";

import {
  parsePromotionList,
  promotionAdminErrorMessage,
  type PromotionErrorLike,
} from "./admin-parse";

/**
 * Phase 15: the promotions LIST read for the admin screen. It calls the same RPC as
 * listPromotions() in admin-api.ts, but keeps a database refusal recognisable: that wrapper turns
 * every failure into a plain Error, which would show a refusal as "could not load". Here
 * 42501 / not_authorised / mfa_required becomes an AdminAccessError so the screen can show the
 * shared no-access state. Writes still go through the unchanged wrappers in admin-api.ts.
 */
export const ADMIN_PROMOTIONS_PAGE_SIZE = 25;

interface RpcFailure extends PromotionErrorLike {
  code?: string | null;
}

function toListError(error: RpcFailure): Error {
  if (
    error.code === "42501" ||
    error.details === "not_authorised" ||
    error.details === "mfa_required"
  ) {
    return new AdminAccessError(
      "You do not have permission to view promotions.",
    );
  }
  return new Error(promotionAdminErrorMessage(error));
}

export const adminPromotionsQuery = (page: number) =>
  queryOptions({
    queryKey: ["admin", "promotions", page],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await (
        requireSupabase().rpc as unknown as (
          fn: string,
          a: Record<string, unknown>,
        ) => Promise<{ data: unknown; error: RpcFailure | null }>
      )("admin_list_promotions", {
        p_limit: ADMIN_PROMOTIONS_PAGE_SIZE,
        p_offset: (page - 1) * ADMIN_PROMOTIONS_PAGE_SIZE,
      });
      if (error) throw toListError(error);
      return parsePromotionList(data);
    },
  });
