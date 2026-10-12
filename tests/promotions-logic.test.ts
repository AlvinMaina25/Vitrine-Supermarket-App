import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  COUPON_ERROR_CODES,
  DELIVERY_DISCOUNTABLE,
  computeDiscountCents,
  couponErrorFromDetail,
  couponErrorMessage,
  describeDiscount,
  discountLabel,
  eligibleBaseCents,
  evaluatePromotion,
  isCouponErrorCode,
  isWellFormedCouponCode,
  normalizeCouponCode,
  parseCouponPreview,
  type PromotionRule,
} from "../src/features/promotions/logic.ts";

/**
 * Pure-logic tests for Phase 8. The evaluation vectors are the SAME cases as
 * db/tests/phase8_discounts_promotions.test.sql, so a rule changed in one place and not the other
 * shows up as a failing test in one of the two. Nothing here talks to a database.
 */

const NOW = Date.UTC(2026, 9, 9, 12, 0, 0);
const HOUR = 3_600_000;

function rule(overrides: Partial<PromotionRule> = {}): PromotionRule {
  return {
    isActive: true,
    discountType: "percentage",
    value: 1000, // 10%
    maxDiscountCents: null,
    minOrderCents: 0,
    startsAtMs: null,
    expiresAtMs: null,
    usageLimit: null,
    perCustomerLimit: null,
    ...overrides,
  };
}

const ctx = (
  overrides: Partial<{
    subtotalCents: number;
    deliveryFeeCents: number;
    total: number;
    byCustomer: number;
    nowMs: number;
  }> = {},
) => ({
  nowMs: overrides.nowMs ?? NOW,
  subtotalCents: overrides.subtotalCents ?? 10000,
  deliveryFeeCents: overrides.deliveryFeeCents ?? 3000,
  usage: { total: overrides.total ?? 0, byCustomer: overrides.byCustomer ?? 0 },
});

describe("coupon codes", () => {
  it("normalises like the database: trim + upper-case, empty is no code", () => {
    assert.equal(normalizeCouponCode("  save10 "), "SAVE10");
    assert.equal(normalizeCouponCode(""), null);
    assert.equal(normalizeCouponCode("   "), null);
    assert.equal(normalizeCouponCode(null), null);
    assert.equal(normalizeCouponCode(42), null);
  });

  it("accepts the stored shape and rejects everything else", () => {
    for (const ok of ["SAVE10", "A-B_C", "ABC", "X".repeat(32)])
      assert.ok(isWellFormedCouponCode(ok), ok);
    for (const bad of [
      "AB",
      "-ABC",
      "ab c",
      "A".repeat(33),
      "SAVE!",
      "save10",
    ]) {
      assert.ok(!isWellFormedCouponCode(bad), bad);
    }
  });
});

describe("delivery is not discountable (one rule)", () => {
  it("is false and the base is the merchandise subtotal only", () => {
    assert.equal(DELIVERY_DISCOUNTABLE, false);
    assert.equal(eligibleBaseCents(10000, 5000), 10000);
    assert.equal(eligibleBaseCents(0, 5000), 0);
    assert.equal(eligibleBaseCents(-5, 100), 0);
  });
});

describe("computeDiscountCents", () => {
  it("percentage floors (basis points)", () => {
    assert.equal(computeDiscountCents(rule(), 10000), 1000);
    assert.equal(computeDiscountCents(rule({ value: 3333 }), 100), 33);
    assert.equal(computeDiscountCents(rule({ value: 1 }), 9999), 0);
  });

  it("applies the cap, then never exceeds the base", () => {
    assert.equal(
      computeDiscountCents(
        rule({ value: 5000, maxDiscountCents: 1500 }),
        10000,
      ),
      1500,
    );
    assert.equal(computeDiscountCents(rule({ value: 10000 }), 777), 777);
  });

  it("fixed never exceeds the base", () => {
    assert.equal(
      computeDiscountCents(rule({ discountType: "fixed", value: 300 }), 10000),
      300,
    );
    assert.equal(
      computeDiscountCents(
        rule({ discountType: "fixed", value: 50000 }),
        10000,
      ),
      10000,
    );
  });

  it("is zero for an empty base or a bad value", () => {
    assert.equal(
      computeDiscountCents(rule({ discountType: "fixed", value: 300 }), 0),
      0,
    );
    assert.equal(computeDiscountCents(rule({ value: 0 }), 10000), 0);
    assert.equal(computeDiscountCents(rule(), 10.5), 0);
  });

  it("the total can never go below the delivery fee, nor below zero", () => {
    const subtotal = 800;
    const fee = 300;
    const discount = computeDiscountCents(
      rule({ discountType: "fixed", value: 99999 }),
      eligibleBaseCents(subtotal, fee),
    );
    assert.equal(discount, subtotal);
    assert.equal(subtotal + fee - discount, fee);
  });
});

