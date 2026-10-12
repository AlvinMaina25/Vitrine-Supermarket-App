import { storeConfig } from "./env";

/** All customer-facing dates and times are shown in the store's local time. */
export const STORE_TIME_ZONE = "Africa/Nairobi";

const moneyFormatters = new Map<string, Intl.NumberFormat>();

/**
 * Formats integer minor units (cents) in the given ISO currency. Orders pass
 * their own stored currency so an old order never changes if the storefront
 * currency setting does.
 */
export function formatMoney(
  cents: number,
  currency: string = storeConfig.currency,
): string {
  let formatter = moneyFormatters.get(currency);
  if (!formatter) {
    formatter = new Intl.NumberFormat("en-US", { style: "currency", currency });
    moneyFormatters.set(currency, formatter);
  }
  return formatter.format(cents / 100);
}

/** Catalogue and basket price in the storefront currency. */
export function formatPrice(cents: number): string {
  return formatMoney(cents);
}

const dateTimeFormatter = new Intl.DateTimeFormat("en-KE", {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: STORE_TIME_ZONE,
});

/** A full timestamp (e.g. an order's placed_at) in store time. */
export function formatDateTime(iso: string): string {
  return dateTimeFormatter.format(new Date(iso));
}

const calendarDateFormatter = new Intl.DateTimeFormat("en-KE", {
  weekday: "short",
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

/**
 * A calendar date with no time zone (Postgres `date`, e.g. "2026-10-01").
 * Parsed and printed in UTC so it can never shift to the previous day.
 */
export function formatCalendarDate(isoDate: string): string {
  return calendarDateFormatter.format(new Date(`${isoDate}T00:00:00Z`));
}

/** "08:00:00" -> "08:00". */
export function formatClock(time: string): string {
  return time.slice(0, 5);
}

/** "08:00:00", "11:00:00" -> "08:00 – 11:00". */
export function formatTimeWindow(start: string, end: string): string {
  return `${formatClock(start)} – ${formatClock(end)}`;
}
