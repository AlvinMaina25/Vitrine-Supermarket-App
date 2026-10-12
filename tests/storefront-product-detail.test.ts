import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  childCategories,
  categoryTrail,
  subtreeIds,
  type TreeCategory,
} from "../src/features/catalog/category-tree.ts";
import {
  MAX_LINE_QUANTITY,
  clampQuantity,
  collectAllPages,
  initialVariantId,
  isVariantAvailable,
  orderedVariants,
  purchasableForProduct,
  purchasableForVariant,
  quantityLimit,
  quantityMessage,
  relatedProducts,
  variantPriceRange,
  variantStockState,
  type RelatableProduct,
  type VariantLike,
} from "../src/features/catalog/product-detail.ts";
import {
  MAX_RECENTLY_VIEWED,
  RECENTLY_VIEWED_KEY,
  addRecentlyViewed,
  clearRecentlyViewed,
  parseRecentlyViewed,
  readRecentlyViewed,
  recordRecentlyViewed,
  resolveRecentlyViewed,
  type StorageLike,
} from "../src/features/catalog/recently-viewed.ts";

function variant(overrides: Partial<VariantLike> = {}): VariantLike {
  return {
    id: "v1",
    name: "Small",
    sku: "S-1",
    price_cents: 5000,
    compare_at_price_cents: null,
    stock_quantity: 10,
    low_stock_threshold: null,
    position: 0,
    is_active: true,
    ...overrides,
  };
}

describe("variants", () => {
  const list = [
    variant({ id: "c", name: "Large", position: 3, stock_quantity: 0 }),
    variant({ id: "a", name: "Small", position: 1 }),
    variant({ id: "b", name: "Medium", position: 2, stock_quantity: 3 }),
    variant({ id: "x", name: "Hidden", position: 0, is_active: false }),
  ];
  it("orders active variants by position, drops inactive, never mutates", () => {
    const copy = [...list];
    assert.deepEqual(
      orderedVariants(list).map((v) => v.id),
      ["a", "b", "c"],
    );
    assert.deepEqual(list, copy);
  });
  it("availability follows units only (variants have no in_stock flag)", () => {
    assert.equal(isVariantAvailable({ stock_quantity: 0 }), false);
    assert.equal(isVariantAvailable({ stock_quantity: 1 }), true);
    assert.deepEqual(
      variantStockState({ stock_quantity: 0, low_stock_threshold: 5 }),
      { kind: "out" },
    );
    assert.deepEqual(
      variantStockState({ stock_quantity: 3, low_stock_threshold: 5 }),
      { kind: "low", left: 3 },
    );
    assert.deepEqual(
      variantStockState({ stock_quantity: 3, low_stock_threshold: null }),
      { kind: "in" },
    );
  });
  it("initial selection: URL id wins (even sold out), unknown ids fall back, first available is next", () => {
    assert.equal(initialVariantId(list, "c"), "c");
    assert.equal(initialVariantId(list, "x"), "a"); // inactive is not selectable
    assert.equal(initialVariantId(list, "nope"), "a");
    assert.equal(initialVariantId(list, 42), "a");
    assert.equal(
      initialVariantId([variant({ id: "z", stock_quantity: 0 })], undefined),
      "z",
    );
    assert.equal(initialVariantId([], "a"), null);
    const soldOutFirst = [
      variant({ id: "p", position: 1, stock_quantity: 0 }),
      variant({ id: "q", position: 2 }),
    ];
    assert.equal(initialVariantId(soldOutFirst, undefined), "q");
  });
  it("price range covers active variants only", () => {
    assert.deepEqual(
      variantPriceRange([
        { price_cents: 500, is_active: true },
        { price_cents: 100, is_active: true },
        { price_cents: 1, is_active: false },
      ]),
      { minCents: 100, maxCents: 500 },
    );
    assert.equal(variantPriceRange([]), null);
  });
  it("purchasable uses the variant's own price, units and sku", () => {
    const out = purchasableForVariant(
      variant({ price_cents: 7000, stock_quantity: 150, sku: null }),
      "BASE",
    );
    assert.equal(out.priceCents, 7000);
    assert.equal(out.maxUnits, MAX_LINE_QUANTITY);
    assert.equal(out.sku, "BASE");
    assert.equal(
      purchasableForVariant(variant({ stock_quantity: 0 })).maxUnits,
      0,
    );
  });
  it("purchasable product mirrors browse rules", () => {
    const out = purchasableForProduct({
      in_stock: false,
      stock_quantity: 5,
      low_stock_threshold: null,
      price_cents: 100,
      compare_at_price_cents: null,
      sku: "A",
    });
    assert.deepEqual(out.state, { kind: "out" });
    assert.equal(out.maxUnits, 0);
    assert.equal(out.sku, "A");
  });
});

