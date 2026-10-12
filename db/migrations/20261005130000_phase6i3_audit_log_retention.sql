-- =============================================================================
-- PHASE 6I.3 - AUDIT LOG RETENTION (2 YEARS). NOT APPLIED / NOT RUN anywhere.
-- Apply once, after 20261005120000. One transaction.
--
-- DOES:
--   1. Adds public.prune_admin_audit_log(): SECURITY DEFINER, search_path = public, pg_temp,
--      NO arguments. EXECUTE for the owner and service_role only (revoked from PUBLIC, anon,
--      authenticated). The 2-year period is a constant inside the function body, so it cannot be
--      passed in or shortened. Each call deletes at most 5000 rows with
--      created_at < now() - interval '2 years' (oldest first) and returns the number deleted.
--   2. Replaces the 6I.1 trigger function public.admin_audit_log_block_change() (same name and
--      signature, so the trigger, its grants and its owner are kept). A DELETE is now allowed ONLY
--      when BOTH hold: the transaction-local flag app.audit_log_prune_active is 'on' (set with
--      set_config(..., true) by prune_admin_audit_log(), cleared again before it returns) AND the
--      row is older than 2 years. Every other DELETE still raises for every role. UPDATE is still
--      blocked except the 6I.1 actor_id ON DELETE SET NULL exception, kept exactly as it was
--      (nested trigger, pg_trigger_depth() > 1, actor_id not null -> null, nothing else changed).
--      TRUNCATE stays blocked (admin_audit_log_block_truncate is not touched).
--   3. A run that deletes at least one row writes ONE summary row: actor_id null, target_id null,
--      action 'audit_log_pruned', reason 'deleted_rows=<n>; cutoff=<YYYY-MM-DD, UTC>'. Nothing else.
--      A run that deletes nothing writes no row. The summary row is an ordinary row: it can itself
--      be pruned only once it is older than 2 years.
--   4. Scheduling: if the pg_cron extension is ALREADY installed, schedules job
--      'prune-admin-audit-log' daily at 03:17 UTC. If it is not installed, nothing is enabled and
--      nothing is scheduled (the function is simply installed). This migration never runs
--      CREATE EXTENSION. To schedule later, after enabling pg_cron (Dashboard -> Database ->
--      Extensions -> pg_cron), run:
--        select cron.schedule('prune-admin-audit-log', '17 3 * * *', 'select public.prune_admin_audit_log()');
-- DOES NOT: add any admin/API delete or purge function, any argument that sets a period, any new
--   audit coverage, or change any table, column, index, policy, other function or other grant.
--   Grants on admin_audit_log are unchanged (service_role still has no UPDATE/DELETE/TRUNCATE).
-- NOTE: the flag is not a secret. Anyone who can already run a DELETE on the table (only the owner
--   or a superuser; no API role has the privilege) could set it, but even then the trigger still
--   refuses every row younger than 2 years. A superuser can also bypass triggers entirely with
--   session_replication_role = replica or drop the trigger; no in-database control prevents that.
-- =============================================================================
begin;

do $pre$
declare
  v_owner oid;
