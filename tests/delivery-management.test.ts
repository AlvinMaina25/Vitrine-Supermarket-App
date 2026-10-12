import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import type {
  AdminDeliveryMethod,
  AdminDeliveryZone,
  AdminDeliveryZoneFee,
} from "../src/features/admin/delivery-config-result.ts";
import {
  ADMIN_DELIVERY_REASONS,
  AdminDeliveryError,
  deliveryReasonMessage,
} from "../src/features/admin/delivery-error.ts";
import {
  DEFAULT_DELIVERY_TAB,
  DELIVERY_SAVE_FAILED,
  DELIVERY_TABS,
  activeDeliveryTab,
  activeSlotRange,
  addDays,
  buildMethodFromDraft,
  buildSlotOverrideFromDraft,
  buildSlotTemplateFromDraft,
  buildZoneFeeFromDraft,
  buildZoneFromDraft,
  describeDeliveryActionError,
  describeSlotCapacity,
  emptySlotOverrideDraft,
  emptySlotTemplateDraft,
  emptyZoneDraft,
  emptyZoneFeeDraft,
  formatTimeHm,
  methodDraftChanged,
  methodDraftFromMethod,
  noActiveZonesWarning,
  parseCapacityText,
  parseDeliveryParams,
  parseShillingsText,
  parsePositionText,
  parseTimeText,
  parseWeekdayText,
  shiftSlotRange,
  slotOverrideDraftFor,
  slotTemplateDraftFromTemplate,
  toSlotsListArgs,
  townsFromText,
  weekRange,
  weekdayLabel,
  withDeliveryTab,
  withSlotRange,
  zoneDraftFromZone,
  zoneFeeDraftFromFee,
} from "../src/features/admin/delivery-management.ts";

const method: AdminDeliveryMethod = {
  code: "standard",
  label: "Standard",
  description: null,
  base_fee_cents: 25000,
  free_over_cents: null,
  min_order_cents: 0,
  requires_slot: true,
  requires_address: true,
  eta_label: null,
  position: 0,
  is_active: true,
};

describe("tabs and date range", () => {
  it("defaults to methods and keeps only valid tabs", () => {
    assert.deepEqual(DELIVERY_TABS, ["methods", "zones", "fees", "slots"]);
    assert.equal(DEFAULT_DELIVERY_TAB, "methods");
    assert.deepEqual(parseDeliveryParams({}), {});
    assert.deepEqual(parseDeliveryParams({ tab: "zones" }), { tab: "zones" });
    assert.deepEqual(parseDeliveryParams({ tab: "fees" }), { tab: "fees" });
    assert.deepEqual(parseDeliveryParams({ tab: "methods" }), {});
    assert.deepEqual(parseDeliveryParams({ tab: "bogus" }), {});
    assert.equal(activeDeliveryTab({}), "methods");
    assert.equal(activeDeliveryTab({ tab: "slots" }), "slots");
  });

  it("keeps a range only when both dates are valid and at most 31 days", () => {
    assert.deepEqual(
      parseDeliveryParams({ from: "2026-10-05", to: "2026-10-11" }),
      {
        from: "2026-10-05",
        to: "2026-10-11",
      },
    );
    for (const search of [
      { from: "2026-10-05" },
      { to: "2026-10-11" },
      { from: "2026-10-11", to: "2026-10-05" },
      { from: "2026-10-01", to: "2026-11-05" },
      { from: "2026-02-30", to: "2026-03-05" },
      { from: 5, to: 6 },
    ]) {
      assert.deepEqual(parseDeliveryParams(search), {}, JSON.stringify(search));
    }
  });

  it("switching tab keeps the range; setting a range keeps the tab", () => {
    const range = { from: "2026-10-05", to: "2026-10-11" };
    const a = withSlotRange({ tab: "slots" }, range);
    assert.deepEqual(a, { tab: "slots", ...range });
    assert.deepEqual(withDeliveryTab(a, "zones"), { tab: "zones", ...range });
    assert.deepEqual(withDeliveryTab(a, "methods"), range);
  });

  it("computes Monday to Sunday weeks, including from a Sunday", () => {
    assert.deepEqual(weekRange("2026-10-07"), {
      from: "2026-10-05",
      to: "2026-10-11",
    }); // Wed
    assert.deepEqual(weekRange("2026-10-05"), {
      from: "2026-10-05",
      to: "2026-10-11",
    }); // Mon
    assert.deepEqual(weekRange("2026-10-11"), {
      from: "2026-10-05",
      to: "2026-10-11",
    }); // Sun
    assert.deepEqual(weekRange("2026-12-31"), {
      from: "2026-12-28",
      to: "2027-01-03",
    });
    assert.equal(addDays("2026-02-28", 1), "2026-03-01");
    assert.equal(addDays("2026-03-01", -1), "2026-02-28");
  });

  it("uses the current week by default and shifts by the range length", () => {
    assert.deepEqual(activeSlotRange({}, "2026-10-07"), {
      from: "2026-10-05",
      to: "2026-10-11",
    });
    const picked = { from: "2026-10-01", to: "2026-10-03" };
    assert.deepEqual(activeSlotRange(picked, "2026-10-07"), picked);
    assert.deepEqual(shiftSlotRange(picked, 1), {
      from: "2026-10-04",
      to: "2026-10-06",
    });
    assert.deepEqual(shiftSlotRange(picked, -1), {
      from: "2026-09-28",
      to: "2026-09-30",
    });
    assert.deepEqual(shiftSlotRange(weekRange("2026-10-07"), 1), {
      from: "2026-10-12",
      to: "2026-10-18",
    });
  });

  it("builds the RPC arguments from the screen state", () => {
    assert.deepEqual(toSlotsListArgs({}, "2026-10-07"), {
      p_from: "2026-10-05",
      p_to: "2026-10-11",
    });
    assert.deepEqual(
      toSlotsListArgs({ from: "2026-10-01", to: "2026-10-02" }, "2026-10-07"),
      {
        p_from: "2026-10-01",
        p_to: "2026-10-02",
      },
    );
  });
});