describe("quantity limits", () => {
  it("room is units minus what is already in the basket", () => {
    assert.deepEqual(quantityLimit(10, 3), {
      room: 7,
      stepperMax: 7,
      reason: "stock",
    });
    assert.deepEqual(quantityLimit(10, 10), {
      room: 0,
      stepperMax: 1,
      reason: "stock",
    });
    assert.deepEqual(quantityLimit(10, 99), {
      room: 0,
      stepperMax: 1,
      reason: "stock",
    });
  });
  it("never goes above 99 and never invents stock", () => {
    assert.deepEqual(quantityLimit(500, 0), {
      room: 99,
      stepperMax: 99,
      reason: "line-limit",
    });
    assert.equal(quantityLimit(0, 0).room, 0);
    assert.equal(quantityLimit(-4, 0).room, 0);
    assert.equal(quantityLimit(4.9, 0).room, 4);
  });
  it("clamps typed input", () => {
    assert.equal(clampQuantity("5", 1, 9), 5);
    assert.equal(clampQuantity("500", 1, 9), 9);
    assert.equal(clampQuantity("0", 1, 9), 1);
    assert.equal(clampQuantity("", 1, 9), 1);
    assert.equal(clampQuantity("abc", 1, 9), 1);
    assert.equal(clampQuantity("2.5", 1, 9), 1);
    assert.equal(clampQuantity(7.8, 1, 9), 7);
    assert.equal(clampQuantity("-3", 1, 9), 1);
  });
  it("messages: silent below the cap, calm at it", () => {
    assert.equal(
      quantityMessage({ maxUnits: 10, inBasket: 0, requested: 3 }),
      null,
    );
    assert.equal(
      quantityMessage({ maxUnits: 4, inBasket: 0, requested: 4 }),
      "That's all we have: 4 available.",
    );
    assert.equal(
      quantityMessage({ maxUnits: 4, inBasket: 1, requested: 3 }),
      "That's all we have: 4 available, 1 already in your basket.",
    );
    assert.equal(
      quantityMessage({ maxUnits: 4, inBasket: 4, requested: 1 }),
      "You already have all 4 available in your basket.",
    );
    assert.equal(
      quantityMessage({ maxUnits: 200, inBasket: 0, requested: 99 }),
      "The most you can order at once is 99.",
    );
    assert.equal(
      quantityMessage({ maxUnits: 0, inBasket: 0, requested: 1 }),
      null,
    );
  });
});

describe("relatedProducts", () => {
  const mk = (
    id: string,
    overrides: Partial<RelatableProduct> = {},
  ): RelatableProduct => ({
    id,
    category_id: "c1",
    name: id,
    brand: null,
    price_cents: 100,
    compare_at_price_cents: null,
    stock_quantity: 5,
    low_stock_threshold: null,
    in_stock: true,
    created_at: "2026-09-01T00:00:00Z",
    ...overrides,
  });
  it("same category only, never the current product", () => {
    const all = [mk("self"), mk("a"), mk("b", { category_id: "c2" })];
    assert.deepEqual(
      relatedProducts({ id: "self", category_id: "c1", brand: null }, all).map(
        (p) => p.id,
      ),
      ["a"],
    );
  });
  it("in-stock first, then same brand, then newest", () => {
    const all = [
      mk("sold", { stock_quantity: 0, brand: "X" }),
      mk("old-other", { created_at: "2026-01-01T00:00:00Z" }),
      mk("new-other", { created_at: "2026-09-10T00:00:00Z" }),
      mk("same-brand", { brand: "x", created_at: "2026-02-01T00:00:00Z" }),
    ];
    assert.deepEqual(
      relatedProducts({ id: "self", category_id: "c1", brand: "X" }, all).map(
        (p) => p.id,
      ),
      ["same-brand", "new-other", "old-other", "sold"],
    );
  });
  it("no category means nothing to relate; limit is respected", () => {
    assert.deepEqual(
      relatedProducts({ id: "s", category_id: null, brand: null }, [mk("a")]),
      [],
    );
    assert.equal(
      relatedProducts(
        { id: "s", category_id: "c1", brand: null },
        [mk("a"), mk("b"), mk("c")],
        2,
      ).length,
      2,
    );
  });
});

