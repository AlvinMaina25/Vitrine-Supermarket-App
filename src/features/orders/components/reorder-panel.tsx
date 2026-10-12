import { useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import {
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";

import { Button } from "@/components/ui-kit/button";
import { cartValidationQuery } from "@/features/cart/validation";
import { useCart } from "@/features/cart/cart-provider";
import { formatMoney } from "@/lib/format";
import type { OrderItemRow } from "@/lib/supabase/types";

import {
  buildReorderLines,
  planBasketChanges,
  planReorder,
  summariseReorder,
  type ReorderPlan,
  type ReorderSummary,
  type SkippedItem,
} from "../reorder";

/**
 * "Buy again". Adds an order's items to the BASKET only; it never places an order.
 *
 * The order's items are a snapshot, so every line is re-checked through the existing basket
 * validation (validate_cart() via cartValidationQuery). The database's answer decides what is
 * added, what is unavailable and what changed price; the old order's price is never reused.
 * The planning is in ../reorder.ts.
 */

type State =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "error" }
  | {
      kind: "done";
      plan: ReorderPlan;
      skipped: SkippedItem[];
      summary: ReorderSummary;
    };

const EMPTY_PLAN: ReorderPlan = {
  toAdd: [],
  added: [],
  unavailable: [],
  priceChanged: [],
  reduced: [],
};

export function ReorderPanel({
  items,
  currency,
}: {
  items: OrderItemRow[];
  currency: string;
}) {
  const cart = useCart();
  const queryClient = useQueryClient();
  const [state, setState] = useState<State>({ kind: "idle" });
  const running = useRef(false);
  const resultRef = useRef<HTMLDivElement>(null);

  // Move focus to the result so keyboard and screen-reader users land on it.
  useEffect(() => {
    if (state.kind === "done" || state.kind === "error") {
      resultRef.current?.focus();
    }
  }, [state.kind]);

  if (items.length === 0) return null;

  async function buyAgain() {
    if (running.current) return; // no double submit
    running.current = true;
    setState({ kind: "checking" });
    try {
      const { lines, skipped } = buildReorderLines(items);
      let plan = EMPTY_PLAN;
      if (lines.length > 0) {
        // Always ask the database now; a cached answer could be out of date.
        const issues = await queryClient.fetchQuery({
          ...cartValidationQuery(lines),
          staleTime: 0,
        });
        plan = planReorder(lines, issues);
      }

      const changes = planBasketChanges(plan.toAdd, cart.lines);
      for (const line of changes.restore) cart.restore(line);
      for (const update of changes.update) {
        cart.setQuantity(update.productId, update.quantity, update.variantId);
        cart.repriceLine(
          { productId: update.productId, variantId: update.variantId },
          update.priceCents,
        );
      }

      setState({
        kind: "done",
        plan,
        skipped,
        summary: summariseReorder(plan, skipped),
      });
    } catch (cause) {
      console.error("[reorder] availability check failed:", cause);
      setState({ kind: "error" });
    } finally {
      running.current = false;
    }
  }

  const checking = state.kind === "checking";

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <Button
          size="touch"
          onClick={() => void buyAgain()}
          disabled={checking}
          aria-busy={checking}
        >
          {checking ? "Checking availability…" : "Buy again"}
        </Button>
        <p className="max-w-[44ch] text-xs text-muted-foreground">
          Adds these items to your basket at today's prices if they're
          available. It doesn't place an order.
        </p>
      </div>

      {state.kind === "error" ? (
        <div
          ref={resultRef}
          tabIndex={-1}
          role="alert"
          className="rounded-(--radius-card) border border-danger/25 bg-danger/5 p-4 text-sm outline-none"
        >
          <p className="font-medium">We couldn't check availability.</p>
          <p className="mt-1 text-muted-foreground">
            Nothing was added to your basket. Check your connection and try
            again.
          </p>
        </div>
      ) : null}

      {state.kind === "done" ? (
        <ReorderResult
          resultRef={resultRef}
          plan={state.plan}
          skipped={state.skipped}
          summary={state.summary}
          currency={currency}
        />
      ) : null}
    </div>
  );
}

function ReorderResult({
  resultRef,
  plan,
  skipped,
  summary,
  currency,
}: {
  resultRef: RefObject<HTMLDivElement | null>;
  plan: ReorderPlan;
  skipped: SkippedItem[];
  summary: ReorderSummary;
  currency: string;
}) {
  const tone =
    summary.tone === "success"
      ? "border-primary/30 bg-primary/5"
      : summary.tone === "partial"
        ? "border-accent/40 bg-accent/10"
        : "border-danger/25 bg-danger/5";

  return (
    <div
      ref={resultRef}
      tabIndex={-1}
      role="status"
      className={`space-y-4 rounded-(--radius-card) border p-4 text-sm outline-none ${tone}`}
    >
      <p className="font-medium">{summary.headline}</p>

      {plan.added.length > 0 ? (
        <ResultList title="Added to your basket">
          {plan.added.map((line) => (
            <li key={`${line.name}-${line.variantName ?? ""}`}>
              {line.name}
              {line.variantName ? ` · ${line.variantName}` : ""} ×{" "}
              {line.quantity}
            </li>
          ))}
        </ResultList>
      ) : null}

      {plan.reduced.length > 0 ? (
        <ResultList title="Added fewer than you ordered (limited stock)">
          {plan.reduced.map((line) => (
            <li key={line.name}>
              {line.name}: added {line.added} of {line.requested}
            </li>
          ))}
        </ResultList>
      ) : null}

      {plan.priceChanged.length > 0 ? (
        <ResultList title="Price has changed since this order">
          {plan.priceChanged.map((line) => (
            <li key={line.name}>
              {line.name}: was {formatMoney(line.oldCents, currency)}, now{" "}
              {formatMoney(line.newCents)}
            </li>
          ))}
        </ResultList>
      ) : null}

      {plan.unavailable.length > 0 || skipped.length > 0 ? (
        <ResultList title="Not available">
          {plan.unavailable.map((line) => (
            <li key={line.name}>
              {line.name}: {line.reason}
            </li>
          ))}
          {skipped.map((line) => (
            <li key={`skipped-${line.name}`}>
              {line.name}: {line.reason}
            </li>
          ))}
        </ResultList>
      ) : null}

      {plan.added.length > 0 ? (
        <Button asChild size="touch" variant="outline">
          <Link to="/cart">Go to your basket</Link>
        </Button>
      ) : null}
    </div>
  );
}

function ResultList({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div>
      <h3 className="eyebrow text-muted-foreground">{title}</h3>
      <ul className="mt-1 list-disc space-y-0.5 pl-5 break-words">
        {children}
      </ul>
    </div>
  );
}
