import type {
  AdminCreateProductArgs,
  AdminProductChanges,
  AdminProductDetail,
  AdminProductList,
  AdminProductMutationResult,
  AdminProductVariantChanges,
  AdminVariantMutationResult,
  ProductRow,
  ProductVariantRow,
} from "../../lib/supabase/types.ts";
import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";

/**
 * Pure helpers for the admin product screens (Phase 6D-3A). No runtime imports beyond the Phase
 * 6A error class, so they run under `node --test`.
 *
 * Nothing here decides authorisation or whether a value is acceptable: the database does
 * (admin_list_products / admin_get_product / admin_update_product / admin_update_product_variant,
 * all behind require_admin()). The validation below exists only so the form can say "that price
 * is not a number" before a round trip. The server stays authoritative: whatever it refuses, the
 * UI reports, and nothing here ever bypasses it.
 */

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export class AdminProductNotFoundError extends Error {
  override readonly name = "AdminProductNotFoundError";

  constructor(message = "That product could not be found.") {
    super(message);
  }
}

/** Form fields a refusal can be attached to. */
export type ProductFieldKey =
  | "name"
  | "slug"
  | "category"
  | "description"
  | "brand"
  | "sku"
  | "price"
  | "compareAt"
  | "unitLabel";

export type VariantFieldKey =
  "name" | "sku" | "price" | "compareAt" | "position";

export type AdminProductActionReason =
  | "slug_taken"
  | "sku_taken"
  | "category_not_found"
  | "variant_not_found"
  | "invalid_arguments"
  | "unsupported_field";

const ACTION_REASONS: readonly AdminProductActionReason[] = [
  "slug_taken",
  "sku_taken",
  "category_not_found",
  "variant_not_found",
  "invalid_arguments",
  "unsupported_field",
];

/**
 * A rule refused a product or variant write. `reason` is the database's own DETAIL code and
 * `field` (when it can be told) is the form field to point at. The message is deliberately NOT
 * the raw database text: the UI builds its own wording from `reason` and `field`.
 */
export class AdminProductActionError extends Error {
  override readonly name = "AdminProductActionError";
  readonly reason: AdminProductActionReason;
  readonly field: string | null;

  constructor(reason: AdminProductActionReason, field: string | null = null) {
    super(`Product change refused: ${reason}`);
    this.reason = reason;
    this.field = field;
  }
}

/** Reads: not-an-admin -> AdminAccessError, unknown product -> AdminProductNotFoundError. */
export function toAdminProductsError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to view admin products.",
    );
  }
  if (error.details === "product_not_found")
    return new AdminProductNotFoundError();
  return new Error(error.message);
}

/**
 * Which form field an `invalid_arguments` message is about. The database messages name the
 * column ("Invalid price_cents (...)"), so the field can be recovered without parsing numbers.
 * compare_at is tested before price_cents because "compare_at_price_cents" contains it.
 */
export function fieldFromInvalidMessage(message: string): string | null {
  const m = message.toLowerCase();
  if (m.includes("compare_at")) return "compareAt";
  if (m.includes("price_cents")) return "price";
  if (
    m.includes("product name") ||
    m.includes("variant name") ||
    m.startsWith("invalid name")
  )
    return "name";
  if (m.includes("slug")) return "slug";
  if (m.includes("description")) return "description";
  if (m.includes("brand")) return "brand";
  if (m.includes("unit_label")) return "unitLabel";
  if (m.includes("sku")) return "sku";
  if (m.includes("category_id")) return "category";
  if (m.includes("position")) return "position";
  return null;
}

/** Writes: also maps the rule refusals. Anything unrecognised becomes a plain Error. */
export function toAdminProductActionError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to change products.",
    );
  }
  if (error.details === "product_not_found")
    return new AdminProductNotFoundError();
  const reason = ACTION_REASONS.find((r) => r === error.details);
  if (!reason) return new Error(error.message);
  switch (reason) {
    case "slug_taken":
      return new AdminProductActionError(reason, "slug");
    case "sku_taken":
      return new AdminProductActionError(reason, "sku");
    case "category_not_found":
      return new AdminProductActionError(reason, "category");
    case "invalid_arguments":
      return new AdminProductActionError(
        reason,
        fieldFromInvalidMessage(error.message),
      );
    default:
      return new AdminProductActionError(reason);
  }
}

