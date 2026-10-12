-- =============================================================================
-- PHASE 6E.1B-2 - customer internal notes. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261004140000. One transaction.
--
-- ADDS: public.customer_notes (separate table, so customers can never read notes) and
--       admin_update_customer_notes(p_customer_id, p_notes) - ADMIN-ONLY (require_admin()).
-- DOES NOT: change admin_list_customers(), admin_get_customer(), profiles, grants on existing
--       tables, or any earlier migration.
--
-- ACCESS: RLS on. The only policy is a SELECT for staff/admin - the same rule admin_audit_log uses.
--   There is no customer policy, and no INSERT/UPDATE/DELETE grant or policy for browser roles.
--   Writes happen only inside admin_update_customer_notes().
-- AUDIT: action 'customer_notes_updated'. The note text is NEVER stored in the audit row; its
--   reason column holds 'length=<n>' (or 'length=0' when the notes were cleared).
-- CLEARING: an empty (or whitespace-only) string clears the notes: the row is kept with notes = ''
--   so updated_by / updated_at still show who cleared it, and the audit row records it.
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.admin_set_customer_status(uuid,text,text)') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_staff(uuid)') is null then
    raise exception 'Phase 6E.1B-2 precondition failed: apply 20261004140000 first.';
  end if;
  if to_regclass('public.customer_notes') is not null
     or to_regprocedure('public.admin_update_customer_notes(uuid,text)') is not null then
    raise exception 'Phase 6E.1B-2 appears to be applied already. Not running it twice.';
  end if;
end
$pre$;

-- 1. Table
create table public.customer_notes (
  customer_id uuid primary key references public.profiles (id) on delete cascade,
  notes text not null default '',
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint customer_notes_length check (char_length(notes) <= 2000)
);

alter table public.customer_notes enable row level security;
revoke all on public.customer_notes from public, anon, authenticated;
grant select on public.customer_notes to authenticated;   -- narrowed to staff by the policy below
grant all on public.customer_notes to service_role;

create policy "Customer notes: staff read"
  on public.customer_notes for select to authenticated
  using (public.is_staff(auth.uid()));

-- 2. admin_update_customer_notes()
-- Returns { customer_id, length } (length of the trimmed text now stored; 0 = cleared).
-- Errors (after the admin gate): P0001 with DETAIL invalid_arguments, notes_too_long,
-- customer_not_found, cannot_target_staff. Gate failure: 42501 / not_authorised.
create function public.admin_update_customer_notes(p_customer_id uuid, p_notes text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_notes text;
begin
  v_actor := public.require_admin();   -- gate first, before any argument is examined

  if p_customer_id is null or p_notes is null then
    raise exception 'A customer and notes (possibly empty) are required.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_notes := btrim(p_notes);
  if char_length(v_notes) > 2000 then
    raise exception 'Notes must be at most 2000 characters.'
      using errcode = 'P0001', detail = 'notes_too_long';
  end if;

  perform 1 from public.profiles p where p.id = p_customer_id for update;
  if not found then
    raise exception 'That customer could not be found.'
      using errcode = 'P0001', detail = 'customer_not_found';
  end if;

  if exists (select 1 from public.user_roles ur
             where ur.user_id = p_customer_id and ur.role in ('staff', 'admin')) then
    raise exception 'Staff and admin accounts cannot be changed here.'
      using errcode = 'P0001', detail = 'cannot_target_staff';
  end if;

  insert into public.customer_notes (customer_id, notes, updated_by, updated_at)
  values (p_customer_id, v_notes, v_actor, now())
  on conflict (customer_id) do update
    set notes = excluded.notes, updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  insert into public.admin_audit_log (actor_id, action, target_id, reason)
  values (v_actor, 'customer_notes_updated', p_customer_id,
          'length=' || char_length(v_notes)::text);

  return jsonb_build_object('customer_id', p_customer_id, 'length', char_length(v_notes));
end;
$$;

comment on function public.admin_update_customer_notes(uuid, text) is
  'Phase 6E.1B-2. Admin-only (require_admin()). Upserts customer_notes and audits the change (length only, never the text).';

revoke all on function public.admin_update_customer_notes(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_update_customer_notes(uuid, text) to authenticated;

-- 3. Self-check
do $check$
declare v_sig constant text := 'public.admin_update_customer_notes(uuid,text)';
begin
  if exists (select 1 from pg_proc p where p.oid = v_sig::regprocedure
             and (not p.prosecdef or p.provolatile <> 'v'
                  or coalesce(p.proconfig::text, '') not like '%search_path=public, pg_temp%')) then
    raise exception 'Phase 6E.1B-2 self-check failed: not VOLATILE SECURITY DEFINER with pinned search_path.';
  end if;
  if has_function_privilege('anon', v_sig, 'EXECUTE') or not has_function_privilege('authenticated', v_sig, 'EXECUTE') then
    raise exception 'Phase 6E.1B-2 self-check failed: function privileges are wrong.';
  end if;
  if has_table_privilege('authenticated', 'public.customer_notes', 'INSERT')
     or has_table_privilege('authenticated', 'public.customer_notes', 'UPDATE')
     or has_table_privilege('authenticated', 'public.customer_notes', 'DELETE')
     or has_any_column_privilege('authenticated', 'public.customer_notes', 'INSERT')
     or has_any_column_privilege('authenticated', 'public.customer_notes', 'UPDATE')
     or has_table_privilege('anon', 'public.customer_notes', 'SELECT')
     or has_any_column_privilege('anon', 'public.customer_notes', 'SELECT')
     or not (select relrowsecurity from pg_class where oid = 'public.customer_notes'::regclass) then
    raise exception 'Phase 6E.1B-2 self-check failed: customer_notes access is wrong.';
  end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'customer_notes') <> 1
     or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_notes'
                and (cmd <> 'SELECT' or qual not like '%is_staff%')) then
    raise exception 'Phase 6E.1B-2 self-check failed: customer_notes must have exactly one staff-only SELECT policy.';
  end if;
end
$check$;

commit;
