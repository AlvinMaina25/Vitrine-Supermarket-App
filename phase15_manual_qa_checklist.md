# Phase 15 — manual QA checklist (admin UI)

Run against a **real** Supabase project with three accounts: a customer, a staff member (no admin role), and an admin with two-factor enrolled. `npm run dev`, then work through the lists. Tick or write what you saw. Phase 15 was only ever seen against a mock backend, so this checklist is the first real check.

## Access (do these first)

- [ ] **Customer** opens `/admin`, then `/admin/orders`, `/admin/payments`, `/admin/promotions` directly by URL: full-page "Admin access required", **no admin nav, no data**, Sign out and Back to the store both work.
- [ ] **Staff** user opens the same URLs: same page, wording mentions staff access. No data anywhere.
- [ ] **Admin on a session without two-factor** is sent to the two-factor screen, not the admin UI (existing behaviour, untouched).
- [ ] While signed in as admin, remove the admin role in the database (or make an RPC refuse), reload a screen: the panel says "Your account is not permitted to…" with **"Nothing was loaded"**, no rows or cards, Try again and Sign out present.
- [ ] Idle sign-out still happens (existing behaviour, untouched).

## An action the server refuses

- [ ] With the admin role removed after the page loaded, press **Deactivate** on a promotion and confirm: a plain sentence appears on that card, nothing changed after refresh.
- [ ] Same with an **order status** change and a **stock adjustment**: plain sentence, no raw database text, data refreshed.

## Double-click on every action (watch the network tab; one request each)

- [ ] Create promotion (button double-clicked)
- [ ] Create promotion live → confirm button double-clicked
- [ ] Activate / Deactivate promotion → confirm button double-clicked
- [ ] Order status change
- [ ] Product save (edit) and product activate/deactivate
- [ ] Stock adjustment (confirm step)
- [ ] Customer status change and customer note save
- [ ] Any delivery save or active toggle

## Screens

- [ ] **Dashboard:** shows "As of …(Africa/Nairobi)"; Order value says it is **not revenue**; payments, delivery and catalogue blocks match what you expect from the database; Refresh works.
- [ ] **Payments:** read-only (no button changes a payment); status filter; paging; "View order" opens the right order; failed rows show the code and message.
- [ ] **Promotions:** new promotion is created **inactive** by default; ticking "Make it live now" asks for confirmation; bad input shows inline messages and focus jumps to the first bad field; a taken coupon code shows on the code field; "Find on this page" says it only searches this page.
- [ ] **Reports:** says "not available yet", shows no numbers.
- [ ] **Inventory → Low stock / Out of stock:** note explains the rule (1 to 10 units) and the counts agree with the dashboard.
- [ ] **Product create / edit, stock adjustment:** submit with a bad value, focus lands on the first bad field; error messages are read out for that field (screen reader).

## Mobile (360 px, real phone if possible)

- [ ] No sideways scrolling of the page on any admin screen (the nav strip and wide tables may scroll inside their own box).
- [ ] The nav strip is reachable with a thumb and with a keyboard (Tab through it; the focused item scrolls into view).
- [ ] Every button, select and input is easy to hit (44 px). Dialog buttons too.
- [ ] Payments and Promotions read as stacked cards.
- [ ] Press Tab once on any admin page: **Skip to content** appears and works.

## Desktop (768 and 1280 px)

- [ ] Sidebar at 768+, tables readable, no horizontal page scroll.
- [ ] Focus ring visible on nav, buttons, inputs.
- [ ] Contrast of grey helper text, badges and error text looks fine (measure with a tool; not measured in Phase 15).

## Offline (DevTools → Offline, **do not navigate while offline**)

- [ ] Banner "You're offline" appears.
- [ ] Press Refresh on the dashboard (or Try again on a screen): "You appear to be offline" with Try again; going back online and pressing it restores the data.
- [ ] Press an action button while offline: "…nothing was changed", and after going back online **nothing happens by itself**.
- [ ] Known issue to confirm: navigating to another admin page while offline sends you to the sign-in page (auth guard, not changed in this phase).

## After leaving admin

- [ ] Click "← Storefront": storefront buttons keep their normal sizes (the 44 px admin rule must not apply).
