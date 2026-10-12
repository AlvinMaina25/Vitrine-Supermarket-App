/**
 * Phase 6M - live Supabase integration run (everything: catalog RLS, customers, orders, payments,
 * admin RPCs, role management, audit log, MFA, delivery lock-down, public HTTP routes).
 *
 *   node --experimental-strip-types scripts/integration/live/run.ts              # enforcement OFF
 *   node --experimental-strip-types scripts/integration/live/run.ts --enforced   # after you turn require_mfa ON
 *
 * It creates its own throwaway users and a throwaway product (slug zz-it-<runid>), never touches
 * existing data, and deletes the users at the end. See scripts/integration/README.md.
 * Needs the repo's dependencies (@supabase/supabase-js). No new dependency is added.
 */
import { writeFileSync } from "node:fs";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import {
  Recorder,
  SkipCheck,
  assertSafeTarget,
  errorInfo,
  expect,
  expectDenied,
  expectNoRows,
  expectOk,
  field,
  findId,
  formatReport,
  totpCode,
  type CallResult,
} from "./core.ts";

const U0 = "00000000-0000-4000-8000-000000000000";
const ENFORCED = process.argv.includes("--enforced");

function need(name: string): string {
  const value = process.env[name];
  if (!value)
    throw new Error(
      `Missing environment variable ${name}. See scripts/integration/README.md.`,
    );
  return value;
}

const URL_ = need("SUPABASE_URL");
const ANON_KEY = need("SUPABASE_ANON_KEY");
const SERVICE_KEY = need("SUPABASE_SERVICE_ROLE_KEY");
const APP_URL = process.env["APP_URL"]?.replace(/\/+$/, "") ?? "";
const ref = assertSafeTarget(URL_, process.env["IT_ALLOW_PROJECT_REF"]);

const runId = Date.now().toString(36);
const PASSWORD = `It-${runId}-${Math.random().toString(36).slice(2, 10)}-Aa1!`;
const rec = new Recorder();

function newClient(key: string): SupabaseClient {
  return createClient(URL_, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}

async function signIn(email: string): Promise<SupabaseClient> {
  const client = newClient(ANON_KEY);
  const { error } = await client.auth.signInWithPassword({
    email,
    password: PASSWORD,
  });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return client;
}

const rpc = (
  c: SupabaseClient,
  fn: string,
  args: Record<string, unknown> = {},
): PromiseLike<CallResult> => c.rpc(fn, args);

interface Person {
  id: string;
  email: string;
}

const service = newClient(SERVICE_KEY);
const anon = newClient(ANON_KEY);
const created: Person[] = [];

async function makeUser(label: string): Promise<Person> {
  const email = `it-${runId}-${label}@example.test`;
  const { data, error } = await service.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
    user_metadata: { full_name: `IT ${label}` },
  });
  if (error || !data.user)
    throw new Error(
      `could not create ${label}: ${error?.message ?? "no user"}`,
    );
  const person = { id: data.user.id, email };
  created.push(person);
  return person;
}

async function giveRole(user: Person, role: "staff" | "admin"): Promise<void> {
  const { error } = await service
    .from("user_roles")
    .insert({ user_id: user.id, role });
  if (error) throw new Error(`could not grant ${role}: ${error.message}`);
}

function text(data: unknown): string {
  return JSON.stringify(data) ?? "";
}

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

// ------------------------------------------------------------------------------------------
// The list of admin-only RPCs and harmless arguments, used for the "everyone else is refused" sweep.
// ------------------------------------------------------------------------------------------
const ADMIN_RPCS: Array<[string, Record<string, unknown>]> = [
  ["admin_dashboard_summary", {}],
  ["admin_list_orders", {}],
  ["admin_get_order", { p_order_id: U0 }],
  [
    "admin_set_order_status",
    { p_order_id: U0, p_status: "cancelled", p_note: "x", p_override: false },
  ],
  ["admin_list_products", {}],
  ["admin_get_product", { p_product_id: U0 }],
  ["admin_create_product", { p_name: "x", p_slug: "x", p_price_cents: 1 }],
  ["admin_update_product", { p_product_id: U0, p_changes: {} }],
  ["admin_set_product_active", { p_product_id: U0, p_is_active: true }],
  [
    "admin_create_product_variant",
    { p_product_id: U0, p_name: "x", p_price_cents: 1 },
  ],
  ["admin_update_product_variant", { p_variant_id: U0, p_changes: {} }],
  ["admin_list_inventory", {}],
  ["admin_get_inventory", { p_product_id: U0 }],
  ["admin_list_inventory_adjustments", {}],
  [
    "admin_adjust_inventory",
    { p_product_id: U0, p_adjustment_quantity: 1, p_reason: "x" },
  ],
  ["admin_list_customers", {}],
  ["admin_get_customer", { p_customer_id: U0 }],
  [
    "admin_set_customer_status",
    { p_customer_id: U0, p_status: "suspended", p_reason: "xxx" },
  ],
  ["admin_update_customer_notes", { p_customer_id: U0, p_notes: "x" }],
  ["admin_list_delivery_config", {}],
  ["admin_list_delivery_slots", { p_from: "2026-01-01", p_to: "2026-01-02" }],
  ["admin_list_payment_transactions", {}],
  ["admin_get_payment_transaction", { p_transaction_id: U0 }],
  ["admin_list_audit_log", {}],
  ["admin_list_role_holders", {}],
  [
    "admin_set_user_role",
    { p_user: U0, p_role: "staff", p_action: "grant", p_reason: "test" },
  ],
  ["record_cod_payment", { p_order_id: U0, p_reason: "test" }],
];

// Tables nobody but the owner / an admin RPC may read directly.
const PRIVATE_TABLES = [
  "orders",
  "order_items",
  "addresses",
  "profiles",
  "user_roles",
  "customer_notes",
  "payment_transactions",
  "admin_audit_log",
  "admin_security_settings",
];

