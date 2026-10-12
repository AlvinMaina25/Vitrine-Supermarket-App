import type {
  AdminCategoryChanges,
  AdminCategoryMutationResult,
  AdminCreateCategoryArgs,
  CategoryRow,
} from "../../lib/supabase/types.ts";
import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Pure helpers for the admin category screen (Phase 20A). No runtime imports beyond the Phase 6A
 * error class, so they run under `node --test`.
 *
 * The checks below mirror admin_create_category() / admin_update_category() so the form can say
 * "the slug may only contain..." before a round trip. The database stays authoritative: it
 * re-validates everything behind require_admin(), and whatever it refuses is shown in plain words
 * from CATEGORY_REASON_MESSAGES. Raw database text is never shown.
 */

export type CategoryFieldKey =
  "name" | "slug" | "tagline" | "description" | "position";

export interface CategoryFormValues {
  name: string;
  slug: string;
  tagline: string;
  description: string;
  /** Kept as text while typing; parsed by the builders. */
  position: string;
  isActive: boolean;
}

export type CategoryFormErrors = Partial<Record<CategoryFieldKey, string>>;

export const CATEGORY_LIMITS = {
  nameMin: 2,
  nameMax: 80,
  slugMax: 80,
  taglineMax: 120,
  descriptionMax: 500,
  positionMax: 2147483647,
} as const;

/** Screen order of the form fields (focus-first-error uses it). */
export const CATEGORY_FIELD_ORDER = [
  "name",
  "slug",
  "tagline",
  "description",
  "position",
] as const;

export const categoryFieldId = (key: string) => `category-${key}`;

const SLUG_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type AdminCategoryActionReason =
  | "slug_taken"
  | "category_not_found"
  | "invalid_arguments"
  | "unsupported_field";

const CATEGORY_REASONS: readonly AdminCategoryActionReason[] = [
  "slug_taken",
  "category_not_found",
  "invalid_arguments",
  "unsupported_field",
];

/** A rule refused a category write. `reason` is the database's DETAIL code. */
export class AdminCategoryActionError extends Error {
  override readonly name = "AdminCategoryActionError";
  readonly reason: AdminCategoryActionReason;
  readonly field: CategoryFieldKey | null;

  constructor(
    reason: AdminCategoryActionReason,
    field: CategoryFieldKey | null = null,
  ) {
    super(`Category change refused: ${reason}`);
    this.reason = reason;
    this.field = field;
  }
}

/** Which field an `invalid_arguments` message ("Invalid category slug ...") is about. */
export function categoryFieldFromMessage(
  message: string,
): CategoryFieldKey | null {
  const m = message.toLowerCase();
  if (m.includes("category name")) return "name";
  if (m.includes("category slug")) return "slug";
  if (m.includes("category tagline")) return "tagline";
  if (m.includes("category description")) return "description";
  if (m.includes("category position")) return "position";
  return null;
}

export function toAdminCategoryActionError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to change categories.",
    );
  }
  const reason = CATEGORY_REASONS.find((r) => r === error.details);
  if (!reason) return new Error(error.message);
  switch (reason) {
    case "slug_taken":
      return new AdminCategoryActionError(reason, "slug");
    case "invalid_arguments":
      return new AdminCategoryActionError(
        reason,
        categoryFieldFromMessage(error.message),
      );
    default:
      return new AdminCategoryActionError(reason);
  }
}

/** Plain words for each refusal. Anything not listed falls back to the generic sentence. */
export const CATEGORY_REASON_MESSAGES: Record<
  AdminCategoryActionReason,
  string
> = {
  slug_taken:
    "Another category already uses that URL slug. Choose a different one.",
  category_not_found:
    "This category no longer exists. Refresh the list and try again.",
  invalid_arguments:
    "Some values were not accepted. Check the form and try again.",
  unsupported_field: "That change could not be saved. Please try again.",
};

const CATEGORY_FIELD_LABELS: Record<CategoryFieldKey, string> = {
  name: "name",
  slug: "URL slug",
  tagline: "tagline",
  description: "description",
  position: "position",
};

export function describeCategorySaveError(error: unknown): string {
  if (error instanceof AdminAccessError) {
    return "Your account is not permitted to change categories.";
  }
  if (error instanceof AdminCategoryActionError) {
    if (error.reason === "invalid_arguments" && error.field) {
      return `The ${CATEGORY_FIELD_LABELS[error.field]} was not accepted. Check it and try again.`;
    }
    return CATEGORY_REASON_MESSAGES[error.reason];
  }
  return "We couldn't save this category. Please try again in a moment.";
}

export function categorySaveErrorField(
  error: unknown,
): CategoryFieldKey | null {
  return error instanceof AdminCategoryActionError ? error.field : null;
}

// ---------------------------------------------------------------------------
// Form values
// ---------------------------------------------------------------------------

export function emptyCategoryFormValues(): CategoryFormValues {
  return {
    name: "",
    slug: "",
    tagline: "",
    description: "",
    position: "0",
    isActive: true,
  };
}

export function categoryToFormValues(
  category: CategoryRow,
): CategoryFormValues {
  return {
    name: category.name,
    slug: category.slug,
    tagline: category.tagline ?? "",
    description: category.description ?? "",
    position: String(category.position),
    isActive: category.is_active,
  };
}

