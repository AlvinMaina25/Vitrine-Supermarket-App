/// <reference types="node" />
import { fetchHttpClient } from "../checkout/providers/http.ts";
import {
  constantTimeEquals,
  normaliseKenyanPhone,
} from "../checkout/providers/mpesa.ts";
import { createServiceClient } from "../../lib/supabase/server-clients.ts";
import { getProvider } from "./providers.ts";
import {
  parseClaimedNotifications,
  type Channel,
  type CompleteOutcome,
} from "./types.ts";
import { run, type WorkerPorts } from "./worker.ts";

/**
 * Server wiring for the notification worker (Phase 7). Import from server code only.
 *
 * Reads server-side env only: SUPABASE_SERVICE_ROLE_KEY, NOTIFICATIONS_RUN_TOKEN and the provider
 * variables listed in providers.ts. None is a VITE_* name; none is logged or returned.
 */

const NOT_FOUND = () => Response.json({ error: "not_found" }, { status: 404 });
const BATCH_LIMIT = 20;

function createPorts(): WorkerPorts {
  const service = createServiceClient();
  return {
    async claim(limit) {
      const { data, error } = await service.rpc("claim_notifications", {
        p_limit: limit,
      });
      if (error) throw new Error("claim_notifications failed.");
      return parseClaimedNotifications(data);
    },
    async complete(
      id: string,
      outcome: CompleteOutcome,
      errorCode: string | null,
    ) {
      const { error } = await service.rpc("complete_notification", {
        p_id: id,
        p_outcome: outcome,
        p_error: errorCode,
      });
      if (error) throw new Error("complete_notification failed.");
    },
    async loadOrder(orderId) {
      const { data, error } = await service
        .from("orders")
        .select("order_number, status")
        .eq("id", orderId)
        .maybeSingle();
      if (error) throw new Error("order lookup failed.");
      return data === null
        ? null
        : { orderNumber: data.order_number, status: data.status };
    },
    async resolveAddress(userId: string, channel: Channel) {
      if (channel === "email") {
        const { data, error } = await service.auth.admin.getUserById(userId);
        if (error) throw new Error("address lookup failed.");
        const email = data.user.email;
        return typeof email === "string" && email.trim() !== ""
          ? email.trim()
          : null;
      }
      const { data, error } = await service
        .from("profiles")
        .select("phone")
        .eq("id", userId)
        .maybeSingle();
      if (error) throw new Error("address lookup failed.");
      const normalised = normaliseKenyanPhone(data?.phone ?? null);
      return normalised === null ? null : `+${normalised}`;
    },
    getProvider: (channel) =>
      getProvider(channel, process.env, fetchHttpClient),
  };
}

/** POST /api/public/notifications-run/$token. Drains one batch of the outbox. */
export async function handleNotificationsRunRequest(
  request: Request,
): Promise<Response> {
  const expected = process.env["NOTIFICATIONS_RUN_TOKEN"];
  if (!expected || expected.length < 16 || request.method !== "POST")
    return NOT_FOUND();
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

  try {
    const summary = await run(createPorts(), {
      limit: BATCH_LIMIT,
      log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
    });
    return Response.json(summary);
  } catch {
    // No detail on purpose: the cause may mention configuration.
    return Response.json({ error: "run_failed" }, { status: 500 });
  }
}
