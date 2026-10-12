/**
 * Pure logic for the "starting stock" and "Active" fields of the product CREATE form (Phase 20C).
 * No imports, so it runs under `node --test`.
 *
 * admin_create_product() is not changed. A new product is created active with no stock; the form
 * then chains two EXISTING admin functions, each its own transaction:
 *
 *   1. admin_create_product            (always)
 *   2. admin_adjust_inventory          (only when starting stock is above 0; reason "Opening stock")
 *   3. admin_set_product_active(false) (only when Active is switched off)
 *
 * If step 2 or 3 fails the product is kept. Step 3 is still tried after step 2 fails, because a
 * product the admin meant to hide must not be left visible just because the stock call failed.
 * Nothing here decides authorisation; every function re-checks require_admin().
 */

export const OPENING_STOCK_REASON = "Opening stock";

/** The largest value admin_adjust_inventory() accepts (a PostgreSQL integer). */
export const MAX_STARTING_STOCK = 2_147_483_647;

export type StartingStockParse =
  | { ok: true; value: number }
  | { ok: false; message: string };

/** Blank means the default, 0. Otherwise digits only: no sign, decimal point, exponent or spaces inside. */
export function parseStartingStock(raw: string): StartingStockParse {
  const text = raw.trim();
  if (text === "") return { ok: true, value: 0 };
  if (!/^\d+$/.test(text)) {
    return { ok: false, message: "Enter a whole number, 0 or more." };
  }
  const value = Number(text);
  if (!Number.isSafeInteger(value) || value > MAX_STARTING_STOCK) {
    return { ok: false, message: "That number is too large." };
  }
  return { ok: true, value };
}

export type FollowUpStep = "stock" | "active";

export interface CreateExtras {
  /** Already parsed with parseStartingStock(). */
  stock: number;
  active: boolean;
}

/** The steps after creation, in the order they run. A zero adjustment is refused by the database, so 0 means no step. */
export function planFollowUpSteps(extras: CreateExtras): FollowUpStep[] {
  const steps: FollowUpStep[] = [];
  if (extras.stock > 0) steps.push("stock");
  if (!extras.active) steps.push("active");
  return steps;
}

export interface CreateRunDeps<P> {
  create: () => Promise<P>;
  /** Reads the new product's id from what create() returned. */
  idOf: (created: P) => string;
  adjustStock: (productId: string, quantity: number) => Promise<unknown>;
  deactivate: (productId: string) => Promise<unknown>;
  /** Raw errors of the follow-up steps go here (the console in the app). */
  onStepError?: (step: FollowUpStep, cause: unknown) => void;
}

export interface CreateRunResult<P> {
  product: P;
  /** Follow-up steps that did not complete, in plan order. Empty means everything was saved. */
  failed: FollowUpStep[];
}

/**
 * Runs the chain. A failure of create() is thrown unchanged, so nothing was written and the
 * caller's normal error handling applies. A failure of a follow-up step never throws: it is
 * recorded in `failed` and the next step still runs.
 */
export async function runCreateWithExtras<P>(
  extras: CreateExtras,
  deps: CreateRunDeps<P>,
): Promise<CreateRunResult<P>> {
  const product = await deps.create();
  const id = deps.idOf(product);
  const failed: FollowUpStep[] = [];
  for (const step of planFollowUpSteps(extras)) {
    try {
      if (step === "stock") await deps.adjustStock(id, extras.stock);
      else await deps.deactivate(id);
    } catch (cause) {
      deps.onStepError?.(step, cause);
      failed.push(step);
    }
  }
  return { product, failed };
}

const PARTIAL_MESSAGES = {
  stock:
    "The product was created, but starting stock was not saved. Set it on the product page.",
  active:
    "The product was created, but it could not be hidden, so it is still visible in the storefront. Deactivate it on the product page.",
  both: "The product was created, but starting stock was not saved and it could not be hidden, so it is still visible in the storefront. Fix both on the product page.",
} as const;

/** Plain-words message for a partial result, or null when everything was saved. */
export function describePartialCreate(failed: FollowUpStep[]): string | null {
  const stock = failed.includes("stock");
  const active = failed.includes("active");
  if (stock && active) return PARTIAL_MESSAGES.both;
  if (stock) return PARTIAL_MESSAGES.stock;
  if (active) return PARTIAL_MESSAGES.active;
  return null;
}
