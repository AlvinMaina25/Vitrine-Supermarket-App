import { Button } from "@/components/ui-kit/button";
import { TextInput } from "@/components/ui-kit/field";
import {
  CUSTOMER_STATUS_LABELS,
  CUSTOMER_STATUSES,
  CUSTOMERS_MAX_SEARCH_LENGTH,
} from "@/features/admin/customers-management";
import type { CustomerStatus } from "@/features/admin/customers-result";

const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background min-h-11 px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

/**
 * Search box and status select for the customers list. Pure display: it reports what was typed
 * or chosen and the caller owns the state (and any debounce). An empty status means all.
 */
export function CustomerFilters({
  search,
  status,
  onSearchChange,
  onStatusChange,
  onClear,
}: {
  /** What is in the box right now. */
  search: string;
  status: CustomerStatus | null;
  onSearchChange: (value: string) => void;
  onStatusChange: (status: CustomerStatus | null) => void;
  onClear: () => void;
}) {
  function handleStatus(value: string) {
    // Values come from the closed option list below; anything else means "all customers".
    const chosen = CUSTOMER_STATUSES.find((option) => option === value);
    onStatusChange(chosen ?? null);
  }

  return (
    <div className="glass-panel mb-4 grid grid-cols-1 gap-3 rounded-(--radius-panel) p-4 md:grid-cols-[2fr_1fr_auto] md:items-end">
      <div className="space-y-1.5">
        <label
          htmlFor="customers-search"
          className="eyebrow block text-muted-foreground"
        >
          Search
        </label>
        <TextInput
          id="customers-search"
          type="search"
          value={search}
          maxLength={CUSTOMERS_MAX_SEARCH_LENGTH}
          onChange={(event) => onSearchChange(event.target.value)}
          placeholder="Name, email or phone"
        />
      </div>
      <div className="space-y-1.5">
        <label
          htmlFor="customers-status"
          className="eyebrow block text-muted-foreground"
        >
          Status
        </label>
        <select
          id="customers-status"
          className={SELECT_CLASS}
          value={status ?? ""}
          onChange={(event) => handleStatus(event.target.value)}
        >
          <option value="">All customers</option>
          {CUSTOMER_STATUSES.map((option) => (
            <option key={option} value={option}>
              {CUSTOMER_STATUS_LABELS[option]}
            </option>
          ))}
        </select>
      </div>
      <Button
        variant="outline"
        disabled={search === "" && status === null}
        onClick={onClear}
      >
        Clear
      </Button>
    </div>
  );
}
