// Phase 6E.2 - STATIC checks for the customers query module (src/features/admin/customers.ts).
//
// The module imports the "@/" alias and the Supabase client, so it cannot run under node --test.
// What can be proved without a database is that it calls exactly the 6E.1 functions, that those
// exist in the migrations, and that the argument names we send are the SQL parameter names.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { buildSetCustomerStatusArgs } from "../src/features/admin/customer-status-result.ts";
import { buildUpdateCustomerNotesArgs } from "../src/features/admin/customer-notes-result.ts";
import { toAdminGetCustomerArgs } from "../src/features/admin/customer-detail-result.ts";
import { toCustomersListArgs } from "../src/features/admin/customers-management.ts";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");
const source = read("../src/features/admin/customers.ts");
const types = read("../src/lib/supabase/types.ts");
const migrations = {
  list: read(
    "../db/migrations/20261004160000_phase6e1b3_customer_status_notes_read.sql",
  ),
  get: read(
    "../db/migrations/20261004160000_phase6e1b3_customer_status_notes_read.sql",
  ),
  status: read(
    "../db/migrations/20261004140000_phase6e1b1_customer_status_audit.sql",
  ),
  notes: read("../db/migrations/20261004150000_phase6e1b2_customer_notes.sql"),
};

describe("customers.ts RPC calls", () => {
  it("calls exactly the four 6E.1 functions", () => {
    const names = [...source.matchAll(/"(admin_[a-z_]+)"/g)]
      .map((m) => m[1])
      .sort();
    assert.deepEqual(names, [
      "admin_get_customer",
      "admin_list_customers",
      "admin_set_customer_status",
      "admin_update_customer_notes",
    ]);
  });

  it("each function exists in its migration and is mirrored in types.ts", () => {
    assert.match(migrations.list, /function public\.admin_list_customers\(/);
    assert.match(migrations.get, /function public\.admin_get_customer\(/);
    assert.match(
      migrations.status,
      /function public\.admin_set_customer_status\(/,
    );
    assert.match(
      migrations.notes,
      /function public\.admin_update_customer_notes\(/,
    );
    for (const name of [
      "admin_list_customers",
      "admin_get_customer",
      "admin_set_customer_status",
      "admin_update_customer_notes",
    ]) {
      assert.ok(types.includes(`${name}: {`), name);
    }
  });

  it("never reads or writes a table directly", () => {
    assert.doesNotMatch(source, /\.from\(/);
  });

  it("sends only argument names the SQL functions declare", () => {
    const list = toCustomersListArgs({ q: "a", status: "active", page: 2 });
    assert.deepEqual(Object.keys(list).sort(), [
      "p_page",
      "p_page_size",
      "p_search",
      "p_status",
    ]);
    for (const key of Object.keys(list))
      assert.ok(migrations.list.includes(`${key} `), key);

    for (const key of Object.keys(toAdminGetCustomerArgs("c1"))) {
      assert.ok(migrations.get.includes(`${key} uuid`), key);
    }

    const status = buildSetCustomerStatusArgs("c1", "suspended", "fraud");
    assert.ok(status.ok);
    for (const key of Object.keys(status.args)) {
      assert.ok(migrations.status.includes(`${key} `), key);
    }

    const notes = buildUpdateCustomerNotesArgs("c1", "hi");
    assert.ok(notes.ok);
    for (const key of Object.keys(notes.args)) {
      assert.ok(migrations.notes.includes(`${key} `), key);
    }
  });

  it("the list RPC is the 4-argument form with p_status", () => {
    assert.match(
      migrations.list,
      /admin_list_customers\(text, integer, integer, text\)/,
    );
  });
});