// ------------------------------------------------------------------------------------------
async function main(): Promise<void> {
  console.log(
    `Phase 6M live run ${runId} against project ${ref}${ENFORCED ? " (ENFORCED mode)" : ""}`,
  );

  // ---- fixtures ---------------------------------------------------------------------------
  const adminU = await makeUser("admin");
  const staffU = await makeUser("staff");
  const custA = await makeUser("custa");
  const custB = await makeUser("custb");
  const plainU = await makeUser("plain");
  await giveRole(adminU, "admin");
  await giveRole(staffU, "staff");

  const admin = await signIn(adminU.email);
  const staff = await signIn(staffU.email);
  const cA = await signIn(custA.email);
  const cB = await signIn(custB.email);

  // Enforcement probe: the default run must start with require_mfa OFF.
  const probe = await rpc(admin, "admin_dashboard_summary");
  const probeInfo = errorInfo(probe.error);
  const enforcementOn = probeInfo?.detail === "mfa_required";
  if (enforcementOn && !ENFORCED) {
    throw new Error(
      "require_mfa is ON. Run `update public.admin_security_settings set require_mfa = false;` " +
        "or re-run with --enforced to test the enforced state.",
    );
  }
  if (!enforcementOn && ENFORCED) {
    throw new Error(
      "--enforced was given but require_mfa is OFF. Turn it on first (see README).",
    );
  }

  if (ENFORCED) {
    await enforcedSection(admin, adminU, [cA, cB], { custA, plainU });
  } else {
    await fullSection({
      admin,
      staff,
      cA,
      cB,
      adminU,
      staffU,
      custA,
      custB,
      plainU,
    });
  }

  await cleanup();
  finish();
}

// ------------------------------------------------------------------------------------------
interface Ctx {
  admin: SupabaseClient;
  staff: SupabaseClient;
  cA: SupabaseClient;
  cB: SupabaseClient;
  adminU: Person;
  staffU: Person;
  custA: Person;
  custB: Person;
  plainU: Person;
}

let productId = "";
let productSlug = "";
let codOrderId = "";
let cardOrderId = "";

