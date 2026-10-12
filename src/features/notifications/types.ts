import {
  nullableString,
  requireArray,
  requireRecord,
  requireString,
  requireWholeNumber,
  type JsonRecord,
} from "../admin/customer-parse.ts";

/**
 * Phase 7 notifications: shared types and the parsers for what the database returns. Pure, no
 * runtime imports beyond the shared guards, so it runs under `node --test`. The RPCs return
 * `jsonb`, so every field is checked here instead of being cast.
 */

export const EVENT_TYPES = [
  "order_created",
  "payment_succeeded",
  "payment_failed",
  "order_status_changed",
  "order_delivered",
  "order_refunded",
] as const;
export type EventType = (typeof EVENT_TYPES)[number];

export const CHANNELS = ["email", "sms", "whatsapp"] as const;
export type Channel = (typeof CHANNELS)[number];

export const OUTBOX_STATUSES = [
  "pending",
  "processing",
  "sent",
  "failed",
  "skipped_not_configured",
  "dead",
] as const;
export type OutboxStatus = (typeof OUTBOX_STATUSES)[number];

/** Mirrors the database: the 5th failed attempt becomes 'dead'. */
export const MAX_ATTEMPTS = 5;

/** What the worker may report back to complete_notification(). */
export type CompleteOutcome =
  "sent" | "failed" | "skipped_not_configured" | "dead";

/** One claimed row. Ids only: no address, no name, no amount. */
export interface ClaimedNotification {
  id: string;
  eventType: EventType;
  entityId: string;
  userId: string;
  channel: Channel;
  orderId: string | null;
  attempts: number;
}

/** The message as handed to a provider. `to` exists only in memory, only for one send. */
export interface OutboundMessage {
  to: string;
  subject: string | null;
  body: string;
}

/** What a provider tells us. 'sent' means the provider ACCEPTED the message, nothing less. */
export type SendResult =
  | { kind: "sent" }
  | { kind: "retry"; code: string }
  | { kind: "permanent"; code: string };

export interface NotificationProvider {
  readonly channel: Channel;
  readonly name: string;
  send(message: OutboundMessage): Promise<SendResult>;
}

function oneOf<T extends string>(
  values: readonly T[],
  value: string,
  what: string,
): T {
  const match = values.find((candidate) => candidate === value);
  if (match === undefined) {
    throw new Error(`${what} returned an unexpected response.`);
  }
  return match;
}

function orderIdFromPayload(payload: JsonRecord): string | null {
  return nullableString(payload, "order_id", "claim_notifications");
}

/** Parses the jsonb array claim_notifications() returns. Throws on any malformed row. */
export function parseClaimedNotifications(
  data: unknown,
): ClaimedNotification[] {
  return requireArray(data, "claim_notifications").map((item) => {
    const row = requireRecord(item, "claim_notifications");
    return {
      id: requireString(row, "id", "claim_notifications"),
      eventType: oneOf(
        EVENT_TYPES,
        requireString(row, "event_type", "claim_notifications"),
        "claim_notifications",
      ),
      entityId: requireString(row, "entity_id", "claim_notifications"),
      userId: requireString(row, "user_id", "claim_notifications"),
      channel: oneOf(
        CHANNELS,
        requireString(row, "channel", "claim_notifications"),
        "claim_notifications",
      ),
      orderId: orderIdFromPayload(
        requireRecord(row["payload"], "claim_notifications"),
      ),
      attempts: requireWholeNumber(row, "attempts", "claim_notifications"),
    };
  });
}

/** Summary of one worker run. Counts only. */
export interface RunSummary {
  claimed: number;
  sent: number;
  skippedNotConfigured: number;
  failed: number;
  dead: number;
}

export function emptySummary(): RunSummary {
  return { claimed: 0, sent: 0, skippedNotConfigured: 0, failed: 0, dead: 0 };
}