begin
  if to_regclass('public.admin_audit_log') is null
     or to_regprocedure('public.admin_audit_log_block_change()') is null
     or to_regprocedure('public.admin_audit_log_block_truncate()') is null
     or to_regprocedure('public.admin_list_audit_log(uuid,text,uuid,timestamptz,timestamptz,integer,integer)') is null then
    raise exception 'Phase 6I.3 precondition failed: Phase 6I.1 is not applied (audit table / trigger functions / reader missing).';
  end if;
  if to_regprocedure('public.prune_admin_audit_log()') is not null then
    raise exception 'Phase 6I.3 appears to be applied already (prune_admin_audit_log exists). Not running it twice.';
  end if;

  -- The two 6I.1 triggers must exist, be enabled and have the 6I.1 shape.
  --   tgtype bits: 1 ROW, 2 BEFORE, 8 DELETE, 16 UPDATE, 32 TRUNCATE.
  if not exists (select 1 from pg_trigger t
                 where t.tgrelid = 'public.admin_audit_log'::regclass and not t.tgisinternal
                   and t.tgname = 'admin_audit_log_no_change' and t.tgenabled = 'O'
                   and t.tgtype = 27
                   and t.tgfoid = 'public.admin_audit_log_block_change()'::regprocedure)
     or not exists (select 1 from pg_trigger t
                    where t.tgrelid = 'public.admin_audit_log'::regclass and not t.tgisinternal
                      and t.tgname = 'admin_audit_log_no_truncate' and t.tgenabled = 'O'
                      and t.tgtype = 34
                      and t.tgfoid = 'public.admin_audit_log_block_truncate()'::regprocedure) then
    raise exception 'Phase 6I.3 precondition failed: the 6I.1 append-only triggers are not as 6I.1 describes. Inspect before continuing.';
  end if;

  -- The trigger function must still be the 6I.1 body (and not already carry the retention rule).
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.admin_audit_log_block_change()'::regprocedure
                   and p.prosrc like '%pg_trigger_depth() > 1%'
                   and p.prosrc like '%audit_log_append_only%'
                   and p.prosrc not like '%audit_log_prune_active%') then
    raise exception 'Phase 6I.3 precondition failed: admin_audit_log_block_change() is not the 6I.1 version. Inspect before continuing.';
  end if;

  -- Table state: RLS on and NOT forced (the owner-run function must be able to delete), no API-role
  -- UPDATE/DELETE/TRUNCATE, service_role without UPDATE/DELETE/TRUNCATE.
  if not exists (select 1 from pg_class c
                 where c.oid = 'public.admin_audit_log'::regclass
                   and c.relrowsecurity and not c.relforcerowsecurity) then
    raise exception 'Phase 6I.3 precondition failed: admin_audit_log must have RLS enabled and not forced.';
  end if;
  if has_table_privilege('service_role', 'public.admin_audit_log', 'UPDATE')
     or has_table_privilege('service_role', 'public.admin_audit_log', 'DELETE')
     or has_table_privilege('service_role', 'public.admin_audit_log', 'TRUNCATE')
     or has_table_privilege('anon', 'public.admin_audit_log', 'DELETE')
     or has_table_privilege('authenticated', 'public.admin_audit_log', 'DELETE') then
    raise exception 'Phase 6I.3 precondition failed: admin_audit_log grants are not as 6I.1 left them.';
  end if;

  -- The SECURITY DEFINER function will be owned by whoever runs this migration; it must be the table owner.
  select c.relowner into v_owner from pg_class c where c.oid = 'public.admin_audit_log'::regclass;
  if v_owner is distinct from (select r.oid from pg_roles r where r.rolname = current_user) then
    raise exception 'Phase 6I.3 precondition failed: run this migration as the owner of public.admin_audit_log.';
  end if;

  -- Baselines for the post-check (transaction-local).
  perform set_config('p6i3.other_fn_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname not in ('admin_audit_log_block_change', 'prune_admin_audit_log')), true);
  perform set_config('p6i3.acl_hash',
    (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                    order by p.oid::regprocedure::text), ''))
     from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname <> 'prune_admin_audit_log'), true);
  perform set_config('p6i3.table_acl',
    (select coalesce(c.relacl::text, '') from pg_class c where c.oid = 'public.admin_audit_log'::regclass), true);
  perform set_config('p6i3.audit_count', (select count(*) from public.admin_audit_log)::text, true);
end
$pre$;

-- 1. The trigger function: 6I.1 behaviour + the narrow retention DELETE ---------------
create or replace function public.admin_audit_log_block_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Retention (6I.3): a DELETE only inside prune_admin_audit_log() (transaction-local flag) and only
  -- for a row older than 2 years. Both conditions are required; the age rule holds even if the flag is set.
  if tg_op = 'DELETE'
     and coalesce(current_setting('app.audit_log_prune_active', true), '') = 'on'
     and old.created_at < now() - interval '2 years' then
    return old;
  end if;
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

-- 2. The pruning function --------------------------------------------------------------
create function public.prune_admin_audit_log()
returns integer
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_retention constant interval := interval '2 years';  -- fixed: not an argument, cannot be shortened
  v_batch constant integer := 5000;
  v_cutoff timestamptz;
  v_deleted integer;
