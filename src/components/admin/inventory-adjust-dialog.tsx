import { useMutation, useQueryClient } from "@tanstack/react-query";
import { focusFirstError } from "@/components/admin/focus-first-error";
import { useRef, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui-kit/button";
import { Field, TextArea, TextInput } from "@/components/ui-kit/field";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { adminAdjustInventory } from "@/features/admin/inventory";
import {
  adjustmentErrorField,
  describeAdjustmentError,
} from "@/features/admin/inventory-management";
import {
  buildAdjustmentArgs,
  emptyAdjustmentValues,
  formatDelta,
  MAX_NOTE_LENGTH,
  MAX_REASON_LENGTH,
  parseAdjustmentQuantity,
  projectStock,
  type AdjustmentFormErrors,
  type AdjustmentFormValues,
} from "@/features/admin/inventory-result";
import type { AdminInventoryRow } from "@/lib/supabase/types";

const ERROR_BOX =
  "rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger";

/** What the unit is called on screen: "Milk", or "Milk — 500 ml". */
function inventoryUnitLabel(
  unit: Pick<AdminInventoryRow, "product_name" | "variant_name">,
) {
  return unit.variant_name
    ? `${unit.product_name} — ${unit.variant_name}`
    : unit.product_name;
}

/**
 * Adjusts one stock unit through admin_adjust_inventory(): the admin enters a signed change (not a
 * final quantity), a reason and an optional note, reviews it, and confirms. The database locks the
 * row, computes the new quantity from the CURRENT stock, refuses a result below zero and records
 * the history row in the same transaction. The browser never writes stock.
 *
 * `unit` is the row as the list last loaded it. It is refreshed after the call settles (success or
 * refusal), so the "current stock" shown is what the database held at the last refresh, not a
 * promise about the moment of confirmation. The preview of the new quantity is an estimate; the
 * success message reports what the database actually stored.
 *
 * Duplicate submissions: the confirm button is disabled and a ref blocks a second call before React
 * re-renders; the dialog cannot be dismissed while the call is in flight. This only prevents
 * accidental double clicks. Concurrency (two admins, two tabs) is the database's row lock.
 */
export function InventoryAdjustDialog({
  unit,
  onClose,
}: {
  unit: AdminInventoryRow;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [values, setValues] = useState<AdjustmentFormValues>(
    emptyAdjustmentValues,
  );
  const [errors, setErrors] = useState<AdjustmentFormErrors>({});
  const [step, setStep] = useState<"form" | "review">("form");
  const [serverError, setServerError] = useState<string | null>(null);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const label = inventoryUnitLabel(unit);

  const mutation = useMutation({
    mutationFn: adminAdjustInventory,
    onSuccess: (result) => {
      toast.success(
        `Stock for “${label}” changed from ${result.previous_quantity} to ${result.new_quantity} (${formatDelta(result.adjustment_quantity)}).`,
      );
      onClose();
    },
    onError: (cause) => {
      console.error("Inventory adjustment failed", cause);
      setServerError(describeAdjustmentError(cause));
      const field = adjustmentErrorField(cause);
      if (field) {
        // The database named the field: send the admin back to it.
        const next: AdjustmentFormErrors = {};
        next[field] = describeAdjustmentError(cause);
        setErrors(next);
        setStep("form");
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      // Success or refusal, show what the database now holds.
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["admin", "inventory"] }),
        queryClient.invalidateQueries({
          queryKey: ["admin", "product", unit.product_id],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "products"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
        // The storefront reads the same stock; keep any cached copy honest.
        queryClient.invalidateQueries({ queryKey: ["products"] }),
        queryClient.invalidateQueries({ queryKey: ["product"] }),
      ]);
    },
  });

  const pending = mutation.isPending;

  const quantity = parseAdjustmentQuantity(values.quantity);
  const projected = quantity.ok
    ? projectStock(unit.stock_quantity, quantity.value)
    : null;

  function update(key: keyof AdjustmentFormValues, value: string) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => {
      const { [key]: _cleared, ...rest } = prev;
      return rest;
    });
    setServerError(null);
  }

  function review(event: FormEvent) {
    event.preventDefault();
    if (pending) return;
    const built = buildAdjustmentArgs(unit, values);
    if (!built.ok) {
      setErrors(built.errors);
      focusFirstError(
        built.errors,
        ["quantity", "reason", "note"] as const,
        (key) => `adjust-${key}`,
      );
      return;
    }
    setErrors({});
    setServerError(null);
    setStep("review");
  }

  function confirm() {
    if (inFlight.current || pending) return;
    const built = buildAdjustmentArgs(unit, values);
    if (!built.ok) {
      setErrors(built.errors);
      setStep("form");
      return;
    }
    inFlight.current = true;
    setServerError(null);
    mutation.mutate(built.args);
  }

  const built = buildAdjustmentArgs(unit, values);

  return (
    <Dialog
      open
      // The dialog cannot be dismissed while the adjustment is being applied.
      onOpenChange={(next) => {
        if (!next && !pending) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {step === "form" ? "Adjust stock" : "Confirm adjustment"}
          </DialogTitle>
          <DialogDescription>
            {label}
            {unit.sku ? ` · SKU ${unit.sku}` : ""}
          </DialogDescription>
        </DialogHeader>

        <div className="rounded-lg border border-border bg-surface-strong px-3 py-2 text-sm">
          <span className="text-muted-foreground">Current stock: </span>
          <span className="font-mono font-medium">{unit.stock_quantity}</span>
          <span className="text-muted-foreground">
            {unit.kind === "variant"
              ? " (this variant)"
              : unit.variant_count
                ? " (the product's own stock, not its variants)"
                : ""}
          </span>
        </div>

        {step === "form" ? (
          <form onSubmit={review} className="space-y-4" noValidate>
            <Field
              label="Change"
              htmlFor="adjust-quantity"
              hint="Use + to add stock and - to remove it, e.g. 24 or -3."
            >
              <TextInput
                id="adjust-quantity"
                inputMode="numeric"
                autoComplete="off"
                value={values.quantity}
                aria-invalid={errors.quantity ? true : undefined}
                aria-describedby={
                  errors.quantity ? "adjust-quantity-error" : undefined
                }
                disabled={pending}
                onChange={(event) => update("quantity", event.target.value)}
              />
              {errors.quantity ? (
                <p
                  id="adjust-quantity-error"
                  role="alert"
                  className="text-xs text-danger"
                >
                  {errors.quantity}
                </p>
              ) : projected !== null ? (
                <p className="text-xs text-muted-foreground">
                  Stock would become about{" "}
                  <span className="font-mono">{projected}</span>.
                  {projected < 0 ? (
                    <span className="text-danger">
                      {" "}
                      That is below zero and will be refused.
                    </span>
                  ) : null}
                </p>
              ) : null}
            </Field>

            <Field
              label="Reason"
              htmlFor="adjust-reason"
              hint="Required. Shown in the history."
            >
              <TextInput
                id="adjust-reason"
                maxLength={MAX_REASON_LENGTH}
                autoComplete="off"
                value={values.reason}
                aria-invalid={errors.reason ? true : undefined}
                aria-describedby={
                  errors.reason ? "adjust-reason-error" : undefined
                }
                disabled={pending}
                onChange={(event) => update("reason", event.target.value)}
              />
              {errors.reason ? (
                <p
                  id="adjust-reason-error"
                  role="alert"
                  className="text-xs text-danger"
                >
                  {errors.reason}
                </p>
              ) : null}
            </Field>

            <Field label="Note (optional)" htmlFor="adjust-note">
              <TextArea
                id="adjust-note"
                rows={3}
                maxLength={MAX_NOTE_LENGTH}
                value={values.note}
                aria-invalid={errors.note ? true : undefined}
                aria-describedby={errors.note ? "adjust-note-error" : undefined}
                disabled={pending}
                onChange={(event) => update("note", event.target.value)}
              />
              {errors.note ? (
                <p
                  id="adjust-note-error"
                  role="alert"
                  className="text-xs text-danger"
                >
                  {errors.note}
                </p>
              ) : null}
            </Field>

            {serverError &&
            !errors.quantity &&
            !errors.reason &&
            !errors.note ? (
              <p role="alert" className={ERROR_BOX}>
                {serverError}
              </p>
            ) : null}

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={pending}
                onClick={onClose}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={pending}>
                Review adjustment
              </Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-4">
            <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
              <dt className="text-muted-foreground">Change</dt>
              <dd className="font-mono font-medium">
                {built.ok ? formatDelta(built.delta) : "—"}
              </dd>
              <dt className="text-muted-foreground">Stock</dt>
              <dd className="font-mono">
                {unit.stock_quantity} → {projected ?? "—"}{" "}
                <span className="font-sans text-xs text-muted-foreground">
                  (estimate)
                </span>
              </dd>
              <dt className="text-muted-foreground">Reason</dt>
              <dd>{values.reason.trim()}</dd>
              {values.note.trim() ? (
                <>
                  <dt className="text-muted-foreground">Note</dt>
                  <dd className="whitespace-pre-wrap">{values.note.trim()}</dd>
                </>
              ) : null}
            </dl>
            <p className="text-xs text-muted-foreground">
              The database applies this change to the stock it holds at the
              moment you confirm, and records it in the history. It can be
              corrected later only with another adjustment.
            </p>

            {serverError ? (
              <p role="alert" className={ERROR_BOX}>
                {serverError}
              </p>
            ) : null}

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={pending}
                onClick={() => {
                  setServerError(null);
                  setStep("form");
                }}
              >
                Back
              </Button>
              <Button
                type="button"
                disabled={pending}
                aria-busy={pending}
                onClick={confirm}
              >
                {pending ? "Applying…" : "Confirm adjustment"}
              </Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
