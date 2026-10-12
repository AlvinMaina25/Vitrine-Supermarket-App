import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { CustomerFilters } from "@/components/admin/customer-filters";
import { CustomersTable } from "@/components/admin/customers-table";
import {
  ConfigNotice,
  EmptyState,
  ErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminCustomersQuery } from "@/features/admin/customers";
import {
  hasCustomersFilter,
  parseCustomersParams,
  withCustomersFilter,
  withCustomersPage,
  type CustomersParams,
} from "@/features/admin/customers-management";
import type { CustomerStatus } from "@/features/admin/customers-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";

export const Route = createFileRoute("/_authenticated/admin/customers/")({
  validateSearch: (search: Record<string, unknown>): CustomersParams =>
    parseCustomersParams(search),
  head: () => ({
    meta: [
      { title: "Customers — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: CustomersPage,
});

/**
 * /admin/customers. Nested under the /admin layout, so signed-out visitors go to /auth and
 * non-admins see "Admin access required" and none of this UI. That only decides what to render:
 * admin_list_customers() re-checks require_admin() in the database, so a customer who reaches
 * the URL or calls the function directly still gets no customer data.
 */
function CustomersPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  // Search, status and page all live in the URL; the database does the searching and paging.
  const query = useQuery({
    ...adminCustomersQuery(params),
    // Keep the previous page on screen while the next one loads, so filtering doesn't flash.
    placeholderData: keepPreviousData,
  });

  // The URL holds the committed search; the box holds what is being typed.
  const [term, setTerm] = useState(params.q ?? "");
  // The search value our own debounced navigation is about to put in the URL, if any.
  const pendingQ = useRef<string | null>(null);

  // Copy the URL into the box only when the URL changed for another reason (back/forward, Clear).
  // The echo of our own navigation is skipped: by the time it lands the person may have typed
  // more, and writing the older value back would delete those characters.
  useEffect(() => {
    const url = params.q ?? "";
    if (pendingQ.current !== null) {
      const ours = pendingQ.current === url;
      pendingQ.current = null;
      if (ours) return;
    }
    setTerm(url);
  }, [params.q]);

  // Search runs after a short pause so each keystroke is not a request.
  useEffect(() => {
    const target = withCustomersFilter(params, { q: term });
    if ((target.q ?? "") === (params.q ?? "")) return;
    const timer = setTimeout(() => {
      pendingQ.current = target.q ?? "";
      void navigate({ search: target, replace: true });
    }, 350);
    return () => clearTimeout(timer);
  }, [term, params, navigate]);

  function setStatus(status: CustomerStatus | null) {
    void navigate({ search: withCustomersFilter(params, { status }) });
  }

  function goToPage(page: number) {
    void navigate({ search: withCustomersPage(params, page) });
  }

  function clearAll() {
    pendingQ.current = null;
    setTerm("");
    void navigate({ search: {} });
  }

  const hasFilters = hasCustomersFilter(params);
  const refreshing = query.isPlaceholderData;
  const list = query.data;

  return (
    <>
      <AdminPageHeader
        title="Customers"
        description="Customer accounts and their order history."
      />

      <CustomerFilters
        search={term}
        status={params.status ?? null}
        onSearchChange={setTerm}
        onStatusChange={setStatus}
        onClear={clearAll}
      />

      {query.isError ? (
        <CustomersError
          error={query.error}
          onRetry={() => void query.refetch()}
        />
      ) : !list ? (
        <CustomersSkeleton />
      ) : list.customers.length === 0 ? (
        <EmptyState
          eyebrow="No customers"
          title={
            list.total > 0
              ? "That page is past the last result"
              : hasFilters
                ? "No customers match"
                : "No customers yet"
          }
          message={
            list.total > 0
              ? "Go back to an earlier page to see the results."
              : hasFilters
                ? "Try a different search or clear the filters."
                : "Customers will appear here once people create an account."
          }
          action={
            hasFilters || list.total > 0 ? (
              <Button variant="outline" onClick={clearAll}>
                {hasFilters
                  ? "Clear search and filters"
                  : "Back to the first page"}
              </Button>
            ) : undefined
          }
        />
      ) : (
        <CustomersTable
          rows={list.customers}
          total={list.total}
          page={list.page}
          pageSize={list.page_size}
          refreshing={refreshing}
          onPage={goToPage}
        />
      )}
    </>
  );
}

function CustomersSkeleton() {
  return (
    <div className="space-y-2" role="status" aria-label="Loading customers">
      {Array.from({ length: 8 }, (_, i) => (
        <div key={i} className="skeleton h-12 rounded-lg" />
      ))}
    </div>
  );
}

function CustomersError({
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
      noun="customers"
      action="view customers"
      onRetry={onRetry}
    />
  );
}
