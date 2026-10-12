import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  parsePromotionList,
  parsePromotionResult,
  promotionAdminErrorMessage,
} from "../src/features/promotions/admin-parse.ts";

const row = {
  id: "00000000-0000-4000-8000-000000000001",
  code: "SAVE10",
  name: "Ten percent",
  discount_type: "percentage",
  value: 1000,
  max_discount_cents: null,
  min_order_cents: 0,
  starts_at: null,
  expires_at: null,
  usage_limit: null,
  per_customer_limit: null,
  is_active: true,
  created_at: "2026-10-09T00:00:00Z",
  updated_at: "2026-10-09T00:00:00Z",
};

describe("promotion admin results", () => {
  it("parses { promotion } and { total, rows }", () => {
    assert.equal(parsePromotionResult({ promotion: row }).code, "SAVE10");
    const list = parsePromotionList({
      total: 1,
      rows: [{ ...row, active_redemptions: 2, active_discount_cents: 500 }],
    });
    assert.equal(list.total, 1);
    assert.equal(list.rows[0]?.active_redemptions, 2);
  });

  it("rejects malformed replies", () => {
    for (const bad of [
      null,
      {},
      { promotion: {} },
      { promotion: { ...row, discount_type: "x" } },
    ]) {
      assert.throws(
        () => parsePromotionResult(bad),
        /Unexpected promotion response/,
      );
    }
    for (const bad of [
      null,
      { total: "1", rows: [] },
      { total: 1, rows: [{}] },
      { total: 1 },
    ]) {
      assert.throws(
        () => parsePromotionList(bad),
        /Unexpected promotion list response/,
      );
    }
  });

  it("maps database details to safe admin messages and never echoes raw text", () => {
    assert.match(
      promotionAdminErrorMessage({ details: "code_taken" }),
      /already in use/,
    );
    assert.match(
      promotionAdminErrorMessage({ details: " invalid_promotion " }),
      /not valid/,
    );
    assert.match(
      promotionAdminErrorMessage({ details: "mfa_required" }),
      /Two-factor/,
    );
    const unknown = promotionAdminErrorMessage({
      message: 'duplicate key value violates "promotions_code_key"',
      details: null,
    });
    assert.ok(!unknown.includes("promotions_code_key"));
  });
});
