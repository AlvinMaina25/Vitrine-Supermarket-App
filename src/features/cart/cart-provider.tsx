import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

import type { ProductRow, ProductVariantRow } from "@/lib/supabase/types";

/**
 * Basket state.
 *
 * Still backed by localStorage so guests can shop, but the shape and the API
 * are deliberately storage-agnostic: swapping in a Supabase-backed basket for
 * signed-in customers means replacing the read/write helpers below, not the
 * components that consume `useCart()`.
 *
 * Prices held here are for display only. Checkout re-prices every line in the
 * database before an order exists.
 */

export interface CartLine {
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

export interface CartLineIdentity {
  productId: string;
  variantId: string | null;
}

interface CartState {
  lines: CartLine[];
  itemCount: number;
  subtotalCents: number;
  hydrated: boolean;
  add: (
    product: ProductRow,
    quantity?: number,
    variant?: ProductVariantRow | null,
  ) => void;
  setQuantity: (
    productId: string,
    quantity: number,
    variantId?: string | null,
  ) => void;
  remove: (productId: string, variantId?: string | null) => void;
  /** Puts a removed line back exactly as it was (for "Undo"). Does nothing if it is already there. */
  restore: (line: CartLine) => void;
  /** Applies an authoritative price from the database to a line. */
  repriceLine: (identity: CartLineIdentity, priceCents: number) => void;
  removeMany: (identities: CartLineIdentity[]) => void;
  clear: () => void;
}

const STORAGE_KEY = "storefront.cart.v1";
const MAX_QUANTITY = 99;

const CartContext = createContext<CartState | null>(null);

export function cartLineKey(
  productId: string,
  variantId: string | null | undefined,
): string {
  return `${productId}:${variantId ?? ""}`;
}

function sameLine(
  line: CartLine,
  productId: string,
  variantId: string | null | undefined,
): boolean {
  return (
    line.productId === productId &&
    (line.variantId ?? null) === (variantId ?? null)
  );
}

/** Tolerates baskets written by earlier versions that had no variant fields. */
function normaliseLine(value: unknown): CartLine | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw["productId"] !== "string" || typeof raw["name"] !== "string")
    return null;
  const quantity = typeof raw["quantity"] === "number" ? raw["quantity"] : 1;
  return {
    productId: raw["productId"],
    variantId: typeof raw["variantId"] === "string" ? raw["variantId"] : null,
    slug: typeof raw["slug"] === "string" ? raw["slug"] : "",
    name: raw["name"],
    variantName:
      typeof raw["variantName"] === "string" ? raw["variantName"] : null,
    unitLabel: typeof raw["unitLabel"] === "string" ? raw["unitLabel"] : null,
    priceCents: typeof raw["priceCents"] === "number" ? raw["priceCents"] : 0,
    imageUrl: typeof raw["imageUrl"] === "string" ? raw["imageUrl"] : null,
    quantity: Math.min(MAX_QUANTITY, Math.max(1, Math.round(quantity))),
  };
}

function readStoredLines(): CartLine[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map(normaliseLine)
      .filter((line): line is CartLine => line !== null);
  } catch {
    return [];
  }
}

export function CartProvider({ children }: { children: ReactNode }) {
  const [lines, setLines] = useState<CartLine[]>([]);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    setLines(readStoredLines());
    setHydrated(true);
  }, []);

  useEffect(() => {
    if (!hydrated) return;
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(lines));
  }, [lines, hydrated]);

  const add = useCallback(
    (
      product: ProductRow,
      quantity = 1,
      variant: ProductVariantRow | null = null,
    ) => {
      const variantId = variant?.id ?? null;
      setLines((current) => {
        const existing = current.find((line) =>
          sameLine(line, product.id, variantId),
        );
        if (existing) {
          return current.map((line) =>
            sameLine(line, product.id, variantId)
              ? {
                  ...line,
                  quantity: Math.min(MAX_QUANTITY, line.quantity + quantity),
                }
              : line,
          );
        }
        return [
          ...current,
          {
            productId: product.id,
            variantId,
            slug: product.slug,
            name: product.name,
            variantName: variant?.name ?? null,
            unitLabel: product.unit_label,
            priceCents: variant?.price_cents ?? product.price_cents,
            imageUrl: product.image_url,
            quantity: Math.min(MAX_QUANTITY, Math.max(1, quantity)),
          },
        ];
      });
    },
    [],
  );

  const setQuantity = useCallback(
    (productId: string, quantity: number, variantId: string | null = null) => {
      setLines((current) =>
        quantity <= 0
          ? current.filter((line) => !sameLine(line, productId, variantId))
          : current.map((line) =>
              sameLine(line, productId, variantId)
                ? { ...line, quantity: Math.min(MAX_QUANTITY, quantity) }
                : line,
            ),
      );
    },
    [],
  );

  const remove = useCallback(
    (productId: string, variantId: string | null = null) => {
      setLines((current) =>
        current.filter((line) => !sameLine(line, productId, variantId)),
      );
    },
    [],
  );

  const restore = useCallback((line: CartLine) => {
    setLines((current) =>
      current.some((existing) =>
        sameLine(existing, line.productId, line.variantId),
      )
        ? current
        : [
            ...current,
            {
              ...line,
              quantity: Math.min(MAX_QUANTITY, Math.max(1, line.quantity)),
            },
          ],
    );
  }, []);

  const repriceLine = useCallback(
    (identity: CartLineIdentity, priceCents: number) => {
      setLines((current) =>
        current.map((line) =>
          sameLine(line, identity.productId, identity.variantId)
            ? { ...line, priceCents }
            : line,
        ),
      );
    },
    [],
  );

  const removeMany = useCallback((identities: CartLineIdentity[]) => {
    setLines((current) =>
      current.filter(
        (line) =>
          !identities.some((identity) =>
            sameLine(line, identity.productId, identity.variantId),
          ),
      ),
    );
  }, []);

  const clear = useCallback(() => setLines([]), []);

  const value = useMemo<CartState>(() => {
    const itemCount = lines.reduce((total, line) => total + line.quantity, 0);
    const subtotalCents = lines.reduce(
      (total, line) => total + line.priceCents * line.quantity,
      0,
    );
    return {
      lines,
      itemCount,
      subtotalCents,
      hydrated,
      add,
      setQuantity,
      remove,
      restore,
      repriceLine,
      removeMany,
      clear,
    };
  }, [
    lines,
    hydrated,
    add,
    setQuantity,
    remove,
    restore,
    repriceLine,
    removeMany,
    clear,
  ]);

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}

export function useCart(): CartState {
  const context = useContext(CartContext);
  if (!context) throw new Error("useCart must be used inside <CartProvider>.");
  return context;
}
