import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { normaliseKenyanPhone } from "../src/features/checkout/providers/mpesa.ts";
import {
  checkMpesaPhone,
  deriveMpesaPanelState,
  formatCountdown,
  interpretMpesaStart,
  mpesaNextPollInterval,
  mpesaPanelCopy,
  PHONE_INVALID_MESSAGE,
  PHONE_REQUIRED_MESSAGE,
  POLL_INTERVAL_MS,
  POLL_MAX_MS,
  type MpesaOrderFacts,
} from "../src/features/payments/mpesa-payment-state.ts";
import type {
  MyOrderPayment,
  MyOrderPayments,
} from "../src/features/payments/payment-read-result.ts";
import type { PaymentTransactionStatus } from "../src/lib/supabase/types.ts";

const ORDER = "11111111-1111-4111-8111-111111111111";

function txn(
  status: PaymentTransactionStatus,
  createdAt: string,
  method: MyOrderPayment["method"] = "mpesa",
  id = createdAt,
): MyOrderPayment {
  return {
    id,
    order_id: ORDER,
    method,
    amount_cents: 100,
    currency: "KES",
    status,
    created_at: createdAt,
    completed_at: null,
  };
}

function payments(...transactions: MyOrderPayment[]): MyOrderPayments {
  return { order_id: ORDER, transactions };
}

const order = (over: Partial<MpesaOrderFacts> = {}): MpesaOrderFacts => ({
  payment_method: "mpesa",
  status: "awaiting_payment",
  payment_status: "pending",
  ...over,
});

describe("deriveMpesaPanelState", () => {
  it("shows nothing for other methods", () => {
    assert.deepEqual(
      deriveMpesaPanelState(order({ payment_method: "card" }), payments()),
      {
        kind: "not_mpesa",
      },
    );
  });

  it("offers to start when there is no M-Pesa attempt (a card attempt does not count)", () => {
    assert.deepEqual(deriveMpesaPanelState(order(), payments()), {
      kind: "start",
    });
    assert.deepEqual(
      deriveMpesaPanelState(
        order(),
        payments(txn("failed", "2026-10-11T10:00:00Z", "card")),
      ),
      { kind: "start" },
    );
  });

  it("waits on pending and processing; never calls them failed", () => {
    for (const status of ["pending", "processing"] as const) {
      assert.deepEqual(
        deriveMpesaPanelState(
          order(),
          payments(txn(status, "2026-10-11T10:00:00Z")),
        ),
        { kind: "in_progress", status },
      );
    }
  });

  it("offers a retry after failed, cancelled and expired", () => {
    for (const reason of ["failed", "cancelled", "expired"] as const) {
      assert.deepEqual(
        deriveMpesaPanelState(
          order(),
          payments(txn(reason, "2026-10-11T10:00:00Z")),
        ),
        { kind: "retry", reason },
      );
    }
  });

  it("uses the latest attempt, not the first", () => {
    const state = deriveMpesaPanelState(
      order(),
      payments(
        txn("failed", "2026-10-11T10:00:00Z"),
        txn("processing", "2026-10-11T10:05:00Z"),
      ),
    );
    assert.deepEqual(state, { kind: "in_progress", status: "processing" });
  });

  it("is paid only when the server says so", () => {
    assert.deepEqual(
      deriveMpesaPanelState(
        order(),
        payments(txn("succeeded", "2026-10-11T10:00:00Z")),
      ),
      { kind: "paid" },
    );
    assert.deepEqual(
      deriveMpesaPanelState(order({ payment_status: "paid" }), payments()),
      {
        kind: "paid",
      },
    );
    // A processing attempt on an unpaid order is not paid.
    assert.notEqual(
      deriveMpesaPanelState(
        order(),
        payments(txn("processing", "2026-10-11T10:00:00Z")),
      ).kind,
      "paid",
    );
  });

  it("closes for cancelled or refunded orders, even after a succeeded attempt", () => {
    const done = payments(txn("succeeded", "2026-10-11T10:00:00Z"));
    assert.deepEqual(
      deriveMpesaPanelState(order({ status: "cancelled" }), done),
      {
        kind: "closed",
      },
    );
    assert.deepEqual(
      deriveMpesaPanelState(order({ payment_status: "refunded" }), done),
      {
        kind: "closed",
      },
    );
    assert.deepEqual(
      deriveMpesaPanelState(order({ payment_status: "cancelled" }), payments()),
      {
        kind: "closed",
      },
    );
  });
});

describe("polling", () => {
  it("polls every 3 s only while in progress, and stops at the limit", () => {
    const waiting = { kind: "in_progress", status: "processing" } as const;
    assert.equal(mpesaNextPollInterval(waiting, 0), POLL_INTERVAL_MS);
    assert.equal(
      mpesaNextPollInterval(waiting, POLL_MAX_MS - 1),
      POLL_INTERVAL_MS,
    );
    assert.equal(mpesaNextPollInterval(waiting, POLL_MAX_MS), false);
    assert.equal(mpesaNextPollInterval({ kind: "start" }, 0), false);
    assert.equal(mpesaNextPollInterval(null, 0), false);
  });

  it("formats the countdown", () => {
    assert.equal(formatCountdown(90_000), "1:30");
    assert.equal(formatCountdown(7_000), "0:07");
    assert.equal(formatCountdown(6_001), "0:07");
    assert.equal(formatCountdown(0), "0:00");
    assert.equal(formatCountdown(-5), "0:00");
  });
});

