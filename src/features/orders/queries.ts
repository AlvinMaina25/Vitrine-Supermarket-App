import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  OrderItemRow,
  OrderRow,
  OrderStatusHistoryRow,
  OrderWithDelivery,
} from "@/lib/supabase/types";

import {
  buildCreateOrderArgs,
  type PlaceOrderInput,
} from "./create-order-args";
import { toPlaceOrderError } from "./place-order-error";

/**
 * Order data access.
 *
 * Reads are scoped by RLS to the signed-in customer. The only write path is
 * the create_order() database function, which recalculates every amount from
 * authoritative product and delivery rows — the browser never sends prices.
 */

const ORDER_COLUMNS =
  "id, user_id, order_number, status, payment_status, payment_method, currency, subtotal_cents, delivery_fee_cents, discount_cents, total_cents, delivery_method, delivery_address, delivery_address_id, delivery_slot_date, delivery_slot_start, delivery_slot_end, delivery_slot_label, customer_notes, idempotency_key, placed_at, created_at, updated_at";

/**
 * The delivery snapshot stored on the order by create_order(). Read from the order row itself:
 * historical orders never join live delivery methods/zones/fees/slots to rebuild these.
 * Every one may be NULL on an order placed before Phase 4.
 */
const DELIVERY_SNAPSHOT_COLUMNS =
  "delivery_zone_id, delivery_zone_code, delivery_zone_name, delivery_method_label, delivery_slot_template_id, delivery_fee_rule";

/**
 * The discount snapshot (Phase 8), copied onto the order by create_order() and immutable. Read from
 * the order row only; the promotions table is never joined (customers cannot read it).
 */
const DISCOUNT_SNAPSHOT_COLUMNS =
  "discount_code, discount_name, discount_type, discount_value, discount_applied_at";

/** Detail + confirmation pages: the list columns plus the delivery and discount snapshots. */
const ORDER_DETAIL_COLUMNS = `${ORDER_COLUMNS}, ${DELIVERY_SNAPSHOT_COLUMNS}, ${DISCOUNT_SNAPSHOT_COLUMNS}`;

const ITEM_COLUMNS =
  "id, order_id, product_id, variant_id, product_name, product_slug, sku, variant_name, variant_attributes, unit_label, image_url, unit_price_cents, quantity, line_total_cents, created_at";

const HISTORY_COLUMNS =
  "id, order_id, previous_status, new_status, payment_status, changed_by, note, created_at";

/** The list shows this many most recent orders; pagination is a later step. */
export const ORDER_LIST_LIMIT = 50;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface OrderDetail {
  order: OrderWithDelivery;
  items: OrderItemRow[];
  history: OrderStatusHistoryRow[];
}

async function requireUserId(): Promise<string> {
  const { data, error } = await requireSupabase().auth.getUser();
  if (error || !data.user)
    throw new Error("Your session has expired. Please sign in again.");
  return data.user.id;
}

export const ordersQuery = () =>
  queryOptions({
    queryKey: ["orders", "list"],
    queryFn: async (): Promise<OrderRow[]> => {
      const userId = await requireUserId();
      const { data, error } = await requireSupabase()
        .from("orders")
        .select(ORDER_COLUMNS)
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(ORDER_LIST_LIMIT);
      if (error) throw new Error(error.message);
      return (data ?? []) as OrderRow[];
    },
  });

/**
 * Units per order for the list page, summed client-side from
 * order_items(order_id, quantity). RLS limits the rows to the customer's own.
 */
export const orderItemCountsQuery = (orderIds: string[]) =>
  queryOptions({
    queryKey: ["orders", "item-counts", orderIds],
    enabled: orderIds.length > 0,
    queryFn: async (): Promise<Record<string, number>> => {
      await requireUserId();
      const { data, error } = await requireSupabase()
        .from("order_items")
        .select("order_id, quantity")
        .in("order_id", orderIds);
      if (error) throw new Error(error.message);

      const counts: Record<string, number> = {};
      for (const row of (data ?? []) as Pick<
        OrderItemRow,
        "order_id" | "quantity"
      >[]) {
        counts[row.order_id] = (counts[row.order_id] ?? 0) + row.quantity;
      }
      return counts;
    },
  });

export const orderQuery = (orderId: string) =>
  queryOptions({
    queryKey: ["orders", "detail", orderId],
    queryFn: async (): Promise<OrderDetail | null> => {
      const userId = await requireUserId();
      if (!UUID_PATTERN.test(orderId)) return null;
      const client = requireSupabase();

      const { data: order, error } = await client
        .from("orders")
        .select(ORDER_DETAIL_COLUMNS)
        .eq("id", orderId)
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw new Error(error.message);
      if (!order) return null;

      const [items, history] = await Promise.all([
        client
          .from("order_items")
          .select(ITEM_COLUMNS)
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
        client
          .from("order_status_history")
          .select(HISTORY_COLUMNS)
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
      ]);

      if (items.error) throw new Error(items.error.message);
      if (history.error) throw new Error(history.error.message);

      return {
        order: order as unknown as OrderWithDelivery,
        items: (items.data ?? []) as OrderItemRow[],
        history: (history.data ?? []) as OrderStatusHistoryRow[],
      };
    },
  });

export type { PlaceOrderInput } from "./create-order-args";
export { isPlaceOrderError, PlaceOrderError } from "./place-order-error";

/**
 * The authoritative delivery quote checkout needs before it can place an order. Defined with
 * the other delivery queries; exposed here so checkout takes its order-placement pieces from
 * one module.
 */
export { deliveryQuoteQuery } from "@/features/delivery/queries";

export async function placeOrder(input: PlaceOrderInput): Promise<string> {
  await requireUserId();

  const args = buildCreateOrderArgs(input);

  const { data, error } = await requireSupabase().rpc("create_order", args);
  if (error) throw toPlaceOrderError(error);
  if (!data)
    throw new Error("The order could not be created. Please try again.");
  return data as string;
}
