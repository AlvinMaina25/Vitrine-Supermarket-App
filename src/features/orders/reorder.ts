import { MAX_LINE_QUANTITY } from "../cart/line-state.ts";

/**
 * Phase 14: "Buy again" — pure planning helpers.
 *
 * The order's items are a SNAPSHOT of what was bought at the time. Reorder never trusts them for
 * today's price or stock: each line is re-checked by the existing basket validation
 * (validate_cart() via cartValidationQuery) and the database's answer decides what is added,
 * what is unavailable and what changed price. Nothing here decides stock or a price, and nothing
 * here places an order; it only arranges the database's answers into a basket change and a
 * plain summary.
 *
 * Types are structural copies of CartLine / CartIssue so this file stays free of React imports.
 */

export interface ReorderSourceItem {
  product_id: string | null;
  variant_id: string | null;
  product_name: string;
  product_slug: string | null;
  variant_name: string | null;
  unit_label: string | null;
  image_url: string | null;
  unit_price_cents: number;
  quantity: number;
}

/** Same fields as CartLine. */
export interface ReorderLine {
  productId: string;
  variantId: string | null;
  slug: string;
  name: string;
  variantName: string | null;
  unitLabel: string | null;
  priceCents: number;
  imageUrl: string | null;
  quantity: number;
}

/** The part of CartIssue this plan reads. */
export interface ReorderIssue {
  productId: string;
  variantId: string | null;
  kind: string;
  message: string;
  maxQuantity?: number | undefined;
  newPriceCents?: number | undefined;
}

export interface SkippedItem {
  name: string;
  reason: string;
}

export interface ReorderUnavailable {
  name: string;
  reason: string;
}

export interface ReorderAdded {
  name: string;
  variantName: string | null;
  quantity: number;
}

export interface ReorderPriceChange {
  name: string;
  /** What the old order paid per unit (the snapshot). */
  oldCents: number;
  /** What the database says it costs now. */
  newCents: number;
}

export interface ReorderReduced {
  name: string;
  requested: number;
  added: number;
}

export interface ReorderPlan {
  /** Lines to put in the basket, priced as the database answered. */
  toAdd: ReorderLine[];
  added: ReorderAdded[];
  unavailable: ReorderUnavailable[];
  priceChanged: ReorderPriceChange[];
  reduced: ReorderReduced[];
}

const NO_PRODUCT_REASON =
  "This item is no longer linked to a product in our shop.";

/** Short customer wording for a line that cannot be added; the basket's own wording says "remove it to continue". */
function unavailableReason(issue: ReorderIssue): string {
  switch (issue.kind) {
    case "removed":
      return "No longer sold.";
    case "unavailable":
    case "out_of_stock":
      return "Currently unavailable.";
    case "variant_unavailable":
      return "That option is no longer available.";
    case "insufficient_stock":
      return "Out of stock.";
    default:
      return issue.message;
  }
}

export function lineKey(productId: string, variantId: string | null): string {
  return `${productId}:${variantId ?? ""}`;
}

function clampQuantity(quantity: number): number {
  return Math.min(MAX_LINE_QUANTITY, Math.max(1, Math.round(quantity)));
}

/**
 * Turns the order's snapshot items into basket lines to validate. Items whose product link no
 * longer exists (product_id is null) are skipped and reported. Duplicate product+variant lines
 * are merged. The snapshot price is carried only so the validation can tell if it changed.
 */
export function buildReorderLines(items: readonly ReorderSourceItem[]): {
  lines: ReorderLine[];
  skipped: SkippedItem[];
} {
  const lines = new Map<string, ReorderLine>();
  const skipped: SkippedItem[] = [];

  for (const item of items) {
    if (!item.product_id) {
      skipped.push({ name: item.product_name, reason: NO_PRODUCT_REASON });
      continue;
    }
    const key = lineKey(item.product_id, item.variant_id);
    const existing = lines.get(key);
    if (existing) {
      existing.quantity = clampQuantity(existing.quantity + item.quantity);
      continue;
    }
    lines.set(key, {
      productId: item.product_id,
      variantId: item.variant_id,
      slug: item.product_slug ?? "",
      name: item.product_name,
      variantName: item.variant_name,
      unitLabel: item.unit_label,
      priceCents: item.unit_price_cents,
      imageUrl: item.image_url,
      quantity: clampQuantity(item.quantity),
    });
  }

  return { lines: [...lines.values()], skipped };
}

