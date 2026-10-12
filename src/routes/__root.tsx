import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  useRouterState,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, useRef, type ReactNode } from "react";

import appCss from "../styles.css?url";
import { reportLovableError } from "../lib/lovable-error-reporting";
import { StoreFooter } from "@/components/layout/store-footer";
import { StoreHeader } from "@/components/layout/store-header";
import { ConnectionBanner, NotFoundState } from "@/components/states/states";
import { AuthProvider } from "@/features/auth/auth-provider";
import { CartProvider } from "@/features/cart/cart-provider";
import { storeConfig, supabaseConfig } from "@/lib/env";
import { Toaster } from "@/components/ui/sonner";

function NotFoundComponent() {
  return (
    <div className="mx-auto max-w-2xl px-4 py-12 sm:px-5">
      <NotFoundState
        title="Page not found"
        message="The page you're looking for doesn't exist or has been moved."
      />
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportLovableError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-dvh items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="font-display text-xl font-semibold tracking-tight text-foreground">
          This page didn't load
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Something went wrong on our end. You can try refreshing or head back
          home.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-full bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/85"
          >
            Try again
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-full border border-border bg-surface-strong px-4 py-2 text-sm font-medium text-foreground transition-colors"
          >
            Go home
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()(
  {
    head: () => ({
      meta: [
        { charSet: "utf-8" },
        { name: "viewport", content: "width=device-width, initial-scale=1" },
        { title: `${storeConfig.name} — fresh groceries, delivered` },
        {
          name: "description",
          content: `${storeConfig.name} is an online supermarket for fresh produce, bakery, dairy and pantry staples.`,
        },
        { property: "og:site_name", content: storeConfig.name },
        { property: "og:type", content: "website" },
        { name: "twitter:card", content: "summary_large_image" },
      ],
      links: [
        { rel: "stylesheet", href: appCss },
        // Open the connection to Supabase early: the shop's first data request starts right after
        // the page loads, and this saves the DNS + TLS wait on that first request.
        ...(supabaseConfig.url
          ? [
              {
                rel: "preconnect",
                href: supabaseConfig.url,
                crossOrigin: "anonymous" as const,
              },
            ]
          : []),
        { rel: "preconnect", href: "https://fonts.googleapis.com" },
        {
          rel: "preconnect",
          href: "https://fonts.gstatic.com",
          crossOrigin: "anonymous",
        },
        {
          rel: "stylesheet",
          href: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Playfair+Display:wght@600;700&family=JetBrains+Mono:wght@400;500&display=swap",
        },
        { rel: "icon", href: "/favicon.ico", sizes: "48x48" },
        {
          rel: "icon",
          href: "/favicon-32.png",
          type: "image/png",
          sizes: "32x32",
        },
        {
          rel: "icon",
          href: "/favicon-16.png",
          type: "image/png",
          sizes: "16x16",
        },
        { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
      ],
    }),
    shellComponent: RootShell,
    component: RootComponent,
    notFoundComponent: NotFoundComponent,
    errorComponent: ErrorComponent,
  },
);

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();
  // The admin area brings its own shell; the storefront header and footer do not belong there.
  const isAdminArea = useRouterState({
    select: (state) =>
      state.location.pathname === "/admin" ||
      state.location.pathname.startsWith("/admin/"),
  });

  // After a page change, move focus to the new page's heading (or the main area) so keyboard and
  // screen-reader users start at the top of the new page. Pathname only: filter and search edits
  // on the same page must not pull focus away from the control being used.
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  });
  const previousPath = useRef(pathname);
  useEffect(() => {
    if (previousPath.current === pathname) return;
    previousPath.current = pathname;
    const main = document.getElementById(isAdminArea ? "admin-main" : "main");
    const target = main?.querySelector<HTMLElement>("h1") ?? main;
    if (!target) return;
    if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1");
    target.focus({ preventScroll: true });
  }, [pathname, isAdminArea]);

  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <CartProvider>
          <div className="min-h-dvh bg-background text-foreground">
            {isAdminArea ? null : (
              <a href="#main" className="skip-link">
                Skip to main content
              </a>
            )}
            {isAdminArea ? null : <StoreHeader />}
            {isAdminArea ? null : <ConnectionBanner />}
            {/* Required: nested routes render here. */}
            {isAdminArea ? (
              <Outlet />
            ) : (
              <main id="main" tabIndex={-1} className="outline-none">
                <Outlet />
              </main>
            )}
            {isAdminArea ? null : <StoreFooter />}
          </div>
          {/* Only the product page has a fixed buy bar on phones; lift toasts clear of it there. */}
          <Toaster
            {...(pathname.startsWith("/product/")
              ? {
                  mobileOffset: {
                    bottom: "calc(5.5rem + env(safe-area-inset-bottom))",
                  },
                }
              : {})}
          />
        </CartProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}
