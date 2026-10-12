import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { deliveryErrorMessage } from "../src/features/delivery/checkout.ts";
import {
  ACCOUNT_SUSPENDED_MESSAGE,
  extractDeliveryErrorCode,
  isAccountSuspendedDetail,
  isPlaceOrderError,
  PlaceOrderError,
  toPlaceOrderError,
  type PostgrestErrorLike,
} from "../src/features/orders/place-order-error.ts";

/**
 * A PostgREST error as create_order() produces it for a delivery rejection:
 * `raise exception '<message>' using errcode = 'P0001', detail = '<code>'`.
 */
function dbError(
  detail: string | null,
  message = "Raw database wording.",
): PostgrestErrorLike {
  return { message, details: detail, hint: null, code: "P0001" };
}

describe("extractDeliveryErrorCode", () => {
  it("reads the machine-readable code from the exception DETAIL", () => {
    assert.equal(extractDeliveryErrorCode("slot_full"), "slot_full");
    assert.equal(extractDeliveryErrorCode("zone_required"), "zone_required");
    assert.equal(
      extractDeliveryErrorCode("below_minimum_order"),
      "below_minimum_order",
    );
  });

  it("tolerates surrounding whitespace", () => {
    assert.equal(extractDeliveryErrorCode("  slot_closed\n"), "slot_closed");
  });

  it("returns null for anything that is not a delivery code", () => {
    assert.equal(extractDeliveryErrorCode(null), null);
    assert.equal(extractDeliveryErrorCode(undefined), null);
    assert.equal(extractDeliveryErrorCode(""), null);
    assert.equal(extractDeliveryErrorCode("insufficient_stock"), null);
    assert.equal(
      extractDeliveryErrorCode("Key (id)=(1) is not present in table"),
      null,
    );
    assert.equal(extractDeliveryErrorCode(42), null);
  });
});

describe("toPlaceOrderError", () => {
  it("recognises every delivery code and maps it to the customer-facing message", () => {
    const codes = [
      "method_required",
      "method_unknown",
      "method_inactive",
      "zone_required",
      "zone_unknown",
      "zone_inactive",
      "below_minimum_order",
      "unavailable",
      "slot_required",
      "invalid_window",
      "slot_in_past",
      "slot_too_far",
      "slot_unknown",
      "slot_inactive",
      "slot_closed",
      "slot_full",
    ] as const;
    for (const code of codes) {
      const error = toPlaceOrderError(dbError(code));
      assert.equal(error.deliveryCode, code);
      assert.equal(error.message, deliveryErrorMessage(code));
    }
  });

  it("does not show the database's own wording for a delivery error", () => {
    const error = toPlaceOrderError(
      dbError("slot_full", "That delivery slot is full (internal 42)."),
    );
    assert.doesNotMatch(error.message, /internal 42/);
  });

  it("keeps the original error as cause and the database fields for debugging", () => {
    const original = { ...dbError("slot_full", "db message"), hint: "a hint" };
    const error = toPlaceOrderError(original);
    assert.equal(error.cause, original);
    assert.equal(error.databaseMessage, "db message");
    assert.equal(error.databaseDetail, "slot_full");
    assert.equal(error.databaseHint, "a hint");
    assert.equal(error.databaseCode, "P0001");
  });

  it("lets checkout tell delivery errors from unrelated ones", () => {
    const delivery = toPlaceOrderError(dbError("zone_inactive"));
    const stock = toPlaceOrderError(dbError(null, "Only 2 of Milk are left."));
    assert.equal(delivery.deliveryCode, "zone_inactive");
    assert.equal(stock.deliveryCode, null);
  });

  it("leaves the message of an unrelated error unchanged and still preserves it", () => {
    const original = dbError(null, "Only 2 of Milk are left.");
    const error = toPlaceOrderError(original);
    assert.equal(error.message, "Only 2 of Milk are left.");
    assert.equal(error.cause, original);
  });

  it("ignores a DETAIL that is not a delivery code", () => {
    const error = toPlaceOrderError(
      dbError("some other detail", "Basket is empty."),
    );
    assert.equal(error.deliveryCode, null);
    assert.equal(error.message, "Basket is empty.");
    assert.equal(error.databaseDetail, "some other detail");
  });

  it("keeps an ordinary Error's own message and wraps it as cause", () => {
    const original = new TypeError("fetch failed");
    const error = toPlaceOrderError(original);
    assert.equal(error.deliveryCode, null);
    assert.equal(error.message, "fetch failed");
    assert.equal(error.cause, original);
  });

  it("uses a generic message for a thrown value that has no message, and keeps it as cause", () => {
    for (const original of [null, undefined, "boom", 42]) {
      const error = toPlaceOrderError(original);
      assert.equal(error.deliveryCode, null);
      assert.match(error.message, /couldn't place your order/i);
      assert.equal(error.cause, original);
    }
  });

  it("returns an existing PlaceOrderError unchanged", () => {
    const first = toPlaceOrderError(dbError("slot_full"));
    assert.equal(toPlaceOrderError(first), first);
  });

  it("is a real Error with a stable name", () => {
    const error = toPlaceOrderError(dbError("slot_full"));
    assert.ok(error instanceof Error);
    assert.ok(error instanceof PlaceOrderError);
    assert.equal(isPlaceOrderError(error), true);
    assert.equal(isPlaceOrderError(new Error("x")), false);
    assert.equal(error.name, "PlaceOrderError");
  });
});

describe("account_suspended", () => {
  it("maps the DETAIL to a fixed message and never shows the database wording", () => {
    const error = toPlaceOrderError(
      dbError("account_suspended", "Account is suspended (raw)."),
    );
    assert.equal(error.accountSuspended, true);
    assert.equal(error.deliveryCode, null);
    assert.equal(error.message, ACCOUNT_SUSPENDED_MESSAGE);
    assert.doesNotMatch(error.message, /raw|suspended \(/i);
    assert.equal(error.databaseDetail, "account_suspended");
    assert.equal(error.databaseCode, "P0001");
  });

  it("tolerates whitespace and ignores other details", () => {
    assert.equal(isAccountSuspendedDetail("  account_suspended\n"), true);
    assert.equal(isAccountSuspendedDetail("account_suspended_x"), false);
    assert.equal(isAccountSuspendedDetail(null), false);
    assert.equal(isAccountSuspendedDetail(42), false);
    assert.equal(
      toPlaceOrderError(dbError("slot_full")).accountSuspended,
      false,
    );
    assert.equal(
      toPlaceOrderError(dbError(null, "Basket is empty.")).accountSuspended,
      false,
    );
  });
});

describe("toPlaceOrderError: coupon rejections (Phase 8)", () => {
  it("maps coupon_<code> to the safe customer message and keeps the code", () => {
    const error = toPlaceOrderError(
      dbError("coupon_expired", "That coupon cannot be applied."),
    );
    assert.equal(error.couponCode, "expired");
    assert.equal(error.message, "This coupon has expired.");
    assert.equal(error.deliveryCode, null);
  });

  it("leaves non-coupon errors without a coupon code", () => {
    assert.equal(toPlaceOrderError(dbError("slot_full")).couponCode, null);
    assert.equal(
      toPlaceOrderError(dbError("coupon_reactivation_limit_reached"))
        .couponCode,
      null,
    );
  });
});
