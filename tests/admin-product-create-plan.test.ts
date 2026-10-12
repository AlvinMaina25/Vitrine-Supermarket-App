import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  describePartialCreate,
  MAX_STARTING_STOCK,
  OPENING_STOCK_REASON,
  parseStartingStock,
  planFollowUpSteps,
  runCreateWithExtras,
  type FollowUpStep,
} from "../src/features/admin/product-create-plan.ts";

describe("parseStartingStock", () => {
  it("treats blank as the default 0", () => {
    assert.deepEqual(parseStartingStock(""), { ok: true, value: 0 });
    assert.deepEqual(parseStartingStock("   "), { ok: true, value: 0 });
  });
  it("accepts whole numbers, trimmed", () => {
    assert.deepEqual(parseStartingStock("0"), { ok: true, value: 0 });
    assert.deepEqual(parseStartingStock(" 25 "), { ok: true, value: 25 });
    assert.deepEqual(parseStartingStock("007"), { ok: true, value: 7 });
    assert.deepEqual(parseStartingStock(String(MAX_STARTING_STOCK)), {
      ok: true,
      value: MAX_STARTING_STOCK,
    });
  });
  it("refuses negatives, decimals, exponents, signs and text", () => {
    for (const bad of ["-1", "1.5", "1e3", "+4", "ten", "1 2", "0x10", "٣"]) {
      assert.equal(parseStartingStock(bad).ok, false, bad);
    }
  });
  it("refuses more than the database can store", () => {
    const result = parseStartingStock(String(MAX_STARTING_STOCK + 1));
    assert.equal(result.ok, false);
    assert.equal(parseStartingStock("99999999999999999999").ok, false);
  });
});

describe("planFollowUpSteps", () => {
  it("is empty for the defaults (0 stock, active)", () => {
    assert.deepEqual(planFollowUpSteps({ stock: 0, active: true }), []);
  });
  it("adds stock only when above 0", () => {
    assert.deepEqual(planFollowUpSteps({ stock: 5, active: true }), ["stock"]);
  });
  it("adds deactivation only when Active is off", () => {
    assert.deepEqual(planFollowUpSteps({ stock: 0, active: false }), [
      "active",
    ]);
  });
  it("runs stock before deactivation", () => {
    assert.deepEqual(planFollowUpSteps({ stock: 5, active: false }), [
      "stock",
      "active",
    ]);
  });
});

function harness(failing: FollowUpStep[] = [], createFails = false) {
  const calls: string[] = [];
  const errors: FollowUpStep[] = [];
  return {
    calls,
    errors,
    deps: {
      create: async () => {
        calls.push("create");
        if (createFails) throw new Error("create failed");
        return { product: { id: "p1" } };
      },
      idOf: (created: { product: { id: string } }) => created.product.id,
      adjustStock: async (id: string, quantity: number) => {
        calls.push(`stock:${id}:${quantity}`);
        if (failing.includes("stock")) throw new Error("stock failed");
      },
      deactivate: async (id: string) => {
        calls.push(`deactivate:${id}`);
        if (failing.includes("active")) throw new Error("deactivate failed");
      },
      onStepError: (step: FollowUpStep) => errors.push(step),
    },
  };
}

describe("runCreateWithExtras", () => {
  it("creates only, for the defaults", async () => {
    const h = harness();
    const out = await runCreateWithExtras({ stock: 0, active: true }, h.deps);
    assert.deepEqual(h.calls, ["create"]);
    assert.deepEqual(out.failed, []);
    assert.equal(out.product.product.id, "p1");
  });
  it("creates, then stock, then deactivate, in that order", async () => {
    const h = harness();
    const out = await runCreateWithExtras({ stock: 12, active: false }, h.deps);
    assert.deepEqual(h.calls, ["create", "stock:p1:12", "deactivate:p1"]);
    assert.deepEqual(out.failed, []);
  });
  it("keeps the product and reports a failed stock step", async () => {
    const h = harness(["stock"]);
    const out = await runCreateWithExtras({ stock: 3, active: true }, h.deps);
    assert.deepEqual(out.failed, ["stock"]);
    assert.deepEqual(h.errors, ["stock"]);
    assert.equal(out.product.product.id, "p1");
  });
  it("still tries to hide the product when the stock step fails", async () => {
    const h = harness(["stock"]);
    const out = await runCreateWithExtras({ stock: 3, active: false }, h.deps);
    assert.deepEqual(h.calls, ["create", "stock:p1:3", "deactivate:p1"]);
    assert.deepEqual(out.failed, ["stock"]);
  });
  it("reports a failed deactivation and a double failure", async () => {
    const a = await runCreateWithExtras(
      { stock: 0, active: false },
      harness(["active"]).deps,
    );
    assert.deepEqual(a.failed, ["active"]);
    const b = await runCreateWithExtras(
      { stock: 2, active: false },
      harness(["stock", "active"]).deps,
    );
    assert.deepEqual(b.failed, ["stock", "active"]);
  });
  it("throws when create fails and runs nothing after it", async () => {
    const h = harness([], true);
    await assert.rejects(
      runCreateWithExtras({ stock: 9, active: false }, h.deps),
      /create failed/,
    );
    assert.deepEqual(h.calls, ["create"]);
  });
});

describe("describePartialCreate", () => {
  it("is null when everything was saved", () => {
    assert.equal(describePartialCreate([]), null);
  });
  it("uses the agreed sentence for a stock failure", () => {
    assert.equal(
      describePartialCreate(["stock"]),
      "The product was created, but starting stock was not saved. Set it on the product page.",
    );
  });
  it("says the product is still visible when it could not be hidden", () => {
    assert.match(describePartialCreate(["active"]) ?? "", /still visible/);
    assert.match(
      describePartialCreate(["stock", "active"]) ?? "",
      /stock was not saved and it could not be hidden/,
    );
  });
  it("never leaks raw error text", () => {
    for (const f of [["stock"], ["active"], ["stock", "active"]] as const)
      assert.doesNotMatch(
        describePartialCreate([...f]) ?? "",
        /rpc|P0001|exception|supabase/i,
      );
  });
  it("uses the reason the spec asks for", () => {
    assert.equal(OPENING_STOCK_REASON, "Opening stock");
  });
});
