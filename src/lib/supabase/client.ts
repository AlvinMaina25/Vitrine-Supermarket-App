import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { isSupabaseConfigured, supabaseConfig } from "../env";
import type { Database } from "./types";

/**
 * Browser Supabase client for the user's own Supabase project.
 *
 * Returns `null` when the environment is not configured yet, so the UI can
 * render an explicit configuration state instead of crashing or faking data.
 */
export const supabase: SupabaseClient<Database> | null = isSupabaseConfigured
  ? createClient<Database>(supabaseConfig.url, supabaseConfig.publishableKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;

export class SupabaseNotConfiguredError extends Error {
  constructor() {
    super("Supabase is not configured for this environment.");
    this.name = "SupabaseNotConfiguredError";
  }
}

export function requireSupabase(): SupabaseClient<Database> {
  if (!supabase) throw new SupabaseNotConfiguredError();
  return supabase;
}
