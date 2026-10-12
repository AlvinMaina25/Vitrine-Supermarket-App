/// <reference types="node" />
import type { PaymentGateway } from "../checkout/payment-providers.ts";
import {
  FLUTTERWAVE_HASH_HEADER,
  createFlutterwaveCardGateway,
  type FlutterwaveConfig,
} from "../checkout/providers/flutterwave.ts";
import { fetchHttpClient } from "../checkout/providers/http.ts";
import { createServiceClient } from "../../lib/supabase/server-clients.ts";
import { handleCardWebhook } from "./card-settlement.ts";
import { getServerGateways } from "./mpesa-server.ts";
import type { SettlementDeps, SettlementPorts } from "./mpesa-settlement.ts";

/**
 * Server wiring for card payments (6H.3, Flutterwave, test keys only). Reads server-only env vars
 * (names in .env.example), builds the gateway once per process, and adapts the service-role
 * Supabase client to the settlement ports. Import from server code only. Never logs a key,
 * hash, header or body.
 */

/** Flutterwave v3 test secret keys start with this. There is deliberately no live-key switch in 6H. */
const TEST_KEY_PREFIX = "FLWSECK_TEST-";

function loadCardConfig(): FlutterwaveConfig | null {
  const env = process.env;
  const secretKey = env["CARD_PROVIDER_SECRET_KEY"];
  const webhookSecret = env["CARD_WEBHOOK_SECRET"];
  const returnBaseUrl = env["CARD_RETURN_BASE_URL"];
  if (
    !secretKey ||
    !secretKey.startsWith(TEST_KEY_PREFIX) ||
    !webhookSecret ||
    webhookSecret.length < 16 ||
    !returnBaseUrl ||
    !returnBaseUrl.startsWith("https://")
  ) {
    return null;
  }
  return {
    secretKey,
    webhookSecret,
    returnBaseUrl: returnBaseUrl.replace(/\/+$/, ""),
  };
}

let memoised: PaymentGateway | null | undefined;

/** The card gateway, or null when its env vars are missing or not test-mode (card then stays "not available"). */
export function getCardGateway(): PaymentGateway | null {
  if (memoised === undefined) {
    const config = loadCardConfig();
    memoised =
      config === null
        ? null
        : createFlutterwaveCardGateway(config, fetchHttpClient);
  }
  return memoised;
}

/** Every gateway that can be used right now: cash, M-Pesa when configured, card when configured. */
export function getServerGatewaysWithCard(): readonly PaymentGateway[] {
  const card = getCardGateway();
  const others = getServerGateways();
  return card === null ? others : [...others, card];
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
    // Not used by the card webhook (no reconcile job in 6H.3).
    listProcessing: () => Promise.resolve({ data: [], error: null }),
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

/**
 * POST /api/public/card-webhook. A missing header is refused before the body is even read; a wrong
 * one is refused before it is parsed. Handled and ignored events get 200 so Flutterwave stops retrying.
 */
export async function handleCardWebhookRequest(
  request: Request,
): Promise<Response> {
  const gateway = getCardGateway();
  if (gateway === null)
    return Response.json({ error: "not_found" }, { status: 404 });
  if (
    request.method !== "POST" ||
    !request.headers.get(FLUTTERWAVE_HASH_HEADER)
  ) {
    return Response.json({ error: "unauthorised" }, { status: 401 });
  }
  const body = await request.text();
  const reply = await handleCardWebhook(deps(gateway), {
    method: request.method,
    url: request.url,
    headers: {
      [FLUTTERWAVE_HASH_HEADER]:
        request.headers.get(FLUTTERWAVE_HASH_HEADER) ?? "",
    },
    // An oversized body is not a Flutterwave webhook; it fails parsing and is acknowledged unchanged.
    body: body.length > MAX_BODY_CHARS ? "" : body,
  });
  return Response.json(reply.body, { status: reply.status });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * GET /api/public/card-return/$orderId. Where Flutterwave sends the customer back. It never reads
 * the query string (status, transaction_id) and never marks anything paid: it only redirects to the
 * existing order page, where the status is read through get_my_order_payments.
 */
export function handleCardReturnRequest(orderId: string): Response {
  const base = process.env["CARD_RETURN_BASE_URL"]?.replace(/\/+$/, "");
  if (!base || !base.startsWith("https://"))
    return Response.json({ error: "not_found" }, { status: 404 });
  const path = UUID.test(orderId) ? `/account/orders/${orderId}` : "/";
  return new Response(null, {
    status: 302,
    headers: { Location: `${base}${path}` },
  });
}
