import { useId } from "react";

import {
  variantStockState,
  type VariantLike,
} from "@/features/catalog/product-detail";
import { formatPrice } from "@/lib/format";
import { cn } from "@/lib/utils";

/**
 * Option picker: native radio buttons in a labelled fieldset (arrow keys, screen readers and
 * touch all work). Every option shows its name, price and availability. Sold-out options stay
 * selectable so a shared link shows what was shared, but they are labelled and cannot be added.
 */
export function VariantSelector<T extends VariantLike>({
  variants,
  selectedId,
  onSelect,
}: {
  variants: readonly T[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  const name = useId();
  return (
    <fieldset className="mt-5">
      <legend className="mb-2 text-sm font-medium">Choose an option</legend>
      <div className="flex flex-wrap gap-2">
        {variants.map((variant) => {
          const state = variantStockState(variant);
          const out = state.kind === "out";
          const checked = variant.id === selectedId;
          return (
            <label
              key={variant.id}
              className={cn(
                "relative flex min-h-11 min-w-[8rem] cursor-pointer flex-col justify-center rounded-xl border px-4 py-2 text-sm has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-primary",
                checked
                  ? "border-primary bg-primary/10"
                  : "border-border bg-surface-strong hover:border-primary",
                out && "text-muted-foreground",
              )}
            >
              <input
                type="radio"
                name={name}
                value={variant.id}
                checked={checked}
                onChange={() => onSelect(variant.id)}
                className="sr-only"
              />
              <span className="font-medium">{variant.name}</span>
              <span className="tabular-nums">
                {formatPrice(variant.price_cents)}
              </span>
              <span className="text-xs">
                {out
                  ? "Sold out"
                  : state.kind === "low"
                    ? `Only ${state.left} left`
                    : "In stock"}
              </span>
            </label>
          );
        })}
      </div>
    </fieldset>
  );
}
