import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui-kit/button";
import { TextArea } from "@/components/ui-kit/field";
import {
  describeNotesError,
  notesChanged,
} from "@/features/admin/customer-detail-management";
import {
  buildUpdateCustomerNotesArgs,
  MAX_CUSTOMER_NOTES_LENGTH,
} from "@/features/admin/customer-notes-result";
import { adminUpdateCustomerNotes } from "@/features/admin/customers";
import { formatDateTime } from "@/lib/format";

/**
 * Internal notes for one customer, saved through admin_update_customer_notes(). Notes are staff
 * only (customers can never read them). Saving an empty box clears the notes.
 *
 * `savedNotes` is what the page last loaded. The page remounts this card (by key) when the
 * database's stored notes change, so after a save the box shows what the database kept (trimmed),
 * not this component's draft.
 *
 * Duplicate submissions: the save button is disabled while saving and a ref blocks a second call
 * before React re-renders.
 */
export function CustomerNotesCard({
  customerId,
  savedNotes,
  updatedAt,
}: {
  customerId: string;
  savedNotes: string | null;
  updatedAt: string | null;
}) {
  const queryClient = useQueryClient();
  const [draft, setDraft] = useState(savedNotes ?? "");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: adminUpdateCustomerNotes,
    onSuccess: (result) => {
      toast.success(result.length === 0 ? "Notes cleared." : "Notes saved.");
    },
    onError: (cause) => {
      console.error("Customer notes update failed", cause);
      setError(describeNotesError(cause));
    },
    onSettled: async () => {
      inFlight.current = false;
      await queryClient.invalidateQueries({ queryKey: ["admin", "customers"] });
    },
  });

  const pending = mutation.isPending;
  const dirty = notesChanged(savedNotes, draft);

  function save() {
    if (inFlight.current || pending || !dirty) return;
    const built = buildUpdateCustomerNotesArgs(customerId, draft);
    if (!built.ok) {
      setFieldError(built.errors.notes);
      document.getElementById("customer-notes")?.focus();
      return;
    }
    inFlight.current = true;
    setFieldError(null);
    setError(null);
    mutation.mutate(built.args);
  }

  return (
    <div className="space-y-3">
      <div className="space-y-1.5">
        <label
          htmlFor="customer-notes"
          className="eyebrow block text-muted-foreground"
        >
          Internal notes
        </label>
        <TextArea
          id="customer-notes"
          rows={6}
          maxLength={MAX_CUSTOMER_NOTES_LENGTH}
          value={draft}
          disabled={pending}
          aria-invalid={fieldError ? true : undefined}
          aria-describedby={fieldError ? "customer-notes-error" : undefined}
          onChange={(event) => {
            setDraft(event.target.value);
            setFieldError(null);
            setError(null);
          }}
        />
        <p className="text-xs text-muted-foreground">
          Only admins can see these. Saving an empty box clears the notes.
          {updatedAt ? ` Last saved ${formatDateTime(updatedAt)}.` : ""}
        </p>
        {fieldError ? (
          <p
            id="customer-notes-error"
            role="alert"
            className="text-xs text-danger"
          >
            {fieldError}
          </p>
        ) : null}
      </div>

      {error ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {error}
        </p>
      ) : null}

      <Button disabled={pending || !dirty} aria-busy={pending} onClick={save}>
        {pending ? "Saving…" : "Save notes"}
      </Button>
    </div>
  );
}
