import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";

export const getRouter = () => {
  const queryClient = new QueryClient();

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    // Load a page's code when the pointer or finger nears its link, so the click feels instant.
    defaultPreload: "intent",
    defaultPreloadStaleTime: 0,
  });

  return router;
};
