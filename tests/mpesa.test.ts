import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { PaymentGateway } from "../src/features/checkout/payment-providers.ts";
import type {
  HttpRequest,
  HttpResponse,
} from "../src/features/checkout/providers/http.ts";
import {
  MPESA_PROVIDER,
  MpesaError,
  constantTimeEquals,
  createMpesaGateway,
  darajaTimestamp,
  normaliseKenyanPhone,
  type MpesaConfig,
} from "../src/features/checkout/providers/mpesa.ts";
import {
  DARAJA_ACK,
  handleMpesaCallback,
  reconcileStuckAttempts,
  type ApplyOutcomeArgs,
  type SettlementDeps,
  type SettlementPorts,
} from "../src/features/payments/mpesa-settlement.ts";
import {
  PaymentStartError,
  parseStartPaymentInput,
  startPayment,
  type PaymentPorts,
  type RpcResult,
} from "../src/features/payments/start-payment.ts";

const TOKEN = "test-callback-token-1234";
const CONFIG: MpesaConfig = {
  consumerKey: "KEY-abc",
  consumerSecret: "SECRET-xyz",
  shortcode: "174379",
  passkey: "PASSKEY-123",
  callbackBaseUrl: "https://shop.example",
  callbackToken: TOKEN,
};
const CB_URL = `https://shop.example/api/public/mpesa-callback/${TOKEN}`;
const ORDER = "11111111-1111-4111-8111-111111111111";
const TXN = "22222222-2222-4222-8222-222222222222";
const CHECKOUT_ID = "ws_CO_191220191020363925";
const PHONE_DIGITS = "254712345678";
const AMOUNT_CENTS = 125000; // KES 1,250 (M-Pesa needs whole shillings)

// ---------------------------------------------------------------- fakes

function fakeHttp(handler?: (req: HttpRequest) => HttpResponse) {
  const requests: HttpRequest[] = [];
  const client = {
    request: (req: HttpRequest): Promise<HttpResponse> => {
      requests.push(req);
      if (handler) return Promise.resolve(handler(req));
      if (req.url.includes("/oauth/v1/generate")) {
        return Promise.resolve({
          status: 200,
          body: JSON.stringify({ access_token: "tok-1", expires_in: "3599" }),
        });
      }
      return Promise.resolve({
        status: 200,
        body: JSON.stringify({
          ResponseCode: "0",
          CheckoutRequestID: CHECKOUT_ID,
        }),
      });
    },
  };
  return { requests, client };
}

function clock(start = 1_760_000_000_000) {
  let t = start;
  return { now: () => t, advance: (ms: number) => void (t += ms) };
}

const attempt = {
  transactionId: TXN,
  provider: MPESA_PROVIDER,
  method: "mpesa" as const,
  amountCents: AMOUNT_CENTS,
  currency: "KES",
  idempotencyKey: "pay:k:1",
};
const order = { id: ORDER, totalCents: AMOUNT_CENTS, currency: "KES" };

function successBody(
  over: {
    amount?: number;
    code?: number;
    checkoutId?: string;
    receipt?: string | null;
  } = {},
) {
  const items: unknown[] = [
    { Name: "Amount", Value: over.amount ?? 1250.0 },
    { Name: "TransactionDate", Value: 20191219102115 },
    { Name: "PhoneNumber", Value: Number(PHONE_DIGITS) },
  ];
  if (over.receipt !== null)
    items.push({
      Name: "MpesaReceiptNumber",
      Value: over.receipt ?? "NLJ7RT61SV",
    });
  return JSON.stringify({
    Body: {
      stkCallback: {
        MerchantRequestID: "29115-34620561-1",
        CheckoutRequestID: over.checkoutId ?? CHECKOUT_ID,
        ResultCode: over.code ?? 0,
        ResultDesc: "The service request is processed successfully.",
        CallbackMetadata: { Item: items },
      },
    },
  });
}

