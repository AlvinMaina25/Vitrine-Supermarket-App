import { Link } from "@tanstack/react-router";
import { SearchX, WifiOff } from "lucide-react";
import { useEffect, type ReactNode } from "react";

import { describeError } from "@/components/states/error-kind";
import { useOnlineStatus } from "@/components/states/use-online-status";
import { useSlowFlag } from "@/components/states/use-slow-flag";
import { Button } from "@/components/ui-kit/button";
import { missingSupabaseEnv } from "@/lib/env";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";

export function ErrorState({
  title = "We couldn't load this",
  message,
  onRetry,
  code,
}: {
  title?: string;
  message: string;
  onRetry?: (() => void) | undefined;
  code?: string;
}) {
  return (
    <div
      role="alert"
      className="rounded-(--radius-card) border border-danger/25 bg-danger/5 p-4"
    >
      <div className="flex items-start gap-3">
        <span className="eyebrow mt-0.5 font-medium text-danger">
          Problem{code ? ` · ${code}` : ""}
        </span>
        <div>
          <h3 className="font-display text-base font-semibold">{title}</h3>
          <p className="mt-1 max-w-[46ch] text-pretty text-sm text-muted-foreground">
            {message}
          </p>
          {onRetry ? (
            <Button variant="danger" className="mt-3" onClick={onRetry}>
              Try again
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

export function EmptyState({
  eyebrow = "Empty",
  title,
  message,
  action,
}: {
  eyebrow?: string;
  title: string;
  message: string;
  action?: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-8">
      <div className="eyebrow text-muted-foreground">{eyebrow}</div>
      <h3 className="mt-3 font-display text-2xl font-semibold">{title}</h3>
      <p className="mt-1 max-w-[40ch] text-pretty text-sm text-muted-foreground">
        {message}
      </p>
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  );
}

export function ConfigNotice() {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-8">
      <div className="eyebrow text-accent">Configuration required</div>
      <h3 className="mt-3 font-display text-2xl font-semibold">
        Connect your Supabase project
      </h3>
      <p className="mt-2 max-w-[54ch] text-pretty text-sm text-muted-foreground">
        The storefront reads its catalogue and accounts from your own Supabase
        project. Add the connection values to the environment and reload —
        nothing is mocked in the meantime.
      </p>
      <ul className="mt-3 space-y-1 font-mono text-xs text-muted-foreground">
        {missingSupabaseEnv.map((name) => (
          <li key={name}>missing · {name}</li>
        ))}
      </ul>
    </div>
  );
}

/** Renders the right state for a failed data read. */
export function QueryErrorState({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry?: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  // Plain words only: the raw error goes to the console, never to the screen.
  console.error("[query] request failed:", error);
  const friendly = describeError(
    error,
    typeof navigator === "undefined" ? undefined : navigator.onLine,
  );
  return (
    <ErrorState
      title={friendly.title}
      message={friendly.message}
      onRetry={onRetry}
    />
  );
}

export function BrowseCta() {
  return (
    <Button asChild size="touch">
      <Link to="/" search={{}}>
        Browse the shelves
      </Link>
    </Button>
  );
}

// ---- Phase 11: storefront states ------------------------------------------------------------------
// Additive. The exports above keep their behaviour because admin and checkout screens use them.

/**
 * Customer-facing failure state. Shows a calm, non-technical message with a Retry button and
 * NEVER the raw error text; the original error goes to the console only. A dropped connection
 * gets its own wording (offline) instead of a generic failure.
 */
export function StorefrontErrorState({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry?: (() => void) | undefined;
}) {
  const online = useOnlineStatus();
  useEffect(() => {
    if (error && !(error instanceof SupabaseNotConfiguredError)) {
      console.error("[storefront] request failed:", error);
    }
  }, [error]);

  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;

  const friendly = describeError(error, online);
  const offline = friendly.kind === "offline";
  return (
    <div
      role="alert"
      className={
        offline
          ? "glass-panel rounded-(--radius-panel) p-6"
          : "rounded-(--radius-panel) border border-danger/25 bg-danger/5 p-6"
      }
    >
      <div className="flex items-start gap-3">
        {offline ? (
          <WifiOff aria-hidden className="mt-1 size-5 shrink-0 text-primary" />
        ) : null}
        <div>
          <h2 className="font-display text-lg font-semibold">
            {friendly.title}
          </h2>
          <p className="mt-1 max-w-[52ch] text-pretty text-sm text-muted-foreground">
            {friendly.message}
          </p>
          {onRetry ? (
            <Button
              size="touch"
              variant={offline ? "primary" : "danger"}
              className="mt-4"
              onClick={onRetry}
            >
              Try again
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/** Proper not-found view for an unknown category or product (and any unmatched route). */
export function NotFoundState({
  title,
  message,
  action,
}: {
  title: string;
  message: string;
  action?: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-8 text-center sm:p-12">
      <SearchX aria-hidden className="mx-auto size-8 text-muted-foreground" />
      <p className="eyebrow mt-3 text-muted-foreground">Not found</p>
      <h1 className="mt-2 font-display text-2xl font-semibold text-balance">
        {title}
      </h1>
      <p className="mx-auto mt-2 max-w-[44ch] text-pretty text-sm text-muted-foreground">
        {message}
      </p>
      <div className="mt-5 flex flex-wrap justify-center gap-2">
        {action ?? <BrowseCta />}
      </div>
    </div>
  );
}

/** A calm, persistent notice while the browser reports no connection. */
export function ConnectionBanner() {
  const online = useOnlineStatus();
  if (online) return null;
  return (
    <div
      role="status"
      className="border-b border-border bg-surface-strong px-5 py-2 text-center text-sm text-foreground"
    >
      <WifiOff aria-hidden className="mr-2 inline size-4 align-text-bottom" />
      You're offline. Pages you've already opened still work; others will load
      once you're back online.
    </div>
  );
}

/** Shown under a skeleton when loading is taking unusually long. */
export function SlowNetworkHint({ loading }: { loading: boolean }) {
  const slow = useSlowFlag(loading);
  if (!slow) return null;
  return (
    <p role="status" className="mt-3 text-sm text-muted-foreground">
      This is taking longer than usual. Your connection may be slow. Thanks for
      waiting.
    </p>
  );
}

/** Matches the product page layout (image left, details right on wide screens). */
export function ProductPageSkeleton() {
  return (
    <div
      aria-busy="true"
      aria-label="Loading product"
      className="grid grid-cols-1 gap-6 md:grid-cols-2"
    >
      <div className="skeleton aspect-square w-full rounded-(--radius-panel)" />
      <div>
        <div className="skeleton h-3 w-24 rounded" />
        <div className="skeleton mt-3 h-8 w-3/4 rounded" />
        <div className="skeleton mt-4 h-6 w-28 rounded" />
        <div className="skeleton mt-6 h-3 w-full rounded" />
        <div className="skeleton mt-2 h-3 w-5/6 rounded" />
        <div className="skeleton mt-8 h-11 w-full rounded-full" />
      </div>
    </div>
  );
}

/** Matches the basket layout (lines left, summary right on wide screens). */
export function CartSkeleton() {
  return (
    <div
      aria-busy="true"
      aria-label="Loading your basket"
      className="grid grid-cols-1 gap-6 lg:grid-cols-[1fr_360px]"
    >
      <div className="space-y-3">
        {Array.from({ length: 3 }).map((_, index) => (
          <div
            key={index}
            className="glass-panel flex gap-3 rounded-(--radius-card) p-3"
          >
            <div className="skeleton size-16 shrink-0 rounded-md" />
            <div className="flex-1">
              <div className="skeleton h-4 w-2/3 rounded" />
              <div className="skeleton mt-2 h-3 w-1/3 rounded" />
              <div className="skeleton mt-4 h-11 w-32 rounded-full" />
            </div>
          </div>
        ))}
      </div>
      <div className="glass-panel h-48 rounded-(--radius-panel) p-5">
        <div className="skeleton h-4 w-1/2 rounded" />
        <div className="skeleton mt-4 h-3 w-full rounded" />
        <div className="skeleton mt-6 h-11 w-full rounded-full" />
      </div>
    </div>
  );
}
