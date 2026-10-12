import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { toDeliverySlotResult } from "../src/features/delivery/slot-validation.ts";
import type {
  DeliverySlotErrorCode,
  DeliverySlotValidationRow,
} from "../src/lib/supabase/types.ts";

/**
 * Unit tests for the TypeScript side of slot validation: how a row returned by
 * public.validate_delivery_slot() becomes a result. They do NOT test the SQL or the locking
 * (see db/tests/delivery_slot_validation.test.sql and db/tests/delivery_slot_concurrency.sh).
 *
 * Run with: bun run test   (Node >= 22.18 runs the .ts files directly)
 */

const validRow: DeliverySlotValidationRow = {
  is_valid: true,
  error_code: null,
  error_message: null,
  slot_date: "2026-10-10",
  slot_start: "08:00:00",
  slot_end: "11:00:00",
  template_id: "template-1",
  label: "Morning",
  capacity: 10,
  capacity_source: "template",
  booked_count: 4,
  remaining: 6,
  is_unlimited: false,
  is_closed: false,
  is_full: false,
};

function rejected(
  code: DeliverySlotErrorCode,
  extra: Partial<DeliverySlotValidationRow> = {},
): DeliverySlotValidationRow {
  return {
    ...validRow,
    is_valid: false,
    error_code: code,
    error_message: `message for ${code}`,
    ...extra,
  };
}

describe("toDeliverySlotResult", () => {
  it("returns identity, capacity and remaining for an available slot", () => {
    const result = toDeliverySlotResult(validRow);
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.templateId, "template-1");
    assert.equal(result.slotDate, "2026-10-10");
    assert.equal(result.capacity, 10);
    assert.equal(result.bookedCount, 4);
    assert.equal(result.remaining, 6);
    assert.equal(result.capacitySource, "template");
    assert.equal(result.isUnlimited, false);
  });

  it("represents an unlimited slot as null capacity and null remaining", () => {
    const result = toDeliverySlotResult({
      ...validRow,
      capacity: null,
      remaining: null,
      is_unlimited: true,
    });
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.capacity, null);
    assert.equal(result.remaining, null);
    assert.equal(result.isUnlimited, true);
  });

  it("reports a date override as the capacity source", () => {
    const result = toDeliverySlotResult({
      ...validRow,
      capacity_source: "override",
    });
    assert.equal(result.ok, true);
    if (result.ok) assert.equal(result.capacitySource, "override");
  });

  const codes: DeliverySlotErrorCode[] = [
    "slot_required",
    "invalid_window",
    "slot_in_past",
    "slot_too_far",
    "slot_unknown",
    "slot_inactive",
    "slot_closed",
    "slot_full",
  ];
  for (const code of codes) {
    it(`rejects ${code} and exposes no slot identity`, () => {
      const result = toDeliverySlotResult(rejected(code));
      assert.equal(result.ok, false);
      if (result.ok) return;
      assert.equal(result.code, code);
      assert.equal(result.message, `message for ${code}`);
      assert.equal("templateId" in result, false);
      assert.equal("remaining" in result, false);
    });
  }

  it("flags a full slot", () => {
    const result = toDeliverySlotResult(
      rejected("slot_full", { is_full: true, remaining: 0, booked_count: 10 }),
    );
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(result.isFull, true);
      assert.equal(result.isClosed, false);
    }
  });

  it("flags a closed slot", () => {
    const result = toDeliverySlotResult(
      rejected("slot_closed", { is_closed: true, capacity: 0, remaining: 0 }),
    );
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(result.isClosed, true);
      assert.equal(result.isFull, false);
    }
  });

  it("never treats a missing row as an available slot", () => {
    for (const row of [null, undefined]) {
      const result = toDeliverySlotResult(row);
      assert.equal(result.ok, false);
      if (!result.ok) assert.equal(result.code, "slot_unknown");
    }
  });

  it("never treats an incomplete 'valid' row as available", () => {
    for (const broken of [
      { ...validRow, template_id: null },
      { ...validRow, slot_date: null },
      { ...validRow, booked_count: null },
      { ...validRow, capacity_source: null },
      { ...validRow, is_unlimited: null },
    ]) {
      assert.equal(toDeliverySlotResult(broken).ok, false);
    }
  });

  it("never treats a 'valid' row that is full, closed or out of places as available", () => {
    for (const broken of [
      { ...validRow, is_full: true },
      { ...validRow, is_closed: true },
      { ...validRow, remaining: 0 },
      { ...validRow, capacity: null },
      { ...validRow, remaining: null },
      { ...validRow, is_unlimited: true },
    ]) {
      assert.equal(toDeliverySlotResult(broken).ok, false);
    }
  });

  it("takes only the database row: nothing client-side can supply capacity", () => {
    assert.equal(toDeliverySlotResult.length, 1);
  });
});
