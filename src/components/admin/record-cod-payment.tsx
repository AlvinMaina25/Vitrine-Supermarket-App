import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { focusFirstInvalid } from "@/components/admin/focus-first-error";
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
import {
  COD_ALREADY_RECORDED_MESSAGE,
  COD_REASON_MAX_LENGTH,
  describeCodRecordFailure,
  describeCodRefusal,
  validateCodReason,
} from "@/features/admin/cod-payment";
import { PAYMENT_STATUS_LABELS } from "@/features/orders/status";
import { recordCodPaymentFn } from "@/features/payments/payment-server";
import { formatPrice } from "@/lib/format";
import type { AdminOrderDetail } from "@/lib/supabase/types";

const REASON_ID = "cod-reason";
const REASON_ERROR_ID = `${REASON_ID}-error`;

/**
 * "Record cash payment" for a delivered cash-on-delivery order. The parent only renders this when
 * canRecordCodPayment() is true; the database function still has the final say (admin, two-factor,
 * cash on delivery, status, already paid) and its refusal is shown in plain words. This component
 * never sets a payment status itself: it asks the server function and then re-reads the order.
 */
export function RecordCashPayment({
  order,
}: {
  order: AdminOrderDetail["order"];
}) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // A second click lands before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: (typedReason: string) =>
      recordCodPaymentFn({ data: { orderId: order.id, reason: typedReason } }),
    onSuccess: (result) => {
      if (result.kind === "refused") {
        setError(describeCodRefusal(result.reason));
        return;
      }
      if (result.changed) {
        toast.success(`Cash payment recorded for order ${order.order_number}.`);
      } else {
        toast.info(COD_ALREADY_RECORDED_MESSAGE);
      }
      close();
    },
    onError: (cause) => {
      console.error("Recording cash payment failed", cause);
      setError(
        describeCodRecordFailure(
          cause,
          typeof navigator === "undefined" ? undefined : navigator.onLine,
        ),
      );
    },
    onSettled: async () => {
      inFlight.current = false;
      // Success or refusal, the order may have changed: show what the database now says.
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ["admin", "order", order.id],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "orders"] }),
      ]);
    },
  });

  function close() {
    setOpen(false);
    setReason("");
    setFieldError(null);
    setError(null);
  }

  function confirm() {
    if (inFlight.current) return;
    const problem = validateCodReason(reason);
    if (problem !== null) {
      setFieldError(problem);
      focusFirstInvalid();
      return;
    }
    inFlight.current = true;
    setFieldError(null);
    setError(null);
    mutation.mutate(reason.trim());
  }

  const amount = formatPrice(order.total_cents);

  return (
    <>
      <p className="text-sm text-muted-foreground">
        This order was delivered, but its payment is still “
        {PAYMENT_STATUS_LABELS[order.payment_status]}”. Once the cash has been
        received, record it here.
      </p>
      <div className="mt-4">
        <Button
          variant="primary"
          disabled={mutation.isPending}
          onClick={() => setOpen(true)}
        >
          Record cash payment
        </Button>
      </div>

      <AlertDialog
        open={open}
        onOpenChange={(next) => {
          if (!next && !mutation.isPending) close();
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              Record cash payment for {order.order_number}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              This records that {amount} in cash was received for this order.
              It cannot be undone from this screen.
            </AlertDialogDescription>
          </AlertDialogHeader>

          <div className="space-y-1.5">
            <label
              htmlFor={REASON_ID}
              className="eyebrow block text-muted-foreground"
            >
              Reason (required)
            </label>
            <TextArea
              id={REASON_ID}
              rows={3}
              maxLength={COD_REASON_MAX_LENGTH}
              value={reason}
              disabled={mutation.isPending}
              aria-invalid={fieldError !== null}
              aria-describedby={
                fieldError !== null ? REASON_ERROR_ID : undefined
              }
              onChange={(event) => {
                setReason(event.target.value);
                if (fieldError !== null) setFieldError(null);
              }}
              placeholder="For example: cash handed to the driver"
            />
            <p className="text-xs text-muted-foreground">
              Saved in the audit log.
            </p>
            {fieldError !== null ? (
              <p
                id={REASON_ERROR_ID}
                role="alert"
                className="text-xs font-medium text-danger"
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
            <Button
              variant="outline"
              disabled={mutation.isPending}
              onClick={close}
            >
              Keep as is
            </Button>
            <Button
              variant="primary"
              disabled={mutation.isPending}
              onClick={confirm}
            >
              {mutation.isPending ? "Saving…" : "Record cash payment"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
