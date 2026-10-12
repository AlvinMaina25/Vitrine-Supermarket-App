import { createFileRoute } from "@tanstack/react-router";

// STK Query fallback trigger (for a scheduler). Guarded by its own secret path token.
export const Route = createFileRoute("/api/public/mpesa-reconcile/$token")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { handleMpesaReconcileRequest } =
          await import("@/features/payments/mpesa-server");
        return handleMpesaReconcileRequest(request);
      },
    },
  },
});