function failureBody(code: number, desc: string, checkoutId = CHECKOUT_ID) {
  return JSON.stringify({
    Body: {
      stkCallback: {
        MerchantRequestID: "29115-34620561-1",
        CheckoutRequestID: checkoutId,
        ResultCode: code,
        ResultDesc: desc,
      },
    },
  });
}

const callbackRequest = (body: string, url = CB_URL, method = "POST") => ({
  method,
  url,
  headers: {},
  body,
});

interface Row {
  id: string;
  provider: string;
  method: string;
  amount_cents: number;
  currency: string;
  status: string;
  provider_reference: string | null;
}

function openRow(over: Partial<Row> = {}): Row {
  return {
    id: TXN,
    provider: MPESA_PROVIDER,
    method: "mpesa",
    amount_cents: AMOUNT_CENTS,
    currency: "KES",
    status: "processing",
    provider_reference: CHECKOUT_ID,
    ...over,
  };
}

function fakeSettlement(rows: Row[], gateway: PaymentGateway) {
  const applied: ApplyOutcomeArgs[] = [];
  const lookups: string[] = [];
  const logs: Array<{
    event: string;
    fields: Record<string, string | number | null>;
  }> = [];
  const ports: SettlementPorts = {
    findByReference: (_provider, ref) => {
      lookups.push(ref);
      return Promise.resolve({
        data: rows.find((r) => r.provider_reference === ref) ?? null,
        error: null,
      });
    },
    listProcessing: () =>
      Promise.resolve({
        data: rows.filter((r) => r.status === "processing"),
        error: null,
      }),
    applyOutcome: (args) => {
      applied.push(args);
      const row = rows.find((r) => r.id === args.transactionId);
      if (!row)
        return Promise.resolve({
          data: null,
          error: { message: "x", details: "transaction_not_found" },
        });
      if (row.status !== "pending" && row.status !== "processing") {
        return Promise.resolve({
          data: null,
          error: { message: "x", details: "invalid_transition" },
        });
      }
      row.status = args.outcome;
      return Promise.resolve({
        data: { changed: true, transaction: row },
        error: null,
      });
    },
  };
  const deps: SettlementDeps = {
    gateway,
    ports,
    log: (event, fields) => void logs.push({ event, fields }),
  };
  return { deps, applied, lookups, logs, rows };
}

function gatewayWith(handler?: (req: HttpRequest) => HttpResponse) {
  const http = fakeHttp(handler);
  const c = clock();
  return {
    gateway: createMpesaGateway(CONFIG, http.client, c.now),
    http,
    clock: c,
  };
}

// ---------------------------------------------------------------- helpers

describe("phone normalisation", () => {
  it("accepts 07/01, 254 and +254 forms and normalises to 254[71]XXXXXXXX", () => {
    const cases: Array<[string, string]> = [
      ["0712345678", "254712345678"],
      ["0112345678", "254112345678"],
      ["254712345678", "254712345678"],
      ["+254 712 345 678", "254712345678"],
      ["0712-345-678", "254712345678"],
      ["254112345678", "254112345678"],
    ];
    for (const [input, expected] of cases)
      assert.equal(normaliseKenyanPhone(input), expected, input);
  });

  it("rejects everything else", () => {
    for (const bad of [
      "",
      "712345678",
      "0212345678",
      "254212345678",
      "25471234567",
      "2547123456789",
      "+0712345678",
      "07123abc78",
      "0712345678; drop",
      "+255712345678",
      "254 7123",
    ]) {
      assert.equal(normaliseKenyanPhone(bad), null, bad);
    }
    assert.equal(normaliseKenyanPhone(null), null);
  });

  it("constantTimeEquals and darajaTimestamp", () => {
    assert.ok(constantTimeEquals("abc", "abc"));
    assert.ok(!constantTimeEquals("abc", "abd"));
    assert.ok(!constantTimeEquals("abc", "abcd"));
    assert.ok(!constantTimeEquals("", "x"));
    // 2026-10-08T10:00:00Z is 13:00 in Nairobi.
    assert.equal(
      darajaTimestamp(Date.UTC(2026, 9, 8, 10, 0, 0)),
      "20261008130000",
    );
  });
});

