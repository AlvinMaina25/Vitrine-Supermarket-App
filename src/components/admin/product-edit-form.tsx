import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  focusFirstError,
  PRODUCT_FIELD_ORDER,
  productFieldId,
} from "@/components/admin/focus-first-error";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui-kit/button";
import { ImagePicker } from "@/components/admin/image-picker";
import { ProductFormFields } from "@/components/admin/product-form-fields";
import { categoriesQuery } from "@/features/catalog/queries";
import {
  describeProductSaveError,
  saveErrorField,
} from "@/features/admin/product-management";
import { adminUpdateProduct } from "@/features/admin/products";
import {
  buildProductChanges,
  hasChanges,
  productToFormValues,
  type ProductFormErrors,
  type ProductFormValues,
} from "@/features/admin/products-result";
import type { ProductRow } from "@/lib/supabase/types";

/**
 * Edits the catalogue fields admin_update_product() accepts: name, URL slug, category,
 * description, brand, SKU, price, compare-at price and unit label. Stock and active status are NOT
 * editable here and are never sent. The picture has its own ImagePicker (Phase 20B) that saves
 * through admin_set_product_image(), never through the text-field PATCH.
 *
 * Only the fields the admin actually changed are sent (a PATCH). The checks in this form are for
 * usability; the database validates everything again and its refusal is shown as a generic,
 * field-level message, never as raw database text.
 */
export function ProductEditForm({ product }: { product: ProductRow }) {
  const queryClient = useQueryClient();
  const categories = useQuery(categoriesQuery());

  // What the form was loaded from. Replaced by the stored row after a successful save.
  const [baseline, setBaseline] = useState<ProductRow>(product);
  const initial = productToFormValues(baseline);
  const [values, setValues] = useState<ProductFormValues>(initial);
  const [errors, setErrors] = useState<ProductFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  // True while the picture is being saved; the picture saves separately from the text fields.
  const [imageBusy, setImageBusy] = useState(false);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const dirty = (Object.keys(values) as (keyof ProductFormValues)[]).some(
    (key) => values[key] !== initial[key],
  );

  // Someone else saved this product after the form was loaded (never true for our own save:
  // that moves the baseline forward first).
  const changedElsewhere =
    Date.parse(product.updated_at) > Date.parse(baseline.updated_at);

  const mutation = useMutation({
    mutationFn: adminUpdateProduct,
    onSuccess: (result) => {
      setBaseline(result.product);
      setValues(productToFormValues(result.product));
      setErrors({});
      setServerError(null);
      toast.success(`Saved “${result.product.name}”.`);
    },
    onError: (cause) => {
      console.error("Product update failed", cause);
      const message = describeProductSaveError(cause);
      const field = saveErrorField(cause);
      if (field && field in values) {
        setErrors({ [field]: message });
        setServerError(null);
      } else {
        setServerError(message);
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      // Success or refusal, show what the database now holds.
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ["admin", "product", product.id],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "products"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "inventory"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
        // The storefront reads the same rows; keep any cached copy honest.
        queryClient.invalidateQueries({ queryKey: ["products"] }),
        queryClient.invalidateQueries({ queryKey: ["product"] }),
      ]);
    },
  });

  function setValue<K extends keyof ProductFormValues>(
    key: K,
    value: ProductFormValues[K],
  ) {
    setValues((prev) => ({ ...prev, [key]: value }));
    // Editing a field clears its own message; the rest stay until the next submit.
    setErrors((prev) => {
      if (!(key in prev)) return prev;
      const { [key as keyof ProductFormErrors]: _removed, ...rest } = prev;
      return rest;
    });
    setServerError(null);
  }

  function reset(next: ProductRow) {
    setBaseline(next);
    setValues(productToFormValues(next));
    setErrors({});
    setServerError(null);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (inFlight.current || mutation.isPending) return;

    const result = buildProductChanges(baseline, initial, values);
    setServerError(null);
    if (Object.keys(result.errors).length > 0) {
      setErrors(result.errors);
      focusFirstError(result.errors, PRODUCT_FIELD_ORDER, productFieldId);
      return;
    }
    if (!hasChanges(result.changes)) {
      setErrors({});
      toast.info("Nothing to save: no fields were changed.");
      return;
    }
    setErrors({});
    inFlight.current = true;
    mutation.mutate({ productId: baseline.id, changes: result.changes });
  }

  const pending = mutation.isPending;
  return (
    <form
      onSubmit={submit}
      noValidate
      aria-busy={pending}
      className="space-y-5"
    >
      {changedElsewhere ? (
        <div
          role="status"
          className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-surface-strong px-3 py-2 text-sm"
        >
          <span>This product was changed elsewhere after you opened it.</span>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={pending}
            onClick={() => reset(product)}
          >
            Discard my edits and load latest
          </Button>
        </div>
      ) : null}

      <ImagePicker
        kind="product"
        targetId={product.id}
        currentUrl={baseline.image_url}
        invalidateKeys={[
          ["admin", "product", product.id],
          ["admin", "products"],
        ]}
        // Only the picture and the stamp move, so unsaved text edits stay exactly as they are and
        // our own picture change is not reported as "changed elsewhere".
        onSaved={(saved) =>
          setBaseline((prev) => ({
            ...prev,
            image_url: saved.image_url,
            updated_at: saved.updated_at,
          }))
        }
        onBusyChange={setImageBusy}
        disabled={pending}
      />

      <ProductFormFields
        values={values}
        errors={errors}
        pending={pending}
        onChange={setValue}
        categories={categories}
        currentCategoryId={baseline.category_id}
      />

      {serverError ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {serverError}
        </p>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <Button type="submit" disabled={pending || imageBusy || !dirty}>
          {pending ? "Saving…" : "Save changes"}
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={pending || !dirty}
          onClick={() => reset(baseline)}
        >
          Reset
        </Button>
        {dirty && !pending ? (
          <span className="text-xs text-muted-foreground">
            You have unsaved changes.
          </span>
        ) : null}
      </div>
    </form>
  );
}
