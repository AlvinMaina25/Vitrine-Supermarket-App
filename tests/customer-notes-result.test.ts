import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminCustomerNotesError,
  MAX_CUSTOMER_NOTES_LENGTH,
  buildUpdateCustomerNotesArgs,
  toAdminCustomerNotesError,
  toAdminUpdateCustomerNotesResult,
} from "../src/features/admin/customer-notes-result.ts";

describe("toAdminUpdateCustomerNotesResult", () => {
  it("parses a result, including a cleared note (length 0)", () => {
    assert.deepEqual(
      toAdminUpdateCustomerNotesResult({ customer_id: "c1", length: 12 }),
      {
        customer_id: "c1",
        length: 12,
      },
    );
    assert.equal(
      toAdminUpdateCustomerNotesResult({ customer_id: "c1", length: 0 }).length,
      0,
    );
  });

  it("rejects malformed results", () => {
    for (const bad of [null, "x", [], {}]) {
      assert.throws(
        () => toAdminUpdateCustomerNotesResult(bad),
        /unexpected response/,
      );
    }
    assert.throws(
      () => toAdminUpdateCustomerNotesResult({ customer_id: "c1", length: -1 }),
      /unexpected/,
    );
    assert.throws(
      () =>
        toAdminUpdateCustomerNotesResult({ customer_id: "c1", length: "3" }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminUpdateCustomerNotesResult({ length: 3 }),
      /unexpected/,
    );
  });
});

describe("toAdminCustomerNotesError", () => {
  it("maps not-authorised", () => {
    assert.ok(
      toAdminCustomerNotesError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
  });

  it("maps every refusal code", () => {
    for (const code of [
      "invalid_arguments",
      "notes_too_long",
      "customer_not_found",
      "cannot_target_staff",
    ]) {
      const e = toAdminCustomerNotesError({ message: "raw", details: code });
      assert.ok(e instanceof AdminCustomerNotesError, code);
      assert.equal((e as AdminCustomerNotesError).reason, code);
      assert.ok(!e.message.includes("raw"));
    }
    const tooLong = toAdminCustomerNotesError({
      message: "x",
      details: "notes_too_long",
    });
    assert.equal((tooLong as AdminCustomerNotesError).field, "notes");
  });

  it("keeps unknown errors as plain errors", () => {
    const e = toAdminCustomerNotesError({ message: "boom" });
    assert.equal(e.message, "boom");
    assert.ok(!(e instanceof AdminCustomerNotesError));
  });
});

describe("buildUpdateCustomerNotesArgs", () => {
  it("trims and builds named arguments", () => {
    assert.deepEqual(buildUpdateCustomerNotesArgs("c1", "  hello  "), {
      ok: true,
      clearing: false,
      args: { p_customer_id: "c1", p_notes: "hello" },
    });
  });

  it("treats blank input as a valid clear, sent as an empty string (never null)", () => {
    const r = buildUpdateCustomerNotesArgs("c1", "   ");
    assert.equal(r.ok, true);
    if (r.ok) {
      assert.equal(r.clearing, true);
      assert.equal(r.args.p_notes, "");
    }
  });

  it("enforces 2000 characters by code points", () => {
    assert.equal(
      buildUpdateCustomerNotesArgs("c1", "😀".repeat(MAX_CUSTOMER_NOTES_LENGTH))
        .ok,
      true,
    );
    const r = buildUpdateCustomerNotesArgs(
      "c1",
      "x".repeat(MAX_CUSTOMER_NOTES_LENGTH + 1),
    );
    assert.equal(r.ok, false);
  });
});
