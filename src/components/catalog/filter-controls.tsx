import { useEffect, useId, useState, type FormEvent } from "react";

import { Button } from "@/components/ui-kit/button";
import {
  priceRangePatch,
  toggleBrandPatch,
  type BrandFacet,
  type DiscoveryFilters,
  type DiscoverySearch,
} from "@/features/catalog/discovery";

export type SearchPatch = Record<string, string | number | true | null>;

const ROW =
  "flex min-h-11 cursor-pointer items-center gap-3 rounded-lg px-1 text-sm";
const CHECK = "size-5 shrink-0 accent-primary";
const LEGEND = "mb-1 font-display text-sm font-semibold";
const NUMBER_INPUT =
  "min-h-11 w-full min-w-0 rounded-lg border border-border bg-surface-strong px-3 text-base text-foreground md:pointer-fine:text-sm";

/**
 * The filter form: availability, offers, price range and brand. Used in the desktop sidebar and
 * the phone sheet. Every control is a native, labelled form control and every row is at least 44px
 * tall. Only filters the loaded catalogue can really answer are offered (brand appears only when
 * products have brands). All state lives in the URL: this component only reports patches.
 */
export function FilterControls({
  filters,
  search,
  facets,
  currency,
  onPatch,
}: {
  filters: DiscoveryFilters;
  search: DiscoverySearch;
  facets: readonly BrandFacet[];
  currency: string;
  onPatch: (patch: SearchPatch) => void;
}) {
  const uid = useId();
  const [minText, setMinText] = useState(
    filters.minPrice === null ? "" : String(filters.minPrice),
  );
  const [maxText, setMaxText] = useState(
    filters.maxPrice === null ? "" : String(filters.maxPrice),
  );

  // Keep the boxes in step when the URL changes elsewhere (chip removed, Clear all, Back button).
  useEffect(() => {
    setMinText(filters.minPrice === null ? "" : String(filters.minPrice));
    setMaxText(filters.maxPrice === null ? "" : String(filters.maxPrice));
  }, [filters.minPrice, filters.maxPrice]);

  function applyPrice(event?: FormEvent) {
    event?.preventDefault();
    const next = priceRangePatch(minText, maxText);
    if (next.min === filters.minPrice && next.max === filters.maxPrice) return;
    onPatch(next);
  }

  const showBrands =
    facets.length >= 2 || (facets.length > 0 && filters.brands.length > 0);
  const selectedBrands = new Set(filters.brands.map((b) => b.toLowerCase()));

  return (
    <div className="space-y-5">
      <fieldset>
        <legend className={LEGEND}>Availability</legend>
        <label className={ROW}>
          <input
            type="checkbox"
            className={CHECK}
            checked={filters.inStockOnly}
            onChange={(event) =>
              onPatch({ instock: event.target.checked ? true : null })
            }
          />
          In stock only
        </label>
        <label className={ROW}>
          <input
            type="checkbox"
            className={CHECK}
            checked={filters.onOffer}
            onChange={(event) =>
              onPatch({ offer: event.target.checked ? true : null })
            }
          />
          On offer
        </label>
      </fieldset>

      <form onSubmit={applyPrice} aria-label="Price range">
        <fieldset>
          <legend className={LEGEND}>Price ({currency})</legend>
          <div className="flex items-end gap-2">
            <div className="min-w-0 flex-1">
              <label
                htmlFor={`${uid}-min`}
                className="text-xs text-muted-foreground"
              >
                Min
              </label>
              <input
                id={`${uid}-min`}
                type="text"
                inputMode="numeric"
                autoComplete="off"
                value={minText}
                onChange={(event) => setMinText(event.target.value)}
                onBlur={() => applyPrice()}
                className={NUMBER_INPUT}
              />
            </div>
            <div className="min-w-0 flex-1">
              <label
                htmlFor={`${uid}-max`}
                className="text-xs text-muted-foreground"
              >
                Max
              </label>
              <input
                id={`${uid}-max`}
                type="text"
                inputMode="numeric"
                autoComplete="off"
                value={maxText}
                onChange={(event) => setMaxText(event.target.value)}
                onBlur={() => applyPrice()}
                className={NUMBER_INPUT}
              />
            </div>
            <Button type="submit" variant="outline" size="touch">
              Apply
            </Button>
          </div>
          <p className="mt-1 text-xs text-muted-foreground">
            Whole amounts, for example 100 and 500.
          </p>
        </fieldset>
      </form>

      {showBrands ? (
        <fieldset>
          <legend className={LEGEND}>Brand</legend>
          <div className="max-h-64 overflow-y-auto pr-1">
            {facets.map((facet) => (
              <label key={facet.label} className={ROW}>
                <input
                  type="checkbox"
                  className={CHECK}
                  checked={selectedBrands.has(facet.label.toLowerCase())}
                  onChange={() =>
                    onPatch(toggleBrandPatch(search, facet.label))
                  }
                />
                <span className="min-w-0 flex-1 break-words">
                  {facet.label}
                </span>
                <span className="text-xs text-muted-foreground tabular-nums">
                  {facet.count}
                </span>
              </label>
            ))}
          </div>
        </fieldset>
      ) : null}
    </div>
  );
}
