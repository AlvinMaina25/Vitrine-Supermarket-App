import {
  AdminAccessError,
  type RpcErrorLike,
} from "../admin/dashboard-result.ts";
import {
  nullableString,
  requireArray,
  requireRecord,
  requireString,
  requireWholeNumber,
  unexpected,
  type JsonRecord,
} from "../admin/customer-parse.ts";
import type {
  PaymentMethod,
  PaymentTransactionStatus,
} from "../../lib/supabase/types.ts";

/**
 * Pure parsers, error mappers and an argument builder for the three Phase 6G.4-A payment read
 * functions: admin_list_payment_transactions(), admin_get_payment_transaction() (admin only) and
 * get_my_order_payments() (the signed-in customer's own order). The browser has no direct table
 * read (6G.4-B), so these RPCs are the only path. Money is integer cents straight from the
 * database; nothing here adds, rounds or converts it. Fields not listed below are dropped.
 */

const WHAT = "The payment records";

// ---------------------------------------------------------------- shapes

/** Fields shared by the admin list and detail. */
export interface AdminPaymentTransaction {
  id: string;
  order_id: string;
  provider: string;
  method: PaymentMethod;
  amount_cents: number;
  currency: string;
  status: PaymentTransactionStatus;
  provider_reference: string | null;
  failure_code: string | null;
  failure_message: string | null;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
}

export interface AdminPaymentTransactionDetail extends AdminPaymentTransaction {
  idempotency_key: string;
}

export interface AdminPaymentTransactionList {
  total_count: number;
  limit: number;
  offset: number;
  transactions: AdminPaymentTransaction[];
}

/** The ONLY fields a customer ever sees. */
export interface MyOrderPayment {
  id: string;
  order_id: string;
  method: PaymentMethod;
  amount_cents: number;
  currency: string;
  status: PaymentTransactionStatus;
  created_at: string;
  completed_at: string | null;
}

export interface MyOrderPayments {
  order_id: string;
  transactions: MyOrderPayment[];
}

// ---------------------------------------------------------------- field guards

function requireTransactionStatus(r: JsonRecord): PaymentTransactionStatus {
  const v = r["status"];
  return v === "pending" ||
    v === "processing" ||
    v === "succeeded" ||
    v === "failed" ||
    v === "cancelled" ||
    v === "expired"
    ? v
    : unexpected(WHAT);
}

function requireMethod(r: JsonRecord): PaymentMethod {
  const v = r["method"];
  return v === "mpesa" || v === "card" || v === "cash_on_delivery"
    ? v
    : unexpected(WHAT);
}

/** Integer cents, whole and strictly positive (the table enforces amount_cents > 0). */
function requireAmountCents(r: JsonRecord): number {
  const v = requireWholeNumber(r, "amount_cents", WHAT);
  return v > 0 ? v : unexpected(WHAT);
}

// ---------------------------------------------------------------- parsers

function toAdminTransaction(value: unknown): AdminPaymentTransaction {
  const r = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    order_id: requireString(r, "order_id", WHAT),
    provider: requireString(r, "provider", WHAT),
    method: requireMethod(r),
    amount_cents: requireAmountCents(r),
    currency: requireString(r, "currency", WHAT),
    status: requireTransactionStatus(r),
    provider_reference: nullableString(r, "provider_reference", WHAT),
    failure_code: nullableString(r, "failure_code", WHAT),
    failure_message: nullableString(r, "failure_message", WHAT),
    created_at: requireString(r, "created_at", WHAT),
    updated_at: requireString(r, "updated_at", WHAT),
    completed_at: nullableString(r, "completed_at", WHAT),
  };
}

export function toAdminPaymentTransactionList(
  data: unknown,
): AdminPaymentTransactionList {
  const r = requireRecord(data, WHAT);
  return {
    total_count: requireWholeNumber(r, "total_count", WHAT),
    limit: requireWholeNumber(r, "limit", WHAT),
    offset: requireWholeNumber(r, "offset", WHAT),
    transactions: requireArray(r["transactions"], WHAT).map(toAdminTransaction),
  };
}

