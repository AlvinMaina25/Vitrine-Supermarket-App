import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type {
  HttpClient,
  HttpRequest,
} from "../src/features/checkout/providers/http.ts";
import {
  PROVIDER_ENV,
  classifyStatus,
  getProvider,
} from "../src/features/notifications/providers.ts";
import { buildMessage } from "../src/features/notifications/templates.ts";
import {
  CHANNELS,
  EVENT_TYPES,
  parseClaimedNotifications,
  type Channel,
  type ClaimedNotification,
  type CompleteOutcome,
  type NotificationProvider,
  type SendResult,
} from "../src/features/notifications/types.ts";
import { run, type WorkerPorts } from "../src/features/notifications/worker.ts";

const ID = "11111111-1111-4111-8111-111111111111";
const USER = "22222222-2222-4222-8222-222222222222";
const ORDER = "33333333-3333-4333-8333-333333333333";
const SECRET = "SECRET-VALUE-abc123";

function fakeHttp(
  status: number,
  body = "{}",
): { http: HttpClient; calls: HttpRequest[] } {
  const calls: HttpRequest[] = [];
  return {
    calls,
    http: {
      request(req) {
        calls.push(req);
        return Promise.resolve({ status, body });
      },
    },
  };
}

const failingHttp: HttpClient = {
  request: () => Promise.reject(new Error(`boom ${SECRET}`)),
};

const FULL_ENV = {
  RESEND_API_KEY: SECRET,
  NOTIFY_EMAIL_FROM: "shop@example.test",
  AT_USERNAME: "user",
  AT_API_KEY: SECRET,
  WHATSAPP_ACCESS_TOKEN: SECRET,
  WHATSAPP_PHONE_NUMBER_ID: "12345",
  WHATSAPP_TEMPLATE_NAME: "order_update",
};

function claimed(
  channel: Channel,
  overrides: Partial<ClaimedNotification> = {},
): ClaimedNotification {
  return {
    id: ID,
    eventType: "order_created",
    entityId: ORDER,
    userId: USER,
    channel,
    orderId: ORDER,
    attempts: 1,
    ...overrides,
  };
}

describe("parseClaimedNotifications", () => {
  const good = {
    id: ID,
    event_type: "order_created",
    entity_id: ORDER,
    user_id: USER,
    channel: "email",
    payload: { order_id: ORDER },
    attempts: 1,
  };

  it("parses a valid row", () => {
    assert.deepEqual(parseClaimedNotifications([good]), [claimed("email")]);
    assert.deepEqual(parseClaimedNotifications([]), []);
  });

  it("rejects malformed data instead of guessing", () => {
    assert.throws(() => parseClaimedNotifications(null));
    assert.throws(() =>
      parseClaimedNotifications([{ ...good, channel: "pigeon" }]),
    );
    assert.throws(() =>
      parseClaimedNotifications([{ ...good, event_type: "x" }]),
    );
    assert.throws(() => parseClaimedNotifications([{ ...good, attempts: -1 }]));
    assert.throws(() =>
      parseClaimedNotifications([{ ...good, payload: null }]),
    );
  });
});

describe("buildMessage", () => {
  const ctx = { orderNumber: "ORD-1042", orderStatus: "out_for_delivery" };

  it("builds every event on every channel, mentioning the order number", () => {
    for (const event of EVENT_TYPES) {
      for (const channel of CHANNELS) {
        const message = buildMessage(event, channel, ctx, "dest");
        assert.ok(message.body.includes("ORD-1042"), `${event}/${channel}`);
        assert.equal(message.to, "dest");
        assert.equal(message.subject !== null, channel === "email");
      }
    }
  });

  it("is deterministic", () => {
    assert.deepEqual(
      buildMessage("order_status_changed", "sms", ctx, "x"),
      buildMessage("order_status_changed", "sms", ctx, "x"),
    );
  });

  it("uses the status label for status updates and a neutral word when unknown", () => {
    assert.match(
      buildMessage("order_status_changed", "sms", ctx, "x").body,
      /out for delivery/,
    );
    assert.match(
      buildMessage(
        "order_status_changed",
        "sms",
        { orderNumber: "A1", orderStatus: "weird" },
        "x",
      ).body,
      /updated/,
    );
  });

  it("carries no payment or money wording and cleans the order number", () => {
    for (const event of EVENT_TYPES) {
      const body = buildMessage(
        event,
        "email",
        { orderNumber: "A1\n<script>", orderStatus: null },
        "x",
      ).body;
      assert.doesNotMatch(body, /KES|\$|card|m-?pesa|amount|total|<|>/i);
    }
    assert.ok(
      buildMessage(
        "order_created",
        "sms",
        { orderNumber: "x".repeat(200), orderStatus: null },
        "t",
      ).body.length < 120,
    );
  });
});

