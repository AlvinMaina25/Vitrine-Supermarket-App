import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import { toAdminDeliveryConfig } from "./delivery-config-result";
import { toAdminDeliveryError } from "./delivery-error";
import { toSlotsListArgs, type DeliveryParams } from "./delivery-management";
import {
  toAdminUpdateDeliveryMethodResult,
  type AdminUpdateDeliveryMethodArgs,
  type AdminUpdateDeliveryMethodResult,
} from "./delivery-method-result";
import {
  toAdminClearDeliverySlotOverrideResult,
  toAdminSaveDeliverySlotOverrideResult,
  type AdminClearDeliverySlotOverrideArgs,
  type AdminClearDeliverySlotOverrideResult,
  type AdminSaveDeliverySlotOverrideArgs,
  type AdminSaveDeliverySlotOverrideResult,
} from "./delivery-slot-override-result";
import {
  toAdminSaveDeliverySlotTemplateResult,
  toAdminSetDeliverySlotTemplateActiveResult,
  type AdminSaveDeliverySlotTemplateArgs,
  type AdminSaveDeliverySlotTemplateResult,
  type AdminSetDeliverySlotTemplateActiveArgs,
  type AdminSetDeliverySlotTemplateActiveResult,
} from "./delivery-slot-template-result";
import { toAdminDeliverySlotList } from "./delivery-slots-result";
import {
  toAdminSaveDeliveryZoneFeeResult,
  toAdminSetDeliveryZoneFeeActiveResult,
  type AdminSaveDeliveryZoneFeeArgs,
  type AdminSaveDeliveryZoneFeeResult,
  type AdminSetDeliveryZoneFeeActiveArgs,
  type AdminSetDeliveryZoneFeeActiveResult,
} from "./delivery-zone-fee-result";
import {
  toAdminSaveDeliveryZoneResult,
  toAdminSetDeliveryZoneActiveResult,
  type AdminSaveDeliveryZoneArgs,
  type AdminSaveDeliveryZoneResult,
  type AdminSetDeliveryZoneActiveArgs,
  type AdminSetDeliveryZoneActiveResult,
} from "./delivery-zone-result";

/**
 * Admin delivery settings (Phase 6F.1A/6F.1B backend, consumed by Phase 6F.2).
 *
 * Every call goes through the signed-in session to an admin-only database function; none of them
 * touches a table directly. The database refuses customers, staff and anonymous visitors
 * (AdminAccessError); hiding a link or a button is a UI convenience only. Money is whole cents,
 * sent exactly as entered and validated, stored and applied by the database; it is never
 * calculated here. Nothing is deleted: configuration is deactivated, overrides are cleared.
 *
 *   admin_list_delivery_config()               read; methods, zones and zone fees, inactive too
 *   admin_save_delivery_zone()                 write; create or update a zone
 *   admin_set_delivery_zone_active()           write; activate / deactivate a zone (reason)
 *   admin_save_delivery_zone_fee()             write; create or update a zone fee rule
 *   admin_set_delivery_zone_fee_active()       write; activate / deactivate a fee rule (reason)
 *   admin_update_delivery_method()             write; base fee, free-over, minimum, active
 *   admin_list_delivery_slots()                read; templates, overrides, per-date slots
 *   admin_save_delivery_slot_template()        write; create or update a slot template
 *   admin_set_delivery_slot_template_active()  write; activate / deactivate (reason)
 *   admin_save_delivery_slot_override()        write; capacity or closure of one slot on a date
 *   admin_clear_delivery_slot_override()       write; reset one slot's override (reason)
 *
 * All query keys start with ["admin", "delivery"], so one invalidation refreshes every view.
 */

/** Methods, zones and zone fee rules (inactive included). */
export const adminDeliveryConfigQuery = () =>
  queryOptions({
    queryKey: ["admin", "delivery", "config"],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_delivery_config",
        {},
      );
      if (error) throw toAdminDeliveryError(error);
      return toAdminDeliveryConfig(data);
    },
  });

/**
 * Slot templates, overrides and per-date slots for the selected range. `today` is the current
 * date in Nairobi (YYYY-MM-DD); it only picks the default week.
 */
export const adminDeliverySlotsQuery = (
  params: DeliveryParams,
  today: string,
) =>
  queryOptions({
    queryKey: ["admin", "delivery", "slots", toSlotsListArgs(params, today)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_delivery_slots",
        toSlotsListArgs(params, today),
      );
      if (error) throw toAdminDeliveryError(error);
      return toAdminDeliverySlotList(data);
    },
  });

export async function adminSaveDeliveryZone(
  args: AdminSaveDeliveryZoneArgs,
): Promise<AdminSaveDeliveryZoneResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_save_delivery_zone",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSaveDeliveryZoneResult(data);
}

export async function adminSetDeliveryZoneActive(
  args: AdminSetDeliveryZoneActiveArgs,
): Promise<AdminSetDeliveryZoneActiveResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_delivery_zone_active",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSetDeliveryZoneActiveResult(data);
}

export async function adminSaveDeliveryZoneFee(
  args: AdminSaveDeliveryZoneFeeArgs,
): Promise<AdminSaveDeliveryZoneFeeResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_save_delivery_zone_fee",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSaveDeliveryZoneFeeResult(data);
}

export async function adminSetDeliveryZoneFeeActive(
  args: AdminSetDeliveryZoneFeeActiveArgs,
): Promise<AdminSetDeliveryZoneFeeActiveResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_delivery_zone_fee_active",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSetDeliveryZoneFeeActiveResult(data);
}

export async function adminUpdateDeliveryMethod(
  args: AdminUpdateDeliveryMethodArgs,
): Promise<AdminUpdateDeliveryMethodResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_update_delivery_method",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminUpdateDeliveryMethodResult(data);
}

export async function adminSaveDeliverySlotTemplate(
  args: AdminSaveDeliverySlotTemplateArgs,
): Promise<AdminSaveDeliverySlotTemplateResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_save_delivery_slot_template",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSaveDeliverySlotTemplateResult(data);
}

export async function adminSetDeliverySlotTemplateActive(
  args: AdminSetDeliverySlotTemplateActiveArgs,
): Promise<AdminSetDeliverySlotTemplateActiveResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_set_delivery_slot_template_active",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSetDeliverySlotTemplateActiveResult(data);
}

export async function adminSaveDeliverySlotOverride(
  args: AdminSaveDeliverySlotOverrideArgs,
): Promise<AdminSaveDeliverySlotOverrideResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_save_delivery_slot_override",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminSaveDeliverySlotOverrideResult(data);
}

export async function adminClearDeliverySlotOverride(
  args: AdminClearDeliverySlotOverrideArgs,
): Promise<AdminClearDeliverySlotOverrideResult> {
  const { data, error } = await requireSupabase().rpc(
    "admin_clear_delivery_slot_override",
    args,
  );
  if (error) throw toAdminDeliveryError(error);
  return toAdminClearDeliverySlotOverrideResult(data);
}
