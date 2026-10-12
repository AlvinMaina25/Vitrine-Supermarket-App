import { firstErrorField } from "@/features/admin/admin-ui";

/**
 * Moves keyboard focus to the first field (in screen order) that has an error, so a failed submit
 * lands the person on the problem instead of leaving focus on the submit button. `idFor` maps a
 * field key to the id of its input. The ordering rule is the tested pure firstErrorField().
 */
export function focusFirstError<K extends string>(
  errors: Partial<Record<K, string | null | undefined>>,
  order: readonly K[],
  idFor: (key: K) => string,
): void {
  const key = firstErrorField(errors, order);
  if (key !== null) document.getElementById(idFor(key))?.focus();
}

/**
 * Moves focus to the first control marked aria-invalid (in DOM order) once React has rendered the
 * errors. Looks inside the open dialog when there is one, so a failed dialog submit never sends
 * focus to the page behind it. Used by forms whose field ids are not a fixed list.
 */
export function focusFirstInvalid(): void {
  if (typeof document === "undefined") return;
  window.setTimeout(() => {
    const root =
      document.querySelector('[role="alertdialog"], [role="dialog"]') ??
      document;
    root.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
  }, 0);
}

/** Screen order and input ids of the product form fields (shared by create and edit). */
export const PRODUCT_FIELD_ORDER = [
  "name",
  "slug",
  "sku",
  "category",
  "price",
  "compareAt",
  "brand",
  "unitLabel",
  "description",
] as const;

export const productFieldId = (key: string) =>
  key === "compareAt"
    ? "product-compare-at"
    : key === "unitLabel"
      ? "product-unit"
      : `product-${key}`;
