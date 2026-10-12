import { useQuery } from "@tanstack/react-query";
import { useNavigate, useRouterState } from "@tanstack/react-router";
import { Search, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import {
  debounce,
  normalizeSearchTerm,
  stockLabel,
  stockState,
} from "@/features/catalog/browse";
import { suggestProducts } from "@/features/catalog/discovery";
import { productsQuery } from "@/features/catalog/queries";
import { isSupabaseConfigured } from "@/lib/env";
import { formatPrice } from "@/lib/format";

/** Wait this long after the last keystroke before the URL (and results) update. */
export const SEARCH_DEBOUNCE_MS = 350;
/** Away from the home page, typing only navigates once there are at least this many characters. */
const MIN_CHARS_TO_LEAVE_PAGE = 2;

/**
 * Header search. The query lives in the URL (`/?q=...`) so results can be shared, reloaded and
 * reached with the back button. Typing updates the URL after a pause (replacing the history
 * entry, so Back is not flooded); Enter searches immediately; Escape clears.
 */
export function SearchBox({ id = "store-search" }: { id?: string }) {
  const navigate = useNavigate();
  const urlTerm = useRouterState({
    select: (state) =>
      normalizeSearchTerm(
        (state.location.search as Record<string, unknown>)["q"],
      ),
  });
  const onHome = useRouterState({
    select: (state) => state.location.pathname === "/",
  });

  const [term, setTerm] = useState(urlTerm);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const listId = `${id}-suggestions`;
  const catalogue = useQuery({
    ...productsQuery(),
    enabled:
      isSupabaseConfigured && open && normalizeSearchTerm(term).length >= 2,
  });
  const suggestions = useMemo(
    () => suggestProducts(catalogue.data ?? [], term, 6),
    [catalogue.data, term],
  );
  const listOpen = open && suggestions.length > 0;
  const inputRef = useRef<HTMLInputElement>(null);
  // The last value this component wrote to the URL; lets us tell our own writes from outside changes.
  const pushedRef = useRef(urlTerm);

  useEffect(() => {
    if (urlTerm === pushedRef.current) return;
    pushedRef.current = urlTerm;
    setTerm(urlTerm);
  }, [urlTerm]);

  function push(raw: string, replace: boolean) {
    const next = normalizeSearchTerm(raw);
    pushedRef.current = next;
    void navigate({
      to: "/",
      replace,
      search: (previous: Record<string, unknown>) => {
        const kept = onHome ? { ...previous } : {};
        delete kept["q"];
        return next ? { ...kept, q: next } : kept;
      },
    });
  }

  const pushRef = useRef(push);
  pushRef.current = push;
  const onHomeRef = useRef(onHome);
  onHomeRef.current = onHome;
  const debounced = useMemo(
    () =>
      debounce((value: string) => {
        const next = normalizeSearchTerm(value);
        if (!onHomeRef.current && next.length < MIN_CHARS_TO_LEAVE_PAGE) return;
        if (next === pushedRef.current) return;
        pushRef.current(value, true);
      }, SEARCH_DEBOUNCE_MS),
    [],
  );
  useEffect(() => () => debounced.cancel(), [debounced]);

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    const chosen = listOpen ? suggestions[active] : undefined;
    if (chosen) {
      debounced.cancel();
      setOpen(false);
      setActive(-1);
      inputRef.current?.blur();
      void navigate({ to: "/product/$slug", params: { slug: chosen.slug } });
      return;
    }
    setOpen(false);
    debounced.cancel();
    push(term, false);
    inputRef.current?.blur();
  }

  function clear() {
    debounced.cancel();
    setTerm("");
    if (pushedRef.current !== "") push("", true);
    inputRef.current?.focus();
  }

  return (
    <div className="relative w-full">
      <form
        role="search"
        onSubmit={onSubmit}
        className="flex min-h-11 w-full items-center gap-1 rounded-full border border-border bg-surface-strong pl-4 focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-primary"
      >
        <label htmlFor={id} className="sr-only">
          Search products
        </label>
        <Search aria-hidden className="size-4 shrink-0 text-muted-foreground" />
        <input
          ref={inputRef}
          id={id}
          type="search"
          enterKeyHint="search"
          autoComplete="off"
          spellCheck={false}
          value={term}
          maxLength={80}
          placeholder="Search products"
          role="combobox"
          aria-expanded={listOpen}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={
            listOpen && active >= 0 ? `${listId}-${active}` : undefined
          }
          onFocus={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          onChange={(event) => {
            setOpen(true);
            setActive(-1);
            setTerm(event.target.value);
            debounced(event.target.value);
          }}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              if (suggestions.length === 0) return;
              event.preventDefault();
              setOpen(true);
              const step = event.key === "ArrowDown" ? 1 : -1;
              // Cycles through -1 (no highlight, just the typed text) and each suggestion.
              setActive(
                (index) =>
                  ((index + 1 + step + suggestions.length + 1) %
                    (suggestions.length + 1)) -
                  1,
              );
              return;
            }
            if (event.key !== "Escape") return;
            if (listOpen) {
              event.preventDefault();
              setOpen(false);
              setActive(-1);
              return;
            }
            if (term !== "") {
              event.preventDefault();
              clear();
            } else {
              inputRef.current?.blur();
            }
          }}
          className="h-11 min-w-0 flex-1 appearance-none bg-transparent text-base text-foreground outline-none placeholder:text-muted-foreground [&::-webkit-search-cancel-button]:hidden"
        />
        {term ? (
          <button
            type="button"
            onClick={clear}
            aria-label="Clear search"
            className="grid size-11 shrink-0 place-items-center rounded-full text-muted-foreground hover:text-foreground"
          >
            <X aria-hidden className="size-4" />
          </button>
        ) : null}
      </form>
      {listOpen ? (
        <ul
          id={listId}
          role="listbox"
          aria-label="Product suggestions"
          className="absolute inset-x-0 top-full z-50 mt-2 overflow-hidden rounded-2xl border border-border bg-background shadow-lg"
        >
          {suggestions.map((product, index) => {
            const label = stockLabel(stockState(product));
            return (
              <li
                key={product.id}
                id={`${listId}-${index}`}
                role="option"
                aria-selected={index === active}
                onMouseDown={(event) => {
                  event.preventDefault();
                  setOpen(false);
                  void navigate({
                    to: "/product/$slug",
                    params: { slug: product.slug },
                  });
                }}
                className={`flex min-h-11 cursor-pointer items-center gap-3 px-3 py-2 text-sm ${index === active ? "bg-primary/10" : "hover:bg-surface-strong"}`}
              >
                {product.image_url ? (
                  <img
                    src={product.image_url}
                    alt=""
                    loading="lazy"
                    decoding="async"
                    width={40}
                    height={40}
                    className="size-10 shrink-0 rounded-lg object-cover"
                  />
                ) : (
                  <span
                    aria-hidden
                    className="size-10 shrink-0 rounded-lg bg-surface-strong"
                  />
                )}
                <span className="min-w-0 flex-1 truncate">{product.name}</span>
                <span className="shrink-0 text-right text-xs tabular-nums">
                  {formatPrice(product.price_cents)}
                  {label ? (
                    <span className="block text-muted-foreground">{label}</span>
                  ) : null}
                </span>
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}
