import type {
  CallbackRequest,
  FinalOutcome,
  GatewayAttempt,
  GatewayOrder,
  GatewayPayer,
  InitiateResult,
  PaymentGateway,
  StatusQueryResult,
  VerifiedOutcome,
} from "../payment-providers.ts";
import type { HttpClient, HttpResponse } from "./http.ts";

/**
 * M-Pesa (Safaricom Daraja) STK Push gateway, sandbox only.
 *
 * Nothing here touches the database or a real network: HTTP goes through the injected client, and
 * the caller (src/features/payments/) applies outcomes. Error messages are fixed strings. They never
 * contain a phone number, token, URL, or any part of a provider payload.
 */

export const MPESA_PROVIDER = "mpesa-daraja";
/** Sandbox host only. There is deliberately no production switch in 6H. */
export const DARAJA_SANDBOX_BASE_URL = "https://sandbox.safaricom.co.ke";

export interface MpesaConfig {
  consumerKey: string;
  consumerSecret: string;
  shortcode: string;
  passkey: string;
  /** Public https origin of this site, no trailing path (the callback path is appended). */
  callbackBaseUrl: string;
  /** Secret path segment that guards the callback route. At least 16 characters. */
  callbackToken: string;
}

export type MpesaErrorReason =
  | "auth_failed"
  | "push_rejected"
  | "query_failed"
  | "bad_response"
  | "amount_not_whole"
  | "bad_phone";

export class MpesaError extends Error {
  readonly reason: MpesaErrorReason;
  constructor(reason: MpesaErrorReason) {
    super(`M-Pesa request failed (${reason}).`);
    this.name = "MpesaError";
    this.reason = reason;
  }
}

/** A callback that must not be acted on. `bad_token` -> the route answers 404; `malformed` -> 200 ack. */
export class CallbackRejectedError extends Error {
  readonly reason: "bad_token" | "malformed";
  constructor(reason: "bad_token" | "malformed") {
    super(`M-Pesa callback rejected (${reason}).`);
    this.name = "CallbackRejectedError";
    this.reason = reason;
  }
}

// ---------------------------------------------------------------- small pure helpers

/** 2547XXXXXXXX or 2541XXXXXXXX, from 07/01 local, 254 or +254 input. Anything else is null. */
export function normaliseKenyanPhone(input: string | null): string | null {
  if (input === null) return null;
  const compact = input.replace(/[\s-]/g, "");
  const hasPlus = compact.startsWith("+");
  const digits = hasPlus ? compact.slice(1) : compact;
  if (!/^\d+$/.test(digits)) return null;
  let international: string;
  if (digits.startsWith("254")) international = digits;
  else if (!hasPlus && digits.startsWith("0"))
    international = `254${digits.slice(1)}`;
  else return null;
  return /^254[71]\d{8}$/.test(international) ? international : null;
}

/** Compares secrets without exiting early on the first differing character. */
export function constantTimeEquals(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}

/** Daraja's YYYYMMDDHHmmss, in East Africa Time (UTC+3). */
export function darajaTimestamp(nowMs: number): string {
  return new Date(nowMs + 3 * 60 * 60 * 1000)
    .toISOString()
    .replace(/[-:T]/g, "")
    .slice(0, 14);
}

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

function nonEmptyString(value: unknown, max = 200): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= max
    ? value
    : null;
}

/** Daraja ResultCode -> final outcome. 0 paid, 1032 user cancelled, 1037 timed out, the rest failed. */
export function mapResultCode(
  code: number,
  description: string | null,
): {
  outcome: FinalOutcome;
  failureCode: string | null;
  failureMessage: string | null;
} {
  if (code === 0)
    return { outcome: "succeeded", failureCode: null, failureMessage: null };
  const outcome: FinalOutcome =
    code === 1032 ? "cancelled" : code === 1037 ? "expired" : "failed";
  return {
    outcome,
    failureCode: `mpesa_${code}`,
    failureMessage: description === null ? null : description.slice(0, 200),
  };
}

/** KES whole units -> integer cents, or null when the value is not an exact cents amount. */
function kesToCents(value: number): number | null {
  if (value < 0) return null;
  const cents = Math.round(value * 100);
  return Math.abs(value * 100 - cents) < 1e-6 ? cents : null;
}

