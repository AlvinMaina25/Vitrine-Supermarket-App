import { Minus, Plus } from "lucide-react";
import { useEffect, useState } from "react";

import { clampQuantity } from "@/features/catalog/product-detail";

import { cn } from "@/lib/utils";

/**
 * Quantity control. Both buttons are 44px square (WCAG 2.5.5 target size) at the default size,
 * and the value is announced politely when it changes. `label` names the product for screen
 * readers ("Decrease quantity of Oat milk").
 */
export function QuantityStepper({
  value,
  onChange,
  min = 1,
  max = 99,
  size = "md",
  label,
  className,
  editable = false,
  onClamp,
}: {
  value: number;
  onChange: (next: number) => void;
  min?: number;
  max?: number;
  size?: "sm" | "md";
  label?: string;
  className?: string;
  /** Show a typed number box instead of plain text. Typed values are clamped to min and max. */
  editable?: boolean;
  /** Called when a typed number had to be changed to fit min and max, so the page can say why. */
  onClamp?: (requested: number, applied: number) => void;
}) {
  const [text, setText] = useState(String(value));
  useEffect(() => setText(String(value)), [value]);
  const commit = () => {
    const next = clampQuantity(text, min, max);
    const requested = /^\s*\d{1,4}\s*$/.test(text) ? Number(text) : Number.NaN;
    setText(String(next));
    if (Number.isFinite(requested) && requested !== next)
      onClamp?.(requested, next);
    if (next !== value) onChange(next);
  };
  const subject = label ? ` of ${label}` : "";
  const button =
    "grid size-11 shrink-0 place-items-center rounded-full text-foreground/70 hover:text-foreground disabled:opacity-40";
  return (
    <div
      role="group"
      aria-label={label ? `Quantity of ${label}` : "Quantity"}
      className={cn(
        "inline-flex items-center rounded-full border border-border bg-surface-strong",
        className,
      )}
    >
      <button
        type="button"
        aria-label={`Decrease quantity${subject}`}
        className={button}
        disabled={value <= min}
        onClick={() => onChange(value - 1)}
      >
        <Minus aria-hidden className="size-4" />
      </button>
      {editable ? (
        <input
          type="text"
          inputMode="numeric"
          autoComplete="off"
          aria-label={label ? `Enter quantity of ${label}` : "Enter quantity"}
          value={text}
          onChange={(event) =>
            setText(event.target.value.replace(/[^\d]/g, "").slice(0, 3))
          }
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              commit();
            }
          }}
          className="h-11 w-12 bg-transparent text-center font-mono text-base tabular-nums outline-none"
        />
      ) : (
        <output
          aria-live="polite"
          className={cn(
            "min-w-8 text-center font-mono tabular-nums",
            size === "sm" ? "text-sm" : "text-base",
          )}
        >
          {value}
        </output>
      )}
      <button
        type="button"
        aria-label={`Increase quantity${subject}`}
        className={button}
        disabled={value >= max}
        onClick={() => onChange(value + 1)}
      >
        <Plus aria-hidden className="size-4" />
      </button>
    </div>
  );
}
