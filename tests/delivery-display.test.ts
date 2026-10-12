import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  getOrderDeliveryDisplay,
  humaniseCode,
  type OrderDeliverySource,
} from "../src/features/orders/delivery-display.ts";
import type { DeliveryFeeRule } from "../src/lib/supabase/types.ts";

/**
 * Unit tests for the snapshot-first delivery display helper. The helper is pure: it reads only
 * the order row. (The OrderDeliveryCard component is not rendered here - no DOM test framework
 * is used - so the last block statically guards that it still takes everything from the helper.)
 *
 * Run with: bun run test   (Node >= 22.18 runs the .ts files directly)
 */

const completeOrder: OrderDeliverySource = {
  delivery_method: "standard",
  delivery_method_label: "Standard delivery",
  delivery_zone_id: "zone-1",
  delivery_zone_code: "westlands",
  delivery_zone_name: "Westlands",
  delivery_slot_template_id: "template-1",
  delivery_slot_date: "2026-10-10",
  delivery_slot_start: "08:00:00",
  delivery_slot_end: "11:00:00",
  delivery_slot_label: "Morning",
  delivery_fee_cents: 25000,
  delivery_fee_rule: {
    source: "zone",
    base_fee_cents: 25000,
    free_over_cents: 500000,
    min_order_cents: 0,
    zone_fee_id: "fee-1",
  },
};

/** An order placed before Phase 4: every snapshot column is NULL. */
const legacyOrder: OrderDeliverySource = {
  delivery_method: "same_day",
  delivery_method_label: null,
  delivery_zone_id: null,
  delivery_zone_code: null,
  delivery_zone_name: null,
  delivery_slot_template_id: null,
  delivery_slot_date: null,
  delivery_slot_start: null,
  delivery_slot_end: null,
  delivery_slot_label: null,
  delivery_fee_cents: 0,
  delivery_fee_rule: null,
};

describe("getOrderDeliveryDisplay: complete snapshot", () => {
  it("shows method, zone, slot and fee from the order", () => {
    const d = getOrderDeliveryDisplay(completeOrder);
    assert.equal(d.methodLabel, "Standard delivery");
    assert.equal(d.methodLabelIsFallback, false);
    assert.equal(d.zoneName, "Westlands");
    assert.deepEqual(d.slot, {
      date: "2026-10-10",
      start: "08:00:00",
      end: "11:00:00",
      label: "Morning",
    });
    assert.equal(d.feeCents, 25000);
    assert.equal(d.isFree, false);
    assert.equal(d.feeSource, "zone");
  });

  it("prefers the snapshot method label over the stored method code", () => {
    // The snapshot label is what the method was called at order time, even though the code
    // (and the live method row) may since have been renamed or deactivated.
    const d = getOrderDeliveryDisplay({
      ...completeOrder,
      delivery_method: "standard",
      delivery_method_label: "Standard (Nairobi)",
    });
    assert.equal(d.methodLabel, "Standard (Nairobi)");
  });

  it("prefers the snapshot zone name, falling back to the stored zone code", () => {
    assert.equal(getOrderDeliveryDisplay(completeOrder).zoneName, "Westlands");
    const codeOnly = getOrderDeliveryDisplay({
      ...completeOrder,
      delivery_zone_name: null,
    });
    assert.equal(codeOnly.zoneName, "westlands");
  });

  it("preserves the stored fee, including a free delivery and the recorded rule source", () => {
    const free = getOrderDeliveryDisplay({
      ...completeOrder,
      delivery_fee_cents: 0,
      delivery_fee_rule: {
        ...completeOrder.delivery_fee_rule!,
        source: "method",
      },
    });
    assert.equal(free.feeCents, 0);
    assert.equal(free.isFree, true);
    assert.equal(free.feeSource, "method");
  });

  it("ignores a malformed fee rule instead of throwing", () => {
    const d = getOrderDeliveryDisplay({
      ...completeOrder,
      delivery_fee_rule: { source: "weird" } as unknown as DeliveryFeeRule,
    });
    assert.equal(d.feeSource, null);
    assert.equal(d.feeCents, 25000);
  });
});

