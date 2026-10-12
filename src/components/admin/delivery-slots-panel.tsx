import { useQuery } from "@tanstack/react-query";
import { AdminQueryError } from "@/components/admin/admin-states";
import { useState } from "react";

import {
  DeliveryReasonDialog,
  DeliveryTableShell,
} from "@/components/admin/delivery-form-parts";
import { DeliverySlotOverrideDialog } from "@/components/admin/delivery-slot-override-dialog";
import { DeliverySlotTemplates } from "@/components/admin/delivery-slot-templates";
import {
  ConfigNotice,
  EmptyState,
  ErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import {
  adminClearDeliverySlotOverride,
  adminDeliverySlotsQuery,
} from "@/features/admin/delivery";
import {
  formatTimeHm,
  shiftSlotRange,
  type DeliveryDateRange,
} from "@/features/admin/delivery-management";
import { buildClearDeliverySlotOverrideArgs } from "@/features/admin/delivery-slot-override-result";
import type { AdminDeliverySlot } from "@/features/admin/delivery-slots-result";
import {
  describeBooked,
  findSlotOverride,
  groupSlotsByDate,
  overrideBlockedReason,
  resolveSlotRange,
  slotHasOverride,
} from "@/features/admin/delivery-slots-view";
import { adminLoadErrorMessage } from "@/features/admin/nav";
import { formatCalendarDate } from "@/lib/format";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { DeliveryParams } from "@/features/admin/delivery-management";

type SlotDialog = { kind: "override" | "clear"; slot: AdminDeliverySlot };

/**
 * The Slots tab: slot windows (templates) and a date-range view of capacity, bookings, closures
 * and per-date overrides. Reads admin_list_delivery_slots; every change goes through the 6F.2
 * wrappers. Clearing an override resets it (nothing is deleted).
 */
export function DeliverySlotsPanel({
  params,
  today,
  onRangeChange,
}: {
  params: DeliveryParams;
  today: string;
  /** null returns to the default range. */
  onRangeChange: (range: DeliveryDateRange | null) => void;
}) {
  const range = resolveSlotRange(params, today);
  const query = useQuery(
    adminDeliverySlotsQuery({ from: range.from, to: range.to }, today),
  );
  const [dialog, setDialog] = useState<SlotDialog | null>(null);
  const close = () => setDialog(null);

  if (query.isError)
    return (
      <SlotsError error={query.error} onRetry={() => void query.refetch()} />
    );
  if (!query.data) {
    return (
      <div
        className="space-y-2"
        role="status"
        aria-label="Loading delivery slots"
      >
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="skeleton h-12 rounded-lg" />
        ))}
      </div>
    );
  }

  const { templates, overrides, slots } = query.data;
  const days = groupSlotsByDate(slots);

  return (
    <div className="space-y-8">
      <DeliverySlotTemplates templates={templates} />

      <section aria-labelledby="slot-dates-heading" className="space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3
              id="slot-dates-heading"
              className="font-display text-lg font-semibold"
            >
              Dates
            </h3>
            <p className="text-sm text-muted-foreground">
              {formatCalendarDate(range.from)} to {formatCalendarDate(range.to)}
            </p>
          </div>
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => onRangeChange(shiftSlotRange(range, -1))}
            >
              Previous
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => onRangeChange(null)}
            >
              Today
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => onRangeChange(shiftSlotRange(range, 1))}
            >
              Next
            </Button>
          </div>
        </div>

        {days.length === 0 ? (
          <EmptyState
            eyebrow="No slots"
            title="No slots run in this range"
            message="Only active slot windows appear on dates. Create or activate a slot, or choose another range."
          />
        ) : (
          days.map((day) => (
            <DeliveryTableShell key={day.date}>
              <h4 className="px-2 pb-2 font-medium">
                {formatCalendarDate(day.date)}
              </h4>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Slot</TableHead>
                    <TableHead>Window</TableHead>
                    <TableHead className="text-right">Capacity</TableHead>
                    <TableHead>Bookings</TableHead>
                    <TableHead>Override</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {day.slots.map((slot) => {
                    const overridden = slotHasOverride(slot, overrides);
                    const note =
                      findSlotOverride(slot, overrides)?.note ?? null;
                    const blocked = overrideBlockedReason(slot, today);
                    return (
                      <TableRow key={`${slot.slot_date}-${slot.template_id}`}>
                        <TableCell className="font-medium">
                          {slot.label}
                          {!slot.template_active ? (
                            <span className="ml-2 text-xs text-muted-foreground">
                              (inactive)
                            </span>
                          ) : null}
                        </TableCell>
                        <TableCell className="font-mono text-sm">
                          {formatTimeHm(slot.start_time)} –{" "}
                          {formatTimeHm(slot.end_time)}
                        </TableCell>
                        <TableCell className="text-right font-mono text-sm">
                          {slot.is_closed
                            ? "Closed"
                            : slot.effective_capacity === null
                              ? "Unlimited"
                              : slot.effective_capacity}
                        </TableCell>
                        <TableCell className="text-sm">
                          {describeBooked(slot)}
                        </TableCell>
                        <TableCell className="text-sm">
                          {overridden ? (
                            <>
                              {slot.override_closed
                                ? "Closed"
                                : slot.override_capacity !== null
                                  ? `Capacity ${slot.override_capacity}`
                                  : "Note only"}
                              {note ? (
                                <div className="max-w-[28ch] text-xs text-muted-foreground">
                                  {note}
                                </div>
                              ) : null}
                            </>
                          ) : (
                            <span className="text-muted-foreground">—</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          <div className="flex justify-end gap-2">
                            <Button
                              variant="outline"
                              size="sm"
                              disabled={blocked !== null}
                              title={blocked ?? undefined}
                              onClick={() =>
                                setDialog({ kind: "override", slot })
                              }
                            >
                              Override
                            </Button>
                            {overridden ? (
                              <Button
                                variant="outline"
                                size="sm"
                                disabled={slot.slot_date < today}
                                onClick={() =>
                                  setDialog({ kind: "clear", slot })
                                }
                              >
                                Clear
                              </Button>
                            ) : null}
                          </div>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </DeliveryTableShell>
          ))
        )}
      </section>

      {dialog?.kind === "override" ? (
        <DeliverySlotOverrideDialog
          slot={dialog.slot}
          overrides={overrides}
          onClose={close}
        />
      ) : null}
      {dialog?.kind === "clear" ? (
        <DeliveryReasonDialog
          title="Clear this override?"
          description={`${dialog.slot.label} on ${formatCalendarDate(dialog.slot.slot_date)} goes back to the slot's usual capacity and opens again. Existing orders are not affected. The reason is saved in the admin audit log.`}
          confirmLabel="Clear override"
          danger={false}
          successMessage="Override cleared."
          buildArgs={(reason) =>
            buildClearDeliverySlotOverrideArgs(
              dialog.slot.template_id,
              dialog.slot.slot_date,
              reason,
            )
          }
          action={adminClearDeliverySlotOverride}
          onClose={close}
        />
      ) : null}
    </div>
  );
}

function SlotsError({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry: () => void;
}) {
  if (error instanceof SupabaseNotConfiguredError) return <ConfigNotice />;
  return (
    <AdminQueryError
      error={error}
      noun="delivery slots"
      action="manage delivery"
      onRetry={onRetry}
    />
  );
}
