import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  DIALOG_ERROR,
  DeliveryReasonDialog,
  DeliveryTableShell,
  FieldError,
  SELECT_CLASS,
  TextField,
} from "@/components/admin/delivery-form-parts";
import { ProductActiveBadge } from "@/components/admin/product-badges";
import { EmptyState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { Field } from "@/components/ui-kit/field";
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
import {
  adminSaveDeliverySlotTemplate,
  adminSetDeliverySlotTemplateActive,
} from "@/features/admin/delivery";
import {
  WEEKDAY_LABELS,
  buildSlotTemplateFromDraft,
  describeSlotCapacity,
  emptySlotTemplateDraft,
  formatTimeHm,
  slotTemplateDraftFromTemplate,
  weekdayLabel,
  type SlotTemplateDraft,
} from "@/features/admin/delivery-management";
import { MAX_SLOT_LABEL_LENGTH } from "@/features/admin/delivery-parse";
import { buildSetDeliverySlotTemplateActiveArgs } from "@/features/admin/delivery-slot-template-result";
import type { AdminDeliverySlotTemplate } from "@/features/admin/delivery-slots-result";
import { useDeliveryAction } from "@/hooks/use-delivery-action";

type TemplateDialog =
  | { kind: "form"; template: AdminDeliverySlotTemplate | null }
  | { kind: "toggle"; template: AdminDeliverySlotTemplate };

/**
 * Slot templates: create, edit, and turn on or off with a reason. Nothing is deleted. Orders that
 * already hold a window keep it; the database blocks time or weekday changes while they do.
 */
export function DeliverySlotTemplates({
  templates,
}: {
  templates: readonly AdminDeliverySlotTemplate[];
}) {
  const [dialog, setDialog] = useState<TemplateDialog | null>(null);
  const close = () => setDialog(null);
  const create = () => setDialog({ kind: "form", template: null });

  return (
    <section aria-labelledby="slot-templates-heading" className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <h3
          id="slot-templates-heading"
          className="font-display text-lg font-semibold"
        >
          Slot windows
        </h3>
        <Button onClick={create}>New slot</Button>
      </div>

      {templates.length === 0 ? (
        <EmptyState
          eyebrow="No slots"
          title="No delivery slots yet"
          message="Create a time window customers can pick at checkout, such as 08:00 – 11:00."
          action={<Button onClick={create}>New slot</Button>}
        />
      ) : (
        <DeliveryTableShell>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Slot</TableHead>
                <TableHead>Window</TableHead>
                <TableHead>Day</TableHead>
                <TableHead className="text-right">Capacity</TableHead>
                <TableHead className="text-right">Position</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {templates.map((template) => (
                <TableRow key={template.id}>
                  <TableCell className="font-medium">
                    {template.label}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {formatTimeHm(template.start_time)} –{" "}
                    {formatTimeHm(template.end_time)}
                  </TableCell>
                  <TableCell className="text-sm">
                    {weekdayLabel(template.day_of_week)}
                  </TableCell>
                  <TableCell className="text-right font-mono text-sm">
                    {describeSlotCapacity(template.capacity)}
                  </TableCell>
                  <TableCell className="text-right font-mono text-sm">
                    {template.position}
                  </TableCell>
                  <TableCell>
                    <ProductActiveBadge active={template.is_active} />
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => setDialog({ kind: "form", template })}
                      >
                        Edit
                      </Button>
                      <Button
                        variant={template.is_active ? "danger" : "primary"}
                        size="sm"
                        onClick={() => setDialog({ kind: "toggle", template })}
                      >
                        {template.is_active ? "Deactivate" : "Activate"}
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </DeliveryTableShell>
      )}

      {dialog?.kind === "form" ? (
        <TemplateFormDialog template={dialog.template} onClose={close} />
      ) : null}
      {dialog?.kind === "toggle" ? (
        <DeliveryReasonDialog
          title={
            dialog.template.is_active
              ? "Deactivate this slot?"
              : "Activate this slot?"
          }
          description={
            dialog.template.is_active
              ? `${dialog.template.label} will stop being offered at checkout. Orders that already hold it keep their slot. The reason is saved in the admin audit log.`
              : `${dialog.template.label} will be offered at checkout again. The reason is saved in the admin audit log.`
          }
          confirmLabel={
            dialog.template.is_active ? "Deactivate slot" : "Activate slot"
          }
          danger={dialog.template.is_active}
          successMessage={
            dialog.template.is_active ? "Slot deactivated." : "Slot activated."
          }
          buildArgs={(reason) =>
            buildSetDeliverySlotTemplateActiveArgs(
              dialog.template.id,
              !dialog.template.is_active,
              reason,
            )
          }
          action={adminSetDeliverySlotTemplateActive}
          onClose={close}
        />
      ) : null}
    </section>
  );
}

function TemplateFormDialog({
  template,
  onClose,
}: {
  template: AdminDeliverySlotTemplate | null;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<SlotTemplateDraft>(() =>
    template
      ? slotTemplateDraftFromTemplate(template)
      : emptySlotTemplateDraft(),
  );
  const op = useDeliveryAction({
    action: adminSaveDeliverySlotTemplate,
    onDone: (result) => {
      toast.success(
        result.created
          ? "Slot created."
          : result.changed
            ? "Slot saved."
            : "Nothing changed.",
      );
      onClose();
    },
  });

  function update(
    patch: Partial<SlotTemplateDraft>,
    field: keyof typeof op.fieldErrors,
  ) {
    setDraft((prev) => ({ ...prev, ...patch }));
    op.clearField(field);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const built = buildSlotTemplateFromDraft(template?.id ?? null, draft);
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
            {template ? `Edit ${template.label}` : "New delivery slot"}
          </DialogTitle>
          <DialogDescription>
            {template
              ? "The times and weekday cannot change while upcoming orders hold this slot. Deactivate it and create a new one instead."
              : "Times are 24-hour, for example 08:00 to 11:00."}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4" noValidate>
          <TextField
            id="slot-label"
            label="Label"
            value={draft.label}
            maxLength={MAX_SLOT_LABEL_LENGTH}
            disabled={op.pending}
            error={op.fieldErrors.label}
            onChange={(value) => update({ label: value }, "label")}
          />
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <TextField
              id="slot-start"
              label="Start time"
              value={draft.startTime}
              disabled={op.pending}
              error={undefined}
              hint="For example 08:00."
              onChange={(value) => update({ startTime: value }, "window")}
            />
            <TextField
              id="slot-end"
              label="End time"
              value={draft.endTime}
              disabled={op.pending}
              error={undefined}
              hint="For example 11:00."
              onChange={(value) => update({ endTime: value }, "window")}
            />
          </div>
          <FieldError id="slot-window-error" message={op.fieldErrors.window} />
          <Field label="Weekday" htmlFor="slot-weekday">
            <select
              id="slot-weekday"
              className={SELECT_CLASS}
              value={draft.dayOfWeek}
              disabled={op.pending}
              onChange={(event) =>
                update({ dayOfWeek: event.target.value }, "weekday")
              }
            >
              <option value="">Every day</option>
              {WEEKDAY_LABELS.map((name, index) => (
                <option key={name} value={String(index)}>
                  {name}
                </option>
              ))}
            </select>
            <FieldError
              id="slot-weekday-error"
              message={op.fieldErrors.weekday}
            />
          </Field>
          <TextField
            id="slot-capacity"
            label="Capacity per date (optional)"
            value={draft.capacity}
            inputMode="numeric"
            disabled={op.pending}
            error={op.fieldErrors.capacity}
            hint="Orders per date. Leave blank for unlimited; 0 closes the slot."
            onChange={(value) => update({ capacity: value }, "capacity")}
          />
          <TextField
            id="slot-position"
            label="Position (optional)"
            value={draft.position}
            inputMode="numeric"
            disabled={op.pending}
            error={op.fieldErrors.position}
            hint="Lower numbers are listed first."
            onChange={(value) => update({ position: value }, "position")}
          />

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
              {op.pending ? "Saving…" : template ? "Save slot" : "Create slot"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
