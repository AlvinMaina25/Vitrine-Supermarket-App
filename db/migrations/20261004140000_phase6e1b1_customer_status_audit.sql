-- =============================================================================
-- PHASE 6E.1B-1 - customer status + admin audit table + admin_set_customer_status().
-- NOT APPLIED / NOT RUN anywhere. Apply once, after 20261004130000. One transaction.
--
-- ADDS: public.admin_audit_log; profiles.status ('active'|'suspended', default 'active');
--       admin_set_customer_status(p_customer_id, p_status, p_reason) - ADMIN-ONLY (require_admin()).
-- DOES NOT: change create_order(), admin_list_customers(), admin_get_customer(), any grant on
--       profiles, or any earlier migration.
--
-- !! SUSPENSION IS NOT ENFORCED. A suspended customer can still sign in and place orders:
-- create_order() is SECURITY DEFINER and goes through no RLS or check that reads profiles.status.
-- Enforcing it needs a one-line check inside create_order() (a later, separately reviewed change).
-- =============================================================================
begin;

do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_staff(uuid)') is null
     or to_regprocedure('public.admin_get_customer(uuid)') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.user_roles') is null then
    raise exception 'Phase 6E.1B-1 precondition failed: apply 6A and 20261004130000 first.';
  end if;
  if to_regclass('public.admin_audit_log') is not null
     or exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'profiles' and column_name = 'status')
     or to_regprocedure('public.admin_set_customer_status(uuid,text,text)') is not null then
    raise exception 'Phase 6E.1B-1 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. Audit table (no general audit table existed). Staff read only; written only by
--    SECURITY DEFINER functions (no INSERT/UPDATE/DELETE grant or policy for browser roles).
create table public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users (id) on delete set null,
  action text not null check (char_length(action) between 1 and 80),
  target_id uuid,
  reason text check (reason is null or char_length(reason) <= 500),
  created_at timestamptz not null default now()
);
create index admin_audit_log_target_idx on public.admin_audit_log (target_id, created_at desc);

alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from public, anon, authenticated;
grant select on public.admin_audit_log to authenticated;
grant all on public.admin_audit_log to service_role;

create policy "Audit log: staff read"
  on public.admin_audit_log for select to authenticated
  using (public.is_staff(auth.uid()));

-- 2. profiles.status. Existing rows take the default. Customers keep UPDATE only on
--    (full_name, phone, avatar_url), so they cannot change it.
alter table public.profiles
  add column status text not null default 'active',
  add constraint profiles_status_check check (status in ('active', 'suspended'));

-- 3. admin_set_customer_status()
-- Returns { changed: true, customer_id, previous_status, status }.
-- Errors (after the admin gate): P0001 with DETAIL invalid_arguments, invalid_status,
-- reason_required, reason_too_long, cannot_target_self, customer_not_found,
-- cannot_target_staff, status_unchanged. Gate failure: 42501 / not_authorised.
create function public.admin_set_customer_status(p_customer_id uuid, p_status text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_prev text;
begin
  v_actor := public.require_admin();   -- gate first, before any argument is examined

  if p_customer_id is null or p_status is null then
    raise exception 'A customer and a status are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if p_status not in ('active', 'suspended') then
    raise exception 'Status must be active or suspended.'
      using errcode = 'P0001', detail = 'invalid_status';
  end if;
  if v_reason = '' then
    raise exception 'A reason is required.'
      using errcode = 'P0001', detail = 'reason_required';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason must be at most 500 characters.'
      using errcode = 'P0001', detail = 'reason_too_long';
  end if;
  if p_customer_id = v_actor then
    raise exception 'You cannot change your own account status.'
      using errcode = 'P0001', detail = 'cannot_target_self';
  end if;

  select p.status into v_prev from public.profiles p where p.id = p_customer_id for update;
  if not found then
    raise exception 'That customer could not be found.'
      using errcode = 'P0001', detail = 'customer_not_found';
  end if;

  if exists (select 1 from public.user_roles ur
             where ur.user_id = p_customer_id and ur.role in ('staff', 'admin')) then
    raise exception 'Staff and admin accounts cannot be changed here.'
      using errcode = 'P0001', detail = 'cannot_target_staff';
  end if;

  if v_prev = p_status then
    raise exception 'That customer is already %.', p_status
      using errcode = 'P0001', detail = 'status_unchanged';
  end if;

  update public.profiles set status = p_status where id = p_customer_id;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor,
          case p_status when 'suspended' then 'customer_suspended' else 'customer_reactivated' end,
          p_customer_id, v_reason);

  return jsonb_build_object('changed', true, 'customer_id', p_customer_id,
                            'previous_status', v_prev, 'status', p_status);
end;
$$;

comment on function public.admin_set_customer_status(uuid, text, text) is
  'Phase 6E.1B-1. Admin-only (require_admin()). Sets profiles.status and writes admin_audit_log in one transaction. Does NOT block ordering.';

revoke all on function public.admin_set_customer_status(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_set_customer_status(uuid, text, text) to authenticated;

-- 4. Self-check
do $check$
declare v_sig constant text := 'public.admin_set_customer_status(uuid,text,text)';
begin
  if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
             and (not p.prosecdef or p.provolatile <> 'v'
                  or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
    raise exception 'Phase 6E.1B-1 self-check failed: not VOLATILE SECURITY DEFINER with pinned search_path.';
  end if;
  if has_function_privilege('anon', v_sig, 'EXECUTE') or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
    raise exception 'Phase 6E.1B-1 self-check failed: function privileges are wrong.';
  end if;
  if has_table_privilege('authenticated', 'public.admin_audit_log', 'INSERT')
     or has_table_privilege('authenticated', 'public.admin_audit_log', 'UPDATE')
     or has_table_privilege('authenticated', 'public.admin_audit_log', 'DELETE')
     or has_table_privilege('anon', 'public.admin_audit_log', 'SELECT')
     or not (select relrowsecurity from pg_class where oid = 'public.admin_audit_log'::regclass) then
    raise exception 'Phase 6E.1B-1 self-check failed: audit table access is wrong.';
  end if;
  if has_column_privilege('authenticated', 'public.profiles', 'status', 'UPDATE')
     or has_column_privilege('anon', 'public.profiles', 'status', 'UPDATE') then
    raise exception 'Phase 6E.1B-1 self-check failed: a browser role can UPDATE profiles.status.';
  end if;
end
$check$;

commit;
