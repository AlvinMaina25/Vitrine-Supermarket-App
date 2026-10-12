import { formatDateTime } from "@/lib/format";
import type { OrderStatusHistoryRow } from "@/lib/supabase/types";

import { buildTimeline, type TimelineEntry } from "../timeline";

/**
 * Timeline of what actually happened.
 *
 * Rendered only from recorded order_status_history rows (see ../timeline.ts for the wording and
 * mapping), so no future or assumed step is ever shown as complete, and no time, rider or
 * place is invented. Cancelled and refunded are marked as end states, not as steps.
 */

function markerClass(entry: TimelineEntry): string {
  const base =
    "absolute -left-[26px] top-1.5 size-3 border-2 border-background";
  if (entry.kind === "end") return `${base} rounded-sm bg-danger`;
  if (entry.kind === "payment") return `${base} rounded-full bg-accent`;
  return `${base} rounded-full ${entry.isLatest ? "bg-primary" : "bg-muted-foreground/40"}`;
}

export function OrderTimeline({
  history,
}: {
  history: OrderStatusHistoryRow[];
}) {
  const entries = buildTimeline(history);

  if (entries.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No status updates have been recorded for this order yet.
      </p>
    );
  }

  return (
    <ol
      aria-label="Order status history, oldest first"
      className="relative space-y-5 border-l border-border pl-6"
    >
      {entries.map((entry) => (
        <li
          key={entry.id}
          aria-current={entry.isLatest ? "step" : undefined}
          className="relative"
        >
          <span aria-hidden="true" className={markerClass(entry)} />
          <div className="flex flex-wrap items-baseline gap-x-2">
            <span
              className={`text-sm font-medium ${
                entry.kind === "end" ? "text-danger" : ""
              }`}
            >
              {entry.title}
            </span>
            {entry.kind === "payment" ? (
              <span className="eyebrow text-muted-foreground">Payment</span>
            ) : null}
            {entry.kind === "end" ? (
              <span className="eyebrow text-muted-foreground">
                Final status
              </span>
            ) : null}
          </div>
          <p className="mt-0.5 text-sm text-muted-foreground">
            {entry.description}
          </p>
          <time
            dateTime={entry.at}
            className="mt-0.5 block font-mono text-[11px] text-muted-foreground"
          >
            {formatDateTime(entry.at)}
          </time>
          {entry.note ? (
            <p className="mt-1 text-xs text-muted-foreground">
              Note: {entry.note}
            </p>
          ) : null}
        </li>
      ))}
    </ol>
  );
}
