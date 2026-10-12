import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { BrowseProduct } from "../src/features/catalog/browse.ts";
import {
  CLEAR_FILTERS_PATCH,
  MAX_BRAND_FILTERS,
  MINOR_UNITS_PER_MAJOR,
  activeFilterChips,
  allowedTypos,
  applyFilters,
  brandFacets,
  countActiveFilters,
  defaultSortFor,
  describeResults,
  discover,
  editDistance,
  filtersFromSearch,
  parseBrandList,
  parseDiscoverySearch,
  parseDiscoverySort,
  patchSearch,
  priceRangePatch,
  removeFilterPatch,
  searchTolerant,
  sortFromSearch,
  sortOptionsFor,
  suggestProducts,
  toggleBrandPatch,
  NO_FILTERS,
} from "../src/features/catalog/discovery.ts";

function p(overrides: Partial<BrowseProduct> = {}): BrowseProduct {
  return {
    name: "Item",
    brand: null,
    price_cents: 10000,
    compare_at_price_cents: null,
    stock_quantity: 10,
    low_stock_threshold: null,
    in_stock: true,
    created_at: "2026-09-01T00:00:00Z",
    ...overrides,
  };
}

const CATALOGUE: BrowseProduct[] = [
  p({
    name: "Fresh milk 1L",
    brand: "Brookside",
    price_cents: 12000,
    compare_at_price_cents: 13500,
    created_at: "2026-09-03T00:00:00Z",
  }),
  p({
    name: "Long life milk 1L",
    brand: "Tuzo",
    price_cents: 13000,
    created_at: "2026-09-04T00:00:00Z",
  }),
  p({
    name: "Plain yoghurt 500g",
    brand: "Brookside",
    price_cents: 9000,
    created_at: "2026-09-05T00:00:00Z",
  }),
  p({
    name: "Strawberry yoghurt",
    brand: "Daima",
    price_cents: 9500,
    stock_quantity: 0,
    created_at: "2026-09-06T00:00:00Z",
  }),
  p({
    name: "Sugar 1kg",
    brand: "Mumias",
    price_cents: 16500,
    in_stock: false,
    created_at: "2026-09-07T00:00:00Z",
  }),
  p({
    name: "Tea leaves",
    brand: null,
    price_cents: 25000,
    created_at: "2026-09-08T00:00:00Z",
  }),
  p({
    name: "Tea bags",
    brand: "Ketepa",
    price_cents: 18000,
    created_at: "2026-09-09T00:00:00Z",
  }),
];
const names = (list: readonly BrowseProduct[]) => list.map((x) => x.name);

describe("editDistance / allowedTypos", () => {
  it("counts insert, delete, substitute and neighbour swaps as one", () => {
    assert.equal(editDistance("milk", "milk"), 0);
    assert.equal(editDistance("mlik", "milk"), 1); // swap
    assert.equal(editDistance("mik", "milk"), 1); // missing letter
    assert.equal(editDistance("milkk", "milk"), 1); // extra letter
    assert.equal(editDistance("silk", "milk"), 1); // substitution
  });
  it("stops early above the limit", () => {
    assert.equal(editDistance("abcdef", "uvwxyz", 2), 3);
    assert.equal(editDistance("a", "abcdef", 2), 3);
  });
  it("short words get no typo allowance, long words get more", () => {
    assert.equal(allowedTypos(3), 0);
    assert.equal(allowedTypos(4), 1);
    assert.equal(allowedTypos(7), 1);
    assert.equal(allowedTypos(8), 2);
  });
});

describe("searchTolerant", () => {
  it("returns exact matches untouched and not flagged as corrected", () => {
    const out = searchTolerant(CATALOGUE, "milk");
    assert.deepEqual(names(out.results), [
      "Fresh milk 1L",
      "Long life milk 1L",
    ]);
    assert.equal(out.corrected, false);
  });
  it("does not add fuzzy hits to a search that already has exact hits", () => {
    // "tea" exact-matches two products; nothing fuzzy is mixed in.
    assert.equal(searchTolerant(CATALOGUE, "tea").results.length, 2);
  });
  it("finds a transposed word only when nothing matches exactly", () => {
    const out = searchTolerant(CATALOGUE, "mlik");
    assert.deepEqual(names(out.results), [
      "Fresh milk 1L",
      "Long life milk 1L",
    ]);
    assert.equal(out.corrected, true);
  });
  it("tolerates a slip in a longer word and word order", () => {
    const out = searchTolerant(CATALOGUE, "yogurt plain");
    assert.deepEqual(names(out.results), ["Plain yoghurt 500g"]);
    assert.equal(out.corrected, true);
  });
  it("never fuzzy-matches very short words", () => {
    assert.deepEqual(searchTolerant(CATALOGUE, "tex").results, []);
  });
  it("returns nothing, honestly, when no spelling is close", () => {
    const out = searchTolerant(CATALOGUE, "zzzzzz");
    assert.deepEqual(out.results, []);
    assert.equal(out.corrected, false);
  });
  it("an empty term returns everything unchanged", () => {
    assert.equal(
      searchTolerant(CATALOGUE, "  ").results.length,
      CATALOGUE.length,
    );
  });
});

