import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type { AppRole } from "@/lib/supabase/types";

/**
 * Role-based authorisation.
 *
 * Roles live in their own table (public.user_roles) — never on profiles — and
 * are enforced in the database by RLS policies calling has_role()/is_staff().
 * The query below only drives the UI; hiding a link is never the security
 * boundary.
 */

export const myRolesQuery = () =>
  queryOptions({
    queryKey: ["auth", "roles"],
    staleTime: 60_000,
    queryFn: async (): Promise<AppRole[]> => {
      const client = requireSupabase();
      const { data: auth, error: authError } = await client.auth.getUser();
      if (authError || !auth.user) return [];

      const { data, error } = await client
        .from("user_roles")
        .select("role")
        .eq("user_id", auth.user.id);
      if (error) throw new Error(error.message);
      return (data ?? []).map((row) => row.role as AppRole);
    },
  });

export function hasRole(roles: AppRole[] | undefined, role: AppRole): boolean {
  return (roles ?? []).includes(role);
}

export function isStaff(roles: AppRole[] | undefined): boolean {
  return hasRole(roles, "staff") || hasRole(roles, "admin");
}

/**
 * UI convenience only (e.g. whether to show an admin link). Never a security boundary:
 * admin-only reads and RPCs are refused by the database for anyone who is not an admin.
 */
export function isAdmin(roles: AppRole[] | undefined): boolean {
  return hasRole(roles, "admin");
}
