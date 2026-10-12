import { requireSupabase } from "@/lib/supabase/client";

import {
  parsePromotionList,
  parsePromotionResult,
  promotionAdminErrorMessage,
  type PromotionAdminRow,
  type PromotionChanges,
  type PromotionErrorLike,
  type PromotionInput,
} from "./admin-parse";

export type {
  PromotionAdminRow,
  PromotionChanges,
  PromotionInput,
} from "./admin-parse";

/**
 * Admin wiring for promotions (Phase 8). Thin: every call is one admin_* RPC, which runs
 * require_admin() first and writes the audit row. There is no table access and no delete: a
 * promotion is deactivated, never removed. No UI uses this yet (see the report).
 */

async function call(
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  // The generated Database type lists these functions; the loose cast keeps this wrapper small.
  const { data, error } = await (
    requireSupabase().rpc as unknown as (
      fn: string,
      a: Record<string, unknown>,
    ) => Promise<{ data: unknown; error: PromotionErrorLike | null }>
  )(name, args);
  if (error) throw new Error(promotionAdminErrorMessage(error));
  return data;
}

export async function createPromotion(
  input: PromotionInput,
): Promise<PromotionAdminRow> {
  return parsePromotionResult(
    await call("admin_create_promotion", { p_input: input }),
  );
}

export async function updatePromotion(
  id: string,
  changes: PromotionChanges,
): Promise<PromotionAdminRow> {
  return parsePromotionResult(
    await call("admin_update_promotion", {
      p_promotion_id: id,
      p_changes: changes,
    }),
  );
}

export async function setPromotionActive(
  id: string,
  isActive: boolean,
): Promise<PromotionAdminRow> {
  return parsePromotionResult(
    await call("admin_set_promotion_active", {
      p_promotion_id: id,
      p_is_active: isActive,
    }),
  );
}

export async function listPromotions(limit = 50, offset = 0) {
  return parsePromotionList(
    await call("admin_list_promotions", { p_limit: limit, p_offset: offset }),
  );
}