describe("provider registry", () => {
  it("returns null (not configured) with no env", () => {
    for (const channel of CHANNELS)
      assert.equal(getProvider(channel, {}, fakeHttp(200).http), null);
  });

  it("returns null when ANY required variable is missing or blank", () => {
    for (const channel of CHANNELS) {
      for (const name of PROVIDER_ENV[channel]) {
        const env: Record<string, string | undefined> = {
          ...FULL_ENV,
          [name]: undefined,
        };
        assert.equal(
          getProvider(channel, env, fakeHttp(200).http),
          null,
          `${channel} without ${name}`,
        );
        assert.equal(
          getProvider(channel, { ...env, [name]: "  " }, fakeHttp(200).http),
          null,
        );
      }
    }
  });

  it("returns a provider per channel when fully configured", () => {
    for (const channel of CHANNELS) {
      const provider = getProvider(channel, FULL_ENV, fakeHttp(200).http);
      assert.equal(provider?.channel, channel);
    }
  });

  it("does not use any VITE_ variable name", () => {
    for (const channel of CHANNELS)
      for (const name of PROVIDER_ENV[channel])
        assert.doesNotMatch(name, /^VITE_/);
  });
});

describe("classifyStatus", () => {
  it("2xx sent; 408/429/5xx retry; other 4xx permanent", () => {
    assert.deepEqual(classifyStatus(202), { kind: "sent" });
    assert.deepEqual(classifyStatus(429), { kind: "retry", code: "http_429" });
    assert.deepEqual(classifyStatus(503), { kind: "retry", code: "http_503" });
    assert.deepEqual(classifyStatus(422), {
      kind: "permanent",
      code: "http_422",
    });
    assert.deepEqual(classifyStatus(401), {
      kind: "permanent",
      code: "http_401",
    });
  });
});

describe("adapters (fake HTTP, nothing real is called)", () => {
  const message = { to: "+254712345678", subject: "S", body: "B" };

  function provider(channel: Channel, http: HttpClient): NotificationProvider {
    const found = getProvider(channel, FULL_ENV, http);
    assert.ok(found);
    return found;
  }

  it("email: sent on 2xx, key only in the Authorization header", async () => {
    const { http, calls } = fakeHttp(200);
    assert.deepEqual(
      await provider("email", http).send({ ...message, to: "a@b.test" }),
      { kind: "sent" },
    );
    assert.equal(calls[0]?.headers["Authorization"], `Bearer ${SECRET}`);
    assert.ok(
      !calls[0]?.url.includes(SECRET) && !calls[0]?.body?.includes(SECRET),
    );
  });

  it("sms: 2xx alone is not enough, the recipient must be accepted", async () => {
    const ok = JSON.stringify({
      SMSMessageData: { Recipients: [{ status: "Success" }] },
    });
    const rejected = JSON.stringify({
      SMSMessageData: { Recipients: [{ status: "InvalidPhoneNumber" }] },
    });
    assert.deepEqual(
      await provider("sms", fakeHttp(201, ok).http).send(message),
      { kind: "sent" },
    );
    assert.deepEqual(
      await provider("sms", fakeHttp(201, rejected).http).send(message),
      {
        kind: "retry",
        code: "sms_not_accepted",
      },
    );
    assert.deepEqual(
      await provider("sms", fakeHttp(200, "not json").http).send(message),
      {
        kind: "retry",
        code: "sms_not_accepted",
      },
    );
  });

  it("whatsapp: needs a message id in the answer; strips the plus", async () => {
    const accepted = fakeHttp(
      200,
      JSON.stringify({ messages: [{ id: "wamid.1" }] }),
    );
    assert.deepEqual(await provider("whatsapp", accepted.http).send(message), {
      kind: "sent",
    });
    assert.match(accepted.calls[0]?.body ?? "", /"to":"254712345678"/);
    assert.deepEqual(
      await provider("whatsapp", fakeHttp(200, "{}").http).send(message),
      {
        kind: "retry",
        code: "whatsapp_not_accepted",
      },
    );
  });

  it("a network failure is a retry and never leaks the error text", async () => {
    for (const channel of CHANNELS) {
      const result = await provider(channel, failingHttp).send(message);
      assert.deepEqual(result, { kind: "retry", code: "network_error" });
    }
  });

  it("provider errors give a status code only, never the response body", async () => {
    const result = await provider(
      "email",
      fakeHttp(422, `bad key ${SECRET}`).http,
    ).send(message);
    assert.deepEqual(result, { kind: "permanent", code: "http_422" });
  });
});

interface Harness {
  ports: WorkerPorts;
  completed: Array<{
    id: string;
    outcome: CompleteOutcome;
    error: string | null;
  }>;
  lookups: string[];
  logs: string[];
  sent: string[];
}

function harness(opts: {
  rows: ClaimedNotification[];
  result?: SendResult | "throw";
  providerConfigured?: boolean;
  order?: { orderNumber: string; status: string } | null;
  address?: string | null;
  completeThrows?: boolean;
}): Harness {
  const h: Harness = {
    completed: [],
    lookups: [],
    logs: [],
    sent: [],
    ports: undefined as never,
  };
  const result = opts.result ?? { kind: "sent" };
  h.ports = {
    claim: () => Promise.resolve(opts.rows),
    complete(id, outcome, error) {
      if (opts.completeThrows) return Promise.reject(new Error("db down"));
      h.completed.push({ id, outcome, error });
      return Promise.resolve();
    },
    loadOrder() {
      h.lookups.push("order");
      return Promise.resolve(
        opts.order === undefined
          ? { orderNumber: "ORD-1", status: "processing" }
          : opts.order,
      );
    },
    resolveAddress() {
      h.lookups.push("address");
      return Promise.resolve(
        opts.address === undefined ? "who@example.test" : opts.address,
      );
    },
    getProvider(channel) {
      if (opts.providerConfigured === false) return null;
      return {
        channel,
        name: "fake",
        send(message) {
          h.sent.push(message.to);
          return result === "throw"
            ? Promise.reject(new Error("kaboom"))
            : Promise.resolve(result);
        },
      };
    },
  };
  return h;
}

