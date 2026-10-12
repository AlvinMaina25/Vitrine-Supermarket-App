import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { GATEWAYS, selectGateway } from "../src/features/checkout/gateways.ts";
import type {
  GatewayAttempt,
  GatewayOrder,
  InitiateResult,
  PaymentGateway,
} from "../src/features/checkout/payment-providers.ts";
import { codGateway } from "../src/features/checkout/providers/cod.ts";
import { PaymentNotFoundError } from "../src/features/payments/payment-read-result.ts";
import {
  COD_REASON,
  PaymentStartError,
  buildIdempotencyKey,
  nextAttemptNumber,
  parseOrderIdInput,
  parseStartPaymentInput,
  readMyOrderPaymentStatus,
  startPayment,
  toClientSafeError,
  toPaymentStartError,
  type PaymentPorts,
  type RpcResult,
} from "../src/features/payments/start-payment.ts";

const ORDER = "11111111-1111-4111-8111-111111111111";
const TXN = "22222222-2222-4222-8222-222222222222";
const DB_TOTAL = 125050;

const good = (data: unknown): RpcResult => ({ data, error: null });
const bad = (details: string, code = "P0001"): RpcResult => ({
  data: null,
  error: { message: "raw database message", code, details },
});

function myPayments(
  rows: Array<{
    id: string;
    method: string;
    status: string;
    created_at: string;
  }> = [],
): RpcResult {
  return good({
    order_id: ORDER,
    transactions: rows.map((r) => ({
      ...r,
      order_id: ORDER,
      amount_cents: DB_TOTAL,
      currency: "KES",
      completed_at: null,
      provider_reference: "SHOULD-BE-DROPPED",
    })),
  });
}

function attemptRow(
  over: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id: TXN,
    order_id: ORDER,
    provider: "fake-mpesa",
    method: "mpesa",
    amount_cents: DB_TOTAL,
    currency: "KES",
    status: "pending",
    ...over,
  };
}

interface Calls {
  readMy: string[];
  getOrder: string[];
  createAttempt: Array<Record<string, unknown>>;
  markProcessing: Array<[string, string]>;
  recordCod: Array<[string, string]>;
}

function fakePorts(over: Partial<PaymentPorts> = {}): {
  ports: PaymentPorts;
  calls: Calls;
} {
  const calls: Calls = {
    readMy: [],
    getOrder: [],
    createAttempt: [],
    markProcessing: [],
    recordCod: [],
  };
  const ports: PaymentPorts = {
    readMyPayments: (id) => {
      calls.readMy.push(id);
      return Promise.resolve(myPayments());
    },
    getOrderForPayment: (id) => {
      calls.getOrder.push(id);
      return Promise.resolve(
        good({
          id: ORDER,
          total_cents: DB_TOTAL,
          currency: "KES",
          status: "awaiting_payment",
          payment_status: "pending",
        }),
      );
    },
    createAttempt: (args) => {
      calls.createAttempt.push({ ...args });
      return Promise.resolve(
        good({ changed: true, transaction: attemptRow() }),
      );
    },
    markProcessing: (id, ref) => {
      calls.markProcessing.push([id, ref]);
      return Promise.resolve(
        good({
          changed: true,
          transaction: attemptRow({
            status: "processing",
            provider_reference: ref,
          }),
        }),
      );
    },
    recordCod: (id, reason) => {
      calls.recordCod.push([id, reason]);
      return Promise.resolve(
        good({
          changed: true,
          transaction: attemptRow({
            provider: "cod",
            method: "cash_on_delivery",
            status: "succeeded",
          }),
        }),
      );
    },
    ...over,
  };
  return { ports, calls };
}

function fakeGateway(
  method: "mpesa" | "card",
  result: InitiateResult | Error,
): {
  gateway: PaymentGateway;
  seen: Array<{ order: GatewayOrder; attempt: GatewayAttempt }>;
} {
  const seen: Array<{ order: GatewayOrder; attempt: GatewayAttempt }> = [];
  const gateway: PaymentGateway = {
    method,
    provider: `fake-${method}`,
    collectsOffline: false,
    initiate: (order, attempt) => {
      seen.push({ order, attempt });
      return result instanceof Error
        ? Promise.reject(result)
        : Promise.resolve(result);
    },
    parseCallback: () => Promise.resolve({ kind: "ignored" }),
  };
  return { gateway, seen };
}