// ---------------------------------------------------------------- gateway

describe("daraja gateway: OAuth token", () => {
  it("is cached across calls, then refreshed once it is near expiry", async () => {
    const { gateway, http, clock: c } = gatewayWith();
    await gateway.initiate(order, attempt, { phone: "0712345678" });
    await gateway.initiate(order, attempt, { phone: "0712345678" });
    const tokenCalls = () =>
      http.requests.filter((r) => r.url.includes("/oauth/v1/generate")).length;
    assert.equal(tokenCalls(), 1);
    c.advance(3599 * 1000 - 30_000); // inside the 60s safety margin
    await gateway.initiate(order, attempt, { phone: "0712345678" });
    assert.equal(tokenCalls(), 2);
  });

  it("concurrent callers share one token request", async () => {
    const { gateway, http } = gatewayWith();
    await Promise.all([
      gateway.initiate(order, attempt, { phone: "0712345678" }),
      gateway.initiate(order, attempt, { phone: "0712345678" }),
      gateway.initiate(order, attempt, { phone: "0712345678" }),
    ]);
    assert.equal(
      http.requests.filter((r) => r.url.includes("/oauth/v1/generate")).length,
      1,
    );
  });

  it("sends Basic auth to the sandbox host only", async () => {
    const { gateway, http } = gatewayWith();
    await gateway.initiate(order, attempt, { phone: "0712345678" });
    const tokenReq = http.requests[0];
    assert.equal(tokenReq?.method, "GET");
    assert.ok(tokenReq?.url.startsWith("https://sandbox.safaricom.co.ke/"));
    assert.equal(
      tokenReq?.headers["Authorization"],
      `Basic ${btoa("KEY-abc:SECRET-xyz")}`,
    );
    assert.ok(
      http.requests.every((r) =>
        r.url.startsWith("https://sandbox.safaricom.co.ke/"),
      ),
    );
  });

  it("an early-expired token (401) is dropped and retried exactly once", async () => {
    let pushes = 0;
    const { gateway, http } = gatewayWith((req) => {
      if (req.url.includes("/oauth/")) {
        return {
          status: 200,
          body: JSON.stringify({
            access_token: `tok-${http.requests.length}`,
            expires_in: "3599",
          }),
        };
      }
      pushes += 1;
      return pushes === 1
        ? { status: 401, body: "{}" }
        : {
            status: 200,
            body: JSON.stringify({
              ResponseCode: "0",
              CheckoutRequestID: CHECKOUT_ID,
            }),
          };
    });
    const result = await gateway.initiate(order, attempt, {
      phone: "0712345678",
    });
    assert.equal(result.kind, "prompt_sent");
    assert.equal(
      http.requests.filter((r) => r.url.includes("/oauth/")).length,
      2,
    );
  });

  it("an OAuth failure becomes a generic auth_failed error", async () => {
    const { gateway } = gatewayWith(() => ({
      status: 400,
      body: '{"error":"SECRET-xyz leaked?"}',
    }));
    await assert.rejects(
      gateway.initiate(order, attempt, { phone: "0712345678" }),
      (e: unknown) => {
        assert.ok(e instanceof MpesaError);
        assert.equal(e.reason, "auth_failed");
        assert.ok(!e.message.includes("SECRET"));
        return true;
      },
    );
  });
});

