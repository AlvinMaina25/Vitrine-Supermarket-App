-- =============================================================================
-- PHASE 6L.2 - Admin role management (backend). NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005140000_phase6l1_admin_mfa.sql. One transaction.
--
-- WHAT THIS ADDS (two functions, nothing else; no table, column, policy or grant on a table)
--   1. public.admin_set_user_role(p_user, p_role, p_action, p_reason)
--        Grants or revokes 'staff' / 'admin' in public.user_roles. SECURITY DEFINER; the gate is
--        require_admin(), so the Phase 6L.1 MFA rule applies (42501 / mfa_required at aal1 when
--        enforcement is on). Rules enforced here, in the database:
--          * p_action is 'grant' or 'revoke'; p_role is 'staff' or 'admin' ('customer' is refused);
--          * the reason is required, 3-200 characters after trimming;
--          * you cannot change your own role (even as a no-op);
--          * the target must exist in auth.users;
--          * granting a role already held, or revoking one not held, is a NO-OP: nothing changes,
--            NO audit row is written, and the result says changed = false;
--          * the last remaining admin can never be revoked (defence in depth: all role changes
--            are serialised by one advisory lock and the caller's own admin role is re-checked
--            under it, so two admins cannot revoke each other at the same moment);
--          * one admin_audit_log row per REAL change: action role_granted / role_revoked,
--            target_id = the user, reason = 'role <role>; <typed reason>'. No email, no name.
--   2. public.admin_list_role_holders()
--        require_admin(). Returns {"holders": [{user_id, role, granted_at}]} for staff and admin
--        rows only. No emails and no names (user_roles.created_at is returned as granted_at).
--
-- ACCESS: both functions are executable by `authenticated` only (revoked from PUBLIC, anon and
-- service_role). Non-admins get 42501 / not_authorised from require_admin().
--
-- ERRORS (SQLSTATE P0001, machine-readable DETAIL; 42501 for access):
--   invalid_arguments, invalid_action, invalid_role, reason_required, reason_too_short,
--   reason_too_long, cannot_change_own_role, user_not_found, last_admin.
--
-- NOT CHANGED: user_roles itself, is_admin(), is_staff(), has_role(), require_admin(), RLS.
-- Roles can still also be granted from the Supabase dashboard / SQL editor (that path is not audited).
-- =============================================================================

begin;

-- ---- 0. Preconditions ---------------------------------------------------------------------
do $pre$
begin
  if to_regclass('public.user_roles') is null
     or to_regclass('public.admin_audit_log') is null
     or to_regclass('auth.users') is null then
    raise exception 'Phase 6L.2 precondition failed: user_roles, admin_audit_log or auth.users is missing.';
  end if;
  if to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.admin_mfa_satisfied()') is null then
    raise exception 'Phase 6L.2 precondition failed: Phase 6L.1 (require_admin with MFA) is not applied.';
  end if;
  if to_regprocedure('public.admin_set_user_role(uuid,text,text,text)') is not null
     or to_regprocedure('public.admin_list_role_holders()') is not null then
    raise exception 'Phase 6L.2 precondition failed: the role-management functions already exist. Not running twice.';
  end if;
end
$pre$;

