import {
  deliveryErrorMessage,
  isDeliveryErrorCode,
  type DeliveryErrorCode,
} from "../delivery/checkout.ts";
import {
  couponErrorFromDetail,
  couponErrorMessage,
  type CouponErrorCode,
} from "../promotions/logic.ts";

/**
 * Turns a create_order() failure into an error checkout can reason about.
 *
 * create_order() raises delivery rejections as `raise exception '<message>' using errcode =
 * 'P0001', detail = '<code>'`. PostgREST returns the DETAIL as `details`, so the machine-readable
 * code is read from there, never parsed out of the human message. The original error is kept as
 * `cause` (and its fields copied) for debugging; only a recognised delivery code changes the
 * message the customer sees.
 */

/** The shape of a Supabase/PostgREST error, kept structural so this has no runtime imports. */
export interface PostgrestErrorLike {
  message: string;
  details?: string | null;
  hint?: string | null;
  code?: string | null;
}

const GENERIC_MESSAGE = "We couldn't place your order. Please try again.";

/** DETAIL create_order() raises (P0001) when the signed-in customer's account is suspended. */
export const ACCOUNT_SUSPENDED_CODE = "account_suspended";

/** Shown instead of the database message; deliberately says nothing about why or how. */
export const ACCOUNT_SUSPENDED_MESSAGE =
  "Your account can't place orders right now. Please contact the store for help.";

/** True when an exception DETAIL says the account is suspended. */
export function isAccountSuspendedDetail(detail: unknown): boolean {
  return typeof detail === "string" && detail.trim() === ACCOUNT_SUSPENDED_CODE;
}

/** Returns the delivery error code held in an exception DETAIL, or null if it holds none. */
export function extractDeliveryErrorCode(
  detail: unknown,
): DeliveryErrorCode | null {
  if (typeof detail !== "string") return null;
  const candidate = detail.trim();
  return isDeliveryErrorCode(candidate) ? candidate : null;
}

export class PlaceOrderError extends Error {
  override readonly name = "PlaceOrderError";
  /** Set only when the database rejected the delivery or slot choice. */
  readonly deliveryCode: DeliveryErrorCode | null;
  /** Set only when create_order() refused the coupon (DETAIL `coupon_<code>`). */
  readonly couponCode: CouponErrorCode | null;
  /** True when create_order() refused because the account is suspended. */
  readonly accountSuspended: boolean;
  /** The database's own message, for logs. Not shown to customers for delivery errors. */
  readonly databaseMessage: string | null;
  /** The raw exception DETAIL, as sent. */
  readonly databaseDetail: string | null;
  readonly databaseHint: string | null;
  /** The SQLSTATE, e.g. "P0001". */
  readonly databaseCode: string | null;

  constructor(
    message: string,
    options: {
      cause: unknown;
      deliveryCode?: DeliveryErrorCode | null;
      couponCode?: CouponErrorCode | null;
      accountSuspended?: boolean;
      databaseMessage?: string | null;
      databaseDetail?: string | null;
      databaseHint?: string | null;
      databaseCode?: string | null;
    },
  ) {
    super(message, { cause: options.cause });
    this.deliveryCode = options.deliveryCode ?? null;
    this.couponCode = options.couponCode ?? null;
    this.accountSuspended = options.accountSuspended ?? false;
    this.databaseMessage = options.databaseMessage ?? null;
    this.databaseDetail = options.databaseDetail ?? null;
    this.databaseHint = options.databaseHint ?? null;
    this.databaseCode = options.databaseCode ?? null;
  }
}

export function isPlaceOrderError(error: unknown): error is PlaceOrderError {
  return error instanceof PlaceOrderError;
}

function isPostgrestErrorLike(error: unknown): error is PostgrestErrorLike {
  return (
    typeof error === "object" &&
    error !== null &&
    typeof (error as { message?: unknown }).message === "string"
  );
}

/**
 * Wraps whatever placeOrder() caught. A delivery error gets the mapped customer message; any
 * other error keeps its own message, as before, so unrelated failures are not rewritten.
 */
export function toPlaceOrderError(error: unknown): PlaceOrderError {
  if (error instanceof PlaceOrderError) return error;

  if (!isPostgrestErrorLike(error)) {
    return new PlaceOrderError(GENERIC_MESSAGE, { cause: error });
  }

  const deliveryCode = extractDeliveryErrorCode(error.details);
  const couponCode = couponErrorFromDetail(error.details);
  const accountSuspended = isAccountSuspendedDetail(error.details);
  const message = accountSuspended
    ? ACCOUNT_SUSPENDED_MESSAGE
    : couponCode
      ? couponErrorMessage(couponCode)
      : deliveryCode
        ? deliveryErrorMessage(deliveryCode)
        : error.message.trim() || GENERIC_MESSAGE;

  return new PlaceOrderError(message, {
    cause: error,
    deliveryCode,
    couponCode,
    accountSuspended,
    databaseMessage: error.message,
    databaseDetail: error.details ?? null,
    databaseHint: error.hint ?? null,
    databaseCode: error.code ?? null,
  });
}
