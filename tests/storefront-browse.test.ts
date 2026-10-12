import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  DEFAULT_SORT,
  MAX_SEARCH_LENGTH,
  PAGE_SIZE,
  debounce,
  filterInStock,
  hasCompareAt,
  initialVisibleCount,
  matchesSearch,
  maxOrderQuantity,
  nextVisibleCount,
  normalizeSearchTerm,
  parseInStockOnly,
  parseListSearch,
  withSearchParam,
  parseSortKey,
  searchProducts,
  sortProducts,
  stockLabel,
  stockState,
  type BrowseProduct,
} from "../src/features/catalog/browse.ts";
import {
  describeError,
  isNetworkFailure,
} from "../src/components/states/error-kind.ts";

function product(overrides: Partial<BrowseProduct> = {}): BrowseProduct {
  return {
    name: "Sourdough loaf",
    brand: null,
    price_cents: 25000,
    compare_at_price_cents: null,
    stock_quantity: 40,
    low_stock_threshold: 5,
    in_stock: true,
    created_at: "2026-10-01T00:00:00Z",
    ...overrides,
  };
}

describe("normalizeSearchTerm", () => {
  it("trims, collapses whitespace and rejects non-strings", () => {
    assert.equal(normalizeSearchTerm("  oat   milk \n"), "oat milk");
    assert.equal(normalizeSearchTerm(undefined), "");
    assert.equal(normalizeSearchTerm(42), "42");
    assert.equal(normalizeSearchTerm(Number.NaN), "");
    assert.equal(normalizeSearchTerm({}), "");
  });
  it("caps the length", () => {
    assert.equal(
      normalizeSearchTerm("a".repeat(500)).length,
      MAX_SEARCH_LENGTH,
    );
  });
});

describe("matchesSearch / searchProducts", () => {
  it("needs every word, in any order, case-insensitively, across name and brand", () => {
    const p = product({ name: "Oat Milk", brand: "Brookside" });
    assert.equal(matchesSearch(p, "milk oat"), true);
    assert.equal(matchesSearch(p, "BROOKSIDE milk"), true);
    assert.equal(matchesSearch(p, "milk soy"), false);
    assert.equal(matchesSearch(p, "   "), true);
  });
  it("ranks prefix matches first and keeps catalogue order inside a rank", () => {
    const list = [
      product({ name: "Wholemeal bread" }),
      product({ name: "Bread rolls" }),
      product({ name: "Sweet bread" }),
      product({ name: "Brea" }),
      product({ name: "Milk" }),
    ];
    const names = searchProducts(list, "bre").map((p) => p.name);
    assert.deepEqual(names, [
      "Bread rolls",
      "Brea",
      "Wholemeal bread",
      "Sweet bread",
    ]);
  });
  it("returns a copy of everything for an empty term", () => {
    const list = [product(), product({ name: "Milk" })];
    const out = searchProducts(list, "");
    assert.deepEqual(out, list);
    assert.notEqual(out, list);
  });
});

describe("sorting", () => {
  const list = [
    product({
      name: "B",
      price_cents: 300,
      created_at: "2026-01-02T00:00:00Z",
    }),
    product({
      name: "A",
      price_cents: 300,
      created_at: "2026-01-03T00:00:00Z",
    }),
    product({
      name: "C",
      price_cents: 100,
      created_at: "2026-01-01T00:00:00Z",
    }),
  ];
  it("parses unknown keys to the default", () => {
    assert.equal(parseSortKey("price-asc"), "price-asc");
    assert.equal(parseSortKey("drop table"), DEFAULT_SORT);
    assert.equal(parseSortKey(undefined), DEFAULT_SORT);
  });
  it("sorts by price with a name tie-break and never mutates the input", () => {
    const before = list.map((p) => p.name).join();
    assert.deepEqual(
      sortProducts(list, "price-asc").map((p) => p.name),
      ["C", "A", "B"],
    );
    assert.deepEqual(
      sortProducts(list, "price-desc").map((p) => p.name),
      ["A", "B", "C"],
    );
    assert.equal(list.map((p) => p.name).join(), before);
  });
  it("sorts newest first and by name", () => {
    assert.deepEqual(
      sortProducts(list, "newest").map((p) => p.name),
      ["A", "B", "C"],
    );
    assert.deepEqual(
      sortProducts(list, "name").map((p) => p.name),
      ["A", "B", "C"],
    );
  });
});

