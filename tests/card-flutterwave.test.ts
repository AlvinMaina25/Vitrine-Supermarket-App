import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { PaymentGateway } from "../src/features/checkout/payment-providers.ts";
import type {
  HttpRequest,
  HttpResponse,
} from "../src/features/checkout/providers/http.ts";
import {
  FLUTTERWAVE_PROVIDER,
  FlutterwaveError,
  createFlutterwaveCardGateway,
  majorToCents,
  type FlutterwaveConfig,
} from "../src/features/checkout/providers/flutterwave.ts";
import { handleCardWebhook } from "../src/features/payments/card-settlement.ts";
import type {
  ApplyOutcomeArgs,
  SettlementDeps,
  SettlementPorts,
} from "../src/features/payments/mpesa-settlement.ts";
import {
  PaymentStartError,
  startPayment,
  type PaymentPorts,
  type RpcResult,
} from "../src/features/payments/start-payment.ts";

// All values below are fixtures. Nothing here is a real key, hash, email or payload.
const SECRET_HASH = "test-secret-hash-123456";
const CONFIG: FlutterwaveConfig = {
  secretKey: "FLWSECK_TEST-fixture-key-X",
  webhookSecret: SECRET_HASH,
  returnBaseUrl: "https://shop.example",
};
const ORDER = "11111111-1111-4111-8111-111111111111";
const ATTEMPT = "22222222-2222-4222-8222-222222222222";
const OTHER_ATTEMPT = "33333333-3333-4333-8333-333333333333";
const EMAIL = "customer@example.com";
const FLW_ID = 285959875;
const HASH_HEADER = { "verif-hash": SECRET_HASH } as const;

// ---------------------------------------------------------------- fakes

class FakeHttp {
  readonly requests: HttpRequest[] = [];
  private readonly respond: (req: HttpRequest) => HttpResponse | Error;
  constructor(respond: (req: HttpRequest) => HttpResponse | Error) {
    this.respond = respond;
  }
  request(req: HttpRequest): Promise<HttpResponse> {
    this.requests.push(req);
    const out = this.respond(req);
    return out instanceof Error ? Promise.reject(out) : Promise.resolve(out);
  }
}

function verifyBody(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    status: "success",
    message: "Transaction fetched successfully",
    data: {
      id: FLW_ID,
      tx_ref: ATTEMPT,
      flw_ref: "FLW-FIXTURE-REF",
      amount: 1500,
      currency: "KES",
      status: "successful",
      processor_response: "Approved",
      ...over,
    },
  });
}

function hookBody(
  over: Record<string, unknown> = {},
  event = "charge.completed",
): string {
  return JSON.stringify({
    event,
    data: {
      id: FLW_ID,
      tx_ref: ATTEMPT,
      status: "successful",
      amount: 1500,
      currency: "KES",
      ...over,
    },
  });
}

const createOk = JSON.stringify({
  status: "success",
  message: "Hosted Link",
  data: {
    link: "https://checkout.flutterwave.com/v3/hosted/pay/flwlnk-fixture",
  },
});

function gatewayWith(respond: (req: HttpRequest) => HttpResponse | Error): {
  gateway: PaymentGateway;
  http: FakeHttp;
} {
  const http = new FakeHttp(respond);
  return { gateway: createFlutterwaveCardGateway(CONFIG, http), http };
}

/** Fake Flutterwave: verify answers with the given body; create answers with createOk. */
function flw(verify: string, verifyStatus = 200) {
  return gatewayWith((req) =>
    req.method === "POST"
      ? { status: 200, body: createOk }
      : { status: verifyStatus, body: verify },
  );
}

interface Row {
  id: string;
  provider: string;
  amount_cents: number;
  currency: string;
  status: string;
  provider_reference: string;
}

function fakeDb(rows: Row[], applyError: RpcResult["error"] = null) {
  const applied: ApplyOutcomeArgs[] = [];
  const logs: Array<{
    event: string;
    fields: Record<string, string | number | null>;
  }> = [];
  const ports: SettlementPorts = {
    findByReference: (provider, ref) =>
      Promise.resolve({
        data:
          rows.find(
            (r) => r.provider === provider && r.provider_reference === ref,
          ) ?? null,
        error: null,
      }),
    listProcessing: () => Promise.resolve({ data: [], error: null }),
    applyOutcome: (args) => {
      applied.push(args);
      if (applyError) return Promise.resolve({ data: null, error: applyError });
      const row = rows.find((r) => r.id === args.transactionId);
      if (!row)
        return Promise.resolve({
          data: null,
          error: {
            code: "P0001",
            details: "transaction_not_found",
            message: "",
          },
        });
      if (row.status === args.outcome)
        return Promise.resolve({ data: { changed: false }, error: null });
      if (row.status !== "pending" && row.status !== "processing") {
        return Promise.resolve({
          data: null,
          error: { code: "P0001", details: "invalid_transition", message: "" },
        });
      }
      row.status = args.outcome;
      return Promise.resolve({ data: { changed: true }, error: null });
    },
  };
  return {
    ports,
    applied,
    logs,
    log: (event: string, fields: Record<string, string | number | null>) =>
      logs.push({ event, fields }),
  };
}

