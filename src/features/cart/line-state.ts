import type { CartIssue } from "./validation.ts";

/**
 * Phase 13: how one basket line is described to the customer.
 *
 * Everything here is a re-labelling of the database's own answer (validate_cart(), already mapped
 * to CartIssue[] in validation.ts). Nothing decides stock or price. A line with no issue is "in
 * stock" only because the database said it is available; while that answer is missing the state is
 * "checking" and no claim is made.
 */

export const MAX_LINE_QUANTITY = 99;

export type LineState =
  /** The validation answer is not here yet (loading, offline or failed): say nothing. */
  | { kind: "checking" }
  | { kind: "in_stock" }
  /** The database says fewer than the basket holds are available. */
  | { kind: "low_stock"; maxQuantity: number }
  | { kind: "unavailable" }
  /** The database price differs from the one stored in the basket. */
  | { kind: "price_changed"; newPriceCents: number };

export function lineStateFor(
  key: string,
  issues: readonly CartIssue[] | undefined,
): LineState {
  if (issues === undefined) return { kind: "checking" };
  const issue = issues.find((candidate) => candidate.key === key);
  if (issue === undefined) return { kind: "in_stock" };
  if (issue.kind === "price_changed") {
    return issue.newPriceCents === undefined
      ? { kind: "unavailable" }
      : { kind: "price_changed", newPriceCents: issue.newPriceCents };
  }
  if (issue.kind === "insufficient_stock" && issue.maxQuantity !== undefined) {
    return { kind: "low_stock", maxQuantity: issue.maxQuantity };
  }
  return { kind: "unavailable" };
}

export type LineTone = "ok" | "warn" | "danger";

export interface LineBadge {
  text: string;
  tone: LineTone;
}

/** The short badge shown on the line, or null when there is nothing honest to say yet. */
export function lineBadge(state: LineState): LineBadge | null {
  switch (state.kind) {
    case "checking":
      return null;
    case "in_stock":
      return { text: "In stock", tone: "ok" };
    case "low_stock":
      return { text: `Only ${state.maxQuantity} left`, tone: "warn" };
    case "unavailable":
      return { text: "Unavailable", tone: "danger" };
    case "price_changed":
      return { text: "Price changed", tone: "warn" };
  }
}

/** The most the stepper should allow for this line. Only the database lowers it below 99. */
export function lineMaxQuantity(state: LineState): number {
  return state.kind === "low_stock"
    ? Math.min(state.maxQuantity, MAX_LINE_QUANTITY)
    : MAX_LINE_QUANTITY;
}

/**
 * What to tell the customer after a typed quantity was changed to fit. Null when nothing was
 * changed. `requested` is the number they typed; `applied` is what the stepper kept.
 */
export function clampMessage(
  requested: number,
  applied: number,
  limits: { min: number; max: number; stockLimited: boolean },
): string | null {
  if (!Number.isFinite(requested) || requested === applied) return null;
  if (requested > limits.max) {
    return limits.stockLimited
      ? `Only ${limits.max} available, so we set the quantity to ${applied}.`
      : `You can order up to ${limits.max} of one item, so we set the quantity to ${applied}.`;
  }
  if (requested < limits.min) {
    return `The smallest quantity is ${limits.min}. To take the item out, use Remove.`;
  }
  return null;
}

/** Whether any line blocks checkout: the database said it cannot be bought as it is. */
export function hasBlockingLine(states: readonly LineState[]): boolean {
  return states.some(
    (state) =>
      state.kind === "unavailable" ||
      state.kind === "low_stock" ||
      state.kind === "price_changed",
  );
}

export interface SubtotalDisplay {
  label: string;
  /** Integer cents to format, or null while the database has not answered yet. */
  cents: number | null;
  /** True when the number is the basket's saved-price estimate, not a database answer. */
  estimated: boolean;
}

/**
 * Which subtotal the basket page shows. The database's number (validate_coupon's subtotal) is used
 * whenever there is one. Without it (signed out, or the answer failed) the basket's own saved
 * prices give an ESTIMATE that is labelled as one; while the answer is still coming nothing is
 * shown. The local number is never presented as the real subtotal.
 */
export function cartSubtotalDisplay(input: {
  serverSubtotalCents: number | null;
  serverPending: boolean;
  savedPricesEstimateCents: number;
}): SubtotalDisplay {
  if (input.serverSubtotalCents !== null) {
    return {
      label: "Subtotal",
      cents: input.serverSubtotalCents,
      estimated: false,
    };
  }
  if (input.serverPending) {
    return { label: "Subtotal", cents: null, estimated: false };
  }
  return {
    label: "Estimated subtotal",
    cents: input.savedPricesEstimateCents,
    estimated: true,
  };
}
