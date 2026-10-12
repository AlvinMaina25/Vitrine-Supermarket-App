import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AUDIT_LOG_PAGE_SIZE,
  hasAuditLogFilter,
  parseAuditLogParams,
  shortId,
  toAuditLogArgs,
  withAuditLogFilter,
  withAuditLogPage,
} from "../src/features/admin/audit-log-params.ts";

const UUID = "3f2b8c1e-5a4d-4e7b-9c10-2d6f8a1b7e90";
const TARGET = "a1b2c3d4-0000-4000-8000-123456789abc";

describe("parseAuditLogParams", () => {
  it("returns nothing for an empty search", () => {
    assert.deepEqual(parseAuditLogParams({}), {});
  });

  it("keeps valid values and trims text", () => {
    assert.deepEqual(
      parseAuditLogParams({
        action: "  customer.status  ",
        targetId: `  ${TARGET}  `,
        actorId: UUID,
        from: "2026-01-05",
        to: "2026-02-01",
        page: "3",
      }),
      {
        action: "customer.status",
        targetId: TARGET,
        actorId: UUID,
        from: "2026-01-05",
        to: "2026-02-01",
        page: 3,
      },
    );
  });

  it("drops invalid values", () => {
    assert.deepEqual(
      parseAuditLogParams({
        action: "   ",
        targetId: 5,
        actorId: "not-a-uuid",
        from: "2026-02-30",
        to: "yesterday",
        page: "abc",
      }),
      {},
    );
  });

  it("ignores a target id that is not a UUID", () => {
    for (const targetId of [
      "abc",
      "t1",
      "",
      "3f2b8c1e-5a4d-4e7b-9c10",
      `${TARGET}x`,
    ]) {
      assert.deepEqual(parseAuditLogParams({ targetId }), {});
    }
    assert.deepEqual(parseAuditLogParams({ targetId: TARGET }), {
      targetId: TARGET,
    });
  });

  it("drops page 1, zero, negative, fractional and huge pages", () => {
    for (const page of [1, 0, -2, 2.5, 1_000_000, "x"]) {
      assert.deepEqual(parseAuditLogParams({ page }), {});
    }
  });

  it("drops an end day before the start day", () => {
    assert.deepEqual(
      parseAuditLogParams({ from: "2026-03-02", to: "2026-03-01" }),
      {
        from: "2026-03-02",
      },
    );
  });

  it("caps long text at 100 characters", () => {
    assert.equal(
      parseAuditLogParams({ action: "a".repeat(300) }).action?.length,
      100,
    );
  });
});

describe("filters and paging", () => {
  it("a filter change returns to page 1; paging keeps the filters", () => {
    const base = parseAuditLogParams({ action: "x", page: 4 });
    assert.deepEqual(withAuditLogFilter(base, { targetId: TARGET }), {
      action: "x",
      targetId: TARGET,
    });
    assert.deepEqual(withAuditLogFilter(base, { action: null }), {});
    assert.deepEqual(withAuditLogPage({ action: "x" }, 2), {
      action: "x",
      page: 2,
    });
    assert.deepEqual(withAuditLogPage({ action: "x" }, 1), { action: "x" });
  });

  it("hasAuditLogFilter ignores paging", () => {
    assert.equal(hasAuditLogFilter({ page: 2 }), false);
    assert.equal(hasAuditLogFilter({ from: "2026-01-01" }), true);
  });
});

describe("toAuditLogArgs", () => {
  it("defaults to page size 25, offset 0 and no filters", () => {
    assert.deepEqual(toAuditLogArgs({}), {
      p_actor: null,
      p_action: null,
      p_target_id: null,
      p_from: null,
      p_to: null,
      p_limit: AUDIT_LOG_PAGE_SIZE,
      p_offset: 0,
    });
    assert.equal(AUDIT_LOG_PAGE_SIZE, 25);
  });

  it("computes the offset and turns days into local-day bounds (to is exclusive)", () => {
    const args = toAuditLogArgs({
      action: "a",
      targetId: "t",
      actorId: UUID,
      from: "2026-01-05",
      to: "2026-01-05",
      page: 3,
    });
    assert.equal(args.p_offset, 50);
    assert.equal(args.p_actor, UUID);
    assert.equal(args.p_from, new Date(2026, 0, 5).toISOString());
    assert.equal(args.p_to, new Date(2026, 0, 6).toISOString());
  });
});

describe("shortId", () => {
  it("shortens long ids and leaves short ones", () => {
    assert.equal(shortId(UUID), "3f2b8c1e…");
    assert.equal(shortId("abc"), "abc");
  });
});
