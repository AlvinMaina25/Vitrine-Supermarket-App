import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Menu, ShoppingBasket, User } from "lucide-react";

import { SearchBox } from "@/components/layout/search-box";
import { Button } from "@/components/ui-kit/button";
import {
  Sheet,
  SheetClose,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { useAuth } from "@/features/auth/auth-provider";
import { useCart } from "@/features/cart/cart-provider";
import { categoriesQuery } from "@/features/catalog/queries";
import { isSupabaseConfigured, storeConfig } from "@/lib/env";

const MENU_LINK =
  "flex min-h-11 items-center rounded-lg px-3 text-base transition-colors duration-150 hover:bg-surface-strong data-[status=active]:font-semibold data-[status=active]:text-primary";

function MobileMenu() {
  const { user, signOut } = useAuth();
  const { data: categories } = useQuery({
    ...categoriesQuery(),
    enabled: isSupabaseConfigured,
  });
  return (
    <Sheet>
      <SheetTrigger asChild>
        <button
          type="button"
          aria-label="Open menu"
          className="grid size-11 shrink-0 place-items-center rounded-full transition-colors duration-150 hover:bg-surface-strong active:bg-surface-strong md:hidden"
        >
          <Menu aria-hidden className="size-5" />
        </button>
      </SheetTrigger>
      <SheetContent side="left" className="w-[85vw] max-w-sm overflow-y-auto">
        <SheetHeader className="text-left">
          <SheetTitle className="font-display">{storeConfig.name}</SheetTitle>
          <SheetDescription className="sr-only">
            Browse categories, your basket and your account.
          </SheetDescription>
        </SheetHeader>
        <nav aria-label="Menu" className="mt-4 space-y-1">
          <SheetClose asChild>
            <Link to="/" search={{}} className={MENU_LINK}>
              Shop all
            </Link>
          </SheetClose>
          {categories?.map((category) => (
            <SheetClose asChild key={category.id}>
              <Link
                to="/category/$slug"
                params={{ slug: category.slug }}
                className={MENU_LINK}
              >
                {category.name}
              </Link>
            </SheetClose>
          ))}
          <div className="my-2 border-t border-border" />
          <SheetClose asChild>
            <Link to="/cart" className={MENU_LINK}>
              Basket
            </Link>
          </SheetClose>
          {user ? (
            <>
              <SheetClose asChild>
                <Link to="/account" className={MENU_LINK}>
                  Account
                </Link>
              </SheetClose>
              <button
                type="button"
                className={`${MENU_LINK} w-full text-left`}
                onClick={() => void signOut()}
              >
                Sign out
              </button>
            </>
          ) : (
            <SheetClose asChild>
              <Link to="/auth" className={MENU_LINK}>
                Sign in
              </Link>
            </SheetClose>
          )}
        </nav>
      </SheetContent>
    </Sheet>
  );
}

export function StoreHeader() {
  const { itemCount, hydrated } = useCart();
  const { user, loading, signOut } = useAuth();
  const count = hydrated ? itemCount : 0;

  return (
    <header className="sticky top-0 z-40 border-b border-border bg-background/90 backdrop-blur-xl">
      <div className="mx-auto flex max-w-[1400px] flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2 sm:px-5 md:flex-nowrap md:gap-4 md:py-3">
        <MobileMenu />
        <Link
          to="/"
          search={{}}
          className="flex min-h-11 items-center font-display text-[22px] font-bold tracking-tight"
        >
          {storeConfig.name}
          <span className="text-primary">.</span>
        </Link>

        <div className="order-last w-full md:order-none md:ml-2 md:w-auto md:max-w-2xl md:flex-1">
          <SearchBox />
        </div>

        <div className="ml-auto flex items-center gap-1 md:ml-0 md:gap-2">
          <div className="hidden items-center gap-1 md:flex">
            {loading ? (
              <span className="skeleton h-11 w-24 rounded-full" />
            ) : user ? (
              <>
                <Button asChild variant="ghost" size="touch">
                  <Link to="/account">
                    <User aria-hidden className="size-4" /> Account
                  </Link>
                </Button>
                <Button
                  variant="outline"
                  size="touch"
                  onClick={() => void signOut()}
                >
                  Sign out
                </Button>
              </>
            ) : (
              <Button asChild size="touch">
                <Link to="/auth">Sign in</Link>
              </Button>
            )}
          </div>
          <Link
            to="/cart"
            aria-label={`Basket, ${count} ${count === 1 ? "item" : "items"}`}
            className="relative grid size-11 shrink-0 place-items-center rounded-full border border-border bg-surface-strong hover:bg-background data-[status=active]:border-primary"
          >
            <ShoppingBasket aria-hidden className="size-5" />
            {count > 0 ? (
              <span
                aria-hidden
                className="absolute -top-1 -right-1 grid min-w-5 place-items-center rounded-full bg-primary px-1 text-[11px] leading-5 font-semibold text-primary-foreground tabular-nums"
              >
                {count > 99 ? "99+" : count}
              </span>
            ) : null}
          </Link>
        </div>
      </div>
    </header>
  );
}
