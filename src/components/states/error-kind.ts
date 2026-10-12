/**
 * Classifies a failed read for customers (Phase 11). PURE.
 *
 * Raw error text from the database or the network never reaches the screen: callers log the
 * original to the console and show the title/message returned here.
 */

export type ErrorKind = "offline" | "generic";

export interface FriendlyError {
  kind: ErrorKind;
  title: string;
  message: string;
}

const NETWORK_PATTERN =
  /failed to fetch|networkerror|network request failed|load failed|network error|err_internet|fetch failed|timeout|timed out|abort/i;

/** True when the failure looks like a dropped or missing connection rather than a server answer. */
export function isNetworkFailure(
  error: unknown,
  online: boolean | undefined,
): boolean {
  if (online === false) return true;
  if (error instanceof TypeError) return NETWORK_PATTERN.test(error.message);
  if (error instanceof Error) return NETWORK_PATTERN.test(error.message);
  if (typeof error === "string") return NETWORK_PATTERN.test(error);
  return false;
}

export function describeError(
  error: unknown,
  online: boolean | undefined,
): FriendlyError {
  if (isNetworkFailure(error, online)) {
    return {
      kind: "offline",
      title: "You seem to be offline",
      message:
        "We couldn't reach the shop. Check your connection or signal and try again. Your basket is safe on this device.",
    };
  }
  return {
    kind: "generic",
    title: "We couldn't load this",
    message: "Something went wrong on our side. Please try again in a moment.",
  };
}
