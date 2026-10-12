// Phase 9A - STATIC checks on the catalog integrity migration and its SQL test.
//
// No database is needed. The behavioural proof is db/tests/phase9a_catalog_integrity.test.sql; this
// file guards the text-level promises about repository files.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const MIGRATION = "20261009030000_phase9a_catalog_integrity.sql";
const migrations = join(root, "db", "migrations");
const sql = readFileSync(join(migrations, MIGRATION), "utf8");
const code = sql
  .split("\n")
  .filter((line) => !line.trim().startsWith("--"))
  .join("\n")
  .toLowerCase();

describe("Phase 9A migration", () => {
  it("is the last phase9a migration and sorts after 20261009020000", () => {
    const names = readdirSync(migrations)
      .filter((n) => n.endsWith(".sql"))
      .sort();
    const phase9a = names.filter((n) => n.includes("_phase9a_"));
    assert.equal(phase9a[phase9a.length - 1], MIGRATION);
    assert.ok(
      names.includes("20261009020000_phase8_validate_coupon_total.sql"),
    );
  });

  it("runs in one transaction with a precondition and a self-check", () => {
    assert.match(code, /^\s*begin;/);
    assert.match(code, /commit;\s*$/);
    assert.ok(code.includes("precondition failed"));
    assert.ok(code.includes("self-check failed"));
  });

  it("rebuilds both SKU indexes under their existing names on lower(sku)", () => {
    for (const name of ["products_sku_key", "product_variants_sku_key"]) {
      assert.match(code, new RegExp(`drop index public\\.${name};`));
      assert.match(
        code,
        new RegExp(
          `create unique index ${name}\\s+on public\\.\\w+ \\(lower\\(sku\\)\\) where sku is not null;`,
        ),
      );
    }
  });

  it("adds the two order_items foreign-key indexes", () => {
    assert.match(code, /create index if not exists order_items_product_id_idx/);
    assert.match(code, /create index if not exists order_items_variant_id_idx/);
  });

  it("adds no table, function, grant or policy, and does not touch create_order()", () => {
    assert.doesNotMatch(code, /create table/);
    assert.doesNotMatch(code, /create (or replace )?function/);
    assert.doesNotMatch(code, /\b(grant|revoke)\b/);
    assert.doesNotMatch(code, /create policy|drop policy/);
    assert.doesNotMatch(code, /create_order/);
  });

  it("does not drop or change the existing price / compare_at CHECK constraints", () => {
    assert.doesNotMatch(code, /drop constraint/);
    assert.doesNotMatch(code, /add constraint/);
  });
});

describe("Phase 9A SQL test registration", () => {
  it("exists, rolls back, and is listed in run-sql-tests.sh", () => {
    const test = readFileSync(
      join(root, "db", "tests", "phase9a_catalog_integrity.test.sql"),
      "utf8",
    );
    assert.match(test, /^begin;/m);
    assert.match(test, /rollback;\s*$/);
    const runner = readFileSync(
      join(root, "scripts", "integration", "run-sql-tests.sh"),
      "utf8",
    );
    assert.ok(runner.includes("phase9a_catalog_integrity"));
  });
});
