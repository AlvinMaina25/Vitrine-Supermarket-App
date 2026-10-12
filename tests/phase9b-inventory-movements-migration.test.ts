// Phase 9B - STATIC checks on the inventory movements migration and its SQL test.
//
// No database is needed. The behavioural proof is db/tests/phase9b_inventory_movements.test.sql; this
// file guards the text-level promises about repository files (what the migration may and may not touch).
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const MIGRATION = "20261009040000_phase9b_inventory_movements.sql";
const migrations = join(root, "db", "migrations");
const sql = readFileSync(join(migrations, MIGRATION), "utf8");
const code = sql
  .split("\n")
  .filter((line) => !line.trim().startsWith("--"))
  .join("\n")
  .toLowerCase();

describe("Phase 9B migration", () => {
  it("sorts directly after the 9A migration and is the only phase9b migration", () => {
    const names = readdirSync(migrations)
      .filter((n) => n.endsWith(".sql"))
      .sort();
    const i9a = names.indexOf("20261009030000_phase9a_catalog_integrity.sql");
    assert.ok(i9a >= 0);
    assert.equal(names[i9a + 1], MIGRATION);
    assert.equal(names.filter((n) => n.includes("_phase9b_")).length, 1);
  });

  it("runs in one transaction with a precondition, a run-once guard and a self-check", () => {
    assert.match(code, /^\s*begin;/);
    assert.match(code, /commit;\s*$/);
    assert.ok(code.includes("precondition failed"));
    assert.ok(code.includes("self-check failed"));
    assert.ok(code.includes("not running it twice"));
  });

  it("extends the ledger with order_id (ON DELETE RESTRICT) and a movement_kind CHECK", () => {
    assert.match(
      code,
      /add column order_id uuid references public\.orders \(id\) on delete restrict/,
    );
    assert.match(
      code,
      /add column movement_kind text not null default 'admin_adjustment'/,
    );
    assert.match(code, /inventory_adjustments_movement_kind_valid/);
    assert.match(code, /inventory_adjustments_order_id_kind/);
  });

  it("does not re-add the ledger indexes or the non-negative stock CHECKs that already exist", () => {
    assert.doesNotMatch(
      code,
      /create index inventory_adjustments_(product|variant)_idx/,
    );
    assert.doesNotMatch(
      code,
      /add constraint (products|product_variants)_stock_nonnegative/,
    );
  });

  it("writes the movement from AFTER UPDATE OF stock_quantity triggers gated by WHEN old is distinct from new", () => {
    for (const table of ["products", "product_variants"]) {
      assert.match(
        code,
        new RegExp(
          `after update of stock_quantity on public\\.${table}\\s+for each row\\s+when \\(old\\.stock_quantity is distinct from new\\.stock_quantity\\)`,
        ),
      );
    }
    assert.doesNotMatch(
      code,
      /after insert on public\.(products|product_variants)/,
    );
  });

  it("avoids the double write with a transaction-local skip flag set around the stock UPDATE", () => {
    assert.match(code, /set_config\('app\.inventory_ledger_skip'/);
    assert.match(code, /set_config\('app\.inventory_ledger_skip', '', true\)/);
    // exactly one ledger insert inside admin_adjust_inventory (the function keeps its own row)
    const start = code.indexOf(
      "create or replace function public.admin_adjust_inventory(",
    );
    const end = code.indexOf(
      "revoke all on function public.admin_adjust_inventory",
    );
    const fn = code.slice(start, end);
    assert.equal(
      fn.split("insert into public.inventory_adjustments").length - 1,
      1,
    );
    assert.ok(fn.includes("insert into public.admin_audit_log"));
  });

  it("keeps admin_adjust_inventory grants as before (authenticated only)", () => {
    assert.match(
      code,
      /revoke all on function public\.admin_adjust_inventory\(uuid, integer, text, uuid, text\) from public, anon, authenticated;/,
    );
    assert.match(
      code,
      /grant execute on function public\.admin_adjust_inventory\(uuid, integer, text, uuid, text\) to authenticated;/,
    );
  });

  it("does not touch create_order() or restock_cancelled_order()", () => {
    assert.doesNotMatch(
      code,
      /create (or replace )?function public\.create_order/,
    );
    assert.doesNotMatch(
      code,
      /create (or replace )?function public\.restock_cancelled_order/,
    );
    assert.doesNotMatch(code, /drop (trigger|function)/);
  });

  it("adds low_stock_threshold (null or 0..1000) and a partial index on both stock tables", () => {
    for (const table of ["products", "product_variants"]) {
      assert.ok(code.includes(`${table}_low_stock_threshold_valid`));
      assert.match(
        code,
        new RegExp(
          `create index ${table}_low_stock_idx\\s+on public\\.${table} \\(stock_quantity\\)\\s+where low_stock_threshold is not null and stock_quantity <= low_stock_threshold;`,
        ),
      );
    }
    assert.match(
      code,
      /low_stock_threshold is null or low_stock_threshold between 0 and 1000/,
    );
  });

  it("makes the ledger append-only (row trigger + TRUNCATE guard) and only allows changed_by -> NULL", () => {
    assert.match(
      code,
      /before update or delete on public\.inventory_adjustments/,
    );
    assert.match(code, /before truncate on public\.inventory_adjustments/);
    assert.match(code, /new\.changed_by is null/);
    assert.match(code, /old\.changed_by is not null/);
    assert.match(
      code,
      /revoke all on table public\.inventory_adjustments from public, anon, authenticated, service_role;/,
    );
    assert.match(
      code,
      /grant select, insert on table public\.inventory_adjustments to service_role;/,
    );
  });

  it("makes every new trigger function SECURITY DEFINER with a pinned search_path and no browser EXECUTE", () => {
    const fns = [
      "inventory_log_stock_change",
      "inventory_order_ctx_set",
      "inventory_order_ctx_clear",
      "inventory_adjustments_guard",
    ];
    for (const f of fns) {
      const re = new RegExp(
        `create function public\\.${f}\\(\\)\\s+returns trigger\\s+language plpgsql\\s+volatile\\s+security definer\\s+set search_path = public, pg_temp`,
      );
      assert.match(code, re, f);
      assert.match(
        code,
        new RegExp(
          `revoke all on function public\\.${f}\\(\\) from public, anon, authenticated;`,
        ),
      );
    }
  });

  it("adds no table, no policy and no location_id / supplier_id column", () => {
    assert.doesNotMatch(code, /create table/);
    assert.doesNotMatch(code, /create policy|drop policy/);
    assert.doesNotMatch(code, /location_id|supplier_id/);
  });

  it("keeps money out of it (no price columns touched)", () => {
    assert.doesNotMatch(code, /price_cents/);
  });
});

describe("Phase 9B SQL test registration", () => {
  it("exists, rolls back, uses the t9b- prefix, and is listed in run-sql-tests.sh", () => {
    const test = readFileSync(
      join(root, "db", "tests", "phase9b_inventory_movements.test.sql"),
      "utf8",
    );
    assert.match(test, /^begin;/m);
    assert.match(test, /rollback;\s*$/);
    assert.ok(test.includes("t9b-"));
    const runner = readFileSync(
      join(root, "scripts", "integration", "run-sql-tests.sh"),
      "utf8",
    );
    assert.ok(runner.includes("phase9b_inventory_movements"));
  });
});