describe("daraja gateway: STK Push", () => {
  it("builds the request from the DB attempt: whole KES, normalised phone, password, callback URL", async () => {
    const { gateway, http } = gatewayWith();
    const result = await gateway.initiate(order, attempt, {
      phone: "0712 345 678",
    });
    assert.deepEqual(result, {
      kind: "prompt_sent",
      providerReference: CHECKOUT_ID,
    });

    const push = http.requests.find((r) =>
      r.url.endsWith("/mpesa/stkpush/v1/processrequest"),
    );
    assert.equal(push?.method, "POST");
    assert.equal(push?.headers["Authorization"], "Bearer tok-1");
    const body = JSON.parse(push?.body ?? "{}") as Record<string, unknown>;
    assert.equal(body["Amount"], 1250);
    assert.equal(body["PartyA"], PHONE_DIGITS);
    assert.equal(body["PhoneNumber"], PHONE_DIGITS);
    assert.equal(body["PartyB"], "174379");
    assert.equal(body["BusinessShortCode"], "174379");
    assert.equal(body["TransactionType"], "CustomerPayBillOnline");
    assert.equal(body["CallBackURL"], CB_URL);
    assert.equal(body["AccountReference"], "111111111111");
    const timestamp = String(body["Timestamp"]);
    assert.match(timestamp, /^\d{14}$/);
    assert.equal(body["Password"], btoa(`174379PASSKEY-123${timestamp}`));
  });

  it("only whole-shilling amounts are acceptable", async () => {
    const { gateway } = gatewayWith();
    assert.equal(gateway.acceptsAmountCents?.(125000), true);
    assert.equal(gateway.acceptsAmountCents?.(125050), false);
    assert.equal(gateway.acceptsAmountCents?.(0), false);
    await assert.rejects(
      gateway.initiate(
        order,
        { ...attempt, amountCents: 125050 },
        { phone: "0712345678" },
      ),
      (e: unknown) =>
        e instanceof MpesaError && e.reason === "amount_not_whole",
    );
  });

  it("rejects a bad phone before any HTTP call", async () => {
    const { gateway, http } = gatewayWith();
    await assert.rejects(
      gateway.initiate(order, attempt, { phone: "12345" }),
      (e: unknown) => e instanceof MpesaError && e.reason === "bad_phone",
    );
    assert.equal(http.requests.length, 0);
  });

  it("a refused push is a generic error that leaks no phone, token or payload", async () => {
    const { gateway } = gatewayWith((req) =>
      req.url.includes("/oauth/")
        ? {
            status: 200,
            body: JSON.stringify({ access_token: "tok-1", expires_in: "3599" }),
          }
        : {
            status: 200,
            body: JSON.stringify({
              ResponseCode: "1",
              errorMessage: `bad ${PHONE_DIGITS}`,
            }),
          },
    );
    await assert.rejects(
      gateway.initiate(order, attempt, { phone: "0712345678" }),
      (e: unknown) => {
        assert.ok(e instanceof MpesaError);
        assert.equal(e.reason, "push_rejected");
        assert.ok(
          !e.message.includes(PHONE_DIGITS) && !e.message.includes("tok-1"),
        );
        return true;
      },
    );
  });

  it("refuses to be built with a short callback token", () => {
    assert.throws(() =>
      createMpesaGateway(
        { ...CONFIG, callbackToken: "short" },
        fakeHttp().client,
      ),
    );
  });
});

