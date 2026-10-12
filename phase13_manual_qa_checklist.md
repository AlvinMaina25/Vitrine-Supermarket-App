# Phase 13 — manual QA checklist (real browser, real Supabase)

Nothing here has been seen in a browser by the developer. Test on a phone (360 px), a tablet (768 px) and a desktop (1280 px). No sideways scroll anywhere.

## Cart
- [ ] Each line shows a badge once the check finishes: "In stock", or "Only N left", "Unavailable", "Price changed: now KSh X each". No badge while loading.
- [ ] At 360 px the stepper and Remove fit; Remove may wrap below the stepper.
- [ ] Type a quantity above stock: it is set to the stock number and a message says why. Type 0: set to 1 and the message points to Remove.
- [ ] Remove a line, press Undo in the toast: the line returns with its quantity.
- [ ] Signed in: Subtotal matches checkout. Signed out: it says "Estimated subtotal" with the note.
- [ ] Offline or check failed: message with "Check again".
- [ ] Empty basket shows the empty state.

## Checkout (mobile and desktop)
- [ ] Summary lines show "KSh X each" (no line totals). Subtotal, delivery and total match the cart and the order afterwards.
- [ ] Apply and remove a coupon: discount and total change; a bad code shows the server message.
- [ ] Double-click Place order: one order only.

## M-Pesa (needs M-Pesa configured on the server)
- [ ] Place an M-Pesa order: you land on the confirmation page with the M-Pesa panel; payment status is not "paid".
- [ ] Empty or bad phone: inline message, focus returns to the box. Valid phone: a prompt arrives on the phone.
- [ ] While waiting: countdown visible, page updates by itself. Enter the PIN: panel says "Payment received" only after the server shows paid, and the payment badge agrees.
- [ ] **Failed payment**: use a wrong PIN or decline. Panel says it didn't go through, order still waiting for payment, "Try again" works.
- [ ] **Cancelled**: dismiss the prompt. Panel says the request was cancelled, "Try again" works.
- [ ] **Timed out**: do nothing for 90 s. Panel says "Still waiting for confirmation", no failure claim, no second prompt, "Check again" works.
- [ ] M-Pesa not configured: panel shows "That payment method is not available yet." after pressing the button; order stays awaiting payment.
- [ ] Reload during the wait and open the order from "Your orders": same state.
- [ ] Open another customer's order link: "We couldn't find that order".

## Confirmation
- [ ] Order number, items, delivery and slot, totals as stored, payment status, "What happens next", link to your orders.
- [ ] Cash on delivery order: next step says to have the exact amount ready.
