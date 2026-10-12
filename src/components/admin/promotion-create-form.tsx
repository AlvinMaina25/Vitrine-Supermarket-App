import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import { useOnlineStatus } from "@/components/states/use-online-status";
import {
  adminActionFailureMessage,
  firstErrorField,
} from "@/features/admin/admin-ui";
import { isAdminAccessError } from "@/features/admin/dashboard-result";
import { createPromotion } from "@/features/promotions/admin-api";
import {
  EMPTY_PROMOTION_FORM,
  PROMOTION_FIELD_ORDER,
  validatePromotionForm,
  type PromotionFormErrors,
  type PromotionFormField,
  type PromotionFormValues,
} from "@/features/promotions/admin-form";
import { promotionAdminErrorMessage } from "@/features/promotions/admin-parse";
import type { PromotionInput } from "@/features/promotions/admin-api";

const id = (field: PromotionFormField) => `promo-${field}`;

/**
 * Create a promotion through the existing admin_create_promotion() RPC. The form only checks
 * what an admin typed; the database validates every value again and its refusal is shown in
 * plain words. A promotion is created INACTIVE unless "Make it live now" is ticked, and creating
 * one live asks for confirmation because it changes what customers pay straight away.
 */
export function PromotionCreateForm({ onDone }: { onDone: () => void }) {
  const queryClient = useQueryClient();
  const online = useOnlineStatus();
  const [values, setValues] =
    useState<PromotionFormValues>(EMPTY_PROMOTION_FORM);
  const [errors, setErrors] = useState<PromotionFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const [pendingInput, setPendingInput] = useState<PromotionInput | null>(null);
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: createPromotion,
    onSuccess: (row) => {
      toast.success(
        `Created “${row.name}” (${row.is_active ? "live" : "inactive"}).`,
      );
      setValues(EMPTY_PROMOTION_FORM);
      setErrors({});
      setServerError(null);
      onDone();
    },
    onError: (cause) => {
      console.error("Promotion create failed", cause);
      const message = adminActionFailureMessage(
        cause,
        online,
        cause instanceof Error && !isAdminAccessError(cause)
          ? cause.message
          : "The promotion could not be saved. Please try again.",
      );
      if (message === promotionAdminErrorMessage({ details: "code_taken" })) {
        setErrors({ code: message });
        setServerError(null);
        document.getElementById(id("code"))?.focus();
      } else {
        setServerError(message);
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      await queryClient.invalidateQueries({
        queryKey: ["admin", "promotions"],
      });
    },
  });
  const pending = mutation.isPending;

  function set<K extends keyof PromotionFormValues>(
    key: K,
    value: PromotionFormValues[K],
  ) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => {
      if (!(key in prev)) return prev;
      const { [key as PromotionFormField]: _gone, ...rest } = prev;
      return rest;
    });
    setServerError(null);
  }

  function send(input: PromotionInput) {
    if (inFlight.current || mutation.isPending) return;
    inFlight.current = true;
    mutation.mutate(input);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (inFlight.current || pending) return;
    setServerError(null);
    const result = validatePromotionForm(values);
    if (!result.ok) {
      setErrors(result.errors);
      const first = firstErrorField(result.errors, PROMOTION_FIELD_ORDER);
      if (first) document.getElementById(id(first))?.focus();
      return;
    }
    setErrors({});
    if (result.input.is_active === true) setPendingInput(result.input);
    else send(result.input);
  }

  const percentage = values.discountType === "percentage";
  const field = (key: PromotionFormField) => ({
    id: id(key),
    "aria-invalid": errors[key] ? true : undefined,
    "aria-describedby": errors[key] ? `${id(key)}-error` : undefined,
    disabled: pending,
  });

  return (
    <form
      onSubmit={submit}
      noValidate
      aria-busy={pending}
      aria-label="New promotion"
      className="glass-panel mb-6 space-y-4 rounded-(--radius-panel) p-5"
    >
      <h2 className="font-display text-xl font-semibold">New promotion</h2>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Name *" htmlFor={id("name")} error={errors.name}>
          <TextInput
            {...field("name")}
            value={values.name}
            onChange={(e) => set("name", e.target.value)}
            autoComplete="off"
          />
        </Field>
        <Field
          label="Coupon code"
          htmlFor={id("code")}
          hint="Leave blank for an automatic promotion."
          error={errors.code}
        >
          <TextInput
            {...field("code")}
            value={values.code}
            onChange={(e) => set("code", e.target.value)}
            autoComplete="off"
            autoCapitalize="characters"
          />
        </Field>

        <div className="space-y-1.5">
          <label
            htmlFor="promo-type"
            className="eyebrow block text-muted-foreground"
          >
            Discount type
          </label>
          <select
            id="promo-type"
            disabled={pending}
            value={values.discountType}
            onChange={(e) =>
              set(
                "discountType",
                e.target.value === "fixed" ? "fixed" : "percentage",
              )
            }
            className="min-h-11 w-full rounded-lg border border-border bg-background px-3 py-2 text-base md:pointer-fine:text-sm"
          >
            <option value="percentage">Percentage off</option>
            <option value="fixed">Fixed amount off</option>
          </select>
        </div>
        <Field
          label={percentage ? "Percentage off *" : "Amount off (KES) *"}
          htmlFor={id("value")}
          hint={percentage ? "For example 10 or 12.5." : "For example 200."}
          error={errors.value}
        >
          <TextInput
            {...field("value")}
            inputMode="decimal"
            value={values.value}
            onChange={(e) => set("value", e.target.value)}
            autoComplete="off"
          />
        </Field>

        {percentage ? (
          <Field
            label="Maximum discount (KES)"
            htmlFor={id("maxDiscount")}
            hint="Optional cap on the amount taken off."
            error={errors.maxDiscount}
          >
            <TextInput
              {...field("maxDiscount")}
              inputMode="decimal"
              value={values.maxDiscount}
              onChange={(e) => set("maxDiscount", e.target.value)}
              autoComplete="off"
            />
          </Field>
        ) : null}
        <Field
          label="Minimum order (KES)"
          htmlFor={id("minOrder")}
          hint="Optional."
          error={errors.minOrder}
        >
          <TextInput
            {...field("minOrder")}
            inputMode="decimal"
            value={values.minOrder}
            onChange={(e) => set("minOrder", e.target.value)}
            autoComplete="off"
          />
        </Field>

        <Field
          label="Starts"
          htmlFor={id("startsAt")}
          hint="Nairobi time. Optional."
          error={errors.startsAt}
        >
          <TextInput
            {...field("startsAt")}
            type="datetime-local"
            value={values.startsAt}
            onChange={(e) => set("startsAt", e.target.value)}
          />
        </Field>
        <Field
          label="Ends"
          htmlFor={id("expiresAt")}
          hint="Nairobi time. Optional."
          error={errors.expiresAt}
        >
          <TextInput
            {...field("expiresAt")}
            type="datetime-local"
            value={values.expiresAt}
            onChange={(e) => set("expiresAt", e.target.value)}
          />
        </Field>

        <Field
          label="Total uses allowed"
          htmlFor={id("usageLimit")}
          hint="Optional."
          error={errors.usageLimit}
        >
          <TextInput
            {...field("usageLimit")}
            inputMode="numeric"
            value={values.usageLimit}
            onChange={(e) => set("usageLimit", e.target.value)}
            autoComplete="off"
          />
        </Field>
        <Field
          label="Uses per customer"
          htmlFor={id("perCustomerLimit")}
          hint="Optional."
          error={errors.perCustomerLimit}
        >
          <TextInput
            {...field("perCustomerLimit")}
            inputMode="numeric"
            value={values.perCustomerLimit}
            onChange={(e) => set("perCustomerLimit", e.target.value)}
            autoComplete="off"
          />
        </Field>
      </div>

      <label className="flex min-h-11 items-center gap-3 text-sm">
        <input
          type="checkbox"
          className="size-5"
          disabled={pending}
          checked={values.activateNow}
          onChange={(e) => set("activateNow", e.target.checked)}
        />
        Make it live now (customers can use it straight away)
      </label>

      {serverError ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {serverError}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-3">
        <Button type="submit" size="touch" disabled={pending}>
          {pending ? "Creating…" : "Create promotion"}
        </Button>
        <Button
          type="button"
          size="touch"
          variant="outline"
          disabled={pending}
          onClick={onDone}
        >
          Cancel
        </Button>
      </div>

      <AlertDialog
        open={pendingInput !== null}
        onOpenChange={(open) => {
          if (!open) setPendingInput(null);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Create this promotion live?</AlertDialogTitle>
            <AlertDialogDescription>
              Customers can use it as soon as it is created. You can deactivate
              it later, but it cannot be deleted.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Go back</AlertDialogCancel>
            <Button
              disabled={pending}
              onClick={() => {
                const input = pendingInput;
                setPendingInput(null);
                if (input) send(input);
              }}
            >
              Create live
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </form>
  );
}
