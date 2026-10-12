// Phase 6C.2.2B.1 - STATIC checks on the admin inventory adjustment history API migration.
//
// No database is needed. The behavioural proof is db/tests/phase6c2_inventory_history_api.test.sql;
// this file guards the text-level promises that a SQL script cannot check about repository files.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const MIGRATION_NAME = "20261004110000_phase6c2_inventory_history_api.sql";
const migrationPath = join(root, "db", "migrations", MIGRATION_NAME);
const raw = readFileSync(migrationPath, "utf8");

/** Strip comments and single-quoted literals, keeping code (including $fn$ bodies). */
function strip(sql: string): string {
  let out = "";
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    const n = sql[i + 1];
    if (c === "-" && n === "-") {
      while (i < sql.length && sql[i] !== "\n") i++;
    } else if (c === "/" && n === "*") {
      const end = sql.indexOf("*/", i + 2);
      i = end === -1 ? sql.length : end + 2;
    } else if (c === "'") {
      i++;
      while (i < sql.length) {
        if (sql[i] === "'" && sql[i + 1] === "'") i += 2;
        else if (sql[i] === "'") {
          i++;
          break;
        } else i++;
      }
      out += "''";
    } else {
      out += c;
      i++;
    }
  }
  return out;
}
const code = strip(raw).toLowerCase();
const fnBody = /\$fn\$([\s\S]*?)\$fn\$/.exec(code)?.[1] ?? "";
const SIG =
  "public\\.admin_list_inventory_adjustments\\(integer, integer, uuid, uuid, text, uuid, timestamptz, timestamptz\\)";

describe("Phase 6C.2.2B.1 migration: file", () => {
  it("is the exact file name and states it is NOT applied", () => {
    assert.ok(existsSync(migrationPath));
    const all = readdirSync(join(root, "db", "migrations"))
      .filter((f) => f.endsWith(".sql"))
      .sort();
    assert.ok(all.includes(MIGRATION_NAME));
    assert.match(raw, /NOT APPLIED/);
    assert.equal((code.match(/\bbegin\s*;/g) ?? []).length, 1);
    assert.equal((code.match(/\bcommit\s*;/g) ?? []).length, 1);
  });

  it("has a SQL test that runs in one rolled-back transaction", () => {
    const p = join(
      root,
      "db",
      "tests",
      "phase6c2_inventory_history_api.test.sql",
    );
    assert.ok(existsSync(p));
    const t = strip(readFileSync(p, "utf8")).toLowerCase();
    assert.ok(/^\s*begin;/m.test(t));
    assert.ok(/rollback;\s*$/.test(t.trim()));
    assert.doesNotMatch(t, /\bcommit\b/);
  });
});

describe("Phase 6C.2.2B.1 migration: scope", () => {
  it("creates exactly one function and nothing else", () => {
    const creates = [
      ...code.matchAll(/\bcreate\s+(?:or\s+replace\s+)?(\w+)/g),
    ].map((m) => m[1]);
    assert.deepEqual(creates, ["function"]);
    assert.match(
      code,
      /create function public\.admin_list_inventory_adjustments\(/,
    );
    assert.doesNotMatch(code, /\balter\s+table\b/);
    assert.doesNotMatch(code, /\bdrop\b/);
    assert.doesNotMatch(code, /\bcreate\s+(trigger|policy|table|index|view)\b/);
  });

  it("does not replace the adjustment writer or any order logic", () => {
    assert.doesNotMatch(code, /function\s+public\.admin_adjust_inventory/);
    for (const name of [
      "create_order",
      "set_order_status",
      "restock_cancelled_order",
    ]) {
      assert.doesNotMatch(code, new RegExp(`function\\s+public\\.${name}`));
    }
  });
});

describe("Phase 6C.2.2B.1 migration: function security and read-only body", () => {
  it("is STABLE SECURITY DEFINER with search_path = public, pg_temp", () => {
    assert.match(code, /\bstable\b/);
    assert.doesNotMatch(code, /\bvolatile\b/);
    assert.match(code, /security definer/);
    assert.match(code, /set search_path = public, pg_temp/);
  });

  it("calls require_admin() first, before arguments are validated or the table is read", () => {
    const gate = fnBody.indexOf("public.require_admin()");
    assert.ok(gate >= 0);
    assert.ok(fnBody.indexOf("p_limit is null") > gate);
    assert.ok(fnBody.indexOf("public.inventory_adjustments") > gate);
  });

  it("contains no write statement, row lock or dynamic SQL", () => {
    assert.doesNotMatch(
      fnBody,
      /\b(insert\s+into|update\s+public|delete\s+from|truncate)\b/,
    );
    assert.doesNotMatch(fnBody, /\bexecute\b/);
    assert.doesNotMatch(
      fnBody,
      /\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/,
    );
  });

  it("orders by a fixed created_at desc, id desc with no order parameter", () => {
    assert.match(fnBody, /order by m\.created_at desc, m\.id desc/);
    const params =
      /create function public\.admin_list_inventory_adjustments\(([\s\S]*?)\)\s*returns/.exec(
        code,
      )?.[1] ?? "";
    const names = params
      .split(",")
      .map((p) => p.trim().split(/\s+/)[0])
      .filter(Boolean);
    assert.deepEqual(names, [
      "p_limit",
      "p_offset",
      "p_product_id",
      "p_variant_id",
      "p_reason",
      "p_changed_by",
      "p_from",
      "p_to",
    ]);
  });

  it("sets the exact EXECUTE ACL and grants nothing on any table", () => {
    assert.match(
      code,
      new RegExp(
        `revoke all on function ${SIG}\\s+from public, anon, authenticated;`,
      ),
    );
    assert.match(
      code,
      new RegExp(`grant execute on function ${SIG}\\s+to authenticated;`),
    );
    const grants = code
      .split(";")
      .map((st) => st.trim())
      .filter((st) => /^grant\b/.test(st));
    assert.equal(grants.length, 1, "exactly one GRANT statement");
    assert.doesNotMatch(
      (grants[0] ?? "").split(/\bto\b/)[1] ?? "",
      /\b(anon|public)\b/,
    );
    assert.doesNotMatch(code, /\bgrant\b[^;]*\bon\s+(table\s+)?public\./);
  });
});
