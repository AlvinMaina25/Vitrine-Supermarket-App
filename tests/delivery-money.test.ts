import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  centsToShillingsText,
  shillingsToCents,
} from "../src/features/admin/delivery-money.ts";

const cents = (text: string) => shillingsToCents(text, "The fee", false);

describe("shillingsToCents", () => {
  it("converts whole shillings and one or two decimals exactly", () => {
    assert.deepEqual(cents("250"), { ok: true, cents: 25000 });
    assert.deepEqual(cents("250.5"), { ok: true, cents: 25050 });
    assert.deepEqual(cents("250.50"), { ok: true, cents: 25050 });
    assert.deepEqual(cents("0.07"), { ok: true, cents: 7 });
    assert.deepEqual(cents("0"), { ok: true, cents: 0 });
    assert.deepEqual(cents("007"), { ok: true, cents: 700 });
  });

  it("never drifts the way floating point does", () => {
    assert.deepEqual(cents("250.10"), { ok: true, cents: 25010 });
    assert.deepEqual(cents("19.99"), { ok: true, cents: 1999 });
    assert.deepEqual(cents("1.15"), { ok: true, cents: 115 });
    assert.deepEqual(cents("0.29"), { ok: true, cents: 29 });
  });

  it("accepts comma groups of three and trims spaces", () => {
    assert.deepEqual(cents(" 1,250 "), { ok: true, cents: 125000 });
    assert.deepEqual(cents("1,250,000.25"), { ok: true, cents: 125000025 });
  });

  it("rejects signs, exponents, units, odd separators and extra decimals", () => {
    for (const bad of [
      "-1",
      "+5",
      "1e3",
      "KES 5",
      "5 KES",
      "1,25",
      "12,34,567",
      ",500",
      "5.",
      ".5",
      "1.234",
      "1 000",
      "٣",
      "２５",
      "0x10",
    ]) {
      assert.equal(cents(bad).ok, false, bad);
    }
  });

  it("allows the database maximum and refuses anything above it", () => {
    assert.deepEqual(cents("21474836.47"), { ok: true, cents: 2147483647 });
    assert.equal(cents("21474836.48").ok, false);
    assert.equal(cents("99999999999999999999").ok, false);
    assert.equal(cents("0000000000000000000000250").ok, true);
  });

  it("blank is null when optional and a labelled error when required", () => {
    assert.deepEqual(shillingsToCents("   ", "The fee", true), {
      ok: true,
      cents: null,
    });
    const required = shillingsToCents("", "The fee", false);
    assert.ok(!required.ok);
    assert.equal(required.error, "The fee is required.");
    const bad = cents("abc");
    assert.ok(!bad.ok);
    assert.match(bad.error, /^The fee must be an amount in shillings/);
  });
});

describe("centsToShillingsText", () => {
  it("prints whole shillings plainly and keeps two decimals otherwise", () => {
    assert.equal(centsToShillingsText(0), "0");
    assert.equal(centsToShillingsText(7), "0.07");
    assert.equal(centsToShillingsText(25000), "250");
    assert.equal(centsToShillingsText(25050), "250.50");
    assert.equal(centsToShillingsText(25010), "250.10");
    assert.equal(centsToShillingsText(2147483647), "21474836.47");
  });

  it("round-trips through shillingsToCents", () => {
    for (const value of [0, 1, 9, 10, 99, 100, 101, 25000, 25055, 2147483647]) {
      assert.deepEqual(cents(centsToShillingsText(value)), {
        ok: true,
        cents: value,
      });
    }
  });

  it("returns blank for values that are not whole non-negative cents", () => {
    assert.equal(centsToShillingsText(-1), "");
    assert.equal(centsToShillingsText(1.5), "");
    assert.equal(centsToShillingsText(Number.NaN), "");
  });
});
