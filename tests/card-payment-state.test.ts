import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  BAD_REDIRECT_MESSAGE,
  CARD_CONTACT_LINE,
  POLL_INTERVAL_MS,
  POLL_MAX_MS,
  START_FALLBACK_MESSAGE,
  cardPanelCopy,
  clearStartNotice,
  deriveCardPanelState,
  interpretStartResult,
  nextPollInterval,
  peekStartNotice,
  pollTimeRemaining,
  rememberStartNotice,
  safeHttpsUrl,
  startErrorMessage,
  type CardOrderFacts,
} from "../src/features/payments/card-payment-state.ts";
import type {
  MyOrderPayment,
  MyOrderPayments,
} from "../src/features/payments/payment-read-result.ts";
import {
  isProviderSelectable,
  paymentProvider,
} from "../src/features/checkout/payment-providers.ts";
import type { PaymentTransactionStatus } from "../src/lib/supabase/types.ts";

const ORDER_ID = "3f2b8c1e-5a4d-4e7b-9c10-2d6f8a1b7e90";

const cardOrder: CardOrderFacts = {
  payment_method: "card",
  status: "awaiting_payment",
  payment_status: "pending",
};

function txn(
  id: string,
  status: PaymentTransactionStatus,
  createdAt: string,
  method: MyOrderPayment["method"] = "card",
): MyOrderPayment {
  return {
    id,
    order_id: ORDER_ID,
    method,
    amount_cents: 1000,
    currency: "KES",
    status,
    created_at: createdAt,
    completed_at: null,
  };
}

function payments(...transactions: MyOrderPayment[]): MyOrderPayments {
  return { order_id: ORDER_ID, transactions };
}

describe("deriveCardPanelState", () => {
  it("shows nothing for non-card orders", () => {
    for (const method of ["cash_on_delivery", "mpesa"]) {
      assert.deepEqual(
        deriveCardPanelState(
          { ...cardOrder, payment_method: method },
          payments(),
        ),
        { kind: "not_card" },
      );
    }
  });

  it("offers payment when there is no attempt", () => {
    assert.deepEqual(deriveCardPanelState(cardOrder, payments()), {
      kind: "start",
    });
  });

  it("ignores attempts of other methods", () => {
    const state = deriveCardPanelState(
      cardOrder,
      payments(txn("a", "succeeded", "2026-01-01T10:00:00Z", "mpesa")),
    );
    assert.deepEqual(state, { kind: "start" });
  });

  it("keeps polling while pending or processing, never calling it failed", () => {
    assert.deepEqual(
      deriveCardPanelState(
        cardOrder,
        payments(txn("a", "pending", "2026-01-01T10:00:00Z")),
      ),
      { kind: "in_progress", status: "pending" },
    );
    assert.deepEqual(
      deriveCardPanelState(
        cardOrder,
        payments(txn("a", "processing", "2026-01-01T10:00:00Z")),
      ),
      { kind: "in_progress", status: "processing" },
    );
  });

  it("is paid only when the database has a succeeded card attempt", () => {
    assert.deepEqual(
      deriveCardPanelState(
        cardOrder,
        payments(txn("a", "succeeded", "2026-01-01T10:00:00Z")),
      ),
      { kind: "paid" },
    );
    // An order row alone never proves payment here.
    assert.notEqual(
      deriveCardPanelState({ ...cardOrder, payment_status: "paid" }, payments())
        .kind,
      "paid",
    );
  });

  it("offers a retry after failed, cancelled or expired", () => {
    for (const reason of ["failed", "cancelled", "expired"] as const) {
      assert.deepEqual(
        deriveCardPanelState(
          cardOrder,
          payments(txn("a", reason, "2026-01-01T10:00:00Z")),
        ),
        { kind: "retry", reason },
      );
    }
  });

  it("uses the latest attempt, not the first", () => {
    const state = deriveCardPanelState(
      cardOrder,
      payments(
        txn("b", "processing", "2026-01-01T10:05:00Z"),
        txn("a", "failed", "2026-01-01T10:00:00Z"),
      ),
    );
    assert.deepEqual(state, { kind: "in_progress", status: "processing" });
  });

  it("stays paid when an older attempt failed", () => {
    const state = deriveCardPanelState(
      cardOrder,
      payments(
        txn("a", "failed", "2026-01-01T10:00:00Z"),
        txn("b", "succeeded", "2026-01-01T10:05:00Z"),
      ),
    );
    assert.deepEqual(state, { kind: "paid" });
  });

  it("offers no payment on a cancelled or refunded order", () => {
    assert.deepEqual(
      deriveCardPanelState({ ...cardOrder, status: "cancelled" }, payments()),
      {
        kind: "closed",
      },
    );
    assert.deepEqual(
      deriveCardPanelState(
        { ...cardOrder, payment_status: "refunded" },
        payments(txn("a", "succeeded", "2026-01-01T10:00:00Z")),
      ),
      { kind: "closed" },
    );
  });
});

describe("polling", () => {
  it("polls every 3 seconds only while in progress and stops after 90 seconds", () => {
    const inProgress = { kind: "in_progress", status: "pending" } as const;
    assert.equal(POLL_INTERVAL_MS, 3000);
    assert.equal(nextPollInterval(inProgress, 0), 3000);
    assert.equal(nextPollInterval(inProgress, POLL_MAX_MS - 1), 3000);
    assert.equal(nextPollInterval(inProgress, POLL_MAX_MS), false);
    assert.equal(nextPollInterval({ kind: "paid" }, 0), false);
    assert.equal(nextPollInterval({ kind: "start" }, 0), false);
    assert.equal(nextPollInterval(null, 0), false);
  });

  it("counts down the time left", () => {
    assert.equal(pollTimeRemaining(0), POLL_MAX_MS);
    assert.equal(pollTimeRemaining(POLL_MAX_MS + 5), 0);
  });
});

