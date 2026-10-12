import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildQuoteRequest,
  buildSlotChoices,
  deliveryErrorMessage,
  deliveryErrorScope,
  dedupeSlotWindows,
  deriveQuoteState,
  isDeliveryErrorCode,
  isSlotSelectable,
  quoteBlockerMessage,
  resolveSelectedSlot,
  resolveZoneId,
  selectableZones,
  slotDateRange,
  visibleSlotChoices,
  zoneRequirement,
  type DeliveryErrorCode,
  type DeliveryQuoteRequest,
} from "../src/features/delivery/checkout.ts";
import { buildCreateOrderArgs } from "../src/features/orders/create-order-args.ts";
import type { PlaceOrderInput } from "../src/features/orders/create-order-args.ts";
import { toDeliverySelectionResult } from "../src/features/delivery/validation.ts";
import type {
  DeliverySelectionValidationRow,
  DeliverySlotAvailabilityRow,
} from "../src/lib/supabase/types.ts";

/**
 * Pure-helper tests for the checkout delivery integration. They do not exercise the database
 * (see db/tests/*.test.sql) or React; they check what checkout asks for and how it reads the
 * answers.
 */

const ALL_CODES: DeliveryErrorCode[] = [
  "method_required",
  "method_unknown",
  "method_inactive",
  "zone_required",
  "zone_unknown",
  "zone_inactive",
  "below_minimum_order",
  "unavailable",
  "slot_required",
  "invalid_window",
  "slot_in_past",
  "slot_too_far",
  "slot_unknown",
  "slot_inactive",
  "slot_closed",
  "slot_full",
];

// ----------------------------------------------------------------------------------------- zones

const zones = [
  { id: "z-active", is_active: true, name: "Nairobi CBD" },
  { id: "z-off", is_active: false, name: "Closed area" },
  { id: "z-active-2", is_active: true, name: "Westlands" },
];

describe("zone selection", () => {
  it("only active zones can be selected", () => {
    assert.deepEqual(
      selectableZones(zones).map((zone) => zone.id),
      ["z-active", "z-active-2"],
    );
  });

  it("an active zone resolves to its id for address delivery", () => {
    assert.equal(
      resolveZoneId({
        requiresAddress: true,
        zones,
        selectedZoneId: "z-active",
      }),
      "z-active",
    );
  });

  it("an inactive or unknown zone does not resolve", () => {
    assert.equal(
      resolveZoneId({ requiresAddress: true, zones, selectedZoneId: "z-off" }),
      null,
    );
    assert.equal(
      resolveZoneId({ requiresAddress: true, zones, selectedZoneId: "nope" }),
      null,
    );
  });

  it("pickup needs no zone, and a stale selection is not sent", () => {
    assert.equal(zoneRequirement(false, zones), "not_required");
    assert.equal(zoneRequirement(false, []), "not_required");
    assert.equal(
      resolveZoneId({
        requiresAddress: false,
        zones,
        selectedZoneId: "z-active",
      }),
      null,
    );
  });

  it("address delivery requires a zone: none chosen resolves to null", () => {
    assert.equal(zoneRequirement(true, zones), "choose");
    assert.equal(
      resolveZoneId({ requiresAddress: true, zones, selectedZoneId: null }),
      null,
    );
  });

  it("address delivery with no active zones is unavailable", () => {
    assert.equal(zoneRequirement(true, []), "no_zones");
    assert.equal(zoneRequirement(true, undefined), "no_zones");
    assert.equal(
      zoneRequirement(true, [{ id: "z-off", is_active: false }]),
      "no_zones",
    );
  });

  it("the selected zone id reaches the create_order() arguments", () => {
    const zoneId = resolveZoneId({
      requiresAddress: true,
      zones,
      selectedZoneId: "z-active-2",
    });
    const input: PlaceOrderInput = {
      items: [{ productId: "p1", variantId: null, quantity: 1 }],
      deliveryMethod: "standard",
      paymentMethod: "cash_on_delivery",
      addressId: "a1",
      zoneId,
      slotDate: "2026-10-10",
      slotStart: "08:00:00",
      slotEnd: "11:00:00",
      slotLabel: "Morning",
      notes: null,
      idempotencyKey: "k",
      expectedTotalCents: 1,
    };
    assert.equal(buildCreateOrderArgs(input).p_zone_id, "z-active-2");

    const pickupZone = resolveZoneId({
      requiresAddress: false,
      zones,
      selectedZoneId: "z-active",
    });
    assert.equal(
      buildCreateOrderArgs({ ...input, zoneId: pickupZone }).p_zone_id,
      null,
    );
  });
});