// ---------------------------------------------------------------------------
// Request arguments and response shapes
// ---------------------------------------------------------------------------

export interface AdminProductListQuery {
  search?: string | null;
  isActive?: boolean | null;
  categoryId?: string | null;
  limit?: number;
  offset?: number;
}

/** Named arguments for admin_list_products(). Blank strings become null; defaults are explicit. */
export function toAdminListProductsArgs(query: AdminProductListQuery = {}) {
  const search = query.search?.trim();
  const category = query.categoryId?.trim();
  return {
    p_search: search ? search : null,
    p_is_active: query.isActive ?? null,
    p_category_id: category ? category : null,
    p_limit: query.limit ?? 25,
    p_offset: query.offset ?? 0,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function toAdminProductList(data: unknown): AdminProductList {
  if (
    !isRecord(data) ||
    !Array.isArray(data["products"]) ||
    typeof data["total"] !== "number"
  ) {
    throw new Error("The admin product list returned an unexpected response.");
  }
  return data as unknown as AdminProductList;
}

export function toAdminProductDetail(data: unknown): AdminProductDetail {
  if (
    !isRecord(data) ||
    !isRecord(data["product"]) ||
    !Array.isArray(data["variants"])
  ) {
    throw new Error("The admin product returned an unexpected response.");
  }
  if (data["category"] !== null && !isRecord(data["category"])) {
    throw new Error("The admin product response has a malformed category.");
  }
  return data as unknown as AdminProductDetail;
}

export function toAdminProductMutationResult(
  data: unknown,
): AdminProductMutationResult {
  if (
    !isRecord(data) ||
    !isRecord(data["product"]) ||
    typeof data["product"]["id"] !== "string"
  ) {
    throw new Error("The product update returned an unexpected response.");
  }
  return data as unknown as AdminProductMutationResult;
}

export function toAdminVariantMutationResult(
  data: unknown,
): AdminVariantMutationResult {
  if (
    !isRecord(data) ||
    !isRecord(data["variant"]) ||
    typeof data["variant"]["id"] !== "string"
  ) {
    throw new Error("The variant update returned an unexpected response.");
  }
  return data as unknown as AdminVariantMutationResult;
}

// ---------------------------------------------------------------------------
// Money input (integer cents only; no floating point anywhere)
// ---------------------------------------------------------------------------

/** products.price_cents / product_variants.price_cents are `integer`. */
export const MAX_PRICE_CENTS = 2_147_483_647;

export type PriceParse =
  { ok: true; cents: number } | { ok: false; message: string };

/**
 * "1250", "1,250.5", "1250.50" -> cents, by string arithmetic. At most two decimals; no sign, no
 * exponent. The result is checked against the integer column's range.
 */
export function parsePriceInput(text: string): PriceParse {
  const cleaned = text.trim().replace(/,/g, "");
  if (cleaned === "") return { ok: false, message: "Enter a price." };
  const match = /^(\d{1,10})(?:\.(\d{1,2}))?$/.exec(cleaned);
  if (!match)
    return { ok: false, message: "Enter an amount like 250 or 250.50." };
  const whole = Number(match[1]);
  const fraction = Number((match[2] ?? "").padEnd(2, "0"));
  const cents = whole * 100 + fraction;
  if (!Number.isSafeInteger(cents) || cents > MAX_PRICE_CENTS) {
    return { ok: false, message: "That amount is too large." };
  }
  return { ok: true, cents };
}

/** 125000 -> "1250.00". Integer arithmetic only. */
export function centsToInput(cents: number): string {
  const whole = Math.trunc(cents / 100);
  const fraction = Math.abs(cents % 100);
  return `${whole}.${String(fraction).padStart(2, "0")}`;
}

// ---------------------------------------------------------------------------
// Product form -> patch
// ---------------------------------------------------------------------------

/** Every value is the raw text of its control, so "unchanged" is a plain string comparison. */
export interface ProductFormValues {
  name: string;
  slug: string;
  /** Category id, or "" for none. */
  categoryId: string;
  description: string;
  brand: string;
  sku: string;
  /** Major units, e.g. "250.00". */
  price: string;
  /** Major units, or "" for none. */
  compareAt: string;
  unitLabel: string;
}

export type ProductFormErrors = Partial<Record<ProductFieldKey, string>>;

export function productToFormValues(product: ProductRow): ProductFormValues {
  return {
    name: product.name,
    slug: product.slug,
    categoryId: product.category_id ?? "",
    description: product.description ?? "",
    brand: product.brand ?? "",
    sku: product.sku ?? "",
    price: centsToInput(product.price_cents),
    compareAt:
      product.compare_at_price_cents === null
        ? ""
        : centsToInput(product.compare_at_price_cents),
    unitLabel: product.unit_label ?? "",
  };
}

const SLUG_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const SKU_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

export function hasControlCharacter(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code < 32 || code === 127) return true;
  }
  return false;
}

