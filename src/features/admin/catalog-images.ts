import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Pure helpers for admin picture upload (Phase 20B). No runtime imports beyond the Phase 6A error
 * class, so they run under `node --test`.
 *
 * The browser checks (file type, size) are for usability only. Storage enforces the same limits on
 * the bucket, and the database function admin_set_*_image() re-validates the address. Raw errors
 * go to the console; the person only sees the plain sentences below.
 */

export const CATALOG_IMAGE_BUCKET = "catalog-images";
/** 2 MB, the bucket's file_size_limit. */
export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
export const ALLOWED_IMAGE_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
] as const;
export type AllowedImageType = (typeof ALLOWED_IMAGE_TYPES)[number];
/** Value for <input accept>. */
export const IMAGE_ACCEPT = ALLOWED_IMAGE_TYPES.join(",");

export type ImageKind = "product" | "category";

const FOLDER: Record<ImageKind, string> = {
  product: "products",
  category: "categories",
};

const EXTENSION: Record<AllowedImageType, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// ---------------------------------------------------------------------------
// File checks and path building
// ---------------------------------------------------------------------------

export type ImageFileProblem = "empty" | "type" | "size";

export const IMAGE_FILE_MESSAGES: Record<ImageFileProblem, string> = {
  empty: "That file is empty. Choose a different picture.",
  type: "Only JPG, PNG or WebP pictures can be used. Choose a different file.",
  size: "That picture is larger than 2 MB. Choose a smaller one.",
};

export function isAllowedImageType(type: string): type is AllowedImageType {
  return (ALLOWED_IMAGE_TYPES as readonly string[]).includes(type);
}

/** null = fine. Only the browser-reported type and size are looked at. */
export function validateImageFile(file: {
  type: string;
  size: number;
}): ImageFileProblem | null {
  if (!isAllowedImageType(file.type)) return "type";
  if (!Number.isFinite(file.size) || file.size <= 0) return "empty";
  if (file.size > MAX_IMAGE_BYTES) return "size";
  return null;
}

/**
 * Storage path for a new upload: `products/<uuid>.<ext>` or `categories/<uuid>.<ext>`. The
 * original file name is never used. Returns null for a type or id that is not acceptable.
 */
export function buildImagePath(
  kind: ImageKind,
  uuid: string,
  mime: string,
): string | null {
  if (!UUID_PATTERN.test(uuid) || !isAllowedImageType(mime)) return null;
  return `${FOLDER[kind]}/${uuid}.${EXTENSION[mime]}`;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type AdminImageActionReason =
  | "invalid_image_url"
  | "image_not_found"
  | "product_not_found"
  | "category_not_found"
  | "invalid_arguments";

const IMAGE_REASONS: readonly AdminImageActionReason[] = [
  "invalid_image_url",
  "image_not_found",
  "product_not_found",
  "category_not_found",
  "invalid_arguments",
];

/** The database refused to link a picture. `reason` is its DETAIL code. */
export class AdminImageActionError extends Error {
  override readonly name = "AdminImageActionError";
  readonly reason: AdminImageActionReason;
  constructor(reason: AdminImageActionReason) {
    super(`Picture change refused: ${reason}`);
    this.reason = reason;
  }
}

/** The file could not be sent to Storage (network, size or type refusal, or no permission). */
export class ImageUploadError extends Error {
  override readonly name = "ImageUploadError";
  constructor(message = "Picture upload failed.") {
    super(message);
  }
}

export function toAdminImageActionError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to change pictures.",
    );
  }
  const reason = IMAGE_REASONS.find((r) => r === error.details);
  return reason ? new AdminImageActionError(reason) : new Error(error.message);
}

export const IMAGE_REASON_MESSAGES: Record<AdminImageActionReason, string> = {
  invalid_image_url:
    "That picture could not be used. Choose it again and try once more.",
  image_not_found:
    "The picture did not finish uploading. Your current picture was not changed. Try again.",
  product_not_found:
    "This product no longer exists. Refresh the page and try again.",
  category_not_found:
    "This category no longer exists. Refresh the list and try again.",
  invalid_arguments: "The picture could not be saved. Please try again.",
};

export const IMAGE_UPLOAD_FAILED_MESSAGE =
  "The picture could not be uploaded. Your current picture was not changed. Check your connection and try again.";
export const IMAGE_GENERIC_MESSAGE =
  "We couldn't save the picture. Your current picture was not changed. Please try again in a moment.";

export function describeImageError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to change pictures.";
  }
  if (error instanceof AdminImageActionError) {
    return IMAGE_REASON_MESSAGES[error.reason];
  }
  if (error instanceof ImageUploadError) return IMAGE_UPLOAD_FAILED_MESSAGE;
  return IMAGE_GENERIC_MESSAGE;
}