function attemptRow(over: Partial<Row> = {}): Row {
  return {
    id: ATTEMPT,
    provider: FLUTTERWAVE_PROVIDER,
    amount_cents: 150000,
    currency: "KES",
    status: "processing",
    provider_reference: ATTEMPT,
    ...over,
  };
}

async function receive(opts: {
  verify?: string;
  verifyStatus?: number;
  body?: string;
  headers?: Record<string, string>;
  rows?: Row[];
  applyError?: RpcResult["error"];
  throwOnVerify?: boolean;
}) {
  const { gateway, http } = opts.throwOnVerify
    ? gatewayWith(() => new Error("network down"))
    : flw(opts.verify ?? verifyBody(), opts.verifyStatus ?? 200);
  const db = fakeDb(opts.rows ?? [attemptRow()], opts.applyError ?? null);
  const deps: SettlementDeps = { gateway, ports: db.ports, log: db.log };
  const reply = await handleCardWebhook(deps, {
    method: "POST",
    url: "https://shop.example/api/public/card-webhook",
    headers: opts.headers ?? HASH_HEADER,
    body: opts.body ?? hookBody(),
  });
  return { reply, db, http };
}

// ---------------------------------------------------------------- initiate

describe("flutterwave card initiate", () => {
  const order = { id: ORDER, totalCents: 150000, currency: "KES" };
  const attempt = {
    transactionId: ATTEMPT,
    provider: FLUTTERWAVE_PROVIDER,
    method: "card" as const,
    amountCents: 150000,
    currency: "KES",
    idempotencyKey: "k",
  };

  it("creates a hosted card checkout for KES with our attempt id as tx_ref", async () => {
    const { gateway, http } = flw(verifyBody());
    const result = await gateway.initiate(order, attempt, {
      phone: null,
      email: EMAIL,
    });
    assert.deepEqual(result, {
      kind: "redirect",
      providerReference: ATTEMPT,
      redirectUrl:
        "https://checkout.flutterwave.com/v3/hosted/pay/flwlnk-fixture",
    });
    const req = http.requests[0]!;
    assert.equal(req.url, "https://api.flutterwave.com/v3/payments");
    assert.equal(req.headers["Authorization"], `Bearer ${CONFIG.secretKey}`);
    const sent = JSON.parse(req.body ?? "") as Record<string, unknown>;
    assert.equal(sent["tx_ref"], ATTEMPT);
    assert.equal(sent["amount"], 1500);
    assert.equal(sent["currency"], "KES");
    assert.equal(sent["payment_options"], "card");
    assert.deepEqual(sent["customer"], { email: EMAIL });
    assert.equal(
      sent["redirect_url"],
      `https://shop.example/api/public/card-return/${ORDER}`,
    );
  });

  it("refuses without a valid email and never calls Flutterwave", async () => {
    for (const email of [undefined, "", "not-an-email", "a b@example.com"]) {
      const { gateway, http } = flw(verifyBody());
      const payer =
        email === undefined ? { phone: null } : { phone: null, email };
      await assert.rejects(
        () => gateway.initiate(order, attempt, payer),
        (e: unknown) =>
          e instanceof FlutterwaveError && e.reason === "email_required",
      );
      assert.equal(http.requests.length, 0);
    }
  });

  it("refuses a non-KES attempt and a non-flutterwave redirect link", async () => {
    const a = flw(verifyBody());
    await assert.rejects(
      () =>
        a.gateway.initiate(
          order,
          { ...attempt, currency: "USD" },
          { phone: null, email: EMAIL },
        ),
      (e: unknown) =>
        e instanceof FlutterwaveError && e.reason === "currency_unsupported",
    );
    const evil = gatewayWith(() => ({
      status: 200,
      body: JSON.stringify({
        status: "success",
        data: { link: "https://evil.example/pay" },
      }),
    }));
    await assert.rejects(
      () =>
        evil.gateway.initiate(order, attempt, { phone: null, email: EMAIL }),
      (e: unknown) =>
        e instanceof FlutterwaveError && e.reason === "bad_response",
    );
  });

  it("converts cents to major units exactly", () => {
    assert.equal(majorToCents(1500), 150000);
    assert.equal(majorToCents(1234.56), 123456);
    assert.equal(majorToCents(0.1 + 0.2 + 1), 130);
    assert.equal(majorToCents(10.005), null);
    assert.equal(majorToCents(0), null);
  });
});

