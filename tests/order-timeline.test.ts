import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildTimeline,
  CUSTOMER_ORDER_STATUS_WORDING,
  CUSTOMER_PAYMENT_STATUS_WORDING,
  isPaymentChangeRow,
} from "../src/features/orders/timeline.ts";
import type {
  OrderStatus,
  OrderStatusHistoryRow,
  PaymentStatus,
} from "../src/lib/supabase/types.ts";

const ALL_ORDER: OrderStatus[] = [
  "pending",
  "awaiting_payment",
  "paid",
  "processing",
  "picking",
  "packed",
  "dispatched",
  "out_for_delivery",
  "delivered",
  "cancelled",
  "refunded",
];
const ALL_PAYMENT: PaymentStatus[] = [
  "pending",
  "processing",
  "paid",
  "failed",
  "cancelled",
  "refunded",
  "partially_refunded",
];

function row(
  id: string,
  at: string,
  previous: OrderStatus | null,
  next: OrderStatus,
  extra: Partial<OrderStatusHistoryRow> = {},
): OrderStatusHistoryRow {
  return {
    id,
    order_id: "o1",
    previous_status: previous,
    new_status: next,
    payment_status: null,
    changed_by: null,
    note: null,
    created_at: at,
    ...extra,
  };
}

describe("customer wording", () => {
  it("has plain wording for every order and payment status", () => {
    for (const status of ALL_ORDER) {
      const w = CUSTOMER_ORDER_STATUS_WORDING[status];
      assert.ok(w.title.length > 0 && w.description.length > 0, status);
    }
    for (const status of ALL_PAYMENT) {
      const w = CUSTOMER_PAYMENT_STATUS_WORDING[status];
      assert.ok(w.title.length > 0 && w.description.length > 0, status);
    }
  });

  it("makes no promise about time, riders or places", () => {
    const all = [
      ...Object.values(CUSTOMER_ORDER_STATUS_WORDING),
      ...Object.values(CUSTOMER_PAYMENT_STATUS_WORDING),
    ];
    for (const w of all) {
      assert.doesNotMatch(
        `${w.title} ${w.description}`,
        /\b(minutes?|hours?|soon|eta|arrive[sd]? (at|by|in)|rider|driver)\b/i,
      );
    }
  });
});

describe("buildTimeline", () => {
  it("returns no entries for no history (nothing is invented)", () => {
    assert.deepEqual(buildTimeline([]), []);
  });

  it("renders only the recorded rows, with their stored timestamps, oldest first", () => {
    const history = [
      row("a", "2026-10-01T08:00:00Z", null, "pending"),
      row("b", "2026-10-01T08:05:00Z", "pending", "processing"),
    ];
    const entries = buildTimeline(history);
    assert.equal(entries.length, 2);
    assert.deepEqual(
      entries.map((e) => e.at),
      ["2026-10-01T08:00:00Z", "2026-10-01T08:05:00Z"],
    );
    assert.deepEqual(
      entries.map((e) => e.isLatest),
      [false, true],
    );
    assert.equal(entries[1]?.title, "Being prepared");
  });

  it("sorts an unordered input by time, then id", () => {
    const entries = buildTimeline([
      row("b", "2026-10-01T09:00:00Z", "pending", "processing"),
      row("a", "2026-10-01T08:00:00Z", null, "pending"),
    ]);
    assert.deepEqual(
      entries.map((e) => e.id),
      ["a", "b"],
    );
  });

  it("does not mutate its input", () => {
    const history = [
      row("b", "2026-10-01T09:00:00Z", "pending", "processing"),
      row("a", "2026-10-01T08:00:00Z", null, "pending"),
    ];
    buildTimeline(history);
    assert.equal(history[0]?.id, "b");
  });

  it("shows cancelled and refunded as end states, not steps", () => {
    const entries = buildTimeline([
      row("a", "2026-10-01T08:00:00Z", null, "pending"),
      row("b", "2026-10-01T09:00:00Z", "pending", "cancelled"),
      row("c", "2026-10-02T09:00:00Z", "cancelled", "refunded"),
    ]);
    assert.deepEqual(
      entries.map((e) => e.kind),
      ["status", "end", "end"],
    );
  });

  it("labels a payment change by the payment status, as its own kind", () => {
    const paymentRow = row(
      "p",
      "2026-10-01T08:10:00Z",
      "awaiting_payment",
      "awaiting_payment",
      {
        payment_status: "failed",
        note: "Payment status updated to failed",
      },
    );
    assert.equal(isPaymentChangeRow(paymentRow), true);
    const [entry] = buildTimeline([paymentRow]);
    assert.equal(entry?.kind, "payment");
    assert.equal(entry?.title, "Payment didn't go through");
    assert.equal(
      entry?.note,
      null,
      "the database's boilerplate note is hidden",
    );
  });

  it("a payment status on a row where the order status moved is still an order step", () => {
    const moved = row("m", "2026-10-01T08:10:00Z", "awaiting_payment", "paid", {
      payment_status: "paid",
    });
    assert.equal(isPaymentChangeRow(moved), false);
    assert.equal(buildTimeline([moved])[0]?.kind, "status");
  });

  it("keeps a real recorded note and drops blank ones", () => {
    const entries = buildTimeline([
      row("a", "2026-10-01T08:00:00Z", null, "pending", { note: "  " }),
      row("b", "2026-10-01T09:00:00Z", "pending", "cancelled", {
        note: "Out of stock",
      }),
    ]);
    assert.equal(entries[0]?.note, null);
    assert.equal(entries[1]?.note, "Out of stock");
  });
});
