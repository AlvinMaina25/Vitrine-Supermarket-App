import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  DIALOG_ERROR,
  DeliveryReasonDialog,
  DeliveryTableShell,
  TextAreaField,
  TextField,
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
import type { AdminDeliveryZone } from "@/features/admin/delivery-config-result";
import {
  adminSaveDeliveryZone,
  adminSetDeliveryZoneActive,
} from "@/features/admin/delivery";
import {
  buildZoneFromDraft,
  emptyZoneDraft,
  zoneDraftFromZone,
  type ZoneDraft,
} from "@/features/admin/delivery-management";
import {
  MAX_COUNTY_LENGTH,
  MAX_ZONE_DESCRIPTION_LENGTH,
  MAX_ZONE_NAME_LENGTH,
} from "@/features/admin/delivery-parse";
import { buildSetDeliveryZoneActiveArgs } from "@/features/admin/delivery-zone-result";
import { useDeliveryAction } from "@/hooks/use-delivery-action";

type ZoneDialog =
  | { kind: "form"; zone: AdminDeliveryZone | null }
  | { kind: "toggle"; zone: AdminDeliveryZone };

/** Towns for the list: the first few, then a count. */
function townsSummary(towns: readonly string[]): string {
  if (towns.length === 0) return "—";
  const shown = towns.slice(0, 3).join(", ");
  return towns.length > 3 ? `${shown} +${towns.length - 3} more` : shown;
}

/**
 * Delivery zones: create, edit, and turn on or off with a reason. Nothing is deleted; a turned-off
 * zone stops taking new orders and its fee rules stay on file.
 */
export function DeliveryZonesPanel({
  zones,
}: {
  zones: readonly AdminDeliveryZone[];
}) {
  const [dialog, setDialog] = useState<ZoneDialog | null>(null);
  const close = () => setDialog(null);

  return (
    <>
      <div className="mb-3 flex justify-end">
        <Button onClick={() => setDialog({ kind: "form", zone: null })}>
          New zone
        </Button>
      </div>

      {zones.length === 0 ? (
        <EmptyState
          eyebrow="No zones"
          title="No delivery zones yet"
          message="Create a zone for each area you deliver to, then give it a fee on the Fees tab."
          action={
            <Button onClick={() => setDialog({ kind: "form", zone: null })}>
              New zone
            </Button>
          }
        />
      ) : (
        <DeliveryTableShell>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Zone</TableHead>
                <TableHead>County</TableHead>
                <TableHead>Towns</TableHead>
                <TableHead className="text-right">Position</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {zones.map((zone) => (
                <TableRow key={zone.id}>
                  <TableCell>
                    <div className="font-medium">{zone.name}</div>
                    <div className="font-mono text-xs text-muted-foreground">
                      {zone.code}
                    </div>
                  </TableCell>
                  <TableCell className="text-sm">
                    {zone.county ?? "—"}
                  </TableCell>
                  <TableCell className="max-w-[28ch] text-sm">
                    {townsSummary(zone.towns)}
                  </TableCell>
                  <TableCell className="text-right font-mono text-sm">
                    {zone.position}
                  </TableCell>
                  <TableCell>
                    <ProductActiveBadge active={zone.is_active} />
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => setDialog({ kind: "form", zone })}
                      >
                        Edit
                      </Button>
                      <Button
                        variant={zone.is_active ? "danger" : "primary"}
                        size="sm"
                        onClick={() => setDialog({ kind: "toggle", zone })}
                      >
                        {zone.is_active ? "Deactivate" : "Activate"}
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
        <ZoneFormDialog zone={dialog.zone} onClose={close} />
      ) : null}
      {dialog?.kind === "toggle" ? (
        <DeliveryReasonDialog
          title={
            dialog.zone.is_active
              ? "Deactivate this zone?"
              : "Activate this zone?"
          }
          description={
            dialog.zone.is_active
              ? `${dialog.zone.name} will stop taking new address orders. Existing orders are not affected. The reason is saved in the admin audit log.`
              : `${dialog.zone.name} will take address orders again. The reason is saved in the admin audit log.`
          }
          confirmLabel={
            dialog.zone.is_active ? "Deactivate zone" : "Activate zone"
          }
          danger={dialog.zone.is_active}
          successMessage={
            dialog.zone.is_active ? "Zone deactivated." : "Zone activated."
          }
          buildArgs={(reason) =>
            buildSetDeliveryZoneActiveArgs(
              dialog.zone.id,
              !dialog.zone.is_active,
              reason,
            )
          }
          action={adminSetDeliveryZoneActive}
          onClose={close}
        />
      ) : null}
    </>
  );
}

function ZoneFormDialog({
  zone,
  onClose,
}: {
  zone: AdminDeliveryZone | null;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<ZoneDraft>(() =>
    zone ? zoneDraftFromZone(zone) : emptyZoneDraft(),
  );
  const op = useDeliveryAction({
    action: adminSaveDeliveryZone,
    onDone: (result) => {
      toast.success(
        result.created
          ? "Zone created."
          : result.changed
            ? "Zone saved."
            : "Nothing changed.",
      );
      onClose();
    },
  });

  function update(
    patch: Partial<ZoneDraft>,
    field: keyof typeof op.fieldErrors,
  ) {
    setDraft((prev) => ({ ...prev, ...patch }));
    op.clearField(field);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const built = buildZoneFromDraft(zone?.id ?? null, draft);
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
            {zone ? `Edit ${zone.name}` : "New delivery zone"}
          </DialogTitle>
          <DialogDescription>
            {zone
              ? "The code is fixed once a zone is created."
              : "Customers choose a zone by its towns, so list every town you cover."}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4" noValidate>
          <TextField
            id="zone-code"
            label="Code"
            value={draft.code}
            disabled={op.pending || zone !== null}
            error={op.fieldErrors.code}
            hint="Lowercase letters, digits, - or _, starting with a letter. For example nairobi-cbd."
            onChange={(value) => update({ code: value }, "code")}
          />
          <TextField
            id="zone-name"
            label="Name"
            value={draft.name}
            maxLength={MAX_ZONE_NAME_LENGTH}
            disabled={op.pending}
            error={op.fieldErrors.name}
            onChange={(value) => update({ name: value }, "name")}
          />
          <TextField
            id="zone-county"
            label="County (optional)"
            value={draft.county}
            maxLength={MAX_COUNTY_LENGTH}
            disabled={op.pending}
            error={op.fieldErrors.county}
            onChange={(value) => update({ county: value }, "county")}
          />
          <TextAreaField
            id="zone-description"
            label="Description (optional)"
            value={draft.description}
            maxLength={MAX_ZONE_DESCRIPTION_LENGTH}
            disabled={op.pending}
            error={op.fieldErrors.description}
            onChange={(value) => update({ description: value }, "description")}
          />
          <TextAreaField
            id="zone-towns"
            label="Towns (optional)"
            value={draft.towns}
            rows={4}
            disabled={op.pending}
            error={op.fieldErrors.towns}
            hint="One town per line, or separated by commas."
            onChange={(value) => update({ towns: value }, "towns")}
          />
          <TextField
            id="zone-position"
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
              {op.pending ? "Saving…" : zone ? "Save zone" : "Create zone"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
