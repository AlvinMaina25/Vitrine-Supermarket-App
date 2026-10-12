import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { toDeliverySelectionResult } from "../src/features/delivery/validation.ts";
import type {
  DeliverySelectionErrorCode,
  DeliverySelectionValidationRow,
} from "../src/lib/supabase/types.ts";

/**
 * Unit tests for the TypeScript side of delivery validation: how a row returned by
 * public.validate_delivery_selection() is turned into a result. They do NOT test the SQL
 * (see db/tests/delivery_validation.test.sql for that).
 *
 * Run with: bun run test   (Node >= 22.18 runs the .ts files directly)
 */

const validRow: DeliverySelectionValidationRow = {
  is_valid: true,
  error_code: null,
  error_message: null,
  method_code: "standard",
  method_label: "Standard delivery",
  requires_slot: true,
  requires_address: true,
  zone_id: "zone-1",
  zone_code: "westlands",
  zone_name: "Westlands",
  subtotal_cents: 200000,
  fee_cents: 40000,
  base_fee_cents: 40000,
  free_over_cents: 800000,
  min_order_cents: 150000,
  fee_source: "zone",
  zone_fee_id: "fee-1",
  fee_rule: {
    source: "zone",
    base_fee_cents: 40000,
    free_over_cents: 800000,
    min_order_cents: 150000,
    zone_fee_id: "fee-1",
  },
};

function rejected(
  code: DeliverySelectionErrorCode,
  extra: Partial<DeliverySelectionValidationRow> = {},
): DeliverySelectionValidationRow {
  return {
    ...validRow,
    is_valid: false,
    error_code: code,
    error_message: `message for ${code}`,
    fee_cents: null,
    base_fee_cents: null,
    free_over_cents: null,
    min_order_cents: null,
    fee_source: null,
    zone_fee_id: null,
    fee_rule: null,
    ...extra,
  };
}

describe("toDeliverySelectionResult", () => {
  it("returns the database fee and rule for a valid selection", () => {
    const result = toDeliverySelectionResult(validRow);
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.feeCents, 40000);
    assert.equal(result.feeSource, "zone");
    assert.equal(result.zoneFeeId, "fee-1");
    assert.deepEqual(result.feeRule, validRow.fee_rule);
    assert.equal(result.zoneCode, "westlands");
  });

  it("represents a free-delivery result as a zero fee, not a rejection", () => {
    const result = toDeliverySelectionResult({
      ...validRow,
      fee_cents: 0,
      subtotal_cents: 900000,
    });
    assert.equal(result.ok, true);
    if (result.ok) assert.equal(result.feeCents, 0);
  });

  const codes: DeliverySelectionErrorCode[] = [
    "invalid_subtotal",
    "method_required",
    "method_unknown",
    "method_inactive",
    "zone_required",
    "zone_unknown",
    "zone_inactive",
    "unavailable",
  ];
  for (const code of codes) {
    it(`rejects ${code} and exposes no fee`, () => {
      const result = toDeliverySelectionResult(rejected(code));
      assert.equal(result.ok, false);
      if (result.ok) return;
      assert.equal(result.code, code);
      assert.equal(result.message, `message for ${code}`);
      assert.equal("feeCents" in result, false);
    });
  }

  it("carries the minimum for below_minimum_order", () => {
    const result = toDeliverySelectionResult(
      rejected("below_minimum_order", { min_order_cents: 150000 }),
    );
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(result.code, "below_minimum_order");
      assert.equal(result.minOrderCents, 150000);
    }
  });

  it("never treats a missing row as free delivery", () => {
    for (const row of [null, undefined]) {
      const result = toDeliverySelectionResult(row);
      assert.equal(result.ok, false);
      if (!result.ok) assert.equal(result.code, "unavailable");
    }
  });

  it("never treats an incomplete 'valid' row as free delivery", () => {
    for (const broken of [
      { ...validRow, fee_cents: null },
      { ...validRow, fee_rule: null },
      { ...validRow, fee_source: null },
      { ...validRow, method_code: null },
    ]) {
      const result = toDeliverySelectionResult(broken);
      assert.equal(result.ok, false);
    }
  });

  it("takes no client-supplied fee: the mapper accepts only the database row", () => {
    assert.equal(toDeliverySelectionResult.length, 1);
  });
});