describe("evaluatePromotion (same vectors as the SQL test)", () => {
  it("applies a plain valid promotion", () => {
    assert.deepEqual(evaluatePromotion(rule(), ctx()), {
      ok: true,
      discountCents: 1000,
    });
  });

  it("inactive is 'invalid' (indistinguishable from unknown)", () => {
    assert.deepEqual(evaluatePromotion(rule({ isActive: false }), ctx()), {
      ok: false,
      error: "invalid",
    });
  });

  it("start boundary: before is not_started, at the instant is valid", () => {
    const r = rule({ startsAtMs: NOW + HOUR });
    assert.deepEqual(evaluatePromotion(r, ctx()), {
      ok: false,
      error: "not_started",
    });
    assert.equal(evaluatePromotion(r, ctx({ nowMs: NOW + HOUR })).ok, true);
  });

  it("expiry boundary: the expiry instant itself is expired", () => {
    const r = rule({ expiresAtMs: NOW + HOUR });
    assert.equal(evaluatePromotion(r, ctx({ nowMs: NOW + HOUR - 1 })).ok, true);
    assert.deepEqual(evaluatePromotion(r, ctx({ nowMs: NOW + HOUR })), {
      ok: false,
      error: "expired",
    });
  });

  it("minimum is checked against the subtotal, never against delivery", () => {
    const r = rule({ minOrderCents: 10000 });
    assert.equal(
      evaluatePromotion(r, ctx({ subtotalCents: 10000, deliveryFeeCents: 0 }))
        .ok,
      true,
    );
    assert.deepEqual(
      evaluatePromotion(
        r,
        ctx({ subtotalCents: 9999, deliveryFeeCents: 5000 }),
      ),
      {
        ok: false,
        error: "min_not_met",
      },
    );
  });

  it("global limit: the last use is allowed, the next is limit_reached", () => {
    const r = rule({ usageLimit: 3 });
    assert.equal(evaluatePromotion(r, ctx({ total: 2 })).ok, true);
    assert.deepEqual(evaluatePromotion(r, ctx({ total: 3 })), {
      ok: false,
      error: "limit_reached",
    });
  });

  it("per-customer limit: already_used once the customer has used it up", () => {
    const r = rule({ perCustomerLimit: 1 });
    assert.equal(
      evaluatePromotion(r, ctx({ byCustomer: 0, total: 50 })).ok,
      true,
    );
    assert.deepEqual(evaluatePromotion(r, ctx({ byCustomer: 1 })), {
      ok: false,
      error: "already_used",
    });
  });

  it("checks run in the database's order: window, minimum, global, per-customer", () => {
    const all = rule({
      expiresAtMs: NOW - 1,
      minOrderCents: 99999,
      usageLimit: 1,
      perCustomerLimit: 1,
    });
    assert.deepEqual(evaluatePromotion(all, ctx({ total: 1, byCustomer: 1 })), {
      ok: false,
      error: "expired",
    });
    const noWindow = { ...all, expiresAtMs: null };
    assert.deepEqual(
      evaluatePromotion(noWindow, ctx({ total: 1, byCustomer: 1 })),
      { ok: false, error: "min_not_met" },
    );
    const noMin = { ...noWindow, minOrderCents: 0 };
    assert.deepEqual(
      evaluatePromotion(noMin, ctx({ total: 1, byCustomer: 1 })),
      { ok: false, error: "limit_reached" },
    );
  });

  it("a rule that computes to zero is 'invalid', not a free pass", () => {
    assert.deepEqual(
      evaluatePromotion(rule({ value: 1 }), ctx({ subtotalCents: 50 })),
      { ok: false, error: "invalid" },
    );
  });

  it("only the six documented codes can ever come out", () => {
    assert.deepEqual(
      [...COUPON_ERROR_CODES],
      [
        "invalid",
        "not_started",
        "expired",
        "min_not_met",
        "limit_reached",
        "already_used",
      ],
    );
  });
});

describe("coupon error mapping", () => {
  it("reads coupon_<code> from a create_order() DETAIL", () => {
    assert.equal(couponErrorFromDetail("coupon_expired"), "expired");
    assert.equal(
      couponErrorFromDetail(" coupon_limit_reached\n"),
      "limit_reached",
    );
    assert.equal(couponErrorFromDetail("coupon_already_used"), "already_used");
  });

  it("returns null for anything else, including admin-only and unknown details", () => {
    for (const d of [
      null,
      undefined,
      "",
      "expired",
      "coupon_reactivation_limit_reached",
      "coupon_secret",
      "slot_full",
      7,
    ]) {
      assert.equal(couponErrorFromDetail(d), null, String(d));
    }
  });

  it("every code has a safe message that leaks no value", () => {
    for (const code of COUPON_ERROR_CODES) {
      const message = couponErrorMessage(code);
      assert.ok(message.length > 10);
      assert.ok(!/\d/.test(message), `${code} message contains a digit`);
    }
    assert.ok(isCouponErrorCode("expired"));
    assert.ok(!isCouponErrorCode("nope"));
  });
});