const mpesaInput = { orderId: ORDER, method: "mpesa" } as const;

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (e) {
    if (e instanceof PaymentStartError) return e.code;
    if (e instanceof PaymentNotFoundError) return `not_found:${e.kind}`;
    throw e;
  }
  return "no_error";
}

describe("provider selection", () => {
  it("selects COD and refuses providers that are not wired up yet", () => {
    assert.equal(selectGateway("cash_on_delivery"), codGateway);
    assert.equal(selectGateway("mpesa"), null);
    assert.equal(selectGateway("card"), null);
    assert.deepEqual(
      GATEWAYS.map((g) => g.method),
      ["cash_on_delivery"],
    );
  });

  it("selects from an injected list by method", () => {
    const { gateway } = fakeGateway("mpesa", { kind: "offline" });
    assert.equal(selectGateway("mpesa", [gateway]), gateway);
    assert.equal(selectGateway("card", [gateway]), null);
  });

  it("an unconnected method starts nothing and touches no port", async () => {
    const { ports, calls } = fakePorts();
    assert.equal(
      await codeOf(startPayment(ports, mpesaInput)),
      "provider_unavailable",
    );
    assert.equal(
      calls.readMy.length + calls.getOrder.length + calls.createAttempt.length,
      0,
    );
  });
});

describe("input validation", () => {
  it("keeps only orderId and method; a browser-sent amount is dropped", () => {
    const parsed = parseStartPaymentInput({
      orderId: ORDER,
      method: "card",
      amountCents: 1,
      total_cents: 1,
    });
    assert.deepEqual(parsed, { orderId: ORDER, method: "card" });
  });

  it("rejects a bad order id, a bad method and non-objects", () => {
    for (const bad of [
      null,
      "x",
      { orderId: "nope", method: "card" },
      { orderId: ORDER, method: "paypal" },
      {},
    ]) {
      assert.throws(() => parseStartPaymentInput(bad), PaymentStartError);
    }
    assert.deepEqual(parseOrderIdInput({ orderId: ORDER }), { orderId: ORDER });
    assert.throws(() => parseOrderIdInput({ orderId: 5 }), PaymentStartError);
  });
});

