import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildUpdateDeliveryMethodArgs,
  toAdminUpdateDeliveryMethodResult,
} from "../src/features/admin/delivery-method-result.ts";
import {
  buildSaveDeliveryZoneFeeArgs,
  buildSetDeliveryZoneFeeActiveArgs,
  toAdminSaveDeliveryZoneFeeResult,
  toAdminSetDeliveryZoneFeeActiveResult,
} from "../src/features/admin/delivery-zone-fee-result.ts";
import {
  buildSaveDeliveryZoneArgs,
  buildSetDeliveryZoneActiveArgs,
  cleanTowns,
  toAdminSaveDeliveryZoneResult,
  toAdminSetDeliveryZoneActiveResult,
} from "../src/features/admin/delivery-zone-result.ts";

const zoneRow = {
  id: "z1",
  code: "nairobi",
  name: "Nairobi",
  description: null,
  county: null,
  towns: [],
  position: 0,
  is_active: true,
};
const feeRow = {
  id: "f1",
  zone_id: "z1",
  method_code: "standard",
  fee_cents: 100,
  free_over_cents: null,
  min_order_cents: 0,
  is_active: true,
};
const methodRow = {
  code: "standard",
  label: "Standard",
  description: null,
  base_fee_cents: 100,
  free_over_cents: null,
  min_order_cents: 0,
  requires_slot: true,
  requires_address: true,
  eta_label: null,
  position: 0,
  is_active: true,
};

describe("zone results", () => {
  it("parses a save result and a status result", () => {
    const saved = toAdminSaveDeliveryZoneResult({
      changed: true,
      created: true,
      zone: zoneRow,
    });
    assert.equal(saved.created, true);
    assert.equal(saved.zone.code, "nairobi");
    const status = {
      changed: true,
      zone_id: "z1",
      previous_is_active: true,
      is_active: false,
    };
    assert.deepEqual(toAdminSetDeliveryZoneActiveResult(status), status);
  });

  it("rejects malformed results", () => {
    for (const bad of [null, [], {}, { changed: true, created: false }]) {
      assert.throws(
        () => toAdminSaveDeliveryZoneResult(bad),
        /unexpected response/,
      );
    }
    assert.throws(
      () =>
        toAdminSaveDeliveryZoneResult({
          changed: "y",
          created: false,
          zone: zoneRow,
        }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminSetDeliveryZoneActiveResult({
          changed: false,
          zone_id: "z1",
          previous_is_active: true,
          is_active: true,
        }),
      /unexpected/,
    );
  });
});

describe("buildSaveDeliveryZoneArgs", () => {
  const base = {
    zoneId: null,
    code: " nairobi-cbd ",
    name: " Nairobi CBD ",
    county: " ",
    description: "",
    towns: [" CBD ", "cbd", "", "Upper Hill"],
    position: null,
  };

  it("builds create args: trims, blanks to null, dedupes towns, sends the code", () => {
    const r = buildSaveDeliveryZoneArgs(base);
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_zone_id: null,
      p_code: "nairobi-cbd",
      p_name: "Nairobi CBD",
      p_county: null,
      p_towns: ["CBD", "Upper Hill"],
      p_description: null,
      p_position: null,
    });
  });

  it("sends a null code when updating (the code is create-only)", () => {
    const r = buildSaveDeliveryZoneArgs({
      ...base,
      zoneId: "z1",
      code: "ignored",
      position: 3,
    });
    assert.ok(r.ok);
    assert.equal(r.args.p_zone_id, "z1");
    assert.equal(r.args.p_code, null);
    assert.equal(r.args.p_position, 3);
  });

  it("reports field errors", () => {
    const r = buildSaveDeliveryZoneArgs({
      ...base,
      code: "Bad Code",
      name: " ",
      county: "c".repeat(81),
      description: "d".repeat(501),
      towns: Array.from({ length: 101 }, (_, i) => `t${i}`),
      position: -1,
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "code",
      "county",
      "description",
      "name",
      "position",
      "towns",
    ]);
  });

  it("does not validate the code on update and rejects a 121-character name", () => {
    assert.ok(
      buildSaveDeliveryZoneArgs({ ...base, zoneId: "z1", code: "" }).ok,
    );
    const r = buildSaveDeliveryZoneArgs({ ...base, name: "n".repeat(121) });
    assert.ok(!r.ok);
    assert.ok(r.errors.name);
  });

  it("counts characters by code point and cleans towns case-insensitively", () => {
    assert.ok(
      buildSaveDeliveryZoneArgs({ ...base, county: "😀".repeat(80) }).ok,
    );
    assert.deepEqual(cleanTowns(["A", " a ", "B", "  "]), ["A", "B"]);
    const longTown = buildSaveDeliveryZoneArgs({
      ...base,
      towns: ["x".repeat(81)],
    });
    assert.ok(!longTown.ok);
  });
});

