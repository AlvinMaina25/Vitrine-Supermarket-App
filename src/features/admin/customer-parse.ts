/**
 * Shared, pure field guards for the Phase 6E.2 customer parsers. No runtime imports, so they run
 * under `node --test`. The customer RPCs return `jsonb`, so nothing about the shape is guaranteed
 * by the type system: every field is checked here instead of being cast.
 */

export type CustomerStatus = "active" | "suspended";

export type JsonRecord = Record<string, unknown>;

export function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The one failure every parser raises: the message never echoes the payload. */
export function unexpected(what: string): never {
  throw new Error(`${what} returned an unexpected response.`);
}

export function requireRecord(value: unknown, what: string): JsonRecord {
  return isRecord(value) ? value : unexpected(what);
}

export function requireArray(value: unknown, what: string): unknown[] {
  return Array.isArray(value) ? value : unexpected(what);
}

export function requireString(
  record: JsonRecord,
  key: string,
  what: string,
): string {
  const value = record[key];
  return typeof value === "string" && value !== "" ? value : unexpected(what);
}

/** Missing, null or a string. Anything else is a malformed response. */
export function nullableString(
  record: JsonRecord,
  key: string,
  what: string,
): string | null {
  const value = record[key];
  if (value === undefined || value === null) return null;
  return typeof value === "string" ? value : unexpected(what);
}

export function requireBoolean(
  record: JsonRecord,
  key: string,
  what: string,
): boolean {
  const value = record[key];
  return typeof value === "boolean" ? value : unexpected(what);
}

/** A non-negative whole number: counts, page numbers and integer cents (never fractional). */
export function requireWholeNumber(
  record: JsonRecord,
  key: string,
  what: string,
): number {
  const value = record[key];
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : unexpected(what);
}

export function requireStatus(
  record: JsonRecord,
  key: string,
  what: string,
): CustomerStatus {
  const value = record[key];
  return value === "active" || value === "suspended" ? value : unexpected(what);
}

/** Characters as the database counts them (code points, not UTF-16 units). */
export function characterCount(text: string): number {
  return Array.from(text).length;
}
