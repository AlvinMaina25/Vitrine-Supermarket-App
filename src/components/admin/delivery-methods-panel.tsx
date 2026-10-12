import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  DIALOG_ERROR,
  DeliveryTableShell,
  MoneyField,
  TextAreaField,
} from "@/components/admin/delivery-form-parts";
import { ProductActiveBadge } from "@/components/admin/product-badges";
import { EmptyState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { AdminDeliveryMethod } from "@/features/admin/delivery-config-result";
import { adminUpdateDeliveryMethod } from "@/features/admin/delivery";
import {
  buildMethodFromDraft,
  methodDraftChanged,
  methodDraftFromMethod,
  type MethodDraft,
} from "@/features/admin/delivery-management";
import { MAX_DELIVERY_REASON_LENGTH } from "@/features/admin/delivery-parse";
import { formatPrice } from "@/lib/format";
import { useDeliveryAction } from "@/hooks/use-delivery-action";

/**
 * Delivery methods (Standard, Express, Pickup...). The list shows what the database holds;
 * editing goes through admin_update_delivery_method(). Methods cannot be created or deleted
 * here: only the fee, free-over threshold, minimum order and on/off can change.
 */
export function DeliveryMethodsPanel({
  methods,
}: {
  methods: readonly AdminDeliveryMethod[];
}) {
  const [editing, setEditing] = useState<AdminDeliveryMethod | null>(null);

  if (methods.length === 0) {
    return (
      <EmptyState
        eyebrow="No methods"
        title="No delivery methods"
        message="Delivery methods are created by the database migrations. None were found."
      />
    );
  }

  return (
    <>
      <DeliveryTableShell>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Method</TableHead>
              <TableHead className="text-right">Fee</TableHead>
              <TableHead className="text-right">Free over</TableHead>
              <TableHead className="text-right">Minimum order</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {methods.map((method) => (
              <TableRow key={method.code}>
                <TableCell>
                  <div className="font-medium">{method.label}</div>
                  <div className="font-mono text-xs text-muted-foreground">
                    {method.code}
                  </div>
                </TableCell>
                <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                  {formatPrice(method.base_fee_cents)}
                </TableCell>
                <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                  {method.free_over_cents === null
                    ? "Never"
                    : formatPrice(method.free_over_cents)}
                </TableCell>
                <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                  {method.min_order_cents === 0
                    ? "None"
                    : formatPrice(method.min_order_cents)}
                </TableCell>
                <TableCell>
                  <ProductActiveBadge active={method.is_active} />
                </TableCell>
                <TableCell className="text-right">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setEditing(method)}
                  >
                    Edit
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </DeliveryTableShell>

      {editing ? (
        <MethodEditDialog method={editing} onClose={() => setEditing(null)} />
      ) : null}
    </>
  );
}

function MethodEditDialog({
  method,
  onClose,
}: {
  method: AdminDeliveryMethod;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<MethodDraft>(() =>
    methodDraftFromMethod(method),
  );
  const op = useDeliveryAction({
    action: adminUpdateDeliveryMethod,
    onDone: (result) => {
      toast.success(
        result.changed ? `${method.label} saved.` : "Nothing changed.",
      );
      onClose();
    },
  });

  const activeChanged = draft.isActive !== method.is_active;

  function update(
    patch: Partial<MethodDraft>,
    field?: keyof typeof op.fieldErrors,
  ) {
    setDraft((prev) => ({ ...prev, ...patch }));
    if (field) op.clearField(field);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const built = buildMethodFromDraft(method, draft);
    if (!built.ok) {
      op.setFieldErrors(built.errors);
      return;
    }
    op.run(built.args);
  }

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next && !op.pending) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit {method.label}</DialogTitle>
          <DialogDescription>
            <span className="font-mono">{method.code}</span> · Changes apply to
            new orders only.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4" noValidate>
          <MoneyField
            id="method-fee"
            label="Base fee"
            value={draft.baseFee}
            disabled={op.pending}
            error={op.fieldErrors.fee}
            onChange={(value) => update({ baseFee: value }, "fee")}
          />
          <MoneyField
            id="method-free-over"
            label="Free over (optional)"
            value={draft.freeOver}
            disabled={op.pending}
            error={op.fieldErrors.freeOver}
            hint="Orders at or above this amount ship free. Leave blank to never waive the fee."
            onChange={(value) => update({ freeOver: value }, "freeOver")}
          />
          <MoneyField
            id="method-min-order"
            label="Minimum order"
            value={draft.minOrder}
            disabled={op.pending}
            error={op.fieldErrors.minOrder}
            hint="Use 0 for no minimum."
            onChange={(value) => update({ minOrder: value }, "minOrder")}
          />

          <label className="flex min-h-11 items-center gap-2 text-sm">
            <input
              className="size-5"
              type="checkbox"
              checked={draft.isActive}
              disabled={op.pending}
              onChange={(event) => update({ isActive: event.target.checked })}
            />
            Available at checkout
          </label>

          {activeChanged ? (
            <TextAreaField
              id="method-reason"
              label={
                draft.isActive
                  ? "Reason for turning on (required)"
                  : "Reason for turning off (required)"
              }
              value={draft.reason}
              maxLength={MAX_DELIVERY_REASON_LENGTH}
              disabled={op.pending}
              error={op.fieldErrors.reason}
              hint="Saved in the admin audit log."
              onChange={(value) => update({ reason: value }, "reason")}
            />
          ) : null}

          {op.formMessage ? (
            <p role="alert" className={DIALOG_ERROR}>
              {op.formMessage}
            </p>
          ) : null}

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={op.pending}
              onClick={onClose}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={op.pending || !methodDraftChanged(method, draft)}
              aria-busy={op.pending}
            >
              {op.pending ? "Saving…" : "Save changes"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
