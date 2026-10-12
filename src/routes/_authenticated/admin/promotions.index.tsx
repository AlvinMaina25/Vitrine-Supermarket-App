import {
  keepPreviousData,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { AdminQueryError } from "@/components/admin/admin-states";
import { InventoryPagination } from "@/components/admin/inventory-pagination";
import { PromotionCreateForm } from "@/components/admin/promotion-create-form";
import { EmptyState } from "@/components/states/states";
import { useOnlineStatus } from "@/components/states/use-online-status";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui-kit/button";
import { TextInput } from "@/components/ui-kit/field";
import {
  adminActionFailureMessage,
  filterLoadedRows,
  sortLoadedRows,
  type SortDirection,
} from "@/features/admin/admin-ui";
import { setPromotionActive } from "@/features/promotions/admin-api";
import { describePromotionValue } from "@/features/promotions/admin-form";
import {
  ADMIN_PROMOTIONS_PAGE_SIZE,
  adminPromotionsQuery,
} from "@/features/promotions/admin-queries";
import type { PromotionAdminRow } from "@/features/promotions/admin-parse";
import { formatDateTime, formatMoney } from "@/lib/format";

export const Route = createFileRoute("/_authenticated/admin/promotions/")({
  validateSearch: (search: Record<string, unknown>): { page?: number } => {
    const page = Number(search["page"]);
    return Number.isInteger(page) && page > 1 ? { page } : {};
  },
  head: () => ({
    meta: [
      { title: "Promotions — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: PromotionsPage,
});

type SortKey = "newest" | "name" | "status";

const SORTS: Record<
  SortKey,
  {
    label: string;
    key: (row: PromotionAdminRow) => string | number | null;
    direction: SortDirection;
  }
> = {
  newest: {
    label: "Newest first",
    key: (row) => Date.parse(row.created_at),
    direction: "desc",
  },
  name: { label: "Name A–Z", key: (row) => row.name, direction: "asc" },
  status: {
    label: "Live first",
    key: (row) => (row.is_active ? 0 : 1),
    direction: "asc",
  },
};

/**
 * /admin/promotions. Lists what admin_list_promotions() returns and creates / activates /
 * deactivates through the existing RPC wrappers. The database refuses non-admins and the screen
 * then shows the shared no-access state. Search and sort here only arrange the rows already
 * loaded ("this page only"); discounts are never calculated in the browser.
 */
function PromotionsPage() {
  const { page: pageParam } = Route.useSearch();
  const page = pageParam ?? 1;
  const navigate = useNavigate({ from: Route.fullPath });
  const query = useQuery({
    ...adminPromotionsQuery(page),
    placeholderData: keepPreviousData,
  });

  const [creating, setCreating] = useState(false);
  const [term, setTerm] = useState("");
  const [sort, setSort] = useState<SortKey>("newest");

  const rows = useMemo(() => {
    if (!query.data) return [];
    const filtered = filterLoadedRows(query.data.rows, term, (r) => [
      r.name,
      r.code,
    ]);
    const s = SORTS[sort];
    return sortLoadedRows(filtered, s.key, s.direction);
  }, [query.data, term, sort]);

  return (
    <>
      <AdminPageHeader
        title="Promotions"
        description="Coupon codes and automatic discounts. A promotion can be switched off but never deleted."
        actions={
          creating ? undefined : (
            <Button size="touch" onClick={() => setCreating(true)}>
              New promotion
            </Button>
          )
        }
      />

      {creating ? (
        <PromotionCreateForm onDone={() => setCreating(false)} />
      ) : null}

      {query.isPending ? (
        <div
          className="space-y-2"
          role="status"
          aria-label="Loading promotions"
        >
          {Array.from({ length: 4 }, (_, i) => (
            <div key={i} className="skeleton h-20 rounded-lg" />
          ))}
        </div>
      ) : query.isError ? (
        <AdminQueryError
          error={query.error}
          noun="promotions"
          action="view promotions"
          onRetry={() => void query.refetch()}
        />
      ) : query.data.total === 0 ? (
        <EmptyState
          eyebrow="No promotions"
          title="No promotions yet"
          message="Create one to offer a coupon code or an automatic discount."
        />
      ) : (
        <>
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <div className="min-w-0 flex-1 basis-56">
              <label
                htmlFor="promo-filter"
                className="eyebrow block text-muted-foreground"
              >
                Find on this page
              </label>
              <TextInput
                id="promo-filter"
                type="search"
                className="mt-1.5 min-h-11"
                placeholder="Name or code"
                value={term}
                onChange={(e) => setTerm(e.target.value)}
              />
            </div>
            <div>
              <label
                htmlFor="promo-sort"
                className="eyebrow block text-muted-foreground"
              >
                Sort this page
              </label>
              <select
                id="promo-sort"
                value={sort}
                onChange={(e) => setSort(e.target.value as SortKey)}
                className="mt-1.5 min-h-11 rounded-lg border border-border bg-background px-3 py-2 text-base md:pointer-fine:text-sm"
              >
                {(Object.keys(SORTS) as SortKey[]).map((key) => (
                  <option key={key} value={key}>
                    {SORTS[key].label}
                  </option>
                ))}
              </select>
            </div>
          </div>
          {term.trim() !== "" ? (
            <p role="status" className="mb-3 text-xs text-muted-foreground">
              Showing {rows.length} of {query.data.rows.length} on this page
              only. Other pages are not searched.
            </p>
          ) : null}

          {rows.length === 0 ? (
            <EmptyState
              eyebrow="No match"
              title="Nothing on this page matches"
              message="Clear the search, or try another page."
            />
          ) : (
            <ul
              className="space-y-3"
              aria-busy={query.isFetching}
              aria-label="Promotions"
            >
              {rows.map((row) => (
                <PromotionCard key={row.id} row={row} />
              ))}
            </ul>
          )}
          <InventoryPagination
            label="Promotions pagination"
            total={query.data.total}
            limit={ADMIN_PROMOTIONS_PAGE_SIZE}
            offset={(page - 1) * ADMIN_PROMOTIONS_PAGE_SIZE}
            rows={query.data.rows.length}
            disabled={query.isFetching}
            onPage={(next) =>
              void navigate({
                search: next > 1 ? { page: next } : {},
              })
            }
          />
        </>
      )}
    </>
  );
}

function PromotionCard({ row }: { row: PromotionAdminRow }) {
  const queryClient = useQueryClient();
  const online = useOnlineStatus();
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: (isActive: boolean) => setPromotionActive(row.id, isActive),
    onSuccess: (updated) => {
      setError(null);
      toast.success(
        `“${updated.name}” is now ${updated.is_active ? "live" : "inactive"}.`,
      );
    },
    onError: (cause) => {
      console.error("Promotion toggle failed", cause);
      setError(
        adminActionFailureMessage(
          cause,
          online,
          cause instanceof Error
            ? cause.message
            : "The change could not be saved. Please try again.",
        ),
      );
    },
    onSettled: async () => {
      inFlight.current = false;
      await queryClient.invalidateQueries({
        queryKey: ["admin", "promotions"],
      });
    },
  });
  const pending = mutation.isPending;
  const next = !row.is_active;

  function confirm() {
    setConfirming(false);
    if (inFlight.current || mutation.isPending) return;
    inFlight.current = true;
    setError(null);
    mutation.mutate(next);
  }

  return (
    <li className="glass-panel rounded-(--radius-panel) p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="font-display text-lg font-semibold">{row.name}</h3>
          <p className="mt-0.5 font-mono text-xs text-muted-foreground">
            {row.code ?? "Automatic (no code)"}
          </p>
        </div>
        <span
          className={`rounded-full px-2.5 py-1 text-xs font-medium ${row.is_active ? "bg-primary/10 text-primary" : "bg-surface-strong text-muted-foreground"}`}
        >
          {row.is_active ? "Live" : "Inactive"}
        </span>
      </div>

      <dl className="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <Item
          term="Discount"
          value={describePromotionValue(row, (c) => formatMoney(c))}
        />
        {row.max_discount_cents !== null ? (
          <Item term="Maximum" value={formatMoney(row.max_discount_cents)} />
        ) : null}
        <Item
          term="Minimum order"
          value={
            row.min_order_cents > 0 ? formatMoney(row.min_order_cents) : "None"
          }
        />
        <Item
          term="Starts"
          value={row.starts_at ? formatDateTime(row.starts_at) : "Any time"}
        />
        <Item
          term="Ends"
          value={row.expires_at ? formatDateTime(row.expires_at) : "No end"}
        />
        <Item
          term="Uses"
          value={`${row.active_redemptions ?? 0}${row.usage_limit !== null ? ` of ${row.usage_limit}` : ""}${row.per_customer_limit !== null ? ` · ${row.per_customer_limit} per customer` : ""}`}
        />
      </dl>

      {error ? (
        <p
          role="alert"
          className="mt-3 rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {error}
        </p>
      ) : null}

      <div className="mt-3">
        <Button
          size="touch"
          variant={row.is_active ? "outline" : "primary"}
          disabled={pending}
          onClick={() => setConfirming(true)}
        >
          {pending ? "Saving…" : row.is_active ? "Deactivate" : "Activate"}
        </Button>
      </div>

      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {next ? "Activate" : "Deactivate"} “{row.name}”?
            </AlertDialogTitle>
            <AlertDialogDescription>
              {next
                ? "Customers can use it straight away, and it changes what they pay."
                : "Customers will no longer be able to use it. Orders already placed keep their discount."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Go back</AlertDialogCancel>
            <Button
              variant={next ? "primary" : "danger"}
              disabled={pending}
              onClick={confirm}
            >
              {next ? "Activate" : "Deactivate"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </li>
  );
}

function Item({ term, value }: { term: string; value: string }) {
  return (
    <div>
      <dt className="eyebrow text-muted-foreground">{term}</dt>
      <dd className="tabular-nums">{value}</dd>
    </div>
  );
}
