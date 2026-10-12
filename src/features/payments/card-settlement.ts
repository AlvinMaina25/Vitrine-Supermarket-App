import { CardCallbackRejectedError } from "../checkout/providers/flutterwave.ts";
import {
  requireRecord,
  requireString,
  requireWholeNumber,
} from "../admin/customer-parse.ts";
import type { RpcResult } from "./start-payment.ts";
import type { SettlementDeps } from "./mpesa-settlement.ts";

/**
 * Phase 6H.3: turns a verified Flutterwave card webhook into a database write. Pure logic over
 * injected ports (the same port shapes as 6H.2): no framework, network or secret. The ONLY thing
 * that can mark a payment succeeded is apply_payment_outcome() from here, service role, after the
 * gateway has checked the secret hash and re-queried Flutterwave.
 *
 * Replay-safe: an attempt that is no longer pending/processing is never written again, so the same
 * webhook twice changes nothing. Logs carry ids, codes and statuses only.
 */

export interface CardWebhookReply {
  status: 200 | 401 | 500;
  body: Record<string, string>;
}

const OK: CardWebhookReply = { status: 200, body: { status: "ok" } };
const UNAUTHORISED: CardWebhookReply = {
  status: 401,
  body: { error: "unauthorised" },
};
/** Retryable: Flutterwave re-sends a webhook that did not get a 200. */
const RETRY: CardWebhookReply = { status: 500, body: { error: "retry" } };

interface AttemptRow {
  id: string;
  provider: string;
  amountCents: number;
  currency: string;
  status: string;
}

function parseAttemptRow(data: unknown): AttemptRow {
  const r = requireRecord(data, "The payment");
  return {
    id: requireString(r, "id", "The payment"),
    provider: requireString(r, "provider", "The payment"),
    amountCents: requireWholeNumber(r, "amount_cents", "The payment"),
    currency: requireString(r, "currency", "The payment"),
    status: requireString(r, "status", "The payment"),
  };
}

const OPEN = new Set(["pending", "processing"]);

function errorDetail(result: RpcResult): string {
  return result.error?.details ?? result.error?.code ?? "error";
}

type ApplyResult = "changed" | "noop" | "domain_error" | "transient_error";

async function apply(
  deps: SettlementDeps,
  event: string,
  row: AttemptRow,
  args: {
    outcome: "succeeded" | "failed" | "cancelled" | "expired";
    providerReference: string;
    amountCents: number | null;
    currency: string | null;
    failureCode: string | null;
    failureMessage: string | null;
  },
): Promise<ApplyResult> {
  const result = await deps.ports.applyOutcome({
    transactionId: row.id,
    ...args,
  });
  if (result.error) {
    // A database error code (invalid_transition, order_already_paid...) will never succeed on retry.
    // No code at all means the call itself failed, which is worth retrying.
    const permanent =
      result.error.details !== undefined && result.error.details !== null;
    deps.log(event, {
      transactionId: row.id,
      applied: "error",
      detail: errorDetail(result),
    });
    return permanent ? "domain_error" : "transient_error";
  }
  const changed = requireRecord(result.data, "The payment")["changed"] === true;
  deps.log(event, {
    transactionId: row.id,
    outcome: args.outcome,
    applied: changed ? "changed" : "noop",
  });
  return changed ? "changed" : "noop";
}

export async function handleCardWebhook(
  deps: SettlementDeps,
  request: {
    method: string;
    url: string;
    headers: Readonly<Record<string, string>>;
    body: string;
  },
): Promise<CardWebhookReply> {
  let verified;
  try {
    verified = await deps.gateway.parseCallback(request);
  } catch (error) {
    if (error instanceof CardCallbackRejectedError) {
      deps.log("card.webhook.rejected", { reason: error.reason });
      if (error.reason === "bad_signature") return UNAUTHORISED;
      if (error.reason === "verify_unavailable") return RETRY;
      return OK;
    }
    deps.log("card.webhook.rejected", { reason: "unexpected" });
    return RETRY;
  }
  if (verified.kind === "ignored") return OK;

  try {
    const found = await deps.ports.findByReference(
      deps.gateway.provider,
      verified.providerReference,
    );
    if (found.error) {
      deps.log("card.webhook.lookup_failed", { detail: errorDetail(found) });
      return RETRY;
    }
    // The reference is our attempt id and is stored before the customer is redirected, so an
    // unknown one is not ours (or not this provider's): acknowledge and change nothing.
    if (found.data === null || found.data === undefined) {
      deps.log("card.webhook.unknown_reference", {
        reference: verified.providerReference,
      });
      return OK;
    }
    const row = parseAttemptRow(found.data);
    if (row.provider !== deps.gateway.provider) return OK;

    if (!OPEN.has(row.status)) {
      deps.log("card.webhook.replay", {
        transactionId: row.id,
        status: row.status,
      });
      if (verified.outcome === "succeeded" && row.status !== "succeeded") {
        // Money was taken for an attempt we had already closed. Nothing is changed; staff must review.
        deps.log("card.webhook.late_success_needs_review", {
          transactionId: row.id,
          status: row.status,
        });
      }
      return OK;
    }

    if (verified.outcome === "succeeded") {
      // The verified amount and currency must equal the attempt's, which came from the database order.
      if (
        verified.amountCents !== row.amountCents ||
        verified.currency !== row.currency
      ) {
        const result = await apply(deps, "card.webhook.amount_mismatch", row, {
          outcome: "failed",
          providerReference: verified.providerReference,
          amountCents: null,
          currency: null,
          failureCode:
            verified.currency !== row.currency
              ? "currency_mismatch"
              : "amount_mismatch",
          failureMessage: `Reported ${String(verified.amountCents)} ${String(verified.currency)} does not match the attempt.`,
        });
        return result === "transient_error" ? RETRY : OK;
      }
      const result = await apply(deps, "card.webhook.applied", row, {
        outcome: "succeeded",
        providerReference: verified.providerReference,
        amountCents: row.amountCents,
        currency: row.currency,
        failureCode: null,
        failureMessage: null,
      });
      return result === "transient_error" ? RETRY : OK;
    }

    const result = await apply(deps, "card.webhook.applied", row, {
      outcome: verified.outcome,
      providerReference: verified.providerReference,
      amountCents: null,
      currency: null,
      failureCode: verified.failureCode,
      failureMessage: verified.failureMessage,
    });
    return result === "transient_error" ? RETRY : OK;
  } catch {
    deps.log("card.webhook.error", { detail: "unexpected" });
    return RETRY;
  }
}