// ---------------------------------------------------------------- startPayment email

describe("startPayment passes the authenticated email to the card gateway", () => {
  function ports(email: string | null | undefined): PaymentPorts {
    const ok = (data: unknown): Promise<RpcResult> =>
      Promise.resolve({ data, error: null });
    const txn = {
      id: ATTEMPT,
      provider: FLUTTERWAVE_PROVIDER,
      method: "card",
      amount_cents: 150000,
      currency: "KES",
      status: "pending",
    };
    const base: PaymentPorts = {
      readMyPayments: () => ok({ order_id: ORDER, transactions: [] }),
      getOrderForPayment: () =>
        ok({ id: ORDER, total_cents: 150000, currency: "KES" }),
      createAttempt: () => ok({ changed: true, transaction: txn }),
      markProcessing: () =>
        ok({ changed: true, transaction: { ...txn, status: "processing" } }),
      recordCod: () => ok({}),
    };
    return email === undefined
      ? base
      : { ...base, readPayerEmail: () => Promise.resolve(email) };
  }

  it("sends the real email and returns the hosted redirect", async () => {
    const { gateway, http } = flw(verifyBody());
    const result = await startPayment(
      ports(EMAIL),
      { orderId: ORDER, method: "card" },
      [gateway],
    );
    assert.equal(result.kind, "initiated");
    const sent = JSON.parse(http.requests[0]?.body ?? "") as {
      customer: { email: string };
    };
    assert.equal(sent.customer.email, EMAIL);
  });

  it("fails clearly with email_required when there is no usable email", async () => {
    for (const email of [null, "bogus", undefined]) {
      const { gateway, http } = flw(verifyBody());
      await assert.rejects(
        () =>
          startPayment(ports(email), { orderId: ORDER, method: "card" }, [
            gateway,
          ]),
        (e: unknown) =>
          e instanceof PaymentStartError && e.code === "email_required",
      );
      assert.equal(http.requests.length, 0);
    }
  });
});

// ---------------------------------------------------------------- webhook

