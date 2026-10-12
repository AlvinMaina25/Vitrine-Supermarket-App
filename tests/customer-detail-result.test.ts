import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminCustomerDetailError,
  toAdminCustomerDetail,
  toAdminCustomerDetailError,
  toAdminGetCustomerArgs,
} from "../src/features/admin/customer-detail-result.ts";

const address = {
  id: "a1",
  label: "Home",
  full_name: "Amina",
  phone: null,
  address_line_1: "1 Road",
  address_line_2: null,
  city: "Nairobi",
  county: "Nairobi",
  postal_code: null,
  delivery_instructions: null,
  is_default: true,
  created_at: "2026-10-01T10:00:00Z",
};
const detail = {
  profile: {
    id: "c1",
    name: "Amina",
    email: "a@example.com",
    phone: null,
    status: "suspended",
    created_at: "2026-10-01T10:00:00Z",
  },
  addresses: [address],
  stats: {
    order_count: 3,
    lifetime_spend_cents: 99900,
    last_order_at: "2026-10-03T10:00:00Z",
  },
  recent_orders: [
    {
      id: "o1",
      status: "cancelled",
      payment_status: "unpaid",
      total_cents: 4500,
      created_at: "2026-10-03T10:00:00Z",
    },
  ],
  notes: "Prefers mornings",
  notes_updated_at: "2026-10-04T10:00:00Z",
};

describe("toAdminCustomerDetail", () => {
  it("parses the full payload", () => {
    const d = toAdminCustomerDetail(detail);
    assert.equal(d.profile.status, "suspended");
    assert.equal(d.addresses[0]?.is_default, true);
    assert.equal(d.stats.lifetime_spend_cents, 99900);
    assert.equal(d.recent_orders[0]?.total_cents, 4500);
    assert.equal(d.notes, "Prefers mornings");
  });

  it("accepts no notes, no addresses, no orders", () => {
    const d = toAdminCustomerDetail({
      ...detail,
      addresses: [],
      recent_orders: [],
      notes: null,
      notes_updated_at: null,
      stats: { order_count: 0, lifetime_spend_cents: 0, last_order_at: null },
    });
    assert.equal(d.notes, null);
    assert.equal(d.notes_updated_at, null);
    assert.deepEqual(d.addresses, []);
  });

  it("treats missing notes keys as null", () => {
    const { notes: _n, notes_updated_at: _t, ...rest } = detail;
    const d = toAdminCustomerDetail(rest);
    assert.equal(d.notes, null);
    assert.equal(d.notes_updated_at, null);
  });

  it("rejects bad envelopes and sections", () => {
    for (const bad of [null, "x", [], {}]) {
      assert.throws(() => toAdminCustomerDetail(bad), /unexpected response/);
    }
    assert.throws(
      () => toAdminCustomerDetail({ ...detail, profile: null }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminCustomerDetail({ ...detail, addresses: {} }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminCustomerDetail({ ...detail, stats: [] }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminCustomerDetail({ ...detail, notes: 5 }),
      /unexpected/,
    );
  });

  it("rejects non-integer money and a bad status", () => {
    assert.throws(
      () =>
        toAdminCustomerDetail({
          ...detail,
          recent_orders: [{ ...detail.recent_orders[0], total_cents: 45.5 }],
        }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminCustomerDetail({
          ...detail,
          stats: { ...detail.stats, lifetime_spend_cents: "99900" },
        }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminCustomerDetail({
          ...detail,
          profile: { ...detail.profile, status: "x" },
        }),
      /unexpected/,
    );
  });

  it("rejects a malformed address", () => {
    assert.throws(
      () =>
        toAdminCustomerDetail({
          ...detail,
          addresses: [{ ...address, is_default: "yes" }],
        }),
      /unexpected/,
    );
  });
});

describe("toAdminCustomerDetailError", () => {
  it("maps not-authorised and customer_not_found", () => {
    assert.ok(
      toAdminCustomerDetailError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
    const e = toAdminCustomerDetailError({
      message: "x",
      details: "customer_not_found",
    });
    assert.ok(e instanceof AdminCustomerDetailError);
    assert.equal((e as AdminCustomerDetailError).reason, "customer_not_found");
  });

  it("keeps unknown errors as plain errors", () => {
    const e = toAdminCustomerDetailError({ message: "boom" });
    assert.equal(e.message, "boom");
    assert.ok(!(e instanceof AdminCustomerDetailError));
  });
});

describe("toAdminGetCustomerArgs", () => {
  it("names the argument", () => {
    assert.deepEqual(toAdminGetCustomerArgs("c1"), { p_customer_id: "c1" });
  });
});
