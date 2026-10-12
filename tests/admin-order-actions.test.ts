import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminOrderActionError,
  AdminOrderNotFoundError,
  toAdminOrderActionError,
  toAdminSetOrderStatusArgs,
  toAdminSetOrderStatusResult,
} from "../src/features/admin/orders-result.ts";

describe("toAdminOrderActionError", () => {
  it("maps the admin gate refusal to AdminAccessError", () => {
    assert.ok(
      toAdminOrderActionError({
        message: "x",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });
  it("maps permission denied for function (anonymous) to AdminAccessError", () => {
    assert.ok(
      toAdminOrderActionError({
        message: "permission denied",
        code: "42501",
      }) instanceof AdminAccessError,
    );
  });
  it("maps order_not_found", () => {
    assert.ok(
      toAdminOrderActionError({
        message: "x",
        code: "P0001",
        details: "order_not_found",
      }) instanceof AdminOrderNotFoundError,
    );
  });
  it("maps every rule refusal to AdminOrderActionError with its reason and message", () => {
    const reasons = [
      "transition_not_allowed",
      "admin_note_required",
      "override_not_requested",
      "payment_state_reserved",
      "payment_not_confirmed",
      "payment_method_mismatch",
      "note_too_long",
      "invalid_arguments",
      "note_reserved_prefix",
      "reactivation_slot_full",
      "reactivation_slot_closed",
      "reactivation_slot_not_offered",
      "reactivation_insufficient_stock",
    ];
    for (const reason of reasons) {
      const err = toAdminOrderActionError({
        message: `msg ${reason}`,
        code: "P0001",
        details: reason,
      });
      assert.ok(err instanceof AdminOrderActionError, reason);
      assert.equal((err as AdminOrderActionError).reason, reason);
      assert.equal(err.message, `msg ${reason}`);
    }
  });
  it("keeps unknown errors as ordinary errors", () => {
    const err = toAdminOrderActionError({
      message: "boom",
      code: "XX000",
      details: "something_else",
    });
    assert.equal(err.message, "boom");
    assert.ok(!(err instanceof AdminAccessError));
    assert.ok(!(err instanceof AdminOrderActionError));
  });
});

describe("toAdminSetOrderStatusArgs", () => {
  it("uses explicit defaults: no note, no override", () => {
    assert.deepEqual(
      toAdminSetOrderStatusArgs({ orderId: "o1", status: "processing" }),
      {
        p_order_id: "o1",
        p_status: "processing",
        p_note: null,
        p_override: false,
      },
    );
  });
  it("trims the note and nulls a blank one", () => {
    assert.equal(
      toAdminSetOrderStatusArgs({
        orderId: "o1",
        status: "cancelled",
        note: "  called  ",
      }).p_note,
      "called",
    );
    assert.equal(
      toAdminSetOrderStatusArgs({
        orderId: "o1",
        status: "cancelled",
        note: "   ",
      }).p_note,
      null,
    );
  });
  it("sends override only when it is exactly true", () => {
    assert.equal(
      toAdminSetOrderStatusArgs({
        orderId: "o1",
        status: "picking",
        override: true,
      }).p_override,
      true,
    );
    assert.equal(
      toAdminSetOrderStatusArgs({
        orderId: "o1",
        status: "picking",
        override: false,
      }).p_override,
      false,
    );
  });
  it("never sends a payment field or a user id", () => {
    const keys = Object.keys(
      toAdminSetOrderStatusArgs({ orderId: "o1", status: "packed" }),
    ).sort();
    assert.deepEqual(keys, ["p_note", "p_order_id", "p_override", "p_status"]);
  });
});

describe("toAdminSetOrderStatusResult", () => {
  const order = { id: "o1", status: "processing" };
  it("accepts a changed result with its history entry", () => {
    const data = {
      changed: true,
      previous_status: "pending",
      order,
      history_entry: { id: "h1" },
    };
    assert.equal(toAdminSetOrderStatusResult(data), data);
  });
  it("accepts an unchanged result with a null history entry", () => {
    const data = {
      changed: false,
      previous_status: "delivered",
      order,
      history_entry: null,
    };
    assert.equal(toAdminSetOrderStatusResult(data), data);
  });
  it("rejects malformed payloads", () => {
    assert.throws(() => toAdminSetOrderStatusResult(null));
    assert.throws(() => toAdminSetOrderStatusResult({ changed: "yes", order }));
    assert.throws(() =>
      toAdminSetOrderStatusResult({ changed: false, order: null }),
    );
    assert.throws(() =>
      toAdminSetOrderStatusResult({
        changed: true,
        previous_status: "pending",
        order,
        history_entry: null,
      }),
    );
  });
});
