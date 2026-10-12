import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Outlet } from "@tanstack/react-router";

import {
  AdminMfaChallenge,
  AdminMfaEnrolPrompt,
} from "@/components/admin/admin-mfa-screens";
import {
  AdminAccessDenied,
  AdminShell,
  AdminShellLoading,
} from "@/components/admin/admin-shell";
import { ConfigNotice, ErrorState } from "@/components/states/states";
import { adminAccessQuery } from "@/features/admin/queries";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { adminMfaGate } from "@/features/auth/admin-mfa-gate";
import { mfaStatusQuery } from "@/features/auth/mfa";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";

/**
 * /admin layout. Nested under _authenticated, so signed-out visitors are redirected to /auth
 * first. Signed-in users are then checked against the database (public.is_admin): customers see
 * "Admin access required" and none of the admin UI or data. That check only decides what to
 * render; each admin RPC enforces is_admin() again server-side.
 *
 * Phase 6L.1: an admin on an aal1 session sees the two-factor enrol / challenge screen instead of
 * the admin UI (decision in features/auth/admin-mfa-gate). Also a convenience: with enforcement
 * on, the database refuses admin RPCs on aal1 sessions (DETAIL mfa_required) regardless.
 */
export const Route = createFileRoute("/_authenticated/admin")({
  head: () => ({
    meta: [{ title: "Admin" }, { name: "robots", content: "noindex" }],
  }),
  component: AdminLayout,
});

function AdminLayout() {
  const access = useQuery(adminAccessQuery());
  const isAdmin = access.data === true;
  const mfa = useQuery({ ...mfaStatusQuery(), enabled: isAdmin });

  if (access.isPending) return <AdminShellLoading />;

  if (access.isError) {
    console.error("Admin access check failed", access.error);
    return (
      <div className="mx-auto max-w-lg px-5 py-16">
        {access.error instanceof SupabaseNotConfiguredError ? (
          <ConfigNotice />
        ) : (
          <ErrorState
            title="We couldn't verify your access"
            message={adminLoadErrorMessage()}
            onRetry={() => void access.refetch()}
          />
        )}
      </div>
    );
  }

  if (mfa.isError) {
    // Fail closed: if the sign-in level cannot be read, the admin UI is not shown.
    return (
      <div className="mx-auto max-w-lg px-5 py-16">
        <ErrorState
          title="We couldn't verify your sign-in"
          message={adminLoadErrorMessage()}
          onRetry={() => void mfa.refetch()}
        />
      </div>
    );
  }

  const gate = adminMfaGate({
    loading: isAdmin && mfa.isPending,
    isAdmin,
    currentLevel: mfa.data?.currentLevel ?? null,
    hasVerifiedFactor:
      mfa.data?.factors.some((factor) => factor.verified) ?? false,
  });

  switch (gate) {
    case "loading":
      return <AdminShellLoading />;
    case "not_admin":
      return <AdminAccessDenied />;
    case "needs_enrol":
      return <AdminMfaEnrolPrompt />;
    case "needs_challenge": {
      const factor = mfa.data?.factors.find((item) => item.verified);
      return factor ? (
        <AdminMfaChallenge factorId={factor.id} />
      ) : (
        <AdminMfaEnrolPrompt />
      );
    }
    case "ok":
      return (
        <AdminShell>
          <Outlet />
        </AdminShell>
      );
  }
}