// ----------------------------------------------------------------------------------------- quote

const delivery = { code: "standard", requires_address: true };
const pickup = { code: "pickup", requires_address: false };

function validRow(overrides: Partial<DeliverySelectionValidationRow> = {}) {
  const row: DeliverySelectionValidationRow = {
    is_valid: true,
    error_code: null,
    error_message: null,
    method_code: "standard",
    method_label: "Standard delivery",
    requires_slot: true,
    requires_address: true,
    zone_id: "z-active",
    zone_code: "cbd",
    zone_name: "Nairobi CBD",
    subtotal_cents: 100_000,
    fee_cents: 25_000,
    base_fee_cents: 30_000,
    free_over_cents: 500_000,
    min_order_cents: 50_000,
    fee_source: "zone",
    zone_fee_id: "zf1",
    fee_rule: {} as DeliverySelectionValidationRow["fee_rule"],
    ...overrides,
  };
  return row;
}

describe("quote request", () => {
  it("is not asked for address delivery until a zone is chosen", () => {
    assert.equal(
      buildQuoteRequest({
        method: delivery,
        zoneId: null,
        subtotalCents: 1000,
      }),
      null,
    );
  });

  it("is asked for address delivery with the zone", () => {
    assert.deepEqual(
      buildQuoteRequest({
        method: delivery,
        zoneId: "z-active",
        subtotalCents: 1000,
      }),
      {
        methodCode: "standard",
        zoneId: "z-active",
        subtotalCents: 1000,
      },
    );
  });

  it("is asked for pickup with a null zone, even if a stale zone is supplied", () => {
    assert.deepEqual(
      buildQuoteRequest({
        method: pickup,
        zoneId: "z-active",
        subtotalCents: 1000,
      }),
      {
        methodCode: "pickup",
        zoneId: null,
        subtotalCents: 1000,
      },
    );
  });

  it("is not asked without a method or with a non-integer subtotal", () => {
    assert.equal(
      buildQuoteRequest({
        method: undefined,
        zoneId: null,
        subtotalCents: 1000,
      }),
      null,
    );
    assert.equal(
      buildQuoteRequest({ method: pickup, zoneId: null, subtotalCents: 10.5 }),
      null,
    );
  });

  it("carries no fee: only method, zone and subtotal", () => {
    const request = buildQuoteRequest({
      method: delivery,
      zoneId: "z",
      subtotalCents: 1,
    });
    assert.deepEqual(Object.keys(request ?? {}).sort(), [
      "methodCode",
      "subtotalCents",
      "zoneId",
    ]);
  });
});

