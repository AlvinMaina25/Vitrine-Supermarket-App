import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  COD_ALREADY_RECORDED_MESSAGE,
  COD_REASON_MAX_LENGTH,
  canRecordCodPayment,
  describeCodRecordFailure,
  describeCodRefusal,
  validateCodReason,
  type CodRefusalReason,
} from "../src/features/admin/cod-payment.ts";
import type {
  OrderStatus,
  PaymentMethod,
  PaymentStatus,
} from "../src/lib/supabase/types.ts";

const base = {
  payment_method: "cash_on_delivery" as PaymentMethod,
  status: "delivered" as OrderStatus,
  payment_status: "pending" as PaymentStatus,
};

describe("canRecordCodPayment", () => {
  it("is true for a delivered cash on delivery order whose payment is not settled", () => {
    for (const payment_status of [
      "pending",
      "processing",
      "failed",
      "cancelled",
    ] as const) {
      assert.equal(canRecordCodPayment({ ...base, payment_status }), true);
    }
  });

  it("is false once paid, partially refunded or refunded", () => {
    for (const payment_status of [
      "paid",
      "partially_refunded",
      "refunded",
    ] as const) {
      assert.equal(canRecordCodPayment({ ...base, payment_status }), false);
    }
  });

  it("is false for every status except delivered (out_for_delivery is left out on purpose)", () => {
    for (const status of [
      "pending",
      "awaiting_payment",
      "paid",
      "processing",
      "picking",
      "packed",
      "dispatched",
      "out_for_delivery",
      "cancelled",
      "refunded",
    ] as const) {
      assert.equal(canRecordCodPayment({ ...base, status }), false, status);
    }
  });

  it("is false for card and M-Pesa orders", () => {
    for (const payment_method of ["card", "mpesa"] as const) {
      assert.equal(canRecordCodPayment({ ...base, payment_method }), false);
    }
  });
});

describe("validateCodReason", () => {
  it("accepts 3 to 400 characters after trimming", () => {
    assert.equal(validateCodReason("abc"), null);
    assert.equal(validateCodReason("  abc  "), null);
    assert.equal(validateCodReason("a".repeat(COD_REASON_MAX_LENGTH)), null);
  });

  it("refuses empty, whitespace-only and too-short input in plain words", () => {
    assert.match(validateCodReason("") ?? "", /Enter a reason/);
    assert.match(validateCodReason("   ") ?? "", /Enter a reason/);
    assert.match(validateCodReason(" ab ") ?? "", /at least 3/);
  });

  it("refuses more than 400 characters", () => {
    assert.match(
      validateCodReason("a".repeat(COD_REASON_MAX_LENGTH + 1)) ?? "",
      /400 characters or fewer/,
    );
  });

  it("counts characters, not UTF-16 units, like the database", () => {
    // 400 emoji are 800 UTF-16 units but 400 characters.
    assert.equal(validateCodReason("😀".repeat(COD_REASON_MAX_LENGTH)), null);
    assert.notEqual(
      validateCodReason("😀".repeat(COD_REASON_MAX_LENGTH + 1)),
      null,
    );
  });
});

describe("messages", () => {
  const reasons: CodRefusalReason[] = [
    "mfa_required",
    "not_permitted",
    "order_not_found",
    "not_cod_order",
    "not_delivered_yet",
    "already_paid",
    "order_not_payable",
    "amount_invalid",
    "invalid_request",
  ];

  it("has a plain sentence for every refusal and never leaks codes", () => {
    for (const reason of reasons) {
      const text = describeCodRefusal(reason);
      assert.ok(text.length > 10, reason);
      assert.doesNotMatch(text, /_|SQLSTATE|P0001|42501/);
    }
  });

  it("tells the admin to finish two-factor sign-in", () => {
    assert.equal(
      describeCodRefusal("mfa_required"),
      "Complete two-factor sign-in, then try again.",
    );
  });

  it("words the already-recorded case as information, not an error", () => {
    assert.equal(COD_ALREADY_RECORDED_MESSAGE, "Already recorded. Nothing changed.");
  });

  it("separates offline from other failures and never echoes the raw message", () => {
    assert.match(
      describeCodRecordFailure(new TypeError("Failed to fetch"), true),
      /couldn't reach the shop/,
    );
    assert.match(
      describeCodRecordFailure(new Error("anything"), false),
      /couldn't reach the shop/,
    );
    const other = describeCodRecordFailure(new Error("secret db text"), true);
    assert.match(other, /couldn't record the payment/);
    assert.doesNotMatch(other, /secret/);
  });
});