describe("idempotency key stability", () => {
  const row = (
    id: string,
    status: string,
    created_at: string,
    method = "mpesa",
  ) =>
    ({
      id,
      order_id: ORDER,
      method,
      status,
      amount_cents: 1,
      currency: "KES",
      created_at,
      completed_at: null,
    }) as never;

  it("is the same key for the same history, whatever the row order", () => {
    const a = [row("a", "processing", "2026-10-01T10:00:00Z")];
    assert.deepEqual(nextAttemptNumber(a, "mpesa").attempt, 1);
    assert.equal(
      buildIdempotencyKey(ORDER, "mpesa", 1),
      buildIdempotencyKey(ORDER, "mpesa", 1),
    );
    const two = [
      row("a", "failed", "2026-10-01T10:00:00Z"),
      row("b", "pending", "2026-10-01T10:05:00Z"),
    ];
    assert.equal(
      nextAttemptNumber(two, "mpesa").attempt,
      nextAttemptNumber([...two].reverse(), "mpesa").attempt,
    );
  });

  it("first attempt is 1; a live attempt is reused; a dead one moves to the next key", () => {
    assert.equal(nextAttemptNumber([], "mpesa").attempt, 1);
    assert.equal(
      nextAttemptNumber([row("a", "pending", "2026-10-01T10:00:00Z")], "mpesa")
        .attempt,
      1,
    );
    assert.equal(
      nextAttemptNumber(
        [row("a", "processing", "2026-10-01T10:00:00Z")],
        "mpesa",
      ).attempt,
      1,
    );
    for (const dead of ["failed", "cancelled", "expired"]) {
      assert.equal(
        nextAttemptNumber([row("a", dead, "2026-10-01T10:00:00Z")], "mpesa")
          .attempt,
        2,
      );
    }
  });

  it("counts per method and differs per order and method", () => {
    const hist = [row("a", "failed", "2026-10-01T10:00:00Z", "card")];
    assert.equal(nextAttemptNumber(hist, "mpesa").attempt, 1);
    assert.notEqual(
      buildIdempotencyKey(ORDER, "mpesa", 1),
      buildIdempotencyKey(ORDER, "card", 1),
    );
    assert.notEqual(
      buildIdempotencyKey(ORDER, "mpesa", 1),
      buildIdempotencyKey(TXN, "mpesa", 1),
    );
    assert.ok(buildIdempotencyKey(ORDER, "cash_on_delivery", 99).length <= 200);
  });

  it("startPayment sends the derived key to create_payment_attempt", async () => {
    const { gateway } = fakeGateway("mpesa", {
      kind: "prompt_sent",
      providerReference: "CHK1",
    });
    const { ports, calls } = fakePorts({
      readMyPayments: () =>
        Promise.resolve(
          myPayments([
            {
              id: "a",
              method: "mpesa",
              status: "failed",
              created_at: "2026-10-01T10:00:00Z",
            },
          ]),
        ),
    });
    await startPayment(ports, mpesaInput, [gateway]);
    assert.equal(
      calls.createAttempt[0]?.["idempotencyKey"],
      `pay:${ORDER}:mpesa:2`,
    );
    assert.equal(calls.createAttempt[0]?.["provider"], "fake-mpesa");
  });
});

describe("amount comes from the database", () => {
  it("initiate sees the DB total; create_payment_attempt is sent no amount", async () => {
    const { gateway, seen } = fakeGateway("mpesa", {
      kind: "prompt_sent",
      providerReference: "CHK1",
    });
    const { ports, calls } = fakePorts();
    const input = parseStartPaymentInput({
      orderId: ORDER,
      method: "mpesa",
      amountCents: 1,
    });
    await startPayment(ports, input, [gateway]);
    assert.equal(seen[0]?.order.totalCents, DB_TOTAL);
    assert.equal(seen[0]?.attempt.amountCents, DB_TOTAL);
    assert.equal(seen[0]?.attempt.currency, "KES");
    assert.deepEqual(Object.keys(calls.createAttempt[0] ?? {}).sort(), [
      "idempotencyKey",
      "method",
      "orderId",
      "provider",
    ]);
  });

  it("refuses to initiate when the attempt and the order disagree", async () => {
    const { gateway, seen } = fakeGateway("mpesa", {
      kind: "prompt_sent",
      providerReference: "CHK1",
    });
    const { ports, calls } = fakePorts({
      createAttempt: () =>
        Promise.resolve(
          good({
            changed: false,
            transaction: attemptRow({ amount_cents: 100 }),
          }),
        ),
    });
    assert.equal(
      await codeOf(startPayment(ports, mpesaInput, [gateway])),
      "amount_mismatch",
    );
    assert.equal(seen.length, 0);
    assert.equal(calls.markProcessing.length, 0);
  });

  it("rejects an order with no payable amount", async () => {
    const { gateway } = fakeGateway("mpesa", { kind: "offline" });
    const { ports } = fakePorts({
      getOrderForPayment: () =>
        Promise.resolve(good({ id: ORDER, total_cents: 0, currency: "KES" })),
    });
    assert.equal(
      await codeOf(startPayment(ports, mpesaInput, [gateway])),
      "amount_invalid",
    );
  });
});