/** Blank (after trimming) means "none", which the database stores as NULL. */
function blankToNull(text: string): string | null {
  const trimmed = text.trim();
  return trimmed === "" ? null : trimmed;
}

export function checkSku(raw: string): {
  value: string | null;
  error?: string;
} {
  const value = blankToNull(raw);
  if (value === null) return { value };
  if (value.length > 64 || !SKU_PATTERN.test(value)) {
    return {
      value,
      error:
        "Use up to 64 letters, digits, dots, slashes, underscores or hyphens.",
    };
  }
  return { value };
}

export interface ProductPatchResult {
  /** Only the fields that differ from the loaded product. Empty when nothing changed. */
  changes: AdminProductChanges;
  errors: ProductFormErrors;
}

/**
 * Builds the PATCH for admin_update_product(): only fields whose text differs from `initial`
 * are validated and sent, so an untouched legacy value can never block a save. This mirrors the
 * database's rules for usability only; the database re-checks everything.
 */
export function buildProductChanges(
  product: ProductRow,
  initial: ProductFormValues,
  values: ProductFormValues,
): ProductPatchResult {
  const changes: AdminProductChanges = {};
  const errors: ProductFormErrors = {};
  const changed = (key: keyof ProductFormValues) =>
    values[key] !== initial[key];

  if (changed("name")) {
    const name = values.name.trim();
    if (name.length < 1 || name.length > 200 || hasControlCharacter(name)) {
      errors.name = "Enter a name of 1 to 200 characters.";
    } else changes.name = name;
  }

  if (changed("slug")) {
    const slug = values.slug.trim();
    if (slug.length < 1 || slug.length > 120 || !SLUG_PATTERN.test(slug)) {
      errors.slug =
        "Use lower-case letters, digits and single hyphens (up to 120 characters).";
    } else changes.slug = slug;
  }

  if (changed("categoryId"))
    changes.category_id = values.categoryId === "" ? null : values.categoryId;

  if (changed("description")) {
    const description = blankToNull(values.description);
    if (description !== null && description.length > 4000) {
      errors.description = "Keep the description to 4000 characters or fewer.";
    } else changes.description = description;
  }

  if (changed("brand")) {
    const brand = blankToNull(values.brand);
    if (brand !== null && (brand.length > 100 || hasControlCharacter(brand))) {
      errors.brand = "Keep the brand to 100 characters or fewer.";
    } else changes.brand = brand;
  }

  if (changed("unitLabel")) {
    const unit = blankToNull(values.unitLabel);
    if (unit !== null && (unit.length > 40 || hasControlCharacter(unit))) {
      errors.unitLabel = "Keep the unit label to 40 characters or fewer.";
    } else changes.unit_label = unit;
  }

  if (changed("sku")) {
    const sku = checkSku(values.sku);
    if (sku.error) errors.sku = sku.error;
    else changes.sku = sku.value;
  }

  // Price and compare-at are checked together: compare-at must not be below the price.
  let priceCents = product.price_cents;
  if (changed("price")) {
    const parsed = parsePriceInput(values.price);
    if (!parsed.ok) errors.price = parsed.message;
    else {
      changes.price_cents = parsed.cents;
      priceCents = parsed.cents;
    }
  }

  const priceValid = errors.price === undefined;
  if (
    changed("compareAt") ||
    (changed("price") && values.compareAt.trim() !== "")
  ) {
    if (values.compareAt.trim() === "") {
      if (changed("compareAt")) changes.compare_at_price_cents = null;
    } else {
      const parsed = parsePriceInput(values.compareAt);
      if (!parsed.ok) errors.compareAt = parsed.message;
      else if (priceValid && parsed.cents < priceCents) {
        errors.compareAt =
          "The compare-at price can't be lower than the price.";
      } else if (changed("compareAt"))
        changes.compare_at_price_cents = parsed.cents;
    }
  }

  return { changes, errors };
}

