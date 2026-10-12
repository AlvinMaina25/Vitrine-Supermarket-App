/// <reference types="node" />
import { GATEWAYS } from "../checkout/gateways.ts";
import type { PaymentGateway } from "../checkout/payment-providers.ts";
import { fetchHttpClient } from "../checkout/providers/http.ts";
import {
  constantTimeEquals,
  createMpesaGateway,
  type MpesaConfig,
} from "../checkout/providers/mpesa.ts";
import { createServiceClient } from "../../lib/supabase/server-clients.ts";
import {
  handleMpesaCallback,
  reconcileStuckAttempts,
  type SettlementDeps,
  type SettlementPorts,
} from "./mpesa-settlement.ts";

/**
 * Server wiring for M-Pesa (6H.2). Reads server-only env vars (names in .env.example), builds the
 * Daraja gateway once per process (so the OAuth token cache survives between requests), and adapts
 * the service-role Supabase client to the settlement ports. Import from server code only.
 */

function loadMpesaConfig(): MpesaConfig | null {
  const env = process.env;
  const consumerKey = env["MPESA_CONSUMER_KEY"];
  const consumerSecret = env["MPESA_CONSUMER_SECRET"];
  const shortcode = env["MPESA_SHORTCODE"];
  const passkey = env["MPESA_PASSKEY"];
  const callbackBaseUrl = env["MPESA_CALLBACK_BASE_URL"];
  const callbackToken = env["MPESA_CALLBACK_TOKEN"];
  if (
    !consumerKey ||
    !consumerSecret ||
    !shortcode ||
    !passkey ||
    !callbackBaseUrl ||
    !callbackToken ||
    callbackToken.length < 16
  ) {
    return null;
  }
  return {
    consumerKey,
    consumerSecret,
    shortcode,
    passkey,
    callbackBaseUrl: callbackBaseUrl.replace(/\/+$/, ""),
    callbackToken,
  };
}

let memoised: PaymentGateway | null | undefined;

/** The Daraja gateway, or null when its env vars are not all set (M-Pesa then stays "not available"). */
export function getMpesaGateway(): PaymentGateway | null {
  if (memoised === undefined) {
    const config = loadMpesaConfig();
    memoised =
      config === null ? null : createMpesaGateway(config, fetchHttpClient);
  }
  return memoised;
}

/** Every gateway that can be used right now. */
export function getServerGateways(): readonly PaymentGateway[] {
  const mpesa = getMpesaGateway();
  return mpesa === null ? GATEWAYS : [...GATEWAYS, mpesa];
}

function toSettlementPorts(): SettlementPorts {
  const service = createServiceClient();
  const columns =
    "id, provider, method, amount_cents, currency, status, provider_reference";
  return {
    findByReference: (provider, providerReference) =>
      service
        .from("payment_transactions")
        .select(columns)
        .eq("provider", provider)
        .eq("provider_reference", providerReference)
        .maybeSingle(),
    listProcessing: (provider, updatedBeforeIso, limit) =>
      service
        .from("payment_transactions")
        .select(columns)
        .eq("provider", provider)
        .eq("status", "processing")
        .lt("updated_at", updatedBeforeIso)
        .order("updated_at", { ascending: true })
        .limit(limit),
    applyOutcome: (args) =>
      service.rpc("apply_payment_outcome", {
        p_transaction_id: args.transactionId,
        p_outcome: args.outcome,
        p_provider_reference: args.providerReference,
        p_amount_cents: args.amountCents,
        p_currency: args.currency,
        p_failure_code: args.failureCode,
        p_failure_message: args.failureMessage,
      }),
  };
}

function deps(gateway: PaymentGateway): SettlementDeps {
  return {
    gateway,
    ports: toSettlementPorts(),
    log: (event, fields) => console.info(`[payments] ${event}`, fields),
  };
}

const MAX_BODY_CHARS = 20_000;
const NOT_FOUND = () => Response.json({ error: "not_found" }, { status: 404 });

/** POST /api/public/mpesa-callback/$token. Daraja gets HTTP 200 + the ack body, except a wrong token (404). */
export async function handleMpesaCallbackRequest(
  request: Request,
): Promise<Response> {
  const gateway = getMpesaGateway();
  if (gateway === null) return NOT_FOUND();
  const body = await request.text();
  const reply = await handleMpesaCallback(deps(gateway), {
    method: request.method,
    url: request.url,
    headers: {},
    // An oversized body is not a Daraja callback; it fails parsing and is acked without processing.
    body: body.length > MAX_BODY_CHARS ? "" : body,
  });
  return Response.json(reply.body, { status: reply.status });
}

/** POST /api/public/mpesa-reconcile/$token. Runs the STK Query fallback for stuck attempts. */
export async function handleMpesaReconcileRequest(
  request: Request,
): Promise<Response> {
  const gateway = getMpesaGateway();
  const expected = process.env["MPESA_RECONCILE_TOKEN"];
  if (
    gateway === null ||
    !expected ||
    expected.length < 16 ||
    request.method !== "POST"
  ) {
    return NOT_FOUND();
  }
  const segments = new URL(request.url).pathname
    .split("/")
    .filter((s) => s !== "");
  if (
    !constantTimeEquals(
      decodeURIComponent(segments[segments.length - 1] ?? ""),
      expected,
    )
  ) {
    return NOT_FOUND();
  }
  const summary = await reconcileStuckAttempts(deps(gateway), {
    olderThanSeconds: 120,
    limit: 25,
    nowMs: Date.now(),
  });
  return Response.json(summary);
}
