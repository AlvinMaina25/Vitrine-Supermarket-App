import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  AdminCategoryChanges,
  AdminCategoryMutationResult,
  AdminCreateCategoryArgs,
  CategoryRow,
} from "@/lib/supabase/types";

import {
  toAdminCategoryActionError,
  toAdminCategoryMutationResult,
} from "./categories-result";

/**
 * Admin categories (Phase 20A).
 *
 *   list    plain SELECT on public.categories. RLS decides what comes back: the policy
 *           "Categories: admin read all" (admin + 2FA) includes INACTIVE rows; everyone else only
 *           sees active ones. The /admin shell has already refused non-admins before this runs.
 *   create  admin_create_category()   admin only, validated and audited in the database
 *   update  admin_update_category()    PATCH; deactivating = { is_active: false }. No delete exists.
 */
export const adminCategoriesQuery = () =>
  queryOptions({
    queryKey: ["admin", "categories"],
    staleTime: 15_000,
    retry: false,
    queryFn: async (): Promise<CategoryRow[]> => {
      const { data, error } = await requireSupabase()
        .from("categories")
        .select(
          "id, slug, name, tagline, description, image_url, parent_id, position, is_active, created_at, updated_at",
        )
        .order("position", { ascending: true })
        .order("name", { ascending: true });
      if (error) throw new Error(error.message);
      return data ?? [];
    },
  });

export async function adminCreateCategory(
  args: AdminCreateCategoryArgs,
): Promise<AdminCategoryMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_create_category",
    args,
  );
  if (error) throw toAdminCategoryActionError(error);
  return toAdminCategoryMutationResult(data);
}

export async function adminUpdateCategory(input: {
  categoryId: string;
  changes: AdminCategoryChanges;
}): Promise<AdminCategoryMutationResult> {
  const { data, error } = await requireSupabase().rpc("admin_update_category", {
    p_category_id: input.categoryId,
    p_changes: input.changes,
  });
  if (error) throw toAdminCategoryActionError(error);
  return toAdminCategoryMutationResult(data);
}
