# Phase 17 manual QA checklist
1. Phone 360 px: open a category, then a product; scroll until the sticky buy bar appears, tap Add. The toast must sit above the bar and not cover the button.
2. Phone: throttle to Slow 3G; catalog, product, cart and orders show skeletons that match the final layout with no jump when data arrives.
3. Tablet 768 px and desktop 1280 px: hover and press every button, chip, product card and nav link; colour change only, nothing shifts, press feels immediate.
4. Basket: remove a line, press Undo within the toast; trigger 4 toasts quickly and confirm no more than 3 show.
5. Keyboard only: Tab through header, catalog, product, cart, checkout; focus ring always visible; no traps.
6. Keyboard: search suggestions with Up/Down/Enter/Esc; Esc returns focus to the input; open and close a dialog and a sheet, focus returns to the trigger.
7. Submit an invalid admin delivery form (zone, fee, slot, method), the variants card and customer notes: focus lands on the first invalid field and the error is read out.
8. Navigate between pages with keyboard: focus lands on the new page heading; changing a filter does not move focus.
9. Reduced motion on: skeletons are flat (no shimmer), no scale or slide animations, nothing loops.
10. Screen reader smoke test (VoiceOver or NVDA): loading regions say loading, toasts are announced once, errors are read as alerts, icon buttons have names; go offline and check each list shows the offline message with Try again.
