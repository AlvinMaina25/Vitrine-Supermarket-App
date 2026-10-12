import { queryOptions } from "@tanstack/react-query";

import {
  toAdminListPaymentTransactionsArgs,
  toAdminPaymentReadError,
  toAdminPaymentTransactionList,
  type AdminPaymentTransactionQuery,
} from "@/features/payments/payment-read-result";
import { requireSupabase } from "@/lib/supabase/client";

/**
 * Phase 15: read-only payment attempts for admins. One RPC, admin_list_payment_transactions(),
 * which the database gates with require_admin(). Nothing here writes: the UI has no way to mark a
 * payment paid or edit a payment status. The parser and argument builder are the existing ones
 * in features/payments (imported, not changed).
 */
export const ADMIN_PAYMENTS_PAGE_SIZE = 25;

export const adminPaymentsQuery = (query: AdminPaymentTransactionQuery = {}) =>
  queryOptions({
    queryKey: [
      "admin",
      "payments",
      toAdminListPaymentTransactionsArgs({
        limit: ADMIN_PAYMENTS_PAGE_SIZE,
        ...query,
      }),
    ],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_payment_transactions",
        toAdminListPaymentTransactionsArgs({
          limit: ADMIN_PAYMENTS_PAGE_SIZE,
          ...query,
        }),
      );
      if (error) throw toAdminPaymentReadError(error);
      return toAdminPaymentTransactionList(data);
    },
  });
