// Phase 8 - STATIC checks on the discounts & promotions migration and its repository promises.
//
// No database is needed. The behavioural proof is db/tests/phase8_discounts_promotions.test.sql
// (and phase8_coupon_concurrency.sh); neither has been executed by the author. This file only
// guards text-level promises that can be checked on the files.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const NAME = "20261009010000_phase8_discounts_promotions.sql";
const sql = readFileSync(join(root, "db", "migrations", NAME), "utf8");
const code = sql
  .split("\n")
  .filter((line) => !line.trim().startsWith("--"))
  .join("\n");

describe("phase 8 migration file", () => {
  it("is timestamped after every earlier-phase migration (later Phase 8, 9 and 20 migrations may follow it)", () => {
    const names = readdirSync(join(root, "db", "migrations"))
      .filter((n) => n.endsWith(".sql"))
      .sort();
    assert.ok(names.includes(NAME));
    for (const other of names.filter(
      (n) =>
        n !== NAME &&
        !n.includes("phase8") &&
        !n.includes("phase9") &&
        !n.includes("phase20"),
    )) {
      assert.ok(other < NAME, `${other} must sort before ${NAME}`);
    }
  });

  it("is one transaction with a self-check before the commit", () => {
    assert.equal((code.match(/^begin;/gm) ?? []).length, 1);
    assert.equal((code.match(/^commit;/gm) ?? []).length, 1);
    assert.ok(code.indexOf("$chk$") < code.lastIndexOf("commit;"));
    assert.ok(code.includes("Phase 8 self-check failed"));
    assert.equal((code.match(/\$\$/g) ?? []).length % 2, 0);
  });

  it("pins the live create_order() it replaces and drops the 12-argument overload", () => {
    assert.ok(code.includes("1f087e8de9c1abd28fd5b0361588e96d"));
    assert.ok(code.includes("drop function public.create_order("));
    assert.ok(code.includes("p_coupon_code text default null"));
  });

  it("turns RLS on for both tables and grants API roles nothing on them", () => {
    for (const table of ["promotions", "promotion_redemptions"]) {
      assert.ok(
        code.includes(`alter table public.${table} enable row level security`),
      );
      assert.ok(
        code.includes(
          `revoke all on public.${table} from public, anon, authenticated, service_role`,
        ),
      );
      assert.ok(
        !new RegExp(`grant\\s+[^;]*on\\s+public\\.${table}\\b`, "i").test(code),
      );
      assert.ok(
        !new RegExp(`create policy[^;]*on\\s+public\\.${table}\\b`, "i").test(
          code,
        ),
      );
    }
  });

  it("every function is SECURITY DEFINER with a pinned search_path", () => {
    const functions = code.match(/create function [^;]*?\$\$/gs) ?? [];
    assert.ok(functions.length >= 13, `found ${functions.length}`);
    for (const fn of functions) {
      assert.ok(/security definer/.test(fn), fn.slice(0, 80));
      assert.ok(/set search_path = public, pg_temp/.test(fn), fn.slice(0, 80));
    }
  });

  it("revokes every function from PUBLIC and anon; only the customer/admin ones reach authenticated", () => {
    const granted = [
      ...code.matchAll(/grant execute on function public\.(\w+)\(/g),
    ].map((m) => m[1]);
    assert.deepEqual([...new Set(granted)].sort(), [
      "admin_create_promotion",
      "admin_list_promotions",
      "admin_set_promotion_active",
      "admin_update_promotion",
      "create_order",
      "validate_coupon",
    ]);
    assert.ok(
      !/grant[^;]*\bto\b[^;]*\b(anon|public|service_role)\b/i.test(
        code.replace(/revoke[^;]*;/gi, ""),
      ),
    );
  });

  it("gates every admin function on require_admin() as its first statement", () => {
    for (const fn of [
      "admin_create_promotion",
      "admin_update_promotion",
      "admin_set_promotion_active",
      "admin_list_promotions",
    ]) {
      const start = code.indexOf(`create function public.${fn}(`);
      const body = code.slice(
        start,
        code.indexOf("$$;", code.indexOf("as $$", start) + 5),
      );
      const afterBegin = body.slice(body.indexOf("begin") + 5).trimStart();
      assert.ok(afterBegin.startsWith("perform public.require_admin()"), fn);
    }
  });

  it("takes the limited-promotion lock before counting, and never in the preview", () => {
    const resolve = code.slice(
      code.indexOf("create function public.resolve_promotion("),
    );
    assert.ok(
      resolve.indexOf("for update") < resolve.indexOf("promotion_evaluate("),
    );
    const validate = code.slice(
      code.indexOf("create function public.validate_coupon("),
      code.indexOf("create function public.orders_sync_promotion_redemption("),
    );
    assert.ok(!/for update/i.test(validate));
  });

  it("orders the work in create_order: slot lock, then discount, then order, then redemption", () => {
    const fn = code.slice(code.indexOf("create function public.create_order("));
    const at = (s: string) => fn.indexOf(s);
    assert.ok(at("lock_delivery_slot") < at("public.resolve_promotion("));
    assert.ok(
      at("public.resolve_promotion(") < at("insert into public.orders"),
    );
    assert.ok(
      at("insert into public.orders") <
        at("insert into public.promotion_redemptions"),
    );
    assert.ok(at("account_suspended") < at("pg_advisory_xact_lock"));
  });

  it("makes the redemption one-per-order and the order snapshot immutable", () => {
    assert.ok(
      code.includes(
        "constraint promotion_redemptions_order_id_key unique (order_id)",
      ),
    );
    assert.ok(code.includes("discount_snapshot_immutable"));
    assert.ok(code.includes("create trigger orders_guard_discount_snapshot"));
  });

  it("does not edit an earlier migration (this change only adds one file)", () => {
    assert.ok(!/alter function public\.create_order/i.test(code));
  });
});

describe("older SQL tests follow the 13-argument create_order()", () => {
  it("no test still names the 12-argument signature", () => {
    const old = "text,text,text,integer,uuid)";
    for (const file of readdirSync(join(root, "db", "tests")).filter((n) =>
      n.endsWith(".sql"),
    )) {
      const text = readFileSync(join(root, "db", "tests", file), "utf8");
      assert.ok(
        !text.includes(old),
        `${file} still names create_order() with 12 arguments`,
      );
    }
  });
});
