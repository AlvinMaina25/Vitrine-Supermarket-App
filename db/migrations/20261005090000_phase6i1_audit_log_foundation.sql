-- =============================================================================
-- PHASE 6I.1 - AUDIT LOG FOUNDATION. NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005080000. One transaction.
--
-- DOES:
--   1. Makes public.admin_audit_log APPEND-ONLY:
--        * revokes UPDATE, DELETE, TRUNCATE from PUBLIC, anon, authenticated and service_role;
--        * adds BEFORE UPDATE OR DELETE (row) and BEFORE TRUNCATE (statement) triggers that raise,
--          so even the table owner / a superuser session cannot change or remove rows.
--        * ONE narrow exception: the existing FK actor_id -> auth.users ON DELETE SET NULL. When an
--          auth user is deleted, Postgres itself nulls actor_id inside a nested trigger. Without
--          this exception a user could never be deleted. The exception allows ONLY
--          actor_id: not null -> null, every other column identical, and only at trigger depth > 1.
--   2. Closes direct reads: drops the admin SELECT policy and revokes SELECT from PUBLIC, anon and
--      authenticated. service_role keeps SELECT and INSERT.
--   3. Adds admin_list_audit_log(p_actor, p_action, p_target_id, p_from, p_to, p_limit, p_offset):
--      the ONLY browser read path. Admin only (require_admin()), newest first, limit capped at 100,
--      returns total_count. Errors: SQLSTATE 42501 / DETAIL not_authorised;
--      SQLSTATE P0001 / DETAIL invalid_arguments.
-- DOES NOT: add a deletion or retention path (6I.3), add any writer, change any other function,
--   table, grant or policy, or store any new data. Returned columns are exactly the existing six:
--   id, actor_id, action, target_id, reason, created_at.
-- NOTE: a superuser can still bypass triggers with session_replication_role = replica, or drop the
--   trigger. That is outside what in-database controls can prevent.
-- =============================================================================
begin;

do $pre$
begin
  if to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.require_admin()') is null
     or to_regprocedure('public.is_admin(uuid)') is null
     or to_regprocedure('public.admin_get_payment_transaction(uuid)') is null then
    raise exception 'Phase 6I.1 precondition failed: apply migrations up to 20261005080000 first.';
  end if;
  if to_regprocedure('public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)') is not null
     or exists (select 1 from pg_trigger
                where tgrelid = 'public.admin_audit_log'::regclass and tgname in ('admin_audit_log_no_change', 'admin_audit_log_no_truncate')) then
    raise exception 'Phase 6I.1 appears to be applied already. Not running it twice.';
  end if;
  if not exists (select 1 from pg_policy p
                 where p.polrelid = 'public.admin_audit_log'::regclass and p.polname = 'Audit log: admin read') then
    raise exception 'Phase 6I.1 precondition failed: admin_audit_log is not in the 6E.3 read state. Inspect before continuing.';
  end if;
end
$pre$;

-- 1. Append-only: privileges -----------------------------------------------------
revoke update, delete, truncate on public.admin_audit_log from public, anon, authenticated, service_role;

-- 2. Append-only: triggers -------------------------------------------------------
create function public.admin_audit_log_block_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- The only allowed change: the FK's ON DELETE SET NULL on actor_id (nested trigger, nothing else touched).
  if tg_op = 'UPDATE'
     and pg_trigger_depth() > 1
     and old.actor_id is not null
     and new.actor_id is null
     and (new.id, new.action, new.target_id, new.reason, new.created_at)
         is not distinct from (old.id, old.action, old.target_id, old.reason, old.created_at) then
    return new;
  end if;
  raise exception 'The audit log is append-only.'
    using errcode = 'P0001', detail = 'audit_log_append_only';
end;
$$;

create function public.admin_audit_log_block_truncate()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'The audit log is append-only.'
    using errcode = 'P0001', detail = 'audit_log_append_only';
end;
$$;

revoke all on function public.admin_audit_log_block_change() from public, anon, authenticated;
revoke all on function public.admin_audit_log_block_truncate() from public, anon, authenticated;

create trigger admin_audit_log_no_change
  before update or delete on public.admin_audit_log
  for each row execute function public.admin_audit_log_block_change();

create trigger admin_audit_log_no_truncate
  before truncate on public.admin_audit_log
  for each statement execute function public.admin_audit_log_block_truncate();

-- 3. Close direct reads ----------------------------------------------------------
drop policy "Audit log: admin read" on public.admin_audit_log;
alter table public.admin_audit_log enable row level security;
revoke select on public.admin_audit_log from public, anon, authenticated;

