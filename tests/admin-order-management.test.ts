import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  describeStatusChangeError,
  getPageInfo,
  getStatusOptions,
  isConsequentialStatus,
  parseOrderListParams,
  toOrderListFilters,
} from "../src/features/admin/order-management.ts";
import {
  AdminOrderActionError,
  AdminOrderNotFoundError,
  toAdminListOrdersArgs,
} from "../src/features/admin/orders-result.ts";

describe("parseOrderListParams", () => {
  it("keeps valid values and trims the search", () => {
    assert.deepEqual(
      parseOrderListParams({
        q: "  ORD-1 ",
        status: "pending",
        payment: "paid",
        page: "3",
      }),
      { q: "ORD-1", status: "pending", payment: "paid", page: 3 },
    );
  });

  it("drops unknown statuses, blank search and bad pages", () => {
    assert.deepEqual(
      parseOrderListParams({
        q: "   ",
        status: "shipped",
        payment: "nope",
        page: "-2",
      }),
      {},
    );
    assert.deepEqual(parseOrderListParams({ page: "1" }), {});
    assert.deepEqual(parseOrderListParams({ page: "2.5" }), {});
  });

  it("caps an over-long search at the database limit", () => {
    assert.equal(parseOrderListParams({ q: "x".repeat(300) }).q?.length, 100);
  });
});

describe("toOrderListFilters", () => {
  it("maps page 1 to offset 0 and page 3 to offset 50", () => {
    assert.equal(toOrderListFilters({}).offset, 0);
    assert.equal(toOrderListFilters({ page: 3 }).offset, 50);
  });

  it("produces the RPC arguments the backend expects", () => {
    const args = toAdminListOrdersArgs(
      toOrderListFilters({
        q: "amina",
        status: "packed",
        payment: "pending",
        page: 2,
      }),
    );
    assert.deepEqual(args, {
      p_search: "amina",
      p_status: "packed",
      p_payment_status: "pending",
      p_payment_method: null,
      p_placed_from: null,
      p_placed_to: null,
      p_limit: 25,
      p_offset: 25,
    });
  });
});

describe("getPageInfo", () => {
  it("describes a middle page", () => {
    assert.deepEqual(getPageInfo(60, 25, 25, 25), {
      page: 2,
      pageCount: 3,
      from: 26,
      to: 50,
      hasPrevious: true,
      hasNext: true,
    });
  });

  it("describes an empty result", () => {
    const info = getPageInfo(0, 25, 0, 0);
    assert.equal(info.from, 0);
    assert.equal(info.hasNext, false);
    assert.equal(info.pageCount, 1);
  });

  it("describes a last short page", () => {
    assert.equal(getPageInfo(51, 25, 50, 1).hasNext, false);
  });
});

describe("getStatusOptions", () => {
  const cod = {
    payment_method: "cash_on_delivery",
    payment_status: "pending",
  } as const;

  it("offers the standard moves only", () => {
    assert.deepEqual(
      getStatusOptions({ status: "pending", ...cod }).map((o) => o.status),
      ["processing", "cancelled"],
    );
    assert.deepEqual(
      getStatusOptions({ status: "dispatched", ...cod }).map((o) => o.status),
      ["out_for_delivery", "delivered", "cancelled"],
    );
  });

  it("never offers paid or refunded, and nothing from a final status", () => {
    for (const status of ["delivered", "cancelled", "refunded"] as const) {
      assert.deepEqual(getStatusOptions({ status, ...cod }), []);
    }
    const all = (
      [
        "pending",
        "awaiting_payment",
        "paid",
        "processing",
        "picking",
        "packed",
        "dispatched",
        "out_for_delivery",
      ] as const
    ).flatMap((status) =>
      getStatusOptions({ status, ...cod }).map((o) => o.status),
    );
    assert.ok(!all.includes("paid" as never));
    assert.ok(!all.includes("refunded" as never));
  });

  it("blocks fulfilment, but not cancellation, for an unpaid online order", () => {
    const options = getStatusOptions({
      status: "paid",
      payment_method: "mpesa",
      payment_status: "pending",
    });
    assert.ok(options.find((o) => o.status === "processing")?.blockedReason);
    assert.equal(
      options.find((o) => o.status === "cancelled")?.blockedReason,
      null,
    );
  });

  it("does not block a paid online order", () => {
    const options = getStatusOptions({
      status: "paid",
      payment_method: "card",
      payment_status: "paid",
    });
    assert.equal(
      options.find((o) => o.status === "processing")?.blockedReason,
      null,
    );
  });
});

describe("isConsequentialStatus", () => {
  it("flags cancel and deliver only", () => {
    assert.equal(isConsequentialStatus("cancelled"), true);
    assert.equal(isConsequentialStatus("delivered"), true);
    assert.equal(isConsequentialStatus("picking"), false);
  });
});

describe("describeStatusChangeError", () => {
  it("explains known database refusals in the UI's own words", () => {
    assert.match(
      describeStatusChangeError(
        new AdminOrderActionError("raw db text", "payment_not_confirmed"),
      ),
      /not been paid/,
    );
  });

  it("falls back to a generic message and never leaks raw errors", () => {
    const message = describeStatusChangeError(
      new Error('relation "orders" violates constraint'),
    );
    assert.doesNotMatch(message, /relation|constraint/);
    assert.doesNotMatch(
      describeStatusChangeError(
        new AdminOrderActionError("raw db text", "unknown"),
      ),
      /raw db text/,
    );
  });

  it("recognises access and not-found errors", () => {
    assert.match(
      describeStatusChangeError(new AdminAccessError()),
      /permission/,
    );
    assert.match(
      describeStatusChangeError(new AdminOrderNotFoundError()),
      /not be found/,
    );
  });
});
