import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useEffect, type ReactNode } from "react";

import { useAdminNetworkMode } from "@/components/admin/use-admin-network-mode";
import { ConnectionBanner } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { adminAccessDeniedCopy } from "@/features/admin/admin-ui";
import { ADMIN_NAV, type AdminNavItem } from "@/features/admin/nav";
import { useAuth } from "@/features/auth/auth-provider";
import { isStaff, myRolesQuery } from "@/features/auth/roles";
import { useAdminIdleSignOut } from "@/features/auth/use-admin-idle-signout";
import { storeConfig } from "@/lib/env";
import { cn } from "@/lib/utils";

// min-h-11 = 44px: the nav is the one control a keyboard or thumb must hit on every page.
const ITEM_BASE =
  "flex min-h-11 items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm whitespace-nowrap transition focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary";

function NavItem({ item }: { item: AdminNavItem }) {
  if (!item.to) {
    // Not built yet: shown so the structure is visible, but not a link.
    return (
      <span
        aria-disabled="true"
        title="Not available yet"
        className={cn(ITEM_BASE, "cursor-not-allowed text-foreground/40")}
      >
        {item.label}
        <span className="eyebrow hidden text-[9px] md:inline">Soon</span>
      </span>
    );
  }
  return (
    <Link
      to={item.to}
      activeOptions={{ exact: item.exact === true }}
      className={cn(
        ITEM_BASE,
        "text-foreground/70 transition-colors duration-150 hover:bg-surface-strong hover:text-foreground",
      )}
      activeProps={{
        className: "bg-primary/10 font-medium text-primary hover:bg-primary/10",
      }}
    >
      {item.label}
      {item.soon ? (
        <span className="eyebrow rounded-full border border-border px-1.5 text-[9px] text-muted-foreground">
          Soon
        </span>
      ) : null}
    </Link>
  );
}

function AdminNav() {
  return (
    <nav aria-label="Admin" className="flex gap-4 md:flex-col md:gap-6">
      {ADMIN_NAV.map((group) => (
        <div
          key={group.label}
          className="flex items-center gap-1 md:flex-col md:items-stretch"
        >
          <div className="eyebrow hidden px-3 pb-1 text-muted-foreground md:block">
            {group.label}
          </div>
          {group.items.map((item) => (
            <NavItem key={item.key} item={item} />
          ))}
        </div>
      ))}
    </nav>
  );
}

/**
 * Admin layout: sidebar on wide screens, a scrolling nav strip on narrow ones. Only rendered
 * once the database has confirmed the caller is an admin (see the /admin route).
 */
export function AdminShell({ children }: { children: ReactNode }) {
  const { user, signOut } = useAuth();
  useAdminIdleSignOut();
  useAdminNetworkMode();
  // Dialogs render in portals outside this component, so the 44px touch rule in styles.css keys
  // off a class on <body> that exists only while the admin shell is mounted. The storefront
  // never has it.
  useEffect(() => {
    document.body.classList.add("admin-active");
    return () => document.body.classList.remove("admin-active");
  }, []);

  return (
    <div className="admin-shell min-h-dvh bg-background text-foreground md:flex">
      <a
        href="#admin-main"
        className="sr-only focus:not-sr-only focus:absolute focus:left-3 focus:top-3 focus:z-50 focus:rounded-lg focus:bg-primary focus:px-4 focus:py-3 focus:text-sm focus:text-primary-foreground"
      >
        Skip to content
      </a>
      <aside className="border-b border-border bg-surface md:sticky md:top-0 md:h-dvh md:w-60 md:shrink-0 md:overflow-y-auto md:border-r md:border-b-0">
        <div className="flex items-center justify-between gap-3 px-5 py-4 md:block">
          <div>
            <Link
              to="/admin"
              className="inline-flex min-h-11 items-center font-display text-xl font-bold tracking-tight"
            >
              {storeConfig.name}
              <span className="text-primary">.</span>
            </Link>
            <div className="eyebrow mt-1 text-muted-foreground">Admin</div>
          </div>
          <Button
            asChild
            variant="ghost"
            size="touch"
            className="md:mt-3 md:px-0"
          >
            <Link to="/" search={{}}>
              ← Storefront
            </Link>
          </Button>
        </div>
        <div className="overflow-x-auto px-3 pb-3 md:pb-6">
          <AdminNav />
        </div>
      </aside>

      <div className="min-w-0 flex-1">
        <ConnectionBanner />
        <header className="flex flex-wrap items-center justify-end gap-3 border-b border-border px-5 py-3 md:px-8">
          <span
            className="truncate text-sm text-muted-foreground"
            title={user?.email ?? ""}
          >
            {user?.email ?? "Admin"}
          </span>
          <Button variant="outline" size="touch" onClick={() => void signOut()}>
            Sign out
          </Button>
        </header>
        <main
          id="admin-main"
          tabIndex={-1}
          className="px-5 py-8 outline-none md:px-8"
        >
          {children}
        </main>
      </div>
    </div>
  );
}

export function AdminPageHeader({
  title,
  description,
  actions,
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
}) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <div className="eyebrow text-muted-foreground">Admin</div>
        <h1 className="mt-2 font-display text-3xl font-semibold">{title}</h1>
        {description ? (
          <p className="mt-1 text-sm text-muted-foreground">{description}</p>
        ) : null}
      </div>
      {actions}
    </div>
  );
}

export function AdminAccessDenied() {
  const { signOut } = useAuth();
  // Words only. If this read fails or is slow the plain wording is used; nothing is granted.
  const roles = useQuery(myRolesQuery());
  const copy = adminAccessDeniedCopy(isStaff(roles.data));
  return (
    <div className="admin-shell flex min-h-dvh items-center justify-center bg-background px-4">
      <div role="alert" className="max-w-md text-center">
        <div className="eyebrow text-muted-foreground">403</div>
        <h1 className="mt-3 font-display text-2xl font-semibold">
          {copy.title}
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">{copy.message}</p>
        {copy.hint ? (
          <p className="mt-2 text-xs text-muted-foreground">{copy.hint}</p>
        ) : null}
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <Button asChild size="touch">
            <Link to="/" search={{}}>
              Back to the store
            </Link>
          </Button>
          <Button size="touch" variant="outline" onClick={() => void signOut()}>
            Sign out
          </Button>
        </div>
      </div>
    </div>
  );
}

/** Full-page placeholder while access is being confirmed. Reveals nothing about the admin area. */
export function AdminShellLoading() {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-background">
      <div className="space-y-3" role="status" aria-label="Loading admin">
        <div className="skeleton h-4 w-40 rounded-full" />
        <div className="skeleton h-4 w-28 rounded-full" />
      </div>
    </div>
  );
}
