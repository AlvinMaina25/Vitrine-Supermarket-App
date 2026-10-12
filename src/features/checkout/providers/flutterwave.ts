import {
  normalisePayerEmail,
  type CallbackRequest,
  type FinalOutcome,
  type GatewayAttempt,
  type GatewayOrder,
  type GatewayPayer,
  type InitiateResult,
  type PaymentGateway,
  type VerifiedOutcome,
} from "../payment-providers.ts";
import { constantTimeEquals } from "./mpesa.ts";
import type { HttpClient } from "./http.ts";

/**
 * Flutterwave (API v3) hosted checkout for CARD payments in KES, test keys only.
 *
 * - initiate: server-side POST /v3/payments with tx_ref = OUR attempt id, then the customer is
 *   redirected to Flutterwave's hosted page. No card data ever reaches this server.
 * - parseCallback: checks the `verif-hash` header against the webhook secret hash BEFORE parsing
 *   the body, then re-queries GET /v3/transactions/{id}/verify and trusts only that answer
 *   (status, amount, currency, tx_ref). Flutterwave's v3 hash is a static shared value (no body
 *   HMAC, no timestamp), so this server-side re-verification is what binds a webhook to a payment.
 *
 * No database access and no real network: HTTP goes through the injected client. Error messages
 * are fixed strings and never contain keys, hashes, emails, URLs or provider payloads.
 */

export const FLUTTERWAVE_PROVIDER = "flutterwave";
export const FLUTTERWAVE_BASE_URL = "https://api.flutterwave.com";
export const FLUTTERWAVE_CURRENCY = "KES";
/** The webhook header Flutterwave v3 sends the secret hash in. Lower-case: routes lower-case names. */
export const FLUTTERWAVE_HASH_HEADER = "verif-hash";

export interface FlutterwaveConfig {
  /** Test secret key (FLWSECK_TEST-...). Server-only. */
  secretKey: string;
  /** The "secret hash" set in the dashboard's webhook settings. At least 16 characters. */
  webhookSecret: string;
  /** Public https origin of this site, no trailing path (the return path is appended). */
  returnBaseUrl: string;
}

export type FlutterwaveErrorReason =
  | "email_required"
  | "currency_unsupported"
  | "amount_invalid"
  | "create_rejected"
  | "bad_response";

export class FlutterwaveError extends Error {
  readonly reason: FlutterwaveErrorReason;
  constructor(reason: FlutterwaveErrorReason) {
    super(`Flutterwave request failed (${reason}).`);
    this.name = "FlutterwaveError";
    this.reason = reason;
  }
}

/**
 * A webhook that must not be acted on.
 * bad_signature -> the route answers 401. malformed -> acknowledged with 200 (retrying cannot fix
 * it). verify_unavailable -> the route answers 500 so Flutterwave retries later.
 */
export type CardCallbackRejection =
  "bad_signature" | "malformed" | "verify_unavailable";

export class CardCallbackRejectedError extends Error {
  readonly reason: CardCallbackRejection;
  constructor(reason: CardCallbackRejection) {
    super(`Card webhook rejected (${reason}).`);
    this.name = "CardCallbackRejectedError";
    this.reason = reason;
  }
}

// ---------------------------------------------------------------- small pure helpers

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

function nonEmptyString(value: unknown, max = 200): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= max
    ? value
    : null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (
    typeof value === "string" &&
    value.trim() !== "" &&
    Number.isFinite(Number(value))
  ) {
    return Number(value);
  }
  return null;
}

/** Flutterwave transaction ids are positive integers (number or numeric string). */
function transactionId(value: unknown): string | null {
  const text =
    typeof value === "number" && Number.isSafeInteger(value)
      ? String(value)
      : value;
  return typeof text === "string" && /^[1-9]\d{0,17}$/.test(text) ? text : null;
}

/** Major units (KES) -> integer cents, or null when the value is not an exact cents amount. */
export function majorToCents(value: number): number | null {
  if (!(value > 0)) return null;
  const cents = Math.round(value * 100);
  return Math.abs(value * 100 - cents) < 1e-6 ? cents : null;
}

/** Provider status -> our final outcome. "pending" and anything unknown map to null (ignore). */
export function mapFlutterwaveStatus(status: string): FinalOutcome | null {
  switch (status.toLowerCase()) {
    case "successful":
    case "succeeded":
    case "success":
      return "succeeded";
    case "failed":
      return "failed";
    case "cancelled":
    case "canceled":
      return "cancelled";
    case "expired":
      return "expired";
    default:
      return null;
  }
}

// ---------------------------------------------------------------- gateway

