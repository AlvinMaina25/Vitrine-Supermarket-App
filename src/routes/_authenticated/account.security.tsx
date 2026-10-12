import { createFileRoute, Link } from "@tanstack/react-router";

import { MfaFactorsPanel } from "@/components/auth/mfa-factors-panel";
import { Button } from "@/components/ui-kit/button";
import { storeConfig } from "@/lib/env";

export const Route = createFileRoute("/_authenticated/account/security")({
  head: () => ({
    meta: [
      { title: `Sign-in security — ${storeConfig.name}` },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: SecurityPage,
});

function SecurityPage() {
  return (
    <section className="mx-auto max-w-xl space-y-6 px-5 pt-10 pb-16">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="eyebrow text-muted-foreground">Account</div>
          <h1 className="mt-2 font-display text-3xl font-semibold">
            Sign-in security
          </h1>
        </div>
        <Button asChild variant="outline">
          <Link to="/account">Back to account</Link>
        </Button>
      </div>
      <MfaFactorsPanel />
    </section>
  );
}
