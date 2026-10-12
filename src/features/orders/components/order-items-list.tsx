import { Link } from "@tanstack/react-router";

import { formatMoney } from "@/lib/format";
import type { OrderItemRow } from "@/lib/supabase/types";

/**
 * Renders the snapshot stored with the order. Names, SKUs and prices come
 * from order_items, never from the live product record, so a later price
 * change cannot rewrite history.
 */
export function OrderItemsList({
  items,
  currency,
}: {
  items: OrderItemRow[];
  currency: string;
}) {
  return (
    <ul className="divide-y divide-border">
      {items.map((item) => (
        <li key={item.id} className="flex items-center gap-3 py-3">
          {item.image_url ? (
            <img
              src={item.image_url}
              alt=""
              loading="lazy"
              decoding="async"
              width={48}
              height={48}
              className="size-12 shrink-0 rounded-md object-cover"
            />
          ) : (
            <div
              className="size-12 shrink-0 rounded-md bg-background"
              aria-hidden="true"
            />
          )}
          <div className="min-w-0 flex-1">
            {item.product_slug ? (
              <Link
                to="/product/$slug"
                params={{ slug: item.product_slug }}
                className="block truncate text-sm font-medium"
              >
                {item.product_name}
              </Link>
            ) : (
              <span className="block truncate text-sm font-medium">
                {item.product_name}
              </span>
            )}
            <div className="font-mono text-[11px] text-muted-foreground">
              {item.variant_name ? `${item.variant_name} · ` : ""}
              {item.quantity} × {formatMoney(item.unit_price_cents, currency)}
              {item.unit_label ? ` · ${item.unit_label}` : ""}
            </div>
          </div>
          <span className="text-sm font-medium">
            {formatMoney(item.line_total_cents, currency)}
          </span>
        </li>
      ))}
    </ul>
  );
}
