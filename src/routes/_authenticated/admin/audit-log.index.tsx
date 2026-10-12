import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { createFileRoute, useNavigate } from "@tanstack/react-router";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { InventoryPagination } from "@/components/admin/inventory-pagination";
import {
  ConfigNotice,
  EmptyState,
  ErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { TextInput } from "@/components/ui-kit/field";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { adminAuditLogQuery } from "@/features/admin/audit-log";
import {
  AUDIT_LOG_MAX_TEXT_LENGTH,
  hasAuditLogFilter,
  parseAuditLogParams,
  shortId,
  withAuditLogFilter,
  withAuditLogPage,
  type AuditLogParams,
} from "@/features/admin/audit-log-params";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import { formatDateTime } from "@/lib/format";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_authenticated/admin/audit-log/")({
  validateSearch: (search: Record<string, unknown>): AuditLogParams =>
    parseAuditLogParams(search),
  head: () => ({
    meta: [
      { title: "Audit log — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: AuditLogPage,
});

/**
 * /admin/audit-log. Read only. The database re-checks admin rights inside admin_list_audit_log(),
 * so this UI only decides what to render. Every value is shown as plain text.
 */
function AuditLogPage() {
  const params = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const query = useQuery({
    ...adminAuditLogQuery(params),
    placeholderData: keepPreviousData,
  });

  const hasFilters = hasAuditLogFilter(params);
  const refreshing = query.isPlaceholderData;
  const list = query.data;

  function setFilter(change: Parameters<typeof withAuditLogFilter>[1]) {
    void navigate({ search: withAuditLogFilter(params, change) });
  }

  function clearAll() {
    void navigate({ search: {} });
  }

  return (
    <>
      <AdminPageHeader
        title="Audit log"
        description="A read-only record of admin actions."
      />

      <div className="glass-panel mb-4 grid grid-cols-1 gap-3 rounded-(--radius-panel) p-4 md:grid-cols-3">
        <FilterField
          id="audit-action"
          label="Action"
          value={params.action ?? ""}
          onCommit={(v) => setFilter({ action: v })}
        />
        <FilterField
          id="audit-target"
          label="Target id"
          value={params.targetId ?? ""}
          onCommit={(v) => setFilter({ targetId: v })}
        />
        <FilterField
          id="audit-actor"
          label="Actor id"
          value={params.actorId ?? ""}
          onCommit={(v) => setFilter({ actorId: v })}
        />
        <FilterField
          id="audit-from"
          label="From"
          type="date"
          value={params.from ?? ""}
          onCommit={(v) => setFilter({ from: v })}
        />
        <FilterField
          id="audit-to"
          label="To"
          type="date"
          value={params.to ?? ""}
          onCommit={(v) => setFilter({ to: v })}
        />
        <div className="flex items-end">
          <Button variant="outline" disabled={!hasFilters} onClick={clearAll}>
            Clear
          </Button>
        </div>
      </div>

      {query.isError ? (
        <AuditLogError
          error={query.error}
          onRetry={() => void query.refetch()}
        />
      ) : !list ? (
        <div className="space-y-2" role="status" aria-label="Loading audit log">
          {Array.from({ length: 8 }, (_, i) => (
            <div key={i} className="skeleton h-12 rounded-lg" />
          ))}
        </div>
      ) : list.entries.length === 0 ? (
        <EmptyState
          eyebrow="No entries"
          title={
            list.total_count > 0
              ? "That page is past the last result"
              : hasFilters
                ? "No entries match"
                : "No audit entries yet"
          }
          message={
            list.total_count > 0
              ? "Go back to an earlier page to see the results."
              : hasFilters
                ? "Try different filters or clear them."
                : "Admin actions will be recorded here."
          }
          action={
            hasFilters || list.total_count > 0 ? (
              <Button variant="outline" onClick={clearAll}>
                {hasFilters ? "Clear filters" : "Back to the first page"}
              </Button>
            ) : undefined
          }
        />
      ) : (
        <div
          className={cn(
            "glass-panel rounded-(--radius-panel) p-2 transition-opacity sm:p-4",
            refreshing && "opacity-60",
          )}
          aria-busy={refreshing}
        >
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Time</TableHead>
                <TableHead>Actor</TableHead>
                <TableHead>Action</TableHead>
                <TableHead>Target</TableHead>
                <TableHead>Reason</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {list.entries.map((entry) => (
                <TableRow key={entry.id}>
                  <TableCell
                    className="text-sm whitespace-nowrap"
                    title={entry.created_at}
                  >
                    {formatDateTime(entry.created_at)}
                  </TableCell>
                  <TableCell
                    className="font-mono text-sm"
                    title={entry.actor_id ?? undefined}
                  >
                    {entry.actor_id === null
                      ? "System"
                      : shortId(entry.actor_id)}
                  </TableCell>
                  <TableCell className="text-sm break-all">
                    {entry.action}
                  </TableCell>
                  <TableCell
                    className="font-mono text-sm"
                    title={entry.target_id ?? undefined}
                  >
                    {entry.target_id === null ? "—" : shortId(entry.target_id)}
                  </TableCell>
                  <TableCell className="text-sm break-words whitespace-pre-wrap">
                    {entry.reason ?? "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <InventoryPagination
            label="Audit log pagination"
            total={list.total_count}
            limit={list.limit}
            offset={list.offset}
            rows={list.entries.length}
            disabled={refreshing}
            onPage={(page) =>
              void navigate({ search: withAuditLogPage(params, page) })
            }
          />
        </div>
      )}
    </>
  );
}

/** Commits on blur or Enter (uncontrolled, keyed on the URL value), so typing does not query. */
function FilterField({
  id,
  label,
  value,
  type = "text",
  onCommit,
}: {
  id: string;
  label: string;
  value: string;
  type?: "text" | "date";
  onCommit: (value: string | null) => void;
}) {
  const commit = (raw: string) => {
    const next = raw.trim();
    if (next !== value) onCommit(next === "" ? null : next);
  };
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="eyebrow block text-muted-foreground">
        {label}
      </label>
      <TextInput
        key={value}
        id={id}
        type={type}
        defaultValue={value}
        maxLength={type === "text" ? AUDIT_LOG_MAX_TEXT_LENGTH : undefined}
        onBlur={(event) => commit(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit(event.currentTarget.value);
        }}
      />
    </div>
  );
}

function AuditLogError({
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
      noun="the audit log"
      action="view the audit log"
      onRetry={onRetry}
    />
  );
}
