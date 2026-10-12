import { hasCompareAt } from "@/features/catalog/browse";
import { formatPrice } from "@/lib/format";
import { cn } from "@/lib/utils";

/**
 * Price, plus the compare-at price struck through when the product really has a higher one.
 * Amounts are integer cents from the catalogue, formatted only through formatPrice(); nothing
 * is computed here.
 */
export function PriceBlock({
  priceCents,
  compareAtCents,
  size = "md",
  className,
}: {
  priceCents: number;
  compareAtCents: number | null;
  size?: "md" | "lg";
  className?: string;
}) {
  const showCompare = hasCompareAt({
    price_cents: priceCents,
    compare_at_price_cents: compareAtCents,
  });
  return (
    <div className={cn("flex flex-wrap items-baseline gap-x-2", className)}>
      <span
        className={cn(
          "font-semibold tabular-nums",
          size === "lg" ? "text-2xl" : "text-base",
        )}
      >
        {formatPrice(priceCents)}
      </span>
      {showCompare && compareAtCents !== null ? (
        <span className="text-sm text-muted-foreground tabular-nums">
          <span className="sr-only">Was </span>
          <s>{formatPrice(compareAtCents)}</s>
        </span>
      ) : null}
    </div>
  );
}
