import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  activeView,
  describeAdjustmentError,
  adjustmentErrorField,
  describeMovement,
  formatActor,
  formatMovementActor,
  INVENTORY_PAGE_SIZE,
  movementOrderReference,
  pageSlice,
  parseInventoryParams,
  toInventoryListQuery,
} from "../src/features/admin/inventory-management.ts";
import {
  AdminInventoryActionError,
  buildAdjustmentArgs,
  classifyStock,
  collectAllPages,
  emptyAdjustmentValues,
  formatDelta,
  inventoryRowKey,
  LOW_STOCK_THRESHOLD,
  parseAdjustmentQuantity,
  projectStock,
  toAdminAdjustmentList,
  toAdminAdjustResult,
  toAdminInventoryActionError,
  toAdminInventoryError,
  toAdminInventoryList,
  toAdminListAdjustmentsArgs,
  toAdminListInventoryArgs,
  type AdjustmentFormValues,
} from "../src/features/admin/inventory-result.ts";
import type { AdminInventoryRow } from "../src/lib/supabase/types.ts";

const PRODUCT_ID = "11111111-1111-4111-8111-111111111111";
const VARIANT_ID = "22222222-2222-4222-8222-222222222222";

function row(overrides: Partial<AdminInventoryRow> = {}): AdminInventoryRow {
  return {
    kind: "product",
    product_id: PRODUCT_ID,
    variant_id: null,
    sku: "MILK-1",
    product_name: "Milk",
    product_slug: "milk",
    variant_name: null,
    price_cents: 1500,
    stock_quantity: 50,
    in_stock: true,
    is_active: true,
    product_is_active: true,
    variant_count: 0,
    updated_at: "2026-10-05T00:00:00Z",
    ...overrides,
  };
}

function form(
  overrides: Partial<AdjustmentFormValues> = {},
): AdjustmentFormValues {
  return {
    ...emptyAdjustmentValues(),
    quantity: "10",
    reason: "Stock received",
    ...overrides,
  };
}

describe("classifyStock (mirrors the Phase 6A dashboard rule)", () => {
  it("product: out of stock when the flag is off or the quantity is 0", () => {
    assert.equal(classifyStock(row({ stock_quantity: 0 })), "out_of_stock");
    assert.equal(
      classifyStock(row({ stock_quantity: 40, in_stock: false })),
      "out_of_stock",
    );
  });

  it("product: low stock only when in_stock and 1..threshold", () => {
    assert.equal(classifyStock(row({ stock_quantity: 1 })), "low_stock");
    assert.equal(
      classifyStock(row({ stock_quantity: LOW_STOCK_THRESHOLD })),
      "low_stock",
    );
    assert.equal(
      classifyStock(row({ stock_quantity: LOW_STOCK_THRESHOLD + 1 })),
      "in_stock",
    );
  });

  it("variant: no in_stock flag; 0 is out, 1..threshold is low", () => {
    const v = (stock_quantity: number) =>
      row({
        kind: "variant",
        variant_id: VARIANT_ID,
        in_stock: null,
        stock_quantity,
      });
    assert.equal(classifyStock(v(0)), "out_of_stock");
    assert.equal(classifyStock(v(5)), "low_stock");
    assert.equal(classifyStock(v(500)), "in_stock");
  });

  it("inactive units, and variants of inactive products, are not classified", () => {
    assert.equal(
      classifyStock(row({ is_active: false, stock_quantity: 0 })),
      "inactive",
    );
    assert.equal(
      classifyStock(
        row({
          kind: "variant",
          in_stock: null,
          stock_quantity: 0,
          product_is_active: false,
        }),
      ),
      "inactive",
    );
  });

  it("honours an explicit threshold", () => {
    assert.equal(classifyStock(row({ stock_quantity: 20 }), 25), "low_stock");
  });
});