// ---------------------------------------------------------------- callback parsing

function parseStkCallback(body: string): {
  checkoutRequestId: string;
  resultCode: number;
  resultDesc: string | null;
  amountCents: number | null;
  receipt: string | null;
} {
  const root = parseJson(body);
  const outer = isRecord(root) ? root["Body"] : undefined;
  const stk = isRecord(outer) ? outer["stkCallback"] : undefined;
  if (!isRecord(stk)) throw new CallbackRejectedError("malformed");

  const checkoutRequestId = nonEmptyString(stk["CheckoutRequestID"]);
  const resultCode = asNumber(stk["ResultCode"]);
  if (
    checkoutRequestId === null ||
    resultCode === null ||
    !Number.isInteger(resultCode)
  ) {
    throw new CallbackRejectedError("malformed");
  }
  const resultDesc =
    typeof stk["ResultDesc"] === "string" ? stk["ResultDesc"] : null;

  const metadata = isRecord(stk["CallbackMetadata"])
    ? stk["CallbackMetadata"]
    : null;
  const items =
    metadata !== null && Array.isArray(metadata["Item"])
      ? (metadata["Item"] as unknown[])
      : [];
  const byName = new Map<string, unknown>();
  for (const item of items) {
    if (isRecord(item) && typeof item["Name"] === "string")
      byName.set(item["Name"], item["Value"]);
  }
  const amount = asNumber(byName.get("Amount"));
  return {
    checkoutRequestId,
    resultCode,
    resultDesc,
    amountCents: amount === null ? null : kesToCents(amount),
    receipt: nonEmptyString(byName.get("MpesaReceiptNumber")),
  };
}

// ---------------------------------------------------------------- gateway

const TOKEN_EXPIRY_MARGIN_MS = 60_000;
const STILL_PROCESSING_CODE = "500.001.1001";

