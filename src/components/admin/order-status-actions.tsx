import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

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
  describeStatusChangeError,
  getStatusOptions,
  isConsequentialStatus,
  MAX_STATUS_NOTE_LENGTH,
} from "@/features/admin/order-management";
import { adminSetOrderStatus } from "@/features/admin/orders";
import { ORDER_STATUS_LABELS } from "@/features/orders/status";
import type { AdminOrderDetail, OrderStatus } from "@/lib/supabase/types";

function consequenceText(status: OrderStatus): string | null {
  if (status === "cancelled") {
    return "Cancelling returns the order's reserved stock to inventory and releases its delivery slot. It cannot be undone from this screen.";
  }
  if (status === "delivered") {
    return "Delivered is a final status. It cannot be changed from this screen afterwards.";
  }
  return null;
}

/**
 * Status changes for one order. Every change goes through admin_set_order_status() (the Phase 6B.2
 * function), which re-checks that the caller is an admin and applies the database's own
 * transition rules. This component only offers the standard moves and reports the outcome; it
 * never writes the orders table. Overrides are not offered here.
 */
export function OrderStatusActions({ detail }: { detail: AdminOrderDetail }) {
  const queryClient = useQueryClient();
  const { order } = detail;
  const options = getStatusOptions(order);

  const [target, setTarget] = useState<OrderStatus | null>(null);
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  // A second click lands before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: adminSetOrderStatus,
    onSuccess: (result) => {
      if (result.changed) {
        toast.success(
          `Order ${result.order.order_number} is now ${ORDER_STATUS_LABELS[result.order.status]}.`,
        );
      } else {
        toast.info(
          `The order was already ${ORDER_STATUS_LABELS[result.order.status]}. Nothing changed.`,
        );
      }
      close();
    },
    onError: (cause) => {
      console.error("Order status change failed", cause);
      setError(describeStatusChangeError(cause));
    },
    onSettled: async () => {
      inFlight.current = false;
      // Success or refusal, the order may have moved: show what the database now says.
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ["admin", "order", order.id],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "orders"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
      ]);
    },
  });

  function close() {
    setTarget(null);
    setNote("");
    setError(null);
  }

  function confirm() {
    if (!target || inFlight.current) return;
    inFlight.current = true;
    setError(null);
    mutation.mutate({
      orderId: order.id,
      status: target,
      note: note.trim() || null,
    });
  }

  if (options.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No further status changes are available for an order that is{" "}
        {ORDER_STATUS_LABELS[order.status].toLowerCase()}.
      </p>
    );
  }

  const consequence = target ? consequenceText(target) : null;

  return (
    <>
      <div className="flex flex-wrap gap-2">
        {options.map((option) => (
          <Button
            key={option.status}
            variant={option.status === "cancelled" ? "danger" : "primary"}
            disabled={mutation.isPending || option.blockedReason !== null}
            title={option.blockedReason ?? undefined}
            onClick={() => {
              setError(null);
              setTarget(option.status);
            }}
          >
            {option.status === "cancelled"
              ? "Cancel order"
              : `Mark as ${ORDER_STATUS_LABELS[option.status].toLowerCase()}`}
          </Button>
        ))}
      </div>
      {options.some((o) => o.blockedReason) ? (
        <p className="mt-3 text-xs text-muted-foreground">
          Fulfilment steps are unavailable until the order is paid.
        </p>
      ) : null}

      <AlertDialog
        open={target !== null}
        onOpenChange={(open) => {
          if (!open && !mutation.isPending) close();
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {target === "cancelled"
                ? `Cancel order ${order.order_number}?`
                : `Move ${order.order_number} to ${target ? ORDER_STATUS_LABELS[target] : ""}?`}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {ORDER_STATUS_LABELS[order.status]} →{" "}
              {target ? ORDER_STATUS_LABELS[target] : ""}.
              {consequence ? ` ${consequence}` : ""}
            </AlertDialogDescription>
          </AlertDialogHeader>

          <div className="space-y-1.5">
            <label
              htmlFor="status-note"
              className="eyebrow block text-muted-foreground"
            >
              {target === "cancelled" ? "Reason (optional)" : "Note (optional)"}
            </label>
            <TextArea
              id="status-note"
              rows={3}
              maxLength={MAX_STATUS_NOTE_LENGTH}
              value={note}
              disabled={mutation.isPending}
              onChange={(event) => setNote(event.target.value)}
              placeholder="Saved in the order's status history"
            />
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
              variant={target === "cancelled" ? "danger" : "primary"}
              disabled={mutation.isPending}
              onClick={confirm}
            >
              {mutation.isPending
                ? "Saving…"
                : target === "cancelled"
                  ? "Cancel order"
                  : "Confirm"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
