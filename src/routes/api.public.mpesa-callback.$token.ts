import { createFileRoute } from "@tanstack/react-router";

// Daraja calls this URL after an STK push. The secret path token is checked server-side.
export const Route = createFileRoute("/api/public/mpesa-callback/$token")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { handleMpesaCallbackRequest } =
          await import("@/features/payments/mpesa-server");
        return handleMpesaCallbackRequest(request);
      },
    },
  },
});
