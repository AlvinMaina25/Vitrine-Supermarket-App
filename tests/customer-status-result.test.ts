import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminCustomerStatusError,
  MAX_STATUS_REASON_LENGTH,
  buildSetCustomerStatusArgs,
  toAdminCustomerStatusError,
  toAdminSetCustomerStatusResult,
} from "../src/features/admin/customer-status-result.ts";

const ok = {
  changed: true,
  customer_id: "c1",
  previous_status: "active",
  status: "suspended",
};

describe("toAdminSetCustomerStatusResult", () => {
  it("parses a result", () => {
    assert.deepEqual(toAdminSetCustomerStatusResult(ok), ok);
  });

  it("rejects malformed results", () => {
    for (const bad of [null, "x", [], {}]) {
      assert.throws(
        () => toAdminSetCustomerStatusResult(bad),
        /unexpected response/,
      );
    }
    assert.throws(
      () => toAdminSetCustomerStatusResult({ ...ok, changed: false }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminSetCustomerStatusResult({ ...ok, status: "x" }),
      /unexpected/,
    );
    assert.throws(
      () => toAdminSetCustomerStatusResult({ ...ok, customer_id: 1 }),
      /unexpected/,
    );
  });
});

describe("toAdminCustomerStatusError", () => {
  it("maps not-authorised", () => {
    assert.ok(
      toAdminCustomerStatusError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("maps every refusal code and attaches the reason field", () => {
    const codes = [
      "invalid_arguments",
      "invalid_status",
      "reason_required",
      "reason_too_long",
      "cannot_target_self",
      "customer_not_found",
      "cannot_target_staff",
      "status_unchanged",
    ];
    for (const code of codes) {
      const e = toAdminCustomerStatusError({ message: "raw", details: code });
      assert.ok(e instanceof AdminCustomerStatusError, code);
      assert.equal((e as AdminCustomerStatusError).reason, code);
      assert.ok(!e.message.includes("raw"));
    }
    const field = (code: string) =>
      (
        toAdminCustomerStatusError({
          message: "x",
          details: code,
        }) as AdminCustomerStatusError
      ).field;
    assert.equal(field("reason_required"), "reason");
    assert.equal(field("reason_too_long"), "reason");
    assert.equal(field("status_unchanged"), null);
  });

  it("keeps unknown errors as plain errors", () => {
    const e = toAdminCustomerStatusError({ message: "boom", details: "weird" });
    assert.equal(e.message, "boom");
    assert.ok(!(e instanceof AdminCustomerStatusError));
  });
});

describe("buildSetCustomerStatusArgs", () => {
  it("builds named arguments with a trimmed reason", () => {
    assert.deepEqual(
      buildSetCustomerStatusArgs("c1", "suspended", "  fraud  "),
      {
        ok: true,
        args: { p_customer_id: "c1", p_status: "suspended", p_reason: "fraud" },
      },
    );
  });

  it("requires a reason", () => {
    const r = buildSetCustomerStatusArgs("c1", "active", "   ");
    assert.equal(r.ok, false);
    if (!r.ok) assert.ok(r.errors.reason);
  });

  it("counts code points against the 500 limit", () => {
    assert.equal(
      buildSetCustomerStatusArgs("c1", "active", "😀".repeat(500)).ok,
      true,
    );
    assert.equal(
      buildSetCustomerStatusArgs(
        "c1",
        "active",
        "x".repeat(MAX_STATUS_REASON_LENGTH + 1),
      ).ok,
      false,
    );
  });
});