describe("suggestProducts", () => {
  it("needs two characters and respects the limit", () => {
    assert.deepEqual(suggestProducts(CATALOGUE, "m"), []);
    assert.equal(suggestProducts(CATALOGUE, "tea", 1).length, 1);
  });
});

describe("sort keys", () => {
  it("relevance exists only with a query", () => {
    assert.equal(defaultSortFor(true), "relevance");
    assert.equal(defaultSortFor(false), "name");
    assert.equal(parseDiscoverySort("relevance", false), "name");
    assert.equal(parseDiscoverySort("relevance", true), "relevance");
    assert.equal(parseDiscoverySort("price-asc", true), "price-asc");
    assert.equal(parseDiscoverySort("bogus", true), "relevance");
    assert.equal(sortOptionsFor(true)[0]?.value, "relevance");
    assert.equal(
      sortOptionsFor(false).some((o) => o.value === "relevance"),
      false,
    );
  });
});

describe("applyFilters", () => {
  it("in stock hides products with no units or the flag off", () => {
    const out = applyFilters(CATALOGUE, { ...NO_FILTERS, inStockOnly: true });
    assert.equal(names(out).includes("Strawberry yoghurt"), false);
    assert.equal(names(out).includes("Sugar 1kg"), false);
    assert.equal(out.length, 5);
  });
  it("on offer needs a real higher compare-at price", () => {
    const out = applyFilters(CATALOGUE, { ...NO_FILTERS, onOffer: true });
    assert.deepEqual(names(out), ["Fresh milk 1L"]);
  });
  it("brand matches case-insensitively and ignores products with no brand", () => {
    const out = applyFilters(CATALOGUE, {
      ...NO_FILTERS,
      brands: ["brookside", "KETEPA"],
    });
    assert.deepEqual(names(out), [
      "Fresh milk 1L",
      "Plain yoghurt 500g",
      "Tea bags",
    ]);
  });
  it("price range is inclusive and in whole units", () => {
    const out = applyFilters(CATALOGUE, {
      ...NO_FILTERS,
      minPrice: 95,
      maxPrice: 130,
    });
    assert.deepEqual(names(out), [
      "Fresh milk 1L",
      "Long life milk 1L",
      "Strawberry yoghurt",
    ]);
    assert.equal(MINOR_UNITS_PER_MAJOR, 100);
  });
  it("filters combine (AND)", () => {
    const out = applyFilters(CATALOGUE, {
      ...NO_FILTERS,
      brands: ["Brookside"],
      inStockOnly: true,
      maxPrice: 100,
    });
    assert.deepEqual(names(out), ["Plain yoghurt 500g"]);
  });
  it("does not mutate its input", () => {
    const copy = [...CATALOGUE];
    applyFilters(CATALOGUE, { ...NO_FILTERS, inStockOnly: true });
    assert.deepEqual(CATALOGUE, copy);
  });
  it("counts active filters (a price range is one)", () => {
    assert.equal(countActiveFilters(NO_FILTERS), 0);
    assert.equal(
      countActiveFilters({
        ...NO_FILTERS,
        inStockOnly: true,
        brands: ["a", "b"],
        minPrice: 1,
        maxPrice: 2,
      }),
      4,
    );
  });
});

describe("brandFacets", () => {
  it("counts under the other filters and lists brands A-Z", () => {
    const facets = brandFacets(CATALOGUE, { ...NO_FILTERS, inStockOnly: true });
    assert.deepEqual(facets, [
      { label: "Brookside", count: 2 },
      { label: "Ketepa", count: 1 },
      { label: "Tuzo", count: 1 },
    ]);
  });
  it("ignores the brand filter itself so other brands stay visible", () => {
    const facets = brandFacets(CATALOGUE, { ...NO_FILTERS, brands: ["Tuzo"] });
    assert.equal(
      facets.some((f) => f.label === "Brookside"),
      true,
    );
  });
  it("keeps a selected brand listed with 0 when other filters hide it", () => {
    const facets = brandFacets(CATALOGUE, {
      ...NO_FILTERS,
      brands: ["Mumias"],
      inStockOnly: true,
    });
    assert.deepEqual(
      facets.find((f) => f.label === "Mumias"),
      { label: "Mumias", count: 0 },
    );
  });
});

