import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  AdminCreateProductArgs,
  AdminCreateProductVariantArgs,
  AdminProductChanges,
  AdminProductVariantChanges,
  AdminProductMutationResult,
  AdminVariantMutationResult,
} from "@/lib/supabase/types";

import {
  toAdminListProductsArgs,
  toAdminProductActionError,
  toAdminProductDetail,
  toAdminProductList,
  toAdminProductMutationResult,
  toAdminProductsError,
  toAdminVariantMutationResult,
  type AdminProductListQuery,
} from "./products-result";

/**
 * Admin products (Phase 6C reads and updates, consumed by Phase 6D-3A).
 *
 * Every call goes through the signed-in session to an admin-only database function; none of them
 * touches a table directly. The database refuses customers, staff and anonymous visitors
 * (AdminAccessError); hiding a link or a button is a UI convenience only.
 *
 *   admin_list_products()           search, filter and paging all happen in the database
 *   admin_get_product()             one product, its category and every variant
 *   admin_create_product()          inserts one product (name, slug, price required; never stock,
 *                                   is_active or image_url)
 *   admin_set_product_active()      sets is_active and nothing else (no deletion exists)
 *   admin_update_product()          patch of catalogue fields (never stock or image_url; is_active only via admin_set_product_active)
 *   admin_update_product_variant()  patch of catalogue fields (never stock or product_id)
 *   admin_create_product_variant()  one new variant (Phase 21; stock 0, active)
 */

export const adminProductsQuery = (query: AdminProductListQuery = {}) =>
  queryOptions({
    queryKey: ["admin", "products", toAdminListProductsArgs(query)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_products",
        toAdminListProductsArgs(query),
      );
      if (error) throw toAdminProductsError(error);
      return toAdminProductList(data);
    },
  });

export const adminProductQuery = (productId: string) =>
  queryOptions({
    queryKey: ["admin", "product", productId],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc("admin_get_product", {
        p_product_id: productId,
      });
      if (error) throw toAdminProductsError(error);
      return toAdminProductDetail(data);
    },
  });

/**
 * Update a product's catalogue fields. `changes` is a PATCH: absent keys are left alone, null
 * clears a nullable column. The database validates every value and returns the stored row; this
 * function never writes the products table itself.
 */
export async function adminUpdateProduct(input: {
  productId: string;
  changes: AdminProductChanges;
}): Promise<AdminProductMutationResult> {
  const { data, error } = await requireSupabase().rpc("admin_update_product", {
    p_product_id: input.productId,
    p_changes: input.changes,
  });
  if (error) throw toAdminProductActionError(error);
  return toAdminProductMutationResult(data);
}

/** Update a variant's catalogue fields (same PATCH rules). Stock is not part of this contract. */
export async function adminUpdateProductVariant(input: {
  variantId: string;
  changes: AdminProductVariantChanges;
}): Promise<AdminVariantMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_update_product_variant",
    {
      p_variant_id: input.variantId,
      p_changes: input.changes,
    },
  );
  if (error) throw toAdminProductActionError(error);
  return toAdminVariantMutationResult(data);
}

/**
 * Create one variant of a product. The database applies the table defaults for what this function
 * cannot write: stock 0 and is_active true. Stock and activation are separate calls (see
 * variant-create-plan.ts). Returns the stored row.
 */
export async function adminCreateProductVariant(
  args: AdminCreateProductVariantArgs,
): Promise<AdminVariantMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_create_product_variant",
    args,
  );
  if (error) throw toAdminProductActionError(error);
  return toAdminVariantMutationResult(data);
}

/**
 * Create one product. The database applies its own defaults for what this function cannot write:
 * stock 0, in_stock true, **is_active true** (a new product is live immediately) and no image.
 * Returns the stored row.
 */
export async function adminCreateProduct(
  args: AdminCreateProductArgs,
): Promise<AdminProductMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_create_product",
    args,
  );
  if (error) throw toAdminProductActionError(error);
  return toAdminProductMutationResult(data);
}

/** Activate or deactivate a product. Changes is_active only; the stored row is returned. */
export async function adminSetProductActive(input: {
  productId: string;
  isActive: boolean;
}): Promise<AdminProductMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_product_active",
    {
      p_product_id: input.productId,
      p_is_active: input.isActive,
    },
  );
  if (error) throw toAdminProductActionError(error);
  return toAdminProductMutationResult(data);
}
