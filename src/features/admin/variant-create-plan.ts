import type { AdminCreateProductVariantArgs } from "../../lib/supabase/types.ts";
import {
  checkSku,
  hasControlCharacter,
  MAX_VARIANT_POSITION,
  parsePriceInput,
} from "./products-result.ts";
import {
  parseStartingStock,
  type CreateExtras,
  type FollowUpStep,
} from "./product-create-plan.ts";

/**
 * Pure logic for the "Add variant" dialog (Phase 21a). No React, so it runs under `node --test`.
 *
 * The chain itself is runCreateWithExtras() from product-create-plan.ts (Phase 20C), not a copy:
 *
 *   1. admin_create_product_variant     (always; the variant starts with stock 0 and is active)
 *   2. admin_adjust_inventory           (only when starting stock is above 0; reason "Opening stock")
 *   3. admin_update_product_variant     (only when Active is off: { is_active: false })
 *
 * If step 2 or 3 fails the variant is kept. Nothing here decides authorisation or limits; the
 * database re-checks everything behind require_admin().
 */

export type NewVariantFieldKey =
  "name" | "sku" | "price" | "compareAt" | "stock";

export interface NewVariantFormValues {
  name: string;
  sku: string;
  price: string;
  compareAt: string;
  stock: string;
  active: boolean;
}

export type NewVariantFormErrors = Partial<Record<NewVariantFieldKey, string>>;

export function emptyNewVariantValues(): NewVariantFormValues {
  return {
    name: "",
    sku: "",
    price: "",
    compareAt: "",
    stock: "",
    active: true,
  };
}

/**
 * The next free display position: one above the highest position in use, or 0 for the first
 * variant. Capped at the database maximum, where a tie is harmless (ties sort by name).
 */
export function nextVariantPosition(used: readonly number[]): number {
  if (used.length === 0) return 0;
  return Math.min(Math.max(...used) + 1, MAX_VARIANT_POSITION);
}

export type NewVariantBuild =
  | {
      ok: true;
      args: AdminCreateProductVariantArgs;
      extras: CreateExtras;
    }
  | { ok: false; errors: NewVariantFormErrors };

/** Form text -> RPC arguments plus the follow-up plan, or one message per bad field. */
export function buildNewVariant(
  productId: string,
  values: NewVariantFormValues,
  position: number,
): NewVariantBuild {
  const errors: NewVariantFormErrors = {};

  const name = values.name.trim();
  if (name.length < 1 || name.length > 200 || hasControlCharacter(name)) {
    errors.name = "Enter a name of 1 to 200 characters.";
  }

  const sku = checkSku(values.sku);
  if (sku.error) errors.sku = sku.error;

  const price = parsePriceInput(values.price);
  if (!price.ok) errors.price = price.message;

  let compareAt: number | null = null;
  if (values.compareAt.trim() !== "") {
    const parsed = parsePriceInput(values.compareAt);
    if (!parsed.ok) errors.compareAt = parsed.message;
    else if (price.ok && parsed.cents < price.cents) {
      errors.compareAt = "The compare-at price can't be lower than the price.";
    } else compareAt = parsed.cents;
  }

  const stock = parseStartingStock(values.stock);
  if (!stock.ok) errors.stock = stock.message;

  if (Object.keys(errors).length > 0 || !price.ok || !stock.ok) {
    return { ok: false, errors };
  }
  return {
    ok: true,
    args: {
      p_product_id: productId,
      p_name: name,
      p_price_cents: price.cents,
      p_sku: sku.value,
      p_compare_at_price_cents: compareAt,
      p_position: position,
    },
    extras: { stock: stock.value, active: values.active },
  };
}

const PARTIAL_MESSAGES = {
  stock: (name: string) =>
    `Variant “${name}” was added, but its starting stock was not saved. Set it on the Inventory screen.`,
  active: (name: string) =>
    `Variant “${name}” was added, but it could not be hidden, so customers can still see it. Open Edit on this variant and switch Active off.`,
  both: (name: string) =>
    `Variant “${name}” was added, but its starting stock was not saved and it could not be hidden, so customers can still see it. Set the stock on the Inventory screen. Open Edit on this variant and switch Active off.`,
} as const;

/** Plain-words message for a partial result, or null when everything was saved. */
export function describePartialVariant(
  name: string,
  failed: readonly FollowUpStep[],
): string | null {
  const stock = failed.includes("stock");
  const active = failed.includes("active");
  if (stock && active) return PARTIAL_MESSAGES.both(name);
  if (stock) return PARTIAL_MESSAGES.stock(name);
  if (active) return PARTIAL_MESSAGES.active(name);
  return null;
}