async function fullSection(c: Ctx): Promise<void> {
  const { admin, staff, cA, cB, custA, custB, plainU, adminU, staffU } = c;

  // ======================================================================== 1. anonymous
  const S1 = "1. Anonymous visitor";
  for (const table of PRIVATE_TABLES) {
    await rec.check(S1, `cannot read ${table}`, async () => {
      expectNoRows(await anon.from(table).select("*").limit(5), table);
    });
  }
  await rec.check(S1, "cannot write admin_security_settings", async () => {
    expectDenied(
      await anon
        .from("admin_security_settings")
        .update({ require_mfa: false })
        .eq("id", true),
    );
  });
  for (const [fn, args] of ADMIN_RPCS) {
    await rec.check(S1, `admin RPC ${fn} refused`, async () => {
      expectDenied(await rpc(anon, fn, args), { code: "42501" });
    });
  }
  await rec.check(S1, "create_order refused", async () => {
    expectDenied(
      await rpc(anon, "create_order", {
        p_items: [{ product_id: U0, variant_id: null, quantity: 1 }],
        p_delivery_method: "pickup",
        p_payment_method: "cash_on_delivery",
      }),
    );
  });
  await rec.check(S1, "payment-engine functions are refused", async () => {
    for (const [fn, args] of [
      ["get_order_for_payment", { p_order_id: U0 }],
      [
        "create_payment_attempt",
        {
          p_order_id: U0,
          p_provider: "x",
          p_method: "card",
          p_idempotency_key: "k",
        },
      ],
      [
        "mark_payment_processing",
        { p_transaction_id: U0, p_provider_reference: "r" },
      ],
      [
        "apply_payment_outcome",
        { p_transaction_id: U0, p_outcome: "succeeded" },
      ],
      ["prune_admin_audit_log", {}],
      ["admin_mfa_satisfied", {}],
      ["require_admin", {}],
    ] as Array<[string, Record<string, unknown>]>) {
      expectDenied(await rpc(anon, fn, args), { code: "42501" });
    }
  });
  await rec.check(
    S1,
    "public catalog helpers work (validate_delivery_selection, slots)",
    async () => {
      expectOk(
        await rpc(anon, "validate_delivery_selection", {
          p_method_code: "pickup",
          p_subtotal_cents: 20000,
        }),
      );
      const today = new Date();
      const to = new Date(today.getTime() + 7 * 86400_000);
      const iso = (d: Date): string => d.toISOString().slice(0, 10);
      expectOk(
        await rpc(anon, "get_delivery_slot_availability", {
          p_from: iso(today),
          p_to: iso(to),
        }),
      );
    },
  );

  // ======================================================================== 2. admin catalog
  const S2 = "2. Admin: catalog and inventory";
  productSlug = `zz-it-${runId}`;
  await rec.check(S2, "admin_create_product", async () => {
    const data = expectOk(
      await rpc(admin, "admin_create_product", {
        p_name: `ZZ IT Product ${runId}`,
        p_slug: productSlug,
        p_price_cents: 10000,
      }),
    );
    productId = findId(data) ?? "";
    expect(productId !== "", `no product id in ${text(data)}`);
  });
  if (productId === "") {
    console.error(
      "Cannot continue without a product; remaining sections skipped.",
    );
    return;
  }
  await rec.check(S2, "duplicate slug refused (slug_taken)", async () => {
    expectDenied(
      await rpc(admin, "admin_create_product", {
        p_name: "dup",
        p_slug: productSlug,
        p_price_cents: 1,
      }),
      { detail: "slug_taken" },
    );
  });
  await rec.check(S2, "admin_update_product", async () => {
    expectOk(
      await rpc(admin, "admin_update_product", {
        p_product_id: productId,
        p_changes: { name: `ZZ IT Product ${runId} (edited)` },
      }),
    );
  });
  await rec.check(S2, "admin_adjust_inventory +50", async () => {
    expectOk(
      await rpc(admin, "admin_adjust_inventory", {
        p_product_id: productId,
        p_adjustment_quantity: 50,
        p_reason: "integration test stock",
      }),
    );
    const { data } = await service
      .from("products")
      .select("stock_quantity")
      .eq("id", productId)
      .single();
    expect(field(data, "stock_quantity") === 50, `stock is ${text(data)}`);
  });
  await rec.check(S2, "zero and over-draw adjustments refused", async () => {
    expectDenied(
      await rpc(admin, "admin_adjust_inventory", {
        p_product_id: productId,
        p_adjustment_quantity: 0,
        p_reason: "zero",
      }),
      { detail: "zero_adjustment_not_allowed" },
    );
    expectDenied(
      await rpc(admin, "admin_adjust_inventory", {
        p_product_id: productId,
        p_adjustment_quantity: -1000,
        p_reason: "too much",
      }),
      { detail: "negative_stock_not_allowed" },
    );
  });
  await rec.check(S2, "inventory read + history", async () => {
    expectOk(
      await rpc(admin, "admin_get_inventory", { p_product_id: productId }),
    );
    expectOk(await rpc(admin, "admin_list_inventory", { p_search: "ZZ IT" }));
    const hist = expectOk(
      await rpc(admin, "admin_list_inventory_adjustments", {
        p_product_id: productId,
      }),
    );
    expect(
      text(hist).includes("integration test stock"),
      "adjustment missing from history",
    );
  });
  await rec.check(S2, "variant create + update", async () => {
    const data = expectOk(
      await rpc(admin, "admin_create_product_variant", {
        p_product_id: productId,
        p_name: "Large",
        p_price_cents: 12000,
      }),
    );
    const variantId = findId(data);
    expect(variantId !== null, `no variant id in ${text(data)}`);
    expectOk(
      await rpc(admin, "admin_update_product_variant", {
        p_variant_id: variantId,
        p_changes: { name: "Large (edited)" },
      }),
    );
  });
  await rec.check(S2, "list/get product + dashboard", async () => {
    expectOk(await rpc(admin, "admin_list_products", { p_search: "ZZ IT" }));
    expectOk(
      await rpc(admin, "admin_get_product", { p_product_id: productId }),
    );
    expectOk(await rpc(admin, "admin_dashboard_summary"));
  });
  await rec.check(
    S2,
    "RLS: an inactive product is hidden from anon, an active one is visible",
    async () => {
      const visible = async (): Promise<number> => {
        const { data, error } = await anon
          .from("products")
          .select("id")
          .eq("slug", productSlug);
        if (error) throw new Error(error.message);
        return data?.length ?? 0;
      };
      expectOk(
        await rpc(admin, "admin_set_product_active", {
          p_product_id: productId,
          p_is_active: false,
        }),
      );
      expect((await visible()) === 0, "inactive product visible to anon");
      expectOk(
        await rpc(admin, "admin_set_product_active", {
          p_product_id: productId,
          p_is_active: true,
        }),
      );
      expect((await visible()) === 1, "active product not visible to anon");
    },
  );
  await rec.check(S2, "validate_cart (anon) prices the product", async () => {
    const data = expectOk(
      await rpc(anon, "validate_cart", {
        p_items: [{ product_id: productId, variant_id: null, quantity: 2 }],
      }),
    );
    expect(
      text(data).includes(productId),
      "cart validation did not return the product",
    );
  });

  // ======================================================================== 3. customers
  const S3 = "3. Customer isolation and orders";
  await rec.check(
    S3,
    "customer sees only their own profile; can edit their name",
    async () => {
      const { data } = await cA.from("profiles").select("id");
      expect(
        (data?.length ?? 0) === 1 && data?.[0]?.["id"] === custA.id,
        `profiles visible: ${text(data)}`,
      );
      const upd = await cA
        .from("profiles")
        .update({ full_name: "IT Alice" })
        .eq("id", custA.id)
        .select("full_name");
      expectOk(upd, "own profile update");
    },
  );
  await rec.check(S3, "customer cannot read another profile", async () => {
    expectNoRows(await cA.from("profiles").select("id").eq("id", custB.id));
  });
  await rec.check(
    S3,
    "customer cannot make themselves suspended/active via profiles.status",
    async () => {
      const res = await cA
        .from("profiles")
        .update({ status: "suspended" })
        .eq("id", custA.id)
        .select("status");
      if (!errorInfo(res.error))
        expect(text(res.data) === "[]", `status changed: ${text(res.data)}`);
    },
  );
  await rec.check(
    S3,
    "customer cannot see roles, notes, audit log, payment ledger",
    async () => {
      for (const t of [
        "user_roles",
        "customer_notes",
        "admin_audit_log",
        "payment_transactions",
        "admin_security_settings",
      ]) {
        expectNoRows(await cA.from(t).select("*").limit(5), t);
      }
    },
  );
  await rec.check(
    S3,
    "customer can save an address; the other customer cannot see it",
    async () => {
      const ins = await cA
        .from("addresses")
        .insert({
          full_name: "IT Alice",
          phone: "0700000000",
          address_line_1: "1 Test St",
          city: "Nairobi",
          county: "Nairobi",
        })
        .select("id");
      const addrId = findId(expectOk(ins, "address insert"));
      expect(addrId !== null, "no address id");
      expectNoRows(
        await cB
          .from("addresses")
          .select("id")
          .eq("id", addrId ?? U0),
      );
    },
  );
  await rec.check(
    S3,
    "customer is refused every admin RPC (not_authorised)",
    async () => {
      for (const [fn, args] of ADMIN_RPCS) {
        const info = expectDenied(await rpc(cA, fn, args), { code: "42501" });
        expect(
          info.detail === "not_authorised",
          `${fn}: detail ${info.detail ?? "none"}`,
        );
      }
    },
  );
  await rec.check(
    S3,
    "set_order_status / payment-engine functions are refused",
    async () => {
      expectDenied(
        await rpc(cA, "set_order_status", {
          p_order_id: U0,
          p_new_status: "cancelled",
        }),
      );
      for (const [fn, args] of [
        ["get_order_for_payment", { p_order_id: U0 }],
        [
          "create_payment_attempt",
          {
            p_order_id: U0,
            p_provider: "x",
            p_method: "card",
            p_idempotency_key: "k",
          },
        ],
        [
          "apply_payment_outcome",
          { p_transaction_id: U0, p_outcome: "succeeded" },
        ],
        ["prune_admin_audit_log", {}],
      ] as Array<[string, Record<string, unknown>]>) {
        expectDenied(await rpc(cA, fn, args), { code: "42501" });
      }
    },
  );

  const items = [{ product_id: productId, variant_id: null, quantity: 2 }];
  await rec.check(
    S3,
    "create_order (COD, pickup) succeeds and is idempotent",
    async () => {
      const args = {
        p_items: items,
        p_delivery_method: "pickup",
        p_payment_method: "cash_on_delivery",
        p_idempotency_key: `it-${runId}-cod`,
      };
      codOrderId = String(
        expectOk(await rpc(cA, "create_order", args), "create_order"),
      );
      const again = String(
        expectOk(await rpc(cA, "create_order", args), "create_order replay"),
      );
      expect(
        again === codOrderId,
        `replay created a different order (${again} vs ${codOrderId})`,
      );
    },
  );
  await rec.check(S3, "stock was reduced once (50 -> 48)", async () => {
    const { data } = await service
      .from("products")
      .select("stock_quantity")
      .eq("id", productId)
      .single();
    expect(field(data, "stock_quantity") === 48, `stock is ${text(data)}`);
  });
  await rec.check(
    S3,
    "owner reads their order and items; the other customer cannot",
    async () => {
      const mine = await cA
        .from("orders")
        .select("id,status,payment_status,payment_method,total_cents")
        .eq("id", codOrderId);
      expect(
        (expectOk(mine, "own order") as unknown[]).length === 1,
        "owner cannot read own order",
      );
      const lines = await cA
        .from("order_items")
        .select("id")
        .eq("order_id", codOrderId);
      expect(
        (expectOk(lines, "own items") as unknown[]).length >= 1,
        "no order items",
      );
      expectNoRows(await cB.from("orders").select("id").eq("id", codOrderId));
      expectNoRows(
        await cB.from("order_items").select("id").eq("order_id", codOrderId),
      );
    },
  );
  await rec.check(
    S3,
    "customer cannot mark their own order paid or change its status",
    async () => {
      const res = await cA
        .from("orders")
        .update({ payment_status: "paid", status: "paid" })
        .eq("id", codOrderId)
        .select("id");
      if (!errorInfo(res.error))
        expect(
          text(res.data) === "[]",
          `order was modified: ${text(res.data)}`,
        );
      const { data } = await service
        .from("orders")
        .select("status,payment_status")
        .eq("id", codOrderId)
        .single();
      expect(
        field(data, "payment_status") !== "paid",
        `payment_status is ${text(data)}`,
      );
    },
  );
  await rec.check(S3, "customer cannot record a COD payment", async () => {
    expectDenied(
      await rpc(cA, "record_cod_payment", {
        p_order_id: codOrderId,
        p_reason: "self service",
      }),
      { detail: "not_authorised" },
    );
  });
  await rec.check(
    S3,
    "get_my_order_payments: owner ok, stranger gets nothing",
    async () => {
      expectOk(
        await rpc(cA, "get_my_order_payments", { p_order_id: codOrderId }),
      );
      const other = await rpc(cB, "get_my_order_payments", {
        p_order_id: codOrderId,
      });
      if (!errorInfo(other.error))
        expect(
          !text(other.data).includes(codOrderId),
          "stranger saw the order's payments",
        );
    },
  );

  // ======================================================================== 4. staff
  const S4 = "4. Staff";
  await rec.check(S4, "staff can read orders", async () => {
    const res = await staff.from("orders").select("id").eq("id", codOrderId);
    expect(
      (expectOk(res, "staff orders") as unknown[]).length === 1,
      "staff cannot see the order",
    );
  });
  await rec.check(
    S4,
    "staff are refused every admin RPC (not_authorised)",
    async () => {
      for (const [fn, args] of ADMIN_RPCS) {
        const info = expectDenied(await rpc(staff, fn, args), {
          code: "42501",
        });
        expect(
          info.detail === "not_authorised",
          `${fn}: detail ${info.detail ?? "none"}`,
        );
      }
    },
  );
  await rec.check(
    S4,
    "staff cannot read the audit log, ledger or settings directly",
    async () => {
      for (const t of [
        "admin_audit_log",
        "payment_transactions",
        "admin_security_settings",
      ]) {
        expectNoRows(await staff.from(t).select("*").limit(5), t);
      }
    },
  );

  // ======================================================================== 5. order lifecycle + COD
  const S5 = "5. Admin: order lifecycle and cash on delivery";
  await rec.check(S5, "admin_list_orders / admin_get_order", async () => {
    const list = expectOk(
      await rpc(admin, "admin_list_orders", { p_search: null }),
    );
    expect(text(list).includes(codOrderId), "new order missing from list");
    expectOk(await rpc(admin, "admin_get_order", { p_order_id: codOrderId }));
  });
  await rec.check(
    S5,
    "a non-standard status jump is refused without override",
    async () => {
      expectDenied(
        await rpc(admin, "admin_set_order_status", {
          p_order_id: codOrderId,
          p_status: "delivered",
          p_note: "skip",
          p_override: false,
        }),
      );
    },
  );
  await rec.check(
    S5,
    "COD cannot be recorded before the order is out for delivery",
    async () => {
      expectDenied(
        await rpc(admin, "record_cod_payment", {
          p_order_id: codOrderId,
          p_reason: "too early",
        }),
        { detail: "order_status_not_allowed" },
      );
    },
  );
  await rec.check(
    S5,
    "override moves the order to out_for_delivery, then delivered",
    async () => {
      expectOk(
        await rpc(admin, "admin_set_order_status", {
          p_order_id: codOrderId,
          p_status: "out_for_delivery",
          p_note: "it run",
          p_override: true,
        }),
      );
      expectOk(
        await rpc(admin, "admin_set_order_status", {
          p_order_id: codOrderId,
          p_status: "delivered",
          p_note: "it run",
          p_override: true,
        }),
      );
    },
  );
  await rec.check(
    S5,
    "record_cod_payment marks it paid, and replays safely",
    async () => {
      const first = expectOk(
        await rpc(admin, "record_cod_payment", {
          p_order_id: codOrderId,
          p_reason: "cash collected in test",
        }),
      );
      expect(field(first, "changed") === true, `first call: ${text(first)}`);
      const replay = expectOk(
        await rpc(admin, "record_cod_payment", {
          p_order_id: codOrderId,
          p_reason: "cash collected in test",
        }),
      );
      expect(field(replay, "changed") === false, `replay: ${text(replay)}`);
      const { data } = await service
        .from("orders")
        .select("payment_status")
        .eq("id", codOrderId)
        .single();
      expect(
        field(data, "payment_status") === "paid",
        `payment_status is ${text(data)}`,
      );
    },
  );
  await rec.check(
    S5,
    "owner now sees the cash payment; admin ledger lists it",
    async () => {
      const mine = expectOk(
        await rpc(cA, "get_my_order_payments", { p_order_id: codOrderId }),
      );
      expect(text(mine).includes("cod"), `owner payments: ${text(mine)}`);
      const ledger = expectOk(
        await rpc(admin, "admin_list_payment_transactions", {
          p_order_id: codOrderId,
        }),
      );
      const txnId = findId(ledger);
      expect(txnId !== null, "ledger empty");
      expectOk(
        await rpc(admin, "admin_get_payment_transaction", {
          p_transaction_id: txnId,
        }),
      );
    },
  );

  // ======================================================================== 6. card payment engine (service role only)
  const S6 = "6. Payment engine (service role)";
  await rec.check(S6, "card order is created by the customer", async () => {
    cardOrderId = String(
      expectOk(
        await rpc(cA, "create_order", {
          p_items: [{ product_id: productId, variant_id: null, quantity: 1 }],
          p_delivery_method: "pickup",
          p_payment_method: "card",
          p_idempotency_key: `it-${runId}-card`,
        }),
        "create_order card",
      ),
    );
  });
  let txnId = "";
  let total = 0;
  await rec.check(
    S6,
    "service role reads the order for payment and opens an attempt (idempotent)",
    async () => {
      const o = expectOk(
        await rpc(service, "get_order_for_payment", {
          p_order_id: cardOrderId,
        }),
      );
      const { data } = await service
        .from("orders")
        .select("total_cents")
        .eq("id", cardOrderId)
        .single();
      total = Number(field(data, "total_cents"));
      expect(total > 0, `order total ${text(o)}`);
      const args = {
        p_order_id: cardOrderId,
        p_provider: "integration",
        p_method: "card",
        p_idempotency_key: `it-${runId}-attempt`,
      };
      const a = expectOk(
        await rpc(service, "create_payment_attempt", args),
        "create_payment_attempt",
      );
      txnId = findId(a) ?? "";
      expect(txnId !== "", `no transaction id in ${text(a)}`);
      const b = expectOk(
        await rpc(service, "create_payment_attempt", args),
        "attempt replay",
      );
      expect(findId(b) === txnId, "replay opened a second transaction");
    },
  );
  await rec.check(
    S6,
    "mark processing, then a wrong amount is refused",
    async () => {
      expectOk(
        await rpc(service, "mark_payment_processing", {
          p_transaction_id: txnId,
          p_provider_reference: `ref-${runId}`,
        }),
      );
      expectDenied(
        await rpc(service, "apply_payment_outcome", {
          p_transaction_id: txnId,
          p_outcome: "succeeded",
          p_provider_reference: `ref-${runId}`,
          p_amount_cents: total + 1,
        }),
      );
      const { data } = await service
        .from("orders")
        .select("payment_status")
        .eq("id", cardOrderId)
        .single();
      expect(
        field(data, "payment_status") !== "paid",
        "order was paid with a wrong amount",
      );
    },
  );
  await rec.check(
    S6,
    "correct amount marks the order paid; replay changes nothing",
    async () => {
      const args = {
        p_transaction_id: txnId,
        p_outcome: "succeeded",
        p_provider_reference: `ref-${runId}`,
        p_amount_cents: total,
      };
      expectOk(
        await rpc(service, "apply_payment_outcome", args),
        "apply_payment_outcome",
      );
      expectOk(
        await rpc(service, "apply_payment_outcome", args),
        "apply replay",
      );
      const { data } = await service
        .from("orders")
        .select("payment_status")
        .eq("id", cardOrderId)
        .single();
      expect(
        field(data, "payment_status") === "paid",
        `payment_status is ${text(data)}`,
      );
    },
  );
  await rec.check(S6, "stock after both orders is 47", async () => {
    const { data } = await service
      .from("products")
      .select("stock_quantity")
      .eq("id", productId)
      .single();
    expect(field(data, "stock_quantity") === 47, `stock is ${text(data)}`);
  });
  await rec.check(
    S6,
    "service role cannot rewrite or delete audit rows (append-only)",
    async () => {
      expectDenied(
        await service
          .from("admin_audit_log")
          .update({ reason: "tamper" })
          .eq("id", U0),
      );
      expectDenied(await service.from("admin_audit_log").delete().eq("id", U0));
      expectDenied(await service.from("admin_security_settings").select("*"), {
        code: "42501",
      });
    },
  );

  // ======================================================================== 7. customers admin
  const S7 = "7. Admin: customers";
  await rec.check(S7, "list, get, notes", async () => {
    expectOk(
      await rpc(admin, "admin_list_customers", { p_search: "it-" + runId }),
    );
    expectOk(
      await rpc(admin, "admin_get_customer", { p_customer_id: custA.id }),
    );
    expectOk(
      await rpc(admin, "admin_update_customer_notes", {
        p_customer_id: custA.id,
        p_notes: "integration note",
      }),
    );
    expectNoRows(
      await cA.from("customer_notes").select("*"),
      "customer_notes as customer",
    );
  });
  await rec.check(
    S7,
    "a suspended customer cannot order; reactivation restores them",
    async () => {
      expectOk(
        await rpc(admin, "admin_set_customer_status", {
          p_customer_id: custB.id,
          p_status: "suspended",
          p_reason: "integration test",
        }),
      );
      expectDenied(
        await rpc(cB, "create_order", {
          p_items: items,
          p_delivery_method: "pickup",
          p_payment_method: "cash_on_delivery",
          p_idempotency_key: `it-${runId}-susp`,
        }),
      );
      expectOk(
        await rpc(admin, "admin_set_customer_status", {
          p_customer_id: custB.id,
          p_status: "active",
          p_reason: "integration test over",
        }),
      );
      const { data } = await service
        .from("profiles")
        .select("status")
        .eq("id", custB.id)
        .single();
      expect(field(data, "status") === "active", `status is ${text(data)}`);
    },
  );

  // ======================================================================== 8. delivery admin + lock-down
  const S8 = "8. Delivery admin and lock-down";
  await rec.check(S8, "admin reads delivery config and slots", async () => {
    expectOk(await rpc(admin, "admin_list_delivery_config"));
    const today = new Date();
    const iso = (d: Date): string => d.toISOString().slice(0, 10);
    expectOk(
      await rpc(admin, "admin_list_delivery_slots", {
        p_from: iso(today),
        p_to: iso(new Date(today.getTime() + 7 * 86400_000)),
      }),
    );
  });
  await rec.check(
    S8,
    "no API role can write delivery tables directly",
    async () => {
      for (const t of [
        "delivery_methods",
        "delivery_zones",
        "delivery_zone_fees",
        "delivery_slot_templates",
        "delivery_slot_overrides",
      ]) {
        expectDenied(await admin.from(t).insert({}), { code: "42501" });
        expectDenied(await anon.from(t).insert({}), { code: "42501" });
      }
    },
  );

  // ======================================================================== 9. roles + audit
  const S9 = "9. Role management and audit log";
  const setRole = (
    user: Person,
    role: string,
    action: string,
    reason: string,
  ): PromiseLike<CallResult> =>
    rpc(admin, "admin_set_user_role", {
      p_user: user.id,
      p_role: role,
      p_action: action,
      p_reason: reason,
    });
  await rec.check(
    S9,
    "role holders list has ids, roles, dates and no emails",
    async () => {
      const data = expectOk(await rpc(admin, "admin_list_role_holders"));
      const t = text(data);
      expect(
        t.includes(adminU.id) && t.includes(staffU.id),
        "admin/staff missing",
      );
      expect(!t.includes("@") && !t.includes("email"), "list leaked an email");
    },
  );
  await rec.check(
    S9,
    "grant, no-op grant, revoke, no-op revoke: exactly two audit rows",
    async () => {
      expect(
        field(
          expectOk(
            await setRole(plainU, "staff", "grant", "integration grant"),
          ),
          "changed",
        ) === true,
        "grant not applied",
      );
      expect(
        field(
          expectOk(
            await setRole(plainU, "staff", "grant", "integration grant"),
          ),
          "changed",
        ) === false,
        "repeat grant not a no-op",
      );
      expect(
        field(
          expectOk(
            await setRole(plainU, "staff", "revoke", "integration revoke"),
          ),
          "changed",
        ) === true,
        "revoke not applied",
      );
      expect(
        field(
          expectOk(
            await setRole(plainU, "staff", "revoke", "integration revoke"),
          ),
          "changed",
        ) === false,
        "repeat revoke not a no-op",
      );
      const log = text(
        expectOk(
          await rpc(admin, "admin_list_audit_log", {
            p_target_id: plainU.id,
            p_limit: 100,
          }),
        ),
      );
      expect(
        count(log, "role_granted") === 1 && count(log, "role_revoked") === 1,
        `audit rows: granted=${count(log, "role_granted")} revoked=${count(log, "role_revoked")}`,
      );
      expect(!log.includes("@"), "audit log leaked an email");
    },
  );
  await rec.check(
    S9,
    "rules: self-change, bad role, short reason, unknown user",
    async () => {
      expectDenied(await setRole(adminU, "staff", "grant", "self change"), {
        detail: "cannot_change_own_role",
      });
      expectDenied(await setRole(plainU, "customer", "grant", "bad role"), {
        detail: "invalid_role",
      });
      expectDenied(await setRole(plainU, "staff", "grant", "ab"), {
        detail: "reason_too_short",
      });
      expectDenied(
        await setRole({ id: U0, email: "" }, "staff", "grant", "ghost user"),
        { detail: "user_not_found" },
      );
    },
  );
  await rec.check(
    S9,
    "the audit log records this run's admin actions, readable only through the RPC",
    async () => {
      const log = text(
        expectOk(await rpc(admin, "admin_list_audit_log", { p_limit: 200 })),
      );
      expect(
        log.includes(productId),
        "product actions are not in the audit log",
      );
      expectDenied(await admin.from("admin_audit_log").select("*").limit(1), {
        code: "42501",
      });
    },
  );
  await rec.check(
    S9,
    "prune_admin_audit_log is not callable by admin or customer",
    async () => {
      expectDenied(await rpc(admin, "prune_admin_audit_log"), {
        code: "42501",
      });
      expectDenied(await rpc(cA, "prune_admin_audit_log"), { code: "42501" });
    },
  );

  // ======================================================================== 10. MFA (enforcement off)
  await mfaSection(adminU, "10. MFA (enforcement off)", false);

  // ======================================================================== 11. public HTTP routes
  const S11 = "11. Public HTTP routes (webhooks)";
  const hit = async (path: string, method: string): Promise<number> => {
    if (!APP_URL) throw new SkipCheck("APP_URL not set");
    const init: RequestInit = { method, redirect: "manual" };
    if (method === "POST") {
      init.headers = { "content-type": "application/json" };
      init.body = "{}";
    }
    return (await fetch(`${APP_URL}${path}`, init)).status;
  };
  await rec.check(
    S11,
    "card webhook without a valid signature is rejected (4xx)",
    async () => {
      const s = await hit("/api/public/card-webhook", "POST");
      expect(s >= 400 && s < 500, `status ${s}`);
    },
  );
  await rec.check(
    S11,
    "M-Pesa callback with a bad token is rejected (4xx)",
    async () => {
      const s = await hit(
        `/api/public/mpesa-callback/bad-token-${runId}`,
        "POST",
      );
      expect(s >= 400 && s < 500, `status ${s}`);
    },
  );
  await rec.check(
    S11,
    "M-Pesa reconcile with a bad token is rejected (4xx)",
    async () => {
      const s = await hit(
        `/api/public/mpesa-reconcile/bad-token-${runId}`,
        "POST",
      );
      expect(s >= 400 && s < 500, `status ${s}`);
    },
  );
  await rec.check(
    S11,
    "card return for an unknown order does not crash (no 5xx)",
    async () => {
      const s = await hit(`/api/public/card-return/${U0}`, "GET");
      expect(s < 500, `status ${s}`);
    },
  );
  await rec.check(
    S11,
    "no webhook marks an order paid by itself (card order still reflects the engine)",
    async () => {
      if (!APP_URL) throw new SkipCheck("APP_URL not set");
      const { data } = await service
        .from("orders")
        .select("payment_status")
        .eq("id", codOrderId)
        .single();
      expect(
        field(data, "payment_status") === "paid",
        "COD order should still be paid, untouched by bogus webhooks",
      );
    },
  );
}

