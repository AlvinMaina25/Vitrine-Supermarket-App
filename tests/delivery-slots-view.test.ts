import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  capacityBelowBookedWarning,
  defaultSlotRange,
  describeBooked,
  groupSlotsByDate,
  overrideBlockedReason,
  resolveSlotRange,
  slotHasOverride,
  storeToday,
} from "../src/features/admin/delivery-slots-view.ts";
import type { AdminDeliverySlot } from "../src/features/admin/delivery-slots-result.ts";

const slot = (patch: Partial<AdminDeliverySlot> = {}): AdminDeliverySlot => ({
  slot_date: "2026-10-08",
  template_id: "t1",
  label: "Morning",
  start_time: "08:00:00",
  end_time: "11:00:00",
  position: 0,
  template_active: true,
  template_capacity: 10,
  override_capacity: null,
  override_closed: false,
  effective_capacity: 10,
  is_closed: false,
  booked_count: 3,
  ...patch,
});

describe("slot range", () => {
  it("defaults to 14 days from today", () => {
    assert.deepEqual(defaultSlotRange("2026-10-07"), {
      from: "2026-10-07",
      to: "2026-10-20",
    });
    assert.deepEqual(resolveSlotRange({}, "2026-10-07"), {
      from: "2026-10-07",
      to: "2026-10-20",
    });
  });
  it("uses the URL range when present", () => {
    const range = { from: "2026-11-01", to: "2026-11-07" };
    assert.deepEqual(resolveSlotRange(range, "2026-10-07"), range);
  });
  it("reads today in Nairobi time", () => {
    assert.equal(storeToday(new Date("2026-10-07T22:30:00Z")), "2026-10-08");
  });
});

describe("groupSlotsByDate", () => {
  it("groups by date and orders by position", () => {
    const days = groupSlotsByDate([
      slot({ slot_date: "2026-10-09", template_id: "a" }),
      slot({ template_id: "b", position: 2 }),
      slot({ template_id: "c", position: 1 }),
    ]);
    assert.deepEqual(
      days.map((d) => d.date),
      ["2026-10-08", "2026-10-09"],
    );
    assert.deepEqual(
      days[0]?.slots.map((s) => s.template_id),
      ["c", "b"],
    );
  });
});

describe("slot wording and rules", () => {
  it("describes bookings", () => {
    assert.equal(describeBooked(slot()), "3 of 10 booked");
    assert.equal(
      describeBooked(slot({ effective_capacity: null })),
      "3 booked (unlimited)",
    );
    assert.equal(
      describeBooked(slot({ is_closed: true })),
      "Closed · 3 booked",
    );
  });
  it("detects overrides", () => {
    assert.equal(slotHasOverride(slot(), []), false);
    assert.equal(slotHasOverride(slot({ override_capacity: 5 }), []), true);
    assert.equal(slotHasOverride(slot({ override_closed: true }), []), true);
  });
  it("blocks past dates and inactive templates", () => {
    const past = overrideBlockedReason(
      slot({ slot_date: "2026-10-06" }),
      "2026-10-07",
    );
    assert.match(past ?? "", /Past/);
    const off = overrideBlockedReason(
      slot({ template_active: false }),
      "2026-10-07",
    );
    assert.match(off ?? "", /Activate/);
    assert.equal(overrideBlockedReason(slot(), "2026-10-07"), null);
  });
  it("warns only when capacity is below booked and the slot stays open", () => {
    assert.match(
      capacityBelowBookedWarning(2, false, 3) ?? "",
      /cannot go below 3/,
    );
    assert.equal(capacityBelowBookedWarning(3, false, 3), null);
    assert.equal(capacityBelowBookedWarning(0, true, 3), null);
    assert.equal(capacityBelowBookedWarning(null, false, 3), null);
  });
});
