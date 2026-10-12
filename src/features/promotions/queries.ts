import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import {
  normalizeCouponCode,
  parseCouponPreview,
  type CouponPreview,
} from "./logic";

/**
 * Customer wiring for coupons (Phase 8). Thin: one RPC, validate_coupon(), which prices the basket
 * from the database and answers with a safe jsonb. It is a PREVIEW. The binding decision is taken
 * again inside create_order(); nothing the browser holds can set a discount, only a code is sent.
 */

export interface CouponLine {
  productId: string;
  variantId: string | null;
  quantity: number;
}

/** The delivery selection the database prices the final total with. Identifiers only, never an amount. */
export interface CouponDelivery {
  methodCode: string;
  zoneId: string | null;
}

/**
 * `code` null previews the automatic promotion (if any). `delivery` null asks without a delivery
 * selection: the reply then carries no total.
 */
export async function validateCoupon(
  lines: readonly CouponLine[],
  code: string | null,
  delivery: CouponDelivery | null,
): Promise<CouponPreview> {
  const supabase = requireSupabase();
  const { data, error } = await supabase.rpc("validate_coupon", {
    p_items: lines.map((line) => ({
      product_id: line.productId,
      variant_id: line.variantId,
      quantity: line.quantity,
    })),
    p_code: normalizeCouponCode(code),
    p_delivery_method: delivery?.methodCode ?? null,
    p_zone_id: delivery?.zoneId ?? null,
  });
  if (error)
    throw new Error("We couldn't check that coupon. Please try again.");
  return parseCouponPreview(data);
}

export const couponPreviewQuery = (
  lines: readonly CouponLine[],
  code: string | null,
  delivery: CouponDelivery | null,
) =>
  queryOptions({
    queryKey: [
      "coupon",
      "preview",
      normalizeCouponCode(code),
      delivery ? [delivery.methodCode, delivery.zoneId] : null,
      lines.map((line) => [line.productId, line.variantId, line.quantity]),
    ],
    enabled: lines.length > 0,
    // A preview goes stale as limits and prices move; checkout re-asks rather than trusting a cache.
    staleTime: 0,
    queryFn: () => validateCoupon(lines, code, delivery),
  });