begin
  v_cutoff := now() - v_retention;

  -- Open the delete window for this transaction only.
  perform set_config('app.audit_log_prune_active', 'on', true);

  with doomed as (
    select a.id
    from public.admin_audit_log a
    where a.created_at < v_cutoff
    order by a.created_at, a.id
    limit v_batch
  )
  delete from public.admin_audit_log t
  using doomed d
  where t.id = d.id;
  get diagnostics v_deleted = row_count;

  -- Close the window again before anything else runs in this transaction.
  perform set_config('app.audit_log_prune_active', 'off', true);

  -- One summary row per run that deleted something: counts and cutoff date only.
  if v_deleted > 0 then
    insert into public.admin_audit_log (actor_id, action, target_id, reason)
    values (null, 'audit_log_pruned', null,
            format('deleted_rows=%s; cutoff=%s', v_deleted, to_char(v_cutoff at time zone 'UTC', 'YYYY-MM-DD')));
  end if;

  return v_deleted;
end;
$fn$;

comment on function public.prune_admin_audit_log() is
  'Phase 6I.3. Deletes admin_audit_log rows older than 2 years (fixed, not an argument), at most 5000 per call, oldest first; writes one audit_log_pruned summary row if anything was deleted. Owner and service_role only.';

revoke all on function public.prune_admin_audit_log() from public, anon, authenticated;
grant execute on function public.prune_admin_audit_log() to service_role;

-- 3. Scheduling: only if pg_cron is ALREADY installed ------------------------------------
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute format('select cron.schedule(%L, %L, %L)',
                   'prune-admin-audit-log', '17 3 * * *', 'select public.prune_admin_audit_log()');
    raise notice 'Phase 6I.3: pg_cron found; scheduled job prune-admin-audit-log (daily 03:17 UTC).';
  else
    raise notice 'Phase 6I.3: pg_cron is not installed; prune_admin_audit_log() installed but NOT scheduled.';
  end if;
end
$cron$;

-- 4. Self-check: refuse to commit unless exactly as designed -------------------------------
do $chk$
declare
  v_role text;
  v_priv text;
  v_jobs bigint;
