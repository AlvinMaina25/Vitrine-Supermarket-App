import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildVariantChanges,
  fieldFromInvalidMessage,
  variantToFormValues,
} from "../src/features/admin/products-result.ts";
import type { ProductVariantRow } from "../src/lib/supabase/types.ts";

function row(over: Partial<ProductVariantRow> = {}): ProductVariantRow {
  return {
    id: "v1",
    product_id: "p1",
    name: "1 L",
    sku: "MILK-1L",
    price_cents: 25000,
    compare_at_price_cents: null,
    stock_quantity: 5,
    low_stock_threshold: null,
    attributes: {},
    position: 0,
    is_active: true,
    created_at: "2026-10-11T00:00:00Z",
    updated_at: "2026-10-11T00:00:00Z",
    ...over,
  } as ProductVariantRow;
}

describe("variant edit form: Active", () => {
  it("starts from the stored status", () => {
    assert.equal(variantToFormValues(row()).active, true);
    assert.equal(variantToFormValues(row({ is_active: false })).active, false);
  });
  it("sends is_active alone when only the switch changed", () => {
    const r = row();
    const initial = variantToFormValues(r);
    const result = buildVariantChanges(r, initial, {
      ...initial,
      active: false,
    });
    assert.deepEqual(result.errors, {});
    assert.deepEqual(result.changes, { is_active: false });
  });
  it("can switch an inactive variant back on", () => {
    const r = row({ is_active: false });
    const initial = variantToFormValues(r);
    const result = buildVariantChanges(r, initial, {
      ...initial,
      active: true,
    });
    assert.deepEqual(result.changes, { is_active: true });
  });
  it("puts is_active in the same patch as other changed fields", () => {
    const r = row();
    const initial = variantToFormValues(r);
    const result = buildVariantChanges(r, initial, {
      ...initial,
      name: " 2 L ",
      active: false,
    });
    assert.deepEqual(result.changes, { name: "2 L", is_active: false });
  });
  it("leaves is_active out when it did not change", () => {
    const r = row({ is_active: false });
    const initial = variantToFormValues(r);
    const result = buildVariantChanges(r, initial, {
      ...initial,
      position: "4",
    });
    assert.deepEqual(result.changes, { position: 4 });
    assert.ok(!("is_active" in result.changes));
  });
  it("sends nothing when nothing changed", () => {
    const r = row();
    const initial = variantToFormValues(r);
    assert.deepEqual(
      buildVariantChanges(r, initial, { ...initial }).changes,
      {},
    );
  });
});

describe("fieldFromInvalidMessage: variant name", () => {
  it("points a server name refusal at the Name field", () => {
    assert.equal(
      fieldFromInvalidMessage(
        "Invalid variant name (1-200 characters, no control characters).",
      ),
      "name",
    );
    assert.equal(
      fieldFromInvalidMessage("Invalid variant name (must be a string)."),
      "name",
    );
  });
});
