import { createFileRoute } from "@tanstack/react-router";

// Flutterwave sends the customer back here. Redirect only: nothing is read or marked paid.
export const Route = createFileRoute("/api/public/card-return/$orderId")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const { handleCardReturnRequest } =
          await import("@/features/payments/card-server");
        return handleCardReturnRequest(params.orderId);
      },
    },
  },
});
