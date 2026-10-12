-- =============================================================================
-- PHASE 6G.4-B - READ LOCKDOWN on payment_transactions ONLY. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005070000. One transaction. No new function, table, column or index.
--
-- WHY: after 6G.4-A all browser reads go through the three SECURITY DEFINER read functions
--   (admin_list_payment_transactions, admin_get_payment_transaction, get_my_order_payments), which
--   run as the table owner. Direct SELECT is therefore no longer needed - and would expose
--   provider_reference, failure_*, idempotency_key to customers through RLS.
--
-- DOES:
--   * revokes SELECT on payment_transactions from authenticated (and re-asserts none for anon/PUBLIC);
--   * drops both SELECT policies ("read own", "staff read all"); RLS stays enabled, so with no
--     policy and no privilege the table is closed to every browser role;
--   * revokes DELETE and TRUNCATE from service_role (append-only ledger); service_role keeps
--     SELECT / INSERT / UPDATE.
-- DOES NOT: weaken any 6G.1 write denial (anon/authenticated still hold no INSERT/UPDATE/DELETE/
--   TRUNCATE), change any function or its grants, or touch orders, inventory, delivery or customers.
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.payment_transactions') is null
     or to_regprocedure('public.get_order_for_payment(uuid)') is null
     or to_regprocedure('public.create_payment_attempt(uuid,text,public.payment_method,text)') is null
     or to_regprocedure('public.mark_payment_processing(uuid,text)') is null
     or to_regprocedure('public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)') is null
     or to_regprocedure('public.record_cod_payment(uuid,text)') is null
     or to_regprocedure('public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)') is null
     or to_regprocedure('public.admin_get_payment_transaction(uuid)') is null
     or to_regprocedure('public.get_my_order_payments(uuid)') is null then
    raise exception 'Phase 6G.4-B precondition failed: apply migrations up to 20261005070000 (6G.1-6G.4-A) first.';
  end if;

  -- Not applied yet = the 6G.1 read state is still in place.
  if not has_table_privilege('authenticated', 'public.payment_transactions', 'SELECT')
     and not exists (select 1 from pg_policy p
                     where p.polrelid = 'public.payment_transactions'::regclass and p.polcmd in ('r', '*')) then
    raise exception 'Phase 6G.4-B appears to be applied already. Not running it twice.';
  end if;
  if not has_table_privilege('authenticated', 'public.payment_transactions', 'SELECT')
     or not exists (select 1 from pg_policy p
                    where p.polrelid = 'public.payment_transactions'::regclass
                      and p.polname = 'Payment transactions: read own')
     or not exists (select 1 from pg_policy p
                    where p.polrelid = 'public.payment_transactions'::regclass
                      and p.polname = 'Payment transactions: staff read all') then
    raise exception 'Phase 6G.4-B precondition failed: payment_transactions is not in the 6G.1 read state (partly applied or changed by hand). Inspect before continuing.';
  end if;
end
$pre$;

-- 1. Policies: remove both SELECT policies. RLS stays enabled (default deny).
drop policy "Payment transactions: read own"       on public.payment_transactions;
drop policy "Payment transactions: staff read all" on public.payment_transactions;
alter table public.payment_transactions enable row level security;

-- 2. Privileges: no direct read for any browser role; append-only for service_role.
revoke select on public.payment_transactions from public, anon, authenticated;
revoke delete, truncate on public.payment_transactions from service_role;

