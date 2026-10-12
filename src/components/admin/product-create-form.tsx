import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  focusFirstError,
  PRODUCT_FIELD_ORDER,
  productFieldId,
} from "@/components/admin/focus-first-error";
import { Link, useNavigate } from "@tanstack/react-router";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { ProductFormFields } from "@/components/admin/product-form-fields";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import { Switch } from "@/components/ui/switch";
import {
  describeProductSaveError,
  saveErrorField,
} from "@/features/admin/product-management";
import { adminAdjustInventory } from "@/features/admin/inventory";
import {
  describePartialCreate,
  OPENING_STOCK_REASON,
  parseStartingStock,
  runCreateWithExtras,
  type CreateExtras,
} from "@/features/admin/product-create-plan";
import {
  adminCreateProduct,
  adminSetProductActive,
} from "@/features/admin/products";
import {
  buildCreateProductArgs,
  emptyProductFormValues,
  slugifyName,
  type ProductFormErrors,
  type ProductFormValues,
} from "@/features/admin/products-result";
import { categoriesQuery } from "@/features/catalog/queries";

/**
 * Creates one product through admin_create_product(). Name, URL slug and price are required;
 * everything else is optional. That function takes no stock, active status or image, so it is
 * unchanged and the two extra fields below chain existing functions after it (Phase 20C):
 * admin_adjust_inventory ("Opening stock") when stock is above 0, then admin_set_product_active
 * (false) when Active is off. If a later step fails the product is kept and the person is told.
 * The picture is added from the product page after creation.
 *
 * The checks here are for usability. The database validates everything again; its refusals are
 * shown as field-level messages (duplicate slug / SKU, unknown category, invalid value) and
 * never as raw database text. Authorisation is the database's (require_admin()).
 */
