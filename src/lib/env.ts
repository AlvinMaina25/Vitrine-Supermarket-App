/**
 * Environment configuration.
 *
 * The storefront reads its Supabase connection from Vite environment
 * variables. Values are validated once here so every consumer can rely on a
 * single, explicit source of truth.
 */

const url = import.meta.env["VITE_SUPABASE_URL"] as string | undefined;
const publishableKey = import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as
  string | undefined;

export const supabaseConfig = {
  url: url ?? "",
  publishableKey: publishableKey ?? "",
} as const;

export const missingSupabaseEnv: string[] = [
  ...(url ? [] : ["VITE_SUPABASE_URL"]),
  ...(publishableKey ? [] : ["VITE_SUPABASE_PUBLISHABLE_KEY"]),
];

export const isSupabaseConfigured = missingSupabaseEnv.length === 0;

export const storeConfig = {
  name: (import.meta.env["VITE_STORE_NAME"] as string | undefined) ?? "Vitrine",
  currency:
    (import.meta.env["VITE_STORE_CURRENCY"] as string | undefined) ?? "KES",
} as const;

/** Public, non-secret flag. Card checkout is selectable only when this is exactly "true". */
export const cardPaymentsEnabled =
  (import.meta.env["VITE_CARD_PAYMENTS_ENABLED"] as string | undefined) ===
  "true";
