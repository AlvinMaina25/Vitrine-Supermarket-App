import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  CUSTOMERS_MAX_PAGE,
  CUSTOMERS_MAX_SEARCH_LENGTH,
  CUSTOMERS_PAGE_SIZE,
  CUSTOMER_STATUSES,
  CUSTOMER_STATUS_LABELS,
  activeCustomersPage,
  customersTotalPages,
  hasCustomersFilter,
  normaliseCustomersParams,
  parseCustomersParams,
  toCustomersListArgs,
  toCustomersListQuery,
  truncateCodePoints,
  withCustomersFilter,
  withCustomersPage,
} from "../src/features/admin/customers-management.ts";

describe("parseCustomersParams", () => {
  it("returns defaults (nothing set) for an empty search", () => {
    assert.deepEqual(parseCustomersParams({}), {});
  });

  it("keeps a trimmed search, a valid status and a page above 1", () => {
    assert.deepEqual(
      parseCustomersParams({ q: "  amina ", status: "suspended", page: "3" }),
      {
        q: "amina",
        status: "suspended",
        page: 3,
      },
    );
  });

  it("drops blank, non-string and oversized-type search values", () => {
    for (const q of ["", "   ", 5, null, undefined, {}, ["a"]]) {
      assert.deepEqual(parseCustomersParams({ q }), {});
    }
  });

  it("trims over-long search to the database limit", () => {
    const q = parseCustomersParams({ q: "x".repeat(300) }).q;
    assert.equal(q?.length, CUSTOMERS_MAX_SEARCH_LENGTH);
  });

  it("drops unknown or wrong-case status values", () => {
    for (const status of [
      "Active",
      "SUSPENDED",
      "banned",
      "",
      1,
      null,
      undefined,
    ]) {
      assert.deepEqual(parseCustomersParams({ status }), {});
    }
  });

  it("drops page 1, invalid and out-of-range pages", () => {
    for (const page of [
      1,
      "1",
      0,
      -2,
      2.5,
      "abc",
      "",
      null,
      undefined,
      CUSTOMERS_MAX_PAGE + 1,
    ]) {
      assert.equal(
        parseCustomersParams({ page }).page,
        undefined,
        String(page),
      );
    }
    assert.equal(
      parseCustomersParams({ page: CUSTOMERS_MAX_PAGE }).page,
      CUSTOMERS_MAX_PAGE,
    );
  });
});

describe("normalisation and transitions", () => {
  it("normalise removes defaults and junk", () => {
    assert.deepEqual(normaliseCustomersParams({ q: "  ", page: 1 }), {});
    assert.deepEqual(
      normaliseCustomersParams({ q: " a ", status: "active", page: 2 }),
      {
        q: "a",
        status: "active",
        page: 2,
      },
    );
  });

  it("a new search or status resets to page 1", () => {
    const base = { q: "a", status: "active" as const, page: 4 };
    assert.deepEqual(withCustomersFilter(base, { q: "b" }), {
      q: "b",
      status: "active",
    });
    assert.deepEqual(withCustomersFilter(base, { status: "suspended" }), {
      q: "a",
      status: "suspended",
    });
  });

  it("null clears a filter, undefined keeps it", () => {
    const base = { q: "a", status: "active" as const };
    assert.deepEqual(withCustomersFilter(base, { status: null }), { q: "a" });
    assert.deepEqual(withCustomersFilter(base, { q: null }), {
      status: "active",
    });
    assert.deepEqual(withCustomersFilter(base, {}), base);
  });

  it("paging keeps the filters and drops page 1", () => {
    const base = { q: "a", status: "active" as const };
    assert.deepEqual(withCustomersPage(base, 3), { ...base, page: 3 });
    assert.deepEqual(withCustomersPage({ ...base, page: 3 }, 1), base);
  });
});

describe("mapping to the list RPC", () => {
  it("defaults: page 1, size 25, no search, no status", () => {
    assert.equal(activeCustomersPage({}), 1);
    assert.deepEqual(toCustomersListQuery({}), {
      search: null,
      status: null,
      page: 1,
      pageSize: CUSTOMERS_PAGE_SIZE,
    });
    assert.deepEqual(toCustomersListArgs({}), {
      p_search: null,
      p_page: 1,
      p_page_size: 25,
      p_status: null,
    });
  });

  it("maps search, status and page to the named arguments", () => {
    assert.deepEqual(
      toCustomersListArgs({ q: "amina", status: "suspended", page: 3 }),
      {
        p_search: "amina",
        p_page: 3,
        p_page_size: 25,
        p_status: "suspended",
      },
    );
  });

  it("honours an explicit page size", () => {
    assert.equal(toCustomersListArgs({}, 50).p_page_size, 50);
  });
});

describe("totals and labels", () => {
  it("customersTotalPages is at least 1 and rounds up", () => {
    assert.equal(customersTotalPages(0, 25), 1);
    assert.equal(customersTotalPages(25, 25), 1);
    assert.equal(customersTotalPages(26, 25), 2);
    assert.equal(customersTotalPages(100, 25), 4);
    assert.equal(customersTotalPages(10, 0), 1);
    assert.equal(customersTotalPages(Number.NaN, 25), 1);
  });

  it("hasCustomersFilter ignores paging", () => {
    assert.equal(hasCustomersFilter({}), false);
    assert.equal(hasCustomersFilter({ page: 3 }), false);
    assert.equal(hasCustomersFilter({ q: "a" }), true);
    assert.equal(hasCustomersFilter({ status: "active" }), true);
  });

  it("has a label for every status", () => {
    for (const s of CUSTOMER_STATUSES) assert.ok(CUSTOMER_STATUS_LABELS[s]);
  });
});

describe("truncating by code point", () => {
  it("leaves short text alone and cuts long text at the limit", () => {
    assert.equal(truncateCodePoints("abc", 5), "abc");
    assert.equal(truncateCodePoints("abcdef", 3), "abc");
  });

  it("never splits an emoji surrogate pair", () => {
    const text = "a".repeat(99) + "😀" + "tail";
    const cut = truncateCodePoints(text, CUSTOMERS_MAX_SEARCH_LENGTH);
    assert.equal(Array.from(cut).length, 100);
    assert.ok(cut.endsWith("😀"));
    assert.doesNotMatch(cut, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/);
  });

  it("is applied to the search parameter", () => {
    const q = parseCustomersParams({ q: "b".repeat(99) + "😀😀" }).q ?? "";
    assert.equal(Array.from(q).length, 100);
    assert.ok(q.endsWith("😀"));
    assert.equal(
      parseCustomersParams({ q: "😀".repeat(150) }).q,
      "😀".repeat(100),
    );
  });
});
