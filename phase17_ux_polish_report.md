# Phase 17: UX polish report

Branch `phase-17-ux-polish` (from `phase-16-responsive`). **Everything below is code-reviewed only.** The sandbox has no network, so `npm ci` failed (`ENOTFOUND`): no `tsc`, `eslint`, `prettier`, `npm test`, `vite build` or browser was run. The only check I ran was a syntax-only parse (TypeScript `transpileModule`) of every changed `.ts`/`.tsx` file: no syntax errors. No Lighthouse or CLS numbers exist.

| Screen / area | Issue found | Fix | Status |
|---|---|---|---|
| All skeletons | Under reduced motion the shimmer ran once, then froze on an arbitrary frame | `.skeleton` is a flat block when reduced; shadcn `Skeleton` gets `motion-reduce:animate-none` | Unverified |
| All buttons (ui-kit) | No pressed feedback on touch | `active:scale-[0.98]`, 150 ms, transform only | Unverified |
| Category chips, filter chips, header icon/links, admin nav, home category tiles, product card | Colour changed with no transition, no press state | `transition-colors` / `transition` 150 ms, `active:` state on chips | Unverified |
| Toasts | Could stack beyond 3; could sit over the sticky buy bar on phones | `visibleToasts={3}`, `mobileOffset` bottom 5.5rem + safe area. Sonner already announces politely | Unverified |
| ProductImage | Placeholder was page-coloured | Flat `bg-surface-strong` behind the photo (ratio box and lazy/eager rules were already right) | Unverified |
| Other `<img>` | Missing `decoding`, size hints, lazy | Added on order items, search suggestions, admin product image, home category tiles | Unverified |
| Orders list, order detail, confirmation, account panels | Skeleton had no busy state | `role="status"`, `aria-busy`, label on the wrappers | Unverified |
| Shared error states | `QueryErrorState` printed raw `error.message`; `ErrorState` had no `role="alert"`, "Error · code" label, 404 label | Plain wording via `describeError`, raw error to console, `role="alert"`, eyebrow "Problem", "Try again", "Not found" | Unverified |
| Account address and profile save | Raw `cause.message` shown | Plain "couldn't reach the shop" / "couldn't save" wording, raw error to console | Unverified |
| Admin delivery forms (all 6), variants card, customer notes | No focus to first error (open since Phase 15) | `focusFirstInvalid()` (first `aria-invalid`, inside the open dialog if any), called from `useDeliveryAction`, variants card, notes card | Unverified |
| Route changes | Focus stayed on the old link | Root effect focuses the new page's `h1` (else `main`) on pathname change only, `preventScroll`; admin uses `#admin-main` | Unverified |

Already fine on reading, not changed: search suggestions (arrows, Esc, `aria-activedescendant`), dialogs and sheets (Radix: Esc and focus return), one `h1` per route, empty/error branches on list screens, add-to-basket and remove-with-Undo toasts, double-submit guards on the admin forms read.

## Needs follow-up
- Run `npm ci && npx prettier --write` and `npx eslint` on the 25 changed files, then `npx tsc --noEmit`, `npm test`, `vite build`. Not run here.
- Browser pass at 360/1280 px, reduced motion on/off, keyboard only (see `phase17_manual_qa_checklist.md`). Check especially the route-change focus (a focus ring on the heading after every nav may feel loud; if so, add `outline-none` to the focus target).
- Toast offset applies on every phone page, not only the product page; confirm it looks right.
- `auth.tsx` still shows the auth provider's message text; it is auth logic, left alone.
- Not done for lack of budget/tooling: skeleton-vs-final height comparison per screen, offline variants on each admin list, promo-apply pending state, checkout internals review.
