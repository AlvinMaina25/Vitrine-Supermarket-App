import { stockLabel, type StockState } from "@/features/catalog/browse";
import { cn } from "@/lib/utils";

/** Sold-out / low-stock pill. Renders nothing for a normally stocked product. */
export function StockBadge({
  state,
  className,
}: {
  state: StockState;
  className?: string;
}) {
  const label = stockLabel(state);
  if (!label) return null;
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium",
        state.kind === "out"
          ? "bg-foreground text-background"
          : "bg-accent text-accent-foreground",
        className,
      )}
    >
      {label}
    </span>
  );
}

export function SaleBadge({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground",
        className,
      )}
    >
      On offer
    </span>
  );
}