function hasControlCharacter(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code < 32 || code === 127) return true;
  }
  return false;
}

/** Whole number >= 0 as typed ("3", " 03 "), or null when it is anything else. */
export function parsePosition(text: string): number | null {
  const t = text.trim();
  if (!/^\d{1,10}$/.test(t)) return null;
  const n = Number(t);
  return n <= CATEGORY_LIMITS.positionMax ? n : null;
}

const MESSAGES = {
  name: "Enter a name of 2 to 80 characters.",
  slug: "Use 1 to 80 lower-case letters, digits and single hyphens (for example fresh-fruit).",
  tagline: "Keep the tagline to 120 characters or fewer.",
  description: "Keep the description to 500 characters or fewer.",
  position: "Enter a whole number, 0 or more.",
} as const;

function validateName(raw: string): string | null {
  const name = raw.trim();
  return name.length < CATEGORY_LIMITS.nameMin ||
    name.length > CATEGORY_LIMITS.nameMax ||
    hasControlCharacter(name)
    ? MESSAGES.name
    : null;
}
function validateSlug(raw: string): string | null {
  const slug = raw.trim();
  return slug.length < 1 ||
    slug.length > CATEGORY_LIMITS.slugMax ||
    !SLUG_PATTERN.test(slug)
    ? MESSAGES.slug
    : null;
}
function validateTagline(raw: string): string | null {
  const t = raw.trim();
  return t.length > CATEGORY_LIMITS.taglineMax || hasControlCharacter(t)
    ? MESSAGES.tagline
    : null;
}
function validateDescription(raw: string): string | null {
  return raw.trim().length > CATEGORY_LIMITS.descriptionMax
    ? MESSAGES.description
    : null;
}
function validatePosition(raw: string): string | null {
  return parsePosition(raw) === null ? MESSAGES.position : null;
}

const VALIDATORS: Record<CategoryFieldKey, (raw: string) => string | null> = {
  name: validateName,
  slug: validateSlug,
  tagline: validateTagline,
  description: validateDescription,
  position: validatePosition,
};

/** Blank (after trimming) means "none", which the database stores as NULL. */
const blankToNull = (text: string): string | null => {
  const t = text.trim();
  return t === "" ? null : t;
};

export interface CategoryCreateResult {
  args: AdminCreateCategoryArgs | null;
  errors: CategoryFormErrors;
}

export function buildCreateCategoryArgs(
  values: CategoryFormValues,
): CategoryCreateResult {
  const errors: CategoryFormErrors = {};
  for (const key of CATEGORY_FIELD_ORDER) {
    const message = VALIDATORS[key](values[key]);
    if (message) errors[key] = message;
  }
  if (Object.keys(errors).length > 0) return { args: null, errors };
  return {
    errors,
    args: {
      p_name: values.name.trim(),
      p_slug: values.slug.trim(),
      p_tagline: blankToNull(values.tagline),
      p_description: blankToNull(values.description),
      p_position: parsePosition(values.position) as number,
      p_is_active: values.isActive,
    },
  };
}

export interface CategoryPatchResult {
  /** Empty when nothing changed or something failed validation. */
  changes: AdminCategoryChanges;
  errors: CategoryFormErrors;
}

/**
 * The PATCH for admin_update_category(): only fields whose value differs from `initial` are
 * validated and sent, so an untouched legacy value can never block a save.
 */
export function buildCategoryChanges(
  initial: CategoryFormValues,
  values: CategoryFormValues,
): CategoryPatchResult {
  const changes: AdminCategoryChanges = {};
  const errors: CategoryFormErrors = {};

  for (const key of CATEGORY_FIELD_ORDER) {
    if (values[key] === initial[key]) continue;
    const message = VALIDATORS[key](values[key]);
    if (message) {
      errors[key] = message;
      continue;
    }
    switch (key) {
      case "name":
        changes.name = values.name.trim();
        break;
      case "slug":
        changes.slug = values.slug.trim();
        break;
      case "tagline":
        changes.tagline = blankToNull(values.tagline);
        break;
      case "description":
        changes.description = blankToNull(values.description);
        break;
      case "position":
        changes.position = parsePosition(values.position) as number;
        break;
    }
  }
  if (values.isActive !== initial.isActive) changes.is_active = values.isActive;

  return Object.keys(errors).length > 0
    ? { changes: {}, errors }
    : { changes, errors };
}

export function categoryHasChanges(changes: AdminCategoryChanges): boolean {
  return Object.keys(changes).length > 0;
}

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

/** The stored row returned by both writers. Anything else is an error, never a guess. */
export function toAdminCategoryMutationResult(
  data: unknown,
): AdminCategoryMutationResult {
  if (!isRecord(data) || !isRecord(data["category"])) {
    throw new Error("Unexpected category response.");
  }
  const c = data["category"];
  if (
    typeof c["id"] !== "string" ||
    typeof c["slug"] !== "string" ||
    typeof c["name"] !== "string" ||
    typeof c["position"] !== "number" ||
    typeof c["is_active"] !== "boolean"
  ) {
    throw new Error("Unexpected category response.");
  }
  return { category: c as unknown as CategoryRow };
}
