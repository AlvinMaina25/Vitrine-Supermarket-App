import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState, type FormEvent } from "react";

import { ConfigNotice, ErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import { ADMIN_IDLE_MESSAGE, isIdleReason } from "@/features/auth/admin-idle";
import { useAuth } from "@/features/auth/auth-provider";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";

export const Route = createFileRoute("/auth")({
  validateSearch: (
    search: Record<string, unknown>,
  ): { redirect?: string; reason?: "idle" } => {
    const redirect = search["redirect"];
    const next: { redirect?: string; reason?: "idle" } = {};
    if (typeof redirect === "string" && redirect.startsWith("/"))
      next.redirect = redirect;
    const reason = search["reason"];
    if (isIdleReason(reason)) next.reason = reason;
    return next;
  },
  head: () => ({
    meta: [
      { title: `Sign in — ${storeConfig.name}` },
      {
        name: "description",
        content: `Sign in to your ${storeConfig.name} account.`,
      },
      { property: "og:title", content: `Sign in — ${storeConfig.name}` },
      {
        property: "og:description",
        content: "Sign in to save your basket and order history.",
      },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const { redirect, reason } = Route.useSearch();
  const navigate = useNavigate();
  const { signIn, signUp, user } = useAuth();

  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(
    isIdleReason(reason) ? ADMIN_IDLE_MESSAGE : null,
  );

  useEffect(() => {
    if (user) void navigate({ to: redirect ?? "/", replace: true });
  }, [user, redirect, navigate]);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    setPending(true);
    setError(null);
    setNotice(null);
    try {
      if (mode === "signin") {
        await signIn(email, password);
      } else {
        const { needsEmailConfirmation } = await signUp(email, password);
        if (needsEmailConfirmation) {
          setNotice(
            "Check your inbox to confirm your email address, then sign in.",
          );
        }
      }
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Sign in failed. Please try again.",
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <section className="mx-auto max-w-md px-5 pt-10 pb-16">
      {!isSupabaseConfigured ? (
        <ConfigNotice />
      ) : (
        <div className="glass-panel rounded-(--radius-panel) p-8">
          <div className="eyebrow text-muted-foreground">
            {mode === "signin" ? "Sign in" : "Create account"}
          </div>
          <h1 className="mt-3 font-display text-2xl font-semibold">
            {mode === "signin"
              ? `Welcome back to ${storeConfig.name}`
              : `Join ${storeConfig.name}`}
          </h1>

          <form onSubmit={onSubmit} className="mt-5 space-y-4">
            <Field label="Email" htmlFor="email">
              <TextInput
                id="email"
                type="email"
                required
                autoComplete="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="you@email.com"
              />
            </Field>
            <Field label="Password" htmlFor="password">
              <TextInput
                id="password"
                type="password"
                required
                minLength={8}
                autoComplete={
                  mode === "signin" ? "current-password" : "new-password"
                }
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="••••••••••"
              />
            </Field>

            {error ? (
              <ErrorState title="Couldn't continue" message={error} />
            ) : null}
            {notice ? (
              <p className="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-muted-foreground">
                {notice}
              </p>
            ) : null}

            <Button type="submit" size="block" disabled={pending}>
              {pending
                ? "Working…"
                : mode === "signin"
                  ? "Continue"
                  : "Create account"}
            </Button>
          </form>

          <p className="mt-3 text-center text-sm text-muted-foreground">
            {mode === "signin" ? "New here? " : "Already have an account? "}
            <button
              type="button"
              className="font-medium text-primary"
              onClick={() => setMode(mode === "signin" ? "signup" : "signin")}
            >
              {mode === "signin" ? "Create an account" : "Sign in"}
            </button>
          </p>
          <p className="mt-4 text-center text-xs text-muted-foreground">
            <Link to="/" search={{}}>
              Back to the shop
            </Link>
          </p>
        </div>
      )}
    </section>
  );
}
