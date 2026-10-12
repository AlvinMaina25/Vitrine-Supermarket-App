// Phase 6C.2.2A.2 - STATIC checks on the admin stock adjustment migration and its types.
//
// No database is needed. The behavioural proof is
// db/tests/phase6c2_admin_inventory_adjustment.test.sql; this file guards the text-level promises
// that a SQL script cannot check about repository files.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const MIGRATION_NAME = "20261004100000_phase6c2_admin_inventory_adjustment.sql";
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

describe("Phase 6C.2.2A.2 migration: file", () => {
  it("is the exact file name, the 6C.2.2B.1 history API exists, and states it is NOT applied", () => {
    assert.ok(existsSync(migrationPath));
    const all = readdirSync(join(root, "db", "migrations"))
      .filter((f) => f.endsWith(".sql"))
      .sort();
    assert.ok(all.includes(MIGRATION_NAME));
    assert.ok(
      all.includes("20261004110000_phase6c2_inventory_history_api.sql"),
    );
    assert.match(raw, /NOT APPLIED/);
    assert.equal((code.match(/\bbegin\s*;/g) ?? []).length, 1);
    assert.equal((code.match(/\bcommit\s*;/g) ?? []).length, 1);
  });

  it("has a SQL test that runs in one rolled-back transaction", () => {
    const p = join(
      root,
      "db",
      "tests",
      "phase6c2_admin_inventory_adjustment.test.sql",
    );
    assert.ok(existsSync(p));
    const t = strip(readFileSync(p, "utf8")).toLowerCase();
    assert.ok(/^\s*begin;/m.test(t));
    assert.ok(/rollback;\s*$/.test(t.trim()));
    assert.doesNotMatch(t, /\bcommit\b/);
  });
});

describe("Phase 6C.2.2A.2 migration: scope", () => {
  it("creates exactly one function and nothing else", () => {
    const creates = [
      ...code.matchAll(/\bcreate\s+(?:or\s+replace\s+)?(\w+)/g),
    ].map((m) => m[1]);
    assert.deepEqual(creates, ["function"]);
    assert.match(code, /create function public\.admin_adjust_inventory\(/);
    assert.doesNotMatch(code, /\balter\s+table\b/);
    assert.doesNotMatch(code, /\bdrop\b/);
    assert.doesNotMatch(code, /\bcreate\s+(trigger|policy|table|index|view)\b/);
  });

  it("does not create the history reader or touch order logic", () => {
    assert.doesNotMatch(code, /admin_list_inventory_adjustments/);
    for (const name of [
      "create_order",
      "set_order_status",
      "restock_cancelled_order",
    ]) {
      assert.doesNotMatch(
        code.replace(/public\.set_order_status/g, ""),
        new RegExp(
          `create\\s+(or\\s+replace\\s+)?function\\s+public\\.${name}`,
        ),
      );
    }
  });
});

describe("Phase 6C.2.2A.2 migration: function security", () => {
  it("is SECURITY DEFINER with search_path = public, pg_temp", () => {
    assert.match(code, /security definer/);
    assert.match(code, /set search_path = public, pg_temp/);
  });

  it("calls require_admin() before any lock, update or insert", () => {
    const gate = fnBody.indexOf("public.require_admin()");
    assert.ok(gate >= 0);
    for (const kw of [
      "for update",
      "for key share",
      "update public.",
      "insert into",
    ]) {
      assert.ok(fnBody.indexOf(kw) > gate, `${kw} must come after the gate`);
    }
  });

  it("sets the exact EXECUTE ACL", () => {
    const sig =
      "public\\.admin_adjust_inventory\\(uuid, integer, text, uuid, text\\)";
    assert.match(
      code,
      new RegExp(
        `revoke all on function ${sig} from public, anon, authenticated;`,
      ),
    );
    assert.match(
      code,
      new RegExp(`grant execute on function ${sig} to authenticated;`),
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
    assert.doesNotMatch(
      grants[0] ?? "",
      /\bon\s+(table\s+)?public\.(products|product_variants|inventory_adjustments)\b/,
    );
  });

  it("takes only a delta: no final quantity, snapshots or actor parameter", () => {
    const params =
      /create function public\.admin_adjust_inventory\(([\s\S]*?)\)\s*returns/.exec(
        code,
      )?.[1] ?? "";
    const names = params
      .split(",")
      .map((p) => p.trim().split(/\s+/)[0])
      .filter(Boolean);
    assert.deepEqual(names, [
      "p_product_id",
      "p_adjustment_quantity",
      "p_reason",
      "p_variant_id",
      "p_note",
    ]);
  });
});

describe("Phase 6C.2.2A.2 migration: stock semantics", () => {
  it("locks rows, uses auth.uid() as actor, computes in bigint and writes only stock_quantity", () => {
    assert.match(fnBody, /for update/);
    assert.match(fnBody, /for key share/);
    assert.match(fnBody, /require_admin\(\)/);
    assert.match(fnBody, /bigint/);
    assert.match(
      fnBody,
      /update public\.products set stock_quantity = v_new where id = p_product_id/,
    );
    assert.match(
      fnBody,
      /update public\.product_variants set stock_quantity = v_new where id = p_variant_id/,
    );
    assert.doesNotMatch(fnBody, /\bin_stock\s*=/);
    assert.doesNotMatch(fnBody, /\bset\s+in_stock\b/);
    assert.equal(
      (fnBody.match(/insert into public\.inventory_adjustments/g) ?? []).length,
      1,
    );
  });

  it("locks the product before the variant (the create_order order)", () => {
    assert.ok(
      fnBody.indexOf(
        "from public.products p where p.id = p_product_id for key share",
      ) > 0,
    );
    assert.ok(
      fnBody.indexOf("for key share") <
        fnBody.indexOf(
          "from public.product_variants v\n    where v.id = p_variant_id and v.product_id = p_product_id\n    for update",
        ),
    );
  });
});

describe("Phase 6C.2.2A.2 types", () => {
  const types = readFileSync(
    join(root, "src", "lib", "supabase", "types.ts"),
    "utf8",
  );
  it("declares the RPC with a delta-only argument type", () => {
    assert.match(
      types,
      /admin_adjust_inventory: \{\s*Args: AdminAdjustInventoryArgs;\s*Returns: AdminAdjustInventoryResult;/,
    );
    const args =
      /export type AdminAdjustInventoryArgs = \{([\s\S]*?)\n\};/.exec(
        types,
      )?.[1] ?? "";
    assert.match(args, /p_adjustment_quantity: number/);
    for (const banned of [
      "new_quantity",
      "previous_quantity",
      "changed_by",
      "p_user",
      "p_quantity:",
    ]) {
      assert.ok(!args.includes(banned), `${banned} must not be an argument`);
    }
  });
});
