import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  OPENING_STOCK_REASON,
  planFollowUpSteps,
  runCreateWithExtras,
  type FollowUpStep,
} from "../src/features/admin/product-create-plan.ts";
import {
  buildNewVariant,
  describePartialVariant,
  emptyNewVariantValues,
  nextVariantPosition,
  type NewVariantFormValues,
} from "../src/features/admin/variant-create-plan.ts";

const PRODUCT = "11111111-1111-1111-1111-111111111111";

function values(
  over: Partial<NewVariantFormValues> = {},
): NewVariantFormValues {
  return { ...emptyNewVariantValues(), name: "1 L", price: "250", ...over };
}

describe("nextVariantPosition", () => {
  it("is 0 for the first variant", () => {
    assert.equal(nextVariantPosition([]), 0);
  });
  it("is one above the highest position, gaps and order ignored", () => {
    assert.equal(nextVariantPosition([0, 1, 2]), 3);
    assert.equal(nextVariantPosition([5, 0, 20]), 21);
  });
  it("never exceeds the database maximum", () => {
    assert.equal(nextVariantPosition([100_000]), 100_000);
  });
});

describe("buildNewVariant", () => {
  it("builds the RPC arguments with blanks as null and stock default 0", () => {
    const built = buildNewVariant(PRODUCT, values(), 4);
    if (!built.ok) throw new Error("expected ok");
    assert.deepEqual(built.args, {
      p_product_id: PRODUCT,
      p_name: "1 L",
      p_price_cents: 25000,
      p_sku: null,
      p_compare_at_price_cents: null,
      p_position: 4,
    });
    assert.deepEqual(built.extras, { stock: 0, active: true });
  });
  it("trims the name and parses every field", () => {
    const built = buildNewVariant(
      PRODUCT,
      values({
        name: "  500 ml ",
        price: "1,250.50",
        compareAt: "1500",
        sku: " MILK-500 ",
        stock: "12",
        active: false,
      }),
      0,
    );
    if (!built.ok) throw new Error("expected ok");
    assert.equal(built.args.p_name, "500 ml");
    assert.equal(built.args.p_price_cents, 125050);
    assert.equal(built.args.p_compare_at_price_cents, 150000);
    assert.equal(built.args.p_sku, "MILK-500");
    assert.deepEqual(built.extras, { stock: 12, active: false });
  });
  it("reports every bad field at once", () => {
    const built = buildNewVariant(
      PRODUCT,
      values({ name: "  ", price: "abc", sku: "bad sku!", stock: "-1" }),
      0,
    );
    if (built.ok) throw new Error("expected refusal");
    assert.deepEqual(Object.keys(built.errors).sort(), [
      "name",
      "price",
      "sku",
      "stock",
    ]);
  });
  it("refuses a name over 200 characters or with a control character", () => {
    assert.ok(
      !buildNewVariant(PRODUCT, values({ name: "a".repeat(201) }), 0).ok,
    );
    assert.ok(!buildNewVariant(PRODUCT, values({ name: "a\u0007b" }), 0).ok);
    assert.ok(
      buildNewVariant(PRODUCT, values({ name: "a".repeat(200) }), 0).ok,
    );
  });
  it("refuses a SKU over 64 characters", () => {
    assert.ok(!buildNewVariant(PRODUCT, values({ sku: "A".repeat(65) }), 0).ok);
    assert.ok(buildNewVariant(PRODUCT, values({ sku: "A".repeat(64) }), 0).ok);
  });
  it("refuses a compare-at price below the price, accepts equal", () => {
    const low = buildNewVariant(PRODUCT, values({ compareAt: "249.99" }), 0);
    if (low.ok) throw new Error("expected refusal");
    assert.ok(low.errors.compareAt);
    assert.ok(buildNewVariant(PRODUCT, values({ compareAt: "250" }), 0).ok);
  });
  it("requires a price", () => {
    const built = buildNewVariant(PRODUCT, values({ price: "" }), 0);
    if (built.ok) throw new Error("expected refusal");
    assert.equal(built.errors.price, "Enter a price.");
  });
  it("refuses decimal or exponent stock", () => {
    assert.ok(!buildNewVariant(PRODUCT, values({ stock: "1.5" }), 0).ok);
    assert.ok(!buildNewVariant(PRODUCT, values({ stock: "1e3" }), 0).ok);
  });
});

describe("variant chain (runCreateWithExtras, reused)", () => {
  function run(
    extras: { stock: number; active: boolean },
    failing: FollowUpStep[] = [],
  ) {
    const calls: string[] = [];
    const promise = runCreateWithExtras(extras, {
      create: async () => {
        calls.push("create");
        return { variant: { id: "v1" } };
      },
      idOf: (r) => r.variant.id,
      adjustStock: async (id, qty) => {
        calls.push(`stock:${id}:${qty}:${OPENING_STOCK_REASON}`);
        if (failing.includes("stock")) throw new Error("boom");
      },
      deactivate: async (id) => {
        calls.push(`deactivate:${id}`);
        if (failing.includes("active")) throw new Error("boom");
      },
    });
    return { calls, promise };
  }

  it("plain variant: create only", async () => {
    const { calls, promise } = run({ stock: 0, active: true });
    assert.deepEqual((await promise).failed, []);
    assert.deepEqual(calls, ["create"]);
  });
  it("stock above 0 adds the Opening stock step on the variant id", async () => {
    const { calls, promise } = run({ stock: 7, active: true });
    await promise;
    assert.deepEqual(calls, ["create", "stock:v1:7:Opening stock"]);
  });
  it("Active off adds the deactivate step; both run in order", async () => {
    const { calls, promise } = run({ stock: 3, active: false });
    await promise;
    assert.deepEqual(calls, [
      "create",
      "stock:v1:3:Opening stock",
      "deactivate:v1",
    ]);
    assert.deepEqual(planFollowUpSteps({ stock: 0, active: false }), [
      "active",
    ]);
  });
  it("a failed stock step keeps the variant and still deactivates", async () => {
    const { calls, promise } = run({ stock: 3, active: false }, ["stock"]);
    const result = await promise;
    assert.deepEqual(result.failed, ["stock"]);
    assert.ok(calls.includes("deactivate:v1"));
  });
});

describe("describePartialVariant", () => {
  it("is null when nothing failed", () => {
    assert.equal(describePartialVariant("1 L", []), null);
  });
  it("names the variant and the fix in plain words", () => {
    assert.match(
      describePartialVariant("1 L", ["stock"]) ?? "",
      /“1 L”.*stock.*not saved/,
    );
    assert.match(
      describePartialVariant("1 L", ["active"]) ?? "",
      /customers can still see it/,
    );
    const both = describePartialVariant("1 L", ["stock", "active"]) ?? "";
    assert.match(both, /stock/);
    assert.match(both, /hidden/);
  });
});
