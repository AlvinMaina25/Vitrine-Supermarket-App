import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { ADMIN_NAV, adminLoadErrorMessage } from "../src/features/admin/nav.ts";

const items = ADMIN_NAV.flatMap((group) => group.items);

describe("ADMIN_NAV", () => {
  it("lists the ten live sections (Phase 15 adds Promotions and Payments; Phase 20 adds Categories) and the one future section", () => {
    assert.deepEqual(
      items.map((item) => item.label),
      [
        "Dashboard",
        "Orders",
        "Products",
        "Categories",
        "Inventory",
        "Customers",
        "Delivery",
        "Promotions",
        "Payments",
        "Audit log",
        "Reports",
      ],
    );
  });

  it("every section links to a route; only Reports is marked soon (its page says it is not available yet)", () => {
    assert.deepEqual(
      items.filter((item) => item.to).map((item) => item.key),
      [
        "dashboard",
        "orders",
        "products",
        "categories",
        "inventory",
        "customers",
        "delivery",
        "promotions",
        "payments",
        "audit-log",
        "reports",
      ],
    );
    assert.deepEqual(
      items.filter((item) => item.soon).map((item) => item.key),
      ["reports"],
    );
  });

  it("keeps Delivery in Operations and only Reports under Coming later", () => {
    const group = (label: string) =>
      ADMIN_NAV.find((g) => g.label === label)?.items ?? [];
    assert.equal(
      group("Operations").find((item) => item.key === "delivery")?.to,
      "/admin/delivery",
    );
    assert.deepEqual(
      group("Coming later").map((item) => item.key),
      ["reports"],
    );
  });

  it("has unique keys", () => {
    assert.equal(new Set(items.map((item) => item.key)).size, items.length);
  });
});

describe("adminLoadErrorMessage", () => {
  it("is generic and carries no database detail", () => {
    assert.doesNotMatch(
      adminLoadErrorMessage(),
      /sql|postgres|pgrst|rpc|42501/i,
    );
  });
});
