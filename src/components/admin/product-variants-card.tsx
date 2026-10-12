import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { ProductActiveBadge } from "@/components/admin/product-badges";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  describeProductSaveError,
  saveErrorField,
} from "@/features/admin/product-management";
import { focusFirstInvalid } from "@/components/admin/focus-first-error";
import { adminAdjustInventory } from "@/features/admin/inventory";
import {
  OPENING_STOCK_REASON,
  runCreateWithExtras,
  type CreateExtras,
} from "@/features/admin/product-create-plan";
import {
  adminCreateProductVariant,
  adminUpdateProductVariant,
} from "@/features/admin/products";
import {
  buildVariantChanges,
  hasChanges,
  variantToFormValues,
  type VariantFormErrors,
  type VariantFormValues,
} from "@/features/admin/products-result";
import {
  buildNewVariant,
  describePartialVariant,
  emptyNewVariantValues,
  nextVariantPosition,
  type NewVariantFormErrors,
  type NewVariantFormValues,
} from "@/features/admin/variant-create-plan";
import { storeConfig } from "@/lib/env";
import { formatPrice } from "@/lib/format";
import type {
  AdminCreateProductVariantArgs,
  ProductVariantRow,
} from "@/lib/supabase/types";
import { Switch } from "@/components/ui/switch";

/**
 * The product's variants as stored (inactive ones included). Catalogue fields of an existing
 * variant, including Active on/off, can be edited through admin_update_product_variant(); its
 * stock is shown read-only. New variants are added with the "Add variant" dialog (Phase 21).
 */
