import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildReorderLines,
  planBasketChanges,
  planReorder,
  summariseReorder,
  type ReorderIssue,
  type ReorderSourceItem,
} from "../src/features/orders/reorder.ts";

function item(over: Partial<ReorderSourceItem> = {}): ReorderSourceItem {
  return {
    product_id: "p1",
    variant_id: null,
    product_name: "Milk",
    product_slug: "milk",
    variant_name: null,
    unit_label: "1 L",
    image_url: null,
    unit_price_cents: 15000,
    quantity: 2,
    ...over,
  };
}

describe("buildReorderLines", () => {
  it("builds basket lines from the snapshot item", () => {
    const { lines, skipped } = buildReorderLines([item()]);
    assert.deepEqual(skipped, []);
    assert.deepEqual(lines, [
      {
        productId: "p1",
        variantId: null,
        slug: "milk",
        name: "Milk",
        variantName: null,
        unitLabel: "1 L",
        priceCents: 15000,
        imageUrl: null,
        quantity: 2,
      },
    ]);
  });

  it("skips an item with no product link and says so", () => {
    const { lines, skipped } = buildReorderLines([
      item({ product_id: null, product_name: "Old thing" }),
    ]);
    assert.equal(lines.length, 0);
    assert.equal(skipped[0]?.name, "Old thing");
    assert.match(skipped[0]?.reason ?? "", /no longer linked/);
  });

  it("merges duplicate product+variant lines and caps the quantity at 99", () => {
    const { lines } = buildReorderLines([
      item({ quantity: 60 }),
      item({ quantity: 60 }),
      item({ variant_id: "v1", quantity: 1 }),
    ]);
    assert.equal(lines.length, 2);
    assert.equal(lines[0]?.quantity, 99);
  });
});

describe("planReorder", () => {
  const { lines } = buildReorderLines([
    item({ product_id: "a", product_name: "A", quantity: 2 }),
    item({
      product_id: "b",
      product_name: "B",
      quantity: 1,
      unit_price_cents: 1000,
    }),
    item({ product_id: "c", product_name: "C", quantity: 5 }),
    item({ product_id: "d", product_name: "D", quantity: 1 }),
    item({ product_id: "e", product_name: "E", quantity: 1 }),
  ]);
  const issues: ReorderIssue[] = [
    {
      productId: "b",
      variantId: null,
      kind: "price_changed",
      message: "x",
      newPriceCents: 1200,
    },
    {
      productId: "c",
      variantId: null,
      kind: "insufficient_stock",
      message: "Only 3 left",
      maxQuantity: 3,
    },
    {
      productId: "d",
      variantId: null,
      kind: "out_of_stock",
      message: "D is currently unavailable.",
    },
    {
      productId: "e",
      variantId: null,
      kind: "removed",
      message: "E is no longer sold.",
    },
  ];

  it("adds available lines, re-prices from the database, reduces to stock, and lists the rest as unavailable", () => {
    const plan = planReorder(lines, issues);
    assert.deepEqual(
      plan.toAdd.map((l) => [l.name, l.quantity, l.priceCents]),
      [
        ["A", 2, 15000],
        ["B", 1, 1200],
        ["C", 3, 15000],
      ],
    );
    assert.deepEqual(plan.priceChanged, [
      { name: "B", oldCents: 1000, newCents: 1200 },
    ]);
    assert.deepEqual(plan.reduced, [{ name: "C", requested: 5, added: 3 }]);
    assert.deepEqual(
      plan.unavailable.map((u) => u.name),
      ["D", "E"],
    );
  });

  it("an insufficient_stock line with no stock left is unavailable, not added", () => {
    const plan = planReorder(lines.slice(0, 1), [
      {
        productId: "a",
        variantId: null,
        kind: "insufficient_stock",
        message: "Only 0 left of A.",
      },
    ]);
    assert.equal(plan.toAdd.length, 0);
    assert.equal(plan.unavailable.length, 1);
  });

  it("never uses the old order's price for a line the database re-priced", () => {
    const plan = planReorder(lines.slice(1, 2), issues);
    assert.equal(plan.toAdd[0]?.priceCents, 1200);
  });
});

describe("summariseReorder", () => {
  const none = {
    toAdd: [],
    added: [],
    unavailable: [],
    priceChanged: [],
    reduced: [],
  };
  const one = { name: "A", variantName: null, quantity: 1 };

  it("never calls it a success when nothing was added", () => {
    const summary = summariseReorder(
      { ...none, unavailable: [{ name: "A", reason: "x" }] },
      [],
    );
    assert.equal(summary.tone, "none");
    assert.match(summary.headline, /Nothing was added/);
    assert.equal(summariseReorder(none, []).tone, "none");
  });

  it("is a success only when every line was added in full", () => {
    assert.deepEqual(summariseReorder({ ...none, added: [one] }, []), {
      tone: "success",
      headline: "Added 1 item to your basket.",
    });
    assert.equal(
      summariseReorder({ ...none, added: [one, one] }, []).headline,
      "Added 2 items to your basket.",
    );
  });

  it("is partial when something was unavailable, skipped or reduced", () => {
    const unavailable = { name: "B", reason: "x" };
    assert.deepEqual(
      summariseReorder(
        { ...none, added: [one], unavailable: [unavailable] },
        [],
      ),
      { tone: "partial", headline: "Added 1 of 2 items to your basket." },
    );
    assert.equal(
      summariseReorder({ ...none, added: [one] }, [{ name: "C", reason: "x" }])
        .tone,
      "partial",
    );
    assert.equal(
      summariseReorder(
        {
          ...none,
          added: [one],
          reduced: [{ name: "A", requested: 3, added: 1 }],
        },
        [],
      ).tone,
      "partial",
    );
  });
});

describe("planBasketChanges", () => {
  const line = (productId: string, quantity: number, priceCents = 100) => ({
    productId,
    variantId: null,
    slug: "",
    name: productId,
    variantName: null,
    unitLabel: null,
    priceCents,
    imageUrl: null,
    quantity,
  });

  it("restores lines that are not in the basket and updates ones that are (no duplicates)", () => {
    const changes = planBasketChanges(
      [line("a", 2, 500), line("b", 1)],
      [{ productId: "a", variantId: null, quantity: 3 }],
    );
    assert.deepEqual(
      changes.restore.map((l) => l.productId),
      ["b"],
    );
    assert.deepEqual(changes.update, [
      { productId: "a", variantId: null, quantity: 5, priceCents: 500 },
    ]);
  });

  it("caps the combined quantity at 99", () => {
    const changes = planBasketChanges(
      [line("a", 50)],
      [{ productId: "a", variantId: null, quantity: 80 }],
    );
    assert.equal(changes.update[0]?.quantity, 99);
  });

  it("treats a different variant of the same product as a different line", () => {
    const changes = planBasketChanges(
      [{ ...line("a", 1), variantId: "v2" }],
      [{ productId: "a", variantId: "v1", quantity: 1 }],
    );
    assert.equal(changes.restore.length, 1);
    assert.equal(changes.update.length, 0);
  });
});
