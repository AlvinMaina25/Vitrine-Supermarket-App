import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  cartSubtotalDisplay,
  clampMessage,
  hasBlockingLine,
  lineBadge,
  lineMaxQuantity,
  lineStateFor,
  MAX_LINE_QUANTITY,
} from "../src/features/cart/line-state.ts";
import type { CartIssue } from "../src/features/cart/validation.ts";

function issue(
  partial: Partial<CartIssue> & Pick<CartIssue, "kind">,
): CartIssue {
  return {
    key: "p1:",
    productId: "p1",
    variantId: null,
    name: "Milk",
    message: "m",
    ...partial,
  };
}

describe("lineStateFor", () => {
  it("says nothing while the validation answer is missing", () => {
    assert.deepEqual(lineStateFor("p1:", undefined), { kind: "checking" });
    assert.equal(lineBadge({ kind: "checking" }), null);
  });

  it("calls a line in stock only when the answer exists and names no issue for it", () => {
    assert.deepEqual(lineStateFor("p1:", []), { kind: "in_stock" });
    assert.deepEqual(
      lineStateFor("p1:", [issue({ key: "other:", kind: "out_of_stock" })]),
      {
        kind: "in_stock",
      },
    );
  });

  it("maps low stock with the database's number", () => {
    const state = lineStateFor("p1:", [
      issue({ kind: "insufficient_stock", maxQuantity: 3 }),
    ]);
    assert.deepEqual(state, { kind: "low_stock", maxQuantity: 3 });
    assert.deepEqual(lineBadge(state), { text: "Only 3 left", tone: "warn" });
    assert.equal(lineMaxQuantity(state), 3);
  });

  it("treats insufficient stock with nothing left as unavailable", () => {
    assert.deepEqual(
      lineStateFor("p1:", [issue({ kind: "insufficient_stock" })]),
      {
        kind: "unavailable",
      },
    );
  });

  it("maps every other blocking kind to unavailable", () => {
    for (const kind of [
      "unavailable",
      "variant_unavailable",
      "out_of_stock",
      "removed",
    ] as const) {
      assert.deepEqual(lineStateFor("p1:", [issue({ kind })]), {
        kind: "unavailable",
      });
    }
    assert.deepEqual(lineBadge({ kind: "unavailable" }), {
      text: "Unavailable",
      tone: "danger",
    });
  });

  it("carries the database price when it changed", () => {
    const state = lineStateFor("p1:", [
      issue({ kind: "price_changed", newPriceCents: 12000 }),
    ]);
    assert.deepEqual(state, { kind: "price_changed", newPriceCents: 12000 });
    assert.deepEqual(lineBadge(state), { text: "Price changed", tone: "warn" });
  });

  it("does not invent a price when the issue has none", () => {
    assert.deepEqual(lineStateFor("p1:", [issue({ kind: "price_changed" })]), {
      kind: "unavailable",
    });
  });
});

describe("lineMaxQuantity", () => {
  it("is 99 unless the database lowered it", () => {
    assert.equal(lineMaxQuantity({ kind: "in_stock" }), MAX_LINE_QUANTITY);
    assert.equal(lineMaxQuantity({ kind: "checking" }), MAX_LINE_QUANTITY);
    assert.equal(
      lineMaxQuantity({ kind: "low_stock", maxQuantity: 500 }),
      MAX_LINE_QUANTITY,
    );
  });
});

describe("clampMessage", () => {
  const stock = { min: 1, max: 3, stockLimited: true };
  it("explains a stock clamp", () => {
    assert.equal(
      clampMessage(10, 3, stock),
      "Only 3 available, so we set the quantity to 3.",
    );
  });
  it("explains the 99 clamp without blaming stock", () => {
    assert.equal(
      clampMessage(150, 99, { min: 1, max: 99, stockLimited: false }),
      "You can order up to 99 of one item, so we set the quantity to 99.",
    );
  });
  it("points to Remove for zero", () => {
    assert.match(clampMessage(0, 1, stock) ?? "", /Remove/);
  });
  it("says nothing when nothing changed or the input is not a number", () => {
    assert.equal(clampMessage(2, 2, stock), null);
    assert.equal(clampMessage(Number.NaN, 1, stock), null);
  });
});

describe("hasBlockingLine", () => {
  it("blocks on anything the database objected to", () => {
    assert.equal(
      hasBlockingLine([{ kind: "in_stock" }, { kind: "checking" }]),
      false,
    );
    assert.equal(hasBlockingLine([{ kind: "unavailable" }]), true);
    assert.equal(
      hasBlockingLine([{ kind: "low_stock", maxQuantity: 1 }]),
      true,
    );
    assert.equal(
      hasBlockingLine([{ kind: "price_changed", newPriceCents: 1 }]),
      true,
    );
  });
});

describe("cartSubtotalDisplay", () => {
  it("uses the database subtotal whenever there is one", () => {
    assert.deepEqual(
      cartSubtotalDisplay({
        serverSubtotalCents: 5000,
        serverPending: false,
        savedPricesEstimateCents: 4000,
      }),
      { label: "Subtotal", cents: 5000, estimated: false },
    );
    assert.equal(
      cartSubtotalDisplay({
        serverSubtotalCents: 0,
        serverPending: true,
        savedPricesEstimateCents: 4000,
      }).cents,
      0,
    );
  });

  it("shows nothing while the database is still answering", () => {
    assert.deepEqual(
      cartSubtotalDisplay({
        serverSubtotalCents: null,
        serverPending: true,
        savedPricesEstimateCents: 4000,
      }),
      { label: "Subtotal", cents: null, estimated: false },
    );
  });

  it("labels the saved-price number as an estimate when the database has not answered", () => {
    assert.deepEqual(
      cartSubtotalDisplay({
        serverSubtotalCents: null,
        serverPending: false,
        savedPricesEstimateCents: 4000,
      }),
      { label: "Estimated subtotal", cents: 4000, estimated: true },
    );
  });
});