describe("quote state", () => {
  const request: DeliveryQuoteRequest = {
    methodCode: "standard",
    zoneId: "z-active",
    subtotalCents: 100_000,
  };

  it("represents the database quote: the fee is copied, the total is subtotal + that fee", () => {
    const state = deriveQuoteState({
      request,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(validRow()),
    });
    assert.equal(state.status, "ready");
    if (state.status !== "ready") return;
    assert.equal(state.feeCents, 25_000);
    assert.equal(state.totalCents, 125_000);
    assert.equal(state.quote.feeSource, "zone");
  });

  it("a zone change updates the quote state to the new database fee", () => {
    const first = deriveQuoteState({
      request,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(validRow()),
    });
    const secondRequest = { ...request, zoneId: "z-active-2" };

    // Until the database answers for the new zone, the old fee is not reused.
    const loading = deriveQuoteState({
      request: secondRequest,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(validRow()), // answered for z-active
    });
    assert.equal(loading.status, "loading");

    const second = deriveQuoteState({
      request: secondRequest,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(
        validRow({
          zone_id: "z-active-2",
          zone_name: "Westlands",
          fee_cents: 40_000,
        }),
      ),
    });
    assert.equal(first.status === "ready" && first.feeCents, 25_000);
    assert.equal(second.status === "ready" && second.feeCents, 40_000);
    assert.equal(second.status === "ready" && second.totalCents, 140_000);
  });

  it("a subtotal change does not reuse a quote answered for another subtotal", () => {
    const state = deriveQuoteState({
      request: { ...request, subtotalCents: 600_000 },
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(validRow()), // answered for 100_000
    });
    assert.equal(state.status, "loading");
  });

  it("uses whatever fee the database returns, including free, with no local rule applied", () => {
    // base fee 30_000 and the subtotal is below the free-over threshold, yet the database
    // says 0: the helper must report 0, not recompute 30_000.
    const state = deriveQuoteState({
      request,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(validRow({ fee_cents: 0 })),
    });
    assert.equal(state.status === "ready" && state.feeCents, 0);
    assert.equal(state.status === "ready" && state.totalCents, 100_000);
  });

  it("a rejected selection is rejected, never free delivery", () => {
    const state = deriveQuoteState({
      request,
      isPending: false,
      error: null,
      result: toDeliverySelectionResult(
        validRow({
          is_valid: false,
          error_code: "below_minimum_order",
          error_message: "db text",
          fee_cents: null,
          min_order_cents: 150_000,
        }),
      ),
    });
    assert.equal(state.status, "rejected");
    if (state.status !== "rejected") return;
    assert.equal(state.code, "below_minimum_order");
    assert.equal(state.minOrderCents, 150_000);
    assert.equal(
      quoteBlockerMessage(state, { minOrderLabel: "KES 1,500.00" }),
      "Delivery needs an order of at least KES 1,500.00. Add more items to continue.",
    );
  });

  it("is idle with no request, loading while pending, and error on transport failure", () => {
    assert.equal(
      deriveQuoteState({
        request: null,
        isPending: true,
        error: null,
        result: undefined,
      }).status,
      "idle",
    );
    assert.equal(
      deriveQuoteState({
        request,
        isPending: true,
        error: null,
        result: undefined,
      }).status,
      "loading",
    );
    const failed = deriveQuoteState({
      request,
      isPending: false,
      error: new Error("network"),
      result: undefined,
    });
    assert.equal(failed.status, "error");
    assert.equal(
      quoteBlockerMessage(failed),
      "We couldn't confirm the delivery fee. Please try again.",
    );
  });

  it("only a ready or idle quote leaves checkout unblocked", () => {
    assert.equal(quoteBlockerMessage({ status: "idle" }), null);
    assert.notEqual(quoteBlockerMessage({ status: "loading" }), null);
  });
});

// ---------------------------------------------------------------------------------------- errors

describe("delivery error messages", () => {
  it("has a customer-facing message for every required code", () => {
    for (const code of ALL_CODES) {
      assert.equal(isDeliveryErrorCode(code), true, code);
      const message = deliveryErrorMessage(code);
      assert.ok(message.length > 0, code);
      // Never SQL, identifiers or the raw code.
      assert.doesNotMatch(
        message,
        /_|P0001|exception|violates|function/i,
        code,
      );
    }
  });

  it("maps specific codes to the right advice", () => {
    assert.match(deliveryErrorMessage("zone_required"), /delivery area/i);
    assert.match(deliveryErrorMessage("slot_full"), /filled up|full/i);
    assert.match(deliveryErrorMessage("slot_in_past"), /too soon/i);
    assert.match(deliveryErrorMessage("slot_too_far"), /too far/i);
    assert.match(deliveryErrorMessage("method_inactive"), /right now/i);
  });

  it("uses the formatted minimum for below_minimum_order when it is known", () => {
    assert.match(
      deliveryErrorMessage("below_minimum_order", {
        minOrderLabel: "KES 500.00",
      }),
      /KES 500\.00/,
    );
    assert.match(deliveryErrorMessage("below_minimum_order"), /minimum order/i);
  });

  it("recognises only delivery codes", () => {
    assert.equal(isDeliveryErrorCode("slot_full"), true);
    assert.equal(isDeliveryErrorCode("insufficient_stock"), false);
    assert.equal(isDeliveryErrorCode("toString"), false);
    assert.equal(isDeliveryErrorCode(null), false);
  });

  it("groups codes by the part of checkout to reset", () => {
    assert.equal(deliveryErrorScope("slot_full"), "slot");
    assert.equal(deliveryErrorScope("slot_closed"), "slot");
    assert.equal(deliveryErrorScope("zone_inactive"), "zone");
    assert.equal(deliveryErrorScope("method_unknown"), "method");
    assert.equal(deliveryErrorScope("below_minimum_order"), "order");
  });
});

