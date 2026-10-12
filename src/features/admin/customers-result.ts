import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  nullableString,
  requireArray,
  requireRecord,
  requireString,
  requireStatus,
  requireWholeNumber,
  type CustomerStatus,
} from "./customer-parse.ts";

/**
 * Pure parser and argument builder for admin_list_customers() (Phase 6E.1B-3, 4-argument form).
 * Admin-only on the server (require_admin()). Money is integer cents straight from the database;
 * nothing here adds, rounds or converts it.
 */

export type { CustomerStatus };

export interface AdminCustomerListRow {
  id: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  status: CustomerStatus;
  created_at: string;
  order_count: number;
  lifetime_spend_cents: number;
  last_order_at: string | null;
}

export interface AdminCustomerList {
  total: number;
  page: number;
  page_size: number;
  customers: AdminCustomerListRow[];
}

const WHAT = "The customer list";

/** Reads: not-an-admin -> AdminAccessError; bad arguments and anything else keep a plain Error. */
export function toAdminCustomersError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to view customers.",
    );
  }
  if (error.details === "invalid_arguments") {
    return new Error("The customer list request was not valid.");
  }
  return new Error(error.message);
}

function toRow(value: unknown): AdminCustomerListRow {
  const r = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    name: nullableString(r, "name", WHAT),
    email: nullableString(r, "email", WHAT),
    phone: nullableString(r, "phone", WHAT),
    status: requireStatus(r, "status", WHAT),
    created_at: requireString(r, "created_at", WHAT),
    order_count: requireWholeNumber(r, "order_count", WHAT),
    lifetime_spend_cents: requireWholeNumber(r, "lifetime_spend_cents", WHAT),
    last_order_at: nullableString(r, "last_order_at", WHAT),
  };
}

export function toAdminCustomerList(data: unknown): AdminCustomerList {
  const r = requireRecord(data, WHAT);
  return {
    total: requireWholeNumber(r, "total", WHAT),
    page: requireWholeNumber(r, "page", WHAT),
    page_size: requireWholeNumber(r, "page_size", WHAT),
    customers: requireArray(r["customers"], WHAT).map(toRow),
  };
}

export interface AdminCustomerListQuery {
  search?: string | null;
  status?: CustomerStatus | null;
  page?: number;
  pageSize?: number;
}

export interface AdminListCustomersArgs {
  p_search: string | null;
  p_page: number;
  p_page_size: number;
  p_status: CustomerStatus | null;
}

/** Named arguments for admin_list_customers(). Blank search becomes null; defaults are explicit. */
export function toAdminListCustomersArgs(
  query: AdminCustomerListQuery = {},
): AdminListCustomersArgs {
  const search = query.search?.trim();
  return {
    p_search: search ? search : null,
    p_page: query.page ?? 1,
    p_page_size: query.pageSize ?? 25,
    p_status: query.status ?? null,
  };
}