-- ---- 1. admin_set_user_role ---------------------------------------------------------------
create function public.admin_set_user_role(
  p_user   uuid,
  p_role   text,
  p_action text,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_len    integer;
  v_held   boolean;
begin
  v_actor := public.require_admin();   -- gate first (admin + MFA), before any argument is examined

  if p_user is null or p_role is null or p_action is null then
    raise exception 'A user, a role and an action are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;
  if p_action not in ('grant', 'revoke') then
    raise exception 'The action must be grant or revoke.'
      using errcode = 'P0001', detail = 'invalid_action';
  end if;
  if p_role not in ('staff', 'admin') then
    raise exception 'The role must be staff or admin.'
      using errcode = 'P0001', detail = 'invalid_role';
  end if;

  v_len := char_length(v_reason);
  if v_len = 0 then
    raise exception 'A reason is required.'
      using errcode = 'P0001', detail = 'reason_required';
  end if;
  if v_len < 3 then
    raise exception 'The reason must be at least 3 characters.'
      using errcode = 'P0001', detail = 'reason_too_short';
  end if;
  if v_len > 200 then
    raise exception 'The reason must be at most 200 characters.'
      using errcode = 'P0001', detail = 'reason_too_long';
  end if;

  if p_user = v_actor then
    raise exception 'You cannot change your own role.'
      using errcode = 'P0001', detail = 'cannot_change_own_role';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_user) then
    raise exception 'That user could not be found.'
      using errcode = 'P0001', detail = 'user_not_found';
  end if;

  -- Serialise every role change. Then make sure the caller is STILL an admin: require_admin()
  -- ran before the lock, so a concurrent change may have revoked them in between.
  perform pg_advisory_xact_lock(hashtextextended('public.admin_set_user_role', 0));

  if not exists (select 1 from public.user_roles ur
                 where ur.user_id = v_actor and ur.role = 'admin') then
    raise exception 'You are not allowed to perform this admin action.'
      using errcode = '42501', detail = 'not_authorised';
  end if;

  select exists (select 1 from public.user_roles ur
                 where ur.user_id = p_user and ur.role = p_role::public.app_role)
    into v_held;

  if p_action = 'grant' then
    if v_held then
      return jsonb_build_object('changed', false, 'user_id', p_user, 'role', p_role, 'action', p_action);
    end if;

    insert into public.user_roles (user_id, role) values (p_user, p_role::public.app_role);

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'role_granted', p_user, format('role %s; %s', p_role, v_reason));
  else
    if not v_held then
      return jsonb_build_object('changed', false, 'user_id', p_user, 'role', p_role, 'action', p_action);
    end if;

    if p_role = 'admin'
       and (select count(*) from public.user_roles ur where ur.role = 'admin') <= 1 then
      raise exception 'The last remaining admin cannot be revoked.'
        using errcode = 'P0001', detail = 'last_admin';
    end if;

    delete from public.user_roles ur
    where ur.user_id = p_user and ur.role = p_role::public.app_role;

    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (v_actor, 'role_revoked', p_user, format('role %s; %s', p_role, v_reason));
  end if;

  return jsonb_build_object('changed', true, 'user_id', p_user, 'role', p_role, 'action', p_action);
end;
$$;

comment on function public.admin_set_user_role(uuid, text, text, text) is
  'Phase 6L.2. Admin-only (require_admin(), so MFA applies). Grants/revokes staff or admin. Reason 3-200 chars; no self-change; last admin protected; no-ops write no audit row; one admin_audit_log row per real change (role_granted / role_revoked, no emails).';

revoke all on function public.admin_set_user_role(uuid, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.admin_set_user_role(uuid, text, text, text) to authenticated;

-- ---- 2. admin_list_role_holders -----------------------------------------------------------
create function public.admin_list_role_holders()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_admin();

  return jsonb_build_object('holders', coalesce((
    select jsonb_agg(
             jsonb_build_object('user_id', x.user_id, 'role', x.role::text, 'granted_at', x.created_at)
             order by x.created_at, x.user_id, x.role::text)
    from (
      select ur.user_id, ur.role, ur.created_at
      from public.user_roles ur
      where ur.role in ('staff', 'admin')
    ) x
  ), '[]'::jsonb));
end;
$$;

comment on function public.admin_list_role_holders() is
  'Phase 6L.2. Admin-only (require_admin()). Staff and admin rows: user_id, role, granted_at. No emails or names.';

revoke all on function public.admin_list_role_holders()
  from public, anon, authenticated, service_role;
grant execute on function public.admin_list_role_holders() to authenticated;

-- ---- 3. Self-check: refuse to commit unless exactly as designed ----------------------------
do $chk$
declare
  v_sig text;
begin
  foreach v_sig in array array['public.admin_set_user_role(uuid,text,text,text)',
                               'public.admin_list_role_holders()'] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'Phase 6L.2 self-check failed: % is missing.', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'EXECUTE')
       or has_function_privilege('service_role', v_sig, 'EXECUTE')
       or not has_function_privilege('authenticated', v_sig, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_sig) and a.privilege_type = 'EXECUTE' and a.grantee = 0) then
      raise exception 'Phase 6L.2 self-check failed: % must be executable by authenticated only.', v_sig;
    end if;
    if not exists (select 1 from pg_proc p
                   where p.oid = to_regprocedure(v_sig)
                     and p.prosecdef
                     and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                     and p.prosrc like '%public.require_admin()%'
                     and p.prosrc not ilike '%email%') then
      raise exception 'Phase 6L.2 self-check failed: % is not SECURITY DEFINER / gated / email-free as designed.', v_sig;
    end if;
  end loop;

  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.admin_set_user_role(uuid,text,text,text)'::regprocedure
                   and p.prosrc like '%role_granted%' and p.prosrc like '%role_revoked%'
                   and p.prosrc like '%cannot_change_own_role%' and p.prosrc like '%last_admin%') then
    raise exception 'Phase 6L.2 self-check failed: admin_set_user_role() is missing a required rule.';
  end if;
end
$chk$;

commit;