// ----------------------------------------------------------------------------------------- slots

function availability(
  overrides: Partial<DeliverySlotAvailabilityRow> &
    Pick<DeliverySlotAvailabilityRow, "template_id">,
): DeliverySlotAvailabilityRow {
  return {
    slot_date: "2026-10-10",
    label: "Morning",
    start_time: "08:00:00",
    end_time: "11:00:00",
    capacity: 10,
    booked_count: 2,
    remaining: 8,
    is_available: true,
    ...overrides,
  };
}

function option(id: string, date: string, startTime: string, endTime: string) {
  return { id, date, startTime, endTime, label: id };
}

const options = [
  option("open", "2026-10-10", "08:00:00", "11:00:00"),
  option("full", "2026-10-10", "11:00:00", "14:00:00"),
  option("zero", "2026-10-10", "14:00:00", "17:00:00"),
  option("override-closed", "2026-10-10", "17:00:00", "20:00:00"),
  option("unlimited", "2026-10-11", "08:00:00", "11:00:00"),
];

const rows: DeliverySlotAvailabilityRow[] = [
  availability({ template_id: "t1" }),
  availability({
    template_id: "t2",
    start_time: "11:00:00",
    end_time: "14:00:00",
    capacity: 5,
    booked_count: 5,
    remaining: 0,
    is_available: false,
  }),
  availability({
    template_id: "t3",
    start_time: "14:00:00",
    end_time: "17:00:00",
    capacity: 0,
    booked_count: 0,
    remaining: 0,
    is_available: false,
  }),
  // no row for 17:00-20:00 on the 10th: the database omits windows closed by an override
  availability({
    template_id: "t1",
    slot_date: "2026-10-11",
    capacity: null,
    booked_count: 40,
    remaining: null,
    is_available: true,
  }),
];

describe("slot choices", () => {
  const choices = buildSlotChoices(options, rows);
  const byId = (id: string) => choices.find((choice) => choice.id === id);

  it("represents available slots, with places left taken from the database", () => {
    assert.equal(byId("open")?.status, "available");
    assert.equal(byId("open")?.remaining, 8);
    assert.equal(isSlotSelectable(byId("open")!), true);
  });

  it("an unlimited slot is available with no remaining count", () => {
    assert.equal(byId("unlimited")?.status, "available");
    assert.equal(byId("unlimited")?.remaining, null);
  });

  it("a full slot is not selectable", () => {
    assert.equal(byId("full")?.status, "full");
    assert.equal(isSlotSelectable(byId("full")!), false);
  });

  it("closed slots (capacity 0, or closed by an override) are not selectable", () => {
    assert.equal(byId("zero")?.status, "closed");
    assert.equal(byId("override-closed")?.status, "closed");
    assert.equal(isSlotSelectable(byId("zero")!), false);
    assert.equal(isSlotSelectable(byId("override-closed")!), false);
  });

  it("hides closed slots but keeps full ones visible", () => {
    assert.deepEqual(
      visibleSlotChoices(choices).map((choice) => choice.id),
      ["open", "full", "unlimited"],
    );
  });

  it("offers nothing until availability has loaded", () => {
    assert.deepEqual(buildSlotChoices(options, undefined), []);
  });

  it("matches windows whether times come as HH:MM or HH:MM:SS", () => {
    const shortForm = buildSlotChoices(
      [option("o", "2026-10-10", "08:00", "11:00")],
      rows,
    );
    assert.equal(shortForm[0]?.status, "available");
  });

  it("keeps the caller's own fields on each choice", () => {
    assert.equal(byId("open")?.label, "open");
  });

  it("derives the date range to ask availability for", () => {
    assert.deepEqual(slotDateRange(options), {
      from: "2026-10-10",
      to: "2026-10-11",
    });
    assert.equal(slotDateRange([]), null);
  });
});