-- 3. Self-check: refuse to commit unless the lockdown is exactly as designed.
do $chk$
declare
  v_role text;
  v_priv text;
  v_sig text;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.payment_transactions'::regclass) then
    raise exception 'Phase 6G.4-B self-check failed: RLS is not enabled.';
  end if;

  -- No SELECT (or ALL) policy of any kind remains.
  if exists (select 1 from pg_policy p
             where p.polrelid = 'public.payment_transactions'::regclass and p.polcmd in ('r', '*')) then
    raise exception 'Phase 6G.4-B self-check failed: a SELECT/ALL policy remains on payment_transactions.';
  end if;

  -- No SELECT for anon / authenticated / PUBLIC: table-level, raw ACL, column-level.
  foreach v_role in array array['anon', 'authenticated'] loop
    if has_table_privilege(v_role, 'public.payment_transactions', 'SELECT')
       or has_any_column_privilege(v_role, 'public.payment_transactions', 'SELECT') then
      raise exception 'Phase 6G.4-B self-check failed: % can still SELECT payment_transactions.', v_role;
    end if;
  end loop;
  if exists (select 1 from pg_class c, aclexplode(c.relacl) a
             where c.oid = 'public.payment_transactions'::regclass and a.privilege_type = 'SELECT'
               and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated')))) then
    raise exception 'Phase 6G.4-B self-check failed: table ACL still grants SELECT to PUBLIC/anon/authenticated.';
  end if;
  if exists (select 1 from pg_attribute at, aclexplode(at.attacl) a
             where at.attrelid = 'public.payment_transactions'::regclass and at.attacl is not null
               and a.privilege_type = 'SELECT'
               and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated')))) then
    raise exception 'Phase 6G.4-B self-check failed: a column ACL still grants SELECT to PUBLIC/anon/authenticated.';
  end if;

  -- 6G.1 write denials intact.
  foreach v_role in array array['anon', 'authenticated'] loop
    foreach v_priv in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      if has_table_privilege(v_role, 'public.payment_transactions', v_priv) then
        raise exception 'Phase 6G.4-B self-check failed: % has % on payment_transactions.', v_role, v_priv;
      end if;
    end loop;
  end loop;

  -- service_role: SELECT/INSERT/UPDATE yes; DELETE/TRUNCATE no.
  foreach v_priv in array array['SELECT', 'INSERT', 'UPDATE'] loop
    if not has_table_privilege('service_role', 'public.payment_transactions', v_priv) then
      raise exception 'Phase 6G.4-B self-check failed: service_role lost % on payment_transactions.', v_priv;
    end if;
  end loop;
  foreach v_priv in array array['DELETE', 'TRUNCATE'] loop
    if has_table_privilege('service_role', 'public.payment_transactions', v_priv) then
      raise exception 'Phase 6G.4-B self-check failed: service_role still has % on payment_transactions.', v_priv;
    end if;
  end loop;

  -- The three read functions still have the right grants.
  foreach v_sig in array array[
    'public.admin_list_payment_transactions(uuid,public.payment_transaction_status,text,timestamptz,timestamptz,integer,integer)',
    'public.admin_get_payment_transaction(uuid)',
    'public.get_my_order_payments(uuid)'] loop
    if has_function_privilege('anon', v_sig::regprocedure, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig::regprocedure, 'EXECUTE') then
      raise exception 'Phase 6G.4-B self-check failed: wrong execute privileges on %.', v_sig;
    end if;
  end loop;

  -- Server-side functions: executable by service_role, not by browser roles.
  foreach v_sig in array array[
    'public.get_order_for_payment(uuid)',
    'public.create_payment_attempt(uuid,text,public.payment_method,text)',
    'public.mark_payment_processing(uuid,text)',
    'public.apply_payment_outcome(uuid,public.payment_transaction_status,text,integer,text,text,text)'] loop
    if not has_function_privilege('service_role', v_sig::regprocedure, 'EXECUTE') then
      raise exception 'Phase 6G.4-B self-check failed: service_role cannot execute %.', v_sig;
    end if;
  end loop;

  -- record_cod_payment stays a customer function.
  if not has_function_privilege('authenticated', 'public.record_cod_payment(uuid,text)'::regprocedure, 'EXECUTE')
     or has_function_privilege('anon', 'public.record_cod_payment(uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'Phase 6G.4-B self-check failed: wrong execute privileges on record_cod_payment.';
  end if;
end
$chk$;

commit;
