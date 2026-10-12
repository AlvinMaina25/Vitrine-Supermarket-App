import type { AdminDashboardSummary } from "../../lib/supabase/types.ts";

/**
 * Pure helpers for public.admin_dashboard_summary() (Phase 6A). No runtime imports, so they run
 * under `node --test` as well as in the app.
 *
 * Authorisation is NOT decided here. The database refuses the call for anyone who is not an admin
 * (SQLSTATE 42501, DETAIL `not_authorised`); this only turns that refusal into an error the UI
 * can recognise, and checks that the payload has the expected shape.
 */

/** The shape of a Supabase/PostgREST error, kept structural so this has no runtime imports. */
export interface RpcErrorLike {
  message: string;
  details?: string | null;
  hint?: string | null;
  code?: string | null;
}

export class AdminAccessError extends Error {
  override readonly name = "AdminAccessError";

  constructor(
    message = "You do not have permission to view the admin dashboard.",
  ) {
    super(message);
  }
}

export function isAdminAccessError(error: unknown): error is AdminAccessError {
  return error instanceof AdminAccessError;
}

/**
 * 42501 covers both "not_authorised" raised by the admin gate (signed-in, not admin) and
 * "permission denied for function" (anonymous). Anything else is an ordinary failure and keeps
 * its own message.
 */
export function toAdminDashboardError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError();
  }
  return new Error(error.message);
}

const REQUIRED_KEYS = [
  "generated_at",
  "time_zone",
  "low_stock_threshold",
  "orders",
  "payments",
  "delivery",
  "products",
  "variants",
  "low_stock_items",
  "customers",
  "recent_orders",
] as const;

/**
 * The RPC returns one jsonb document. The types are hand-maintained, so check the top-level
 * shape instead of trusting a cast: a database that has not had the Phase 6A migration (or one
 * that returned something else) fails loudly here rather than rendering `undefined`.
 */
export function toAdminDashboardSummary(data: unknown): AdminDashboardSummary {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new Error("The admin dashboard returned an unexpected response.");
  }
  const record = data as Record<string, unknown>;
  for (const key of REQUIRED_KEYS) {
    if (!(key in record)) {
      throw new Error(`The admin dashboard response is missing "${key}".`);
    }
  }
  return data as AdminDashboardSummary;
}
