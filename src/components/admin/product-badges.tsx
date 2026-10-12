import { cn } from "@/lib/utils";

const BASE =
  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap";

/** Active / inactive, as stored. Display only; the status card on the product page changes it. */
export function ProductActiveBadge({ active }: { active: boolean }) {
  return (
    <span
      className={cn(
        BASE,
        active
          ? "bg-primary/10 text-primary"
          : "bg-surface-strong text-muted-foreground",
      )}
    >
      {active ? "Active" : "Inactive"}
    </span>
  );
}

/** The stored in_stock flag. The quantity is shown next to it by the caller. */
export function ProductStockBadge({ inStock }: { inStock: boolean }) {
  return (
    <span
      className={cn(
        BASE,
        inStock ? "bg-primary/10 text-primary" : "bg-danger/10 text-danger",
      )}
    >
      {inStock ? "In stock" : "Out of stock"}
    </span>
  );
}
