import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";

import { focusFirstInvalid } from "@/components/admin/focus-first-error";
import {
  isAdminDeliveryError,
  type DeliveryFieldErrors,
} from "@/features/admin/delivery-error";
import { describeDeliveryActionError } from "@/features/admin/delivery-management";

/**
 * Runs one admin delivery write. A ref blocks a second call before React re-renders the disabled
 * button, the delivery queries are refreshed whether it succeeds or is refused (so the screen
 * shows what the database now holds), and every failure becomes a friendly message: a field's
 * message when the database names the field, otherwise a message for the whole form.
 */
export function useDeliveryAction<A, R>({
  action,
  onDone,
}: {
  action: (args: A) => Promise<R>;
  onDone: (result: R) => void;
}) {
  const queryClient = useQueryClient();
  const inFlight = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<DeliveryFieldErrors>({});

  const mutation = useMutation({
    mutationFn: action,
    onSuccess: onDone,
    onError: (cause) => {
      console.error("Delivery change failed", cause);
      const message = describeDeliveryActionError(cause);
      setError(message);
      if (isAdminDeliveryError(cause) && cause.field !== null) {
        const next: DeliveryFieldErrors = {};
        next[cause.field] = message;
        setFieldErrors(next);
        focusFirstInvalid();
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      await queryClient.invalidateQueries({ queryKey: ["admin", "delivery"] });
    },
  });

  function run(args: A) {
    if (inFlight.current || mutation.isPending) return;
    inFlight.current = true;
    setError(null);
    setFieldErrors({});
    mutation.mutate(args);
  }

  function clearField(key: keyof DeliveryFieldErrors) {
    setFieldErrors((prev) => {
      const { [key]: _cleared, ...rest } = prev;
      return rest;
    });
    setError(null);
  }

  /** The message for the whole form: a form-level validation error, or a refusal with no field. */
  const formMessage =
    fieldErrors.form ??
    (error !== null && Object.keys(fieldErrors).length === 0 ? error : null);

  return {
    pending: mutation.isPending,
    fieldErrors,
    /** Shows the errors and moves focus to the first invalid field. */
    setFieldErrors: (errors: DeliveryFieldErrors) => {
      setFieldErrors(errors);
      focusFirstInvalid();
    },
    clearField,
    formMessage,
    run,
  };
}

export type BuildResult<A> =
  { ok: true; args: A } | { ok: false; errors: DeliveryFieldErrors };