describe("discover (global across pages)", () => {
  const many: BrowseProduct[] = Array.from({ length: 45 }, (_, i) =>
    p({
      name: `Product ${String(i).padStart(2, "0")}`,
      price_cents: (45 - i) * 1000,
      brand: i % 3 === 0 ? "A" : "B",
    }),
  );
  it("sorts the WHOLE list, so the cheapest item is first even if it was 'on page 3'", () => {
    const { results } = discover(many, {
      term: "",
      filters: NO_FILTERS,
      sort: "price-asc",
    });
    assert.equal(results.length, 45);
    assert.equal(results[0]?.name, "Product 44");
    assert.deepEqual(
      results.map((r) => r.price_cents),
      [...results.map((r) => r.price_cents)].sort((a, b) => a - b),
    );
  });
  it("filters before the count, so the total is the filtered total", () => {
    const { results, searchedCount } = discover(many, {
      term: "",
      filters: { ...NO_FILTERS, brands: ["A"] },
      sort: "name",
    });
    assert.equal(results.length, 15);
    assert.equal(searchedCount, 45);
  });
  it("relevance keeps the search ranking; any other sort overrides it", () => {
    const list = [
      p({ name: "Aloe milk drink" }),
      p({ name: "Milk chocolate" }),
      p({ name: "Milk 1L" }),
    ];
    const rel = discover(list, {
      term: "milk",
      filters: NO_FILTERS,
      sort: "relevance",
    }).results;
    assert.deepEqual(names(rel), [
      "Milk chocolate",
      "Milk 1L",
      "Aloe milk drink",
    ]);
    const byName = discover(list, {
      term: "milk",
      filters: NO_FILTERS,
      sort: "name",
    }).results;
    assert.deepEqual(names(byName), [
      "Aloe milk drink",
      "Milk 1L",
      "Milk chocolate",
    ]);
  });
  it("relevance with no term behaves as name, and reports corrections", () => {
    assert.deepEqual(
      names(
        discover(CATALOGUE, {
          term: "",
          filters: NO_FILTERS,
          sort: "relevance",
        }).results,
      ),
      names([...CATALOGUE].sort((a, b) => a.name.localeCompare(b.name))),
    );
    assert.equal(
      discover(CATALOGUE, {
        term: "mlik",
        filters: NO_FILTERS,
        sort: "relevance",
      }).corrected,
      true,
    );
  });
  it("never mutates the cached list", () => {
    const copy = [...many];
    discover(many, { term: "", filters: NO_FILTERS, sort: "price-desc" });
    assert.deepEqual(many, copy);
  });
});

describe("URL parsing", () => {
  it("a clean URL stays clean", () => {
    assert.deepEqual(parseDiscoverySearch({}), {});
    assert.deepEqual(
      parseDiscoverySearch({
        sort: "name",
        instock: "0",
        offer: "no",
        min: "0",
      }),
      {},
    );
  });
  it("reads every key, including values the router turned into numbers", () => {
    assert.deepEqual(
      parseDiscoverySearch({
        q: 500,
        sort: "price-desc",
        instock: "1",
        offer: true,
        brand: "Brookside|Tuzo",
        min: 100,
        max: "500",
      }),
      {
        q: "500",
        sort: "price-desc",
        instock: true,
        offer: true,
        brand: "Brookside|Tuzo",
        min: 100,
        max: 500,
      },
    );
  });
  it("relevance is the default with a query, so it is omitted; name is then explicit", () => {
    assert.deepEqual(parseDiscoverySearch({ q: "milk", sort: "relevance" }), {
      q: "milk",
    });
    assert.deepEqual(parseDiscoverySearch({ q: "milk", sort: "name" }), {
      q: "milk",
      sort: "name",
    });
    assert.deepEqual(parseDiscoverySearch({ sort: "relevance" }), {});
  });
  it("allowQuery:false ignores q (category pages)", () => {
    assert.deepEqual(
      parseDiscoverySearch({ q: "milk" }, { allowQuery: false }),
      {},
    );
  });
  it("rejects junk: negatives, decimals text, huge numbers, unknown keys", () => {
    assert.deepEqual(
      parseDiscoverySearch({ min: -5, max: "abc", foo: "bar" }),
      {},
    );
    assert.deepEqual(parseDiscoverySearch({ max: 99999999999 }), {
      max: 10_000_000,
    });
    assert.deepEqual(parseDiscoverySearch({ min: "12.5" }), {});
  });
  it("swaps a reversed price range instead of returning nothing", () => {
    assert.deepEqual(parseDiscoverySearch({ min: 500, max: 100 }), {
      min: 100,
      max: 500,
    });
  });
  it("brand list: trims, de-duplicates case-insensitively, caps the count", () => {
    assert.deepEqual(parseBrandList(" A | a |B||"), ["A", "B"]);
    assert.deepEqual(parseBrandList(7), ["7"]);
    assert.equal(
      parseBrandList(Array.from({ length: 30 }, (_, i) => `b${i}`).join("|"))
        .length,
      MAX_BRAND_FILTERS,
    );
    assert.deepEqual(parseBrandList(undefined), []);
  });
  it("round-trips into filters and sort", () => {
    const search = parseDiscoverySearch({
      q: "tea",
      instock: "1",
      brand: "Ketepa",
      min: 50,
    });
    assert.deepEqual(filtersFromSearch(search), {
      inStockOnly: true,
      onOffer: false,
      brands: ["Ketepa"],
      minPrice: 50,
      maxPrice: null,
    });
    assert.equal(sortFromSearch(search), "relevance");
    assert.equal(sortFromSearch({}), "name");
  });
});