export function hasChanges(changes: object): boolean {
  return Object.keys(changes).length > 0;
}

// ---------------------------------------------------------------------------
// Product form -> create arguments (Phase 6D-3B)
// ---------------------------------------------------------------------------

/** An empty create form. Blank optional fields are sent as null; the database stores NULL. */
export function emptyProductFormValues(): ProductFormValues {
  return {
    name: "",
    slug: "",
    categoryId: "",
    description: "",
    brand: "",
    sku: "",
    price: "",
    compareAt: "",
    unitLabel: "",
  };
}

/**
 * A suggested URL slug for a name: lower-case, accents dropped, anything that is not a letter or
 * digit becomes a single hyphen, capped at the database's 120 characters. It is only a
 * suggestion for the form; the database still validates whatever is sent.
 */
export function slugifyName(name: string): string {
  return name
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120)
    .replace(/-+$/g, "");
}

export interface ProductCreateResult {
  /** Present only when every field passed the usability checks. */
  args: AdminCreateProductArgs | null;
  errors: ProductFormErrors;
}

/**
 * Builds the arguments of admin_create_product(). name, slug and price are required; everything
 * else is optional and blank means null. Stock, active status and the image are not part of the
 * contract and are never sent: a new product gets the table defaults (stock 0, ACTIVE, no image).
 * These checks mirror the database for usability only; the database re-checks everything.
 */
export function buildCreateProductArgs(
  values: ProductFormValues,
): ProductCreateResult {
  const errors: ProductFormErrors = {};

  const name = values.name.trim();
  if (name.length < 1 || name.length > 200 || hasControlCharacter(name)) {
    errors.name = "Enter a name of 1 to 200 characters.";
  }

  const slug = values.slug.trim();
  if (slug.length < 1 || slug.length > 120 || !SLUG_PATTERN.test(slug)) {
    errors.slug =
      "Use lower-case letters, digits and single hyphens (up to 120 characters).";
  }

  const description = blankToNull(values.description);
  if (description !== null && description.length > 4000) {
    errors.description = "Keep the description to 4000 characters or fewer.";
  }

  const brand = blankToNull(values.brand);
  if (brand !== null && (brand.length > 100 || hasControlCharacter(brand))) {
    errors.brand = "Keep the brand to 100 characters or fewer.";
  }

  const unit = blankToNull(values.unitLabel);
  if (unit !== null && (unit.length > 40 || hasControlCharacter(unit))) {
    errors.unitLabel = "Keep the unit label to 40 characters or fewer.";
  }

  const sku = checkSku(values.sku);
  if (sku.error) errors.sku = sku.error;

  let priceCents = 0;
  const price = parsePriceInput(values.price);
  if (!price.ok) errors.price = price.message;
  else priceCents = price.cents;

  let compareAtCents: number | null = null;
  if (values.compareAt.trim() !== "") {
    const compareAt = parsePriceInput(values.compareAt);
    if (!compareAt.ok) errors.compareAt = compareAt.message;
    else if (price.ok && compareAt.cents < priceCents) {
      errors.compareAt = "The compare-at price can't be lower than the price.";
    } else compareAtCents = compareAt.cents;
  }

  if (Object.keys(errors).length > 0) return { args: null, errors };

  return {
    errors,
    args: {
      p_name: name,
      p_slug: slug,
      p_price_cents: priceCents,
      p_category_id: values.categoryId === "" ? null : values.categoryId,
      p_description: description,
      p_brand: brand,
      p_sku: sku.value,
      p_unit_label: unit,
      p_compare_at_price_cents: compareAtCents,
    },
  };
}