export function createMpesaGateway(
  config: MpesaConfig,
  http: HttpClient,
  now: () => number = Date.now,
): PaymentGateway {
  if (config.callbackToken.length < 16) {
    throw new Error(
      "The M-Pesa callback token must be at least 16 characters.",
    );
  }

  let cached: { token: string; expiresAtMs: number } | null = null;
  let inflight: Promise<string> | null = null;

  async function fetchToken(): Promise<string> {
    const response = await http.request({
      method: "GET",
      url: `${DARAJA_SANDBOX_BASE_URL}/oauth/v1/generate?grant_type=client_credentials`,
      headers: {
        Authorization: `Basic ${btoa(`${config.consumerKey}:${config.consumerSecret}`)}`,
      },
    });
    const json = parseJson(response.body);
    const token = isRecord(json)
      ? nonEmptyString(json["access_token"], 2000)
      : null;
    if (response.status !== 200 || token === null)
      throw new MpesaError("auth_failed");
    const expiresInSeconds =
      (isRecord(json) ? asNumber(json["expires_in"]) : null) ?? 3599;
    cached = { token, expiresAtMs: now() + expiresInSeconds * 1000 };
    return token;
  }

  /** Cached, expiry-aware, and concurrent callers share one in-flight request. */
  async function accessToken(): Promise<string> {
    if (cached !== null && now() < cached.expiresAtMs - TOKEN_EXPIRY_MARGIN_MS)
      return cached.token;
    inflight ??= fetchToken().finally(() => {
      inflight = null;
    });
    return inflight;
  }

  async function authedPost(
    path: string,
    payload: JsonRecord,
  ): Promise<HttpResponse> {
    for (let attempt = 0; ; attempt += 1) {
      const token = await accessToken();
      const response = await http.request({
        method: "POST",
        url: `${DARAJA_SANDBOX_BASE_URL}${path}`,
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      // An early-expired token: drop it and retry exactly once.
      if (response.status === 401 && attempt === 0) {
        cached = null;
        continue;
      }
      return response;
    }
  }

  function passwordFor(timestamp: string): string {
    return btoa(`${config.shortcode}${config.passkey}${timestamp}`);
  }

  return {
    method: "mpesa",
    provider: MPESA_PROVIDER,
    collectsOffline: false,

    normalisePayer: (phone) => normaliseKenyanPhone(phone),

    // M-Pesa takes whole shillings only.
    acceptsAmountCents: (amountCents) =>
      Number.isInteger(amountCents) &&
      amountCents > 0 &&
      amountCents % 100 === 0,

    async initiate(
      order: GatewayOrder,
      attempt: GatewayAttempt,
      payer: GatewayPayer,
    ): Promise<InitiateResult> {
      const phone = normaliseKenyanPhone(payer.phone);
      if (phone === null) throw new MpesaError("bad_phone");
      if (attempt.amountCents % 100 !== 0 || attempt.amountCents <= 0) {
        throw new MpesaError("amount_not_whole");
      }
      const timestamp = darajaTimestamp(now());
      const response = await authedPost("/mpesa/stkpush/v1/processrequest", {
        BusinessShortCode: config.shortcode,
        Password: passwordFor(timestamp),
        Timestamp: timestamp,
        TransactionType: "CustomerPayBillOnline",
        Amount: attempt.amountCents / 100,
        PartyA: phone,
        PartyB: config.shortcode,
        PhoneNumber: phone,
        CallBackURL: `${config.callbackBaseUrl}/api/public/mpesa-callback/${config.callbackToken}`,
        AccountReference: order.id.replace(/-/g, "").slice(0, 12),
        TransactionDesc: "Order payment",
      });
      const json = parseJson(response.body);
      const reference = isRecord(json)
        ? nonEmptyString(json["CheckoutRequestID"])
        : null;
      const accepted = isRecord(json) && String(json["ResponseCode"]) === "0";
      if (response.status !== 200 || !accepted || reference === null) {
        throw new MpesaError("push_rejected");
      }
      return { kind: "prompt_sent", providerReference: reference };
    },

    // Daraja callbacks carry no signature. Authenticity here = the secret path token, then shape.
    parseCallback(request: CallbackRequest): Promise<VerifiedOutcome> {
      return Promise.resolve().then(() => {
        const segments = (() => {
          try {
            return new URL(request.url).pathname
              .split("/")
              .filter((s) => s !== "");
          } catch {
            return [];
          }
        })();
        const given = decodeURIComponentSafe(
          segments[segments.length - 1] ?? "",
        );
        if (
          request.method !== "POST" ||
          !constantTimeEquals(given, config.callbackToken)
        ) {
          throw new CallbackRejectedError("bad_token");
        }
        const parsed = parseStkCallback(request.body);
        const mapped = mapResultCode(parsed.resultCode, parsed.resultDesc);
        if (
          mapped.outcome === "succeeded" &&
          (parsed.amountCents === null || parsed.receipt === null)
        ) {
          // A "success" with no usable amount or receipt cannot be verified. The STK Query fallback decides.
          throw new CallbackRejectedError("malformed");
        }
        return {
          kind: "outcome",
          providerReference: parsed.checkoutRequestId,
          outcome: mapped.outcome,
          amountCents:
            mapped.outcome === "succeeded" ? parsed.amountCents : null,
          currency: mapped.outcome === "succeeded" ? "KES" : null,
          receiptNumber: parsed.receipt,
          failureCode: mapped.failureCode,
          failureMessage: mapped.failureMessage,
        } satisfies VerifiedOutcome;
      });
    },

    async queryStatus(providerReference: string): Promise<StatusQueryResult> {
      const timestamp = darajaTimestamp(now());
      const response = await authedPost("/mpesa/stkpushquery/v1/query", {
        BusinessShortCode: config.shortcode,
        Password: passwordFor(timestamp),
        Timestamp: timestamp,
        CheckoutRequestID: providerReference,
      });
      const json = parseJson(response.body);
      // Daraja answers "still being processed" with an error body, not a ResultCode.
      if (isRecord(json) && json["errorCode"] === STILL_PROCESSING_CODE)
        return { kind: "pending" };
      if (
        response.status !== 200 ||
        !isRecord(json) ||
        String(json["ResponseCode"]) !== "0"
      ) {
        throw new MpesaError("query_failed");
      }
      const code = asNumber(json["ResultCode"]);
      if (code === null || !Number.isInteger(code))
        throw new MpesaError("bad_response");
      const description =
        typeof json["ResultDesc"] === "string" ? json["ResultDesc"] : null;
      return { kind: "outcome", ...mapResultCode(code, description) };
    },
  };
}

function decodeURIComponentSafe(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