// ------------------------------------------------------------------------------------------
/** Real TOTP enrolment against Supabase Auth, and what aal1 / aal2 mean for admin RPCs. */
async function mfaSection(
  adminU: Person,
  section: string,
  enforced: boolean,
): Promise<void> {
  const aal1 = await signIn(adminU.email);
  let factorId = "";
  let secret = "";

  await rec.check(
    section,
    "an admin with no factor starts at aal1",
    async () => {
      const { data, error } =
        await aal1.auth.mfa.getAuthenticatorAssuranceLevel();
      if (error) throw new Error(error.message);
      expect(
        data.currentLevel === "aal1",
        `level ${data.currentLevel ?? "null"}`,
      );
    },
  );
  await rec.check(
    section,
    "enrolment works" + (enforced ? " while enforcement is ON" : ""),
    async () => {
      const { data, error } = await aal1.auth.mfa.enroll({
        factorType: "totp",
      });
      if (error)
        throw new Error(
          `enroll: ${error.message}. Is TOTP MFA enabled in Authentication settings?`,
        );
      factorId = data.id;
      secret = data.totp.secret;
      expect(
        data.totp.qr_code.length > 0 && secret.length > 0,
        "no QR / secret returned",
      );
    },
  );
  await rec.check(
    section,
    "a wrong code is refused; the right code upgrades the session to aal2",
    async () => {
      if (factorId === "") throw new SkipCheck("enrolment failed");
      const ch = await aal1.auth.mfa.challenge({ factorId });
      if (ch.error) throw new Error(ch.error.message);
      const bad = await aal1.auth.mfa.verify({
        factorId,
        challengeId: ch.data.id,
        code: "000000",
      });
      expect(bad.error !== null, "000000 was accepted");
      let ok = false;
      for (const offset of [0, 1, -1]) {
        const c2 = await aal1.auth.mfa.challenge({ factorId });
        if (c2.error) throw new Error(c2.error.message);
        const v = await aal1.auth.mfa.verify({
          factorId,
          challengeId: c2.data.id,
          code: totpCode(secret, Date.now(), offset),
        });
        if (!v.error) {
          ok = true;
          break;
        }
      }
      expect(ok, "no computed code was accepted (clock skew?)");
      const lvl = await aal1.auth.mfa.getAuthenticatorAssuranceLevel();
      expect(
        lvl.data?.currentLevel === "aal2",
        `level ${lvl.data?.currentLevel ?? "null"}`,
      );
    },
  );
  await rec.check(section, "aal2 session: admin RPC allowed", async () => {
    if (factorId === "") throw new SkipCheck("enrolment failed");
    expectOk(await rpc(aal1, "admin_dashboard_summary"));
  });
  await rec.check(
    section,
    "a fresh sign-in is aal1 again; the RPC " +
      (enforced
        ? "is refused with mfa_required"
        : "is still allowed (flag off)"),
    async () => {
      if (factorId === "") throw new SkipCheck("enrolment failed");
      const fresh = await signIn(adminU.email);
      const lvl = await fresh.auth.mfa.getAuthenticatorAssuranceLevel();
      expect(
        lvl.data?.currentLevel === "aal1" && lvl.data?.nextLevel === "aal2",
        `levels ${text(lvl.data)}`,
      );
      const res = await rpc(fresh, "admin_dashboard_summary");
      if (enforced)
        expectDenied(res, { code: "42501", detail: "mfa_required" });
      else expectOk(res);
    },
  );
  await rec.check(
    section,
    "removing a verified factor needs aal2",
    async () => {
      if (factorId === "") throw new SkipCheck("enrolment failed");
      const fresh = await signIn(adminU.email);
      const denied = await fresh.auth.mfa.unenroll({ factorId });
      expect(denied.error !== null, "unenroll succeeded at aal1");
      const ok = await aal1.auth.mfa.unenroll({ factorId });
      expect(
        ok.error === null,
        `unenroll at aal2 failed: ${ok.error?.message ?? ""}`,
      );
    },
  );
}

