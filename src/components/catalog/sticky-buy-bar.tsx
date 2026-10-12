import { useEffect, useState, type RefObject } from "react";

import { Button } from "@/components/ui-kit/button";
import { formatPrice } from "@/lib/format";

/**
 * Phone-only add-to-basket bar. It appears only while the real purchase block has scrolled out
 * of view, so there is never a duplicate button on screen. Sits above the home-indicator inset.
 */
export function StickyBuyBar({
  targetRef,
  label,
  priceCents,
  disabled,
  buttonText,
  onAdd,
}: {
  targetRef: RefObject<HTMLElement | null>;
  label: string;
  priceCents: number;
  disabled: boolean;
  buttonText: string;
  onAdd: () => void;
}) {
  const [show, setShow] = useState(false);
  useEffect(() => {
    const el = targetRef.current;
    if (!el || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(([entry]) => {
      // Only once the block is above the viewport (scrolled past), not while it is still below.
      setShow(
        !!entry && !entry.isIntersecting && entry.boundingClientRect.top < 0,
      );
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [targetRef]);
  if (!show) return null;
  return (
    <div
      data-sticky-buy
      role="region"
      aria-label="Quick add to basket"
      className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-background/95 px-4 pt-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] backdrop-blur md:hidden"
    >
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium">{label}</p>
          <p className="text-sm tabular-nums">{formatPrice(priceCents)}</p>
        </div>
        <Button size="touch" disabled={disabled} onClick={onAdd}>
          {buttonText}
        </Button>
      </div>
    </div>
  );
}