describe("buildSetDeliveryZoneActiveArgs", () => {
  it("requires and trims a reason", () => {
    const r = buildSetDeliveryZoneActiveArgs(
      "z1",
      false,
      "  closed for the season ",
    );
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_zone_id: "z1",
      p_is_active: false,
      p_reason: "closed for the season",
    });
    const blank = buildSetDeliveryZoneActiveArgs("z1", true, "  ");
    assert.ok(!blank.ok);
    assert.equal(blank.errors.reason, "A reason is required.");
    assert.ok(!buildSetDeliveryZoneActiveArgs("z1", true, "x".repeat(501)).ok);
  });
});

describe("zone fee rules", () => {
  it("parses results", () => {
    const saved = toAdminSaveDeliveryZoneFeeResult({
      changed: false,
      created: false,
      zone_fee: feeRow,
    });
    assert.equal(saved.zone_fee.fee_cents, 100);
    const status = {
      changed: true,
      zone_fee_id: "f1",
      previous_is_active: false,
      is_active: true,
    };
    assert.deepEqual(toAdminSetDeliveryZoneFeeActiveResult(status), status);
    assert.throws(
      () => toAdminSaveDeliveryZoneFeeResult({ changed: true }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminSaveDeliveryZoneFeeResult({
          changed: true,
          created: true,
          zone_fee: { ...feeRow, fee_cents: 1.5 },
        }),
      /unexpected/,
    );
  });

  it("builds create args and keeps cents exactly as given", () => {
    const r = buildSaveDeliveryZoneFeeArgs({
      feeId: null,
      zoneId: "z1",
      methodCode: " standard ",
      feeCents: 30000,
      freeOverCents: null,
      minOrderCents: null,
    });
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_fee_id: null,
      p_zone_id: "z1",
      p_method_code: "standard",
      p_fee_cents: 30000,
      p_free_over_cents: null,
      p_min_order_cents: null,
    });
  });

  it("sends null zone and method when updating", () => {
    const r = buildSaveDeliveryZoneFeeArgs({
      feeId: "f1",
      zoneId: "z1",
      methodCode: "standard",
      feeCents: 0,
      freeOverCents: 0,
      minOrderCents: 0,
    });
    assert.ok(r.ok);
    assert.equal(r.args.p_zone_id, null);
    assert.equal(r.args.p_method_code, null);
    assert.equal(r.args.p_fee_cents, 0);
  });

  it("rejects bad cents, and a missing zone or method on create", () => {
    const bad = buildSaveDeliveryZoneFeeArgs({
      feeId: "f1",
      zoneId: null,
      methodCode: null,
      feeCents: 12.5,
      freeOverCents: -1,
      minOrderCents: 2147483648,
    });
    assert.ok(!bad.ok);
    assert.deepEqual(Object.keys(bad.errors).sort(), [
      "fee",
      "freeOver",
      "minOrder",
    ]);
    const noZone = buildSaveDeliveryZoneFeeArgs({
      feeId: null,
      zoneId: null,
      methodCode: "standard",
      feeCents: 1,
      freeOverCents: null,
      minOrderCents: null,
    });
    assert.ok(!noZone.ok);
    assert.ok(noZone.errors.form);
    const noMethod = buildSaveDeliveryZoneFeeArgs({
      feeId: null,
      zoneId: "z1",
      methodCode: " ",
      feeCents: 1,
      freeOverCents: null,
      minOrderCents: null,
    });
    assert.ok(!noMethod.ok);
  });

  it("requires a reason to change a rule's active flag", () => {
    assert.ok(buildSetDeliveryZoneFeeActiveArgs("f1", false, "rate review").ok);
    assert.ok(!buildSetDeliveryZoneFeeActiveArgs("f1", false, "").ok);
  });
});

describe("delivery methods", () => {
  it("parses a result", () => {
    const r = toAdminUpdateDeliveryMethodResult({
      changed: true,
      method: methodRow,
    });
    assert.equal(r.method.base_fee_cents, 100);
    assert.throws(
      () => toAdminUpdateDeliveryMethodResult({ changed: true }),
      /unexpected/,
    );
    assert.throws(() => toAdminUpdateDeliveryMethodResult(null), /unexpected/);
  });

  const input = {
    code: "standard",
    baseFeeCents: 25000,
    freeOverCents: null,
    minOrderCents: 0,
    isActive: true,
    currentIsActive: true,
    reason: "",
  };

  it("builds args; a reason is optional unless the active flag changes", () => {
    const r = buildUpdateDeliveryMethodArgs(input);
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_code: "standard",
      p_base_fee_cents: 25000,
      p_free_over_cents: null,
      p_min_order_cents: 0,
      p_is_active: true,
      p_reason: null,
    });
    const noReason = buildUpdateDeliveryMethodArgs({
      ...input,
      isActive: false,
    });
    assert.ok(!noReason.ok);
    assert.ok(noReason.errors.reason);
    const withReason = buildUpdateDeliveryMethodArgs({
      ...input,
      isActive: false,
      reason: " pausing ",
    });
    assert.ok(withReason.ok);
    assert.equal(withReason.args.p_reason, "pausing");
  });

  it("rejects fractional or out-of-range cents", () => {
    const r = buildUpdateDeliveryMethodArgs({
      ...input,
      baseFeeCents: 0.5,
      minOrderCents: -2,
      freeOverCents: 2147483648,
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "fee",
      "freeOver",
      "minOrder",
    ]);
  });
});
