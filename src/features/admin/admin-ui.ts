import { isNetworkFailure } from "../../components/states/error-kind.ts";
import { isAdminAccessError } from "./dashboard-result.ts";

/**
 * Phase 15: pure helpers for the admin UI. No runtime imports from the app, so they run under
 * `node --test` as well as in the browser.
 *
 * Nothing here decides who may do what. A "no access" answer always comes from the database (an
 * AdminAccessError built from SQLSTATE 42501 by the per-area result mappers); these helpers only
 * choose the words and the arrangement of rows that were already loaded.
 */

// ---------------------------------------------------------------- load failures

export type AdminLoadFailureKind =
  "not_configured" | "no_access" | "offline" | "failed";

/**
 * Which state a failed admin read should show. The order matters: a missing configuration and a
 * database refusal are never reported as a connection problem, and a dropped connection is
 * reported as one even when the browser's own error text is odd.
 */
export function classifyAdminLoadError(
  error: unknown,
  online: boolean | undefined,
): AdminLoadFailureKind {
  if (error instanceof Error && error.name === "SupabaseNotConfiguredError") {
    return "not_configured";
  }
  if (isAdminAccessError(error)) return "no_access";
  if (isNetworkFailure(error, online)) return "offline";
  return "failed";
}

export interface AdminStateCopy {
  title: string;
  message: string;
  /** A second, quieter line. Optional. */
  hint?: string;
}

/**
 * The no-access wording. `action` completes "Your account is not permitted to …", for example
 * "view orders". The hint covers the two cases a person can fix themselves without the screen
 * having to guess which one it is: a session that needs two-factor again, or a role that changed.
 */
export function adminNoAccessCopy(action: string): AdminStateCopy {
  return {
    title: "Admin access required",
    message: `Your account is not permitted to ${action}. Nothing was loaded.`,
    hint: "If your role or two-factor sign-in changed recently, sign in again. Otherwise ask an administrator.",
  };
}

/**
 * The full-page "not an administrator" wording, shown when the database says the signed-in user
 * is not an admin (public.is_admin). `isStaff` only chooses the words: a staff member is told
 * plainly that staff access does not include the admin area, so they do not think the account is
 * broken. It decides nothing; the admin RPCs refuse a staff caller regardless.
 */
export function adminAccessDeniedCopy(isStaff: boolean): AdminStateCopy {
  return {
    title: "Admin access required",
    message: isStaff
      ? "Your account has staff access, but the admin area is for store administrators."
      : "This area is for store administrators.",
    hint: "If you think you should have access, ask an existing administrator to grant it.",
  };
}

export function adminOfflineCopy(): AdminStateCopy {
  return {
    title: "You appear to be offline",
    message:
      "We couldn't reach the server, so this page may be out of date. Check your connection and try again.",
  };
}

/** `what` is a plural noun phrase: "orders", "delivery settings". */
export function adminLoadFailedCopy(what: string): AdminStateCopy {
  return {
    title: `We couldn't load ${what}`,
    message:
      "Something went wrong while loading this page. Please try again in a moment.",
  };
}

// ---------------------------------------------------------------- action failures

/**
 * Wording for a refused or failed admin ACTION (as opposed to a read). The per-area describe
 * functions already turn known database reasons into plain words; this only covers what they
 * do not: a refusal because the account is not allowed, and a dropped connection. Raw database
 * text is never returned.
 */
export function adminActionFailureMessage(
  error: unknown,
  online: boolean | undefined,
  fallback: string,
): string {
  if (isAdminAccessError(error)) {
    return "Your account is not permitted to do this. Nothing was changed. If your sign-in changed recently, sign in again.";
  }
  if (isNetworkFailure(error, online)) {
    return "We couldn't reach the server, so nothing was changed. Check your connection and try again.";
  }
  return fallback;
}

// ---------------------------------------------------------------- "as of" label

/**
 * "As of 11 Oct 2026, 14:05 (Africa/Nairobi)" from the dashboard's generated_at and time_zone.
 * Returns null when either is unusable, so the caller can leave the line out instead of
 * printing a wrong time.
 */
export function asOfLabel(
  generatedAt: string,
  timeZone: string,
): string | null {
  const date = new Date(generatedAt);
  if (Number.isNaN(date.getTime())) return null;
  try {
    const text = new Intl.DateTimeFormat("en-KE", {
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
      timeZone,
    }).format(date);
    return `As of ${text} (${timeZone})`;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- loaded-row arrangement

/**
 * Case-insensitive "contains" filter over rows that are ALREADY loaded. It never asks the
 * database for more, so a screen using it must say "this page only". A blank term keeps every row.
 */
export function filterLoadedRows<T>(
  rows: readonly T[],
  term: string,
  texts: (row: T) => readonly (string | null | undefined)[],
): T[] {
  const needle = term.trim().toLowerCase();
  if (needle === "") return [...rows];
  return rows.filter((row) =>
    texts(row).some(
      (text) => typeof text === "string" && text.toLowerCase().includes(needle),
    ),
  );
}

export type SortDirection = "asc" | "desc";

/**
 * Stable sort of loaded rows by one key. Missing values (null / undefined) always sort last,
 * whatever the direction, so an empty cell never jumps to the top.
 */
export function sortLoadedRows<T>(
  rows: readonly T[],
  key: (row: T) => string | number | null | undefined,
  direction: SortDirection,
): T[] {
  const sign = direction === "asc" ? 1 : -1;
  return rows
    .map((row, index) => ({ row, index, value: key(row) }))
    .sort((a, b) => {
      const aMissing = a.value === null || a.value === undefined;
      const bMissing = b.value === null || b.value === undefined;
      if (aMissing || bMissing) {
        if (aMissing && bMissing) return a.index - b.index;
        return aMissing ? 1 : -1;
      }
      let order = 0;
      if (typeof a.value === "number" && typeof b.value === "number") {
        order = a.value - b.value;
      } else {
        order = String(a.value).localeCompare(String(b.value), "en", {
          sensitivity: "base",
          numeric: true,
        });
      }
      return order !== 0 ? sign * order : a.index - b.index;
    })
    .map((entry) => entry.row);
}

// ---------------------------------------------------------------- forms

/** The first field, in screen order, that has an error message. Used to move focus on submit. */
export function firstErrorField<K extends string>(
  errors: Partial<Record<K, string | null | undefined>>,
  order: readonly K[],
): K | null {
  for (const key of order) {
    const message = errors[key];
    if (typeof message === "string" && message !== "") return key;
  }
  return null;
}
