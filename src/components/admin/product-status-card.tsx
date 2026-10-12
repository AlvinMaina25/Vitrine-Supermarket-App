import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { toast } from "sonner";

import { ProductActiveBadge } from "@/components/admin/product-badges";
import { Button } from "@/components/ui-kit/button";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { describeProductActivationError } from "@/features/admin/product-management";
import { adminSetProductActive } from "@/features/admin/products";
import type { ProductRow } from "@/lib/supabase/types";

/**
 * Shows whether the product is active and offers the opposite action behind a confirmation.
 * The change goes through admin_set_product_active(), which sets is_active and nothing else
 * (stock, price and variants are untouched, and nothing is deleted). The database refuses anyone
 * who is not an admin; this card only decides what to render.
 *
 * `product` is always the stored row from the detail query, so after the mutation settles and
 * the queries are invalidated the badge and the button reflect what the database now holds.
 */
export function ProductStatusCard({ product }: { product: ProductRow }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const target = !product.is_active;

  const mutation = useMutation({
    mutationFn: adminSetProductActive,
    onSuccess: (result) => {
      setError(null);
      setOpen(false);
      toast.success(
        result.product.is_active
          ? `“${result.product.name}” is now active.`
          : `“${result.product.name}” is now inactive.`,
      );
    },
    onError: (cause) => {
      console.error("Product activation change failed", cause);
      setError(describeProductActivationError(cause, target));
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

  const pending = mutation.isPending;

  function confirm() {
    if (inFlight.current || pending) return;
    inFlight.current = true;
    setError(null);
    mutation.mutate({ productId: product.id, isActive: target });
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-3">
        <ProductActiveBadge active={product.is_active} />
        <span className="text-sm text-muted-foreground">
          {product.is_active
            ? "Customers can see and buy this product."
            : "Hidden from the storefront. Existing orders are not affected."}
        </span>
      </div>

      <Button
        type="button"
        variant={product.is_active ? "outline" : "primary"}
        disabled={pending}
        onClick={() => {
          setError(null);
          setOpen(true);
        }}
      >
        {pending
          ? "Saving…"
          : product.is_active
            ? "Deactivate product"
            : "Activate product"}
      </Button>

      {error && !open ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {error}
        </p>
      ) : null}

      <AlertDialog
        open={open}
        // The dialog cannot be dismissed while the change is being saved.
        onOpenChange={(next) => {
          if (!pending) setOpen(next);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {target ? "Activate this product?" : "Deactivate this product?"}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {target
                ? `“${product.name}” will become visible in the storefront and customers will be able to order it.`
                : `“${product.name}” will be hidden from the storefront and customers will no longer be able to order it. Existing orders, stock and variants are not changed, and nothing is deleted.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          {error ? (
            <p
              role="alert"
              className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
            >
              {error}
            </p>
          ) : null}
          <AlertDialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={() => setOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant={target ? "primary" : "danger"}
              disabled={pending}
              onClick={confirm}
            >
              {pending ? "Saving…" : target ? "Activate" : "Deactivate"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
