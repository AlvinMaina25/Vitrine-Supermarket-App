import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  adminAccessDeniedCopy,
  adminActionFailureMessage,
  adminLoadFailedCopy,
  adminNoAccessCopy,
  adminOfflineCopy,
  asOfLabel,
  classifyAdminLoadError,
  filterLoadedRows,
  firstErrorField,
  sortLoadedRows,
} from "../src/features/admin/admin-ui.ts";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";

class NotConfigured extends Error {
  constructor() {
    super("Supabase is not configured for this environment.");
    this.name = "SupabaseNotConfiguredError";
  }
}

describe("classifyAdminLoadError", () => {
  it("a database refusal is no_access, never a connection problem", () => {
    assert.equal(
      classifyAdminLoadError(new AdminAccessError(), true),
      "no_access",
    );
    // Even when the browser also reports offline: the refusal wins over guessing.
    assert.equal(
      classifyAdminLoadError(new AdminAccessError(), false),
      "no_access",
    );
  });

  it("missing configuration is its own state", () => {
    assert.equal(
      classifyAdminLoadError(new NotConfigured(), true),
      "not_configured",
    );
  });

  it("a dropped connection is offline", () => {
    assert.equal(
      classifyAdminLoadError(new Error("anything"), false),
      "offline",
    );
    assert.equal(
      classifyAdminLoadError(new TypeError("Failed to fetch"), true),
      "offline",
    );
  });

  it("anything else is a plain failure", () => {
    assert.equal(classifyAdminLoadError(new Error("boom"), true), "failed");
    assert.equal(classifyAdminLoadError("weird", undefined), "failed");
    assert.equal(classifyAdminLoadError(null, true), "failed");
  });
});

describe("admin state wording", () => {
  it("no-access copy names the action and says nothing was loaded", () => {
    const copy = adminNoAccessCopy("view orders");
    assert.equal(copy.title, "Admin access required");
    assert.match(copy.message, /not permitted to view orders/);
    assert.match(copy.message, /Nothing was loaded/);
    assert.match(copy.hint ?? "", /two-factor/);
  });

  it("no copy carries database detail", () => {
    const all = [
      adminNoAccessCopy("view orders"),
      adminOfflineCopy(),
      adminLoadFailedCopy("orders"),
    ]
      .map((c) => `${c.title} ${c.message} ${c.hint ?? ""}`)
      .join(" ");
    assert.doesNotMatch(
      all,
      /sql|postgres|pgrst|rpc|42501|not_authorised|mfa_required/i,
    );
  });

  it("the full-page denial tells staff their access does not include admin, and grants nothing", () => {
    const staff = adminAccessDeniedCopy(true);
    const other = adminAccessDeniedCopy(false);
    assert.match(staff.message, /staff access/);
    assert.doesNotMatch(other.message, /staff/);
    assert.equal(staff.title, other.title);
    for (const c of [staff, other]) {
      assert.match(c.hint ?? "", /ask an existing administrator/);
    }
  });

  it("failed copy names what could not load", () => {
    assert.equal(
      adminLoadFailedCopy("delivery settings").title,
      "We couldn't load delivery settings",
    );
  });
});

describe("adminActionFailureMessage", () => {
  it("a refusal says nothing was changed", () => {
    const message = adminActionFailureMessage(
      new AdminAccessError(),
      true,
      "x",
    );
    assert.match(message, /not permitted/);
    assert.match(message, /Nothing was changed/);
  });

  it("a dropped connection says nothing was changed", () => {
    assert.match(
      adminActionFailureMessage(new TypeError("Failed to fetch"), true, "x"),
      /Nothing was changed|nothing was changed/,
    );
  });

  it("otherwise the caller's already-plain fallback is used, never the raw error", () => {
    assert.equal(
      adminActionFailureMessage(
        new Error('relation "orders" does not exist'),
        true,
        "That did not save.",
      ),
      "That did not save.",
    );
  });
});

describe("asOfLabel", () => {
  it("formats in the stated time zone", () => {
    // 11:05 UTC is 14:05 in Nairobi (UTC+3).
    const label = asOfLabel("2026-10-11T11:05:00Z", "Africa/Nairobi");
    assert.match(label ?? "", /^As of /);
    assert.match(label ?? "", /14:05/);
    assert.match(label ?? "", /\(Africa\/Nairobi\)$/);
  });

  it("returns null rather than a wrong time", () => {
    assert.equal(asOfLabel("not a date", "Africa/Nairobi"), null);
    assert.equal(asOfLabel("2026-10-11T11:05:00Z", "Not/AZone"), null);
    assert.equal(asOfLabel("", "Africa/Nairobi"), null);
  });
});

describe("filterLoadedRows", () => {
  const rows = [
    { name: "Welcome 10", code: "WELCOME10" },
    { name: "Eid offer", code: null },
    { name: "Bulk", code: "BULK5" },
  ];
  const texts = (r: (typeof rows)[number]) => [r.name, r.code];

  it("blank term keeps every row (as a copy)", () => {
    const out = filterLoadedRows(rows, "  ", texts);
    assert.deepEqual(out, rows);
    assert.notEqual(out, rows);
  });

  it("matches case-insensitively on any field and ignores null fields", () => {
    assert.deepEqual(
      filterLoadedRows(rows, "eid", texts).map((r) => r.name),
      ["Eid offer"],
    );
    assert.deepEqual(
      filterLoadedRows(rows, "bulk5", texts).map((r) => r.name),
      ["Bulk"],
    );
    assert.deepEqual(filterLoadedRows(rows, "zzz", texts), []);
  });
});

describe("sortLoadedRows", () => {
  const rows = [
    { id: "a", n: 5 as number | null },
    { id: "b", n: null },
    { id: "c", n: 1 },
    { id: "d", n: 5 },
  ];

  it("sorts numbers both ways, missing values last in both, stable for ties", () => {
    assert.deepEqual(
      sortLoadedRows(rows, (r) => r.n, "asc").map((r) => r.id),
      ["c", "a", "d", "b"],
    );
    assert.deepEqual(
      sortLoadedRows(rows, (r) => r.n, "desc").map((r) => r.id),
      ["a", "d", "c", "b"],
    );
  });

  it("sorts text naturally and does not change the input", () => {
    const texts = [{ s: "Item 10" }, { s: "item 2" }, { s: "Apple" }];
    assert.deepEqual(
      sortLoadedRows(texts, (r) => r.s, "asc").map((r) => r.s),
      ["Apple", "item 2", "Item 10"],
    );
    assert.deepEqual(
      texts.map((r) => r.s),
      ["Item 10", "item 2", "Apple"],
    );
  });
});

describe("firstErrorField", () => {
  const order = ["name", "code", "value"] as const;

  it("returns the first field in screen order, not insertion order", () => {
    assert.equal(firstErrorField({ value: "bad", code: "bad" }, order), "code");
  });

  it("ignores empty and missing messages; null when clean", () => {
    assert.equal(firstErrorField({ name: "", code: null }, order), null);
    assert.equal(firstErrorField({}, order), null);
  });
});
