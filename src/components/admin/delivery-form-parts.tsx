import { useState, type ReactNode } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui-kit/button";
import { Field, TextArea, TextInput } from "@/components/ui-kit/field";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { MAX_DELIVERY_REASON_LENGTH } from "@/features/admin/delivery-parse";
import {
  useDeliveryAction,
  type BuildResult,
} from "@/hooks/use-delivery-action";

export const DIALOG_ERROR =
  "rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger";

export const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary disabled:opacity-50";

/** The table shell the other admin lists use. */
export function DeliveryTableShell({ children }: { children: ReactNode }) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-2 sm:p-4">
      {children}
    </div>
  );
}

/** A non-blocking warning, styled like the admin error box. */
export function DeliveryWarning({
  title,
  message,
}: {
  title: string;
  message: string;
}) {
  return (
    <div
      role="alert"
      className="rounded-(--radius-card) border border-danger/25 bg-danger/5 p-4"
    >
      <div className="eyebrow font-medium text-danger">Warning</div>
      <h3 className="mt-1 font-display text-base font-semibold">{title}</h3>
      <p className="mt-1 text-sm text-muted-foreground">{message}</p>
    </div>
  );
}

export function FieldError({
  id,
  message,
}: {
  id: string;
  message: string | undefined;
}) {
  if (!message) return null;
  return (
    <p id={id} role="alert" className="text-xs text-danger">
      {message}
    </p>
  );
}

/** A labelled text input with its own error line. */
export function TextField({
  id,
  label,
  value,
  onChange,
  error,
  hint,
  disabled,
  maxLength,
  inputMode,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  error: string | undefined;
  hint?: ReactNode;
  disabled: boolean;
  maxLength?: number;
  inputMode?: "text" | "numeric" | "decimal";
}) {
  return (
    <Field label={label} htmlFor={id} hint={hint}>
      <TextInput
        id={id}
        autoComplete="off"
        value={value}
        disabled={disabled}
        maxLength={maxLength}
        inputMode={inputMode}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        onChange={(event) => onChange(event.target.value)}
      />
      <FieldError id={`${id}-error`} message={error} />
    </Field>
  );
}

/** An amount in shillings (for example 250 or 250.50). The shared helper converts it to cents. */
export function MoneyField(props: {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  error: string | undefined;
  hint?: ReactNode;
  disabled: boolean;
}) {
  return (
    <TextField
      {...props}
      inputMode="decimal"
      hint={props.hint ?? "In shillings, for example 250 or 250.50."}
    />
  );
}

export function TextAreaField({
  id,
  label,
  value,
  onChange,
  error,
  hint,
  disabled,
  maxLength,
  rows = 3,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  error: string | undefined;
  hint?: ReactNode;
  disabled: boolean;
  maxLength?: number;
  rows?: number;
}) {
  return (
    <Field label={label} htmlFor={id} hint={hint}>
      <TextArea
        id={id}
        rows={rows}
        value={value}
        disabled={disabled}
        maxLength={maxLength}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        onChange={(event) => onChange(event.target.value)}
      />
      <FieldError id={`${id}-error`} message={error} />
    </Field>
  );
}

/**
 * Confirm dialog with a required reason, for turning a zone or a fee rule on or off. The reason
 * is saved in the admin audit log by the database. It cannot be dismissed while saving.
 */
export function DeliveryReasonDialog<A>({
  title,
  description,
  confirmLabel,
  danger,
  successMessage,
  buildArgs,
  action,
  onClose,
}: {
  title: string;
  description: string;
  confirmLabel: string;
  danger: boolean;
  successMessage: string;
  buildArgs: (reason: string) => BuildResult<A>;
  action: (args: A) => Promise<unknown>;
  onClose: () => void;
}) {
  const [reason, setReason] = useState("");
  const op = useDeliveryAction({
    action,
    onDone: () => {
      toast.success(successMessage);
      onClose();
    },
  });

  function confirm() {
    const built = buildArgs(reason);
    if (!built.ok) {
      op.setFieldErrors(built.errors);
      return;
    }
    op.run(built.args);
  }

  return (
    <AlertDialog
      open
      onOpenChange={(next) => {
        if (!next && !op.pending) onClose();
      }}
    >
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>

        <TextAreaField
          id="delivery-reason"
          label="Reason (required)"
          value={reason}
          maxLength={MAX_DELIVERY_REASON_LENGTH}
          disabled={op.pending}
          error={op.fieldErrors.reason}
          onChange={(value) => {
            setReason(value);
            op.clearField("reason");
          }}
        />

        {op.formMessage ? (
          <p role="alert" className={DIALOG_ERROR}>
            {op.formMessage}
          </p>
        ) : null}

        <AlertDialogFooter>
          <Button variant="outline" disabled={op.pending} onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant={danger ? "danger" : "primary"}
            disabled={op.pending}
            aria-busy={op.pending}
            onClick={confirm}
          >
            {op.pending ? "Saving…" : confirmLabel}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
