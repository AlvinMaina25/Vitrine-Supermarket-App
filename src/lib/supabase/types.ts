/**
 * Database types matching db/migrations/*.sql.
 *
 * Hand-maintained in the shape produced by `supabase gen types typescript`,
 * so they can be swapped for generated output from the connected project.
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type ProfileRow = {
  id: string;
  full_name: string | null;
  phone: string | null;
  email: string | null;
  avatar_url: string | null;
  /** 'active' | 'suspended'. Set only by admin_set_customer_status(); create_order() refuses 'suspended'. */
  status: "active" | "suspended";
  created_at: string;
  updated_at: string;
};

export type CategoryRow = {
  id: string;
  slug: string;
  name: string;
  tagline: string | null;
  description: string | null;
  image_url: string | null;
  parent_id: string | null;
  position: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type ProductRow = {
  id: string;
  slug: string;
  name: string;
  category_id: string | null;
  description: string | null;
  brand: string | null;
  sku: string | null;
  image_url: string | null;
  price_cents: number;
  compare_at_price_cents: number | null;
  unit_label: string | null;
  stock_quantity: number;
  /** Phase 9B. Per-product low-stock level 0-1000; null = use the reader's default (10). */
  low_stock_threshold: number | null;
  in_stock: boolean;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type ProductVariantRow = {
  id: string;
  product_id: string;
  name: string;
  sku: string | null;
  price_cents: number;
  compare_at_price_cents: number | null;
  stock_quantity: number;
  /** Phase 9B. Per-variant low-stock level 0-1000; null = use the reader's default (10). */
  low_stock_threshold: number | null;
  attributes: Json;
  position: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type AddressRow = {
  id: string;
  user_id: string;
  label: string | null;
  full_name: string;
  phone: string;
  address_line_1: string;
  address_line_2: string | null;
  city: string;
  county: string;
  postal_code: string | null;
  delivery_instructions: string | null;
  latitude: number | null;
  longitude: number | null;
  is_default: boolean;
  created_at: string;
  updated_at: string;
};

// ---------------------------------------------------------------------------
// Orders, delivery and roles
// ---------------------------------------------------------------------------

export type OrderStatus =
  | "pending"
  | "awaiting_payment"
  | "paid"
  | "processing"
  | "picking"
  | "packed"
  | "dispatched"
  | "out_for_delivery"
  | "delivered"
  | "cancelled"
  | "refunded";

export type PaymentStatus =
  | "pending"
  | "processing"
  | "paid"
  | "failed"
  | "cancelled"
  | "refunded"
  | "partially_refunded";

export type PaymentMethod = "mpesa" | "card" | "cash_on_delivery";

/** Status of ONE payment attempt (payment_transactions); separate from orders.status / payment_status. */
export type PaymentTransactionStatus =
  "pending" | "processing" | "succeeded" | "failed" | "cancelled" | "expired";

export type PaymentTransactionRow = {
  id: string;
  order_id: string;
  provider: string;
  method: PaymentMethod;
  amount_cents: number;
  currency: string;
  status: PaymentTransactionStatus;
  provider_reference: string | null;
  idempotency_key: string;
  failure_code: string | null;
  failure_message: string | null;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
};

export type AppRole = "customer" | "staff" | "admin";

/** Snapshot of the address as it was when the order was placed. */
export type DeliveryAddressSnapshot = {
  full_name: string;
  phone: string;
  label: string | null;
  address_line_1: string;
  address_line_2: string | null;
  city: string;
  county: string;
  postal_code: string | null;
  delivery_instructions: string | null;
};

export type DeliveryMethodRow = {
  code: string;
  label: string;
  description: string | null;
  base_fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  requires_slot: boolean;
  requires_address: boolean;
  eta_label: string | null;
  position: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type DeliverySlotTemplateRow = {
  id: string;
  label: string;
  start_time: string;
  end_time: string;
  day_of_week: number | null;
  capacity: number | null;
  position: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

export type DeliveryZoneRow = {
  id: string;
  /** Stable key, also snapshotted onto orders. Insert-only. */
  code: string;
  name: string;
  description: string | null;
  county: string | null;
  towns: string[];
  position: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

/**
 * A complete fee rule for one zone and one method. It replaces the method's base
 * fee and free-over threshold (null = never waived) and can only raise its minimum.
 */
export type DeliveryZoneFeeRow = {
  id: string;
  zone_id: string;
  method_code: string;
  fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

/** Capacity change (null = inherit) or closure of one slot window on one date. */
export type DeliverySlotOverrideRow = {
  id: string;
  template_id: string;
  /** ISO calendar date, e.g. "2026-10-10". */
  slot_date: string;
  capacity: number | null;
  is_active: boolean;
  note: string | null;
  created_at: string;
  updated_at: string;
};

export type DeliveryFeeSource = "method" | "zone";

/** The fee rule that produced an order's delivery_fee_cents, kept on the order. */
export type DeliveryFeeRule = {
  source: DeliveryFeeSource;
  base_fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  zone_fee_id: string | null;
};

/** Row shape returned by public.resolve_delivery_fee(). Zero rows = not available. */
export type DeliveryFeeResolutionRow = {
  fee_cents: number;
  base_fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  fee_source: DeliveryFeeSource;
  zone_fee_id: string | null;
};

/** Why public.validate_delivery_selection() rejected a selection. */
export type DeliverySelectionErrorCode =
  | "invalid_subtotal"
  | "method_required"
  | "method_unknown"
  | "method_inactive"
  | "zone_required"
  | "zone_unknown"
  | "zone_inactive"
  | "unavailable"
  | "below_minimum_order";

/**
 * Row shape returned by public.validate_delivery_selection(). Always exactly one row.
 * When is_valid is false only error_code / error_message (and, for below_minimum_order,
 * min_order_cents) are meaningful; the fee fields are null.
 */
export type DeliverySelectionValidationRow = {
  is_valid: boolean;
  error_code: DeliverySelectionErrorCode | null;
  error_message: string | null;
  method_code: string | null;
  method_label: string | null;
  requires_slot: boolean | null;
  requires_address: boolean | null;
  zone_id: string | null;
  zone_code: string | null;
  zone_name: string | null;
  subtotal_cents: number;
  fee_cents: number | null;
  base_fee_cents: number | null;
  free_over_cents: number | null;
  min_order_cents: number | null;
  fee_source: DeliveryFeeSource | null;
  zone_fee_id: string | null;
  fee_rule: DeliveryFeeRule | null;
};

/**
 * Row shape returned by public.get_delivery_slot_availability().
 * capacity null = unlimited; remaining is null when capacity is null.
 */
export type DeliverySlotAvailabilityRow = {
  slot_date: string;
  template_id: string;
  label: string;
  start_time: string;
  end_time: string;
  capacity: number | null;
  booked_count: number;
  remaining: number | null;
  is_available: boolean;
};

/** Why public.validate_delivery_slot() rejected a slot. */
export type DeliverySlotErrorCode =
  | "slot_required"
  | "invalid_window"
  | "slot_in_past"
  | "slot_too_far"
  | "slot_unknown"
  | "slot_inactive"
  | "slot_closed"
  | "slot_full";

/**
 * Row shape returned by public.validate_delivery_slot(). Always exactly one row.
 * capacity null = unlimited (is_unlimited true); remaining is null when unlimited. Usage
 * fields are null when the slot template could not be found.
 */
export type DeliverySlotValidationRow = {
  is_valid: boolean;
  error_code: DeliverySlotErrorCode | null;
  error_message: string | null;
  slot_date: string | null;
  slot_start: string | null;
  slot_end: string | null;
  template_id: string | null;
  label: string | null;
  capacity: number | null;
  capacity_source: "template" | "override" | null;
  booked_count: number | null;
  remaining: number | null;
  is_unlimited: boolean | null;
  is_closed: boolean | null;
  is_full: boolean | null;
};

export type OrderRow = {
  id: string;
  user_id: string;
  order_number: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
  payment_method: PaymentMethod;
  currency: string;
  subtotal_cents: number;
  delivery_fee_cents: number;
  discount_cents: number;
  total_cents: number;
  delivery_method: string;
  delivery_address: DeliveryAddressSnapshot | null;
  delivery_address_id: string | null;
  delivery_slot_date: string | null;
  delivery_slot_start: string | null;
  delivery_slot_end: string | null;
  delivery_slot_label: string | null;
  customer_notes: string | null;
  idempotency_key: string | null;
  placed_at: string;
  created_at: string;
  updated_at: string;
};

/**
 * Delivery relationships and snapshots added to orders in PHASE 4A. Kept apart from
 * OrderRow because the order LIST query selects an explicit column list that does not
 * include them; orderQuery() (detail + confirmation) selects them and returns
 * OrderWithDelivery. Select them explicitly when you need them.
 * All are written by create_order() or the service role, never the browser.
 */
export type OrderDeliveryColumns = {
  delivery_zone_id: string | null;
  delivery_zone_code: string | null;
  delivery_zone_name: string | null;
  delivery_method_label: string | null;
  delivery_slot_template_id: string | null;
  delivery_fee_rule: DeliveryFeeRule | null;
};

/**
 * The discount an order received, copied at order time (Phase 8). Immutable: later edits to a
 * promotion never change these. All NULL when no discount applied (and on every older order).
 * The amount itself is OrderRow.discount_cents.
 */
export type OrderDiscountColumns = {
  discount_code: string | null;
  discount_name: string | null;
  discount_type: "percentage" | "fixed" | null;
  /** percentage: basis points. fixed: cents. */
  discount_value: number | null;
  discount_applied_at: string | null;
};

/** An order as the customer detail/confirmation pages read it: the row plus its delivery and discount snapshots. */
export type OrderWithDelivery = OrderRow &
  OrderDeliveryColumns &
  OrderDiscountColumns;

export type OrderItemRow = {
  id: string;
  order_id: string;
  product_id: string | null;
  variant_id: string | null;
  product_name: string;
  product_slug: string | null;
  sku: string | null;
  variant_name: string | null;
  variant_attributes: Json;
  unit_label: string | null;
  image_url: string | null;
  unit_price_cents: number;
  quantity: number;
  line_total_cents: number;
  created_at: string;
};

export type OrderStatusHistoryRow = {
  id: string;
  order_id: string;
  previous_status: OrderStatus | null;
  new_status: OrderStatus;
  payment_status: PaymentStatus | null;
  changed_by: string | null;
  note: string | null;
  created_at: string;
};

export type UserRoleRow = {
  id: string;
  user_id: string;
  role: AppRole;
  created_at: string;
};

/** Row shape returned by the public.validate_cart() function. */
export type CartValidationRow = {
  product_id: string;
  variant_id: string | null;
  name: string;
  available: boolean;
  reason:
    | "ok"
    | "unavailable"
    | "variant_unavailable"
    | "out_of_stock"
    | "insufficient_stock";
  unit_price_cents: number;
  stock_quantity: number;
};

// ---------------------------------------------------------------------------
// Admin products (Phase 6C.1A.1, extended in 6C.1A.2). Results of public.admin_list_products() /
// public.admin_get_product(). READ ONLY (the write RPCs of Phase 6C.1B.1 are typed further below).
// Admin only: the database refuses everyone else with SQLSTATE 42501 / DETAIL not_authorised.
// Invalid arguments -> P0001 / DETAIL invalid_arguments; unknown product -> P0001 / product_not_found.
// `products` are public.products rows (inactive ones included), ordered by name, slug, id.
// `total` counts ALL products matching the filters (not just this page).
// ---------------------------------------------------------------------------

export type AdminProductList = {
  total: number;
  limit: number;
  offset: number;
  products: ProductRow[];
};

/** Named arguments of admin_list_products(). limit 1-100 (default 50), offset >= 0 (default 0). */
export type AdminProductListFilters = {
  /** Case-insensitive literal substring over name, slug, sku, brand, category name, variant sku. Max 100 chars. */
  p_search?: string | null;
  /** null = all products, true = active only, false = inactive only. */
  p_is_active?: boolean | null;
  /** Exact category (sub-categories are not included). null = any category. */
  p_category_id?: string | null;
  p_limit?: number;
  p_offset?: number;
};

/** The category block of admin_get_product(); the field itself is null when the product has none. */
export type AdminProductCategory = Pick<
  CategoryRow,
  "id" | "slug" | "name" | "parent_id" | "is_active"
>;

/** Result of public.admin_get_product(). Variants: ordered by position, name, id; inactive included. */
export type AdminProductDetail = {
  product: ProductRow;
  category: AdminProductCategory | null;
  variants: ProductVariantRow[];
};

// ---------------------------------------------------------------------------
// Admin inventory reads (Phase 6C.2.1). Results of public.admin_list_inventory() /
// public.admin_get_inventory(). READ ONLY: stock is adjusted by admin_adjust_inventory() (Phase 6C.2.2A.2, below).
// Admin only: the database refuses everyone else with SQLSTATE 42501 / DETAIL not_authorised.
// Invalid arguments -> P0001 / invalid_arguments; unknown product -> P0001 / product_not_found;
// unknown variant (or one of another product) -> P0001 / variant_not_found.
// Stock lives on two independent levels in the schema, so there are two kinds of unit: a
// "product" unit (products.stock_quantity / in_stock, used by order lines without a variant) and
// a "variant" unit (product_variants.stock_quantity). No inventory table and no low-stock
// threshold column exist, so none is exposed.
// ---------------------------------------------------------------------------

/** One stock-bearing unit. Same shape in the list and in the detail (all 14 keys always present). */
export type AdminInventoryRow = {
  kind: "product" | "variant";
  product_id: string;
  /** null for a product unit. */
  variant_id: string | null;
  /** The unit's own sku (products.sku or product_variants.sku); may be null. */
  sku: string | null;
  product_name: string;
  product_slug: string;
  /** null for a product unit. */
  variant_name: string | null;
  /** The unit's own price (products.price_cents or product_variants.price_cents). */
  price_cents: number;
  stock_quantity: number;
  /** products.in_stock for a product unit; null for a variant unit (the table has no such column). */
  in_stock: boolean | null;
  /** The unit's own is_active. */
  is_active: boolean;
  /** The parent product's is_active (equals is_active for a product unit). */
  product_is_active: boolean;
  /** Number of variants of the product for a product unit; null for a variant unit. */
  variant_count: number | null;
  updated_at: string;
};

/** Result of public.admin_list_inventory(). `total` counts ALL units matching the filters. */
export type AdminInventoryList = {
  total: number;
  limit: number;
  offset: number;
  inventory: AdminInventoryRow[];
};

/** Named arguments of admin_list_inventory(). limit 1-100 (default 50), offset >= 0 (default 0). */
export type AdminInventoryListFilters = {
  /** Case-insensitive literal substring over name, slug, sku, brand and variant name / sku. Max 100 chars. */
  p_search?: string | null;
  /** null = all units, true / false = units whose OWN is_active equals it. */
  p_is_active?: boolean | null;
  /** null = all products, otherwise only that product's units (product unit + variants). */
  p_product_id?: string | null;
  p_limit?: number;
  p_offset?: number;
};

/** Named arguments of admin_get_inventory(). Omit / null p_variant_id for the product's own unit. */
export type AdminInventoryDetailArgs = {
  p_product_id: string;
  p_variant_id?: string | null;
};

/** The product block of admin_get_inventory(). */
export type AdminInventoryProduct = {
  id: string;
  slug: string;
  name: string;
  brand: string | null;
  unit_label: string | null;
  category_id: string | null;
  is_active: boolean;
};

/** Result of public.admin_get_inventory(). */
export type AdminInventoryDetail = {
  inventory: AdminInventoryRow;
  product: AdminInventoryProduct;
};

// ---------------------------------------------------------------------------
// Admin stock adjustment (Phase 6C.2.2A.2). Arguments / result of
// public.admin_adjust_inventory(). DELTA based: the caller says how much to add (+) or remove (-);
// the database computes the new quantity from the locked current stock, so there is no way to
// send a final quantity. Omit / null p_variant_id to adjust the product's own stock; pass it to
// adjust that variant's stock (the parent product is then not touched).
// Admin only: everyone else gets SQLSTATE 42501 / DETAIL not_authorised.
// Errors (SQLSTATE P0001, in DETAIL): invalid_arguments, zero_adjustment_not_allowed,
// product_not_found, variant_not_found, variant_product_mismatch,
// negative_stock_not_allowed, stock_overflow, actor_unavailable.
// ---------------------------------------------------------------------------

/** Named arguments of admin_adjust_inventory(). */
export type AdminAdjustInventoryArgs = {
  p_product_id: string;
  /** Signed, non-zero whole number: +10 adds 10, -3 removes 3. */
  p_adjustment_quantity: number;
  /** Required, trimmed, 1-120 characters. */
  p_reason: string;
  p_variant_id?: string | null;
  /** Optional, trimmed, 1-500 characters when given (a blank note is refused). */
  p_note?: string | null;
};

/** Result of public.admin_adjust_inventory(). */
export type AdminAdjustInventoryResult = {
  adjustment_id: string;
  product_id: string;
  variant_id: string | null;
  kind: "product" | "variant";
  previous_quantity: number;
  adjustment_quantity: number;
  new_quantity: number;
  reason: string;
  note: string | null;
  created_at: string;
};

// ---------------------------------------------------------------------------
// Admin inventory adjustment HISTORY (Phase 6C.2.2B.1). Result of
// public.admin_list_inventory_adjustments(): the only read path to inventory_adjustments.
// Admin only (SQLSTATE 42501 / DETAIL not_authorised for everyone else). Fixed order: created_at
// desc, id desc. Every filter is optional (null = no filter) and filters are ANDed; p_from is
// inclusive and p_to exclusive. Invalid arguments -> P0001 / invalid_arguments.
// ---------------------------------------------------------------------------

/**
 * Why a ledger row exists (Phase 9B column, returned by the history reader since Phase 9C).
 *   admin_adjustment   an admin used the adjustment form
 *   order_restock      stock returned by cancelling an order (order_id set)
 *   order_reactivation stock taken again by reactivating an order (order_id set)
 *   stock_change       any other change: order placement or a direct change (order_id NULL)
 */
export type InventoryMovementKind =
  "admin_adjustment" | "order_restock" | "order_reactivation" | "stock_change";

/** One recorded adjustment. variant_* are null for a product-level adjustment. */
export type AdminInventoryAdjustmentRow = {
  id: string;
  product_id: string;
  variant_id: string | null;
  previous_quantity: number;
  /** Signed delta as stored: positive added stock, negative removed it. */
  adjustment_quantity: number;
  new_quantity: number;
  reason: string;
  note: string | null;
  /**
   * The acting user's id. Phase 9C: returned only for admin adjustments and for actors holding a
   * staff / admin role; null otherwise (never a customer id) and when the account was deleted.
   */
  changed_by: string | null;
  created_at: string;
  /**
   * Phase 9C. Null when the database has not applied 9C yet (older response): the UI then shows no
   * movement label rather than guessing one.
   */
  movement_kind: string | null;
  /** Phase 9C. The order behind an order_restock / order_reactivation row; null for every other kind. */
  order_id: string | null;
  product_name: string;
  product_sku: string | null;
  variant_name: string | null;
  variant_sku: string | null;
};

/** Result of public.admin_list_inventory_adjustments(). `total` counts ALL matching rows. */
export type AdminInventoryAdjustmentList = {
  total: number;
  limit: number;
  offset: number;
  adjustments: AdminInventoryAdjustmentRow[];
};

/** Named arguments of admin_list_inventory_adjustments(). limit 1-100 (default 50), offset >= 0. */
export type AdminInventoryAdjustmentListFilters = {
  p_limit?: number;
  p_offset?: number;
  p_product_id?: string | null;
  p_variant_id?: string | null;
  /** Exact, case-sensitive, trimmed match; 1-120 characters. */
  p_reason?: string | null;
  p_changed_by?: string | null;
  p_from?: string | null;
  p_to?: string | null;
};

// ---------------------------------------------------------------------------
// Admin product writes (Phase 6C.1B.1). Results/arguments of public.admin_create_product() and
// public.admin_update_product(). Admin only: the database refuses everyone else with
// SQLSTATE 42501 / DETAIL not_authorised. The browser has no direct INSERT/UPDATE on products.
// Errors: invalid input -> P0001 / invalid_arguments; unknown key in the patch -> P0001 /
// unsupported_field; unknown category -> P0001 / category_not_found; unknown product -> P0001 /
// product_not_found; duplicate slug / SKU -> 23505 / slug_taken | sku_taken.
// NOT writable here (later phases): stock_quantity, in_stock, is_active (inventory / activation)
// and image_url (images). A new product gets the table defaults for those.
// ---------------------------------------------------------------------------

/** Result of admin_create_product() and admin_update_product(): the stored row (all 16 columns). */
export type AdminProductMutationResult = {
  product: ProductRow;
};

/**
 * Named arguments of admin_create_product(). Required: name, slug (lower-case kebab, max 120),
 * price_cents (integer >= 0). Blank optional text is stored as null.
 */
export type AdminCreateProductArgs = {
  p_name: string;
  p_slug: string;
  p_price_cents: number;
  p_category_id?: string | null;
  p_description?: string | null;
  p_brand?: string | null;
  p_sku?: string | null;
  p_unit_label?: string | null;
  /** null, or >= the price. */
  p_compare_at_price_cents?: number | null;
};

// ---------------------------------------------------------------------------
// Admin categories (Phase 20A). Arguments / results of public.admin_create_category() and
// public.admin_update_category(). Admin only (SQLSTATE 42501 / DETAIL not_authorised). Refusals:
// P0001 invalid_arguments / unsupported_field / category_not_found; 23505 slug_taken.
// There is no delete: a category is deactivated with is_active = false.
// ---------------------------------------------------------------------------

export type AdminCreateCategoryArgs = {
  p_name: string;
  p_slug: string;
  p_tagline?: string | null;
  p_description?: string | null;
  p_position?: number;
  p_is_active?: boolean;
};

/** PATCH of admin_update_category(): absent = unchanged; tagline / description may be null. */
export type AdminCategoryChanges = {
  name?: string;
  slug?: string;
  tagline?: string | null;
  description?: string | null;
  position?: number;
  is_active?: boolean;
};

/** Result of both category writers: the stored row (all 11 columns). */
export type AdminCategoryMutationResult = { category: CategoryRow };

/**
 * The patch of admin_update_product(). A key that is absent leaves the column unchanged; a key
 * set to null clears it (nullable columns only: name, slug and price_cents cannot be null).
 * Any other key is rejected with unsupported_field.
 */
export type AdminProductChanges = {
  name?: string;
  slug?: string;
  category_id?: string | null;
  description?: string | null;
  brand?: string | null;
  sku?: string | null;
  price_cents?: number;
  compare_at_price_cents?: number | null;
  unit_label?: string | null;
};

// ---------------------------------------------------------------------------
// Admin product activation + variants (Phase 6C.1B.2). Results/arguments of
// public.admin_set_product_active(), public.admin_create_product_variant() and
// public.admin_update_product_variant(). Admin only: the database refuses everyone else with
// SQLSTATE 42501 / DETAIL not_authorised. The browser has no direct INSERT/UPDATE on products or
// product_variants. Errors: invalid input -> P0001 / invalid_arguments; unknown key in the patch ->
// P0001 / unsupported_field; unknown product -> P0001 / product_not_found; unknown variant ->
// P0001 / variant_not_found; duplicate variant SKU -> 23505 / sku_taken.
// NOT writable here (Phase 6C.2 inventory): stock_quantity. A new variant gets the table defaults
// (stock_quantity 0, is_active true), so it has no stock until the inventory phase exists.
// Passing a stock value to the create RPC is a PostgreSQL "function does not exist" error (42883):
// the argument is deliberately not part of the contract.
// ---------------------------------------------------------------------------

/** Result of admin_set_product_active(): the stored product row (all 16 columns). */
export type AdminSetProductActiveResult = AdminProductMutationResult;

/** Result of admin_create_product_variant() and admin_update_product_variant(): the stored row (all 12 columns). */
export type AdminVariantMutationResult = {
  variant: ProductVariantRow;
};

/**
 * Named arguments of admin_create_product_variant(). Required: product id, name (1-200),
 * price_cents (integer >= 0). Omitted / null attributes and position use the table defaults
 * ({} and 0). There is deliberately NO stock, in_stock or is_active argument.
 */
export type AdminCreateProductVariantArgs = {
  p_product_id: string;
  p_name: string;
  p_price_cents: number;
  /** null / blank = no SKU. Unique among variants. */
  p_sku?: string | null;
  /** null, or >= the price. */
  p_compare_at_price_cents?: number | null;
  /** A JSON object (at most 4000 bytes). */
  p_attributes?: Record<string, Json> | null;
  /** Whole number 0 to 100000. */
  p_position?: number | null;
};

/**
 * The patch of admin_update_product_variant(). A key that is absent leaves the column unchanged;
 * a key set to null clears it (sku and compare_at_price_cents only). `attributes` is replaced as a
 * whole. Any other key (stock_quantity, in_stock, product_id, id, ...) is rejected with
 * unsupported_field.
 */
export type AdminProductVariantChanges = {
  name?: string;
  sku?: string | null;
  price_cents?: number;
  compare_at_price_cents?: number | null;
  attributes?: Record<string, Json>;
  position?: number;
  is_active?: boolean;
};

// ---------------------------------------------------------------------------
// Admin orders (Phase 6B.1). Results of public.admin_list_orders() / admin_get_order().
// Admin only: the database refuses everyone else with SQLSTATE 42501 / DETAIL not_authorised.
// ---------------------------------------------------------------------------

export type AdminOrderCustomer = {
  id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
};

export type AdminOrderListItem = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
  payment_method: PaymentMethod;
  delivery_method: string;
  delivery_method_label: string | null;
  delivery_slot_date: string | null;
  subtotal_cents: number;
  delivery_fee_cents: number;
  discount_cents: number;
  total_cents: number;
  currency: string;
  placed_at: string;
  customer: AdminOrderCustomer;
};

export type AdminOrderList = {
  /** Count of ALL matching orders, not just this page. */
  total: number;
  limit: number;
  offset: number;
  orders: AdminOrderListItem[];
};

export type AdminOrderHistoryEntry = {
  id: string;
  previous_status: OrderStatus | null;
  new_status: OrderStatus;
  payment_status: PaymentStatus | null;
  changed_by: string | null;
  changed_by_name: string | null;
  note: string | null;
  created_at: string;
};

export type AdminOrderDetail = {
  order: OrderWithDelivery & { restocked_at: string | null };
  customer: (AdminOrderCustomer & { created_at: string | null }) | null;
  delivery: {
    method: string;
    method_label: string | null;
    zone_id: string | null;
    zone_code: string | null;
    zone_name: string | null;
    slot_date: string | null;
    slot_start: string | null;
    slot_end: string | null;
    slot_label: string | null;
    slot_template_id: string | null;
    fee_cents: number;
    fee_rule: DeliveryFeeRule | null;
    /** Snapshot taken when the order was placed. */
    address: DeliveryAddressSnapshot | null;
    address_id: string | null;
    customer_notes: string | null;
  };
  /** What orders already records. No transaction/provider data exists in the schema. */
  payment: {
    method: PaymentMethod;
    status: PaymentStatus;
    currency: string;
    subtotal_cents: number;
    delivery_fee_cents: number;
    discount_cents: number;
    total_cents: number;
  };
  items: OrderItemRow[];
  history: AdminOrderHistoryEntry[];
};

export type AdminOrderListFilters = {
  search?: string | null;
  status?: OrderStatus | null;
  paymentStatus?: PaymentStatus | null;
  paymentMethod?: PaymentMethod | null;
  /** Inclusive Africa/Nairobi calendar days, YYYY-MM-DD. */
  placedFrom?: string | null;
  placedTo?: string | null;
  /** 1-100, default 25. */
  limit?: number;
  /** >= 0, default 0. */
  offset?: number;
};

/**
 * Result of public.admin_set_order_status() (Phase 6B.2). Admin only; the database refuses
 * everyone else with SQLSTATE 42501 / DETAIL not_authorised.
 *
 * `changed` is false when the order already had the requested status (nothing was written and
 * `history_entry` is null). Customer contact data, address, notes and items are NOT returned:
 * refetch the order with admin_get_order() for those.
 */
export type AdminOrderHistoryRow = {
  id: string;
  previous_status: OrderStatus | null;
  new_status: OrderStatus;
  payment_status: PaymentStatus | null;
  changed_by: string | null;
  note: string | null;
  created_at: string;
};

export type AdminSetOrderStatusResult = {
  changed: boolean;
  previous_status: OrderStatus;
  order: {
    id: string;
    order_number: string;
    status: OrderStatus;
    payment_status: PaymentStatus;
    payment_method: PaymentMethod;
    delivery_method: string;
    delivery_slot_date: string | null;
    total_cents: number;
    currency: string;
    placed_at: string;
    updated_at: string;
    /** Set when the order's stock was returned to inventory (a cancellation); null otherwise. */
    restocked_at: string | null;
  };
  history_entry: AdminOrderHistoryRow | null;
};

export type AdminSetOrderStatusInput = {
  orderId: string;
  status: OrderStatus;
  /**
   * Optional history note, at most 400 characters. Required (3+) for an override. May not start
   * with "Admin override:" (reserved; the database adds it to overrides itself).
   */
  note?: string | null;
  /**
   * Explicitly confirm a manual administrative override (a move that is not a standard
   * transition). Without it the database refuses such a move. Defaults to false.
   */
  override?: boolean;
};

/**
 * Result of public.admin_dashboard_summary() (Phase 6A). Admin only; the database refuses
 * everyone else with SQLSTATE 42501 / DETAIL not_authorised.
 *
 * Every figure is read from tables that already exist. It is NOT revenue: `gross_value_cents`
 * sums `total_cents` of orders that are not cancelled/refunded, including unpaid and
 * cash-on-delivery orders. The schema records no payment transactions, so none are reported.
 * Count maps list EVERY enum value (zero when none).
 */
export type AdminLowStockItem = {
  kind: "product" | "variant";
  product_id: string;
  variant_id: string | null;
  name: string;
  variant_name: string | null;
  sku: string | null;
  stock_quantity: number;
  state: "out_of_stock" | "low_stock";
};

/** Display fields only: no email, phone, address, notes or user id. */
export type AdminRecentOrder = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
  payment_method: PaymentMethod;
  delivery_method: string;
  total_cents: number;
  currency: string;
  placed_at: string;
  customer_name: string | null;
};

export type AdminDashboardSummary = {
  generated_at: string;
  /** The store clock used for "today" (Africa/Nairobi). */
  time_zone: string;
  /** The caller-supplied cut-off for "low stock". There is no stored reorder level. */
  low_stock_threshold: number;
  orders: {
    total: number;
    placed_today: number;
    gross_value_cents: number;
    by_status: Record<OrderStatus, number>;
  };
  payments: {
    by_status: Record<PaymentStatus, number>;
    by_method: Record<PaymentMethod, number>;
  };
  delivery: {
    scheduled_today: number;
    scheduled_upcoming: number;
    by_method: {
      code: string;
      label: string;
      is_active: boolean;
      orders: number;
    }[];
    configuration: {
      active_methods: number;
      active_zones: number;
      active_slot_templates: number;
    };
  };
  products: {
    total: number;
    active: number;
    inactive: number;
    out_of_stock: number;
    low_stock: number;
  };
  variants: {
    total: number;
    active: number;
    out_of_stock: number;
    low_stock: number;
  };
  low_stock_items: AdminLowStockItem[];
  customers: { total: number; new_last_30_days: number };
  recent_orders: AdminRecentOrder[];
};

/** Arguments accepted by public.create_order(). Prices are never sent. */
export type CreateOrderArgs = {
  p_items: {
    product_id: string;
    variant_id: string | null;
    quantity: number;
  }[];
  p_delivery_method: string;
  p_payment_method: PaymentMethod;
  p_address_id: string | null;
  p_slot_date: string | null;
  p_slot_start: string | null;
  p_slot_end: string | null;
  p_slot_label: string | null;
  p_notes: string | null;
  p_idempotency_key: string;
  /**
   * The total the customer was shown. The database recomputes the real total
   * and refuses the order when the two differ; this never sets an amount.
   */
  p_expected_total_cents: number | null;
  /**
   * Delivery zone. Required by the database when the method needs an address; validated
   * whenever given. Never carries a fee: the fee is resolved server-side from the zone.
   */
  p_zone_id: string | null;
  /**
   * Phase 8: optional coupon CODE. Never an amount; the database computes the discount.
   * Optional so a caller that does not know about coupons still type-checks (SQL default NULL).
   */
  p_coupon_code?: string | null;
};

type Generated = "id" | "created_at" | "updated_at";

// Insert/Update shapes mirror the column-level grants in
// 20260930030000_delivery_system_foundation.sql: keys and timestamps are not writable.
export type DeliveryMethodInsert = Pick<DeliveryMethodRow, "code" | "label"> &
  Partial<Omit<DeliveryMethodRow, Generated>>;
export type DeliveryMethodUpdate = Partial<
  Omit<DeliveryMethodRow, Generated | "code">
>;

export type DeliveryZoneInsert = Pick<DeliveryZoneRow, "code" | "name"> &
  Partial<Omit<DeliveryZoneRow, Generated>>;
export type DeliveryZoneUpdate = Partial<
  Omit<DeliveryZoneRow, Generated | "code">
>;

export type DeliveryZoneFeeInsert = Pick<
  DeliveryZoneFeeRow,
  "zone_id" | "method_code" | "fee_cents"
> &
  Partial<Omit<DeliveryZoneFeeRow, Generated>>;
export type DeliveryZoneFeeUpdate = Partial<
  Omit<DeliveryZoneFeeRow, Generated | "zone_id" | "method_code">
>;

export type DeliverySlotTemplateInsert = Pick<
  DeliverySlotTemplateRow,
  "label" | "start_time" | "end_time"
> &
  Partial<Omit<DeliverySlotTemplateRow, Generated>>;
export type DeliverySlotTemplateUpdate = Partial<
  Omit<DeliverySlotTemplateRow, Generated>
>;

export type DeliverySlotOverrideInsert = Pick<
  DeliverySlotOverrideRow,
  "template_id" | "slot_date"
> &
  Partial<Omit<DeliverySlotOverrideRow, Generated>>;
export type DeliverySlotOverrideUpdate = Partial<
  Omit<DeliverySlotOverrideRow, Generated | "template_id" | "slot_date">
>;

export type ProfileUpdate = Partial<
  Pick<ProfileRow, "full_name" | "phone" | "avatar_url">
>;

/** user_id is omitted: the database defaults it to auth.uid() and RLS enforces it. */
export type AddressInsert = Omit<
  AddressRow,
  Generated | "user_id" | "latitude" | "longitude" | "is_default"
> &
  Partial<Pick<AddressRow, "latitude" | "longitude" | "is_default">>;
export type AddressUpdate = Partial<AddressInsert>;

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: ProfileRow;
        // status is not insertable (INSERT revoked in 6E.3); it defaults to 'active'.
        Insert: Pick<ProfileRow, "id"> &
          Partial<Omit<ProfileRow, "id" | "status">>;
        Update: ProfileUpdate;
        Relationships: [];
      };
      categories: {
        Row: CategoryRow;
        Insert: Pick<CategoryRow, "slug" | "name"> & Partial<CategoryRow>;
        Update: Partial<CategoryRow>;
        Relationships: [
          {
            foreignKeyName: "categories_parent_id_fkey";
            columns: ["parent_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["id"];
          },
        ];
      };
      products: {
        Row: ProductRow;
        Insert: Pick<ProductRow, "slug" | "name"> & Partial<ProductRow>;
        Update: Partial<ProductRow>;
        Relationships: [
          {
            foreignKeyName: "products_category_id_fkey";
            columns: ["category_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["id"];
          },
        ];
      };
      product_variants: {
        Row: ProductVariantRow;
        Insert: Pick<ProductVariantRow, "product_id" | "name" | "price_cents"> &
          Partial<ProductVariantRow>;
        Update: Partial<ProductVariantRow>;
        Relationships: [
          {
            foreignKeyName: "product_variants_product_id_fkey";
            columns: ["product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["id"];
          },
        ];
      };
      addresses: {
        Row: AddressRow;
        Insert: AddressInsert;
        Update: AddressUpdate;
        Relationships: [];
      };
      delivery_methods: {
        Row: DeliveryMethodRow;
        Insert: DeliveryMethodInsert;
        Update: DeliveryMethodUpdate;
        Relationships: [];
      };
      delivery_slot_templates: {
        Row: DeliverySlotTemplateRow;
        Insert: DeliverySlotTemplateInsert;
        Update: DeliverySlotTemplateUpdate;
        Relationships: [];
      };
      delivery_zones: {
        Row: DeliveryZoneRow;
        Insert: DeliveryZoneInsert;
        Update: DeliveryZoneUpdate;
        Relationships: [];
      };
      delivery_zone_fees: {
        Row: DeliveryZoneFeeRow;
        Insert: DeliveryZoneFeeInsert;
        Update: DeliveryZoneFeeUpdate;
        Relationships: [
          {
            foreignKeyName: "delivery_zone_fees_zone_id_fkey";
            columns: ["zone_id"];
            isOneToOne: false;
            referencedRelation: "delivery_zones";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "delivery_zone_fees_method_code_fkey";
            columns: ["method_code"];
            isOneToOne: false;
            referencedRelation: "delivery_methods";
            referencedColumns: ["code"];
          },
        ];
      };
      delivery_slot_overrides: {
        Row: DeliverySlotOverrideRow;
        Insert: DeliverySlotOverrideInsert;
        Update: DeliverySlotOverrideUpdate;
        Relationships: [
          {
            foreignKeyName: "delivery_slot_overrides_template_id_fkey";
            columns: ["template_id"];
            isOneToOne: false;
            referencedRelation: "delivery_slot_templates";
            referencedColumns: ["id"];
          },
        ];
      };
      /** Insert-only through public.create_order(); customers have no write policy. */
      orders: {
        Row: OrderRow & OrderDeliveryColumns;
        Insert: never;
        Update: Partial<Pick<OrderRow, "status">>;
        Relationships: [];
      };
      order_items: {
        Row: OrderItemRow;
        Insert: never;
        Update: never;
        Relationships: [
          {
            foreignKeyName: "order_items_order_id_fkey";
            columns: ["order_id"];
            isOneToOne: false;
            referencedRelation: "orders";
            referencedColumns: ["id"];
          },
        ];
      };
      order_status_history: {
        Row: OrderStatusHistoryRow;
        Insert: never;
        Update: never;
        Relationships: [
          {
            foreignKeyName: "order_status_history_order_id_fkey";
            columns: ["order_id"];
            isOneToOne: false;
            referencedRelation: "orders";
            referencedColumns: ["id"];
          },
        ];
      };
      user_roles: {
        Row: UserRoleRow;
        Insert: Pick<UserRoleRow, "user_id" | "role">;
        Update: never;
        Relationships: [];
      };
      /** Server (service_role) reads only: browser roles have no SELECT (6G.4-B). Written by DB functions. */
      payment_transactions: {
        Row: PaymentTransactionRow;
        Insert: never;
        Update: never;
        Relationships: [];
      };
    };
    Views: { [_ in never]: never };
    Functions: {
      create_order: {
        Args: CreateOrderArgs;
        Returns: string;
      };
      validate_cart: {
        Args: {
          p_items: {
            product_id: string;
            variant_id: string | null;
            quantity: number;
          }[];
        };
        Returns: CartValidationRow[];
      };
      resolve_delivery_fee: {
        Args: {
          p_method_code: string;
          p_zone_id?: string | null;
          p_subtotal_cents?: number;
        };
        Returns: DeliveryFeeResolutionRow[];
      };
      validate_delivery_selection: {
        Args: {
          p_method_code: string;
          p_zone_id?: string | null;
          p_subtotal_cents?: number;
        };
        Returns: DeliverySelectionValidationRow[];
      };
      get_delivery_slot_availability: {
        Args: { p_from: string; p_to: string };
        Returns: DeliverySlotAvailabilityRow[];
      };
      validate_delivery_slot: {
        Args: { p_slot_date: string; p_slot_start: string; p_slot_end: string };
        Returns: DeliverySlotValidationRow[];
      };
      has_role: {
        Args: { _user_id: string; _role: AppRole };
        Returns: boolean;
      };
      is_staff: {
        Args: { _user_id: string };
        Returns: boolean;
      };
      is_admin: {
        Args: { _user_id: string };
        Returns: boolean;
      };
      admin_dashboard_summary: {
        Args: {
          p_recent_orders_limit?: number;
          p_low_stock_threshold?: number;
        };
        Returns: AdminDashboardSummary;
      };
      admin_list_orders: {
        Args: {
          p_search?: string | null;
          p_status?: OrderStatus | null;
          p_payment_status?: PaymentStatus | null;
          p_payment_method?: PaymentMethod | null;
          p_placed_from?: string | null;
          p_placed_to?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: AdminOrderList;
      };
      admin_get_order: {
        Args: { p_order_id: string };
        Returns: AdminOrderDetail;
      };
      admin_list_products: {
        Args: {
          p_limit?: number;
          p_offset?: number;
          p_search?: string | null;
          p_is_active?: boolean | null;
          p_category_id?: string | null;
        };
        Returns: AdminProductList;
      };
      admin_get_product: {
        Args: { p_product_id: string };
        Returns: AdminProductDetail;
      };
      admin_create_product: {
        Args: AdminCreateProductArgs;
        Returns: AdminProductMutationResult;
      };
      admin_create_category: {
        Args: AdminCreateCategoryArgs;
        Returns: AdminCategoryMutationResult;
      };
      admin_update_category: {
        Args: { p_category_id: string; p_changes: AdminCategoryChanges };
        Returns: AdminCategoryMutationResult;
      };
      admin_set_product_image: {
        Args: { p_product_id: string; p_image_url: string | null };
        Returns: AdminProductMutationResult;
      };
      admin_set_category_image: {
        Args: { p_category_id: string; p_image_url: string | null };
        Returns: AdminCategoryMutationResult;
      };
      admin_update_product: {
        Args: { p_product_id: string; p_changes: AdminProductChanges };
        Returns: AdminProductMutationResult;
      };
      admin_set_product_active: {
        Args: { p_product_id: string; p_is_active: boolean };
        Returns: AdminSetProductActiveResult;
      };
      admin_create_product_variant: {
        Args: AdminCreateProductVariantArgs;
        Returns: AdminVariantMutationResult;
      };
      admin_update_product_variant: {
        Args: { p_variant_id: string; p_changes: AdminProductVariantChanges };
        Returns: AdminVariantMutationResult;
      };
      admin_list_inventory: {
        Args: AdminInventoryListFilters;
        Returns: AdminInventoryList;
      };
      admin_get_inventory: {
        Args: AdminInventoryDetailArgs;
        Returns: AdminInventoryDetail;
      };
      admin_adjust_inventory: {
        Args: AdminAdjustInventoryArgs;
        Returns: AdminAdjustInventoryResult;
      };
      admin_list_inventory_adjustments: {
        Args: AdminInventoryAdjustmentListFilters;
        Returns: AdminInventoryAdjustmentList;
      };
      admin_list_customers: {
        Args: {
          p_search?: string | null;
          p_page?: number;
          p_page_size?: number;
          p_status?: "active" | "suspended" | null;
        };
        Returns: unknown;
      };
      admin_list_payment_transactions: {
        Args: {
          p_order_id?: string | null;
          p_status?: PaymentTransactionStatus | null;
          p_provider?: string | null;
          p_from?: string | null;
          p_to?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: unknown;
      };
      admin_list_audit_log: {
        Args: {
          p_actor?: string | null;
          p_action?: string | null;
          p_target_id?: string | null;
          p_from?: string | null;
          p_to?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: unknown;
      };
      admin_get_payment_transaction: {
        Args: { p_transaction_id: string };
        Returns: unknown;
      };
      get_my_order_payments: {
        Args: { p_order_id: string };
        Returns: unknown;
      };
      get_order_for_payment: {
        Args: { p_order_id: string };
        Returns: unknown;
      };
      create_payment_attempt: {
        Args: {
          p_order_id: string;
          p_provider: string;
          p_method: PaymentMethod;
          p_idempotency_key: string;
        };
        Returns: unknown;
      };
      mark_payment_processing: {
        Args: { p_transaction_id: string; p_provider_reference: string };
        Returns: unknown;
      };
      apply_payment_outcome: {
        Args: {
          p_transaction_id: string;
          p_outcome: PaymentTransactionStatus;
          p_provider_reference?: string | null;
          p_amount_cents?: number | null;
          p_currency?: string | null;
          p_failure_code?: string | null;
          p_failure_message?: string | null;
        };
        Returns: unknown;
      };
      record_cod_payment: {
        Args: { p_order_id: string; p_reason: string };
        Returns: unknown;
      };
      validate_coupon: {
        Args: {
          p_items: {
            product_id: string;
            variant_id: string | null;
            quantity: number;
          }[];
          p_code?: string | null;
          p_delivery_method?: string | null;
          p_zone_id?: string | null;
        };
        Returns: unknown;
      };
      admin_create_promotion: {
        Args: { p_input: Record<string, unknown> };
        Returns: unknown;
      };
      admin_update_promotion: {
        Args: { p_promotion_id: string; p_changes: Record<string, unknown> };
        Returns: unknown;
      };
      admin_set_promotion_active: {
        Args: { p_promotion_id: string; p_is_active: boolean };
        Returns: unknown;
      };
      admin_list_promotions: {
        Args: { p_limit?: number; p_offset?: number };
        Returns: unknown;
      };
      claim_notifications: {
        Args: { p_limit?: number };
        Returns: unknown;
      };
      complete_notification: {
        Args: { p_id: string; p_outcome: string; p_error?: string | null };
        Returns: unknown;
      };
      admin_list_notifications: {
        Args: { p_status?: string | null; p_limit?: number; p_offset?: number };
        Returns: unknown;
      };
      get_my_notifications: {
        Args: { p_limit?: number };
        Returns: unknown;
      };
      admin_get_customer: {
        Args: { p_customer_id: string };
        Returns: unknown;
      };
      admin_set_customer_status: {
        Args: {
          p_customer_id: string;
          p_status: "active" | "suspended";
          p_reason: string;
        };
        Returns: unknown;
      };
      admin_update_customer_notes: {
        Args: { p_customer_id: string; p_notes: string };
        Returns: unknown;
      };
      // Phase 6F.1A: delivery methods, zones and zone fee rules. Admin-only; money is whole cents.
      admin_list_delivery_config: {
        Args: Record<string, never>;
        Returns: unknown;
      };
      admin_save_delivery_zone: {
        Args: {
          p_zone_id: string | null;
          p_code: string | null;
          p_name: string;
          p_county: string | null;
          p_towns: string[];
          p_description: string | null;
          p_position: number | null;
        };
        Returns: unknown;
      };
      admin_set_delivery_zone_active: {
        Args: { p_zone_id: string; p_is_active: boolean; p_reason: string };
        Returns: unknown;
      };
      admin_save_delivery_zone_fee: {
        Args: {
          p_fee_id: string | null;
          p_zone_id: string | null;
          p_method_code: string | null;
          p_fee_cents: number;
          p_free_over_cents: number | null;
          p_min_order_cents: number | null;
        };
        Returns: unknown;
      };
      admin_set_delivery_zone_fee_active: {
        Args: { p_fee_id: string; p_is_active: boolean; p_reason: string };
        Returns: unknown;
      };
      admin_update_delivery_method: {
        Args: {
          p_code: string;
          p_base_fee_cents: number;
          p_free_over_cents: number | null;
          p_min_order_cents: number;
          p_is_active: boolean;
          p_reason?: string | null;
        };
        Returns: unknown;
      };
      // Phase 6F.1B: delivery slot templates and per-date overrides. Admin-only.
      admin_list_delivery_slots: {
        Args: { p_from: string; p_to: string };
        Returns: unknown;
      };
      admin_save_delivery_slot_template: {
        Args: {
          p_template_id: string | null;
          p_label: string;
          p_start_time: string;
          p_end_time: string;
          p_day_of_week: number | null;
          p_capacity: number | null;
          p_position: number | null;
        };
        Returns: unknown;
      };
      admin_set_delivery_slot_template_active: {
        Args: { p_template_id: string; p_is_active: boolean; p_reason: string };
        Returns: unknown;
      };
      admin_save_delivery_slot_override: {
        Args: {
          p_template_id: string;
          p_slot_date: string;
          p_capacity: number | null;
          p_is_closed: boolean;
          p_note?: string | null;
        };
        Returns: unknown;
      };
      admin_clear_delivery_slot_override: {
        Args: { p_template_id: string; p_slot_date: string; p_reason: string };
        Returns: unknown;
      };
      admin_set_order_status: {
        Args: {
          p_order_id: string;
          p_status: OrderStatus;
          p_note?: string | null;
          p_override?: boolean;
        };
        Returns: AdminSetOrderStatusResult;
      };
    };
    Enums: {
      order_status: OrderStatus;
      payment_status: PaymentStatus;
      payment_method: PaymentMethod;
      payment_transaction_status: PaymentTransactionStatus;
      app_role: AppRole;
    };
    CompositeTypes: { [_ in never]: never };
  };
}
