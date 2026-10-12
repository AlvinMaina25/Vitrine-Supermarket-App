import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";

import { ProductShelf } from "@/components/catalog/product-shelf";
import { Button } from "@/components/ui-kit/button";
import { resolveRecentlyViewed } from "@/features/catalog/recently-viewed";
import { productsQuery } from "@/features/catalog/queries";
import { useRecentlyViewed } from "@/features/catalog/use-recently-viewed";
import { isSupabaseConfigured } from "@/lib/env";

/**
 * Products this device looked at recently. Ids come from localStorage and are re-checked against
 * the live catalogue, so deleted or deactivated products silently disappear. Nothing is sent to
 * the server. Renders nothing when there is nothing to show.
 */
export function RecentlyViewedShelf({ excludeId }: { excludeId?: string }) {
  const { ids, ready, clear } = useRecentlyViewed();
  const { data } = useQuery({
    ...productsQuery(),
    enabled: isSupabaseConfigured && ready && ids.length > 0,
  });
  const products = useMemo(
    () =>
      resolveRecentlyViewed(ids, data ?? [], {
        ...(excludeId ? { excludeId } : {}),
      }),
    [ids, data, excludeId],
  );
  if (products.length === 0) return null;
  return (
    <ProductShelf
      id="recently-viewed"
      title="Recently viewed"
      subtitle="Saved on this device only."
      products={products}
      action={
        <Button variant="ghost" size="touch" onClick={clear}>
          Clear recently viewed
        </Button>
      }
    />
  );
}
