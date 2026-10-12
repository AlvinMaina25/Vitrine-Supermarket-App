import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { focusFirstError } from "@/components/admin/focus-first-error";
import { ImagePicker } from "@/components/admin/image-picker";
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
import { Switch } from "@/components/ui/switch";
import {
  adminCreateCategory,
  adminUpdateCategory,
} from "@/features/admin/categories";
import {
  buildCategoryChanges,
  buildCreateCategoryArgs,
  categoryFieldId,
  categoryHasChanges,
  categorySaveErrorField,
  categoryToFormValues,
  CATEGORY_FIELD_ORDER,
  describeCategorySaveError,
  emptyCategoryFormValues,
  type CategoryFormErrors,
  type CategoryFormValues,
} from "@/features/admin/categories-result";
import { slugifyName } from "@/features/admin/products-result";
import type { CategoryRow } from "@/lib/supabase/types";

/**
 * Create (category = null) or edit one category. Create calls admin_create_category(); edit sends
 * only the changed fields to admin_update_category(). There is no delete: switching "Active" off
 * hides the category from the storefront (behind a confirmation) and nothing is removed.
 * The checks here are for usability; the database validates everything again and refusals are
 * shown in plain words, never as raw database text.
 */
export function CategoryForm({
  category,
  onDone,
}: {
  category: CategoryRow | null;
  /** Called after a successful save and when the person cancels. */
  onDone: (saved: CategoryRow | null) => void;
}) {
  const queryClient = useQueryClient();
  const editing = category !== null;
  const initial = category
    ? categoryToFormValues(category)
    : emptyCategoryFormValues();

  const [values, setValues] = useState<CategoryFormValues>(initial);
  const [errors, setErrors] = useState<CategoryFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const [slugEdited, setSlugEdited] = useState(editing);
  const [confirmHide, setConfirmHide] = useState(false);
  // True while the picture is being saved; the picture saves separately from the text fields.
  const [imageBusy, setImageBusy] = useState(false);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: async (): Promise<CategoryRow> => {
      if (category) {
        const { changes } = buildCategoryChanges(initial, values);
        const result = await adminUpdateCategory({
          categoryId: category.id,
          changes,
        });
        return result.category;
      }
      const { args } = buildCreateCategoryArgs(values);
      if (!args) throw new Error("Form not valid");
      return (await adminCreateCategory(args)).category;
    },
    onSuccess: (saved) => {
      setErrors({});
      setServerError(null);
      toast.success(
        editing ? `Saved “${saved.name}”.` : `Created “${saved.name}”.`,
      );
      onDone(saved);
    },
    onError: (cause) => {
      console.error("Category save failed", cause);
      const message = describeCategorySaveError(cause);
      const field = categorySaveErrorField(cause);
      if (field) {
        setErrors({ [field]: message });
        setServerError(null);
      } else {
        setServerError(message);
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      await queryClient.invalidateQueries({
        queryKey: ["admin", "categories"],
      });
    },
  });

  const pending = mutation.isPending;

  function setValue<K extends keyof CategoryFormValues>(
    key: K,
    value: CategoryFormValues[K],
  ) {
    setValues((prev) => {
      const next = { ...prev, [key]: value };
      if (key === "name" && !slugEdited) next.slug = slugifyName(String(value));
      return next;
    });
    if (key === "slug") setSlugEdited(true);
    setErrors((prev) => {
      const next = { ...prev };
      delete next[key as keyof CategoryFormErrors];
      if (key === "name" && !slugEdited) delete next.slug;
      return next;
    });
    setServerError(null);
  }

  function save() {
    if (inFlight.current || pending) return;
    setServerError(null);
    const result = editing
      ? buildCategoryChanges(initial, values)
      : buildCreateCategoryArgs(values);
    if (Object.keys(result.errors).length > 0) {
      setErrors(result.errors);
      focusFirstError(result.errors, CATEGORY_FIELD_ORDER, categoryFieldId);
      return;
    }
    if (
      editing &&
      !categoryHasChanges((result as { changes: object }).changes)
    ) {
      toast.message("Nothing to save: no changes were made.");
      return;
    }
    setErrors({});
    inFlight.current = true;
    mutation.mutate();
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (inFlight.current || pending) return;
    // Hiding a live category needs a confirmation first.
    if (editing && initial.isActive && !values.isActive) {
      setConfirmHide(true);
      return;
    }
    save();
  }

  const err = (key: keyof CategoryFormErrors) => errors[key];
  const describedBy = (key: keyof CategoryFormErrors) =>
    err(key) ? `${categoryFieldId(key)}-error` : undefined;

  return (
    <form
      onSubmit={submit}
      noValidate
      aria-busy={pending}
      className="space-y-4"
    >
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <Field
          label="Name *"
          htmlFor={categoryFieldId("name")}
          error={err("name")}
        >
          <TextInput
            id={categoryFieldId("name")}
            value={values.name}
            maxLength={80}
            disabled={pending}
            aria-invalid={err("name") ? true : undefined}
            aria-describedby={describedBy("name")}
            onChange={(event) => setValue("name", event.target.value)}
          />
        </Field>
        <Field
          label="URL slug *"
          htmlFor={categoryFieldId("slug")}
          hint={
            editing
              ? "Changing this changes the category's storefront address."
              : "Lower-case letters, digits and hyphens. Filled in from the name."
          }
          error={err("slug")}
        >
          <TextInput
            id={categoryFieldId("slug")}
            value={values.slug}
            maxLength={80}
            spellCheck={false}
            disabled={pending}
            aria-invalid={err("slug") ? true : undefined}
            aria-describedby={describedBy("slug")}
            onChange={(event) => setValue("slug", event.target.value)}
          />
        </Field>
        <Field
          label="Tagline"
          htmlFor={categoryFieldId("tagline")}
          hint="Optional. Up to 120 characters."
          error={err("tagline")}
        >
          <TextInput
            id={categoryFieldId("tagline")}
            value={values.tagline}
            maxLength={120}
            disabled={pending}
            aria-invalid={err("tagline") ? true : undefined}
            aria-describedby={describedBy("tagline")}
            onChange={(event) => setValue("tagline", event.target.value)}
          />
        </Field>
        <Field
          label="Position"
          htmlFor={categoryFieldId("position")}
          hint="0 or more. Lower numbers come first."
          error={err("position")}
        >
          <TextInput
            id={categoryFieldId("position")}
            inputMode="numeric"
            value={values.position}
            disabled={pending}
            aria-invalid={err("position") ? true : undefined}
            aria-describedby={describedBy("position")}
            onChange={(event) => setValue("position", event.target.value)}
          />
        </Field>
      </div>

      <Field
        label="Description"
        htmlFor={categoryFieldId("description")}
        hint="Optional. Up to 500 characters."
        error={err("description")}
      >
        <TextArea
          id={categoryFieldId("description")}
          rows={3}
          value={values.description}
          maxLength={500}
          disabled={pending}
          aria-invalid={err("description") ? true : undefined}
          aria-describedby={describedBy("description")}
          onChange={(event) => setValue("description", event.target.value)}
        />
      </Field>

      {category ? (
        <ImagePicker
          kind="category"
          targetId={category.id}
          currentUrl={category.image_url}
          invalidateKeys={[["admin", "categories"]]}
          onBusyChange={setImageBusy}
          disabled={pending}
        />
      ) : (
        <p className="text-xs text-muted-foreground">
          Save the category first, then you can add a picture.
        </p>
      )}

      <div className="flex items-center gap-3">
        <Switch
          id="category-active"
          checked={values.isActive}
          disabled={pending}
          onCheckedChange={(checked) => setValue("isActive", checked)}
          aria-describedby="category-active-hint"
        />
        <label htmlFor="category-active" className="text-sm font-medium">
          Active
        </label>
        <span
          id="category-active-hint"
          className="text-xs text-muted-foreground"
        >
          {values.isActive
            ? "Shown in the storefront."
            : "Hidden from the storefront. Nothing is deleted."}
        </span>
      </div>

      {serverError ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {serverError}
        </p>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <Button type="submit" disabled={pending || imageBusy}>
          {pending ? "Saving…" : editing ? "Save changes" : "Create category"}
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={pending}
          onClick={() => onDone(null)}
        >
          Cancel
        </Button>
      </div>

      <AlertDialog
        open={confirmHide}
        onOpenChange={(next) => {
          if (!pending) setConfirmHide(next);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Hide this category?</AlertDialogTitle>
            <AlertDialogDescription>
              “{category?.name}” will disappear from the storefront. Its
              products are not changed and nothing is deleted. You can switch it
              back on at any time.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={() => setConfirmHide(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="danger"
              disabled={pending}
              onClick={() => {
                setConfirmHide(false);
                save();
              }}
            >
              Hide category
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </form>
  );
}
