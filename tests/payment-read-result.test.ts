import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  PaymentNotFoundError,
  toAdminListPaymentTransactionsArgs,
  toAdminPaymentReadError,
  toAdminPaymentTransactionDetail,
  toAdminPaymentTransactionList,
  toMyOrderPayments,
  toMyOrderPaymentsError,
} from "../src/features/payments/payment-read-result.ts";

const adminRow = {
  id: "t1",
  order_id: "o1",
  provider: "mpesa-daraja",
  method: "mpesa",
  amount_cents: 125050,
  currency: "KES",
  status: "succeeded",
  provider_reference: "REF1",
  failure_code: null,
  failure_message: null,
  created_at: "2026-10-01T10:00:00Z",
  updated_at: "2026-10-01T10:05:00Z",
  completed_at: "2026-10-01T10:05:00Z",
};
const page = { total_count: 1, limit: 25, offset: 0, transactions: [adminRow] };
const detail = { ...adminRow, idempotency_key: "idem-1" };
const customerRow = {
  id: "t1",
  order_id: "o1",
  method: "mpesa",
  amount_cents: 125050,
  currency: "KES",
  status: "succeeded",
  created_at: "2026-10-01T10:00:00Z",
  completed_at: "2026-10-01T10:05:00Z",
};
const mine = { order_id: "o1", transactions: [customerRow] };

describe("toAdminPaymentTransactionList", () => {
  it("parses a page and keeps cents as integers", () => {
    const list = toAdminPaymentTransactionList(page);
    assert.equal(list.total_count, 1);
    assert.equal(list.limit, 25);
    assert.equal(list.offset, 0);
    assert.equal(list.transactions[0]?.amount_cents, 125050);
    assert.equal(list.transactions[0]?.provider_reference, "REF1");
    assert.equal(list.transactions[0]?.status, "succeeded");
  });

  it("accepts an empty page", () => {
    const list = toAdminPaymentTransactionList({
      ...page,
      total_count: 0,
      transactions: [],
    });
    assert.deepEqual(list.transactions, []);
  });

  it("accepts null or missing optional fields", () => {
    const { provider_reference: _r, failure_code: _c, ...rest } = adminRow;
    const list = toAdminPaymentTransactionList({
      ...page,
      transactions: [
        {
          ...rest,
          failure_message: null,
          completed_at: null,
          status: "pending",
        },
      ],
    });
    const row = list.transactions[0];
    assert.equal(row?.provider_reference, null);
    assert.equal(row?.failure_code, null);
    assert.equal(row?.failure_message, null);
    assert.equal(row?.completed_at, null);
  });

  it("rejects non-objects and bad envelope fields", () => {
    for (const bad of [null, undefined, "x", 5, [], {}]) {
      assert.throws(
        () => toAdminPaymentTransactionList(bad),
        /unexpected response/,
      );
    }
    assert.throws(
      () => toAdminPaymentTransactionList({ ...page, total_count: "1" }),
      /unexpected response/,
    );
    assert.throws(
      () => toAdminPaymentTransactionList({ ...page, offset: -1 }),
      /unexpected response/,
    );
    assert.throws(
      () => toAdminPaymentTransactionList({ ...page, transactions: null }),
      /unexpected response/,
    );
  });

  it("rejects fractional, negative, zero or string cents", () => {
    for (const amount_cents of [10.5, -1, 0, "100", null, Number.NaN]) {
      assert.throws(
        () =>
          toAdminPaymentTransactionList({
            ...page,
            transactions: [{ ...adminRow, amount_cents }],
          }),
        /unexpected response/,
      );
    }
  });

  it("rejects an unknown status or method and a missing id", () => {
    for (const patch of [
      { status: "paid" },
      { status: "" },
      { status: null },
      { method: "bitcoin" },
      { id: "" },
      { id: undefined },
    ]) {
      assert.throws(
        () =>
          toAdminPaymentTransactionList({
            ...page,
            transactions: [{ ...adminRow, ...patch }],
          }),
        /unexpected response/,
      );
    }
  });

  it("accepts every valid status", () => {
    for (const status of [
      "pending",
      "processing",
      "succeeded",
      "failed",
      "cancelled",
      "expired",
    ]) {
      assert.equal(
        toAdminPaymentTransactionList({
          ...page,
          transactions: [{ ...adminRow, status }],
        }).transactions[0]?.status,
        status,
      );
    }
  });

  it("never echoes the payload in the error", () => {
    assert.throws(
      () =>
        toAdminPaymentTransactionList({
          ...page,
          transactions: [
            { ...adminRow, provider_reference: 7, secret: "TOPSECRET" },
          ],
        }),
      (e: unknown) => e instanceof Error && !e.message.includes("TOPSECRET"),
    );
  });
});

describe("toAdminPaymentTransactionDetail", () => {
  it("adds idempotency_key", () => {
    const d = toAdminPaymentTransactionDetail(detail);
    assert.equal(d.idempotency_key, "idem-1");
    assert.equal(d.amount_cents, 125050);
  });

  it("requires idempotency_key and a record", () => {
    assert.throws(
      () => toAdminPaymentTransactionDetail(adminRow),
      /unexpected response/,
    );
    assert.throws(
      () => toAdminPaymentTransactionDetail({ ...detail, idempotency_key: "" }),
      /unexpected response/,
    );
    for (const bad of [null, undefined, "x", []]) {
      assert.throws(
        () => toAdminPaymentTransactionDetail(bad),
        /unexpected response/,
      );
    }
  });
});