describe("start payment: provider flow", () => {
  it("prompt provider: attempt created, initiated, marked processing with the reference", async () => {
    const { gateway } = fakeGateway("mpesa", {
      kind: "prompt_sent",
      providerReference: "CHK1",
    });
    const { ports, calls } = fakePorts();
    const result = await startPayment(ports, mpesaInput, [gateway]);
    assert.deepEqual(result, {
      kind: "initiated",
      transactionId: TXN,
      status: "processing",
      next: { type: "prompt_sent" },
    });
    assert.deepEqual(calls.markProcessing, [[TXN, "CHK1"]]);
  });

  it("redirect provider returns the hosted-page url", async () => {
    const { gateway } = fakeGateway("card", {
      kind: "redirect",
      providerReference: "S1",
      redirectUrl: "https://pay.example/s1",
    });
    const { ports } = fakePorts();
    const result = await startPayment(
      ports,
      { orderId: ORDER, method: "card" },
      [gateway],
    );
    assert.equal(
      result.kind === "initiated" &&
        result.next.type === "redirect" &&
        result.next.redirectUrl,
      "https://pay.example/s1",
    );
  });

  it("a replay of an attempt already past pending sends nothing to the provider", async () => {
    const { gateway, seen } = fakeGateway("mpesa", {
      kind: "prompt_sent",
      providerReference: "CHK1",
    });
    const { ports, calls } = fakePorts({
      createAttempt: () =>
        Promise.resolve(
          good({
            changed: false,
            transaction: attemptRow({ status: "processing" }),
          }),
        ),
    });
    const result = await startPayment(ports, mpesaInput, [gateway]);
    assert.deepEqual(result, {
      kind: "already_in_progress",
      transactionId: TXN,
      status: "processing",
    });
    assert.equal(seen.length, 0);
    assert.equal(calls.markProcessing.length, 0);
  });

  it("an already-succeeded attempt stops before create_payment_attempt", async () => {
    const { gateway } = fakeGateway("mpesa", { kind: "offline" });
    const { ports, calls } = fakePorts({
      readMyPayments: () =>
        Promise.resolve(
          myPayments([
            {
              id: "a",
              method: "mpesa",
              status: "succeeded",
              created_at: "2026-10-01T10:00:00Z",
            },
          ]),
        ),
    });
    assert.equal(
      await codeOf(startPayment(ports, mpesaInput, [gateway])),
      "already_paid",
    );
    assert.equal(calls.createAttempt.length, 0);
  });

  it("someone else's order: not found, and no service-role port is touched", async () => {
    const { gateway } = fakeGateway("mpesa", { kind: "offline" });
    const { ports, calls } = fakePorts({
      readMyPayments: () => Promise.resolve(bad("order_not_found")),
    });
    assert.equal(
      await codeOf(startPayment(ports, mpesaInput, [gateway])),
      "not_found:order",
    );
    assert.equal(calls.getOrder.length + calls.createAttempt.length, 0);
  });

  it("a provider failure becomes a generic provider_error and never marks processing", async () => {
    const { gateway } = fakeGateway(
      "mpesa",
      new Error("254712345678 token=abc raw payload"),
    );
    const { ports, calls } = fakePorts();
    try {
      await startPayment(ports, mpesaInput, [gateway]);
      assert.fail("expected an error");
    } catch (e) {
      assert.ok(e instanceof PaymentStartError);
      assert.equal(e.code, "provider_error");
      assert.ok(
        !e.message.includes("254712345678") && !e.message.includes("token"),
      );
    }
    assert.equal(calls.markProcessing.length, 0);
  });
});