// ---------------------------------------------------------------------------
// Variant form -> patch
// ---------------------------------------------------------------------------

/** Catalogue fields and the Active switch. Stock and attributes are not editable on this screen. */
export interface VariantFormValues {
  name: string;
  sku: string;
  price: string;
  compareAt: string;
  position: string;
  active: boolean;
}

export type VariantFormErrors = Partial<Record<VariantFieldKey, string>>;

export function variantToFormValues(
  variant: ProductVariantRow,
): VariantFormValues {
  return {
    name: variant.name,
    sku: variant.sku ?? "",
    price: centsToInput(variant.price_cents),
    compareAt:
      variant.compare_at_price_cents === null
        ? ""
        : centsToInput(variant.compare_at_price_cents),
    position: String(variant.position),
    active: variant.is_active,
  };
}

export const MAX_VARIANT_POSITION = 100_000;

export function buildVariantChanges(
  variant: ProductVariantRow,
  initial: VariantFormValues,
  values: VariantFormValues,
): { changes: AdminProductVariantChanges; errors: VariantFormErrors } {
  const changes: AdminProductVariantChanges = {};
  const errors: VariantFormErrors = {};
  const changed = (key: keyof VariantFormValues) =>
    values[key] !== initial[key];

  if (changed("name")) {
    const name = values.name.trim();
    if (name.length < 1 || name.length > 200 || hasControlCharacter(name)) {
      errors.name = "Enter a name of 1 to 200 characters.";
    } else changes.name = name;
  }

  if (changed("sku")) {
    const sku = checkSku(values.sku);
    if (sku.error) errors.sku = sku.error;
    else changes.sku = sku.value;
  }

  let priceCents = variant.price_cents;
  if (changed("price")) {
    const parsed = parsePriceInput(values.price);
    if (!parsed.ok) errors.price = parsed.message;
    else {
      changes.price_cents = parsed.cents;
      priceCents = parsed.cents;
    }
  }

  const priceValid = errors.price === undefined;
  if (
    changed("compareAt") ||
    (changed("price") && values.compareAt.trim() !== "")
  ) {
    if (values.compareAt.trim() === "") {
      if (changed("compareAt")) changes.compare_at_price_cents = null;
    } else {
      const parsed = parsePriceInput(values.compareAt);
      if (!parsed.ok) errors.compareAt = parsed.message;
      else if (priceValid && parsed.cents < priceCents) {
        errors.compareAt =
          "The compare-at price can't be lower than the price.";
      } else if (changed("compareAt"))
        changes.compare_at_price_cents = parsed.cents;
    }
  }

  if (changed("position")) {
    const text = values.position.trim();
    const position = Number(text);
    if (
      !/^\d{1,6}$/.test(text) ||
      !Number.isInteger(position) ||
      position > MAX_VARIANT_POSITION
    ) {
      errors.position = `Enter a whole number from 0 to ${MAX_VARIANT_POSITION.toLocaleString("en-US")}.`;
    } else changes.position = position;
  }

  if (changed("active")) changes.is_active = values.active;

  return { changes, errors };
}