describe("low-stock rule has not drifted from the Phase 6A migration", () => {
  const sql = readFileSync(
    new URL(
      "../db/migrations/20261004010000_phase6a_admin_operations_foundation.sql",
      import.meta.url,
    ),
    "utf8",
  );

  it("the dashboard default threshold equals LOW_STOCK_THRESHOLD", () => {
    assert.match(sql, /p_low_stock_threshold integer default (\d+)/);
    const found = /p_low_stock_threshold integer default (\d+)/.exec(sql);
    assert.equal(Number(found?.[1]), LOW_STOCK_THRESHOLD);
  });

  it("the dashboard still defines low stock as 1..threshold and product out-of-stock as flag or 0", () => {
    assert.match(sql, /p\.stock_quantity between 1 and p_low_stock_threshold/);
    assert.match(sql, /v\.stock_quantity between 1 and p_low_stock_threshold/);
    assert.match(sql, /not p\.in_stock or p\.stock_quantity = 0/);
    assert.match(sql, /v\.stock_quantity = 0/);
  });
});

describe("the UI reuses the Phase 6C functions and invents no database object", () => {
  const read = (name: string) =>
    readFileSync(new URL(`../db/migrations/${name}`, import.meta.url), "utf8");

  it("admin_list_inventory has no low-stock parameter (so the filter is a documented client rule)", () => {
    const sql = read("20261004080000_phase6c2_inventory_read_foundation.sql");
    const signature =
      /create function public\.admin_list_inventory\(([\s\S]*?)\)\s*returns/.exec(
        sql,
      );
    assert.ok(signature?.[1]);
    assert.doesNotMatch(signature[1], /low|threshold/i);
  });

  it("the argument names sent match the migrations", () => {
    const list = read("20261004080000_phase6c2_inventory_read_foundation.sql");
    for (const name of Object.keys(toAdminListInventoryArgs()))
      assert.ok(list.includes(name), name);
    const history = read("20261004110000_phase6c2_inventory_history_api.sql");
    for (const name of Object.keys(toAdminListAdjustmentsArgs())) {
      assert.ok(history.includes(name), name);
    }
    const adjust = read(
      "20261004100000_phase6c2_admin_inventory_adjustment.sql",
    );
    const built = buildAdjustmentArgs(row(), form({ note: "n" }));
    assert.ok(built.ok);
    for (const name of Object.keys(built.args))
      assert.ok(adjust.includes(name), name);
  });

  it("the Phase 6C.2 inventory migrations exist", () => {
    const files = readdirSync(
      new URL("../db/migrations/", import.meta.url),
    ).filter((f) => f.endsWith(".sql"));
    for (const name of [
      "20261004080000_phase6c2_inventory_read_foundation.sql",
      "20261004090000_phase6c2_inventory_adjustment_history.sql",
      "20261004100000_phase6c2_admin_inventory_adjustment.sql",
      "20261004110000_phase6c2_inventory_history_api.sql",
    ]) {
      assert.ok(files.includes(name), name);
    }
  });
});

describe("parseAdjustmentQuantity", () => {
  it("accepts signed whole numbers", () => {
    assert.deepEqual(parseAdjustmentQuantity("10"), { ok: true, value: 10 });
    assert.deepEqual(parseAdjustmentQuantity("+10"), { ok: true, value: 10 });
    assert.deepEqual(parseAdjustmentQuantity(" -3 "), { ok: true, value: -3 });
  });

  it("refuses blank, zero, decimals, exponents and text", () => {
    for (const bad of [
      "",
      "  ",
      "0",
      "-0",
      "+0",
      "1.5",
      "1e3",
      "abc",
      "--1",
      "1 2",
    ]) {
      assert.equal(parseAdjustmentQuantity(bad).ok, false, bad);
    }
  });

  it("refuses numbers beyond the integer column", () => {
    assert.equal(parseAdjustmentQuantity("2147483647").ok, true);
    assert.equal(parseAdjustmentQuantity("2147483648").ok, false);
    assert.equal(parseAdjustmentQuantity("-2147483648").ok, false);
    assert.equal(parseAdjustmentQuantity("99999999999999999999").ok, false);
  });
});

