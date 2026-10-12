import { Link } from "@tanstack/react-router";

import { storeConfig } from "@/lib/env";

const LINK =
  "inline-flex min-h-11 min-w-11 items-center justify-center px-2 hover:text-foreground hover:underline";

export function StoreFooter() {
  return (
    <footer className="mt-12 border-t border-border bg-surface">
      <div className="mx-auto flex max-w-[1400px] flex-col gap-4 px-4 py-8 text-sm text-muted-foreground sm:px-5 md:flex-row md:items-center md:justify-between">
        <p className="font-display text-lg font-bold text-foreground">
          {storeConfig.name}
          <span className="text-primary">.</span>
        </p>
        <nav aria-label="Footer" className="flex flex-wrap gap-x-5">
          <Link to="/" search={{}} className={LINK}>
            Shop
          </Link>
          <Link to="/cart" className={LINK}>
            Basket
          </Link>
          <Link to="/account" className={LINK}>
            Account
          </Link>
        </nav>
        <p>
          © {new Date().getFullYear()} {storeConfig.name}
        </p>
      </div>
    </footer>
  );
}