describe("whole-number and time parsing", () => {
  it("turns shillings into whole cents", () => {
    assert.deepEqual(parseShillingsText(" 250 ", "The fee", false), {
      ok: true,
      value: 25000,
    });
    assert.deepEqual(parseShillingsText("250.50", "The fee", false), {
      ok: true,
      value: 25050,
    });
    assert.deepEqual(parseShillingsText("0", "The fee", false), {
      ok: true,
      value: 0,
    });
    assert.deepEqual(parseShillingsText("21474836.47", "The fee", false), {
      ok: true,
      value: 2147483647,
    });
  });

  it("rejects signs, exponents, units, extra decimals and overflow", () => {
    for (const bad of [
      "-1",
      "+5",
      "1e3",
      "KES 5",
      "0x10",
      "٣",
      "２",
      "1.234",
      "1,00",
      "5.",
    ]) {
      assert.equal(parseShillingsText(bad, "The fee", false).ok, false, bad);
    }
    assert.equal(parseShillingsText("21474836.48", "The fee", false).ok, false);
    assert.equal(
      parseShillingsText("99999999999999999999", "The fee", false).ok,
      false,
    );
  });

  it("blank is null when optional and an error when required", () => {
    assert.deepEqual(parseShillingsText("  ", "The fee", true), {
      ok: true,
      value: null,
    });
    const required = parseShillingsText("", "The fee", false);
    assert.ok(!required.ok);
    assert.match(required.error, /required/);
  });

  it("parses capacity, position, weekday and times", () => {
    assert.deepEqual(parseCapacityText(""), { ok: true, value: null });
    assert.deepEqual(parseCapacityText("0"), { ok: true, value: 0 });
    assert.equal(parseCapacityText("100001").ok, false);
    assert.equal(parseCapacityText("2.5").ok, false);
    assert.deepEqual(parsePositionText("1000000"), {
      ok: true,
      value: 1000000,
    });
    assert.equal(parsePositionText("1000001").ok, false);
    assert.deepEqual(parseWeekdayText(""), { ok: true, value: null });
    assert.deepEqual(parseWeekdayText("0"), { ok: true, value: 0 });
    assert.deepEqual(parseWeekdayText("6"), { ok: true, value: 6 });
    assert.equal(parseWeekdayText("7").ok, false);
    assert.equal(parseWeekdayText("mon").ok, false);
    assert.deepEqual(parseTimeText("08:00", "The start time"), {
      ok: true,
      value: "08:00:00",
    });
    assert.equal(parseTimeText("8:00", "The start time").ok, false);
    assert.equal(parseTimeText("24:00", "The start time").ok, false);
  });

  it("formats labels for display", () => {
    assert.equal(weekdayLabel(null), "Every day");
    assert.equal(weekdayLabel(0), "Sunday");
    assert.equal(weekdayLabel(6), "Saturday");
    assert.equal(formatTimeHm("08:00:00"), "08:00");
    assert.equal(describeSlotCapacity(null), "Unlimited");
    assert.equal(describeSlotCapacity(0), "Closed");
    assert.equal(describeSlotCapacity(12), "12");
  });
});

