/// <reference types="node" />
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { supabaseConfig } from "../env";
import type { Database } from "./types";

/**
 * Server-only Supabase clients. Import these ONLY from inside server-function handlers.
 *
 * - The user client carries the caller's access token, so RLS and auth.uid() apply (it is how
 *   get_my_order_payments and record_cod_payment see the signed-in user).
 * - The service client uses SUPABASE_SERVICE_ROLE_KEY, a server-only variable: never a VITE_* name,
 *   never logged, never sent to the browser. It is the only way to call the service_role payment
 *   functions.
 */

const NO_SESSION = {
  persistSession: false,
  autoRefreshToken: false,
  detectSessionInUrl: false,
} as const;

export class ServerConfigError extends Error {
  constructor(name: string) {
    super(`Server configuration is missing ${name}.`);
    this.name = "ServerConfigError";
  }
}

function requireProjectConfig(): { url: string; publishableKey: string } {
  if (!supabaseConfig.url) throw new ServerConfigError("VITE_SUPABASE_URL");
  if (!supabaseConfig.publishableKey)
    throw new ServerConfigError("VITE_SUPABASE_PUBLISHABLE_KEY");
  return {
    url: supabaseConfig.url,
    publishableKey: supabaseConfig.publishableKey,
  };
}

export function createUserClient(
  accessToken: string,
): SupabaseClient<Database> {
  const { url, publishableKey } = requireProjectConfig();
  return createClient<Database>(url, publishableKey, {
    auth: NO_SESSION,
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export function createServiceClient(): SupabaseClient<Database> {
  const { url } = requireProjectConfig();
  const serviceRoleKey = process.env["SUPABASE_SERVICE_ROLE_KEY"];
  if (!serviceRoleKey) throw new ServerConfigError("SUPABASE_SERVICE_ROLE_KEY");
  return createClient<Database>(url, serviceRoleKey, { auth: NO_SESSION });
}
