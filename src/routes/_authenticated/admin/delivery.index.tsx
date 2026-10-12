import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { useState } from "react";
import { createFileRoute, useNavigate } from "@tanstack/react-router";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { DeliveryFeesPanel } from "@/components/admin/delivery-fees-panel";
import { DeliveryWarning } from "@/components/admin/delivery-form-parts";
import { DeliveryMethodsPanel } from "@/components/admin/delivery-methods-panel";
import { DeliverySlotsPanel } from "@/components/admin/delivery-slots-panel";
import { DeliveryZonesPanel } from "@/components/admin/delivery-zones-panel";
import { ConfigNotice, ErrorState } from "@/components/states/states";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminDeliveryConfigQuery } from "@/features/admin/delivery";
import {
  DELIVERY_TAB_LABELS,
  DELIVERY_TABS,
  activeDeliveryTab,
  noActiveZonesWarning,
  parseDeliveryParams,
  withDeliveryTab,
  withSlotRange,
  type DeliveryDateRange,
  type DeliveryParams,
} from "@/features/admin/delivery-management";
import { storeToday } from "@/features/admin/delivery-slots-view";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";

export const Route = createFileRoute("/_authenticated/admin/delivery/")({
  validateSearch: (search: Record<string, unknown>): DeliveryParams =>
    parseDeliveryParams(search),
  head: () => ({
    meta: [
      { title: "Delivery — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: DeliveryPage,
});

/**
 * /admin/delivery. Nested under the /admin layout, so signed-out visitors go to /auth and
 * non-admins see "Admin access required" and none of this UI. That only decides what to render:
 * every delivery function re-checks require_admin() in the database. The selected tab lives in
 * the URL. All four tabs are live; the Slots date range also lives in the URL.
 */
function DeliveryPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const query = useQuery(adminDeliveryConfigQuery());
  const [today] = useState(() => storeToday(new Date()));
  const tab = activeDeliveryTab(params);
  const config = query.data;
  const warning = config ? noActiveZonesWarning(config.zones) : null;

  function selectTab(value: string) {
    const next = DELIVERY_TABS.find((candidate) => candidate === value);
    if (next) void navigate({ search: withDeliveryTab(params, next) });
  }

  function changeRange(range: DeliveryDateRange | null) {
    const { from: _from, to: _to, ...rest } = params;
    void navigate({ search: range ? withSlotRange(params, range) : rest });
  }

  return (
    <>
      <AdminPageHeader
        title="Delivery"
        description="Delivery methods, zones and the fee each zone charges."
      />

      {query.isError ? (
        <DeliveryError
          error={query.error}
          onRetry={() => void query.refetch()}
        />
      ) : !config ? (
        <DeliverySkeleton />
      ) : (
        <div className="space-y-4">
          {warning ? (
            <DeliveryWarning
              title="No active delivery zones"
              message={warning}
            />
          ) : null}

          <Tabs value={tab} onValueChange={selectTab}>
            <TabsList>
              {DELIVERY_TABS.map((value) => (
                <TabsTrigger key={value} value={value}>
                  {DELIVERY_TAB_LABELS[value]}
                </TabsTrigger>
              ))}
            </TabsList>

            <TabsContent value="methods" className="mt-4">
              <DeliveryMethodsPanel methods={config.methods} />
            </TabsContent>
            <TabsContent value="zones" className="mt-4">
              <DeliveryZonesPanel zones={config.zones} />
            </TabsContent>
            <TabsContent value="fees" className="mt-4">
              <DeliveryFeesPanel
                fees={config.zone_fees}
                zones={config.zones}
                methods={config.methods}
              />
            </TabsContent>
            <TabsContent value="slots" className="mt-4">
              <DeliverySlotsPanel
                params={params}
                today={today}
                onRangeChange={changeRange}
              />
            </TabsContent>
          </Tabs>
        </div>
      )}
    </>
  );
}

function DeliverySkeleton() {
  return (
    <div
      className="space-y-2"
      role="status"
      aria-label="Loading delivery settings"
    >
      {Array.from({ length: 6 }, (_, i) => (
        <div key={i} className="skeleton h-12 rounded-lg" />
      ))}
    </div>
  );
}

function DeliveryError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  return (
    <AdminQueryError
      error={error}
      noun="delivery settings"
      action="manage delivery"
      onRetry={onRetry}
    />
  );
}