describe("zone drafts", () => {
  const zone: AdminDeliveryZone = {
    id: "z1",
    code: "nairobi",
    name: "Nairobi",
    description: null,
    county: "Nairobi",
    towns: ["Westlands", "Kilimani"],
    position: 2,
    is_active: true,
  };

  it("round-trips a zone through a draft", () => {
    const draft = zoneDraftFromZone(zone);
    assert.equal(draft.towns, "Westlands\nKilimani");
    const r = buildZoneFromDraft("z1", draft);
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_zone_id: "z1",
      p_code: null,
      p_name: "Nairobi",
      p_county: "Nairobi",
      p_towns: ["Westlands", "Kilimani"],
      p_description: null,
      p_position: 2,
    });
  });

  it("builds a new zone from comma or line separated towns", () => {
    assert.deepEqual(townsFromText("a, b\nc,,"), ["a", " b", "c", "", ""]);
    const r = buildZoneFromDraft(null, {
      ...emptyZoneDraft(),
      code: "thika",
      name: "Thika",
      towns: "Thika Town, thika town\nJuja",
    });
    assert.ok(r.ok);
    assert.equal(r.args.p_code, "thika");
    assert.deepEqual(r.args.p_towns, ["Thika Town", "Juja"]);
    assert.equal(r.args.p_position, null);
  });

  it("reports parse and builder errors together", () => {
    const r = buildZoneFromDraft(null, {
      ...emptyZoneDraft(),
      position: "1.5",
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "code",
      "name",
      "position",
    ]);
  });
});

describe("zone fee drafts", () => {
  const fee: AdminDeliveryZoneFee = {
    id: "f1",
    zone_id: "z1",
    method_code: "standard",
    fee_cents: 30000,
    free_over_cents: null,
    min_order_cents: 0,
    is_active: true,
    zone_code: "nairobi",
    zone_name: "Nairobi",
    method_label: "Standard",
  };

  it("round-trips a rule and sends the cents for the shillings typed", () => {
    const draft = zoneFeeDraftFromFee(fee);
    assert.deepEqual(draft, {
      zoneId: "z1",
      methodCode: "standard",
      fee: "300",
      freeOver: "",
      minOrder: "0",
    });
    const r = buildZoneFeeFromDraft("f1", draft);
    assert.ok(r.ok);
    assert.equal(r.args.p_fee_cents, 30000);
    assert.equal(r.args.p_free_over_cents, null);
    assert.equal(r.args.p_min_order_cents, 0);
  });

  it("creates a rule with blank minimum as null and rejects bad amounts", () => {
    const create = buildZoneFeeFromDraft(null, {
      ...emptyZoneFeeDraft("z1", "express"),
      fee: "450",
      freeOver: "8,000",
    });
    assert.ok(create.ok);
    assert.deepEqual(create.args, {
      p_fee_id: null,
      p_zone_id: "z1",
      p_method_code: "express",
      p_fee_cents: 45000,
      p_free_over_cents: 800000,
      p_min_order_cents: null,
    });
    const bad = buildZoneFeeFromDraft(null, {
      ...emptyZoneFeeDraft("z1", "express"),
      fee: "450.555",
      freeOver: "-1",
      minOrder: "1e3",
    });
    assert.ok(!bad.ok);
    assert.deepEqual(Object.keys(bad.errors).sort(), [
      "fee",
      "freeOver",
      "minOrder",
    ]);
    assert.ok(!buildZoneFeeFromDraft(null, emptyZoneFeeDraft()).ok);
  });
});