describe("buildAdjustmentArgs", () => {
  it("sends only the five arguments the function takes, never a final quantity", () => {
    const built = buildAdjustmentArgs(
      row(),
      form({ quantity: "-3", note: "  damaged  " }),
    );
    assert.ok(built.ok);
    assert.equal(built.delta, -3);
    assert.deepEqual(built.args, {
      p_product_id: PRODUCT_ID,
      p_adjustment_quantity: -3,
      p_reason: "Stock received",
      p_variant_id: null,
      p_note: "damaged",
    });
  });

  it("targets a variant by id and omits a blank note", () => {
    const built = buildAdjustmentArgs(
      row({ kind: "variant", variant_id: VARIANT_ID }),
      form({ note: "   " }),
    );
    assert.ok(built.ok);
    assert.equal(built.args.p_variant_id, VARIANT_ID);
    assert.equal(built.args.p_note, null);
  });

  it("reports field errors and builds nothing", () => {
    const built = buildAdjustmentArgs(row(), {
      quantity: "0",
      reason: "   ",
      note: "x".repeat(501),
    });
    assert.equal(built.ok, false);
    if (!built.ok) {
      assert.ok(built.errors.quantity);
      assert.ok(built.errors.reason);
      assert.ok(built.errors.note);
    }
  });

  it("counts a 120-character reason as valid and 121 as too long", () => {
    assert.equal(
      buildAdjustmentArgs(row(), form({ reason: "r".repeat(120) })).ok,
      true,
    );
    assert.equal(
      buildAdjustmentArgs(row(), form({ reason: "r".repeat(121) })).ok,
      false,
    );
  });
});

describe("projectStock / formatDelta", () => {
  it("previews current + change", () => {
    assert.equal(projectStock(5, -8), -3);
    assert.equal(projectStock(5, 10), 15);
  });
  it("formats signs", () => {
    assert.equal(formatDelta(10), "+10");
    assert.equal(formatDelta(-3), "-3");
  });
});

