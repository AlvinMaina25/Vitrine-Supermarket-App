import { requireSupabase } from "@/lib/supabase/client";
import type {
  AdminCategoryMutationResult,
  AdminProductMutationResult,
} from "@/lib/supabase/types";

import {
  buildImagePath,
  CATALOG_IMAGE_BUCKET,
  ImageUploadError,
  toAdminImageActionError,
  validateImageFile,
  type ImageKind,
} from "./catalog-images";
import { toAdminCategoryMutationResult } from "./categories-result";
import { optimiseImage } from "./image-optimise";
import { toAdminProductMutationResult } from "./products-result";

/**
 * Admin picture upload (Phase 20B).
 *
 *   uploadCatalogImage()        sends the file to the public "catalog-images" bucket under a random
 *                               name (uuid + extension, never the original name) and returns its
 *                               public address. Storage policies allow admins with 2FA only.
 *   adminSetProductImage()      admin_set_product_image(): link an uploaded file, or null to remove
 *   adminSetCategoryImage()     admin_set_category_image(): same for a category
 *
 * Order for a replacement: upload, then link. If the upload fails nothing is linked, so the old
 * picture stays. Old files are never deleted (past orders keep a copy of the address).
 */
export async function uploadCatalogImage(
  kind: ImageKind,
  chosen: File,
): Promise<string> {
  const problem = validateImageFile(chosen);
  if (problem) throw new ImageUploadError(`Rejected before upload: ${problem}`);
  // Scale big photos down first (falls back to the original if the browser cannot).
  const file = await optimiseImage(chosen);
  if (
    typeof crypto === "undefined" ||
    typeof crypto.randomUUID !== "function"
  ) {
    throw new ImageUploadError("No secure random id is available.");
  }
  const path = buildImagePath(kind, crypto.randomUUID(), file.type);
  if (!path) throw new ImageUploadError("Could not build an upload path.");

  const bucket = requireSupabase().storage.from(CATALOG_IMAGE_BUCKET);
  const { error } = await bucket.upload(path, file, {
    contentType: file.type,
    cacheControl: "31536000",
    upsert: false,
  });
  if (error) {
    console.error("Picture upload failed", error);
    throw new ImageUploadError(error.message);
  }
  return bucket.getPublicUrl(path).data.publicUrl;
}

export async function adminSetProductImage(input: {
  productId: string;
  imageUrl: string | null;
}): Promise<AdminProductMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_product_image",
    { p_product_id: input.productId, p_image_url: input.imageUrl },
  );
  if (error) throw toAdminImageActionError(error);
  return toAdminProductMutationResult(data);
}

export async function adminSetCategoryImage(input: {
  categoryId: string;
  imageUrl: string | null;
}): Promise<AdminCategoryMutationResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_category_image",
    { p_category_id: input.categoryId, p_image_url: input.imageUrl },
  );
  if (error) throw toAdminImageActionError(error);
  return toAdminCategoryMutationResult(data);
}
