import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import {
  toAdminCustomerDetail,
  toAdminCustomerDetailError,
  toAdminGetCustomerArgs,
} from "./customer-detail-result";
import {
  toAdminUpdateCustomerNotesResult,
  toAdminCustomerNotesError,
  type AdminUpdateCustomerNotesArgs,
  type AdminUpdateCustomerNotesResult,
} from "./customer-notes-result";
import {
  toAdminCustomerStatusError,
  toAdminSetCustomerStatusResult,
  type AdminSetCustomerStatusArgs,
  type AdminSetCustomerStatusResult,
} from "./customer-status-result";
import {
  toCustomersListArgs,
  type CustomersParams,
} from "./customers-management";
import { toAdminCustomerList, toAdminCustomersError } from "./customers-result";

/**
 * Admin customers (Phase 6E.1 backend, consumed by Phase 6E.2).
 *
 * Every call goes through the signed-in session to an admin-only database function; none of them
 * touches a table directly. The database refuses customers, staff and anonymous visitors
 * (AdminAccessError); hiding a link or a button is a UI convenience only. Money (order totals,
 * lifetime spend) arrives as integer cents computed by the database and is never calculated here.
 *
 *   admin_list_customers()         read; search, status filter and paging happen in the database
 *   admin_get_customer()           read; profile, addresses, stats, recent orders, status, notes
 *   admin_set_customer_status()    write; sets active / suspended and writes the audit row
 *   admin_update_customer_notes()  write; upserts the internal notes and audits the length only
 *
 * Suspension is a label: the database does not yet stop a suspended customer from ordering.
 *
 * All query keys start with ["admin", "customers"], so one invalidation refreshes every view.
 */

/** Server-paged list, straight from the screen state (search, status, page). */
export const adminCustomersQuery = (params: CustomersParams = {}) =>
  queryOptions({
    queryKey: ["admin", "customers", "list", toCustomersListArgs(params)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_customers",
        toCustomersListArgs(params),
      );
      if (error) throw toAdminCustomersError(error);
      return toAdminCustomerList(data);
    },
  });

/** One customer: profile, addresses, stats, recent orders, status and internal notes. */
export const adminCustomerQuery = (customerId: string) =>
  queryOptions({
    queryKey: ["admin", "customers", "detail", customerId],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_get_customer",
        toAdminGetCustomerArgs(customerId),
      );
      if (error) throw toAdminCustomerDetailError(error);
      return toAdminCustomerDetail(data);
    },
  });

/**
 * Suspend or reactivate one customer. The database checks the reason, refuses staff accounts and
 * the caller's own account, and writes the audit row in the same transaction.
 */
export async function adminSetCustomerStatus(
  args: AdminSetCustomerStatusArgs,
): Promise<AdminSetCustomerStatusResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_customer_status",
    args,
  );
  if (error) throw toAdminCustomerStatusError(error);
  return toAdminSetCustomerStatusResult(data);
}

/**
 * Replace one customer's internal notes. An empty string clears them. The database audits the
 * length only, never the text.
 */
export async function adminUpdateCustomerNotes(
  args: AdminUpdateCustomerNotesArgs,
): Promise<AdminUpdateCustomerNotesResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_update_customer_notes",
    args,
  );
  if (error) throw toAdminCustomerNotesError(error);
  return toAdminUpdateCustomerNotesResult(data);
}