describe("daraja gateway: parseCallback", () => {
  it("success: cents from KES, receipt, reference", async () => {
    const { gateway } = gatewayWith();
    const out = await gateway.parseCallback(callbackRequest(successBody()));
    assert.deepEqual(out, {
      kind: "outcome",
      providerReference: CHECKOUT_ID,
      outcome: "succeeded",
      amountCents: 125000,
      currency: "KES",
      receiptNumber: "NLJ7RT61SV",
      failureCode: null,
      failureMessage: null,
    });
  });

  it("maps cancel / timeout / insufficient funds", async () => {
    const { gateway } = gatewayWith();
    const cases: Array<[number, string]> = [
      [1032, "cancelled"],
      [1037, "expired"],
      [1, "failed"],
      [2001, "failed"],
    ];
    for (const [code, outcome] of cases) {
      const out = await gateway.parseCallback(
        callbackRequest(failureBody(code, "desc")),
      );
      assert.equal(
        out.kind === "outcome" && out.outcome,
        outcome,
        String(code),
      );
      assert.equal(out.kind === "outcome" && out.failureCode, `mpesa_${code}`);
    }
  });

  it("a wrong or missing path token is rejected as bad_token", async () => {
    const { gateway } = gatewayWith();
    for (const url of [
      "https://shop.example/api/public/mpesa-callback/wrong-token-0000000",
      "https://shop.example/api/public/mpesa-callback/",
      "https://shop.example/api/public/mpesa-callback",
      "not a url",
    ]) {
      await assert.rejects(
        gateway.parseCallback(callbackRequest(successBody(), url)),
        (e: unknown) =>
          e instanceof Error &&
          e.name === "CallbackRejectedError" &&
          Reflect.get(e, "reason") === "bad_token",
        url,
      );
    }
    await assert.rejects(
      gateway.parseCallback(callbackRequest(successBody(), CB_URL, "GET")),
    );
  });

  it("malformed bodies and unverifiable successes are rejected as malformed", async () => {
    const { gateway } = gatewayWith();
    for (const body of [
      "not json",
      "{}",
      JSON.stringify({ Body: {} }),
      JSON.stringify({ Body: { stkCallback: { ResultCode: 0 } } }),
      successBody({ receipt: null }),
      failureBody(0, "ok"), // success with no amount or receipt
    ]) {
      await assert.rejects(
        gateway.parseCallback(callbackRequest(body)),
        (e: unknown) =>
          e instanceof Error && Reflect.get(e, "reason") === "malformed",
        body.slice(0, 40),
      );
    }
  });
});

// ---------------------------------------------------------------- callback handling

