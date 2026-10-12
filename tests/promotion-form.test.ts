import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  basisPointsToPercentText,
  describePromotionValue,
  EMPTY_PROMOTION_FORM,
  nairobiLocalToIso,
  percentToBasisPoints,
  PROMOTION_FIELD_ORDER,
  validatePromotionForm,
  type PromotionFormValues,
} from "../src/features/promotions/admin-form.ts";

const base = (
  over: Partial<PromotionFormValues> = {},
): PromotionFormValues => ({
  ...EMPTY_PROMOTION_FORM,
  name: "Welcome",
  value: "10",
  ...over,
});

describe("percentToBasisPoints", () => {
  it("converts without floating point", () => {
    assert.equal(percentToBasisPoints("10"), 1000);
    assert.equal(percentToBasisPoints("12.5"), 1250);
    assert.equal(percentToBasisPoints("0.01"), 1);
    assert.equal(percentToBasisPoints("100"), 10000);
    assert.equal(percentToBasisPoints("33.33"), 3333);
    assert.equal(percentToBasisPoints(" 7.1 "), 710);
  });
  it("rejects out of range and malformed input", () => {
    for (const bad of [
      "0",
      "0.00",
      "100.01",
      "101",
      "-5",
      "1e2",
      "10%",
      "",
      "abc",
      "1.234",
      "1,5",
    ]) {
      assert.equal(percentToBasisPoints(bad), null, bad);
    }
  });
  it("round-trips with the display text", () => {
    for (const text of ["10", "12.5", "0.01", "100", "33.33"]) {
      assert.equal(
        basisPointsToPercentText(percentToBasisPoints(text) ?? -1),
        text,
      );
    }
    assert.equal(basisPointsToPercentText(-1), "");
  });
});

describe("nairobiLocalToIso", () => {
  it("reads the typed time as Nairobi (+03:00)", () => {
    assert.equal(
      nairobiLocalToIso("2026-10-11T08:00"),
      "2026-10-11T08:00:00+03:00",
    );
    assert.equal(
      new Date("2026-10-11T08:00:00+03:00").toISOString(),
      "2026-10-11T05:00:00.000Z",
    );
  });
  it("rejects anything else", () => {
    for (const bad of [
      "",
      "2026-10-11",
      "2026-10-11 08:00",
      "2026-13-01T08:00",
      "tomorrow",
    ]) {
      assert.equal(nairobiLocalToIso(bad), null, bad);
    }
  });
});

describe("validatePromotionForm", () => {
  it("builds the RPC input for a percentage coupon, inactive by default", () => {
    const result = validatePromotionForm(
      base({
        code: " welcome10 ",
        maxDiscount: "500",
        minOrder: "1,000",
        usageLimit: "100",
        perCustomerLimit: "1",
      }),
    );
    assert.deepEqual(result, {
      ok: true,
      input: {
        name: "Welcome",
        discount_type: "percentage",
        value: 1000,
        is_active: false,
        code: "WELCOME10",
        max_discount_cents: 50000,
        min_order_cents: 100000,
        usage_limit: 100,
        per_customer_limit: 1,
      },
    });
  });

  it("a fixed promotion sends integer cents and never a max discount", () => {
    const result = validatePromotionForm(
      base({
        discountType: "fixed",
        value: "250.50",
        maxDiscount: "999",
        activateNow: true,
      }),
    );
    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.input.value, 25050);
      assert.equal(result.input.is_active, true);
      assert.equal("max_discount_cents" in result.input, false);
      assert.equal(
        "code" in result.input,
        false,
        "blank code = automatic promotion",
      );
    }
  });

  it("omits optional fields left blank, including a zero minimum order", () => {
    const result = validatePromotionForm(base({ minOrder: "0" }));
    assert.equal(result.ok, true);
    if (result.ok) {
      assert.deepEqual(Object.keys(result.input).sort(), [
        "discount_type",
        "is_active",
        "name",
        "value",
      ]);
    }
  });

  it("reports every problem at once, keyed by field", () => {
    const result = validatePromotionForm(
      base({
        name: "  ",
        code: "a!",
        value: "0",
        minOrder: "-1",
        usageLimit: "0",
        perCustomerLimit: "1.5",
        startsAt: "soon",
      }),
    );
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.deepEqual(Object.keys(result.errors).sort(), [
        "code",
        "minOrder",
        "name",
        "perCustomerLimit",
        "startsAt",
        "usageLimit",
        "value",
      ]);
    }
  });

  it("the end must be after the start", () => {
    const result = validatePromotionForm(
      base({ startsAt: "2026-10-11T08:00", expiresAt: "2026-10-11T08:00" }),
    );
    assert.equal(result.ok, false);
    if (!result.ok)
      assert.equal(result.errors.expiresAt, "The end must be after the start.");
    const ok = validatePromotionForm(
      base({ startsAt: "2026-10-11T08:00", expiresAt: "2026-10-12T08:00" }),
    );
    assert.equal(ok.ok, true);
  });

  it("refuses a limit above the integer range and a fixed discount of zero", () => {
    const big = validatePromotionForm(base({ usageLimit: "2147483648" }));
    assert.equal(big.ok, false);
    const zero = validatePromotionForm(
      base({ discountType: "fixed", value: "0" }),
    );
    assert.equal(zero.ok, false);
  });

  it("field order covers every error key the validator can produce", () => {
    const result = validatePromotionForm({
      ...EMPTY_PROMOTION_FORM,
      code: "!",
      maxDiscount: "x",
      minOrder: "x",
      startsAt: "x",
      expiresAt: "x",
      usageLimit: "x",
      perCustomerLimit: "x",
    });
    assert.equal(result.ok, false);
    if (!result.ok) {
      for (const key of Object.keys(result.errors)) {
        assert.ok(
          (PROMOTION_FIELD_ORDER as readonly string[]).includes(key),
          key,
        );
      }
    }
  });
});

describe("describePromotionValue", () => {
  it("shows the stored value, formatted by the caller's money formatter", () => {
    const money = (c: number) => `KES ${c / 100}`;
    assert.equal(
      describePromotionValue(
        { discount_type: "percentage", value: 1250 },
        money,
      ),
      "12.5%",
    );
    assert.equal(
      describePromotionValue({ discount_type: "fixed", value: 20000 }, money),
      "KES 200",
    );
  });
});