async function enforcedSection(
  admin: SupabaseClient,
  adminU: Person,
  customers: SupabaseClient[],
  who: { custA: Person; plainU: Person },
): Promise<void> {
  const S = "E. Enforcement ON";
  await rec.check(
    S,
    "aal1 admin is refused with SQLSTATE 42501 / mfa_required",
    async () => {
      expectDenied(await rpc(admin, "admin_dashboard_summary"), {
        code: "42501",
        detail: "mfa_required",
      });
      expectDenied(await rpc(admin, "admin_list_role_holders"), {
        code: "42501",
        detail: "mfa_required",
      });
    },
  );
  await rec.check(
    S,
    "customers and anon get exactly what they got before (not_authorised / permission denied)",
    async () => {
      const [cust] = customers;
      if (!cust) throw new Error("no customer client");
      expectDenied(await rpc(cust, "admin_dashboard_summary"), {
        code: "42501",
        detail: "not_authorised",
      });
      expectDenied(await rpc(anon, "admin_dashboard_summary"), {
        code: "42501",
      });
    },
  );
  await rec.check(
    S,
    "settings table is unreadable and unwritable through the API",
    async () => {
      expectDenied(await admin.from("admin_security_settings").select("*"), {
        code: "42501",
      });
      expectDenied(
        await service
          .from("admin_security_settings")
          .update({ require_mfa: false })
          .eq("id", true),
        { code: "42501" },
      );
    },
  );
  await rec.check(
    S,
    "aal1 admin loses direct admin reads (profiles shows only their own row)",
    async () => {
      const { data, error } = await admin.from("profiles").select("id");
      if (error) throw new Error(error.message);
      expect((data?.length ?? 0) === 1, `saw ${data?.length ?? 0} profiles`);
    },
  );
  await mfaSection(adminU, "E2. MFA (enforcement ON)", true);
  await rec.check(S, "aal2 admin sees all profiles again", async () => {
    const aal1 = await signIn(adminU.email);
    const { data } = await aal1.auth.mfa.listFactors();
    // The factor was removed at the end of the MFA checks; enrol a new one for this read.
    const enr = await aal1.auth.mfa.enroll({ factorType: "totp" });
    if (enr.error) throw new Error(enr.error.message);
    void data;
    let ok = false;
    for (const offset of [0, 1, -1]) {
      const ch = await aal1.auth.mfa.challenge({ factorId: enr.data.id });
      if (ch.error) throw new Error(ch.error.message);
      const v = await aal1.auth.mfa.verify({
        factorId: enr.data.id,
        challengeId: ch.data.id,
        code: totpCode(enr.data.totp.secret, Date.now(), offset),
      });
      if (!v.error) {
        ok = true;
        break;
      }
    }
    expect(ok, "no code accepted");
    const res = await aal1
      .from("profiles")
      .select("id")
      .in("id", [adminU.id, who.custA.id, who.plainU.id]);
    expect(
      (expectOk(res, "profiles at aal2") as unknown[]).length === 3,
      "aal2 admin cannot read all profiles",
    );
    expectOk(await rpc(aal1, "admin_dashboard_summary"));
    await aal1.auth.mfa.unenroll({ factorId: enr.data.id });
  });
}

