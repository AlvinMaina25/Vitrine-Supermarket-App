import { ClipboardList, CreditCard, Truck } from "lucide-react";

/**
 * Static reassurance copy. Deliberately generic and true to what the shop does today: delivery
 * areas, fees and slots are configured by staff and shown at checkout; cash on delivery is
 * available; other payment methods appear at checkout when enabled; orders can be followed from
 * the account. No claims about speed, freshness, stock or prices.
 */
const CUES = [
  {
    icon: Truck,
    title: "Delivery or pickup",
    text: "Delivery areas, fees and time slots are shown at checkout.",
  },
  {
    icon: CreditCard,
    title: "Pay your way",
    text: "Cash on delivery is available. Other payment options appear at checkout when enabled.",
  },
  {
    icon: ClipboardList,
    title: "Follow your order",
    text: "Sign in to see the status and details of every order you place.",
  },
] as const;

export function TrustStrip() {
  return (
    <section
      aria-label="How ordering works"
      className="mx-auto max-w-[1400px] px-4 pt-6 sm:px-5"
    >
      <ul className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        {CUES.map(({ icon: Icon, title, text }) => (
          <li
            key={title}
            className="flex items-start gap-3 rounded-(--radius-card) bg-surface p-4 outline-1 -outline-offset-1 outline-border"
          >
            <Icon aria-hidden className="mt-0.5 size-5 shrink-0 text-primary" />
            <div>
              <h2 className="font-body text-sm font-semibold">{title}</h2>
              <p className="mt-0.5 text-sm text-pretty text-muted-foreground">
                {text}
              </p>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
