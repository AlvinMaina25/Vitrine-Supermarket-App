import type {
  FinalOutcome,
  PaymentGateway,
} from "../checkout/payment-providers.ts";
import { CallbackRejectedError } from "../checkout/providers/mpesa.ts";
import {
  requireRecord,
  requireString,
  requireWholeNumber,
} from "../admin/customer-parse.ts";
import type { RpcResult } from "./start-payment.ts";

/**
 * Phase 6H.2: turns a verified M-Pesa outcome (callback, or STK Query fallback) into a database
 * write. Pure logic over injected ports: no framework, network or secret. The ONLY thing that can
 * mark a payment succeeded is apply_payment_outcome(), called from here with the service-role port.
 *
 * Replay-safe: an attempt that is no longer pending/processing is never written again, so the same
 * callback twice (or a late contradictory one) changes nothing.
 */

export interface ApplyOutcomeArgs {
  transactionId: string;
  outcome: FinalOutcome;
  providerReference: string;
  amountCents: number | null;
  currency: string | null;
  failureCode: string | null;
  failureMessage: string | null;
}

export interface SettlementPorts {
  /** Service-role table read; data is one row or null. */
  findByReference(
    provider: string,
    providerReference: string,
  ): PromiseLike<RpcResult>;
  /** Service-role table read; data is an array of rows, oldest first. */
  listProcessing(
    provider: string,
    updatedBeforeIso: string,
    limit: number,
  ): PromiseLike<RpcResult>;
  /** apply_payment_outcome, service role. */
  applyOutcome(args: ApplyOutcomeArgs): PromiseLike<RpcResult>;
}

/** Ids, codes and statuses only. Never phones, tokens, URLs or provider payloads. */
export type SettlementLog = (
  event: string,
  fields: Record<string, string | number | null>,
) => void;

export interface SettlementDeps {
  gateway: PaymentGateway;
  ports: SettlementPorts;
  log: SettlementLog;
}

/** The body Daraja expects back. Always sent with HTTP 200 (except a wrong path token). */
export const DARAJA_ACK = { ResultCode: 0, ResultDesc: "Accepted" } as const;

export interface CallbackReply {
  status: 200 | 404;
  body: unknown;
}

// ---------------------------------------------------------------- row parsing

interface AttemptRow {
  id: string;
  provider: string;
  amountCents: number;
  currency: string;
  status: string;
  providerReference: string | null;
}

function parseAttemptRow(data: unknown): AttemptRow {
  const r = requireRecord(data, "The payment");
  const ref = r["provider_reference"];
  return {
    id: requireString(r, "id", "The payment"),
    provider: requireString(r, "provider", "The payment"),
    amountCents: requireWholeNumber(r, "amount_cents", "The payment"),
    currency: requireString(r, "currency", "The payment"),
    status: requireString(r, "status", "The payment"),
    providerReference: typeof ref === "string" ? ref : null,
  };
}

const OPEN = new Set(["pending", "processing"]);

function errorDetail(result: RpcResult): string {
  return result.error?.details ?? result.error?.code ?? "error";
}

// ---------------------------------------------------------------- apply

async function apply(
  deps: SettlementDeps,
  event: string,
  row: AttemptRow,
  args: Omit<ApplyOutcomeArgs, "transactionId">,
): Promise<"changed" | "noop" | "error"> {
  const result = await deps.ports.applyOutcome({
    transactionId: row.id,
    ...args,
  });
  if (result.error) {
    // invalid_transition / order_already_paid etc. land here: logged, never retried or surfaced.
    deps.log(event, {
      transactionId: row.id,
      applied: "error",
      detail: errorDetail(result),
    });
    return "error";
  }
  const changed = requireRecord(result.data, "The payment")["changed"] === true;
  deps.log(event, {
    transactionId: row.id,
    outcome: args.outcome,
    applied: changed ? "changed" : "noop",
  });
  return changed ? "changed" : "noop";
}

// ---------------------------------------------------------------- callback