export function createFlutterwaveCardGateway(
  config: FlutterwaveConfig,
  http: HttpClient,
): PaymentGateway {
  if (config.webhookSecret.length < 16) {
    throw new Error("The card webhook secret must be at least 16 characters.");
  }
  const returnBase = config.returnBaseUrl.replace(/\/+$/, "");
  const authHeaders = {
    Authorization: `Bearer ${config.secretKey}`,
    "Content-Type": "application/json",
  } as const;

  /** Re-queries Flutterwave for the transaction. Network trouble is retryable; a bad body is not. */
  async function verifyTransaction(id: string): Promise<JsonRecord> {
    let response;
    try {
      response = await http.request({
        method: "GET",
        url: `${FLUTTERWAVE_BASE_URL}/v3/transactions/${id}/verify`,
        headers: authHeaders,
      });
    } catch {
      throw new CardCallbackRejectedError("verify_unavailable");
    }
    if (response.status >= 500 || response.status === 429) {
      throw new CardCallbackRejectedError("verify_unavailable");
    }
    const json = parseJson(response.body);
    if (
      response.status !== 200 ||
      !isRecord(json) ||
      json["status"] !== "success"
    ) {
      throw new CardCallbackRejectedError("malformed");
    }
    const data = json["data"];
    if (!isRecord(data)) throw new CardCallbackRejectedError("malformed");
    return data;
  }

  return {
    method: "card",
    provider: FLUTTERWAVE_PROVIDER,
    collectsOffline: false,
    requiresPayerEmail: true,

    async initiate(
      order: GatewayOrder,
      attempt: GatewayAttempt,
      payer: GatewayPayer,
    ): Promise<InitiateResult> {
      // Real, authenticated email only: never a placeholder.
      const email = normalisePayerEmail(payer.email);
      if (email === null) throw new FlutterwaveError("email_required");
      if (attempt.currency !== FLUTTERWAVE_CURRENCY)
        throw new FlutterwaveError("currency_unsupported");
      if (!Number.isInteger(attempt.amountCents) || attempt.amountCents <= 0) {
        throw new FlutterwaveError("amount_invalid");
      }

      const response = await http.request({
        method: "POST",
        url: `${FLUTTERWAVE_BASE_URL}/v3/payments`,
        headers: authHeaders,
        body: JSON.stringify({
          // Our attempt id is the reference: unique per attempt, and what the webhook echoes back.
          tx_ref: attempt.transactionId,
          // Flutterwave takes major units; the amount comes from the database attempt, never the browser.
          amount: attempt.amountCents / 100,
          currency: FLUTTERWAVE_CURRENCY,
          redirect_url: `${returnBase}/api/public/card-return/${order.id}`,
          payment_options: "card",
          customer: { email },
          meta: { attempt_id: attempt.transactionId },
          customizations: { title: "Order payment" },
        }),
      });
      const json = parseJson(response.body);
      const data = isRecord(json) ? json["data"] : undefined;
      const link = isRecord(data) ? nonEmptyString(data["link"], 2000) : null;
      if (
        response.status !== 200 ||
        !isRecord(json) ||
        json["status"] !== "success"
      ) {
        throw new FlutterwaveError("create_rejected");
      }
      if (link === null || !isFlutterwaveCheckoutUrl(link))
        throw new FlutterwaveError("bad_response");
      return {
        kind: "redirect",
        providerReference: attempt.transactionId,
        redirectUrl: link,
      };
    },

    async parseCallback(request: CallbackRequest): Promise<VerifiedOutcome> {
      // 1. Authenticity first. Nothing in the body is read until the secret hash matches.
      const given = request.headers[FLUTTERWAVE_HASH_HEADER];
      if (
        request.method !== "POST" ||
        typeof given !== "string" ||
        given.length === 0 ||
        !constantTimeEquals(given, config.webhookSecret)
      ) {
        throw new CardCallbackRejectedError("bad_signature");
      }

      // 2. Shape.
      const root = parseJson(request.body);
      if (!isRecord(root)) throw new CardCallbackRejectedError("malformed");
      if (root["event"] !== "charge.completed") return { kind: "ignored" };
      const hook = root["data"];
      if (!isRecord(hook)) throw new CardCallbackRejectedError("malformed");
      const id = transactionId(hook["id"]);
      const hookRef = nonEmptyString(hook["tx_ref"]);
      if (id === null || hookRef === null)
        throw new CardCallbackRejectedError("malformed");

      // 3. Never trust the webhook's own status or amount: re-query Flutterwave and use that answer.
      const verified = await verifyTransaction(id);
      if (
        transactionId(verified["id"]) !== id ||
        verified["tx_ref"] !== hookRef
      ) {
        throw new CardCallbackRejectedError("malformed");
      }
      const status = nonEmptyString(verified["status"], 40);
      if (status === null) throw new CardCallbackRejectedError("malformed");
      const outcome = mapFlutterwaveStatus(status);
      if (outcome === null) return { kind: "ignored" };

      if (outcome === "succeeded") {
        const amount = asNumber(verified["amount"]);
        const currency = nonEmptyString(verified["currency"], 3);
        return {
          kind: "outcome",
          providerReference: hookRef,
          outcome,
          // Not an exact cents amount -> null, which settlement treats as an amount mismatch.
          amountCents: amount === null ? null : majorToCents(amount),
          currency,
          receiptNumber: nonEmptyString(verified["flw_ref"]),
          failureCode: null,
          failureMessage: null,
        };
      }
      const processor = nonEmptyString(verified["processor_response"]);
      return {
        kind: "outcome",
        providerReference: hookRef,
        outcome,
        amountCents: null,
        currency: null,
        receiptNumber: null,
        failureCode: `flutterwave_${status.toLowerCase()}`.slice(0, 60),
        failureMessage: processor,
      };
    },
  };
}

/** Only an https link on a flutterwave.com host is ever handed to the browser as a redirect. */
function isFlutterwaveCheckoutUrl(link: string): boolean {
  try {
    const url = new URL(link);
    return (
      url.protocol === "https:" &&
      (url.hostname === "flutterwave.com" ||
        url.hostname.endsWith(".flutterwave.com"))
    );
  } catch {
    return false;
  }
}
