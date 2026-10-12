import type { PaymentGateway } from "../payment-providers.ts";

/**
 * Cash on delivery. There is no provider to call and no payment attempt: the DB refuses
 * create_payment_attempt() for COD, and cash is recorded by record_cod_payment() (which the
 * database restricts to admins, once the order is out for delivery or delivered).
 */
export const COD_PROVIDER = "cod";

export const codGateway: PaymentGateway = {
  method: "cash_on_delivery",
  provider: COD_PROVIDER,
  collectsOffline: true,
  initiate: () => Promise.resolve({ kind: "offline" }),
  // COD has no provider callbacks. Anything arriving here is not ours to act on.
  parseCallback: () => Promise.resolve({ kind: "ignored" }),
};