describe("mpesaPanelCopy", () => {
  it("has no copy for non-M-Pesa orders", () => {
    assert.equal(mpesaPanelCopy({ kind: "not_mpesa" }, false), null);
  });

  it("asks for a phone and shows a button at start and on retry only", () => {
    const start = mpesaPanelCopy({ kind: "start" }, false);
    assert.equal(start?.needsPhone, true);
    assert.equal(start?.action, "Send M-Pesa prompt");
    for (const reason of ["failed", "cancelled", "expired"] as const) {
      const copy = mpesaPanelCopy({ kind: "retry", reason }, false);
      assert.equal(copy?.action, "Try again");
      assert.equal(copy?.needsPhone, true);
      assert.match(copy?.message ?? "", /still waiting for payment/);
    }
    for (const state of [
      { kind: "paid" },
      { kind: "closed" },
      { kind: "in_progress", status: "pending" },
    ] as const) {
      const copy = mpesaPanelCopy(state, false);
      assert.equal(copy?.action, null);
      assert.equal(copy?.needsPhone, false);
    }
  });

  it("tells the three retry reasons apart", () => {
    const text = (reason: "failed" | "cancelled" | "expired") =>
      mpesaPanelCopy({ kind: "retry", reason }, false)?.message;
    assert.match(text("failed") ?? "", /didn't go through/);
    assert.match(text("cancelled") ?? "", /cancelled/);
    assert.match(text("expired") ?? "", /timed out/);
  });

  it("keeps the timed-out wait honest: no retry, no claim of failure", () => {
    const copy = mpesaPanelCopy(
      { kind: "in_progress", status: "processing" },
      true,
    );
    assert.equal(copy?.action, null);
    assert.equal(copy?.title, "Still waiting for confirmation");
    assert.doesNotMatch(copy?.message ?? "", /fail|didn't go through/i);
  });

  it("only says received for the paid state", () => {
    assert.equal(
      mpesaPanelCopy({ kind: "paid" }, false)?.title,
      "Payment received",
    );
    for (const state of [
      { kind: "start" },
      { kind: "in_progress", status: "processing" },
      { kind: "retry", reason: "failed" },
    ] as const) {
      assert.doesNotMatch(
        mpesaPanelCopy(state, false)?.title ?? "",
        /received/i,
      );
    }
  });
});

describe("checkMpesaPhone", () => {
  it("accepts the shapes the server accepts", () => {
    for (const value of [
      "0712345678",
      "0112345678",
      "254712345678",
      "+254 712 345 678",
      "0712-345-678",
    ]) {
      assert.deepEqual(checkMpesaPhone(value), { ok: true }, value);
    }
  });

  it("asks for a number when empty", () => {
    assert.deepEqual(checkMpesaPhone("  "), {
      ok: false,
      message: PHONE_REQUIRED_MESSAGE,
    });
  });

  it("rejects anything else with one clear message", () => {
    for (const value of [
      "071234567",
      "07123456789",
      "0212345678",
      "abc",
      "+0712345678",
      "255712345678",
    ]) {
      assert.deepEqual(
        checkMpesaPhone(value),
        { ok: false, message: PHONE_INVALID_MESSAGE },
        value,
      );
    }
  });

  it("never disagrees with the server's own normaliser", () => {
    const samples = [
      "0712345678",
      "0112345678",
      "254712345678",
      "+254712345678",
      "712345678",
      "0612345678",
      "07123",
      "",
      "  ",
      "0712 345 678",
      "+2547123456789",
      "25471234567",
      "07a2345678",
    ];
    for (const value of samples) {
      assert.equal(
        checkMpesaPhone(value).ok,
        normaliseKenyanPhone(value) !== null,
        JSON.stringify(value),
      );
    }
  });
});

describe("interpretMpesaStart", () => {
  it("waits after a prompt was sent or one is already open", () => {
    assert.deepEqual(
      interpretMpesaStart({
        kind: "initiated",
        transactionId: "t",
        status: "processing",
        next: { type: "prompt_sent" },
      }),
      { type: "waiting" },
    );
    assert.deepEqual(
      interpretMpesaStart({
        kind: "already_in_progress",
        transactionId: "t",
        status: "processing",
      }),
      { type: "waiting" },
    );
  });

  it("refuses to follow a redirect or treat cash as M-Pesa", () => {
    assert.equal(
      interpretMpesaStart({
        kind: "initiated",
        transactionId: "t",
        status: "processing",
        next: { type: "redirect", redirectUrl: "https://example.com" },
      }).type,
      "error",
    );
    assert.equal(
      interpretMpesaStart({
        kind: "cod_recorded",
        transactionId: "t",
        changed: true,
      }).type,
      "error",
    );
  });
});
