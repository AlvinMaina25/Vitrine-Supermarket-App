import type { PaymentMethod } from "@/lib/supabase/types";

/**
 * Payment provider registry.
 *
 * Checkout talks only to this interface. Real providers (M-Pesa STK push,
 * card gateway) will implement `initiate` via a server function, confirm
 * payment through a verified webhook route under /api/public/, and never mark
 * an order paid from the browser.
 *
 * `connected: false` means the gateway is not wired up yet. An order can
 * still be placed — it is created with payment_status 'pending' and order
 * status 'awaiting_payment'. Nothing here ever reports a successful payment.
 */

export type PaymentMethodId = PaymentMethod;

export interface PaymentProvider {
  id: PaymentMethodId;
  label: string;
  description: string;
  /** True once a real gateway can be charged. */
  connected: boolean;
  /** Copy shown after the order is created. */
  pendingNote: string;
}

export const PAYMENT_PROVIDERS: readonly PaymentProvider[] = [
  {
    id: "mpesa",
    label: "M-Pesa",
    description: "Pay with an STK push to your phone.",
    connected: false,
    pendingNote:
      "Your order stays awaiting payment until M-Pesa confirms it. You send the M-PESA prompt from the order page after placing the order; if M-Pesa isn't available then, the page will say so.",
  },
  {
    id: "card",
    label: "Debit / credit card",
    description:
      "Visa or Mastercard on a secure payment page. You'll be taken there after you place the order.",
    connected: false,
    pendingNote:
      "You'll pay by card on a secure payment page. Your order stays awaiting payment until the payment is confirmed.",
  },
  {
    id: "cash_on_delivery",
    label: "Cash on delivery",
    description: "Pay the rider when your order arrives.",
    connected: true,
    pendingNote:
      "Have the exact amount ready for the rider. Payment is recorded on delivery.",
  },
];

/** Public, non-secret switches. Passed in so this file stays importable under `node --test`. */
export interface PaymentAvailability {
  cardPaymentsEnabled: boolean;
}

/** Card can be chosen only when enabled; other methods keep their existing behaviour. */
export function isProviderSelectable(
  provider: PaymentProvider,
  availability: PaymentAvailability,
): boolean {
  return provider.id === "card" ? availability.cardPaymentsEnabled : true;
}

export function paymentProvider(id: PaymentMethodId): PaymentProvider {
  return (
    PAYMENT_PROVIDERS.find((provider) => provider.id === id) ??
    PAYMENT_PROVIDERS[0]!
  );
}

// ---------------------------------------------------------------------------------------------
// Server-side gateway interface (Phase 6H). Type-only: no secrets, no I/O, safe to import anywhere.
// One implementation per provider lives under src/features/checkout/providers/. Gateways never
// touch the database and never mark an order paid; they only talk to the provider and report what
// it said. The server function (src/features/payments/start-payment.ts) owns every database call.
// ---------------------------------------------------------------------------------------------

/** The order as the DATABASE reports it. Amounts here are never taken from the browser. */
export interface GatewayOrder {
  id: string;
  totalCents: number;
  currency: string;
}

/** The payment attempt row created by create_payment_attempt(). */
export interface GatewayAttempt {
  transactionId: string;
  provider: string;
  method: PaymentMethodId;
  amountCents: number;
  currency: string;
  idempotencyKey: string;
}

/** Who is paying, as the browser told us (never money). Validated by the gateway, not trusted. */
export interface GatewayPayer {
  phone: string | null;
  /** The signed-in user's real, authenticated email. Only set for gateways that need it. */
  email?: string;
}

const EMAIL_PATTERN =
  /^[^\s@<>"',;:()[\]\\]+@[^\s@<>"',;:()[\]\\]+\.[^\s@<>"',;:()[\]\\]+$/;

/** The trimmed email when it looks valid (at most 254 characters), else null. Never invents one. */
export function normalisePayerEmail(
  email: string | null | undefined,
): string | null {
  if (typeof email !== "string") return null;
  const trimmed = email.trim();
  return trimmed.length > 0 &&
    trimmed.length <= 254 &&
    EMAIL_PATTERN.test(trimmed)
    ? trimmed
    : null;
}

export type InitiateResult =
  /** Cash on delivery: nothing is sent to a provider. */
  | { kind: "offline" }
  /** A prompt was pushed to the customer's device (M-Pesa STK push). */
  | { kind: "prompt_sent"; providerReference: string }
  /** The customer must continue on the provider's hosted page (card). */
  | { kind: "redirect"; providerReference: string; redirectUrl: string };

/** A provider callback as received by a server route. The body is the raw text, unparsed. */
export interface CallbackRequest {
  method: string;
  url: string;
  headers: Readonly<Record<string, string>>;
  body: string;
}

export type FinalOutcome = "succeeded" | "failed" | "cancelled" | "expired";

export type VerifiedOutcome =
  /** Authentic but nothing to apply (for example an unrelated event type). */
  | { kind: "ignored" }
  | {
      kind: "outcome";
      providerReference: string;
      outcome: FinalOutcome;
      /** Integer cents as the provider reported it; null when the provider reported none. */
      amountCents: number | null;
      /** The provider's own receipt id, when it sends one. Not stored by the database today. */
      receiptNumber?: string | null;
      currency: string | null;
      failureCode: string | null;
      failureMessage: string | null;
    };

/** Answer to "what happened to this attempt?", for attempts whose callback never arrived. */
export type StatusQueryResult =
  | { kind: "pending" }
  | {
      kind: "outcome";
      outcome: FinalOutcome;
      failureCode: string | null;
      failureMessage: string | null;
    };

export interface PaymentGateway {
  readonly method: PaymentMethodId;
  /** Stored in payment_transactions.provider (1-40 characters). */
  readonly provider: string;
  /** True when payment is collected in person and recorded by record_cod_payment(), with no attempt row. */
  readonly collectsOffline: boolean;
  /** Returns the normalised payer phone, or null when it is not acceptable. Absent: no phone needed. */
  normalisePayer?(phone: string | null): string | null;
  /** True when the provider needs the payer's authenticated email (hosted card checkout). */
  readonly requiresPayerEmail?: boolean;
  /** Absent: any positive integer amount is fine. M-Pesa needs whole shillings. */
  acceptsAmountCents?(amountCents: number): boolean;
  initiate(
    order: GatewayOrder,
    attempt: GatewayAttempt,
    payer: GatewayPayer,
  ): Promise<InitiateResult>;
  /** Ask the provider directly about an attempt (fallback when no callback arrived). */
  queryStatus?(providerReference: string): Promise<StatusQueryResult>;
  /** Verifies authenticity itself and throws on a forged or malformed callback. */
  parseCallback(request: CallbackRequest): Promise<VerifiedOutcome>;
}
