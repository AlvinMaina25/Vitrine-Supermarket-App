import { useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { normalizeCouponCode } from "../logic";

/**
 * Minimal coupon box for checkout (Phase 8). It only collects a code; it never shows or sends an
 * amount. The parent runs the preview and owns what is applied.
 */
export function CouponInput({
  applied,
  message,
  busy,
  onApply,
  onRemove,
}: {
  /** The code currently applied, or null. */
  applied: string | null;
  /** A safe message about the applied code (e.g. "This coupon has expired."), or null. */
  message: string | null;
  busy: boolean;
  onApply: (code: string) => void;
  onRemove: () => void;
}) {
  const [draft, setDraft] = useState("");
  const removeRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  // Applying or removing swaps one control for another, so the focused one unmounts. Hand focus
  // to its replacement, otherwise keyboard users land back at the top of the page.
  const focusNext = useRef<"remove" | "input" | null>(null);

  useEffect(() => {
    if (focusNext.current === "remove" && applied !== null) {
      removeRef.current?.focus();
    } else if (focusNext.current === "input" && applied === null) {
      inputRef.current?.focus();
    } else {
      return;
    }
    focusNext.current = null;
  }, [applied]);

  if (applied !== null) {
    return (
      <div className="mt-4 text-sm">
        <div className="flex items-center justify-between gap-3">
          <span>
            Coupon <span className="font-mono">{applied}</span>
          </span>
          <Button
            ref={removeRef}
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => {
              focusNext.current = "input";
              onRemove();
            }}
          >
            Remove
          </Button>
        </div>
        {busy ? (
          <p role="status" className="mt-1 text-xs text-muted-foreground">
            Checking your coupon…
          </p>
        ) : null}
        {message ? (
          <p role="alert" className="mt-1 text-xs text-danger">
            {message}
          </p>
        ) : null}
      </div>
    );
  }

  const code = normalizeCouponCode(draft);
  return (
    <div className="mt-4">
      <label htmlFor="coupon-code" className="text-sm">
        Coupon code
      </label>
      <div className="mt-1 flex gap-2">
        <Input
          ref={inputRef}
          id="coupon-code"
          value={draft}
          maxLength={32}
          autoComplete="off"
          onChange={(event) => setDraft(event.target.value)}
        />
        <Button
          type="button"
          variant="outline"
          disabled={busy || code === null}
          onClick={() => {
            if (code !== null) {
              focusNext.current = "remove";
              onApply(code);
              setDraft("");
            }
          }}
        >
          Apply
        </Button>
      </div>
    </div>
  );
}
