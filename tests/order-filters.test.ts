import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { isOrderOpen } from "../src/features/orders/status.ts";
import {
  filterOrders,
  matchesOrderFilter,
} from "../src/features/orders/order-filters.ts";
import type { OrderStatus } from "../src/lib/supabase/types.ts";

const ALL: OrderStatus[] = [
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

describe("order filters", () => {
  it("'all' keeps every order", () => {
    for (const status of ALL)
      assert.equal(matchesOrderFilter(status, "all"), true);
  });
  it("every status falls in exactly one of open, delivered, closed", () => {
    for (const status of ALL) {
      const hits = (["open", "delivered", "closed"] as const).filter((f) =>
        matchesOrderFilter(status, f),
      );
      assert.equal(hits.length, 1, status);
    }
  });
  it("'open' agrees with the existing isOrderOpen()", () => {
    for (const status of ALL) {
      const open = matchesOrderFilter(status, "open");
      assert.equal(open, isOrderOpen(status), status);
    }
  });
  it("filters rows by their stored status and keeps order", () => {
    const rows = [
      { id: 1, status: "delivered" as const },
      { id: 2, status: "cancelled" as const },
      { id: 3, status: "picking" as const },
    ];
    assert.deepEqual(
      filterOrders(rows, "closed").map((r) => r.id),
      [2],
    );
    assert.deepEqual(
      filterOrders(rows, "open").map((r) => r.id),
      [3],
    );
  });
});
