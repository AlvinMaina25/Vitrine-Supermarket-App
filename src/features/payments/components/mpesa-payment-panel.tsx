import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useRef, useState } from "react";

import { useOnlineStatus } from "@/components/states/use-online-status";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import { OrderSectionCard } from "@/features/orders/components/order-sections";
import { orderQuery } from "@/features/orders/queries";
import {
  checkMpesaPhone,
  deriveMpesaPanelState,
  formatCountdown,
  interpretMpesaStart,
  isMpesaOrder,
  MPESA_CONTACT_LINE,
  mpesaNextPollInterval,
  mpesaPanelCopy,
  pollTimeRemaining,
  startErrorMessage,
} from "@/features/payments/mpesa-payment-state";
import {
  getMyOrderPaymentStatusFn,
  startPaymentFn,
} from "@/features/payments/payment-server";
import type { OrderRow } from "@/lib/supabase/types";

/**
 * M-Pesa payment for one order: phone entry, the wait, and the outcome. Everything shown about
 * the payment is read from the server (get_my_order_payments and the order's own status). The
 * browser sends a phone number and an order id, never an amount, and never marks anything paid.
 */
export function MpesaPaymentPanel({ order }: { order: OrderRow }) {
  if (!isMpesaOrder(order)) return null;
  return <MpesaPaymentPanelInner order={order} />;
}

function MpesaPaymentPanelInner({ order }: { order: OrderRow }) {
  const orderId = order.id;
  const queryClient = useQueryClient();
  const online = useOnlineStatus();
  const phoneId = useId();
  const errorId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const pollStart = useRef(Date.now());
  const [now, setNow] = useState(() => Date.now());
  const [timedOut, setTimedOut] = useState(false);
  const [phone, setPhone] = useState("");
  const [phoneError, setPhoneError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const statusQuery = useQuery({
    queryKey: ["orders", "payment-status", orderId],
    queryFn: () => getMyOrderPaymentStatusFn({ data: { orderId } }),
    refetchInterval: (query) => {
      const data = query.state.data;
      const state = data ? deriveMpesaPanelState(order, data) : null;
      return mpesaNextPollInterval(state, Date.now() - pollStart.current);
    },
  });

  const state = statusQuery.data
    ? deriveMpesaPanelState(order, statusQuery.data)
    : null;
  const kind = state?.kind ?? null;

  // Stop reading after the limit and say so.
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

  // The visible countdown only ticks while we are actually waiting.
  const waiting = kind === "in_progress" && !timedOut;
  useEffect(() => {
    if (!waiting) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [waiting]);

  // Once the server says paid, re-read the order so the rest of the page agrees.
  useEffect(() => {
    if (kind === "paid")
      void queryClient.invalidateQueries({
        queryKey: orderQuery(orderId).queryKey,
      });
  }, [kind, orderId, queryClient]);

  function restartPolling() {
    pollStart.current = Date.now();
    setNow(Date.now());
    setTimedOut(false);
    void statusQuery.refetch();
  }

  const start = useMutation({
    mutationFn: () =>
      startPaymentFn({
        data: { orderId, method: "mpesa", phone: phone.trim() },
      }),
    onSuccess: (result) => {
      const outcome = interpretMpesaStart(result);
      if (outcome.type === "error") setNotice(outcome.message);
      else setNotice(null);
      restartPolling();
    },
    onError: (error) => {
      setNotice(startErrorMessage(error));
      inputRef.current?.focus();
      void statusQuery.refetch();
    },
  });

  function submit() {
    if (start.isPending) return;
    const check = checkMpesaPhone(phone);
    if (!check.ok) {
      setPhoneError(check.message);
      inputRef.current?.focus();
      return;
    }
    setPhoneError(null);
    setNotice(null);
    start.mutate();
  }

  const copy = state ? mpesaPanelCopy(state, timedOut) : null;
  const busy = start.isPending;

  return (
    <OrderSectionCard title="M-Pesa payment">
      <div className="space-y-3 text-sm" aria-live="polite">
        {statusQuery.isPending ? (
          <p className="text-muted-foreground">Checking your payment…</p>
        ) : state === null || copy === null ? (
          <>
            <p role="alert" className="text-danger">
              We couldn't check your payment status right now.
            </p>
            <Button
              type="button"
              size="touch"
              variant="outline"
              onClick={restartPolling}
            >
              Check again
            </Button>
          </>
        ) : (
          <>
            <div>
              <div className="font-medium">{copy.title}</div>
              <p className="mt-1 text-muted-foreground">{copy.message}</p>
            </div>
            {waiting ? (
              <p
                role="timer"
                className="font-mono text-xs text-muted-foreground"
              >
                Waiting for up to{" "}
                {formatCountdown(pollTimeRemaining(now - pollStart.current))}
              </p>
            ) : null}
            {copy.needsPhone ? (
              <form
                noValidate
                onSubmit={(event) => {
                  event.preventDefault();
                  submit();
                }}
                className="space-y-3"
              >
                <Field
                  label="Safaricom number"
                  htmlFor={phoneId}
                  hint="Like 0712345678 or 254712345678."
                >
                  <TextInput
                    id={phoneId}
                    ref={inputRef}
                    type="tel"
                    inputMode="tel"
                    autoComplete="tel"
                    value={phone}
                    disabled={busy}
                    aria-invalid={phoneError !== null}
                    aria-describedby={phoneError !== null ? errorId : undefined}
                    className="min-h-11 text-base"
                    onChange={(event) => {
                      setPhone(event.target.value);
                      if (phoneError !== null) setPhoneError(null);
                    }}
                  />
                </Field>
                {phoneError !== null ? (
                  <p id={errorId} role="alert" className="text-danger">
                    {phoneError}
                  </p>
                ) : null}
                <Button
                  type="submit"
                  size="touchBlock"
                  disabled={busy || !online}
                >
                  {busy ? "Sending…" : copy.action}
                </Button>
                {!online ? (
                  <p className="text-xs text-muted-foreground">
                    You're offline. Reconnect to send the prompt.
                  </p>
                ) : null}
              </form>
            ) : null}
            {kind === "in_progress" && timedOut ? (
              <Button
                type="button"
                size="touch"
                variant="outline"
                onClick={restartPolling}
              >
                Check again
              </Button>
            ) : null}
          </>
        )}
        {notice ? (
          <p role="alert" className="text-danger">
            {notice}
          </p>
        ) : null}
        <p className="text-xs text-muted-foreground">
          {MPESA_CONTACT_LINE} Your order number is {order.order_number}.
        </p>
      </div>
    </OrderSectionCard>
  );
}