begin
  -- prune function shape
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.prune_admin_audit_log()'::regprocedure
                   and p.pronargs = 0 and p.prosecdef and p.provolatile = 'v'
                   and p.prorettype = 'integer'::regtype
                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%'
                   and p.proowner = (select c.relowner from pg_class c where c.oid = 'public.admin_audit_log'::regclass)
                   and p.prosrc like '%interval ''2 years''%'
                   and p.prosrc like '%limit v_batch%') then
    raise exception 'Phase 6I.3 self-check failed: prune_admin_audit_log() is not as designed.';
  end if;

  -- EXECUTE: owner and service_role only
  foreach v_role in array array['anon', 'authenticated'] loop
    if has_function_privilege(v_role, 'public.prune_admin_audit_log()', 'EXECUTE') then
      raise exception 'Phase 6I.3 self-check failed: % can execute prune_admin_audit_log().', v_role;
    end if;
  end loop;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
             where p.oid = 'public.prune_admin_audit_log()'::regprocedure
               and a.privilege_type = 'EXECUTE'
               and a.grantee not in (p.proowner, (select oid from pg_roles where rolname = 'service_role'))) then
    raise exception 'Phase 6I.3 self-check failed: prune_admin_audit_log() is executable by a role other than the owner and service_role (PUBLIC included).';
  end if;
  if not has_function_privilege('service_role', 'public.prune_admin_audit_log()', 'EXECUTE') then
    raise exception 'Phase 6I.3 self-check failed: service_role cannot execute prune_admin_audit_log().';
  end if;

  -- trigger function replaced; triggers unchanged; trigger functions still not callable by API roles
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.admin_audit_log_block_change()'::regprocedure
                   and p.prosrc like '%app.audit_log_prune_active%'
                   and p.prosrc like '%interval ''2 years''%'
                   and p.prosrc like '%pg_trigger_depth() > 1%'
                   and p.prosrc like '%audit_log_append_only%'
                   and coalesce(p.proconfig::text, '') like '%search_path=public, pg_temp%') then
    raise exception 'Phase 6I.3 self-check failed: admin_audit_log_block_change() is not as designed.';
  end if;
  if (select count(*) from pg_trigger t
      where t.tgrelid = 'public.admin_audit_log'::regclass and not t.tgisinternal and t.tgenabled = 'O'
        and ((t.tgname = 'admin_audit_log_no_change' and t.tgtype = 27
              and t.tgfoid = 'public.admin_audit_log_block_change()'::regprocedure)
          or (t.tgname = 'admin_audit_log_no_truncate' and t.tgtype = 34
              and t.tgfoid = 'public.admin_audit_log_block_truncate()'::regprocedure))) <> 2 then
    raise exception 'Phase 6I.3 self-check failed: append-only triggers are missing, changed or disabled.';
  end if;
  foreach v_role in array array['anon', 'authenticated'] loop
    if has_function_privilege(v_role, 'public.admin_audit_log_block_change()', 'EXECUTE')
       or has_function_privilege(v_role, 'public.admin_audit_log_block_truncate()', 'EXECUTE') then
      raise exception 'Phase 6I.3 self-check failed: % can execute an append-only trigger function.', v_role;
    end if;
  end loop;

  -- table grants unchanged: nobody gained or lost anything
  if (select coalesce(c.relacl::text, '') from pg_class c where c.oid = 'public.admin_audit_log'::regclass)
     is distinct from current_setting('p6i3.table_acl') then
    raise exception 'Phase 6I.3 self-check failed: the table ACL of admin_audit_log changed.';
  end if;
  foreach v_priv in array array['UPDATE', 'DELETE', 'TRUNCATE'] loop
    if has_table_privilege('service_role', 'public.admin_audit_log', v_priv)
       or has_table_privilege('anon', 'public.admin_audit_log', v_priv)
       or has_table_privilege('authenticated', 'public.admin_audit_log', v_priv) then
      raise exception 'Phase 6I.3 self-check failed: an API role has % on admin_audit_log.', v_priv;
    end if;
  end loop;

  -- no other function changed (apart from the trigger function and the new prune function) and no other ACL changed
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || md5(p.prosrc), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname not in ('admin_audit_log_block_change', 'prune_admin_audit_log'))
     is distinct from current_setting('p6i3.other_fn_hash') then
    raise exception 'Phase 6I.3 self-check failed: a function other than the two intended ones changed.';
  end if;
  if (select md5(coalesce(string_agg(p.oid::regprocedure::text || '/' || coalesce(p.proacl::text, ''), '|'
                                     order by p.oid::regprocedure::text), ''))
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname <> 'prune_admin_audit_log')
     is distinct from current_setting('p6i3.acl_hash') then
    raise exception 'Phase 6I.3 self-check failed: a function ACL changed.';
  end if;

  -- the prune function is the ONLY code that deletes from the audit log; no function takes a period
  if exists (select 1 from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname <> 'prune_admin_audit_log'
               and p.prosrc ~* 'delete\s+from\s+(only\s+)?(public\.)?admin_audit_log\M') then
    raise exception 'Phase 6I.3 self-check failed: another function deletes from admin_audit_log.';
  end if;

  -- this migration wrote and removed nothing
  if (select count(*) from public.admin_audit_log)::text is distinct from current_setting('p6i3.audit_count') then
    raise exception 'Phase 6I.3 self-check failed: the audit row count changed during the migration.';
  end if;

  -- the delete window is closed
  if coalesce(current_setting('app.audit_log_prune_active', true), '') = 'on' then
    raise exception 'Phase 6I.3 self-check failed: the prune flag is on.';
  end if;

  -- scheduling, only when pg_cron is installed
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute format('select count(*) from cron.job where jobname = %L and command like %L',
                   'prune-admin-audit-log', '%prune_admin_audit_log()%') into v_jobs;
    if v_jobs <> 1 then
      raise exception 'Phase 6I.3 self-check failed: pg_cron is installed but the prune job is not scheduled exactly once.';
    end if;
  end if;
end
$chk$;

commit;
