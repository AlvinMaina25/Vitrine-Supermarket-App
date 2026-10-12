import { buildMessage } from "./templates.ts";
import {
  MAX_ATTEMPTS,
  emptySummary,
  type Channel,
  type ClaimedNotification,
  type CompleteOutcome,
  type NotificationProvider,
  type RunSummary,
} from "./types.ts";

/**
 * Phase 7 worker. Pure logic over injected ports: no framework, network, secret or database client.
 * server.ts wires the real ports.
 *
 * Per claimed row:
 *   1. no provider for the channel      -> skipped_not_configured (nothing is looked up, nothing sent)
 *   2. the order is gone                 -> dead
 *   3. no usable address                 -> dead
 *   4. provider.send()                   -> sent (accepted) | failed (retry, backoff) | dead (permanent)
 * 'sent' is reported only when a provider returned an accepted result. Delivery is never simulated.
 *
 * Delivery is at-least-once: if the process dies after a provider accepted a message but before
 * complete_notification ran, the lease expires and the row is sent again.
 */

export interface OrderContext {
  orderNumber: string;
  status: string;
}

export interface WorkerPorts {
  /** claim_notifications, service role. */
  claim(limit: number): Promise<ClaimedNotification[]>;
  /** complete_notification, service role. Throws if the database refuses. */
  complete(
    id: string,
    outcome: CompleteOutcome,
    error: string | null,
  ): Promise<void>;
  /** Service-role read of the order number and current status, or null if the order is gone. */
  loadOrder(orderId: string): Promise<OrderContext | null>;
  /** Service-role lookup of the address for this channel at send time, or null if there is none. */
  resolveAddress(userId: string, channel: Channel): Promise<string | null>;
  /** The configured provider, or null. */
  getProvider(channel: Channel): NotificationProvider | null;
}

/** Event codes and counts only. Never an address, a message body or a provider response. */
export type WorkerLog = (
  event: string,
  fields: Record<string, string | number | null>,
) => void;

export interface RunOptions {
  limit: number;
  log: WorkerLog;
}

async function finish(
  ports: WorkerPorts,
  log: WorkerLog,
  row: ClaimedNotification,
  outcome: CompleteOutcome,
  error: string | null,
): Promise<boolean> {
  try {
    await ports.complete(row.id, outcome, error);
    return true;
  } catch {
    // The row stays 'processing' and is reclaimed when its lease expires.
    log("notification_complete_failed", { id: row.id, outcome });
    return false;
  }
}

export async function run(
  ports: WorkerPorts,
  options: RunOptions,
): Promise<RunSummary> {
  const summary = emptySummary();
  const rows = await ports.claim(options.limit);
  summary.claimed = rows.length;

  for (const row of rows) {
    let outcome: CompleteOutcome;
    let error: string | null = null;

    try {
      const provider = ports.getProvider(row.channel);
      if (provider === null) {
        outcome = "skipped_not_configured";
      } else if (row.orderId === null) {
        outcome = "dead";
        error = "missing_order_id";
      } else {
        const order = await ports.loadOrder(row.orderId);
        if (order === null) {
          outcome = "dead";
          error = "order_not_found";
        } else {
          const address = await ports.resolveAddress(row.userId, row.channel);
          if (address === null) {
            outcome = "dead";
            error = "no_address";
          } else {
            const message = buildMessage(
              row.eventType,
              row.channel,
              { orderNumber: order.orderNumber, orderStatus: order.status },
              address,
            );
            const result = await provider.send(message);
            if (result.kind === "sent") {
              outcome = "sent";
            } else {
              outcome = result.kind === "retry" ? "failed" : "dead";
              error = result.code;
            }
          }
        }
      }
    } catch {
      // A bug or a lookup error: retry with backoff (it becomes dead after 5 attempts).
      outcome = "failed";
      error = "worker_error";
    }

    const recorded = await finish(ports, options.log, row, outcome, error);
    if (!recorded) continue;
    if (outcome === "sent") summary.sent += 1;
    else if (outcome === "skipped_not_configured")
      summary.skippedNotConfigured += 1;
    else if (outcome === "failed" && row.attempts < MAX_ATTEMPTS)
      summary.failed += 1;
    else summary.dead += 1;
  }

  options.log("notifications_run", { ...summary });
  return summary;
}
