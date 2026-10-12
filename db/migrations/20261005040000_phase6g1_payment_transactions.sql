-- =============================================================================
-- PHASE 6G.1 - payment_transactions ledger table + security ONLY. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005030000. One transaction.
--
-- ADDS: enum public.payment_transaction_status and table public.payment_transactions.
-- DOES NOT: add any function, provider/M-Pesa/card code or webhook, change orders, orders.status,
--   orders.payment_status, inventory, delivery or customers, or touch any earlier migration.
--
-- The status here is the status of ONE payment attempt. It is separate from orders.status and
-- orders.payment_status and never changes them. Nothing in this migration marks anything paid.
-- Money is integer cents. No secrets, card data or raw provider payload are stored.
--
-- ACCESS: RLS on. SELECT only: a customer reads rows of their own orders; staff/admin read all.
--   anon has no privilege at all. public/anon/authenticated have no INSERT/UPDATE/DELETE/TRUNCATE.
--   Only service_role (server-side) keeps full access, as on the other tables.
-- INDEXES: order_id, status, created_at, plus the two uniqueness rules the spec requires
--   (idempotency_key; provider + provider_reference when provider_reference is not null).
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.orders') is null
     or not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                    where n.nspname = 'public' and t.typname = 'payment_method')
     or to_regprocedure('public.set_updated_at()') is null
     or to_regprocedure('public.is_staff(uuid)') is null
     or to_regprocedure('public.require_admin()') is null then
    raise exception 'Phase 6G.1 precondition failed: apply migrations up to 20261005030000 first.';
  end if;
  if to_regclass('public.payment_transactions') is not null
     or exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                where n.nspname = 'public' and t.typname = 'payment_transaction_status') then
    raise exception 'Phase 6G.1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. Enum (one payment attempt; separate from order status and order payment status)
create type public.payment_transaction_status as enum
  ('pending', 'processing', 'succeeded', 'failed', 'cancelled', 'expired');

-- 2. Table
create table public.payment_transactions (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid not null references public.orders (id) on delete restrict,
  provider           text not null,
  method             public.payment_method not null,
  amount_cents       integer not null,
  currency           text not null default 'KES',
  status             public.payment_transaction_status not null default 'pending',
  provider_reference text,
  idempotency_key    text not null,
  failure_code       text,
  failure_message    text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  completed_at       timestamptz,

  constraint payment_transactions_amount_positive check (amount_cents > 0),
  constraint payment_transactions_currency_format check (currency ~ '^[A-Z]{3}$'),
  constraint payment_transactions_provider_length check (char_length(provider) between 1 and 40),
  constraint payment_transactions_reference_length
    check (provider_reference is null or char_length(provider_reference) between 1 and 200),
  constraint payment_transactions_idempotency_key_length check (char_length(idempotency_key) between 1 and 200),
  constraint payment_transactions_failure_code_length
    check (failure_code is null or char_length(failure_code) <= 80),
  constraint payment_transactions_failure_message_length
    check (failure_message is null or char_length(failure_message) <= 500),
  constraint payment_transactions_idempotency_key_key unique (idempotency_key)
);

comment on table public.payment_transactions is
  'Ledger of payment attempts per order. Written only server-side (service_role / future SECURITY DEFINER functions). No secrets, card data or raw provider payloads.';

-- Provider references are unique per provider, but only when present.
create unique index payment_transactions_provider_reference_key
  on public.payment_transactions (provider, provider_reference)
  where provider_reference is not null;

create index payment_transactions_order_id_idx   on public.payment_transactions (order_id);
create index payment_transactions_status_idx     on public.payment_transactions (status);
create index payment_transactions_created_at_idx on public.payment_transactions (created_at);

-- 3. updated_at
create trigger payment_transactions_set_updated_at
  before update on public.payment_transactions
  for each row execute function public.set_updated_at();

-- 4. Privileges: nothing for public/anon; SELECT only for authenticated; no write privilege at all.
revoke all on public.payment_transactions from public, anon, authenticated;
grant select on public.payment_transactions to authenticated;
grant all on public.payment_transactions to service_role;

-- 5. RLS: read-only policies
alter table public.payment_transactions enable row level security;

create policy "Payment transactions: read own"
  on public.payment_transactions for select to authenticated
  using (exists (select 1 from public.orders o
                 where o.id = payment_transactions.order_id and o.user_id = auth.uid()));

create policy "Payment transactions: staff read all"
  on public.payment_transactions for select to authenticated
  using (public.is_staff(auth.uid()));

-- 6. Self-check: refuse to commit unless the table is locked down as designed.
do $chk$
declare
  v_priv text;
  v_role text;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.payment_transactions'::regclass) then
    raise exception 'Phase 6G.1 self-check failed: RLS is not enabled.';
  end if;

  foreach v_role in array array['anon', 'authenticated'] loop
    foreach v_priv in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      if has_table_privilege(v_role, 'public.payment_transactions', v_priv) then
        raise exception 'Phase 6G.1 self-check failed: % still has % on payment_transactions.', v_role, v_priv;
      end if;
    end loop;
  end loop;

  if has_table_privilege('anon', 'public.payment_transactions', 'SELECT') then
    raise exception 'Phase 6G.1 self-check failed: anon can SELECT payment_transactions.';
  end if;
  if not has_table_privilege('authenticated', 'public.payment_transactions', 'SELECT') then
    raise exception 'Phase 6G.1 self-check failed: authenticated cannot SELECT (RLS needs the grant).';
  end if;

  -- PUBLIC pseudo-role (grantee 0) and any column-level grants to browser roles
  if exists (select 1 from pg_class c, aclexplode(c.relacl) a
             where c.oid = 'public.payment_transactions'::regclass
               and (a.grantee = 0
                    or (a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated'))
                        and a.privilege_type <> 'SELECT'))) then
    raise exception 'Phase 6G.1 self-check failed: unexpected table privilege on payment_transactions.';
  end if;
  if exists (select 1 from information_schema.column_privileges cp
             where cp.table_schema = 'public' and cp.table_name = 'payment_transactions'
               and cp.grantee in ('PUBLIC', 'anon', 'authenticated')
               and cp.privilege_type in ('INSERT', 'UPDATE')) then
    raise exception 'Phase 6G.1 self-check failed: column-level write privilege remains.';
  end if;
end
$chk$;

commit;