describe("chips and patches", () => {
  const search = parseDiscoverySearch({
    q: "tea",
    instock: "1",
    offer: "1",
    brand: "Ketepa|Tuzo",
    min: 50,
    max: 300,
  });
  it("one chip per filter, one per brand, one for the price range", () => {
    const chips = activeFilterChips(search, "KES");
    assert.deepEqual(
      chips.map((c) => c.label),
      ["In stock only", "On offer", "Ketepa", "Tuzo", "KES 50–300"],
    );
  });
  it("describes open-ended price ranges", () => {
    assert.equal(
      activeFilterChips({ min: 50 }, "KES")[0]?.label,
      "From KES 50",
    );
    assert.equal(
      activeFilterChips({ max: 300 }, "KES")[0]?.label,
      "Up to KES 300",
    );
  });
  it("removing a chip patches only that filter", () => {
    assert.deepEqual(removeFilterPatch(search, { key: "instock" }), {
      instock: null,
    });
    assert.deepEqual(removeFilterPatch(search, { key: "price" }), {
      min: null,
      max: null,
    });
    assert.deepEqual(
      removeFilterPatch(search, { key: "brand", value: "ketepa" }),
      { brand: "Tuzo" },
    );
    assert.deepEqual(
      removeFilterPatch({ brand: "Tuzo" }, { key: "brand", value: "Tuzo" }),
      { brand: null },
    );
  });
  it("toggling a brand adds then removes it", () => {
    assert.deepEqual(toggleBrandPatch({}, "Tuzo"), { brand: "Tuzo" });
    assert.deepEqual(toggleBrandPatch({ brand: "Tuzo" }, "tuzo"), {
      brand: null,
    });
    assert.deepEqual(toggleBrandPatch({ brand: "Tuzo" }, "Ketepa"), {
      brand: "Tuzo|Ketepa",
    });
  });
  it("clear-all removes filters but leaves q and sort in the URL", () => {
    const next = patchSearch(
      {
        q: "tea",
        sort: "price-asc",
        instock: true,
        offer: true,
        brand: "X",
        min: 1,
        max: 2,
      },
      CLEAR_FILTERS_PATCH,
    );
    assert.deepEqual(next, { q: "tea", sort: "price-asc" });
  });
  it("patchSearch removes on null/empty and never mutates", () => {
    const prev = { a: 1, b: 2 };
    assert.deepEqual(patchSearch(prev, { a: null, c: "x", b: "" }), { c: "x" });
    assert.deepEqual(prev, { a: 1, b: 2 });
  });
  it("typed price inputs: blank clears, junk clears, reversed swaps, commas ok", () => {
    assert.deepEqual(priceRangePatch("", ""), { min: null, max: null });
    assert.deepEqual(priceRangePatch("abc", "200"), { min: null, max: 200 });
    assert.deepEqual(priceRangePatch("500", "100"), { min: 100, max: 500 });
    assert.deepEqual(priceRangePatch("1,000", ""), { min: 1000, max: null });
    assert.deepEqual(priceRangePatch("0", "50"), { min: null, max: 50 });
  });
});

describe("describeResults", () => {
  it("singular, plural, filtered and corrected wording", () => {
    assert.equal(
      describeResults({
        shown: 1,
        searchedCount: 1,
        filtersActive: false,
        corrected: false,
      }),
      "1 product",
    );
    assert.equal(
      describeResults({
        shown: 12,
        searchedCount: 12,
        filtersActive: true,
        corrected: false,
      }),
      "12 products",
    );
    assert.equal(
      describeResults({
        shown: 3,
        searchedCount: 12,
        filtersActive: true,
        corrected: false,
      }),
      "3 products of 12",
    );
    assert.equal(
      describeResults({
        shown: 2,
        searchedCount: 2,
        filtersActive: false,
        corrected: true,
      }),
      "2 products, showing similar spellings",
    );
  });
});
