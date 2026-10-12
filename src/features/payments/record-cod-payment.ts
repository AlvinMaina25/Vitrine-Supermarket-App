import {
  COD_REASON_MAX_LENGTH,
  COD_REASON_MIN_LENGTH,
  type CodRefusalReason,
} from "../admin/cod-payment.ts";
import { requireRecord, requireString } from "../admin/customer-parse.ts";
import type { RpcErrorLike } from "../admin/dashboard-result.ts";
import { COD_PROVIDER } from "../checkout/providers/cod.ts";
import { PaymentNotFoundError } from "./payment-read-result.ts";
import {
  PaymentStartError,
  toPaymentStartError,
  type PaymentPorts,
} from "./start-payment.ts";

/**
 * Phase 19: the admin "record cash received" use case, as pure logic behind PaymentPorts.recordCod.
 *
 * The database function record_cod_payment() decides everything (admin only, MFA, cash on
 * delivery, status, already paid). This file validates the input, calls it once, and turns its
 * answer into a result the screen can show. Expected refusals are RETURNED (kind "refused") so
 * the reason survives the server-function boundary; anything unexpected is thrown and made generic.
 */

export interface RecordCodInput {
  orderId: string;
  reason: string;
}

export type CodRecordResult =
  | { kind: "recorded"; changed: boolean; transactionId: string }
  | { kind: "refused"; reason: CodRefusalReason };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Server-function input validator. Exactly two fields; any other field is rejected. The reason is
 * trimmed and must be 3-400 characters, the same limits as the database function.
 */
export function parseRecordCodInput(data: unknown): RecordCodInput {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new PaymentStartError("invalid_request");
  }
  if (Object.keys(data).some((key) => key !== "orderId" && key !== "reason")) {
    throw new PaymentStartError("invalid_request");
  }
  const orderId: unknown = Reflect.get(data, "orderId");
  const reason: unknown = Reflect.get(data, "reason");
  if (typeof orderId !== "string" || !UUID.test(orderId)) {
    throw new PaymentStartError("invalid_request");
  }
  if (typeof reason !== "string") {
    throw new PaymentStartError("invalid_request");
  }
  const trimmed = reason.trim();
  const length = [...trimmed].length;
  if (length < COD_REASON_MIN_LENGTH || length > COD_REASON_MAX_LENGTH) {
    throw new PaymentStartError("invalid_request");
  }
  return { orderId, reason: trimmed };
}

/**
 * This function's own mapping of a refused record_cod_payment() call. mfa_required is checked
 * first because it shares SQLSTATE 42501 with a plain "not an admin"; the shared mapper
 * (toPaymentStartError) is reused for everything else and is not changed.
 */
export function toCodRefusal(
  error: RpcErrorLike,
): CodRefusalReason | "unexpected" {
  if (error.details === "mfa_required") return "mfa_required";
  const mapped = toPaymentStartError(error);
  if (mapped instanceof PaymentNotFoundError) return "order_not_found";
  if (mapped instanceof PaymentStartError) {
    switch (mapped.code) {
      case "not_permitted":
        return "not_permitted";
      case "not_cod_order":
        return "not_cod_order";
      case "cod_not_allowed_yet":
        return "not_delivered_yet";
      case "already_paid":
        return "already_paid";
      case "order_not_payable":
        return "order_not_payable";
      case "amount_invalid":
        return "amount_invalid";
      case "invalid_request":
        return "invalid_request";
      default:
        return "unexpected";
    }
  }
  return "unexpected";
}

export async function recordCodPayment(
  ports: Pick<PaymentPorts, "recordCod">,
  input: RecordCodInput,
): Promise<CodRecordResult> {
  const result = await ports.recordCod(input.orderId, input.reason);
  if (result.error) {
    const reason = toCodRefusal(result.error);
    if (reason === "unexpected") throw new PaymentStartError("unexpected");
    return { kind: "refused", reason };
  }

  const WHAT = "The payment";
  const body = requireRecord(result.data, WHAT);
  const changed = body["changed"];
  if (typeof changed !== "boolean") throw new PaymentStartError("unexpected");
  const txn = requireRecord(body["transaction"], WHAT);
  if (txn["provider"] !== COD_PROVIDER) {
    throw new PaymentStartError("unexpected");
  }
  return {
    kind: "recorded",
    changed,
    transactionId: requireString(txn, "id", WHAT),
  };
}
