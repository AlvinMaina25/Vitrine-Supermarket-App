import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import {
  collectAllPages,
  summariseVariants,
  type OptionsSummary,
} from "@/features/catalog/product-detail";
import type {
  CategoryRow,
  ProductRow,
  ProductVariantRow,
} from "@/lib/supabase/types";

/**
 * One retry, not React Query's default three: the Supabase client already retries network
 * failures itself, and stacking both left customers on a skeleton for a long time on a bad
 * connection before any error and Retry button appeared.
 */
const STOREFRONT_RETRY = 1;

/**
 * Cache windows for the shop. Without them every page change refetched the whole catalogue.
 * Admin changes still show straight away: the admin screens invalidate these keys after a save.
 * Prices and stock are always re-checked by the database at cart and checkout, never from here.
 */
const CATEGORIES_STALE_MS = 5 * 60_000;
const CATALOGUE_STALE_MS = 60_000;

const PRODUCT_COLUMNS =
  "id, slug, name, category_id, description, brand, sku, image_url, price_cents, compare_at_price_cents, unit_label, stock_quantity, low_stock_threshold, in_stock, is_active, created_at, updated_at";

export const categoriesQuery = () =>
  queryOptions({
    queryKey: ["categories"],
    retry: STOREFRONT_RETRY,
    staleTime: CATEGORIES_STALE_MS,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<CategoryRow[]> => {
      const { data, error } = await requireSupabase()
        .from("categories")
        .select(
          "id, slug, name, tagline, description, image_url, parent_id, position, is_active, created_at, updated_at",
        )
        .eq("is_active", true)
        .order("position", { ascending: true });
      if (error) throw new Error(error.message);
      return data ?? [];
    },
  });

export const productsQuery = (categorySlug?: string) =>
  queryOptions({
    queryKey: ["products", categorySlug ?? "all"],
    retry: STOREFRONT_RETRY,
    staleTime: CATALOGUE_STALE_MS,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<ProductRow[]> => {
      const client = requireSupabase();
      let categoryId: string | null = null;

      if (categorySlug) {
        const { data: category, error: categoryError } = await client
          .from("categories")
          .select("id")
          .eq("slug", categorySlug)
          .maybeSingle();
        if (categoryError) throw new Error(categoryError.message);
        if (!category) return [];
        categoryId = category.id;
      }

      // Admins can read hidden rows (see "Products: admin read all"), so the shop must filter
      // is_active itself; otherwise a deactivated product still shows while signed in as admin.
      let query = client
        .from("products")
        .select(PRODUCT_COLUMNS)
        .eq("is_active", true)
        .order("name");
      if (categoryId) query = query.eq("category_id", categoryId);

      const { data, error } = await query;
      if (error) throw new Error(error.message);
      return (data ?? []) as ProductRow[];
    },
  });

export const productQuery = (slug: string) =>
  queryOptions({
    queryKey: ["product", slug],
    retry: STOREFRONT_RETRY,
    staleTime: CATALOGUE_STALE_MS,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<ProductRow | null> => {
      const { data, error } = await requireSupabase()
        .from("products")
        .select(PRODUCT_COLUMNS)
        .eq("slug", slug)
        .eq("is_active", true)
        .maybeSingle();
      if (error) throw new Error(error.message);
      return (data as ProductRow | null) ?? null;
    },
  });

const VARIANT_COLUMNS =
  "id, product_id, name, sku, price_cents, compare_at_price_cents, stock_quantity, low_stock_threshold, attributes, position, is_active, created_at, updated_at";

/**
 * Phase 12. Active options (variants) of one product. Reads the existing public product_variants
 * table through the same browser client as every other catalogue read (the existing "public read
 * active" policy and SELECT grant apply); no new function, table or column.
 */
export const productVariantsQuery = (productId: string) =>
  queryOptions({
    queryKey: ["product-variants", productId],
    retry: STOREFRONT_RETRY,
    staleTime: CATALOGUE_STALE_MS,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<ProductVariantRow[]> => {
      const { data, error } = await requireSupabase()
        .from("product_variants")
        .select(VARIANT_COLUMNS)
        .eq("product_id", productId)
        .eq("is_active", true)
        .order("position", { ascending: true });
      if (error) throw new Error(error.message);
      return (data ?? []) as ProductVariantRow[];
    },
  });

/**
 * Phase 12. One small read of every active variant's product id, price and units, grouped per
 * product, so lists can show "Choose options" and judge sold-out by the options. If this read
 * fails or cannot be read completely, cards stop offering quick-add (they link to the product page,
 * which always checks the variants) and filters fall back to the product row's own stock.
 */
export const variantSummaryQuery = () =>
  queryOptions({
    queryKey: ["variant-summary"],
    retry: STOREFRONT_RETRY,
    staleTime: CATALOGUE_STALE_MS,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<Map<string, OptionsSummary>> => {
      const supabase = requireSupabase();
      // Paged with an exact count and a stable order, so a server row cap can never hand back a
      // silently partial list. If it cannot be read completely this throws and lists fall back.
      const rows = await collectAllPages(async (from, to) => {
        const { data, error, count } = await supabase
          .from("product_variants")
          .select("product_id, price_cents, stock_quantity, is_active", {
            count: "exact",
          })
          .eq("is_active", true)
          .order("id", { ascending: true })
          .range(from, to);
        if (error) throw new Error(error.message);
        return { rows: data ?? [], total: count };
      });
      return summariseVariants(rows);
    },
  });