describe("method drafts", () => {
  it("detects changes and requires a reason when the active flag changes", () => {
    const draft = methodDraftFromMethod(method);
    assert.equal(methodDraftChanged(method, draft), false);
    assert.equal(
      methodDraftChanged(method, { ...draft, baseFee: " 250.01 " }),
      true,
    );
    assert.equal(
      methodDraftChanged(method, { ...draft, isActive: false }),
      true,
    );
    const noReason = buildMethodFromDraft(method, {
      ...draft,
      isActive: false,
    });
    assert.ok(!noReason.ok);
    assert.ok(noReason.errors.reason);
    const ok = buildMethodFromDraft(method, {
      ...draft,
      isActive: false,
      reason: "paused",
    });
    assert.ok(ok.ok);
    assert.equal(ok.args.p_is_active, false);
    assert.equal(ok.args.p_reason, "paused");
  });

  it("maps amount errors to the matching fields", () => {
    const r = buildMethodFromDraft(method, {
      ...methodDraftFromMethod(method),
      baseFee: "",
      freeOver: "12.555",
      minOrder: "-3",
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "fee",
      "freeOver",
      "minOrder",
    ]);
  });

  it("sends a blank free-over as null and the cents for the shillings typed", () => {
    const r = buildMethodFromDraft(method, {
      ...methodDraftFromMethod(method),
      baseFee: "250",
      freeOver: "",
    });
    assert.ok(r.ok);
    assert.equal(r.args.p_base_fee_cents, 25000);
    assert.equal(r.args.p_free_over_cents, null);
  });
});

describe("slot template and override drafts", () => {
  it("round-trips a template and builds create args from a fresh draft", () => {
    const draft = slotTemplateDraftFromTemplate({
      id: "t1",
      label: "Morning",
      start_time: "08:00:00",
      end_time: "12:00:00",
      day_of_week: 3,
      capacity: null,
      position: 1,
      is_active: true,
    });
    assert.deepEqual(draft, {
      label: "Morning",
      startTime: "08:00",
      endTime: "12:00",
      dayOfWeek: "3",
      capacity: "",
      position: "1",
    });
    const r = buildSlotTemplateFromDraft("t1", draft);
    assert.ok(r.ok);
    assert.equal(r.args.p_start_time, "08:00:00");
    assert.equal(r.args.p_day_of_week, 3);
    assert.equal(r.args.p_capacity, null);

    const created = buildSlotTemplateFromDraft(null, {
      ...emptySlotTemplateDraft(),
      label: "Evening",
      startTime: "16:00",
      endTime: "20:00",
      capacity: "0",
    });
    assert.ok(created.ok);
    assert.equal(created.args.p_capacity, 0);
    assert.equal(created.args.p_day_of_week, null);
  });

  it("reports time, weekday and capacity problems", () => {
    const r = buildSlotTemplateFromDraft(null, {
      ...emptySlotTemplateDraft(),
      label: "X",
      startTime: "9am",
      endTime: "12:00",
      dayOfWeek: "9",
      capacity: "-1",
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "capacity",
      "weekday",
      "window",
    ]);
    const backwards = buildSlotTemplateFromDraft(null, {
      ...emptySlotTemplateDraft(),
      label: "X",
      startTime: "12:00",
      endTime: "08:00",
    });
    assert.ok(!backwards.ok);
    assert.ok(backwards.errors.window);
  });

  it("finds an override's note and builds override args", () => {
    const slot = {
      slot_date: "2026-10-08",
      template_id: "t1",
      label: "Morning",
      start_time: "08:00:00",
      end_time: "12:00:00",
      position: 0,
      template_active: true,
      template_capacity: 10,
      override_capacity: 4,
      override_closed: false,
      effective_capacity: 4,
      is_closed: false,
      booked_count: 1,
    };
    const overrides = [
      {
        id: "o1",
        template_id: "t1",
        slot_date: "2026-10-08",
        capacity: 4,
        is_active: true,
        note: "market day",
        template_label: "Morning",
        start_time: "08:00:00",
        end_time: "12:00:00",
        is_closed: false,
        booked_count: 1,
      },
    ];
    const draft = slotOverrideDraftFor(slot, overrides);
    assert.deepEqual(draft, {
      capacity: "4",
      closed: false,
      note: "market day",
    });
    assert.deepEqual(
      slotOverrideDraftFor({ ...slot, slot_date: "2026-10-09" }, overrides)
        .note,
      "",
    );
    const r = buildSlotOverrideFromDraft("t1", "2026-10-08", draft);
    assert.ok(r.ok);
    assert.equal(r.args.p_capacity, 4);
    assert.equal(r.args.p_note, "market day");
  });

  it("refuses an empty override and closed-with-capacity, and flags decimal capacity", () => {
    assert.ok(
      !buildSlotOverrideFromDraft("t1", "2026-10-08", emptySlotOverrideDraft())
        .ok,
    );
    const both = buildSlotOverrideFromDraft("t1", "2026-10-08", {
      capacity: "3",
      closed: true,
      note: "",
    });
    assert.ok(!both.ok);
    assert.ok(both.errors.capacity);
    const decimal = buildSlotOverrideFromDraft("t1", "2026-10-08", {
      capacity: "2.5",
      closed: false,
      note: "x",
    });
    assert.ok(!decimal.ok);
    assert.ok(decimal.errors.capacity);
    const closed = buildSlotOverrideFromDraft("t1", "2026-10-08", {
      capacity: "",
      closed: true,
      note: "",
    });
    assert.ok(closed.ok);
    assert.equal(closed.args.p_is_closed, true);
  });
});

