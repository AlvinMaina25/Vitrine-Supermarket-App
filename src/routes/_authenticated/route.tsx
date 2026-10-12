import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";

import { supabase } from "@/lib/supabase/client";

export const Route = createFileRoute("/_authenticated")({
  // Sessions live in browser storage, so this subtree is gated client-side only.
  ssr: false,
  beforeLoad: async ({ location }) => {
    if (!supabase) throw redirect({ to: "/auth", search: {} });
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) {
      throw redirect({ to: "/auth", search: { redirect: location.href } });
    }
    return { user: data.user };
  },
  component: () => <Outlet />,
});
