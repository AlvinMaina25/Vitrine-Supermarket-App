import { ProductCard } from "@/components/catalog/product-card";
import { ProductCardSkeleton } from "@/components/catalog/product-card";
import type { ReactNode } from "react";
import type { ProductRow } from "@/lib/supabase/types";

const ITEM = "w-[44vw] max-w-[220px] shrink-0 snap-start sm:w-[200px]";

/** A single-row, swipeable shelf of products (home page "On offer", "Recently added"). */
export function ProductShelf({
  id,
  title,
  products,
  loading = false,
  action,
  subtitle,
}: {
  id: string;
  title: string;
  products: ProductRow[];
  loading?: boolean;
  /** Small control beside the title (for example a Clear button). */
  action?: ReactNode;
  subtitle?: string;
}) {
  if (!loading && products.length === 0) return null;
  return (
    <section
      aria-labelledby={`${id}-title`}
      className="mx-auto max-w-[1400px] px-4 pt-8 sm:px-5"
    >
      <div className="mb-3 flex flex-wrap items-center justify-between gap-x-4">
        <div>
          <h2
            id={`${id}-title`}
            className="font-display text-xl font-bold tracking-tight sm:text-2xl"
          >
            {title}
          </h2>
          {subtitle ? (
            <p className="text-sm text-muted-foreground">{subtitle}</p>
          ) : null}
        </div>
        {action}
      </div>
      <ul className="no-scrollbar relative -mx-4 flex scroll-pl-4 snap-x sm:scroll-pl-5 gap-3 overflow-x-auto px-4 pb-2 sm:-mx-5 sm:px-5">
        {loading
          ? Array.from({ length: 5 }).map((_, index) => (
              <li key={index} className={ITEM} aria-hidden>
                <ProductCardSkeleton />
              </li>
            ))
          : products.map((product) => (
              <li key={product.id} className={`${ITEM} flex`}>
                <ProductCard product={product} />
              </li>
            ))}
      </ul>
    </section>
  );
}