describe("parseCouponPreview", () => {
  const applied = {
    ok: true,
    applied: true,
    code: "SAVE10",
    name: "Ten percent",
    discount_type: "percentage",
    discount_value: 1000,
    discount_cents: 1000,
    subtotal_cents: 10000,
    eligible_cents: 10000,
  };

  it("parses an applied discount", () => {
    assert.deepEqual(parseCouponPreview(applied), {
      status: "applied",
      code: "SAVE10",
      name: "Ten percent",
      discountType: "percentage",
      discountValue: 1000,
      discountCents: 1000,
      subtotalCents: 10000,
      eligibleCents: 10000,
      totals: { deliveryFeeCents: null, totalCents: null },
    });
  });

  it("parses 'nothing applies' and an automatic promotion (null code)", () => {
    assert.deepEqual(
      parseCouponPreview({
        ok: true,
        applied: false,
        subtotal_cents: 500,
        discount_cents: 0,
      }),
      {
        status: "none",
        subtotalCents: 500,
        totals: { deliveryFeeCents: null, totalCents: null },
      },
    );
    const auto = parseCouponPreview({ ...applied, code: null });
    assert.equal(auto.status === "applied" && auto.code, null);
  });

  it("carries the server's delivery fee and final total when both are present", () => {
    const withTotals = parseCouponPreview({
      ...applied,
      delivery_fee_cents: 5000,
      total_cents: 14000,
    });
    assert.equal(withTotals.status, "applied");
    assert.deepEqual(withTotals.status === "applied" && withTotals.totals, {
      deliveryFeeCents: 5000,
      totalCents: 14000,
    });
    const none = parseCouponPreview({
      ok: true,
      applied: false,
      subtotal_cents: 10000,
      discount_cents: 0,
      delivery_fee_cents: 0,
      total_cents: 10000,
    });
    assert.deepEqual(none.status === "none" && none.totals, {
      deliveryFeeCents: 0,
      totalCents: 10000,
    });
  });

  it("never invents a total: it is passed through untouched, not recomputed", () => {
    // Deliberately not subtotal + fee - discount: the parser reports what the database said.
    const odd = parseCouponPreview({
      ...applied,
      delivery_fee_cents: 5000,
      total_cents: 12345,
    });
    assert.equal(odd.status === "applied" && odd.totals.totalCents, 12345);
  });

  it("parses a rejection and maps an unknown error string to 'invalid'", () => {
    assert.deepEqual(parseCouponPreview({ ok: false, error: "expired" }), {
      status: "rejected",
      error: "expired",
    });
    assert.deepEqual(
      parseCouponPreview({ ok: false, error: "some_internal_thing" }),
      {
        status: "rejected",
        error: "invalid",
      },
    );
  });

  it("refuses a reply that breaks an invariant", () => {
    const bad = [
      null,
      "x",
      [],
      {},
      { ok: true },
      { ...applied, discount_cents: 10001 }, // above the eligible base
      { ...applied, eligible_cents: 10001 }, // above the subtotal
      { ...applied, discount_cents: 0 },
      { ...applied, discount_cents: -5 },
      { ...applied, discount_cents: 10.5 },
      { ...applied, discount_type: "bogus" },
      { ...applied, name: 5 },
      { ...applied, total_cents: 14000 }, // a total without its fee
      { ...applied, delivery_fee_cents: 5000 }, // a fee without its total
      { ...applied, delivery_fee_cents: 5000, total_cents: -1 },
      { ...applied, delivery_fee_cents: 5000, total_cents: 140.5 },
      { ...applied, delivery_fee_cents: "5000", total_cents: 14000 },
      { ...applied, delivery_fee_cents: null, total_cents: null },
    ];
    for (const value of bad)
      assert.throws(
        () => parseCouponPreview(value),
        /Unexpected coupon response/,
      );
  });
});

describe("display helpers", () => {
  it("labels a discount by code, else name, else plain", () => {
    assert.equal(
      discountLabel({ code: "SAVE10", name: "Ten" }),
      "Discount (SAVE10)",
    );
    assert.equal(
      discountLabel({ code: null, name: "Weekend sale" }),
      "Discount (Weekend sale)",
    );
    assert.equal(discountLabel({ code: null, name: null }), "Discount");
  });

  it("describes a rule from its snapshot", () => {
    assert.equal(describeDiscount("percentage", 1000), "10% off");
    assert.equal(describeDiscount("percentage", 1250), "12.50% off");
    assert.equal(describeDiscount("fixed", 25000), "250.00 off");
  });
});
