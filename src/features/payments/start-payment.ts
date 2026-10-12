import { selectGateway } from "../checkout/gateways.ts";
import {
  normalisePayerEmail,
  type GatewayPayer,
  type PaymentGateway,
  type PaymentMethodId,
} from "../checkout/payment-providers.ts";
import { COD_PROVIDER } from "../checkout/providers/cod.ts";
import {
  requireRecord,
  requireString,
  requireWholeNumber,
} from "../admin/customer-parse.ts";
import type { RpcErrorLike } from "../admin/dashboard-result.ts";
import type { PaymentTransactionStatus } from "../../lib/supabase/types.ts";
import {
  PaymentNotFoundError,
  toMyOrderPayments,
  toMyOrderPaymentsError,
  type MyOrderPayment,
  type MyOrderPayments,
} from "./payment-read-result.ts";

/**
 * Phase 6H.1: the "start payment" use case and the customer status read, as pure logic.
 *
 * Every database call goes through `PaymentPorts`, so this file has no framework, network or
 * secret in it and is unit-tested with fakes. The server functions in payment-server.ts wire the
 * ports to real Supabase clients. The amount ALWAYS comes from the database; the browser sends
 * only an order id and a method. Nothing here marks an order paid except through the database
 * functions (record_cod_payment, and later apply_payment_outcome from verified callbacks).
 */

// ---------------------------------------------------------------- ports

export interface RpcResult {
  data: unknown;
  error: RpcErrorLike | null;
}

export interface PaymentPorts {
  /** get_my_order_payments, as the signed-in customer. Doubles as the ownership check. */
  readMyPayments(orderId: string): PromiseLike<RpcResult>;
  /** get_order_for_payment, service role. */
  getOrderForPayment(orderId: string): PromiseLike<RpcResult>;
  /** create_payment_attempt, service role. */
  createAttempt(args: {
    orderId: string;
    provider: string;
    method: PaymentMethodId;
    idempotencyKey: string;
  }): PromiseLike<RpcResult>;
  /** mark_payment_processing, service role. */
  markProcessing(
    transactionId: string,
    providerReference: string,
  ): PromiseLike<RpcResult>;
  /** record_cod_payment, as the signed-in user (the database requires an admin). */
  recordCod(orderId: string, reason: string): PromiseLike<RpcResult>;
  /**
   * The signed-in user's authenticated email (from auth.getUser), or null when there is none.
   * Absent on ports that cannot supply one; gateways that need an email then refuse to start.
   */
  readPayerEmail?(): PromiseLike<string | null>;
}

// ---------------------------------------------------------------- input

