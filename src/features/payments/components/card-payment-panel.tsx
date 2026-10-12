import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui-kit/button";
import { OrderSectionCard } from "@/features/orders/components/order-sections";
import { orderQuery } from "@/features/orders/queries";
import {
  CARD_CONTACT_LINE,
  cardPanelCopy,
  clearStartNotice,
  deriveCardPanelState,
  interpretStartResult,
  isCardOrder,
  nextPollInterval,
  peekStartNotice,
  pollTimeRemaining,
  startErrorMessage,
} from "@/features/payments/card-payment-state";
import {
  getMyOrderPaymentStatusFn,
  startPaymentFn,
} from "@/features/payments/payment-server";
import type { OrderRow } from "@/lib/supabase/types";

/**
 * Card payment status and "Pay by card" for one order. Paid is shown only from the database
 * (get_my_order_payments); returning from the provider just means "check the status again".
 */
export function CardPaymentPanel({ order }: { order: OrderRow }) {
  if (!isCardOrder(order)) return null;
  return <CardPaymentPanelInner order={order} />;
}

function CardPaymentPanelInner({ order }: { order: OrderRow }) {
  const orderId = order.id;
  const queryClient = useQueryClient();
  const pollStart = useRef(Date.now());
  const [timedOut, setTimedOut] = useState(false);
  const [notice, setNotice] = useState<string | null>(() =>
    peekStartNotice(orderId),
  );
  const [redirecting, setRedirecting] = useState(false);

  useEffect(() => {
    clearStartNotice(orderId);
  }, [orderId]);

  const statusQuery = useQuery({
    queryKey: ["orders", "payment-status", orderId],
    queryFn: () => getMyOrderPaymentStatusFn({ data: { orderId } }),
    refetchInterval: (query) => {
      const data = query.state.data;
      const state = data ? deriveCardPanelState(order, data) : null;
      return nextPollInterval(state, Date.now() - pollStart.current);
    },
  });

  const state = statusQuery.data
    ? deriveCardPanelState(order, statusQuery.data)
    : null;
  const kind = state?.kind ?? null;

  // Stop polling after the limit and say so.
  useEffect(() => {
    if (kind !== "in_progress") {
      setTimedOut(false);
      return;
    }
    const remaining = pollTimeRemaining(Date.now() - pollStart.current);
    if (remaining === 0) {
      setTimedOut(true);
      return;
    }
    const timer = window.setTimeout(() => setTimedOut(true), remaining);
    return () => window.clearTimeout(timer);
  }, [kind]);

  // Once the database says paid, re-read the order so the rest of the page agrees.
  useEffect(() => {
    if (kind === "paid")
      void queryClient.invalidateQueries({
        queryKey: orderQuery(orderId).queryKey,
      });
  }, [kind, orderId, queryClient]);

  function restartPolling() {
    pollStart.current = Date.now();
    setTimedOut(false);
    void statusQuery.refetch();
  }

  const start = useMutation({
    mutationFn: () => startPaymentFn({ data: { orderId, method: "card" } }),
    onSuccess: (result) => {
      const outcome = interpretStartResult(result);
      if (outcome.type === "redirect") {
        setRedirecting(true);
        window.location.assign(outcome.url);
        return;
      }
      if (outcome.type === "error") setNotice(outcome.message);
      else setNotice(null);
      restartPolling();
    },
    onError: (error) => {
      setNotice(startErrorMessage(error));
      void statusQuery.refetch();
    },
  });

  const busy = start.isPending || redirecting;

  return (
    <OrderSectionCard title="Card payment">
      <div className="space-y-3 text-sm" aria-live="polite">
        {statusQuery.isPending ? (
          <p className="text-muted-foreground">Checking your payment…</p>
        ) : state === null ? (
          <>
            <p role="alert" className="text-danger">
              We couldn't check your payment status right now.
            </p>
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={restartPolling}
            >
              Check again
            </Button>
          </>
        ) : (
          <PanelBody
            copy={cardPanelCopy(state, timedOut)}
            busy={busy}
            onPay={() => start.mutate()}
            onCheck={
              state.kind === "in_progress" && timedOut ? restartPolling : null
            }
          />
        )}
        {notice ? (
          <p role="alert" className="text-danger">
            {notice}
          </p>
        ) : null}
        <p className="text-xs text-muted-foreground">
          {CARD_CONTACT_LINE} Your order number is {order.order_number}.
        </p>
      </div>
    </OrderSectionCard>
  );
}

function PanelBody({
  copy,
  busy,
  onPay,
  onCheck,
}: {
  copy: ReturnType<typeof cardPanelCopy>;
  busy: boolean;
  onPay: () => void;
  onCheck: (() => void) | null;
}) {
  if (!copy) return null;
  return (
    <>
      <div>
        <div className="font-medium">{copy.title}</div>
        <p className="mt-1 text-muted-foreground">{copy.message}</p>
      </div>
      {copy.action ? (
        <Button type="button" disabled={busy} onClick={onPay}>
          {busy ? "Please wait…" : copy.action}
        </Button>
      ) : null}
      {onCheck ? (
        <Button type="button" size="sm" variant="outline" onClick={onCheck}>
          Check again
        </Button>
      ) : null}
    </>
  );
}