describe("flutterwave card webhook", () => {
  it("valid hash + verified success marks the attempt succeeded (and re-verifies with the API)", async () => {
    const { reply, db, http } = await receive({});
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 1);
    assert.deepEqual(
      {
        o: db.applied[0]?.outcome,
        a: db.applied[0]?.amountCents,
        c: db.applied[0]?.currency,
      },
      { o: "succeeded", a: 150000, c: "KES" },
    );
    assert.equal(db.applied[0]?.providerReference, ATTEMPT);
    assert.equal(
      http.requests[0]?.url,
      `https://api.flutterwave.com/v3/transactions/${FLW_ID}/verify`,
    );
  });

  it("failed, cancelled and expired map to the matching outcome with no amount", async () => {
    for (const [status, outcome] of [
      ["failed", "failed"],
      ["cancelled", "cancelled"],
      ["expired", "expired"],
    ] as const) {
      const { reply, db } = await receive({ verify: verifyBody({ status }) });
      assert.equal(reply.status, 200);
      assert.equal(db.applied[0]?.outcome, outcome);
      assert.equal(db.applied[0]?.amountCents, null);
      assert.equal(db.applied[0]?.failureCode, `flutterwave_${status}`);
    }
  });

  it("missing hash -> 401, nothing verified, nothing changed", async () => {
    const { reply, db, http } = await receive({ headers: {} });
    assert.equal(reply.status, 401);
    assert.equal(db.applied.length, 0);
    assert.equal(http.requests.length, 0);
  });

  it("wrong hash -> 401, even with a body that would otherwise succeed", async () => {
    const { reply, db, http } = await receive({
      headers: { "verif-hash": "wrong-hash-value-xx" },
    });
    assert.equal(reply.status, 401);
    assert.equal(db.applied.length, 0);
    assert.equal(http.requests.length, 0);
  });

  it("a malformed body is not parsed past the hash check and changes nothing", async () => {
    const { reply, db } = await receive({ body: "not json at all" });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
  });

  it("tampered body: tx_ref swapped to another attempt is rejected by re-verification", async () => {
    const rows = [
      attemptRow(),
      attemptRow({ id: OTHER_ATTEMPT, provider_reference: OTHER_ATTEMPT }),
    ];
    const { reply, db } = await receive({
      rows,
      body: hookBody({ tx_ref: OTHER_ATTEMPT }),
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
    assert.equal(rows[1]?.status, "processing");
  });

  it("tampered body: a forged 'successful' status is ignored when Flutterwave says failed", async () => {
    const { db } = await receive({
      body: hookBody({ status: "successful", amount: 1 }),
      verify: verifyBody({ status: "failed" }),
    });
    assert.equal(db.applied.length, 1);
    assert.equal(db.applied[0]?.outcome, "failed");
    assert.equal(db.applied[0]?.amountCents, null);
  });

  it("wrong amount from Flutterwave -> recorded failed with amount_mismatch, never paid", async () => {
    const { reply, db } = await receive({
      verify: verifyBody({ amount: 1499 }),
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 1);
    assert.equal(db.applied[0]?.outcome, "failed");
    assert.equal(db.applied[0]?.failureCode, "amount_mismatch");
  });

  it("wrong currency from Flutterwave -> recorded failed with currency_mismatch, never paid", async () => {
    const { db } = await receive({ verify: verifyBody({ currency: "USD" }) });
    assert.equal(db.applied[0]?.outcome, "failed");
    assert.equal(db.applied[0]?.failureCode, "currency_mismatch");
  });

  it("a non-cents amount is treated as an amount mismatch", async () => {
    const { db } = await receive({ verify: verifyBody({ amount: 1500.004 }) });
    assert.equal(db.applied[0]?.outcome, "failed");
    assert.equal(db.applied[0]?.failureCode, "amount_mismatch");
  });

  it("duplicate event changes nothing the second time", async () => {
    const rows = [attemptRow()];
    const first = await receive({ rows });
    const second = await receive({ rows });
    assert.equal(first.reply.status, 200);
    assert.equal(second.reply.status, 200);
    assert.equal(first.db.applied.length, 1);
    assert.equal(second.db.applied.length, 0); // already succeeded: not written again
    assert.equal(rows[0]?.status, "succeeded");
  });

  it("a late success after the attempt was closed is acknowledged, not applied, and flagged", async () => {
    const { reply, db } = await receive({
      rows: [attemptRow({ status: "failed" })],
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
    assert.ok(
      db.logs.some((l) => l.event === "card.webhook.late_success_needs_review"),
    );
  });

  it("unknown reference -> 200, nothing changed", async () => {
    const { reply, db } = await receive({ rows: [] });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
  });

  it("unknown event type -> 200 ignored, without calling Flutterwave", async () => {
    const { reply, db, http } = await receive({
      body: hookBody({}, "transfer.completed"),
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
    assert.equal(http.requests.length, 0);
  });

  it("a still-pending transaction is ignored", async () => {
    const { reply, db } = await receive({
      verify: verifyBody({ status: "pending" }),
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
  });

  it("Flutterwave unreachable or erroring -> 500 so it retries, nothing changed", async () => {
    for (const opts of [{ throwOnVerify: true }, { verifyStatus: 503 }]) {
      const { reply, db } = await receive(opts);
      assert.equal(reply.status, 500);
      assert.equal(db.applied.length, 0);
    }
  });

  it("an unknown transaction on verify (not found) is acknowledged without changes", async () => {
    const { reply, db } = await receive({
      verify: JSON.stringify({
        status: "error",
        message: "No transaction was found for this id",
        data: null,
      }),
      verifyStatus: 400,
    });
    assert.equal(reply.status, 200);
    assert.equal(db.applied.length, 0);
  });

  it("a transient database failure -> 500 (retry); a coded one -> 200", async () => {
    const transient = await receive({
      applyError: { code: "", message: "fetch failed", details: null },
    });
    assert.equal(transient.reply.status, 500);
    const coded = await receive({
      applyError: { code: "P0001", message: "", details: "order_already_paid" },
    });
    assert.equal(coded.reply.status, 200);
  });

  it("logs ids and codes only: no hash, key, email or payload", async () => {
    const { db } = await receive({});
    const text = JSON.stringify(db.logs);
    for (const secret of [
      SECRET_HASH,
      CONFIG.secretKey,
      EMAIL,
      "FLW-FIXTURE-REF",
      "Approved",
    ]) {
      assert.ok(!text.includes(secret));
    }
  });
});
