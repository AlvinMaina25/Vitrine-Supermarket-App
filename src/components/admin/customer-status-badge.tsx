import { CUSTOMER_STATUS_LABELS } from "@/features/admin/customers-management";
import type { CustomerStatus } from "@/features/admin/customers-result";
import { cn } from "@/lib/utils";

const BASE =
  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap";

const TONE: Record<CustomerStatus, string> = {
  active: "bg-primary/10 text-primary",
  suspended: "bg-danger/10 text-danger",
};

/** The stored customer status. Display only; changing it is a separate admin action. */
export function CustomerStatusBadge({ status }: { status: CustomerStatus }) {
  return (
    <span className={cn(BASE, TONE[status])}>
      {CUSTOMER_STATUS_LABELS[status]}
    </span>
  );
}
