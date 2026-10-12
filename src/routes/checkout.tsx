import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  createFileRoute,
  Link,
  redirect,
  useNavigate,
} from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import {
  BrowseCta,
  EmptyState,
  ErrorState,
  QueryErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { Field, TextArea } from "@/components/ui-kit/field";
import { addressesQuery } from "@/features/account/queries";
import { cartLineKey, useCart } from "@/features/cart/cart-provider";
import {
  cartValidationQuery,
  type CartIssue,
} from "@/features/cart/validation";
import {
  isProviderSelectable,
  PAYMENT_PROVIDERS,
  paymentProvider,
} from "@/features/checkout/payment-providers";
import {
  buildQuoteRequest,
  buildSlotChoices,
  deliveryErrorMessage,
  deliveryErrorScope,
  deriveQuoteState,
  quoteBlockerMessage,
  resolveSelectedSlot,
  resolveZoneId,
  selectableZones,
  slotDateRange,
  visibleSlotChoices,
  zoneRequirement,
  isSlotSelectable,
  type SlotChoice,
} from "@/features/delivery/checkout";
import {
  buildSlotOptions,
  deliveryMethodsQuery,
  deliveryZonesQuery,
  slotAvailabilityQuery,
  slotTemplatesQuery,
  type DeliverySlotOption,
} from "@/features/delivery/queries";
import {
  interpretStartResult,
  rememberStartNotice,
  startErrorMessage,
} from "@/features/payments/card-payment-state";
import { startPaymentFn } from "@/features/payments/payment-server";
import {
  deliveryQuoteQuery,
  isPlaceOrderError,
  placeOrder,
} from "@/features/orders/queries";
import { cardPaymentsEnabled, storeConfig } from "@/lib/env";
import { formatMoney } from "@/lib/format";
import { newIdempotencyKey } from "@/lib/idempotency";
import { CouponInput } from "@/features/promotions/components/coupon-input";
import { couponErrorMessage, discountLabel } from "@/features/promotions/logic";
import { couponPreviewQuery } from "@/features/promotions/queries";
import { supabase } from "@/lib/supabase/client";
import type {
  DeliveryMethodRow,
  DeliveryZoneRow,
  PaymentMethod,
} from "@/lib/supabase/types";

export const Route = createFileRoute("/checkout")({
  // Sessions live in browser storage, so this route is gated client-side only,
  // using the same flow as the protected account area.
  ssr: false,
  beforeLoad: async () => {
    if (!supabase) throw redirect({ to: "/auth", search: {} });
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user)
      throw redirect({ to: "/auth", search: { redirect: "/checkout" } });
    return { user: data.user };
  },
  head: () => ({
    meta: [
      { title: `Checkout — ${storeConfig.name}` },
      {
        name: "description",
        content: `Choose delivery and payment for your ${storeConfig.name} order.`,
      },
      { property: "og:title", content: `Checkout — ${storeConfig.name}` },
      {
        property: "og:description",
        content: "Choose delivery and payment for your order.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: CheckoutPage,
});

const NOTES_MAX_LENGTH = 1000;

/** Slot windows near their lead-time cut-off are re-evaluated this often. */
const SLOT_REFRESH_MS = 60_000;

const AVAILABILITY = { cardPaymentsEnabled };

/** Cash on delivery stays the default; card is never preselected. */
const DEFAULT_PAYMENT: PaymentMethod = "cash_on_delivery";

/** Time for the cart's storage effect to run before the page is left for the card page. */
const CLEAR_SETTLE_MS = 50;

type CardStart = { type: "redirect"; url: string } | { type: "stay" };

/** Starts the card payment for a new order. Never throws; the order exists whatever happens. */
async function startCardPayment(orderId: string): Promise<CardStart> {
  try {
    const outcome = interpretStartResult(
      await startPaymentFn({ data: { orderId, method: "card" } }),
    );
    if (outcome.type === "redirect") return outcome;
    if (outcome.type === "error") rememberStartNotice(orderId, outcome.message);
  } catch (error) {
    rememberStartNotice(orderId, startErrorMessage(error));
  }
  return { type: "stay" };
}

interface SlotDay {
  date: string;
  dayLabel: string;
  options: SlotChoice<DeliverySlotOption>[];
}

function groupSlotsByDay(options: SlotChoice<DeliverySlotOption>[]): SlotDay[] {
  const days: SlotDay[] = [];
  for (const option of options) {
    const last = days[days.length - 1];
    if (last && last.date === option.date) {
      last.options.push(option);
    } else {
      days.push({
        date: option.date,
        dayLabel: option.dayLabel,
        options: [option],
      });
    }
  }
  return days;
}

/**
 * The ETA for a delivery method. The fee is deliberately not shown here: it can depend on the
 * zone, so the only fee the customer sees is the database quote for the current selection.
 */
function methodDetail(method: DeliveryMethodRow): string | null {
  return method.eta_label || null;
}

/** What the customer needs to tell zones apart: county, towns, description. */
function zoneDescription(zone: DeliveryZoneRow): string {
  const parts: string[] = [];
  if (zone.county) parts.push(zone.county);
  if (zone.towns.length > 0) parts.push(zone.towns.join(", "));
  if (zone.description) parts.push(zone.description);
  return parts.join(" · ");
}

function Section({
  step,
  title,
  children,
}: {
  step: number;
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
      <div className="eyebrow text-muted-foreground">Step {step}</div>
      <h2 className="mt-1 font-display text-lg font-semibold">{title}</h2>
      <div className="mt-4">{children}</div>
    </div>
  );
}

function Option({
  checked,
  onSelect,
  title,
  description,
  disabled,
  name,
}: {
  checked: boolean;
  onSelect: () => void;
  title: ReactNode;
  description?: ReactNode | undefined;
  disabled?: boolean | undefined;
  name: string;
}) {
  return (
    <label
      className={`flex min-h-11 cursor-pointer items-start gap-3 rounded-(--radius-card) border p-3 text-sm transition ${
        checked
          ? "border-primary bg-primary/5"
          : "border-border bg-surface-strong"
      } ${disabled ? "cursor-not-allowed opacity-60" : ""}`}
    >
      <input
        type="radio"
        name={name}
        className="mt-1"
        checked={checked}
        disabled={disabled}
        onChange={onSelect}
      />
      <span>
        <span className="block font-medium">{title}</span>
        {description ? (
          <span className="block text-muted-foreground">{description}</span>
        ) : null}
      </span>
    </label>
  );
}

/** One basket problem with the buttons that resolve it. */
function IssueRow({ issue }: { issue: CartIssue }) {
  const { setQuantity, remove, repriceLine } = useCart();
  const { newPriceCents, maxQuantity } = issue;

  return (
    <li className="flex flex-wrap items-center justify-between gap-2 text-sm">
      <span className="min-w-0 flex-1">{issue.message}</span>
      <span className="flex flex-wrap gap-2">
        {newPriceCents !== undefined ? (
          <Button
            type="button"
            size="sm"
            onClick={() =>
              repriceLine(
                { productId: issue.productId, variantId: issue.variantId },
                newPriceCents,
              )
            }
          >
            Accept {formatMoney(newPriceCents)}
          </Button>
        ) : null}
        {maxQuantity !== undefined ? (
          <Button
            type="button"
            size="sm"
            onClick={() =>
              setQuantity(issue.productId, maxQuantity, issue.variantId)
            }
          >
            Reduce to {maxQuantity}
          </Button>
        ) : null}
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={() => remove(issue.productId, issue.variantId)}
        >
          Remove
        </Button>
      </span>
    </li>
  );
}

function CheckoutPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { lines, itemCount, subtotalCents, hydrated, clear } = useCart();

  const methodsQuery = useQuery(deliveryMethodsQuery());
  const templatesQuery = useQuery(slotTemplatesQuery());
  const addressesQ = useQuery(addressesQuery());
  const validationQuery = useQuery(cartValidationQuery(lines));

  const [methodCode, setMethodCode] = useState<string | null>(null);
  const [addressId, setAddressId] = useState<string | null>(null);
  const [zoneId, setZoneId] = useState<string | null>(null);
  const [slotId, setSlotId] = useState<string | null>(null);
  const [paymentId, setPaymentId] = useState<PaymentMethod | null>(null);
  const [notes, setNotes] = useState("");
  // Phase 8: the coupon CODE the customer typed. Never an amount; the preview below is the database's.
  const [couponCode, setCouponCode] = useState<string | null>(null);
  const [now, setNow] = useState(() => new Date());

  // One key per distinct checkout. It is replaced whenever anything that would
  // change the order changes, and reused when the same order is submitted again.
  const idempotency = useRef<{ signature: string; key: string } | null>(null);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), SLOT_REFRESH_MS);
    return () => window.clearInterval(timer);
  }, []);

  const templates = templatesQuery.data;
  const slotOptions = useMemo(
    () => (templates ? buildSlotOptions(templates, undefined, now) : []),
    [templates, now],
  );

  // What the selected method needs. Computed before the early returns because the zone, quote
  // and availability queries below depend on it.
  const methods = methodsQuery.data;
  const method =
    methods?.find((candidate) => candidate.code === methodCode) ?? methods?.[0];
  const needsAddress = method?.requires_address ?? true;
  const needsSlot = method?.requires_slot ?? true;

  // Active zones, only for methods that deliver to an address.
  const zonesQ = useQuery({ ...deliveryZonesQuery(), enabled: needsAddress });
  const zones = useMemo(() => selectableZones(zonesQ.data), [zonesQ.data]);
  const zoneMode = zoneRequirement(needsAddress, zones);
  const selectedZoneId = resolveZoneId({
    requiresAddress: needsAddress,
    zones,
    selectedZoneId: zoneId,
  });

  // The authoritative fee: validate_delivery_selection() -> resolve_delivery_fee(). Re-asked
  // whenever the method, zone or subtotal changes. React never works out a fee itself.
  const quoteRequest = buildQuoteRequest({
    method,
    zoneId: selectedZoneId,
    subtotalCents,
  });
  const quoteQ = useQuery(deliveryQuoteQuery(quoteRequest));
  const quote = deriveQuoteState({
    request: quoteRequest,
    isPending: quoteQ.isPending,
    error: quoteQ.error,
    result: quoteQ.data,
  });

  // Coupon preview AND final payable total: validate_coupon() prices the basket, the discount and the
  // delivery fee (the same selection the quote above uses) in the database. React adds nothing up.
  const couponQ = useQuery(
    couponPreviewQuery(
      lines,
      couponCode,
      quoteRequest
        ? { methodCode: quoteRequest.methodCode, zoneId: quoteRequest.zoneId }
        : null,
    ),
  );

  // Capacity per window, from get_delivery_slot_availability(). Refreshed so a window that
  // fills up while the customer is deciding stops being offered.
  const slotRange = slotDateRange(slotOptions);
  const availabilityQ = useQuery({
    ...slotAvailabilityQuery(slotRange?.from ?? "", slotRange?.to ?? ""),
    enabled: needsSlot && slotRange !== null,
    refetchInterval: SLOT_REFRESH_MS,
  });
  const slotChoices = useMemo(
    () => buildSlotChoices(slotOptions, availabilityQ.data),
    [slotOptions, availabilityQ.data],
  );
  const { slot, invalid: slotInvalid } = resolveSelectedSlot(
    slotChoices,
    slotId,
  );

  const place = useMutation({
    mutationFn: placeOrder,
    onSuccess: async (orderId, variables) => {
      await queryClient.invalidateQueries({ queryKey: ["orders"] });
      if (variables.paymentMethod === "card") {
        const start = await startCardPayment(orderId);
        if (start.type === "redirect") {
          // The order exists, so the basket is emptied before leaving for the hosted page.
          clear();
          await new Promise((resolve) =>
            window.setTimeout(resolve, CLEAR_SETTLE_MS),
          );
          window.location.assign(start.url);
          return;
        }
      }
      try {
        await navigate({
          to: "/order-confirmation/$orderId",
          params: { orderId },
          replace: true,
        });
      } finally {
        // Only after the order exists and we have moved on is the basket emptied.
        clear();
      }
    },
    onError: (error) => {
      // The basket, prices, stock or slots may have moved; re-read them.
      void queryClient.invalidateQueries({ queryKey: ["cart", "validation"] });
      void queryClient.invalidateQueries({ queryKey: ["delivery"] });

      // Coupons are re-checked by the database at order time; re-ask the preview after any failure.
      void queryClient.invalidateQueries({ queryKey: ["coupon"] });

      // A rejected slot or zone is no longer a valid pick: clear it so the customer chooses again.
      if (isPlaceOrderError(error) && error.deliveryCode) {
        const scope = deliveryErrorScope(error.deliveryCode);
        if (scope === "slot") setSlotId(null);
        if (scope === "zone") setZoneId(null);
      }
    },
  });

  if (!hydrated) {
    return (
      <section className="mx-auto max-w-[1200px] px-5 pt-6 pb-16">
        <div className="skeleton h-40 w-full rounded-(--radius-panel)" />
      </section>
    );
  }

  if (lines.length === 0) {
    return (
      <section className="mx-auto max-w-[1400px] px-5 pt-6 pb-12">
        <EmptyState
          title="Your basket is empty"
          message="Add items to your basket before checking out."
          action={<BrowseCta />}
        />
      </section>
    );
  }

  const addresses = addressesQ.data;
  const address =
    addresses?.find((candidate) => candidate.id === addressId) ??
    addresses?.find((candidate) => candidate.is_default) ??
    addresses?.[0];
  const zone =
    zones.find((candidate) => candidate.id === selectedZoneId) ?? null;
  const payment = paymentProvider(paymentId ?? DEFAULT_PAYMENT);

  const addressStep = needsAddress ? 2 : 0;
  const zoneStep = needsAddress ? 3 : 0;
  const slotStep = needsSlot ? 2 + (needsAddress ? 2 : 0) : 0;
  const paymentStep = 2 + (needsAddress ? 2 : 0) + (needsSlot ? 1 : 0);
  const notesStep = paymentStep + 1;

  // Everything in the summary is a database answer (validate_coupon). create_order() recomputes it
  // and refuses the order if the total differs from what the customer was shown.
  // Discount: the database's own preview (validate_coupon). A rejected code gives no discount and
  // blocks the order until it is removed or fixed; an automatic promotion shows when no code is applied.
  const coupon = couponQ.data;
  // Shown in the summary: the fee and the total both come from the same validate_coupon() answer,
  // so the summary always adds up to what create_order() will charge.
  const feeCents =
    quote.status === "ready" && coupon && coupon.status !== "rejected"
      ? coupon.totals.deliveryFeeCents
      : null;
  // The database's own subtotal for this exact basket. The basket's saved prices are not shown as one.
  const serverSubtotalCents =
    coupon && coupon.status !== "rejected" ? coupon.subtotalCents : null;
  const couponRejectedMessage =
    coupon?.status === "rejected" ? couponErrorMessage(coupon.error) : null;
  // The server's final payable total; null until the database has priced this exact selection.
  const totalCents =
    quote.status === "ready" && coupon && coupon.status !== "rejected"
      ? coupon.totals.totalCents
      : null;
  const quoteMinOrderLabel =
    quote.status === "rejected" && quote.minOrderCents !== null
      ? formatMoney(quote.minOrderCents)
      : null;
  const quoteBlocker = quoteBlockerMessage(quote, {
    minOrderLabel: quoteMinOrderLabel,
  });

  const issues = validationQuery.data ?? [];
  const checkingBasket =
    validationQuery.isPending || validationQuery.isFetching;

  const blockers: [boolean | undefined, string][] = [
    [methodsQuery.isPending, "Loading delivery options…"],
    [
      methodsQuery.isError || !method,
      "Delivery options aren't available right now.",
    ],
    [
      method?.requires_address && addressesQ.isPending,
      "Loading your addresses…",
    ],
    [
      method?.requires_address && addressesQ.isError,
      "Your addresses couldn't be loaded.",
    ],
    [needsAddress && zonesQ.isPending, "Loading delivery areas…"],
    [needsAddress && zonesQ.isError, "Delivery areas couldn't be loaded."],
    [
      needsAddress && zonesQ.isSuccess && zoneMode === "no_zones",
      "Delivery to an address isn't available right now.",
    ],
    [
      method?.requires_slot && templatesQuery.isPending,
      "Loading delivery slots…",
    ],
    [
      method?.requires_slot && templatesQuery.isError,
      "Delivery slots couldn't be loaded.",
    ],
    [
      method?.requires_slot && availabilityQ.isPending,
      "Checking delivery slot availability…",
    ],
    [
      method?.requires_slot && availabilityQ.isError,
      "Delivery slot availability couldn't be loaded.",
    ],
    [couponQ.isFetching, "Checking your discount…"],
    [couponQ.isError, "We couldn't check your coupon. Remove it or try again."],
    [couponRejectedMessage !== null, couponRejectedMessage ?? ""],
    [
      quote.status === "ready" && !couponQ.isFetching && totalCents === null,
      "We couldn't confirm your total. Please try again.",
    ],
    [checkingBasket, "Checking your basket…"],
    [validationQuery.isError, "We couldn't check your basket."],
    [issues.length > 0, "Fix the basket issues above to continue."],
    [
      method?.requires_address && !address,
      "Choose a delivery address to continue.",
    ],
    [
      needsAddress && zoneMode === "choose" && !zone,
      deliveryErrorMessage("zone_required"),
    ],
    [quoteBlocker !== null, quoteBlocker ?? ""],
    [method?.requires_slot && !slot, deliveryErrorMessage("slot_required")],
    [
      notes.length > NOTES_MAX_LENGTH,
      `Notes can be up to ${NOTES_MAX_LENGTH} characters.`,
    ],
  ];
  const blocker = blockers.find(([active]) => active)?.[1] ?? null;

  function submit() {
    if (
      blocker !== null ||
      !method ||
      place.isPending ||
      quote.status !== "ready"
    )
      return;

    const orderAddressId = method.requires_address
      ? (address?.id ?? null)
      : null;
    const orderSlot = method.requires_slot ? slot : null;
    const orderNotes = notes.trim() || null;
    const orderZoneId = method.requires_address ? (zone?.id ?? null) : null;
    // The veto sends the database's own total (validate_coupon), never one computed here.
    const expectedTotalCents = totalCents;
    if (expectedTotalCents === null) return;

    const signature = JSON.stringify([
      lines.map((line) => [
        cartLineKey(line.productId, line.variantId),
        line.quantity,
      ]),
      method.code,
      orderAddressId,
      orderZoneId,
      orderSlot
        ? [orderSlot.date, orderSlot.startTime, orderSlot.endTime]
        : null,
      payment.id,
      orderNotes,
      couponCode,
      expectedTotalCents,
    ]);
    const attempt =
      idempotency.current?.signature === signature
        ? idempotency.current
        : { signature, key: newIdempotencyKey() };
    idempotency.current = attempt;

    place.mutate({
      items: lines.map((line) => ({
        productId: line.productId,
        variantId: line.variantId,
        quantity: line.quantity,
      })),
      deliveryMethod: method.code,
      paymentMethod: payment.id,
      addressId: orderAddressId,
      // The zone the customer chose; null for methods without an address.
      zoneId: orderZoneId,
      slotDate: orderSlot?.date ?? null,
      slotStart: orderSlot?.startTime ?? null,
      slotEnd: orderSlot?.endTime ?? null,
      slotLabel: orderSlot?.templateLabel ?? null,
      notes: orderNotes,
      idempotencyKey: attempt.key,
      expectedTotalCents,
      couponCode,
    });
  }

  const slotDays = groupSlotsByDay(visibleSlotChoices(slotChoices));

  return (
    <section className="mx-auto max-w-[1200px] px-5 pt-6 pb-16">
      <h1 className="font-display text-3xl font-semibold">Checkout</h1>
      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_360px]">
        <div className="space-y-5">
          {validationQuery.isError ? (
            <QueryErrorState
              error={validationQuery.error}
              onRetry={() => void validationQuery.refetch()}
            />
          ) : null}

          {issues.length > 0 ? (
            <div
              role="alert"
              className="rounded-(--radius-card) border border-danger/25 bg-danger/5 p-4"
            >
              <h2 className="font-display text-base font-semibold">
                Update your basket to continue
              </h2>
              <ul className="mt-3 space-y-3">
                {issues.map((issue) => (
                  <IssueRow key={issue.key} issue={issue} />
                ))}
              </ul>
            </div>
          ) : null}

          <Section step={1} title="Delivery method">
            {methodsQuery.isPending ? (
              <div className="skeleton h-16 w-full rounded-lg" />
            ) : methodsQuery.isError ? (
              <QueryErrorState
                error={methodsQuery.error}
                onRetry={() => void methodsQuery.refetch()}
              />
            ) : methodsQuery.data.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No delivery methods are available right now.
              </p>
            ) : (
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
                {methodsQuery.data.map((candidate) => (
                  <Option
                    key={candidate.code}
                    name="delivery-method"
                    checked={candidate.code === method?.code}
                    onSelect={() => setMethodCode(candidate.code)}
                    title={candidate.label}
                    description={
                      <>
                        {candidate.description}
                        {methodDetail(candidate) ? (
                          <span className="mt-1 block font-mono text-xs">
                            {methodDetail(candidate)}
                          </span>
                        ) : null}
                      </>
                    }
                  />
                ))}
              </div>
            )}
          </Section>

          {needsAddress ? (
            <Section step={addressStep} title="Delivery address">
              {addressesQ.isPending ? (
                <div className="skeleton h-16 w-full rounded-lg" />
              ) : addressesQ.isError ? (
                <QueryErrorState
                  error={addressesQ.error}
                  onRetry={() => void addressesQ.refetch()}
                />
              ) : addressesQ.data.length === 0 ? (
                <div className="text-sm">
                  <p className="text-muted-foreground">
                    You haven't saved a delivery address yet.
                  </p>
                  <Button asChild className="mt-3">
                    <Link to="/account">Add an address</Link>
                  </Button>
                </div>
              ) : (
                <div className="space-y-2">
                  {addressesQ.data.map((candidate) => (
                    <Option
                      key={candidate.id}
                      name="delivery-address"
                      checked={candidate.id === address?.id}
                      onSelect={() => setAddressId(candidate.id)}
                      title={
                        <>
                          {candidate.label || "Address"}
                          {candidate.is_default ? (
                            <span className="ml-2 text-xs text-primary">
                              Default
                            </span>
                          ) : null}
                        </>
                      }
                      description={`${candidate.full_name} · ${candidate.address_line_1}, ${candidate.city}, ${candidate.county} · ${candidate.phone}`}
                    />
                  ))}
                  <Link
                    to="/account"
                    className="inline-block text-xs text-primary"
                  >
                    Manage addresses
                  </Link>
                </div>
              )}
            </Section>
          ) : null}

          {needsAddress ? (
            <Section step={zoneStep} title="Delivery area">
              {zonesQ.isPending ? (
                <div className="skeleton h-16 w-full rounded-lg" />
              ) : zonesQ.isError ? (
                <QueryErrorState
                  error={zonesQ.error}
                  onRetry={() => void zonesQ.refetch()}
                />
              ) : zoneMode === "no_zones" ? (
                <p className="text-sm text-muted-foreground">
                  Delivery to an address isn't available right now.
                  {methods &&
                  methods.some((candidate) => !candidate.requires_address)
                    ? " You can choose a pickup option instead."
                    : " Please check back soon."}
                </p>
              ) : (
                <div className="space-y-2">
                  {zones.map((candidate) => (
                    <Option
                      key={candidate.id}
                      name="delivery-zone"
                      checked={candidate.id === zone?.id}
                      onSelect={() => setZoneId(candidate.id)}
                      title={candidate.name}
                      description={zoneDescription(candidate) || undefined}
                    />
                  ))}
                  {zoneId !== null && !zone ? (
                    <p className="text-xs text-danger">
                      {deliveryErrorMessage("zone_inactive")}
                    </p>
                  ) : null}
                  {quote.status === "ready" ? (
                    <p className="font-mono text-xs text-muted-foreground">
                      Delivery to {zone?.name}:{" "}
                      {quote.feeCents === 0
                        ? "Free"
                        : formatMoney(quote.feeCents)}
                      {quote.quote.freeOverCents !== null && quote.feeCents > 0
                        ? ` · free over ${formatMoney(quote.quote.freeOverCents)}`
                        : ""}
                      {quote.quote.minOrderCents > 0
                        ? ` · minimum order ${formatMoney(quote.quote.minOrderCents)}`
                        : ""}
                    </p>
                  ) : null}
                </div>
              )}
            </Section>
          ) : null}

          {needsSlot ? (
            <Section step={slotStep} title="Delivery slot">
              {templatesQuery.isPending || availabilityQ.isPending ? (
                <div className="skeleton h-16 w-full rounded-lg" />
              ) : templatesQuery.isError ? (
                <QueryErrorState
                  error={templatesQuery.error}
                  onRetry={() => void templatesQuery.refetch()}
                />
              ) : availabilityQ.isError ? (
                <QueryErrorState
                  error={availabilityQ.error}
                  onRetry={() => void availabilityQ.refetch()}
                />
              ) : slotDays.length === 0 ? (
                <p className="text-sm text-muted-foreground">
                  No delivery slots are open right now. Please try again later.
                </p>
              ) : (
                <div className="space-y-4">
                  {slotDays.map((day) => (
                    <div key={day.date}>
                      <div className="eyebrow text-muted-foreground">
                        {day.dayLabel}
                      </div>
                      <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
                        {day.options.map((option) => (
                          <button
                            key={option.id}
                            type="button"
                            aria-pressed={option.id === slot?.id}
                            disabled={!isSlotSelectable(option)}
                            onClick={() => setSlotId(option.id)}
                            className={`rounded-lg border px-2 py-2 text-left text-xs transition ${
                              option.id === slot?.id
                                ? "border-primary bg-primary/5"
                                : "border-border bg-surface-strong"
                            } ${isSlotSelectable(option) ? "" : "cursor-not-allowed opacity-60"}`}
                          >
                            <span className="block font-medium">
                              {option.templateLabel}
                            </span>
                            <span className="font-mono text-muted-foreground">
                              {option.windowLabel}
                            </span>
                            {option.status === "full" ? (
                              <span className="mt-1 block text-muted-foreground">
                                Full
                              </span>
                            ) : option.remaining !== null &&
                              option.remaining <= 3 ? (
                              <span className="mt-1 block text-muted-foreground">
                                {option.remaining} left
                              </span>
                            ) : null}
                          </button>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              )}
              {slotInvalid && availabilityQ.isSuccess ? (
                <p className="mt-3 text-xs text-danger">
                  The slot you picked can no longer be booked. Choose another
                  one.
                </p>
              ) : null}
              <p className="mt-3 text-xs text-muted-foreground">
                A slot is only held once your order is placed. If it fills up
                first, you'll be asked to choose another.
              </p>
            </Section>
          ) : null}

          <Section step={paymentStep} title="Payment method">
            <div className="space-y-2">
              {PAYMENT_PROVIDERS.map((provider) => (
                <Option
                  key={provider.id}
                  name="payment-method"
                  checked={provider.id === payment.id}
                  onSelect={() => setPaymentId(provider.id)}
                  disabled={!isProviderSelectable(provider, AVAILABILITY)}
                  title={
                    <>
                      {provider.label}
                      {!provider.connected &&
                      !(provider.id === "card" && cardPaymentsEnabled) ? (
                        <span className="ml-2 text-xs text-muted-foreground">
                          Not connected yet
                        </span>
                      ) : null}
                    </>
                  }
                  description={provider.description}
                />
              ))}
            </div>
            <p className="mt-3 rounded-lg border border-border bg-surface px-3 py-2 text-xs text-muted-foreground">
              {payment.pendingNote}
            </p>
          </Section>

          <Section step={notesStep} title="Order notes">
            <Field
              label="Notes for your order (optional)"
              htmlFor="order-notes"
              hint={`${notes.length}/${NOTES_MAX_LENGTH}`}
            >
              <TextArea
                id="order-notes"
                rows={3}
                maxLength={NOTES_MAX_LENGTH}
                placeholder="Anything we should know about your order?"
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
              />
            </Field>
          </Section>
        </div>

        <aside className="lg:sticky lg:top-20 lg:self-start">
          <div className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
            <h2 className="font-display text-lg font-semibold">
              Order summary
            </h2>
            <ul className="mt-4 space-y-2 text-sm">
              {lines.map((line) => (
                <li
                  key={cartLineKey(line.productId, line.variantId)}
                  className="flex justify-between gap-3"
                >
                  <span className="min-w-0 truncate">
                    {line.quantity} × {line.name}
                    {line.variantName ? ` (${line.variantName})` : ""}
                  </span>
                  <span className="shrink-0 font-mono text-muted-foreground">
                    {formatMoney(line.priceCents)} each
                  </span>
                </li>
              ))}
            </ul>
            <dl className="mt-4 space-y-1 border-t border-border pt-3 text-sm">
              <div className="flex justify-between">
                <dt>Subtotal ({itemCount} items)</dt>
                <dd className="font-mono">
                  {serverSubtotalCents === null
                    ? "—"
                    : formatMoney(serverSubtotalCents)}
                </dd>
              </div>
              {coupon?.status === "applied" ? (
                <div className="flex justify-between">
                  <dt>
                    {discountLabel({ code: coupon.code, name: coupon.name })}
                  </dt>
                  <dd className="font-mono">
                    −{formatMoney(coupon.discountCents)}
                  </dd>
                </div>
              ) : null}
              <div className="flex justify-between">
                <dt>Delivery</dt>
                <dd className="font-mono">
                  {feeCents === null
                    ? "—"
                    : feeCents === 0
                      ? "Free"
                      : formatMoney(feeCents)}
                </dd>
              </div>
              <div className="flex justify-between border-t border-border pt-2 font-medium">
                <dt>Total</dt>
                <dd className="font-mono">
                  {totalCents === null ? "—" : formatMoney(totalCents)}
                </dd>
              </div>
            </dl>
            <CouponInput
              applied={couponCode}
              message={couponRejectedMessage}
              busy={couponQ.isFetching}
              onApply={setCouponCode}
              onRemove={() => setCouponCode(null)}
            />
            <dl className="mt-4 space-y-1 border-t border-border pt-3 text-xs text-muted-foreground">
              <div>Method: {method?.label ?? "—"}</div>
              {needsAddress ? (
                <div>
                  Deliver to:{" "}
                  {address ? `${address.address_line_1}, ${address.city}` : "—"}
                </div>
              ) : null}
              {needsAddress ? (
                <div>Delivery area: {zone ? zone.name : "—"}</div>
              ) : null}
              {needsSlot ? <div>Slot: {slot ? slot.label : "—"}</div> : null}
              <div>Payment: {payment.label}</div>
            </dl>
            <p className="mt-3 text-xs text-muted-foreground">
              Prices, stock and the delivery fee are confirmed when you place
              the order. If any of them changed, the order is not placed and
              nothing is charged.
            </p>
            {place.isError ? (
              <div className="mt-4">
                <ErrorState
                  title={
                    isPlaceOrderError(place.error) &&
                    place.error.accountSuspended
                      ? "Your account can't place orders"
                      : "We couldn't place your order"
                  }
                  message={place.error.message}
                />
              </div>
            ) : null}
            <Button
              type="button"
              size="block"
              className="mt-4"
              disabled={blocker !== null || place.isPending}
              onClick={submit}
            >
              {place.isPending ? "Placing order…" : "Place order"}
            </Button>
            {blocker !== null && !place.isPending ? (
              <p className="mt-2 text-center text-xs text-muted-foreground">
                {blocker}
              </p>
            ) : null}
          </div>
        </aside>
      </div>
    </section>
  );
}
