import {
  toAdminListCustomersArgs,
  type AdminCustomerListQuery,
  type AdminListCustomersArgs,
  type CustomerStatus,
} from "./customers-result.ts";

/**
 * Pure helpers for the admin customers list screen (Phase 6E.2). No runtime imports beyond
 * sibling pure modules, so they run under `node --test`.
 *
 * The URL is the single source of truth for what is on screen. Nothing here decides who may see
 * customers: the database does (require_admin() inside admin_list_customers()).
 */

export const CUSTOMERS_PAGE_SIZE = 25;

/** admin_list_customers() rejects a search over 100 characters; longer input is trimmed instead. */
export const CUSTOMERS_MAX_SEARCH_LENGTH = 100;

/** Pages beyond this are treated as page 1 (the database refuses above 1,000,000). */
export const CUSTOMERS_MAX_PAGE = 100_000;

export const CUSTOMER_STATUSES: readonly CustomerStatus[] = [
  "active",
  "suspended",
];

export const CUSTOMER_STATUS_LABELS: Record<CustomerStatus, string> = {
  active: "Active",
  suspended: "Suspended",
};

export interface CustomersParams {
  /** Search text (name, email or phone); omitted means no search. */
  q?: string;
  /** Status filter; omitted means all customers. */
  status?: CustomerStatus;
  /** 1-based; omitted means page 1. */
  page?: number;
}

/**
 * Keeps at most `max` characters, counted by code point like the database's char_length(), so an
 * emoji (a UTF-16 surrogate pair) is never cut in half.
 */
export function truncateCodePoints(value: string, max: number): string {
  const points = Array.from(value);
  return points.length <= max ? value : points.slice(0, max).join("");
}

/** Unknown or malformed values are dropped rather than sent to the database. */
export function parseCustomersParams(
  search: Record<string, unknown>,
): CustomersParams {
  const params: CustomersParams = {};

  const q = search["q"];
  if (typeof q === "string" && q.trim() !== "") {
    params.q = truncateCodePoints(q.trim(), CUSTOMERS_MAX_SEARCH_LENGTH).trim();
  }

  const status = search["status"];
  if (status === "active" || status === "suspended") params.status = status;

  const page = Number(search["page"]);
  if (Number.isInteger(page) && page > 1 && page <= CUSTOMERS_MAX_PAGE)
    params.page = page;

  return params;
}

/** Page 1 when none is set. */
export function activeCustomersPage(params: CustomersParams): number {
  return params.page ?? 1;
}

/** Search params as they go in the URL: defaults (page 1, no filter) are left out. */
export function normaliseCustomersParams(
  params: CustomersParams,
): CustomersParams {
  return parseCustomersParams({
    q: params.q,
    status: params.status,
    page: params.page,
  });
}

/** A new search or filter always returns to page 1; paging alone keeps the rest. */
export function withCustomersFilter(
  params: CustomersParams,
  change: { q?: string | null; status?: CustomerStatus | null },
): CustomersParams {
  return parseCustomersParams({
    q: change.q === undefined ? params.q : change.q,
    status: change.status === undefined ? params.status : change.status,
  });
}

export function withCustomersPage(
  params: CustomersParams,
  page: number,
): CustomersParams {
  return normaliseCustomersParams({ ...params, page });
}

/** Query for the list RPC wrapper. */
export function toCustomersListQuery(
  params: CustomersParams,
  pageSize: number = CUSTOMERS_PAGE_SIZE,
): AdminCustomerListQuery {
  return {
    search: params.q ?? null,
    status: params.status ?? null,
    page: activeCustomersPage(params),
    pageSize,
  };
}

/** Named arguments for admin_list_customers(), straight from the screen state. */
export function toCustomersListArgs(
  params: CustomersParams,
  pageSize: number = CUSTOMERS_PAGE_SIZE,
): AdminListCustomersArgs {
  return toAdminListCustomersArgs(toCustomersListQuery(params, pageSize));
}

/** Number of pages for the database's own `total` and the page size it reported; at least 1. */
export function customersTotalPages(total: number, pageSize: number): number {
  if (!Number.isFinite(total) || total <= 0 || pageSize < 1) return 1;
  return Math.ceil(total / pageSize);
}

/** True when any search or status filter is applied (paging alone is not a filter). */
export function hasCustomersFilter(params: CustomersParams): boolean {
  return params.q !== undefined || params.status !== undefined;
}