describe("slot revalidation", () => {
  const choices = buildSlotChoices(options, rows);

  it("keeps a selection that is still available", () => {
    const result = resolveSelectedSlot(choices, "open");
    assert.equal(result.slot?.id, "open");
    assert.equal(result.invalid, false);
  });

  it("has no slot and nothing to explain when nothing was selected", () => {
    assert.deepEqual(resolveSelectedSlot(choices, null), {
      slot: null,
      invalid: false,
    });
  });

  it("clears a selection that has become full or closed, and flags it", () => {
    assert.deepEqual(resolveSelectedSlot(choices, "full"), {
      slot: null,
      invalid: true,
    });
    assert.deepEqual(resolveSelectedSlot(choices, "zero"), {
      slot: null,
      invalid: true,
    });
  });

  it("clears a selection that is no longer offered at all", () => {
    assert.deepEqual(resolveSelectedSlot(choices, "gone"), {
      slot: null,
      invalid: true,
    });
  });

  it("revalidates when availability changes: a slot that fills up stops being selectable", () => {
    const filled = rows.map((row) =>
      row.template_id === "t1" && row.slot_date === "2026-10-10"
        ? { ...row, booked_count: 10, remaining: 0, is_available: false }
        : row,
    );
    const refreshed = buildSlotChoices(options, filled);
    assert.deepEqual(resolveSelectedSlot(refreshed, "open"), {
      slot: null,
      invalid: true,
    });
  });
});

describe("duplicate slot templates", () => {
  // A generic template (position 1, capacity 2, already full) and a weekday-specific duplicate
  // of the same window (position 5, capacity 10). create_order() books against the lowest
  // position, so the window is FULL even though the shadowed template has room.
  const winner = availability({
    template_id: "generic",
    capacity: 2,
    booked_count: 2,
    remaining: 0,
    is_available: false,
  });
  const shadowed = availability({
    template_id: "shadow",
    capacity: 10,
    booked_count: 2,
    remaining: 8,
    is_available: true,
  });
  const window = [option("w", "2026-10-10", "08:00:00", "11:00:00")];

  it("a shadowed template listed after the winner does not make the window look usable", () => {
    // Older database responses listed both rows, ordered by position.
    const choices = buildSlotChoices(window, [winner, shadowed]);
    assert.equal(choices[0]?.status, "full");
    assert.equal(isSlotSelectable(choices[0]!), false);
  });

  it("the winning template's capacity is used, not the larger shadowed one", () => {
    const choices = buildSlotChoices(window, [winner, shadowed]);
    assert.equal(choices[0]?.remaining, 0);
  });

  it("offers a duplicated window once, keeping the first (lowest position) option", () => {
    const duplicated = [
      option("generic_option", "2026-10-10", "08:00:00", "11:00:00"),
      option("shadow_option", "2026-10-10", "08:00", "11:00"),
      option("other_day", "2026-10-11", "08:00:00", "11:00:00"),
      option("other_window", "2026-10-10", "11:00:00", "14:00:00"),
    ];
    assert.deepEqual(
      dedupeSlotWindows(duplicated).map((entry) => entry.id),
      ["generic_option", "other_day", "other_window"],
    );
  });

  it("leaves distinct windows alone", () => {
    assert.equal(dedupeSlotWindows(options).length, options.length);
  });
});