// ------------------------------------------------------------------------------------------
async function cleanup(): Promise<void> {
  const notes: string[] = [];
  if (productId) {
    const { error } = await service
      .from("products")
      .update({ is_active: false })
      .eq("id", productId);
    if (error)
      notes.push(
        `could not deactivate product ${productSlug}: ${error.message}`,
      );
  }
  for (const person of created) {
    const { error } = await service.auth.admin.deleteUser(person.id);
    if (error) notes.push(`could not delete ${person.email}: ${error.message}`);
  }
  await rec.check(
    "Cleanup",
    "test users deleted and the test product deactivated",
    () => {
      if (notes.length > 0) throw new Error(notes.join("; "));
    },
  );
  console.log(
    `\nLeft behind on purpose: audit rows (append-only), and the product ${productSlug || "(none)"} + its orders/stock history.\n` +
      `Manual tidy-up, as owner, only if you want it:  see scripts/integration/README.md (Cleanup).`,
  );
}

function finish(): void {
  const report = formatReport(rec.results);
  console.log(report);
  const file = `integration-report-${runId}${ENFORCED ? "-enforced" : ""}.json`;
  writeFileSync(
    file,
    JSON.stringify(
      { runId, ref, enforced: ENFORCED, results: rec.results },
      null,
      2,
    ),
  );
  console.log(`\nWrote ${file}`);
  if (rec.counts().FAIL > 0) process.exitCode = 1;
}

main().catch(async (error: unknown) => {
  console.error(
    `\nRun aborted: ${error instanceof Error ? error.message : String(error)}`,
  );
  try {
    await cleanup();
  } catch {
    /* best effort */
  }
  console.log(formatReport(rec.results));
  process.exitCode = 2;
});
