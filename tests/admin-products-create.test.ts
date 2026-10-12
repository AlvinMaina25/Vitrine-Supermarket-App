import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import { describeProductActivationError } from "../src/features/admin/product-management.ts";
import {
  AdminProductActionError,
  AdminProductNotFoundError,
  buildCreateProductArgs,
  emptyProductFormValues,
  slugifyName,
  toAdminProductActionError,
  type ProductFormValues,
} from "../src/features/admin/products-result.ts";

const CATEGORY_ID = "11111111-1111-4111-8111-111111111111";

function form(overrides: Partial<ProductFormValues> = {}): ProductFormValues {
  return {
    ...emptyProductFormValues(),
    name: "Whole Milk",
    slug: "whole-milk",
    price: "1.50",
    ...overrides,
  };
}

describe("emptyProductFormValues", () => {
  it("is all blank", () => {
    for (const value of Object.values(emptyProductFormValues()))
      assert.equal(value, "");
  });
});

describe("slugifyName", () => {
  it("makes lower-case kebab slugs", () => {
    assert.equal(slugifyName("Whole Milk 1L"), "whole-milk-1l");
    assert.equal(slugifyName("  Fresh & Tasty!! Bread  "), "fresh-tasty-bread");
  });
  it("drops accents and symbols", () => {
    assert.equal(slugifyName("Crème Brûlée"), "creme-brulee");
    assert.equal(slugifyName("100% ___ ???"), "100");
  });
  it("returns an empty string when nothing usable remains", () => {
    assert.equal(slugifyName("!!!"), "");
    assert.equal(slugifyName(""), "");
  });
  it("is capped at 120 characters without a trailing hyphen", () => {
    const slug = slugifyName(`${"a".repeat(119)} b`);
    assert.ok(slug.length <= 120);
    assert.ok(!slug.endsWith("-"));
  });
});

