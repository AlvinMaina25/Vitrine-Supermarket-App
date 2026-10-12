// Phase 8 follow-up - STATIC checks on the validate_coupon() total migration.
//
// No database is needed. The behavioural proof is db/tests/phase8_validate_coupon_total.test.sql, which
// has NOT been executed by the author. This file only guards text-level promises.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const dir = join(root, "db", "migrations");
const PHASE8 = "20261009010000_phase8_discounts_promotions.sql";
const NAME = "20261009020000_phase8_validate_coupon_total.sql";
const sql = readFileSync(join(dir, NAME), "utf8");
const code = sql
  .split("\n")
  .filter((line) => !line.trim().startsWith("--"))
  .join("\n");

describe("phase 8 validate_coupon total migration", () => {
  it("is a new, later migration and the Phase 8 migration is untouched by it", () => {
    const names = readdirSync(dir)
      .filter((n) => n.endsWith(".sql"))
      .sort();
    assert.ok(NAME > PHASE8);
    // Later phases (9A and on) may follow it; it must be the last Phase 8 migration.
    assert.equal(names.filter((n) => n.includes("phase8")).pop(), NAME);
    assert.ok(
      !code.includes("create or replace function public.validate_coupon"),
    );
  });

  it("pins the replaced function body to the one in the Phase 8 file", () => {
    const phase8 = readFileSync(join(dir, PHASE8), "utf8").replace(/\r/g, "");
    const start = phase8.indexOf("create function public.validate_coupon(");
    const open = phase8.indexOf("as $$\n", start) + "as $$".length;
    const close = phase8.indexOf("\n$$;", open) + 1;
    const md5 = createHash("md5")
      .update(phase8.slice(open, close))
      .digest("hex");
    assert.ok(sql.includes(`'${md5}'`), `the precondition must pin md5 ${md5}`);
  });

  it("is one transaction with a self-check before the commit", () => {
    assert.equal((code.match(/^begin;/gm) ?? []).length, 1);
    assert.equal((code.match(/^commit;/gm) ?? []).length, 1);
    assert.ok(code.indexOf("$chk$") < code.indexOf("commit;"));
  });

  it("drops the 2-argument function and creates one 4-argument function", () => {
    assert.match(code, /drop function public\.validate_coupon\(jsonb, text\);/);
    assert.match(
      code,
      /create function public\.validate_coupon\(\s*p_items jsonb,\s*p_code text default null,\s*p_delivery_method text default null,\s*p_zone_id uuid default null\s*\)/,
    );
  });

  it("keeps the grant and search_path conventions", () => {
    assert.match(code, /security definer/);
    assert.match(code, /set search_path = public, pg_temp/);
    assert.match(
      code,
      /revoke all on function public\.validate_coupon\(jsonb, text, text, uuid\) from public, anon, service_role;/,
    );
    assert.match(
      code,
      /grant execute on function public\.validate_coupon\(jsonb, text, text, uuid\) to authenticated;/,
    );
  });

  it("takes no lock and takes the fee only from validate_delivery_selection()", () => {
    const start = code.indexOf("create function public.validate_coupon(");
    const body = code.slice(start, code.indexOf("$$;", start + 400));
    assert.ok(!/for update/i.test(body));
    assert.ok(
      body.includes(
        "public.validate_delivery_selection(p_delivery_method, p_zone_id, v_subtotal::integer)",
      ),
    );
    assert.ok(body.includes("'total_cents'"));
    assert.ok(body.includes("'delivery_fee_cents'"));
  });

  it("has a SQL test next to the other Phase 8 SQL tests", () => {
    const test = readFileSync(
      join(root, "db", "tests", "phase8_validate_coupon_total.test.sql"),
      "utf8",
    );
    assert.match(test, /^begin;/m);
    assert.match(test, /^rollback;/m);
    assert.ok(!/^commit;/m.test(test));
  });
});