export async function handleMpesaCallback(
  deps: SettlementDeps,
  request: {
    method: string;
    url: string;
    headers: Readonly<Record<string, string>>;
    body: string;
  },
): Promise<CallbackReply> {
  const ack: CallbackReply = { status: 200, body: DARAJA_ACK };

  let verified;
  try {
    verified = await deps.gateway.parseCallback(request);
  } catch (error) {
    if (
      error instanceof CallbackRejectedError &&
      error.reason === "bad_token"
    ) {
      // Not Daraja. Reveal nothing and process nothing.
      deps.log("mpesa.callback.rejected", { reason: "bad_token" });
      return { status: 404, body: { error: "not_found" } };
    }
    deps.log("mpesa.callback.rejected", { reason: "malformed" });
    return ack;
  }
  if (verified.kind === "ignored") return ack;

  try {
    const found = await deps.ports.findByReference(
      deps.gateway.provider,
      verified.providerReference,
    );
    if (found.error) {
      deps.log("mpesa.callback.lookup_failed", { detail: errorDetail(found) });
      return ack;
    }
    // Includes a callback that beat mark_payment_processing: the STK Query fallback settles it.
    if (found.data === null || found.data === undefined) {
      deps.log("mpesa.callback.unknown_reference", {
        checkoutRequestId: verified.providerReference,
      });
      return ack;
    }
    const row = parseAttemptRow(found.data);
    if (row.provider !== deps.gateway.provider) return ack;
    if (!OPEN.has(row.status)) {
      deps.log("mpesa.callback.replay", {
        transactionId: row.id,
        status: row.status,
      });
      return ack;
    }

    if (verified.outcome === "succeeded") {
      // The callback's own amount must equal the attempt's amount (KES units x100 vs amount_cents).
      if (
        verified.amountCents !== row.amountCents ||
        verified.currency !== row.currency
      ) {
        await apply(deps, "mpesa.callback.amount_mismatch", row, {
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
        return ack;
      }
      await apply(deps, "mpesa.callback.applied", row, {
        outcome: "succeeded",
        providerReference: verified.providerReference,
        amountCents: row.amountCents,
        currency: row.currency,
        failureCode: null,
        failureMessage: null,
      });
      return ack;
    }

    await apply(deps, "mpesa.callback.applied", row, {
      outcome: verified.outcome,
      providerReference: verified.providerReference,
      amountCents: null,
      currency: null,
      failureCode: verified.failureCode,
      failureMessage: verified.failureMessage,
    });
  } catch {
    // Daraja must always get its 200; anything missed is settled by the STK Query fallback.
    deps.log("mpesa.callback.error", { detail: "unexpected" });
  }
  return ack;
}

// ---------------------------------------------------------------- STK Query fallback

export interface ReconcileSummary {
  checked: number;
  applied: number;
  stillPending: number;
  errors: number;
}

/**
 * Asks Daraja about attempts stuck in "processing" with no callback. The query reply carries no
 * amount or receipt, so a success here is applied with the attempt's own amount: the amount we
 * pushed, which came from the database order.
 */
export async function reconcileStuckAttempts(
  deps: SettlementDeps,
  options: { olderThanSeconds: number; limit: number; nowMs: number },
): Promise<ReconcileSummary> {
  const summary: ReconcileSummary = {
    checked: 0,
    applied: 0,
    stillPending: 0,
    errors: 0,
  };
  const queryStatus = deps.gateway.queryStatus?.bind(deps.gateway);
  if (!queryStatus) return summary;

  const cutoff = new Date(
    options.nowMs - options.olderThanSeconds * 1000,
  ).toISOString();
  const listed = await deps.ports.listProcessing(
    deps.gateway.provider,
    cutoff,
    options.limit,
  );
  if (listed.error || !Array.isArray(listed.data)) {
    deps.log("mpesa.reconcile.list_failed", {
      detail: listed.error ? errorDetail(listed) : "shape",
    });
    summary.errors += 1;
    return summary;
  }

  for (const raw of listed.data as unknown[]) {
    let row: AttemptRow;
    try {
      row = parseAttemptRow(raw);
    } catch {
      summary.errors += 1;
      continue;
    }
    if (row.providerReference === null || !OPEN.has(row.status)) continue;
    summary.checked += 1;
    try {
      const answer = await queryStatus(row.providerReference);
      if (answer.kind === "pending") {
        summary.stillPending += 1;
        continue;
      }
      const isSuccess = answer.outcome === "succeeded";
      const result = await apply(deps, "mpesa.reconcile.applied", row, {
        outcome: answer.outcome,
        providerReference: row.providerReference,
        amountCents: isSuccess ? row.amountCents : null,
        currency: isSuccess ? row.currency : null,
        failureCode: answer.failureCode,
        failureMessage: answer.failureMessage,
      });
      if (result === "changed") summary.applied += 1;
      if (result === "error") summary.errors += 1;
    } catch {
      deps.log("mpesa.reconcile.query_failed", { transactionId: row.id });
      summary.errors += 1;
    }
  }
  return summary;
}
