import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  DIALOG_ERROR,
  DeliveryWarning,
  TextAreaField,
  TextField,
} from "@/components/admin/delivery-form-parts";
import { Button } from "@/components/ui-kit/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { adminSaveDeliverySlotOverride } from "@/features/admin/delivery";
import {
  buildSlotOverrideFromDraft,
  parseCapacityText,
  slotOverrideDraftFor,
  formatTimeHm,
  type SlotOverrideDraft,
} from "@/features/admin/delivery-management";
import { MAX_OVERRIDE_NOTE_LENGTH } from "@/features/admin/delivery-parse";
import type {
  AdminDeliverySlot,
  AdminDeliverySlotOverride,
} from "@/features/admin/delivery-slots-result";
import { capacityBelowBookedWarning } from "@/features/admin/delivery-slots-view";
import { formatCalendarDate } from "@/lib/format";
import { useDeliveryAction } from "@/hooks/use-delivery-action";

/**
 * Capacity or closure of one slot on one date. Shows how many orders hold it. The database
 * refuses a capacity below that number (closing is always allowed); the warning here is an early
 * explanation only.
 */
export function DeliverySlotOverrideDialog({
  slot,
  overrides,
  onClose,
}: {
  slot: AdminDeliverySlot;
  overrides: readonly AdminDeliverySlotOverride[];
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<SlotOverrideDraft>(() =>
    slotOverrideDraftFor(slot, overrides),
  );
  const op = useDeliveryAction({
    action: adminSaveDeliverySlotOverride,
    onDone: (result) => {
      toast.success(
        result.changed ? "Date override saved." : "Nothing changed.",
      );
      onClose();
    },
  });

  const parsed = parseCapacityText(draft.capacity);
  const warning = capacityBelowBookedWarning(
    parsed.ok ? parsed.value : null,
    draft.closed,
    slot.booked_count,
  );

  function update(
    patch: Partial<SlotOverrideDraft>,
    field: keyof typeof op.fieldErrors,
  ) {
    setDraft((prev) => ({ ...prev, ...patch }));
    op.clearField(field);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const built = buildSlotOverrideFromDraft(
      slot.template_id,
      slot.slot_date,
      draft,
    );
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
          <DialogTitle>
            {slot.label} · {formatCalendarDate(slot.slot_date)}
          </DialogTitle>
          <DialogDescription>
            {formatTimeHm(slot.start_time)} – {formatTimeHm(slot.end_time)}.{" "}
            {slot.booked_count === 0
              ? "No orders hold this slot on this date."
              : `${slot.booked_count} order${slot.booked_count === 1 ? "" : "s"} hold this slot on this date. Closing it stops new orders only; those orders keep their slot.`}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4" noValidate>
          <TextField
            id="override-capacity"
            label="Capacity for this date (optional)"
            value={draft.capacity}
            inputMode="numeric"
            disabled={op.pending || draft.closed}
            error={op.fieldErrors.capacity}
            hint={`Blank uses the slot's usual capacity. It cannot be below ${slot.booked_count} (the orders already booked).`}
            onChange={(value) => update({ capacity: value }, "capacity")}
          />

          <label className="flex items-center gap-2 text-sm">
            <Checkbox
              checked={draft.closed}
              disabled={op.pending}
              onCheckedChange={(checked) =>
                update(
                  checked === true
                    ? { closed: true, capacity: "" }
                    : { closed: false },
                  "capacity",
                )
              }
            />
            Close this slot on this date
          </label>

          <TextAreaField
            id="override-note"
            label="Note (optional)"
            value={draft.note}
            maxLength={MAX_OVERRIDE_NOTE_LENGTH}
            disabled={op.pending}
            error={op.fieldErrors.note}
            onChange={(value) => update({ note: value }, "note")}
          />

          {warning ? (
            <DeliveryWarning title="Capacity too low" message={warning} />
          ) : null}

          {op.fieldErrors.date ? (
            <p role="alert" className={DIALOG_ERROR}>
              {op.fieldErrors.date}
            </p>
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
            <Button type="submit" disabled={op.pending} aria-busy={op.pending}>
              {op.pending ? "Saving…" : "Save override"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
