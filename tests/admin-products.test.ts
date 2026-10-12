import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  describeProductSaveError,
  describeProductStock,
  parseProductListParams,
  PRODUCTS_PAGE_SIZE,
  saveErrorField,
  toProductListQuery,
} from "../src/features/admin/product-management.ts";
import {
  AdminProductActionError,
  AdminProductNotFoundError,
  buildProductChanges,
  buildVariantChanges,
  centsToInput,
  fieldFromInvalidMessage,
  hasChanges,
  MAX_PRICE_CENTS,
  parsePriceInput,
  productToFormValues,
  toAdminListProductsArgs,
  toAdminProductActionError,
  toAdminProductDetail,
  toAdminProductList,
  toAdminProductMutationResult,
  toAdminProductsError,
  toAdminVariantMutationResult,
  variantToFormValues,
  type ProductFormValues,
} from "../src/features/admin/products-result.ts";
import type {
  ProductRow,
  ProductVariantRow,
} from "../src/lib/supabase/types.ts";

const CATEGORY_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_CATEGORY_ID = "22222222-2222-4222-8222-222222222222";

function product(overrides: Partial<ProductRow> = {}): ProductRow {
  return {
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    slug: "whole-milk-1l",
    name: "Whole milk 1 L",
    category_id: CATEGORY_ID,
    description: "Fresh whole milk.",
    brand: "Dairy Co",
    sku: "MILK-1L",
    image_url: "https://example.com/milk.jpg",
    price_cents: 15000,
    compare_at_price_cents: 18000,
    unit_label: "1 L",
    stock_quantity: 40,
    in_stock: true,
    is_active: true,
    created_at: "2026-10-01T08:00:00Z",
    updated_at: "2026-10-02T08:00:00Z",
    ...overrides,
  };
}

function variant(
  overrides: Partial<ProductVariantRow> = {},
): ProductVariantRow {
  return {
    id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    product_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    name: "2 L",
    sku: "MILK-2L",
    price_cents: 28000,
    compare_at_price_cents: null,
    stock_quantity: 12,
    attributes: {},
    position: 1,
    is_active: true,
    created_at: "2026-10-01T08:00:00Z",
    updated_at: "2026-10-02T08:00:00Z",
    ...overrides,
  };
}

/** Builds a patch from the loaded row with the given form edits applied. */
function patch(edits: Partial<ProductFormValues>, row: ProductRow = product()) {
  const initial = productToFormValues(row);
  return buildProductChanges(row, initial, { ...initial, ...edits });
}

