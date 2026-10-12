import type { HttpClient, HttpResponse } from "../checkout/providers/http.ts";
import type {
  Channel,
  NotificationProvider,
  OutboundMessage,
  SendResult,
} from "./types.ts";

/**
 * Phase 7 provider registry and adapters.
 *
 * The registry returns null ("not configured") unless EVERY required env var for that channel is
 * present and non-empty. Secrets are read from server-side env only (never VITE_*), held only in
 * the adapter's closure, and never put in a log line, an error code or a return value.
 *
 * An adapter reports 'sent' ONLY when the provider's own response accepted the message. A failure
 * is reported as a short code (an HTTP status or a fixed word), never the response body.
 *
 * NOT VERIFIED against the live providers: the request shapes follow each provider's public
 * documentation but nothing here has been called. Test against the provider's sandbox first.
 */

export type NotificationEnv = Readonly<Record<string, string | undefined>>;

function present(env: NotificationEnv, name: string): string | null {
  const value = env[name];
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** 2xx accepted; throttling and server errors retry; any other 4xx is the request's fault. */
export function classifyStatus(status: number): SendResult {
  if (status >= 200 && status < 300) return { kind: "sent" };
  if (status === 408 || status === 429 || status >= 500)
    return { kind: "retry", code: `http_${status}` };
  return { kind: "permanent", code: `http_${status}` };
}

async function post(
  http: HttpClient,
  url: string,
  headers: Record<string, string>,
  body: string,
): Promise<HttpResponse | null> {
  try {
    return await http.request({ method: "POST", url, headers, body });
  } catch {
    return null; // timeout / DNS / reset: the message may not have left, so it is retried
  }
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function field(value: unknown, key: string): unknown {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)[key]
    : undefined;
}

// ---- email: Resend -------------------------------------------------------------------------------
const RESEND_URL = "https://api.resend.com/emails";

function createResendProvider(
  apiKey: string,
  from: string,
  http: HttpClient,
): NotificationProvider {
  return {
    channel: "email",
    name: "resend",
    async send(message: OutboundMessage): Promise<SendResult> {
      const response = await post(
        http,
        RESEND_URL,
        {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        JSON.stringify({
          from,
          to: [message.to],
          subject: message.subject ?? "",
          text: message.body,
        }),
      );
      if (response === null) return { kind: "retry", code: "network_error" };
      return classifyStatus(response.status);
    },
  };
}

// ---- sms: Africa's Talking ---------------------------------------------------------------------
const AT_URL = "https://api.africastalking.com/version1/messaging";

function createAfricasTalkingProvider(
  username: string,
  apiKey: string,
  senderId: string | null,
  http: HttpClient,
): NotificationProvider {
  return {
    channel: "sms",
    name: "africastalking",
    async send(message: OutboundMessage): Promise<SendResult> {
      const form = new URLSearchParams({
        username,
        to: message.to,
        message: message.body,
      });
      if (senderId !== null) form.set("from", senderId);
      const response = await post(
        http,
        AT_URL,
        {
          apiKey,
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        form.toString(),
      );
      if (response === null) return { kind: "retry", code: "network_error" };
      const verdict = classifyStatus(response.status);
      if (verdict.kind !== "sent") return verdict;
      // HTTP 2xx is not enough here: the per-recipient status says whether it was accepted.
      const data = parseJson(response.body);
      const recipients = field(field(data, "SMSMessageData"), "Recipients");
      const first: unknown = Array.isArray(recipients)
        ? recipients[0]
        : undefined;
      return field(first, "status") === "Success"
        ? { kind: "sent" }
        : { kind: "retry", code: "sms_not_accepted" };
    },
  };
}

// ---- whatsapp: Meta Cloud API (approved template, one body variable) --------------------------
const WHATSAPP_VERSION = "v21.0";

function createWhatsAppProvider(
  accessToken: string,
  phoneNumberId: string,
  templateName: string,
  language: string,
  http: HttpClient,
): NotificationProvider {
  return {
    channel: "whatsapp",
    name: "whatsapp_cloud",
    async send(message: OutboundMessage): Promise<SendResult> {
      const response = await post(
        http,
        `https://graph.facebook.com/${WHATSAPP_VERSION}/${encodeURIComponent(phoneNumberId)}/messages`,
        {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        JSON.stringify({
          messaging_product: "whatsapp",
          to: message.to.replace(/^\+/, ""),
          type: "template",
          template: {
            name: templateName,
            language: { code: language },
            components: [
              {
                type: "body",
                parameters: [{ type: "text", text: message.body }],
              },
            ],
          },
        }),
      );
      if (response === null) return { kind: "retry", code: "network_error" };
      const verdict = classifyStatus(response.status);
      if (verdict.kind !== "sent") return verdict;
      const messages = field(parseJson(response.body), "messages");
      const accepted =
        Array.isArray(messages) && typeof field(messages[0], "id") === "string";
      return accepted
        ? { kind: "sent" }
        : { kind: "retry", code: "whatsapp_not_accepted" };
    },
  };
}

/** Env var NAMES per channel. Values are secrets: they live in the host's env, nowhere else. */
export const PROVIDER_ENV = {
  email: ["RESEND_API_KEY", "NOTIFY_EMAIL_FROM"],
  sms: ["AT_USERNAME", "AT_API_KEY"],
  whatsapp: [
    "WHATSAPP_ACCESS_TOKEN",
    "WHATSAPP_PHONE_NUMBER_ID",
    "WHATSAPP_TEMPLATE_NAME",
  ],
} as const satisfies Readonly<Record<Channel, readonly string[]>>;

/** The provider for a channel, or null when it is not (fully) configured. Never throws. */
export function getProvider(
  channel: Channel,
  env: NotificationEnv,
  http: HttpClient,
): NotificationProvider | null {
  switch (channel) {
    case "email": {
      const apiKey = present(env, "RESEND_API_KEY");
      const from = present(env, "NOTIFY_EMAIL_FROM");
      return apiKey !== null && from !== null
        ? createResendProvider(apiKey, from, http)
        : null;
    }
    case "sms": {
      const username = present(env, "AT_USERNAME");
      const apiKey = present(env, "AT_API_KEY");
      return username !== null && apiKey !== null
        ? createAfricasTalkingProvider(
            username,
            apiKey,
            present(env, "AT_SENDER_ID"),
            http,
          )
        : null;
    }
    case "whatsapp": {
      const token = present(env, "WHATSAPP_ACCESS_TOKEN");
      const phoneNumberId = present(env, "WHATSAPP_PHONE_NUMBER_ID");
      const template = present(env, "WHATSAPP_TEMPLATE_NAME");
      return token !== null && phoneNumberId !== null && template !== null
        ? createWhatsAppProvider(
            token,
            phoneNumberId,
            template,
            present(env, "WHATSAPP_TEMPLATE_LANG") ?? "en",
            http,
          )
        : null;
    }
  }
}