export interface StartPaymentInput {
  orderId: string;
  method: PaymentMethodId;
  /** The payer's phone (M-Pesa). Never money: the amount always comes from the database. */
  phone?: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isMethod(value: unknown): value is PaymentMethodId {
  return value === "mpesa" || value === "card" || value === "cash_on_delivery";
}

/** Server-function input validator. Built field by field: an `amount` from the browser is dropped. */
export function parseStartPaymentInput(data: unknown): StartPaymentInput {
  if (typeof data !== "object" || data === null) {
    throw new PaymentStartError("invalid_request");
  }
  const orderId: unknown = Reflect.get(data, "orderId");
  const method: unknown = Reflect.get(data, "method");
  if (typeof orderId !== "string" || !UUID.test(orderId) || !isMethod(method)) {
    throw new PaymentStartError("invalid_request");
  }
  const phone: unknown = Reflect.get(data, "phone");
  if (typeof phone === "string" && phone.length > 0 && phone.length <= 20) {
    return { orderId, method, phone };
  }
  return { orderId, method };
}

export function parseOrderIdInput(data: unknown): { orderId: string } {
  const orderId: unknown =
    typeof data === "object" && data !== null
      ? Reflect.get(data, "orderId")
      : undefined;
  if (typeof orderId !== "string" || !UUID.test(orderId)) {
    throw new PaymentStartError("invalid_request");
  }
  return { orderId };
}

// ---------------------------------------------------------------- errors

export type PaymentStartErrorCode =
  | "invalid_request"
  | "invalid_phone"
  | "email_required"
  | "not_signed_in"
  | "not_permitted"
  | "provider_unavailable"
  | "order_not_payable"
  | "already_paid"
  | "amount_invalid"
  | "amount_mismatch"
  | "method_not_supported"
  | "idempotency_conflict"
  | "cod_not_allowed_yet"
  | "not_cod_order"
  | "attempt_conflict"
  | "provider_error"
  | "unexpected";

const MESSAGES: Record<PaymentStartErrorCode, string> = {
  invalid_request: "The payment request was not valid.",
  invalid_phone:
    "Enter a valid Safaricom number, like 0712345678 or 254712345678.",
  email_required:
    "Card payments need an email address on your account. Add one and try again.",
  not_signed_in: "Please sign in to pay for an order.",
  not_permitted: "You do not have permission to record this payment.",
  provider_unavailable: "That payment method is not available yet.",
  order_not_payable: "This order cannot be paid for.",
  already_paid: "This order is already paid.",
  amount_invalid: "This order has no payable amount.",
  amount_mismatch:
    "The payment amount did not match the order. Please try again.",
  method_not_supported: "That payment method cannot be started this way.",
  idempotency_conflict:
    "That payment request conflicts with an earlier one. Please try again.",
  cod_not_allowed_yet:
    "Cash can only be recorded once the order is out for delivery or delivered.",
  not_cod_order: "This is not a cash on delivery order.",
  attempt_conflict: "This payment is already being processed.",
  provider_error:
    "The payment provider could not be reached. Please try again.",
  unexpected: "The payment could not be started.",
};

/** Carries a code plus a fixed, safe message. Never echoes the database or provider message. */
export class PaymentStartError extends Error {
  readonly code: PaymentStartErrorCode;
  constructor(code: PaymentStartErrorCode) {
    super(MESSAGES[code]);
    this.name = "PaymentStartError";
    this.code = code;
  }
}

/** Maps the 6G.2/6G.3 write-function error codes (error.details) to a safe error. */
export function toPaymentStartError(error: RpcErrorLike): Error {
  if (error.code === "42501" || error.details === "not_authorised") {
    // require_admin() and the auth.uid() guards both land here.
    return new PaymentStartError("not_permitted");
  }
  switch (error.details) {
    case "invalid_arguments":
    case "invalid_reference":
      return new PaymentStartError("invalid_request");
    case "order_not_found":
      return new PaymentNotFoundError("order");
    case "transaction_not_found":
      return new PaymentNotFoundError("transaction");
    case "order_not_payable":
      return new PaymentStartError("order_not_payable");
    case "order_already_paid":
      return new PaymentStartError("already_paid");
    case "order_amount_invalid":
      return new PaymentStartError("amount_invalid");
    case "method_not_supported":
      return new PaymentStartError("method_not_supported");
    case "idempotency_key_conflict":
      return new PaymentStartError("idempotency_conflict");
    case "order_status_not_allowed":
      return new PaymentStartError("cod_not_allowed_yet");
    case "not_cash_on_delivery":
      return new PaymentStartError("not_cod_order");
    case "invalid_transition":
    case "reference_conflict":
    case "provider_reference_in_use":
      return new PaymentStartError("attempt_conflict");
    default:
      return new PaymentStartError("unexpected");
  }
}

/** For the server-function boundary: known errors pass through, anything else is made generic. */
export function toClientSafeError(error: unknown): Error {
  if (
    error instanceof PaymentStartError ||
    error instanceof PaymentNotFoundError
  )
    return error;
  return new PaymentStartError("unexpected");
}

// ---------------------------------------------------------------- idempotency

const RETRYABLE: ReadonlySet<PaymentTransactionStatus> = new Set([
  "failed",
  "cancelled",
  "expired",
]);

/**
 * Which attempt of this method are we on? Stable: the same history always gives the same number,
 * so a double-click or a replayed request reuses one idempotency key (and so one attempt row),
 * while a customer whose last attempt failed, was cancelled or timed out gets a fresh key.
 */
export function nextAttemptNumber(
  transactions: readonly MyOrderPayment[],
  method: PaymentMethodId,
): { attempt: number; latest: MyOrderPayment | null } {
  const mine = transactions
    .filter((t) => t.method === method)
    .sort((a, b) =>
      a.created_at === b.created_at
        ? a.id.localeCompare(b.id)
        : a.created_at < b.created_at
          ? -1
          : 1,
    );
  const latest = mine[mine.length - 1] ?? null;
  if (latest === null) return { attempt: 1, latest: null };
  return {
    attempt: RETRYABLE.has(latest.status) ? mine.length + 1 : mine.length,
    latest,
  };
}

export function buildIdempotencyKey(
  orderId: string,
  method: PaymentMethodId,
  attempt: number,
): string {
  return `pay:${orderId}:${method}:${attempt}`;
}

// ---------------------------------------------------------------- result parsing

interface DbOrder {
  id: string;
  totalCents: number;
  currency: string;
}

interface DbAttempt {
  changed: boolean;
  id: string;
  provider: string;
  method: PaymentMethodId;
  amountCents: number;
  currency: string;
  status: PaymentTransactionStatus;
}

const WHAT = "The payment";

function ok(result: RpcResult): unknown {
  if (result.error) throw toPaymentStartError(result.error);
  return result.data;
}

function parseOrder(data: unknown): DbOrder {
  const r = requireRecord(data, WHAT);
  const totalCents = requireWholeNumber(r, "total_cents", WHAT);
  if (totalCents <= 0) throw new PaymentStartError("amount_invalid");
  return {
    id: requireString(r, "id", WHAT),
    totalCents,
    currency: requireString(r, "currency", WHAT),
  };
}

function parseStatus(value: unknown): PaymentTransactionStatus {
  if (
    value === "pending" ||
    value === "processing" ||
    value === "succeeded" ||
    value === "failed" ||
    value === "cancelled" ||
    value === "expired"
  ) {
    return value;
  }
  throw new PaymentStartError("unexpected");
}

function parseWrite(data: unknown): {
  changed: boolean;
  txn: Record<string, unknown>;
} {
  const r = requireRecord(data, WHAT);
  const changed = r["changed"];
  if (typeof changed !== "boolean") throw new PaymentStartError("unexpected");
  return { changed, txn: requireRecord(r["transaction"], WHAT) };
}

function parseAttempt(data: unknown): DbAttempt {
  const { changed, txn } = parseWrite(data);
  const method = txn["method"];
  if (
    method !== "mpesa" &&
    method !== "card" &&
    method !== "cash_on_delivery"
  ) {
    throw new PaymentStartError("unexpected");
  }
  return {
    changed,
    id: requireString(txn, "id", WHAT),
    provider: requireString(txn, "provider", WHAT),
    method,
    amountCents: requireWholeNumber(txn, "amount_cents", WHAT),
    currency: requireString(txn, "currency", WHAT),
    status: parseStatus(txn["status"]),
  };
}

// ---------------------------------------------------------------- use cases

export type StartPaymentResult =
  /** COD recorded (or already recorded) by record_cod_payment(). */
  | { kind: "cod_recorded"; transactionId: string; changed: boolean }
  /** An attempt already exists and is past "pending": nothing was sent to the provider again. */
  | {
      kind: "already_in_progress";
      transactionId: string;
      status: PaymentTransactionStatus;
    }
  | {
      kind: "initiated";
      transactionId: string;
      status: PaymentTransactionStatus;
      next: { type: "prompt_sent" } | { type: "redirect"; redirectUrl: string };
    };

export const COD_REASON = "Cash collected on delivery";

export async function startPayment(
  ports: PaymentPorts,
  input: StartPaymentInput,
  gateways?: readonly PaymentGateway[],
): Promise<StartPaymentResult> {
  const gateway = selectGateway(input.method, gateways);
  if (gateway === null) throw new PaymentStartError("provider_unavailable");

  // Checked before any attempt row exists, so a typo never leaves a dangling attempt behind.
  const payerPhone = gateway.normalisePayer
    ? gateway.normalisePayer(input.phone ?? null)
    : null;
  if (gateway.normalisePayer && payerPhone === null)
    throw new PaymentStartError("invalid_phone");

  // Cash on delivery: no attempt row, no provider. The database decides who may record it and when.
  if (gateway.collectsOffline) {
    const cod = parseWrite(
      ok(await ports.recordCod(input.orderId, COD_REASON)),
    );
    if (cod.txn["provider"] !== COD_PROVIDER)
      throw new PaymentStartError("unexpected");
    return {
      kind: "cod_recorded",
      transactionId: requireString(cod.txn, "id", WHAT),
      changed: cod.changed,
    };
  }

  // Hosted card checkout needs the customer's real email. Never guessed: no email, no attempt row.
  let payerEmail: string | null = null;
  if (gateway.requiresPayerEmail) {
    payerEmail = normalisePayerEmail((await ports.readPayerEmail?.()) ?? null);
    if (payerEmail === null) throw new PaymentStartError("email_required");
  }
  const payer: GatewayPayer =
    payerEmail === null
      ? { phone: payerPhone }
      : { phone: payerPhone, email: payerEmail };

  // Ownership gate + history. A non-existent order and another customer's order both come back
  // as PaymentNotFoundError, so this call is the "is it yours?" check for the service-role steps.
  const mineResult = await ports.readMyPayments(input.orderId);
  if (mineResult.error) throw toMyOrderPaymentsError(mineResult.error);
  const mine = toMyOrderPayments(mineResult.data);

  const order = parseOrder(ok(await ports.getOrderForPayment(input.orderId)));

  if (
    gateway.acceptsAmountCents &&
    !gateway.acceptsAmountCents(order.totalCents)
  ) {
    throw new PaymentStartError("amount_invalid");
  }

  const { attempt: attemptNo, latest } = nextAttemptNumber(
    mine.transactions,
    input.method,
  );
  if (latest?.status === "succeeded")
    throw new PaymentStartError("already_paid");

  const attempt = parseAttempt(
    ok(
      await ports.createAttempt({
        orderId: order.id,
        provider: gateway.provider,
        method: input.method,
        idempotencyKey: buildIdempotencyKey(order.id, input.method, attemptNo),
      }),
    ),
  );

  // Replay of an attempt that has moved on: do not push a second prompt to the customer.
  if (!attempt.changed && attempt.status !== "pending") {
    return {
      kind: "already_in_progress",
      transactionId: attempt.id,
      status: attempt.status,
    };
  }

  // Belt and braces: the attempt snapshot and the order must agree, both as the database sees them.
  if (
    attempt.amountCents !== order.totalCents ||
    attempt.currency !== order.currency
  ) {
    throw new PaymentStartError("amount_mismatch");
  }

  let initiated;
  try {
    initiated = await gateway.initiate(
      { id: order.id, totalCents: order.totalCents, currency: order.currency },
      {
        transactionId: attempt.id,
        provider: attempt.provider,
        method: attempt.method,
        amountCents: attempt.amountCents,
        currency: attempt.currency,
        idempotencyKey: buildIdempotencyKey(order.id, input.method, attemptNo),
      },
      payer,
    );
  } catch {
    // Deliberately drops the provider's error: it may carry phone numbers or raw payloads.
    throw new PaymentStartError("provider_error");
  }

  if (initiated.kind === "offline")
    throw new PaymentStartError("method_not_supported");

  const marked = parseAttempt(
    ok(await ports.markProcessing(attempt.id, initiated.providerReference)),
  );
  return {
    kind: "initiated",
    transactionId: marked.id,
    status: marked.status,
    next:
      initiated.kind === "redirect"
        ? { type: "redirect", redirectUrl: initiated.redirectUrl }
        : { type: "prompt_sent" },
  };
}

/** Customer-facing payment status: get_my_order_payments through the 6G.4-C mapper. */
export async function readMyOrderPaymentStatus(
  ports: Pick<PaymentPorts, "readMyPayments">,
  orderId: string,
): Promise<MyOrderPayments> {
  const result = await ports.readMyPayments(orderId);
  if (result.error) throw toMyOrderPaymentsError(result.error);
  return toMyOrderPayments(result.data);
}