describe("toAdminProductsError", () => {
  it("maps the admin gate refusal to AdminAccessError", () => {
    assert.ok(
      toAdminProductsError({
        message: "nope",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminProductsError({
        message: "permission denied for function",
        code: "42501",
      }) instanceof AdminAccessError,
    );
  });

  it("maps an unknown product to AdminProductNotFoundError", () => {
    const error = toAdminProductsError({
      message: "Product not found.",
      code: "P0001",
      details: "product_not_found",
    });
    assert.ok(error instanceof AdminProductNotFoundError);
  });

  it("keeps the message of anything else (it is never shown to users)", () => {
    const error = toAdminProductsError({ message: "boom", code: "XX000" });
    assert.equal(error.message, "boom");
    assert.ok(!(error instanceof AdminAccessError));
  });
});

describe("toAdminProductActionError", () => {
  it("maps not-an-admin and not-found", () => {
    assert.ok(
      toAdminProductActionError({
        message: "x",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminProductActionError({
        message: "x",
        code: "P0001",
        details: "product_not_found",
      }) instanceof AdminProductNotFoundError,
    );
  });

  it("attaches duplicate and missing-category refusals to their fields", () => {
    const cases: [string, string][] = [
      ["slug_taken", "slug"],
      ["sku_taken", "sku"],
      ["category_not_found", "category"],
    ];
    for (const [details, field] of cases) {
      const error = toAdminProductActionError({
        message: "db text",
        code: "23505",
        details,
      });
      assert.ok(error instanceof AdminProductActionError, details);
      assert.equal(error.field, field);
      assert.equal(error.reason, details);
    }
  });

  it("recovers the field of an invalid_arguments refusal from the message", () => {
    const error = toAdminProductActionError({
      message:
        "Invalid price_cents (a whole number of cents, 0 to 2147483647).",
      code: "P0001",
      details: "invalid_arguments",
    });
    assert.ok(error instanceof AdminProductActionError);
    assert.equal(error.field, "price");
  });

  it("does not carry the raw database message", () => {
    const error = toAdminProductActionError({
      message:
        "duplicate key value violates unique constraint products_slug_key",
      code: "23505",
      details: "slug_taken",
    });
    assert.doesNotMatch(
      error.message,
      /duplicate key|constraint|products_slug_key/i,
    );
  });

  it("falls back to a plain Error for unknown codes", () => {
    const error = toAdminProductActionError({
      message: "boom",
      code: "XX000",
      details: "other",
    });
    assert.ok(!(error instanceof AdminProductActionError));
    assert.equal(error.message, "boom");
  });
});

describe("fieldFromInvalidMessage", () => {
  it("tests compare_at before price_cents", () => {
    assert.equal(
      fieldFromInvalidMessage(
        "Invalid compare_at_price_cents (must be null or >= price_cents).",
      ),
      "compareAt",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid price_cents (must be a number)."),
      "price",
    );
  });

  it("recognises the other product fields", () => {
    assert.equal(
      fieldFromInvalidMessage("Invalid product name (1-200 characters)."),
      "name",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid product slug (1-120 characters)."),
      "slug",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid description (max 4000 characters)."),
      "description",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid brand (max 100 characters)."),
      "brand",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid unit_label (max 40 characters)."),
      "unitLabel",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid sku (max 64 characters)."),
      "sku",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid category_id (must be a uuid)."),
      "category",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid position (0 to 100000)."),
      "position",
    );
    assert.equal(fieldFromInvalidMessage("A product id is required."), null);
  });
});

describe("toAdminListProductsArgs", () => {
  it("defaults to 25 rows from offset 0 with no filters", () => {
    assert.deepEqual(toAdminListProductsArgs(), {
      p_search: null,
      p_is_active: null,
      p_category_id: null,
      p_limit: 25,
      p_offset: 0,
    });
  });

  it("trims the search, turns blanks into null and keeps explicit filters", () => {
    assert.deepEqual(
      toAdminListProductsArgs({
        search: "  milk ",
        isActive: false,
        categoryId: CATEGORY_ID,
        limit: 10,
        offset: 20,
      }),
      {
        p_search: "milk",
        p_is_active: false,
        p_category_id: CATEGORY_ID,
        p_limit: 10,
        p_offset: 20,
      },
    );
    assert.equal(
      toAdminListProductsArgs({ search: "   ", categoryId: " " }).p_search,
      null,
    );
    assert.equal(
      toAdminListProductsArgs({ categoryId: " " }).p_category_id,
      null,
    );
  });
});

describe("response shape checks", () => {
  it("accepts a list and rejects anything else", () => {
    const list = { total: 1, limit: 25, offset: 0, products: [product()] };
    assert.equal(toAdminProductList(list).total, 1);
    assert.throws(() => toAdminProductList(null));
    assert.throws(() => toAdminProductList({ total: 1 }));
    assert.throws(() => toAdminProductList({ products: [], total: "1" }));
  });

  it("accepts a detail with or without a category and rejects malformed ones", () => {
    assert.ok(
      toAdminProductDetail({
        product: product(),
        category: null,
        variants: [],
      }),
    );
    assert.ok(
      toAdminProductDetail({
        product: product(),
        category: {
          id: CATEGORY_ID,
          slug: "dairy",
          name: "Dairy",
          parent_id: null,
          is_active: true,
        },
        variants: [variant()],
      }),
    );
    assert.throws(() =>
      toAdminProductDetail({ product: product(), variants: [] }),
    );
    assert.throws(() =>
      toAdminProductDetail({ product: product(), category: 3, variants: [] }),
    );
    assert.throws(() =>
      toAdminProductDetail({ product: product(), category: null }),
    );
    assert.throws(() => toAdminProductDetail("nope"));
  });

  it("checks mutation results", () => {
    assert.ok(toAdminProductMutationResult({ product: product() }));
    assert.throws(() => toAdminProductMutationResult({}));
    assert.ok(toAdminVariantMutationResult({ variant: variant() }));
    assert.throws(() => toAdminVariantMutationResult({ product: product() }));
  });
});

describe("parsePriceInput", () => {
  it("converts to cents with integer arithmetic", () => {
    const cases: [string, number][] = [
      ["0", 0],
      ["250", 25000],
      ["250.5", 25050],
      ["250.50", 25050],
      ["0.07", 7],
      ["0.1", 10],
      ["1,250.50", 125050],
      ["  19.99 ", 1999],
      ["21474836.47", MAX_PRICE_CENTS],
    ];
    for (const [text, cents] of cases) {
      assert.deepEqual(parsePriceInput(text), { ok: true, cents }, text);
    }
  });

  it("rejects blanks, signs, exponents, extra decimals and out-of-range amounts", () => {
    for (const text of [
      "",
      "  ",
      "-1",
      "+1",
      "1e3",
      "abc",
      "12.345",
      "1.",
      ".5",
      "1 000",
      "21474836.48",
    ]) {
      assert.equal(parsePriceInput(text).ok, false, text);
    }
    assert.equal(parsePriceInput("99999999999").ok, false);
  });
});

describe("centsToInput", () => {
  it("formats integer cents without floating point", () => {
    assert.equal(centsToInput(0), "0.00");
    assert.equal(centsToInput(7), "0.07");
    assert.equal(centsToInput(15000), "150.00");
    assert.equal(centsToInput(125050), "1250.50");
    assert.equal(centsToInput(MAX_PRICE_CENTS), "21474836.47");
  });

  it("round-trips through parsePriceInput", () => {
    for (const cents of [0, 1, 99, 100, 1999, 15000, 2147483647]) {
      assert.deepEqual(parsePriceInput(centsToInput(cents)), {
        ok: true,
        cents,
      });
    }
  });
});

describe("buildProductChanges", () => {
  it("sends nothing when nothing changed", () => {
    const result = patch({});
    assert.deepEqual(result.changes, {});
    assert.deepEqual(result.errors, {});
    assert.equal(hasChanges(result.changes), false);
  });

  it("sends only the changed fields", () => {
    const result = patch({ name: "  Whole milk 2 L  ", price: "170" });
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, {
      name: "Whole milk 2 L",
      price_cents: 17000,
    });
  });

  it("clears optional fields with null and treats blank text as null", () => {
    const result = patch({
      description: "   ",
      brand: "",
      sku: "",
      unitLabel: " ",
      categoryId: "",
      compareAt: "",
    });
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, {
      description: null,
      brand: null,
      sku: null,
      unit_label: null,
      category_id: null,
      compare_at_price_cents: null,
    });
  });

  it("changes the category to another id", () => {
    assert.deepEqual(patch({ categoryId: OTHER_CATEGORY_ID }).changes, {
      category_id: OTHER_CATEGORY_ID,
    });
  });

  it("never emits a field the database does not accept here", () => {
    const allowed = new Set([
      "name",
      "slug",
      "category_id",
      "description",
      "brand",
      "sku",
      "price_cents",
      "compare_at_price_cents",
      "unit_label",
    ]);
    const result = patch({
      name: "A",
      slug: "a",
      categoryId: "",
      description: "d",
      brand: "b",
      sku: "S1",
      price: "1",
      compareAt: "2",
      unitLabel: "u",
    });
    assert.deepEqual(result.errors, {});
    for (const key of Object.keys(result.changes))
      assert.ok(allowed.has(key), key);
    for (const forbidden of [
      "stock_quantity",
      "in_stock",
      "is_active",
      "image_url",
      "id",
    ]) {
      assert.ok(!(forbidden in result.changes), forbidden);
    }
  });

  it("flags invalid values without sending them", () => {
    const result = patch({
      name: "   ",
      slug: "Has Spaces",
      price: "12.345",
      sku: "-bad",
      brand: "x".repeat(101),
      unitLabel: "y".repeat(41),
      description: "z".repeat(4001),
    });
    assert.deepEqual(Object.keys(result.errors).sort(), [
      "brand",
      "description",
      "name",
      "price",
      "sku",
      "slug",
      "unitLabel",
    ]);
    assert.deepEqual(result.changes, {});
  });

  it("rejects control characters in the name", () => {
    assert.ok(patch({ name: "Milk\u0007" }).errors.name);
  });

  it("requires compare-at to be at least the price", () => {
    assert.ok(patch({ compareAt: "100" }).errors.compareAt);
    assert.equal(patch({ compareAt: "150" }).errors.compareAt, undefined);
    assert.deepEqual(patch({ compareAt: "150" }).changes, {
      compare_at_price_cents: 15000,
    });
  });

  it("re-checks an untouched compare-at when the price rises above it", () => {
    // Loaded price 150.00, compare-at 180.00. Raising the price to 200 would break the rule.
    const result = patch({ price: "200" });
    assert.ok(result.errors.compareAt);
    assert.equal(result.errors.price, undefined);
  });

  it("allows lowering the price below an untouched compare-at", () => {
    const result = patch({ price: "120" });
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, { price_cents: 12000 });
  });

  it("does not validate fields that were not touched (legacy values never block a save)", () => {
    const legacy = product({ sku: "-legacy sku-", brand: "b".repeat(150) });
    const result = patch({ name: "Renamed" }, legacy);
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, { name: "Renamed" });
  });

  it("treats a changed slug as a change and validates the kebab-case rule", () => {
    assert.deepEqual(patch({ slug: "whole-milk-2l" }).changes, {
      slug: "whole-milk-2l",
    });
    for (const bad of ["Whole-Milk", "a--b", "-a", "a-", "a b", ""]) {
      assert.ok(patch({ slug: bad }).errors.slug, bad);
    }
  });
});