describe("cardPanelCopy", () => {
  it("has a pay button for start and retry only", () => {
    assert.equal(
      cardPanelCopy({ kind: "start" }, false)?.action,
      "Pay by card",
    );
    assert.equal(
      cardPanelCopy({ kind: "retry", reason: "failed" }, false)?.action,
      "Pay by card",
    );
    assert.equal(cardPanelCopy({ kind: "paid" }, false)?.action, null);
    assert.equal(
      cardPanelCopy({ kind: "in_progress", status: "processing" }, false)
        ?.action,
      null,
    );
    assert.equal(cardPanelCopy({ kind: "closed" }, false)?.action, null);
    assert.equal(cardPanelCopy({ kind: "not_card" }, false), null);
  });

  it("never says failed while in progress, and tells the customer to refresh after the limit", () => {
    const waiting = cardPanelCopy(
      { kind: "in_progress", status: "processing" },
      false,
    );
    const late = cardPanelCopy(
      { kind: "in_progress", status: "processing" },
      true,
    );
    assert.ok(waiting && !/fail/i.test(`${waiting.title} ${waiting.message}`));
    assert.ok(
      late &&
        /refresh in a moment/i.test(late.message) &&
        !/fail/i.test(late.message),
    );
  });

  it("describes each way a payment can end", () => {
    assert.match(
      cardPanelCopy({ kind: "retry", reason: "failed" }, false)?.message ?? "",
      /didn't go through/,
    );
    assert.match(
      cardPanelCopy({ kind: "retry", reason: "cancelled" }, false)?.message ??
        "",
      /cancelled/,
    );
    assert.match(
      cardPanelCopy({ kind: "retry", reason: "expired" }, false)?.message ?? "",
      /expired/,
    );
  });

  it("has the contact line", () => {
    assert.match(CARD_CONTACT_LINE, /charged/);
    assert.match(CARD_CONTACT_LINE, /order number/);
  });
});

describe("starting a payment", () => {
  it("accepts only https URLs", () => {
    assert.equal(
      safeHttpsUrl("https://checkout.example.com/pay/abc"),
      "https://checkout.example.com/pay/abc",
    );
    for (const bad of [
      "http://x.example",
      "javascript:alert(1)",
      "data:text/html,x",
      "//x.example",
      "not a url",
      "",
      null,
      5,
    ]) {
      assert.equal(safeHttpsUrl(bad), null);
    }
  });

  it("redirects only for an https redirect result", () => {
    assert.deepEqual(
      interpretStartResult({
        kind: "initiated",
        transactionId: "t",
        status: "processing",
        next: { type: "redirect", redirectUrl: "https://pay.example.com/x" },
      }),
      { type: "redirect", url: "https://pay.example.com/x" },
    );
    assert.deepEqual(
      interpretStartResult({
        kind: "initiated",
        transactionId: "t",
        status: "processing",
        next: { type: "redirect", redirectUrl: "http://pay.example.com/x" },
      }),
      { type: "error", message: BAD_REDIRECT_MESSAGE },
    );
  });

  it("keeps polling on already_in_progress and ignores other results", () => {
    assert.deepEqual(
      interpretStartResult({
        kind: "already_in_progress",
        transactionId: "t",
        status: "processing",
      }),
      { type: "in_progress" },
    );
    assert.deepEqual(
      interpretStartResult({
        kind: "initiated",
        transactionId: "t",
        status: "processing",
        next: { type: "prompt_sent" },
      }),
      { type: "none" },
    );
    assert.deepEqual(
      interpretStartResult({
        kind: "cod_recorded",
        transactionId: "t",
        changed: true,
      }),
      { type: "none" },
    );
  });

  it("passes the server's client-safe message through, else a fixed fallback", () => {
    const message =
      "Card payments need an email address on your account. Add one and try again.";
    assert.equal(startErrorMessage(new Error(message)), message);
    assert.equal(startErrorMessage(new Error("  ")), START_FALLBACK_MESSAGE);
    assert.equal(startErrorMessage("boom"), START_FALLBACK_MESSAGE);
  });

  it("hands a failure message to the order page until it is cleared", () => {
    assert.equal(peekStartNotice(ORDER_ID), null);
    rememberStartNotice(ORDER_ID, "msg");
    assert.equal(peekStartNotice(ORDER_ID), "msg");
    assert.equal(peekStartNotice(ORDER_ID), "msg");
    clearStartNotice(ORDER_ID);
    assert.equal(peekStartNotice(ORDER_ID), null);
  });
});

describe("card availability", () => {
  it("makes card selectable only when enabled; other methods are unchanged", () => {
    const card = paymentProvider("card");
    assert.equal(
      isProviderSelectable(card, { cardPaymentsEnabled: false }),
      false,
    );
    assert.equal(
      isProviderSelectable(card, { cardPaymentsEnabled: true }),
      true,
    );
    for (const id of ["cash_on_delivery", "mpesa"] as const) {
      assert.equal(
        isProviderSelectable(paymentProvider(id), {
          cardPaymentsEnabled: false,
        }),
        true,
      );
    }
  });
});
