/**
 * Phase 6L.2 - admin idle sign-out timing. ALL the timing logic lives here, as a pure helper with
 * an injectable clock, so it runs under `node --test` with no browser. The React hook that wires
 * it to real events and to sign-out is use-admin-idle-signout.ts.
 *
 * Design: one timer is armed for the full timeout. Activity only records "last activity at"
 * (cheap, so mousemove can call it freely). When the timer fires it compares the injected clock
 * with the last activity: idle long enough -> onIdle() once; otherwise it re-arms for exactly the
 * remaining time. `check()` does the same comparison on demand, so a laptop that slept, or a
 * background tab whose timers were throttled, signs out as soon as the page wakes up.
 */

export const ADMIN_IDLE_TIMEOUT_MS = 30 * 60 * 1000;

/** Browser events that count as activity inside /admin. */
export const ADMIN_ACTIVITY_EVENTS = [
  "mousemove",
  "mousedown",
  "keydown",
  "touchstart",
  "touchmove",
  "scroll",
  "wheel",
] as const;

/** Where the signed-out admin is sent, and the key the sign-in page reads for its message. */
export const ADMIN_IDLE_REASON = "idle";
export const ADMIN_IDLE_MESSAGE =
  "You were signed out of the admin area after 30 minutes of inactivity. Please sign in again.";

export interface IdleClock {
  /** Milliseconds, any fixed origin (Date.now in the browser). */
  now: () => number;
  setTimer: (callback: () => void, delayMs: number) => unknown;
  clearTimer: (handle: unknown) => void;
}

export interface IdleTracker {
  /** Starts counting from now. Calling it again restarts the count. */
  start: () => void;
  /** Records activity (mouse, key, touch, scroll). Ignored after the tracker has fired or stopped. */
  recordActivity: () => void;
  /** Compares the clock with the last activity right now (call when the page becomes visible). */
  check: () => void;
  /** Cancels the timer. Safe to call repeatedly. */
  stop: () => void;
  /** True once onIdle has fired. */
  hasFired: () => boolean;
}

export interface IdleTrackerOptions {
  clock: IdleClock;
  onIdle: () => void;
  timeoutMs?: number;
}

export function createIdleTracker(options: IdleTrackerOptions): IdleTracker {
  const { clock, onIdle } = options;
  const timeoutMs = options.timeoutMs ?? ADMIN_IDLE_TIMEOUT_MS;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new RangeError("timeoutMs must be a positive, finite number.");
  }

  let handle: unknown = null;
  let armed = false;
  let fired = false;
  let lastActivityAt = 0;

  function clear(): void {
    if (armed) clock.clearTimer(handle);
    handle = null;
    armed = false;
  }

  function arm(delayMs: number): void {
    clear();
    handle = clock.setTimer(evaluate, delayMs);
    armed = true;
  }

  function evaluate(): void {
    // The timer that called us has fired; it is no longer pending.
    handle = null;
    armed = false;
    if (fired) return;
    const idleFor = clock.now() - lastActivityAt;
    if (idleFor >= timeoutMs) {
      fired = true;
      onIdle();
      return;
    }
    arm(timeoutMs - idleFor);
  }

  return {
    start() {
      fired = false;
      lastActivityAt = clock.now();
      arm(timeoutMs);
    },
    recordActivity() {
      if (fired) return;
      lastActivityAt = clock.now();
    },
    check() {
      if (fired || !armed) return;
      clear();
      evaluate();
    },
    stop() {
      clear();
    },
    hasFired() {
      return fired;
    },
  };
}

/** The real clock for the browser. */
export const systemIdleClock: IdleClock = {
  now: () => Date.now(),
  setTimer: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimer: (handle) => {
    // The handle always comes from setTimer above; anything else is ignored.
    if (
      typeof handle === "number" ||
      (typeof handle === "object" && handle !== null)
    ) {
      clearTimeout(handle as ReturnType<typeof setTimeout>);
    }
  },
};

/** Query-string value the /auth page uses to decide whether to show the idle message. */
export function isIdleReason(
  value: unknown,
): value is typeof ADMIN_IDLE_REASON {
  return value === ADMIN_IDLE_REASON;
}