describe("error mapping", () => {
  it("42501 / not_authorised becomes AdminAccessError on reads and writes", () => {
    assert.ok(
      toAdminInventoryError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
    assert.ok(
      toAdminInventoryActionError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("rule refusals keep their reason and point at a field", () => {
    const negative = toAdminInventoryActionError({
      message: "raw database text",
      code: "P0001",
      details: "negative_stock_not_allowed",
    });
    assert.ok(negative instanceof AdminInventoryActionError);
    assert.equal(negative.reason, "negative_stock_not_allowed");
    assert.equal(adjustmentErrorField(negative), "quantity");

    const reason = toAdminInventoryActionError({
      message: "A reason of 1 to 120 characters is required.",
      details: "invalid_arguments",
    });
    assert.equal(adjustmentErrorField(reason), "reason");
    const note = toAdminInventoryActionError({
      message: "A note, when given, must be 1 to 500 characters.",
      details: "invalid_arguments",
    });
    assert.equal(adjustmentErrorField(note), "note");
  });

  it("raw database text never reaches the admin", () => {
    const raw =
      "The adjustment would make stock negative (current 2, change -5).";
    const text = describeAdjustmentError(
      toAdminInventoryActionError({
        message: raw,
        details: "negative_stock_not_allowed",
      }),
    );
    assert.doesNotMatch(text, /current 2|change -5|negative \(/);
    assert.doesNotMatch(
      describeAdjustmentError(new Error("pgrst 500 boom")),
      /pgrst|boom/i,
    );
  });

  it("an unknown failure tells the admin to check the history before retrying", () => {
    assert.match(describeAdjustmentError(new Error("network down")), /History/);
  });

  it("an access refusal is worded as a permission problem", () => {
    assert.match(
      describeAdjustmentError(new AdminAccessError()),
      /not permitted/,
    );
  });
});

describe("response shape checks", () => {
  it("accept the documented shapes", () => {
    assert.equal(
      toAdminInventoryList({ total: 0, limit: 25, offset: 0, inventory: [] })
        .total,
      0,
    );
    assert.equal(
      toAdminAdjustmentList({ total: 0, limit: 25, offset: 0, adjustments: [] })
        .total,
      0,
    );
    assert.equal(
      toAdminAdjustResult({
        adjustment_id: "a",
        previous_quantity: 1,
        adjustment_quantity: 2,
        new_quantity: 3,
      }).new_quantity,
      3,
    );
  });

  it("refuse anything else loudly", () => {
    assert.throws(() => toAdminInventoryList(null));
    assert.throws(() => toAdminInventoryList({ total: 1, inventory: [] }));
    assert.throws(() =>
      toAdminAdjustmentList({
        adjustments: "x",
        total: 1,
        limit: 1,
        offset: 0,
      }),
    );
    assert.throws(() => toAdminAdjustResult({ adjustment_id: 5 }));
  });
});

describe("collectAllPages", () => {
  const makeFetch = (total: number, pageSize: number) => {
    let calls = 0;
    const fetchPage = async (offset: number) => {
      calls += 1;
      const rows = Array.from(
        { length: Math.max(0, Math.min(pageSize, total - offset)) },
        (_, i) => offset + i,
      );
      return { total, rows };
    };
    return { fetchPage, calls: () => calls };
  };

  it("reads every page", async () => {
    const f = makeFetch(250, 100);
    const result = await collectAllPages(f.fetchPage, {
      pageSize: 100,
      maxRows: 2000,
    });
    assert.equal(result.rows.length, 250);
    assert.equal(result.truncated, false);
    assert.equal(f.calls(), 3);
  });

  it("stops at the cap and says so", async () => {
    const f = makeFetch(5000, 100);
    const result = await collectAllPages(f.fetchPage, {
      pageSize: 100,
      maxRows: 300,
    });
    assert.equal(result.rows.length, 300);
    assert.equal(result.total, 5000);
    assert.equal(result.truncated, true);
  });

  it("cannot loop forever on a misreported total", async () => {
    const result = await collectAllPages(
      async () => ({ total: 999, rows: [] as number[] }),
      {
        pageSize: 100,
        maxRows: 2000,
      },
    );
    assert.equal(result.rows.length, 0);
  });

  it("handles an empty list", async () => {
    const f = makeFetch(0, 100);
    const result = await collectAllPages(f.fetchPage, {
      pageSize: 100,
      maxRows: 2000,
    });
    assert.deepEqual(result, { rows: [], total: 0, truncated: false });
  });
});

describe("URL params and paging", () => {
  it("keeps valid values and drops malformed ones", () => {
    assert.deepEqual(
      parseInventoryParams({
        q: "  milk ",
        view: "low",
        page: "3",
        tab: "history",
        product: "nope",
      }),
      { q: "milk", view: "low", tab: "history", page: 3 },
    );
    assert.deepEqual(
      parseInventoryParams({ view: "everything", page: "-2", q: "   " }),
      {},
    );
  });

  it("a variant filter needs its product", () => {
    assert.deepEqual(parseInventoryParams({ variant: VARIANT_ID }), {});
    assert.deepEqual(
      parseInventoryParams({ product: PRODUCT_ID, variant: VARIANT_ID }),
      {
        product: PRODUCT_ID,
        variant: VARIANT_ID,
      },
    );
  });

  it("defaults to all inventory and builds a server page query", () => {
    assert.equal(activeView({}), "all");
    assert.equal(activeView({ view: "out" }), "out");
    assert.deepEqual(toInventoryListQuery({ q: "milk", page: 3 }), {
      search: "milk",
      limit: INVENTORY_PAGE_SIZE,
      offset: 2 * INVENTORY_PAGE_SIZE,
    });
  });

  it("slices client pages", () => {
    const items = Array.from({ length: 60 }, (_, i) => i);
    assert.equal(pageSlice(items, 1, 25).length, 25);
    assert.equal(pageSlice(items, 3, 25).length, 10);
    assert.equal(pageSlice(items, 4, 25).length, 0);
  });

  it("row keys separate a product's own stock from its variants", () => {
    assert.notEqual(
      inventoryRowKey(row()),
      inventoryRowKey(row({ kind: "variant", variant_id: VARIANT_ID })),
    );
  });
});

describe("formatActor", () => {
  it("never exposes more than a short id", () => {
    const id = "33333333-3333-4333-8333-333333333333";
    assert.equal(formatActor(id, id), "You");
    assert.equal(formatActor(id, null), "Admin 33333333");
    assert.match(formatActor(null, id), /Unknown/);
  });
});

describe("movement labels (Phase 9C)", () => {
  it("labels each kind from what the database can attribute", () => {
    assert.equal(
      describeMovement("admin_adjustment")?.label,
      "Admin adjustment",
    );
    assert.equal(describeMovement("order_restock")?.label, "Order cancelled");
    assert.equal(
      describeMovement("order_reactivation")?.label,
      "Order reactivated",
    );
    const unattributed = describeMovement("stock_change");
    assert.match(unattributed?.label ?? "", /Order or direct change/);
    assert.match(unattributed?.detail ?? "", /cannot be told apart/);
  });

  it("shows nothing for a missing kind and a generic label for an unknown one", () => {
    assert.equal(describeMovement(null), null);
    assert.equal(describeMovement(undefined), null);
    assert.equal(describeMovement(""), null);
    assert.equal(describeMovement("something_new")?.label, "Stock movement");
  });

  it("builds a short order reference and tolerates a missing order id", () => {
    assert.equal(
      movementOrderReference("abcdef12-0000-4000-8000-000000000000"),
      "ABCDEF12",
    );
    assert.equal(movementOrderReference(null), null);
    assert.equal(movementOrderReference(undefined), null);
  });

  it("never calls a customer or the system an admin", () => {
    const id = "33333333-3333-4333-8333-333333333333";
    // admin adjustments keep the old wording
    assert.equal(formatMovementActor("admin_adjustment", id, id), "You");
    assert.equal(
      formatMovementActor("admin_adjustment", id, null),
      "Admin 33333333",
    );
    assert.match(formatMovementActor("admin_adjustment", null, id), /Unknown/);
    // older database (no kind) behaves as before
    assert.equal(formatMovementActor(null, id, null), "Admin 33333333");
    // other kinds: a null actor is a customer or the system, not a removed account
    assert.equal(
      formatMovementActor("stock_change", null, id),
      "Customer or system",
    );
    assert.equal(
      formatMovementActor("order_restock", null, id),
      "Customer or system",
    );
    assert.equal(formatMovementActor("order_restock", id, id), "You");
    assert.equal(
      formatMovementActor("order_reactivation", id, null),
      "Team member 33333333",
    );
  });

  it("parses rows with and without the Phase 9C fields", () => {
    const base = { id: "a", reason: "r", note: null, changed_by: null };
    const list = toAdminAdjustmentList({
      total: 2,
      limit: 25,
      offset: 0,
      adjustments: [
        { ...base, movement_kind: "order_restock", order_id: "o1" },
        { ...base },
      ],
    });
    assert.equal(list.adjustments[0]?.movement_kind, "order_restock");
    assert.equal(list.adjustments[0]?.order_id, "o1");
    assert.equal(list.adjustments[1]?.movement_kind, null);
    assert.equal(list.adjustments[1]?.order_id, null);
    assert.equal(list.total, 2);
  });
});