describe("buildVariantChanges", () => {
  function vpatch(
    edits: Record<string, string>,
    row: ProductVariantRow = variant(),
  ) {
    const initial = variantToFormValues(row);
    return buildVariantChanges(row, initial, { ...initial, ...edits });
  }

  it("sends only changed catalogue fields", () => {
    const result = vpatch({ name: " 2 litre ", price: "300", position: "3" });
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, {
      name: "2 litre",
      price_cents: 30000,
      position: 3,
    });
  });

  it("never offers stock, attributes or product_id, and no is_active unless it changed", () => {
    const result = vpatch({
      name: "x",
      sku: "",
      compareAt: "400",
      position: "0",
    });
    for (const forbidden of [
      "stock_quantity",
      "is_active",
      "attributes",
      "product_id",
    ]) {
      assert.ok(!(forbidden in result.changes), forbidden);
    }
  });

  it("clears the SKU and compare-at with null", () => {
    const row = variant({ compare_at_price_cents: 30000 });
    const result = vpatch({ sku: "", compareAt: "" }, row);
    assert.deepEqual(result.changes, {
      sku: null,
      compare_at_price_cents: null,
    });
  });

  it("validates price, compare-at and position", () => {
    const result = vpatch({ price: "x", position: "-1", name: "" });
    assert.deepEqual(Object.keys(result.errors).sort(), [
      "name",
      "position",
      "price",
    ]);
    assert.ok(vpatch({ compareAt: "100" }).errors.compareAt);
    assert.ok(vpatch({ position: "100001" }).errors.position);
    assert.equal(vpatch({ position: "100000" }).errors.position, undefined);
  });
});

