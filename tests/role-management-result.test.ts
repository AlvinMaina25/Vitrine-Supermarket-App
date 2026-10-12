import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import {
  AdminRoleChangeError,
  buildSetUserRoleArgs,
  roleChangeErrorMessage,
  toAdminRoleChangeError,
  toAdminSetUserRoleResult,
  toRoleHolderList,
  toRoleHoldersReadError,
  type AdminRoleChangeReason,
} from "../src/features/admin/role-management-result.ts";

const holder = {
  user_id: "u1",
  role: "admin",
  granted_at: "2026-10-01T10:00:00Z",
};

describe("toRoleHolderList", () => {
  it("parses holders", () => {
    const list = toRoleHolderList({
      holders: [
        holder,
        { user_id: "u2", role: "staff", granted_at: "2026-10-02T10:00:00Z" },
      ],
    });
    assert.equal(list.holders.length, 2);
    assert.deepEqual(list.holders[0], holder);
    assert.equal(list.holders[1]?.role, "staff");
  });

  it("accepts an empty list", () => {
    assert.deepEqual(toRoleHolderList({ holders: [] }).holders, []);
  });

  it("drops fields it does not know about (no emails can leak through)", () => {
    const out = toRoleHolderList({
      holders: [
        { ...holder, email: "someone@example.com", full_name: "Someone" },
      ],
      extra: "x",
    });
    assert.deepEqual(Object.keys(out.holders[0] ?? {}).sort(), [
      "granted_at",
      "role",
      "user_id",
    ]);
    assert.equal("extra" in out, false);
    assert.equal(JSON.stringify(out).includes("example.com"), false);
  });

  it("rejects non-objects, a missing list and malformed holders", () => {
    for (const bad of [null, undefined, "x", 5, [], {}, { holders: "x" }]) {
      assert.throws(() => toRoleHolderList(bad), /unexpected response/);
    }
    for (const bad of [
      { ...holder, user_id: "" },
      { ...holder, user_id: 5 },
      { ...holder, role: "customer" },
      { ...holder, role: "owner" },
      { ...holder, granted_at: null },
    ]) {
      assert.throws(
        () => toRoleHolderList({ holders: [bad] }),
        /unexpected response/,
      );
    }
    assert.throws(
      () => toRoleHolderList({ holders: [null] }),
      /unexpected response/,
    );
  });
});

describe("toAdminSetUserRoleResult", () => {
  const ok = { changed: true, user_id: "u1", role: "staff", action: "grant" };

  it("parses a real change and a no-op", () => {
    assert.deepEqual(toAdminSetUserRoleResult(ok), ok);
    assert.equal(
      toAdminSetUserRoleResult({ ...ok, changed: false }).changed,
      false,
    );
    assert.equal(
      toAdminSetUserRoleResult({ ...ok, role: "admin", action: "revoke" })
        .action,
      "revoke",
    );
  });

  it("drops unknown fields", () => {
    const out = toAdminSetUserRoleResult({
      ...ok,
      email: "a@b.test",
      token: "TOPSECRET",
    });
    assert.deepEqual(Object.keys(out).sort(), [
      "action",
      "changed",
      "role",
      "user_id",
    ]);
    assert.equal(JSON.stringify(out).includes("TOPSECRET"), false);
  });

  it("rejects bad shapes", () => {
    for (const bad of [
      null,
      "x",
      [],
      {},
      { ...ok, changed: "true" },
      { ...ok, changed: undefined },
      { ...ok, user_id: "" },
      { ...ok, role: "customer" },
      { ...ok, action: "delete" },
    ]) {
      assert.throws(() => toAdminSetUserRoleResult(bad), /unexpected response/);
    }
  });
});