describe("getOrderDeliveryDisplay: old orders with NULL snapshots", () => {
  it("does not throw and invents nothing", () => {
    const d = getOrderDeliveryDisplay(legacyOrder);
    assert.equal(d.zoneName, null);
    assert.equal(d.slot, null);
    assert.equal(d.feeSource, null);
    assert.equal(d.feeCents, 0);
  });

  it("falls back to the order's own stored method code, tidied, never to live configuration", () => {
    const d = getOrderDeliveryDisplay(legacyOrder);
    assert.equal(d.methodLabel, "Same day");
    assert.equal(d.methodLabelIsFallback, true);
    assert.equal(humaniseCode("click-and-collect"), "Click and collect");
  });

  it("treats blank strings like NULL", () => {
    const d = getOrderDeliveryDisplay({
      ...legacyOrder,
      delivery_method_label: "   ",
      delivery_zone_name: "",
      delivery_zone_code: " ",
    });
    assert.equal(d.methodLabel, "Same day");
    assert.equal(d.zoneName, null);
  });

  it("shows a stored slot date without a window when start or end is missing", () => {
    const d = getOrderDeliveryDisplay({
      ...legacyOrder,
      delivery_slot_date: "2026-09-01",
      delivery_slot_start: "08:00:00",
      delivery_slot_end: null,
      delivery_slot_label: "Morning",
    });
    assert.deepEqual(d.slot, {
      date: "2026-09-01",
      start: null,
      end: null,
      label: "Morning",
    });
  });

  it("copes with a missing method code too", () => {
    const d = getOrderDeliveryDisplay({
      ...legacyOrder,
      delivery_method: "" as string,
    });
    assert.equal(d.methodLabel, "Delivery");
  });

  it("has no slot when there is a window but no date", () => {
    const d = getOrderDeliveryDisplay({
      ...legacyOrder,
      delivery_slot_start: "08:00:00",
      delivery_slot_end: "11:00:00",
    });
    assert.equal(d.slot, null);
  });
});

describe("historical display is independent of today's delivery configuration", () => {
  it("renaming a method, changing a zone fee or deleting a zone cannot change the display", () => {
    const before = getOrderDeliveryDisplay(completeOrder);

    // Today's configuration after staff edits. The helper has no way to see it: its only input
    // is the order, so the result must be identical whatever happens to these.
    const liveConfig = {
      methods: [
        { code: "standard", label: "Renamed method", is_active: false },
      ],
      zones: [{ id: "zone-1", name: "Westlands (renamed)", is_active: false }],
      zoneFees: [{ zone_id: "zone-1", base_fee_cents: 99999 }],
    };
    liveConfig.methods[0]!.label = "Another rename";
    liveConfig.zoneFees[0]!.base_fee_cents = 1;
    liveConfig.zones.length = 0;

    const after = getOrderDeliveryDisplay(completeOrder);
    assert.deepEqual(after, before);
    assert.equal(after.methodLabel, "Standard delivery");
    assert.equal(after.zoneName, "Westlands");
    assert.equal(after.feeCents, 25000);
  });

  it("does not mutate the order it is given", () => {
    const snapshot = JSON.stringify(legacyOrder);
    getOrderDeliveryDisplay(legacyOrder);
    assert.equal(JSON.stringify(legacyOrder), snapshot);
  });
});

describe("snapshot wiring (static guards; no DOM framework)", () => {
  const read = (path: string) =>
    readFileSync(new URL(path, import.meta.url), "utf8");

  it("the display helper imports nothing live", () => {
    const source = read("../src/features/orders/delivery-display.ts");
    const imports = source.match(/^import .*$/gm) ?? [];
    for (const line of imports) {
      assert.match(
        line,
        /^import type /,
        `only type imports are allowed: ${line}`,
      );
    }
    assert.doesNotMatch(
      source,
      /supabase\/client|react-query|features\/delivery\/queries/,
    );
  });

  it("OrderDeliveryCard uses the helper and no longer queries live delivery methods", () => {
    const source = read("../src/features/orders/components/order-sections.tsx");
    assert.match(source, /getOrderDeliveryDisplay\(order\)/);
    assert.doesNotMatch(source, /deliveryMethodsQuery|useQuery/);
  });

  it("the order detail query reads the snapshot columns from the order row", () => {
    const source = read("../src/features/orders/queries.ts");
    for (const column of [
      "delivery_zone_id",
      "delivery_zone_code",
      "delivery_zone_name",
      "delivery_method_label",
      "delivery_slot_template_id",
      "delivery_fee_rule",
    ]) {
      assert.match(source, new RegExp(column), `${column} must be selected`);
    }
    assert.match(source, /\.select\(ORDER_DETAIL_COLUMNS\)/);
    // No join to live delivery configuration to rebuild history.
    assert.doesNotMatch(
      source,
      /delivery_methods\(|delivery_zones\(|delivery_slot_templates\(/,
    );
  });
});
