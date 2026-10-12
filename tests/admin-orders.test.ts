import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminOrderNotFoundError,
  toAdminListOrdersArgs,
  toAdminOrderDetail,
  toAdminOrderList,
  toAdminOrdersError,
} from "../src/features/admin/orders-result.ts";

describe("toAdminOrdersError", () => {
  it("maps the admin gate refusal to AdminAccessError", () => {
    assert.ok(
      toAdminOrdersError({
        message: "x",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });
  it("maps permission denied for function (anonymous) to AdminAccessError", () => {
    assert.ok(
      toAdminOrdersError({
        message: "permission denied",
        code: "42501",
      }) instanceof AdminAccessError,
    );
  });
  it("maps order_not_found", () => {
    assert.ok(
      toAdminOrdersError({
        message: "x",
        code: "P0001",
        details: "order_not_found",
      }) instanceof AdminOrderNotFoundError,
    );
  });
  it("keeps other errors as ordinary errors", () => {
    const err = toAdminOrdersError({ message: "boom", code: "XX000" });
    assert.equal(err.message, "boom");
    assert.ok(!(err instanceof AdminAccessError));
  });
});

describe("toAdminListOrdersArgs", () => {
  it("uses explicit defaults", () => {
    assert.deepEqual(toAdminListOrdersArgs(), {
      p_search: null,
      p_status: null,
      p_payment_status: null,
      p_payment_method: null,
      p_placed_from: null,
      p_placed_to: null,
      p_limit: 25,
      p_offset: 0,
    });
  });
  it("trims search, nulls blanks and passes filters through", () => {
    const args = toAdminListOrdersArgs({
      search: "  jane  ",
      status: "processing",
      paymentStatus: "paid",
      paymentMethod: "mpesa",
      placedFrom: " ",
      placedTo: "2026-10-04",
      limit: 10,
      offset: 20,
    });
    assert.equal(args.p_search, "jane");
    assert.equal(args.p_status, "processing");
    assert.equal(args.p_payment_status, "paid");
    assert.equal(args.p_payment_method, "mpesa");
    assert.equal(args.p_placed_from, null);
    assert.equal(args.p_placed_to, "2026-10-04");
    assert.equal(args.p_limit, 10);
    assert.equal(args.p_offset, 20);
  });
});

describe("payload checks", () => {
  it("accepts a list payload and rejects a malformed one", () => {
    assert.equal(
      toAdminOrderList({ total: 0, limit: 25, offset: 0, orders: [] }).total,
      0,
    );
    assert.throws(() => toAdminOrderList(null));
    assert.throws(() => toAdminOrderList({ orders: [] }));
    assert.throws(() => toAdminOrderList({ total: 1, orders: "x" }));
  });
  it("accepts a detail payload and rejects a missing key or malformed arrays", () => {
    const ok = {
      order: {},
      customer: null,
      delivery: {},
      payment: {},
      items: [],
      history: [],
    };
    assert.ok(toAdminOrderDetail(ok));
    assert.throws(
      () => toAdminOrderDetail({ ...ok, history: undefined }),
      /history/,
    );
    assert.throws(() => toAdminOrderDetail({ ...ok, items: {} }), /malformed/);
    assert.throws(() => toAdminOrderDetail([]));
  });
});
