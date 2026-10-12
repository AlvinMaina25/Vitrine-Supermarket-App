// Phase 6C.2.2A.1 - STATIC checks on the inventory adjustment history migration.
//
// A SQL script cannot read the repository's files, so the text-level promise lives here:
// the migration may create the audit table and nothing else. It must not mutate stock, create
// functions/triggers/views/policies, or grant the browser roles anything. These run with the
// rest of the suite (`npm test`) and need no database.
//
// The database-side proof of the same promises is db/tests/phase6c2_inventory_adjustment_history.test.sql.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const MIGRATION_NAME =
  "20261004090000_phase6c2_inventory_adjustment_history.sql";
const TEST_NAME = "phase6c2_inventory_adjustment_history.test.sql";
const migrationPath = join(root, "db", "migrations", MIGRATION_NAME);
const sqlTestPath = join(root, "db", "tests", TEST_NAME);

/**
 * Remove SQL comments and single-quoted string literals (with '' escapes), keeping everything
 * else - including the bodies of DO $$ ... $$ blocks, which are real code and must be scanned.
 * Quoted text can therefore never hide, or fake, a statement.
 */
function stripCommentsAndStrings(sql: string): string {
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
      out += " ";
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

const raw = readFileSync(migrationPath, "utf8");
const code = stripCommentsAndStrings(raw).toLowerCase();
// "on delete set null" / "on delete restrict" are foreign-key rules, not DML.
const codeNoFkRules = code.replace(
  /on\s+delete\s+(restrict|set\s+null|cascade|no\s+action)/g,
  " ",
);

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === ".git") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

describe("Phase 6C.2.2A.1 migration: file", () => {
  it("is the exact required file name and the 6C.2.2A.2 and 6C.2.2B.1 migrations follow it", () => {
    assert.ok(existsSync(migrationPath), `${MIGRATION_NAME} must exist`);
    const all = readdirSync(join(root, "db", "migrations"))
      .filter((f) => f.endsWith(".sql"))
      .sort();
    const after = all.slice(all.indexOf(MIGRATION_NAME) + 1);
    assert.ok(all.includes(MIGRATION_NAME));
    assert.ok(
      after.includes("20261004100000_phase6c2_admin_inventory_adjustment.sql"),
    );
    assert.ok(
      after.includes("20261004110000_phase6c2_inventory_history_api.sql"),
    );
    assert.equal(
      all.filter((f) => f.includes("inventory_adjustment_history")).length,
      1,
    );
  });

  it("states that it is NOT applied, and runs in one transaction", () => {
    assert.match(raw, /NOT APPLIED/);
    assert.equal((code.match(/\bbegin\s*;/g) ?? []).length, 1);
    assert.equal((code.match(/\bcommit\s*;/g) ?? []).length, 1);
    assert.ok(code.indexOf("begin;") < code.indexOf("commit;"));
  });
});

