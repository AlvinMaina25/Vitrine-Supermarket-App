import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { CircleCheck, Trash2, TriangleAlert } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { ProductImage } from "@/components/catalog/product-image";
import {
  BrowseCta,
  CartSkeleton,
  EmptyState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { QuantityStepper } from "@/components/ui-kit/quantity-stepper";
import { useAuth } from "@/features/auth/auth-provider";
import {
  cartLineKey,
  useCart,
  type CartLine,
} from "@/features/cart/cart-provider";
import {
  cartSubtotalDisplay,
  clampMessage,
  lineBadge,
  lineMaxQuantity,
  lineStateFor,
  type LineState,
} from "@/features/cart/line-state";
import {
  cartValidationQuery,
  type CartIssue,
} from "@/features/cart/validation";
import { discountLabel } from "@/features/promotions/logic";
import { couponPreviewQuery } from "@/features/promotions/queries";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";
import { formatPrice } from "@/lib/format";

export const Route = createFileRoute("/cart")({
  head: () => ({
    meta: [
      { title: `Your basket — ${storeConfig.name}` },
      {
        name: "description",
        content: `Review the items in your ${storeConfig.name} basket.`,
      },
      { property: "og:title", content: `Your basket — ${storeConfig.name}` },
      {
        property: "og:description",
        content: "Review your basket before checkout.",
      },
    ],
  }),
  component: CartPage,
});

/** Same three fixes the checkout offers, using the same existing basket functions. */
function IssueRow({ issue }: { issue: CartIssue }) {
  const { setQuantity, remove, repriceLine } = useCart();
  const maxQuantity = issue.maxQuantity;
  const newPriceCents = issue.newPriceCents;
  return (
    <li
      role="alert"
      className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-(--radius-card) border border-danger/25 bg-danger/5 p-3 text-sm"
    >
      <TriangleAlert aria-hidden className="size-4 shrink-0 text-danger" />
      <span className="min-w-0 flex-1">{issue.message}</span>
      {newPriceCents !== undefined ? (
        <Button
          size="touch"
          variant="outline"
          onClick={() =>
            repriceLine(
              { productId: issue.productId, variantId: issue.variantId },
              newPriceCents,
            )
          }
        >
          Accept new price
        </Button>
      ) : null}
      {maxQuantity !== undefined ? (
        <Button
          size="touch"
          variant="outline"
          onClick={() =>
            setQuantity(issue.productId, maxQuantity, issue.variantId)
          }
        >
          Reduce to {maxQuantity}
        </Button>
      ) : null}
      {issue.kind !== "price_changed" && maxQuantity === undefined ? (
        <Button
          size="touch"
          variant="outline"
          onClick={() => remove(issue.productId, issue.variantId)}
        >
          Remove
        </Button>
      ) : null}
    </li>
  );
}

function CartLineItem({ line, state }: { line: CartLine; state: LineState }) {
  const { setQuantity, remove, restore } = useCart();
  const [hint, setHint] = useState<string | null>(null);
  const badge = lineBadge(state);
  const max = lineMaxQuantity(state);
  const hintId = `qty-hint-${cartLineKey(line.productId, line.variantId)}`;
  return (
    <li className="glass-panel grid grid-cols-[80px_1fr] gap-x-3 gap-y-2 rounded-(--radius-card) p-3 sm:grid-cols-[96px_1fr]">
      <ProductImage
        src={line.imageUrl}
        alt={line.name}
        className="size-20 rounded-md sm:size-24"
      />
      <div className="min-w-0">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            {line.slug ? (
              <Link
                to="/product/$slug"
                params={{ slug: line.slug }}
                className="flex min-h-11 items-center text-base leading-snug font-medium [overflow-wrap:anywhere] hover:underline"
              >
                {line.name}
              </Link>
            ) : (
              <span className="block text-base leading-snug font-medium [overflow-wrap:anywhere]">
                {line.name}
              </span>
            )}
            {line.variantName ? (
              <div className="text-xs text-muted-foreground">
                {line.variantName}
              </div>
            ) : null}
          </div>
          <span className="shrink-0 text-right">
            <span className="block text-base font-semibold tabular-nums">
              {formatPrice(line.priceCents)}
            </span>
            <span className="block text-xs text-muted-foreground">
              {line.unitLabel ?? "each"}
            </span>
          </span>
        </div>
        {badge ? (
          <p
            className={
              badge.tone === "ok"
                ? "mt-1 flex items-center gap-1.5 text-xs font-medium text-primary"
                : badge.tone === "danger"
                  ? "mt-1 flex items-center gap-1.5 text-xs font-medium text-danger"
                  : "mt-1 flex items-center gap-1.5 text-xs font-medium text-foreground"
            }
          >
            {badge.tone === "ok" ? (
              <CircleCheck aria-hidden className="size-3.5 shrink-0" />
            ) : (
              <TriangleAlert aria-hidden className="size-3.5 shrink-0" />
            )}
            <span>
              {badge.text}
              {state.kind === "price_changed"
                ? `: now ${formatPrice(state.newPriceCents)} each`
                : ""}
            </span>
          </p>
        ) : null}
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <QuantityStepper
            editable
            size="sm"
            min={1}
            max={max}
            value={line.quantity}
            label={line.name}
            onClamp={(requested, applied) =>
              setHint(
                clampMessage(requested, applied, {
                  min: 1,
                  max,
                  stockLimited: state.kind === "low_stock",
                }),
              )
            }
            onChange={(next) => {
              setHint(null);
              setQuantity(line.productId, next, line.variantId);
            }}
          />
          <button
            type="button"
            onClick={() => {
              remove(line.productId, line.variantId);
              toast(`${line.name} removed from your basket`, {
                action: { label: "Undo", onClick: () => restore(line) },
              });
            }}
            className="inline-flex min-h-11 items-center gap-1.5 rounded-full px-3 text-sm text-muted-foreground hover:text-danger"
          >
            <Trash2 aria-hidden className="size-4" />
            Remove
            <span className="sr-only"> {line.name}</span>
          </button>
        </div>
        <p
          id={hintId}
          role="status"
          className="mt-1 min-h-0 text-xs text-muted-foreground"
        >
          {hint}
        </p>
      </div>
    </li>
  );
}

function CartPage() {
  const { lines, itemCount, subtotalCents, hydrated } = useCart();
  const { user } = useAuth();

  const validation = useQuery({
    ...cartValidationQuery(lines),
    enabled: isSupabaseConfigured && hydrated && lines.length > 0,
  });
  // validate_coupon is available to signed-in customers only; guests simply see no offer line.
  const couponLines = useMemo(
    () =>
      lines.map((line) => ({
        productId: line.productId,
        variantId: line.variantId,
        quantity: line.quantity,
      })),
    [lines],
  );
  const offer = useQuery({
    ...couponPreviewQuery(couponLines, null, null),
    enabled:
      isSupabaseConfigured && hydrated && Boolean(user) && lines.length > 0,
  });
  const applied = offer.data?.status === "applied" ? offer.data : null;
  // undefined until the database has answered: no line is called "in stock" before that.
  const issues = validation.isSuccess ? validation.data : undefined;
  const serverSubtotalCents =
    offer.data && offer.data.status !== "rejected"
      ? offer.data.subtotalCents
      : null;
  const subtotal = cartSubtotalDisplay({
    serverSubtotalCents,
    serverPending: Boolean(user) && offer.isPending,
    savedPricesEstimateCents: subtotalCents,
  });

  if (!hydrated) {
    return (
      <section className="mx-auto max-w-[1400px] px-4 pt-6 pb-12 sm:px-5">
        <h1 className="mb-4 font-display text-2xl font-bold">Your basket</h1>
        <CartSkeleton />
      </section>
    );
  }

  if (lines.length === 0) {
    return (
      <section className="mx-auto max-w-2xl px-4 pt-8 pb-12 sm:px-5">
        <EmptyState
          title="Your basket is empty"
          message="Add something from the shelves and it'll appear here, ready for checkout."
          action={<BrowseCta />}
        />
      </section>
    );
  }

  return (
    <section className="mx-auto max-w-[1400px] px-4 pt-6 pb-12 sm:px-5">
      <div className="mb-4 flex items-baseline justify-between gap-3">
        <h1 className="font-display text-2xl font-bold sm:text-3xl">
          Your basket
        </h1>
        <span className="text-sm text-muted-foreground">
          {itemCount} {itemCount === 1 ? "item" : "items"}
        </span>
      </div>

      <div className="grid grid-cols-1 items-start gap-6 lg:grid-cols-[1fr_380px]">
        <div className="space-y-3">
          {issues && issues.length > 0 ? (
            <ul className="space-y-2">
              {issues.map((issue) => (
                <IssueRow key={issue.key} issue={issue} />
              ))}
            </ul>
          ) : null}
          {validation.isError ? (
            <div
              role="alert"
              className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-(--radius-card) border border-border p-3 text-sm"
            >
              <span className="min-w-0 flex-1">
                We couldn't check stock and prices just now. They are checked
                again at checkout.
              </span>
              <Button
                size="touch"
                variant="outline"
                onClick={() => void validation.refetch()}
              >
                Check again
              </Button>
            </div>
          ) : null}
          <ul className="space-y-3">
            {lines.map((line) => (
              <CartLineItem
                key={cartLineKey(line.productId, line.variantId)}
                line={line}
                state={lineStateFor(
                  cartLineKey(line.productId, line.variantId),
                  issues,
                )}
              />
            ))}
          </ul>
        </div>

        <aside
          aria-labelledby="summary-title"
          className="glass-panel rounded-(--radius-panel) p-5 lg:sticky lg:top-28"
        >
          <h2 id="summary-title" className="font-display text-lg font-bold">
            Order summary
          </h2>
          <dl className="mt-3 space-y-2 text-sm">
            <div className="flex justify-between">
              <dt>{subtotal.label}</dt>
              <dd className="font-medium tabular-nums">
                {subtotal.cents === null ? "—" : formatPrice(subtotal.cents)}
              </dd>
            </div>
            {applied ? (
              <div className="flex justify-between text-primary">
                <dt>
                  {discountLabel({ code: applied.code, name: applied.name })}
                </dt>
                <dd className="font-medium tabular-nums">
                  −{formatPrice(applied.discountCents)}
                </dd>
              </div>
            ) : null}
          </dl>
          <p className="mt-3 text-sm text-muted-foreground">
            {subtotal.estimated
              ? "This estimate uses the prices saved in your basket. "
              : ""}
            Delivery, any coupon code and the final total are confirmed at
            checkout.
          </p>

          {user ? (
            <Button asChild size="touchBlock" className="mt-4">
              <Link to="/checkout">Continue to checkout</Link>
            </Button>
          ) : (
            <>
              <Button asChild size="touchBlock" className="mt-4">
                <Link to="/auth" search={{ redirect: "/checkout" }}>
                  Sign in to check out
                </Link>
              </Button>
              <p className="mt-2 text-xs text-muted-foreground">
                Your basket is saved on this device while you sign in.
              </p>
            </>
          )}
          <Button asChild variant="ghost" size="touchBlock" className="mt-1">
            <Link to="/" search={{}}>
              Continue shopping
            </Link>
          </Button>
        </aside>
      </div>
    </section>
  );
}