describe("toMyOrderPayments", () => {
  it("parses exactly the eight safe fields", () => {
    const out = toMyOrderPayments(mine);
    assert.equal(out.order_id, "o1");
    assert.deepEqual(Object.keys(out.transactions[0] ?? {}).sort(), [
      "amount_cents",
      "completed_at",
      "created_at",
      "currency",
      "id",
      "method",
      "order_id",
      "status",
    ]);
  });

  it("drops hidden fields even if the server sends them", () => {
    const leaky = {
      ...customerRow,
      provider: "mpesa-daraja",
      provider_reference: "REF1",
      failure_code: "F1",
      failure_message: "declined",
      idempotency_key: "idem-1",
      updated_at: "2026-10-01T10:05:00Z",
    };
    const out = toMyOrderPayments({
      ...mine,
      transactions: [leaky],
      extra: "x",
    });
    const row = out.transactions[0] as unknown as Record<string, unknown>;
    for (const hidden of [
      "provider",
      "provider_reference",
      "failure_code",
      "failure_message",
      "idempotency_key",
      "updated_at",
    ]) {
      assert.equal(hidden in row, false, `${hidden} must not be exposed`);
    }
    assert.equal("extra" in out, false);
    assert.equal(JSON.stringify(out).includes("REF1"), false);
  });

  it("accepts an empty list and a null completed_at", () => {
    assert.deepEqual(
      toMyOrderPayments({ ...mine, transactions: [] }).transactions,
      [],
    );
    const out = toMyOrderPayments({
      ...mine,
      transactions: [{ ...customerRow, status: "pending", completed_at: null }],
    });
    assert.equal(out.transactions[0]?.completed_at, null);
  });

  it("rejects bad input", () => {
    for (const bad of [null, undefined, "x", 5, [], {}]) {
      assert.throws(() => toMyOrderPayments(bad), /unexpected response/);
    }
    assert.throws(
      () => toMyOrderPayments({ ...mine, transactions: null }),
      /unexpected response/,
    );
    for (const patch of [
      { amount_cents: 1.5 },
      { amount_cents: -5 },
      { amount_cents: "100" },
      { status: "paid" },
      { id: undefined },
    ]) {
      assert.throws(
        () =>
          toMyOrderPayments({
            ...mine,
            transactions: [{ ...customerRow, ...patch }],
          }),
        /unexpected response/,
      );
    }
  });
});

describe("error mapping", () => {
  it("maps not_authorised to AdminAccessError for admin calls", () => {
    assert.ok(
      toAdminPaymentReadError({
        message: "raw",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminPaymentReadError({
        message: "permission denied for function",
        code: "42501",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminPaymentReadError({
        message: "raw",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("maps not-found and invalid arguments without echoing raw text", () => {
    const e1 = toAdminPaymentReadError({
      message: "DB INTERNAL 1",
      code: "P0001",
      details: "transaction_not_found",
    });
    assert.ok(e1 instanceof PaymentNotFoundError && e1.kind === "transaction");
    const e2 = toMyOrderPaymentsError({
      message: "DB INTERNAL 2",
      code: "P0001",
      details: "order_not_found",
    });
    assert.ok(e2 instanceof PaymentNotFoundError && e2.kind === "order");
    const e3 = toAdminPaymentReadError({
      message: "DB INTERNAL 3",
      code: "P0001",
      details: "invalid_arguments",
    });
    assert.ok(e3 instanceof Error && !(e3 instanceof AdminAccessError));
    for (const e of [e1, e2, e3])
      assert.equal(/DB INTERNAL/.test(e.message), false);
  });

  it("maps signed-out to a plain Error for the customer call", () => {
    const e = toMyOrderPaymentsError({
      message: "raw",
      code: "42501",
      details: "not_authorised",
    });
    assert.ok(e instanceof Error && !(e instanceof AdminAccessError));
    assert.equal(/raw/.test(e.message), false);
  });

  it("falls back to a fixed message and never leaks unknown DB text", () => {
    assert.equal(
      toAdminPaymentReadError({ message: "relation x does not exist" }).message,
      "Payment records could not be loaded.",
    );
    assert.equal(
      toMyOrderPaymentsError({ message: "relation x does not exist" }).message,
      "Your payments could not be loaded.",
    );
  });
});

describe("toAdminListPaymentTransactionsArgs", () => {
  it("uses explicit defaults 25/0 and nulls", () => {
    assert.deepEqual(toAdminListPaymentTransactionsArgs(), {
      p_order_id: null,
      p_status: null,
      p_provider: null,
      p_from: null,
      p_to: null,
      p_limit: 25,
      p_offset: 0,
    });
  });

  it("turns a blank or whitespace provider into null and trims real ones", () => {
    assert.equal(
      toAdminListPaymentTransactionsArgs({ provider: "   " }).p_provider,
      null,
    );
    assert.equal(
      toAdminListPaymentTransactionsArgs({ provider: "" }).p_provider,
      null,
    );
    assert.equal(
      toAdminListPaymentTransactionsArgs({ provider: " daraja " }).p_provider,
      "daraja",
    );
  });

  it("passes filters, paging and a zero offset through", () => {
    assert.deepEqual(
      toAdminListPaymentTransactionsArgs({
        orderId: "o1",
        status: "failed",
        provider: "p",
        from: "2026-10-01T00:00:00Z",
        to: "2026-10-02T00:00:00Z",
        limit: 50,
        offset: 100,
      }),
      {
        p_order_id: "o1",
        p_status: "failed",
        p_provider: "p",
        p_from: "2026-10-01T00:00:00Z",
        p_to: "2026-10-02T00:00:00Z",
        p_limit: 50,
        p_offset: 100,
      },
    );
  });
});