export function ProductVariantsCard({
  productId,
  variants,
}: {
  productId: string;
  variants: ProductVariantRow[];
}) {
  const [editing, setEditing] = useState<ProductVariantRow | null>(null);
  const [adding, setAdding] = useState(false);

  const addButton = (
    <Button type="button" size="sm" onClick={() => setAdding(true)}>
      Add variant
    </Button>
  );
  const addDialog = adding ? (
    <VariantAddDialog
      productId={productId}
      usedPositions={variants.map((variant) => variant.position)}
      onClose={() => setAdding(false)}
    />
  ) : null;

  if (variants.length === 0) {
    return (
      <>
        <p className="mb-3 text-sm text-muted-foreground">
          This product has no variants.
        </p>
        {addButton}
        {addDialog}
      </>
    );
  }

  return (
    <>
      <div className="mb-3">{addButton}</div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Variant</TableHead>
            <TableHead>SKU</TableHead>
            <TableHead className="text-right">Price</TableHead>
            <TableHead className="text-right">Compare-at</TableHead>
            <TableHead className="text-right">Stock</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="text-right">
              <span className="sr-only">Actions</span>
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {variants.map((variant) => (
            <TableRow key={variant.id}>
              <TableCell className="font-medium">{variant.name}</TableCell>
              <TableCell className="font-mono text-xs">
                {variant.sku ?? "—"}
              </TableCell>
              <TableCell className="text-right font-mono text-xs whitespace-nowrap">
                {formatPrice(variant.price_cents)}
              </TableCell>
              <TableCell className="text-right font-mono text-xs whitespace-nowrap">
                {variant.compare_at_price_cents === null
                  ? "—"
                  : formatPrice(variant.compare_at_price_cents)}
              </TableCell>
              <TableCell className="text-right font-mono text-xs">
                {variant.stock_quantity}
              </TableCell>
              <TableCell>
                <ProductActiveBadge active={variant.is_active} />
              </TableCell>
              <TableCell className="text-right">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setEditing(variant)}
                >
                  Edit
                  <span className="sr-only"> {variant.name}</span>
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className="mt-3 text-xs text-muted-foreground">
        Stock is shown for reference. Change it on the Inventory screen.
      </p>

      {addDialog}
      {editing ? (
        <VariantEditDialog
          key={editing.id}
          variant={editing}
          onClose={() => setEditing(null)}
        />
      ) : null}
    </>
  );
}

function VariantEditDialog({
  variant,
  onClose,
}: {
  variant: ProductVariantRow;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const initial = variantToFormValues(variant);
  const [values, setValues] = useState<VariantFormValues>(initial);
  const [errors, setErrors] = useState<VariantFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const dirty = (Object.keys(values) as (keyof VariantFormValues)[]).some(
    (key) => values[key] !== initial[key],
  );

  const mutation = useMutation({
    mutationFn: adminUpdateProductVariant,
    onSuccess: (result) => {
      toast.success(`Saved variant “${result.variant.name}”.`);
      onClose();
    },
    onError: (cause) => {
      console.error("Variant update failed", cause);
      const message = describeProductSaveError(cause);
      const field = saveErrorField(cause);
      if (field && field in values) {
        setErrors({ [field]: message });
        setServerError(null);
        focusFirstInvalid();
      } else {
        setServerError(message);
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ["admin", "product", variant.product_id],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "products"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "inventory"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
        queryClient.invalidateQueries({ queryKey: ["products"] }),
        queryClient.invalidateQueries({ queryKey: ["product"] }),
      ]);
    },
  });

  function setValue<K extends keyof VariantFormValues>(
    key: K,
    value: VariantFormValues[K],
  ) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => {
      if (!(key in prev)) return prev;
      const { [key as keyof VariantFormErrors]: _removed, ...rest } = prev;
      return rest;
    });
    setServerError(null);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (inFlight.current || mutation.isPending) return;

    const result = buildVariantChanges(variant, initial, values);
    setServerError(null);
    if (Object.keys(result.errors).length > 0) {
      setErrors(result.errors);
      focusFirstInvalid();
      return;
    }
    if (!hasChanges(result.changes)) {
      onClose();
      return;
    }
    setErrors({});
    inFlight.current = true;
    mutation.mutate({ variantId: variant.id, changes: result.changes });
  }

  const pending = mutation.isPending;
  const message = (key: keyof VariantFormErrors, fallback?: string) => {
    const error = errors[key];
    if (error) {
      return (
        <span id={`variant-${key}-error`} role="alert" className="text-danger">
          {error}
        </span>
      );
    }
    return fallback;
  };
  const invalid = (key: keyof VariantFormErrors) =>
    errors[key] ? true : undefined;
  const describedBy = (key: keyof VariantFormErrors) =>
    errors[key] ? `variant-${key}-error` : undefined;

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        // Don't let the dialog close under an in-flight save.
        if (!open && !pending) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit variant</DialogTitle>
          <DialogDescription>
            Name, SKU, prices, display position and whether customers can see
            it. Stock can't be changed here.
          </DialogDescription>
        </DialogHeader>

        <form
          onSubmit={submit}
          noValidate
          aria-busy={pending}
          className="space-y-4"
        >
          <Field label="Name" htmlFor="variant-name" hint={message("name")}>
            <TextInput
              id="variant-name"
              value={values.name}
              maxLength={200}
              disabled={pending}
              aria-invalid={invalid("name")}
              aria-describedby={describedBy("name")}
              onChange={(event) => setValue("name", event.target.value)}
            />
          </Field>
          <Field
            label="SKU"
            htmlFor="variant-sku"
            hint={message("sku", "Optional. Must be unique among variants.")}
          >
            <TextInput
              id="variant-sku"
              value={values.sku}
              maxLength={64}
              disabled={pending}
              spellCheck={false}
              aria-invalid={invalid("sku")}
              aria-describedby={describedBy("sku")}
              onChange={(event) => setValue("sku", event.target.value)}
            />
          </Field>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field
              label={`Price (${storeConfig.currency})`}
              htmlFor="variant-price"
              hint={message("price")}
            >
              <TextInput
                id="variant-price"
                inputMode="decimal"
                value={values.price}
                disabled={pending}
                aria-invalid={invalid("price")}
                aria-describedby={describedBy("price")}
                onChange={(event) => setValue("price", event.target.value)}
              />
            </Field>
            <Field
              label={`Compare-at (${storeConfig.currency})`}
              htmlFor="variant-compare-at"
              hint={message("compareAt", "Optional.")}
            >
              <TextInput
                id="variant-compare-at"
                inputMode="decimal"
                value={values.compareAt}
                disabled={pending}
                aria-invalid={invalid("compareAt")}
                aria-describedby={describedBy("compareAt")}
                onChange={(event) => setValue("compareAt", event.target.value)}
              />
            </Field>
          </div>
          <Field
            label="Position"
            htmlFor="variant-position"
            hint={message("position", "Lower numbers are listed first.")}
          >
            <TextInput
              id="variant-position"
              inputMode="numeric"
              value={values.position}
              disabled={pending}
              aria-invalid={invalid("position")}
              aria-describedby={describedBy("position")}
              onChange={(event) => setValue("position", event.target.value)}
            />
          </Field>
          <div className="flex items-center gap-3">
            <Switch
              id="variant-active"
              checked={values.active}
              disabled={pending}
              onCheckedChange={(checked) => setValue("active", checked)}
              aria-describedby="variant-active-hint"
            />
            <label htmlFor="variant-active" className="text-sm font-medium">
              Active
            </label>
            <span
              id="variant-active-hint"
              className="text-xs text-muted-foreground"
            >
              {values.active
                ? "Customers can choose it."
                : "Hidden from the storefront."}
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

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={onClose}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={pending || !dirty}>
              {pending ? "Saving…" : "Save variant"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

const ADD_FIELD_IDS = {
  name: "new-variant-name",
  sku: "new-variant-sku",
  price: "new-variant-price",
  compareAt: "new-variant-compare-at",
  stock: "new-variant-stock",
} as const;

interface AddVariantInput {
  args: AdminCreateProductVariantArgs;
  extras: CreateExtras;
  again: boolean;
}

function VariantAddDialog({
  productId,
  usedPositions,
  onClose,
}: {
  productId: string;
  usedPositions: number[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [values, setValues] = useState<NewVariantFormValues>(
    emptyNewVariantValues,
  );
  const [errors, setErrors] = useState<NewVariantFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const inFlight = useRef(false);
  // Positions this dialog has used itself, so "Save and add another" does not wait for a refetch.
  const created = useRef<number[]>([]);

  const mutation = useMutation({
    mutationFn: (input: AddVariantInput) =>
      runCreateWithExtras(input.extras, {
        create: () => adminCreateProductVariant(input.args),
        idOf: (result) => result.variant.id,
        adjustStock: (variantId, quantity) =>
          adminAdjustInventory({
            p_product_id: productId,
            p_variant_id: variantId,
            p_adjustment_quantity: quantity,
            p_reason: OPENING_STOCK_REASON,
          }),
        deactivate: (variantId) =>
          adminUpdateProductVariant({
            variantId,
            changes: { is_active: false },
          }),
        onStepError: (step, cause) =>
          console.error(`Variant follow-up step failed: ${step}`, cause),
      }),
    onSuccess: (result, input) => {
      const name = result.product.variant.name;
      created.current.push(result.product.variant.position);
      const partial = describePartialVariant(name, result.failed);
      if (partial !== null) toast.warning(partial, { duration: 15_000 });
      else toast.success(`Added variant “${name}”.`);
      if (input.again) {
        setValues(emptyNewVariantValues());
        setErrors({});
        setServerError(null);
        window.setTimeout(
          () => document.getElementById(ADD_FIELD_IDS.name)?.focus(),
          0,
        );
      } else {
        onClose();
      }
    },
    onError: (cause) => {
      console.error("Variant create failed", cause);
      const message = describeProductSaveError(cause);
      const field = saveErrorField(cause);
      if (field && field in ADD_FIELD_IDS) {
        setErrors({ [field]: message });
        setServerError(null);
        focusFirstInvalid();
      } else {
        setServerError(message);
      }
    },
    onSettled: async () => {
      inFlight.current = false;
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ["admin", "product", productId],
        }),
        queryClient.invalidateQueries({ queryKey: ["admin", "products"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "inventory"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
        queryClient.invalidateQueries({ queryKey: ["products"] }),
        queryClient.invalidateQueries({ queryKey: ["product"] }),
        queryClient.invalidateQueries({ queryKey: ["product-variants"] }),
        queryClient.invalidateQueries({ queryKey: ["variant-summary"] }),
      ]);
    },
  });

  function setValue<K extends keyof NewVariantFormValues>(
    key: K,
    value: NewVariantFormValues[K],
  ) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => {
      if (!(key in prev)) return prev;
      const { [key as keyof NewVariantFormErrors]: _removed, ...rest } = prev;
      return rest;
    });
    setServerError(null);
  }

  function submit(again: boolean) {
    if (inFlight.current || mutation.isPending) return;
    const built = buildNewVariant(
      productId,
      values,
      nextVariantPosition([...usedPositions, ...created.current]),
    );
    setServerError(null);
    if (!built.ok) {
      setErrors(built.errors);
      focusFirstInvalid();
      return;
    }
    setErrors({});
    inFlight.current = true;
    mutation.mutate({ args: built.args, extras: built.extras, again });
  }

  const pending = mutation.isPending;
  const message = (key: keyof NewVariantFormErrors, fallback?: string) => {
    const error = errors[key];
    if (error) {
      return (
        <span
          id={`${ADD_FIELD_IDS[key]}-error`}
          role="alert"
          className="text-danger"
        >
          {error}
        </span>
      );
    }
    return fallback;
  };
  const invalid = (key: keyof NewVariantFormErrors) =>
    errors[key] ? true : undefined;
  const describedBy = (key: keyof NewVariantFormErrors) =>
    errors[key] ? `${ADD_FIELD_IDS[key]}-error` : undefined;

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        // Don't let the dialog close under an in-flight save.
        if (!open && !pending) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add variant</DialogTitle>
          <DialogDescription>
            For example “1 L” or “500 ml”. Starting stock is recorded as
            “Opening stock”.
          </DialogDescription>
        </DialogHeader>

        <form
          onSubmit={(event) => {
            event.preventDefault();
            submit(false);
          }}
          noValidate
          aria-busy={pending}
          className="space-y-4"
        >
          <Field
            label="Name"
            htmlFor={ADD_FIELD_IDS.name}
            hint={message("name")}
          >
            <TextInput
              id={ADD_FIELD_IDS.name}
              value={values.name}
              maxLength={200}
              autoComplete="off"
              disabled={pending}
              aria-invalid={invalid("name")}
              aria-describedby={describedBy("name")}
              onChange={(event) => setValue("name", event.target.value)}
            />
          </Field>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field
              label={`Price (${storeConfig.currency})`}
              htmlFor={ADD_FIELD_IDS.price}
              hint={message("price")}
            >
              <TextInput
                id={ADD_FIELD_IDS.price}
                inputMode="decimal"
                autoComplete="off"
                value={values.price}
                disabled={pending}
                aria-invalid={invalid("price")}
                aria-describedby={describedBy("price")}
                onChange={(event) => setValue("price", event.target.value)}
              />
            </Field>
            <Field
              label={`Compare-at (${storeConfig.currency})`}
              htmlFor={ADD_FIELD_IDS.compareAt}
              hint={message("compareAt", "Optional.")}
            >
              <TextInput
                id={ADD_FIELD_IDS.compareAt}
                inputMode="decimal"
                autoComplete="off"
                value={values.compareAt}
                disabled={pending}
                aria-invalid={invalid("compareAt")}
                aria-describedby={describedBy("compareAt")}
                onChange={(event) => setValue("compareAt", event.target.value)}
              />
            </Field>
          </div>
          <Field
            label="SKU"
            htmlFor={ADD_FIELD_IDS.sku}
            hint={message("sku", "Optional. Must be unique among variants.")}
          >
            <TextInput
              id={ADD_FIELD_IDS.sku}
              value={values.sku}
              maxLength={64}
              autoComplete="off"
              spellCheck={false}
              disabled={pending}
              aria-invalid={invalid("sku")}
              aria-describedby={describedBy("sku")}
              onChange={(event) => setValue("sku", event.target.value)}
            />
          </Field>
          <Field
            label="Starting stock"
            htmlFor={ADD_FIELD_IDS.stock}
            hint={message("stock", "Whole number, 0 or more. Blank means 0.")}
          >
            <TextInput
              id={ADD_FIELD_IDS.stock}
              inputMode="numeric"
              autoComplete="off"
              value={values.stock}
              disabled={pending}
              aria-invalid={invalid("stock")}
              aria-describedby={describedBy("stock")}
              onChange={(event) => setValue("stock", event.target.value)}
            />
          </Field>
          <div className="flex items-center gap-3">
            <Switch
              id="new-variant-active"
              checked={values.active}
              disabled={pending}
              onCheckedChange={(checked) => setValue("active", checked)}
              aria-describedby="new-variant-active-hint"
            />
            <label htmlFor="new-variant-active" className="text-sm font-medium">
              Active
            </label>
            <span
              id="new-variant-active-hint"
              className="text-xs text-muted-foreground"
            >
              {values.active
                ? "Customers can choose it."
                : "Hidden from the storefront."}
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

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={onClose}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={() => submit(true)}
            >
              {pending && mutation.variables?.again
                ? "Saving…"
                : "Save and add another"}
            </Button>
            <Button type="submit" disabled={pending}>
              {pending && !mutation.variables?.again
                ? "Saving…"
                : "Add variant"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