describe("Phase 6C.2.2A.1 migration: NO STOCK MUTATION", () => {
  it("contains no INSERT / UPDATE / DELETE / TRUNCATE / MERGE / COPY statement at all", () => {
    assert.doesNotMatch(codeNoFkRules, /\binsert\s+into\b/);
    assert.doesNotMatch(codeNoFkRules, /\bupdate\s+[\w."]+\s+set\b/);
    assert.doesNotMatch(codeNoFkRules, /\bupdate\b/);
    assert.doesNotMatch(codeNoFkRules, /\bdelete\s+from\b/);
    assert.doesNotMatch(codeNoFkRules, /\bdelete\b/);
    assert.doesNotMatch(codeNoFkRules, /\btruncate\b/);
    assert.doesNotMatch(codeNoFkRules, /\bmerge\s+into\b/);
    assert.doesNotMatch(codeNoFkRules, /\bcopy\b/);
  });

  it("never assigns products.stock_quantity, product_variants.stock_quantity or in_stock", () => {
    assert.doesNotMatch(codeNoFkRules, /\bset\s+(stock_quantity|in_stock)\b/);
    assert.doesNotMatch(codeNoFkRules, /\b(stock_quantity|in_stock)\s*=[^=]/);
  });

  it("does not alter, index, trigger or re-grant products or product_variants", () => {
    assert.doesNotMatch(
      codeNoFkRules,
      /\balter\s+table\s+(only\s+)?public\.(products|product_variants)\b/,
    );
    assert.doesNotMatch(
      codeNoFkRules,
      /\b(create|drop)\s+(unique\s+)?(index|trigger|policy)\b[^;]*\bon\s+public\.(products|product_variants)\b/,
    );
    assert.doesNotMatch(
      codeNoFkRules,
      /\b(grant|revoke)\b[^;]*\bpublic\.(products|product_variants)\b/,
    );
    assert.doesNotMatch(codeNoFkRules, /\bdrop\s+table\b/);
  });

  it("creates no function, trigger, view, policy, type, sequence or extension", () => {
    for (const kind of [
      "function",
      "or\\s+replace\\s+function",
      "procedure",
      "trigger",
      "view",
      "materialized\\s+view",
      "policy",
      "type",
      "sequence",
      "extension",
      "rule",
    ]) {
      assert.doesNotMatch(
        codeNoFkRules,
        new RegExp(`\\bcreate\\s+${kind}\\b`),
        `create ${kind}`,
      );
    }
  });

  it("creates exactly one table: public.inventory_adjustments", () => {
    const tables = [
      ...codeNoFkRules.matchAll(
        /\bcreate\s+(?:temp(?:orary)?\s+)?table\s+([\w."]+)/g,
      ),
    ].map((m) => m[1]);
    assert.deepEqual(tables, ["public.inventory_adjustments"]);
  });
});

describe("Phase 6C.2.2A.1 migration: table shape", () => {
  const tableBody =
    /create table public\.inventory_adjustments \(([\s\S]*?)\n\);/.exec(
      stripCommentsAndStrings(raw).toLowerCase(),
    )?.[1] ?? "";

  it("has exactly the intended columns and no second stock authority", () => {
    assert.ok(tableBody.length > 0, "create table block found");
    const columns = tableBody
      .split("\n")
      .map((l) => l.trim())
      .filter(
        (l) =>
          l &&
          !l.startsWith("constraint") &&
          !l.startsWith("check") &&
          !l.startsWith("new_quantity::"),
      )
      .map((l) => l.split(/\s+/)[0] ?? "")
      .filter((w) => /^[a-z_]+$/.test(w));
    assert.deepEqual(columns, [
      "id",
      "product_id",
      "variant_id",
      "previous_quantity",
      "adjustment_quantity",
      "new_quantity",
      "reason",
      "note",
      "changed_by",
      "created_at",
    ]);
    for (const banned of [
      "current_quantity",
      "stock_quantity",
      "in_stock",
      "balance",
      "on_hand",
    ]) {
      assert.ok(!columns.includes(banned), `no ${banned} column`);
    }
  });

  it("references the stock tables with ON DELETE RESTRICT and auth.users with SET NULL", () => {
    const sql = tableBody;
    assert.match(
      sql,
      /product_id uuid not null references public\.products \(id\) on delete restrict/,
    );
    assert.match(
      sql,
      /variant_id uuid references public\.product_variants \(id\) on delete restrict/,
    );
    assert.match(
      sql,
      /changed_by uuid references auth\.users \(id\) on delete set null/,
    );
  });
});

describe("Phase 6C.2.2A.1 migration: security", () => {
  it("revokes everything from public, anon and authenticated", () => {
    assert.match(
      code,
      /revoke all on table public\.inventory_adjustments from public, anon, authenticated;/,
    );
  });

  it("grants anon / authenticated nothing, anywhere", () => {
    for (const stmt of code.split(";").filter((s) => /\bgrant\b/.test(s))) {
      assert.doesNotMatch(
        stmt,
        /\b(anon|authenticated|public)\b\s*$/m,
        `browser grant: ${stmt.trim()}`,
      );
      assert.doesNotMatch(
        stmt,
        /\bto\b[^;]*\b(anon|authenticated)\b/,
        `browser grant: ${stmt.trim()}`,
      );
    }
    assert.match(
      code,
      /grant all on table public\.inventory_adjustments to service_role;/,
    );
  });

  it("enables row level security and defines no policy", () => {
    assert.match(
      code,
      /alter table public\.inventory_adjustments enable row level security;/,
    );
    assert.doesNotMatch(code, /\bcreate\s+policy\b/);
  });
});

describe("Phase 6C.2.2A.1 phase boundary", () => {
  // Phase 6C.2.2A.1 originally forbade ANY mention of the table in src/. Phase 6D-4 legitimately
  // adds the history screen, which calls the admin function admin_list_inventory_adjustments()
  // (and its name contains the table name). What must stay true is that the application never
  // touches the TABLE itself: no .from("inventory_adjustments"), no schema-qualified reference.
  it("never reads or writes the table directly from the application", () => {
    const hits = walk(join(root, "src")).filter((f) => {
      if (!/\.(ts|tsx)$/.test(f)) return false;
      const text = readFileSync(f, "utf8");
      return (
        /\.from\(\s*["'`]inventory_adjustments["'`]/.test(text) ||
        /\bpublic\.inventory_adjustments\b/.test(text)
      );
    });
    assert.deepEqual(hits, []);
  });

  it("has a SQL test that runs in one rolled-back transaction", () => {
    assert.ok(existsSync(sqlTestPath), `${TEST_NAME} must exist`);
    const t = stripCommentsAndStrings(
      readFileSync(sqlTestPath, "utf8"),
    ).toLowerCase();
    assert.ok(/^\s*begin;/m.test(t));
    assert.ok(/rollback;\s*$/.test(t.trim()));
    assert.doesNotMatch(t, /\bcommit\b/);
  });
});
