import { useNavigate } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

import {
  ADMIN_ACTIVITY_EVENTS,
  ADMIN_IDLE_REASON,
  createIdleTracker,
  systemIdleClock,
} from "./admin-idle.ts";
import { useAuth } from "./auth-provider";

/**
 * Phase 6L.2 - signs the admin out after 30 minutes without mouse, key, touch or scroll activity,
 * then sends them to /auth with a short message. Mounted only by AdminShell, so it runs inside
 * /admin and nowhere in the customer shop. All timing lives in the pure helper (admin-idle.ts).
 *
 * This is a browser-side convenience. The real session lifetime is set in the Supabase dashboard
 * (JWT expiry, session time-box / inactivity timeout, refresh-token rotation); code cannot change it.
 */
export function useAdminIdleSignOut(): void {
  const { signOut } = useAuth();
  const navigate = useNavigate();

  // Keep the latest callbacks without restarting the timer when they change identity.
  const signOutRef = useRef(signOut);
  const navigateRef = useRef(navigate);
  useEffect(() => {
    signOutRef.current = signOut;
    navigateRef.current = navigate;
  }, [signOut, navigate]);

  useEffect(() => {
    const tracker = createIdleTracker({
      clock: systemIdleClock,
      onIdle: () => {
        void signOutRef
          .current()
          .catch(() => undefined)
          .then(() =>
            navigateRef.current({
              to: "/auth",
              search: { reason: ADMIN_IDLE_REASON },
              replace: true,
            }),
          );
      },
    });

    const onActivity = (): void => tracker.recordActivity();
    const onVisibility = (): void => {
      if (document.visibilityState === "visible") tracker.check();
    };

    for (const name of ADMIN_ACTIVITY_EVENTS) {
      window.addEventListener(name, onActivity, {
        passive: true,
        capture: true,
      });
    }
    document.addEventListener("visibilitychange", onVisibility);
    tracker.start();

    return () => {
      tracker.stop();
      for (const name of ADMIN_ACTIVITY_EVENTS) {
        window.removeEventListener(name, onActivity, { capture: true });
      }
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);
}
