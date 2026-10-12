import type { CreateOrderArgs, PaymentMethod } from "@/lib/supabase/types";

/**
 * What the browser is allowed to say when placing an order. There is deliberately no
 * subtotal, delivery fee or total-to-charge here: create_order() computes the subtotal from
 * locked product rows and takes the fee from validate_delivery_selection(). The only money
 * value the client sends is `expectedTotalCents`, which can veto an order but never set an
 * amount.
 */
export interface PlaceOrderInput {
  items: { productId: string; variantId: string | null; quantity: number }[];
  deliveryMethod: string;
  paymentMethod: PaymentMethod;
  addressId: string | null;
  /**
   * The delivery zone the customer chose. The database requires it for methods that need an
   * address and validates it whenever it is given. null for methods without an address.
   * There is no address -> zone mapping: the customer picks the zone explicitly.
   */
  zoneId: string | null;
  slotDate: string | null;
  slotStart: string | null;
  slotEnd: string | null;
  slotLabel: string | null;
  notes: string | null;
  /** Stable for the lifetime of one checkout attempt; replays return the same order. */
  idempotencyKey: string;
  /** Total shown to the customer. The DB refuses the order if its own total differs. */
  expectedTotalCents: number | null;
  /**
   * Optional coupon CODE (Phase 8). Never an amount: the database finds the promotion, checks it
   * and computes the discount itself. Omitted or null = no code (an automatic promotion may still apply).
   */
  couponCode?: string | null;
}

/** Maps checkout input to the create_order() arguments. Pure, so it can be unit tested. */
export function buildCreateOrderArgs(input: PlaceOrderInput): CreateOrderArgs {
  return {
    p_items: input.items.map((item) => ({
      product_id: item.productId,
      variant_id: item.variantId,
      quantity: item.quantity,
    })),
    p_delivery_method: input.deliveryMethod,
    p_payment_method: input.paymentMethod,
    p_address_id: input.addressId,
    p_slot_date: input.slotDate,
    p_slot_start: input.slotStart,
    p_slot_end: input.slotEnd,
    p_slot_label: input.slotLabel,
    p_notes: input.notes,
    p_idempotency_key: input.idempotencyKey,
    p_expected_total_cents: input.expectedTotalCents,
    p_zone_id: input.zoneId,
    p_coupon_code: input.couponCode ?? null,
  };
}
