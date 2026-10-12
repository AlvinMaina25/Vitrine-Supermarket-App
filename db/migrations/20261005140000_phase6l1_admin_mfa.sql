-- =============================================================================
-- Phase 6L.1 - Admin two-factor sign-in (TOTP), database gate.
--
-- WHAT THIS ADDS
--   1. public.admin_security_settings : one row, require_mfa boolean NOT NULL DEFAULT false.
--      Enforcement ships OFF. No API role (anon, authenticated, service_role) can read or write
--      the table; only the owner (SQL Editor) flips it.
--   2. public.admin_mfa_satisfied()   : true when enforcement is off OR the caller's JWT says
--      aal = 'aal2'. A missing settings row counts as "off" (lockout-safe).
--   3. public.require_admin()         : same signature, grants, search_path and errcode as Phase
--      6A. After the existing admin check it raises 42501 / DETAIL 'mfa_required' when the caller
--      is a real admin whose session is not aal2 and enforcement is on. Non-admins and anonymous
--      callers still get exactly what they got before (not_authorised / permission denied).
--   4. The five remaining policies that admit admins through is_admin(auth.uid()) also require
--      admin_mfa_satisfied(). All five call is_admin() with auth.uid() only.
--
-- NOT CHANGED
--   is_admin(uuid) is untouched: the browser asks it "is this person an admin?" BEFORE MFA, to
--   decide between the enrol and challenge screens. Policies and functions that use is_staff() or
--   has_role() are untouched (see the Phase 6L.1 report for the list).
--
-- TURN ENFORCEMENT ON / OFF (SQL Editor, as owner):
--   update public.admin_security_settings set require_mfa = true;
--   update public.admin_security_settings set require_mfa = false;
-- Enrolment and challenge use Supabase Auth directly, not admin functions, so they keep working
-- while enforcement is on.
-- =============================================================================

-- ---- 0. Preconditions --------------------------------------------------------------------
do $pre$
begin
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null then
    raise exception 'Phase 6L.1 precondition failed: require_admin() / is_admin(uuid) are missing (Phase 5B.2 / 6A).';
  end if;
  if to_regclass('public.admin_security_settings') is not null then
    raise exception 'Phase 6L.1 precondition failed: public.admin_security_settings already exists.';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'products'       and policyname = 'Products: admin read all')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'product_variants' and policyname = 'Variants: admin read all')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'categories'     and policyname = 'Categories: admin read all')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'profiles'       and policyname = 'Profiles: admin read all')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_notes' and policyname = 'Customer notes: admin read') then
    raise exception 'Phase 6L.1 precondition failed: an expected admin read policy is missing (Phase 6A / 6E.3).';
  end if;
end
$pre$;

-- ---- 1. Settings table (owner-only) ------------------------------------------------------
create table public.admin_security_settings (
  id          boolean primary key default true check (id),   -- forces a single row
  require_mfa boolean not null default false
);

insert into public.admin_security_settings (id, require_mfa) values (true, false);

alter table public.admin_security_settings enable row level security;   -- no policies: deny by default
revoke all on public.admin_security_settings from public, anon, authenticated, service_role;

comment on table public.admin_security_settings is
  'Phase 6L.1. One row. require_mfa=true makes admin RPCs and admin RLS policies demand an aal2 session. Owner-only: no API role has any privilege on it.';

-- ---- 2. Helper ---------------------------------------------------------------------------
-- SECURITY DEFINER so it can read the owner-only table. It returns one boolean about the caller's
-- own session and the flag; it takes no argument and cannot be used to probe anyone else.
create or replace function public.admin_mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select not s.require_mfa from public.admin_security_settings s where s.id), true)
         or coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

-- authenticated needs EXECUTE because RLS policy expressions run with the caller's privileges.
revoke all on function public.admin_mfa_satisfied() from public, anon, authenticated;
grant execute on function public.admin_mfa_satisfied() to authenticated;

-- ---- 3. require_admin(): same contract, plus the MFA check for real admins ---------------
create or replace function public.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null or not public.is_admin(v_user) then
    raise exception 'You are not allowed to perform this admin action.'
      using errcode = '42501', detail = 'not_authorised';
  end if;
  if not public.admin_mfa_satisfied() then
    raise exception 'Two-factor sign-in is required for this admin action.'
      using errcode = '42501', detail = 'mfa_required';
  end if;
  return v_user;
end;
$$;

revoke all on function public.require_admin() from public, anon, authenticated;

-- ---- 4. Admin RLS policies (is_admin(auth.uid()) only) -----------------------------------
alter policy "Products: admin read all"       on public.products
  using (public.is_admin(auth.uid()) and public.admin_mfa_satisfied());
alter policy "Variants: admin read all"       on public.product_variants
  using (public.is_admin(auth.uid()) and public.admin_mfa_satisfied());
alter policy "Categories: admin read all"     on public.categories
  using (public.is_admin(auth.uid()) and public.admin_mfa_satisfied());
alter policy "Profiles: admin read all"       on public.profiles
  using (public.is_admin(auth.uid()) and public.admin_mfa_satisfied());
alter policy "Customer notes: admin read"     on public.customer_notes
  using (public.is_admin(auth.uid()) and public.admin_mfa_satisfied());

-- ---- 5. Self-check (aborts the whole transaction if anything is off) ---------------------
do $check$
declare
  v_role text;
  v_def  text;
begin
  if (select count(*) from public.admin_security_settings) <> 1
     or (select require_mfa from public.admin_security_settings) is distinct from false then
    raise exception 'Phase 6L.1 self-check failed: settings must hold exactly one row with require_mfa = false.';
  end if;
  foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
    if has_any_column_privilege(v_role, 'public.admin_security_settings'::regclass, 'SELECT, INSERT, UPDATE, REFERENCES')
       or has_table_privilege(v_role, 'public.admin_security_settings'::regclass, 'DELETE, TRUNCATE, TRIGGER') then
      raise exception 'Phase 6L.1 self-check failed: % holds a privilege on admin_security_settings.', v_role;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.require_admin()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.require_admin()', 'EXECUTE') then
    raise exception 'Phase 6L.1 self-check failed: a browser role can execute require_admin() directly.';
  end if;
  if has_function_privilege('anon', 'public.admin_mfa_satisfied()', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.admin_mfa_satisfied()', 'EXECUTE') then
    raise exception 'Phase 6L.1 self-check failed: admin_mfa_satisfied() grants are wrong.';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = 'public.require_admin()'::regprocedure
                 and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%') then
    raise exception 'Phase 6L.1 self-check failed: require_admin() lost SECURITY DEFINER or its search_path.';
  end if;
  for v_def in
    select pg_get_expr(pol.polqual, pol.polrelid)
    from pg_policy pol
    where (pol.polrelid, pol.polname) in (
      ('public.products'::regclass,       'Products: admin read all'),
      ('public.product_variants'::regclass, 'Variants: admin read all'),
      ('public.categories'::regclass,      'Categories: admin read all'),
      ('public.profiles'::regclass,        'Profiles: admin read all'),
      ('public.customer_notes'::regclass,  'Customer notes: admin read'))
  loop
    if v_def not like '%admin_mfa_satisfied%' or v_def not like '%is_admin%' then
      raise exception 'Phase 6L.1 self-check failed: an admin policy does not use the MFA helper.';
    end if;
  end loop;
end
$check$;
