import { createFileRoute } from "@tanstack/react-router";

// Flutterwave calls this URL for card payment events. The verif-hash header is checked server-side.
export const Route = createFileRoute("/api/public/card-webhook")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { handleCardWebhookRequest } =
          await import("@/features/payments/card-server");
        return handleCardWebhookRequest(request);
      },
    },
  },
});
