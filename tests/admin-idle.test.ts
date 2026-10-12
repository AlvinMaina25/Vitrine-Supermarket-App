import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  ADMIN_ACTIVITY_EVENTS,
  ADMIN_IDLE_REASON,
  ADMIN_IDLE_TIMEOUT_MS,
  createIdleTracker,
  isIdleReason,
  type IdleClock,
} from "../src/features/auth/admin-idle.ts";

const MINUTE = 60 * 1000;

interface Pending {
  id: number;
  at: number;
  callback: () => void;
}

/** A manual clock: time only moves when the test says so, and due timers run in order. */
function fakeClock(): IdleClock & {
  advance: (ms: number) => void;
  pending: () => number;
} {
  let time = 1_000_000;
  let nextId = 1;
  let timers: Pending[] = [];
  return {
    now: () => time,
    setTimer: (callback, delayMs) => {
      const id = nextId++;
      timers.push({ id, at: time + delayMs, callback });
      return id;
    },
    clearTimer: (handle) => {
      timers = timers.filter((t) => t.id !== handle);
    },
    pending: () => timers.length,
    advance(ms) {
      const target = time + ms;
      for (;;) {
        const due = timers
          .filter((t) => t.at <= target)
          .sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers = timers.filter((t) => t.id !== due.id);
        time = Math.max(time, due.at);
        due.callback();
      }
      time = target;
    },
  };
}

function setup(timeoutMs?: number) {
  const clock = fakeClock();
  let idleCalls = 0;
  const tracker = createIdleTracker({
    clock,
    onIdle: () => {
      idleCalls += 1;
    },
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
  });
  return { clock, tracker, idleCalls: () => idleCalls };
}

describe("createIdleTracker", () => {
  it("defaults to 30 minutes", () => {
    assert.equal(ADMIN_IDLE_TIMEOUT_MS, 30 * MINUTE);
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(30 * MINUTE - 1);
    assert.equal(idleCalls(), 0);
    clock.advance(1);
    assert.equal(idleCalls(), 1);
    assert.equal(tracker.hasFired(), true);
  });

  it("does not fire before the timeout", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(29 * MINUTE);
    assert.equal(idleCalls(), 0);
    assert.equal(tracker.hasFired(), false);
  });

  it("activity pushes the deadline out to 30 minutes after the activity", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(20 * MINUTE);
    tracker.recordActivity();
    clock.advance(29 * MINUTE);
    assert.equal(idleCalls(), 0);
    clock.advance(1 * MINUTE);
    assert.equal(idleCalls(), 1);
  });

  it("steady activity every 10 minutes never signs out", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    for (let i = 0; i < 20; i += 1) {
      clock.advance(10 * MINUTE);
      tracker.recordActivity();
    }
    assert.equal(idleCalls(), 0);
  });

  it("fires only once, even if time keeps passing or activity is recorded afterwards", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(31 * MINUTE);
    tracker.recordActivity();
    clock.advance(120 * MINUTE);
    tracker.check();
    assert.equal(idleCalls(), 1);
  });

  it("recordActivity never creates timers (cheap enough for mousemove)", () => {
    const { clock, tracker } = setup();
    tracker.start();
    const before = clock.pending();
    for (let i = 0; i < 1000; i += 1) tracker.recordActivity();
    assert.equal(clock.pending(), before);
    assert.equal(before, 1);
  });

  it("check() signs out immediately when the page wakes up long after the deadline", () => {
    // A sleeping laptop: wall time jumps but the throttled timer callback never runs.
    const clock = fakeClock();
    let calls = 0;
    const tracker = createIdleTracker({
      clock: { now: clock.now, setTimer: () => 1, clearTimer: () => undefined },
      onIdle: () => {
        calls += 1;
      },
    });
    tracker.start();
    clock.advance(45 * MINUTE);
    assert.equal(calls, 0);
    tracker.check();
    assert.equal(calls, 1);
  });

  it("check() before the deadline does not fire and keeps the tracker armed", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(10 * MINUTE);
    tracker.check();
    assert.equal(idleCalls(), 0);
    assert.equal(clock.pending(), 1);
    clock.advance(20 * MINUTE);
    assert.equal(idleCalls(), 1);
  });

  it("stop() cancels everything; a stopped tracker never fires and check() is a no-op", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    tracker.stop();
    tracker.stop();
    assert.equal(clock.pending(), 0);
    clock.advance(120 * MINUTE);
    tracker.check();
    assert.equal(idleCalls(), 0);
    assert.equal(tracker.hasFired(), false);
  });

  it("start() again restarts the count and clears a previous firing", () => {
    const { clock, tracker, idleCalls } = setup();
    tracker.start();
    clock.advance(31 * MINUTE);
    assert.equal(idleCalls(), 1);
    tracker.start();
    assert.equal(tracker.hasFired(), false);
    clock.advance(29 * MINUTE);
    assert.equal(idleCalls(), 1);
    clock.advance(1 * MINUTE);
    assert.equal(idleCalls(), 2);
    // Restarting while armed never leaves two timers behind.
    tracker.start();
    tracker.start();
    assert.equal(clock.pending(), 1);
  });

  it("honours a custom timeout", () => {
    const { clock, tracker, idleCalls } = setup(5 * MINUTE);
    tracker.start();
    clock.advance(5 * MINUTE);
    assert.equal(idleCalls(), 1);
  });

  it("rejects a non-positive or non-finite timeout", () => {
    for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      assert.throws(() => setup(bad), RangeError);
    }
  });
});

describe("activity events and reason flag", () => {
  it("covers mouse, key, touch and scroll", () => {
    const names: readonly string[] = ADMIN_ACTIVITY_EVENTS;
    for (const required of [
      "mousemove",
      "mousedown",
      "keydown",
      "touchstart",
      "scroll",
    ]) {
      assert.ok(names.includes(required), required);
    }
  });

  it("isIdleReason accepts only the idle flag", () => {
    assert.equal(ADMIN_IDLE_REASON, "idle");
    assert.equal(isIdleReason("idle"), true);
    for (const bad of [undefined, null, "", "IDLE", "timeout", 1, {}]) {
      assert.equal(isIdleReason(bad), false);
    }
  });
});
