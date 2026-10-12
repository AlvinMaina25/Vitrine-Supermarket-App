import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  nullableString,
  requireArray,
  requireBoolean,
  requireRecord,
  requireString,
  requireStatus,
  requireWholeNumber,
  type CustomerStatus,
} from "./customer-parse.ts";

/**
 * Pure parser for admin_get_customer() (Phase 6E.1B-3). Admin-only on the server. Stats and
 * recent-order totals are integer cents computed by the database and passed through untouched.
 */

export interface AdminCustomerProfile {
  id: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  status: CustomerStatus;
  created_at: string;
}

export interface AdminCustomerAddress {
  id: string;
  label: string | null;
  full_name: string | null;
  phone: string | null;
  address_line_1: string | null;
  address_line_2: string | null;
  city: string | null;
  county: string | null;
  postal_code: string | null;
  delivery_instructions: string | null;
  is_default: boolean;
  created_at: string;
}

export interface AdminCustomerStats {
  order_count: number;
  lifetime_spend_cents: number;
  last_order_at: string | null;
}

export interface AdminCustomerRecentOrder {
  id: string;
  status: string;
  payment_status: string;
  total_cents: number;
  created_at: string;
}

export interface AdminCustomerDetail {
  profile: AdminCustomerProfile;
  addresses: AdminCustomerAddress[];
  stats: AdminCustomerStats;
  recent_orders: AdminCustomerRecentOrder[];
  /** null when there is no note row or the notes were cleared. */
  notes: string | null;
  notes_updated_at: string | null;
}

export type AdminCustomerDetailReason =
  "invalid_arguments" | "customer_not_found";

/** The database says this customer does not exist (or is a staff/admin account). */
export class AdminCustomerDetailError extends Error {
  override readonly name = "AdminCustomerDetailError";
  readonly reason: AdminCustomerDetailReason;

  constructor(reason: AdminCustomerDetailReason) {
    super(`Customer detail refused: ${reason}`);
    this.reason = reason;
  }
}

export function toAdminCustomerDetailError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    return new AdminAccessError(
      "You do not have permission to view customers.",
    );
  }
  if (
    error.details === "customer_not_found" ||
    error.details === "invalid_arguments"
  ) {
    return new AdminCustomerDetailError(error.details);
  }
  return new Error(error.message);
}

const WHAT = "The customer detail";

function toProfile(value: unknown): AdminCustomerProfile {
  const r = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    name: nullableString(r, "name", WHAT),
    email: nullableString(r, "email", WHAT),
    phone: nullableString(r, "phone", WHAT),
    status: requireStatus(r, "status", WHAT),
    created_at: requireString(r, "created_at", WHAT),
  };
}

function toAddress(value: unknown): AdminCustomerAddress {
  const r = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    label: nullableString(r, "label", WHAT),
    full_name: nullableString(r, "full_name", WHAT),
    phone: nullableString(r, "phone", WHAT),
    address_line_1: nullableString(r, "address_line_1", WHAT),
    address_line_2: nullableString(r, "address_line_2", WHAT),
    city: nullableString(r, "city", WHAT),
    county: nullableString(r, "county", WHAT),
    postal_code: nullableString(r, "postal_code", WHAT),
    delivery_instructions: nullableString(r, "delivery_instructions", WHAT),
    is_default: requireBoolean(r, "is_default", WHAT),
    created_at: requireString(r, "created_at", WHAT),
  };
}

function toStats(value: unknown): AdminCustomerStats {
  const r = requireRecord(value, WHAT);
  return {
    order_count: requireWholeNumber(r, "order_count", WHAT),
    lifetime_spend_cents: requireWholeNumber(r, "lifetime_spend_cents", WHAT),
    last_order_at: nullableString(r, "last_order_at", WHAT),
  };
}

function toRecentOrder(value: unknown): AdminCustomerRecentOrder {
  const r = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    status: requireString(r, "status", WHAT),
    payment_status: requireString(r, "payment_status", WHAT),
    total_cents: requireWholeNumber(r, "total_cents", WHAT),
    created_at: requireString(r, "created_at", WHAT),
  };
}

export function toAdminCustomerDetail(data: unknown): AdminCustomerDetail {
  const r = requireRecord(data, WHAT);
  return {
    profile: toProfile(r["profile"]),
    addresses: requireArray(r["addresses"], WHAT).map(toAddress),
    stats: toStats(r["stats"]),
    recent_orders: requireArray(r["recent_orders"], WHAT).map(toRecentOrder),
    notes: nullableString(r, "notes", WHAT),
    notes_updated_at: nullableString(r, "notes_updated_at", WHAT),
  };
}

/** Named argument for admin_get_customer(). */
export function toAdminGetCustomerArgs(customerId: string): {
  p_customer_id: string;
} {
  return { p_customer_id: customerId };
}
