import { createFileRoute, Link } from "@tanstack/react-router";

import { AdminNotAvailable } from "@/components/admin/admin-states";
import { AdminPageHeader } from "@/components/admin/admin-shell";
import { Button } from "@/components/ui-kit/button";

export const Route = createFileRoute("/_authenticated/admin/reports/")({
  head: () => ({
    meta: [
      { title: "Reports — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: ReportsPage,
});

/**
 * /admin/reports. There is no report read in the database yet (the only aggregate is the
 * dashboard summary), so this page shows no figures and invents none. It exists so the section
 * is reachable and says plainly why it is empty.
 */
function ReportsPage() {
  return (
    <>
      <AdminPageHeader title="Reports" />
      <AdminNotAvailable
        title="Reports are not available yet"
        message="No report data is exposed by the database yet, so nothing is shown here rather than estimating figures. The dashboard shows the figures the database already provides, with the time they were produced."
      >
        <Button asChild size="touch">
          <Link to="/admin">Open the dashboard</Link>
        </Button>
      </AdminNotAvailable>
    </>
  );
}