export function ProductCreateForm() {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const categories = useQuery(categoriesQuery());

  const [values, setValues] = useState<ProductFormValues>(
    emptyProductFormValues,
  );
  const [errors, setErrors] = useState<ProductFormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  // Until the admin types in the slug box themselves, it follows the name.
  const [slugEdited, setSlugEdited] = useState(false);
  // Set after a successful create so nothing can be submitted twice while we navigate away.
  const [created, setCreated] = useState(false);
  // Phase 20C: kept apart from ProductFormValues (which is all text for the product row itself).
  const [stockText, setStockText] = useState("0");
  const [stockError, setStockError] = useState<string | null>(null);
  const [active, setActive] = useState(true);
  // Set when the product exists but a follow-up step did not complete.
  const [partial, setPartial] = useState<{
    productId: string;
    message: string;
  } | null>(null);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const mutation = useMutation({
    mutationFn: (input: {
      args: Parameters<typeof adminCreateProduct>[0];
      extras: CreateExtras;
    }) =>
      runCreateWithExtras(input.extras, {
        create: () => adminCreateProduct(input.args),
        idOf: (created) => created.product.id,
        adjustStock: (productId, quantity) =>
          adminAdjustInventory({
            p_product_id: productId,
            p_adjustment_quantity: quantity,
            p_reason: OPENING_STOCK_REASON,
          }),
        deactivate: (productId) =>
          adminSetProductActive({ productId, isActive: false }),
        onStepError: (step, cause) =>
          console.error(`Product follow-up step failed: ${step}`, cause),
      }),
    onSuccess: async ({ product: result, failed }) => {
      setCreated(true);
      setErrors({});
      setServerError(null);
      // The new row must show up in the list, the dashboard counts and the storefront caches.
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["admin", "products"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "inventory"] }),
        queryClient.invalidateQueries({ queryKey: ["admin", "dashboard"] }),
        queryClient.invalidateQueries({ queryKey: ["products"] }),
      ]);
      const message = describePartialCreate(failed);
      if (message !== null) {
        // Stay here so the message is not lost; the link opens the product.
        setPartial({ productId: result.product.id, message });
        return;
      }
      toast.success(`Created “${result.product.name}”.`);
      await navigate({
        to: "/admin/products/$productId",
        params: { productId: result.product.id },
      });
    },
    onError: (cause) => {
      console.error("Product creation failed", cause);
      const message = describeProductSaveError(cause);
      const field = saveErrorField(cause);
      if (field && field in values) {
        setErrors({ [field]: message });
        setServerError(null);
      } else {
        setServerError(message);
      }
      inFlight.current = false;
    },
  });

  function setValue<K extends keyof ProductFormValues>(
    key: K,
    value: ProductFormValues[K],
  ) {
    setValues((prev) => {
      const next = { ...prev, [key]: value };
      if (key === "name" && !slugEdited) next.slug = slugifyName(String(value));
      return next;
    });
    if (key === "slug") setSlugEdited(true);
    // Editing a field clears its own message (and the slug's, if it follows the name).
    setErrors((prev) => {
      const next: ProductFormErrors = { ...prev };
      delete next[key as keyof ProductFormErrors];
      if (key === "name" && !slugEdited) delete next.slug;
      return next;
    });
    setServerError(null);
  }

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (inFlight.current || mutation.isPending || created) return;

    const result = buildCreateProductArgs(values);
    const stock = parseStartingStock(stockText);
    setServerError(null);
    setStockError(stock.ok ? null : stock.message);
    if (result.args === null || !stock.ok) {
      setErrors(result.errors);
      focusFirstError<string>(
        { ...result.errors, stock: stock.ok ? null : stock.message },
        [...PRODUCT_FIELD_ORDER, "stock"],
        productFieldId,
      );
      return;
    }
    setErrors({});
    inFlight.current = true;
    mutation.mutate({
      args: result.args,
      extras: { stock: stock.value, active },
    });
  }

  const busy = mutation.isPending || created;

  return (
    <form onSubmit={submit} noValidate aria-busy={busy} className="space-y-5">
      <p className="text-xs text-muted-foreground">
        Fields marked * are required. Set the starting stock and whether the
        product is active below. You can add a picture from the product page
        after it is created.
      </p>

      <ProductFormFields
        values={values}
        errors={errors}
        pending={busy}
        onChange={setValue}
        categories={categories}
        showRequired
        slugHint="Lower-case letters, digits and hyphens. Filled in from the name; you can change it."
      />

      <Field
        label="Starting stock"
        htmlFor="product-stock"
        hint="Whole number, 0 or more. Recorded as “Opening stock”."
        error={stockError}
      >
        <TextInput
          id="product-stock"
          inputMode="numeric"
          autoComplete="off"
          value={stockText}
          disabled={busy}
          aria-invalid={stockError ? true : undefined}
          aria-describedby={stockError ? "product-stock-error" : undefined}
          onChange={(event) => {
            setStockText(event.target.value);
            setStockError(null);
          }}
        />
      </Field>

      <div className="flex items-center gap-3">
        <Switch
          id="product-active"
          checked={active}
          disabled={busy}
          onCheckedChange={setActive}
          aria-describedby="product-active-hint"
        />
        <label htmlFor="product-active" className="text-sm font-medium">
          Active
        </label>
        <span
          id="product-active-hint"
          className="text-xs text-muted-foreground"
        >
          {active
            ? "Visible in the storefront."
            : "Hidden from the storefront until you activate it."}
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

      {partial ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {partial.message}{" "}
          <Link
            to="/admin/products/$productId"
            params={{ productId: partial.productId }}
            className="font-medium underline"
          >
            Open the product
          </Link>
        </p>
      ) : created ? (
        <p role="status" className="text-sm text-primary">
          Product created. Opening it…
        </p>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <Button type="submit" disabled={busy}>
          {created
            ? "Created"
            : mutation.isPending
              ? "Creating…"
              : "Create product"}
        </Button>
        {busy ? (
          <Button type="button" variant="outline" disabled>
            Cancel
          </Button>
        ) : (
          <Button asChild variant="outline">
            <Link to="/admin/products" search={{}}>
              Cancel
            </Link>
          </Button>
        )}
      </div>
    </form>
  );
}
