import type { PaymentGateway, PaymentMethodId } from "./payment-providers.ts";
import { codGateway } from "./providers/cod.ts";

/**
 * Gateways that can actually be used. M-Pesa (6H.2) and card (6H.3) are added here when their
 * provider files exist; until then selecting them returns null and nothing is charged.
 */
export const GATEWAYS: readonly PaymentGateway[] = [codGateway];

export function selectGateway(
  method: PaymentMethodId,
  gateways: readonly PaymentGateway[] = GATEWAYS,
): PaymentGateway | null {
  return gateways.find((gateway) => gateway.method === method) ?? null;
}
