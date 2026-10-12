// Phase 6F.2 - STATIC checks for the delivery admin query module (src/features/admin/delivery.ts).
//
// The module imports the "@/" alias and the Supabase client, so it cannot run under node --test.
// What can be proved without a database: it calls exactly the eleven 6F.1A/6F.1B functions, never
// touches a table, those functions exist in the migrations, types.ts mirrors their argument names,
// and the pure argument builders send exactly the SQL parameter names.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { buildUpdateDeliveryMethodArgs } from "../src/features/admin/delivery-method-result.ts";
import {
  buildClearDeliverySlotOverrideArgs,
  buildSaveDeliverySlotOverrideArgs,
} from "../src/features/admin/delivery-slot-override-result.ts";
import {
  buildSaveDeliverySlotTemplateArgs,
  buildSetDeliverySlotTemplateActiveArgs,
} from "../src/features/admin/delivery-slot-template-result.ts";
import {
  buildSaveDeliveryZoneFeeArgs,
  buildSetDeliveryZoneFeeActiveArgs,
} from "../src/features/admin/delivery-zone-fee-result.ts";
import {
  buildSaveDeliveryZoneArgs,
  buildSetDeliveryZoneActiveArgs,
} from "../src/features/admin/delivery-zone-result.ts";
import { toSlotsListArgs } from "../src/features/admin/delivery-management.ts";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");
const source = read("../src/features/admin/delivery.ts");
const types = read("../src/lib/supabase/types.ts");
const m1a = read(
  "../db/migrations/20261005010000_phase6f1a_delivery_admin_methods_zones.sql",
);
const m1b = read(
  "../db/migrations/20261005020000_phase6f1b_delivery_admin_slots.sql",
);

const EXPECTED = [
  "admin_clear_delivery_slot_override",
  "admin_list_delivery_config",
  "admin_list_delivery_slots",
  "admin_save_delivery_slot_override",
  "admin_save_delivery_slot_template",
  "admin_save_delivery_zone",
  "admin_save_delivery_zone_fee",
  "admin_set_delivery_slot_template_active",
  "admin_set_delivery_zone_active",
  "admin_set_delivery_zone_fee_active",
  "admin_update_delivery_method",
];

/** Parameter names of a function as declared in its migration, e.g. ["p_zone_id", ...]. */
function sqlParams(migration: string, name: string): string[] {
  const match = new RegExp(
    `create function public\\.${name}\\(([^)]*)\\)`,
  ).exec(migration);
  assert.ok(match, `${name} not found`);
  return (match[1] ?? "")
    .split(",")
    .map((p) => p.trim().split(/\s+/)[0] ?? "")
    .filter((p) => p !== "");
}

/** Argument names of a function as declared in types.ts. */
function typeArgs(name: string): string[] {
  const start = types.indexOf(`      ${name}: {`);
  assert.ok(start >= 0, `${name} missing from types.ts`);
  const end = types.indexOf("Returns:", start);
  const block = types.slice(start, end);
  return [...block.matchAll(/\b(p_[a-z_]+)\??:/g)].map((m) => m[1] ?? "");
}

