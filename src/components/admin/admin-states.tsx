import { Link } from "@tanstack/react-router";
import { LockKeyhole, WifiOff } from "lucide-react";
import { useEffect, type ReactNode } from "react";

import { ConfigNotice, ErrorState } from "@/components/states/states";
import { useOnlineStatus } from "@/components/states/use-online-status";
import { Button } from "@/components/ui-kit/button";
import {
  adminLoadFailedCopy,
  adminNoAccessCopy,
  adminOfflineCopy,
  classifyAdminLoadError,
} from "@/features/admin/admin-ui";
import { useAuth } from "@/features/auth/auth-provider";

/**
 * Phase 15: the one "the server refused this" state for every admin screen.
 *
 * It is only ever rendered because the DATABASE refused a read (an AdminAccessError built from
 * SQLSTATE 42501). It shows no data from the failed read, offers a retry (the answer can change
 * after signing in again or a role change) and a sign-out, and grants nothing.
 */
export function AdminNoAccess({
  action,
  onRetry,
}: {
  /** Completes "Your account is not permitted to …", e.g. "view orders". */
  action: string;
  onRetry?: (() => void) | undefined;
}) {
  const { signOut } = useAuth();
  const copy = adminNoAccessCopy(action);
  return (
    <div
      role="alert"
      className="rounded-(--radius-panel) border border-border bg-surface p-6"
    >
      <div className="flex items-start gap-3">
        <LockKeyhole
          aria-hidden
          className="mt-1 size-5 shrink-0 text-muted-foreground"
        />
        <div className="min-w-0">
          <p className="eyebrow text-muted-foreground">403</p>
          <h2 className="mt-1 font-display text-lg font-semibold">
            {copy.title}
          </h2>
          <p className="mt-1 max-w-[56ch] text-pretty text-sm text-muted-foreground">
            {copy.message}
          </p>
          {copy.hint ? (
            <p className="mt-2 max-w-[56ch] text-pretty text-xs text-muted-foreground">
              {copy.hint}
            </p>
          ) : null}
          <div className="mt-4 flex flex-wrap gap-2">
            {onRetry ? (
              <Button size="touch" variant="outline" onClick={onRetry}>
                Try again
              </Button>
            ) : null}
            <Button size="touch" variant="ghost" onClick={() => void signOut()}>
              Sign out
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

/**
 * The failed-read state for an admin screen. Picks, in order: configuration notice, no-access,
 * offline, then a plain failure. Raw error text is never shown; it goes to the console.
 *
 * `noun` completes "We couldn't load …" ("orders"); `action` completes "Your account is not
 * permitted to …" ("view orders").
 */
export function AdminQueryError({
  error,
  noun,
  action,
  onRetry,
}: {
  error: unknown;
  noun: string;
  action: string;
  onRetry: () => void;
}) {
  const online = useOnlineStatus();
  const kind = classifyAdminLoadError(error, online);

  useEffect(() => {
    if (kind === "failed" || kind === "offline") {
      console.error(`[admin] could not load ${noun}:`, error);
    }
  }, [kind, noun, error]);

  switch (kind) {
    case "not_configured":
      return <ConfigNotice />;
    case "no_access":
      return <AdminNoAccess action={action} onRetry={onRetry} />;
    case "offline": {
      const copy = adminOfflineCopy();
      return (
        <div role="alert" className="glass-panel rounded-(--radius-panel) p-6">
          <div className="flex items-start gap-3">
            <WifiOff
              aria-hidden
              className="mt-1 size-5 shrink-0 text-primary"
            />
            <div>
              <h2 className="font-display text-lg font-semibold">
                {copy.title}
              </h2>
              <p className="mt-1 max-w-[56ch] text-pretty text-sm text-muted-foreground">
                {copy.message}
              </p>
              <Button size="touch" className="mt-4" onClick={onRetry}>
                Try again
              </Button>
            </div>
          </div>
        </div>
      );
    }
    case "failed": {
      const copy = adminLoadFailedCopy(noun);
      return (
        <ErrorState
          title={copy.title}
          message={copy.message}
          onRetry={onRetry}
        />
      );
    }
  }
}

/**
 * A section whose backend read does not exist yet. It says so plainly and shows no figures;
 * nothing here is mocked or estimated.
 */
export function AdminNotAvailable({
  title,
  message,
  children,
}: {
  title: string;
  message: string;
  children?: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-8">
      <div className="eyebrow text-muted-foreground">Not available yet</div>
      <h2 className="mt-3 font-display text-2xl font-semibold">{title}</h2>
      <p className="mt-1 max-w-[56ch] text-pretty text-sm text-muted-foreground">
        {message}
      </p>
      <div className="mt-4 flex flex-wrap gap-2">
        {children ?? (
          <Button asChild size="touch" variant="outline">
            <Link to="/admin">Back to the dashboard</Link>
          </Button>
        )}
      </div>
    </div>
  );
}
