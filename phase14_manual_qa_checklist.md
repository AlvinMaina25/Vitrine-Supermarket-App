# Phase 14 — manual QA checklist (real browser, real Supabase)

Nothing here has been seen in a browser by the developer. Test on a phone (360 px), a tablet (768 px) and a desktop (1280 px), signed in. No sideways scroll anywhere. You need: one customer with several orders (paid, awaiting payment, delivered, cancelled if possible), and a second customer account.

## Orders list
- [ ] Loading shows placeholders; then each order shows number, date, item count, total, **two** badges (order status and payment status), and View.
- [ ] Filters: All / In progress / Delivered / Cancelled or refunded change the list. A filter with no match shows "No orders in this view" and "Show all orders" works.
- [ ] No orders at all: empty state with "Browse the shelves".
- [ ] Go offline and reload: friendly "offline" message with "Try again" (no raw error text).
- [ ] At 360 px: long order numbers wrap, nothing scrolls sideways, View is at least 44 px tall.

## Order detail
- [ ] Heading is the order number. Items, totals, delivery (method, zone, window, fee, address) and payment match the order as placed.
- [ ] Change a product's price or name in admin: the old order does not change.
- [ ] Order status and payment status are shown separately.
- [ ] "What happens next" sentence matches the state (paid, waiting for payment, cash on delivery, cancelled, refunded).
- [ ] Unpaid card or M-Pesa order: the payment panel appears once (not duplicated). Paid order: no panel.
- [ ] **Another customer's order link**: sign in as customer B, open customer A's order URL → "We couldn't find that order". Same for a made-up id.

## Status history
- [ ] Entries match the real history rows, oldest first, with the stored times. Latest is highlighted.
- [ ] A payment change (e.g. failed) is marked "Payment" and does not look like an order step.
- [ ] A cancelled or refunded order ends with "Final status" in the danger colour, not as a step.
- [ ] No ETA, rider, location or invented time anywhere.
- [ ] A history note written by staff is shown: check it is safe for a customer to read (see report, open item 3).

## Buy again
- [ ] Press **Buy again** on a normal order: the button shows "Checking availability…" once (double-click does nothing extra); then "Added N items to your basket", a list of what was added, and "Go to your basket". Basket quantities are right and no duplicate lines appear. No order is created.
- [ ] Already have one of the items in the basket: its quantity increases, no duplicate line.
- [ ] **Order with an unavailable item**: in admin deactivate one product (or set its stock to 0) from an old order, then Buy again: that item is under "Not available" with a reason; the others are added; headline says "Added X of Y items".
- [ ] A product whose stock is lower than the ordered quantity: added with the lower amount, listed under "Added fewer than you ordered".
- [ ] Change a product's price in admin: the result lists "was … now …", and the basket shows the new price.
- [ ] Every item unavailable: "Nothing was added to your basket." in the red style, no "Go to your basket".
- [ ] An order with an item whose product was deleted: that item is skipped and listed.
- [ ] Go offline and press Buy again: error message, nothing added.
- [ ] Focus moves to the result message; a screen reader announces it.

## Profile
- [ ] Edit profile: every field has a visible label. A bad phone shows its message under the field and focus moves to it. A name over 120 characters shows a message.
- [ ] Press Save twice quickly: one save. Cancel works. Email is read-only.

## Addresses
- [ ] Add: submit empty → messages under name, phone, street, city; focus on the first (name). Fix them and save.
- [ ] Edit an address; set another as default: only one default at a time.
- [ ] Delete: "Delete" shows "Yes, delete / Keep it" with focus on "Keep it"; Keep it changes nothing; Yes, delete removes it. An old order still shows its own address copy.
- [ ] While one change saves, the other address buttons are disabled.
- [ ] Keyboard only: Tab order follows the screen order; focus is always visible.
- [ ] All buttons and inputs are at least 44 px tall at 360 px; the "default address" checkbox row is easy to tap.
