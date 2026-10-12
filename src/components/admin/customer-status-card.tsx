import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { CustomerStatusBadge } from "@/components/admin/customer-status-badge";
import { Button } from "@/components/ui-kit/button";
import { TextArea } from "@/components/ui-kit/field";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { adminSetCustomerStatus } from "@/features/admin/customers";
import {
  describeStatusChangeError,
  oppositeStatus,
  statusActionLabel,
  statusConfirmLabel,
} from "@/features/admin/customer-detail-management";
import {
  buildSetCustomerStatusArgs,
  MAX_STATUS_REASON_LENGTH,
} from "@/features/admin/customer-status-result";
import type { CustomerStatus } from "@/features/admin/customers-result";

/**
 * Suspends or reactivates one customer through admin_set_customer_status(). A reason is required
 * and is recorded in the admin audit log by the database. The database refuses the admin's own
 * account and staff accounts; this component only reports the outcome and never writes a table.
 *
 * `status` is what the page last loaded. It is refreshed after the call settles (success or
 * refusal), so what is shown is always the database's answer, not this component's guess.
 *
 * Duplicate submissions: the confirm button is disabled and a ref blocks a second call before
 * React re-renders; the dialog cannot be dismissed while the call is in flight.
 */
export function CustomerStatusCard({
  customerId,
  status,
}: {
  customerId: string;
  status: CustomerStatus;
}) {
  const queryClient = useQueryClient();
  const target = oppositeStatus(status);

  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // A second click lands before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: adminSetCustomerStatus,
    onSuccess: (result) => {
      toast.success(
        result.status === "suspended"
          ? "Customer suspended."
          : "Customer reactivated.",
      );
      close();
    },
    onError: (cause) => {
      console.error("Customer status change failed", cause);
      setError(describeStatusChangeError(cause));
    },
    onSettled: async () => {
      inFlight.current = false;
      // Success or refusal, the status may have moved: show what the database now says.
      await queryClient.invalidateQueries({ queryKey: ["admin", "customers"] });
    },
  });

  const pending = mutation.isPending;

  function close() {
    setOpen(false);
    setReason("");
    setFieldError(null);
    setError(null);
  }

  function confirm() {
    if (inFlight.current || pending) return;
    const built = buildSetCustomerStatusArgs(customerId, target, reason);
    if (!built.ok) {
      setFieldError(built.errors.reason ?? null);
      return;
    }
    inFlight.current = true;
    setFieldError(null);
    setError(null);
    mutation.mutate(built.args);
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-3">
        <CustomerStatusBadge status={status} />
        <Button
          variant={target === "suspended" ? "danger" : "primary"}
          disabled={pending}
          onClick={() => {
            setError(null);
            setFieldError(null);
            setOpen(true);
          }}
        >
          {statusActionLabel(target)}
        </Button>
      </div>

      <AlertDialog
        open={open}
        onOpenChange={(next) => {
          if (!next && !pending) close();
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {target === "suspended"
                ? "Suspend this customer?"
                : "Reactivate this customer?"}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {status === "active" ? "Active" : "Suspended"} →{" "}
              {target === "active" ? "Active" : "Suspended"}. The reason is
              saved in the admin audit log.
            </AlertDialogDescription>
          </AlertDialogHeader>

          <div className="space-y-1.5">
            <label
              htmlFor="customer-status-reason"
              className="eyebrow block text-muted-foreground"
            >
              Reason (required)
            </label>
            <TextArea
              id="customer-status-reason"
              rows={3}
              maxLength={MAX_STATUS_REASON_LENGTH}
              value={reason}
              disabled={pending}
              aria-invalid={fieldError ? true : undefined}
              aria-describedby={
                fieldError ? "customer-status-reason-error" : undefined
              }
              onChange={(event) => {
                setReason(event.target.value);
                setFieldError(null);
                setError(null);
              }}
            />
            {fieldError ? (
              <p
                id="customer-status-reason-error"
                role="alert"
                className="text-xs text-danger"
              >
                {fieldError}
              </p>
            ) : null}
          </div>

          {error ? (
            <p
              role="alert"
              className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
            >
              {error}
            </p>
          ) : null}

          <AlertDialogFooter>
            <Button variant="outline" disabled={pending} onClick={close}>
              Cancel
            </Button>
            <Button
              variant={target === "suspended" ? "danger" : "primary"}
              disabled={pending}
              aria-busy={pending}
              onClick={confirm}
            >
              {pending ? "Saving…" : statusConfirmLabel(target)}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
