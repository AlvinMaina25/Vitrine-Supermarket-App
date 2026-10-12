import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { orderNextStep } from "../src/features/orders/next-step.ts";

describe("orderNextStep", () => {
  it("only says the payment is confirmed when the order's payment status is paid", () => {
    assert.match(
      orderNextStep({
        status: "paid",
        payment_method: "mpesa",
        payment_status: "paid",
      }),
      /payment is confirmed/i,
    );
    for (const payment_status of ["pending", "processing", "failed"] as const) {
      assert.doesNotMatch(
        orderNextStep({
          status: "awaiting_payment",
          payment_method: "mpesa",
          payment_status,
        }),
        /payment is confirmed/i,
      );
    }
  });

  it("tells pay-online customers the order is waiting for payment", () => {
    for (const payment_method of ["mpesa", "card"]) {
      assert.match(
        orderNextStep({
          status: "awaiting_payment",
          payment_method,
          payment_status: "pending",
        }),
        /waiting for payment/,
      );
    }
  });

  it("tells cash customers to have the exact amount ready", () => {
    assert.match(
      orderNextStep({
        status: "pending",
        payment_method: "cash_on_delivery",
        payment_status: "pending",
      }),
      /exact amount/,
    );
  });

  it("handles cancelled and refunded orders before anything else", () => {
    assert.match(
      orderNextStep({
        status: "cancelled",
        payment_method: "mpesa",
        payment_status: "pending",
      }),
      /cancelled/,
    );
    assert.match(
      orderNextStep({
        status: "paid",
        payment_method: "card",
        payment_status: "partially_refunded",
      }),
      /refunded/,
    );
  });
});
