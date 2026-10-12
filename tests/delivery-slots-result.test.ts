import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildClearDeliverySlotOverrideArgs,
  buildSaveDeliverySlotOverrideArgs,
  toAdminClearDeliverySlotOverrideResult,
  toAdminSaveDeliverySlotOverrideResult,
} from "../src/features/admin/delivery-slot-override-result.ts";
import {
  buildSaveDeliverySlotTemplateArgs,
  buildSetDeliverySlotTemplateActiveArgs,
  toAdminSaveDeliverySlotTemplateResult,
  toAdminSetDeliverySlotTemplateActiveResult,
} from "../src/features/admin/delivery-slot-template-result.ts";
import {
  buildListDeliverySlotsArgs,
  daysBetween,
  toAdminDeliverySlotList,
} from "../src/features/admin/delivery-slots-result.ts";

const template = {
  id: "t1",
  label: "Morning",
  start_time: "08:00:00",
  end_time: "12:00:00",
  day_of_week: null,
  capacity: 10,
  position: 0,
  is_active: true,
};
const overrideRow = {
  id: "o1",
  template_id: "t1",
  slot_date: "2026-10-08",
  capacity: 3,
  is_active: true,
  note: null,
};
const list = {
  from: "2026-10-05",
  to: "2026-10-11",
  templates: [template],
  overrides: [
    {
      ...overrideRow,
      template_label: "Morning",
      start_time: "08:00:00",
      end_time: "12:00:00",
      is_closed: false,
      booked_count: 2,
    },
  ],
  slots: [
    {
      slot_date: "2026-10-08",
      template_id: "t1",
      label: "Morning",
      start_time: "08:00:00",
      end_time: "12:00:00",
      position: 0,
      template_active: true,
      template_capacity: 10,
      override_capacity: 3,
      override_closed: false,
      effective_capacity: 3,
      is_closed: false,
      booked_count: 2,
    },
  ],
};

describe("toAdminDeliverySlotList", () => {
  it("parses templates, overrides and slots", () => {
    const l = toAdminDeliverySlotList(list);
    assert.equal(l.from, "2026-10-05");
    assert.equal(l.templates[0]?.capacity, 10);
    assert.equal(l.overrides[0]?.booked_count, 2);
    assert.equal(l.slots[0]?.effective_capacity, 3);
  });

  it("keeps unlimited (null) distinct from closed (0)", () => {
    const slot = list.slots[0];
    assert.ok(slot);
    const l = toAdminDeliverySlotList({
      ...list,
      slots: [
        {
          ...slot,
          effective_capacity: null,
          override_capacity: null,
          template_capacity: null,
        },
        { ...slot, effective_capacity: 0, is_closed: true },
      ],
    });
    assert.equal(l.slots[0]?.effective_capacity, null);
    assert.equal(l.slots[1]?.effective_capacity, 0);
  });

  it("rejects malformed payloads", () => {
    const slot = list.slots[0];
    assert.ok(slot);
    for (const bad of [
      null,
      [],
      {},
      { ...list, from: "2026-02-30" },
      { ...list, templates: "x" },
      { ...list, templates: [{ ...template, day_of_week: 7 }] },
      { ...list, templates: [{ ...template, start_time: "8am" }] },
      { ...list, slots: [{ ...slot, booked_count: -1 }] },
      { ...list, slots: [{ ...slot, is_closed: "no" }] },
    ]) {
      assert.throws(() => toAdminDeliverySlotList(bad), /unexpected response/);
    }
  });
});

describe("buildListDeliverySlotsArgs", () => {
  it("accepts a valid range up to 31 days", () => {
    const r = buildListDeliverySlotsArgs("2026-10-01", "2026-11-01");
    assert.ok(r.ok);
    assert.deepEqual(r.args, { p_from: "2026-10-01", p_to: "2026-11-01" });
    assert.ok(buildListDeliverySlotsArgs("2026-10-05", "2026-10-05").ok);
    assert.equal(daysBetween("2026-10-01", "2026-11-01"), 31);
  });

  it("rejects reversed, malformed and too-large ranges", () => {
    assert.ok(!buildListDeliverySlotsArgs("2026-10-06", "2026-10-05").ok);
    assert.ok(!buildListDeliverySlotsArgs("nope", "2026-10-05").ok);
    const big = buildListDeliverySlotsArgs("2026-10-01", "2026-11-02");
    assert.ok(!big.ok);
    assert.match(big.errors.range ?? "", /31/);
  });
});