describe("stock presentation", () => {
  it("treats not in_stock and zero units as sold out", () => {
    assert.equal(stockState(product({ in_stock: false })).kind, "out");
    assert.equal(stockState(product({ stock_quantity: 0 })).kind, "out");
    assert.equal(stockState(product({ stock_quantity: -2 })).kind, "out");
  });
  it("shows low stock only from the product's own threshold", () => {
    assert.deepEqual(stockState(product({ stock_quantity: 3 })), {
      kind: "low",
      left: 3,
    });
    assert.equal(stockState(product({ stock_quantity: 6 })).kind, "in");
    assert.equal(
      stockState(product({ stock_quantity: 3, low_stock_threshold: null }))
        .kind,
      "in",
    );
    assert.equal(
      stockState(product({ stock_quantity: 3, low_stock_threshold: undefined }))
        .kind,
      "in",
    );
  });
  it("labels states", () => {
    assert.equal(stockLabel({ kind: "out" }), "Sold out");
    assert.equal(stockLabel({ kind: "low", left: 2 }), "Only 2 left");
    assert.equal(stockLabel({ kind: "in" }), null);
  });
  it("caps the quantity a customer can pick", () => {
    assert.equal(maxOrderQuantity(product({ stock_quantity: 4 })), 4);
    assert.equal(maxOrderQuantity(product({ stock_quantity: 500 })), 99);
    assert.equal(maxOrderQuantity(product({ in_stock: false })), 0);
    assert.equal(maxOrderQuantity(product({ stock_quantity: -1 })), 0);
  });
  it("filters sold-out products on request", () => {
    const list = [product(), product({ in_stock: false })];
    assert.equal(filterInStock(list, true).length, 1);
    assert.equal(filterInStock(list, false).length, 2);
    assert.equal(parseInStockOnly("1"), true);
    assert.equal(parseInStockOnly("true"), true);
    assert.equal(parseInStockOnly("0"), false);
    assert.equal(parseInStockOnly(undefined), false);
  });
});

describe("hasCompareAt", () => {
  it("is true only for a genuinely higher compare-at price", () => {
    assert.equal(
      hasCompareAt({ price_cents: 100, compare_at_price_cents: 150 }),
      true,
    );
    assert.equal(
      hasCompareAt({ price_cents: 100, compare_at_price_cents: 100 }),
      false,
    );
    assert.equal(
      hasCompareAt({ price_cents: 100, compare_at_price_cents: 50 }),
      false,
    );
    assert.equal(
      hasCompareAt({ price_cents: 100, compare_at_price_cents: null }),
      false,
    );
  });
});

describe("load more", () => {
  it("starts at one page and grows a page at a time, never past the total", () => {
    assert.equal(initialVisibleCount(5), 5);
    assert.equal(initialVisibleCount(100), PAGE_SIZE);
    assert.equal(nextVisibleCount(PAGE_SIZE, 100), PAGE_SIZE * 2);
    assert.equal(nextVisibleCount(PAGE_SIZE * 4, 85), 85);
    assert.equal(nextVisibleCount(0, 3), 3);
  });
});

describe("debounce", () => {
  const wait = (ms: number) =>
    new Promise((resolve) => setTimeout(resolve, ms));
  it("fires once with the last arguments", async () => {
    const calls: string[] = [];
    const fn = debounce((value: string) => calls.push(value), 20);
    fn("a");
    fn("ab");
    fn("abc");
    assert.deepEqual(calls, []);
    await wait(50);
    assert.deepEqual(calls, ["abc"]);
  });
  it("flush runs the pending call immediately, once", async () => {
    const calls: string[] = [];
    const fn = debounce((value: string) => calls.push(value), 20);
    fn("x");
    fn.flush();
    fn.flush();
    assert.deepEqual(calls, ["x"]);
    await wait(40);
    assert.deepEqual(calls, ["x"]);
  });
  it("cancel drops the pending call", async () => {
    const calls: string[] = [];
    const fn = debounce((value: string) => calls.push(value), 20);
    fn("x");
    fn.cancel();
    await wait(40);
    assert.deepEqual(calls, []);
  });
});

describe("describeError", () => {
  it("recognises network failures and an offline browser", () => {
    assert.equal(
      isNetworkFailure(new TypeError("Failed to fetch"), true),
      true,
    );
    assert.equal(
      isNetworkFailure(new Error("TypeError: Load failed"), true),
      true,
    );
    assert.equal(isNetworkFailure(new Error("whatever"), false), true);
    assert.equal(isNetworkFailure(new Error("permission denied"), true), false);
  });
  it("never leaks raw error text", () => {
    const raw = 'relation "public.products" does not exist (42P01)';
    const friendly = describeError(new Error(raw), true);
    assert.equal(friendly.kind, "generic");
    assert.ok(!friendly.message.includes("42P01"));
    assert.ok(!friendly.message.includes("relation"));
    const offline = describeError(new Error(raw), false);
    assert.equal(offline.kind, "offline");
  });
});

describe("URL state", () => {
  it("parseListSearch keeps only non-default, valid values", () => {
    assert.deepEqual(parseListSearch({}), {});
    assert.deepEqual(parseListSearch({ sort: "name" }), {});
    assert.deepEqual(parseListSearch({ sort: "price-desc", instock: "1" }), {
      sort: "price-desc",
      instock: true,
    });
    assert.deepEqual(parseListSearch({ sort: "evil", instock: "0" }), {});
    assert.deepEqual(parseListSearch({ instock: true }), { instock: true });
    assert.deepEqual(parseListSearch({ instock: 1 }), { instock: true });
  });
  it("withSearchParam sets and removes without mutating", () => {
    const before = { q: "oat", sort: "newest" };
    assert.deepEqual(withSearchParam(before, "sort", "price-asc"), {
      q: "oat",
      sort: "price-asc",
    });
    assert.deepEqual(withSearchParam(before, "sort", null), { q: "oat" });
    assert.deepEqual(withSearchParam(before, "q", ""), { sort: "newest" });
    assert.deepEqual(before, { q: "oat", sort: "newest" });
  });
});
