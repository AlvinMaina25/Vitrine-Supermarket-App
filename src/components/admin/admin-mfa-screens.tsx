import { Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { MfaChallengeForm } from "@/components/auth/mfa-challenge-form";
import { Button } from "@/components/ui-kit/button";

function Screen({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm text-center">
        <div className="eyebrow text-muted-foreground">Admin</div>
        <h1 className="mt-3 font-display text-2xl font-semibold">{title}</h1>
        {children}
      </div>
    </div>
  );
}

/** Admin, aal1, no verified authenticator. Enrolment lives outside /admin so it is always reachable. */
export function AdminMfaEnrolPrompt() {
  return (
    <Screen title="Set up two-factor sign-in">
      <p className="mt-2 text-sm text-muted-foreground">
        Administrator accounts need a 6-digit code from an authenticator app.
        Set one up, then come back to the admin area.
      </p>
      <div className="mt-6">
        <Button asChild>
          <Link to="/account/security">Set up two-factor sign-in</Link>
        </Button>
      </div>
    </Screen>
  );
}

/** Admin, aal1, has a verified authenticator. On success the parent re-reads the session level. */
export function AdminMfaChallenge({ factorId }: { factorId: string }) {
  return (
    <Screen title="Enter your code">
      <p className="mt-2 mb-6 text-sm text-muted-foreground">
        Open your authenticator app and enter the 6-digit code to continue.
      </p>
      <MfaChallengeForm factorId={factorId} />
    </Screen>
  );
}