/**
 * Arranges the database's validation answer. A line with no issue is available at the snapshot
 * price (the database compared them and found no difference).
 */
export function planReorder(
  lines: readonly ReorderLine[],
  issues: readonly ReorderIssue[],
): ReorderPlan {
  const issueByKey = new Map(
    issues.map((issue) => [lineKey(issue.productId, issue.variantId), issue]),
  );
  const plan: ReorderPlan = {
    toAdd: [],
    added: [],
    unavailable: [],
    priceChanged: [],
    reduced: [],
  };

  for (const line of lines) {
    const issue = issueByKey.get(lineKey(line.productId, line.variantId));

    if (!issue) {
      plan.toAdd.push({ ...line });
      plan.added.push({
        name: line.name,
        variantName: line.variantName,
        quantity: line.quantity,
      });
      continue;
    }

    if (
      issue.kind === "price_changed" &&
      typeof issue.newPriceCents === "number"
    ) {
      plan.toAdd.push({ ...line, priceCents: issue.newPriceCents });
      plan.added.push({
        name: line.name,
        variantName: line.variantName,
        quantity: line.quantity,
      });
      plan.priceChanged.push({
        name: line.name,
        oldCents: line.priceCents,
        newCents: issue.newPriceCents,
      });
      continue;
    }

    if (
      issue.kind === "insufficient_stock" &&
      typeof issue.maxQuantity === "number" &&
      issue.maxQuantity > 0
    ) {
      // The database gave no current price for this line; the basket re-validates it.
      const quantity = clampQuantity(
        Math.min(issue.maxQuantity, line.quantity),
      );
      plan.toAdd.push({ ...line, quantity });
      plan.added.push({
        name: line.name,
        variantName: line.variantName,
        quantity,
      });
      plan.reduced.push({
        name: line.name,
        requested: line.quantity,
        added: quantity,
      });
      continue;
    }

    plan.unavailable.push({
      name: line.name,
      reason: unavailableReason(issue),
    });
  }

  return plan;
}

export type ReorderTone = "success" | "partial" | "none";

export interface ReorderSummary {
  tone: ReorderTone;
  headline: string;
}

function itemsWord(count: number): string {
  return `${count} ${count === 1 ? "item" : "items"}`;
}

/** One plain sentence. "Nothing was added" is never worded as a success. */
export function summariseReorder(
  plan: ReorderPlan,
  skipped: readonly SkippedItem[],
): ReorderSummary {
  const addedCount = plan.added.length;
  const total = addedCount + plan.unavailable.length + skipped.length;

  if (addedCount === 0) {
    return { tone: "none", headline: "Nothing was added to your basket." };
  }
  const everythingAdded =
    plan.unavailable.length === 0 &&
    skipped.length === 0 &&
    plan.reduced.length === 0;
  if (everythingAdded) {
    return {
      tone: "success",
      headline: `Added ${itemsWord(addedCount)} to your basket.`,
    };
  }
  return {
    tone: "partial",
    headline: `Added ${addedCount} of ${itemsWord(total)} to your basket.`,
  };
}

export interface BasketLineLike {
  productId: string;
  variantId: string | null;
  quantity: number;
}

export interface BasketChanges {
  /** Lines not in the basket yet: put them in as they are. */
  restore: ReorderLine[];
  /** Lines already in the basket: new quantity and the database's price. */
  update: {
    productId: string;
    variantId: string | null;
    quantity: number;
    priceCents: number;
  }[];
}

/**
 * Turns the plan into basket operations without creating duplicate lines: a product already in
 * the basket gets its quantity increased (up to the basket maximum) and the validated price.
 */
export function planBasketChanges(
  toAdd: readonly ReorderLine[],
  basket: readonly BasketLineLike[],
): BasketChanges {
  const inBasket = new Map(
    basket.map((line) => [lineKey(line.productId, line.variantId), line]),
  );
  const changes: BasketChanges = { restore: [], update: [] };

  for (const line of toAdd) {
    const existing = inBasket.get(lineKey(line.productId, line.variantId));
    if (!existing) {
      changes.restore.push(line);
      continue;
    }
    changes.update.push({
      productId: line.productId,
      variantId: line.variantId,
      quantity: clampQuantity(existing.quantity + line.quantity),
      priceCents: line.priceCents,
    });
  }
  return changes;
}