const log =
  (h: Harness) =>
  (event: string, fields: Record<string, string | number | null>) => {
    h.logs.push(JSON.stringify({ event, ...fields }));
  };

describe("worker run()", () => {
  it("no provider connected: skipped_not_configured, nothing looked up, nothing sent", async () => {
    const h = harness({
      rows: [claimed("email"), claimed("sms", { id: "x" })],
      providerConfigured: false,
    });
    const summary = await run(h.ports, { limit: 20, log: log(h) });
    assert.deepEqual(
      h.completed.map((c) => c.outcome),
      ["skipped_not_configured", "skipped_not_configured"],
    );
    assert.deepEqual(h.lookups, []);
    assert.deepEqual(h.sent, []);
    assert.equal(summary.skippedNotConfigured, 2);
    assert.equal(summary.sent, 0);
  });

  it("reports sent only when the provider accepted", async () => {
    const h = harness({ rows: [claimed("email")] });
    const summary = await run(h.ports, { limit: 20, log: log(h) });
    assert.deepEqual(h.completed, [{ id: ID, outcome: "sent", error: null }]);
    assert.deepEqual(h.sent, ["who@example.test"]);
    assert.equal(summary.sent, 1);
  });

  it("a retryable provider failure is failed with a code; a permanent one is dead", async () => {
    const retry = harness({
      rows: [claimed("email")],
      result: { kind: "retry", code: "http_503" },
    });
    const a = await run(retry.ports, { limit: 20, log: log(retry) });
    assert.deepEqual(retry.completed, [
      { id: ID, outcome: "failed", error: "http_503" },
    ]);
    assert.equal(a.failed, 1);

    const permanent = harness({
      rows: [claimed("email")],
      result: { kind: "permanent", code: "http_422" },
    });
    const b = await run(permanent.ports, { limit: 20, log: log(permanent) });
    assert.deepEqual(permanent.completed, [
      { id: ID, outcome: "dead", error: "http_422" },
    ]);
    assert.equal(b.dead, 1);
  });

  it("the 5th failed attempt is counted as dead (the database does the same)", async () => {
    const h = harness({
      rows: [claimed("email", { attempts: 5 })],
      result: { kind: "retry", code: "http_503" },
    });
    const summary = await run(h.ports, { limit: 20, log: log(h) });
    assert.equal(summary.dead, 1);
    assert.equal(summary.failed, 0);
  });

  it("no address / missing order are dead and nothing is sent", async () => {
    const noAddress = harness({ rows: [claimed("sms")], address: null });
    await run(noAddress.ports, { limit: 20, log: log(noAddress) });
    assert.deepEqual(noAddress.completed, [
      { id: ID, outcome: "dead", error: "no_address" },
    ]);
    assert.deepEqual(noAddress.sent, []);

    const noOrder = harness({ rows: [claimed("email")], order: null });
    await run(noOrder.ports, { limit: 20, log: log(noOrder) });
    assert.deepEqual(noOrder.completed, [
      { id: ID, outcome: "dead", error: "order_not_found" },
    ]);

    const noId = harness({ rows: [claimed("email", { orderId: null })] });
    await run(noId.ports, { limit: 20, log: log(noId) });
    assert.deepEqual(noId.completed, [
      { id: ID, outcome: "dead", error: "missing_order_id" },
    ]);
  });

  it("an unexpected throw becomes a retryable failure and never 'sent'", async () => {
    const h = harness({ rows: [claimed("email")], result: "throw" });
    const summary = await run(h.ports, { limit: 20, log: log(h) });
    assert.deepEqual(h.completed, [
      { id: ID, outcome: "failed", error: "worker_error" },
    ]);
    assert.equal(summary.sent, 0);
  });

  it("if recording fails the row is not counted and the run continues", async () => {
    const h = harness({
      rows: [claimed("email"), claimed("sms", { id: "second" })],
      completeThrows: true,
    });
    const summary = await run(h.ports, { limit: 20, log: log(h) });
    assert.equal(summary.claimed, 2);
    assert.equal(summary.sent, 0);
    assert.equal(h.sent.length, 2);
  });

  it("logs never contain an address, a body or a secret", async () => {
    const h = harness({
      rows: [claimed("email")],
      address: "private.person@example.test",
    });
    await run(h.ports, { limit: 20, log: log(h) });
    const all = h.logs.join("\n");
    assert.doesNotMatch(all, /private\.person|example\.test|ORD-1|Hello/);
  });
});
