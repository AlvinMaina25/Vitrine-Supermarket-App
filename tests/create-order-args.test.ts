import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildCreateOrderArgs,
  type PlaceOrderInput,
} from "../src/features/orders/create-order-args.ts";

/**
 * Unit tests for how checkout input becomes create_order() arguments. They do NOT test the
 * database function (see db/tests/create_order_delivery.test.sql).
 */

const input: PlaceOrderInput = {
  items: [{ productId: "p1", variantId: null, quantity: 2 }],
  deliveryMethod: "standard",
  paymentMethod: "cash_on_delivery",
  addressId: "a1",
  zoneId: "z1",
  slotDate: "2026-10-10",
  slotStart: "08:00:00",
  slotEnd: "11:00:00",
  slotLabel: "Morning",
  notes: null,
  idempotencyKey: "key-1",
  expectedTotalCents: 12345,
};

describe("buildCreateOrderArgs", () => {
  it("passes the zone, method and slot window through unchanged", () => {
    const args = buildCreateOrderArgs(input);
    assert.equal(args.p_zone_id, "z1");
    assert.equal(args.p_delivery_method, "standard");
    assert.equal(args.p_slot_date, "2026-10-10");
    assert.equal(args.p_slot_start, "08:00:00");
    assert.equal(args.p_slot_end, "11:00:00");
  });

  it("sends a null zone explicitly when none is chosen", () => {
    const args = buildCreateOrderArgs({ ...input, zoneId: null });
    assert.ok("p_zone_id" in args);
    assert.equal(args.p_zone_id, null);
  });

  it("has no subtotal or delivery fee argument, so a fee cannot be sent", () => {
    const keys = Object.keys(buildCreateOrderArgs(input));
    assert.deepEqual(
      keys.filter((key) => /fee|subtotal/.test(key)),
      [],
    );
  });

  it("sends the displayed total only as the expected-total veto", () => {
    const args = buildCreateOrderArgs(input);
    assert.equal(args.p_expected_total_cents, 12345);
    assert.deepEqual(
      Object.keys(args).filter((key) => /total/.test(key)),
      ["p_expected_total_cents"],
    );
  });

  it("maps basket lines to snake_case without prices", () => {
    const args = buildCreateOrderArgs(input);
    assert.deepEqual(args.p_items, [
      { product_id: "p1", variant_id: null, quantity: 2 },
    ]);
  });
});

describe("buildCreateOrderArgs: coupon code (Phase 8)", () => {
  it("sends the code and nothing else about discounts", () => {
    const args = buildCreateOrderArgs({ ...input, couponCode: "SAVE10" });
    assert.equal(args.p_coupon_code, "SAVE10");
    assert.deepEqual(
      Object.keys(args).filter((key) => /discount|amount|cents/.test(key)),
      ["p_expected_total_cents"],
    );
  });

  it("sends null when no code is given", () => {
    assert.equal(buildCreateOrderArgs(input).p_coupon_code, null);
    assert.equal(
      buildCreateOrderArgs({ ...input, couponCode: null }).p_coupon_code,
      null,
    );
  });
});
