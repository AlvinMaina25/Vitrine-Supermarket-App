import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { PaymentStartError } from "../src/features/payments/start-payment.ts";
import {
  parseRecordCodInput,
  recordCodPayment,
  toCodRefusal,
} from "../src/features/payments/record-cod-payment.ts";
import type { RpcResult } from "../src/features/payments/start-payment.ts";

const ORDER = "11111111-1111-4111-8111-111111111111";
const TXN = "22222222-2222-4222-8222-222222222222";

function invalid(data: unknown): void {
  assert.throws(
    () => parseRecordCodInput(data),
    (error: unknown) =>
      error instanceof PaymentStartError && error.code === "invalid_request",
  );
}

describe("parseRecordCodInput", () => {
  it("accepts an order id and a reason, and trims the reason", () => {
    assert.deepEqual(
      parseRecordCodInput({ orderId: ORDER, reason: "  Cash handed over " }),
      { orderId: ORDER, reason: "Cash handed over" },
    );
  });

  it("rejects a bad id, a missing or non-string reason, and non-objects", () => {
    invalid({ orderId: "nope", reason: "Cash received" });
    invalid({ reason: "Cash received" });
    invalid({ orderId: ORDER });
    invalid({ orderId: ORDER, reason: 42 });
    invalid(null);
    invalid("text");
    invalid([ORDER, "Cash received"]);
  });

  it("rejects a reason outside 3-400 characters after trimming", () => {
    invalid({ orderId: ORDER, reason: "  ab  " });
    invalid({ orderId: ORDER, reason: "   " });
    invalid({ orderId: ORDER, reason: "a".repeat(401) });
    assert.equal(
      parseRecordCodInput({ orderId: ORDER, reason: "a".repeat(400) }).reason
        .length,
      400,
    );
  });

  it("rejects any other field (no amount, status or method from the browser)", () => {
    invalid({ orderId: ORDER, reason: "Cash received", amount: 1 });
    invalid({ orderId: ORDER, reason: "Cash received", method: "card" });
    invalid({ orderId: ORDER, reason: "Cash received", status: "paid" });
  });
});

describe("toCodRefusal", () => {
  const rpc = (details: string | null, code: string | null = "P0001") => ({
    message: "raw database text",
    details,
    code,
  });

  it("keeps mfa_required distinct from a plain 'not an admin'", () => {
    assert.equal(toCodRefusal(rpc("mfa_required", "42501")), "mfa_required");
    assert.equal(toCodRefusal(rpc("not_authorised", "42501")), "not_permitted");
    assert.equal(toCodRefusal(rpc(null, "42501")), "not_permitted");
  });

  it("maps each database refusal to a reason", () => {
    const cases: Array<[string, string]> = [
      ["order_not_found", "order_not_found"],
      ["not_cash_on_delivery", "not_cod_order"],
      ["order_status_not_allowed", "not_delivered_yet"],
      ["order_already_paid", "already_paid"],
      ["order_not_payable", "order_not_payable"],
      ["order_amount_invalid", "amount_invalid"],
      ["invalid_arguments", "invalid_request"],
    ];
    for (const [details, expected] of cases) {
      assert.equal(toCodRefusal(rpc(details)), expected, details);
    }
  });

  it("treats anything unknown as unexpected", () => {
    assert.equal(toCodRefusal(rpc("something_new")), "unexpected");
    assert.equal(toCodRefusal(rpc(null, null)), "unexpected");
    assert.equal(toCodRefusal(rpc("attempt_conflict")), "unexpected");
  });
});

describe("recordCodPayment", () => {
  const txn = { id: TXN, provider: "cod", status: "succeeded" };
  const run = (result: RpcResult | Error) => {
    const calls: Array<[string, string]> = [];
    const promise = recordCodPayment(
      {
        recordCod: (orderId, reason) => {
          calls.push([orderId, reason]);
          return result instanceof Error
            ? Promise.reject(result)
            : Promise.resolve(result);
        },
      },
      { orderId: ORDER, reason: "Cash received" },
    );
    return { calls, promise };
  };

  it("sends the order id and the admin's reason, once", async () => {
    const { calls, promise } = run({
      data: { changed: true, transaction: txn },
      error: null,
    });
    await promise;
    assert.deepEqual(calls, [[ORDER, "Cash received"]]);
  });

  it("returns changed true on a new record and changed false on a replay", async () => {
    assert.deepEqual(
      await run({ data: { changed: true, transaction: txn }, error: null })
        .promise,
      { kind: "recorded", changed: true, transactionId: TXN },
    );
    assert.deepEqual(
      await run({ data: { changed: false, transaction: txn }, error: null })
        .promise,
      { kind: "recorded", changed: false, transactionId: TXN },
    );
  });

  it("returns a refusal instead of throwing for an expected database refusal", async () => {
    const result = await run({
      data: null,
      error: {
        message: "raw",
        details: "order_status_not_allowed",
        code: "P0001",
      },
    }).promise;
    assert.deepEqual(result, { kind: "refused", reason: "not_delivered_yet" });
  });

  it("throws a generic error for unknown refusals and malformed answers", async () => {
    await assert.rejects(
      run({
        data: null,
        error: { message: "raw", details: "weird", code: "XX000" },
      }).promise,
      PaymentStartError,
    );
    await assert.rejects(
      run({ data: { changed: "yes", transaction: txn }, error: null }).promise,
    );
    await assert.rejects(
      run({
        data: { changed: true, transaction: { ...txn, provider: "mpesa" } },
        error: null,
      }).promise,
      PaymentStartError,
    );
  });

  it("lets a network failure through so the screen can say 'offline'", async () => {
    await assert.rejects(
      run(new TypeError("Failed to fetch")).promise,
      TypeError,
    );
  });
});
