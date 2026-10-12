import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  toAdminCustomerList,
  toAdminCustomersError,
  toAdminListCustomersArgs,
} from "../src/features/admin/customers-result.ts";

const row = {
  id: "c1",
  name: "Amina",
  email: "a@example.com",
  phone: null,
  status: "active",
  created_at: "2026-10-01T10:00:00Z",
  order_count: 2,
  lifetime_spend_cents: 125050,
  last_order_at: "2026-10-03T10:00:00Z",
};
const page = { total: 1, page: 1, page_size: 25, customers: [row] };

describe("toAdminCustomerList", () => {
  it("parses a page and keeps cents as integers", () => {
    const list = toAdminCustomerList(page);
    assert.equal(list.total, 1);
    assert.equal(list.customers[0]?.lifetime_spend_cents, 125050);
    assert.equal(list.customers[0]?.phone, null);
  });

  it("accepts an empty page and null last_order_at", () => {
    assert.deepEqual(
      toAdminCustomerList({ ...page, customers: [] }).customers,
      [],
    );
    const list = toAdminCustomerList({
      ...page,
      customers: [
        {
          ...row,
          order_count: 0,
          lifetime_spend_cents: 0,
          last_order_at: null,
        },
      ],
    });
    assert.equal(list.customers[0]?.last_order_at, null);
  });

  it("rejects non-objects and missing envelope fields", () => {
    for (const bad of [null, undefined, "x", 5, [], {}]) {
      assert.throws(() => toAdminCustomerList(bad), /unexpected response/);
    }
    assert.throws(
      () => toAdminCustomerList({ ...page, total: "1" }),
      /unexpected response/,
    );
    assert.throws(
      () => toAdminCustomerList({ ...page, customers: null }),
      /unexpected response/,
    );
  });

  it("rejects fractional, negative or string money and counts", () => {
    for (const patch of [
      { lifetime_spend_cents: 10.5 },
      { lifetime_spend_cents: -1 },
      { lifetime_spend_cents: "100" },
      { order_count: 1.5 },
    ]) {
      assert.throws(
        () =>
          toAdminCustomerList({ ...page, customers: [{ ...row, ...patch }] }),
        /unexpected response/,
      );
    }
  });

  it("rejects an unknown status or a missing id", () => {
    assert.throws(
      () =>
        toAdminCustomerList({
          ...page,
          customers: [{ ...row, status: "banned" }],
        }),
      /unexpected response/,
    );
    assert.throws(
      () =>
        toAdminCustomerList({
          ...page,
          customers: [{ ...row, id: undefined }],
        }),
      /unexpected response/,
    );
  });
});

describe("toAdminCustomersError", () => {
  it("maps not-authorised to AdminAccessError", () => {
    assert.ok(
      toAdminCustomersError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
    assert.ok(
      toAdminCustomersError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("does not leak the raw message for invalid arguments, keeps others", () => {
    const invalid = toAdminCustomersError({
      message: "raw db text",
      details: "invalid_arguments",
    });
    assert.ok(!invalid.message.includes("raw db text"));
    assert.equal(toAdminCustomersError({ message: "boom" }).message, "boom");
  });
});

describe("toAdminListCustomersArgs", () => {
  it("defaults explicitly", () => {
    assert.deepEqual(toAdminListCustomersArgs(), {
      p_search: null,
      p_page: 1,
      p_page_size: 25,
      p_status: null,
    });
  });

  it("trims search, blanks become null, passes status and paging", () => {
    assert.equal(toAdminListCustomersArgs({ search: "   " }).p_search, null);
    assert.deepEqual(
      toAdminListCustomersArgs({
        search: " amina ",
        status: "suspended",
        page: 3,
        pageSize: 50,
      }),
      { p_search: "amina", p_page: 3, p_page_size: 50, p_status: "suspended" },
    );
  });
});
