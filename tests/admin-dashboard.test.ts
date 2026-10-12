import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AdminAccessError,
  isAdminAccessError,
  toAdminDashboardError,
  toAdminDashboardSummary,
} from "../src/features/admin/dashboard-result.ts";

const KEYS = [
  "generated_at",
  "time_zone",
  "low_stock_threshold",
  "orders",
  "payments",
  "delivery",
  "products",
  "variants",
  "low_stock_items",
  "customers",
  "recent_orders",
];

function payload(): Record<string, unknown> {
  return Object.fromEntries(
    KEYS.map((key) => [key, key === "time_zone" ? "Africa/Nairobi" : {}]),
  );
}

describe("toAdminDashboardError", () => {
  it("maps the admin gate refusal (42501 / not_authorised) to AdminAccessError", () => {
    const error = toAdminDashboardError({
      message: "You are not allowed to perform this admin action.",
      details: "not_authorised",
      code: "42501",
    });
    assert.ok(isAdminAccessError(error));
    assert.ok(error instanceof AdminAccessError);
  });

  it("maps a plain permission-denied (anonymous caller) to AdminAccessError", () => {
    const error = toAdminDashboardError({
      message: "permission denied for function admin_dashboard_summary",
      code: "42501",
    });
    assert.ok(isAdminAccessError(error));
  });

  it("maps a not_authorised DETAIL even without a code", () => {
    assert.ok(
      isAdminAccessError(
        toAdminDashboardError({ message: "x", details: "not_authorised" }),
      ),
    );
  });

  it("keeps the message of any other failure and does not treat it as an access error", () => {
    const error = toAdminDashboardError({
      message:
        "Invalid dashboard arguments (recent orders 1-50, low-stock threshold 0-1000).",
      details: "invalid_arguments",
      code: "P0001",
    });
    assert.equal(isAdminAccessError(error), false);
    assert.match(error.message, /Invalid dashboard arguments/);
  });

  it("does not treat a missing function (migration not applied) as an access error", () => {
    const error = toAdminDashboardError({
      message: "Could not find the function public.admin_dashboard_summary",
      code: "PGRST202",
    });
    assert.equal(isAdminAccessError(error), false);
  });
});

describe("toAdminDashboardSummary", () => {
  it("accepts a document with every documented top-level key", () => {
    const data = payload();
    assert.equal(toAdminDashboardSummary(data) as unknown, data);
  });

  it("rejects null, arrays and scalars", () => {
    for (const bad of [null, undefined, [], "x", 1, true]) {
      assert.throws(() => toAdminDashboardSummary(bad), /unexpected response/);
    }
  });

  it("names the key that is missing", () => {
    for (const key of KEYS) {
      const data = payload();
      delete data[key];
      assert.throws(
        () => toAdminDashboardSummary(data),
        new RegExp(`missing "${key}"`),
      );
    }
  });
});