-- 4. The only read path -----------------------------------------------------------
create function public.admin_list_audit_log(
  p_actor uuid default null,
  p_action text default null,
  p_target_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer;
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_admin();

  if p_limit is null or p_limit < 1
     or p_offset is null or p_offset < 0
     or (p_from is not null and p_to is not null and p_from >= p_to)
     or (p_action is not null and char_length(p_action) not between 1 and 80) then
    raise exception 'Invalid audit log list arguments.'
      using errcode = 'P0001', detail = 'invalid_arguments';
  end if;

  v_limit := least(p_limit, 100);

  select count(*) into v_total
  from public.admin_audit_log a
  where (p_actor is null or a.actor_id = p_actor)
    and (p_action is null or a.action = p_action)
    and (p_target_id is null or a.target_id = p_target_id)
    and (p_from is null or a.created_at >= p_from)
    and (p_to is null or a.created_at < p_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'actor_id', x.actor_id,
           'action', x.action,
           'target_id', x.target_id,
           'reason', x.reason,
           'created_at', x.created_at
         ) order by x.created_at desc, x.id desc), '[]'::jsonb)
  into v_rows
  from (
    select a.id, a.actor_id, a.action, a.target_id, a.reason, a.created_at
    from public.admin_audit_log a
    where (p_actor is null or a.actor_id = p_actor)
      and (p_action is null or a.action = p_action)
      and (p_target_id is null or a.target_id = p_target_id)
      and (p_from is null or a.created_at >= p_from)
      and (p_to is null or a.created_at < p_to)
    order by a.created_at desc, a.id desc
    limit v_limit offset p_offset
  ) x;

  return jsonb_build_object('total_count', v_total, 'limit', v_limit, 'offset', p_offset, 'entries', v_rows);
end;
$$;

comment on function public.admin_list_audit_log(uuid, text, uuid, timestamptz, timestamptz, integer, integer) is
  'Phase 6I.1. Admin-only, read-only filtered/paged audit log, newest first (limit capped at 100). The only browser read path.';

revoke all on function public.admin_list_audit_log(uuid, text, uuid, timestamptz, timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.admin_list_audit_log(uuid, text, uuid, timestamptz, timestamptz, integer, integer) to authenticated;

-- 5. Self-check: refuse to commit unless exactly as designed ----------------------
do $chk$
declare
  v_role text;
  v_priv text;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.admin_audit_log'::regclass) then
    raise exception 'Phase 6I.1 self-check failed: RLS is not enabled on admin_audit_log.';
  end if;
  if exists (select 1 from pg_policy p
             where p.polrelid = 'public.admin_audit_log'::regclass and p.polcmd in ('r', '*')) then
    raise exception 'Phase 6I.1 self-check failed: a SELECT/ALL policy remains on admin_audit_log.';
  end if;

  foreach v_role in array array['anon', 'authenticated'] loop
    foreach v_priv in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      if has_table_privilege(v_role, 'public.admin_audit_log', v_priv) then
        raise exception 'Phase 6I.1 self-check failed: % has % on admin_audit_log.', v_role, v_priv;
      end if;
    end loop;
    if has_any_column_privilege(v_role, 'public.admin_audit_log', 'SELECT') then
      raise exception 'Phase 6I.1 self-check failed: % has column SELECT on admin_audit_log.', v_role;
    end if;
  end loop;

  if exists (select 1 from pg_class c, aclexplode(c.relacl) a
             where c.oid = 'public.admin_audit_log'::regclass
               and a.privilege_type in ('SELECT', 'UPDATE', 'DELETE', 'TRUNCATE')
               and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated')))) then
    raise exception 'Phase 6I.1 self-check failed: table ACL grants a read/change privilege to PUBLIC/anon/authenticated.';
  end if;

  foreach v_priv in array array['UPDATE', 'DELETE', 'TRUNCATE'] loop
    if has_table_privilege('service_role', 'public.admin_audit_log', v_priv) then
      raise exception 'Phase 6I.1 self-check failed: service_role still has % on admin_audit_log.', v_priv;
    end if;
  end loop;
  foreach v_priv in array array['SELECT', 'INSERT'] loop
    if not has_table_privilege('service_role', 'public.admin_audit_log', v_priv) then
      raise exception 'Phase 6I.1 self-check failed: service_role lost % on admin_audit_log.', v_priv;
    end if;
  end loop;

  if (select count(*) from pg_trigger
      where tgrelid = 'public.admin_audit_log'::regclass and not tgisinternal
        and tgname in ('admin_audit_log_no_change', 'admin_audit_log_no_truncate') and tgenabled = 'O') <> 2 then
    raise exception 'Phase 6I.1 self-check failed: append-only triggers are missing or disabled.';
  end if;

  if has_function_privilege('anon', 'public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)', 'EXECUTE') then
    raise exception 'Phase 6I.1 self-check failed: admin_list_audit_log grants are wrong.';
  end if;
end
$chk$;

commit;
