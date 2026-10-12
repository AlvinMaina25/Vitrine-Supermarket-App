import { useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  DIALOG_ERROR,
  DeliveryReasonDialog,
  DeliveryTableShell,
  FieldError,
  MoneyField,
  SELECT_CLASS,
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
import type {
  AdminDeliveryMethod,
  AdminDeliveryZone,
  AdminDeliveryZoneFee,
} from "@/features/admin/delivery-config-result";
import {
  adminSaveDeliveryZoneFee,
  adminSetDeliveryZoneFeeActive,
} from "@/features/admin/delivery";
import {
  buildZoneFeeFromDraft,
  emptyZoneFeeDraft,
  zoneFeeDraftFromFee,
  type ZoneFeeDraft,
} from "@/features/admin/delivery-management";
import { buildSetDeliveryZoneFeeActiveArgs } from "@/features/admin/delivery-zone-fee-result";
import { formatPrice } from "@/lib/format";
import { useDeliveryAction } from "@/hooks/use-delivery-action";

type FeeDialog =
  | { kind: "form"; fee: AdminDeliveryZoneFee | null }
  | { kind: "toggle"; fee: AdminDeliveryZoneFee };

/**
 * Fee rules: what each zone charges for each delivery method. A rule is created for a zone and
 * method pair once; after that only its amounts and on/off can change. Turning a rule off needs
 * a reason. Nothing is deleted.
 */
export function DeliveryFeesPanel({
  fees,
  zones,
  methods,
}: {
  fees: readonly AdminDeliveryZoneFee[];
  zones: readonly AdminDeliveryZone[];
  methods: readonly AdminDeliveryMethod[];
}) {
  const [dialog, setDialog] = useState<FeeDialog | null>(null);
  const close = () => setDialog(null);
  const canCreate = zones.length > 0 && methods.length > 0;
  const zoneActive = new Map(zones.map((zone) => [zone.id, zone.is_active]));

  const newButton = (
    <Button
      disabled={!canCreate}
      onClick={() => setDialog({ kind: "form", fee: null })}
    >
      New fee rule
    </Button>
  );

  return (
    <>
      <div className="mb-3 flex flex-wrap items-center justify-end gap-3">
        {!canCreate ? (
          <p className="text-sm text-muted-foreground">
            Create a zone before adding fee rules.
          </p>
        ) : null}
        {newButton}
      </div>

      {fees.length === 0 ? (
        <EmptyState
          eyebrow="No fee rules"
          title="No zone fee rules yet"
          message="A zone needs a fee rule for a delivery method before customers can choose it there."
        />
      ) : (
        <DeliveryTableShell>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Zone</TableHead>
                <TableHead>Method</TableHead>
                <TableHead className="text-right">Fee</TableHead>
                <TableHead className="text-right">Free over</TableHead>
                <TableHead className="text-right">Minimum order</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {fees.map((fee) => (
                <TableRow key={fee.id}>
                  <TableCell>
                    <div className="font-medium">{fee.zone_name}</div>
                    {zoneActive.get(fee.zone_id) === false ? (
                      <div className="text-xs text-muted-foreground">
                        Zone is inactive
                      </div>
                    ) : null}
                  </TableCell>
                  <TableCell className="text-sm">{fee.method_label}</TableCell>
                  <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                    {formatPrice(fee.fee_cents)}
                  </TableCell>
                  <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                    {fee.free_over_cents === null
                      ? "Never"
                      : formatPrice(fee.free_over_cents)}
                  </TableCell>
                  <TableCell className="text-right font-mono text-sm whitespace-nowrap">
                    {fee.min_order_cents === 0
                      ? "Method's"
                      : formatPrice(fee.min_order_cents)}
                  </TableCell>
                  <TableCell>
                    <ProductActiveBadge active={fee.is_active} />
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => setDialog({ kind: "form", fee })}
                      >
                        Edit
                      </Button>
                      <Button
                        variant={fee.is_active ? "danger" : "primary"}
                        size="sm"
                        onClick={() => setDialog({ kind: "toggle", fee })}
                      >
                        {fee.is_active ? "Turn off" : "Turn on"}
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
        <FeeFormDialog
          fee={dialog.fee}
          zones={zones}
          methods={methods}
          onClose={close}
        />
      ) : null}
      {dialog?.kind === "toggle" ? (
        <DeliveryReasonDialog
          title={
            dialog.fee.is_active
              ? "Turn this fee rule off?"
              : "Turn this fee rule on?"
          }
          description={`${dialog.fee.zone_name} · ${dialog.fee.method_label}. ${
            dialog.fee.is_active
              ? "Customers will no longer be able to choose this method in this zone."
              : "Customers will be able to choose this method in this zone again."
          } The reason is saved in the admin audit log.`}
          confirmLabel={dialog.fee.is_active ? "Turn off" : "Turn on"}
          danger={dialog.fee.is_active}
          successMessage={
            dialog.fee.is_active
              ? "Fee rule turned off."
              : "Fee rule turned on."
          }
          buildArgs={(reason) =>
            buildSetDeliveryZoneFeeActiveArgs(
              dialog.fee.id,
              !dialog.fee.is_active,
              reason,
            )
          }
          action={adminSetDeliveryZoneFeeActive}
          onClose={close}
        />
      ) : null}
    </>
  );
}

function FeeFormDialog({
  fee,
  zones,
  methods,
  onClose,
}: {
  fee: AdminDeliveryZoneFee | null;
  zones: readonly AdminDeliveryZone[];
  methods: readonly AdminDeliveryMethod[];
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<ZoneFeeDraft>(() =>
    fee ? zoneFeeDraftFromFee(fee) : emptyZoneFeeDraft(),
  );
  const op = useDeliveryAction({
    action: adminSaveDeliveryZoneFee,
    onDone: (result) => {
      toast.success(
        result.created
          ? "Fee rule created."
          : result.changed
            ? "Fee rule saved."
            : "Nothing changed.",
      );
      onClose();
    },
  });

  function update(
    patch: Partial<ZoneFeeDraft>,
    field: keyof typeof op.fieldErrors,
  ) {
    setDraft((prev) => ({ ...prev, ...patch }));
    op.clearField(field);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const built = buildZoneFeeFromDraft(fee?.id ?? null, draft);
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
          <DialogTitle>{fee ? "Edit fee rule" : "New fee rule"}</DialogTitle>
          <DialogDescription>
            {fee
              ? `${fee.zone_name} · ${fee.method_label}. The zone and method cannot change.`
              : "Choose the zone and method this fee applies to."}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4" noValidate>
          {fee ? null : (
            <>
              <Field label="Zone" htmlFor="fee-zone">
                <select
                  id="fee-zone"
                  className={SELECT_CLASS}
                  value={draft.zoneId}
                  disabled={op.pending}
                  onChange={(event) =>
                    update({ zoneId: event.target.value }, "form")
                  }
                >
                  <option value="">Choose a zone</option>
                  {zones.map((zone) => (
                    <option key={zone.id} value={zone.id}>
                      {zone.name}
                      {zone.is_active ? "" : " (inactive)"}
                    </option>
                  ))}
                </select>
              </Field>
              <Field label="Method" htmlFor="fee-method">
                <select
                  id="fee-method"
                  className={SELECT_CLASS}
                  value={draft.methodCode}
                  disabled={op.pending}
                  onChange={(event) =>
                    update({ methodCode: event.target.value }, "form")
                  }
                >
                  <option value="">Choose a method</option>
                  {methods.map((method) => (
                    <option key={method.code} value={method.code}>
                      {method.label}
                      {method.is_active ? "" : " (inactive)"}
                    </option>
                  ))}
                </select>
                <FieldError id="fee-form-error" message={op.fieldErrors.form} />
              </Field>
            </>
          )}

          <MoneyField
            id="fee-amount"
            label="Fee"
            value={draft.fee}
            disabled={op.pending}
            error={op.fieldErrors.fee}
            onChange={(value) => update({ fee: value }, "fee")}
          />
          <MoneyField
            id="fee-free-over"
            label="Free over (optional)"
            value={draft.freeOver}
            disabled={op.pending}
            error={op.fieldErrors.freeOver}
            hint="Orders at or above this amount ship free. Leave blank to never waive the fee."
            onChange={(value) => update({ freeOver: value }, "freeOver")}
          />
          <MoneyField
            id="fee-min-order"
            label="Minimum order (optional)"
            value={draft.minOrder}
            disabled={op.pending}
            error={op.fieldErrors.minOrder}
            hint="Can only raise the method's minimum order. Leave blank to use the method's minimum."
            onChange={(value) => update({ minOrder: value }, "minOrder")}
          />

          {op.formMessage && fee ? (
            <p role="alert" className={DIALOG_ERROR}>
              {op.formMessage}
            </p>
          ) : null}
          {op.formMessage && !fee && op.fieldErrors.form === undefined ? (
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
              {op.pending
                ? "Saving…"
                : fee
                  ? "Save fee rule"
                  : "Create fee rule"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