describe("slot templates", () => {
  it("parses results", () => {
    const saved = toAdminSaveDeliverySlotTemplateResult({
      changed: true,
      created: true,
      template,
    });
    assert.equal(saved.template.label, "Morning");
    const status = {
      changed: true,
      template_id: "t1",
      previous_is_active: true,
      is_active: false,
      upcoming_booked_orders: 4,
    };
    assert.deepEqual(
      toAdminSetDeliverySlotTemplateActiveResult(status),
      status,
    );
    assert.throws(
      () =>
        toAdminSetDeliverySlotTemplateActiveResult({
          ...status,
          upcoming_booked_orders: null,
        }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminSaveDeliverySlotTemplateResult({ changed: true }),
      /unexpected/,
    );
  });

  const input = {
    templateId: null,
    label: " Morning ",
    startTime: "08:00",
    endTime: "12:30",
    dayOfWeek: null,
    capacity: null,
    position: null,
  };

  it("builds args with HH:MM:SS times, trimmed label and nulls kept", () => {
    const r = buildSaveDeliverySlotTemplateArgs(input);
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_template_id: null,
      p_label: "Morning",
      p_start_time: "08:00:00",
      p_end_time: "12:30:00",
      p_day_of_week: null,
      p_capacity: null,
      p_position: null,
    });
    const sunday = buildSaveDeliverySlotTemplateArgs({
      ...input,
      dayOfWeek: 0,
      capacity: 0,
    });
    assert.ok(sunday.ok);
    assert.equal(sunday.args.p_day_of_week, 0);
    assert.equal(sunday.args.p_capacity, 0);
  });

  it("rejects bad label, window, weekday, capacity and position", () => {
    const r = buildSaveDeliverySlotTemplateArgs({
      ...input,
      label: "",
      startTime: "12:00",
      endTime: "12:00",
      dayOfWeek: 7,
      capacity: 100001,
      position: 1_000_001,
    });
    assert.ok(!r.ok);
    assert.deepEqual(Object.keys(r.errors).sort(), [
      "capacity",
      "label",
      "position",
      "weekday",
      "window",
    ]);
    assert.ok(
      !buildSaveDeliverySlotTemplateArgs({ ...input, startTime: "25:00" }).ok,
    );
    assert.ok(
      !buildSaveDeliverySlotTemplateArgs({ ...input, label: "x".repeat(81) })
        .ok,
    );
    assert.ok(
      !buildSaveDeliverySlotTemplateArgs({ ...input, capacity: 1.5 }).ok,
    );
  });

  it("requires a reason to activate or deactivate", () => {
    const r = buildSetDeliverySlotTemplateActiveArgs("t1", false, " holiday ");
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_template_id: "t1",
      p_is_active: false,
      p_reason: "holiday",
    });
    assert.ok(!buildSetDeliverySlotTemplateActiveArgs("t1", true, " ").ok);
  });
});

describe("slot overrides", () => {
  it("parses save and clear results", () => {
    const saved = toAdminSaveDeliverySlotOverrideResult({
      changed: true,
      created: true,
      override: overrideRow,
      booked_count: 2,
    });
    assert.equal(saved.booked_count, 2);
    assert.equal(saved.override.capacity, 3);
    const cleared = {
      changed: true,
      override_id: "o1",
      template_id: "t1",
      slot_date: "2026-10-08",
      previous_capacity: null,
      previous_is_closed: true,
    };
    assert.deepEqual(toAdminClearDeliverySlotOverrideResult(cleared), cleared);
    assert.throws(
      () =>
        toAdminClearDeliverySlotOverrideResult({
          ...cleared,
          slot_date: "bad",
        }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminSaveDeliverySlotOverrideResult({
          changed: true,
          created: true,
          override: {},
        }),
      /unexpected/,
    );
  });

  const input = {
    templateId: "t1",
    slotDate: "2026-10-08",
    capacity: 5,
    closed: false,
    note: " busy day ",
  };

  it("builds args", () => {
    const r = buildSaveDeliverySlotOverrideArgs(input);
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_template_id: "t1",
      p_slot_date: "2026-10-08",
      p_capacity: 5,
      p_is_closed: false,
      p_note: "busy day",
    });
    const closed = buildSaveDeliverySlotOverrideArgs({
      ...input,
      capacity: null,
      closed: true,
      note: "",
    });
    assert.ok(closed.ok);
    assert.equal(closed.args.p_note, null);
    assert.equal(closed.args.p_is_closed, true);
  });

  it("refuses closed with a capacity, an empty override, bad date and long notes", () => {
    const both = buildSaveDeliverySlotOverrideArgs({ ...input, closed: true });
    assert.ok(!both.ok);
    assert.ok(both.errors.capacity);
    const empty = buildSaveDeliverySlotOverrideArgs({
      ...input,
      capacity: null,
      note: " ",
    });
    assert.ok(!empty.ok);
    assert.ok(empty.errors.form);
    assert.ok(
      !buildSaveDeliverySlotOverrideArgs({ ...input, slotDate: "2026-02-30" })
        .ok,
    );
    assert.ok(
      !buildSaveDeliverySlotOverrideArgs({ ...input, note: "n".repeat(301) })
        .ok,
    );
    assert.ok(
      !buildSaveDeliverySlotOverrideArgs({ ...input, capacity: 100001 }).ok,
    );
    assert.ok(buildSaveDeliverySlotOverrideArgs({ ...input, capacity: 0 }).ok);
  });

  it("builds clear args and requires a reason", () => {
    const r = buildClearDeliverySlotOverrideArgs("t1", "2026-10-08", " reset ");
    assert.ok(r.ok);
    assert.deepEqual(r.args, {
      p_template_id: "t1",
      p_slot_date: "2026-10-08",
      p_reason: "reset",
    });
    const bad = buildClearDeliverySlotOverrideArgs("t1", "x", "");
    assert.ok(!bad.ok);
    assert.deepEqual(Object.keys(bad.errors).sort(), ["date", "reason"]);
  });
});