describe("buildCreateProductArgs", () => {
  it("builds the contract of admin_create_product from the minimum fields", () => {
    const result = buildCreateProductArgs(form());
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.args, {
      p_name: "Whole Milk",
      p_slug: "whole-milk",
      p_price_cents: 150,
      p_category_id: null,
      p_description: null,
      p_brand: null,
      p_sku: null,
      p_unit_label: null,
      p_compare_at_price_cents: null,
    });
  });

  it("sends only keys the function accepts (never stock, is_active or image_url)", () => {
    const { args } = buildCreateProductArgs(
      form({ categoryId: CATEGORY_ID, sku: "MILK-1" }),
    );
    assert.ok(args);
    const allowed = new Set([
      "p_name",
      "p_slug",
      "p_price_cents",
      "p_category_id",
      "p_description",
      "p_brand",
      "p_sku",
      "p_unit_label",
      "p_compare_at_price_cents",
    ]);
    for (const key of Object.keys(args)) assert.ok(allowed.has(key), key);
  });

  it("trims text, nulls blanks, converts money to integer cents", () => {
    const { args } = buildCreateProductArgs(
      form({
        name: "  Whole Milk  ",
        slug: " whole-milk ",
        price: "1,250.5",
        compareAt: "1300",
        brand: "  ",
        description: "  Fresh.  ",
        unitLabel: " 1 L ",
        sku: " MILK-1 ",
        categoryId: CATEGORY_ID,
      }),
    );
    assert.ok(args);
    assert.equal(args.p_name, "Whole Milk");
    assert.equal(args.p_slug, "whole-milk");
    assert.equal(args.p_price_cents, 125050);
    assert.equal(args.p_compare_at_price_cents, 130000);
    assert.equal(args.p_brand, null);
    assert.equal(args.p_description, "Fresh.");
    assert.equal(args.p_unit_label, "1 L");
    assert.equal(args.p_sku, "MILK-1");
    assert.equal(args.p_category_id, CATEGORY_ID);
  });

  it("requires name, slug and price", () => {
    const result = buildCreateProductArgs(emptyProductFormValues());
    assert.equal(result.args, null);
    assert.ok(result.errors.name);
    assert.ok(result.errors.slug);
    assert.ok(result.errors.price);
    assert.equal(result.errors.sku, undefined);
    assert.equal(result.errors.brand, undefined);
  });

  it("rejects a slug that is not lower-case kebab (it is not silently fixed)", () => {
    for (const slug of [
      "Whole-Milk",
      "whole milk",
      "-milk",
      "milk-",
      "a--b",
      "mil_k",
    ]) {
      const result = buildCreateProductArgs(form({ slug }));
      assert.equal(result.args, null, slug);
      assert.ok(result.errors.slug, slug);
    }
  });

  it("rejects bad prices and allows zero", () => {
    for (const price of ["", "abc", "-1", "1.234", "1e3", "99999999999"]) {
      const result = buildCreateProductArgs(form({ price }));
      assert.equal(result.args, null, price);
      assert.ok(result.errors.price, price);
    }
    assert.equal(
      buildCreateProductArgs(form({ price: "0" })).args?.p_price_cents,
      0,
    );
  });

  it("rejects a compare-at price below the price, accepts equal", () => {
    const below = buildCreateProductArgs(
      form({ price: "10", compareAt: "9.99" }),
    );
    assert.equal(below.args, null);
    assert.ok(below.errors.compareAt);
    assert.equal(
      buildCreateProductArgs(form({ price: "10", compareAt: "10" })).args
        ?.p_compare_at_price_cents,
      1000,
    );
  });

  it("does not report a compare-at ordering error when the price itself is invalid", () => {
    const result = buildCreateProductArgs(form({ price: "x", compareAt: "5" }));
    assert.ok(result.errors.price);
    assert.equal(result.errors.compareAt, undefined);
  });

  it("applies the length, character and SKU rules", () => {
    assert.ok(
      buildCreateProductArgs(form({ name: "a".repeat(201) })).errors.name,
    );
    assert.ok(
      buildCreateProductArgs(form({ name: "bad\u0007name" })).errors.name,
    );
    assert.ok(
      buildCreateProductArgs(form({ description: "d".repeat(4001) })).errors
        .description,
    );
    assert.ok(
      buildCreateProductArgs(form({ brand: "b".repeat(101) })).errors.brand,
    );
    assert.ok(
      buildCreateProductArgs(form({ unitLabel: "u".repeat(41) })).errors
        .unitLabel,
    );
    assert.ok(buildCreateProductArgs(form({ sku: "-bad" })).errors.sku);
    assert.ok(buildCreateProductArgs(form({ sku: "s".repeat(65) })).errors.sku);
    assert.equal(
      buildCreateProductArgs(form({ sku: "AB.1/2_x-y" })).errors.sku,
      undefined,
    );
  });

  it("reports every problem at once", () => {
    const result = buildCreateProductArgs(
      form({ name: "", slug: "BAD", price: "x" }),
    );
    assert.equal(result.args, null);
    assert.deepEqual(Object.keys(result.errors).sort(), [
      "name",
      "price",
      "slug",
    ]);
  });
});

describe("create / activation error mapping", () => {
  it("maps database refusals of a create to field-level reasons", () => {
    const slug = toAdminProductActionError({
      code: "23505",
      details: "slug_taken",
      message: "x",
    });
    assert.ok(slug instanceof AdminProductActionError);
    assert.equal(slug.reason, "slug_taken");
    assert.equal(slug.field, "slug");

    const sku = toAdminProductActionError({
      code: "23505",
      details: "sku_taken",
      message: "x",
    });
    assert.ok(sku instanceof AdminProductActionError);
    assert.equal(sku.field, "sku");

    const category = toAdminProductActionError({
      code: "P0001",
      details: "category_not_found",
      message: "x",
    });
    assert.ok(category instanceof AdminProductActionError);
    assert.equal(category.field, "category");
  });

  it("maps a non-admin to AdminAccessError and an unknown product to not-found", () => {
    assert.ok(
      toAdminProductActionError({
        code: "42501",
        details: "not_authorised",
        message: "x",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminProductActionError({
        code: "P0001",
        details: "product_not_found",
        message: "x",
      }) instanceof AdminProductNotFoundError,
    );
  });

  it("describes activation failures without database text", () => {
    assert.match(
      describeProductActivationError(new AdminAccessError("secret"), true),
      /not permitted/,
    );
    assert.match(
      describeProductActivationError(new AdminProductNotFoundError(), false),
      /no longer exists/,
    );
    const activate = describeProductActivationError(
      new Error("relation products leaked"),
      true,
    );
    const deactivate = describeProductActivationError(
      new Error("relation products leaked"),
      false,
    );
    assert.match(activate, /activate/);
    assert.match(deactivate, /deactivate/);
    assert.ok(!activate.includes("leaked") && !deactivate.includes("leaked"));
  });
});
