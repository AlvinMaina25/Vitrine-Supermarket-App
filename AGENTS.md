<!-- LOVABLE:BEGIN -->

> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.

<!-- LOVABLE:END -->

## Architecture rules

- Supabase is the user's own project via VITE_SUPABASE_* env (src/lib/supabase/client.ts); not Lovable Cloud — preserves the imported architecture.
- Schema lives in db/migrations/*.sql and src/lib/supabase/types.ts must mirror it — types are hand-kept until generated.
- Money is integer minor units (`*_cents`) — avoids float rounding.
- Customer data (profiles, addresses) is read via the browser client under RLS scoped to auth.uid(); user_id is never sent from the client — DB defaults it.
- Payment providers live in src/features/checkout/payment-providers.ts; orders are only marked paid by verified server webhooks — never from the browser.
