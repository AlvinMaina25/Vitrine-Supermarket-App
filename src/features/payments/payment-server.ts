import { createMiddleware, createServerFn } from "@tanstack/react-start";
import { getRequestHeader } from "@tanstack/react-start/server";
import type { SupabaseClient } from "@supabase/supabase-js";

import { supabase } from "@/lib/supabase/client";
import {
  createServiceClient,
  createUserClient,
} from "@/lib/supabase/server-clients";
import { getServerGatewaysWithCard } from "./card-server";
import type { Database } from "@/lib/supabase/types";
import { parseRecordCodInput, recordCodPayment } from "./record-cod-payment";
import {
  PaymentStartError,
  parseOrderIdInput,
  parseStartPaymentInput,
  readMyOrderPaymentStatus,
  startPayment,
  toClientSafeError,
  type PaymentPorts,
} from "./start-payment";

/**
 * Phase 6H.1 server functions (no UI). Auth is required: the browser sends its Supabase access
 * token as a Bearer header; the server verifies it before doing anything.
 */

/** Attaches the signed-in user's access token to every call. Runs in the browser only. */
const attachAccessToken = createMiddleware({ type: "function" }).client(
  async ({ next }) => {
    const { data } = (await supabase?.auth.getSession()) ?? {
      data: { session: null },
    };
    const token = data.session?.access_token;
    return next(token ? { headers: { Authorization: `Bearer ${token}` } } : {});
  },
);

/** Verifies the token server-side and exposes a client scoped to that user. */
const requireUser = createMiddleware({ type: "function" })
  .middleware([attachAccessToken])
  .server(async ({ next }) => {
    const header = getRequestHeader("authorization");
    const token = header?.startsWith("Bearer ") ? header.slice(7).trim() : "";
    if (!token) throw new PaymentStartError("not_signed_in");

    const userClient = createUserClient(token);
    const { data, error } = await userClient.auth.getUser(token);
    if (error || !data.user) throw new PaymentStartError("not_signed_in");

    // The authenticated user's own email, from this same getUser() call. Never taken from the browser.
    return next({
      context: { userClient, userEmail: data.user.email ?? null },
    });
  });

function toPorts(
  userClient: SupabaseClient<Database>,
  serviceClient: SupabaseClient<Database>,
  userEmail: string | null,
): PaymentPorts {
  return {
    readPayerEmail: () => Promise.resolve(userEmail),
    readMyPayments: (orderId) =>
      userClient.rpc("get_my_order_payments", { p_order_id: orderId }),
    getOrderForPayment: (orderId) =>
      serviceClient.rpc("get_order_for_payment", { p_order_id: orderId }),
    createAttempt: (args) =>
      serviceClient.rpc("create_payment_attempt", {
        p_order_id: args.orderId,
        p_provider: args.provider,
        p_method: args.method,
        p_idempotency_key: args.idempotencyKey,
      }),
    markProcessing: (transactionId, providerReference) =>
      serviceClient.rpc("mark_payment_processing", {
        p_transaction_id: transactionId,
        p_provider_reference: providerReference,
      }),
    recordCod: (orderId, reason) =>
      userClient.rpc("record_cod_payment", {
        p_order_id: orderId,
        p_reason: reason,
      }),
  };
}

/** Logs ids and codes only: never phone numbers, tokens or provider payloads. */
function logFailure(what: string, orderId: string, error: unknown): void {
  const code = error instanceof PaymentStartError ? error.code : "unexpected";
  console.error(`[payments] ${what} failed`, { orderId, code });
}

export const startPaymentFn = createServerFn({ method: "POST" })
  .middleware([requireUser])
  .inputValidator(parseStartPaymentInput)
  .handler(async ({ data, context }) => {
    try {
      // The service client is created only for non-COD work and never leaves this handler.
      const serviceClient = createServiceClient();
      return await startPayment(
        toPorts(context.userClient, serviceClient, context.userEmail),
        data,
        getServerGatewaysWithCard(),
      );
    } catch (error) {
      logFailure("startPayment", data.orderId, error);
      throw toClientSafeError(error);
    }
  });

export const getMyOrderPaymentStatusFn = createServerFn({ method: "GET" })
  .middleware([requireUser])
  .inputValidator(parseOrderIdInput)
  .handler(async ({ data, context }) => {
    try {
      // Read-only and customer-scoped: no service-role client is needed or created.
      const ports = {
        readMyPayments: (orderId: string) =>
          context.userClient.rpc("get_my_order_payments", {
            p_order_id: orderId,
          }),
      };
      return await readMyOrderPaymentStatus(ports, data.orderId);
    } catch (error) {
      logFailure("getMyOrderPaymentStatus", data.orderId, error);
      throw toClientSafeError(error);
    }
  });

/**
 * Phase 19: an admin records that cash was received for a cash-on-delivery order. Uses only the
 * signed-in user's client (no service role): record_cod_payment() is granted to `authenticated`
 * and requires an admin with two-factor sign-in. Expected refusals come back as a result; anything
 * else is logged by code and made generic.
 */
export const recordCodPaymentFn = createServerFn({ method: "POST" })
  .middleware([requireUser])
  .inputValidator(parseRecordCodInput)
  .handler(async ({ data, context }) => {
    try {
      return await recordCodPayment(
        {
          recordCod: (orderId, reason) =>
            context.userClient.rpc("record_cod_payment", {
              p_order_id: orderId,
              p_reason: reason,
            }),
        },
        data,
      );
    } catch (error) {
      logFailure("recordCodPayment", data.orderId, error);
      throw toClientSafeError(error);
    }
  });