describe("parseProductListParams", () => {
  it("returns nothing for an empty search", () => {
    assert.deepEqual(parseProductListParams({}), {});
  });

  it("keeps valid values and trims the search to 100 characters", () => {
    assert.deepEqual(
      parseProductListParams({
        q: "  milk ",
        status: "inactive",
        category: CATEGORY_ID,
        page: "3",
      }),
      { q: "milk", status: "inactive", category: CATEGORY_ID, page: 3 },
    );
    assert.equal(parseProductListParams({ q: "a".repeat(150) }).q?.length, 100);
  });

  it("drops unknown or malformed values", () => {
    assert.deepEqual(
      parseProductListParams({
        q: "   ",
        status: "draft",
        category: "not-a-uuid",
        page: "0",
      }),
      {},
    );
    assert.deepEqual(parseProductListParams({ page: "1" }), {});
    assert.deepEqual(parseProductListParams({ page: "2.5" }), {});
    assert.deepEqual(parseProductListParams({ page: "200000" }), {});
    assert.deepEqual(
      parseProductListParams({ q: 5, status: ["active"], category: 7 }),
      {},
    );
  });
});

describe("toProductListQuery", () => {
  it("maps the status filter and page to database arguments", () => {
    assert.deepEqual(toProductListQuery({}), {
      search: null,
      isActive: null,
      categoryId: null,
      limit: PRODUCTS_PAGE_SIZE,
      offset: 0,
    });
    assert.equal(toProductListQuery({ status: "active" }).isActive, true);
    assert.equal(toProductListQuery({ status: "inactive" }).isActive, false);
    assert.equal(
      toProductListQuery({ page: 3 }).offset,
      2 * PRODUCTS_PAGE_SIZE,
    );
    assert.equal(toProductListQuery({ page: 2 }, 10).offset, 10);
  });

  it("stays inside the database's limit and offset rules", () => {
    const query = toProductListQuery({ page: 100_000 });
    assert.ok(
      query.limit !== undefined && query.limit >= 1 && query.limit <= 100,
    );
    assert.ok(query.offset !== undefined && query.offset >= 0);
  });
});