describe("mpesa callback handling", () => {
  it("success: applies succeeded with the attempt's amount and replies 200 + ack", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody()),
    );
    assert.equal(reply.status, 200);
    assert.deepEqual(reply.body, DARAJA_ACK);
    assert.deepEqual(s.applied, [
      {
        transactionId: TXN,
        outcome: "succeeded",
        providerReference: CHECKOUT_ID,
        amountCents: 125000,
        currency: "KES",
        failureCode: null,
        failureMessage: null,
      },
    ]);
  });

  it("user cancelled -> cancelled", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(failureBody(1032, "Request cancelled by user")),
    );
    assert.equal(reply.status, 200);
    assert.equal(s.applied[0]?.outcome, "cancelled");
    assert.equal(s.applied[0]?.failureCode, "mpesa_1032");
    assert.equal(s.applied[0]?.amountCents, null);
  });

  it("insufficient funds -> failed", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    await handleMpesaCallback(
      s.deps,
      callbackRequest(failureBody(1, "The balance is insufficient")),
    );
    assert.equal(s.applied[0]?.outcome, "failed");
    assert.equal(s.applied[0]?.failureCode, "mpesa_1");
    assert.equal(s.applied[0]?.failureMessage, "The balance is insufficient");
  });

  it("timeout -> expired", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    await handleMpesaCallback(
      s.deps,
      callbackRequest(failureBody(1037, "DS timeout user cannot be reached")),
    );
    assert.equal(s.applied[0]?.outcome, "expired");
  });

  it("wrong amount is never applied as a success", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody({ amount: 1 })),
    );
    assert.equal(reply.status, 200);
    assert.equal(s.applied.length, 1);
    assert.equal(s.applied[0]?.outcome, "failed");
    assert.equal(s.applied[0]?.failureCode, "amount_mismatch");
    assert.equal(s.applied[0]?.amountCents, null);
    assert.equal(s.rows[0]?.status, "failed");
  });

  it("unknown CheckoutRequestID: nothing written, still acked", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody({ checkoutId: "ws_CO_unknown" })),
    );
    assert.deepEqual(reply, { status: 200, body: DARAJA_ACK });
    assert.equal(s.applied.length, 0);
    assert.equal(s.lookups[0], "ws_CO_unknown");
  });

  it("the same callback twice changes nothing the second time", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const first = await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody()),
    );
    const second = await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody()),
    );
    assert.deepEqual(first, second);
    assert.equal(s.applied.length, 1);
    assert.equal(s.rows[0]?.status, "succeeded");
  });

  it("a late contradictory callback cannot downgrade a settled attempt", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow({ status: "succeeded" })], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(failureBody(1032, "cancelled")),
    );
    assert.equal(reply.status, 200);
    assert.equal(s.applied.length, 0);
  });

  it("bad path token: 404, no lookup, no write", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    const reply = await handleMpesaCallback(
      s.deps,
      callbackRequest(
        successBody(),
        "https://shop.example/api/public/mpesa-callback/not-the-token-000",
      ),
    );
    assert.equal(reply.status, 404);
    assert.equal(s.lookups.length + s.applied.length, 0);
  });

  it("malformed body: 200 ack, nothing written", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    for (const body of ["garbage", successBody({ receipt: null })]) {
      const reply = await handleMpesaCallback(s.deps, callbackRequest(body));
      assert.deepEqual(reply, { status: 200, body: DARAJA_ACK });
    }
    assert.equal(s.applied.length, 0);
  });

  it("a database refusal or outage still gets Daraja its 200", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement([openRow()], gateway);
    s.deps.ports.applyOutcome = () =>
      Promise.resolve({
        data: null,
        error: { message: "x", details: "order_already_paid" },
      });
    assert.equal(
      (await handleMpesaCallback(s.deps, callbackRequest(successBody())))
        .status,
      200,
    );
    s.deps.ports.findByReference = () => Promise.reject(new Error("db down"));
    assert.equal(
      (await handleMpesaCallback(s.deps, callbackRequest(successBody())))
        .status,
      200,
    );
  });

  it("logs ids and statuses only: never the phone, the receipt, the token or the raw body", async () => {
    const { gateway } = gatewayWith();
    const s = fakeSettlement(
      [
        openRow(),
        openRow({
          id: "33333333-3333-4333-8333-333333333333",
          provider_reference: "ws_CO_2",
        }),
      ],
      gateway,
    );
    await handleMpesaCallback(s.deps, callbackRequest(successBody()));
    await handleMpesaCallback(
      s.deps,
      callbackRequest(successBody({ amount: 5, checkoutId: "ws_CO_2" })),
    );
    await handleMpesaCallback(
      s.deps,
      callbackRequest(
        successBody(),
        "https://shop.example/api/public/mpesa-callback/bad-token-00000000",
      ),
    );
    await handleMpesaCallback(s.deps, callbackRequest("garbage"));
    const logged = JSON.stringify(s.logs);
    for (const secret of [
      PHONE_DIGITS,
      "NLJ7RT61SV",
      TOKEN,
      "bad-token-00000000",
      "CallbackMetadata",
      "garbage",
    ]) {
      assert.ok(!logged.includes(secret), secret);
    }
    assert.ok(s.logs.length > 0);
  });
});

// ---------------------------------------------------------------- STK Query fallback