describe("cash on delivery path", () => {
  it("calls record_cod_payment only: no attempt row, no order read, no provider", async () => {
    const { ports, calls } = fakePorts();
    const result = await startPayment(ports, {
      orderId: ORDER,
      method: "cash_on_delivery",
    });
    assert.deepEqual(result, {
      kind: "cod_recorded",
      transactionId: TXN,
      changed: true,
    });
    assert.deepEqual(calls.recordCod, [[ORDER, COD_REASON]]);
    assert.equal(
      calls.createAttempt.length + calls.getOrder.length + calls.readMy.length,
      0,
    );
  });

  it("maps the database's refusals to safe errors", async () => {
    const cases: Array<[RpcResult, string]> = [
      [bad("not_authorised", "42501"), "not_permitted"],
      [bad("order_status_not_allowed"), "cod_not_allowed_yet"],
      [bad("not_cash_on_delivery"), "not_cod_order"],
      [bad("order_already_paid"), "already_paid"],
      [bad("order_not_payable"), "order_not_payable"],
      [bad("order_not_found"), "not_found:order"],
    ];
    for (const [rpc, expected] of cases) {
      const { ports } = fakePorts({ recordCod: () => Promise.resolve(rpc) });
      assert.equal(
        await codeOf(
          startPayment(ports, { orderId: ORDER, method: "cash_on_delivery" }),
        ),
        expected,
      );
    }
  });

  it("a replay (already recorded) reports changed: false", async () => {
    const { ports } = fakePorts({
      recordCod: () =>
        Promise.resolve(
          good({
            changed: false,
            transaction: attemptRow({
              provider: "cod",
              method: "cash_on_delivery",
              status: "succeeded",
            }),
          }),
        ),
    });
    const result = await startPayment(ports, {
      orderId: ORDER,
      method: "cash_on_delivery",
    });
    assert.equal(result.kind === "cod_recorded" && result.changed, false);
  });
});

describe("error mapping", () => {
  it("maps every write-function error code and never echoes the database message", () => {
    const table: Array<[string, string]> = [
      ["invalid_arguments", "invalid_request"],
      ["invalid_reference", "invalid_request"],
      ["order_not_payable", "order_not_payable"],
      ["order_already_paid", "already_paid"],
      ["order_amount_invalid", "amount_invalid"],
      ["method_not_supported", "method_not_supported"],
      ["idempotency_key_conflict", "idempotency_conflict"],
      ["invalid_transition", "attempt_conflict"],
      ["reference_conflict", "attempt_conflict"],
      ["provider_reference_in_use", "attempt_conflict"],
      ["something_new", "unexpected"],
    ];
    for (const [details, code] of table) {
      const err = toPaymentStartError({
        message: "SECRET raw db text",
        details,
        code: "P0001",
      });
      assert.ok(err instanceof PaymentStartError, details);
      assert.equal((err as PaymentStartError).code, code, details);
      assert.ok(!err.message.includes("SECRET"));
    }
    assert.ok(
      toPaymentStartError({
        message: "x",
        details: "order_not_found",
      }) instanceof PaymentNotFoundError,
    );
    assert.ok(
      toPaymentStartError({
        message: "x",
        details: "transaction_not_found",
      }) instanceof PaymentNotFoundError,
    );
  });

  it("toClientSafeError passes known errors and hides the rest", () => {
    const known = new PaymentStartError("already_paid");
    assert.equal(toClientSafeError(known), known);
    const hidden = toClientSafeError(
      new Error("service key sk_live_123 leaked"),
    );
    assert.ok(hidden instanceof PaymentStartError);
    assert.ok(!hidden.message.includes("sk_live"));
  });
});

describe("customer status read", () => {
  it("returns only the customer-safe fields through the 6G.4-C mapper", async () => {
    const { ports } = fakePorts({
      readMyPayments: () =>
        Promise.resolve(
          myPayments([
            {
              id: "a",
              method: "mpesa",
              status: "processing",
              created_at: "2026-10-01T10:00:00Z",
            },
          ]),
        ),
    });
    const status = await readMyOrderPaymentStatus(ports, ORDER);
    assert.equal(status.transactions[0]?.status, "processing");
    assert.ok(!("provider_reference" in (status.transactions[0] ?? {})));
  });

  it("maps errors: signed out, not their order, generic", async () => {
    const cases: Array<[RpcResult, string]> = [
      [bad("not_authorised", "42501"), "Please sign in to view your payments."],
      [bad("order_not_found"), "That order could not be found."],
      [bad("boom"), "Your payments could not be loaded."],
    ];
    for (const [rpc, message] of cases) {
      const { ports } = fakePorts({
        readMyPayments: () => Promise.resolve(rpc),
      });
      await assert.rejects(
        readMyOrderPaymentStatus(ports, ORDER),
        (e: Error) => e.message === message,
      );
    }
  });
});
