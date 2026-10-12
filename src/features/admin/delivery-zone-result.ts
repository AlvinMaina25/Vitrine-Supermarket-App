import {
  characterCount,
  requireBoolean,
  requireRecord,
  requireString,
} from "./customer-parse.ts";
import {
  parseDeliveryZone,
  type AdminDeliveryZone,
} from "./delivery-config-result.ts";
import type { DeliveryFieldErrors } from "./delivery-error.ts";
import {
  MAX_COUNTY_LENGTH,
  MAX_POSITION,
  MAX_TOWNS,
  MAX_TOWN_LENGTH,
  MAX_ZONE_DESCRIPTION_LENGTH,
  MAX_ZONE_NAME_LENGTH,
  ZONE_CODE_PATTERN,
  checkReason,
  inWholeRange,
} from "./delivery-parse.ts";
import { unexpected } from "./customer-parse.ts";

/**
 * Pure parsers and argument builders for admin_save_delivery_zone() and
 * admin_set_delivery_zone_active() (Phase 6F.1A). Admin-only on the server.
 */

export interface AdminSaveDeliveryZoneResult {
  changed: boolean;
  created: boolean;
  zone: AdminDeliveryZone;
}

export function toAdminSaveDeliveryZoneResult(
  data: unknown,
): AdminSaveDeliveryZoneResult {
  const what = "The delivery zone save";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    created: requireBoolean(r, "created", what),
    zone: parseDeliveryZone(requireRecord(r["zone"], what), what),
  };
}

export interface AdminSaveDeliveryZoneArgs {
  p_zone_id: string | null;
  p_code: string | null;
  p_name: string;
  p_county: string | null;
  p_towns: string[];
  p_description: string | null;
  p_position: number | null;
}

export interface DeliveryZoneInput {
  /** null creates a zone; an id updates it. */
  zoneId: string | null;
  /** Create-only; ignored (sent as null) when updating. */
  code: string;
  name: string;
  county: string;
  description: string;
  towns: readonly string[];
  /** null keeps the current position (0 on create). */
  position: number | null;
}

export type DeliveryZoneBuild =
  | { ok: true; args: AdminSaveDeliveryZoneArgs }
  | { ok: false; errors: DeliveryFieldErrors };

/** Trimmed, blanks dropped, case-insensitive duplicates dropped (first spelling kept). */
export function cleanTowns(towns: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const town of towns) {
    const t = town.trim();
    if (t === "") continue;
    const key = t.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(t);
  }
  return out;
}

export function buildSaveDeliveryZoneArgs(
  input: DeliveryZoneInput,
): DeliveryZoneBuild {
  const errors: DeliveryFieldErrors = {};
  const creating = input.zoneId === null;
  const code = input.code.trim();
  const name = input.name.trim();
  const county = input.county.trim();
  const description = input.description.trim();
  const towns = cleanTowns(input.towns);

  if (creating && !ZONE_CODE_PATTERN.test(code)) {
    errors.code =
      "The code must be 2-40 characters: lowercase letters, digits, - or _, starting with a letter.";
  }
  if (name === "") errors.name = "A name is required.";
  else if (characterCount(name) > MAX_ZONE_NAME_LENGTH) {
    errors.name = `Keep the name to ${MAX_ZONE_NAME_LENGTH} characters or fewer.`;
  }
  if (characterCount(county) > MAX_COUNTY_LENGTH) {
    errors.county = `Keep the county to ${MAX_COUNTY_LENGTH} characters or fewer.`;
  }
  if (characterCount(description) > MAX_ZONE_DESCRIPTION_LENGTH) {
    errors.description = `Keep the description to ${MAX_ZONE_DESCRIPTION_LENGTH} characters or fewer.`;
  }
  if (
    towns.length > MAX_TOWNS ||
    towns.some((t) => characterCount(t) > MAX_TOWN_LENGTH)
  ) {
    errors.towns = `List at most ${MAX_TOWNS} towns of ${MAX_TOWN_LENGTH} characters or fewer.`;
  }
  if (input.position !== null && !inWholeRange(input.position, MAX_POSITION)) {
    errors.position =
      "The position must be a whole number from 0 to 1,000,000.";
  }
  if (Object.keys(errors).length > 0) return { ok: false, errors };

  return {
    ok: true,
    args: {
      p_zone_id: input.zoneId,
      p_code: creating ? code : null,
      p_name: name,
      p_county: county === "" ? null : county,
      p_towns: towns,
      p_description: description === "" ? null : description,
      p_position: input.position,
    },
  };
}

export interface AdminSetDeliveryZoneActiveResult {
  changed: true;
  zone_id: string;
  previous_is_active: boolean;
  is_active: boolean;
}

export function toAdminSetDeliveryZoneActiveResult(
  data: unknown,
): AdminSetDeliveryZoneActiveResult {
  const what = "The delivery zone status change";
  const r = requireRecord(data, what);
  if (!requireBoolean(r, "changed", what)) unexpected(what);
  return {
    changed: true,
    zone_id: requireString(r, "zone_id", what),
    previous_is_active: requireBoolean(r, "previous_is_active", what),
    is_active: requireBoolean(r, "is_active", what),
  };
}

export interface AdminSetDeliveryZoneActiveArgs {
  p_zone_id: string;
  p_is_active: boolean;
  p_reason: string;
}

export type DeliveryZoneActiveBuild =
  | { ok: true; args: AdminSetDeliveryZoneActiveArgs }
  | { ok: false; errors: DeliveryFieldErrors };

export function buildSetDeliveryZoneActiveArgs(
  zoneId: string,
  isActive: boolean,
  rawReason: string,
): DeliveryZoneActiveBuild {
  const reason = checkReason(rawReason, true);
  if (reason.value === null)
    return { ok: false, errors: { reason: reason.error ?? "" } };
  return {
    ok: true,
    args: { p_zone_id: zoneId, p_is_active: isActive, p_reason: reason.value },
  };
}