describe("category tree", () => {
  const c = (
    id: string,
    parent: string | null,
    position = 0,
    active = true,
  ): TreeCategory => ({
    id,
    slug: id,
    name: id,
    parent_id: parent,
    position,
    is_active: active,
  });
  const cats = [
    c("dairy", null),
    c("milk", "dairy", 2),
    c("yog", "dairy", 1),
    c("uht", "milk"),
    c("off", "dairy", 3, false),
    c("veg", null),
  ];
  it("children are active only and ordered by position", () => {
    assert.deepEqual(
      childCategories(cats, "dairy").map((x) => x.id),
      ["yog", "milk"],
    );
    assert.deepEqual(childCategories(cats, "veg"), []);
  });
  it("subtree includes the root and every active descendant", () => {
    assert.deepEqual(subtreeIds(cats, "dairy").sort(), [
      "dairy",
      "milk",
      "uht",
      "yog",
    ]);
    assert.deepEqual(subtreeIds(cats, "veg"), ["veg"]);
  });
  it("survives a parent loop", () => {
    const loop = [c("a", "b"), c("b", "a")];
    assert.deepEqual(subtreeIds(loop, "a").sort(), ["a", "b"]);
    assert.equal(categoryTrail(loop, "a").length, 2);
  });
  it("trail runs root first and stops at a missing parent", () => {
    assert.deepEqual(
      categoryTrail(cats, "uht").map((x) => x.id),
      ["dairy", "milk", "uht"],
    );
    assert.deepEqual(
      categoryTrail([c("orphan", "gone")], "orphan").map((x) => x.id),
      ["orphan"],
    );
    assert.deepEqual(categoryTrail(cats, "missing"), []);
  });
});

function fakeStorage(
  initial: Record<string, string> = {},
  failWrites = false,
): StorageLike & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem: (k) => (k in data ? (data[k] as string) : null),
    setItem: (k, v) => {
      if (failWrites) throw new Error("quota");
      data[k] = v;
    },
    removeItem: (k) => void delete data[k],
  };
}

describe("recently viewed", () => {
  it("adds newest first, de-duplicates, caps at 12", () => {
    assert.deepEqual(addRecentlyViewed(["a", "b", "c"], "b"), ["b", "a", "c"]);
    let list: string[] = [];
    for (let i = 0; i < 20; i += 1) list = addRecentlyViewed(list, `p${i}`);
    assert.equal(list.length, MAX_RECENTLY_VIEWED);
    assert.equal(list[0], "p19");
  });
  it("refuses odd ids so storage only ever holds ids", () => {
    assert.deepEqual(addRecentlyViewed(["a"], "<script>"), ["a"]);
    assert.deepEqual(addRecentlyViewed(["a"], ""), ["a"]);
  });
  it("parses untrusted storage defensively", () => {
    assert.deepEqual(parseRecentlyViewed(null), []);
    assert.deepEqual(parseRecentlyViewed("not json"), []);
    assert.deepEqual(parseRecentlyViewed('{"a":1}'), []);
    assert.deepEqual(parseRecentlyViewed('["a",1,null,"a","b c","ok-1"]'), [
      "a",
      "ok-1",
    ]);
    assert.equal(
      parseRecentlyViewed(
        JSON.stringify(Array.from({ length: 50 }, (_, i) => `x${i}`)),
      ).length,
      MAX_RECENTLY_VIEWED,
    );
  });
  it("stores ids only, under a versioned key", () => {
    const storage = fakeStorage();
    recordRecentlyViewed(storage, "p1");
    recordRecentlyViewed(storage, "p2");
    assert.deepEqual(JSON.parse(storage.data[RECENTLY_VIEWED_KEY] as string), [
      "p2",
      "p1",
    ]);
    assert.deepEqual(readRecentlyViewed(storage), ["p2", "p1"]);
  });
  it("never throws when storage is missing, full or blocked", () => {
    assert.deepEqual(recordRecentlyViewed(null, "p1"), ["p1"]);
    assert.deepEqual(readRecentlyViewed(null), []);
    assert.deepEqual(recordRecentlyViewed(fakeStorage({}, true), "p1"), ["p1"]);
    const hostile: StorageLike = {
      getItem: () => {
        throw new Error("denied");
      },
      setItem: () => {
        throw new Error("denied");
      },
      removeItem: () => {
        throw new Error("denied");
      },
    };
    assert.deepEqual(readRecentlyViewed(hostile), []);
    assert.doesNotThrow(() => clearRecentlyViewed(hostile));
  });
  it("clear removes the key", () => {
    const storage = fakeStorage({ [RECENTLY_VIEWED_KEY]: '["a"]' });
    clearRecentlyViewed(storage);
    assert.deepEqual(readRecentlyViewed(storage), []);
  });
  it("re-validates against live products: missing dropped, order kept, current page excluded", () => {
    const live = [{ id: "a" }, { id: "b" }, { id: "c" }];
    assert.deepEqual(
      resolveRecentlyViewed(["c", "gone", "a", "b"], live).map((p) => p.id),
      ["c", "a", "b"],
    );
    assert.deepEqual(
      resolveRecentlyViewed(["c", "a"], live, { excludeId: "c" }).map(
        (p) => p.id,
      ),
      ["a"],
    );
    assert.deepEqual(
      resolveRecentlyViewed(["a", "b", "c"], live, { limit: 2 }).map(
        (p) => p.id,
      ),
      ["a", "b"],
    );
    assert.deepEqual(resolveRecentlyViewed(["a"], []), []);
  });
});

