import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { toAdminDeliveryConfig } from "../src/features/admin/delivery-config-result.ts";

const method = {
  code: "standard",
  label: "Standard",
  description: null,
  base_fee_cents: 25000,
  free_over_cents: null,
  min_order_cents: 0,
  requires_slot: true,
  requires_address: true,
  eta_label: "Same day",
  position: 0,
  is_active: true,
  created_at: "2026-10-01T00:00:00Z",
  updated_at: "2026-10-01T00:00:00Z",
};
const zone = {
  id: "z1",
  code: "nairobi",
  name: "Nairobi",
  description: null,
  county: "Nairobi",
  towns: ["Westlands", "Kilimani"],
  position: 1,
  is_active: true,
};
const fee = {
  id: "f1",
  zone_id: "z1",
  method_code: "standard",
  fee_cents: 30000,
  free_over_cents: 500000,
  min_order_cents: 100000,
  is_active: false,
  zone_code: "nairobi",
  zone_name: "Nairobi",
  method_label: "Standard",
};
const ok = { methods: [method], zones: [zone], zone_fees: [fee] };

describe("toAdminDeliveryConfig", () => {
  it("parses methods, zones and zone fees and keeps cents as integers", () => {
    const c = toAdminDeliveryConfig(ok);
    assert.equal(c.methods[0]?.base_fee_cents, 25000);
    assert.equal(c.methods[0]?.free_over_cents, null);
    assert.deepEqual(c.zones[0]?.towns, ["Westlands", "Kilimani"]);
    assert.equal(c.zone_fees[0]?.free_over_cents, 500000);
    assert.equal(c.zone_fees[0]?.is_active, false);
    assert.equal(c.zone_fees[0]?.method_label, "Standard");
  });

  it("accepts empty lists", () => {
    assert.deepEqual(
      toAdminDeliveryConfig({ methods: [], zones: [], zone_fees: [] }),
      {
        methods: [],
        zones: [],
        zone_fees: [],
      },
    );
  });

  it("rejects malformed payloads without echoing them", () => {
    for (const bad of [
      null,
      "x",
      [],
      {},
      { ...ok, methods: "no" },
      { ...ok, zones: [1] },
    ]) {
      assert.throws(() => toAdminDeliveryConfig(bad), /unexpected response/);
    }
  });

  it("rejects fractional, negative or non-number cents", () => {
    for (const cents of [12.5, -1, "100", Number.NaN, null]) {
      assert.throws(
        () =>
          toAdminDeliveryConfig({
            ...ok,
            methods: [{ ...method, base_fee_cents: cents }],
          }),
        /unexpected/,
      );
    }
    assert.throws(
      () =>
        toAdminDeliveryConfig({
          ...ok,
          zone_fees: [{ ...fee, free_over_cents: 1.5 }],
        }),
      /unexpected/,
    );
  });

  it("rejects wrong types in zones and fees", () => {
    assert.throws(
      () => toAdminDeliveryConfig({ ...ok, zones: [{ ...zone, towns: [1] }] }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminDeliveryConfig({
          ...ok,
          zones: [{ ...zone, is_active: "yes" }],
        }),
      /unexpected/,
    );
    const { zone_code: _omit, ...noZoneCode } = fee;
    assert.throws(
      () => toAdminDeliveryConfig({ ...ok, zone_fees: [noZoneCode] }),
      /unexpected/,
    );
  });
});
