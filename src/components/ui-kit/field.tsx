import type { ComponentProps, ReactNode } from "react";

import { cn } from "@/lib/utils";

export function Field({
  label,
  htmlFor,
  hint,
  error,
  children,
}: {
  label: string;
  htmlFor: string;
  hint?: ReactNode;
  /** Phase 14: an inline problem with this field. The input should set aria-invalid and aria-describedby={`${htmlFor}-error`}. */
  error?: string | null | undefined;
  children: ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="eyebrow text-muted-foreground block">
        {label}
      </label>
      {children}
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
      {error ? (
        <p id={`${htmlFor}-error`} className="text-xs font-medium text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
}

export function TextInput({ className, ...props }: ComponentProps<"input">) {
  return (
    <input
      className={cn(
        "min-h-11 w-full min-w-0 rounded-lg border border-border bg-background px-3 py-2 text-base text-foreground md:pointer-fine:text-sm placeholder:text-muted-foreground focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary",
        className,
      )}
      {...props}
    />
  );
}

export function TextArea({ className, ...props }: ComponentProps<"textarea">) {
  return (
    <textarea
      className={cn(
        "w-full min-w-0 rounded-lg border border-border bg-background px-3 py-2 text-base text-foreground md:pointer-fine:text-sm placeholder:text-muted-foreground focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary",
        className,
      )}
      {...props}
    />
  );
}