describe("STK Query fallback for stuck attempts", () => {
  const queryReply =
    (resultCode: string) =>
    (req: HttpRequest): HttpResponse =>
      req.url.includes("/oauth/")
        ? {
            status: 200,
            body: JSON.stringify({ access_token: "tok-1", expires_in: "3599" }),
          }
        : {
            status: 200,
            body: JSON.stringify({
              ResponseCode: "0",
              ResultCode: resultCode,
              ResultDesc: "desc",
              CheckoutRequestID: CHECKOUT_ID,
            }),
          };
  const opts = { olderThanSeconds: 120, limit: 25, nowMs: 1_760_000_000_000 };

  it("a successful query settles the attempt with the attempt's own amount", async () => {
    const { gateway, http } = gatewayWith(queryReply("0"));
    const s = fakeSettlement([openRow()], gateway);
    const summary = await reconcileStuckAttempts(s.deps, opts);
    assert.deepEqual(summary, {
      checked: 1,
      applied: 1,
      stillPending: 0,
      errors: 0,
    });
    assert.equal(s.applied[0]?.outcome, "succeeded");
    assert.equal(s.applied[0]?.amountCents, AMOUNT_CENTS);
    const q = http.requests.find((r) =>
      r.url.endsWith("/mpesa/stkpushquery/v1/query"),
    );
    assert.equal(
      (JSON.parse(q?.body ?? "{}") as Record<string, unknown>)[
        "CheckoutRequestID"
      ],
      CHECKOUT_ID,
    );
  });

  it("cancelled and timed-out queries map to cancelled / expired", async () => {
    for (const [code, outcome] of [
      ["1032", "cancelled"],
      ["1037", "expired"],
      ["1", "failed"],
    ] as const) {
      const { gateway } = gatewayWith(queryReply(code));
      const s = fakeSettlement([openRow()], gateway);
      await reconcileStuckAttempts(s.deps, opts);
      assert.equal(s.applied[0]?.outcome, outcome, code);
      assert.equal(s.applied[0]?.amountCents, null);
    }
  });

  it("'still being processed' changes nothing", async () => {
    const { gateway } = gatewayWith((req) =>
      req.url.includes("/oauth/")
        ? {
            status: 200,
            body: JSON.stringify({ access_token: "tok-1", expires_in: "3599" }),
          }
        : {
            status: 500,
            body: JSON.stringify({
              errorCode: "500.001.1001",
              errorMessage: "The transaction is being processed",
            }),
          },
    );
    const s = fakeSettlement([openRow()], gateway);
    const summary = await reconcileStuckAttempts(s.deps, opts);
    assert.deepEqual(summary, {
      checked: 1,
      applied: 0,
      stillPending: 1,
      errors: 0,
    });
    assert.equal(s.applied.length, 0);
  });

  it("a query failure is counted, not applied, and does not stop the batch", async () => {
    let n = 0;
    const { gateway } = gatewayWith((req) => {
      if (req.url.includes("/oauth/"))
        return {
          status: 200,
          body: JSON.stringify({ access_token: "tok-1", expires_in: "3599" }),
        };
      n += 1;
      return n === 1
        ? { status: 503, body: "upstream down" }
        : {
            status: 200,
            body: JSON.stringify({
              ResponseCode: "0",
              ResultCode: "1032",
              ResultDesc: "x",
            }),
          };
    });
    const second = openRow({
      id: "33333333-3333-4333-8333-333333333333",
      provider_reference: "ws_CO_2",
    });
    const s = fakeSettlement([openRow(), second], gateway);
    const summary = await reconcileStuckAttempts(s.deps, opts);
    assert.deepEqual(summary, {
      checked: 2,
      applied: 1,
      stillPending: 0,
      errors: 1,
    });
    assert.equal(s.applied.length, 1);
  });

  it("skips attempts with no reference and ones already settled", async () => {
    const { gateway, http } = gatewayWith(queryReply("0"));
    const s = fakeSettlement([openRow({ provider_reference: null })], gateway);
    s.deps.ports.listProcessing = () =>
      Promise.resolve({
        data: [
          openRow({ provider_reference: null }),
          openRow({ status: "succeeded" }),
        ],
        error: null,
      });
    const summary = await reconcileStuckAttempts(s.deps, opts);
    assert.equal(summary.checked, 0);
    assert.equal(http.requests.length, 0);
  });
});

// ---------------------------------------------------------------- start payment with the M-Pesa gateway