import { summariseVariants } from "../src/features/catalog/product-detail.ts";
import { applyFilters, NO_FILTERS } from "../src/features/catalog/discovery.ts";

describe("options summary and the sold-out override", () => {
  it("groups active variants per product and ignores inactive ones", () => {
    const map = summariseVariants([
      {
        product_id: "p1",
        price_cents: 500,
        stock_quantity: 0,
        is_active: true,
      },
      {
        product_id: "p1",
        price_cents: 900,
        stock_quantity: 4,
        is_active: true,
      },
      {
        product_id: "p1",
        price_cents: 1,
        stock_quantity: 99,
        is_active: false,
      },
      {
        product_id: "p2",
        price_cents: 700,
        stock_quantity: 0,
        is_active: true,
      },
    ]);
    assert.deepEqual(map.get("p1"), {
      count: 2,
      anyAvailable: true,
      minPriceCents: 500,
      maxPriceCents: 900,
    });
    assert.deepEqual(map.get("p2"), {
      count: 1,
      anyAvailable: false,
      minPriceCents: 700,
      maxPriceCents: 700,
    });
    assert.equal(map.get("p3"), undefined);
  });
  it("the in-stock filter can judge by variants instead of the base row", () => {
    const base = {
      name: "Mix",
      brand: null,
      price_cents: 100,
      compare_at_price_cents: null,
      stock_quantity: 0,
      low_stock_threshold: null,
      in_stock: true,
      created_at: "2026-09-01T00:00:00Z",
    };
    const list = [
      { ...base, id: "p1" },
      { ...base, id: "p2" },
    ];
    assert.equal(
      applyFilters(list, { ...NO_FILTERS, inStockOnly: true }).length,
      0,
    );
    const kept = applyFilters(
      list,
      { ...NO_FILTERS, inStockOnly: true },
      { soldOut: (p) => p.id !== "p1" },
    );
    assert.deepEqual(
      kept.map((p) => p.id),
      ["p1"],
    );
  });
});

describe("collectAllPages (a capped list is read completely or not at all)", () => {
  const table = Array.from({ length: 2500 }, (_, i) => i);
  /** A fake PostgREST that never returns more than `cap` rows per request. */
  const server =
    (cap: number, total: number | null = table.length) =>
    async (from: number, to: number) => ({
      rows: table.slice(from, Math.min(to + 1, from + cap)),
      total,
    });

  it("reads every row across pages", async () => {
    assert.equal((await collectAllPages(server(1000))).length, 2500);
  });

  it("still reads everything when the server cap is below the page size", async () => {
    const rows = await collectAllPages(server(300));
    assert.equal(rows.length, 2500);
    assert.deepEqual(rows.slice(0, 3), [0, 1, 2]);
    assert.equal(rows[2499], 2499);
  });

  it("stops after the first page when the whole table fits", async () => {
    let calls = 0;
    const rows = await collectAllPages(async () => {
      calls += 1;
      return { rows: [1, 2, 3], total: 3 };
    });
    assert.equal(rows.length, 3);
    assert.equal(calls, 1);
  });

  it("an empty table is an empty list, not an error", async () => {
    assert.deepEqual(
      await collectAllPages(async () => ({ rows: [], total: 0 })),
      [],
    );
  });

  it("throws when the server does not return a count", async () => {
    await assert.rejects(collectAllPages(server(1000, null)));
  });

  it("throws instead of returning a partial list when pages stop early", async () => {
    await assert.rejects(
      collectAllPages(async (from) => ({
        rows: from === 0 ? [1, 2] : [],
        total: 10,
      })),
    );
  });

  it("throws when the list is longer than the page budget", async () => {
    await assert.rejects(collectAllPages(server(1000), 1000, 2));
  });
});
