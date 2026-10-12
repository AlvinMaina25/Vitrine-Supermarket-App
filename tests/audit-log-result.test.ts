import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  toAdminListAuditLogArgs,
  toAuditLogList,
  toAuditLogReadError,
} from "../src/features/admin/audit-log-result.ts";

const entry = {
  id: "a1",
  actor_id: "u1",
  action: "customer_suspended",
  target_id: "c1",
  reason: "fraud review",
  created_at: "2026-10-01T10:00:00Z",
};
const page = { total_count: 1, limit: 25, offset: 0, entries: [entry] };

describe("toAuditLogList", () => {
  it("parses a page", () => {
    const list = toAuditLogList(page);
    assert.equal(list.total_count, 1);
    assert.equal(list.limit, 25);
    assert.equal(list.offset, 0);
    assert.deepEqual(list.entries[0], entry);
  });

  it("accepts an empty page and null actor/target/reason (system rows, deleted users)", () => {
    assert.deepEqual(
      toAuditLogList({ ...page, total_count: 0, entries: [] }).entries,
      [],
    );
    const row = toAuditLogList({
      ...page,
      entries: [{ ...entry, actor_id: null, target_id: null, reason: null }],
    }).entries[0];
    assert.equal(row?.actor_id, null);
    assert.equal(row?.target_id, null);
    assert.equal(row?.reason, null);
  });

  it("drops fields it does not know about", () => {
    const out = toAuditLogList({
      ...page,
      extra: "x",
      entries: [{ ...entry, payload: { token: "TOPSECRET" }, card: "4111" }],
    });
    assert.deepEqual(Object.keys(out.entries[0] ?? {}).sort(), [
      "action",
      "actor_id",
      "created_at",
      "id",
      "reason",
      "target_id",
    ]);
    assert.equal("extra" in out, false);
    assert.equal(JSON.stringify(out).includes("TOPSECRET"), false);
  });

  it("rejects non-objects and bad envelope fields", () => {
    for (const bad of [null, undefined, "x", 5, [], {}]) {
      assert.throws(() => toAuditLogList(bad), /unexpected response/);
    }
    assert.throws(
      () => toAuditLogList({ ...page, total_count: "1" }),
      /unexpected response/,
    );
    assert.throws(
      () => toAuditLogList({ ...page, offset: -1 }),
      /unexpected response/,
    );
    assert.throws(
      () => toAuditLogList({ ...page, entries: null }),
      /unexpected response/,
    );
  });

  it("rejects entries with a missing id, action or created_at", () => {
    for (const patch of [
      { id: "" },
      { action: undefined },
      { created_at: null },
      { reason: 7 },
    ]) {
      assert.throws(
        () => toAuditLogList({ ...page, entries: [{ ...entry, ...patch }] }),
        /unexpected response/,
      );
    }
  });

  it("never echoes the payload in the error", () => {
    assert.throws(
      () =>
        toAuditLogList({
          ...page,
          entries: [{ ...entry, reason: 7, secret: "TOPSECRET" }],
        }),
      (e: unknown) => e instanceof Error && !e.message.includes("TOPSECRET"),
    );
  });
});

describe("toAuditLogReadError", () => {
  it("maps not_authorised and 42501 to AdminAccessError", () => {
    assert.ok(
      toAuditLogReadError({
        message: "x",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAuditLogReadError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
    assert.ok(
      toAuditLogReadError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("maps invalid_arguments to a plain Error", () => {
    const e = toAuditLogReadError({
      message: "db text",
      code: "P0001",
      details: "invalid_arguments",
    });
    assert.equal(e instanceof AdminAccessError, false);
    assert.equal(e.message, "The audit log request was not valid.");
  });

  it("maps anything else to a generic Error and never echoes the database message", () => {
    const e = toAuditLogReadError({
      message: "SECRET db detail",
      code: "XX000",
    });
    assert.equal(e.message, "The audit log could not be loaded.");
    assert.equal(e.message.includes("SECRET"), false);
  });
});

describe("toAdminListAuditLogArgs", () => {
  it("defaults to 25/0 with null filters", () => {
    assert.deepEqual(toAdminListAuditLogArgs(), {
      p_actor: null,
      p_action: null,
      p_target_id: null,
      p_from: null,
      p_to: null,
      p_limit: 25,
      p_offset: 0,
    });
  });

  it("passes filters through and turns a blank action into null", () => {
    const args = toAdminListAuditLogArgs({
      actorId: "u1",
      action: "  cod_payment_recorded ",
      targetId: "o1",
      from: "2026-10-01T00:00:00Z",
      to: "2026-10-02T00:00:00Z",
      limit: 50,
      offset: 100,
    });
    assert.equal(args.p_actor, "u1");
    assert.equal(args.p_action, "cod_payment_recorded");
    assert.equal(args.p_target_id, "o1");
    assert.equal(args.p_limit, 50);
    assert.equal(args.p_offset, 100);
    assert.equal(toAdminListAuditLogArgs({ action: "   " }).p_action, null);
  });
});
