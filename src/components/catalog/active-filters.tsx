import { X } from "lucide-react";

import { Button } from "@/components/ui-kit/button";
import type { FilterChip } from "@/features/catalog/discovery";

/**
 * Removable chips for every active filter, plus Clear all. Each chip is a real button with a
 * spoken name ("Remove filter: Brookside"). Nothing renders when no filter is active.
 */
export function ActiveFilters({
  chips,
  onRemove,
  onClearAll,
}: {
  chips: readonly FilterChip[];
  onRemove: (chip: FilterChip) => void;
  onClearAll: () => void;
}) {
  if (chips.length === 0) return null;
  return (
    <div
      role="group"
      aria-label="Active filters"
      className="mb-4 flex flex-wrap items-center gap-2"
    >
      {chips.map((chip) => (
        <button
          key={chip.id}
          type="button"
          onClick={() => onRemove(chip)}
          aria-label={`Remove filter: ${chip.label}`}
          className="inline-flex min-h-11 items-center gap-1.5 rounded-full border border-border bg-surface-strong pr-3 pl-4 text-sm transition duration-150 hover:border-primary hover:text-primary active:scale-[0.98]"
        >
          {chip.label}
          <X aria-hidden className="size-4" />
        </button>
      ))}
      <Button variant="ghost" size="touch" onClick={onClearAll}>
        Clear all
      </Button>
    </div>
  );
}
