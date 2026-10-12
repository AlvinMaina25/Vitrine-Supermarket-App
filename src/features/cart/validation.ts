import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type { CartValidationRow } from "@/lib/supabase/types";

import { cartLineKey, type CartLine } from "./cart-provider";

/**
 * Basket validation.
 *
 * Mirrors the checks create_order() performs, so the customer sees price and
 * availability problems in the basket rather than as a failed order. The
 * database remains the authority — this is a warning layer, not a gate.
 */

export type CartIssueKind =
  | "unavailable"
  | "variant_unavailable"
  | "out_of_stock"
  | "insufficient_stock"
  | "price_changed"
  | "removed";

export interface CartIssue {
  key: string;
  productId: string;
  variantId: string | null;
  name: string;
  kind: CartIssueKind;
  message: string;
  /** Present when the line can be fixed by lowering the quantity. */
  maxQuantity?: number;
  /** Present when the line can be fixed by accepting the new price. */
  newPriceCents?: number;
}

export const cartValidationQuery = (lines: CartLine[]) =>
  queryOptions({
    queryKey: [
      "cart",
      "validation",
      lines
        .map(
          (line) =>
            `${cartLineKey(line.productId, line.variantId)}x${line.quantity}@${line.priceCents}`,
        )
        .join("|"),
    ],
    enabled: lines.length > 0,
    staleTime: 30_000,
    queryFn: async (): Promise<CartIssue[]> => {
      const { data, error } = await requireSupabase().rpc("validate_cart", {
        p_items: lines.map((line) => ({
          product_id: line.productId,
          variant_id: line.variantId,
          quantity: line.quantity,
        })),
      });
      if (error) throw new Error(error.message);

      const rows = (data ?? []) as CartValidationRow[];
      const byKey = new Map(
        rows.map((row) => [cartLineKey(row.product_id, row.variant_id), row]),
      );

      return lines.flatMap((line): CartIssue[] => {
        const key = cartLineKey(line.productId, line.variantId);
        const row = byKey.get(key);

        if (!row) {
          return [
            {
              key,
              productId: line.productId,
              variantId: line.variantId,
              name: line.name,
              kind: "removed",
              message: `${line.name} is no longer sold. Remove it to continue.`,
            },
          ];
        }

        if (!row.available) {
          const kind: CartIssueKind =
            row.reason === "insufficient_stock"
              ? "insufficient_stock"
              : row.reason === "variant_unavailable"
                ? "variant_unavailable"
                : row.reason === "out_of_stock"
                  ? "out_of_stock"
                  : "unavailable";

          const message =
            kind === "insufficient_stock"
              ? `Only ${Math.max(row.stock_quantity, 0)} left of ${row.name}.`
              : kind === "variant_unavailable"
                ? `That option of ${row.name} is no longer available.`
                : `${row.name} is currently unavailable.`;

          const issue: CartIssue = {
            key,
            productId: line.productId,
            variantId: line.variantId,
            name: row.name,
            kind,
            message,
          };
          if (kind === "insufficient_stock" && row.stock_quantity > 0) {
            issue.maxQuantity = row.stock_quantity;
          }
          return [issue];
        }

        if (row.unit_price_cents !== line.priceCents) {
          return [
            {
              key,
              productId: line.productId,
              variantId: line.variantId,
              name: row.name,
              kind: "price_changed",
              message: `The price of ${row.name} has changed since you added it.`,
              newPriceCents: row.unit_price_cents,
            },
          ];
        }

        return [];
      });
    },
  });
