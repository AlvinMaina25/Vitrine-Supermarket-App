import { MAX_CENTS } from "./delivery-parse.ts";

/**
 * The one place shillings typed by an admin become integer cents (Phase 6F.3A), and the one place
 * cents become editable shillings text. Pure string handling, no floating point, so 250.10 can
 * never turn into 25009.999. Nothing else in the admin delivery screens converts or computes
 * money; display uses the shared formatter (formatMoney in src/lib/format.ts).
 *
 * Accepted: 250, 250.5, 250.50, 1,250 and 1,250.50 (comma groups of three). Rejected: signs,
 * exponents, currency words, more than two decimals, and anything above the database limit.
 */

export type ShillingsParse =
  { ok: true; cents: number | null } | { ok: false; error: string };

const PLAIN = /^\d+(?:\.\d{1,2})?$/;
const GROUPED = /^\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?$/;

/** Blank is `null` when `optional`, otherwise an error. `label` starts the message ("The fee"). */
export function shillingsToCents(
  text: string,
  label: string,
  optional: boolean,
): ShillingsParse {
  const t = text.trim();
  if (t === "") {
    return optional
      ? { ok: true, cents: null }
      : { ok: false, error: `${label} is required.` };
  }
  if (!PLAIN.test(t) && !GROUPED.test(t)) {
    return {
      ok: false,
      error: `${label} must be an amount in shillings, such as 250 or 250.50.`,
    };
  }
  const [whole = "", fraction = ""] = t.replace(/,/g, "").split(".");
  const digits = `${whole}${fraction.padEnd(2, "0")}`.replace(/^0+(?=\d)/, "");
  const cents = Number(digits);
  if (
    digits.length > String(MAX_CENTS).length ||
    !Number.isSafeInteger(cents) ||
    cents > MAX_CENTS
  ) {
    return { ok: false, error: `${label} is too large.` };
  }
  return { ok: true, cents };
}

/** Cents as the text an admin would type back: 25000 -> "250", 25050 -> "250.50". */
export function centsToShillingsText(cents: number): string {
  if (!Number.isSafeInteger(cents) || cents < 0) return "";
  const padded = String(cents).padStart(3, "0");
  const whole = padded.slice(0, -2);
  const fraction = padded.slice(-2);
  return fraction === "00" ? whole : `${whole}.${fraction}`;
}
