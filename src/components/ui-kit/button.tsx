import { cva, type VariantProps } from "class-variance-authority";
import { Slot } from "@radix-ui/react-slot";
import type { ComponentProps } from "react";

import { cn } from "@/lib/utils";

export const buttonVariants = cva(
  "inline-flex max-md:min-h-11 pointer-coarse:min-h-11 items-center justify-center gap-2 rounded-full font-medium transition duration-150 active:scale-[0.98] disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
  {
    variants: {
      variant: {
        primary: "bg-primary text-primary-foreground hover:bg-primary/85",
        outline:
          "border border-border bg-surface-strong text-foreground hover:bg-background",
        ghost: "text-foreground/70 hover:text-foreground",
        danger: "bg-danger text-danger-foreground hover:bg-danger/85",
        onImage: "bg-surface-strong text-foreground hover:bg-white",
      },
      size: {
        sm: "px-3 py-1 text-xs",
        md: "px-4 py-2 text-sm",
        lg: "px-5 py-2.5 text-sm",
        block: "w-full px-4 py-2.5 text-sm",
        /* Phase 11: 44px minimum touch target for storefront controls. Existing sizes are unchanged. */
        touch: "min-h-11 px-5 text-sm",
        touchBlock: "min-h-11 w-full px-5 text-sm",
        touchIcon: "size-11 shrink-0 p-0",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

type ButtonProps = ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & { asChild?: boolean };

export function Button({
  className,
  variant,
  size,
  asChild,
  ...props
}: ButtonProps) {
  const Comp = asChild ? Slot : "button";
  return (
    <Comp
      className={cn(buttonVariants({ variant, size }), className)}
      {...props}
    />
  );
}