describe("delivery.ts RPC calls", () => {
  it("calls exactly the eleven 6F.1A/6F.1B functions, each once", () => {
    const names = [...source.matchAll(/"(admin_[a-z_]+)"/g)]
      .map((m) => m[1])
      .sort();
    assert.deepEqual(names, EXPECTED);
  });

  it("only uses .rpc() and never touches a table, storage or raw SQL", () => {
    assert.ok(!/\.from\(/.test(source), "delivery.ts must not call .from()");
    assert.ok(!/\.(insert|update|upsert|delete|select)\(/.test(source));
    assert.ok(!/\.storage\b/.test(source));
    assert.ok(!/\bfetch\(/.test(source));
    const rpcCalls = [...source.matchAll(/\.rpc\(/g)].length;
    assert.equal(rpcCalls, EXPECTED.length);
    for (const table of [
      "delivery_methods",
      "delivery_zones",
      "delivery_zone_fees",
      "delivery_slot_templates",
      "delivery_slot_overrides",
      "orders",
      "admin_audit_log",
    ]) {
      assert.ok(
        !source.includes(`"${table}"`),
        `delivery.ts must not name table ${table}`,
      );
    }
  });

  it("does not import the old direct-write module or the browser client directly", () => {
    assert.ok(!/features\/delivery\/admin/.test(source));
    assert.ok(!/supabase-js/.test(source));
    assert.match(source, /requireSupabase\(\)/);
  });

  it("keeps every query key under admin/delivery and maps every error", () => {
    const keys = [...source.matchAll(/queryKey: \["admin", "delivery"/g)];
    assert.equal(keys.length, 2);
    assert.equal(
      [...source.matchAll(/toAdminDeliveryError\(error\)/g)].length,
      EXPECTED.length,
    );
  });

  it("every function exists in its migration and is mirrored in types.ts", () => {
    for (const name of EXPECTED) {
      const migration = name.includes("slot") ? m1b : m1a;
      assert.match(
        migration,
        new RegExp(`create function public\\.${name}\\(`),
        name,
      );
      assert.ok(
        types.includes(`      ${name}: {`),
        `${name} missing from types.ts`,
      );
    }
  });

  it("types.ts argument names equal the SQL parameter names", () => {
    for (const name of EXPECTED) {
      const migration = name.includes("slot") ? m1b : m1a;
      const sql = sqlParams(migration, name);
      assert.deepEqual(typeArgs(name).sort(), [...sql].sort(), name);
    }
  });
});

describe("argument builders send the SQL parameter names", () => {
  const keysOf = (args: object) => Object.keys(args).sort();

  it("matches every write function", () => {
    const zone = buildSaveDeliveryZoneArgs({
      zoneId: null,
      code: "ab",
      name: "A",
      county: "",
      description: "",
      towns: [],
      position: null,
    });
    const fee = buildSaveDeliveryZoneFeeArgs({
      feeId: null,
      zoneId: "z",
      methodCode: "standard",
      feeCents: 1,
      freeOverCents: null,
      minOrderCents: null,
    });
    const method = buildUpdateDeliveryMethodArgs({
      code: "standard",
      baseFeeCents: 1,
      freeOverCents: null,
      minOrderCents: 0,
      isActive: true,
      currentIsActive: true,
      reason: "",
    });
    const template = buildSaveDeliverySlotTemplateArgs({
      templateId: null,
      label: "A",
      startTime: "08:00",
      endTime: "09:00",
      dayOfWeek: null,
      capacity: null,
      position: null,
    });
    const override = buildSaveDeliverySlotOverrideArgs({
      templateId: "t",
      slotDate: "2026-10-08",
      capacity: 1,
      closed: false,
      note: "",
    });
    const built = {
      admin_save_delivery_zone: zone,
      admin_save_delivery_zone_fee: fee,
      admin_update_delivery_method: method,
      admin_save_delivery_slot_template: template,
      admin_save_delivery_slot_override: override,
      admin_set_delivery_zone_active: buildSetDeliveryZoneActiveArgs(
        "z",
        true,
        "r",
      ),
      admin_set_delivery_zone_fee_active: buildSetDeliveryZoneFeeActiveArgs(
        "f",
        true,
        "r",
      ),
      admin_set_delivery_slot_template_active:
        buildSetDeliverySlotTemplateActiveArgs("t", true, "r"),
      admin_clear_delivery_slot_override: buildClearDeliverySlotOverrideArgs(
        "t",
        "2026-10-08",
        "r",
      ),
    };
    for (const [name, result] of Object.entries(built)) {
      assert.ok(result.ok, name);
      const migration = name.includes("slot") ? m1b : m1a;
      assert.deepEqual(
        keysOf(result.args),
        [...sqlParams(migration, name)].sort(),
        name,
      );
    }
    assert.deepEqual(
      keysOf(toSlotsListArgs({}, "2026-10-07")),
      [...sqlParams(m1b, "admin_list_delivery_slots")].sort(),
    );
  });
});

describe("migrations are admin-only and money-safe (what the frontend relies on)", () => {
  it("every function runs the admin gate and is granted to authenticated only", () => {
    for (const name of EXPECTED) {
      const migration = name.includes("slot") ? m1b : m1a;
      const body = migration.slice(
        migration.indexOf(`create function public.${name}(`),
      );
      assert.match(body.slice(0, 1800), /require_admin\(\)/, name);
      assert.match(
        migration,
        new RegExp(
          `grant execute on function public\\.${name}\\([^)]*\\) to authenticated`,
        ),
        name,
      );
      assert.match(
        migration,
        new RegExp(
          `revoke all on function public\\.${name}\\([^)]*\\) from public, anon, authenticated`,
        ),
        name,
      );
    }
  });
});
