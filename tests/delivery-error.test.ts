import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  ADMIN_DELIVERY_REASONS,
  AdminDeliveryError,
  deliveryReasonMessage,
  isAdminDeliveryReason,
  toAdminDeliveryError,
} from "../src/features/admin/delivery-error.ts";
import {
  checkReason,
  isIsoDate,
  normaliseTime,
} from "../src/features/admin/delivery-parse.ts";

// Every DETAIL code the two migrations can raise after the gate.
const MIGRATION_CODES = [
  "invalid_arguments",
  "invalid_code",
  "code_immutable",
  "code_taken",
  "name_required",
  "name_too_long",
  "county_too_long",
  "description_too_long",
  "invalid_towns",
  "invalid_position",
  "invalid_fee",
  "invalid_free_over",
  "invalid_min_order",
  "immutable_fields",
  "zone_not_found",
  "zone_fee_not_found",
  "method_not_found",
  "zone_fee_exists",
  "reason_required",
  "reason_too_long",
  "status_unchanged",
  "invalid_date_range",
  "date_range_too_large",
  "label_required",
  "label_too_long",
  "invalid_window",
  "invalid_weekday",
  "invalid_capacity",
  "template_not_found",
  "template_has_bookings",
  "template_inactive",
  "template_not_on_date",
  "date_in_past",
  "date_too_far",
  "note_too_long",
  "capacity_with_closed",
  "override_empty",
  "override_not_found",
  "capacity_below_booked",
];

describe("toAdminDeliveryError", () => {
  it("maps not-authorised and 42501 to AdminAccessError", () => {
    assert.ok(
      toAdminDeliveryError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminDeliveryError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
  });

  it("maps every migration code, with a friendly message that never echoes the database text", () => {
    assert.deepEqual(
      [...ADMIN_DELIVERY_REASONS].sort(),
      [...MIGRATION_CODES].sort(),
    );
    for (const code of MIGRATION_CODES) {
      const e = toAdminDeliveryError({
        message: "raw db text",
        details: code,
        code: "P0001",
      });
      assert.ok(e instanceof AdminDeliveryError, code);
      assert.equal((e as AdminDeliveryError).reason, code);
      assert.ok(!e.message.includes("raw db text"), code);
      assert.ok(e.message.length > 10, code);
      assert.ok(isAdminDeliveryReason(code));
    }
  });

  it("attaches the form field a refusal belongs to", () => {
    const field = (code: string) =>
      (
        toAdminDeliveryError({
          message: "x",
          details: code,
        }) as AdminDeliveryError
      ).field;
    assert.equal(field("invalid_fee"), "fee");
    assert.equal(field("invalid_free_over"), "freeOver");
    assert.equal(field("invalid_min_order"), "minOrder");
    assert.equal(field("capacity_below_booked"), "capacity");
    assert.equal(field("invalid_window"), "window");
    assert.equal(field("reason_required"), "reason");
    assert.equal(field("code_taken"), "code");
    assert.equal(field("zone_not_found"), null);
  });

  it("keeps the database message for unknown failures", () => {
    const e = toAdminDeliveryError({
      message: "network down",
      details: "something_else",
    });
    assert.ok(!(e instanceof AdminDeliveryError));
    assert.equal(e.message, "network down");
    assert.equal(
      toAdminDeliveryError({ message: "boom", details: null }).message,
      "boom",
    );
  });

  it("has a message for each reason", () => {
    assert.match(
      deliveryReasonMessage("capacity_below_booked"),
      /Close the slot/,
    );
    assert.equal(isAdminDeliveryReason("nope"), false);
    assert.equal(isAdminDeliveryReason(undefined), false);
  });
});

describe("shared parse helpers", () => {
  it("validates real calendar dates only", () => {
    assert.equal(isIsoDate("2026-10-07"), true);
    for (const bad of [
      "2026-02-30",
      "2026-13-01",
      "26-10-07",
      "2026-10-7",
      "",
      5,
      null,
    ]) {
      assert.equal(isIsoDate(bad), false, String(bad));
    }
  });

  it("normalises HH:MM and HH:MM:SS, rejects the rest", () => {
    assert.equal(normaliseTime("08:00"), "08:00:00");
    assert.equal(normaliseTime(" 23:59:30 "), "23:59:30");
    for (const bad of ["24:00", "8:00", "08:60", "08-00", "", "noon"]) {
      assert.equal(normaliseTime(bad), null, bad);
    }
  });

  it("checks reasons: trims, optional blank, required blank, length by code point", () => {
    assert.deepEqual(checkReason("  hello ", true), {
      value: "hello",
      error: null,
    });
    assert.deepEqual(checkReason("   ", false), { value: null, error: null });
    assert.equal(checkReason("   ", true).error, "A reason is required.");
    assert.equal(checkReason("a".repeat(500), true).value, "a".repeat(500));
    assert.match(checkReason("a".repeat(501), true).error ?? "", /500/);
    assert.equal(checkReason("😀".repeat(500), true).error, null);
  });
});
