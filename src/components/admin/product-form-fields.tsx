import type { UseQueryResult } from "@tanstack/react-query";

import { Field, TextArea, TextInput } from "@/components/ui-kit/field";
import type {
  ProductFormErrors,
  ProductFormValues,
} from "@/features/admin/products-result";
import { storeConfig } from "@/lib/env";
import type { CategoryRow } from "@/lib/supabase/types";

const SELECT_CLASS =
  "w-full rounded-lg border border-border bg-background min-h-11 px-3 py-2 text-base text-foreground md:pointer-fine:text-sm focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

function FieldError({ id, message }: { id: string; message: string }) {
  return (
    <span id={id} role="alert" className="text-danger">
      {message}
    </span>
  );
}

export interface ProductFormFieldsProps {
  values: ProductFormValues;
  errors: ProductFormErrors;
  pending: boolean;
  onChange: <K extends keyof ProductFormValues>(
    key: K,
    value: ProductFormValues[K],
  ) => void;
  categories: UseQueryResult<CategoryRow[]>;
  /** Shown as "Current category" while the category list is still loading (edit form only). */
  currentCategoryId?: string | null;
  /** Marks name, slug and price as required (the create form). */
  showRequired?: boolean;
  /** Replaces the default slug hint. */
  slugHint?: string;
}

/**
 * The catalogue fields admin_create_product() / admin_update_product() accept, and nothing else:
 * name, URL slug, SKU, category, price, compare-at price, brand, unit label and description.
 * Stock, active status and the image are not editable here. Shared by the create and edit forms
 * so the two cannot drift apart. Checks are for usability; the database validates everything.
 */
export function ProductFormFields({
  values,
  errors,
  pending,
  onChange,
  categories,
  currentCategoryId = null,
  showRequired = false,
  slugHint = "Changing this changes the product's storefront address.",
}: ProductFormFieldsProps) {
  const err = (key: keyof ProductFormErrors) => errors[key];
  const hint = (key: keyof ProductFormErrors, fallback?: string) => {
    const message = err(key);
    if (message)
      return <FieldError id={`product-${key}-error`} message={message} />;
    return fallback;
  };
  const invalid = (key: keyof ProductFormErrors) =>
    err(key) ? true : undefined;
  const describedBy = (key: keyof ProductFormErrors) =>
    err(key) ? `product-${key}-error` : undefined;
  const req = showRequired ? " *" : "";

  return (
    <>
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <Field label={`Name${req}`} htmlFor="product-name" hint={hint("name")}>
          <TextInput
            id="product-name"
            value={values.name}
            maxLength={200}
            disabled={pending}
            aria-invalid={invalid("name")}
            aria-describedby={describedBy("name")}
            onChange={(event) => onChange("name", event.target.value)}
          />
        </Field>

        <Field
          label={`URL slug${req}`}
          htmlFor="product-slug"
          hint={hint("slug", slugHint)}
        >
          <TextInput
            id="product-slug"
            value={values.slug}
            maxLength={120}
            disabled={pending}
            spellCheck={false}
            aria-invalid={invalid("slug")}
            aria-describedby={describedBy("slug")}
            onChange={(event) => onChange("slug", event.target.value)}
          />
        </Field>

        <Field
          label="SKU"
          htmlFor="product-sku"
          hint={hint("sku", "Optional. Must be unique.")}
        >
          <TextInput
            id="product-sku"
            value={values.sku}
            maxLength={64}
            disabled={pending}
            spellCheck={false}
            aria-invalid={invalid("sku")}
            aria-describedby={describedBy("sku")}
            onChange={(event) => onChange("sku", event.target.value)}
          />
        </Field>

        <Field
          label="Category"
          htmlFor="product-category"
          hint={
            hint("category") ??
            (categories.isError
              ? "Categories couldn't be loaded; the category can't be chosen right now."
              : undefined)
          }
        >
          <select
            id="product-category"
            className={SELECT_CLASS}
            value={values.categoryId}
            disabled={pending || categories.isPending || categories.isError}
            aria-invalid={invalid("category")}
            aria-describedby={describedBy("category")}
            onChange={(event) => onChange("categoryId", event.target.value)}
          >
            <option value="">No category</option>
            {/* Keep the current category selectable even while the list loads or has failed. */}
            {categories.data === undefined && currentCategoryId ? (
              <option value={currentCategoryId}>Current category</option>
            ) : null}
            {(categories.data ?? []).map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
                {category.is_active ? "" : " (inactive)"}
              </option>
            ))}
          </select>
        </Field>

        <Field
          label={`Price (${storeConfig.currency})${req}`}
          htmlFor="product-price"
          hint={hint(
            "price",
            showRequired
              ? "Required. E.g. 250 or 250.50."
              : "Stored as whole cents, e.g. 250.50.",
          )}
        >
          <TextInput
            id="product-price"
            inputMode="decimal"
            value={values.price}
            disabled={pending}
            aria-invalid={invalid("price")}
            aria-describedby={describedBy("price")}
            onChange={(event) => onChange("price", event.target.value)}
          />
        </Field>

        <Field
          label={`Compare-at price (${storeConfig.currency})`}
          htmlFor="product-compare-at"
          hint={hint(
            "compareAt",
            "Optional. The “was” price; can't be below the price.",
          )}
        >
          <TextInput
            id="product-compare-at"
            inputMode="decimal"
            value={values.compareAt}
            disabled={pending}
            aria-invalid={invalid("compareAt")}
            aria-describedby={describedBy("compareAt")}
            onChange={(event) => onChange("compareAt", event.target.value)}
          />
        </Field>

        <Field label="Brand" htmlFor="product-brand" hint={hint("brand")}>
          <TextInput
            id="product-brand"
            value={values.brand}
            maxLength={100}
            disabled={pending}
            aria-invalid={invalid("brand")}
            aria-describedby={describedBy("brand")}
            onChange={(event) => onChange("brand", event.target.value)}
          />
        </Field>

        <Field
          label="Unit label"
          htmlFor="product-unit"
          hint={hint("unitLabel", "How it is sold, e.g. “500 g” or “each”.")}
        >
          <TextInput
            id="product-unit"
            value={values.unitLabel}
            maxLength={40}
            disabled={pending}
            aria-invalid={invalid("unitLabel")}
            aria-describedby={describedBy("unitLabel")}
            onChange={(event) => onChange("unitLabel", event.target.value)}
          />
        </Field>
      </div>

      <Field
        label="Description"
        htmlFor="product-description"
        hint={hint("description")}
      >
        <TextArea
          id="product-description"
          rows={5}
          value={values.description}
          maxLength={4000}
          disabled={pending}
          aria-invalid={invalid("description")}
          aria-describedby={describedBy("description")}
          onChange={(event) => onChange("description", event.target.value)}
        />
      </Field>
    </>
  );
}