describe("toAdminRoleChangeError", () => {
  it("maps not_authorised, 42501 and mfa_required to AdminAccessError", () => {
    assert.ok(
      toAdminRoleChangeError({
        message: "x",
        code: "42501",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminRoleChangeError({
        message: "x",
        code: "42501",
        details: "mfa_required",
      }) instanceof AdminAccessError,
    );
    assert.ok(
      toAdminRoleChangeError({
        message: "x",
        details: "not_authorised",
      }) instanceof AdminAccessError,
    );
  });

  it("maps every rule code to AdminRoleChangeError carrying that code", () => {
    const codes: AdminRoleChangeReason[] = [
      "invalid_arguments",
      "invalid_action",
      "invalid_role",
      "reason_required",
      "reason_too_short",
      "reason_too_long",
      "cannot_change_own_role",
      "user_not_found",
      "last_admin",
    ];
    for (const code of codes) {
      const e = toAdminRoleChangeError({
        message: "db text",
        code: "P0001",
        details: code,
      });
      assert.ok(e instanceof AdminRoleChangeError);
      assert.equal((e as AdminRoleChangeError).reason, code);
    }
  });

  it("marks only reason problems as field errors", () => {
    const field = (details: string) =>
      (
        toAdminRoleChangeError({
          message: "x",
          details,
        }) as AdminRoleChangeError
      ).field;
    assert.equal(field("reason_required"), "reason");
    assert.equal(field("reason_too_short"), "reason");
    assert.equal(field("reason_too_long"), "reason");
    assert.equal(field("last_admin"), null);
    assert.equal(field("cannot_change_own_role"), null);
  });

  it("never echoes the database message", () => {
    const unknown = toAdminRoleChangeError({
      message: "secret db text",
      code: "XX000",
    });
    assert.ok(!(unknown instanceof AdminRoleChangeError));
    assert.ok(!(unknown instanceof AdminAccessError));
    assert.equal(unknown.message.includes("secret"), false);
    const known = toAdminRoleChangeError({
      message: "secret db text",
      details: "last_admin",
    });
    assert.equal(known.message.includes("secret"), false);
  });
});

describe("toRoleHoldersReadError", () => {
  it("maps access errors and hides everything else", () => {
    assert.ok(
      toRoleHoldersReadError({ message: "x", code: "42501" }) instanceof
        AdminAccessError,
    );
    const other = toRoleHoldersReadError({ message: "secret db text" });
    assert.ok(!(other instanceof AdminAccessError));
    assert.equal(other.message.includes("secret"), false);
  });
});

describe("roleChangeErrorMessage", () => {
  it("has a non-empty, database-free message for every code", () => {
    const codes: AdminRoleChangeReason[] = [
      "invalid_arguments",
      "invalid_action",
      "invalid_role",
      "reason_required",
      "reason_too_short",
      "reason_too_long",
      "cannot_change_own_role",
      "user_not_found",
      "last_admin",
    ];
    for (const code of codes)
      assert.ok(roleChangeErrorMessage(code).length > 0);
  });
});

describe("buildSetUserRoleArgs", () => {
  it("builds named arguments with a trimmed reason", () => {
    const out = buildSetUserRoleArgs("u1", "staff", "grant", "  new cashier  ");
    assert.deepEqual(out, {
      ok: true,
      args: {
        p_user: "u1",
        p_role: "staff",
        p_action: "grant",
        p_reason: "new cashier",
      },
    });
  });

  it("accepts the 3 and 200 character edges", () => {
    assert.equal(buildSetUserRoleArgs("u1", "admin", "revoke", "abc").ok, true);
    assert.equal(
      buildSetUserRoleArgs("u1", "admin", "revoke", "a".repeat(200)).ok,
      true,
    );
  });

  it("refuses blank, too-short and too-long reasons", () => {
    for (const reason of ["", "   ", "\n\t"]) {
      const out = buildSetUserRoleArgs("u1", "staff", "grant", reason);
      assert.equal(out.ok, false);
      if (!out.ok) assert.equal(out.errors.reason, "A reason is required.");
    }
    const short = buildSetUserRoleArgs("u1", "staff", "grant", " ab ");
    assert.equal(short.ok, false);
    if (!short.ok) assert.match(short.errors.reason ?? "", /at least 3/);
    const long = buildSetUserRoleArgs("u1", "staff", "grant", "a".repeat(201));
    assert.equal(long.ok, false);
    if (!long.ok) assert.match(long.errors.reason ?? "", /200/);
  });

  it("counts characters the way the database does (code points)", () => {
    assert.equal(
      buildSetUserRoleArgs("u1", "staff", "grant", "😀".repeat(200)).ok,
      true,
    );
    assert.equal(
      buildSetUserRoleArgs("u1", "staff", "grant", "😀".repeat(201)).ok,
      false,
    );
  });
});