describe("describeProductStock", () => {
  it("reports the stored flag and quantity", () => {
    assert.deepEqual(
      describeProductStock({ in_stock: true, stock_quantity: 5 }),
      {
        label: "In stock",
        inStock: true,
        quantity: 5,
      },
    );
    assert.equal(
      describeProductStock({ in_stock: false, stock_quantity: 0 }).label,
      "Out of stock",
    );
  });
});

describe("describeProductSaveError", () => {
  const LEAK =
    /sql|postgres|pgrst|rpc|42501|23505|constraint|products_|violates|duplicate key/i;

  it("is generic and never leaks database text", () => {
    const errors: unknown[] = [
      new AdminAccessError(),
      new AdminProductNotFoundError(),
      new AdminProductActionError("slug_taken", "slug"),
      new AdminProductActionError("sku_taken", "sku"),
      new AdminProductActionError("category_not_found", "category"),
      new AdminProductActionError("variant_not_found"),
      new AdminProductActionError("invalid_arguments", "price"),
      new AdminProductActionError("invalid_arguments"),
      new AdminProductActionError("unsupported_field"),
      new Error(
        'duplicate key value violates unique constraint "products_slug_key"',
      ),
      "a string",
      null,
    ];
    for (const error of errors) {
      const text = describeProductSaveError(error);
      assert.ok(text.length > 0);
      assert.doesNotMatch(text, LEAK);
    }
  });

  it("tells the admin what to fix for the common refusals", () => {
    assert.match(
      describeProductSaveError(
        new AdminProductActionError("slug_taken", "slug"),
      ),
      /slug/i,
    );
    assert.match(
      describeProductSaveError(new AdminProductActionError("sku_taken", "sku")),
      /SKU/,
    );
    assert.match(
      describeProductSaveError(
        new AdminProductActionError("invalid_arguments", "compareAt"),
      ),
      /compare-at price/,
    );
    assert.match(
      describeProductSaveError(new AdminAccessError()),
      /not permitted/,
    );
  });
});

describe("saveErrorField", () => {
  it("returns the field of a rule refusal and null otherwise", () => {
    assert.equal(
      saveErrorField(new AdminProductActionError("slug_taken", "slug")),
      "slug",
    );
    assert.equal(
      saveErrorField(new AdminProductActionError("unsupported_field")),
      null,
    );
    assert.equal(saveErrorField(new Error("boom")), null);
  });
});
