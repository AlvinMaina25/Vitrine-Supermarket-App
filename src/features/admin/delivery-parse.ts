import {
  isRecord,
  requireString,
  unexpected,
  type JsonRecord,
} from "./customer-parse.ts";

/**
 * Shared, pure helpers for the Phase 6F.2 delivery admin parsers (methods, zones, zone fees,
 * slot templates and per-date overrides). No runtime imports beyond sibling pure modules, so they
 * run under `node --test`. Money is integer cents and is only ever checked here, never computed.
 */

/** Limits the database enforces (6F.1A / 6F.1B); the frontend only mirrors them for early errors. */
export const MAX_CENTS = 2_147_483_647;
export const MAX_CAPACITY = 100_000;
export const MAX_POSITION = 1_000_000;
export const MAX_ZONE_NAME_LENGTH = 120;
export const MAX_COUNTY_LENGTH = 80;
export const MAX_ZONE_DESCRIPTION_LENGTH = 500;
export const MAX_TOWNS = 100;
export const MAX_TOWN_LENGTH = 80;
export const MAX_SLOT_LABEL_LENGTH = 80;
export const MAX_OVERRIDE_NOTE_LENGTH = 300;
export const MAX_DELIVERY_REASON_LENGTH = 500;
export const MAX_SLOT_RANGE_DAYS = 31;

export const ZONE_CODE_PATTERN = /^[a-z][a-z0-9_-]{1,39}$/;

/** A non-negative whole number or null (nullable cents, capacity, weekday). */
export function nullableWholeNumber(
  record: JsonRecord,
  key: string,
  what: string,
): number | null {
  const value = record[key];
  if (value === undefined || value === null) return null;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : unexpected(what);
}

export function requireStringArray(
  record: JsonRecord,
  key: string,
  what: string,
): string[] {
  const value = record[key];
  if (!Array.isArray(value)) return unexpected(what);
  return value.map((item) =>
    typeof item === "string" ? item : unexpected(what),
  );
}

/** The jsonb row as an object, or the shared "unexpected response" failure. */
export function parseList<T>(
  value: unknown,
  what: string,
  parseRow: (row: JsonRecord) => T,
): T[] {
  if (!Array.isArray(value)) return unexpected(what);
  return value.map((row) => (isRecord(row) ? parseRow(row) : unexpected(what)));
}

/** A calendar date as the database prints it: YYYY-MM-DD, and a real day. */
export function isIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const date = new Date(`${value}T00:00:00Z`);
  return (
    !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value
  );
}

export function requireIsoDate(
  record: JsonRecord,
  key: string,
  what: string,
): string {
  const value = record[key];
  return isIsoDate(value) ? value : unexpected(what);
}

/** A time of day as the database prints it (HH:MM:SS) or as a form sends it (HH:MM). */
export function normaliseTime(value: string): string | null {
  const match = /^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/.exec(value.trim());
  return match ? `${match[1]}:${match[2]}:${match[3] ?? "00"}` : null;
}

export function requireTime(
  record: JsonRecord,
  key: string,
  what: string,
): string {
  const value = requireString(record, key, what);
  return normaliseTime(value) === null ? unexpected(what) : value;
}

export function inWholeRange(value: number, max: number): boolean {
  return Number.isSafeInteger(value) && value >= 0 && value <= max;
}

export interface ReasonCheck {
  value: string | null;
  error: string | null;
}

/** Trims a reason; `required` makes blank an error. Length is counted by code point. */
export function checkReason(raw: string, required: boolean): ReasonCheck {
  const value = raw.trim();
  if (value === "") {
    return required
      ? { value: null, error: "A reason is required." }
      : { value: null, error: null };
  }
  if (Array.from(value).length > MAX_DELIVERY_REASON_LENGTH) {
    return {
      value: null,
      error: `Keep the reason to ${MAX_DELIVERY_REASON_LENGTH} characters or fewer.`,
    };
  }
  return { value, error: null };
}
