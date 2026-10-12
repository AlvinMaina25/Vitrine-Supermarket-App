import { SlidersHorizontal } from "lucide-react";
import type { ReactNode } from "react";

import { Button } from "@/components/ui-kit/button";
import {
  Sheet,
  SheetClose,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import {
  parseDiscoverySort,
  sortOptionsFor,
  type DiscoverySortKey,
} from "@/features/catalog/discovery";

/** Native select: best keyboard and touch behaviour, 44px tall, labelled. */
export function SortSelect({
  value,
  hasQuery,
  onChange,
}: {
  value: DiscoverySortKey;
  hasQuery: boolean;
  onChange: (sort: DiscoverySortKey) => void;
}) {
  return (
    <label className="flex items-center gap-2 text-sm">
      <span className="text-muted-foreground">Sort by</span>
      <select
        value={value}
        onChange={(event) =>
          onChange(parseDiscoverySort(event.target.value, hasQuery))
        }
        className="min-h-11 rounded-lg border border-border bg-surface-strong px-3 text-base text-foreground md:pointer-fine:text-sm"
      >
        {sortOptionsFor(hasQuery).map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  );
}

/**
 * Phone/tablet filters: a sheet that slides in from the left. The footer button reports the live
 * result count and closes the sheet. Desktop uses the same controls in a sidebar instead.
 */
export function FiltersSheet({
  activeCount,
  resultText,
  children,
}: {
  activeCount: number;
  resultText: string;
  children: ReactNode;
}) {
  return (
    <Sheet>
      <SheetTrigger asChild>
        <Button variant="outline" size="touch" className="lg:hidden">
          <SlidersHorizontal aria-hidden className="size-4" />
          Filters{activeCount > 0 ? ` (${activeCount})` : ""}
        </Button>
      </SheetTrigger>
      <SheetContent
        side="left"
        className="flex w-[88vw] max-w-sm flex-col overflow-hidden"
      >
        <SheetHeader className="text-left">
          <SheetTitle className="font-display">Filters</SheetTitle>
          <SheetDescription className="sr-only">
            Narrow the products by availability, offers, price and brand.
          </SheetDescription>
        </SheetHeader>
        <div className="min-h-0 flex-1 overflow-y-auto pr-1">{children}</div>
        <SheetFooter>
          <SheetClose asChild>
            <Button size="touchBlock">Show results ({resultText})</Button>
          </SheetClose>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}
