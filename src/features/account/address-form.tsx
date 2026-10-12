import { useRef, useState, type FormEvent } from "react";

import { isNetworkFailure } from "@/components/states/error-kind";
import { ErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import type { AddressInsert, AddressRow } from "@/lib/supabase/types";

import {
  ADDRESS_FIELD_ORDER,
  cleanPhone,
  firstErrorField,
  validateAddress,
  type AddressErrors,
  type AddressField,
} from "./form-validation";
import { KENYAN_COUNTIES } from "./queries";

/** DOM id of each field, so focus can move to the first one with a problem. */
const FIELD_IDS: Record<AddressField, string> = {
  label: "addr-label",
  fullName: "addr-name",
  phone: "addr-phone",
  county: "addr-county",
  line1: "addr-line1",
  line2: "addr-line2",
  city: "addr-city",
  postalCode: "addr-postal",
  instructions: "addr-notes",
};

/** Props that tie an input to its inline error message. */
function invalidProps(errors: AddressErrors, field: AddressField) {
  const id = FIELD_IDS[field];
  return errors[field]
    ? ({ "aria-invalid": true, "aria-describedby": `${id}-error` } as const)
    : {};
}

const selectClass =
  "min-h-11 w-full rounded-lg border border-border bg-background px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

function blankToNull(value: string): string | null {
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

export function AddressForm({
  initial,
  defaultName,
  defaultPhone,
  onSubmit,
  onCancel,
}: {
  initial?: AddressRow | undefined;
  defaultName?: string | null | undefined;
  defaultPhone?: string | null | undefined;
  onSubmit: (values: AddressInsert) => Promise<void>;
  onCancel: () => void;
}) {
  const [values, setValues] = useState({
    label: initial?.label ?? "",
    full_name: initial?.full_name ?? defaultName ?? "",
    phone: initial?.phone ?? defaultPhone ?? "",
    address_line_1: initial?.address_line_1 ?? "",
    address_line_2: initial?.address_line_2 ?? "",
    city: initial?.city ?? "",
    county: initial?.county ?? "Nairobi",
    postal_code: initial?.postal_code ?? "",
    delivery_instructions: initial?.delivery_instructions ?? "",
    is_default: initial?.is_default ?? false,
  });
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errors, setErrors] = useState<AddressErrors>({});
  const submitting = useRef(false);

  const set = (key: keyof typeof values) => (value: string | boolean) =>
    setValues((current) => ({ ...current, [key]: value }));

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (submitting.current) return; // no double submit
    setError(null);
    const phone = cleanPhone(values.phone);
    const found = validateAddress({
      label: values.label,
      fullName: values.full_name,
      phone: values.phone,
      county: values.county,
      line1: values.address_line_1,
      line2: values.address_line_2,
      city: values.city,
      postalCode: values.postal_code,
      instructions: values.delivery_instructions,
    });
    setErrors(found);
    const first = firstErrorField(found, ADDRESS_FIELD_ORDER);
    if (first) {
      document.getElementById(FIELD_IDS[first])?.focus();
      return;
    }
    submitting.current = true;
    setPending(true);
    try {
      await onSubmit({
        label: blankToNull(values.label),
        full_name: values.full_name.trim(),
        phone,
        address_line_1: values.address_line_1.trim(),
        address_line_2: blankToNull(values.address_line_2),
        city: values.city.trim(),
        county: values.county,
        postal_code: blankToNull(values.postal_code),
        delivery_instructions: blankToNull(values.delivery_instructions),
        is_default: values.is_default,
      });
    } catch (cause) {
      console.error("Address save failed", cause);
      setError(
        isNetworkFailure(
          cause,
          typeof navigator === "undefined" ? undefined : navigator.onLine,
        )
          ? "We couldn't reach the shop. Check your connection and try again."
          : "We couldn't save this address. Please try again.",
      );
    } finally {
      submitting.current = false;
      setPending(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="space-y-4">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field
          label="Label"
          htmlFor="addr-label"
          error={errors.label}
          hint="e.g. Home, Office"
        >
          <TextInput
            className="min-h-11"
            id="addr-label"
            {...invalidProps(errors, "label")}
            maxLength={40}
            value={values.label}
            onChange={(e) => set("label")(e.target.value)}
          />
        </Field>
        <Field
          label="Recipient name"
          htmlFor="addr-name"
          error={errors.fullName}
        >
          <TextInput
            className="min-h-11"
            id="addr-name"
            {...invalidProps(errors, "fullName")}
            required
            maxLength={120}
            autoComplete="name"
            value={values.full_name}
            onChange={(e) => set("full_name")(e.target.value)}
          />
        </Field>
        <Field label="Phone" htmlFor="addr-phone" error={errors.phone}>
          <TextInput
            className="min-h-11"
            id="addr-phone"
            {...invalidProps(errors, "phone")}
            required
            type="tel"
            autoComplete="tel"
            placeholder="0712 345 678"
            value={values.phone}
            onChange={(e) => set("phone")(e.target.value)}
          />
        </Field>
        <Field label="County" htmlFor="addr-county" error={errors.county}>
          <select
            id="addr-county"
            {...invalidProps(errors, "county")}
            required
            className={selectClass}
            value={values.county}
            onChange={(e) => set("county")(e.target.value)}
          >
            {KENYAN_COUNTIES.map((county) => (
              <option key={county} value={county}>
                {county}
              </option>
            ))}
          </select>
        </Field>
        <div className="sm:col-span-2">
          <Field
            label="Street / building"
            htmlFor="addr-line1"
            error={errors.line1}
          >
            <TextInput
              className="min-h-11"
              id="addr-line1"
              {...invalidProps(errors, "line1")}
              required
              maxLength={200}
              autoComplete="address-line1"
              placeholder="e.g. Riverside Drive, Apt 4B"
              value={values.address_line_1}
              onChange={(e) => set("address_line_1")(e.target.value)}
            />
          </Field>
        </div>
        <div className="sm:col-span-2">
          <Field
            label="Estate / landmark (optional)"
            htmlFor="addr-line2"
            error={errors.line2}
          >
            <TextInput
              className="min-h-11"
              id="addr-line2"
              {...invalidProps(errors, "line2")}
              maxLength={200}
              autoComplete="address-line2"
              value={values.address_line_2}
              onChange={(e) => set("address_line_2")(e.target.value)}
            />
          </Field>
        </div>
        <Field label="Town / city" htmlFor="addr-city" error={errors.city}>
          <TextInput
            className="min-h-11"
            id="addr-city"
            {...invalidProps(errors, "city")}
            required
            maxLength={80}
            autoComplete="address-level2"
            value={values.city}
            onChange={(e) => set("city")(e.target.value)}
          />
        </Field>
        <Field
          label="Postal code (optional)"
          htmlFor="addr-postal"
          error={errors.postalCode}
        >
          <TextInput
            className="min-h-11"
            id="addr-postal"
            {...invalidProps(errors, "postalCode")}
            maxLength={10}
            autoComplete="postal-code"
            value={values.postal_code}
            onChange={(e) => set("postal_code")(e.target.value)}
          />
        </Field>
        <div className="sm:col-span-2">
          <Field
            label="Delivery instructions (optional)"
            htmlFor="addr-notes"
            error={errors.instructions}
          >
            <textarea
              id="addr-notes"
              {...invalidProps(errors, "instructions")}
              maxLength={500}
              rows={3}
              className={selectClass}
              placeholder="Gate code, which entrance, call on arrival…"
              value={values.delivery_instructions}
              onChange={(e) => set("delivery_instructions")(e.target.value)}
            />
          </Field>
        </div>
      </div>
      <label className="flex min-h-11 items-center gap-2 text-sm">
        <input
          className="size-5"
          type="checkbox"
          checked={values.is_default}
          onChange={(e) => set("is_default")(e.target.checked)}
        />
        Use as my default delivery address
      </label>
      {error ? (
        <div role="alert">
          <ErrorState title="Couldn't save address" message={error} />
        </div>
      ) : null}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="touch" disabled={pending}>
          {pending ? "Saving…" : initial ? "Save address" : "Add address"}
        </Button>
        <Button
          type="button"
          size="touch"
          variant="outline"
          onClick={onCancel}
          disabled={pending}
        >
          Cancel
        </Button>
      </div>
    </form>
  );
}
