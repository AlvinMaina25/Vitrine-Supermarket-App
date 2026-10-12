import {
  requireBoolean,
  requireRecord,
  requireString,
  requireWholeNumber,
  nullableString,
  type JsonRecord,
} from "./customer-parse.ts";
import {
  nullableWholeNumber,
  parseList,
  requireStringArray,
} from "./delivery-parse.ts";

/**
 * Pure parser for admin_list_delivery_config() (Phase 6F.1A). Admin-only on the server. One read
 * returns every method, zone and zone fee rule, inactive ones included. Money is integer cents
 * straight from the database; nothing here adds, rounds or converts it. The function takes no
 * arguments.
 */

export interface AdminDeliveryMethod {
  code: string;
  label: string;
  description: string | null;
  base_fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  requires_slot: boolean;
  requires_address: boolean;
  eta_label: string | null;
  position: number;
  is_active: boolean;
}

export interface AdminDeliveryZone {
  id: string;
  code: string;
  name: string;
  description: string | null;
  county: string | null;
  towns: string[];
  position: number;
  is_active: boolean;
}

export interface AdminDeliveryZoneFee {
  id: string;
  zone_id: string;
  method_code: string;
  fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  is_active: boolean;
  zone_code: string;
  zone_name: string;
  method_label: string;
}

export interface AdminDeliveryConfig {
  methods: AdminDeliveryMethod[];
  zones: AdminDeliveryZone[];
  zone_fees: AdminDeliveryZoneFee[];
}

const WHAT = "The delivery configuration";

export function parseDeliveryMethod(
  r: JsonRecord,
  what: string = WHAT,
): AdminDeliveryMethod {
  return {
    code: requireString(r, "code", what),
    label: requireString(r, "label", what),
    description: nullableString(r, "description", what),
    base_fee_cents: requireWholeNumber(r, "base_fee_cents", what),
    free_over_cents: nullableWholeNumber(r, "free_over_cents", what),
    min_order_cents: requireWholeNumber(r, "min_order_cents", what),
    requires_slot: requireBoolean(r, "requires_slot", what),
    requires_address: requireBoolean(r, "requires_address", what),
    eta_label: nullableString(r, "eta_label", what),
    position: requireWholeNumber(r, "position", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

export function parseDeliveryZone(
  r: JsonRecord,
  what: string = WHAT,
): AdminDeliveryZone {
  return {
    id: requireString(r, "id", what),
    code: requireString(r, "code", what),
    name: requireString(r, "name", what),
    description: nullableString(r, "description", what),
    county: nullableString(r, "county", what),
    towns: requireStringArray(r, "towns", what),
    position: requireWholeNumber(r, "position", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

/** A bare fee rule row (as returned by admin_save_delivery_zone_fee); no zone/method labels. */
export interface AdminDeliveryZoneFeeRow {
  id: string;
  zone_id: string;
  method_code: string;
  fee_cents: number;
  free_over_cents: number | null;
  min_order_cents: number;
  is_active: boolean;
}

export function parseDeliveryZoneFeeRow(
  r: JsonRecord,
  what: string = WHAT,
): AdminDeliveryZoneFeeRow {
  return {
    id: requireString(r, "id", what),
    zone_id: requireString(r, "zone_id", what),
    method_code: requireString(r, "method_code", what),
    fee_cents: requireWholeNumber(r, "fee_cents", what),
    free_over_cents: nullableWholeNumber(r, "free_over_cents", what),
    min_order_cents: requireWholeNumber(r, "min_order_cents", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

export function toAdminDeliveryConfig(data: unknown): AdminDeliveryConfig {
  const r = requireRecord(data, WHAT);
  return {
    methods: parseList(r["methods"], WHAT, (row) => parseDeliveryMethod(row)),
    zones: parseList(r["zones"], WHAT, (row) => parseDeliveryZone(row)),
    zone_fees: parseList(r["zone_fees"], WHAT, (row) => ({
      ...parseDeliveryZoneFeeRow(row),
      zone_code: requireString(row, "zone_code", WHAT),
      zone_name: requireString(row, "zone_name", WHAT),
      method_label: requireString(row, "method_label", WHAT),
    })),
  };
}