export function toAdminPaymentTransactionDetail(
  data: unknown,
): AdminPaymentTransactionDetail {
  const r = requireRecord(data, WHAT);
  return {
    ...toAdminTransaction(r),
    idempotency_key: requireString(r, "idempotency_key", WHAT),
  };
}

function toMyPayment(value: unknown): MyOrderPayment {
  const r = requireRecord(value, WHAT);
  // Built field by field: anything else the server sends is dropped, never passed through.
  return {
    id: requireString(r, "id", WHAT),
    order_id: requireString(r, "order_id", WHAT),
    method: requireMethod(r),
    amount_cents: requireAmountCents(r),
    currency: requireString(r, "currency", WHAT),
    status: requireTransactionStatus(r),
    created_at: requireString(r, "created_at", WHAT),
    completed_at: nullableString(r, "completed_at", WHAT),
  };
}

export function toMyOrderPayments(data: unknown): MyOrderPayments {
  const r = requireRecord(data, WHAT);
  return {
    order_id: requireString(r, "order_id", WHAT),
    transactions: requireArray(r["transactions"], WHAT).map(toMyPayment),
  };
}

// ---------------------------------------------------------------- error mapping

/** An order or payment record that does not exist (or, for customers, is not theirs). */
export class PaymentNotFoundError extends Error {
  readonly kind: "order" | "transaction";
  constructor(kind: "order" | "transaction") {
    super(
      kind === "order"
        ? "That order could not be found."
        : "That payment could not be found.",
    );
    this.name = "PaymentNotFoundError";
    this.kind = kind;
  }
}

function isNotAuthorised(error: RpcErrorLike): boolean {
  return error.code === "42501" || error.details === "not_authorised";
}

/** Shared by both mappers. Never echoes the database message. */
function mapCommon(error: RpcErrorLike): Error | null {
  if (error.details === "invalid_arguments")
    return new Error("The payment request was not valid.");
  if (error.details === "order_not_found")
    return new PaymentNotFoundError("order");
  if (error.details === "transaction_not_found")
    return new PaymentNotFoundError("transaction");
  return null;
}

/** Admin calls: not-an-admin -> AdminAccessError. */
export function toAdminPaymentReadError(error: RpcErrorLike): Error {
  if (isNotAuthorised(error)) {
    return new AdminAccessError("You do not have permission to view payments.");
  }
  return mapCommon(error) ?? new Error("Payment records could not be loaded.");
}

/** Customer call: signed out -> plain Error; not their order -> PaymentNotFoundError. */
export function toMyOrderPaymentsError(error: RpcErrorLike): Error {
  if (isNotAuthorised(error))
    return new Error("Please sign in to view your payments.");
  return mapCommon(error) ?? new Error("Your payments could not be loaded.");
}

// ---------------------------------------------------------------- arguments

export interface AdminPaymentTransactionQuery {
  orderId?: string | null;
  status?: PaymentTransactionStatus | null;
  provider?: string | null;
  /** Inclusive lower bound, ISO timestamp. */
  from?: string | null;
  /** Exclusive upper bound, ISO timestamp. */
  to?: string | null;
  limit?: number;
  offset?: number;
}

export interface AdminListPaymentTransactionsArgs {
  p_order_id: string | null;
  p_status: PaymentTransactionStatus | null;
  p_provider: string | null;
  p_from: string | null;
  p_to: string | null;
  p_limit: number;
  p_offset: number;
}

/** Named arguments for admin_list_payment_transactions(). Blank provider becomes null; defaults 25/0. */
export function toAdminListPaymentTransactionsArgs(
  query: AdminPaymentTransactionQuery = {},
): AdminListPaymentTransactionsArgs {
  const provider = query.provider?.trim();
  return {
    p_order_id: query.orderId ?? null,
    p_status: query.status ?? null,
    p_provider: provider ? provider : null,
    p_from: query.from ?? null,
    p_to: query.to ?? null,
    p_limit: query.limit ?? 25,
    p_offset: query.offset ?? 0,
  };
}
