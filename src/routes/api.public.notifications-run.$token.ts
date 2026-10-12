import { createFileRoute } from "@tanstack/react-router";

// Outbox worker trigger (for a scheduler). Guarded by its own secret path token.
export const Route = createFileRoute("/api/public/notifications-run/$token")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { handleNotificationsRunRequest } =
          await import("@/features/notifications/server");
        return handleNotificationsRunRequest(request);
      },
    },
  },
});