describe("method draft change detection", () => {
  it("treats the same amount typed differently as unchanged", () => {
    const draft = methodDraftFromMethod(method);
    assert.equal(draft.baseFee, "250");
    assert.equal(
      methodDraftChanged(method, { ...draft, baseFee: "250.00" }),
      false,
    );
    assert.equal(
      methodDraftChanged(method, { ...draft, baseFee: "250.0" }),
      false,
    );
    assert.equal(
      methodDraftChanged(method, { ...draft, freeOver: "1,000" }),
      true,
    );
    assert.equal(
      methodDraftChanged(method, { ...draft, baseFee: "abc" }),
      true,
    );
  });
});

describe("no active zones warning", () => {
  const zone = (is_active: boolean): AdminDeliveryZone => ({
    id: "z",
    code: "nairobi",
    name: "Nairobi",
    description: null,
    county: null,
    towns: [],
    position: 0,
    is_active,
  });

  it("warns when no zone exists, or none is active, and is silent otherwise", () => {
    assert.equal(
      noActiveZonesWarning([]),
      "Address delivery cannot be ordered until a zone exists.",
    );
    assert.match(
      noActiveZonesWarning([zone(false)]) ?? "",
      /until a zone is active/,
    );
    assert.equal(noActiveZonesWarning([zone(false), zone(true)]), null);
  });
});

describe("describeDeliveryActionError", () => {
  it("maps every backend refusal code to its friendly message", () => {
    for (const reason of ADMIN_DELIVERY_REASONS) {
      const message = describeDeliveryActionError(
        new AdminDeliveryError(reason),
      );
      assert.equal(message, deliveryReasonMessage(reason));
      assert.ok(message.length > 10, reason);
      assert.doesNotMatch(
        message,
        /\b[a-z]+_[a-z_]+\b|sql|postgres|pgrst/i,
        reason,
      );
    }
  });

  it("explains a refused admin check and hides unknown failures", () => {
    assert.match(
      describeDeliveryActionError(new AdminAccessError("nope")),
      /nope/,
    );
    const generic = describeDeliveryActionError(
      new Error('relation "x" does not exist'),
    );
    assert.equal(generic, DELIVERY_SAVE_FAILED);
    assert.equal(describeDeliveryActionError("boom"), DELIVERY_SAVE_FAILED);
  });
});
