import { cn } from "@/lib/utils";
import type { OrderStatus, PaymentStatus } from "@/lib/supabase/types";

import {
  ORDER_STATUS_LABELS,
  ORDER_STATUS_TONES,
  PAYMENT_STATUS_LABELS,
  PAYMENT_STATUS_TONES,
  type StatusTone,
} from "../status";

const TONE_CLASSES: Record<StatusTone, string> = {
  neutral: "bg-surface-strong text-muted-foreground",
  progress: "bg-primary/10 text-primary",
  success: "bg-primary text-primary-foreground",
  warning: "bg-accent/15 text-accent-foreground",
  danger: "bg-danger/10 text-danger",
};

function Badge({ tone, children }: { tone: StatusTone; children: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap",
        TONE_CLASSES[tone],
      )}
    >
      {children}
    </span>
  );
}

export function OrderStatusBadge({ status }: { status: OrderStatus }) {
  return (
    <Badge tone={ORDER_STATUS_TONES[status]}>
      {ORDER_STATUS_LABELS[status]}
    </Badge>
  );
}

export function PaymentStatusBadge({ status }: { status: PaymentStatus }) {
  return (
    <Badge tone={PAYMENT_STATUS_TONES[status]}>
      {PAYMENT_STATUS_LABELS[status]}
    </Badge>
  );
}