describe("start payment: M-Pesa", () => {
  function mpesaPorts(over: Partial<PaymentPorts> = {}) {
    const calls = { readMy: 0, createAttempt: 0 };
    const good = (data: unknown): RpcResult => ({ data, error: null });
    const ports: PaymentPorts = {
      readMyPayments: () => {
        calls.readMy += 1;
        return Promise.resolve(good({ order_id: ORDER, transactions: [] }));
      },
      getOrderForPayment: () =>
        Promise.resolve(
          good({ id: ORDER, total_cents: AMOUNT_CENTS, currency: "KES" }),
        ),
      createAttempt: () => {
        calls.createAttempt += 1;
        return Promise.resolve(
          good({
            changed: true,
            transaction: {
              id: TXN,
              provider: MPESA_PROVIDER,
              method: "mpesa",
              amount_cents: AMOUNT_CENTS,
              currency: "KES",
              status: "pending",
            },
          }),
        );
      },
      markProcessing: (_id, ref) =>
        Promise.resolve(
          good({
            changed: true,
            transaction: {
              id: TXN,
              provider: MPESA_PROVIDER,
              method: "mpesa",
              amount_cents: AMOUNT_CENTS,
              currency: "KES",
              status: "processing",
              provider_reference: ref,
            },
          }),
        ),
      recordCod: () => Promise.reject(new Error("not used")),
      ...over,
    };
    return { ports, calls };
  }

  async function code(p: Promise<unknown>): Promise<string> {
    try {
      await p;
    } catch (e) {
      if (e instanceof PaymentStartError) return e.code;
      throw e;
    }
    return "no_error";
  }

  it("a bad phone is rejected before any database call", async () => {
    const { gateway } = gatewayWith();
    const { ports, calls } = mpesaPorts();
    for (const phone of [undefined, "", "12345", "0212345678"]) {
      const input = parseStartPaymentInput({
        orderId: ORDER,
        method: "mpesa",
        ...(phone === undefined ? {} : { phone }),
      });
      assert.equal(
        await code(startPayment(ports, input, [gateway])),
        "invalid_phone",
        String(phone),
      );
    }
    assert.equal(calls.readMy + calls.createAttempt, 0);
  });

  it("a valid phone pushes the DB amount and ends in 'processing' with the CheckoutRequestID", async () => {
    const { gateway, http } = gatewayWith();
    const { ports } = mpesaPorts();
    const input = parseStartPaymentInput({
      orderId: ORDER,
      method: "mpesa",
      phone: "0712 345 678",
      amountCents: 1,
    });
    const result = await startPayment(ports, input, [gateway]);
    assert.deepEqual(result, {
      kind: "initiated",
      transactionId: TXN,
      status: "processing",
      next: { type: "prompt_sent" },
    });
    const push = http.requests.find((r) => r.url.includes("stkpush"));
    const body = JSON.parse(push?.body ?? "{}") as Record<string, unknown>;
    assert.equal(body["Amount"], 1250);
    assert.equal(body["PhoneNumber"], PHONE_DIGITS);
  });

  it("an order total with cents cannot be paid by M-Pesa and creates no attempt", async () => {
    const { gateway, http } = gatewayWith();
    const { ports, calls } = mpesaPorts({
      getOrderForPayment: () =>
        Promise.resolve({
          data: { id: ORDER, total_cents: 125050, currency: "KES" },
          error: null,
        }),
    });
    const input = parseStartPaymentInput({
      orderId: ORDER,
      method: "mpesa",
      phone: "0712345678",
    });
    assert.equal(
      await code(startPayment(ports, input, [gateway])),
      "amount_invalid",
    );
    assert.equal(calls.createAttempt, 0);
    assert.equal(http.requests.length, 0);
  });

  it("parseStartPaymentInput keeps a phone and drops oversize ones", () => {
    assert.deepEqual(
      parseStartPaymentInput({
        orderId: ORDER,
        method: "mpesa",
        phone: "0712345678",
      }),
      {
        orderId: ORDER,
        method: "mpesa",
        phone: "0712345678",
      },
    );
    assert.deepEqual(
      parseStartPaymentInput({
        orderId: ORDER,
        method: "mpesa",
        phone: "0".repeat(40),
      }),
      {
        orderId: ORDER,
        method: "mpesa",
      },
    );
  });
});
